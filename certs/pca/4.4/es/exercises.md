# PCA 4.4 — Alerting Basics (When, What, and Why): Ejercicios Guiados

> **Objetivo.** Al finalizar estos labs vas a decidir *qué* merece una alerta (síntoma vs. causa), *cuándo* debería dispararse (`for`, staleness, burn rate multiventana) y *por qué* le importa al ingeniero de guardia (severidad, labels, annotations, ruteo). Todo se hace con la toolchain real — `prometheus`, `promtool`, `alertmanager`, `amtool` — y cada regla se verifica de forma determinista antes de siquiera tocar un target vivo.
>
> **Fuentes de referencia**
> - Alerting overview — https://prometheus.io/docs/alerting/latest/overview/
> - Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
> - Unit testing rules — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
> - Alertmanager configuration — https://prometheus.io/docs/alerting/latest/configuration/
> - Alerting philosophy (symptoms, not causes) — https://prometheus.io/docs/practices/alerting/
> - Google SRE: *Monitoring Distributed Systems* — https://sre.google/sre-book/monitoring-distributed-systems/
> - Google SRE Workbook: *Alerting on SLOs* — https://sre.google/workbook/alerting-on-slos/

## Prerrequisitos (configuración por única vez)

Necesitás los binarios `prometheus`, `promtool`, `alertmanager` y `amtool` (v2.50+ / v0.27+). `promtool` y `amtool` vienen dentro de los tarballs de release de Prometheus y Alertmanager respectivamente.

```bash
mkdir -p ~/pca-4.4 && cd ~/pca-4.4
prometheus --version    # expect: prometheus, version 2.5x.x ...
promtool --version
alertmanager --version
amtool --version
```

Creá un `prometheus.yml` mínimo que conecte Prometheus con Alertmanager y cargue un archivo de reglas. Vas a completar `api-alerts.yml` durante los ejercicios.

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "api-alerts.yml"
  - "slo-rules.yml"          # used in Exercise 5

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
```

---

## Ejercicio 1 — *Qué* alertar: síntoma vs. causa

La regla central del alerting (SRE book, cap. 6) es: **paginá a una persona solo por síntomas visibles para el usuario que requieran acción inmediata.** Las causas son para los dashboards y para la *description* de una alerta de síntoma, no para páginas propias.

1. Creá `api-alerts.yml` con dos reglas — una escrita de la forma *incorrecta* (basada en causa) y una de la forma *correcta* (basada en síntoma). Las mantenemos lado a lado para que puedas compararlas en la UI.

   ```yaml
   # api-alerts.yml
   groups:
     - name: api-availability
       rules:
         # ❌ CAUSE-BASED — pages on an internal detail that may be harmless
         - alert: ApiHighCpu
           expr: rate(process_cpu_seconds_total{job="api"}[5m]) > 0.9
           for: 5m
           labels:
             severity: critical
           annotations:
             summary: "API process CPU is high"

         # ✅ SYMPTOM-BASED — pages on user-visible failure
         - alert: ApiHighErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               /
             sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.05
           for: 10m
           labels:
             severity: critical
           annotations:
             summary: "API 5xx error ratio is {{ $value | humanizePercentage }} (SLO breach)"
             description: >-
               More than 5% of requests to {{ $labels.job }} are failing.
               Check saturation, upstream dependencies, and recent deploys.
   ```

2. Validá el archivo estáticamente *antes* de cargarlo. `promtool` parsea el YAML, compila cada expresión PromQL y rechaza el archivo si alguna regla está mal formada:

   ```bash
   promtool check rules api-alerts.yml
   ```
   Esperado:
   ```
   Checking api-alerts.yml
     SUCCESS: 2 rules found
   ```

3. Arrancá Prometheus y confirmá que las reglas se cargaron como un rule group:

   ```bash
   prometheus --config.file=prometheus.yml &
   curl -s http://localhost:9090/api/v1/rules \
     | jq '.data.groups[].rules[] | {name, type, state}'
   ```
   Esperado (ambas `inactive` porque todavía no falla nada):
   ```json
   { "name": "ApiHighCpu",      "type": "alerting", "state": "inactive" }
   { "name": "ApiHighErrorRate","type": "alerting", "state": "inactive" }
   ```

**Comprobá tu comprensión**

- **1a.** `ApiHighCpu` se dispara cada vez que el proceso está limitado por CPU durante 5 minutos. Dá una situación concreta donde esta alerta esté disparándose pero *nada esté mal para el usuario* — y explicá por qué paginar sobre esto causa alert fatigue.
- **1b.** ¿Por qué `ApiHighErrorRate` usa `sum by (job)(...) / sum by (job)(...)` en lugar de alertar sobre el conteo crudo `rate(http_requests_total{code=~"5.."}[5m]) > 10`?
- **1c.** La causa (CPU alta) sigue siendo útil. ¿Dónde debería vivir si no es en una página?

---

## Ejercicio 2 — *Cuándo* se dispara: la cláusula `for`, pending vs. firing, y unit tests

Una expresión de alerta que es verdadera durante una sola evaluación es ruido. La cláusula `for` requiere que la condición se mantenga continuamente antes de que la alerta transicione `pending → firing`. Vas a probar el timing de forma determinista con `promtool test rules` — sin necesitar un servicio vivo que falle.

1. Creá un archivo de unit-test que alimente series sintéticas a las reglas y afirme el estado de la alerta en momentos específicos. `0+60x30` significa "empezá en 0, sumá 60 cada minuto, 30 veces".

   ```yaml
   # api-alerts_test.yml
   rule_files:
     - api-alerts.yml

   evaluation_interval: 1m

   tests:
     - interval: 1m
       input_series:
         # 5xx grows by 60/min  -> rate = 1 req/s
         - series: 'http_requests_total{job="api", code="500"}'
           values: '0+60x30'
         # 2xx grows by 600/min -> rate = 10 req/s  => error ratio ≈ 9.1%
         - series: 'http_requests_total{job="api", code="200"}'
           values: '0+600x30'

       alert_rule_test:
         # At 12 min the ratio is already > 5% but `for: 10m` has NOT elapsed
         # (the 5m rate only becomes valid ~5m in), so the alert is still pending.
         - eval_time: 12m
           alertname: ApiHighErrorRate
           exp_alerts: []          # <-- no alerts firing yet

         # By 20 min the condition has held for >10m -> FIRING
         - eval_time: 20m
           alertname: ApiHighErrorRate
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: api
               exp_annotations:
                 summary: "API 5xx error ratio is 9.09% (SLO breach)"
                 description: >-
                   More than 5% of requests to api are failing.
                   Check saturation, upstream dependencies, and recent deploys.
   ```

2. Corré el test:

   ```bash
   promtool test rules api-alerts_test.yml
   ```
   Esperado:
   ```
   Unit Testing:  api-alerts_test.yml
     SUCCESS
   ```

3. Ahora **rompé el timing a propósito** para ver cómo la herramienta te protege. Editá el `eval_time: 12m` del primer bloque a `eval_time: 20m` pero mantené `exp_alerts: []`, luego volvé a correr. Fallo esperado:

   ```
   Unit Testing:  api-alerts_test.yml
     FAILED:
       alertname: ApiHighErrorRate, time: 20m0s,
         exp:[],
         got:[Labels:{alertname="ApiHighErrorRate", job="api", severity="critical"} ...]
   ```
   Restaurálo a `12m` y confirmá `SUCCESS` de nuevo.

**Comprobá tu comprensión**

- **2a.** Con `for: 10m`, ¿cuál es el retraso máximo entre que el usuario efectivamente ve errores y que la alerta llega a `firing`? ¿Por qué un `for` *más largo* no es automáticamente "más seguro"?
- **2b.** En el paso 1 la condición se cumple hacia los ~5 min, y sin embargo la alerta recién se dispara alrededor de los 15 min. Nombrá los dos retrasos independientes que se acumulan acá.
- **2c.** Un colega elimina `for:` por completo para "que le llegue la página más rápido". ¿Qué modo de falla (pista: una métrica que desaparece brevemente o un blip de un solo scrape) reintroduce esto?
- **2d.** ¿Por qué un unit test de `promtool` es una garantía más fuerte que abrir la UI de Prometheus y mirar el gráfico a ojo?

---

## Ejercicio 3 — *Por qué* importa: severidad, labels y annotations accionables

Los *labels* de una alerta deciden el ruteo y la identidad; sus *annotations* son la carga útil legible para humanos. Una buena alerta responde, sin necesidad de investigar nada: qué se rompió, cuán grave es y qué hacer a continuación.

1. Mejorá la alerta buena con una carga útil completa y accionable, y una `warning` compañera en un umbral más bajo. Reemplazá la regla `ApiHighErrorRate` con este par:

   ```yaml
         - alert: ApiHighErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               / sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.05
           for: 10m
           labels:
             severity: critical
             team: payments
           annotations:
             summary: "{{ $labels.job }} 5xx ratio {{ $value | humanizePercentage }} > 5%"
             description: "Fast error-budget burn on {{ $labels.job }}. Users are seeing failures now."
             runbook_url: "https://runbooks.example.com/api/HighErrorRate"
             dashboard_url: "https://grafana.example.com/d/api-overview"

         - alert: ApiElevatedErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               / sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.01
           for: 30m
           labels:
             severity: warning
             team: payments
           annotations:
             summary: "{{ $labels.job }} 5xx ratio {{ $value | humanizePercentage }} > 1%"
             runbook_url: "https://runbooks.example.com/api/HighErrorRate"
   ```

2. Revalidá y confirmá que ahora existen cuatro reglas:

   ```bash
   promtool check rules api-alerts.yml
   # Checking api-alerts.yml
   #   SUCCESS: 4 rules found  (ApiHighCpu, ApiHighErrorRate, ApiElevatedErrorRate, ...)
   ```

3. Verificá que el templating renderice correctamente agregando una aserción a `api-alerts_test.yml`. `humanizePercentage` convierte un ratio `0–1` en un string de porcentaje:

   ```yaml
         - eval_time: 20m
           alertname: ApiElevatedErrorRate
           exp_alerts:
             - exp_labels:
                 severity: warning
                 team: payments
                 job: api
               exp_annotations:
                 summary: "api 5xx ratio 9.09% > 1%"
                 runbook_url: "https://runbooks.example.com/api/HighErrorRate"
   ```
   Corré `promtool test rules api-alerts_test.yml` → `SUCCESS`.

**Comprobá tu comprensión**

- **3a.** ¿Cuáles de estos pertenecen a **labels** y cuáles a **annotations**, y por qué la distinción cambia el comportamiento del sistema (no solo la presentación)? `severity`, `runbook_url`, `team`, `summary`, `job`.
- **3b.** `humanizePercentage` espera `$value` en el rango 0–1. ¿Qué mostraría el `summary` si en su lugar templatearas el *conteo* crudo de errores, y por qué eso hace la alerta menos accionable?
- **3c.** ¿Por qué enviar una `warning` (1% durante 30m) y una `critical` (5% durante 10m) para el *mismo* síntoma en lugar de un solo umbral?
- **3d.** Una alerta con un `summary` perfecto pero sin `runbook_url` igual falla en una parte del "por qué". ¿Cuál parte, y quién paga el costo a las 3 de la mañana?

---

## Ejercicio 4 — *A dónde* va: ruteo, agrupamiento e inhibición en Alertmanager

Prometheus decide *si* dispararse; Alertmanager decide *a quién* se notifica, *cómo se agrupa* y *si* una alerta redundante se suprime. Esta es la diferencia entre "una alerta se disparó" y "la persona correcta recibió una notificación útil".

1. Creá `alertmanager.yml`. El árbol de rutas envía `critical` a un pager y `warning` a Slack; el agrupamiento colapsa una tormenta en una sola notificación; la regla de inhibición silencia la `warning` cuando su hermana `critical` ya está disparándose.

   ```yaml
   # alertmanager.yml
   route:
     receiver: default
     group_by: ['alertname', 'job']
     group_wait: 30s
     group_interval: 5m
     repeat_interval: 4h
     routes:
       - matchers: [ 'severity="critical"' ]
         receiver: pager
       - matchers: [ 'severity="warning"' ]
         receiver: slack

   inhibit_rules:
     - source_matchers: [ 'severity="critical"' ]
       target_matchers: [ 'severity="warning"' ]
       equal: ['alertname', 'job']

   receivers:
     - name: default
     - name: pager
       webhook_configs:
         - url: "http://127.0.0.1:5001/pager"
     - name: slack
       webhook_configs:
         - url: "http://127.0.0.1:5001/slack"
   ```

2. Validá la config estáticamente:

   ```bash
   amtool check-config alertmanager.yml
   ```
   Esperado:
   ```
   Checking 'alertmanager.yml'  SUCCESS
   Found:
    - global config
    - route
    - 1 inhibit rules
    - 3 receivers
    - 0 templates
   ```

3. **Probá el árbol de rutas sin enviar nada.** Preguntale a Alertmanager a qué receiver resuelve un labelset:

   ```bash
   amtool config routes test --config.file=alertmanager.yml severity=critical job=api
   # pager

   amtool config routes test --config.file=alertmanager.yml severity=warning job=api
   # slack

   amtool config routes test --config.file=alertmanager.yml severity=info job=api
   # default
   ```

4. Arrancá Alertmanager y leé de vuelta la config efectiva y cualquier silence activo:

   ```bash
   alertmanager --config.file=alertmanager.yml &
   amtool --alertmanager.url=http://localhost:9093 config show   | head
   amtool --alertmanager.url=http://localhost:9093 silence query   # (empty for now)
   ```

5. Creá un **silence** para una ventana de mantenimiento planificada (p. ej. un deploy), luego confirmálo, luego expirálo:

   ```bash
   amtool --alertmanager.url=http://localhost:9093 silence add \
     job=api --duration=1h --comment="deploy window" --author="$USER"
   # returns a silence ID, e.g. 2f1c...

   amtool --alertmanager.url=http://localhost:9093 silence query
   amtool --alertmanager.url=http://localhost:9093 silence expire <silence-id>
   ```

**Comprobá tu comprensión**

- **4a.** `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h` — decí en una oración qué controla cada timer, y cuál evita que una página no resuelta vuelva a notificar en cada evaluación.
- **4b.** La regla de inhibición tiene `equal: ['alertname','job']`. ¿Qué se rompe si eliminás `equal` por completo — es decir, inhibir `warning` cada vez que *cualquier* `critical` esté disparándose en cualquier lado?
- **4c.** Contrastá **inhibición** y un **silence**: cuál es automático-y-basado-en-relación, cuál es humano-y-acotado-en-el-tiempo, y cuándo recurrís a cada uno.
- **4d.** Con `group_by: ['alertname','job']`, cuarenta instancias de `ApiHighErrorRate{job="api"}` disparándose a la vez producen ¿cuántas notificaciones, y por qué ese es el punto?

---

## Ejercicio 5 — *Por qué ahora*: alerting de SLO multiventana y multi-burn-rate

Los umbrales estáticos ("5% durante 10m") paginan demasiado tarde para burns lentos y con demasiada ansiedad para picos breves. El enfoque del SRE Workbook alerta sobre el **burn rate del error budget**: cuán rápido estás consumiendo el presupuesto de un SLO del 99.9%. Una ventana corta *y* una larga deben coincidir, lo que hace la alerta a la vez rápida y resistente a picos.

Para un SLO del **99.9%** el ratio de error aceptable es `0.001`. Un burn-rate de `14.4×` durante 1h consume el 2% de un budget de 30 días — paginá. `6×` durante 6h consume el 5% — paginá. `1×` durante 3d consume el 10% — ticket.

1. Creá recording rules que precalculen el ratio de error en cada ventana que necesites (las recording rules mantienen las expresiones de alerta baratas y legibles):

   ```yaml
   # slo-rules.yml
   groups:
     - name: slo:http_error_ratio
       rules:
         - record: job:slo_errors:ratio_rate5m
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[5m]))
                 / sum by (job)(rate(http_requests_total[5m]))
         - record: job:slo_errors:ratio_rate1h
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[1h]))
                 / sum by (job)(rate(http_requests_total[1h]))
         - record: job:slo_errors:ratio_rate30m
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[30m]))
                 / sum by (job)(rate(http_requests_total[30m]))
         - record: job:slo_errors:ratio_rate6h
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[6h]))
                 / sum by (job)(rate(http_requests_total[6h]))
   ```

2. Agregá las alertas de burn-rate multiventana. Cada una se dispara solo cuando la ventana **larga** y la **corta** superan ambas el umbral de burn:

   ```yaml
     - name: slo:burn_rate
       rules:
         # Fast burn: 14.4x over 1h (2% of budget) — PAGE
         - alert: ErrorBudgetBurnFast
           expr: |
             job:slo_errors:ratio_rate1h  > (14.4 * 0.001)
               and
             job:slo_errors:ratio_rate5m  > (14.4 * 0.001)
           for: 2m
           labels: { severity: critical, long_window: 1h, short_window: 5m }
           annotations:
             summary: "Fast error-budget burn on {{ $labels.job }} ({{ $value | humanizePercentage }})"
             runbook_url: "https://runbooks.example.com/slo/burn"

         # Slow burn: 6x over 6h (5% of budget) — PAGE
         - alert: ErrorBudgetBurnSlow
           expr: |
             job:slo_errors:ratio_rate6h  > (6 * 0.001)
               and
             job:slo_errors:ratio_rate30m > (6 * 0.001)
           for: 15m
           labels: { severity: critical, long_window: 6h, short_window: 30m }
           annotations:
             summary: "Slow error-budget burn on {{ $labels.job }}"
             runbook_url: "https://runbooks.example.com/slo/burn"
   ```

3. Validá ambos archivos juntos:

   ```bash
   promtool check rules slo-rules.yml
   #   SUCCESS: 6 rules found
   ```

4. Confirmá la lógica de burn con un unit test. Acá el ratio de error se sitúa en ~2% (`0.02 > 0.0144`), así que el burn **fast** debería paginar, pero la alerta cruda de "5% durante 10m" del Ejercicio 3 permanecería en silencio — esa es la mejora:

   ```yaml
   # slo_test.yml
   rule_files: [ slo-rules.yml ]
   evaluation_interval: 1m
   tests:
     - interval: 1m
       input_series:
         - series: 'http_requests_total{job="api", code="500"}'
           values: '0+12x120'     # 12/min => rate 0.2/s
         - series: 'http_requests_total{job="api", code="200"}'
           values: '0+588x120'    # 588/min => rate 9.8/s  => ratio ≈ 2.0%
       alert_rule_test:
         - eval_time: 70m
           alertname: ErrorBudgetBurnFast
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: api
                 long_window: 1h
                 short_window: 5m
               exp_annotations:
                 summary: "Fast error-budget burn on api 2.04%"
                 runbook_url: "https://runbooks.example.com/slo/burn"
   ```
   ```bash
   promtool test rules slo_test.yml     # SUCCESS
   ```

**Comprobá tu comprensión**

- **5a.** ¿Por qué requerir *ambas* una ventana corta y una larga? Describí el mal resultado específico que obtenés de una alerta solo-de-ventana-larga, y el de una solo-de-ventana-corta.
- **5b.** ¿De dónde sale la constante `0.0144`, y qué cambiarías para pasar de un SLO del 99.9% a uno del 99.95%?
- **5c.** `ErrorBudgetBurnFast` es `critical`/página; la regla de `1×` durante 3d es `warning`/ticket. Atá esto de vuelta a la regla del Ejercicio 1: ¿por qué un burn lento *no* merece una página?
- **5d.** ¿Por qué calcular el ratio en **recording rules** primero en lugar de meter la expresión completa en línea en cada alerta?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1
- **1a.** Un pico de tráfico legítimo, un job batch/cron, o un warm-up JIT pueden clavar la CPU durante 5 minutos mientras cada request sigue devolviendo `200` rápidamente. Nada es visible para el usuario, y sin embargo se paginó al de guardia. Las páginas no accionables repetidas entrenan a los responders a ignorar la alerta — así que el incidente *real* también se ignora. Alertá sobre el síntoma (usuarios fallando), no sobre la causa (una CPU ocupada).
- **1b.** Un conteo crudo no tiene denominador: `>10` errores/s es catastrófico para un servicio que hace 20 req/s e irrelevante para uno que hace 50 000 req/s. El umbral necesitaría ajuste por servicio y derivaría a medida que el tráfico crece. Un **ratio** es independiente del tráfico y mapea directamente a un SLO ("5% de los requests fallan"). `sum by (job)` conserva el label `job` para que la alerta resultante sea identificable y ruteable.
- **1c.** En un dashboard, y dentro de la *description/annotation* de la alerta de síntoma como pista de debugging. Las causas informan el diagnóstico; no justifican una página propia. (SRE book, *Monitoring Distributed Systems*.)

### Ejercicio 2
- **2a.** Hasta `for` + un intervalo de evaluación (~10m15s acá) de falla visible para el usuario antes de disparar. Un `for` más largo no es automáticamente más seguro: cambia menos falsos positivos por un *time-to-detect* más largo, y para una caída total y rápida ese retraso es inaceptable. `for` se ajusta por alerta contra cuán rápido debe detectarse el síntoma.
- **2b.** (1) El `rate(...[5m])` necesita que su ventana se llene antes de reflejar el rate verdadero (~5m de rampa), y (2) la cláusula `for: 10m` requiere que la condición se mantenga continuamente *después* de eso. Los dos retrasos se acumulan.
- **2c.** Los blips de un solo scrape y los picos transitorios ahora paginan al instante (flapping). Peor aún, una métrica que se vuelve stale/ausente brevemente puede hacer que la expresión evalúe de forma extraña; `for` absorbe condiciones momentáneas y solo escala las sostenidas.
- **2d.** El unit test es determinista, versionado, y corre en CI en cada cambio — afirma el estado *exacto* (`pending`/`firing`) y las annotations renderizadas *exactas* en tiempos *exactos*. Mirar un gráfico a ojo es una comprobación única, no reproducible, que se pudre silenciosamente cuando alguien edita la regla más adelante.

### Ejercicio 3
- **3a.** **Labels:** `severity`, `team`, `job` — son parte de la identidad de la alerta e impulsan el ruteo, agrupamiento, inhibición y silences de Alertmanager (comportamiento del sistema). **Annotations:** `runbook_url`, `summary` — solo carga útil legible para humanos; cambiarlas nunca re-rutea una alerta. Poner `runbook_url` en un label contaminaría la clave de identidad/agrupamiento; poner `severity` en una annotation haría imposible el ruteo.
- **3b.** Mostraría algo como `9.09` interpretado como `909%` — porque `humanizePercentage` multiplica por 100 y espera un ratio 0–1, un conteo crudo produce un sinsentido. Más allá del formato, un conteo pelado no le dice al responder *cuán grave es relativo a lo normal*, así que no es accionable.
- **3c.** Distintas urgencias merecen distintas respuestas y canales: 1%-durante-30m es una degradación lenta que amerita un ticket de Slack en horario laboral; 5%-durante-10m es una caída activa que amerita una página. Un solo umbral o bien pagina por blips menores (fatiga) o bien se pierde los burns lentos (punto ciego).
- **3d.** La parte de "qué hago a continuación". Sin un runbook el responder improvisa bajo presión a las 3 de la mañana, aumentando el time-to-mitigate y el riesgo de error. La accionabilidad, no solo la detección, es el objetivo.

### Ejercicio 4
- **4a.** `group_wait` = cuánto retener la *primera* notificación de un grupo nuevo para que las alertas relacionadas se agrupen; `group_interval` = espera mínima antes de volver a notificar sobre *nuevas* alertas agregadas a un grupo existente; `repeat_interval` = con qué frecuencia *reenviar* un grupo sin cambios que sigue disparándose. `repeat_interval` es el que detiene la re-notificación por evaluación.
- **4b.** Sin `equal`, un único `critical` no relacionado (digamos una alerta de base de datos) inhibiría *todas* las `warning`s en cada servicio — suprimirías warnings que no tienen nada que ver con el critical disparado. `equal: ['alertname','job']` acota la inhibición al *mismo* síntoma en el *mismo* servicio, así que solo se silencia la hermana redundante.
- **4c.** La **inhibición** es automática y basada en relación: cuando una alerta más severa se dispara, su hermana de menor severidad se suprime por regla, indefinidamente, mientras la fuente siga disparándose. Un **silence** es iniciado por un humano y acotado en el tiempo: una persona silencia un labelset durante una ventana conocida (deploy, mantenimiento) y expira por sí solo. Usá inhibición para redundancia estructural; usá silences para decisiones humanas planificadas y temporales.
- **4d.** **Una** notificación — las cuarenta instancias colapsan en una sola notificación agrupada por clave `(alertname, job)`. Ese es el punto: el agrupamiento convierte una tormenta de alertas en un solo mensaje accionable en lugar de cuarenta páginas.

### Ejercicio 5
- **5a.** La **ventana larga** hace la alerta precisa y resistente a picos pero lenta para disparar. La **ventana corta** la hace rápida pero ruidosa. Solo-larga ⇒ detectás una caída real demasiado tarde (budget ya quemado). Solo-corta ⇒ un pico breve te pagina por algo que ya se recuperó. Requerir que ambas superen el umbral da rapidez *y* precisión: dispara rápido ante un burn sostenido, y la ventana corta además permite que la alerta *se resuelva* rápido una vez que el burn se detiene.
- **5b.** `0.0144 = 14.4 × 0.001`, donde `0.001 = 1 − 0.999` es el ratio de error permitido de un SLO del 99.9% y `14.4` es el factor de burn-rate que gasta el 2% de un budget de 30 días en 1h. Para un SLO del 99.95% cambiás el error budget base a `0.0005` (`1 − 0.9995`); los factores de burn-rate (14.4, 6, 1) quedan iguales, así que los umbrales pasan a ser `14.4 × 0.0005`, etc.
- **5c.** Un burn lento (`1×` durante días) sigue dentro de una ventana de respuesta que un ticket para el siguiente día hábil satisface — reflejando el Ejercicio 1: paginá solo por síntomas que necesiten acción humana *inmediata*. Paginar por algo que tenés días para arreglar es no-accionable-ahora y genera fatiga. Reservá las páginas para burns rápidos que amenazan el budget en cuestión de horas.
- **5d.** Las recording rules precalculan el ratio (costoso) una vez por ventana, así que cada alerta de burn-rate es una comparación barata contra una sola serie en lugar de reevaluar `sum(rate(...))` anidados sobre 6h/1h en cada evaluación. Además mantienen las expresiones de alerta legibles, reutilizables entre múltiples alertas/dashboards, y consistentes (una sola definición de "el ratio de error").

</details>