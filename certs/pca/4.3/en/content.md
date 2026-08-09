# 4.3 — Understand and Use Alertmanager

> PCA Domain 4 (Observability / Alerting) · Topic weight **4.5** · Authoring language: English
> Target reader: SRE / Platform Architect running Prometheus + Alertmanager in production.

---

## 1. The production problem: why Prometheus alone cannot alert

Prometheus does exactly two alerting things and nothing more:

1. It **evaluates alerting rules** on every rule-group interval. When an expression returns a non-empty vector for at least `for`, the corresponding time series enters `firing`.
2. It **pushes** the firing (and resolved) alerts, as JSON, to every configured Alertmanager over `POST /api/v2/alerts`.

Everything a human actually cares about — *don't page me 500 times for one bad deploy, don't wake up the on-call for a `warning`, shut up during the maintenance window, page PagerDuty for `critical` but Slack for `warning`, and tell me when it's over* — is **not** in Prometheus. It lives in **Alertmanager**.

The architectural reason this is split is decoupling and fan-in:

```
                          POST /api/v2/alerts (every ~1m while firing)
 ┌────────────┐   ┌────────────┐          ┌──────────────────────────────┐
 │ Prometheus │──▶│            │          │        Alertmanager cluster    │
 │   (rules)  │   │ Prometheus │────────▶ │  am-0 ⇄ am-1 ⇄ am-2 (gossip)  │──▶ PagerDuty
 └────────────┘   │   (rules)  │────────▶ │  dedup · group · inhibit ·     │──▶ Slack
 ┌────────────┐   └────────────┘          │  silence · route · notify      │──▶ Email
 │ Prometheus │─────────────────────────▶ │                                │──▶ Webhook
 └────────────┘   many producers   →      └──────────────────────────────┘   few humans
```

Key consequences you must internalize for the exam and for production:

- **Prometheus does not deduplicate.** It sends the *same* alert to *all* Alertmanagers in the cluster. Deduplication is Alertmanager's job (via the gossiped notification log). This is deliberate: it makes the alerting path highly available without a leader.
- **Prometheus re-sends firing alerts periodically** (`--rules.alert.resend-delay`, default `1m`) so Alertmanager knows the alert is still active. Each alert carries a `startsAt` and an `endsAt`; if Prometheus stops sending, Alertmanager auto-resolves after `endsAt` (or after `global.resolve_timeout`, default `5m`, when `endsAt` is absent).
- **Alertmanager is stateful but not durable.** Its critical state (silences + the notification log / `nflog`) lives in memory and is gossiped across peers and periodically snapshotted to `--storage.path`. Losing a single instance loses nothing; losing the whole cluster loses silences and may re-notify.

---

## 2. The Alertmanager notification pipeline

An incoming alert traverses two layers: the **dispatcher** (grouping) and the per-receiver **notification pipeline** (the stages).

### 2.1 Dispatcher — routing and grouping

The **route tree** decides two things for every alert: which **receiver** it goes to, and how alerts are **grouped** (`group_by`). Alerts landing in the same route with the same values for the `group_by` labels form an **aggregation group**, which is the unit of a notification.

Three timers govern a group's cadence:

| Parameter | Default | Meaning | Tuning intuition |
|---|---|---|---|
| `group_wait` | `30s` | Buffer time before the **first** notification of a new group, so a burst collapses into one message. | Low for latency-sensitive pages (paging on-call), higher (e.g. `1m`) to batch. |
| `group_interval` | `5m` | Wait before sending an **update** when *new* alerts join an already-notified group. | Controls how fast you learn a group is growing. |
| `repeat_interval` | `4h` | Re-notify an **unchanged, still-firing** group. | The "nag" timer. `1h` for critical pages, `12h`+ for tickets. |

### 2.2 Per-receiver stages (in order)

For each receiver, Alertmanager builds a pipeline. The order matters and is a frequent source of "why didn't I get paged" incidents:

```
GossipSettle → Inhibit(MuteStage) → Silence(MuteStage) → TimeMute →
   Wait(HA position) → Dedup(nflog) → Retry(send) → SetNotifies(nflog)
```

