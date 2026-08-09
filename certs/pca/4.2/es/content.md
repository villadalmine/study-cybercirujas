# Tema 4.2 — Configuración de alerting rules

> Dominio 4 · Peso en el examen **4.5** · Perfil: SRE de producción / Arquitecto de plataforma
> Prometheus crea *alertas*; Alertmanager las *enruta*. Este tema trata sobre la primera mitad: convertir una expresión PromQL en una alerta con estado, deduplicada y bien etiquetada sobre la que el pipeline de notificaciones pueda actuar — y hacerlo de modo que sobreviva a recargas, reinicios, retraso de evaluación y flapping sin despertar a nadie a las 3 de la mañana por nada.

---

## 1. Motivación y el problema de arquitectura en producción

Una alerta es un *lazo de control sobre una serie temporal*. El modelo mental ingenuo — "cuando esta métrica cruza una línea, mandá un email" — esconde cuatro problemas difíciles con los que todo despliegue de Prometheus en producción termina topándose:

1. **Estado en un modelo de scrape sin estado.** Los scrapes de Prometheus son puntuales. Un cruce en el scrape *N* no significa nada por sí solo; un incidente real es un cruce *sostenido*. El motor de alertas tiene que mantener estado (`inactive → pending → firing`) entre evaluaciones, y mantenerlo correctamente a través de recargas de config y reinicios de proceso — si no, cada deploy rearma cada alerta y vuelve a paginar al on-call.

2. **Separación de la detección respecto del enrutamiento.** La detección (¿algo anda mal?) corresponde junto a los datos, en Prometheus, expresada en PromQL. El enrutamiento/dedup/silenciamiento (¿quién se entera, y con qué volumen?) corresponde a Alertmanager. Colapsar ambas en una sola capa es el error de arquitectura más común: acopla "qué está roto" con "quién está de guardia esta semana", y vuelve ambas cosas no testeables.

3. **Costo de evaluación vs. frescura.** Las reglas se ejecutan de forma síncrona dentro de un grupo de reglas en un intervalo fijo. Un grupo cuyas reglas tardan más en evaluarse que su `interval` se atrasa silenciosamente — `prometheus_rule_group_iterations_missed_total` sube, las alertas se disparan tarde, y nadie lo nota porque *la alerta sobre el alertado lento tampoco se dispara a tiempo*.

4. **La fatiga de alertas es una regresión de confiabilidad.** Una alerta que pagina sobre una *causa* ("el nodo tiene 90% de memoria") en lugar de un *síntoma* ("los usuarios reciben 500s") pagina constantemente y entrena al on-call para ignorar el pager. El modelo SRE de Google — paginar sobre síntomas que violan un SLO, ticketear sobre causas — tiene que estar *codificado en las expresiones de las reglas*, no dejado a la disciplina humana.

El entregable de este tema es un conjunto de **alerting rules** almacenadas en **rule files** (o CRDs `PrometheusRule` bajo el Operator), cargadas por Prometheus, evaluadas según una planificación y enviadas a Alertmanager por HTTP. Todo lo que sigue trata de escribir esas reglas para que sean correctas, testeables y operativamente aburridas.

### Dónde encajan las alerting rules en el pipeline

```
 scrape targets ──▶  Prometheus TSDB
                          │
                          ▼
                 ┌──────────────────────┐
                 │  Rule Manager        │   evaluate_interval / group interval
                 │  ┌────────────────┐  │
                 │  │ recording rules│  │   precompute expensive series
                 │  ├────────────────┤  │
                 │  │ alerting rules │  │   expr → pending → firing
                 │  └────────────────┘  │
                 └──────────┬───────────┘
                            │ active alerts (labels + annotations)
                            ▼
                 ┌──────────────────────┐
                 │  Notifier / queue    │   resend-delay, dropped, errors
                 └──────────┬───────────┘
                            │ HTTP POST /api/v2/alerts
                            ▼
                     Alertmanager  ──▶  dedup, group, inhibit, silence, notify
```

Prometheus nunca envía una "notificación". Envía un flujo de **objetos de alerta activos** (con `startsAt`/`endsAt`) a *cada* Alertmanager configurado, y sigue reenviando las alertas en firing según `resend-delay`. Alertmanager es responsable de convertir ese flujo en pages, tickets y mensajes de Slack. Mantener esta frontera nítida es lo que hace al sistema diagnosticable.

---

## 2. Anatomía de una alerting rule

Un rule file es un conjunto de **grupos**; cada grupo es una lista ordenada de **reglas**. Una regla es o bien una *recording rule* (`record:`) o una *alerting rule* (`alert:`). Nunca mezcles las dos claves en una misma regla.

