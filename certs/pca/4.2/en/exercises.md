# Exercises — Topic 4.2: Configuring Alerting Rules (PCA)

> Prometheus itself only *decides when an alert is firing*; the actual notification (email, Slack, PagerDuty) is Alertmanager's job. This topic is about the first half: writing, validating, testing and reloading **alerting rules** inside Prometheus, and understanding the `inactive → pending → firing` lifecycle. Keep that boundary in mind — most exam traps live exactly on it.
>
> Reference material used throughout:
> - Alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
> - Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
> - Template reference — https://prometheus.io/docs/prometheus/latest/configuration/template_reference/
> - Unit testing rules — https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/
> - Alertmanager wiring — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
> - PCA curriculum — https://github.com/cncf/curriculum

---

## Lab setup (do this once)

You need the `prometheus` and `promtool` binaries (both ship in the same tarball) and, optionally, `node_exporter`. Everything below runs from a single directory.

```
pca-alerting-lab/
├── prometheus.yml
├── rules/
│   └── node-alerts.yml
└── tests/
    └── node-alerts_test.yml
```

**Steps**

1. Create the lab directory and enter it:

   ```bash
   mkdir -p pca-alerting-lab/rules pca-alerting-lab/tests
   cd pca-alerting-lab
   ```

2. Write `prometheus.yml`. Note the three sections that matter for this topic: `evaluation_interval`, `rule_files`, and `alerting`.

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s      # how often rule groups are evaluated by default
     external_labels:
       cluster: pca-lab
       region: local

   rule_files:
     - "rules/*.yml"               # glob is resolved relative to this file

   alerting:
     alertmanagers:
       - static_configs:
           - targets:
               - "localhost:9093"  # where firing alerts are pushed (may be down; fine for now)

   scrape_configs:
     - job_name: "prometheus"
       static_configs:
         - targets: ["localhost:9090"]
     - job_name: "node"
       static_configs:
         - targets: ["localhost:9100"]   # we will NOT start node_exporter, on purpose
   ```

3. Create an empty rules file so Prometheus starts cleanly:

   ```bash
   printf 'groups: []\n' > rules/node-alerts.yml
   ```

4. Start Prometheus with the lifecycle API enabled (you will need it to hot-reload rules later):

   ```bash
   prometheus \
     --config.file=prometheus.yml \
     --web.enable-lifecycle
   ```

5. In a second terminal, confirm the config loaded and no rules exist yet:

   ```bash
   curl -s http://localhost:9090/api/v1/rules | jq '.data.groups | length'
   ```

   Expected output:

   ```
   0
   ```

**Check your understanding**

- **Q1.** Which two configuration keys are strictly required for an alerting rule to ever be *evaluated* and for its firing state to ever *leave* Prometheus? Name the file section for each.
- **Q2.** We deliberately did not start `node_exporter`. Predict what the metric `up{job="node"}` will equal, and why that is useful for the next exercise.
- **Q3.** `--web.enable-lifecycle` is off by default. What operational risk does enabling it introduce, and how is it usually mitigated in production?

---

## Exercise 1 — Your first alerting rule and the pending → firing lifecycle

**Goal:** wire a real rule, watch it move through the three states, and understand the `for` clause.

**Steps**

1. Replace `rules/node-alerts.yml` with two rules — one that fires immediately when a target is down, and one synthetic rule built purely to observe the lifecycle:

   ```yaml
   # rules/node-alerts.yml
   groups:
     - name: node.rules
       rules:
         - alert: TargetDown
           expr: up{job="node"} == 0
           for: 1m
           labels:
             severity: critical
           annotations:
             summary: "Target {{ $labels.instance }} (job {{ $labels.job }}) is down"
             description: "{{ $labels.instance }} has failed scraping for more than 1 minute."

         - alert: LifecycleDemo
           expr: vector(1)          # always returns one series with value 1 -> always active
           for: 2m
           labels:
             severity: none
           annotations:
             summary: "Demo alert used to watch inactive -> pending -> firing"
   ```

2. Hot-reload Prometheus (no restart needed):

   ```bash
   curl -s -X POST http://localhost:9090/-/reload && echo reloaded
   ```

   Expected output:

   ```
   reloaded
   ```

3. Immediately query the alert state. Do this **twice**, ~30 s apart, then again after 2–3 minutes:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | "\(.labels.alertname)\t\(.state)\t\(.activeAt)"'
   ```

   Expected progression (first call, seconds after reload):

   ```
   TargetDown       pending    2026-08-09T14:03:11.402Z
   LifecycleDemo    pending    2026-08-09T14:03:11.402Z
   ```

   After ~1 minute:

   ```
   TargetDown       firing     2026-08-09T14:03:11.402Z
   LifecycleDemo    pending    2026-08-09T14:03:11.402Z
   ```

   After ~2 minutes:

   ```
   TargetDown       firing     2026-08-09T14:03:11.402Z
   LifecycleDemo    firing     2026-08-09T14:03:11.402Z
   ```

4. Look at the same lifecycle through the synthetic `ALERTS` metric that Prometheus writes for every active alert. In the expression browser (`http://localhost:9090/graph`) run:

   ```promql
   ALERTS{alertname="TargetDown"}
   ```

   Expected instant-vector result once firing:

   ```
   ALERTS{alertname="TargetDown", alertstate="firing", instance="localhost:9100", job="node", severity="critical"}   1
   ```

**Check your understanding**

- **Q4.** `TargetDown` has `for: 1m` and `LifecycleDemo` has `for: 2m`, yet both became `pending` at the *same* `activeAt` timestamp. Explain precisely what `activeAt` marks and why `for` controls the *transition to firing*, not the transition to pending.
- **Q5.** During the pending window, does Prometheus send anything to Alertmanager? What about during firing?
- **Q6.** The `ALERTS` series carries a label `alertstate`. What are its possible values, and would a query for `ALERTS{alertstate="inactive"}` ever return data? Why or why not?
- **Q7.** If you set `for: 0` (or omit `for` entirely), how does the lifecycle change?

---

## Exercise 2 — Validate before you ship: `promtool check rules`

**Goal:** catch broken rules at author time, offline, with zero cost — this is the "quality floor before writing" mindset.

**Steps**

1. Run the linter against your rule file:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Expected output:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   ```

2. Now deliberately break the file to learn the failure modes. Introduce a **PromQL syntax error** by removing the `==`:

   ```yaml
           expr: up{job="node"} 0
   ```

   Re-run:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Expected output (exit code non-zero):

   ```
   Checking rules/node-alerts.yml
     FAILED:
   rules/node-alerts.yml: could not parse expression: 1:20: parse error: unexpected number "0"
   ```

3. Fix that, then introduce a **structural error**: rename `alert:` to `name:` on the first rule. Re-run `promtool check rules`. Expected output:

   ```
   Checking rules/node-alerts.yml
     FAILED:
   rules/node-alerts.yml: yaml: unmarshal errors:
     line 4: field name not found in type rulefmt.RuleNode
   ```

4. Fix it back to a valid file and confirm `SUCCESS` again. Then check the exit code explicitly (this is what CI relies on):

   ```bash
   promtool check rules rules/node-alerts.yml; echo "exit=$?"
   ```

   Expected output:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   exit=0
   ```

**Check your understanding**

- **Q8.** `promtool check rules` validates two distinct things about each rule. What are they, and what does it *not* verify?
- **Q9.** Why is a non-zero exit code the property that actually matters for a pre-commit hook or CI gate, more than the human-readable text?
- **Q10.** You can also run `promtool check config prometheus.yml`. How does that differ in scope from `promtool check rules`, and which one transitively covers the other?

---

## Exercise 3 — Templating labels and annotations

**Goal:** produce alerts a human can act on — with the offending value, instance, and humanized units interpolated.

**Steps**

1. Add a resource-usage alert that uses templating heavily. Append this rule to the `node.rules` group:

   ```yaml
         - alert: NodeHighMemory
           expr: |
             100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 85
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "High memory on {{ $labels.instance }}"
             description: >-
               Memory usage is {{ $value | printf "%.1f" }}% on
               {{ $labels.instance }} (job {{ $labels.job }}),
               above 85% for 5m. Cluster: {{ $externalLabels.cluster }}.
             runbook_url: "https://runbooks.example.com/NodeHighMemory"
   ```

