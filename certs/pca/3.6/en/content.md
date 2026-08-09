# Basics of SLOs, SLAs, and SLIs

> **PCA — Domain 3: Observability Concepts · Topic 3.6** · Exam weight: 3
> Level: Production SRE / Platform Architect. Everything is grounded in Prometheus and PromQL, because on the PCA the SLI is *the query* and the SLO is *the rule*.

---

## 1. Motivation: the production problem SLIs/SLOs/SLAs actually solve

A service is never "up" or "down" as a binary. At scale it is *partially* degraded, *for some* users, *some* of the time. Two teams looking at the same Prometheus instance will disagree about whether an incident is happening unless they have agreed, *in advance and in a machine-computable form*, on:

1. **What "working" means** — a number derived from telemetry (the **SLI**).
2. **How much "working" is enough** — a target on that number over a window (the **SLO**).
3. **What happens when it isn't enough** — a decision (page, freeze releases) or a contractual consequence (the **SLA**).

Without this, alerting devolves into *cause-based* alerts ("node CPU > 90%", "pod restarted") that fire constantly, page humans for symptoms customers never feel, and stay silent during outages that don't map to any pre-imagined cause. The architectural shift SRE introduced is **symptom-based, budget-driven alerting**: you alert on the *user-visible SLI* burning through an *error budget*, not on internal causes.

The **error budget** is the pivot. If your SLO is 99.9% availability over 30 days, you are *permitted* 0.1% failure — **43.2 minutes** per 30 days. That permitted failure is a budget you can spend on risky deploys, chaos experiments, or infrastructure migrations. It turns the endless "stability vs. velocity" argument between SRE and product into arithmetic: *budget remaining → ship; budget exhausted → freeze*. The entire point of instrumenting SLIs in Prometheus is to make that budget a live PromQL number, not a quarterly PowerPoint.

**Where Prometheus fits:** Prometheus is where the SLI is *computed* (PromQL over counters/histograms), where the SLO is *encoded* (recording + alerting rules), and where the burn rate is *evaluated* (multi-window alert expressions). Grafana/Alertmanager consume it; Prometheus produces it.

---

## 2. The three terms, precisely — and how they differ