```yaml
groups:
  - name: node-availability          # unique within the file
    interval: 30s                    # optional; overrides global evaluation_interval
    limit: 0                         # optional; cap on # of alerts/series (0 = unlimited)
    rules:
      - alert: InstanceDown          # the alertname label
        expr: up == 0                # PromQL; must return an instant vector
        for: 5m                      # sustain time before firing
        keep_firing_for: 2m          # keep firing after condition clears (v2.42+)
        labels:                      # merged/overwritten onto the result series labels
          severity: critical
          team: platform
        annotations:                 # informational only; templated; not part of identity
          summary: "Instance {{ $labels.instance }} of job {{ $labels.job }} is down"
          description: >-
            {{ $labels.instance }} of job {{ $labels.job }} has been unreachable
            for more than 5 minutes. Current value: {{ $value }}.
          runbook_url: https://runbooks.example.com/InstanceDown
```

### Semántica de campos que importa en producción

| Campo | Propósito | Trampa |
|---|---|---|
| `alert` | Establece la etiqueta `alertname`. | Debe ser único *conceptualmente*, no sintácticamente — dos reglas pueden compartir un nombre y producir alertas distintas si sus otras etiquetas difieren. |
| `expr` | PromQL de vector instantáneo. Cada serie devuelta se convierte en una instancia de alerta. | Si `expr` devuelve un *range vector* o un *scalar*, la regla da error. `> bool 0` devuelve un scalar → no funcionará; quitá el `bool`. |
| `for` | La condición debe mantenerse *de forma continua* durante esta duración antes de pasar a `firing`. Durante esa ventana la alerta está en `pending`. | Si una sola evaluación devuelve vacío, el temporizador se reinicia. Poné `for` ≥ 2–3× el intervalo de scrape para que un scrape perdido no lo reinicie. Omitir `for` dispara en la primera evaluación verdadera (ruidoso). |
| `keep_firing_for` | Mantiene la alerta en `firing` durante este tiempo *después* de que `expr` deja de devolverla. | Anti-flap para condiciones oscilantes. Distinto de `for` (que es amortiguación de entrada); `keep_firing_for` es amortiguación de salida. Requiere Prometheus **v2.42.0+**. |
| `labels` | Etiquetas estáticas/plantilladas que se fusionan sobre cada serie de resultado. Definen la **identidad** de la alerta (junto con las etiquetas de expr + `alertname`). | Cambiar una etiqueta crea una alerta *nueva* (reinicia `for`). Se permite el uso de plantillas, pero mantenelas deterministas; una etiqueta cuyo valor cambia constantemente fragmenta la alerta en muchas identidades. |
| `annotations` | Metadatos orientados a personas (summary, description, enlaces a dashboard/runbook). Plantillados. **No** forman parte de la identidad. | Se pueden cambiar libremente; las actualizaciones se propagan en el próximo reenvío sin reiniciar el estado. Poné acá cualquier cosa volátil (`$value`), nunca en `labels`. |

### El ciclo de vida de la alerta (máquina de estados)

```
             expr returns series                 for elapsed while true
  inactive ──────────────────────▶ pending ──────────────────────────▶ firing
     ▲                                │                                    │
     │      expr empty (timer reset)  │       expr empty                   │ expr empty
     └────────────────────────────────┘◀───────────────────────────────── │  AND keep_firing_for elapsed
                                                                           │
                                        (during keep_firing_for window, stays firing)
```

En cada evaluación, Prometheus materializa dos series sintéticas *por cada alerta activa*:

- `ALERTS{alertname="…", alertstate="pending"|"firing", <all alert labels>}` — valor `1` mientras está activa. **Podés consultarla y alertar sobre ella**, p. ej. contar cuántas alertas están en firing.
- `ALERTS_FOR_STATE{…}` — el valor es el timestamp Unix de cuando la alerta se activó por primera vez. Esto es lo que permite a Prometheus **restaurar el temporizador `for` tras un reinicio** en lugar de rearmarlo desde cero.

```promql
# How many critical alerts are firing per team right now?
count by (team) (ALERTS{severity="critical", alertstate="firing"})
```

---

## 3. Trade-offs comparativos

### 3.1 Recording rule vs. alerting rule para el umbral

Podés computar un ratio costoso en línea dentro del `expr` de la alerta, o precalcularlo con una recording rule y alertar sobre la serie registrada.

| Enfoque | Latencia | Reutilización | Testeabilidad | Costo | Cuándo |
|---|---|---|---|---|---|
| **Umbral en línea dentro de `expr`** | 1 evaluación | ninguna | se testea toda la regla de una vez | se recalcula en cada intervalo del grupo | Expresiones simples y baratas; un solo consumidor. |
| **Recording rule + alerta sobre ella** | +1 intervalo de grupo (regla → serie registrada → la alerta la lee en el ciclo siguiente) | dashboards + múltiples alertas reutilizan la serie | la serie registrada se testea de forma independiente | amortizado; el PromQL pesado se ejecuta una vez | Agregaciones costosas (`histogram_quantile`, `sum by` de alta cardinalidad), burn rates de SLO, cualquier cosa que también use un dashboard. |

