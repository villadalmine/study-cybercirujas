# 4.4 Alerting basics (when, what, and why)

> **Domain:** Alerting & Dashboarding · **Exam weight:** 4.5
> **Scope:** the decision layer that turns time-series into human action — the philosophy (*when/what/why*), the mechanics of alerting rules in the Prometheus server, the handoff to Alertmanager, and how to prove a rule fires exactly when it should and never when it shouldn't.

---

## 1. The production problem: from a graph to a human's phone at 03:00

A dashboard is a *pull* interface — a human must be looking. Alerting is the *push* interface: the system decides that a human must look **now**. The entire value of the subsystem is captured in one adversarial tension:

- **Miss a real problem** (false negative) → an outage burns undetected. The SLO is violated, the customer notices before you do.
- **Fire on a non-problem** (false positive) → **alert fatigue**. Engineers learn to ignore the pager, acknowledge-and-move-on becomes reflex, and the *next* alert — the real one — is muted by habit.

Alert fatigue is not a soft, cultural problem; it is the dominant failure mode of production monitoring. A pager that fires 40 times a shift trains humans to treat page #41 as noise. So the engineering objective of alerting is **not** "detect everything" — it is **maximize the signal-to-noise ratio of the pager** while keeping recall high enough that real, user-affecting incidents are always caught.

That objective decomposes into the three questions this topic is named after:

| Question | Decides | Failure if wrong |
|---|---|---|
| **When** do we alert? | The *trigger condition* and *duration* (`expr` + `for`) | Flapping pages, or detection lag |
| **What** do we alert on? | The *signal* (symptom vs cause) | Pages that aren't actionable |
| **Why** do we alert? | The *severity and destination* (page vs ticket) | Someone woken for a non-urgent problem |

### The alerting data path

Alerting in Prometheus is deliberately split across two processes. This separation is the single most important architectural fact of the topic.

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

- **The Prometheus server decides IF an alert should fire.** It evaluates alerting rules against its TSDB and pushes the *firing* alerts to Alertmanager. It has no concept of who to notify or how often.
- **Alertmanager decides WHAT TO DO with a firing alert** — deduplicate across HA Prometheus replicas, group related alerts into one notification, suppress (inhibit/silence), route to the right receiver, and throttle repeats.

This topic (4.4) lives on the **left** side: *when/what/why an alert fires*. Routing, grouping and notification (Alertmanager configuration) are 4.5. Knowing the boundary is itself examinable.

| Concern | Prometheus server | Alertmanager |
|---|---|---|
| Evaluate `expr` against TSDB | ✅ | ❌ |
| Hold `pending` → `firing` via `for` | ✅ | ❌ |
| Attach `labels` / `annotations` | ✅ (rule) | ✅ (can add via routing) |
| Deduplicate identical alerts from HA pairs | ❌ | ✅ |
| Group, silence, inhibit | ❌ | ✅ |
| Route to receivers, throttle `repeat_interval` | ❌ | ✅ |
| Send email/Slack/PagerDuty | ❌ | ✅ |

---

## 2. When: symptom-based alerting, not cause-based

The founding text is Rob Ewaschuk's *"My Philosophy on Alerting"* (the seed of the Google SRE book chapter *Monitoring Distributed Systems*). Its core rule:

> **Alert on symptoms, not causes.** Page a human only for conditions that are *urgent, actionable, and visible to (or imminently threatening to) the user.*

A **symptom** is what the user experiences: high latency, elevated error rate, the checkout page returning 503. A **cause** is an internal condition that *might* produce a symptom: a full disk, a restarting pod, high CPU, a leader election.

```
Cause-based (fragile):     "node-3 CPU > 90% for 5m"   → pages even if users are fine
Symptom-based (robust):    "checkout p99 latency > 1s" → pages only when it matters
```

Why symptom-based wins in production:

1. **Coverage without enumeration.** You cannot enumerate every cause of a slow API — a thousand different failures produce the same symptom. One symptom alert catches all of them, including the ones you never imagined.
2. **Fewer false pages.** CPU at 95% with latency nominal is *headroom being used*, not an incident. A cause alert pages; a symptom alert stays quiet.
3. **Actionability.** "Latency is high" is a real, urgent problem a human must fix. "CPU is high" may be entirely fine.

Causes still belong in monitoring — as **tickets/warnings** and as **dashboard/diagnostic context** you consult *after* a symptom page. The line is: **symptoms page (wake a human); causes ticket (investigate during business hours).**

### The signal catalogue: which symptoms

Three canonical frameworks tell you *what* to measure. They are complementary lenses, not competitors.

