# 4.1 Dashboarding basics

> **Domain:** Alerting & Dashboarding · **Exam weight:** 4.5
> **Level:** Advanced — SRE / Platform Architect

---

## 1. Motivation: the architectural problem dashboards actually solve

Prometheus is a *pull-based, dimensional* time-series database. It scrapes `/metrics` endpoints, stores samples as `(metric_name{labels}, timestamp, float64)`, and exposes them over HTTP through two query endpoints:

- `GET/POST /api/v1/query` — **instant vector** at a single evaluation timestamp.
- `GET/POST /api/v1/query_range` — **range vector** evaluated at `step` intervals between `start` and `end`.

Everything visual sits *on top of* those two endpoints. The architectural question of "dashboarding" is therefore **not** "how do I draw a graph" — it is:

> How do I turn a raw, high-cardinality, pull-based TSDB into a **curated, low-latency, reproducible operational surface** that an on-call engineer can read in five seconds at 03:00, and that survives cluster rebuilds?

The naïve path — engineers typing PromQL into the built-in expression browser during an incident — fails in production for concrete reasons:

| Failure mode of ad-hoc querying | Consequence in production |
|---|---|
| Query knowledge lives in people's heads | On-call without tribal knowledge is blind |
| No shared time window / correlation | Two engineers look at different windows and disagree |
| Every panel re-computes heavy aggregations | Query load spikes exactly during incidents |
| No versioning of "what good looks like" | Baselines drift; regressions go unnoticed |
| Layout resets on every browser reload | No muscle memory, slow triage |

A dashboard is the **materialized, version-controlled contract** of what an SRE considers the health of a system. Treating it as *code* (provisioned, reviewed, diffable) rather than *clicks* is the single most important production discipline in this topic.

### 1.1 The three-layer visualization stack

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

Prometheus ships **two** native visualization surfaces that you must know for the exam, and both are deliberately minimal:

1. **Expression browser** (`http://<prometheus>:9090/graph`) — a Table/Graph tab for interactive PromQL. Excellent for *exploration and debugging*, never for standing dashboards. No persistence, no variables, no auth model of its own.
2. **Console templates** — Go-`html/template` pages served from `--web.console.templates` under `/consoles/`. These predate Grafana, render server-side, and are version-controlled files. They are effectively **legacy**; the ecosystem has consolidated on Grafana. Know that they exist and why they were superseded.

The design decision — Prometheus intentionally keeps visualization thin — is documented in the project's own guidance: *"Grafana … is the recommended way to visualize Prometheus data."* (see References).

---

## 2. Technical comparatives and trade-offs

### 2.1 Visualization layer choices

| | Expression browser | Console templates | **Grafana** | Perses |
|---|---|---|---|---|
| Persistence | None | Files on Prometheus host | DB + provisioning | GitOps-native CRDs |
| Variables / templating | No | Go template vars | Rich (`label_values`, chained) | Yes |
| Multi-datasource | Prometheus only | Prometheus only | 100+ sources, mixed panels | Prometheus-centric |
| AuthN/AuthZ | Inherits Prometheus | Inherits Prometheus | Users, teams, folder RBAC | K8s RBAC |
| Dashboards-as-code | N/A | Native (files) | JSON model + provisioning/operator | CRD-first |
| Production fit | Debug only | Legacy | **De-facto standard** | Emerging (CNCF sandbox) |

**Verdict for PCA:** Grafana is the answer for standing dashboards; the expression browser is the answer for ad-hoc PromQL debugging.

### 2.2 Data source access mode

| Mode | Path of the query | Use when |
|---|---|---|
| `access: proxy` (**server**) | Browser → Grafana backend → Prometheus | Almost always. Prometheus need not be reachable from the browser; credentials stay server-side. |
| `access: direct` (**browser**) | Browser → Prometheus directly | Deprecated / rare. Requires CORS + browser reachability; leaks endpoints. |

### 2.3 Query type per panel

| Query type | Endpoint used | Returns | Panel it feeds |
|---|---|---|---|
| **Range** | `/api/v1/query_range` | matrix (series over time) | Time series, Heatmap, State timeline |
| **Instant** | `/api/v1/query` | vector (one point per series, "now") | Stat, Gauge, Bar gauge, Table |

Choosing *instant* for a Stat panel and *range* for a time-series graph is the difference between a correct dashboard and one that silently over-queries the TSDB.

### 2.4 The step / interval trade-off (the detail that separates seniors)

Grafana injects macro variables into every PromQL query:

| Macro | Definition | Why it matters |
|---|---|---|
| `$__interval` | `time_range / max_data_points` (rounded to a "nice" step) | Sets the `step` of `query_range`. Too small → huge result, slow render; too large → aliasing. |
| `$__rate_interval` | `max($__interval + scrape_interval, 4 × scrape_interval)` | **Always use this inside `rate()`/`irate()`.** Guarantees ≥ 4 samples per window → no gaps, no NaN when zoomed in. |
| `$__range` | end − start of the dashboard time picker | For `_over_time` aggregations and totals. |
| `$__from` / `$__to` | epoch ms of the picker bounds | Annotations, links. |

**Trade-off table — `rate()` interval choice:**

| You write | Zoomed out (1h) | Zoomed in (5m) | Verdict |
|---|---|---|---|
| `rate(x[5m])` (hard-coded) | fine | fine only if scrape ≤ ~75s | brittle |
| `rate(x[$__interval])` | fine | **gaps / empty** (may be < scrape) | wrong |
| `rate(x[$__rate_interval])` | fine | fine | **correct** |

The `timeInterval` field on the data source (a.k.a. "Scrape interval") is what `$__rate_interval` reads to compute the floor — set it to your real `scrape_interval` or the macro is wrong.

### 2.5 Provisioning strategy

| Strategy | Source of truth | Drift risk | Best for |
|---|---|---|---|
| Manual UI clicks | Grafana DB | High | Prototyping only |
| **File provisioning** (`provisioning/*.yaml` + JSON) | Git | Low | Single-instance / Deployment |
| **Sidecar ConfigMap** (kube-prometheus-stack) | Git → ConfigMap → sidecar | Low | Kubernetes, dynamic discovery |
| **grafana-operator** (CRDs) | Git → CRD | Very low | Multi-tenant, multi-instance GitOps |
| Terraform provider | Git (HCL) | Low | Org-wide, cross-tool IaC |

Provisioned dashboards are **read-only in the UI** by default (`allowUiUpdates: false`) — this is a feature: it forces changes through review.

---

## 3. Complete infrastructure and manifests (uncut)

### 3.1 Grafana Prometheus data source — file provisioning

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

### 3.2 Dashboard provider — file provisioning

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

### 3.3 Kubernetes: Grafana Deployment + dashboard as ConfigMap

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

### 3.4 grafana-operator (v5) — dashboards as CRDs (GitOps)

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

### 3.5 kube-prometheus-stack — the sidecar pattern

The stack's Grafana runs a **sidecar** that watches for ConfigMaps/Secrets carrying a label and auto-imports them — no Grafana restart, no volume wiring. Enable and label:

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

Any `ConfigMap` labeled `grafana_dashboard: "1"` (see 3.3) is then imported automatically. Annotate it with `grafana_folder: "Platform"` to place it.

---

## 4. CLI and real terminal output

### 4.1 Confirm the data path *before* touching Grafana

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

`value[1] == "1"` → target healthy. If this fails, **no dashboard can work** — always debug bottom-up.

Range query (what a time-series panel issues):

```console
$ curl -s -G 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=sum(rate(http_requests_total[1m]))' \
    --data-urlencode "start=$(date -d '-5 min' +%s)" \
    --data-urlencode "end=$(date +%s)" \
    --data-urlencode 'step=15s' | jq '.status,.data.result[0].values | length'
"success"
21
```

21 points over 5 minutes at a 15s step = correct sampling.

### 4.2 promtool — validate PromQL offline

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

### 4.3 Grafana health and provisioning verification

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

### 4.4 Confirm the sidecar imported a ConfigMap

```console
$ kubectl -n monitoring get configmap -l grafana_dashboard=1
NAME                            DATA   AGE
grafana-dashboard-api-health    1      4m

$ kubectl -n monitoring logs deploy/grafana -c grafana-sc-dashboard | tail -3
{"time":"2026-08-08T12:01:07Z","msg":"Writing /tmp/dashboards/api-health.json (ADDED)"}
{"time":"2026-08-08T12:01:07Z","msg":"POST request sent to http://localhost:3000/api/admin/provisioning/dashboards/reload"}
{"time":"2026-08-08T12:01:08Z","msg":"reload successful, status: 200"}
```

### 4.5 grafana-cli (plugins for panel types)

```console
$ kubectl -n monitoring exec deploy/grafana -c grafana -- \
    grafana-cli plugins install grafana-piechart-panel
✔ Downloaded grafana-piechart-panel v1.6.4

$ kubectl -n monitoring exec deploy/grafana -c grafana -- grafana-cli plugins ls
installed plugins:
grafana-piechart-panel @ 1.6.4
```

---

## 5. Verification and failure diagnosis

Diagnose **bottom-up** along the three layers. The single most common mistake is debugging Grafana when the problem is one or two layers below.

### 5.1 Decision flow

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

### 5.2 Symptom → root cause → fix

| Symptom | Likely root cause | Verification | Fix |
|---|---|---|---|
| Panel "No data", query works in `:9090` | Datasource unreachable from Grafana pod | `curl .../datasources/uid/<uid>/health` → error | Fix `url`, `access: proxy`, DNS, NetworkPolicy |
| Graph has **gaps** when zoomed in | `rate([$__interval])` < scrape interval | Inspect → query panel; check `step` vs scrape | Use `rate(...[$__rate_interval])`; set `timeInterval` on DS |
| `histogram_quantile` returns `NaN`/flat | Not summing over `le`, or `_bucket` not scraped | Query `..._bucket` directly in `:9090` | `sum by (le, ...) (rate(..._bucket[$__rate_interval]))` |
| Dashboard slow / Prometheus CPU spikes on load | Heavy aggregation recomputed per panel, high cardinality | `topk(10, count by(__name__)({__name__=~".+"}))` | Add **recording rules**; reduce `max_data_points`; enable `incrementalQuerying` |
| Provisioned dashboard not appearing | Wrong provider `path`, or sidecar label missing | `curl /api/search`; check sidecar logs | Correct `options.path` or label `grafana_dashboard: "1"` |
| Can't edit dashboard in UI | `allowUiUpdates: false` (by design) | Provider YAML | Edit the JSON in Git, not the UI |
| Variable `$namespace` empty | `label_values()` targets a metric that doesn't exist | Run the variable query in `:9090` | Point at a live metric; set variable **Refresh: On time range change** |
| Values off by 1000× or wrong unit | Panel `unit` not set (bytes vs bits, s vs ms) | Panel → Field → Unit | Set correct unit; use `percentunit` for ratios |
| Datasource change ignored after edit | UID collision / not restarted | `curl /api/datasources` shows old URL | Ensure unique `uid`; provisioning reload / restart |

### 5.3 Recording rules — the production fix for dashboard latency

A dashboard that recomputes `histogram_quantile(0.99, sum by (le, route) (rate(...[5m])))` across every panel refresh is a self-inflicted load generator. Precompute:

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

The panel then queries the cheap precomputed series `job:http_request_duration_seconds:p99` — evaluated once per rule interval, not once per viewer. This is the intended interaction between the **Prometheus Fundamentals** and **Dashboarding** domains.

### 5.4 Golden-signal panel design (RED / USE)

Design panels around a method, not around whatever metric is convenient:

| Method | Signals | Fits |
|---|---|---|
| **RED** | **R**ate, **E**rrors, **D**uration | request-driven services |
| **USE** | **U**tilization, **S**aturation, **E**rrors | resources (CPU, disk, queue) |

Canonical RED trio (Grafana macros throughout):

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