2. Validate:

   ```bash
   promtool check rules rules/node-alerts.yml
   ```

   Expected:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 3 rules found
   ```

3. Study three key templating variables and functions by reading the rendered annotation once the alert fires (or via a unit test in Exercise 4). The interesting pieces:
   - `{{ $labels.<name> }}` — labels of the *individual series* that triggered this alert instance.
   - `{{ $value }}` — the *scalar sample value* returned by `expr` for that series.
   - `{{ $externalLabels.<name> }}` — the `global.external_labels` from `prometheus.yml`.

4. Compare two humanizing pipelines. In the expression browser, this is what the template functions do to a raw value like `0.8734`:

   | Template snippet | Renders as |
   |---|---|
   | `{{ $value }}` | `0.8734` |
   | `{{ $value | printf "%.1f" }}` | `0.9` |
   | `{{ $value | humanizePercentage }}` | `87.34%` (expects a 0–1 ratio) |
   | `{{ humanize $value }}` | `873.4m` |
   | `{{ humanizeDuration 3661 }}` | `1h 1m 1s` |

   > `humanizePercentage` multiplies by 100, so feed it a **ratio** (0–1). If your `expr` already multiplies by 100 (as `NodeHighMemory` does), use `printf "%.1f"` and append a literal `%` instead — mixing them gives `8734.0%`.

**Check your understanding**

- **Q11.** In `{{ $labels.instance }}`, where does that label value come from — the rule, the scrape config, or the matched series at evaluation time?
- **Q12.** `{{ $value }}` in a `TargetDown` alert whose `expr` is `up{job="node"} == 0` — what number does it print, and why is that not always the useful number to show? What is one way to expose a more meaningful value?
- **Q13.** A colleague writes `{{ $value | humanizePercentage }}` for the `NodeHighMemory` alert (whose expr already multiplies by 100). What will the student read in the notification, and how do you fix it?
- **Q14.** Labels vs annotations: which set participates in Alertmanager grouping/deduplication and alert *identity*, and which is purely informational? What's the practical consequence of putting a high-cardinality value (like `$value`) in a **label**?

---

## Exercise 4 — Unit-testing rules with `promtool test rules`

**Goal:** prove a rule fires with the right labels/annotations at the right time, deterministically, with no running Prometheus. This is the strongest guarantee you can get offline.

**Steps**

1. Create the test file. The syntax `0x10` means "value 0, repeated 10 more times" (i.e. 11 samples at 1-minute steps).

   ```yaml
   # tests/node-alerts_test.yml
   rule_files:
     - ../rules/node-alerts.yml

   evaluation_interval: 1m

   tests:
     # ---- TargetDown ----
     - interval: 1m
       input_series:
         - series: 'up{job="node", instance="localhost:9100"}'
           values: "0x10"               # target down the whole time
       alert_rule_test:
         - eval_time: 30s               # before `for: 1m` elapses
           alertname: TargetDown
           exp_alerts: []               # still pending -> nothing firing yet
         - eval_time: 3m                # well past `for: 1m`
           alertname: TargetDown
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: node
                 instance: localhost:9100
               exp_annotations:
                 summary: "Target localhost:9100 (job node) is down"
                 description: "localhost:9100 has failed scraping for more than 1 minute."

     # ---- NodeHighMemory (templating + value) ----
     - interval: 1m
       input_series:
         - series: 'node_memory_MemTotal_bytes{job="node", instance="localhost:9100"}'
           values: "100x10"
         - series: 'node_memory_MemAvailable_bytes{job="node", instance="localhost:9100"}'
           values: "10x10"              # 90% used -> above 85 threshold
       alert_rule_test:
         - eval_time: 6m                # past `for: 5m`
           alertname: NodeHighMemory
           exp_alerts:
             - exp_labels:
                 severity: warning
                 job: node
                 instance: localhost:9100
               exp_annotations:
                 summary: "High memory on localhost:9100"
                 description: "Memory usage is 90.0% on localhost:9100 (job node), above 85% for 5m. Cluster: pca-lab."
                 runbook_url: "https://runbooks.example.com/NodeHighMemory"
   ```

2. Run the tests:

   ```bash
   promtool test rules tests/node-alerts_test.yml
   ```

   Expected output on success:

   ```
   Unit Testing:  tests/node-alerts_test.yml
   SUCCESS
   ```

3. Make it fail on purpose to read a diff. Change the expected description to `"...above 90%..."` and re-run. Expected output:

   ```
   Unit Testing:  tests/node-alerts_test.yml
   FAILED:
     alertname: NodeHighMemory, time: 6m,
         exp:[
           0:
             Labels:{alertname="NodeHighMemory", instance="localhost:9100", job="node", severity="warning"}
             Annotations:{description="Memory usage is 90.0% ... above 90% ...", ...}
         ],
         got:[
           0:
             Labels:{alertname="NodeHighMemory", instance="localhost:9100", job="node", severity="warning"}
             Annotations:{description="Memory usage is 90.0% ... above 85% ...", ...}
         ]
   ```

4. Fix it back to green. Add a `promql_expr_test` block to the second test to assert the raw computed value too — this pins the arithmetic independently of the alert:

   ```yaml
       promql_expr_test:
         - expr: '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
           eval_time: 6m
           exp_samples:
             - labels: '{job="node", instance="localhost:9100"}'
               value: 90
   ```

**Check your understanding**

- **Q15.** Why is `exp_alerts: []` at `eval_time: 30s` a *meaningful* assertion rather than a no-op? What behavior would a bug have to exhibit for this line to catch it?
- **Q16.** The unit test never contacts Alertmanager and never runs a scrape. Given that, what class of production problems can it *not* catch, even when it passes?
- **Q17.** In `values: "0x10"`, how many samples exist and at what timestamps (given `interval: 1m`)? What would `values: "1+2x4"` produce?
- **Q18.** Why does `alert_rule_test` only assert *firing* alerts and never pending ones? Tie your answer back to Q4.

---

## Exercise 5 — Rule groups, evaluation order, recording rules feeding alerts, and `keep_firing_for`

**Goal:** understand *when* and *in what order* rules evaluate, and how a recording rule can precompute an expensive expression that an alert then reads.

**Steps**

1. Refactor so an expensive expression is computed once by a **recording rule**, and the alert references that recorded series. Note the ordering: within one group, rules evaluate **top to bottom, sequentially**, so a recording rule defined *above* an alert is available to it in the same evaluation cycle.

   ```yaml
   # rules/node-alerts.yml  (relevant group)
   groups:
     - name: node.slo
       interval: 30s                 # per-group override of global evaluation_interval
       limit: 0                      # 0 = unlimited alerts/series produced by this group
       rules:
         # (1) recording rule — computed first
         - record: instance:node_memory_utilization:ratio
           expr: 1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes

         # (2) alert reads the recorded series — computed second, same cycle
         - alert: NodeHighMemory
           expr: instance:node_memory_utilization:ratio > 0.85
           for: 5m
           keep_firing_for: 5m       # stay firing 5m after expr goes false (dampens flapping)
           labels:
             severity: warning
           annotations:
             summary: "High memory on {{ $labels.instance }}"
             description: "Memory at {{ $value | humanizePercentage }} on {{ $labels.instance }}."
   ```

   > `keep_firing_for` requires Prometheus **v2.42+**. On older versions `promtool check rules` will reject the unknown field — a clean way to detect the running version's capabilities.

2. Validate and reload:

   ```bash
   promtool check rules rules/node-alerts.yml && \
   curl -s -X POST http://localhost:9090/-/reload && echo ok
   ```

   Expected:

   ```
   Checking rules/node-alerts.yml
     SUCCESS: 2 rules found
   ok
   ```

3. Inspect group evaluation health via the API — every group reports its `interval`, `evaluationTime` (how long the last run took) and `lastEvaluation`:

   ```bash
   curl -s http://localhost:9090/api/v1/rules \
     | jq -r '.data.groups[] | "\(.name)\tinterval=\(.interval)s\tlast_took=\(.evaluationTime)s"'
   ```

   Expected output:

   ```
   node.slo    interval=30s    last_took=0.0012s
   ```

4. Confirm the recorded series exists as a first-class metric you can query and alert on:

   ```promql
   instance:node_memory_utilization:ratio
   ```

**Check your understanding**

- **Q19.** Rules *within* a group run sequentially; groups run **independently and concurrently**. Why does that make it unsafe to put a recording rule in group A and an alert that depends on it in group B?
- **Q20.** What does `keep_firing_for` change about the lifecycle, and how does it differ conceptually from `for`? Give a flapping scenario where it prevents a notification storm.
- **Q21.** A group's `evaluationTime` starts creeping toward its `interval` (e.g. `last_took=27s` on a 30s group). What is about to happen, what does Prometheus expose to warn you, and what are two remedies?
- **Q22.** Why prefer a recording rule for `instance:node_memory_utilization:ratio` over inlining the division in ten different alerts? Name at least two distinct benefits.

---

## Exercise 6 — Advanced diagnostics: reloads, evaluation failures, and `for`-state across restarts

**Goal:** debug the failure modes that separate "the rule is written" from "the rule works in production."

**Steps**

1. **Diagnose a silently-ignored rule file.** Add a rule with a label value that is not a valid string and reload. Then check the reload actually succeeded:

   ```bash
   curl -s -X POST http://localhost:9090/-/reload; echo "exit=$?"
   ```

   A failed reload returns HTTP 400 with a body, and Prometheus keeps the *previous* good config. Confirm which config is live:

   ```bash
   curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head
   ```

   > Lesson: a rejected reload does **not** crash Prometheus and does **not** apply the new rules. Always assert the exit code / HTTP status; "I ran curl" is not "the rules are live."

2. **Find a rule that is loaded but erroring at evaluation.** A rule can pass `promtool check rules` (syntactically valid) yet fail every evaluation (e.g. an aggregation that produces duplicate series). Query rule health:

   ```bash
   curl -s http://localhost:9090/api/v1/rules \
     | jq -r '.data.groups[].rules[] | select(.health != "ok") | "\(.name // .record)\t\(.health)\t\(.lastError)"'
   ```

   Expected output when a rule is broken:

   ```
   NodeHighMemory    err    found duplicate series for the match group ...
   ```

   Cross-check with the built-in metrics:

   ```promql
   rate(prometheus_rule_evaluation_failures_total[5m]) > 0
   ```

3. **Observe `for`-state restoration across a restart.** Get `LifecycleDemo` into `firing`, note its `activeAt`, then restart Prometheus and immediately re-query. Prometheus restores the `for` progress from the persisted `ALERTS_FOR_STATE` series in its TSDB rather than resetting the clock to zero:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | select(.labels.alertname=="LifecycleDemo") | "\(.state)\t\(.activeAt)"'
   ```

   The `activeAt` after restart should match the pre-restart value (within tolerance), not jump to "now."

4. Relate this to the flags that govern restoration:
   - `--rules.alert.for-outage-tolerance` (default `1h`) — max downtime for which `for` state is still restored.
   - `--rules.alert.for-grace-period` (default `10m`) — minimum enforced `for` after restart to avoid instant re-fire.

**Check your understanding**

- **Q23.** A teammate says "I reloaded, but the new alert isn't showing up." Walk through the exact sequence of checks (commands/endpoints) you'd run to distinguish: (a) reload rejected, (b) rule loaded but erroring, (c) rule healthy but never satisfies its `expr`, (d) rule pending, not yet firing.
- **Q24.** Without `for`-state restoration, what undesirable behavior would every Prometheus restart cause for alerts that use a long `for` (say `for: 1h`)? How do `for-outage-tolerance` and `for-grace-period` bound the two edge cases (short blip vs. long outage)?
- **Q25.** `prometheus_rule_group_last_duration_seconds`, `prometheus_rule_evaluation_failures_total`, and `prometheus_rule_group_iterations_missed_total` — match each to the specific failure it detects.
- **Q26.** Why does relying on `ALERTS_FOR_STATE` mean that a Prometheus with a *wiped* TSDB (fresh volume) will re-arm every `for` timer from zero — and why is that occasionally the *desired* behavior after a major incident?

---

## Answers

<details>
<summary>Show answers (Q1–Q26)</summary>

**Q1.** (1) `rule_files:` in `prometheus.yml` — without it the file is never loaded, so the rule is never evaluated. (2) The `alerting:` / `alertmanagers:` block — without a reachable Alertmanager the alert can reach `firing` internally but its notification never leaves Prometheus. Evaluation needs `rule_files`; *delivery* needs `alerting`.

**Q2.** `node_exporter` isn't running, so the scrape of `localhost:9100` fails and Prometheus records `up{job="node"} == 0`. That gives us a deterministic, always-true condition to drive `TargetDown` without having to break anything real.

**Q3.** `--web.enable-lifecycle` exposes `POST /-/reload` and `/-/quit`, which unauthenticated callers could abuse to trigger reloads or shut Prometheus down. Mitigations: restrict via a reverse proxy / network policy, bind to a private interface, and/or require auth in front of the HTTP endpoints. Many shops instead reload with `SIGHUP` and leave the lifecycle API off.

**Q4.** `activeAt` marks the instant the `expr` first returned a result for that series — i.e. the moment the alert became **active (pending)**. `for` is a *dwell time*: the condition must stay continuously true for that whole duration before the state flips to **firing**. Both alerts became active at the same instant (both exprs were true immediately after reload), but they fire at different times because their `for` values differ (1m vs 2m). If `expr` goes false at any point, `activeAt` resets and the `for` clock restarts.

**Q5.** Pending → nothing is sent to Alertmanager; pending is purely internal. Firing → Prometheus sends the alert to every configured Alertmanager and keeps re-sending it (per `--rules.alert.resend-delay`, default 1m) for as long as it stays firing, plus a "resolved" notification when it clears.

**Q6.** `alertstate` is `pending` or `firing` only. `ALERTS{alertstate="inactive"}` never returns data because Prometheus writes the `ALERTS` series *only while an alert is active*; an inactive alert produces no series at all (the absence of the series is what "inactive" means).

**Q7.** With `for: 0` (or omitted) there is no pending phase from the user's perspective: as soon as `expr` is true at an evaluation, the alert goes straight to `firing`. It's more sensitive (fires on a single true evaluation) and therefore more prone to flapping on transient spikes.

**Q8.** It checks (1) that each `expr` is *valid PromQL* (parses) and (2) that the file's *structure* conforms to the rule schema (correct keys like `alert`/`record`/`expr`/`for`/`labels`/`annotations`). It does **not** check that the metrics referenced actually exist, that the threshold is sensible, that the alert will ever fire, or that annotations render correctly — only unit tests / live evaluation do that.

**Q9.** Automation (pre-commit hooks, CI) branches on exit status, not on scraping stdout. `promtool check rules` returns non-zero on any failure, so `... && git commit` or a CI step naturally blocks the bad change. The human text is for the person reading the log; the exit code is the gate.

**Q10.** `promtool check config prometheus.yml` validates the main config *and* transitively validates every file matched by `rule_files:` (it invokes the same rule check). `promtool check rules FILE` validates only the rule file(s) you name. `check config` is the superset — but you often run `check rules` directly in CI when only rule files changed.

**Q11.** From the **matched series at evaluation time**. The alert's `expr` returns a set of series (each with its own labels, inherited from the scrape/relabeling that produced them); `$labels` is the label set of the specific series that triggered this alert instance. It is not taken from the rule text or statically from the scrape config.

**Q12.** For `up == 0`, the `expr` evaluates to `1` where the comparison holds (the filtered result value is the left operand's value only if you use `bool`; with a plain filter the returned sample value is the left-hand `up` value, which is `0`). Either way it's a constant tied to the comparison, not a meaningful magnitude. To show something useful, base the alert on a metric whose value carries information (e.g. `time() - node_boot_time_seconds`), or put the meaningful figure in a separate annotation via a templated sub-query, or record it as a companion series.

**Q13.** `NodeHighMemory`'s expr already yields a percentage (e.g. `90`). `humanizePercentage` multiplies by 100 and appends `%`, so the student reads **`9000%`**. Fix: either feed `humanizePercentage` a 0–1 ratio (drop the `*100` in the expr, as done in Exercise 5) or keep the `*100` expr and render with `{{ $value | printf "%.1f" }}%`.

**Q14.** **Labels** define alert identity and drive Alertmanager grouping, routing, inhibition and deduplication; **annotations** are free-form, informational, and ignored for identity. Putting a high-cardinality value like `$value` in a *label* changes the alert's identity on every evaluation, so Alertmanager sees a brand-new alert each time — breaking dedup/grouping and causing notification storms. High-cardinality data belongs in annotations.

**Q15.** It asserts that at 30s (before `for: 1m` has elapsed) the alert is **not yet firing** — i.e. that the `for` clause is actually being honored. A bug that ignored `for` (fired immediately) would produce a firing alert at 30s, and this assertion would catch it. So `exp_alerts: []` pins the *timing semantics*, not just the eventual outcome.

**Q16.** Anything that depends on the live environment: wrong/missing target labels from real relabeling, metrics that don't exist in production, Alertmanager routing/silences/inhibition, notification delivery, scrape gaps and staleness, and rule-group scheduling under real load. A green unit test proves the rule's logic given synthetic input; it says nothing about whether the real input arrives.

**Q17.** `values: "0x10"` = 11 samples (the initial `0` plus 10 repeats) at t = 0, 1m, 2m, … 10m. `values: "1+2x4"` = an arithmetic sequence starting at 1, step +2, 4 repeats → `1, 3, 5, 7, 9` (5 samples).

**Q18.** Because pending is an internal, transient bookkeeping state that never leaves Prometheus and is fully determined by `for` + `activeAt`; the externally meaningful outcome is *what fires*. `alert_rule_test` asserts the observable contract (which alerts, with which labels/annotations, at which times). You test the pending window indirectly by asserting `exp_alerts: []` at a time before `for` elapses (Q15), which is exactly what ties back to Q4's lifecycle.

**Q19.** Groups evaluate concurrently, each on its own schedule, and consistency of a rule's inputs is only guaranteed *within* a single group's sequential top-to-bottom pass. If the recording rule is in group A and the dependent alert in group B, the alert may read a stale value (last cycle's) or none at all on the first run, and the two can drift on every evaluation. Keep a recording rule and its dependent alert in the **same group**, recording rule first.

**Q20.** `for` gates *entry* into firing (condition must hold N seconds before firing). `keep_firing_for` gates *exit*: after `expr` stops returning the series, the alert stays firing for the extra duration before resolving. Flapping scenario: a metric oscillates just above/below the threshold every 20–40s. With only `for`, you get repeated fire/resolve cycles and a resolved+fired notification storm; `keep_firing_for: 5m` holds it firing across the dips, collapsing the noise into one sustained alert.

**Q21.** The group's evaluation is nearly overrunning its interval; if `evaluationTime` exceeds `interval`, iterations are **skipped** (alerts evaluate late, `for` timing degrades). Prometheus exposes `prometheus_rule_group_last_duration_seconds`, `prometheus_rule_group_iterations_missed_total`, and `prometheus_rule_group_interval_seconds`. Remedies: split the group into smaller groups (more parallelism), replace expensive inline exprs with recording rules, widen the group `interval`, or reduce series cardinality feeding the rules.

**Q22.** (1) Cost/performance: the expensive division is computed once per cycle instead of once per dependent alert and per dashboard query. (2) Consistency: every consumer reads the identical precomputed series, so alerts and dashboards can't disagree. (3) Faster dashboards/queries over long ranges (the derived series is stored). (4) Single point of change if the formula needs fixing.

**Q23.** (a) `curl -s -X POST /-/reload; echo exit=$?` and/or check HTTP status and logs — non-zero/400 means reload rejected and old rules remain live; confirm with `/api/v1/status/config`. (b) `GET /api/v1/rules` and filter `.health != "ok"` and read `.lastError`; corroborate with `rate(prometheus_rule_evaluation_failures_total[5m])`. (c) Rule shows `health: ok` but run its `expr` in the expression browser — if it returns no series, the condition is simply not met. (d) `GET /api/v1/alerts` shows `state: pending` with a recent `activeAt` — it's within its `for` window; wait it out.

**Q24.** Every restart would reset each alert's `for` clock to zero, so a `for: 1h` alert that had been counting for 55m would start over and delay firing by up to another hour — restarts (deploys, OOMs) could indefinitely postpone real alerts. `for-outage-tolerance` (default 1h) caps how long a *gap* can be while still trusting the restored state (beyond that, treat as fresh); `for-grace-period` (default 10m) enforces a minimum post-restart `for` so a long-`for` alert doesn't instantly re-fire the moment Prometheus comes back.

**Q25.** `prometheus_rule_group_last_duration_seconds` → a group taking too long to evaluate (approaching/over its interval). `prometheus_rule_evaluation_failures_total` → individual rule evaluations erroring (bad expr result at runtime, duplicate series, etc.). `prometheus_rule_group_iterations_missed_total` → whole evaluation cycles skipped because the previous run hadn't finished (overrun) — the direct symptom of the duration problem.

**Q26.** `for`-state is persisted as the `ALERTS_FOR_STATE` series inside Prometheus's own TSDB; on startup Prometheus reads it back to reconstruct `activeAt`. A fresh/empty TSDB has no such series, so nothing can be restored and every `for` timer starts at zero. That's occasionally desirable: after a major incident or a clean migration you may *want* every alert re-evaluated from a blank slate rather than resurrecting stale firing state that no longer reflects reality.

</details>