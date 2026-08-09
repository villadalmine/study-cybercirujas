# Topic 4.2 — Configuring Alerting Rules

> Domain 4 · Exam weight **4.5** · Profile: production SRE / Platform Architect
> Prometheus authors *alerts*; Alertmanager *routes* them. This topic is about the first half: turning a PromQL expression into a stateful, deduplicated, well-labeled alert that the notification pipeline can act on — and doing it so it survives reloads, restarts, evaluation lag, and flapping without waking anyone at 3 a.m. for nothing.

---

## 1. Motivation and the production architecture problem

An alert is a *control loop over a time series*. The naïve mental model — "when this metric crosses a line, send an email" — hides four hard problems that every production Prometheus deployment eventually hits:

1. **Statefulness across a stateless scrape model.** Prometheus scrapes are point-in-time. A crossing at scrape *N* means nothing on its own; a real incident is a *sustained* crossing. The alerting engine has to hold state (`inactive → pending → firing`) between evaluations, and hold it correctly across config reloads and process restarts — otherwise every deploy re-arms every alert and re-pages the on-call.

2. **Separation of detection from routing.** Detection (is something wrong?) belongs next to the data, in Prometheus, expressed in PromQL. Routing/dedup/silencing (who hears about it, and how loudly?) belongs in Alertmanager. Collapsing these two into one layer is the single most common architectural mistake: it couples "what is broken" to "who is on call this week," and makes both untestable.

3. **Evaluation cost vs. freshness.** Rules run synchronously inside a rule group on a fixed interval. A group whose rules take longer to evaluate than its `interval` silently falls behind — `prometheus_rule_group_iterations_missed_total` climbs, alerts fire late, and nobody notices because *the alert about slow alerting doesn't fire in time either*.

4. **Alert fatigue is a reliability regression.** An alert that pages on a *cause* ("node has 90% memory") instead of a *symptom* ("users are getting 500s") pages constantly and trains the on-call to ignore the pager. The Google SRE model — page on symptoms that violate an SLO, ticket on causes — has to be *encoded in the rule expressions*, not left to human discipline.

The deliverable of this topic is a set of **alerting rules** stored in **rule files** (or `PrometheusRule` CRDs under the Operator), loaded by Prometheus, evaluated on a schedule, and shipped to Alertmanager over HTTP. Everything below is about writing those rules so they are correct, testable, and operationally boring.

### Where alerting rules sit in the pipeline

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

Prometheus never sends a "notification." It sends a stream of **active alert objects** (with `startsAt`/`endsAt`) to *every* configured Alertmanager, and keeps re-sending firing alerts on `resend-delay`. Alertmanager is responsible for turning that stream into pages, tickets, and Slack messages. Keeping this boundary crisp is what makes the system diagnosable.

---

## 2. Anatomy of an alerting rule

A rule file is a set of **groups**; each group is an ordered list of **rules**. A rule is either a *recording rule* (`record:`) or an *alerting rule* (`alert:`). Never mix the two keys in one rule.

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

### Field semantics that matter in production

| Field | Purpose | Gotcha |
|---|---|---|
| `alert` | Sets the `alertname` label. | Must be unique *conceptually*, not syntactically — two rules can share a name and produce distinct alerts if their other labels differ. |
| `expr` | Instant-vector PromQL. Every returned series becomes one alert instance. | If `expr` returns a *range vector* or *scalar*, the rule errors. `> bool 0` returns a scalar → won't work; drop the `bool`. |
| `for` | The condition must hold *continuously* for this duration before `firing`. During that window the alert is `pending`. | If a single evaluation returns empty, the timer resets. Set `for` ≥ 2–3× the scrape interval so one missed scrape doesn't reset it. Omitting `for` fires on the first true evaluation (noisy). |
| `keep_firing_for` | Keep the alert `firing` for this long *after* `expr` stops returning it. | Anti-flap for oscillating conditions. Distinct from `for` (which is entry damping); `keep_firing_for` is exit damping. Requires Prometheus **v2.42.0+**. |
| `labels` | Static/templated labels merged onto each result series. Define the alert's **identity** (alongside expr labels + `alertname`). | Changing a label creates a *new* alert (resets `for`). Templating is allowed but keep it deterministic; a label whose value churns fragments the alert into many identities. |
| `annotations` | Human-facing metadata (summary, description, dashboard/runbook links). Templated. **Not** part of identity. | Safe to change freely; updates propagate on the next resend without resetting state. Put anything volatile (`$value`) here, never in `labels`. |