1. **GossipSettle** — on startup, wait for the cluster to converge before sending, so a just-restarted peer doesn't double-notify.
2. **Inhibit** — drop this alert if a matching *source* alert (e.g. a `critical`) is currently active. See §5.3.
3. **Silence** — drop if a matching silence is active. See §5.4.
4. **TimeMute / TimeActive** — drop if inside a `mute_time_intervals` window (or *outside* an `active_time_intervals` window).
5. **Wait** — HA only: delay by `peer position × peer_timeout` (default `15s`) so peers don't all fire at once.
6. **Dedup** — check the gossiped `nflog`; if a peer already notified this exact group hash, skip.
7. **Retry** — actually call the integration (Slack/PagerDuty/…), retrying with backoff on transient failure.
8. **SetNotifies** — record success in the `nflog` and gossip it, so peers dedup.

### 2.3 Suppression mechanisms compared

These three are constantly confused. Learn the distinctions:

| Mechanism | Who defines it | Scope | Lifetime | Typical use |
|---|---|---|---|---|
| **Silence** | Operator (ad hoc, via UI/API/amtool) | Alerts matching label matchers | Explicit start/end (`--duration`) | "I'm doing maintenance on node1 for 2h." |
| **Inhibition** | Config (`inhibit_rules`) | Suppress *target* alerts while a *source* alert fires | As long as the source fires | "If the whole cluster is `critical` down, don't also page for every `warning` in it." |
| **Time interval mute** | Config (`time_intervals` + route) | A whole route/receiver | Recurring calendar windows | "No non-critical Slack noise on weekends / outside business hours." |

---

## 3. High availability: gossip and deduplication

Alertmanager is designed for HA **without** a leader or external quorum store. Peers form a mesh using HashiCorp `memberlist` gossip (default listen `0.0.0.0:9094`, TCP+UDP). They replicate two things: **silences** and the **notification log (`nflog`)**.

The dedup trick, precisely:

- Each peer computes a stable **peer position** (sorted by name in the cluster).
- The **Wait** stage delays notification by `position × peer-timeout`. Peer 0 waits `0s`, peer 1 waits `15s`, peer 2 waits `30s`.
- Peer 0 sends first, records success in its `nflog`, and gossips it. By the time peer 1's wait expires, its **Dedup** stage sees the entry and skips.
- If peer 0 is dead or slow (didn't gossip in time), peer 1 sends. This is **at-least-once**: a duplicate is possible during partitions, but a *missed* page is not. That is the correct bias for alerting.

| Topology | Availability | Duplicate risk | State loss risk | Recommended for |
|---|---|---|---|---|
| **Single instance** | None — SPOF | Zero | Silences/nflog lost on crash | Dev, lab, PCA practice |
| **2 peers** | Survives 1 loss | Low (window ≤ `peer-timeout`) | None if 1 survives | Small prod |
| **3 peers** (recommended) | Survives 2 loss / 1 partition side | Low | None | Production |
| **5+ peers** | Overkill; more gossip traffic | Slightly higher | None | Very large fleets |

> **Critical rule for HA:** point **every** Prometheus at **all** Alertmanager peers (do *not* load-balance in front of them). Prometheus fan-out + Alertmanager gossip dedup is the design. A single LB in front defeats the redundancy and can drop alerts if it fails.

Cluster flags (each peer):

```
--cluster.listen-address=0.0.0.0:9094
--cluster.peer=am-0.alertmanager:9094
--cluster.peer=am-1.alertmanager:9094
--cluster.peer=am-2.alertmanager:9094
--cluster.peer-timeout=15s
--cluster.gossip-interval=200ms
--cluster.pushpull-interval=1m0s
--cluster.settle-timeout=1m0s
```

---

## 4. Complete, valid manifests

### 4.1 Prometheus side — pointing at the cluster and loading rules

`prometheus.yml` (relevant sections, complete):

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s        # how often alerting rules are evaluated
  external_labels:
    cluster: prod-eu-west-1        # attached to every alert; used in group_by/inhibit `equal`
    replica: prom-a                # HA Prometheus pair; Alertmanager dedups across replicas

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alert_relabel_configs:
    # Drop the replica label so the HA Prometheus pair produce identical alerts
    # that Alertmanager can deduplicate.
    - source_labels: [replica]
      action: labeldrop
  alertmanagers:
    - api_version: v2
      path_prefix: /
      timeout: 10s
      static_configs:
        - targets:
            - alertmanager-0.alertmanager:9093
            - alertmanager-1.alertmanager:9093
            - alertmanager-2.alertmanager:9093
      # In Kubernetes you would instead use kubernetes_sd_configs + relabeling:
      # kubernetes_sd_configs:
      #   - role: endpoints
      #     namespaces: { names: [monitoring] }
      # relabel_configs:
      #   - source_labels: [__meta_kubernetes_service_name]
      #     regex: alertmanager
      #     action: keep
```

`/etc/prometheus/rules/latency.yml` — a real alerting rule group with `for` and `keep_firing_for`:

```yaml
groups:
  - name: api-slo
    interval: 15s
    rules:
      # Recording rule feeding the alert (keeps the alert expr cheap and stable)
      - record: job:http_request_duration_seconds:p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      - alert: HighRequestLatency
        expr: job:http_request_duration_seconds:p99_5m{job="payments-api"} > 0.5
        for: 10m                 # must hold 10m before firing (inactive→pending→firing)
        keep_firing_for: 5m      # stay firing 5m after it recovers, to avoid flapping
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "p99 latency on {{ $labels.job }} is {{ $value | humanizeDuration }}"
          description: >-
            p99 request latency is above 500ms for 10m on {{ $labels.job }}
            in cluster {{ $externalLabels.cluster }}.
          runbook_url: https://runbooks.example.com/payments/high-latency

      - alert: TargetDown
        expr: up{job="payments-api"} == 0
        for: 2m
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "Target {{ $labels.instance }} is down"
```

### 4.2 Alertmanager side — a full `alertmanager.yml`

This is intentionally not truncated: route tree, receivers, inhibition, time intervals, and templating.

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: smtp.example.com:587
  smtp_from: alertmanager@example.com
  smtp_auth_username: alertmanager@example.com
  smtp_auth_password_file: /etc/alertmanager/secrets/smtp_password
  slack_api_url_file: /etc/alertmanager/secrets/slack_url
  http_config:
    follow_redirects: true

templates:
  - /etc/alertmanager/templates/*.tmpl

# ---- Recurring calendar windows referenced by the route tree ----
time_intervals:
  - name: outside-business-hours
    time_intervals:
      - weekdays: ['saturday', 'sunday']
      - times:
          - start_time: '00:00'
            end_time: '09:00'
          - start_time: '18:00'
            end_time: '24:00'
        weekdays: ['monday:friday']
        location: 'Europe/Madrid'

# ---- The routing tree ----
route:
  receiver: default-email               # catch-all fallback
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # 1) Anything critical → PagerDuty, page fast, nag hourly.
    - matchers:
        - severity = "critical"
      receiver: pagerduty-critical
      group_wait: 10s
      repeat_interval: 1h
      continue: true            # keep evaluating siblings so it also lands in Slack

    # 2) Team-based fan-out for the payments team.
    - matchers:
        - team = "payments"
      receiver: payments-slack
      routes:
        # Mute non-critical payments noise outside business hours.
        - matchers:
            - severity =~ "warning|info"
          receiver: payments-slack
          mute_time_intervals:
            - outside-business-hours

    # 3) Watchdog / dead-man's-switch always-firing alert → healthcheck webhook.
    - matchers:
        - alertname = "Watchdog"
      receiver: 'null'
      group_wait: 0s
      group_interval: 1m
      repeat_interval: 1m

receivers:
  - name: 'null'                # black hole (used by Watchdog handled elsewhere)

  - name: default-email
    email_configs:
      - to: sre@example.com
        send_resolved: true

  - name: pagerduty-critical
    pagerduty_configs:
      - routing_key_file: /etc/alertmanager/secrets/pd_routing_key
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
        send_resolved: true
        description: '{{ .CommonAnnotations.summary }}'
        details:
          cluster: '{{ .CommonLabels.cluster }}'
          num_firing: '{{ .Alerts.Firing | len }}'

  - name: payments-slack
    slack_configs:
      - channel: '#payments-alerts'
        send_resolved: true
        title: '{{ template "slack.title" . }}'
        text: '{{ template "slack.text" . }}'
        actions:
          - type: button
            text: 'Runbook'
            url: '{{ (index .Alerts 0).Annotations.runbook_url }}'

# ---- Inhibition: a critical suppresses warnings for the same service ----
inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'cluster', 'service']

  # If a whole node is down, don't also alert on individual pods on it.
  - source_matchers:
      - alertname = "NodeDown"
    target_matchers:
      - alertname =~ "PodNotReady|KubeletDown"
    equal: ['node']
```

Custom template `/etc/alertmanager/templates/slack.tmpl`:

```
{{ define "slack.title" }}[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}{{ end }}

{{ define "slack.text" }}
{{ range .Alerts -}}
*Severity:* {{ .Labels.severity }}
*Summary:* {{ .Annotations.summary }}
*Cluster:* {{ .Labels.cluster }}
{{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
{{ end }}
{{ end }}
```

### 4.3 Kubernetes: HA Alertmanager as a StatefulSet

A raw (non-Operator) HA deployment. The headless Service gives stable DNS names for gossip peers.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: monitoring
  labels: { app: alertmanager }
spec:
  clusterIP: None            # headless → per-pod DNS: alertmanager-0.alertmanager...
  selector: { app: alertmanager }
  ports:
    - { name: web,     port: 9093, targetPort: 9093 }
    - { name: gossip-tcp, port: 9094, targetPort: 9094, protocol: TCP }
    - { name: gossip-udp, port: 9094, targetPort: 9094, protocol: UDP }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  serviceName: alertmanager
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: alertmanager }
  template:
    metadata:
      labels: { app: alertmanager }
    spec:
      containers:
        - name: alertmanager
          image: quay.io/prometheus/alertmanager:v0.27.0
          args:
            - --config.file=/etc/alertmanager/alertmanager.yml
            - --storage.path=/alertmanager
            - --data.retention=120h
            - --web.listen-address=0.0.0.0:9093
            - --web.external-url=https://alertmanager.example.com
            - --cluster.listen-address=0.0.0.0:9094
            - --cluster.peer=alertmanager-0.alertmanager:9094
            - --cluster.peer=alertmanager-1.alertmanager:9094
            - --cluster.peer=alertmanager-2.alertmanager:9094
            - --cluster.peer-timeout=15s
          ports:
            - { name: web, containerPort: 9093 }
            - { name: gossip-tcp, containerPort: 9094, protocol: TCP }
            - { name: gossip-udp, containerPort: 9094, protocol: UDP }
          readinessProbe:
            httpGet: { path: /-/ready, port: 9093 }
            initialDelaySeconds: 10
          livenessProbe:
            httpGet: { path: /-/healthy, port: 9093 }
          volumeMounts:
            - { name: config, mountPath: /etc/alertmanager }
            - { name: data,   mountPath: /alertmanager }
      volumes:
        - name: config
          configMap: { name: alertmanager-config }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        resources: { requests: { storage: 1Gi } }
```

### 4.4 Prometheus Operator: `AlertmanagerConfig` CRD

If you run kube-prometheus-stack, you author routing per-namespace declaratively:

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: payments-routing
  namespace: payments
  labels:
    alertmanagerConfig: prod      # must match Alertmanager CR's configSelector
spec:
  route:
    receiver: payments-slack
    groupBy: ['alertname', 'severity']
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: team
        value: payments
        matchType: '='
  receivers:
    - name: payments-slack
      slackConfigs:
        - channel: '#payments-alerts'
          sendResolved: true
          apiURL:
            name: slack-webhook      # references a Secret
            key: url
  inhibitRules:
    - sourceMatch:
        - name: severity
          value: critical
      targetMatch:
        - name: severity
          value: warning
      equal: ['alertname', 'service']
```

---

## 5. CLI and terminal walkthroughs (`$`)

### 5.1 Validate config before shipping it (`amtool`)

```
$ amtool check-config /etc/alertmanager/alertmanager.yml
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
Found:
 - global config
 - route
 - 2 inhibit rules
 - 5 receivers
 - 1 time interval
 - 1 template file
```

A broken config fails loudly (and Alertmanager refuses to reload it):

```
$ amtool check-config alertmanager.yml
Checking 'alertmanager.yml'  FAILED: undefined receiver "payments-slak" used in route
```

### 5.2 Inspect and *test* the routing tree

```
$ amtool config routes show --config.file=alertmanager.yml
Routing tree:
.
└── default-route  receiver: default-email
    ├── {severity="critical"}   receiver: pagerduty-critical  continue: true
    ├── {team="payments"}       receiver: payments-slack
    │   └── {severity=~"warning|info"}  receiver: payments-slack
    └── {alertname="Watchdog"}  receiver: null
```

Test which receiver(s) a hypothetical alert would hit — this catches routing bugs before they page:

```
$ amtool config routes test --config.file=alertmanager.yml \
    severity=critical team=payments service=payments-api
pagerduty-critical
payments-slack
```

```
$ amtool config routes test --config.file=alertmanager.yml \
    --verify.receivers=pagerduty-critical severity=critical
pagerduty-critical
```

### 5.3 Query live alerts

```
$ amtool alert query --alertmanager.url=http://localhost:9093
Alertname          Starts At                Summary                                  State
HighRequestLatency 2026-08-09 09:12:04 UTC  p99 latency on payments-api is 812ms     active
TargetDown         2026-08-09 09:15:41 UTC  Target 10.0.3.7:8080 is down             suppressed
Watchdog           2026-08-09 06:00:00 UTC  This is an always-firing alert           active
```

`suppressed` above = inhibited or silenced. Filter to just the suppressed ones:

```
$ amtool alert query --alertmanager.url=http://localhost:9093 \
    'severity="warning"' --output=extended
```

### 5.4 Silences (the maintenance workflow)

```
$ amtool silence add \
    --alertmanager.url=http://localhost:9093 \
    --author="sre@example.com" \
    --duration="2h" \
    --comment="Rolling node1 kernel upgrade — ticket OPS-4821" \
    alertname="TargetDown" instance=~"node1.*"
b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa

$ amtool silence query --alertmanager.url=http://localhost:9093
ID                                   Matchers                          Ends At                  Comment
b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa alertname="TargetDown" instance=~ 2026-08-09 11:34 UTC     Rolling node1 kernel upgrade...

$ amtool silence expire b3ede22e-ca14-4aa0-a7d1-2f0e5cf6c1aa \
    --alertmanager.url=http://localhost:9093
```

### 5.5 Fire a synthetic alert end-to-end (integration test)

```
$ amtool alert add --alertmanager.url=http://localhost:9093 \
    alertname="SmokeTest" severity="warning" team="payments" \
    --annotation=summary="pipeline smoke test" \
    --start="2026-08-09T09:00:00Z"
```

Or hit the raw v2 API (what Prometheus does):

```
$ curl -sS -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {"alertname":"SmokeTest","severity":"warning","team":"payments"},
    "annotations": {"summary":"pipeline smoke test"},
    "startsAt": "2026-08-09T09:00:00Z",
    "endsAt":   "2026-08-09T09:10:00Z"
  }
]'
```

### 5.6 Hot-reload configuration (no restart)

```
$ curl -sS -XPOST http://localhost:9093/-/reload      # requires --web.enable-lifecycle
$ # or, in-place:
$ kill -HUP $(pidof alertmanager)
```

Confirm the reload actually took (see the metric in §6).

---

## 6. Verification and failure diagnosis

### 6.1 The "did my alert get delivered?" ladder

Trace the alert through each hop; each hop has a metric that either proves success or localizes the fault.

| Symptom | Where to look | Metric / check |
|---|---|---|
| Alert fires in Prometheus but Alertmanager never sees it | Prometheus → AM link | `prometheus_notifications_dropped_total`, `prometheus_notifications_errors_total{alertmanager=...}`, `prometheus_notifications_sent_total`, `prometheus_notifications_queue_length` vs `_capacity` |
| Prometheus discovers 0 Alertmanagers | Prometheus SD | `prometheus_notifications_alertmanagers_discovered` (should equal peer count); check `/api/v1/alertmanagers` |
| AM receives the alert but never notifies | AM pipeline | Alert shows `suppressed` in `amtool alert query` → check silences/inhibition/time-mute |
| Notification attempted but failing | AM → integration | `alertmanager_notifications_failed_total{integration="slack"}` climbing; check integration logs |
| Getting duplicate pages | AM HA / dedup | `alertmanager_cluster_health_score` (0 = healthy), `alertmanager_cluster_members`, `alertmanager_cluster_failed_peers` |
| Config change didn't apply | AM reload | `alertmanager_config_last_reload_successful` == 1, `alertmanager_config_last_reload_success_timestamp_seconds` |

### 6.2 Prometheus side — is it even reaching Alertmanager?

```
$ curl -sS http://localhost:9090/api/v1/alertmanagers | jq
{
  "status": "success",
  "data": {
    "activeAlertmanagers": [
      {"url": "http://alertmanager-0.alertmanager:9093/api/v2/alerts"},
      {"url": "http://alertmanager-1.alertmanager:9093/api/v2/alerts"},
      {"url": "http://alertmanager-2.alertmanager:9093/api/v2/alerts"}
    ],
    "droppedAlertmanagers": []
  }
}
```

If `activeAlertmanagers` is empty → service discovery / relabeling / network is broken; nothing downstream matters yet. Check:

```
$ curl -sS 'http://localhost:9090/api/v1/query?query=prometheus_notifications_errors_total' | jq '.data.result'
$ curl -sS 'http://localhost:9090/api/v1/query?query=prometheus_notifications_queue_length' | jq '.data.result'
```

A `queue_length` approaching `queue_capacity` (default 10000) means Alertmanager can't keep up and Prometheus is about to *drop* alerts (`prometheus_notifications_dropped_total` rising) — a genuine "we lost alerts" incident.

Confirm the rule is actually firing in Prometheus itself (synthetic `ALERTS` series):

```
$ curl -sS 'http://localhost:9090/api/v1/query?query=ALERTS{alertstate="firing"}' | jq '.data.result[].metric'
```

### 6.3 Alertmanager side — cluster health

```
$ curl -sS http://localhost:9093/api/v2/status | jq '.cluster'
{
  "name": "01J...",
  "status": "ready",
  "peers": [
    {"name": "01J...a", "address": "10.0.1.5:9094"},
    {"name": "01J...b", "address": "10.0.1.6:9094"},
    {"name": "01J...c", "address": "10.0.1.7:9094"}
  ]
}
```

Health-score PromQL to alert on your alerting (meta-monitoring — **always do this**):

```
# Cluster unhealthy
max(alertmanager_cluster_health_score) > 0

# A peer went missing
alertmanager_cluster_members < 3

# Config failed to reload
alertmanager_config_last_reload_successful == 0

# Notifications failing to an integration
rate(alertmanager_notifications_failed_total[5m]) > 0
```

### 6.4 The dead-man's-switch (Watchdog)

The single most important verification pattern: an alert that is **always firing** (`expr: vector(1)`), routed to a receiver that expects a *heartbeat*. If the heartbeat stops, an external system pages you — proving the *entire* pipeline (Prometheus rules → send → Alertmanager → route → notify) is alive. Without it, a broken alerting pipeline is silent by definition.

```yaml
- alert: Watchdog
  expr: vector(1)
  labels: { severity: none }
  annotations:
    summary: "Alerting pipeline is alive. If this stops, alerting is broken."
```

### 6.5 Common failure modes and root cause

| Failure | Root cause | Fix |
|---|---|---|
| No page, alert `suppressed` | Overlapping inhibit rule or forgotten silence | `amtool silence query`; check `inhibit_rules` `equal` labels |
| No page, alert not even in AM | `alert_relabel_configs` dropped a needed label, or SD returns 0 AMs | `amtool config routes test` with the real labels; check `/api/v1/alertmanagers` |
| Wrong receiver | Route matcher precedence / missing `continue: true` | `amtool config routes test`; remember first match wins unless `continue` |
| Duplicate pages | Peers can't gossip (port 9094 blocked), so no dedup | Open TCP+UDP 9094; check `alertmanager_cluster_failed_peers` |
| Alert never resolves | Prometheus stopped sending but `resolve_timeout` too long, or receiver lacks `send_resolved: true` | Set `send_resolved: true`; verify `endsAt` propagation |
| Flapping notifications | No `for` / no `keep_firing_for`, or `group_interval` too low | Add `for`, `keep_firing_for`; raise `repeat_interval` |
| Config edit ignored | `--web.enable-lifecycle` not set, so `/-/reload` 405s | Enable the flag or `SIGHUP`; verify `config_last_reload_successful` |

### 6.6 Matcher syntax — the deprecation trap

Old `match` / `match_re` (map form) are deprecated in favor of the `matchers` list. Learn both; production configs still mix them.

| Old (deprecated) | New (`matchers` list) |
|---|---|
| `match: {severity: critical}` | `matchers: ['severity="critical"']` |
| `match_re: {service: (foo|bar)}` | `matchers: ['service=~"foo|bar"']` |
| — | `matchers: ['team!="db"']`, `matchers: ['env!~"dev|stg"']` |

Values in the new syntax are always **quoted**; the operators are `=`, `!=`, `=~`, `!~`.

---

## 7. References

- Alertmanager overview — https://prometheus.io/docs/alerting/latest/alertmanager/
- Alertmanager configuration reference — https://prometheus.io/docs/alerting/latest/configuration/
- Notification examples & templating — https://prometheus.io/docs/alerting/latest/notification_examples/ and https://prometheus.io/docs/alerting/latest/notifications/
- High availability — https://github.com/prometheus/alertmanager#high-availability
- `amtool` documentation — https://github.com/prometheus/alertmanager#amtool
- Alertmanager HTTP API (v2, OpenAPI) — https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml
- Prometheus alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus `alerting` / `alertmanager_config` — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
- Prometheus alertmanager overview — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/ and https://prometheus.io/docs/practices/alerting/
- Prometheus Operator `AlertmanagerConfig` CRD — https://prometheus-operator.dev/docs/developer/alerting/ and https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api-reference/api.md
- PCA Curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf