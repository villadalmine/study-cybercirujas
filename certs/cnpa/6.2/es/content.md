# Tema 6.2 — DORA Metrics and Indicators for Platform Initiatives

> **Perfil:** Platform Architect / SRE Senior · **Peso en examen CNPA:** 4.0 · **Versión de examen:** 2025-04-01
>
> **Tesis central:** las DORA metrics no son un dashboard, son un *pipeline de datos con problema de atribución*. En una Internal Developer Platform (IDP) el reto no es calcular cuatro números, sino **atribuir** el rendimiento de entrega a la plataforma, por equipo, por servicio y por entorno, extrayendo eventos de sistemas heterogéneos (git, CI, CD/GitOps, incident management) sin instrumentar a mano cada stream team.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 Qué mide DORA y por qué le importa a una plataforma

DORA (**DevOps Research and Assessment**, el programa de investigación de Google Cloud, hoy en `dora.dev`) publica desde 2014 el *Accelerate State of DevOps Report*. De su análisis estadístico salen **cuatro métricas** que discriminan a los equipos de alto y bajo rendimiento, agrupadas en dos ejes:

| Eje | Métrica DORA (nombre 2024) | Nombre histórico | Pregunta que responde |
|---|---|---|---|
| **Throughput** (velocidad) | **Deployment Frequency** (DF) | — | ¿Con qué frecuencia desplegamos a producción? |
| **Throughput** | **Lead Time for Changes** (LTC) | Change lead time | ¿Cuánto tarda un `commit` en llegar a producción? |
| **Stability** (estabilidad) | **Change Failure Rate** (CFR) | — | ¿Qué porcentaje de deploys causa una degradación que requiere remediación? |
| **Stability** | **Failed Deployment Recovery Time** (FDRT) | Time to Restore Service / MTTR | ¿Cuánto tardamos en recuperarnos de un deploy fallido? |

> **Precisión terminológica (relevante para el examen):** en 2024 DORA renombró *Time to Restore Service* → **Failed Deployment Recovery Time** para desambiguar de la recuperación ante incidentes no ligados a un cambio. Evitá "MTTR" en material nuevo: MTTR mezcla mean-time-to-*acknowledge*, *detect* y *recover*, y DORA mide específicamente la recuperación de un **deployment fallido**. Desde 2021 el modelo añade una quinta señal de fiabilidad operacional (**Reliability**, basada en SLO), pero **no** es una de "las cuatro" — es un modificador de contexto.

**Por qué a una Platform Initiative:** el paradigma *platform-as-a-product* (Dominio 1 del CNPA) exige justificar la inversión en la IDP con evidencia. Las DORA metrics son el proxy estándar del *outcome* que la plataforma promete: reducir el `lead time` con golden paths, subir la `deployment frequency` con self-service CD, bajar el `CFR` con progressive delivery, y acortar el `FDRT` con rollbacks automáticos. La plataforma es el **tratamiento**; las DORA metrics son la **variable de resultado**.

### 1.2 El problema arquitectónico real: atribución, no cálculo

Calcular DF para *un* servicio es trivial: contar deploys / tiempo. El problema de producción aparece cuando la plataforma sirve a decenas de stream teams:

1. **Fuentes heterogéneas y correlación de eventos.** Ningún sistema conoce las cuatro métricas. El `lead time` necesita casar un `commit SHA` (git provider) con un `deployment event` (Argo CD / Flux / Tekton) con un `merge time`. El `CFR` y el `FDRT` necesitan casar un `deployment` con un `incident` (PagerDuty / Opsgenie / Alertmanager). **La métrica no existe en ningún origen; nace de la correlación.**

2. **Multi-tenancy y cardinalidad.** Debe segmentarse por `team`, `service`, `environment`. Esto explota la cardinalidad si se modela ingenuamente en Prometheus (una serie por combinación). El anti-patrón clásico: usar `commit_sha` o `deployment_id` como label → cardinalidad ilimitada → OOM del TSDB.

