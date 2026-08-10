# PCA 4.4 — Alerting Basics (When, What, and Why): Guided Exercises

> **Objective.** By the end of these labs you will decide *what* deserves an alert (symptom vs. cause), *when* it should fire (`for`, staleness, multi-window burn rate), and *why* it matters to the on-call engineer (severity, labels, annotations, routing). Everything is done with the real toolchain — `prometheus`, `promtool`, `alertmanager`, `amtool` — and every rule is verified deterministically before it ever touches a live target.
>
> **Reference sources**
> - Alerting overview — https://prometheus.io/docs/alerting/latest/overview/
> - Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
> - Unit testing rules — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
> - Alertmanager configuration — https://prometheus.io/docs/alerting/latest/configuration/
> - Alerting philosophy (symptoms, not causes) — https://prometheus.io/docs/practices/alerting/
> - Google SRE: *Monitoring Distributed Systems* — https://sre.google/sre-book/monitoring-distributed-systems/
> - Google SRE Workbook: *Alerting on SLOs* — https://sre.google/workbook/alerting-on-slos/

## Prerequisites (one-time setup)

You need the `prometheus`, `promtool`, `alertmanager`, and `amtool` binaries (v2.50+ / v0.27+). `promtool` and `amtool` ship inside the Prometheus and Alertmanager release tarballs respectively.

```bash
mkdir -p ~/pca-4.4 && cd ~/pca-4.4
prometheus --version    # expect: prometheus, version 2.5x.x ...
promtool --version
alertmanager --version
amtool --version
```

Create a minimal `prometheus.yml` that wires Prometheus to Alertmanager and loads a rules file. You will fill `api-alerts.yml` in during the exercises.

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "api-alerts.yml"
  - "slo-rules.yml"          # used in Exercise 5

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
```

---

## Exercise 1 — *What* to alert on: symptom vs. cause

The central rule of alerting (SRE book, ch. 6) is: **page a human only for symptoms that are user-visible and require immediate action.** Causes are for dashboards and for the *description* of a symptom alert, not for pages of their own.

1. Create `api-alerts.yml` with two rules — one written the *wrong* way (cause-based) and one the *right* way (symptom-based). We keep them side by side so you can compare them in the UI.

   ```yaml
   # api-alerts.yml
   groups:
     - name: api-availability
       rules:
         # ❌ CAUSE-BASED — pages on an internal detail that may be harmless
         - alert: ApiHighCpu
           expr: rate(process_cpu_seconds_total{job="api"}[5m]) > 0.9
           for: 5m
           labels:
             severity: critical
           annotations:
             summary: "API process CPU is high"

         # ✅ SYMPTOM-BASED — pages on user-visible failure
         - alert: ApiHighErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               /
             sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.05
           for: 10m
           labels:
             severity: critical
           annotations:
             summary: "API 5xx error ratio is {{ $value | humanizePercentage }} (SLO breach)"
             description: >-
               More than 5% of requests to {{ $labels.job }} are failing.
               Check saturation, upstream dependencies, and recent deploys.
   ```

2. Statically validate the file *before* loading it. `promtool` parses the YAML, compiles every PromQL expression, and rejects the file if any rule is malformed:

   ```bash
   promtool check rules api-alerts.yml
   ```
   Expected:
   ```
   Checking api-alerts.yml
     SUCCESS: 2 rules found
   ```

3. Start Prometheus and confirm the rules loaded as a rule group:

   ```bash
   prometheus --config.file=prometheus.yml &
   curl -s http://localhost:9090/api/v1/rules \
     | jq '.data.groups[].rules[] | {name, type, state}'
   ```
   Expected (both `inactive` because nothing is failing yet):
   ```json
   { "name": "ApiHighCpu",      "type": "alerting", "state": "inactive" }
   { "name": "ApiHighErrorRate","type": "alerting", "state": "inactive" }
   ```

**Check your understanding**

- **1a.** `ApiHighCpu` fires whenever the process is CPU-bound for 5 minutes. Give one concrete situation where this alert is firing but *nothing is wrong for the user* — and explain why paging on it causes alert fatigue.
- **1b.** Why does `ApiHighErrorRate` use `sum by (job)(...) / sum by (job)(...)` instead of alerting on the raw count `rate(http_requests_total{code=~"5.."}[5m]) > 10`?
- **1c.** The cause (high CPU) is still useful. Where should it live if not in a page?

---

## Exercise 2 — *When* it fires: the `for` clause, pending vs. firing, and unit tests

An alert expression that is true for a single evaluation is noise. The `for` clause requires the condition to hold continuously before the alert transitions `pending → firing`. You will prove the timing deterministically with `promtool test rules` — no live failing service required.

1. Create a unit-test file that feeds synthetic series into the rules and asserts the alert state at specific times. `0+60x30` means "start at 0, add 60 each minute, 30 times."

   ```yaml
   # api-alerts_test.yml
   rule_files:
     - api-alerts.yml

   evaluation_interval: 1m

   tests:
     - interval: 1m
       input_series:
         # 5xx grows by 60/min  -> rate = 1 req/s
         - series: 'http_requests_total{job="api", code="500"}'
           values: '0+60x30'
         # 2xx grows by 600/min -> rate = 10 req/s  => error ratio ≈ 9.1%
         - series: 'http_requests_total{job="api", code="200"}'
           values: '0+600x30'

       alert_rule_test:
         # At 12 min the ratio is already > 5% but `for: 10m` has NOT elapsed
         # (the 5m rate only becomes valid ~5m in), so the alert is still pending.
         - eval_time: 12m
           alertname: ApiHighErrorRate
           exp_alerts: []          # <-- no alerts firing yet

         # By 20 min the condition has held for >10m -> FIRING
         - eval_time: 20m
           alertname: ApiHighErrorRate
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: api
               exp_annotations:
                 summary: "API 5xx error ratio is 9.09% (SLO breach)"
                 description: >-
                   More than 5% of requests to api are failing.
                   Check saturation, upstream dependencies, and recent deploys.
   ```

2. Run the test:

   ```bash
   promtool test rules api-alerts_test.yml
   ```
   Expected:
   ```
   Unit Testing:  api-alerts_test.yml
     SUCCESS
   ```

3. Now **break the timing on purpose** to see how the tool guards you. Edit the first block's `eval_time: 12m` to `eval_time: 20m` but keep `exp_alerts: []`, then rerun. Expected failure:

   ```
   Unit Testing:  api-alerts_test.yml
     FAILED:
       alertname: ApiHighErrorRate, time: 20m0s,
         exp:[],
         got:[Labels:{alertname="ApiHighErrorRate", job="api", severity="critical"} ...]
   ```
   Restore it to `12m` and confirm `SUCCESS` again.

**Check your understanding**

- **2a.** With `for: 10m`, what is the maximum delay between the user actually seeing errors and the alert reaching `firing`? Why is a *longer* `for` not automatically "safer"?
- **2b.** In step 1 the condition is met by ~5 min, yet the alert only fires around 15 min. Name the two independent delays that stack up here.
- **2c.** A colleague removes `for:` entirely to "get paged faster." What failure mode (hint: a metric that briefly disappears or a single-scrape blip) does this reintroduce?
- **2d.** Why is a `promtool` unit test a stronger guarantee than opening the Prometheus UI and eyeballing the graph?

---

## Exercise 3 — *Why* it matters: severity, labels, and actionable annotations

An alert's *labels* decide routing and identity; its *annotations* are the human-readable payload. A good alert answers, without any digging: what broke, how bad, and what to do next.

1. Upgrade the good alert with a full, actionable payload and a companion `warning` at a lower threshold. Replace the `ApiHighErrorRate` rule with this pair:

   ```yaml
         - alert: ApiHighErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               / sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.05
           for: 10m
           labels:
             severity: critical
             team: payments
           annotations:
             summary: "{{ $labels.job }} 5xx ratio {{ $value | humanizePercentage }} > 5%"
             description: "Fast error-budget burn on {{ $labels.job }}. Users are seeing failures now."
             runbook_url: "https://runbooks.example.com/api/HighErrorRate"
             dashboard_url: "https://grafana.example.com/d/api-overview"

         - alert: ApiElevatedErrorRate
           expr: |
             sum by (job) (rate(http_requests_total{job="api", code=~"5.."}[5m]))
               / sum by (job) (rate(http_requests_total{job="api"}[5m]))
               > 0.01
           for: 30m
           labels:
             severity: warning
             team: payments
           annotations:
             summary: "{{ $labels.job }} 5xx ratio {{ $value | humanizePercentage }} > 1%"
             runbook_url: "https://runbooks.example.com/api/HighErrorRate"
   ```

2. Re-validate and confirm four rules now exist:

   ```bash
   promtool check rules api-alerts.yml
   # Checking api-alerts.yml
   #   SUCCESS: 4 rules found  (ApiHighCpu, ApiHighErrorRate, ApiElevatedErrorRate, ...)
   ```

3. Verify the templating renders correctly by adding an assertion to `api-alerts_test.yml`. `humanizePercentage` turns a `0–1` ratio into a percent string:

   ```yaml
         - eval_time: 20m
           alertname: ApiElevatedErrorRate
           exp_alerts:
             - exp_labels:
                 severity: warning
                 team: payments
                 job: api
               exp_annotations:
                 summary: "api 5xx ratio 9.09% > 1%"
                 runbook_url: "https://runbooks.example.com/api/HighErrorRate"
   ```
   Run `promtool test rules api-alerts_test.yml` → `SUCCESS`.

**Check your understanding**

- **3a.** Which of these belong in **labels** and which in **annotations**, and why does the distinction change system behavior (not just presentation)? `severity`, `runbook_url`, `team`, `summary`, `job`.
- **3b.** `humanizePercentage` expects `$value` in the range 0–1. What would the `summary` display if you templated the raw error *count* instead of the ratio, and why does that make the alert less actionable?
- **3c.** Why ship a `warning` (1% for 30m) and a `critical` (5% for 10m) for the *same* symptom instead of one threshold?
- **3d.** An alert with a perfect `summary` but no `runbook_url` still fails one part of the "why." Which part, and who pays the cost at 3 a.m.?

---

## Exercise 4 — *Where* it goes: Alertmanager routing, grouping, and inhibition

Prometheus decides *whether* to fire; Alertmanager decides *who* is notified, *how grouped*, and *whether* a redundant alert is suppressed. This is the difference between "an alert fired" and "the right person got one useful notification."

1. Create `alertmanager.yml`. The route tree sends `critical` to a pager and `warning` to Slack; grouping collapses a storm into one notification; the inhibit rule silences the `warning` when its `critical` sibling is already firing.

   ```yaml
   # alertmanager.yml
   route:
     receiver: default
     group_by: ['alertname', 'job']
     group_wait: 30s
     group_interval: 5m
     repeat_interval: 4h
     routes:
       - matchers: [ 'severity="critical"' ]
         receiver: pager
       - matchers: [ 'severity="warning"' ]
         receiver: slack

   inhibit_rules:
     - source_matchers: [ 'severity="critical"' ]
       target_matchers: [ 'severity="warning"' ]
       equal: ['alertname', 'job']

   receivers:
     - name: default
     - name: pager
       webhook_configs:
         - url: "http://127.0.0.1:5001/pager"
     - name: slack
       webhook_configs:
         - url: "http://127.0.0.1:5001/slack"
   ```

2. Statically validate the config:

   ```bash
   amtool check-config alertmanager.yml
   ```
   Expected:
   ```
   Checking 'alertmanager.yml'  SUCCESS
   Found:
    - global config
    - route
    - 1 inhibit rules
    - 3 receivers
    - 0 templates
   ```

3. **Test the route tree without sending anything.** Ask Alertmanager which receiver a labelset resolves to:

   ```bash
   amtool config routes test --config.file=alertmanager.yml severity=critical job=api
   # pager

   amtool config routes test --config.file=alertmanager.yml severity=warning job=api
   # slack

   amtool config routes test --config.file=alertmanager.yml severity=info job=api
   # default
   ```

4. Start Alertmanager and read back the effective config and any active silences:

   ```bash
   alertmanager --config.file=alertmanager.yml &
   amtool --alertmanager.url=http://localhost:9093 config show   | head
   amtool --alertmanager.url=http://localhost:9093 silence query   # (empty for now)
   ```

5. Create a **silence** for a planned maintenance window (e.g. a deploy), then confirm it, then expire it:

   ```bash
   amtool --alertmanager.url=http://localhost:9093 silence add \
     job=api --duration=1h --comment="deploy window" --author="$USER"
   # returns a silence ID, e.g. 2f1c...

   amtool --alertmanager.url=http://localhost:9093 silence query
   amtool --alertmanager.url=http://localhost:9093 silence expire <silence-id>
   ```

**Check your understanding**

- **4a.** `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h` — say in one sentence what each timer controls, and which one prevents an unresolved page from re-notifying every evaluation.
- **4b.** The inhibit rule has `equal: ['alertname','job']`. What breaks if you drop `equal` entirely — i.e., inhibit `warning` whenever *any* `critical` is firing anywhere?
- **4c.** Contrast **inhibition** and a **silence**: which is automatic-and-relationship-based, which is human-and-time-boxed, and when do you reach for each?
- **4d.** With `group_by: ['alertname','job']`, forty instances of `ApiHighErrorRate{job="api"}` firing at once produce how many notifications, and why is that the point?

---

## Exercise 5 — *Why now*: multi-window, multi-burn-rate SLO alerting

Static thresholds ("5% for 10m") page too late for slow burns and too eagerly for brief spikes. The SRE Workbook approach alerts on **error-budget burn rate**: how fast you are consuming the budget of a 99.9% SLO. A short *and* long window must both agree, which makes the alert both fast and resistant to spikes.

For a **99.9%** SLO the acceptable error ratio is `0.001`. Burn-rate `14.4×` over 1h consumes 2% of a 30-day budget — page. `6×` over 6h consumes 5% — page. `1×` over 3d consumes 10% — ticket.

1. Create recording rules that precompute the error ratio at every window you need (recording rules keep the alert expressions cheap and readable):

   ```yaml
   # slo-rules.yml
   groups:
     - name: slo:http_error_ratio
       rules:
         - record: job:slo_errors:ratio_rate5m
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[5m]))
                 / sum by (job)(rate(http_requests_total[5m]))
         - record: job:slo_errors:ratio_rate1h
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[1h]))
                 / sum by (job)(rate(http_requests_total[1h]))
         - record: job:slo_errors:ratio_rate30m
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[30m]))
                 / sum by (job)(rate(http_requests_total[30m]))
         - record: job:slo_errors:ratio_rate6h
           expr: sum by (job)(rate(http_requests_total{code=~"5.."}[6h]))
                 / sum by (job)(rate(http_requests_total[6h]))
   ```

2. Add the multi-window burn-rate alerts. Each fires only when the **long** and **short** windows both exceed the burn threshold:

   ```yaml
     - name: slo:burn_rate
       rules:
         # Fast burn: 14.4x over 1h (2% of budget) — PAGE
         - alert: ErrorBudgetBurnFast
           expr: |
             job:slo_errors:ratio_rate1h  > (14.4 * 0.001)
               and
             job:slo_errors:ratio_rate5m  > (14.4 * 0.001)
           for: 2m
           labels: { severity: critical, long_window: 1h, short_window: 5m }
           annotations:
             summary: "Fast error-budget burn on {{ $labels.job }} ({{ $value | humanizePercentage }})"
             runbook_url: "https://runbooks.example.com/slo/burn"

         # Slow burn: 6x over 6h (5% of budget) — PAGE
         - alert: ErrorBudgetBurnSlow
           expr: |
             job:slo_errors:ratio_rate6h  > (6 * 0.001)
               and
             job:slo_errors:ratio_rate30m > (6 * 0.001)
           for: 15m
           labels: { severity: critical, long_window: 6h, short_window: 30m }
           annotations:
             summary: "Slow error-budget burn on {{ $labels.job }}"
             runbook_url: "https://runbooks.example.com/slo/burn"
   ```

3. Validate both files together:

   ```bash
   promtool check rules slo-rules.yml
   #   SUCCESS: 6 rules found
   ```

4. Confirm the burn logic with a unit test. Here the error ratio sits at ~2% (`0.02 > 0.0144`), so **fast** burn should page but the raw "5% for 10m" alert from Exercise 3 would stay silent — that is the improvement:

   ```yaml
   # slo_test.yml
   rule_files: [ slo-rules.yml ]
   evaluation_interval: 1m
   tests:
     - interval: 1m
       input_series:
         - series: 'http_requests_total{job="api", code="500"}'
           values: '0+12x120'     # 12/min => rate 0.2/s
         - series: 'http_requests_total{job="api", code="200"}'
           values: '0+588x120'    # 588/min => rate 9.8/s  => ratio ≈ 2.0%
       alert_rule_test:
         - eval_time: 70m
           alertname: ErrorBudgetBurnFast
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: api
                 long_window: 1h
                 short_window: 5m
               exp_annotations:
                 summary: "Fast error-budget burn on api 2.04%"
                 runbook_url: "https://runbooks.example.com/slo/burn"
   ```
   ```bash
   promtool test rules slo_test.yml     # SUCCESS
   ```

**Check your understanding**

- **5a.** Why require *both* a short and a long window? Describe the specific bad outcome you get from a long-window-only alert, and the one from a short-window-only alert.
- **5b.** Where does the constant `0.0144` come from, and what would you change to move from a 99.9% SLO to a 99.95% SLO?
- **5c.** `ErrorBudgetBurnFast` is `critical`/page; the `1×`-over-3d rule is `warning`/ticket. Tie this back to Exercise 1's rule: why does a slow burn *not* deserve a page?
- **5d.** Why compute the ratio in **recording rules** first instead of inlining the full expression in every alert?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** A legitimate traffic spike, a batch/cron job, or a JIT warm-up can peg CPU for 5 minutes while every request still returns `200` quickly. Nothing is user-visible, yet the on-call is paged. Repeated non-actionable pages train responders to ignore the alert — so the *real* incident gets ignored too. Alert on the symptom (users failing), not the cause (a busy CPU).
- **1b.** A raw count has no denominator: `>10` errors/s is catastrophic for a service doing 20 req/s and irrelevant for one doing 50 000 req/s. The threshold would need per-service tuning and would drift as traffic grows. A **ratio** is traffic-independent and maps directly to an SLO ("5% of requests fail"). `sum by (job)` keeps the `job` label so the resulting alert is identifiable and routable.
- **1c.** On a dashboard, and inside the *description/annotation* of the symptom alert as a debugging hint. Causes inform diagnosis; they don't justify their own page. (SRE book, *Monitoring Distributed Systems*.)

### Exercise 2
- **2a.** Up to `for` + one evaluation interval (~10m15s here) of user-visible failure before firing. A longer `for` is not automatically safer: it trades fewer false positives for a *longer time-to-detect*, and for a fast, total outage that delay is unacceptable. `for` is tuned per alert against how fast the symptom must be caught.
- **2b.** (1) The `rate(...[5m])` needs its window to fill before it reflects the true rate (~5m ramp), and (2) the `for: 10m` clause requires the condition to hold continuously *after* that. The two delays stack.
- **2c.** Single-scrape blips and transient spikes now page instantly (flapping). Worse, a metric that briefly goes stale/absent can make the expression evaluate oddly; `for` absorbs momentary conditions and only escalates sustained ones.
- **2d.** The unit test is deterministic, versioned, and runs in CI on every change — it asserts *exact* state (`pending`/`firing`) and *exact* rendered annotations at *exact* times. Eyeballing a graph is a one-off, non-reproducible check that silently rots when someone edits the rule later.

### Exercise 3
- **3a.** **Labels:** `severity`, `team`, `job` — they are part of the alert's identity and drive Alertmanager routing, grouping, inhibition, and silences (system behavior). **Annotations:** `runbook_url`, `summary` — human-readable payload only; changing them never re-routes an alert. Putting `runbook_url` in a label would pollute the identity/grouping key; putting `severity` in an annotation would make routing impossible.
- **3b.** It would show something like `9.09` interpreted as `909%` — because `humanizePercentage` multiplies by 100 and expects a 0–1 ratio, a raw count produces nonsense. Beyond the formatting, a bare count doesn't tell the responder *how bad relative to normal*, so it isn't actionable.
- **3c.** Different urgencies deserve different responses and channels: 1%-for-30m is a slow degradation worth a Slack ticket during business hours; 5%-for-10m is an active outage worth a page. One threshold either pages on minor blips (fatigue) or misses slow burns (blind spot).
- **3d.** The "what do I do next" part. Without a runbook the responder improvises under pressure at 3 a.m., increasing time-to-mitigate and error risk. Actionability, not just detection, is the goal.

### Exercise 4
- **4a.** `group_wait` = how long to hold the *first* notification of a new group so related alerts batch together; `group_interval` = minimum wait before notifying again about *new* alerts added to an existing group; `repeat_interval` = how often to *re-send* an unchanged, still-firing group. `repeat_interval` is the one that stops per-evaluation re-notification.
- **4b.** Without `equal`, a single unrelated `critical` (say a database alert) would inhibit *all* `warning`s across every service — you'd suppress warnings that have nothing to do with the firing critical. `equal: ['alertname','job']` scopes inhibition to the *same* symptom on the *same* service, so only the redundant sibling is silenced.
- **4c.** **Inhibition** is automatic and relationship-based: when a more-severe alert fires, its lower-severity sibling is suppressed by rule, indefinitely, as long as the source fires. **A silence** is human-initiated and time-boxed: a person mutes a labelset for a known window (deploy, maintenance) and it expires on its own. Use inhibition for structural redundancy; use silences for planned, temporary human decisions.
- **4d.** **One** notification — the forty instances collapse into a single grouped notification keyed by `(alertname, job)`. That's the point: grouping turns an alert storm into one actionable message instead of forty pages.

### Exercise 5
- **5a.** The **long window** makes the alert precise and spike-resistant but slow to fire. The **short window** makes it fast but noisy. Long-only ⇒ you detect a real outage too late (budget already burned). Short-only ⇒ a brief spike pages you for something already recovered. Requiring both to exceed the threshold gives fast *and* precise: fires quickly on a sustained burn, and the short window also lets the alert *resolve* quickly once the burn stops.
- **5b.** `0.0144 = 14.4 × 0.001`, where `0.001 = 1 − 0.999` is the allowed error ratio of a 99.9% SLO and `14.4` is the burn-rate factor that spends 2% of a 30-day budget in 1h. For a 99.95% SLO you change the base error budget to `0.0005` (`1 − 0.9995`); the burn-rate factors (14.4, 6, 1) stay the same, so the thresholds become `14.4 × 0.0005`, etc.
- **5c.** A slow burn (`1×` over days) is still within a response window that a next-business-day ticket satisfies — mirroring Exercise 1: page only for symptoms that need *immediate* human action. Paging for something you have days to fix is non-actionable-now and breeds fatigue. Reserve pages for fast burns that threaten the budget within hours.
- **5d.** Recording rules precompute the (expensive) ratio once per window, so each burn-rate alert is a cheap comparison against a single series instead of re-evaluating nested `sum(rate(...))` over 6h/1h on every evaluation. They also keep alert expressions readable, reusable across multiple alerts/dashboards, and consistent (one definition of "the error ratio").

</details>