| Aspect | **SLI** (Indicator) | **SLO** (Objective) | **SLA** (Agreement) |
|---|---|---|---|
| What it is | A *measurement* of service behavior | A *target/range* for an SLI over a window | A *contract* with a customer |
| Form | A number, usually a ratio `good/valid` in `[0,1]` | `SLI ≥ target` over `window` (e.g. ≥ 99.9% / 30d) | Legal doc + financial/credit penalty |
| Audience | Engineers | Engineers, product | Customers, legal, sales |
| Consequence of breach | None (it's just a number) | Internal: page, release freeze, prioritize reliability | External: refunds, service credits, churn |
| Who sets it | Derived from telemetry | SRE + product owner | Business/legal |
| Prometheus artifact | A PromQL query / recording rule | Recording rules + burn-rate alerting rules | Usually **not** in Prometheus (reported, not alerted) |
| Typical tightness | — | **Stricter** than the SLA | **Looser** than the SLO (safety margin) |

**Key relationships, memorize for the exam:**

- **SLA is looser than SLO is derived from SLI.** You *always* set your internal SLO tighter than the SLA you sell, so that when you start missing the SLO you have time to react *before* you breach the SLA and owe money. Example: SLA = 99.5% (credits below that), internal SLO = 99.9%.
- **Error budget = `1 − SLO`.** Not `1 − SLA`.
- **An SLA without an SLO is unenforceable; an SLO without an SLI is unmeasurable.** SLI → SLO → SLA is a dependency chain.
- You **alert on SLOs**, you **report on SLAs**. Paging on an SLA breach is too late by definition.

### Error budget as concrete downtime (request this table cold)

Error budget is `1 − SLO`. Translated to allowed downtime/failure per window:

| SLO (availability) | Error budget | Per 30 days | Per 90 days | Per 365 days |
|---|---|---|---|---|
| 99%     | 1%      | 7h 12m    | 21h 36m   | 3d 15h 36m |
| 99.5%   | 0.5%    | 3h 36m    | 10h 48m   | 1d 19h 48m |
| 99.9%   | 0.1%    | 43m 12s   | 2h 9m 36s | 8h 45m 57s |
| 99.95%  | 0.05%   | 21m 36s   | 1h 4m 48s | 4h 22m 58s |
| 99.99%  | 0.01%   | 4m 19s    | 12m 58s   | 52m 35s |
| 99.999% | 0.001%  | 25.9s     | 1m 18s    | 5m 15s |

> Arithmetic: 30 days = 43,200 min. `99.9%` → `43,200 × 0.001 = 43.2 min`. This is why "three nines" is the everyday production default: sub-hour budget, still humanly achievable.

---

## 3. Choosing the SLI: the two implementations, and the trade-off

There are two ways to express an SLI, and the PCA cares that you know both because they change the PromQL.

| | **Request-based (event ratio)** | **Window-based (time slices)** |
|---|---|---|
| Definition | `good events / valid events` | `good time-windows / total time-windows` |
| Prometheus source | Counters (`*_total`), histograms | A boolean SLI evaluated per interval, then `avg_over_time` |
| PromQL shape | `sum(rate(good[w])) / sum(rate(valid[w]))` | `avg_over_time( (sli_bool)[w] )` |
| Sensitivity | Weighted by traffic — one bad second under peak load hurts proportionally | Every window counts equally regardless of traffic |
| Best for | High-volume request/response services (APIs) | Low-traffic services, batch, "is the leader elected?" |
| Failure mode | Denominator → 0 during no traffic → `NaN` | A single bad request in a quiet window fails the whole window |
| SRE recommendation | **Default.** Directly proportional to user pain | Use when events are sparse or non-request-shaped |

### The four families of SLI (the "SLI menu")

| SLI type | What it measures | Prometheus building block |
|---|---|---|
| **Availability** | fraction of *successful* requests | `code!~"5.."` counter ratio |
| **Latency** | fraction of requests *fast enough* | histogram bucket `le` ratio |
| **Quality/Correctness** | fraction of *correct/non-degraded* responses | app-level counter |
| **Freshness/Coverage** | data recency / completeness (pipelines) | timestamp gauges, `time() - push_time` |
| **Throughput/Durability** | for data systems | domain counters |

**Availability SLI (request-based):**
```promql
sum(rate(http_requests_total{job="api", code!~"5.."}[5m]))
/
sum(rate(http_requests_total{job="api"}[5m]))
```

**Latency SLI (fraction served under 500 ms, from a native or classic histogram):**
```promql
sum(rate(http_request_duration_seconds_bucket{job="api", le="0.5"}[5m]))
/
sum(rate(http_request_duration_seconds_count{job="api"}[5m]))
```
> Note: the latency SLI is **not** `histogram_quantile(...)`. A quantile tells you *where the p99 is*; an SLI needs *what fraction met the threshold* — that's the bucket-count ratio above. This distinction is a common exam trap.

**Error ratio (the complement, used for burn rate):**
```promql
sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
/
sum(rate(http_requests_total{job="api"}[5m]))
```

---

## 4. Burn rate — turning an SLO into an alert

The naïve alert "error ratio > 0.001 for 5m" is a disaster: it fires on every tiny blip and it can't tell a slow leak from a fast fire. The SRE Workbook's answer is the **burn rate**.

**Burn rate** = how fast you are consuming the error budget relative to the rate that would exhaust it *exactly* at the end of the SLO window. Burn rate `1` = perfectly on-budget; burn rate `10` = you'll be broke in 1/10th of the window.

`budget consumed over window = burn_rate × (window / SLO_window)`

The alert condition is: `observed_error_ratio > burn_rate × (1 − SLO)`.

### Multi-window, multi-burn-rate (MWMBR) — the canonical scheme

Pairing a **long window** (accuracy, low false positives) with a **short window** (fast reset, so the alert clears quickly after recovery). For a 30-day / 99.9% SLO (`1 − SLO = 0.001`):

| Severity | Long window | Short window | Burn rate | Budget consumed if sustained | Threshold on error ratio |
|---|---|---|---|---|---|
| **Page** (fast burn) | 1h | 5m | **14.4** | 2% in 1h | `> 0.0144` |
| **Page** (medium burn) | 6h | 30m | **6** | 5% in 6h | `> 0.006` |
| **Ticket** (slow burn) | 3d | 6h | **1** | 10% in 3d | `> 0.001` |

> Derivation for row 1: `14.4 × (1h / 720h) = 0.02 = 2%`. The short window (5m) must *also* be over threshold, so the alert both fires fast **and** stops fast when the incident ends.

**Trade-off table — alerting strategies:**

| Strategy | Detection speed | False positives | Reset time | Budget-aware? |
|---|---|---|---|---|
| Static threshold + long `for:` | Slow | Low | Slow | No |
| Static threshold + short `for:` | Fast | High | Fast | No |
| Single burn rate, single window | Medium | Medium | Poor | Yes |
| **Multi-window multi-burn-rate** | **Fast for big fires, patient for leaks** | **Low** | **Fast** | **Yes** |

---

## 5. Complete infrastructure — manifests, unabridged

### 5.1 Recording rules: precompute the SLI error ratio at every window

Precomputing keeps alert expressions cheap and consistent (compute once, reference many). `slo:sli_error:ratio_rateXX` is the de-facto naming convention popularized by Sloth.

```yaml
# slo-api-availability.rules.yml
groups:
  - name: slo-api-availability:sli-ratios
    interval: 30s
    rules:
      - record: slo:sli_error:ratio_rate5m
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
          /
          sum(rate(http_requests_total{job="api"}[5m]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate30m
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[30m]))
          /
          sum(rate(http_requests_total{job="api"}[30m]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate1h
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[1h]))
          /
          sum(rate(http_requests_total{job="api"}[1h]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate6h
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[6h]))
          /
          sum(rate(http_requests_total{job="api"}[6h]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate1d
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[1d]))
          /
          sum(rate(http_requests_total{job="api"}[1d]))
        labels:
          slo: api-availability
          service: api
      - record: slo:sli_error:ratio_rate3d
        expr: |
          sum(rate(http_requests_total{job="api", code=~"5.."}[3d]))
          /
          sum(rate(http_requests_total{job="api"}[3d]))
        labels:
          slo: api-availability
          service: api

  # Static metadata so dashboards/alerts can read the objective and window
  - name: slo-api-availability:metadata
    rules:
      - record: slo:objective:ratio
        expr: vector(0.999)
        labels: { slo: api-availability, service: api }
      - record: slo:error_budget:ratio
        expr: vector(1 - 0.999)     # 0.001
        labels: { slo: api-availability, service: api }
      # Remaining error budget as a fraction in [0,1] over the 30d window
      # (uses the 3d ratio scaled — for exact 30d use a ratio_rate30d rule; long ranges are expensive)
      - record: slo:error_budget:remaining_ratio
        expr: |
          1 - (
            avg_over_time(slo:sli_error:ratio_rate1h{slo="api-availability"}[30d])
            / 0.001
          )
        labels: { slo: api-availability, service: api }
```

### 5.2 Alerting rules: the MWMBR page + ticket alerts

```yaml
# slo-api-availability.alerts.yml
groups:
  - name: slo-api-availability:alerts
    rules:
      # ---- PAGE: fast burn (14.4 over 1h/5m, OR 6 over 6h/30m) ----
      - alert: ApiAvailabilityErrorBudgetBurnPage
        expr: |
          (
            slo:sli_error:ratio_rate1h{slo="api-availability"} > (14.4 * 0.001)
            and
            slo:sli_error:ratio_rate5m{slo="api-availability"} > (14.4 * 0.001)
          )
          or
          (
            slo:sli_error:ratio_rate6h{slo="api-availability"} > (6 * 0.001)
            and
            slo:sli_error:ratio_rate30m{slo="api-availability"} > (6 * 0.001)
          )
        labels:
          severity: page
          slo: api-availability
        annotations:
          summary: "High error-budget burn on api-availability (page)"
          description: >
            Error budget for SLO api-availability (99.9% / 30d) is burning
            fast. Current 1h error ratio:
            {{ printf "%.4f" $value }}. At this rate a significant fraction of
            the 30d budget is consumed within hours.
          runbook_url: "https://runbooks.internal/slo/api-availability"

      # ---- TICKET: slow burn (1 over 3d/6h) ----
      - alert: ApiAvailabilityErrorBudgetBurnTicket
        expr: |
          slo:sli_error:ratio_rate3d{slo="api-availability"} > (1 * 0.001)
          and
          slo:sli_error:ratio_rate6h{slo="api-availability"} > (1 * 0.001)
        labels:
          severity: ticket
          slo: api-availability
        annotations:
          summary: "Slow error-budget burn on api-availability (ticket)"
          description: >
            Sustained low-level errors are eroding the 30d error budget.
            3d error ratio: {{ printf "%.4f" $value }}. Investigate within
            business hours before the budget is exhausted.
          runbook_url: "https://runbooks.internal/slo/api-availability"
```

### 5.3 Generate it all from a single spec with **Sloth** (recommended in production)

Hand-writing six windows × N SLOs does not scale. Sloth generates the recording + MWMBR alerting rules from a compact declarative spec.

```yaml
# sloth-api.yml
version: "prometheus/v1"
service: "api"
labels:
  team: "platform"
  tier: "1"
slos:
  - name: "requests-availability"
    objective: 99.9
    description: "99.9% of API requests over 30d return non-5xx."
    sli:
      events:
        error_query: sum(rate(http_requests_total{job="api", code=~"5.."}[{{.window}}]))
        total_query: sum(rate(http_requests_total{job="api"}[{{.window}}]))
    alerting:
      name: ApiAvailabilityHighErrorRate
      labels:
        category: "availability"
      annotations:
        summary: "High error rate on the API SLI"
      page_alert:
        labels:
          severity: page
      ticket_alert:
        labels:
          severity: ticket

  - name: "requests-latency"
    objective: 99.0
    description: "99% of API requests over 30d complete under 500ms."
    sli:
      events:
        error_query: |
          (
            sum(rate(http_request_duration_seconds_count{job="api"}[{{.window}}]))
            -
            sum(rate(http_request_duration_seconds_bucket{job="api", le="0.5"}[{{.window}}]))
          )
        total_query: sum(rate(http_request_duration_seconds_count{job="api"}[{{.window}}]))
    alerting:
      name: ApiLatencyHighErrorRate
      page_alert:
        labels: { severity: page }
      ticket_alert:
        labels: { severity: ticket }
```

### 5.4 Kubernetes-native SLOs with **Pyrra** (CRD-driven)

Pyrra exposes a `ServiceLevelObjective` CRD, generates the Prometheus rules, and ships a UI showing budget remaining. Ideal when SLOs must live in Git next to the workload.

```yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: api-availability
  namespace: monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  target: "99.9"          # objective as a percentage
  window: 4w              # rolling SLO window
  description: "API 5xx availability."
  indicator:
    ratio:
      errors:
        metric: http_requests_total{job="api", code=~"5.."}
      total:
        metric: http_requests_total{job="api"}
```

### 5.5 Wire the rules into Prometheus and route the alert

```yaml
# prometheus.yml (excerpt)
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/slo-*.rules.yml
  - /etc/prometheus/rules/slo-*.alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

```yaml
# alertmanager.yml (excerpt) — page vs ticket route to different receivers
route:
  receiver: default
  group_by: ["slo"]
  routes:
    - matchers: ['severity="page"']
      receiver: pagerduty
      group_wait: 30s
      repeat_interval: 1h
    - matchers: ['severity="ticket"']
      receiver: jira
      repeat_interval: 12h
receivers:
  - name: default
  - name: pagerduty
    pagerduty_configs:
      - routing_key: "<key>"
  - name: jira
    webhook_configs:
      - url: "http://jira-bridge:8080/alert"
```

### 5.6 Trade-offs: how to encode SLOs in Prometheus

| Approach | Effort | Consistency | Portability | K8s-native | Best for |
|---|---|---|---|---|---|
| Hand-written recording/alert rules | High, error-prone | Depends on discipline | High | No | Learning, one-off SLOs |
| **Sloth** (spec → rules) | Low | High (templated MWMBR) | High (plain Prometheus rules) | Optional CRD | Most Prometheus shops |
| **Pyrra** (CRD + UI) | Low | High | Medium (needs operator) | Yes | Kubernetes / GitOps |
| **OpenSLO** + Nobl9/converters | Medium | Vendor-neutral spec | High (multi-backend) | Varies | Multi-tool / multi-cloud orgs |

---

## 6. CLI and terminal — real commands and outputs

**Validate the rule files before loading (never load unchecked rules):**
```console
$ promtool check rules slo-api-availability.rules.yml slo-api-availability.alerts.yml
Checking slo-api-availability.rules.yml
  SUCCESS: 9 rules found

Checking slo-api-availability.alerts.yml
  SUCCESS: 2 rules found
```

**Generate rules from the Sloth spec:**
```console
$ sloth generate -i sloth-api.yml -o slo-api.rules.yml
INFO[0000] Generating from Prometheus format spec ...  version=v0.11.0
INFO[0000] SLI recording rules generated  rules=6 slo=api-requests-availability
INFO[0000] Metadata recording rules generated  rules=7 slo=api-requests-availability
INFO[0000] SLO alert rules generated  rules=2 slo=api-requests-availability
INFO[0000] Prometheus rules written  file=slo-api.rules.yml groups=6
```

**Query the live SLI error ratio (Prometheus HTTP API):**
```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:sli_error:ratio_rate1h{slo="api-availability"}' | jq .
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": { "slo": "api-availability", "service": "api" },
        "value": [ 1754640000, "0.0213" ]
      }
    ]
  }
}
```
> `0.0213 > 0.0144` (the 14.4 page threshold) → the fast-burn page condition is satisfied on the 1h window.

**Check whether the page alert is firing:**
```console
$ curl -s 'http://localhost:9090/api/v1/alerts' \
    | jq '.data.alerts[] | {name: .labels.alertname, state, severity: .labels.severity}'
{
  "name": "ApiAvailabilityErrorBudgetBurnPage",
  "state": "firing",
  "severity": "page"
}
```

**Read remaining error budget:**
```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=slo:error_budget:remaining_ratio{slo="api-availability"}' \
    | jq -r '.data.result[0].value[1]'
0.37
```
> 37% of the 30-day budget remains — release policy: proceed with caution, no risky migrations.

**Unit-test the alert logic with `promtool test rules` (regression-proof your SLO):**
```yaml
# slo-tests.yml
rule_files:
  - slo-api-availability.rules.yml
  - slo-api-availability.alerts.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      # 5% of requests are 5xx for 90 minutes -> well above the 14.4 page threshold
      - series: 'http_requests_total{job="api", code="500"}'
        values: '0+5x90'
      - series: 'http_requests_total{job="api", code="200"}'
        values: '0+95x90'
    alert_rule_test:
      - eval_time: 70m
        alertname: ApiAvailabilityErrorBudgetBurnPage
        exp_alerts:
          - exp_labels:
              severity: page
              slo: api-availability
```
```console
$ promtool test rules slo-tests.yml
Unit Testing:  slo-tests.yml
  SUCCESS
```

**Apply the Pyrra CRD and confirm generated PrometheusRule:**
```console
$ kubectl apply -f api-availability-slo.yaml
servicelevelobjective.pyrra.dev/api-availability created

$ kubectl get prometheusrule -n monitoring -l pyrra.dev/servicelevelobjective=api-availability
NAME               AGE
api-availability   12s
```

---

## 7. Verification and failure diagnosis

### 7.1 Verification ladder

1. **Structure:** `promtool check rules ...` → every rule file must parse and validate.
2. **Presence:** confirm each `slo:sli_error:ratio_rateXX` series exists — `count(slo:sli_error:ratio_rate5m)` should be `≥ 1`.
3. **Sanity of the ratio:** the SLI ratio must be in `[0,1]`. `slo:sli_error:ratio_rate5m > 1 or slo:sli_error:ratio_rate5m < 0` should return **empty**.
4. **Logic:** `promtool test rules` unit tests — assert the page fires under a synthetic fast burn and stays silent under normal traffic.
5. **End-to-end:** inject a synthetic 5xx burst (or a chaos experiment) and confirm the alert reaches PagerDuty and clears within the short-window reset time.

### 7.2 Failure catalog

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| SLI ratio is `NaN` / gaps | No traffic → denominator `= 0` (`0/0`) | `sum(rate(http_requests_total[5m]))` returns nothing during quiet periods | Wrap with `... or vector(0)`, or use a `clamp`/`OR on()` guard; consider a window-based SLI for low-traffic services |
| Alert never fires during a real outage | SLI counts the wrong events (e.g. LB returns 200 while backend 5xx) | Compare app-level vs edge-level error counters | Measure the SLI **as close to the user as possible** (edge/LB), not deep in the app |
| Alert flaps on/off | Using `irate()` (last two samples) instead of `rate()` | Graph the recording rule — spiky sawtooth | Use `rate()` over the burn window; MWMBR short window already handles reset |
| Recording rule stale / not updating | `interval` in the rule group longer than expected; rule eval overload | `count_over_time(slo:sli_error:ratio_rate5m[10m])` far below expected | Lower group `interval` (or fix rule-eval latency: `prometheus_rule_group_last_duration_seconds`) |
| Ratio wrong after a deploy | Counter reset not handled | Raw counter drops to 0 at restart | `rate()`/`increase()` already handle resets — verify you didn't switch to raw `delta` on a counter |
| Cardinality explosion / OOM | Too many labels on SLI series (per-path, per-user) | `topk(10, count by (__name__)({__name__=~"slo:.*"}))` | Aggregate away high-cardinality labels in the recording rule |
| Latency SLI ~ p99 not "% fast" | Used `histogram_quantile` for the SLI | Value looks like seconds, not a `[0,1]` fraction | SLI = `bucket(le=T) / count`, not a quantile |
| Budget "remaining" negative | Observed error ratio exceeded the budget | `slo:error_budget:remaining_ratio < 0` | Expected — budget is exhausted; freeze releases |

### 7.3 Diagnostic PromQL

```promql
# Is the SLI series being produced at all?
count(slo:sli_error:ratio_rate5m{slo="api-availability"})

# Guard against divide-by-zero (no-traffic) NaNs
(
  sum(rate(http_requests_total{job="api", code=~"5.."}[5m]))
  /
  sum(rate(http_requests_total{job="api"}[5m]))
) or vector(0)

# Current burn rate as a multiple of budget (readable on a dashboard)
slo:sli_error:ratio_rate1h{slo="api-availability"} / 0.001

# Rule-group evaluation health (are your SLO rules keeping up?)
prometheus_rule_group_last_duration_seconds
  > prometheus_rule_group_interval_seconds
```

---

## 8. References

- CNCF PCA Curriculum — https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
- Google SRE Book, *Service Level Objectives* — https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook, *Implementing SLOs* (error budgets, multi-window multi-burn-rate) — https://sre.google/workbook/implementing-slos/
- Google SRE Workbook, *Alerting on SLOs* — https://sre.google/workbook/alerting-on-slos/
- Prometheus — Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — Querying / functions (`rate`, `histogram_quantile`) — https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/alerts`) — https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Unit testing rules (`promtool test rules`) — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
- Prometheus — Histograms and summaries — https://prometheus.io/docs/practices/histograms/
- Sloth — Prometheus SLO generator — https://sloth.dev/ · https://github.com/slok/sloth
- Pyrra — Kubernetes-native SLOs — https://github.com/pyrra-dev/pyrra
- OpenSLO — vendor-neutral SLO specification — https://openslo.com/ · https://github.com/OpenSLO/OpenSLO
- Alertmanager — configuration & routing — https://prometheus.io/docs/alerting/latest/configuration/