| Framework | Signals | Best for | Source |
|---|---|---|---|
| **Four Golden Signals** | Latency, Traffic, Errors, Saturation | User-facing services (the default) | Google SRE |
| **RED** | Rate, Errors, Duration | Request-driven microservices | Tom Wilkie / Weaveworks |
| **USE** | Utilization, Saturation, Errors | Resources (CPU, disk, NIC, queues) | Brendan Gregg |

- **Golden Signals / RED** produce **symptom** alerts → page-worthy.
- **USE** produces mostly **resource/cause** signals → ticket-worthy, with **Saturation** being the one that often *predicts* a symptom and can justify a page (e.g. "disk will be full in 4h").

**Rule of thumb:** page on **Errors** and **Latency** (symptoms), ticket on **Saturation** (leading indicator), dashboard on **Traffic/Utilization** (context).

---

## 3. Why: severity is a routing decision, encoded as a label

An alert's `severity` is not decoration — it is the label Alertmanager routes on. It answers *why are we telling a human, and how urgently.*

| Severity | Meaning | Human action | Destination | Latency budget |
|---|---|---|---|---|
| `critical` / `page` | User-visible or imminent; SLO at risk | Wake someone up **now** | PagerDuty / OpsGenie / phone | Minutes |
| `warning` / `ticket` | Real but not urgent; degradation or leading indicator | Handle in business hours | Ticket queue / Slack channel | Hours–days |
| `info` | Contextual; never actioned alone | None; dashboard/annotation only | Suppressed or logged | — |

The **every-page-is-actionable** invariant: if a human receiving a `critical` cannot do something about it *right now*, it should not be `critical`. Downgrade it to `warning`, or delete it. The strongest test of a page-level alert: *"If this fires and I do nothing, does a user get hurt soon?"* If no → it's not a page.

---

## 4. Anatomy of an alerting rule

Alerting rules live in `rule_files` loaded by the Prometheus server (the *same* file mechanism as recording rules; only the top key differs — `alert:` vs `record:`).

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

### Field semantics that get tested

- **`expr`** — any PromQL expression. **Every series it returns becomes one alert**, identified by the combination of `alertname` + all its label pairs. An expression returning three series → three distinct alerts. An expression returning *nothing* → the alert is `inactive`.
- **`for`** — the alert stays `pending` while the expression is continuously true, and only transitions to `firing` after `for` has elapsed. This is the primary de-flapping control: it filters transient spikes. If the expression goes false at any point during `for`, the timer resets to zero.
- **`keep_firing_for`** (Prometheus ≥ 2.42) — the mirror of `for` on the *way out*. Keeps the alert `firing` for this long after the expression stops returning it, preventing rapid resolve/refire flapping. Defaults to `0`.
- **`labels`** — static labels merged onto the alert. `severity` is the critical one (routing). Labels are part of the alert's identity — changing them creates a *different* alert.
- **`annotations`** — never used for identity or routing; purely informational, Go-templated. `{{ $value }}` is the numeric value of the series; `{{ $labels.X }}` its labels. A `runbook_url` here is the difference between an actionable page and a mystery.

### The alert lifecycle (three states)

```
      expr returns series          for elapses while continuously true
inactive ───────────────▶ pending ────────────────────────────────▶ firing
    ▲                        │                                          │
    │  expr returns nothing  │  expr goes false (timer resets)          │ expr false
    └────────────────────────┴──────────────────────────────────────── + keep_firing_for elapsed
```

Timing is quantized by `evaluation_interval` (global, default 15s) or the group's `interval`. With `evaluation_interval: 30s` and `for: 10m`, the alert becomes firing on the first evaluation at/after 10m of continuous truth — so up to one interval of extra lag. **A `for` shorter than `evaluation_interval` is meaningless** and effectively immediate.

### The synthetic `ALERTS` metric

Prometheus exposes every pending/firing alert as an *internal* time series you can query and, crucially, **alert on / graph** like any other:

```
ALERTS{alertname="HighErrorRate", alertstate="firing", severity="critical", service="checkout"}  1
ALERTS_FOR_STATE{alertname="HighErrorRate", ...}  1.6912...e9   # unix ts the "for" started
```

- `ALERTS` has value `1` while the alert is `pending` or `firing` (distinguished by the `alertstate` label). It does **not** exist for `inactive`.
- `ALERTS_FOR_STATE` records when the `for` timer began. On restart, Prometheus reads this back (subject to `--rules.alert.for-outage-tolerance`, default 1h) to **restore** the `for` progress rather than resetting every alert to `pending` — so a server restart doesn't reset your 10-minute timers and delay a real page.

---

## 5. Threshold vs burn-rate: how to choose *when*

The naïve alert — *"error ratio > 5% for 5m"* — has two failure modes at once:

- **Too sensitive** → a 90-second blip pages you.
- **Too insensitive** → a slow 1% error rate that *is* quietly eating your monthly SLO never trips a static threshold.

The production answer is **SLO / error-budget burn-rate alerting** (Google SRE Workbook, *Alerting on SLOs*). Instead of a fixed error threshold, you alert on **how fast you are consuming your error budget** — normalizing severity to *time-to-exhaustion*, not to an instantaneous number.

For an SLO of **99.9% success** over 30 days, the **error budget** is `1 − 0.999 = 0.001` (0.1%). **Burn rate** = observed error ratio ÷ budget. Burn rate `1` exhausts the budget in exactly 30 days; burn rate `14.4` exhausts it in ~50 hours.

| Approach | Fires on | Strength | Weakness |
|---|---|---|---|
| **Static threshold** (`ratio > 0.05 for 5m`) | Instantaneous level | Simple, obvious | Blind to slow burns; brittle threshold; flaps |
| **Single burn-rate** (e.g. `> 14.4× for 1h`) | Budget consumption speed | SLO-aligned | Slow to detect huge outages; or fast-but-noisy |
| **Multi-window multi-burn-rate** | Fast burn confirmed by short + long window | High precision **and** recall; fast on big fires, patient on small | More rules, needs recording rules |

### The multi-window, multi-burn-rate table (SRE Workbook)

Each severity uses a **long window** (precision — is this sustained?) AND a **short window** (recall — is it still happening right now?). The short window prevents the alert from staying lit long after the incident ends.

| Severity | Long window | Short window | Burn rate | Budget spent to trigger | Detection time |
|---|---|---|---|---|---|
| **Page** | 1h | 5m | 14.4× | 2% | fast |
| **Page** | 6h | 30m | 6× | 5% | medium |
| **Ticket** | 24h | 2h | 3× | 10% | slow |
| **Ticket** | 3d | 6h | 1× | 10% | slowest |

**Reading the table:** a `14.4×` burn over 1h consumes `14.4 × (1h / 720h) = 2%` of a 30-day budget. If both the 1h *and* the 5m windows exceed `14.4 × 0.001`, page — the long window says "this is sustained," the short window says "it's still going." A total 45-minute outage burns budget fast enough to page in minutes; a chronic 0.15% error rate never trips a page but eventually opens a ticket.

---

## 6. Complete manifests

### 6.1 Wiring the Prometheus server to Alertmanager and its rule files

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

### 6.2 Recording rules that feed the burn-rate alerts

Burn-rate expressions must not recompute `rate()` over six windows on every evaluation — that is expensive and duplicated across page/ticket rules. Precompute the ratio once per window with recording rules, then alert on the cheap recorded series.

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

### 6.3 The alerting rules (symptom + burn-rate)

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

### 6.4 The same, as a Prometheus Operator `PrometheusRule` CRD

In Kubernetes with the Prometheus Operator, you do **not** edit `prometheus.yml` by hand — you create `PrometheusRule` objects and the operator renders and reloads them. Note the CRD spec is *byte-identical* to a native rule group under `spec.groups`.

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

## 7. Verification and failure diagnosis

Alerting rules are code that runs at 03:00 with no human in the loop. They must be **tested like code** — statically checked, unit-tested against synthetic timelines, and inspected live.

### 7.1 Static check — does the YAML/PromQL even parse?

```console
$ promtool check rules /etc/prometheus/rules/slo_alerts.yml
Checking /etc/prometheus/rules/slo_alerts.yml
  SUCCESS: 5 rules found
```

A broken expression fails loudly, with the line:

```console
$ promtool check rules /etc/prometheus/rules/broken.yml
Checking /etc/prometheus/rules/broken.yml
  FAILED:
/etc/prometheus/rules/broken.yml: group "slo:http.alerts", rule 1, "ErrorBudgetBurnFast":
  could not parse expression: 1:37: parse error: unexpected "and" in aggregation

1 rule(s) with errors detected
```

Wire this into CI so a malformed rule never reaches production:

```console
$ find rules/ -name '*.yml' -print0 | xargs -0 promtool check rules
```

### 7.2 Unit test — does it fire at the *right time*, with the *right labels*?

`promtool test rules` runs alerting rules against a hand-authored time series and asserts the alerts (and their labels/annotations) at a given instant. This is the single most valuable, most under-used tool in the topic.

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

Run it:

```console
$ promtool test rules tests/slo_alerts_test.yml
Unit Testing:  tests/slo_alerts_test.yml
  SUCCESS
```

A regression — say someone loosens `for: 5m` to `for: 15m` — is caught immediately:

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

### 7.3 Live inspection — what is the server actually doing right now?

**Rule loading and health via the HTTP API:**

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

**Currently active (pending/firing) alerts:**

```console
$ curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname:.labels.alertname, state, activeAt, value}'
{
  "alertname": "ErrorBudgetBurnFast",
  "state": "firing",
  "activeAt": "2026-08-09T06:12:41.113Z",
  "value": "6.0e-02"
}
```

**Query the synthetic `ALERTS` metric** — lets you graph "how many alerts were pending vs firing over time," the meta-signal for tuning `for`:

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=ALERTS{alertstate="firing"}' | jq -r \
    '.data.result[] | "\(.metric.alertname)\t\(.metric.severity)\t\(.value[1])"'
ErrorBudgetBurnFast     critical        1
```

**Confirm the alert actually reached Alertmanager** (proves the *push* leg, not just local firing):

```console
$ amtool alert query --alertmanager.url=http://localhost:9093
Alertname            Starts At                Summary                                        State
ErrorBudgetBurnFast  2026-08-09 06:12:41 UTC  Fast error-budget burn on api (14.4x)          active
```

### 7.4 Reloading rules without a restart

Editing a rule file does **not** hot-reload it. Trigger a reload (requires `--web.enable-lifecycle`):

```console
$ curl -sf -X POST http://localhost:9090/-/reload && echo "reloaded"
reloaded
# In Kubernetes with the Operator, config-reloader sidecars do this automatically on ConfigMap change.
```

### 7.5 Failure-mode diagnosis matrix

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Rule change ignored | File not reloaded | `GET /api/v1/rules` still shows old expr | `POST /-/reload` or restart; check `--web.enable-lifecycle` |
| Alert stuck `pending`, never `firing` | `for` longer than the condition persists, or `evaluation_interval` too coarse | Graph `ALERTS{alertstate="pending"}`; check `activeAt` vs now | Shorten `for`, or verify the underlying spike is genuinely brief |
| Alert never appears at all | `expr` returns empty vector | Run the `expr` in the query UI — 0 series = inactive | Fix label matchers / metric name; check the metric exists |
| Rule `health: "err"` | PromQL runtime error (e.g. many-to-many match) | `GET /api/v1/rules` → `lastError` | Add `on()/ignoring()` grouping; validate with `promtool check rules` |
| Fires locally but no notification | Push leg to Alertmanager broken | `up{job="alertmanager"}`, `prometheus_notifications_dropped_total`, `amtool alert query` | Fix `alerting.alertmanagers` target / network policy |
| Duplicate pages from HA Prometheus | `replica` label not dropped before send | Two alerts differing only by `replica` in Alertmanager | `alert_relabel_configs` labeldrop `replica`; set distinct `external_labels` |
| Flapping resolve/refire | Condition oscillates around threshold | Watch `ALERTS` toggling 1→0→1 | Add `keep_firing_for`; widen `for`; hysteresis in `expr` |
| Alert re-pages after Prometheus restart | `for` state not restored | Restart correlated with page; gap > `for-outage-tolerance` | Ensure TSDB persistence; `--rules.alert.for-outage-tolerance` (default 1h) covers the gap |
| Notifications repeat too fast/slow | Alertmanager `repeat_interval`, not a rule issue | `amtool config routes show` | Tune in Alertmanager (topic 4.5), not the rule |

**Relevant server flags for the timing edge cases above:**

| Flag | Default | Effect |
|---|---|---|
| `--rules.alert.for-outage-tolerance` | `1h` | Max Prometheus downtime for which `for` progress is restored on restart (via `ALERTS_FOR_STATE`) |
| `--rules.alert.for-grace-period` | `10m` | Minimum `for` duration for which restoration applies; short-`for` alerts always re-evaluate fresh |
| `--rules.alert.resend-delay` | `1m` | How often the server *re-sends* a still-firing alert to Alertmanager (keeps it alive against Alertmanager's `resolve_timeout`) |

---

## 8. Design checklist (the exam's mental model)

Before a rule ships, it should pass every line:

1. **What** — does it measure a **symptom** (page) or a **cause** (ticket)? Is the severity label correct for that answer?
2. **When** — is `for` long enough to filter transients but short enough to detect real incidents? Would a burn-rate formulation catch slow degradations a static threshold misses?
3. **Why** — if this fires and the on-call does nothing, does a user get hurt? If not, it is not `critical`.
4. **Actionable** — does the annotation carry a `runbook_url` and enough context to act without spelunking?
5. **Proven** — is there a `promtool test rules` case asserting both that it fires when it should *and stays silent when it shouldn't*?
6. **Reachable** — is the rule file in `rule_files`/matched by `ruleSelector`, loaded (`/api/v1/rules`), and is the Alertmanager push leg healthy?

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