**Regla general:** si una subexpresión aparece en más de una alerta *o* en un dashboard, promovela a una recording rule con una convención de nombres `level:metric:operation` (`job:http_requests:rate5m`). Esta es la mayor palanca sobre la CPU del motor de reglas.

### 3.2 `for` vs. `keep_firing_for`

| | `for` | `keep_firing_for` |
|---|---|---|
| Amortigua | Entrada (falsos positivos) | Salida (flapping) |
| Estado mientras está activa-pero-no-confirmada | `pending` | `firing` |
| Efecto sobre el paging | Retrasa el page | Extiende/mantiene abierto el page |
| Valor típico | 2–15 min (síntoma), más largo para causas | 1–5 min |
| Riesgo si es demasiado grande | Lento para detectar incidentes reales | Lento para autorresolver, pages obsoletos |

Usá ambos juntos para señales oscilantes (p. ej. un SLO de latencia que ronda el umbral): `for: 5m` para confirmar, `keep_firing_for: 5m` para que no se resuelva/re-dispare en cada scrape.

### 3.3 Alertado basado en síntomas vs. basado en causas

| | Síntoma (page) | Causa (ticket/inhibición) |
|---|---|---|
| Pregunta que responde | "¿Están afectados los usuarios?" | "¿Por qué podrían verse afectados pronto los usuarios?" |
| Ejemplo | `error ratio > SLO burn threshold` | `disk will fill in 4h` |
| Cardinalidad de los pages | Baja (uno por servicio de cara al usuario) | Alta si se paginan |
| Enrutamiento | `severity: critical` → page | `severity: warning` → ticket/dashboard |
| Recomendación SRE | Alertá acá | Ticket o usar como **fuente de inhibición** en Alertmanager |

### 3.4 Rule files estáticos vs. `PrometheusRule` CRD (Operator)

| | Rule files (`rule_files:`) | `PrometheusRule` CRD |
|---|---|---|
| Entrega | Archivos montados + reload | API de Kubernetes + reconciliación del operator |
| Selección | Ruta glob | Coincidencia de etiquetas `ruleSelector` en el CR `Prometheus` |
| Validación | `promtool check rules` en CI | admisión del operator + `promtool` |
| Multi-tenant | un conjunto de archivos por Prometheus | muchos CRDs entre namespaces, fusionados |
| Reload | `POST /-/reload` o SIGHUP | el operator escribe la config + dispara el reload automáticamente |
| Mejor para | VMs, Prometheus puro, control estricto | Kubernetes, GitOps, propiedad por equipo |

---

## 4. Manifiestos completos e infraestructura (sin abreviar)

### 4.1 Conectando reglas y Alertmanager en `prometheus.yml`

```yaml
# prometheus.yml — the parts relevant to alerting
global:
  scrape_interval: 15s
  evaluation_interval: 15s          # default cadence for rule groups without their own interval
  external_labels:                  # attached to every outbound alert; critical for HA dedup
    cluster: prod-eu-west-1
    replica: prometheus-0           # per-replica; Alertmanager dedups on the rest

# Where Prometheus finds alerting + recording rules. Globs are supported.
rule_files:
  - /etc/prometheus/rules/*.yml

# Optional: delay rule evaluation so late-arriving samples are already ingested.
rule_query_offset: 30s              # v2.53+ ; per-group override is `query_offset`

# How Prometheus reaches Alertmanager(s).
alerting:
  alert_relabel_configs:            # last chance to drop/rewrite labels before sending
    - source_labels: [severity]
      regex: debug
      action: drop
  alertmanagers:
    - api_version: v2               # /api/v2/alerts ; v1 is deprecated
      timeout: 10s
      scheme: http
      # Discover Alertmanager replicas dynamically in Kubernetes:
      kubernetes_sd_configs:
        - role: endpoints
          namespaces:
            names: [monitoring]
      relabel_configs:
        - source_labels:
            [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
          regex: alertmanager;web
          action: keep
```

Dos detalles críticos en producción:

- **`external_labels` + una etiqueta `replica` por réplica** es cómo se corre Prometheus en HA (dos réplicas idénticas alertando a la vez). Alertmanager deduplica sobre el conjunto de etiquetas idéntico *menos* `replica` — así que ambas réplicas paginando producen **un** page. Olvidate de la etiqueta `replica` y obtenés pages dobles; olvidate por completo de `external_labels` y Alertmanager no puede distinguir entre clusters.
- **Enviá a *todos* los Alertmanagers, no a uno balanceado por carga.** Prometheus reparte hacia cada Alertmanager descubierto; el propio cluster de Alertmanager usa gossip para deduplicar. Poner un único VIP delante anula el HA.

