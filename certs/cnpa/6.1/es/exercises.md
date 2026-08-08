# Ejercicios guiados — Tema 6.1: Platform Efficiency, Product Value, and Team Productivity

> **Peso en el examen: 4.0** — Este tema no evalúa "cómo construir" la plataforma, sino **cómo demostrar que aporta valor**. La competencia central es tratar la plataforma como un *product* y sustentar esa afirmación con métricas: throughput y estabilidad de la entrega (DORA), adopción y self-service, cognitive load / developer experience, y eficiencia económica (ROI). Los cinco ejercicios recorren esa cadena de medición de punta a punta.

## Entorno de laboratorio

Todos los ejercicios asumen una shell POSIX con estas herramientas. Verificá antes de empezar:

```bash
jq --version        # jq-1.7.1
yq --version        # yq (https://github.com/mikefarah/yq/) version v4.44.3
bc --version        # bc 1.07.1
kubectl version --client -o yaml | grep gitVersion   # v1.30+
```

El cluster tiene desplegado `kube-prometheus-stack` (operador Prometheus) en el namespace `monitoring`. Si no lo tenés a mano, los Ejercicios 1, 3, 4 y 5 son autocontenidos (solo requieren `jq`/`yq`/`bc`); el Ejercicio 2 necesita el CRD `PrometheusRule` (`monitoring.coreos.com/v1`).

---

## Ejercicio 1 — Las cuatro métricas DORA desde eventos de despliegue

**Objetivo:** calcular *Deployment Frequency*, *Lead Time for Changes*, *Change Failure Rate* y *Failed Deployment Recovery Time* a partir de un log crudo de despliegues, y clasificar el rendimiento del equipo. Este es el cálculo que la plataforma debe automatizar; hacerlo a mano una vez fija los conceptos.

**Paso 1.** Generá el dataset de eventos de una semana para el servicio `checkout` (cada línea es un deployment a `production`; `committed_at` es el commit que originó el cambio y `deployed_at` cuándo llegó a producción):

```bash
cat > deployments.jsonl <<'EOF'
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-07-28T08:00:00Z","deployed_at":"2026-07-28T09:30:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-07-29T10:00:00Z","deployed_at":"2026-07-29T12:00:00Z"}
{"service":"checkout","env":"production","outcome":"failure","committed_at":"2026-07-30T09:00:00Z","deployed_at":"2026-07-30T09:45:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-07-30T14:00:00Z","deployed_at":"2026-07-30T15:00:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-07-31T11:00:00Z","deployed_at":"2026-07-31T13:30:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-08-01T08:30:00Z","deployed_at":"2026-08-01T09:00:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-08-02T16:00:00Z","deployed_at":"2026-08-02T20:00:00Z"}
{"service":"checkout","env":"production","outcome":"failure","committed_at":"2026-08-03T09:00:00Z","deployed_at":"2026-08-03T10:00:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-08-03T12:00:00Z","deployed_at":"2026-08-03T12:30:00Z"}
{"service":"checkout","env":"production","outcome":"success","committed_at":"2026-08-04T09:00:00Z","deployed_at":"2026-08-04T10:30:00Z"}
EOF
wc -l deployments.jsonl
```

Salida esperada:

```
10 deployments.jsonl
```

**Paso 2.** Calculá tres de las cuatro keys (Deployment Frequency, Change Failure Rate y la mediana del Lead Time) con un solo pipeline de `jq`. Fijate que el lead time se mide en segundos como `deployed_at - committed_at` y luego se convierte a horas:

```bash
jq -s '
  ([ .[] | select(.env=="production") ])                as $p
  | ($p | length)                                       as $n
  | ([ $p[] | select(.outcome=="failure") ] | length)   as $f
  | ([ $p[] | (.deployed_at|fromdateiso8601)
             - (.committed_at|fromdateiso8601) ] | sort) as $lt
  | ($lt | length)                                      as $m
  | {
      window_days: 7,
      total_deployments: $n,
      deployment_frequency_per_day: (($n / 7 * 100 | round) / 100),
      change_failure_rate_pct: ($f / $n * 100),
      median_lead_time_hours:
        (( if ($m % 2) == 1
             then $lt[($m/2|floor)]
             else ($lt[$m/2 - 1] + $lt[$m/2]) / 2
           end ) / 3600)
    }
' deployments.jsonl
```

Salida esperada:

```json
{
  "window_days": 7,
  "total_deployments": 10,
  "deployment_frequency_per_day": 1.43,
  "change_failure_rate_pct": 20,
  "median_lead_time_hours": 1.25
}
```

**Paso 3.** Calculá la cuarta key, *Failed Deployment Recovery Time*: el tiempo desde cada deployment fallido hasta el siguiente deployment exitoso del mismo servicio. Emparejamos cada `failure` con el primer `success` posterior:

```bash
jq -s '
  ([ .[] | select(.env=="production") ] | sort_by(.deployed_at)) as $p
  | [ range(0; ($p|length)) as $i
      | select($p[$i].outcome=="failure")
      | ($p[$i].deployed_at|fromdateiso8601) as $tf
      | ( first( $p[($i+1):][] | select(.outcome=="success")
                  | (.deployed_at|fromdateiso8601) ) ) as $tr
      | ($tr - $tf) ]
  | { recovery_times_hours: (map(. / 3600)),
      median_recovery_hours:
        ( (sort | (.[ (length/2|floor) ] + .[ ((length-1)/2|floor) ]) / 2) / 3600
          | . as $x | ($x*100|round)/100 ) }
' deployments.jsonl
```

Salida esperada:

```json
{
  "recovery_times_hours": [5.25, 2.5],
  "median_recovery_hours": 3.88
}
```

**Paso 4.** Contrastá los cuatro números contra los umbrales del cluster *Elite* del DORA State of DevOps report (Deployment Frequency *on-demand* / múltiples por día; Lead Time < 1 día; Change Failure Rate ≤ ~5–15 %; Recovery < 1 hora).

### Preguntas de comprensión — Ejercicio 1

1. Las cuatro keys se agrupan en dos ejes. ¿Cuáles dos miden **throughput** y cuáles dos miden **stability**? ¿Por qué CNPA insiste en reportar siempre las cuatro juntas en lugar de optimizar una sola?
2. Con los resultados obtenidos (DF ≈ 1.43/día, LT p50 = 1.25 h, CFR = 20 %, recovery p50 ≈ 3.88 h), ¿en qué keys el equipo alcanza nivel *Elite* y en cuáles no? ¿Cuál es la que más lo aleja de *Elite*?
3. El Lead Time se calculó con `deployed_at - committed_at`, incluyendo también los deployments fallidos. ¿Por qué DORA mide el lead time sobre *todos* los cambios que llegan a producción y no solo sobre los exitosos?
4. ¿Por qué la **mediana** (p50) y no la media aritmética es la estadística correcta para Lead Time y Recovery Time?

---

## Ejercicio 2 — Exponer DORA como recording rules en Prometheus

**Objetivo:** dejar de calcular las métricas a mano y hacerlas continuas. La plataforma emite dos señales instrumentadas —`deployments_total` (counter con label `outcome`) y `change_lead_time_seconds` (histogram)— y Prometheus deriva las keys con *recording rules*.

**Paso 1.** Creá el manifiesto `PrometheusRule`. Es sintácticamente válido para el operador Prometheus:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # debe coincidir con ruleSelector del Prometheus CR
spec:
  groups:
    - name: dora.rules
      interval: 1m
      rules:
        # Deployment Frequency: despliegues exitosos a prod por día (ventana 7d)
        - record: dora:deployment_frequency:per_day
          expr: |
            sum by (service) (
              increase(deployments_total{env="production", outcome="success"}[7d])
            ) / 7

        # Change Failure Rate: fallidos / total (ventana 7d), en fracción 0..1
        - record: dora:change_failure_rate:ratio
          expr: |
            sum by (service) (increase(deployments_total{env="production", outcome="failure"}[7d]))
            /
            clamp_min(
              sum by (service) (increase(deployments_total{env="production"}[7d])),
              1
            )

        # Lead Time for Changes: p50 del histogram (segundos)
        - record: dora:lead_time_seconds:p50
          expr: |
            histogram_quantile(0.5,
              sum by (service, le) (rate(change_lead_time_seconds_bucket[7d]))
            )
      # Alerta si la plataforma cae por debajo de un objetivo de estabilidad
    - name: dora.alerts
      rules:
        - alert: ChangeFailureRateHigh
          expr: dora:change_failure_rate:ratio > 0.15
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "CFR de {{ $labels.service }} sobre el 15% (valor: {{ $value | humanizePercentage }})"
```

**Paso 2.** Validá la sintaxis de las reglas **sin** aplicarlas al cluster (`promtool` viene en la imagen de Prometheus):

```bash
kubectl -n monitoring exec deploy/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
  promtool check rules /dev/stdin < dora-metrics.yaml
```

Salida esperada (aproximada):

```
Checking /dev/stdin
  SUCCESS: 4 rules found
```

**Paso 3.** Aplicá el manifiesto y confirmá que el operador lo recogió:

```bash
kubectl apply -f dora-metrics.yaml
kubectl -n monitoring get prometheusrule dora-metrics
```

Salida esperada:

```
NAME           AGE
dora-metrics   12s
```

**Paso 4.** Consultá una recording rule ya materializada vía la HTTP API de Prometheus (medida como despliegues/día). Ajustá el port-forward si tu Service tiene otro nombre:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 2
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=dora:deployment_frequency:per_day{service="checkout"}' \
  | jq '.data.result[] | {service: .metric.service, value: .value[1]}'
```

Salida esperada (ejemplo):

```json
{
  "service": "checkout",
  "value": "1.4285714285714286"
}
```

### Preguntas de comprensión — Ejercicio 2

1. En la regla de CFR se usa `clamp_min(..., 1)` en el denominador. ¿Qué problema concreto de PromQL evita esa función cuando un servicio no tuvo ningún deployment en la ventana de 7 días?
2. Lead Time se deriva con `histogram_quantile(0.5, ...)` sobre `..._bucket`. ¿Por qué se instrumenta el lead time como un **histogram** y no como un **gauge** con el último valor?
3. El label `release: kube-prometheus-stack` en `metadata.labels` no es decorativo. ¿Qué campo del Prometheus CR lo usa y qué pasa si no coincide?
4. `increase(...[7d])` versus `rate(...[7d])`: ¿por qué para "despliegues por día" conviene `increase()/7` en lugar de `rate() * 86400`? (Pista: unidades y legibilidad, no corrección.)

---

## Ejercicio 3 — Productividad del equipo: Time-to-First-Deploy y adopción del golden path

**Objetivo:** medir dos señales de *team productivity* que la plataforma habilita: el **Time-to-First-Deploy (TTFD)** de un servicio nuevo y el **self-service ratio** (qué fracción del trabajo de plataforma se resuelve sin abrir un ticket a un humano). Un golden path que nadie usa no aporta valor: la adopción es parte de la métrica.

**Paso 1.** Un golden path se materializa como un *software template* (aquí, un Backstage Scaffolder template). Guardalo — es el artefacto cuya adopción vamos a medir:

```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: golden-path-service
  title: "Golden Path — Go microservice"
  tags: [recommended, golden-path]
spec:
  owner: platform-team
  type: service
  parameters:
    - title: Identidad del servicio
      required: [name]
      properties:
        name:
          type: string
          pattern: '^[a-z0-9-]+$'
  steps:
    - id: scaffold
      name: Render repo desde skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values: { name: '${{ parameters.name }}' }
    - id: publish
      name: Crear repo Git
      action: publish:github
      input:
        repoUrl: 'github.com?owner=acme&repo=${{ parameters.name }}'
    - id: register
      name: Registrar en el catálogo
      action: catalog:register
      input:
        repoContentsUrl: '${{ steps.publish.output.repoContentsUrl }}'
        catalogInfoPath: '/catalog-info.yaml'
  output:
    links:
      - title: Repositorio
        url: '${{ steps.publish.output.remoteUrl }}'
```

**Paso 2.** Cargá el registro de eventos de onboarding de servicios nuevos. `path` indica si el servicio nació del golden path o se armó a mano; los timestamps miden desde la creación del repo hasta el primer deploy exitoso a producción:

```bash
cat > onboarding.jsonl <<'EOF'
{"service":"payments-api","path":"golden","created_at":"2026-08-01T09:00:00Z","first_prod_deploy_at":"2026-08-01T12:00:00Z"}
{"service":"loyalty","path":"golden","created_at":"2026-08-02T10:00:00Z","first_prod_deploy_at":"2026-08-02T14:30:00Z"}
{"service":"reporting","path":"manual","created_at":"2026-08-01T09:00:00Z","first_prod_deploy_at":"2026-08-06T17:00:00Z"}
{"service":"notifications","path":"golden","created_at":"2026-08-03T08:00:00Z","first_prod_deploy_at":"2026-08-03T11:30:00Z"}
{"service":"search","path":"manual","created_at":"2026-08-02T09:00:00Z","first_prod_deploy_at":"2026-08-05T15:00:00Z"}
EOF
```

**Paso 3.** Calculá el TTFD mediano por *path* y el golden-path adoption ratio:

```bash
jq -s '
  def ttfd: (.first_prod_deploy_at|fromdateiso8601) - (.created_at|fromdateiso8601);
  def median(f): map(f) | sort | (.[ (length/2|floor) ] + .[ ((length-1)/2|floor) ]) / 2;
  {
    golden_ttfd_hours:
      ( ([ .[] | select(.path=="golden") ] | median(ttfd)) / 3600 ),
    manual_ttfd_hours:
      ( ([ .[] | select(.path=="manual") ] | median(ttfd)) / 3600 ),
    golden_path_adoption_pct:
      ( ([ .[] | select(.path=="golden") ] | length) / (length) * 100 )
  }
' onboarding.jsonl
```

Salida esperada:

```json
{
  "golden_ttfd_hours": 3.5,
  "manual_ttfd_hours": 102,
  "golden_path_adoption_pct": 60
}
```

**Paso 4.** Calculá el **self-service ratio** desde el export de solicitudes a la plataforma. `channel = portal` significa resuelto por self-service; `ticket` significa que un ingeniero de plataforma tuvo que intervenir:

```bash
cat > platform_requests.jsonl <<'EOF'
{"kind":"new-service","channel":"portal"}
{"kind":"namespace","channel":"portal"}
{"kind":"database","channel":"ticket"}
{"kind":"new-service","channel":"portal"}
{"kind":"tls-cert","channel":"portal"}
{"kind":"vpc-peering","channel":"ticket"}
{"kind":"namespace","channel":"portal"}
{"kind":"new-service","channel":"portal"}
EOF

jq -s '
  { total: length,
    self_service: ([ .[] | select(.channel=="portal") ] | length),
    self_service_ratio_pct:
      ( ([ .[] | select(.channel=="portal") ] | length) / length * 100 | round )
  }
' platform_requests.jsonl
```

Salida esperada:

```json
{
  "total": 8,
  "self_service": 6,
  "self_service_ratio_pct": 75
}
```

### Preguntas de comprensión — Ejercicio 3

1. El TTFD del golden path es 3.5 h contra 102 h del manual — una mejora de ~29×. ¿Por qué esta métrica es un proxy directo de **reducción de cognitive load**, y no solo de velocidad?
2. El golden-path adoption está en 60 %. Si fuera 100 % pero el `self_service_ratio` fuera 20 %, ¿qué te diría esa combinación sobre la plataforma? ¿Y el caso inverso (adoption baja, self-service alto)?
3. ¿Por qué el `self_service_ratio` es una métrica *leading* (anticipa) mientras que las cuatro keys DORA son *lagging* (confirman a posteriori) respecto de la salud de la plataforma?
4. El template declara `catalog:register` como último step. ¿Qué señal de medición se pierde si un servicio se despliega pero nunca se registra en el catálogo?

---

## Ejercicio 4 — Cognitive load y Developer Experience (DevEx / SPACE) mapeado al Maturity Model

**Objetivo:** convertir percepción subjetiva en una señal cuantificada. Vas a puntuar una encuesta DevEx sobre las tres dimensiones del framework (*feedback loops*, *cognitive load*, *flow state*), obtener un índice ponderado, y mapearlo a un nivel del **CNCF Platform Engineering Maturity Model** en su aspecto *Measurement*.

**Paso 1.** Guardá las respuestas agregadas de la encuesta trimestral (escala 1–5, mayor es mejor; `cognitive_load` ya está invertida para que "mayor = menos carga"):

```bash
cat > devex_survey.yaml <<'EOF'
respondents: 42
dimensions:
  feedback_loops:      # CI rápido, tiempo de deploy, tiempo de review
    score: 3.8
    weight: 0.35
  cognitive_load:      # claridad de docs, nº de herramientas a dominar, complejidad
    score: 2.9
    weight: 0.40
  flow_state:          # interrupciones, autonomía, foco
    score: 3.4
    weight: 0.25
EOF
```

**Paso 2.** Calculá el DevEx Index ponderado con `yq`:

```bash
yq -o=json '
  .dimensions
  | to_entries
  | map(.value.score * .value.weight)
  | add
  | { devex_index: (. * 100 | round / 100) }
' devex_survey.yaml
```

Salida esperada:

```json
{
  "devex_index": 3.36
}
```

**Paso 3.** Mapeá el índice a un nivel de madurez. El Maturity Model define cuatro niveles; usá esta tabla de correspondencia del aspecto *Measurement* (rúbrica del laboratorio):

```bash
cat > maturity_map.sh <<'EOF'
#!/usr/bin/env bash
idx="$1"
level=$(echo "$idx" | awk '{
  if      ($1 < 2.0) print "1 Provisional  — medición ad-hoc, sin baseline";
  else if ($1 < 3.0) print "2 Operational  — métricas recogidas, no accionadas";
  else if ($1 < 4.0) print "3 Scalable     — métricas guían inversión y roadmap";
  else               print "4 Optimizing   — feedback loops cierran solos, mejora continua";
}')
echo "DevEx Index $idx -> Maturity Level $level"
EOF
chmod +x maturity_map.sh
./maturity_map.sh 3.36
```

Salida esperada:

```
DevEx Index 3.36 -> Maturity Level 3 Scalable     — métricas guían inversión y roadmap
```

**Paso 4.** Identificá la dimensión que más frena el índice. Con `cognitive_load` en 2.9 (la más baja) y el mayor peso (0.40), es el driver dominante: bajar la carga cognitiva es la inversión de mayor retorno según *esta* medición.

### Preguntas de comprensión — Ejercicio 4

1. El framework **DevEx** (feedback loops, cognitive load, flow state) es *perceptual*; el framework **SPACE** (Satisfaction, Performance, Activity, Communication, Efficiency) y **DORA** son en buena parte *sistémicos/de flujo*. ¿Por qué CNPA sostiene que ninguno de los tres reemplaza a los otros y hay que triangular?
2. La `cognitive_load` está invertida ("mayor = menos carga") antes de ponderar. ¿Qué error de interpretación aparecería si se sumara sin invertir?
3. El nivel de madurez cayó en *Scalable* (3), no en *Optimizing* (4). Según la rúbrica, ¿qué capacidad concreta le falta a la plataforma para llegar a *Optimizing*?
4. **Trampa clásica:** medir *Activity* (commits, PRs, deploys por dev) como proxy de productividad. ¿Por qué el framework SPACE advierte explícitamente contra usar métricas de actividad de forma aislada para evaluar personas?

---

## Ejercicio 5 — Eficiencia y ROI de la plataforma

**Objetivo:** expresar el valor de la plataforma en términos económicos: **cost per deployment**, **engineer-hours saved** y **ROI**. Es el argumento que sostiene la inversión frente a finanzas y liderazgo, y el corazón de "Product Value" en 6.1.

**Paso 1.** Cargá los parámetros mensuales del sistema (infra medida por kubecost/opencost + costo del equipo de plataforma + telemetría de flujo):

```bash
cat > platform_econ.yaml <<'EOF'
period: "2026-07"
costs_usd:
  infra_monthly: 18000        # cómputo/almacenamiento imputable a la plataforma
  platform_team_monthly: 96000 # 6 ingenieros, costo cargado
flow:
  deployments_per_month: 640
  developers_served: 80
lead_time_hours:
  before_platform: 6.0        # baseline manual histórico
  after_platform: 1.25        # p50 actual (del Ejercicio 1)
economics:
  loaded_hourly_rate_usd: 95  # costo cargado por hora de developer
EOF
```

**Paso 2.** Calculá **cost per deployment** y **cost per developer served**:

```bash
yq -o=json '
  (.costs_usd.infra_monthly + .costs_usd.platform_team_monthly) as $total
  | {
      total_platform_cost_usd: $total,
      cost_per_deployment_usd:
        ($total / .flow.deployments_per_month | . * 100 | round / 100),
      cost_per_developer_usd:
        ($total / .flow.developers_served | . * 100 | round / 100)
    }
' platform_econ.yaml
```

Salida esperada:

```json
{
  "total_platform_cost_usd": 114000,
  "cost_per_deployment_usd": 178.13,
  "cost_per_developer_usd": 1425
}
```

**Paso 3.** Calculá el valor entregado como **engineer-hours saved** por la reducción de lead time, monetizado, y de ahí el **ROI**:

```bash
yq -o=json '
  (.lead_time_hours.before_platform - .lead_time_hours.after_platform) as $saved_h
  | ($saved_h * .flow.deployments_per_month) as $hours_saved
  | ($hours_saved * .economics.loaded_hourly_rate_usd) as $value
  | (.costs_usd.infra_monthly + .costs_usd.platform_team_monthly) as $cost
  | {
      hours_saved_per_month: $hours_saved,
      value_delivered_usd: $value,
      platform_cost_usd: $cost,
      net_value_usd: ($value - $cost),
      roi_pct: (($value - $cost) / $cost * 100 | round)
    }
' platform_econ.yaml
```

Salida esperada:

```json
{
  "hours_saved_per_month": 3040,
  "value_delivered_usd": 288800,
  "platform_cost_usd": 114000,
  "net_value_usd": 174800,
  "roi_pct": 153
}
```

**Paso 4.** Sensibilizá el resultado: ¿cuál es el `loaded_hourly_rate_usd` de **break-even** (ROI = 0 %)? Es el rate para el que `value_delivered == platform_cost`:

```bash
echo "scale=2; 114000 / 3040" | bc
```

Salida esperada:

```
37.50
```

Interpretación: mientras la hora cargada de un developer valga más de **US$37.50**, la plataforma se paga sola solo con el ahorro de lead time — sin contar reducción de CFR, menor MTTR ni onboarding más rápido.

### Preguntas de comprensión — Ejercicio 5

1. El ROI de 153 % se apoya **solo** en `hours_saved` por lead time. Nombrá al menos tres fuentes de valor adicionales, ya medidas en los ejercicios anteriores, que este cálculo **subestima** por dejarlas afuera.
2. El break-even da US$37.50/h. ¿Por qué presentar el *break-even rate* es un argumento más robusto ante finanzas que presentar el ROI puntual de 153 %?
3. `cost_per_deployment` bajará automáticamente si suben los `deployments_per_month` a costo de equipo constante. ¿Por qué esta métrica, **sola**, puede inducir a un comportamiento peligroso, y con qué key DORA hay que aparearla siempre?
4. El costo de infra sale de kubecost/opencost imputado a la plataforma. ¿Por qué el reparto (allocation) de costos compartidos —un ingress controller, un cluster de observabilidad— es la parte más disputable de todo el cálculo de ROI?

---

## Respuestas

<details>
<summary>Mostrar respuestas de los cinco ejercicios</summary>

### Ejercicio 1

1. **Throughput:** Deployment Frequency y Lead Time for Changes. **Stability:** Change Failure Rate y Failed Deployment Recovery Time. Se reportan las cuatro juntas porque throughput y stability están en tensión: se puede inflar la Deployment Frequency degradando el CFR (deployar rápido y roto), o bajar el CFR a costa de casi no deployar. Las cuatro juntas describen si la mejora es real (ambos ejes suben) o un trade-off encubierto. Es la defensa contra optimizar la métrica en vez del sistema (Goodhart).
2. **Elite** en throughput: Deployment Frequency (1.43/día ≈ *multiple deploys per day/on-demand*) y Lead Time (1.25 h ≪ 1 día). **No-Elite** en stability: Change Failure Rate = 20 % (por encima del rango elite ~5–15 %) y Recovery ≈ 3.88 h (por encima de la hora). La que más lo aleja es el **Recovery Time** en términos de orden de magnitud, aunque el CFR de 20 % es la señal de riesgo más accionable. El equipo es rápido pero inestable: clásico perfil que necesita invertir en testing/rollback antes que en más velocidad.
3. Porque DORA mide el flujo del *value stream* hasta producción; un cambio que llegó a producción **consumió** lead time exista o no un bug. Excluir los fallidos sesgaría la métrica hacia abajo justo cuando el proceso funciona peor, ocultando el costo real de entregar. Lead Time mide "cuánto tarda un commit en llegar a los usuarios", no "cuánto tarda un commit *bueno*".
4. Porque las distribuciones de lead time y recovery tienen **cola larga a la derecha** (unos pocos deploys/incidentes patológicos de muchas horas). La media es arrastrada por esos outliers y deja de representar la experiencia típica; la mediana (p50) refleja el caso habitual. Por eso DORA reporta percentiles (p50, y a veces p90 para ver la cola) y no promedios.

### Ejercicio 2

1. Evita la **división por cero → `NaN`/vector vacío**. Si un servicio no tuvo deployments en 7 días, `increase(deployments_total[7d])` es 0; `0/0` produce un resultado sin muestras y la regla no registra nada (o propaga `NaN`), rompiendo dashboards y alertas. `clamp_min(denominador, 1)` fuerza un piso de 1, devolviendo `0/1 = 0` (CFR real cuando no hubo fallos ni deploys), que es interpretable.
2. Porque un histogram preserva la **distribución** de lead times en buckets, y eso permite calcular *cualquier* cuantil (p50, p90, p99) del lado del servidor con `histogram_quantile`, además de agregarse correctamente entre instancias sumando por `le`. Un gauge con "el último lead time" pierde la distribución: no podés sacar percentiles ni una mediana con sentido, y un único valor atípico lo domina.
3. Lo usa el campo **`spec.ruleSelector`** del recurso `Prometheus` (el CR del operador). El operador solo carga los `PrometheusRule` cuyas labels matchean ese selector (típicamente `release: kube-prometheus-stack`). Si no coincide, el manifiesto se aplica al cluster pero **el operador lo ignora** y las reglas nunca llegan a Prometheus — falla silenciosa clásica.
4. Es cuestión de **unidades e intención**, no de corrección: `increase(...[7d])` da el número total de eventos (despliegues) en la ventana; dividido por 7 da "despliegues por día", una magnitud entera y directamente legible. `rate()` da eventos **por segundo**; multiplicar por 86400 daría el mismo número pero pasando por una tasa fraccionaria minúscula, más propensa a confusión y a errores de escala al leer el valor crudo.

### Ejercicio 3

1. Porque el TTFD mide el tiempo que un developer pasa peleando con **plumbing** de plataforma (repos, CI, permisos, manifiestos, ingress) antes de entregar valor — exactamente la carga extrínseca que el golden path elimina. Bajar de 102 h a 3.5 h no significa solo "más rápido": significa que el developer ya no necesita **saber ni decidir** todo eso, que es la definición operativa de reducir cognitive load. Velocidad es el efecto; menor carga cognitiva es la causa.
2. **Adoption 100 % + self-service 20 %:** todos usan el template para *nacer*, pero el día a día (bases de datos, secretos, redes) sigue pasando por tickets a humanos — el golden path arranca servicios pero la plataforma no es realmente self-service; el equipo de plataforma sigue siendo cuello de botella. **Adoption baja + self-service alto:** las operaciones puntuales se autoservician bien, pero el camino recomendado para *crear* servicios no convence — hay golden paths compitiendo o mal diseñados, y se acumula divergencia/snowflakes que encarece el mantenimiento futuro.
3. El self-service ratio *anticipa* (leading): mide fricción y autonomía **hoy**, antes de que se traduzca en entregas. Si cae, la plataforma se está volviendo un cuello de botella y las keys DORA empeorarán *después*. Las keys DORA son *lagging*: confirman el resultado (velocidad/estabilidad) una vez que los cambios ya ocurrieron. Medir solo lagging te avisa tarde; el leading te da tiempo de corregir.
4. Se pierde toda la **medición basada en el catálogo**: ownership del servicio, mapeo a equipos, dependencias, y la capacidad de *atribuir* las métricas DORA y de costo a un servicio/owner concreto. Un servicio no registrado es invisible para la plataforma — existe en producción pero no en ninguna métrica de valor. Por eso el `catalog:register` es parte del golden path, no un opcional.

### Ejercicio 4

1. Porque miden capas distintas de la misma realidad y cada una tiene un punto ciego. **DORA** mide el *resultado del sistema de entrega* (flujo y estabilidad) pero no dice *por qué* ni cómo se sienten las personas. **SPACE** amplía a satisfacción, comunicación y eficiencia, evitando reducir productividad a una sola cifra. **DevEx** captura la *percepción* de fricción (feedback loops, carga cognitiva, flujo) que precede y explica a las otras dos. Un DORA excelente con DevEx pésimo señala burnout inminente; un DevEx bueno con DORA pobre señala un cuello estructural fuera del control del developer. Triangular es la única forma de no engañarse.
2. Si `cognitive_load = 2.9` se interpretara como "mayor es peor", sumarlo con el resto (donde mayor es mejor) mezclaría escalas opuestas: una plataforma con carga cognitiva altísima (valor bruto alto) inflaría el índice y *parecería* mejor. Invertir primero garantiza que las tres dimensiones apunten en el mismo sentido ("más = mejor") antes de ponderar; sin eso el índice es incoherente.
3. Le falta el **cierre automático del feedback loop**: en *Optimizing* las métricas no solo guían decisiones humanas de roadmap (eso ya es *Scalable*), sino que disparan mejora continua semiautomática — SLOs que ajustan el sistema, experimentos A/B de plataforma, detección y remediación de regresiones de DevEx sin intervención manual. En *Scalable* la medición **informa**; en *Optimizing* la medición **actúa**.
4. Porque *Activity* mide **volumen de output**, no **valor ni resultado**, y es trivialmente gameable: más commits/PRs pueden significar peor batching, más churn o trabajo troceado artificialmente, no más valor. Usada por persona, incentiva optimizar la métrica (partir PRs, commits vacíos) y penaliza trabajo de alto valor pero bajo volumen (mentoring, diseño, borrar código). SPACE la admite **solo agregada y triangulada** con las otras dimensiones, nunca como KPI individual.

### Ejercicio 5

1. El cálculo omite, entre otras: (a) el valor de la **reducción de CFR / menor MTTR** — cada incidente evitado ahorra horas de firefighting y pérdida de ingresos por downtime; (b) el **TTFD** — 29× más rápido para poner un servicio nuevo en producción (Ejercicio 3) es time-to-market que no aparece acá; (c) el trabajo del **equipo de plataforma liberado** por el self-service ratio (75 %), que antes se consumía en tickets; (d) el valor de **retención/menor burnout** implícito en un mejor DevEx (Ejercicio 4). El 153 % es por eso un **piso**, no una estimación central.
2. Porque el ROI puntual depende de un `loaded_hourly_rate` que finanzas puede discutir como "optimista". El break-even invierte el argumento: en vez de defender un número, mostrás que la plataforma es rentable **para cualquier rate por encima de US$37.50/h** — un umbral que cualquier ingeniero de software supera holgadamente. Convertís un debate sobre supuestos en una afirmación robusta a los supuestos; es mucho más difícil de refutar.
3. Porque `cost_per_deployment` premia **deployar más**, aunque esos deploys sean triviales, riesgosos o rotos — es directamente gameable inflando el denominador. Aislada, incentiva volumen sobre valor y puede empeorar la estabilidad. Hay que aparearla **siempre con el Change Failure Rate** (y idealmente con Recovery Time): "cost per *successful* deployment" o costo por deploy junto a CFR asegura que el abaratamiento no venga de romper producción más seguido.
4. Porque los recursos compartidos no tienen un dueño único: el ingress controller, la stack de observabilidad o el control plane sirven a *todos* los servicios, y **cómo se reparte** ese costo (por request, por namespace, por CPU/memoria, a partes iguales) cambia radicalmente el `infra_monthly` imputado a la plataforma — y por lo tanto el ROI. Es la cifra más disputable porque es una **decisión de allocation**, no una medición directa: dos métodos de reparto defendibles pueden dar costos que difieren en 2–3×, y el resultado del ROI hereda esa incertidumbre. Por eso hay que declarar explícitamente el método de allocation junto al número.

</details>

---

### Fuentes

- CNCF Platforms White Paper — *TAG App Delivery, Platforms WG*: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- CNCF Platform Engineering Maturity Model (aspecto *Measurement* y niveles Provisional→Optimizing): https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- DORA — *Four Keys* y State of DevOps benchmarks: https://dora.dev/guides/dora-metrics-four-keys/ · https://dora.dev/
- *Four Keys* (proyecto de referencia para instrumentar DORA): https://github.com/dora-team/fourkeys
- N. Forsgren et al., *The SPACE of Developer Productivity* — ACM Queue: https://queue.acm.org/detail.cfm?id=3454124
- A. Noda et al., *DevEx: What Actually Drives Productivity* — ACM Queue: https://queue.acm.org/detail.cfm?id=3595878
- Team Topologies — *Platform as a Product* y cognitive load: https://teamtopologies.com/key-concepts
- Backstage Software Templates (Scaffolder): https://backstage.io/docs/features/software-templates/
- OpenCost (allocation de costos en Kubernetes): https://www.opencost.io/docs/
- Prometheus — recording & alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/