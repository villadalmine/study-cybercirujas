# 4.1 Dashboarding basics

> **Domain:** Alerting & Dashboarding · **Exam weight:** 4.5
> **Level:** Advanced — SRE / Platform Architect

---

## 1. Motivación: el problema arquitectónico que los dashboards realmente resuelven

Prometheus es una base de datos de series temporales *dimensional y basada en pull*. Hace scraping de endpoints `/metrics`, almacena muestras como `(metric_name{labels}, timestamp, float64)`, y las expone sobre HTTP a través de dos endpoints de consulta:

- `GET/POST /api/v1/query` — **instant vector** en un único timestamp de evaluación.
- `GET/POST /api/v1/query_range` — **range vector** evaluado a intervalos de `step` entre `start` y `end`.

Todo lo visual se apoya *encima* de esos dos endpoints. La pregunta arquitectónica del "dashboarding" no es, por lo tanto, "cómo dibujo un gráfico" — es:

> ¿Cómo convierto una TSDB cruda, de alta cardinalidad y basada en pull en una **superficie operativa curada, de baja latencia y reproducible** que un ingeniero de guardia pueda leer en cinco segundos a las 03:00, y que sobreviva a las reconstrucciones del cluster?

El camino ingenuo — ingenieros tecleando PromQL en el expression browser incorporado durante un incidente — falla en producción por razones concretas:

| Modo de fallo de las consultas ad-hoc | Consecuencia en producción |
|---|---|
| El conocimiento de las consultas vive en la cabeza de las personas | La guardia sin conocimiento tribal está ciega |
| Sin ventana temporal compartida / correlación | Dos ingenieros miran ventanas distintas y no se ponen de acuerdo |
| Cada panel recalcula agregaciones pesadas | La carga de consultas se dispara justo durante los incidentes |
| Sin versionado de "cómo se ve lo bueno" | Las líneas base derivan; las regresiones pasan desapercibidas |
| El layout se resetea en cada recarga del navegador | Sin memoria muscular, triaje lento |

Un dashboard es el **contrato materializado y bajo control de versiones** de lo que un SRE considera la salud de un sistema. Tratarlo como *código* (provisionado, revisado, diffeable) en lugar de *clics* es la disciplina de producción más importante de este tema.

### 1.1 El stack de visualización de tres capas

```
┌──────────────────────────────────────────────────────────┐
│  Layer 3: Grafana (or Perses)                              │
│  panels, variables, folders, RBAC, provisioning-as-code    │
└───────────────▲──────────────────────────────────────────┘
                │  HTTP /api/v1/query[_range]  (PromQL)
┌───────────────┴──────────────────────────────────────────┐
│  Layer 2: Prometheus query engine + TSDB                   │
│  recording rules, retention, WAL, head block               │
└───────────────▲──────────────────────────────────────────┘
                │  scrape /metrics (pull, every scrape_interval)
┌───────────────┴──────────────────────────────────────────┐
│  Layer 1: instrumented targets + exporters                 │
└────────────────────────────────────────────────────────────┘
```

Prometheus incluye **dos** superficies de visualización nativas que debés conocer para el examen, y ambas son deliberadamente mínimas:

1. **Expression browser** (`http://<prometheus>:9090/graph`) — una pestaña Table/Graph para PromQL interactivo. Excelente para *exploración y debugging*, nunca para dashboards permanentes. Sin persistencia, sin variables, sin modelo de auth propio.
2. **Console templates** — páginas de Go-`html/template` servidas desde `--web.console.templates` bajo `/consoles/`. Son anteriores a Grafana, se renderizan del lado del servidor, y son archivos bajo control de versiones. En la práctica son **legacy**; el ecosistema se consolidó en torno a Grafana. Sabé que existen y por qué fueron reemplazadas.

La decisión de diseño — Prometheus intencionalmente mantiene delgada la visualización — está documentada en la propia guía del proyecto: *"Grafana … is the recommended way to visualize Prometheus data."* (ver Referencias).

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Opciones de la capa de visualización