### 4.2 Un rule file de producción: burn-rate de SLO + infraestructura

Este archivo combina los patrones recomendados: recording rules alimentan alertas de SLO multi-ventana multi-burn-rate (síntoma, paginan), más una alerta de capacidad (causa, ticket) y una meta-alerta de automonitoreo.

```yaml
# /etc/prometheus/rules/checkout-slo.yml
groups:
  # ---- 1. Recording rules: precompute the request/error rates once ----
  - name: checkout.slo.recordings
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total{job="checkout"}[5m]))

      - record: job:http_requests:rate30m
        expr: sum by (job) (rate(http_requests_total{job="checkout"}[30m]))

      - record: job:http_requests:rate1h
        expr: sum by (job) (rate(http_requests_total{job="checkout"}[1h]))

      - record: job:http_requests:rate6h
        expr: sum by (job) (rate(http_requests_total{job="checkout"}[6h]))

      # error ratio over each window = errors / total
      - record: job:http_errors:ratio_rate5m
        expr: |
          sum by (job) (rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
            /
          sum by (job) (rate(http_requests_total{job="checkout"}[5m]))

      - record: job:http_errors:ratio_rate1h
        expr: |
          sum by (job) (rate(http_requests_total{job="checkout",code=~"5.."}[1h]))
            /
          sum by (job) (rate(http_requests_total{job="checkout"}[1h]))

      - record: job:http_errors:ratio_rate30m
        expr: |
          sum by (job) (rate(http_requests_total{job="checkout",code=~"5.."}[30m]))
            /
          sum by (job) (rate(http_requests_total{job="checkout"}[30m]))

      - record: job:http_errors:ratio_rate6h
        expr: |
          sum by (job) (rate(http_requests_total{job="checkout",code=~"5.."}[6h]))
            /
          sum by (job) (rate(http_requests_total{job="checkout"}[6h]))

  # ---- 2. Symptom alerts: multi-window multi-burn-rate for a 99.9% SLO ----
  # SLO = 99.9%  =>  error budget = 0.001 . Burn-rate thresholds per the SRE Workbook.
  - name: checkout.slo.alerts
    rules:
      # Fast burn: 2% of a 30-day budget in 1h. Long=1h, Short=5m, burn=14.4
      - alert: CheckoutErrorBudgetBurnFast
        expr: |
          job:http_errors:ratio_rate1h{job="checkout"}  > (14.4 * 0.001)
            and
          job:http_errors:ratio_rate5m{job="checkout"}  > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: checkout-availability
          long_window: 1h
          short_window: 5m
        annotations:
          summary: "Checkout is burning error budget 14.4x too fast"
          description: >-
            1h error ratio is {{ $value | humanizePercentage }} (budget 0.1%).
            At this rate the 30-day error budget is exhausted in ~2 days.
          runbook_url: https://runbooks.example.com/checkout/error-budget

      # Slow burn: 5% of budget in 6h. Long=6h, Short=30m, burn=6
      - alert: CheckoutErrorBudgetBurnSlow
        expr: |
          job:http_errors:ratio_rate6h{job="checkout"}   > (6 * 0.001)
            and
          job:http_errors:ratio_rate30m{job="checkout"}  > (6 * 0.001)
        for: 15m
        labels:
          severity: warning
          slo: checkout-availability
          long_window: 6h
          short_window: 30m
        annotations:
          summary: "Checkout is slowly burning its error budget (6x)"
          description: >-
            6h error ratio is {{ $value | humanizePercentage }}; sustained,
            this consumes the monthly budget by month-end.
          runbook_url: https://runbooks.example.com/checkout/error-budget

  # ---- 3. Cause alert: capacity prediction (ticket, used for inhibition) ----
  - name: infra.capacity
    interval: 1m
    rules:
      - alert: NodeFilesystemWillFill
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4*3600) < 0
            and
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.15
        for: 30m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} will fill within 4h"
          description: >-
            {{ $labels.device }} mounted at {{ $labels.mountpoint }} is at
            {{ with printf "node_filesystem_avail_bytes{instance='%s',mountpoint='%s'} / node_filesystem_size_bytes{instance='%s',mountpoint='%s'}" $labels.instance $labels.mountpoint $labels.instance $labels.mountpoint | query }}{{ . | first | value | humanizePercentage }}{{ end }} free
            and trending to full in under 4 hours.

  # ---- 4. Meta-alert: the alerting engine monitoring itself ----
  - name: prometheus.self
    rules:
      - alert: PrometheusRuleEvaluationFailing
        expr: increase(prometheus_rule_evaluation_failures_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Prometheus {{ $labels.instance }} is failing to evaluate rules"
          description: "{{ $value | humanize }} rule evaluation failures in the last 5m."

      - alert: PrometheusRuleGroupFallingBehind
        expr: |
          (prometheus_rule_group_last_duration_seconds
             / prometheus_rule_group_interval_seconds) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Rule group {{ $labels.rule_group }} evaluation is near its deadline"
          description: >-
            Group takes {{ $value | humanizePercentage }} of its interval to evaluate;
            iterations will start missing soon.

      - alert: PrometheusNotificationsDropped
        expr: increase(prometheus_notifications_dropped_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Prometheus is dropping alert notifications to Alertmanager"
          description: >-
            {{ $value | humanize }} notifications dropped in 5m — alerts may not be
            reaching Alertmanager. Check connectivity and queue capacity.
```

### 4.3 Las mismas alertas como un `PrometheusRule` CRD (Operator / Kubernetes)

El Prometheus Operator observa los objetos `PrometheusRule` cuyas etiquetas coinciden con el `ruleSelector` del CR `Prometheus`, los renderiza en la configuración y dispara un reload. Este es el camino de entrega nativo de CNCF.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-slo
  namespace: monitoring
  labels:
    # Must match .spec.ruleSelector on the Prometheus CR (below).
    prometheus: k8s
    role: alert-rules
spec:
  groups:
    - name: checkout.slo.alerts
      rules:
        - alert: CheckoutErrorBudgetBurnFast
          expr: |
            job:http_errors:ratio_rate1h{job="checkout"} > (14.4 * 0.001)
              and
            job:http_errors:ratio_rate5m{job="checkout"} > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            slo: checkout-availability
          annotations:
            summary: "Checkout is burning error budget 14.4x too fast"
            runbook_url: https://runbooks.example.com/checkout/error-budget
```

```yaml
# The Prometheus CR that selects the rule above.
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: k8s
  namespace: monitoring
spec:
  replicas: 2
  ruleSelector:
    matchLabels:
      role: alert-rules
      prometheus: k8s
  ruleNamespaceSelector: {}          # {} = all namespaces; tighten in multi-tenant clusters
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager-main
        port: web
        apiVersion: v2
  externalLabels:
    cluster: prod-eu-west-1
```

> El operator ejecuta una validación equivalente a `promtool` y rechaza un `PrometheusRule` malformado en la admisión — pero solo en cuanto a sintaxis. La corrección semántica (¿se dispara la alerta cuando debe?) sigue siendo tu trabajo mediante tests unitarios (§5.3).

### 4.4 Referencia de plantillas de annotations

Los annotations y los valores de etiqueta se renderizan con `text/template` de Go. Las variables y las funciones más útiles:

| Expresión | Produce |
|---|---|
| `{{ $labels.instance }}` | valor de la etiqueta `instance` en esta serie de alerta |
| `{{ $value }}` | el valor numérico de la muestra de la alerta |
| `{{ $externalLabels.cluster }}` | un valor de `external_labels` |
| `{{ $value | humanize }}` | formateo SI estilo `12.3k` |
| `{{ $value | humanizePercentage }}` | `0.0144` → `1.44%` |
| `{{ $value | humanizeDuration }}` | segundos → `3m 20s` |
| `{{ $labels.job | toUpper }}` | en mayúsculas |
| `{{ printf "%.2f" $value }}` | precisión fija |
| `{{ reReplaceAll ":.*" "" $labels.instance }}` | quita `:port` de `instance` |
| `{{ range query "up == 0" }}{{ .Labels.instance }} {{ end }}` | ejecuta una consulta PromQL en tiempo de render e itera |
| `{{ with query "..." }}{{ . | first | value }}{{ end }}` | búsqueda de un único valor |

Mantené las plantillas libres de efectos secundarios y baratas: se renderizan en **cada reenvío de notificación**, y un `query` dentro de una plantilla que se expande sobre alta cardinalidad puede dominar la latencia de notificación.

---

## 5. Comandos de CLI y salida real de terminal

### 5.1 Validar la sintaxis de las reglas antes de publicar (compuerta de CI)

```console
$ promtool check rules /etc/prometheus/rules/checkout-slo.yml
Checking /etc/prometheus/rules/checkout-slo.yml
  SUCCESS: 4 groups found
  SUCCESS: 14 rules found

$ echo $?
0
```

Una regla rota falla ruidosamente y con código distinto de cero (conectá esto a CI):

```console
$ promtool check rules bad.yml
Checking bad.yml
  FAILED:
group "checkout.slo.alerts", rule 1, "CheckoutErrorBudgetBurnFast": could not parse expression: 1:38: parse error: unexpected character: '&'

$ echo $?
1
```

### 5.2 Inspeccionar el estado en vivo de reglas y alertas

```console
$ curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | {name, interval, evaluationTime, lastEvaluation}'
{
  "name": "checkout.slo.recordings",
  "interval": 30,
  "evaluationTime": 0.0123,
  "lastEvaluation": "2026-08-09T12:04:30.001Z"
}
{
  "name": "checkout.slo.alerts",
  "interval": 15,
  "evaluationTime": 0.0041,
  "lastEvaluation": "2026-08-09T12:04:45.002Z"
}

# Only alerting rules, with health and current state:
$ curl -s http://localhost:9090/api/v1/rules?type=alert \
  | jq -r '.data.groups[].rules[] | "\(.name)\t\(.state)\t\(.health)\t\(.evaluationTime)s"'
CheckoutErrorBudgetBurnFast     firing     ok    0.0011s
CheckoutErrorBudgetBurnSlow     inactive   ok    0.0009s
NodeFilesystemWillFill          pending    ok    0.0031s
PrometheusRuleEvaluationFailing inactive   ok    0.0004s
```

```console
$ curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.state)\t\(.activeAt)"'
CheckoutErrorBudgetBurnFast     firing     2026-08-09T11:58:12Z
NodeFilesystemWillFill          pending    2026-08-09T12:01:40Z
```

Confirmá que Prometheus efectivamente sabe a dónde enviar las alertas:

```console
$ curl -s http://localhost:9090/api/v1/alertmanagers | jq
{
  "status": "success",
  "data": {
    "activeAlertmanagers": [
      { "url": "http://10.0.3.11:9093/api/v2/alerts" },
      { "url": "http://10.0.3.12:9093/api/v2/alerts" }
    ],
    "droppedAlertmanagers": []
  }
}
```

Una lista `activeAlertmanagers` vacía significa que las alertas se están calculando pero **no pueden salir de Prometheus** — la causa raíz más común de "¿por qué no me llegó el page?".

### 5.3 Testear unitariamente las alerting rules con `promtool test rules`

Así es como probás que una alerta se dispara *en el momento correcto* sin esperar a un incidente real. El archivo de test alimenta series de entrada sintéticas y verifica el estado de la alerta en tiempos de evaluación elegidos.

```yaml
# tests/checkout-slo_test.yml
rule_files:
  - ../rules/checkout-slo.yml

evaluation_interval: 1m

tests:
  # Scenario: 20% of requests are 5xx for 10 minutes -> fast burn must fire.
  - interval: 1m
    input_series:
      - series: 'http_requests_total{job="checkout", code="200"}'
        values: '0+800x15'          # 800/min ramp
      - series: 'http_requests_total{job="checkout", code="500"}'
        values: '0+200x15'          # 200/min ramp  => 20% error ratio

    # (a) verify the recorded ratio
    promql_expr_test:
      - expr: job:http_errors:ratio_rate5m{job="checkout"}
        eval_time: 10m
        exp_samples:
          - labels: 'job:http_errors:ratio_rate5m{job="checkout"}'
            value: 0.2

    # (b) verify the alert reaches firing and carries the right labels/annotations
    alert_rule_test:
      - eval_time: 10m
        alertname: CheckoutErrorBudgetBurnFast
        exp_alerts:
          - exp_labels:
              severity: critical
              slo: checkout-availability
              long_window: 1h
              short_window: 5m
            exp_annotations:
              summary: "Checkout is burning error budget 14.4x too fast"
              runbook_url: https://runbooks.example.com/checkout/error-budget

  # Scenario: zero errors -> the alert must NOT fire (regression guard).
  - interval: 1m
    input_series:
      - series: 'http_requests_total{job="checkout", code="200"}'
        values: '0+1000x15'
    alert_rule_test:
      - eval_time: 10m
        alertname: CheckoutErrorBudgetBurnFast
        exp_alerts: []              # empty = assert no alerts
```

```console
$ promtool test rules tests/checkout-slo_test.yml
Unit Testing:  tests/checkout-slo_test.yml
  SUCCESS

$ echo $?
0
```

Una aserción fallida muestra el diff exacto entre lo esperado y lo real — invaluable cuando alguien sube un umbral:

```console
$ promtool test rules tests/checkout-slo_test.yml
Unit Testing:  tests/checkout-slo_test.yml
  FAILED:
    alertname: CheckoutErrorBudgetBurnFast, time: 10m,
        exp:[
            0:
              Labels:{alertname="CheckoutErrorBudgetBurnFast", severity="critical", slo="checkout-availability", ...}
        ],
        got:[]

$ echo $?
1
```

`got:[]` significa que la alerta no se disparó cuando el test lo esperaba — normalmente un `for:` más largo que la ventana del test, o un umbral que ya no coincide con la entrada.

### 5.4 Hot-reload tras cambiar las reglas

```console
# Requires the flag --web.enable-lifecycle at startup.
$ curl -s -X POST http://localhost:9090/-/reload -o /dev/null -w '%{http_code}\n'
200

# Equivalent for a bare process:
$ kill -HUP $(pgrep -x prometheus)
```

```console
$ tail -f /var/log/prometheus.log
level=info ts=2026-08-09T12:10:02.114Z caller=main.go:1214 msg="Loading configuration file" filename=/etc/prometheus/prometheus.yml
level=info ts=2026-08-09T12:10:02.140Z caller=manager.go:951 component="rule manager" msg="Starting rule manager..."
level=info ts=2026-08-09T12:10:02.141Z caller=main.go:1251 msg="Completed loading of configuration file" totalDuration=27ms
```

Un reload con un rule file roto **mantiene corriendo la config anterior** y registra el error — no tira abajo Prometheus, así que siempre revisá el log / el estado HTTP de `/-/reload`, no solo "el proceso está arriba":

```console
$ curl -s -X POST http://localhost:9090/-/reload -w '%{http_code}\n'
failed to reload config: ... couldn't load rule file: ... parse error
400
```

---

## 6. Verificación y diagnóstico de fallos

Una checklist disciplinada, ordenada según dónde se rompen las alertas en la práctica.

### 6.1 La escalera de triaje de cuatro preguntas

| Síntoma | Primera pregunta | Comando / consulta | Causa probable |
|---|---|---|---|
| La alerta nunca se dispara | ¿La `expr` devuelve datos *ahora*? | Pegá la `expr` en `/graph` | Matchers de etiquetas incorrectos, un `bool` colándose, un resultado vacío reinicia `for`. |
| La alerta se dispara tarde | ¿El grupo de reglas se está atrasando? | `prometheus_rule_group_iterations_missed_total` > 0 | Evaluación del grupo más lenta que `interval`; dividí el grupo o precalculá. |
| La alerta se dispara pero no hay page | ¿Puede Prometheus alcanzar a Alertmanager? | `/api/v1/alertmanagers` → ¿`activeAlertmanagers` vacío? | SD/relabel mal, red, `api_version` incorrecta. |
| Tormenta de pages / flapping | ¿Están seteados `for`/`keep_firing_for`? ¿Identidad correcta? | Estados en la página `/rules`; cardinalidad de `ALERTS` | Sin amortiguación, o una etiqueta volátil en `labels:` fragmentando la identidad. |

### 6.2 Señales de salud del motor de reglas para scrapear y alertar

```promql
# Any rule erroring? (health goes "err" on the /rules page)
increase(prometheus_rule_evaluation_failures_total[5m]) > 0

# Group can't keep up with its interval — evaluations are being skipped:
increase(prometheus_rule_group_iterations_missed_total[10m]) > 0

# Group evaluation consuming most of its budget (early warning before misses):
prometheus_rule_group_last_duration_seconds
  / prometheus_rule_group_interval_seconds > 0.9

# Notifier problems (alerts computed but not delivered):
increase(prometheus_notifications_dropped_total[5m]) > 0
increase(prometheus_notifications_errors_total[5m]) > 0
prometheus_notifications_queue_length
  / prometheus_notifications_queue_capacity > 0.5
```

Que `prometheus_notifications_dropped_total` se incremente es una alarma de fallo silencioso: Prometheus está *descartando* alertas porque la cola hacia Alertmanager está llena o Alertmanager es inalcanzable. Nada más lo revela.

### 6.3 Supervivencia del estado `for` entre reinicios

Tras un reinicio, Prometheus **no** rearma cada alerta `pending`/`firing` desde cero — restaura el estado desde la serie `ALERTS_FOR_STATE`, acotado por tres flags:

| Flag | Por defecto | Significado |
|---|---|---|
| `--rules.alert.for-outage-tolerance` | `1h` | Downtime máximo para el cual el estado `for` todavía se restaura (más allá de esto, reinicia desde `pending`). |
| `--rules.alert.for-grace-period` | `10m` | Ventana `for` mínima impuesta tras la restauración, para que una alerta recién restaurada no se dispare al instante. |
| `--rules.alert.resend-delay` | `1m` | Con qué frecuencia se reenvían a Alertmanager las alertas en firing mientras están activas. |

Diagnóstico: si un rolling restart vuelve a paginar al on-call, verificá que (a) el downtime haya estado por debajo de `for-outage-tolerance`, y (b) `ALERTS_FOR_STATE` se esté reteniendo (vive en la TSDB como cualquier serie). En HA, la *segunda* réplica cubre sin fisuras, lo cual es otra razón para correr dos.

### 6.4 Fallos concretos comunes y su solución

1. **`expr` usa `> bool 0`.** Devuelve un scalar/vector `0|1` en lugar de filtrar — la regla "se dispara" constantemente (el valor `0` igual cuenta como una serie devuelta). **Solución:** quitá el `bool`; usá `up == 0`, no `up == bool 0`.
2. **`for` más corto que 2× el intervalo de scrape.** Un único scrape perdido vacía el resultado y reinicia el temporizador, así que la alerta nunca llega a `firing`. **Solución:** `for` ≥ `2–3 × scrape_interval`.
3. **Etiqueta volátil en `labels:` (p. ej. `{{ $value }}`).** Cada evaluación acuña una identidad de alerta *nueva* → `for` nunca acumula, y Alertmanager ve una tormenta de alertas de un solo disparo. **Solución:** los datos volátiles van solo en `annotations`.
4. **Una recording rule referenciada por una alerta vive en un grupo *posterior*.** La alerta lee una serie obsoleta/ausente en el primer ciclo. **Solución:** poné los productores antes que los consumidores; dentro de un grupo las reglas se ejecutan en orden, así que las recording rules deberían preceder a las alertas que las usan (o vivir en un grupo anterior).
5. **Desajuste de `ruleSelector` (Operator).** Las etiquetas de `PrometheusRule` no coinciden con el selector del CR `Prometheus` → las reglas se ignoran silenciosamente. **Solución:** verificá con `kubectl get prometheusrule -n monitoring --show-labels` y compará con `.spec.ruleSelector`.
6. **Doble paging en HA.** Ambas réplicas envían sin que Alertmanager *elimine* una etiqueta externa `replica` distintiva. **Solución:** `external_labels` idénticas salvo una etiqueta `replica`; asegurá que Alertmanager deduplique sobre el resto.

### 6.5 Smoke test de extremo a extremo

```console
# 1. Force an alert by scraping a target you then stop:
$ curl -s 'http://localhost:9090/api/v1/query?query=ALERTS{alertstate="firing"}' \
    | jq -r '.data.result[].metric.alertname' | sort -u
CheckoutErrorBudgetBurnFast

# 2. Confirm Alertmanager received it:
$ curl -s http://alertmanager:9093/api/v2/alerts \
    | jq -r '.[] | "\(.labels.alertname)\t\(.status.state)"'
CheckoutErrorBudgetBurnFast     active

# 3. Confirm delivery didn't error:
$ curl -s 'http://localhost:9090/api/v1/query?query=rate(prometheus_notifications_errors_total[5m])' \
    | jq -r '.data.result[].value[1]'
0
```

Si el paso 1 muestra la alerta en firing pero el paso 2 está vacío, la falla está entre Prometheus y Alertmanager (§6.1 fila 3). Si el paso 2 la muestra pero ningún humano fue notificado, la falla está dentro del enrutamiento/silences de Alertmanager — otro tema.

---

## Referencias

- Prometheus — *Alerting rules*: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — *Recording rules*: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — *Configuration (`rule_files`, `alerting`, `rule_query_offset`, `external_labels`)*: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — *Template reference (annotation/label templating)*: https://prometheus.io/docs/prometheus/latest/configuration/template_reference/
- Prometheus — *Template examples*: https://prometheus.io/docs/prometheus/latest/configuration/template_examples/
- Prometheus — *Unit Testing for Rules (`promtool test rules`)*: https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — *HTTP API (`/api/v1/rules`, `/api/v1/alerts`, `/api/v1/alertmanagers`)*: https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — *Management API / lifecycle (`/-/reload`)*: https://prometheus.io/docs/prometheus/latest/management_api/
- Prometheus — *Alerting overview & Alertmanager handoff*: https://prometheus.io/docs/alerting/latest/overview/
- Prometheus — *Feature/release notes for `keep_firing_for` (v2.42.0) and group `limit`/`query_offset`*: https://github.com/prometheus/prometheus/blob/main/CHANGELOG.md
- Google SRE Workbook — *Alerting on SLOs (multi-window, multi-burn-rate)*: https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — *Monitoring Distributed Systems (symptom vs. cause)*: https://sre.google/sre-book/monitoring-distributed-systems/
- Prometheus Operator — *`PrometheusRule` CRD & `ruleSelector`*: https://prometheus-operator.dev/docs/developer/alerting/
- Prometheus Operator — *API reference (`PrometheusRule`, `Prometheus.spec`)*: https://prometheus-operator.dev/docs/api-reference/api/
- CNCF — *PCA Curriculum*: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf