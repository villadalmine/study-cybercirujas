# 4.4 Fundamentos de alerting (cuándo, qué y por qué)

> **Dominio:** Alerting & Dashboarding · **Peso en el examen:** 4.5
> **Alcance:** la capa de decisión que convierte las series temporales en acción humana — la filosofía (*cuándo/qué/por qué*), la mecánica de las reglas de alerting en el servidor Prometheus, el traspaso a Alertmanager, y cómo demostrar que una regla se dispara exactamente cuando debe y nunca cuando no debe.

---

## 1. El problema de producción: de un gráfico al teléfono de una persona a las 03:00

Un dashboard es una interfaz de *pull* — alguien tiene que estar mirando. El alerting es la interfaz de *push*: el sistema decide que una persona debe mirar **ahora**. Todo el valor del subsistema se captura en una única tensión adversarial:

- **Perderse un problema real** (falso negativo) → una caída se consume sin ser detectada. Se viola el SLO, el cliente lo nota antes que vos.
- **Dispararse ante un no-problema** (falso positivo) → **fatiga de alertas**. Los ingenieros aprenden a ignorar el pager, el acknowledge-and-move-on se vuelve reflejo, y la *siguiente* alerta — la real — queda silenciada por hábito.

La fatiga de alertas no es un problema blando ni cultural; es el modo de fallo dominante del monitoreo de producción. Un pager que se dispara 40 veces por turno entrena a las personas a tratar el aviso #41 como ruido. Por eso el objetivo de ingeniería del alerting **no** es "detectar todo" — es **maximizar la relación señal-ruido del pager** manteniendo el recall lo suficientemente alto como para que los incidentes reales que afectan al usuario siempre se detecten.

Ese objetivo se descompone en las tres preguntas que dan nombre a este tema:

| Pregunta | Decide | Fallo si se equivoca |
|---|---|---|
| **Cuándo** alertamos? | La *condición de disparo* y la *duración* (`expr` + `for`) | Pages con flapping, o retraso en la detección |
| **Qué** alertamos? | La *señal* (síntoma vs causa) | Pages que no son accionables |
| **Por qué** alertamos? | La *severidad y el destino* (page vs ticket) | Alguien despertado por un problema no urgente |

### El camino de los datos del alerting

El alerting en Prometheus está deliberadamente dividido entre dos procesos. Esta separación es el hecho arquitectónico más importante del tema.

```
                    Prometheus server                         Alertmanager
   ┌──────────────────────────────────────────┐   ┌───────────────────────────────────┐
   │  scrape ─▶ TSDB ─▶ rule evaluation loop   │   │  dedup ─▶ group ─▶ inhibit ─▶      │
   │            (every evaluation_interval)    │   │  silence ─▶ route ─▶ throttle ─▶   │
   │                    │                      │   │  notify (Slack/PagerDuty/email)   │
   │        alert fires (pending→firing)       │   └───────────────────────────────────┘
   │                    │  HTTP POST                          ▲
   │                    └── /api/v2/alerts ──────────────────┘
   └──────────────────────────────────────────┘
```

- **El servidor Prometheus decide SI una alerta debe dispararse.** Evalúa las reglas de alerting contra su TSDB y empuja las alertas *firing* a Alertmanager. No tiene ningún concepto de a quién notificar ni con qué frecuencia.
- **Alertmanager decide QUÉ HACER con una alerta firing** — deduplicar a lo largo de réplicas Prometheus en HA, agrupar alertas relacionadas en una sola notificación, suprimir (inhibit/silence), enrutar al receiver correcto y regular las repeticiones.

Este tema (4.4) vive en el lado **izquierdo**: *cuándo/qué/por qué se dispara una alerta*. El enrutamiento, la agrupación y la notificación (configuración de Alertmanager) son el 4.5. Conocer el límite es examinable en sí mismo.

| Aspecto | Prometheus server | Alertmanager |
|---|---|---|
| Evaluar `expr` contra la TSDB | ✅ | ❌ |
| Mantener `pending` → `firing` vía `for` | ✅ | ❌ |
| Adjuntar `labels` / `annotations` | ✅ (regla) | ✅ (puede agregar vía routing) |
| Deduplicar alertas idénticas de pares en HA | ❌ | ✅ |
| Agrupar, silenciar, inhibir | ❌ | ✅ |
| Enrutar a receivers, regular `repeat_interval` | ❌ | ✅ |
| Enviar email/Slack/PagerDuty | ❌ | ✅ |

---

## 2. Cuándo: alerting basado en síntomas, no en causas

El texto fundacional es *"My Philosophy on Alerting"* de Rob Ewaschuk (la semilla del capítulo del libro SRE de Google *Monitoring Distributed Systems*). Su regla central:

> **Alertá sobre síntomas, no sobre causas.** Enviá un page a una persona solo por condiciones que sean *urgentes, accionables y visibles para (o que amenacen de forma inminente a) el usuario.*

Un **síntoma** es lo que el usuario experimenta: latencia alta, tasa de errores elevada, la página de checkout devolviendo 503. Una **causa** es una condición interna que *podría* producir un síntoma: un disco lleno, un pod reiniciándose, CPU alta, una elección de líder.

```
Cause-based (fragile):     "node-3 CPU > 90% for 5m"   → pages even if users are fine
Symptom-based (robust):    "checkout p99 latency > 1s" → pages only when it matters
```

Por qué el basado en síntomas gana en producción:

1. **Cobertura sin enumeración.** No podés enumerar todas las causas de una API lenta — mil fallos distintos producen el mismo síntoma. Una sola alerta de síntoma los captura a todos, incluidos los que nunca imaginaste.
2. **Menos pages falsos.** CPU al 95% con latencia nominal es *headroom siendo usado*, no un incidente. Una alerta de causa envía un page; una alerta de síntoma permanece callada.
3. **Accionabilidad.** "La latencia está alta" es un problema real y urgente que una persona debe arreglar. "La CPU está alta" puede estar perfectamente bien.

Las causas igual pertenecen al monitoreo — como **tickets/warnings** y como **contexto de dashboard/diagnóstico** que consultás *después* de un page por síntoma. La línea es: **los síntomas envían page (despiertan a una persona); las causas envían ticket (se investigan en horario laboral).**

### El catálogo de señales: qué síntomas

Tres frameworks canónicos te dicen *qué* medir. Son lentes complementarias, no competidoras.

| Framework | Señales | Mejor para | Fuente |
|---|---|---|---|
| **Four Golden Signals** | Latency, Traffic, Errors, Saturation | Servicios de cara al usuario (el default) | Google SRE |
| **RED** | Rate, Errors, Duration | Microservicios orientados a requests | Tom Wilkie / Weaveworks |
| **USE** | Utilization, Saturation, Errors | Recursos (CPU, disco, NIC, colas) | Brendan Gregg |

- **Golden Signals / RED** producen alertas de **síntoma** → dignas de page.
- **USE** produce mayormente señales de **recurso/causa** → dignas de ticket, siendo **Saturation** la que a menudo *predice* un síntoma y puede justificar un page (p. ej. "el disco se llenará en 4h").

**Regla general:** page sobre **Errors** y **Latency** (síntomas), ticket sobre **Saturation** (indicador anticipado), dashboard sobre **Traffic/Utilization** (contexto).

---

## 3. Por qué: la severidad es una decisión de enrutamiento, codificada como una label

La `severity` de una alerta no es decoración — es la label sobre la que Alertmanager enruta. Responde *por qué se lo estamos diciendo a una persona, y con qué urgencia.*

| Severidad | Significado | Acción humana | Destino | Presupuesto de latencia |
|---|---|---|---|---|
| `critical` / `page` | Visible al usuario o inminente; SLO en riesgo | Despertar a alguien **ahora** | PagerDuty / OpsGenie / teléfono | Minutos |
| `warning` / `ticket` | Real pero no urgente; degradación o indicador anticipado | Atender en horario laboral | Cola de tickets / canal de Slack | Horas–días |
| `info` | Contextual; nunca accionado por sí solo | Ninguna; solo dashboard/annotation | Suprimida o registrada | — |

El invariante **todo-page-es-accionable**: si una persona que recibe un `critical` no puede hacer algo al respecto *en este mismo momento*, no debería ser `critical`. Bajalo a `warning`, o borralo. La prueba más fuerte de una alerta a nivel page: *"Si esto se dispara y no hago nada, ¿un usuario sale lastimado pronto?"* Si no → no es un page.

---

## 4. Anatomía de una regla de alerting

Las reglas de alerting viven en los `rule_files` cargados por el servidor Prometheus (el *mismo* mecanismo de archivos que las recording rules; solo difiere la clave superior — `alert:` vs `record:`).

```yaml
# /etc/prometheus/rules/symptom_alerts.yml
groups:
  - name: symptom.rules
    # Optional: override the global evaluation_interval for this group.
    interval: 30s
    rules:
      - alert: HighErrorRate                       # the alert's identity (alertname)
        expr: |                                    # a PromQL vector; each returned series = one alert
          sum by (job, service) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job, service) (rate(http_requests_total[5m]))
            > 0.05
        for: 10m                                   # must stay true this long before FIRING
        keep_firing_for: 5m                        # stay firing this long after expr goes false (anti-flap)
        labels:                                    # merged onto the alert; used by Alertmanager routing
          severity: critical
          team: payments
        annotations:                               # human-readable; templated with the alert's labels/value
          summary: "High 5xx error rate on {{ $labels.service }}"
          description: >-
            {{ $labels.service }} (job {{ $labels.job }}) is serving
            {{ $value | humanizePercentage }} errors over the last 5m,
            above the 5% threshold, for more than 10m.
          runbook_url: "https://runbooks.internal/HighErrorRate"
          dashboard: "https://grafana.internal/d/svc/{{ $labels.service }}"
```

### Semántica de campos que se evalúa en el examen

- **`expr`** — cualquier expresión PromQL. **Cada serie que devuelve se convierte en una alerta**, identificada por la combinación de `alertname` + todos sus pares de labels. Una expresión que devuelve tres series → tres alertas distintas. Una expresión que no devuelve *nada* → la alerta está `inactive`.
- **`for`** — la alerta permanece `pending` mientras la expresión sea continuamente verdadera, y solo transiciona a `firing` después de que haya transcurrido `for`. Este es el control primario de de-flapping: filtra picos transitorios. Si la expresión se vuelve falsa en cualquier momento durante `for`, el temporizador se reinicia a cero.
- **`keep_firing_for`** (Prometheus ≥ 2.42) — el espejo de `for` en la *salida*. Mantiene la alerta `firing` durante este tiempo después de que la expresión deja de devolverla, evitando el flapping de resolve/refire rápido. Su valor por defecto es `0`.
- **`labels`** — labels estáticas fusionadas sobre la alerta. `severity` es la crítica (routing). Las labels son parte de la identidad de la alerta — cambiarlas crea una alerta *diferente*.
- **`annotations`** — nunca se usan para identidad ni routing; puramente informativas, con templating de Go. `{{ $value }}` es el valor numérico de la serie; `{{ $labels.X }}` sus labels. Un `runbook_url` acá es la diferencia entre un page accionable y un misterio.

### El ciclo de vida de la alerta (tres estados)

```
      expr returns series          for elapses while continuously true
inactive ───────────────▶ pending ────────────────────────────────▶ firing
    ▲                        │                                          │
    │  expr returns nothing  │  expr goes false (timer resets)          │ expr false
    └────────────────────────┴──────────────────────────────────────── + keep_firing_for elapsed
```

El timing está cuantizado por `evaluation_interval` (global, default 15s) o el `interval` del grupo. Con `evaluation_interval: 30s` y `for: 10m`, la alerta pasa a firing en la primera evaluación en/después de 10m de verdad continua — así que hasta un intervalo de retraso extra. **Un `for` más corto que `evaluation_interval` no tiene sentido** y es efectivamente inmediato.

### La métrica sintética `ALERTS`

Prometheus expone cada alerta pending/firing como una serie temporal *interna* que podés consultar y, algo crucial, **alertar sobre / graficar** como cualquier otra:

```
ALERTS{alertname="HighErrorRate", alertstate="firing", severity="critical", service="checkout"}  1
ALERTS_FOR_STATE{alertname="HighErrorRate", ...}  1.6912...e9   # unix ts the "for" started
```

- `ALERTS` tiene valor `1` mientras la alerta está `pending` o `firing` (distinguidas por la label `alertstate`). **No** existe para `inactive`.
- `ALERTS_FOR_STATE` registra cuándo comenzó el temporizador `for`. En un reinicio, Prometheus lo lee de vuelta (sujeto a `--rules.alert.for-outage-tolerance`, default 1h) para **restaurar** el progreso de `for` en lugar de reiniciar cada alerta a `pending` — así un reinicio del servidor no reinicia tus temporizadores de 10 minutos ni retrasa un page real.

---

## 5. Threshold vs burn-rate: cómo elegir el *cuándo*

La alerta ingenua — *"error ratio > 5% for 5m"* — tiene dos modos de fallo a la vez:

- **Demasiado sensible** → un blip de 90 segundos te envía un page.
- **Demasiado insensible** → una tasa de error lenta del 1% que *sí* está consumiendo silenciosamente tu SLO mensual nunca dispara un threshold estático.

La respuesta de producción es el **alerting por burn-rate de SLO / error-budget** (Google SRE Workbook, *Alerting on SLOs*). En lugar de un threshold de error fijo, alertás sobre **qué tan rápido estás consumiendo tu error budget** — normalizando la severidad al *tiempo-hasta-agotamiento*, no a un número instantáneo.

Para un SLO del **99.9% de éxito** durante 30 días, el **error budget** es `1 − 0.999 = 0.001` (0.1%). **Burn rate** = error ratio observado ÷ budget. Un burn rate de `1` agota el budget en exactamente 30 días; un burn rate de `14.4` lo agota en ~50 horas.

| Enfoque | Se dispara ante | Fortaleza | Debilidad |
|---|---|---|---|
| **Threshold estático** (`ratio > 0.05 for 5m`) | Nivel instantáneo | Simple, obvio | Ciego a burns lentos; threshold frágil; flapea |
| **Burn-rate único** (p. ej. `> 14.4× for 1h`) | Velocidad de consumo del budget | Alineado al SLO | Lento para detectar caídas enormes; o rápido-pero-ruidoso |
| **Multi-window multi-burn-rate** | Burn rápido confirmado por ventana corta + larga | Alta precisión **y** recall; rápido en fuegos grandes, paciente en los pequeños | Más reglas, necesita recording rules |

### La tabla multi-window, multi-burn-rate (SRE Workbook)

Cada severidad usa una **ventana larga** (precisión — ¿es esto sostenido?) Y una **ventana corta** (recall — ¿sigue ocurriendo ahora mismo?). La ventana corta evita que la alerta siga encendida mucho después de que el incidente termina.

| Severidad | Ventana larga | Ventana corta | Burn rate | Budget consumido para disparar | Tiempo de detección |
|---|---|---|---|---|---|
| **Page** | 1h | 5m | 14.4× | 2% | rápido |
| **Page** | 6h | 30m | 6× | 5% | medio |
| **Ticket** | 24h | 2h | 3× | 10% | lento |
| **Ticket** | 3d | 6h | 1× | 10% | el más lento |

**Leyendo la tabla:** un burn de `14.4×` durante 1h consume `14.4 × (1h / 720h) = 2%` de un budget de 30 días. Si tanto la ventana de 1h *como* la de 5m exceden `14.4 × 0.001`, page — la ventana larga dice "esto es sostenido", la ventana corta dice "todavía sigue". Una caída total de 45 minutos consume budget lo bastante rápido como para enviar un page en minutos; una tasa de error crónica del 0.15% nunca dispara un page pero eventualmente abre un ticket.

---

## 6. Manifiestos completos

### 6.1 Conectando el servidor Prometheus a Alertmanager y a sus archivos de reglas

```yaml
# /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s        # how often ALL rule groups are evaluated (unless overridden per-group)
  external_labels:
    cluster: prod-eu-west-1       # stamped onto every alert; lets Alertmanager dedup HA pairs by identity
    replica: A                    # differs per HA replica; Alertmanager strips it during dedup

# Where firing alerts are sent (this is the /api/v2/alerts push target).
alerting:
  alert_relabel_configs:          # optional: e.g. drop the 'replica' label so HA pairs dedup cleanly
    - source_labels: [replica]
      regex: .*
      action: labeldrop
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager-0.alertmanager:9093
            - alertmanager-1.alertmanager:9093
      # HA Alertmanager: Prometheus fans out to ALL AMs; the AM mesh dedups. Do NOT load-balance.
      timeout: 10s
      path_prefix: /

# Rule files: both recording AND alerting rules are loaded here (glob supported).
rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

### 6.2 Recording rules que alimentan las alertas de burn-rate

Las expresiones de burn-rate no deben recalcular `rate()` sobre seis ventanas en cada evaluación — eso es caro y está duplicado entre las reglas de page/ticket. Precalculá el ratio una vez por ventana con recording rules, y después alertá sobre las series grabadas, que son baratas.

```yaml
# /etc/prometheus/rules/slo_recording.yml
groups:
  - name: slo:http.recording
    interval: 30s
    rules:
      - record: job:slo_errors_per_request:ratio_rate5m
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
            /
          sum by (job) (rate(http_requests_total[5m]))
      - record: job:slo_errors_per_request:ratio_rate30m
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[30m]))
            /
          sum by (job) (rate(http_requests_total[30m]))
      - record: job:slo_errors_per_request:ratio_rate1h
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[1h]))
            /
          sum by (job) (rate(http_requests_total[1h]))
      - record: job:slo_errors_per_request:ratio_rate6h
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[6h]))
            /
          sum by (job) (rate(http_requests_total[6h]))
      - record: job:slo_errors_per_request:ratio_rate1d
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[1d]))
            /
          sum by (job) (rate(http_requests_total[1d]))
      - record: job:slo_errors_per_request:ratio_rate3d
        expr: |
          sum by (job) (rate(http_requests_total{code=~"5.."}[3d]))
            /
          sum by (job) (rate(http_requests_total[3d]))
```

### 6.3 Las reglas de alerting (síntoma + burn-rate)

```yaml
# /etc/prometheus/rules/slo_alerts.yml
groups:
  - name: slo:http.alerts
    rules:
      # ── Fast burn (2% budget in 1h) → PAGE ───────────────────────────────
      - alert: ErrorBudgetBurnFast
        expr: |
          job:slo_errors_per_request:ratio_rate1h{job="api"} > (14.4 * 0.001)
            and
          job:slo_errors_per_request:ratio_rate5m{job="api"} > (14.4 * 0.001)
        for: 2m
        labels:
          severity: critical
          slo: http-availability
        annotations:
          summary: "Fast error-budget burn on {{ $labels.job }} (14.4x)"
          description: >-
            {{ $labels.job }} is burning the 30-day error budget 14.4x faster
            than sustainable ({{ $value | humanizePercentage }} errors). At this
            rate the entire budget is gone in ~2 days.
          runbook_url: "https://runbooks.internal/ErrorBudgetBurn"

      # ── Medium burn (5% budget in 6h) → PAGE ─────────────────────────────
      - alert: ErrorBudgetBurnMedium
        expr: |
          job:slo_errors_per_request:ratio_rate6h{job="api"} > (6 * 0.001)
            and
          job:slo_errors_per_request:ratio_rate30m{job="api"} > (6 * 0.001)
        for: 15m
        labels:
          severity: critical
          slo: http-availability
        annotations:
          summary: "Sustained error-budget burn on {{ $labels.job }} (6x)"
          runbook_url: "https://runbooks.internal/ErrorBudgetBurn"

      # ── Slow burn (10% budget in 3d) → TICKET ────────────────────────────
      - alert: ErrorBudgetBurnSlow
        expr: |
          job:slo_errors_per_request:ratio_rate3d{job="api"} > (1 * 0.001)
            and
          job:slo_errors_per_request:ratio_rate6h{job="api"} > (1 * 0.001)
        for: 1h
        labels:
          severity: warning
          slo: http-availability
        annotations:
          summary: "Chronic error-budget burn on {{ $labels.job }} (1x)"
          runbook_url: "https://runbooks.internal/ErrorBudgetBurn"

  - name: infra.alerts
    rules:
      # ── Symptom-agnostic safety net: target actually scrapeable ──────────
      - alert: InstanceDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} of job {{ $labels.job }} is down"
          description: "Prometheus has failed to scrape {{ $labels.instance }} for 5m."

      # ── Leading indicator (Saturation) → TICKET, not page ────────────────
      - alert: DiskWillFillIn4Hours
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4*3600) < 0
            and
          node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.15
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.device }} on {{ $labels.instance }} will fill within 4h"
          description: >-
            Linear projection of the last 6h shows {{ $labels.mountpoint }} running
            out of space in under 4 hours; currently
            {{ $value | humanize }} bytes trend.
```

### 6.4 Lo mismo, como un CRD `PrometheusRule` de Prometheus Operator

En Kubernetes con el Prometheus Operator, **no** editás `prometheus.yml` a mano — creás objetos `PrometheusRule` y el operador los renderiza y recarga. Notá que el spec del CRD es *byte a byte idéntico* a un grupo de reglas nativo bajo `spec.groups`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: http-slo-alerts
  namespace: monitoring
  labels:
    # Must match the Prometheus CR's ruleSelector, or the rules are silently ignored.
    prometheus: k8s
    role: alert-rules
spec:
  groups:
    - name: slo:http.alerts
      rules:
        - alert: ErrorBudgetBurnFast
          expr: |
            job:slo_errors_per_request:ratio_rate1h{job="api"} > (14.4 * 0.001)
              and
            job:slo_errors_per_request:ratio_rate5m{job="api"} > (14.4 * 0.001)
          for: 2m
          labels:
            severity: critical
            slo: http-availability
          annotations:
            summary: "Fast error-budget burn on {{ $labels.job }} (14.4x)"
            runbook_url: "https://runbooks.internal/ErrorBudgetBurn"
```

---

## 7. Verificación y diagnóstico de fallos

Las reglas de alerting son código que corre a las 03:00 sin ninguna persona en el loop. Deben **testearse como código** — chequeadas estáticamente, testeadas unitariamente contra líneas de tiempo sintéticas, e inspeccionadas en vivo.

### 7.1 Chequeo estático — ¿siquiera parsea el YAML/PromQL?

```console
$ promtool check rules /etc/prometheus/rules/slo_alerts.yml
Checking /etc/prometheus/rules/slo_alerts.yml
  SUCCESS: 5 rules found
```

Una expresión rota falla ruidosamente, con la línea:

```console
$ promtool check rules /etc/prometheus/rules/broken.yml
Checking /etc/prometheus/rules/broken.yml
  FAILED:
/etc/prometheus/rules/broken.yml: group "slo:http.alerts", rule 1, "ErrorBudgetBurnFast":
  could not parse expression: 1:37: parse error: unexpected "and" in aggregation

1 rule(s) with errors detected
```

Conectá esto en CI para que una regla malformada nunca llegue a producción:

```console
$ find rules/ -name '*.yml' -print0 | xargs -0 promtool check rules
```

### 7.2 Test unitario — ¿se dispara en el momento *correcto*, con las labels *correctas*?

`promtool test rules` corre las reglas de alerting contra una serie temporal escrita a mano y verifica las alertas (y sus labels/annotations) en un instante dado. Esta es la herramienta más valiosa y más infrautilizada del tema.

```yaml
# tests/slo_alerts_test.yml
rule_files:
  - ../rules/slo_recording.yml
  - ../rules/slo_alerts.yml
evaluation_interval: 1m

tests:
  - interval: 1m
    input_series:
      # 6% of requests are 5xx for 30 minutes → well over the 14.4x page threshold.
      - series: 'http_requests_total{job="api", code="500"}'
        values: '0+6x30'          # start 0, +6 each minute, 30 samples
      - series: 'http_requests_total{job="api", code="200"}'
        values: '0+94x30'         # +94/min → 6/(6+94) = 6% error ratio
    alert_rule_test:
      - eval_time: 63m            # give the 1h window time to fill + the 2m "for"
        alertname: ErrorBudgetBurnFast
        exp_alerts:
          - exp_labels:
              severity: critical
              slo: http-availability
              job: api
            exp_annotations:
              summary: "Fast error-budget burn on api (14.4x)"
              runbook_url: "https://runbooks.internal/ErrorBudgetBurn"

  - interval: 1m
    input_series:
      - series: 'up{job="api", instance="10.0.0.5:8080"}'
        values: '1 1 1 0 0 0 0 0 0 0'    # up for 3m, then down
    alert_rule_test:
      - eval_time: 4m                     # only 1m down < for:5m → must NOT fire yet
        alertname: InstanceDown
        exp_alerts: []                    # asserting silence is as important as asserting a page
      - eval_time: 9m                     # 6m down > for:5m → must be firing
        alertname: InstanceDown
        exp_alerts:
          - exp_labels:
              severity: critical
              job: api
              instance: 10.0.0.5:8080
            exp_annotations:
              summary: "Target 10.0.0.5:8080 of job api is down"
              description: "Prometheus has failed to scrape 10.0.0.5:8080 for 5m."
```

Correlo:

```console
$ promtool test rules tests/slo_alerts_test.yml
Unit Testing:  tests/slo_alerts_test.yml
  SUCCESS
```

Una regresión — digamos que alguien afloja `for: 5m` a `for: 15m` — se captura de inmediato:

```console
$ promtool test rules tests/slo_alerts_test.yml
Unit Testing:  tests/slo_alerts_test.yml
  FAILED:
    alertname: InstanceDown, time: 9m0s,
        exp:[
            0:
              Labels:{alertname="InstanceDown", instance="10.0.0.5:8080", job="api", severity="critical"}
              ...
        ],
        got:[]

1 rules failed unit testing
```

### 7.3 Inspección en vivo — ¿qué está haciendo realmente el servidor ahora mismo?

**Carga y salud de las reglas vía la HTTP API:**

```console
$ curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | {name, state, health, lastError}'
{
  "name": "ErrorBudgetBurnFast",
  "state": "firing",
  "health": "ok",
  "lastError": ""
}
{
  "name": "InstanceDown",
  "state": "inactive",
  "health": "ok",
  "lastError": ""
}
```

**Alertas actualmente activas (pending/firing):**

```console
$ curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname:.labels.alertname, state, activeAt, value}'
{
  "alertname": "ErrorBudgetBurnFast",
  "state": "firing",
  "activeAt": "2026-08-09T06:12:41.113Z",
  "value": "6.0e-02"
}
```

**Consultá la métrica sintética `ALERTS`** — te permite graficar "cuántas alertas estuvieron pending vs firing a lo largo del tiempo", la meta-señal para afinar `for`:

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=ALERTS{alertstate="firing"}' | jq -r \
    '.data.result[] | "\(.metric.alertname)\t\(.metric.severity)\t\(.value[1])"'
ErrorBudgetBurnFast     critical        1
```

**Confirmá que la alerta realmente llegó a Alertmanager** (prueba la etapa de *push*, no solo el firing local):

```console
$ amtool alert query --alertmanager.url=http://localhost:9093
Alertname            Starts At                Summary                                        State
ErrorBudgetBurnFast  2026-08-09 06:12:41 UTC  Fast error-budget burn on api (14.4x)          active
```

### 7.4 Recargar reglas sin un reinicio

Editar un archivo de reglas **no** lo recarga en caliente. Dispará un reload (requiere `--web.enable-lifecycle`):

```console
$ curl -sf -X POST http://localhost:9090/-/reload && echo "reloaded"
reloaded
# In Kubernetes with the Operator, config-reloader sidecars do this automatically on ConfigMap change.
```

### 7.5 Matriz de diagnóstico de modos de fallo

| Síntoma | Causa probable | Cómo confirmar | Solución |
|---|---|---|---|
| Cambio de regla ignorado | Archivo no recargado | `GET /api/v1/rules` sigue mostrando la expr vieja | `POST /-/reload` o reiniciar; verificar `--web.enable-lifecycle` |
| Alerta atascada en `pending`, nunca `firing` | `for` más largo que lo que persiste la condición, o `evaluation_interval` demasiado grueso | Graficar `ALERTS{alertstate="pending"}`; comparar `activeAt` con ahora | Acortar `for`, o verificar que el pico subyacente sea genuinamente breve |
| La alerta nunca aparece | `expr` devuelve un vector vacío | Correr la `expr` en la UI de query — 0 series = inactive | Corregir los matchers de labels / nombre de métrica; verificar que la métrica exista |
| Regla con `health: "err"` | Error de runtime de PromQL (p. ej. match many-to-many) | `GET /api/v1/rules` → `lastError` | Agregar agrupación `on()/ignoring()`; validar con `promtool check rules` |
| Se dispara localmente pero no hay notificación | Etapa de push a Alertmanager rota | `up{job="alertmanager"}`, `prometheus_notifications_dropped_total`, `amtool alert query` | Corregir el target de `alerting.alertmanagers` / la network policy |
| Pages duplicados desde Prometheus en HA | Label `replica` no eliminada antes del envío | Dos alertas que difieren solo por `replica` en Alertmanager | `alert_relabel_configs` labeldrop `replica`; setear `external_labels` distintas |
| Flapping de resolve/refire | La condición oscila alrededor del threshold | Observar `ALERTS` alternando 1→0→1 | Agregar `keep_firing_for`; ampliar `for`; histéresis en `expr` |
| La alerta vuelve a enviar page tras reiniciar Prometheus | Estado de `for` no restaurado | Reinicio correlacionado con el page; hueco > `for-outage-tolerance` | Asegurar la persistencia de la TSDB; `--rules.alert.for-outage-tolerance` (default 1h) cubre el hueco |
| Las notificaciones se repiten demasiado rápido/lento | `repeat_interval` de Alertmanager, no un problema de la regla | `amtool config routes show` | Afinar en Alertmanager (tema 4.5), no en la regla |

**Flags del servidor relevantes para los casos borde de timing de arriba:**

| Flag | Default | Efecto |
|---|---|---|
| `--rules.alert.for-outage-tolerance` | `1h` | Máximo tiempo de caída de Prometheus para el cual el progreso de `for` se restaura en el reinicio (vía `ALERTS_FOR_STATE`) |
| `--rules.alert.for-grace-period` | `10m` | Duración mínima de `for` para la cual aplica la restauración; las alertas con `for` corto siempre se re-evalúan desde cero |
| `--rules.alert.resend-delay` | `1m` | Con qué frecuencia el servidor *reenvía* una alerta aún en firing a Alertmanager (la mantiene viva frente al `resolve_timeout` de Alertmanager) |

---

## 8. Checklist de diseño (el modelo mental del examen)

Antes de que una regla se despliegue, debería pasar cada línea:

1. **Qué** — ¿mide un **síntoma** (page) o una **causa** (ticket)? ¿Es la label de severidad correcta para esa respuesta?
2. **Cuándo** — ¿es `for` lo suficientemente largo para filtrar transitorios pero lo suficientemente corto para detectar incidentes reales? ¿Capturaría una formulación de burn-rate las degradaciones lentas que un threshold estático se pierde?
3. **Por qué** — si esto se dispara y el on-call no hace nada, ¿un usuario sale lastimado? Si no, no es `critical`.
4. **Accionable** — ¿lleva la annotation un `runbook_url` y suficiente contexto para actuar sin tener que hurgar?
5. **Probada** — ¿hay un caso de `promtool test rules` que verifique tanto que se dispara cuando debe *como que permanece en silencio cuando no debe*?
6. **Alcanzable** — ¿está el archivo de reglas en `rule_files`/emparejado por `ruleSelector`, cargado (`/api/v1/rules`), y está sana la etapa de push a Alertmanager?

---

## Referencias

- Prometheus — Alerting rules (definition, `for`, `keep_firing_for`, `ALERTS`): https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Alerting overview (server ↔ Alertmanager split): https://prometheus.io/docs/alerting/latest/overview/
- Prometheus — Best practices, *Alerting* (symptom-based philosophy): https://prometheus.io/docs/practices/alerting/
- Prometheus — Recording rules (feeding burn-rate ratios): https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Unit testing rules (`promtool test rules`): https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Configuration, `alerting`/`rule_files` blocks: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — HTTP API (`/api/v1/rules`, `/api/v1/alerts`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Server feature flags & CLI (`--rules.alert.*`): https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- Alertmanager — Overview and `amtool`: https://prometheus.io/docs/alerting/latest/alertmanager/
- Google SRE Book — *Monitoring Distributed Systems* (Four Golden Signals, symptom-based alerting): https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Workbook — *Alerting on SLOs* (multi-window, multi-burn-rate): https://sre.google/workbook/alerting-on-slos/
- Rob Ewaschuk — *My Philosophy on Alerting*: https://docs.google.com/document/d/199PqyG3UsyXlwieHaqbGiWVa8eMWi8zzAn0YfcApr8Q/edit
- Prometheus Operator — `PrometheusRule` CRD: https://prometheus-operator.dev/docs/developer/alerting/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf