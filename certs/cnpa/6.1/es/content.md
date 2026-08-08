# 6.1 Platform Efficiency, Product Value, and Team Productivity

> **Dominio:** Platform Engineering Core Fundamentals · **Peso:** 4.0 · **Examen:** CNPA 2025-04-01
> **Perfil:** este módulo cierra el bucle de "Platform as a Product": una vez que la plataforma existe, hay que **demostrar que genera valor**. Sin medición, la plataforma es indistinguible de un centro de costos y es la primera línea que se recorta en el próximo ejercicio presupuestario.

---

## 1. El problema arquitectónico: la plataforma como centro de costos vs. como producto

Una Internal Developer Platform (IDP) es una inversión permanente: un equipo dedicado (típicamente 4–8 personas), un stack de control plane (Kubernetes, Argo CD, Backstage, Crossplane, observabilidad) y un costo de infraestructura que crece con la adopción. Ese gasto es **visible y concentrado**; el retorno es **difuso y diferido** — se manifiesta como velocidad de decenas de stream-aligned teams que *no* están en tu organigrama.

Esta asimetría produce el **cost-center trap**:

```
Costo de la plataforma      → concentrado, mensual, fácil de ver en la factura cloud
Valor de la plataforma      → distribuido en N equipos, medido en lead time evitado,
                              incidentes no ocurridos, onboarding acelerado
```

Cuando llega el recorte, quien no puede cuantificar el segundo término pierde. La disciplina de este tema es **convertir el valor difuso en evidencia defendible**, sin caer en vanity metrics.

### 1.1 Las tres lentes del valor

El título del tema no es casual: son tres preguntas técnicas distintas, con instrumentación distinta.

| Lente | Pregunta | Naturaleza de la métrica | Fuente de datos |
|---|---|---|---|
| **Efficiency** | ¿La plataforma produce entrega por unidad de gasto? | Económica / operativa (lagging) | CI/CD events, cost allocation, utilización de recursos |
| **Product Value** | ¿Los equipos la usan y les resuelve el problema? | Adopción / outcome (mixta) | Catálogo, golden path coverage, self-service ratio, NPS |
| **Team Productivity** | ¿Reduce la carga cognitiva y acelera el flujo? | Socio-técnica (leading + perceptual) | DORA, SPACE, DevEx, surveys |

El error clásico es medir solo la primera (es la más fácil, sale de la factura) y declarar victoria o derrota con datos incompletos.

### 1.2 El fundamento teórico: carga cognitiva (Team Topologies)

El *por qué* existe una plataforma, en el marco de **Team Topologies** (Skelton & Pais), es reducir la **extraneous cognitive load** de los stream-aligned teams para que puedan gastar su capacidad en **intrinsic** (el dominio de negocio) y **germane** (aprendizaje productivo) load.

- **Intrinsic**: la complejidad esencial del problema (ej.: reglas de facturación). No se puede eliminar.
- **Extraneous**: la complejidad del *entorno* (ej.: escribir manifiestos de Kubernetes desde cero, configurar TLS, cablear un pipeline). **Esto es lo que la plataforma absorbe.**
- **Germane**: el esfuerzo de construir modelos mentales útiles.

Una plataforma que funciona se ofrece como **X-as-a-Service** (modo de interacción de Team Topologies) sobre una **Thinnest Viable Platform (TVP)**: lo mínimo que reduce carga sin volverse ella misma una fuente de carga extraneous. La métrica de productividad, entonces, mide indirectamente si ese contrato se está cumpliendo.

> **Antipatrón:** una plataforma que *agrega* carga cognitiva (una abstracción con fugas, un YAML propietario más complejo que el de Kubernetes puro, un portal que hay que aprender además de todo lo demás). Los números de adopción lo delatan antes que las quejas.

---

## 2. Marcos de medición: comparativa técnica

No hay una única métrica. Hay tres marcos maduros, complementarios, con propósitos distintos. Elegir uno solo es un error de diseño.

| Marco | Qué mide | Dimensiones | Naturaleza | Riesgo de mal uso |
|---|---|---|---|---|
| **DORA** | Rendimiento de *delivery* | 4 keys + Reliability | Cuantitativa, system-based | Alto: fácil de gamificar (deploys triviales) |
| **SPACE** | Productividad *multidimensional* | Satisfaction, Performance, Activity, Communication, Efficiency | Mixta (system + perceptual) | Medio: exige ≥2 dimensiones para ser válida |
| **DevEx** | *Experiencia* del desarrollador | Feedback loops, Cognitive load, Flow state | Perceptual + workflow + KPI | Bajo si se combinan las tres capas |

### 2.1 DORA — las cuatro keys (+ una)

Del *State of DevOps Report* / DevOps Research and Assessment. Dos métricas de **throughput** y dos de **stability**; el hallazgo central de DORA es que **no hay trade-off**: los equipos elite puntúan alto en las cuatro simultáneamente.

| Métrica | Definición operativa | Tipo |
|---|---|---|
| **Deployment Frequency** | Nº de despliegues a producción por unidad de tiempo | Throughput |
| **Lead Time for Changes** | Tiempo desde el commit hasta que corre en producción | Throughput |
| **Change Failure Rate (CFR)** | % de despliegues que degradan el servicio y requieren remediación | Stability |
| **Failed Deployment Recovery Time** | Tiempo para restaurar el servicio tras un despliegue fallido (antes "MTTR"/Time to Restore) | Stability |
| **Reliability** *(5ª, 2021+)* | Cumplimiento de objetivos operativos (SLOs) | Operativa |

**Clusters de referencia** (aproximados; DORA reajusta los umbrales cada año — usar como orientación, no como dogma):

| Métrica | Elite | High | Medium | Low |
|---|---|---|---|---|
| Deployment Frequency | On-demand (varios/día) | 1/día – 1/semana | 1/sem – 1/mes | < 1/mes |
| Lead Time for Changes | < 1 día | 1 día – 1 semana | 1 sem – 1 mes | > 1 mes |
| Change Failure Rate | 0–15% | 16–30% | 16–30% | > 30% |
| Recovery Time | < 1 hora | < 1 día | 1 día – 1 semana | > 1 semana |

> **Advertencia (Goodhart's Law):** *"When a measure becomes a target, it ceases to be a good measure."* Deployment Frequency subordinada como objetivo produce deploys artificiales sin valor. DORA solo es válida a nivel de **equipo/servicio**, nunca de **individuo**, y las cuatro deben leerse **juntas** — subir throughput mientras CFR se dispara es una regresión, no una mejora.

### 2.2 SPACE — contra la métrica única

De *"The SPACE of Developer Productivity"* (Forsgren, Storey, Maddila, Zimmermann, Butler, Houck — ACM Queue, 2021). Su tesis central: la productividad **no es unidimensional** y no se puede reducir a "líneas de código" o "commits".

- **S**atisfaction and well-being — encuestas (eNPS, burnout).
- **P**erformance — resultado, no output (ej.: calidad, ausencia de defectos).
- **A**ctivity — conteos (deploys, PRs) — el único observable "barato", y el más peligroso solo.
- **C**ommunication and collaboration — tiempo de review, calidad de la documentación.
- **E**fficiency and flow — interrupciones, tiempo en flow, handoffs.

**Regla de implementación:** capturar **al menos dos o tres dimensiones**, mezclando métricas de sistema con perceptuales, y **jamás** usarlas para stack-ranking de personas.

### 2.3 DevEx — feedback, carga cognitiva, flow

De *"DevEx: What Actually Drives Productivity"* (Noda, Storey, Forsgren, Greiler — ACM Queue, 2023). Operacionaliza la carga cognitiva de la sección 1.2 en tres dimensiones medibles en tres capas (perceptions / workflows / KPIs):

| Dimensión | Señal de plataforma sana | Señal de fricción |
|---|---|---|
| **Feedback loops** | CI < 10 min, preview envs en minutos | esperar 40 min por un pipeline para saber si rompiste algo |
| **Cognitive load** | golden path autoexplicado, `scaffold` en 1 comando | 300 líneas de YAML copiadas de otro repo |
| **Flow state** | despliegue self-service sin ticket | esperar aprobación humana de ops para cada cambio |

**Síntesis operativa:** DORA da la foto de *delivery* (barata, automatizable, la que va al board), DevEx explica el *por qué* de esa foto (perceptual, la que guía el roadmap de la plataforma), y SPACE es el paraguas que impide reducir todo a una sola cifra.

---

## 3. Instrumentación de DORA en producción (CNCF-native)

El patrón de referencia es un **pipeline de eventos**: cada evento de CI/CD y cada incidente se normaliza en un event store, del que se derivan las cuatro keys. Google publicó la arquitectura canónica ("Four Keys"); acá la reconstruimos con componentes CNCF y Prometheus, que es lo que un stack de plataforma ya tiene desplegado.

```
┌──────────────┐   webhook    ┌───────────────┐   /metrics   ┌────────────┐
│ CI (Actions, │─────────────▶│ dora-exporter │◀─────────────│ Prometheus │
│  Argo CD,    │   deploy/     │ (normaliza a  │   scrape     │ (recording │
│  Rollouts)   │   incident    │  counters +   │              │  rules)    │
└──────────────┘   events      │  histograms)  │              └─────┬──────┘
        ▲                      └───────────────┘                    │
        │ incident close (recovery)                                 ▼
┌──────────────┐                                             ┌────────────┐
│ Alertmanager │                                             │  Grafana   │
│ / on-call    │                                             │ (dashboard)│
└──────────────┘                                             └────────────┘
```

Dos decisiones de diseño clave:

1. **Deployment Frequency** y **CFR** se modelan como `counter` con labels `service`, `team`, `env`, `outcome`.
2. **Lead Time** y **Recovery Time** se modelan como `histogram` (con buckets), porque las medianas y percentiles son lo que importa; un promedio esconde la cola.

### 3.1 Reglas de grabado (PrometheusRule)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # descubierto por el operator vía ruleSelector
    role: dora
spec:
  groups:
    - name: dora.deployment_frequency
      interval: 1m
      rules:
        # deployment_total lo incrementa dora-exporter en cada rollout exitoso a prod
        - record: dora:deployment_frequency:per_day_7d
          expr: |
            sum by (service, team) (
              increase(deployment_total{env="production"}[7d])
            ) / 7
        - record: dora:deployment_frequency:daily
          expr: |
            sum by (service, team) (
              increase(deployment_total{env="production"}[1d])
            )

    - name: dora.lead_time
      interval: 1m
      rules:
        # deployment_lead_time_seconds = (deploy_ts - first_commit_ts) observado al desplegar
        - record: dora:lead_time_seconds:p50
          expr: |
            histogram_quantile(0.50,
              sum by (le, service, team) (
                rate(deployment_lead_time_seconds_bucket{env="production"}[7d])
              )
            )
        - record: dora:lead_time_seconds:p90
          expr: |
            histogram_quantile(0.90,
              sum by (le, service, team) (
                rate(deployment_lead_time_seconds_bucket{env="production"}[7d])
              )
            )

    - name: dora.change_failure_rate
      interval: 1m
      rules:
        # clamp_min evita la división por cero cuando no hubo deploys en la ventana
        - record: dora:change_failure_rate:ratio_7d
          expr: |
            sum by (service, team) (
              increase(deployment_total{env="production", outcome="failed"}[7d])
            )
            /
            clamp_min(
              sum by (service, team) (
                increase(deployment_total{env="production"}[7d])
              ), 1
            )

    - name: dora.recovery_time
      interval: 1m
      rules:
        # deployment_recovery_seconds se observa al cerrar el incidente ligado a un deploy fallido
        - record: dora:recovery_seconds:p50
          expr: |
            histogram_quantile(0.50,
              sum by (le, service, team) (
                rate(deployment_recovery_seconds_bucket{env="production"}[30d])
              )
            )
```

### 3.2 Descubrimiento del exporter (ServiceMonitor)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dora-exporter
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: dora-exporter
  namespaceSelector:
    matchNames:
      - platform-metrics
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      scheme: http
```

### 3.3 Atajo CNCF-native: derivar deployment frequency de Argo CD

Si ya usás GitOps, **Argo CD ya emite las señales**: cada sync exitoso es un deploy. No hace falta esperar el exporter para tener la primera key.

```promql
# Deployment frequency directo del controller de Argo CD
sum by (name) (
  increase(argocd_app_sync_total{phase="Succeeded"}[1d])
)
```

Y **Argo Rollouts** aporta CFR sin instrumentación adicional: una `AnalysisRun` que falla y dispara un `abort`/rollback es, por definición, un change failure.

```promql
# Proxy de CFR desde Argo Rollouts
sum(increase(rollout_events_total{type="Warning", reason="RolloutAborted"}[7d]))
/
clamp_min(sum(increase(argocd_app_sync_total{phase="Succeeded"}[7d])), 1)
```

### 3.4 Lead Time: correlacionar git con el evento de deploy

El cálculo real que hace el exporter al recibir el webhook de deploy: `deploy_ts - first_commit_ts` del cambio desplegado.

```console
$ # timestamp del deploy = ahora (lo pone el webhook receiver)
$ DEPLOY_TS=$(date -u +%s)

$ # primer commit del rango desplegado (desde el SHA anterior en prod hasta el nuevo)
$ git log --reverse --pretty='%H %ct' v1.4.2..v1.5.0 | head -1
7a1c9e4b0f2d8a3c5e6f1a2b3c4d5e6f7a8b9c0d 1754500800

$ FIRST_COMMIT_TS=1754500800
$ echo "lead_time_seconds=$((DEPLOY_TS - FIRST_COMMIT_TS))"
lead_time_seconds=27540      # ≈ 7.65 h  → cluster High/Elite
```

### 3.5 OpenTelemetry para observabilidad de CI/CD

La ruta moderna: OpenTelemetry publica **semantic conventions para CI/CD** (`cicd.pipeline.*`, `cicd.pipeline.run.duration`), lo que estandariza los eventos de pipeline como traces/metrics en vez de webhooks ad-hoc. El collector actúa como el normalizador:

```yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  batch: {}
  # deriva un histograma de lead time a partir de spans del pipeline
  transform:
    metric_statements:
      - context: datapoint
        statements:
          - set(attributes["team"], resource.attributes["service.namespace"])

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [transform, batch]
      exporters: [prometheus]
```

---

## 4. Efficiency: cost allocation con OpenCost (FinOps)

La lente de eficiencia responde: *¿cuánto cuesta la unidad de valor que entrega la plataforma?* El estándar CNCF es **OpenCost** (la especificación abierta de cost allocation de Kubernetes, base de Kubecost), que atribuye costo de CPU/memoria/almacenamiento/red por namespace, deployment, label o equipo — usando datos de Prometheus.

### 4.1 Instalación (Helm) con conexión a Prometheus existente

```console
$ helm repo add opencost https://opencost.github.io/opencost-helm-chart
$ helm repo update
$ helm upgrade --install opencost opencost/opencost \
    --namespace opencost --create-namespace \
    --set opencost.prometheus.internal.enabled=false \
    --set opencost.prometheus.external.enabled=true \
    --set opencost.prometheus.external.url="http://kube-prometheus-stack-prometheus.monitoring:9090"
Release "opencost" has been upgraded. Happy Helming!
NAME: opencost
STATUS: deployed
REVISION: 1
```

### 4.2 Consultar la asignación de costos por equipo

OpenCost expone una API HTTP; el costo por namespace en los últimos 7 días:

```console
$ kubectl -n opencost port-forward svc/opencost 9003:9003 >/dev/null 2>&1 &
$ curl -sG 'http://localhost:9003/allocation/compute' \
    --data-urlencode 'window=7d' \
    --data-urlencode 'aggregate=namespace' \
    --data-urlencode 'accumulate=true' | \
  jq -r '.data[0] | to_entries[] | [.key, (.value.totalCost|round)] | @tsv' | sort -k2 -rn | head
team-payments      412
team-checkout      287
platform-system    193
team-search        141
opencost            6
```

Lectura de plataforma: `platform-system` cuesta 193 USD/sem y **habilita** los 840 USD/sem de los equipos de negocio; ese ratio (1:4.3) es tu argumento de eficiencia ante finanzas — showback en acción.

### 4.3 Resource efficiency: el desperdicio oculto

La eficiencia no es solo costo total, sino **utilización**: requests infladas que reservan capacidad que nadie usa. El desperdicio es la diferencia entre lo reservado y lo consumido.

```promql
# CPU efficiency por namespace = uso real / requests reservadas (0..1; <0.4 = sobre-aprovisionado)
sum by (namespace) (
  rate(container_cpu_usage_seconds_total{container!="", namespace=~"team-.*"}[5d])
)
/
clamp_min(
  sum by (namespace) (
    kube_pod_container_resource_requests{resource="cpu", namespace=~"team-.*"}
  ), 0.001
)
```

```console
$ promtool query instant http://localhost:9090 \
  'sum by (namespace)(rate(container_cpu_usage_seconds_total{namespace="team-payments"}[5d]))
   / clamp_min(sum by (namespace)(kube_pod_container_resource_requests{resource="cpu",namespace="team-payments"}),0.001)'
{namespace="team-payments"} => 0.31 @[1754570400]
```

CPU efficiency de 0.31 → el equipo reserva 3× lo que usa. La plataforma aporta valor de eficiencia **automatizando** el ajuste (VPA en modo recomendación como golden path), no mandando un mail.

### 4.4 Trade-off: showback vs. chargeback

| Modelo | Mecánica | Cuándo | Riesgo |
|---|---|---|---|
| **Showback** | Se *muestra* el costo por equipo, sin facturar | Fase de adopción, cultura de responsabilidad naciente | Se ignora si no hay incentivo |
| **Chargeback** | Se *factura* el costo al presupuesto del equipo | Organización madura, cost-consciousness alta | Perverso si es prematuro: los equipos evitan la plataforma para esquivar el cargo |

> Regla de secuencia: **showback primero, siempre**. Chargeback antes de que exista confianza en los datos empuja a los equipos *fuera* de la plataforma — mata la adopción, que es la métrica de la sección 5.

---

## 5. Product Value: adopción y golden path coverage (Backstage)

Efficiency mide el costo; **product value** mide si alguien lo usa. Una plataforma técnicamente impecable con 2 equipos adoptados fracasó como producto. El instrumento natural es el **Software Catalog de Backstage** (proyecto CNCF), que ya es el inventario de servicios; sobre él se miden adopción y cumplimiento de golden paths con el plugin **Tech Insights** (Scorecards).

### 5.1 Métricas de product value

| Métrica | Definición | Fuente |
|---|---|---|
| **Adoption rate** | servicios en la plataforma / servicios totales | Catálogo |
| **Self-service ratio** | acciones sin ticket humano / acciones totales | Scaffolder / audit log |
| **Golden path coverage** | componentes que pasan el scorecard / total | Tech Insights |
| **Time to first deploy (TTFD)** | de "template ejecutado" a "corriendo en prod" | Scaffolder + deploy event |
| **Platform NPS / eNPS** | ¿recomendarías la plataforma? | Encuesta |

### 5.2 Componente en el catálogo con anotaciones de medición

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payments-api
  annotations:
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: payments-api-prod
    prometheus.io/service-name: payments-api
    # marca de adopción: creado desde un golden path, no a mano
    platform.internal/created-from-template: "grpc-service-v3"
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: payments
```

### 5.3 Scorecard: golden path coverage como check ejecutable

Definición de un check de Tech Insights que un servicio "aprueba" si cumple el golden path (tiene owner, SLO, y se creó desde un template):

```yaml
# app-config.yaml — sección techInsights
techInsights:
  factRetrievers:
    entityMetadataFactRetriever:
      cadence: "*/15 * * * *"   # cada 15 min
  checks:
    - id: golden-path-compliance
      type: json-rules-engine
      name: Golden Path Compliance
      description: El componente cumple el golden path de la plataforma
      factIds:
        - entityMetadataFactRetriever
        - entityOwnershipFactRetriever
      rule:
        conditions:
          all:
            - fact: hasOwner
              operator: equal
              value: true
            - fact: hasAnnotationCreatedFromTemplate
              operator: equal
              value: true
            - fact: hasSlo
              operator: equal
              value: true
```

### 5.4 Consultar adopción (script real contra la API del catálogo)

```console
$ TOTAL=$(curl -s "http://backstage:7007/api/catalog/entities?filter=kind=component" \
    -H "Authorization: Bearer $TOKEN" | jq 'length')
$ FROMTPL=$(curl -s "http://backstage:7007/api/catalog/entities?filter=kind=component,metadata.annotations.platform.internal/created-from-template" \
    -H "Authorization: Bearer $TOKEN" | jq 'length')
$ echo "adoption=$(awk "BEGIN{printf \"%.1f%%\", $FROMTPL/$TOTAL*100}") ($FROMTPL/$TOTAL)"
adoption=64.0% (48/75)
```

64% de los servicios nacieron de un golden path. Es la métrica que, subiendo trimestre a trimestre, justifica la existencia del equipo de plataforma mejor que cualquier tabla de costos.

---

## 6. Team Productivity: cerrar el bucle sin gamificar

Aquí es donde la ingeniería se cruza con lo socio-técnico. Las métricas de sistema (DORA) se combinan con las **perceptuales** (SPACE/DevEx) porque ninguna de las dos sola es suficiente: los números dicen *qué* pasa, las encuestas dicen *por qué*.

### 6.1 North Star y leading vs. lagging

- **Lagging indicators** (resultado, tarde para actuar): DORA lead time, CFR, costo.
- **Leading indicators** (predictivos, accionables ya): CI duration, cognitive-load survey score, self-service ratio, tamaño de PR.

Un buen tablero de plataforma pone **una North Star** (ej.: *"lead time del cambio p90 por equipo"*) rodeada de leading indicators que la explican. La North Star no puede ser Activity (deploys/commits): es la puerta de entrada a Goodhart.

### 6.2 Encuesta DevEx como código (fuente de datos perceptual)

```yaml
# devex-survey.yaml — pulso trimestral, correlacionado con las métricas de sistema por equipo
survey:
  cadence: quarterly
  scale: 1-5   # Likert
  dimensions:
    feedback_loops:
      - "Recibo feedback de CI en un tiempo que no me saca del flow."
      - "Puedo probar mi cambio en un entorno realista sin pedir ayuda."
    cognitive_load:
      - "Entiendo cómo desplegar un servicio nuevo sin consultar a otra persona."
      - "El YAML/configuración que mantengo es proporcional al problema que resuelve."
    flow_state:
      - "Puedo desplegar a producción sin esperar aprobaciones manuales."
      - "Las interrupciones no planificadas por temas de infraestructura son raras."
  anti_metrics:            # explícitamente prohibido derivar
    - individual_ranking
    - lines_of_code
    - commits_per_person
```

### 6.3 Antipatrones (los que carga el examen y la realidad)

| Antipatrón | Por qué falla | Corrección |
|---|---|---|
| Métrica única (deploys/día) | Goodhart: se gamifica trivialmente | ≥2 dimensiones (SPACE) |
| DORA por individuo | Destruye colaboración; mide ruido | Solo a nivel equipo/servicio |
| Vanity metrics (nº de features del portal) | Miden actividad de la plataforma, no valor entregado | Medir *outcomes* del consumidor |
| Chargeback prematuro | Expulsa a los equipos de la plataforma | Showback hasta que haya confianza |
| Medir solo costo | Ignora product value y productivity | Las tres lentes juntas |
| Encuesta sin acción | Erosiona la confianza; nadie vuelve a responder | Cerrar el loop: mostrar qué cambió |

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Validar que las recording rules cargan y evalúan

```console
$ promtool check rules dora-metrics.yaml
Checking dora-metrics.yaml
  SUCCESS: 8 rules found

$ # ¿el operator las cargó?
$ kubectl -n monitoring get prometheusrule dora-metrics -o jsonpath='{.metadata.name}{"\n"}'
dora-metrics

$ # ¿evalúan sin error? (deben aparecer en la API de rules de Prometheus)
$ curl -s http://localhost:9090/api/v1/rules | \
    jq -r '.data.groups[].rules[] | select(.name|startswith("dora:")) | "\(.name) health=\(.health)"'
dora:deployment_frequency:per_day_7d health=ok
dora:lead_time_seconds:p50          health=ok
dora:change_failure_rate:ratio_7d   health=ok
dora:recovery_seconds:p50           health=ok
```

### 7.2 Diagnóstico: la serie DORA está vacía

**Síntoma:** `dora:deployment_frequency:daily` devuelve `no data`.

```console
$ # 1) ¿el target del exporter está UP?
$ curl -s http://localhost:9090/api/v1/targets | \
    jq -r '.data.activeTargets[] | select(.labels.job|test("dora")) | "\(.scrapeUrl) \(.health)"'
http://10.42.3.17:8080/metrics up

$ # 2) ¿la métrica cruda existe? (si NO, el problema es el exporter/webhook, no la regla)
$ promtool query instant http://localhost:9090 'deployment_total'
(empty)                       # ← el counter nunca se incrementó: ningún webhook llegó
```

**Árbol de decisión:**

| Observación | Causa probable | Acción |
|---|---|---|
| Target `down` | ServiceMonitor no matchea labels del Service | Alinear `selector.matchLabels` con las labels reales del Service |
| Target `up`, `deployment_total` vacío | El CI no dispara el webhook / receiver caído | Revisar logs del exporter; probar el webhook con `curl` manual |
| Métrica cruda existe, regla vacía | El label de agrupación (`service`,`team`) no está en la serie | Ajustar `sum by(...)` o agregar el label en el exporter |
| `histogram_quantile` da `NaN` | No hay `_bucket` con `le` o rate sobre ventana sin muestras | Verificar que se emiten buckets; ampliar la ventana `[7d]` |
| CFR = 1.0 constante | `clamp_min` ausente y denominador 0 en despliegues escasos | Confirmar el `clamp_min(...,1)` de la regla |

### 7.3 Diagnóstico: OpenCost devuelve costo 0 o vacío

```console
$ kubectl -n opencost logs deploy/opencost -c opencost | grep -iE 'prometheus|error' | tail
ERR Failed to query Prometheus: dial tcp: lookup prometheus-server on 10.43.0.10:53: no such host
```

Causa clásica: URL de Prometheus mal apuntada (nombre de Service/namespace incorrecto). El costo depende **enteramente** de que OpenCost pueda leer `container_cpu_allocation` y métricas de nodo de Prometheus.

```console
$ # verificar conectividad desde el pod de opencost
$ kubectl -n opencost exec deploy/opencost -c opencost -- \
    wget -qO- http://kube-prometheus-stack-prometheus.monitoring:9090/-/healthy
Prometheus Server is Healthy.

$ # verificar que existen las métricas que OpenCost necesita
$ promtool query instant http://localhost:9090 'count(node_cpu_hourly_cost)'
{} => 6 @[1754570400]        # 0 aquí = falta node-exporter/kube-state-metrics
```

### 7.4 Sanity check de coherencia (Goodhart guard)

Antes de reportar un número al negocio, cruzarlo contra su métrica de estabilidad hermana. Un tablero honesto **nunca** muestra throughput sin stability al lado.

```console
$ # regla de oro: si la frecuencia de deploy sube pero CFR también, NO es una mejora
$ promtool query instant http://localhost:9090 \
    'dora:deployment_frequency:per_day_7d{team="payments"}'
{service="payments-api",team="payments"} => 4.3 @[...]

$ promtool query instant http://localhost:9090 \
    'dora:change_failure_rate:ratio_7d{team="payments"}'
{service="payments-api",team="payments"} => 0.08 @[...]   # 8% → estable: la mejora es real
```

### 7.5 Tablero como código (ConfigMap con sidecar de Grafana)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dora-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # el sidecar de Grafana lo auto-descubre
data:
  dora.json: |
    {
      "title": "Platform Value — DORA",
      "schemaVersion": 39,
      "panels": [
        {
          "type": "stat",
          "title": "Deployment Frequency (per day, 7d)",
          "gridPos": {"h": 6, "w": 8, "x": 0, "y": 0},
          "targets": [
            {"expr": "sum(dora:deployment_frequency:per_day_7d)", "refId": "A"}
          ]
        },
        {
          "type": "timeseries",
          "title": "Change Failure Rate by team",
          "gridPos": {"h": 6, "w": 16, "x": 8, "y": 0},
          "targets": [
            {"expr": "dora:change_failure_rate:ratio_7d", "legendFormat": "{{team}}", "refId": "A"}
          ]
        }
      ]
    }
```

```console
$ # validar el JSON embebido antes de aplicar (falla frecuente: coma colgante)
$ kubectl create configmap dora-dashboard --from-file=dora.json --dry-run=client -o yaml | \
    yq '.data."dora.json"' | jq empty && echo "JSON válido"
JSON válido
```

---

## 8. Referencias

- **CNPA Curriculum** — CNCF: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **DORA — DevOps Research and Assessment** (métricas y clusters): https://dora.dev/
- **DORA — Guía de las cuatro keys**: https://dora.dev/guides/dora-metrics-four-keys/
- **Four Keys (implementación de referencia, Google)**: https://github.com/dora-team/fourkeys
- **The SPACE of Developer Productivity** (ACM Queue): https://queue.acm.org/detail.cfm?id=3454124
- **DevEx: What Actually Drives Productivity** (ACM Queue): https://queue.acm.org/detail.cfm?id=3595878
- **Team Topologies**: https://teamtopologies.com/key-concepts
- **CNCF Platforms White Paper**: https://tag-app-delivery.cncf.io/whitepapers/platforms/
- **CNCF Platform Engineering Maturity Model**: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- **OpenCost (spec y proyecto CNCF)**: https://www.opencost.io/docs/
- **OpenCost API — Allocation**: https://www.opencost.io/docs/integrations/api
- **Backstage — Software Catalog**: https://backstage.io/docs/features/software-catalog/
- **Backstage — Tech Insights (Scorecards)**: https://backstage.io/docs/features/tech-insights/
- **Argo CD — Metrics**: https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- **Argo Rollouts — Analysis**: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- **Prometheus Operator — PrometheusRule**: https://prometheus-operator.dev/docs/developer/alerting/
- **OpenTelemetry — CI/CD Semantic Conventions**: https://opentelemetry.io/docs/specs/semconv/cicd/
- **FinOps Foundation — Kubernetes**: https://www.finops.org/framework/