| | Expression browser | Console templates | **Grafana** | Perses |
|---|---|---|---|---|
| Persistencia | Ninguna | Archivos en el host de Prometheus | DB + provisioning | CRDs GitOps-native |
| Variables / templating | No | Variables de Go template | Rica (`label_values`, encadenada) | Sí |
| Multi-datasource | Solo Prometheus | Solo Prometheus | 100+ fuentes, paneles mixtos | Centrada en Prometheus |
| AuthN/AuthZ | Hereda de Prometheus | Hereda de Prometheus | Usuarios, teams, RBAC por folder | K8s RBAC |
| Dashboards-as-code | N/A | Nativo (archivos) | Modelo JSON + provisioning/operator | CRD-first |
| Encaje en producción | Solo debug | Legacy | **Estándar de facto** | Emergente (CNCF sandbox) |

**Veredicto para PCA:** Grafana es la respuesta para dashboards permanentes; el expression browser es la respuesta para debugging ad-hoc de PromQL.

### 2.2 Modo de acceso del data source

| Modo | Ruta de la consulta | Usar cuando |
|---|---|---|
| `access: proxy` (**server**) | Browser → Grafana backend → Prometheus | Casi siempre. Prometheus no necesita ser alcanzable desde el navegador; las credenciales quedan del lado del servidor. |
| `access: direct` (**browser**) | Browser → Prometheus directamente | Deprecado / raro. Requiere CORS + alcanzabilidad desde el navegador; expone los endpoints. |

### 2.3 Tipo de consulta por panel

| Tipo de consulta | Endpoint usado | Devuelve | Panel que alimenta |
|---|---|---|---|
| **Range** | `/api/v1/query_range` | matrix (series a lo largo del tiempo) | Time series, Heatmap, State timeline |
| **Instant** | `/api/v1/query` | vector (un punto por serie, "ahora") | Stat, Gauge, Bar gauge, Table |

Elegir *instant* para un panel Stat y *range* para un gráfico de time-series es la diferencia entre un dashboard correcto y uno que silenciosamente sobreconsulta la TSDB.

### 2.4 El trade-off de step / interval (el detalle que separa a los seniors)

Grafana inyecta variables macro en cada consulta PromQL:

| Macro | Definición | Por qué importa |
|---|---|---|
| `$__interval` | `time_range / max_data_points` (redondeado a un step "lindo") | Establece el `step` de `query_range`. Muy pequeño → resultado enorme, render lento; muy grande → aliasing. |
| `$__rate_interval` | `max($__interval + scrape_interval, 4 × scrape_interval)` | **Usá siempre esto dentro de `rate()`/`irate()`.** Garantiza ≥ 4 muestras por ventana → sin huecos, sin NaN al hacer zoom in. |
| `$__range` | end − start del time picker del dashboard | Para agregaciones `_over_time` y totales. |
| `$__from` / `$__to` | epoch ms de los límites del picker | Anotaciones, enlaces. |

**Tabla de trade-offs — elección del intervalo de `rate()`:**

| Escribís | Con zoom out (1h) | Con zoom in (5m) | Veredicto |
|---|---|---|---|
| `rate(x[5m])` (hard-coded) | bien | bien solo si scrape ≤ ~75s | frágil |
| `rate(x[$__interval])` | bien | **huecos / vacío** (puede ser < scrape) | incorrecto |
| `rate(x[$__rate_interval])` | bien | bien | **correcto** |

El campo `timeInterval` en el data source (a.k.a. "Scrape interval") es lo que `$__rate_interval` lee para calcular el piso — ajustalo a tu `scrape_interval` real o la macro está mal.

### 2.5 Estrategia de provisioning

| Estrategia | Fuente de verdad | Riesgo de drift | Mejor para |
|---|---|---|---|
| Clics manuales en la UI | Grafana DB | Alto | Solo prototipado |
| **File provisioning** (`provisioning/*.yaml` + JSON) | Git | Bajo | Instancia única / Deployment |
| **Sidecar ConfigMap** (kube-prometheus-stack) | Git → ConfigMap → sidecar | Bajo | Kubernetes, descubrimiento dinámico |
| **grafana-operator** (CRDs) | Git → CRD | Muy bajo | Multi-tenant, multi-instancia GitOps |
| Terraform provider | Git (HCL) | Bajo | A nivel org, IaC cross-tool |

Los dashboards provisionados son **de solo lectura en la UI** por defecto (`allowUiUpdates: false`) — esto es una feature: obliga a que los cambios pasen por revisión.

---

## 3. Infraestructura completa y manifiestos (sin recortes)

### 3.1 Data source de Prometheus en Grafana — file provisioning

`/etc/grafana/provisioning/datasources/prometheus.yaml`:

```yaml
apiVersion: 1

# Datasources removed from this file are deleted on restart when listed here.
deleteDatasources:
  - name: Prometheus-old
    orgId: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy                       # server-side proxy (recommended)
    orgId: 1
    uid: prometheus-main                # stable UID → referenced by dashboards
    url: http://prometheus-server.monitoring.svc:9090
    isDefault: true
    editable: false                     # provisioned = source of truth
    jsonData:
      httpMethod: POST                  # POST avoids URL-length limits on big PromQL
      timeInterval: "15s"               # MUST match scrape_interval → feeds $__rate_interval
      queryTimeout: "60s"
      manageAlerts: true                # allow Grafana-managed alert rules
      prometheusType: Prometheus        # Prometheus | Cortex | Mimir | Thanos
      prometheusVersion: "2.53.0"
      cacheLevel: "High"
      incrementalQuerying: true         # only fetch new data on dashboard refresh
      incrementalQueryOverlapWindow: "10m"
      exemplarTraceIdDestinations:      # trace correlation (exemplars → Tempo/Jaeger)
        - name: trace_id
          datasourceUid: tempo-main
    # secureJsonData:                   # for auth’d Prometheus / remote backends
    #   httpHeaderValue1: "Bearer <token>"
```

### 3.2 Provider de dashboards — file provisioning

`/etc/grafana/provisioning/dashboards/provider.yaml`:

```yaml
apiVersion: 1

providers:
  - name: 'platform-dashboards'
    orgId: 1
    folder: 'Platform'                  # target Grafana folder (created if absent)
    folderUid: platform
    type: file
    disableDeletion: true               # don't delete on file removal
    updateIntervalSeconds: 30           # poll interval for changed JSON
    allowUiUpdates: false               # read-only in UI → Git is the truth
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true   # subdirs become Grafana folders
```

### 3.3 Kubernetes: Deployment de Grafana + dashboard como ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        uid: prometheus-main
        url: http://prometheus-server.monitoring.svc:9090
        isDefault: true
        jsonData:
          httpMethod: POST
          timeInterval: "15s"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-providers
  namespace: monitoring
data:
  providers.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: 'Platform'
        type: file
        disableDeletion: true
        allowUiUpdates: false
        options:
          path: /var/lib/grafana/dashboards
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-api-health
  namespace: monitoring
  labels:
    grafana_dashboard: "1"          # picked up by the sidecar (see 3.5)
data:
  api-health.json: |
    {
      "uid": "api-health",
      "title": "API — RED overview",
      "schemaVersion": 39,
      "editable": false,
      "timezone": "browser",
      "time": { "from": "now-6h", "to": "now" },
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "query",
            "datasource": { "type": "prometheus", "uid": "prometheus-main" },
            "query": "label_values(http_requests_total, namespace)",
            "refresh": 2,
            "includeAll": true,
            "multi": true
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "type": "stat",
          "title": "Request rate (req/s)",
          "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "prometheus-main" },
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=~\"$namespace\"}[$__rate_interval]))",
              "instant": true,
              "legendFormat": "req/s"
            }
          ]
        },
        {
          "id": 2,
          "type": "stat",
          "title": "Error ratio (5xx)",
          "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 },
          "datasource": { "type": "prometheus", "uid": "prometheus-main" },
          "fieldConfig": {
            "defaults": {
              "unit": "percentunit",
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "red", "value": 0.01 }
                ]
              }
            }
          },
          "targets": [
            {
              "expr": "sum(rate(http_requests_total{namespace=~\"$namespace\",code=~\"5..\"}[$__rate_interval])) / sum(rate(http_requests_total{namespace=~\"$namespace\"}[$__rate_interval]))",
              "instant": true
            }
          ]
        },
        {
          "id": 3,
          "type": "timeseries",
          "title": "p99 latency by route",
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 6 },
          "datasource": { "type": "prometheus", "uid": "prometheus-main" },
          "fieldConfig": { "defaults": { "unit": "s" } },
          "targets": [
            {
              "expr": "histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace=~\"$namespace\"}[$__rate_interval])))",
              "legendFormat": "{{route}}"
            }
          ]
        }
      ]
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels: { app: grafana }
  template:
    metadata:
      labels: { app: grafana }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 472
        fsGroup: 472
      containers:
        - name: grafana
          image: grafana/grafana:11.1.0
          ports:
            - { name: http, containerPort: 3000 }
          env:
            - { name: GF_SECURITY_ADMIN_USER, value: admin }
            - name: GF_SECURITY_ADMIN_PASSWORD
              valueFrom: { secretKeyRef: { name: grafana-admin, key: password } }
            - { name: GF_USERS_DEFAULT_THEME, value: dark }
          readinessProbe:
            httpGet: { path: /api/health, port: http }
            initialDelaySeconds: 10
          livenessProbe:
            httpGet: { path: /api/health, port: http }
            initialDelaySeconds: 30
          volumeMounts:
            - { name: datasources, mountPath: /etc/grafana/provisioning/datasources }
            - { name: providers,   mountPath: /etc/grafana/provisioning/dashboards }
            - { name: dashboards,  mountPath: /var/lib/grafana/dashboards }
      volumes:
        - { name: datasources, configMap: { name: grafana-datasources } }
        - { name: providers,   configMap: { name: grafana-dashboard-providers } }
        - name: dashboards
          configMap:
            name: grafana-dashboard-api-health
            items:
              - { key: api-health.json, path: api-health.json }
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
spec:
  selector: { app: grafana }
  ports:
    - { name: http, port: 80, targetPort: http }
```

### 3.4 grafana-operator (v5) — dashboards como CRDs (GitOps)

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: monitoring
  labels:
    dashboards: "grafana"          # instances select CRDs by this label
spec:
  config:
    security:
      admin_user: admin
      admin_password: admin        # use secret in production
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.monitoring.svc:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      timeInterval: "30s"
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: node-exporter-full
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  resyncPeriod: 5m
  # Source options (mutually exclusive): json | url | grafanaCom | configMapRef | jsonnet
  grafanaCom:
    id: 1860                       # "Node Exporter Full" from grafana.com/dashboards
    revision: 37
  datasources:
    - inputName: "DS_PROMETHEUS"   # remap the dashboard's datasource input
      datasourceName: "Prometheus"
```

### 3.5 kube-prometheus-stack — el patrón sidecar

La Grafana del stack corre un **sidecar** que observa ConfigMaps/Secrets que llevan una label y los auto-importa — sin reinicio de Grafana, sin cableado de volúmenes. Habilitar y etiquetar:

```yaml
# values.yaml (helm: prometheus-community/kube-prometheus-stack)
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard        # the trigger label
      labelValue: "1"
      folderAnnotation: grafana_folder # ConfigMap annotation → Grafana folder
      searchNamespace: ALL            # discover CMs cluster-wide
      provider:
        allowUiUpdates: false
    datasources:
      enabled: true
      label: grafana_datasource
```

Cualquier `ConfigMap` etiquetado con `grafana_dashboard: "1"` (ver 3.3) es entonces importado automáticamente. Anotalo con `grafana_folder: "Platform"` para ubicarlo.

---

## 4. CLI y salida real de terminal

### 4.1 Confirmá la ruta de datos *antes* de tocar Grafana

```console
$ kubectl -n monitoring port-forward svc/prometheus-server 9090:9090 &
Forwarding from 127.0.0.1:9090 -> 9090

$ curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result[0]'
{
  "metric": {
    "__name__": "up",
    "instance": "10.42.0.15:9100",
    "job": "node-exporter"
  },
  "value": [
    1723075200.412,
    "1"
  ]
}
```

`value[1] == "1"` → target sano. Si esto falla, **ningún dashboard puede funcionar** — siempre debuggeá de abajo hacia arriba.

Range query (lo que emite un panel de time-series):

```console
$ curl -s -G 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=sum(rate(http_requests_total[1m]))' \
    --data-urlencode "start=$(date -d '-5 min' +%s)" \
    --data-urlencode "end=$(date +%s)" \
    --data-urlencode 'step=15s' | jq '.status,.data.result[0].values | length'
"success"
21
```

21 puntos a lo largo de 5 minutos con un step de 15s = muestreo correcto.

### 4.2 promtool — validar PromQL offline

```console
$ promtool query instant http://localhost:9090 \
    'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))'
{} => 0.4823 @[1723075260]

$ promtool query range --start=$(date -d '-10min' +%s) --end=$(date +%s) --step=30s \
    http://localhost:9090 'sum(rate(http_requests_total[5m]))'
{} =>
142.3 @[1723074660]
138.9 @[1723074690]
...
```

### 4.3 Salud de Grafana y verificación del provisioning

```console
$ kubectl -n monitoring port-forward svc/grafana 3000:80 &
$ curl -s http://localhost:3000/api/health | jq
{
  "commit": "0c8b2d3",
  "database": "ok",
  "version": "11.1.0"
}

$ curl -s -u admin:admin http://localhost:3000/api/datasources | jq '.[] | {name,type,uid,url}'
{
  "name": "Prometheus",
  "type": "prometheus",
  "uid": "prometheus-main",
  "url": "http://prometheus-server.monitoring.svc:9090"
}

# Data source health check (does Grafana actually reach Prometheus?)
$ curl -s -u admin:admin \
    "http://localhost:3000/api/datasources/uid/prometheus-main/health" | jq
{
  "status": "OK",
  "message": "Successfully queried the Prometheus API."
}

# Which dashboards got provisioned?
$ curl -s -u admin:admin "http://localhost:3000/api/search?type=dash-db" \
    | jq '.[] | {title, uid, folderTitle}'
{
  "title": "API — RED overview",
  "uid": "api-health",
  "folderTitle": "Platform"
}
```

### 4.4 Confirmá que el sidecar importó un ConfigMap

```console
$ kubectl -n monitoring get configmap -l grafana_dashboard=1
NAME                            DATA   AGE
grafana-dashboard-api-health    1      4m

$ kubectl -n monitoring logs deploy/grafana -c grafana-sc-dashboard | tail -3
{"time":"2026-08-08T12:01:07Z","msg":"Writing /tmp/dashboards/api-health.json (ADDED)"}
{"time":"2026-08-08T12:01:07Z","msg":"POST request sent to http://localhost:3000/api/admin/provisioning/dashboards/reload"}
{"time":"2026-08-08T12:01:08Z","msg":"reload successful, status: 200"}
```

### 4.5 grafana-cli (plugins para tipos de panel)

```console
$ kubectl -n monitoring exec deploy/grafana -c grafana -- \
    grafana-cli plugins install grafana-piechart-panel
✔ Downloaded grafana-piechart-panel v1.6.4

$ kubectl -n monitoring exec deploy/grafana -c grafana -- grafana-cli plugins ls
installed plugins:
grafana-piechart-panel @ 1.6.4
```

---

## 5. Verificación y diagnóstico de fallos

Diagnosticá **de abajo hacia arriba** a lo largo de las tres capas. El error más común es debuggear Grafana cuando el problema está una o dos capas más abajo.

### 5.1 Flujo de decisión

```
Panel shows "No data"
        │
        ▼
[1] Does the PromQL return data in the expression browser (:9090/graph)?
        │ no ──► fix the query / the target is down / metric name typo
        │ yes
        ▼
[2] Is the Grafana datasource /health OK?
        │ no ──► URL / DNS / access mode / auth / network policy
        │ yes
        ▼
[3] Does the dashboard time range overlap the data?  (retention? clock skew?)
        │ no ──► widen picker / fix NTP / check TSDB retention
        │ yes
        ▼
[4] Do template variables resolve?  ($namespace empty → regex matches nothing)
        │ no ──► fix label_values() / "Include All" / refresh-on-time-change
        │ yes
        ▼
[5] Panel-level: instant vs range mismatch, unit, legendFormat, $__rate_interval
```

### 5.2 Síntoma → causa raíz → solución

| Síntoma | Causa raíz probable | Verificación | Solución |
|---|---|---|---|
| Panel "No data", la query funciona en `:9090` | Datasource inalcanzable desde el pod de Grafana | `curl .../datasources/uid/<uid>/health` → error | Corregir `url`, `access: proxy`, DNS, NetworkPolicy |
| El gráfico tiene **huecos** al hacer zoom in | `rate([$__interval])` < scrape interval | Inspect → query panel; verificar `step` vs scrape | Usar `rate(...[$__rate_interval])`; ajustar `timeInterval` en el DS |
| `histogram_quantile` devuelve `NaN`/plano | No se agrega sobre `le`, o `_bucket` no se scrapea | Consultar `..._bucket` directamente en `:9090` | `sum by (le, ...) (rate(..._bucket[$__rate_interval]))` |
| Dashboard lento / la CPU de Prometheus se dispara al cargar | Agregación pesada recalculada por panel, alta cardinalidad | `topk(10, count by(__name__)({__name__=~".+"}))` | Agregar **recording rules**; reducir `max_data_points`; habilitar `incrementalQuerying` |
| Dashboard provisionado no aparece | `path` del provider incorrecto, o falta la label del sidecar | `curl /api/search`; revisar logs del sidecar | Corregir `options.path` o la label `grafana_dashboard: "1"` |
| No se puede editar el dashboard en la UI | `allowUiUpdates: false` (por diseño) | YAML del provider | Editar el JSON en Git, no la UI |
| Variable `$namespace` vacía | `label_values()` apunta a una métrica que no existe | Correr la query de la variable en `:9090` | Apuntar a una métrica viva; ajustar la variable a **Refresh: On time range change** |
| Valores desviados por 1000× o unidad incorrecta | `unit` del panel sin ajustar (bytes vs bits, s vs ms) | Panel → Field → Unit | Ajustar la unidad correcta; usar `percentunit` para ratios |
| Cambio del datasource ignorado tras editar | Colisión de UID / no reiniciado | `curl /api/datasources` muestra la URL vieja | Asegurar un `uid` único; reload del provisioning / reinicio |

### 5.3 Recording rules — la solución de producción para la latencia del dashboard

Un dashboard que recalcula `histogram_quantile(0.99, sum by (le, route) (rate(...[5m])))` en cada refresh de cada panel es un generador de carga autoinfligido. Precalculá:

```yaml
groups:
  - name: api-slo.rules
    interval: 30s
    rules:
      - record: job:http_request_duration_seconds:p99
        expr: |
          histogram_quantile(0.99,
            sum by (le, job, route) (
              rate(http_request_duration_seconds_bucket[5m])
            ))
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
```

El panel entonces consulta la serie precalculada barata `job:http_request_duration_seconds:p99` — evaluada una vez por intervalo de regla, no una vez por espectador. Esta es la interacción prevista entre los dominios de **Prometheus Fundamentals** y **Dashboarding**.

### 5.4 Diseño de paneles con golden-signals (RED / USE)

Diseñá los paneles alrededor de un método, no alrededor de la métrica que resulte conveniente:

| Método | Señales | Encaja en |
|---|---|---|
| **RED** | **R**ate, **E**rrors, **D**uration | servicios request-driven |
| **USE** | **U**tilization, **S**aturation, **E**rrors | recursos (CPU, disco, cola) |

Trío RED canónico (macros de Grafana en todo momento):

```promql
# Rate
sum(rate(http_requests_total{job="$job"}[$__rate_interval]))

# Errors (ratio)
sum(rate(http_requests_total{job="$job",code=~"5.."}[$__rate_interval]))
/ sum(rate(http_requests_total{job="$job"}[$__rate_interval]))

# Duration (p99)
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket{job="$job"}[$__rate_interval])))
```

---

## 6. References

- **PCA Curriculum (CNCF)** — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- **Prometheus — Visualization / Grafana integration** — https://prometheus.io/docs/visualization/grafana/
- **Prometheus — Expression browser** — https://prometheus.io/docs/visualization/browser/
- **Prometheus — Console templates** — https://prometheus.io/docs/visualization/consoles/
- **Prometheus — HTTP API (`query`, `query_range`)** — https://prometheus.io/docs/prometheus/latest/querying/api/
- **Prometheus — Recording rules** — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- **Grafana — Prometheus data source** — https://grafana.com/docs/grafana/latest/datasources/prometheus/
- **Grafana — Configure the Prometheus data source (query editor, `$__rate_interval`)** — https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/
- **Grafana — Provision dashboards & data sources** — https://grafana.com/docs/grafana/latest/administration/provisioning/
- **Grafana — Global & built-in variables (`$__interval`, `$__rate_interval`, `$__range`)** — https://grafana.com/docs/grafana/latest/dashboards/variables/add-template-variables/
- **Grafana — Panels and visualizations** — https://grafana.com/docs/grafana/latest/panels-visualizations/
- **Grafana — HTTP API (datasources, dashboards, search, health)** — https://grafana.com/docs/grafana/latest/developers/http_api/
- **Grafana Operator (v5)** — https://grafana.github.io/grafana-operator/docs/
- **kube-prometheus-stack (Helm chart, Grafana sidecar)** — https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- **Grafana dashboards library (import by ID, e.g. Node Exporter Full #1860)** — https://grafana.com/grafana/dashboards/
- **The RED Method (Weave Works / Grafana Labs)** — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- **The USE Method (Brendan Gregg)** — https://www.brendangregg.com/usemethod.html