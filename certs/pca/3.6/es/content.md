# Fundamentos de SLOs, SLAs y SLIs

> **PCA — Dominio 3: Conceptos de Observabilidad · Tema 3.6** · Peso en el examen: 3
> Nivel: SRE de Producción / Arquitecto de Plataforma. Todo está anclado en Prometheus y PromQL, porque en la PCA el SLI es *la query* y el SLO es *la regla*.

---

## 1. Motivación: el problema de producción que los SLIs/SLOs/SLAs realmente resuelven

Un servicio nunca está "arriba" o "abajo" de forma binaria. A escala está *parcialmente* degradado, *para algunos* usuarios, *durante parte* del tiempo. Dos equipos mirando la misma instancia de Prometheus van a estar en desacuerdo sobre si está ocurriendo un incidente a menos que hayan acordado, *de antemano y en una forma computable por máquina*, sobre:

1. **Qué significa "funcionar"** — un número derivado de la telemetría (el **SLI**).
2. **Cuánto "funcionar" es suficiente** — un objetivo sobre ese número a lo largo de una ventana (el **SLO**).
3. **Qué pasa cuando no es suficiente** — una decisión (paginar, congelar releases) o una consecuencia contractual (el **SLA**).

Sin esto, el alerting degenera en alertas *basadas en causas* ("CPU del nodo > 90%", "pod reiniciado") que se disparan constantemente, paginan humanos por síntomas que los clientes nunca sienten, y se quedan en silencio durante caídas que no encajan con ninguna causa preimaginada. El cambio arquitectónico que introdujo SRE es el **alerting basado en síntomas y guiado por presupuesto**: alertás sobre el *SLI visible para el usuario* consumiendo un *error budget*, no sobre causas internas.

El **error budget** es el punto de pivote. Si tu SLO es 99.9% de disponibilidad a lo largo de 30 días, tenés *permitido* 0.1% de fallo — **43.2 minutos** por cada 30 días. Ese fallo permitido es un presupuesto que podés gastar en deploys riesgosos, experimentos de caos o migraciones de infraestructura. Convierte la interminable discusión "estabilidad vs. velocidad" entre SRE y producto en aritmética: *presupuesto restante → lanzar; presupuesto agotado → congelar*. El objetivo entero de instrumentar SLIs en Prometheus es hacer que ese presupuesto sea un número PromQL en vivo, no un PowerPoint trimestral.

**Dónde encaja Prometheus:** Prometheus es donde el SLI se *computa* (PromQL sobre counters/histogramas), donde el SLO se *codifica* (recording + alerting rules), y donde el burn rate se *evalúa* (expresiones de alerta multi-ventana). Grafana/Alertmanager lo consumen; Prometheus lo produce.

---

## 2. Los tres términos, con precisión — y en qué se diferencian

| Aspecto | **SLI** (Indicator) | **SLO** (Objective) | **SLA** (Agreement) |
|---|---|---|---|
| Qué es | Una *medición* del comportamiento del servicio | Un *objetivo/rango* para un SLI a lo largo de una ventana | Un *contrato* con un cliente |
| Forma | Un número, usualmente un ratio `good/valid` en `[0,1]` | `SLI ≥ target` a lo largo de `window` (ej. ≥ 99.9% / 30d) | Documento legal + penalización financiera/de crédito |
| Audiencia | Ingenieros | Ingenieros, producto | Clientes, legal, ventas |
| Consecuencia de incumplirlo | Ninguna (es solo un número) | Interna: paginar, congelar releases, priorizar confiabilidad | Externa: reembolsos, créditos de servicio, churn |
| Quién lo fija | Derivado de la telemetría | SRE + product owner | Negocio/legal |
| Artefacto en Prometheus | Una query PromQL / recording rule | Recording rules + burn-rate alerting rules | Usualmente **no** en Prometheus (se reporta, no se alerta) |
| Rigurosidad típica | — | **Más estricto** que el SLA | **Más laxo** que el SLO (margen de seguridad) |

**Relaciones clave, memorizar para el examen:**

- **El SLA es más laxo que el SLO, que se deriva del SLI.** *Siempre* fijás tu SLO interno más estricto que el SLA que vendés, de modo que cuando empezás a incumplir el SLO tenés tiempo de reaccionar *antes* de incumplir el SLA y deber dinero. Ejemplo: SLA = 99.5% (créditos por debajo de eso), SLO interno = 99.9%.
- **Error budget = `1 − SLO`.** No `1 − SLA`.
- **Un SLA sin un SLO es inaplicable; un SLO sin un SLI es inmedible.** SLI → SLO → SLA es una cadena de dependencias.
- **Alertás sobre SLOs**, **reportás sobre SLAs**. Paginar ante un incumplimiento de SLA es demasiado tarde por definición.

### El error budget como downtime concreto (te pueden pedir esta tabla de memoria)

El error budget es `1 − SLO`. Traducido a downtime/fallo permitido por ventana:

| SLO (disponibilidad) | Error budget | Por 30 días | Por 90 días | Por 365 días |
|---|---|---|---|---|
| 99%     | 1%      | 7h 12m    | 21h 36m   | 3d 15h 36m |
| 99.5%   | 0.5%    | 3h 36m    | 10h 48m   | 1d 19h 48m |
| 99.9%   | 0.1%    | 43m 12s   | 2h 9m 36s | 8h 45m 57s |
| 99.95%  | 0.05%   | 21m 36s   | 1h 4m 48s | 4h 22m 58s |
| 99.99%  | 0.01%   | 4m 19s    | 12m 58s   | 52m 35s |
| 99.999% | 0.001%  | 25.9s     | 1m 18s    | 5m 15s |

> Aritmética: 30 días = 43,200 min. `99.9%` → `43,200 × 0.001 = 43.2 min`. Por esto "tres nueves" es el default cotidiano en producción: presupuesto sub-hora, todavía humanamente alcanzable.

---

## 3. Elegir el SLI: las dos implementaciones, y el trade-off

Hay dos formas de expresar un SLI, y a la PCA le importa que conozcas ambas porque cambian el PromQL.

| | **Basado en requests (ratio de eventos)** | **Basado en ventanas (rebanadas de tiempo)** |
|---|---|---|
| Definición | `good events / valid events` | `good time-windows / total time-windows` |
| Fuente en Prometheus | Counters (`*_total`), histogramas | Un SLI booleano evaluado por intervalo, luego `avg_over_time` |
| Forma en PromQL | `sum(rate(good[w])) / sum(rate(valid[w]))` | `avg_over_time( (sli_bool)[w] )` |
| Sensibilidad | Ponderado por tráfico — un segundo malo bajo carga pico duele proporcionalmente | Cada ventana cuenta igual sin importar el tráfico |
| Mejor para | Servicios request/response de alto volumen (APIs) | Servicios de bajo tráfico, batch, "¿está electo el líder?" |
| Modo de fallo | Denominador → 0 durante ausencia de tráfico → `NaN` | Un solo request malo en una ventana tranquila hace fallar toda la ventana |
| Recomendación de SRE | **Default.** Directamente proporcional al dolor del usuario | Usar cuando los eventos son escasos o no tienen forma de request |

### Las cuatro familias de SLI (el "menú de SLI")

| Tipo de SLI | Qué mide | Bloque de construcción en Prometheus |
|---|---|---|
| **Availability** | fracción de requests *exitosos* | ratio de counter `code!~"5.."` |
| **Latency** | fracción de requests *suficientemente rápidos* | ratio de bucket de histograma `le` |
| **Quality/Correctness** | fracción de respuestas *correctas/no degradadas* | counter a nivel de aplicación |
| **Freshness/Coverage** | recencia / completitud de datos (pipelines) | gauges de timestamp, `time() - push_time` |
| **Throughput/Durability** | para sistemas de datos | counters de dominio |

**SLI de Availability (basado en requests):**
```promql
sum(rate(http_requests_total{job="api", code!~"5.."}[5m]))
/
sum(rate(http_requests_total{job="api"}[5m]))
```

**SLI de Latency (fracción servida bajo 500 ms, desde un histograma nativo o clásico):**
```promql
sum(rate(http_request_duration_seconds_bucket{job="api", le="0.5"}[5m]))
/
sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
```
> Nota: el SLI de latency **no** es `histogram_quantile(...)`. Un cuantil te dice *dónde está el p99*; un SLI necesita *qué fracción cumplió el umbral* — eso es el ratio de conteo de buckets de arriba. Esta distinción es una trampa común de examen.

**Ratio de error (el complemento, usado para el burn rate):**
```promql
sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="api"}[5m]))
```

---

## 4. Burn rate — convertir un SLO en una alerta

La alerta ingenua "ratio de error > 0.001 durante 5m" es un desastre: se dispara ante cada pequeño blip y no puede distinguir una fuga lenta de un incendio rápido. La respuesta del SRE Workbook es el **burn rate**.

**Burn rate** = cuán rápido estás consumiendo el error budget respecto de la tasa que lo agotaría *exactamente* al final de la ventana del SLO. Burn rate `1` = perfectamente en presupuesto; burn rate `10` = te quedás sin nada en 1/10 de la ventana.

`presupuesto consumido sobre la ventana = burn_rate × (window / SLO_window)`

La condición de alerta es: `observed_error_ratio > burn_rate × (1 − SLO)`.

### Multi-window, multi-burn-rate (MWMBR) — el esquema canónico

Emparejar una **ventana larga** (precisión, pocos falsos positivos) con una **ventana corta** (reset rápido, para que la alerta se limpie rápido tras la recuperación). Para un SLO de 30 días / 99.9% (`1 − SLO = 0.001`):

| Severidad | Ventana larga | Ventana corta | Burn rate | Presupuesto consumido si se sostiene | Umbral sobre el ratio de error |
|---|---|---|---|---|---|
| **Page** (burn rápido) | 1h | 5m | **14.4** | 2% en 1h | `> 0.0144` |
| **Page** (burn medio) | 6h | 30m | **6** | 5% en 6h | `> 0.006` |
| **Ticket** (burn lento) | 3d | 6h | **1** | 10% en 3d | `> 0.001` |

> Derivación de la fila 1: `14.4 × (1h / 720h) = 0.02 = 2%`. La ventana corta (5m) también *debe* estar sobre el umbral, así la alerta se dispara rápido **y** se detiene rápido cuando el incidente termina.

**Tabla de trade-offs — estrategias de alerting:**

| Estrategia | Velocidad de detección | Falsos positivos | Tiempo de reset | ¿Consciente del presupuesto? |
|---|---|---|---|---|
| Umbral estático + `for:` largo | Lenta | Bajos | Lento | No |
| Umbral estático + `for:` corto | Rápida | Altos | Rápido | No |
| Burn rate único, ventana única | Media | Medios | Pobre | Sí |
| **Multi-window multi-burn-rate** | **Rápida para incendios grandes, paciente para fugas** | **Bajos** | **Rápido** | **Sí** |

---

## 5. Infraestructura completa — manifiestos, sin abreviar

### 5.1 Recording rules: precomputar el ratio de error del SLI en cada ventana

Precomputar mantiene las expresiones de alerta baratas y consistentes (computar una vez, referenciar muchas). `slo:sli_error:ratio_rateXX` es la convención de nombrado de facto popularizada por Sloth.

```yaml
# slo-api-availability.rules.yml
groups:
  - name: slo-api-availability:sli-ratios
    interval: 30s
    rules:
      - record: slo:sli_error:ratio_rate5m
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
          /
          sum(rate(http_requests_total{job="api"}[5m]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate30m
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[30m]))
          /
          sum(rate(http_requests_total{job="api"}[30m]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate1h
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[1h]))
          /
          sum(rate(http_requests_total{job="api"}[1h]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate6h
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[6h]))
          /
          sum(rate(http_requests_total{job="api"}[6h]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate1d
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[1d]))
          /
          sum(rate(http_requests_total{job="api"}[1d]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate3d
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[3d]))
          /
          sum(rate(http_requests_total{job="api"}[3d]))
        labels:
          slo: api-availability
          service: api

  # Metadatos estáticos para que dashboards/alertas puedan leer el objetivo y la ventana
  - name: slo-api-availability:metadata
    rules:
      - record: slo:objective:ratio
        expr: vector(0.999)
        labels: { slo: api-availability, service: api }
      - record: slo:error_budget:ratio
        expr: vector(1 - 0.999)     # 0.001
        labels: { slo: api-availability, service: api }
      # Error budget restante como fracción en [0,1] sobre la ventana de 30d
      # (usa el ratio de 3d escalado — para 30d exacto usá una regla ratio_rate30d; los rangos largos son caros)
      - record: slo:error_budget:remaining_ratio
        expr: |
          1 - (
            avg_over_time(slo:sli_error:ratio_rate1h{slo="api-availability"}[30d])
            / 0.001
          )
        labels: { slo: api-availability, service: api }
```

### 5.2 Alerting rules: las alertas MWMBR de page + ticket

```yaml
# slo-api-availability.alerts.yml
groups:
  - name: slo-api-availability:alerts
    rules:
      # ---- PAGE: burn rápido (14.4 sobre 1h/5m, O 6 sobre 6h/30m) ----
      - alert: ApiAvailabilityErrorBudgetBurnPage
        expr: |
          (
            slo:sli_error:ratio_rate1h{slo="api-availability"} > (14.4 * 0.001)
            and
            slo:sli_error:ratio_rate5m{slo="api-availability"} > (14.4 * 0.001)
          )
          or
          (
            slo:sli_error:ratio_rate6h{slo="api-availability"} > (6 * 0.001)
            and
            slo:sli_error:ratio_rate30m{slo="api-availability"} > (6 * 0.001)
          )
        labels:
          severity: page
          slo: api-availability
        annotations:
          summary: "High error-budget burn on api-availability (page)"
          description: >
            Error budget for SLO api-availability (99.9% / 30d) is burning
            fast. Current 1h error ratio:
            {{ printf "%.4f" $value }}. At this rate a significant fraction of
            the 30d budget is consumed within hours.
          runbook_url: "https://runbooks.internal/slo/api-availability"

      # ---- TICKET: burn lento (1 sobre 3d/6h) ----
      - alert: ApiAvailabilityErrorBudgetBurnTicket
        expr: |
          slo:sli_error:ratio_rate3d{slo="api-availability"} > (1 * 0.001)
          and
          slo:sli_error:ratio_rate6h{slo="api-availability"} > (1 * 0.001)
        labels:
          severity: ticket
          slo: api-availability
        annotations:
          summary: "Slow error-budget burn on api-availability (ticket)"
          description: >
            Sustained low-level errors are eroding the 30d error budget.
            3d error ratio: {{ printf "%.4f" $value }}. Investigate within
            business hours before the budget is exhausted.
          runbook_url: "https://runbooks.internal/slo/api-availability"
```

### 5.3 Generarlo todo desde una sola spec con **Sloth** (recomendado en producción)

Escribir a mano seis ventanas × N SLOs no escala. Sloth genera las recording + MWMBR alerting rules a partir de una spec declarativa compacta.

```yaml
# sloth-api.yml
version: "prometheus/v1"
service: "api"
labels:
  team: "platform"
  tier: "1"
slos:
  - name: "requests-availability"
    objective: 99.9
    description: "99.9% of API requests over 30d return non-5xx."
    sli:
      events:
        error_query: sum(rate(http_requests_total{job="api", code=~"5.."}[{{.window}}]))
        total_query: sum(rate(http_requests_total{job="api"}[{{.window}}]))
    alerting:
      name: ApiAvailabilityHighErrorRate
      labels:
        category: "availability"
      annotations:
        summary: "High error rate on the API SLI"
      page_alert:
        labels:
          severity: page
      ticket_alert:
        labels:
          severity: ticket

  - name: "requests-latency"
    objective: 99.0
    description: "99% of API requests over 30d complete under 500ms."
    sli:
      events:
        error_query: |
          (
            sum(rate(http_request_duration_seconds_count{job="api"}[{{.window}}]))
            -
            sum(rate(http_request_duration_seconds_bucket{job="api", le="0.5"}[{{.window}}]))
          )
        total_query: sum(rate(http_request_duration_seconds_count{job="api"}[{{.window}}]))
    alerting:
      name: ApiLatencyHighErrorRate
      page_alert:
        labels: { severity: page }
      ticket_alert:
        labels: { severity: ticket }
```

### 5.4 SLOs nativos de Kubernetes con **Pyrra** (guiados por CRD)

Pyrra expone un CRD `ServiceLevelObjective`, genera las reglas de Prometheus, y trae una UI que muestra el presupuesto restante. Ideal cuando los SLOs deben vivir en Git junto al workload.

```yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: api-availability
  namespace: monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  target: "99.9"          # objetivo como porcentaje
  window: 4w              # ventana rodante del SLO
  description: "API 5xx availability."
  indicator:
    ratio:
      errors:
        metric: http_requests_total{job="api", code=~"5.."}
      total:
        metric: http_requests_total{job="api"}
```

### 5.5 Conectar las reglas en Prometheus y enrutar la alerta

```yaml
# prometheus.yml (excerpt)
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/slo-*.rules.yml
  - /etc/prometheus/rules/slo-*.alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

```yaml
# alertmanager.yml (excerpt) — page vs ticket enrutan a receivers distintos
route:
  receiver: default
  group_by: ["slo"]
  routes:
    - matchers: ['severity="page"']
      receiver: pagerduty
      group_wait: 30s
      repeat_interval: 1h
    - matchers: ['severity="ticket"']
      receiver: jira
      repeat_interval: 12h
receivers:
  - name: default
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "<key>"
  - name: jira
    webhook_configs:
      - url: "http://jira-bridge:8080/alert"
```

### 5.6 Trade-offs: cómo codificar SLOs en Prometheus

| Enfoque | Esfuerzo | Consistencia | Portabilidad | Nativo de K8s | Mejor para |
|---|---|---|---|---|---|
| Recording/alert rules escritas a mano | Alto, propenso a errores | Depende de la disciplina | Alta | No | Aprendizaje, SLOs puntuales |
| **Sloth** (spec → rules) | Bajo | Alta (MWMBR con plantillas) | Alta (reglas Prometheus planas) | CRD opcional | La mayoría de los shops de Prometheus |
| **Pyrra** (CRD + UI) | Bajo | Alta | Media (necesita operator) | Sí | Kubernetes / GitOps |
| **OpenSLO** + Nobl9/converters | Medio | Spec neutral de proveedor | Alta (multi-backend) | Varía | Organizaciones multi-tool / multi-cloud |

---

## 6. CLI y terminal — comandos y salidas reales

**Validar los archivos de reglas antes de cargarlos (nunca cargar reglas sin verificar):**
```console
$ promtool check rules slo-api-availability.rules.yml slo-api-availability.alerts.yml
Checking slo-api-availability.rules.yml
  SUCCESS: 9 rules found

Checking slo-api-availability.alerts.yml
  SUCCESS: 2 rules found
```

**Generar reglas desde la spec de Sloth:**
```console
$ sloth generate -i sloth-api.yml -o slo-api.rules.yml
INFO[0000] Generating from Prometheus format spec ...  version=v0.11.0
INFO[0000] SLI recording rules generated  rules=6 slo=api-requests-availability
INFO[0000] Metadata recording rules generated  rules=7 slo=api-requests-availability
INFO[0000] SLO alert rules generated  rules=2 slo=api-requests-availability
INFO[0000] Prometheus rules written  file=slo-api.rules.yml groups=6
```

**Consultar el ratio de error del SLI en vivo (HTTP API de Prometheus):**
```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:sli_error:ratio_rate1h{slo="api-availability"}' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "slo": "api-availability", "service": "api" },
        "value": [ 1754640000, "0.0213" ]
      }
    ]
  }
}
```
> `0.0213 > 0.0144` (el umbral de page de 14.4) → la condición de page de burn rápido se satisface en la ventana de 1h.

**Verificar si la alerta de page está disparándose:**
```console
$ curl -s 'http://localhost:9090/api/v1/alerts' \
    | jq '.data.alerts[] | {name: .labels.alertname, state, severity: .labels.severity}'
{
  "name": "ApiAvailabilityErrorBudgetBurnPage",
  "state": "firing",
  "severity": "page"
}
```

**Leer el error budget restante:**
```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:error_budget:remaining_ratio{slo="api-availability"}' \
    | jq -r '.data.result[0].value[1]'
0.37
```
> Queda el 37% del presupuesto de 30 días — política de release: proceder con cautela, sin migraciones riesgosas.

**Testear la lógica de la alerta con `promtool test rules` (blindar tu SLO contra regresiones):**
```yaml
# slo-tests.yml
rule_files:
  - slo-api-availability.rules.yml
  - slo-api-availability.alerts.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      # 5% of requests are 5xx for 90 minutes -> well above the 14.4 page threshold
      - series: 'http_requests_total{job="api", code="500"}'
        values: '0+5x90'
      - series: 'http_requests_total{job="api", code="200"}'
        values: '0+95x90'
    alert_rule_test:
      - eval_time: 70m
        alertname: ApiAvailabilityErrorBudgetBurnPage
        exp_alerts:
          - exp_labels:
              severity: page
              slo: api-availability
```
```console
$ promtool test rules slo-tests.yml
Unit Testing:  slo-tests.yml
  SUCCESS
```

**Aplicar el CRD de Pyrra y confirmar el PrometheusRule generado:**
```console
$ kubectl apply -f api-availability-slo.yaml
servicelevelobjective.pyrra.dev/api-availability created

$ kubectl get prometheusrule -n monitoring -l pyrra.dev/servicelevelobjective=api-availability
NAME               AGE
api-availability   12s
```

---

## 7. Verificación y diagnóstico de fallos

### 7.1 Escalera de verificación

1. **Estructura:** `promtool check rules ...` → cada archivo de reglas debe parsear y validar.
2. **Presencia:** confirmar que cada serie `slo:sli_error:ratio_rateXX` existe — `count(slo:sli_error:ratio_rate5m)` debe ser `≥ 1`.
3. **Cordura del ratio:** el ratio del SLI debe estar en `[0,1]`. `slo:sli_error:ratio_rate5m > 1 or slo:sli_error:ratio_rate5m < 0` debe devolver **vacío**.
4. **Lógica:** unit tests con `promtool test rules` — afirmar que el page se dispara bajo un burn rápido sintético y permanece en silencio bajo tráfico normal.
5. **End-to-end:** inyectar una ráfaga de 5xx sintética (o un experimento de caos) y confirmar que la alerta llega a PagerDuty y se limpia dentro del tiempo de reset de la ventana corta.

### 7.2 Catálogo de fallos

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| El ratio del SLI es `NaN` / con huecos | Sin tráfico → denominador `= 0` (`0/0`) | `sum(rate(http_requests_total[5m]))` no devuelve nada durante periodos tranquilos | Envolver con `... or vector(0)`, o usar un guard `clamp`/`OR on()`; considerar un SLI basado en ventanas para servicios de bajo tráfico |
| La alerta nunca se dispara durante una caída real | El SLI cuenta los eventos equivocados (ej. el LB devuelve 200 mientras el backend hace 5xx) | Comparar counters de error a nivel de app vs a nivel de edge | Medir el SLI **lo más cerca posible del usuario** (edge/LB), no en lo profundo de la app |
| La alerta oscila encendida/apagada | Usar `irate()` (últimas dos muestras) en vez de `rate()` | Graficar la recording rule — diente de sierra irregular | Usar `rate()` sobre la ventana de burn; la ventana corta de MWMBR ya maneja el reset |
| Recording rule obsoleta / no se actualiza | `interval` en el grupo de reglas más largo de lo esperado; sobrecarga en la evaluación de reglas | `count_over_time(slo:sli_error:ratio_rate5m[10m])` muy por debajo de lo esperado | Bajar el `interval` del grupo (o corregir la latencia de evaluación de reglas: `prometheus_rule_group_last_duration_seconds`) |
| Ratio erróneo tras un deploy | Reset de counter no manejado | El counter crudo cae a 0 al reiniciar | `rate()`/`increase()` ya manejan los resets — verificá que no hayas cambiado a `delta` crudo sobre un counter |
| Explosión de cardinalidad / OOM | Demasiados labels en las series del SLI (por-path, por-usuario) | `topk(10, count by (__name__)({__name__=~"slo:.*"}))` | Agregar (agregando fuera) los labels de alta cardinalidad en la recording rule |
| SLI de latency ~ p99 en vez de "% rápido" | Se usó `histogram_quantile` para el SLI | El valor parece segundos, no una fracción `[0,1]` | SLI = `bucket(le=T) / count`, no un cuantil |
| Presupuesto "restante" negativo | El ratio de error observado excedió el presupuesto | `slo:error_budget:remaining_ratio < 0` | Esperado — el presupuesto está agotado; congelar releases |

### 7.3 PromQL de diagnóstico

```promql
# ¿Se está produciendo la serie del SLI en absoluto?
count(slo:sli_error:ratio_rate5m{slo="api-availability"})

# Protegerse contra la división por cero (sin tráfico) que produce NaNs
(
  sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
  /
  sum(rate(http_requests_total{job="api"}[5m]))
) or vector(0)

# Burn rate actual como múltiplo del presupuesto (legible en un dashboard)
slo:sli_error:ratio_rate1h{slo="api-availability"} / 0.001

# Salud de evaluación del grupo de reglas (¿tus reglas de SLO van al día?)
prometheus_rule_group_last_duration_seconds
  > prometheus_rule_group_interval_seconds
```

---

## 8. Referencias

- CNCF PCA Curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- Google SRE Book, *Service Level Objectives* — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook, *Implementing SLOs* (error budgets, multi-window multi-burn-rate) — https://sre.google/workbook/implementing-slos/
- Google SRE Workbook, *Alerting on SLOs* — https://sre.google/workbook/alerting-on-slos/
- Prometheus — Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Querying / functions (`rate`, `histogram_quantile`) — https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/alerts`) — https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Unit testing rules (`promtool test rules`) — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Histograms and summaries — https://prometheus.io/docs/practices/histograms/
- Sloth — Prometheus SLO generator — https://sloth.dev/ · https://github.com/slok/sloth
- Pyrra — Kubernetes-native SLOs — https://github.com/pyrra-dev/pyrra
- OpenSLO — vendor-neutral SLO specification — https://openslo.com/ · https://github.com/OpenSLO/OpenSLO
- Alertmanager — configuration & routing — https://prometheus.io/docs/alerting/latest/configuration/