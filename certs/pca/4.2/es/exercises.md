# Ejercicios — Tema 4.2: Configuración de reglas de alerta (PCA)

> Prometheus por sí mismo solo *decide cuándo una alerta está firing*; la notificación real (email, Slack, PagerDuty) es trabajo de Alertmanager. Este tema trata sobre la primera mitad: escribir, validar, testear y recargar **reglas de alerta** dentro de Prometheus, y entender el ciclo de vida `inactive → pending → firing`. Mantené presente esa frontera — la mayoría de las trampas del examen viven exactamente sobre ella.
>
> Material de referencia usado a lo largo del tema:
> - Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
> - Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
> - Template reference — https://prometheus.io/docs/prometheus/latest/configuration/template_reference/
> - Unit testing rules — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
> - Alertmanager wiring — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
> - PCA curriculum — https://github.com/cncf/curriculum

---

## Preparación del laboratorio (hacé esto una sola vez)

Necesitás los binarios `prometheus` y `promtool` (ambos vienen en el mismo tarball) y, opcionalmente, `node_exporter`. Todo lo de abajo se ejecuta desde un único directorio.

```
pca-alerting-lab/
├── prometheus.yml
├── rules/
│   └── node-alerts.yml
└── tests/
    └── node-alerts_test.yml
```

**Pasos**

1. Creá el directorio del laboratorio y entrá en él:

   ```bash
   mkdir -p pca-alerting-lab/rules pca-alerting-lab/tests
   cd pca-alerting-lab
   ```

2. Escribí `prometheus.yml`. Fijate en las tres secciones que importan para este tema: `evaluation_interval`, `rule_files` y `alerting`.

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s      # how often rule groups are evaluated by default
     external_labels:
       cluster: pca-lab
       region: local

   rule_files:
     - "rules/*.yml"               # glob is resolved relative to this file

   alerting:
     alertmanagers:
       - static_configs:
           - targets:
               - "localhost:9093"  # where firing alerts are pushed (may be down; fine for now)

   scrape_configs:
     - job_name: "prometheus"
       static_configs:
         - targets: ["localhost:9090"]
     - job_name: "node"
       static_configs:
         - targets: ["localhost:9100"]   # we will NOT start node_exporter, on purpose
   ```

3. Creá un archivo de reglas vacío para que Prometheus arranque de forma limpia:

   ```bash
   printf 'groups: []\n' > rules/node-alerts.yml
   ```

4. Iniciá Prometheus con la API de lifecycle habilitada (la vas a necesitar para hacer hot-reload de reglas más adelante):

   ```bash
   prometheus \
     --config.file=prometheus.yml \
     --web.enable-lifecycle
   ```

5. En una segunda terminal, confirmá que la config se cargó y que todavía no existe ninguna regla:

   ```bash
   curl -s http://localhost:9090/api/v1/rules | jq '.data.groups | length'
   ```

   Salida esperada:

   ```
   0
   ```

**Verificá tu comprensión**

- **Q1.** ¿Cuáles son las dos claves de configuración estrictamente necesarias para que una regla de alerta llegue a ser *evaluada* y para que su estado firing llegue a *salir* de Prometheus? Nombrá la sección del archivo para cada una.
- **Q2.** A propósito no iniciamos `node_exporter`. Predecí a qué será igual la métrica `up{job="node"}`, y por qué eso resulta útil para el próximo ejercicio.
- **Q3.** `--web.enable-lifecycle` está desactivado por defecto. ¿Qué riesgo operativo introduce habilitarlo, y cómo se mitiga habitualmente en producción?

---

## Ejercicio 1 — Tu primera regla de alerta y el ciclo de vida pending → firing

**Objetivo:** cablear una regla real, verla moverse a través de los tres estados, y entender la cláusula `for`.

**Pasos**

1. Reemplazá `rules/node-alerts.yml` con dos reglas — una que se dispara inmediatamente cuando un target está caído, y otra regla sintética construida puramente para observar el ciclo de vida:

   ```yaml
   # rules/node-alerts.yml
   groups:
     - name: node.rules
       rules:
         - alert: TargetDown
           expr: up{job="node"} == 0
           for: 1m
           labels:
             severity: critical
           annotations:
             summary: "Target {{ $labels.instance }} (job {{ $labels.job }}) is down"
             description: "{{ $labels.instance }} has failed scraping for more than 1 minute."

         - alert: LifecycleDemo
           expr: vector(1)          # always returns one series with value 1 -> always active
           for: 2m
           labels:
             severity: none
           annotations:
             summary: "Demo alert used to watch inactive -> pending -> firing"
   ```

2. Hacé hot-reload de Prometheus (no hace falta reiniciar):

   ```bash
   curl -s -X POST http://localhost:9090/-/reload && echo reloaded
   ```

   Salida esperada:

   ```
   reloaded
   ```

3. Consultá inmediatamente el estado de la alerta. Hacelo **dos veces**, con ~30 s de diferencia, y luego otra vez después de 2–3 minutos:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.state)\t\(.activeAt)"'
   ```

   Progresión esperada (primera llamada, segundos después del reload):

   ```
   TargetDown       pending    2026-08-09T14:03:11.402Z
   LifecycleDemo    pending    2026-08-09T14:03:11.402Z
   ```

   Después de ~1 minuto:

   ```
   TargetDown       firing     2026-08-09T14:03:11.402Z
   LifecycleDemo    pending    2026-08-09T14:03:11.402Z
   ```

   Después de ~2 minutos:

   ```
   TargetDown       firing     2026-08-09T14:03:11.402Z
   LifecycleDemo    firing     2026-08-09T14:03:11.402Z
   ```

4. Mirá el mismo ciclo de vida a través de la métrica sintética `ALERTS` que Prometheus escribe para cada alerta activa. En el navegador de expresiones (`http://localhost:9090/graph`) ejecutá:

   ```promql
   ALERTS{alertname="TargetDown"}
   ```

   Resultado de instant-vector esperado una vez en firing:

   ```
   ALERTS{alertname="TargetDown", alertstate="firing", instance="localhost:9100", job="node", severity="critical"}   1
   ```

**Verificá tu comprensión**

- **Q4.** `TargetDown` tiene `for: 1m` y `LifecycleDemo` tiene `for: 2m`, sin embargo ambos pasaron a `pending` en el *mismo* timestamp `activeAt`. Explicá con precisión qué marca `activeAt` y por qué `for` controla la *transición a firing*, no la transición a pending.
- **Q5.** Durante la ventana pending, ¿Prometheus envía algo a Alertmanager? ¿Y durante firing?
- **Q6.** La serie `ALERTS` lleva una label `alertstate`. ¿Cuáles son sus valores posibles, y una consulta por `ALERTS{alertstate="inactive"}` devolvería datos alguna vez? ¿Por qué sí o por qué no?
- **Q7.** Si ponés `for: 0` (u omitís `for` por completo), ¿cómo cambia el ciclo de vida?

---

## Ejercicio 2 — Validá antes de publicar: `promtool check rules`

**Objetivo:** detectar reglas rotas en el momento de escribirlas, offline, con costo cero — esta es la mentalidad del "quality floor before writing".

**Pasos**

1. Ejecutá el linter contra tu archivo de reglas:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Salida esperada:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   ```

2. Ahora rompé el archivo deliberadamente para aprender los modos de falla. Introducí un **error de sintaxis PromQL** quitando el `==`:

   ```yaml
           expr: up{job="node"} 0
   ```

   Volvé a ejecutar:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Salida esperada (código de salida distinto de cero):

   ```
   Checking rules/node-alerts.yml
     FAILED:
   rules/node-alerts.yml: could not parse expression: 1:20: parse error: unexpected number "0"
   ```

3. Corregí eso, luego introducí un **error estructural**: renombrá `alert:` a `name:` en la primera regla. Volvé a ejecutar `promtool check rules`. Salida esperada:

   ```
   Checking rules/node-alerts.yml
     FAILED:
   rules/node-alerts.yml: yaml: unmarshal errors:
     line 4: field name not found in type rulefmt.RuleNode
   ```

4. Dejalo de nuevo como un archivo válido y confirmá `SUCCESS` otra vez. Después chequeá el código de salida explícitamente (esto es en lo que se apoya CI):

   ```bash
   promtool check rules rules/node-alerts.yml; echo "exit=$?"
   ```

   Salida esperada:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   exit=0
   ```

**Verificá tu comprensión**

- **Q8.** `promtool check rules` valida dos cosas distintas sobre cada regla. ¿Cuáles son, y qué *no* verifica?
- **Q9.** ¿Por qué un código de salida distinto de cero es la propiedad que realmente importa para un pre-commit hook o un CI gate, más que el texto legible por humanos?
- **Q10.** También podés ejecutar `promtool check config prometheus.yml`. ¿En qué difiere en alcance respecto de `promtool check rules`, y cuál cubre transitivamente al otro?

---

## Ejercicio 3 — Templating de labels y annotations

**Objetivo:** producir alertas sobre las que un humano pueda actuar — con el valor ofensor, la instance y las unidades humanizadas interpoladas.

**Pasos**

1. Agregá una alerta de uso de recursos que use templating intensivamente. Añadí esta regla al grupo `node.rules`:

   ```yaml
         - alert: NodeHighMemory
           expr: |
             100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 85
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "High memory on {{ $labels.instance }}"
             description: >-
               Memory usage is {{ $value | printf "%.1f" }}% on
               {{ $labels.instance }} (job {{ $labels.job }}),
               above 85% for 5m. Cluster: {{ $externalLabels.cluster }}.
             runbook_url: "https://runbooks.example.com/NodeHighMemory"
   ```

2. Validá:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Esperado:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 3 rules found
   ```

3. Estudiá tres variables y funciones clave de templating leyendo la annotation renderizada una vez que la alerta se dispara (o mediante un unit test en el Ejercicio 4). Las piezas interesantes:
   - `{{ $labels.<name> }}` — labels de la *serie individual* que disparó esta instancia de alerta.
   - `{{ $value }}` — el *valor escalar de la muestra* devuelto por `expr` para esa serie.
   - `{{ $externalLabels.<name> }}` — las `global.external_labels` de `prometheus.yml`.

4. Comparás dos pipelines de humanización. En el navegador de expresiones, esto es lo que las funciones de template le hacen a un valor crudo como `0.8734`:

   | Fragmento de template | Se renderiza como |
   |---|---|
   | `{{ $value }}` | `0.8734` |
   | `{{ $value | printf "%.1f" }}` | `0.9` |
   | `{{ $value | humanizePercentage }}` | `87.34%` (espera un ratio 0–1) |
   | `{{ humanize $value }}` | `873.4m` |
   | `{{ humanizeDuration 3661 }}` | `1h 1m 1s` |

   > `humanizePercentage` multiplica por 100, así que dale un **ratio** (0–1). Si tu `expr` ya multiplica por 100 (como hace `NodeHighMemory`), usá `printf "%.1f"` y agregá un `%` literal en su lugar — mezclarlos da `8734.0%`.

**Verificá tu comprensión**

- **Q11.** En `{{ $labels.instance }}`, ¿de dónde proviene ese valor de label — de la regla, del scrape config, o de la serie coincidente en el momento de la evaluación?
- **Q12.** `{{ $value }}` en una alerta `TargetDown` cuyo `expr` es `up{job="node"} == 0` — ¿qué número imprime, y por qué ese no es siempre el número útil para mostrar? ¿Cuál es una manera de exponer un valor más significativo?
- **Q13.** Un colega escribe `{{ $value | humanizePercentage }}` para la alerta `NodeHighMemory` (cuyo expr ya multiplica por 100). ¿Qué va a leer el estudiante en la notificación, y cómo lo corregís?
- **Q14.** Labels vs annotations: ¿cuál conjunto participa en el grouping/deduplicación de Alertmanager y en la *identidad* de la alerta, y cuál es puramente informativo? ¿Cuál es la consecuencia práctica de poner un valor de alta cardinalidad (como `$value`) en una **label**?

---

## Ejercicio 4 — Unit-testing de reglas con `promtool test rules`

**Objetivo:** probar que una regla se dispara con las labels/annotations correctas en el momento correcto, de forma determinística, sin un Prometheus corriendo. Esta es la garantía más fuerte que podés obtener offline.

**Pasos**

1. Creá el archivo de test. La sintaxis `0x10` significa "valor 0, repetido 10 veces más" (es decir, 11 muestras a pasos de 1 minuto).

   ```yaml
   # tests/node-alerts_test.yml
   rule_files:
     - ../rules/node-alerts.yml

   evaluation_interval: 1m

   tests:
     # ---- TargetDown ----
     - interval: 1m
       input_series:
         - series: 'up{job="node", instance="localhost:9100"}'
           values: "0x10"               # target down the whole time
       alert_rule_test:
         - eval_time: 30s               # before `for: 1m` elapses
           alertname: TargetDown
           exp_alerts: []               # still pending -> nothing firing yet
         - eval_time: 3m                # well past `for: 1m`
           alertname: TargetDown
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: node
                 instance: localhost:9100
               exp_annotations:
                 summary: "Target localhost:9100 (job node) is down"
                 description: "localhost:9100 has failed scraping for more than 1 minute."

     # ---- NodeHighMemory (templating + value) ----
     - interval: 1m
       input_series:
         - series: 'node_memory_MemTotal_bytes{job="node", instance="localhost:9100"}'
           values: "100x10"
         - series: 'node_memory_MemAvailable_bytes{job="node", instance="localhost:9100"}'
           values: "10x10"              # 90% used -> above 85 threshold
       alert_rule_test:
         - eval_time: 6m                # past `for: 5m`
           alertname: NodeHighMemory
           exp_alerts:
             - exp_labels:
                 severity: warning
                 job: node
                 instance: localhost:9100
               exp_annotations:
                 summary: "High memory on localhost:9100"
                 description: "Memory usage is 90.0% on localhost:9100 (job node), above 85% for 5m. Cluster: pca-lab."
                 runbook_url: "https://runbooks.example.com/NodeHighMemory"
   ```

2. Ejecutá los tests:

   ```bash
   promtool test rules tests/node-alerts_test.yml
   ```

   Salida esperada en caso de éxito:

   ```
   Unit Testing:  tests/node-alerts_test.yml
   SUCCESS
   ```

3. Hacelo fallar a propósito para leer un diff. Cambiá la descripción esperada a `"...above 90%..."` y volvé a ejecutar. Salida esperada:

   ```
   Unit Testing:  tests/node-alerts_test.yml
   FAILED:
     alertname: NodeHighMemory, time: 6m,
         exp:[
           0:
             Labels:{alertname="NodeHighMemory", instance="localhost:9100", job="node", severity="warning"}
             Annotations:{description="Memory usage is 90.0% ... above 90% ...", ...}
         ],
         got:[
           0:
             Labels:{alertname="NodeHighMemory", instance="localhost:9100", job="node", severity="warning"}
             Annotations:{description="Memory usage is 90.0% ... above 85% ...", ...}
         ]
   ```

4. Dejalo de nuevo en verde. Agregá un bloque `promql_expr_test` al segundo test para afirmar también el valor crudo calculado — esto fija la aritmética de forma independiente de la alerta:

   ```yaml
       promql_expr_test:
         - expr: '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
           eval_time: 6m
           exp_samples:
             - labels: '{job="node", instance="localhost:9100"}'
               value: 90
   ```

**Verificá tu comprensión**

- **Q15.** ¿Por qué `exp_alerts: []` en `eval_time: 30s` es una aserción *significativa* y no un no-op? ¿Qué comportamiento tendría que exhibir un bug para que esta línea lo detecte?
- **Q16.** El unit test nunca contacta a Alertmanager y nunca ejecuta un scrape. Dado eso, ¿qué clase de problemas de producción *no* puede detectar, incluso cuando pasa?
- **Q17.** En `values: "0x10"`, ¿cuántas muestras existen y en qué timestamps (dado `interval: 1m`)? ¿Qué produciría `values: "1+2x4"`?
- **Q18.** ¿Por qué `alert_rule_test` solo afirma alertas en *firing* y nunca en pending? Relacioná tu respuesta con la Q4.

---

## Ejercicio 5 — Grupos de reglas, orden de evaluación, recording rules que alimentan alertas, y `keep_firing_for`

**Objetivo:** entender *cuándo* y *en qué orden* se evalúan las reglas, y cómo una recording rule puede precalcular una expresión costosa que luego una alerta lee.

**Pasos**

1. Refactorizá de modo que una expresión costosa sea calculada una sola vez por una **recording rule**, y la alerta referencie esa serie registrada. Fijate en el orden: dentro de un grupo, las reglas se evalúan **de arriba hacia abajo, secuencialmente**, así que una recording rule definida *arriba* de una alerta está disponible para ella en el mismo ciclo de evaluación.

   ```yaml
   # rules/node-alerts.yml  (relevant group)
   groups:
     - name: node.slo
       interval: 30s                 # per-group override of global evaluation_interval
       limit: 0                      # 0 = unlimited alerts/series produced by this group
       rules:
         # (1) recording rule — computed first
         - record: instance:node_memory_utilization:ratio
           expr: 1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes

         # (2) alert reads the recorded series — computed second, same cycle
         - alert: NodeHighMemory
           expr: instance:node_memory_utilization:ratio > 0.85
           for: 5m
           keep_firing_for: 5m       # stay firing 5m after expr goes false (dampens flapping)
           labels:
             severity: warning
           annotations:
             summary: "High memory on {{ $labels.instance }}"
             description: "Memory at {{ $value | humanizePercentage }} on {{ $labels.instance }}."
   ```

   > `keep_firing_for` requiere Prometheus **v2.42+**. En versiones más viejas `promtool check rules` rechazará el campo desconocido — una forma limpia de detectar las capacidades de la versión en ejecución.

2. Validá y recargá:

   ```bash
   promtool check rules rules/node-alerts.yml && \
   curl -s -X POST http://localhost:9090/-/reload && echo ok
   ```

   Esperado:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   ok
   ```

3. Inspeccioná la salud de la evaluación del grupo vía la API — cada grupo reporta su `interval`, `evaluationTime` (cuánto tardó la última corrida) y `lastEvaluation`:

   ```bash
   curl -s http://localhost:9090/api/v1/rules \
     | jq -r '.data.groups[] | "\(.name)\tinterval=\(.interval)s\tlast_took=\(.evaluationTime)s"'
   ```

   Salida esperada:

   ```
   node.slo    interval=30s    last_took=0.0012s
   ```

4. Confirmá que la serie registrada existe como una métrica de primera clase que podés consultar y sobre la que podés alertar:

   ```promql
   instance:node_memory_utilization:ratio
   ```

**Verificá tu comprensión**

- **Q19.** Las reglas *dentro* de un grupo corren secuencialmente; los grupos corren **de forma independiente y concurrente**. ¿Por qué eso hace inseguro poner una recording rule en el grupo A y una alerta que depende de ella en el grupo B?
- **Q20.** ¿Qué cambia `keep_firing_for` respecto del ciclo de vida, y en qué difiere conceptualmente de `for`? Dá un escenario de flapping donde prevenga una tormenta de notificaciones.
- **Q21.** El `evaluationTime` de un grupo empieza a acercarse a su `interval` (ej. `last_took=27s` en un grupo de 30s). ¿Qué está por pasar, qué expone Prometheus para advertirte, y cuáles son dos remedios?
- **Q22.** ¿Por qué preferir una recording rule para `instance:node_memory_utilization:ratio` en lugar de inline-ar la división en diez alertas distintas? Nombrá al menos dos beneficios diferentes.

---

## Ejercicio 6 — Diagnóstico avanzado: reloads, fallas de evaluación, y estado `for` a través de reinicios

**Objetivo:** depurar los modos de falla que separan "la regla está escrita" de "la regla funciona en producción".

**Pasos**

1. **Diagnosticá un archivo de reglas silenciosamente ignorado.** Agregá una regla con un valor de label que no es un string válido y recargá. Después chequeá que el reload realmente tuvo éxito:

   ```bash
   curl -s -X POST http://localhost:9090/-/reload; echo "exit=$?"
   ```

   Un reload fallido devuelve HTTP 400 con un body, y Prometheus mantiene la config *previa* buena. Confirmá cuál config está en vivo:

   ```bash
   curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head
   ```

   > Lección: un reload rechazado **no** hace crashear a Prometheus y **no** aplica las nuevas reglas. Siempre afirmá el código de salida / status HTTP; "ejecuté curl" no es "las reglas están en vivo".

2. **Encontrá una regla que está cargada pero que da error en la evaluación.** Una regla puede pasar `promtool check rules` (sintácticamente válida) y sin embargo fallar en cada evaluación (ej. una agregación que produce series duplicadas). Consultá la salud de la regla:

   ```bash
   curl -s http://localhost:9090/api/v1/rules \
     | jq -r '.data.groups[].rules[] | select(.health != "ok") | "\(.name // .record)\t\(.health)\t\(.lastError)"'
   ```

   Salida esperada cuando una regla está rota:

   ```
   NodeHighMemory    err    found duplicate series for the match group ...
   ```

   Cruzá la verificación con las métricas incorporadas:

   ```promql
   rate(prometheus_rule_evaluation_failures_total[5m]) > 0
   ```

3. **Observá la restauración del estado `for` a través de un reinicio.** Llevá `LifecycleDemo` a `firing`, anotá su `activeAt`, luego reiniciá Prometheus y consultá de nuevo inmediatamente. Prometheus restaura el progreso de `for` desde la serie persistida `ALERTS_FOR_STATE` en su TSDB en lugar de reiniciar el reloj a cero:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | select(.labels.alertname=="LifecycleDemo") | "\(.state)\t\(.activeAt)"'
   ```

   El `activeAt` después del reinicio debería coincidir con el valor previo al reinicio (dentro de una tolerancia), no saltar a "ahora".

4. Relacioná esto con los flags que gobiernan la restauración:
   - `--rules.alert.for-outage-tolerance` (default `1h`) — downtime máximo para el cual el estado `for` todavía se restaura.
   - `--rules.alert.for-grace-period` (default `10m`) — `for` mínimo forzado después de un reinicio para evitar un re-fire instantáneo.

**Verificá tu comprensión**

- **Q23.** Un compañero dice "hice reload, pero la nueva alerta no aparece". Recorré la secuencia exacta de chequeos (comandos/endpoints) que ejecutarías para distinguir entre: (a) reload rechazado, (b) regla cargada pero con error, (c) regla sana pero que nunca satisface su `expr`, (d) regla pending, todavía no en firing.
- **Q24.** Sin restauración del estado `for`, ¿qué comportamiento indeseable causaría cada reinicio de Prometheus para alertas que usan un `for` largo (digamos `for: 1h`)? ¿Cómo acotan `for-outage-tolerance` y `for-grace-period` los dos casos límite (blip corto vs. outage largo)?
- **Q25.** `prometheus_rule_group_last_duration_seconds`, `prometheus_rule_evaluation_failures_total`, y `prometheus_rule_group_iterations_missed_total` — asociá cada uno con la falla específica que detecta.
- **Q26.** ¿Por qué apoyarse en `ALERTS_FOR_STATE` significa que un Prometheus con una TSDB *borrada* (volumen fresco) re-armará cada timer `for` desde cero — y por qué ese es ocasionalmente el comportamiento *deseado* después de un incidente mayor?

---

## Respuestas

<details>
<summary>Mostrar respuestas (Q1–Q26)</summary>

**Q1.** (1) `rule_files:` en `prometheus.yml` — sin ella el archivo nunca se carga, así que la regla nunca se evalúa. (2) El bloque `alerting:` / `alertmanagers:` — sin un Alertmanager alcanzable la alerta puede llegar a `firing` internamente pero su notificación nunca sale de Prometheus. La evaluación necesita `rule_files`; la *entrega* necesita `alerting`.

**Q2.** `node_exporter` no está corriendo, así que el scrape de `localhost:9100` falla y Prometheus registra `up{job="node"} == 0`. Eso nos da una condición determinística y siempre verdadera para manejar `TargetDown` sin tener que romper nada real.

**Q3.** `--web.enable-lifecycle` expone `POST /-/reload` y `/-/quit`, que llamantes no autenticados podrían abusar para disparar reloads o apagar Prometheus. Mitigaciones: restringir vía un reverse proxy / network policy, bindear a una interfaz privada, y/o requerir auth por delante de los endpoints HTTP. Muchos lugares en cambio recargan con `SIGHUP` y dejan la API de lifecycle apagada.

**Q4.** `activeAt` marca el instante en que el `expr` devolvió por primera vez un resultado para esa serie — es decir, el momento en que la alerta pasó a estar **activa (pending)**. `for` es un *tiempo de permanencia* (dwell time): la condición debe mantenerse continuamente verdadera durante toda esa duración antes de que el estado pase a **firing**. Ambas alertas pasaron a activas en el mismo instante (ambos exprs eran verdaderos inmediatamente después del reload), pero se disparan en momentos distintos porque sus valores de `for` difieren (1m vs 2m). Si `expr` se vuelve falso en algún punto, `activeAt` se resetea y el reloj de `for` reinicia.

**Q5.** Pending → no se envía nada a Alertmanager; pending es puramente interno. Firing → Prometheus envía la alerta a cada Alertmanager configurado y la sigue re-enviando (según `--rules.alert.resend-delay`, default 1m) mientras se mantenga en firing, más una notificación de "resolved" cuando se aclara.

**Q6.** `alertstate` es únicamente `pending` o `firing`. `ALERTS{alertstate="inactive"}` nunca devuelve datos porque Prometheus escribe la serie `ALERTS` *solo mientras una alerta está activa*; una alerta inactiva no produce ninguna serie (la ausencia de la serie es lo que significa "inactive").

**Q7.** Con `for: 0` (u omitido) no hay fase pending desde la perspectiva del usuario: apenas `expr` es verdadero en una evaluación, la alerta pasa directamente a `firing`. Es más sensible (se dispara con una sola evaluación verdadera) y por lo tanto más propensa al flapping ante picos transitorios.

**Q8.** Chequea (1) que cada `expr` sea *PromQL válido* (parsea) y (2) que la *estructura* del archivo se ajuste al esquema de reglas (claves correctas como `alert`/`record`/`expr`/`for`/`labels`/`annotations`). **No** chequea que las métricas referenciadas realmente existan, que el threshold sea sensato, que la alerta llegue a dispararse alguna vez, ni que las annotations se rendericen correctamente — solo los unit tests / la evaluación en vivo hacen eso.

**Q9.** La automatización (pre-commit hooks, CI) se ramifica según el status de salida, no según el scraping de stdout. `promtool check rules` devuelve distinto de cero ante cualquier falla, así que `... && git commit` o un paso de CI bloquea naturalmente el cambio malo. El texto humano es para la persona que lee el log; el código de salida es el gate.

**Q10.** `promtool check config prometheus.yml` valida la config principal *y* valida transitivamente cada archivo que coincida con `rule_files:` (invoca el mismo check de reglas). `promtool check rules FILE` valida únicamente el/los archivo(s) de reglas que nombrás. `check config` es el superconjunto — pero a menudo ejecutás `check rules` directamente en CI cuando solo cambiaron archivos de reglas.

**Q11.** De la **serie coincidente en el momento de la evaluación**. El `expr` de la alerta devuelve un conjunto de series (cada una con sus propias labels, heredadas del scrape/relabeling que las produjo); `$labels` es el conjunto de labels de la serie específica que disparó esta instancia de alerta. No se toma del texto de la regla ni estáticamente del scrape config.

**Q12.** Para `up == 0`, el `expr` evalúa a `1` donde la comparación se cumple (el valor del resultado filtrado es el valor del operando izquierdo solo si usás `bool`; con un filtro plano el valor de la muestra devuelta es el valor del `up` de la izquierda, que es `0`). De cualquier manera es una constante ligada a la comparación, no una magnitud significativa. Para mostrar algo útil, basá la alerta en una métrica cuyo valor lleve información (ej. `time() - node_boot_time_seconds`), o poné la cifra significativa en una annotation separada vía una sub-consulta templada, o registrala como una serie compañera.

**Q13.** El expr de `NodeHighMemory` ya da un porcentaje (ej. `90`). `humanizePercentage` multiplica por 100 y agrega `%`, así que el estudiante lee **`9000%`**. Fix: o le das a `humanizePercentage` un ratio 0–1 (quitá el `*100` del expr, como se hace en el Ejercicio 5) o mantenés el expr con `*100` y renderizás con `{{ $value | printf "%.1f" }}%`.

**Q14.** Las **labels** definen la identidad de la alerta y manejan el grouping, routing, inhibición y deduplicación de Alertmanager; las **annotations** son de forma libre, informativas, e ignoradas para la identidad. Poner un valor de alta cardinalidad como `$value` en una *label* cambia la identidad de la alerta en cada evaluación, así que Alertmanager ve una alerta completamente nueva cada vez — rompiendo la dedup/grouping y causando tormentas de notificaciones. Los datos de alta cardinalidad pertenecen a las annotations.

**Q15.** Afirma que a los 30s (antes de que haya transcurrido `for: 1m`) la alerta **todavía no está en firing** — es decir, que la cláusula `for` realmente se está respetando. Un bug que ignorara `for` (disparando inmediatamente) produciría una alerta en firing a los 30s, y esta aserción lo detectaría. Así que `exp_alerts: []` fija la *semántica temporal*, no solo el resultado final.

**Q16.** Cualquier cosa que dependa del entorno en vivo: labels de target incorrectas/faltantes producto del relabeling real, métricas que no existen en producción, routing/silences/inhibición de Alertmanager, entrega de notificaciones, huecos de scrape y staleness, y la planificación de los grupos de reglas bajo carga real. Un unit test en verde prueba la lógica de la regla dada una entrada sintética; no dice nada sobre si la entrada real llega.

**Q17.** `values: "0x10"` = 11 muestras (el `0` inicial más 10 repeticiones) en t = 0, 1m, 2m, … 10m. `values: "1+2x4"` = una secuencia aritmética que empieza en 1, paso +2, 4 repeticiones → `1, 3, 5, 7, 9` (5 muestras).

**Q18.** Porque pending es un estado de contabilidad interno y transitorio que nunca sale de Prometheus y está totalmente determinado por `for` + `activeAt`; el resultado externamente significativo es *qué se dispara*. `alert_rule_test` afirma el contrato observable (qué alertas, con qué labels/annotations, en qué momentos). Testeás la ventana pending indirectamente afirmando `exp_alerts: []` en un momento anterior a que transcurra `for` (Q15), que es exactamente lo que se conecta con el ciclo de vida de la Q4.

**Q19.** Los grupos se evalúan concurrentemente, cada uno en su propio schedule, y la consistencia de las entradas de una regla solo se garantiza *dentro* de la pasada secuencial de arriba hacia abajo de un único grupo. Si la recording rule está en el grupo A y la alerta dependiente en el grupo B, la alerta puede leer un valor obsoleto (el del ciclo anterior) o ninguno en la primera corrida, y los dos pueden desincronizarse en cada evaluación. Mantené una recording rule y su alerta dependiente en el **mismo grupo**, con la recording rule primero.

**Q20.** `for` controla la *entrada* a firing (la condición debe mantenerse N segundos antes de disparar). `keep_firing_for` controla la *salida*: después de que `expr` deja de devolver la serie, la alerta se mantiene en firing por la duración extra antes de resolverse. Escenario de flapping: una métrica oscila justo por encima/debajo del threshold cada 20–40s. Con solo `for`, obtenés ciclos repetidos de fire/resolve y una tormenta de notificaciones resolved+fired; `keep_firing_for: 5m` la mantiene en firing a través de las caídas, colapsando el ruido en una sola alerta sostenida.

**Q21.** La evaluación del grupo está casi sobrepasando su interval; si `evaluationTime` excede `interval`, las iteraciones se **saltean** (las alertas se evalúan tarde, el timing de `for` se degrada). Prometheus expone `prometheus_rule_group_last_duration_seconds`, `prometheus_rule_group_iterations_missed_total`, y `prometheus_rule_group_interval_seconds`. Remedios: dividir el grupo en grupos más pequeños (más paralelismo), reemplazar exprs inline costosas por recording rules, ampliar el `interval` del grupo, o reducir la cardinalidad de las series que alimentan las reglas.

**Q22.** (1) Costo/rendimiento: la división costosa se calcula una vez por ciclo en lugar de una vez por cada alerta dependiente y por cada consulta de dashboard. (2) Consistencia: cada consumidor lee la serie precalculada idéntica, así que las alertas y los dashboards no pueden discrepar. (3) Dashboards/consultas más rápidas sobre rangos largos (la serie derivada queda almacenada). (4) Un único punto de cambio si la fórmula necesita corrección.

**Q23.** (a) `curl -s -X POST /-/reload; echo exit=$?` y/o chequear el status HTTP y los logs — distinto de cero/400 significa reload rechazado y las reglas viejas siguen vivas; confirmá con `/api/v1/status/config`. (b) `GET /api/v1/rules` y filtrá por `.health != "ok"` y leé `.lastError`; corroborá con `rate(prometheus_rule_evaluation_failures_total[5m])`. (c) La regla muestra `health: ok` pero ejecutá su `expr` en el navegador de expresiones — si no devuelve series, la condición simplemente no se cumple. (d) `GET /api/v1/alerts` muestra `state: pending` con un `activeAt` reciente — está dentro de su ventana `for`; esperá a que transcurra.

**Q24.** Cada reinicio resetearía a cero el reloj de `for` de cada alerta, así que una alerta `for: 1h` que había estado contando durante 55m empezaría de nuevo y demoraría el disparo hasta otra hora más — los reinicios (deploys, OOMs) podrían posponer indefinidamente alertas reales. `for-outage-tolerance` (default 1h) limita cuán largo puede ser un *hueco* confiando aún en el estado restaurado (más allá de eso, se trata como fresco); `for-grace-period` (default 10m) fuerza un `for` mínimo posterior al reinicio para que una alerta con `for` largo no re-dispare instantáneamente en el momento en que Prometheus vuelve.

**Q25.** `prometheus_rule_group_last_duration_seconds` → un grupo que tarda demasiado en evaluarse (acercándose/superando su interval). `prometheus_rule_evaluation_failures_total` → evaluaciones de reglas individuales que dan error (resultado de expr malo en runtime, series duplicadas, etc.). `prometheus_rule_group_iterations_missed_total` → ciclos de evaluación completos salteados porque la corrida anterior no había terminado (overrun) — el síntoma directo del problema de duración.

**Q26.** El estado `for` se persiste como la serie `ALERTS_FOR_STATE` dentro de la propia TSDB de Prometheus; en el arranque Prometheus la lee de vuelta para reconstruir `activeAt`. Una TSDB fresca/vacía no tiene esa serie, así que nada puede restaurarse y cada timer `for` empieza en cero. Eso es ocasionalmente deseable: después de un incidente mayor o una migración limpia podés *querer* que cada alerta se reevalúe desde una pizarra en blanco en lugar de resucitar estado de firing obsoleto que ya no refleja la realidad.

</details>