### The alert lifecycle (state machine)

```
             expr returns series                 for elapsed while true
  inactive ──────────────────────▶ pending ──────────────────────────▶ firing
     ▲                                │                                    │
     │      expr empty (timer reset)  │       expr empty                   │ expr empty
     └────────────────────────────────┘◀───────────────────────────────── │  AND keep_firing_for elapsed
                                                                           │
                                        (during keep_firing_for window, stays firing)
```

Every evaluation, Prometheus materializes two synthetic series *per active alert*:

- `ALERTS{alertname="…", alertstate="pending"|"firing", <all alert labels>}` — value `1` while active. **You can query and alert on this**, e.g. count how many alerts are firing.
- `ALERTS_FOR_STATE{…}` — value is the Unix timestamp when the alert first became active. This is what lets Prometheus **restore the `for` timer after a restart** instead of re-arming from zero.

```promql
# How many critical alerts are firing per team right now?
count by (team) (ALERTS{severity="critical", alertstate="firing"})
```

---

## 3. Comparative trade-offs

### 3.1 Recording rule vs. alerting rule for the threshold

You can compute an expensive ratio inline in the alert `expr`, or precompute it with a recording rule and alert on the recorded series.

| Approach | Latency | Reuse | Testability | Cost | When |
|---|---|---|---|---|---|
| **Threshold inline in `expr`** | 1 evaluation | none | test the whole rule at once | recomputes every group interval | Simple, cheap expressions; one consumer. |
| **Recording rule + alert on it** | +1 group interval (rule → recorded series → alert reads it next cycle) | dashboards + multiple alerts reuse the series | recorded series testable independently | amortized; heavy PromQL runs once | Expensive aggregations (`histogram_quantile`, high-cardinality `sum by`), SLO burn rates, anything a dashboard also uses. |

**Rule of thumb:** if a subexpression appears in more than one alert *or* in a dashboard, promote it to a recording rule with a `level:metric:operation` naming convention (`job:http_requests:rate5m`). This is the single biggest lever on rule-engine CPU.

### 3.2 `for` vs. `keep_firing_for`

| | `for` | `keep_firing_for` |
|---|---|---|
| Damps | Entry (false positives) | Exit (flapping) |
| State while active-but-not-committed | `pending` | `firing` |
| Effect on paging | Delays the page | Extends/holds the page open |
| Typical value | 2–15 min (symptom), longer for causes | 1–5 min |
| Risk if too large | Slow to detect real incidents | Slow to auto-resolve, stale pages |

Use both together for oscillating signals (e.g. a latency SLO that hovers at the threshold): `for: 5m` to confirm, `keep_firing_for: 5m` so it doesn't resolve/re-fire every scrape.

### 3.3 Symptom-based vs. cause-based alerting

| | Symptom (page) | Cause (ticket/inhibit) |
|---|---|---|
| Question answered | "Are users affected?" | "Why might users be affected soon?" |
| Example | `error ratio > SLO burn threshold` | `disk will fill in 4h` |
| Cardinality of pages | Low (one per user-facing service) | High if paged |
| Routing | `severity: critical` → page | `severity: warning` → ticket/dashboard |
| SRE guidance | Alert here | Ticket or use as **inhibition source** in Alertmanager |

### 3.4 Static rule files vs. `PrometheusRule` CRD (Operator)

| | Rule files (`rule_files:`) | `PrometheusRule` CRD |
|---|---|---|
| Delivery | Mounted files + reload | Kubernetes API + operator reconciliation |
| Selection | Glob path | `ruleSelector` label matching on the `Prometheus` CR |
| Validation | `promtool check rules` in CI | operator admission + `promtool` |
| Multi-tenant | one file set per Prometheus | many CRDs across namespaces, merged |
| Reload | `POST /-/reload` or SIGHUP | operator writes config + triggers reload automatically |
| Best for | VMs, bare Prometheus, tight control | Kubernetes, GitOps, per-team ownership |

---

## 4. Complete manifests and infrastructure (unabridged)

### 4.1 Wiring rules and Alertmanager into `prometheus.yml`

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

Two production-critical details:

- **`external_labels` + a per-replica `replica` label** is how you run Prometheus in HA (two identical replicas both alerting). Alertmanager deduplicates on the identical label set *minus* `replica` — so both replicas paging produces **one** page. Forget the `replica` label and you get double pages; forget `external_labels` entirely and Alertmanager can't tell clusters apart.
- **Send to *all* Alertmanagers, not a load-balanced one.** Prometheus fans out to every discovered Alertmanager; the Alertmanager cluster itself gossips to dedup. Putting a single VIP in front defeats HA.

### 4.2 A production rule file: SLO burn-rate + infrastructure

This file combines the recommended patterns: recording rules feed multi-window multi-burn-rate SLO alerts (symptom, pages), plus a capacity alert (cause, ticket) and a self-monitoring meta-alert.

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

### 4.3 The same alerts as a `PrometheusRule` CRD (Operator / Kubernetes)

The Prometheus Operator watches `PrometheusRule` objects whose labels match the `Prometheus` CR's `ruleSelector`, renders them into the config, and triggers a reload. This is the CNCF-native delivery path.

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

> The operator runs `promtool`-equivalent validation and rejects a malformed `PrometheusRule` at admission — but only for syntax. Semantic correctness (does the alert fire when it should?) is still your job via unit tests (§5.3).

### 4.4 Annotation templating reference

Annotations and label values are rendered with Go's `text/template`. The variables and the most useful functions:

| Expression | Yields |
|---|---|
| `{{ $labels.instance }}` | value of the `instance` label on this alert series |
| `{{ $value }}` | the numeric value of the alert's sample |
| `{{ $externalLabels.cluster }}` | an `external_labels` value |
| `{{ $value | humanize }}` | `12.3k` style SI formatting |
| `{{ $value | humanizePercentage }}` | `0.0144` → `1.44%` |
| `{{ $value | humanizeDuration }}` | seconds → `3m 20s` |
| `{{ $labels.job | toUpper }}` | uppercase |
| `{{ printf "%.2f" $value }}` | fixed precision |
| `{{ reReplaceAll ":.*" "" $labels.instance }}` | strip `:port` from `instance` |
| `{{ range query "up == 0" }}{{ .Labels.instance }} {{ end }}` | run a PromQL query at render time and iterate |
| `{{ with query "..." }}{{ . | first | value }}{{ end }}` | single-value lookup |

Keep templates side-effect-free and cheap: they render on **every notification resend**, and a `query` in a template that fans out over high cardinality can dominate notification latency.

---

## 5. CLI commands and real terminal output

### 5.1 Validate rule syntax before shipping (CI gate)

```console
$ promtool check rules /etc/prometheus/rules/checkout-slo.yml
Checking /etc/prometheus/rules/checkout-slo.yml
  SUCCESS: 4 groups found
  SUCCESS: 14 rules found

$ echo $?
0
```

A broken rule fails loudly and non-zero (wire this into CI):

```console
$ promtool check rules bad.yml
Checking bad.yml
  FAILED:
group "checkout.slo.alerts", rule 1, "CheckoutErrorBudgetBurnFast": could not parse expression: 1:38: parse error: unexpected character: '&'

$ echo $?
1
```

### 5.2 Inspect live rule and alert state

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

Confirm Prometheus actually knows where to send alerts:

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

An empty `activeAlertmanagers` list means alerts are being computed but **cannot leave Prometheus** — the most common "why didn't I get paged" root cause.

### 5.3 Unit-test alerting rules with `promtool test rules`

This is how you prove an alert fires *at the right time* without waiting for a real incident. The test file feeds synthetic input series and asserts the alert state at chosen evaluation times.

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

A failing assertion shows the exact diff between expected and actual — invaluable when someone bumps a threshold:

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

`got:[]` means the alert didn't fire when the test expected it — usually a `for:` longer than the test window, or a threshold that no longer matches the input.

### 5.4 Hot-reload after changing rules

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

A reload with a broken rule file **keeps the old config running** and logs the error — it does not crash Prometheus, so always check the log/`/-/reload` HTTP status, not just "the process is up":

```console
$ curl -s -X POST http://localhost:9090/-/reload -w '%{http_code}\n'
failed to reload config: ... couldn't load rule file: ... parse error
400
```

---

## 6. Verification and failure diagnosis

A disciplined checklist, ordered by where alerts break in practice.

### 6.1 The four-question triage ladder

| Symptom | First question | Command / query | Likely cause |
|---|---|---|---|
| Alert never fires | Does the `expr` return data *now*? | Paste `expr` into `/graph` | Wrong label matchers, `bool` sneaking in, empty result resets `for`. |
| Alert fires late | Is the rule group falling behind? | `prometheus_rule_group_iterations_missed_total` > 0 | Group evaluation slower than `interval`; split the group or precompute. |
| Alert fires but no page | Can Prometheus reach Alertmanager? | `/api/v1/alertmanagers` → `activeAlertmanagers` empty? | SD/relabel wrong, network, wrong `api_version`. |
| Page storm / flapping | Is `for`/`keep_firing_for` set? Right identity? | `/rules` page states; `ALERTS` cardinality | No damping, or a volatile label in `labels:` fragmenting identity. |

### 6.2 Rule-engine health signals to scrape and alert on

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

`prometheus_notifications_dropped_total` incrementing is a silent-failure alarm: Prometheus is *discarding* alerts because the queue to Alertmanager is full or Alertmanager is unreachable. Nothing else surfaces this.

### 6.3 `for`-state survival across restarts

After a restart, Prometheus does **not** re-arm every `pending`/`firing` alert from zero — it restores state from the `ALERTS_FOR_STATE` series, bounded by three flags:

| Flag | Default | Meaning |
|---|---|---|
| `--rules.alert.for-outage-tolerance` | `1h` | Max downtime for which `for` state is still restored (beyond this, restart from `pending`). |
| `--rules.alert.for-grace-period` | `10m` | Minimum `for` window enforced after restore, so a just-restored alert isn't fired instantly. |
| `--rules.alert.resend-delay` | `1m` | How often firing alerts are re-pushed to Alertmanager while active. |

Diagnosis: if a rolling restart re-pages the on-call, check that (a) the outage was under `for-outage-tolerance`, and (b) `ALERTS_FOR_STATE` is being retained (it lives in the TSDB like any series). In HA, the *second* replica seamlessly covers, which is another reason to run two.

### 6.4 Common concrete failures and their fix

1. **`expr` uses `> bool 0`.** Returns a scalar/`0|1` vector instead of filtering — the rule "fires" constantly (value `0` still counts as a returned series). **Fix:** drop `bool`; use `up == 0`, not `up == bool 0`.
2. **`for` shorter than 2× scrape interval.** A single missed scrape empties the result and resets the timer, so the alert never reaches `firing`. **Fix:** `for` ≥ `2–3 × scrape_interval`.
3. **Volatile label in `labels:` (e.g. `{{ $value }}`).** Every evaluation mints a *new* alert identity → `for` never accumulates, and Alertmanager sees a storm of one-shot alerts. **Fix:** volatile data goes in `annotations` only.
4. **Recording rule referenced by an alert lives in a *later* group.** The alert reads a stale/absent series on the first cycle. **Fix:** put producers before consumers; within a group rules run in order, so recording rules should precede alerts that use them (or live in an earlier group).
5. **`ruleSelector` mismatch (Operator).** `PrometheusRule` labels don't match the `Prometheus` CR's selector → rules silently ignored. **Fix:** verify with `kubectl get prometheusrule -n monitoring --show-labels` and compare to `.spec.ruleSelector`.
6. **HA double-paging.** Both replicas send without a distinguishing `replica` external label being *stripped* by Alertmanager. **Fix:** identical `external_labels` except a `replica` label; ensure Alertmanager dedups on the rest.

### 6.5 End-to-end smoke test

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

If step 1 shows the alert firing but step 2 is empty, the break is between Prometheus and Alertmanager (§6.1 row 3). If step 2 shows it but no human was notified, the break is inside Alertmanager routing/silences — a different topic.

---

## References

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