3. **Atribución causal débil (Goodhart's law).** *"When a measure becomes a target, it ceases to be a good measure."* Si el bono del equipo depende de la DF, se fragmentan PRs para inflar el conteo de deploys. Las DORA metrics deben leerse como **sistema balanceado** (throughput vs stability): subir DF bajando CFR es progreso; subir DF *subiendo* CFR es deuda.

4. **Punto de medición del `lead time`.** ¿Se cuenta desde el *first commit*, el *merge a main*, o el *PR open*? DORA define LTC como **first commit → running in production**. Elegir el `merge time` (más fácil de instrumentar) subestima sistemáticamente el lead time y hace incomparables los equipos.

5. **Aislamiento del measurement pipeline.** El sistema que mide la fiabilidad de la entrega no puede caerse cuando cae la entrega. El pipeline de DORA es *observability*, no *control plane* — pero su blast radius y su SLA deben tratarse con el mismo rigor.

### 1.3 Arquitectura de referencia (event-sourced)

```
┌────────────┐   webhooks / CDEvents   ┌──────────────────┐
│ Git (GitHub│──────────────────────► │                  │
│  /GitLab)  │                         │  Event Collector │
├────────────┤   CloudEvents           │  (normaliza a un │      ┌───────────┐
│ CI (Tekton │──────────────────────► │  esquema común)  │────► │ Warehouse │
│  /Actions) │                         │                  │      │ (Postgres/│
├────────────┤   deploy events (Argo)  │  ─ dedupe        │      │ BigQuery) │
│ CD (Argo/  │──────────────────────► │  ─ correlate     │      └─────┬─────┘
│  Flux)     │                         │  ─ attribute     │            │
├────────────┤   incident hooks        │                  │      ┌─────▼─────┐
│ Incident   │──────────────────────► │                  │      │ Metrics   │
│ (PD/Alertmr)│                        └──────────────────┘      │ engine +  │
└────────────┘                                                   │ Grafana   │
                                                                 └───────────┘
```

El *contract* entre productores y colector es lo que hace esto escalable: un **esquema de evento común** (idealmente **CDEvents**, spec de la CNCF/CDF) desacopla los orígenes del motor de métricas.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 DORA vs otros frameworks de medición de plataforma

DORA no vive solo. El examen espera que distingas *qué mide cada marco* y que no los confundas.

| Framework | Qué mide | Unidad de análisis | Fortaleza | Límite |
|---|---|---|---|---|
| **DORA (4 keys)** | Rendimiento de *entrega de software* | Sistema de entrega / servicio | Validado estadísticamente, benchmark externo | No mide developer experience ni carga cognitiva |
| **SPACE** | Productividad multidimensional: **S**atisfaction, **P**erformance, **A**ctivity, **C**ommunication, **E**fficiency | Individuo + equipo | Evita el reduccionismo de una sola métrica | No prescribe métricas concretas; requiere diseño |
| **DevEx (DXI)** | Fricción percibida del developer | Developer | Capta *flow state*, feedback loops, cognitive load | Basado en encuestas (percepción, no telemetría) |
| **Flow metrics** (Flow Framework) | Flujo de valor: Velocity, Time, Efficiency, Load, Distribution | Value stream | Liga entrega a valor de negocio | Requiere modelar el value stream completo |
| **Golden Signals / SLO** | *Salud del sistema en runtime*: latency, traffic, errors, saturation | Servicio en producción | Operacional, tiempo real | No mide velocidad de *entrega* |

> **Regla de examen:** DORA mide **cómo entregás**; los SLO/Golden Signals miden **cómo corre lo entregado**. La quinta métrica DORA (*Reliability*) es el puente: se *deriva* de tus SLO. No mezcles CFR (un cambio degradó producción) con error budget burn (el sistema viola su SLO por cualquier causa).

### 2.2 Estrategias de instrumentación

| Estrategia | Mecanismo | Latencia del dato | Acoplamiento | Cuándo usar |
|---|---|---|---|---|
| **Pull / API polling** | Job periódico consulta APIs de GitHub/Argo/PagerDuty | Minutos–horas | Bajo (no toca pipelines) | Arranque rápido, brownfield, DevLake |
| **Push / webhooks** | Los sistemas emiten webhooks al colector | Segundos | Medio (configurar cada origen) | Near-real-time sin tocar código de app |
| **Event-native (CDEvents/CloudEvents)** | Pipelines emiten eventos tipados | Segundos | Alto (requiere adopción) | Greenfield, plataforma con Tekton/Knative |
| **Log/trace-based (OTel CI/CD)** | Spans de pipeline exportados a un backend | Segundos | Alto | Ya se usa OpenTelemetry end-to-end |

**Trade-off nuclear:** *polling* no requiere que los stream teams cambien nada (ideal para adopción incremental en la plataforma), pero introduce latencia y **ceguera a eventos entre polls** (un deploy y su rollback en el mismo intervalo se pierden). *Event-native* es preciso y en tiempo casi real, pero exige que cada golden path emita eventos — sólo viable si la plataforma **posee** los pipelines.

### 2.3 Build vs Buy para el motor de DORA

| Solución | Tipo | Modelo de datos | Correlación incidente↔deploy | Coste operativo | Multi-tenant |
|---|---|---|---|---|---|
| **Google Four Keys** | OSS (Cloud Run + BigQuery + Dataflow) | Event-sourced en BigQuery | Vía label `incident` en issues | Medio (GCP-native) | Limitado |
| **Apache DevLake** | OSS, incubating (fuera de sandbox CNCF pero cloud-native) | Domain layer normalizado (MySQL) | Nativa (issue tracking + CICD) | Medio (Helm/Docker) | Sí (por project/blueprint) |
| **Backstage + plugin DORA** | OSS (Spotify/CNCF) | Delega en backend externo | Depende del backend | Bajo si ya hay Backstage | Vía catalog |
| **Comercial** (Sleuth, LinearB, Faros, Cortex) | SaaS | Propietario | Nativa | Bajo (SaaS) / $$$ | Sí |

Para una plataforma cloud-native con Kubernetes, la referencia OSS es **Apache DevLake** (polling multi-fuente, normaliza a un *domain layer*, sirve dashboards Grafana out-of-the-box) o **Four Keys** si el stack es GCP. Ambos aparecen en la bibliografía del CNPA.

### 2.4 De dónde sale cada métrica (mapa origen→métrica)

| Métrica | Evento origen | Sistema típico | Campo clave para correlación |
|---|---|---|---|
| Deployment Frequency | `deployment` / `rollout succeeded` | Argo CD, Flux, Tekton, Deployment k8s | `service`, `environment`, `timestamp` |
| Lead Time for Changes | `commit` + `deployment` | Git + CD | `commit_sha` → `deploy.revision` |
| Change Failure Rate | `deployment` + `incident` | CD + PagerDuty/Alertmanager | `incident.deploy_id` / ventana temporal |
| Failed Deployment Recovery Time | `incident.opened` + `incident.resolved` | Incident tool | `incident_id`, `deploy_id` |

---

## 3. Manifiestos y código de infraestructura (completos)

### 3.1 Esquema del data warehouse (estilo Four Keys, PostgreSQL)

El corazón es *event sourcing*: dos tablas de eventos crudos y vistas que computan las métricas. Nada de estado mutable.

```sql
-- schema.sql — modelo event-sourced para DORA metrics
-- Filosofía: los eventos son inmutables; las métricas son VIEWS derivadas.

CREATE TABLE IF NOT EXISTS deployments (
    deployment_id   TEXT        NOT NULL,          -- id único del deploy (ej. argo sync id)
    service         TEXT        NOT NULL,          -- unidad de atribución
    environment     TEXT        NOT NULL DEFAULT 'production',
    revision        TEXT        NOT NULL,          -- commit SHA desplegado
    deployed_at     TIMESTAMPTZ NOT NULL,          -- momento "running in production"
    source          TEXT        NOT NULL,          -- 'argocd' | 'flux' | 'tekton'
    PRIMARY KEY (deployment_id, environment)       -- idempotencia: reintentos no duplican
);

CREATE TABLE IF NOT EXISTS changes (
    change_id       TEXT        NOT NULL PRIMARY KEY, -- commit SHA
    service         TEXT        NOT NULL,
    authored_at     TIMESTAMPTZ NOT NULL,           -- FIRST COMMIT time (definición DORA de LTC)
    merged_at       TIMESTAMPTZ,                     -- opcional, para análisis
    deployment_id   TEXT                             -- FK lógica: en qué deploy salió
);

CREATE TABLE IF NOT EXISTS incidents (
    incident_id     TEXT        NOT NULL PRIMARY KEY,
    service         TEXT        NOT NULL,
    opened_at       TIMESTAMPTZ NOT NULL,
    resolved_at     TIMESTAMPTZ,                     -- NULL mientras abierto
    root_deploy_id  TEXT,                            -- deploy que causó el fallo (CFR/FDRT)
    severity        TEXT        NOT NULL DEFAULT 'sev2'
);

-- Índices para las ventanas temporales de los cálculos
CREATE INDEX IF NOT EXISTS idx_deploy_svc_time ON deployments (service, deployed_at);
CREATE INDEX IF NOT EXISTS idx_incident_deploy ON incidents (root_deploy_id);

-- ── VIEW 1: Deployment Frequency (deploys/día por servicio, últimos 30d) ──
CREATE OR REPLACE VIEW v_deployment_frequency AS
SELECT
    service,
    environment,
    COUNT(*)                                              AS deploys,
    ROUND(COUNT(*)::numeric / 30, 2)                      AS deploys_per_day,
    CASE
        WHEN COUNT(*) / 30.0 >= 1        THEN 'Elite'     -- on-demand / diario
        WHEN COUNT(*) / 7.0  >= 1        THEN 'High'      -- >= 1/semana
        WHEN COUNT(*) / 30.0 >= 1/30.0   THEN 'Medium'    -- >= 1/mes
        ELSE 'Low'
    END                                                   AS performance_band
FROM deployments
WHERE deployed_at >= now() - INTERVAL '30 days'
  AND environment = 'production'
GROUP BY service, environment;

-- ── VIEW 2: Lead Time for Changes (mediana, first-commit → deploy) ──
CREATE OR REPLACE VIEW v_lead_time AS
SELECT
    c.service,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (d.deployed_at - c.authored_at))
    ) / 3600.0                                            AS median_lead_hours
FROM changes c
JOIN deployments d ON d.deployment_id = c.deployment_id
WHERE d.deployed_at >= now() - INTERVAL '30 days'
GROUP BY c.service;

-- ── VIEW 3: Change Failure Rate (deploys con incidente / total) ──
CREATE OR REPLACE VIEW v_change_failure_rate AS
SELECT
    d.service,
    COUNT(DISTINCT i.root_deploy_id)::numeric
        / NULLIF(COUNT(DISTINCT d.deployment_id), 0)      AS cfr,
    ROUND(100 * COUNT(DISTINCT i.root_deploy_id)::numeric
        / NULLIF(COUNT(DISTINCT d.deployment_id), 0), 1)  AS cfr_pct
FROM deployments d
LEFT JOIN incidents i ON i.root_deploy_id = d.deployment_id
WHERE d.deployed_at >= now() - INTERVAL '30 days'
GROUP BY d.service;

-- ── VIEW 4: Failed Deployment Recovery Time (mediana de recuperación) ──
CREATE OR REPLACE VIEW v_recovery_time AS
SELECT
    service,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (resolved_at - opened_at))
    ) / 3600.0                                            AS median_recovery_hours
FROM incidents
WHERE resolved_at IS NOT NULL
  AND root_deploy_id IS NOT NULL
  AND opened_at >= now() - INTERVAL '30 days'
GROUP BY service;
```

### 3.2 Deployment-event exporter: un controller que observa Argo CD y emite CDEvents

El puente entre el CD y el warehouse. Este `Deployment` observa los `Application` de Argo CD y emite un **CDEvent** `dev.cdevents.service.deployed` por cada sync exitoso (patrón productor).

```yaml
# dora-deploy-exporter.yaml — emite CDEvents al colector cuando Argo sincroniza
apiVersion: v1
kind: Namespace
metadata:
  name: platform-dora
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dora-deploy-exporter
  namespace: platform-dora
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dora-deploy-exporter
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dora-deploy-exporter
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dora-deploy-exporter
subjects:
  - kind: ServiceAccount
    name: dora-deploy-exporter
    namespace: platform-dora
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dora-deploy-exporter
  namespace: platform-dora
spec:
  replicas: 1                     # singleton: leader-election evita eventos dobles
  selector:
    matchLabels: { app: dora-deploy-exporter }
  template:
    metadata:
      labels: { app: dora-deploy-exporter }
    spec:
      serviceAccountName: dora-deploy-exporter
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: exporter
          image: ghcr.io/acme-platform/dora-deploy-exporter:v1.4.2
          args:
            - --collector-url=http://dora-collector.platform-dora.svc:8080/events
            - --leader-elect=true
          env:
            - name: CDEVENTS_SOURCE
              value: "/platform/argocd"
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          ports:
            - { name: metrics, containerPort: 9090 }
```

CDEvent que emite (contrato con el colector, conforme a la spec CDEvents v0.4):

```json
{
  "context": {
    "version": "0.4.1",
    "id": "A234-1234-1234",
    "source": "/platform/argocd",
    "type": "dev.cdevents.service.deployed.0.2.0",
    "timestamp": "2025-03-18T14:27:11Z"
  },
  "subject": {
    "id": "checkout-api",
    "source": "/platform/argocd",
    "type": "service",
    "content": {
      "environment": { "id": "production" },
      "artifactId": "pkg:oci/checkout-api@sha256:9f8e...ab"
    }
  },
  "customData": {
    "revision": "3f2a1cd9e4b7...",
    "deploymentId": "argocd-sync-8842",
    "team": "payments"
  }
}
```

### 3.3 Apache DevLake por Helm (motor completo de polling multi-fuente)

```yaml
# devlake-values.yaml — Helm values para Apache DevLake (chart oficial)
# helm repo add devlake https://apache.github.io/incubator-devlake-helm-chart
# helm install devlake devlake/devlake -n platform-dora -f devlake-values.yaml
grafana:
  enabled: true
  adminUser: admin
  # el password real por secret externo, no en values (ver 3.6)

mysql:
  enabled: true
  storage:
    size: 20Gi
    class: fast-ssd

lake:
  replicas: 1
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2",  memory: 4Gi }

grafanaIngress:
  enabled: true
  host: dora.platform.acme.internal
  tls:
    enabled: true
    secretName: dora-tls

# encryption key para credenciales de conectores (rotable)
encryptionSecret:
  secretName: devlake-encryption
  secretKey: ENCRYPTION_SECRET
```

Definición del **blueprint** (qué recolecta y cada cuánto) vía la API de configuración de DevLake:

```json
{
  "name": "payments-dora",
  "mode": "NORMAL",
  "enable": true,
  "cronConfig": "0 */2 * * *",
  "isManual": false,
  "connections": [
    {
      "pluginName": "github",
      "connectionId": 1,
      "scopes": [
        { "scopeId": "acme/checkout-api",
          "scopeConfigId": 1 }
      ]
    },
    {
      "pluginName": "pagerduty",
      "connectionId": 1,
      "scopes": [ { "scopeId": "PXXXXXX" } ]
    }
  ]
}
```

### 3.4 Recording rules de Prometheus (deployment frequency sin explotar cardinalidad)

Contamos deploys **incrementando un contador**, sin usar `commit_sha` como label (evita cardinalidad ilimitada). El exporter expone `dora_deployments_total{service,environment,team}`.

```yaml
# dora-recording-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-metrics
  namespace: platform-dora
  labels:
    release: kube-prometheus-stack        # que Prometheus Operator lo cargue
spec:
  groups:
    - name: dora.deployment-frequency
      interval: 5m
      rules:
        # deploys por día (ventana 7d), por servicio+entorno
        - record: dora:deployment_frequency:per_day7d
          expr: |
            sum by (service, environment, team) (
              increase(dora_deployments_total{environment="production"}[7d])
            ) / 7

    - name: dora.change-failure-rate
      interval: 5m
      rules:
        # CFR = deploys que dispararon incidente / deploys totales (30d)
        - record: dora:change_failure_rate:ratio30d
          expr: |
            sum by (service) (increase(dora_failed_deployments_total[30d]))
            /
            sum by (service) (increase(dora_deployments_total[30d]) > 0)

    - name: dora.alerting
      rules:
        # alerta: CFR por encima del umbral "Elite" (15%) sostenido
        - alert: DoraChangeFailureRateHigh
          expr: dora:change_failure_rate:ratio30d > 0.15
          for: 1h
          labels: { severity: warning, tier: platform }
          annotations:
            summary: "CFR de {{ $labels.service }} = {{ $value | humanizePercentage }} (>15%, fuera de banda Elite)"
            runbook_url: "https://platform.acme.internal/runbooks/dora-cfr"
```

### 3.5 Panel de Grafana provisionado (mediana de lead time como Time series)

```yaml
# grafana-dora-dashboard-cm.yaml — provisioning por ConfigMap (sidecar)
apiVersion: v1
kind: ConfigMap
metadata:
  name: dora-dashboard
  namespace: platform-dora
  labels:
    grafana_dashboard: "1"          # el sidecar de Grafana lo autodescubre
data:
  dora.json: |
    {
      "title": "DORA — Platform Initiative",
      "uid": "dora-platform",
      "panels": [
        {
          "type": "stat",
          "title": "Deployment Frequency (deploys/día)",
          "targets": [{
            "expr": "sum by (team) (dora:deployment_frequency:per_day7d)",
            "legendFormat": "{{team}}"
          }],
          "fieldConfig": { "defaults": {
            "thresholds": { "steps": [
              { "color": "red",    "value": null },
              { "color": "yellow", "value": 0.033 },
              { "color": "green",  "value": 1 }
            ]}
          }}
        },
        {
          "type": "timeseries",
          "title": "Change Failure Rate (30d)",
          "targets": [{
            "expr": "dora:change_failure_rate:ratio30d",
            "legendFormat": "{{service}}"
          }]
        }
      ]
    }
```

### 3.6 Anotación de catálogo Backstage (atribución por servicio)

Backstage liga el servicio (unidad de atribución DORA) a su fuente de deploys/PRs:

```yaml
# catalog-info.yaml del servicio
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-api
  annotations:
    github.com/project-slug: acme/checkout-api
    argocd/app-name: checkout-api
    pagerduty.com/service-id: PXXXXXX
    dora.platform.acme/team: payments        # clave de atribución
spec:
  type: service
  lifecycle: production
  owner: team-payments
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Verificar que el exporter emite deployments

```console
$ kubectl -n platform-dora get deploy dora-deploy-exporter
NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
dora-deploy-exporter    1/1     1            1           12d

$ kubectl -n platform-dora logs deploy/dora-deploy-exporter --tail=4
2025-03-18T14:27:11Z INF became leader, watching argoproj.io/Application
2025-03-18T14:27:11Z INF sync OK app=checkout-api rev=3f2a1cd env=production
2025-03-18T14:27:11Z INF emitted cdevent type=dev.cdevents.service.deployed id=A234-1234-1234
2025-03-18T14:27:11Z INF collector ack status=202
```

### 4.2 Contar deployment frequency directo desde Prometheus

```console
$ kubectl -n platform-dora exec -it prometheus-0 -- \
    promtool query instant http://localhost:9090 \
    'sum by (team) (dora:deployment_frequency:per_day7d)'
dora:deployment_frequency:per_day7d{team="payments"} => 4.28 @[1742308200]
dora:deployment_frequency:per_day7d{team="search"}   => 0.71 @[1742308200]
dora:deployment_frequency:per_day7d{team="billing"}  => 0.14 @[1742308200]
```

> Lectura: `payments` está en banda **Elite** (>1/día), `search` en **High** (>1/semana), `billing` en **Medium** (~1/semana). El objetivo de la plataforma es mover a `billing` con un golden path de CD.

### 4.3 Lead time desde git (first commit → deploy) sin herramienta

Cálculo manual del `lead time` de un release, útil para validar el pipeline automático:

```console
$ # timestamp del PRIMER commit del rango desplegado (definición DORA)
$ git log --reverse --format='%aI %h' v1.8.0..v1.9.0 | head -1
2025-03-16T09:12:04+00:00 a1b2c3d

$ # momento en que Argo marcó Healthy+Synced en producción
$ argocd app get checkout-api -o json \
    | jq -r '.status.operationState.finishedAt'
2025-03-18T14:27:09Z

$ # diferencia en horas
$ python3 -c "from datetime import datetime as d; \
  print(round((d.fromisoformat('2025-03-18T14:27:09+00:00') - \
               d.fromisoformat('2025-03-16T09:12:04+00:00')).total_seconds()/3600,1), 'h')"
53.3 h
```

53.3 h → banda **High** (1 día–1 semana). Un lead time de <1 h sería **Elite**.

### 4.4 Disparar y verificar un blueprint de DevLake por API

```console
$ curl -sS -X POST http://devlake.platform-dora.svc:8080/blueprints \
    -H 'Content-Type: application/json' -d @payments-dora.json | jq '.id, .name'
7
"payments-dora"

$ # forzar una ejecución inmediata (trigger manual del blueprint 7)
$ curl -sS -X POST http://devlake.platform-dora.svc:8080/blueprints/7/trigger | jq '.id, .status'
1042
"TASK_RUNNING"

$ # estado de la pipeline de recolección
$ curl -sS http://devlake.platform-dora.svc:8080/pipelines/1042 \
    | jq '{status, finishedTasks, totalTasks}'
{
  "status": "TASK_COMPLETED",
  "finishedTasks": 6,
  "totalTasks": 6
}
```

### 4.5 Four Keys: consulta directa en BigQuery

```console
$ bq query --use_legacy_sql=false '
SELECT
  FORMAT_DATE("%Y-%W", DATE(time_created)) AS week,
  COUNT(DISTINCT deploy_id)                AS deploys
FROM `four_keys.deployments`
WHERE time_created >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 28 DAY)
GROUP BY week ORDER BY week'
+---------+---------+
|  week   | deploys |
+---------+---------+
| 2025-08 |      41 |
| 2025-09 |      55 |
| 2025-10 |      48 |
| 2025-11 |      62 |
+---------+---------+
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de correctitud del pipeline de DORA

| # | Verificación | Comando / método | Síntoma de fallo |
|---|---|---|---|
| 1 | Los deploys llegan al warehouse | `SELECT count(*) FROM deployments WHERE deployed_at > now()-interval '1 day'` | 0 filas → exporter caído o webhook roto |
| 2 | No hay deploys duplicados | `SELECT deployment_id, count(*) FROM deployments GROUP BY 1 HAVING count(*)>1` | Filas → falta idempotencia (PK/upsert) |
| 3 | Lead time usa *first commit* | Inspeccionar `changes.authored_at` vs `merged_at` | LTC sospechosamente bajo → usa merge time |
| 4 | Incidentes correlacionan con deploy | `SELECT count(*) FROM incidents WHERE root_deploy_id IS NULL` | Muchos NULL → CFR/FDRT subestimados |
| 5 | Cardinalidad Prometheus acotada | `count(count by (__name__)({__name__=~"dora.*"}))` | Crece sin parar → label de alta cardinalidad |
| 6 | Timezones normalizados a UTC | `SELECT deployed_at FROM deployments LIMIT 5` | Offsets mixtos → lead time con saltos de ±horas |

### 5.2 Fallas frecuentes y su causa raíz

**A. Deployment frequency "cae a cero" un fin de semana.**
No es que no se desplegara: el exporter usa *polling* y el intervalo se solapó con un rollout+rollback. Verificá con eventos crudos:

```console
$ kubectl -n platform-dora exec prometheus-0 -- \
    promtool query instant http://localhost:9090 \
    'increase(dora_deployments_total{service="checkout-api"}[1h])'
dora_deployments_total{service="checkout-api"} => 0 @[...]
```
Si el warehouse SÍ tiene el deploy pero Prometheus no, el problema es el `increase()` sobre un contador que se reinició (restart del exporter → counter reset). Solución: `increase()` maneja resets, pero si el pod se recreó y perdió el valor, usar el warehouse como fuente de verdad para conteos históricos, y Prometheus solo para tiempo real.

**B. CFR = 0% para todos los servicios (falso positivo de excelencia).**
Casi siempre la correlación incidente↔deploy está rota (`root_deploy_id` siempre NULL). Diagnóstico:

```console
$ psql -c "SELECT count(*) FILTER (WHERE root_deploy_id IS NOT NULL) AS linked,
                  count(*) AS total FROM incidents;"
 linked | total
--------+-------
      0 |    37
```
0 de 37 incidentes ligados → el heurístico de correlación (por ventana temporal o por label) no está corriendo. **Un CFR de 0% con 37 incidentes abiertos es una alarma, no un logro.**

**C. Lead time se dispara a "meses".**
Un `commit` viejo en una rama de larga duración se mergeó tarde; su `authored_at` arrastra la mediana. Verificá con el percentil y no con la media, y considerá excluir long-lived branches — pero **documentá la exclusión**, porque esconder feature branches enormes es esconder deuda real de proceso.

**D. Cardinalidad explota el TSDB (OOMKilled de Prometheus).**

```console
$ kubectl -n platform-dora describe pod prometheus-0 | grep -A2 State
    State:      Running
    Last State: Terminated
      Reason:   OOMKilled
$ curl -s localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[] | select(.name|test("dora"))'
{ "name": "dora_deployments_total", "value": 148213 }
```
148k series para un contador de deploys = alguien puso `commit_sha` o `deployment_id` como label. **Regla:** los identificadores únicos van al warehouse (Postgres/BigQuery), **nunca** como labels de Prometheus. Prometheus solo lleva dimensiones acotadas: `service`, `environment`, `team`.

**E. Números no reproducibles entre Grafana y el reporte trimestral.**
Ventanas temporales distintas (7d de rolling en Grafana vs mes calendario en el reporte) o zonas horarias. Fijá una **única definición canónica** de ventana y timezone (UTC) en las VIEWS del warehouse y hacé que Grafana consulte esas VIEWS, no re-calcule.

### 5.3 Anti-patrones de gobernanza (Goodhart)

- **No** ates compensación individual a DF/LTC → fragmentación artificial de PRs.
- **Siempre** mostrá throughput y stability **juntos**: subir DF mientras sube CFR es regresión disfrazada de progreso.
- **No** compares equipos con productos distintos (un batch nocturno vs un servicio web tienen DF estructuralmente distinta). DORA compara *contra sí mismo en el tiempo* y contra benchmark de industria, no equipo-vs-equipo como ranking.
- La plataforma reporta DORA para **demostrar impacto agregado** (¿los adoptantes del golden path mejoran sus 4 métricas vs los no-adoptantes?), no para vigilar equipos.

---

## 6. Referencias

- **DORA — Guías oficiales de las cuatro métricas y el modelo de capacidades:** https://dora.dev/guides/dora-metrics-four-keys/
- **DORA — Quick Check y benchmarks por banda (Elite/High/Medium/Low):** https://dora.dev/quickcheck/
- **Accelerate State of DevOps Report (edición vigente):** https://dora.dev/research/
- **Google Cloud — Four Keys (implementación OSS de referencia):** https://github.com/dora-team/fourkeys
- **Apache DevLake — documentación de métricas DORA:** https://devlake.apache.org/docs/DORA
- **Apache DevLake — Helm chart:** https://github.com/apache/incubator-devlake-helm-chart
- **CDEvents — especificación (CNCF / Continuous Delivery Foundation):** https://cdevents.dev/docs/
- **CloudEvents — especificación (CNCF):** https://cloudevents.io/
- **OpenTelemetry — CI/CD Observability SIG:** https://opentelemetry.io/docs/specs/semconv/cicd/
- **SPACE framework (Forsgren et al., ACM Queue):** https://queue.acm.org/detail.cfm?id=3454124
- **DevEx / Developer Experience (Noda, Storey, Forsgren, ACM Queue):** https://queue.acm.org/detail.cfm?id=3595878
- **Backstage — catálogo de software (unidad de atribución):** https://backstage.io/docs/features/software-catalog/
- **CNCF — Cloud Native Platform Engineering Associate (CNPA) curriculum:** https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf