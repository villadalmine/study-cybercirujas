# Timestamp Metrics

**Certification:** Prometheus Certified Associate (PCA) · **Domain:** PromQL · **Topic 1.7** · **Exam weight: 4**

---

## 1. Motivation: the two clocks and why a metric can *be* a timestamp

Every sample Prometheus stores is a triple: `(series identity, value float64, sample timestamp ms)`. The **sample timestamp** answers *"when did Prometheus observe this?"*. It is assigned by the scrape loop (or copied from the exposition format when `honor_timestamps` is on) and it is what the TSDB indexes on the time axis.

A **timestamp metric** is a completely different thing that happens to look similar: it is an ordinary `gauge` whose *value* is a Unix epoch time (seconds since `1970-01-01T00:00:00Z`). The series is scraped every 15 s like any other gauge, but the number it carries is not a rate or a count — it encodes *when an event happened*:

| Metric | Exporter / source | The value means… |
|---|---|---|
| `process_start_time_seconds` | any client library | when this process booted |
| `node_boot_time_seconds` | node_exporter | when the kernel came up |
| `node_time_seconds` | node_exporter | the node's *own* wall clock at scrape |
| `probe_ssl_earliest_cert_expiry` | blackbox_exporter | when the TLS chain first expires |
| `push_time_seconds` | Pushgateway (auto-added) | when the last push for this group arrived |
| `kube_pod_start_time` | kube-state-metrics | when the Pod was scheduled/started |
| `prometheus_config_last_reload_success_timestamp_seconds` | Prometheus itself | last successful config reload |
| `<job>_last_success_timestamp_seconds` | your batch jobs → Pushgateway | last successful run |

The production problem this topic solves is **freshness and deadlines under a pull model**. Prometheus scrapes; it does not receive events. So the questions that keep an SRE up at night — *"has the nightly backup run in the last 26 h?"*, *"does any certificate expire within 7 days?"*, *"did this process just restart?"*, *"is this node's clock drifting away from Prometheus?"* — cannot be answered by counting or rating. They are answered by arithmetic between **`time()` (the evaluation clock)** and a **timestamp metric (the event clock)**.

The single canonical idiom is subtraction:

```promql
# Age of a process, in seconds
time() - process_start_time_seconds

# Time remaining before a certificate expires, in seconds
probe_ssl_earliest_cert_expiry - time()
```

`time()` returns the **evaluation timestamp** of the query as epoch seconds — *not* `now()` on the server, but the instant the sample is being evaluated for (this matters for range queries and backfills, where each step evaluates at its own `time()`). This is why a `time() - X` expression plotted over a range produces a clean sawtooth that resets at each restart: every step subtracts a *different* `time()`.

---

## 2. The function family and its trade-offs

Three distinct mechanisms are routinely confused. Keep them apart:

| Function | Returns | Argument | Typical use |
|---|---|---|---|
| `time()` | evaluation time (epoch s) | none | the "now" side of every deadline/age calc |
| `timestamp(v)` | the **sample** timestamp of each element of `v` (epoch s) | instant-vector | scrape lag, staleness, clock-skew, "when last observed" |
| `<gauge value>` | the encoded **event** time (epoch s) | — | the "then" side; it is just data |

And the calendar helpers, all of which **interpret their input as a Unix timestamp and return UTC**, defaulting to `vector(time())` when called with no argument:

| Function | Range | Notes |
|---|---|---|
| `year(v=vector(time()))` | e.g. 2026 | UTC |
| `month(v)` | 1–12 | UTC |
| `day_of_month(v)` | 1–31 | UTC |
| `day_of_week(v)` | 0–6 | **0 = Sunday**, 6 = Saturday |
| `day_of_year(v)` | 1–366 | UTC |
| `days_in_month(v)` | 28–31 | leap-year aware |
| `hour(v)` | 0–23 | UTC |
| `minute(v)` | 0–59 | UTC |

> **Trap #1 — everything is UTC.** `hour()` never respects a local timezone. "Business hours 09:00–18:00 Buenos Aires (UTC−3)" must be written as `hour() >= 12 and hour() < 21`. There is no `tz` argument.

> **Trap #2 — `timestamp()` is the sample clock, not the value.** `timestamp(node_boot_time_seconds)` returns *when Prometheus scraped it*, not the boot time. To read the boot time you use the bare series. Mixing these up is the most common PromQL error in this domain.

### `time() - X` vs `timestamp()` — when to reach for each

| Goal | Correct expression | Why |
|---|---|---|
| Uptime of a process | `time() - process_start_time_seconds` | value is the event time |
| Seconds until cert expiry | `probe_ssl_earliest_cert_expiry - time()` | value is a future event time |
| Staleness of a *push* / batch metric | `time() - push_time_seconds` | value is the push event time |
| **Scrape lag** — how old is the freshest sample? | `time() - timestamp(up)` | uses the *sample* clock |
| **Clock skew** node ↔ Prometheus | `node_time_seconds - timestamp(node_time_seconds)` | value=node clock, timestamp=Prom clock |
| Suppress alerts on weekends | `... unless on() (day_of_week() == 0 or day_of_week() == 6)` | calendar helper |

The clock-skew idiom deserves emphasis because it is the only place you *deliberately* combine a timestamp metric with `timestamp()`:

```promql
# Positive => node clock ahead of Prometheus; includes scrape+network latency (~ tens of ms)
node_time_seconds - timestamp(node_time_seconds)
```

Anything beyond ~1–2 s here is real clock drift, not latency — corroborate with `node_timex_offset_seconds` (the kernel's own NTP offset estimate).

### Detecting a restart vs. measuring age

`time() - process_start_time_seconds` gives age; to *alert on a fresh restart* you threshold it low **and** guard against gaps:

```promql
time() - process_start_time_seconds < 60
```

Prefer `changes(process_start_time_seconds[1h]) > 0` when you care about *"restarted at all in the window"* rather than *"is young right now"* — the latter has a 5-minute lookback blind spot after the process reappears.

---

## 3. Manifests and infrastructure (complete, unabridged)

### 3.1 Scrape config — timestamps in the exposition format

The Prometheus exposition format allows an **optional millisecond timestamp** as a third field on each sample line:

```
# HELP http_requests_total Total HTTP requests.
# TYPE http_requests_total counter
http_requests_total{method="post",code="200"} 1027 1754640123456
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1.7546400e+09
```

`honor_timestamps` controls whether Prometheus adopts that embedded timestamp (`1754640123456`) as the sample timestamp, or overwrites it with its own scrape time. This is the switch that connects "timestamps" to the scrape pipeline:

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # Ordinary app scrape — trust our own scrape clock (recommended default).
  - job_name: app
    honor_timestamps: true        # default; use exporter-provided timestamps if present
    static_configs:
      - targets: ['app:8080']

  # Federation / Pushgateway — DO NOT overwrite the source timestamps.
  - job_name: pushgateway
    honor_timestamps: true
    honor_labels: true            # keep instance/job the pushing jobs set
    static_configs:
      - targets: ['pushgateway:9091']

  # A flaky exporter that emits bad/backdated timestamps — force our clock.
  - job_name: legacy-exporter
    honor_timestamps: false       # ignore embedded timestamps; stamp at scrape time
    static_configs:
      - targets: ['legacy:9200']

  # Blackbox TLS probes — source of probe_ssl_earliest_cert_expiry.
  - job_name: blackbox-tls
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://api.example.com
          - https://dashboard.example.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

> **Why `honor_timestamps: false` on the legacy job:** samples whose embedded timestamp is older than `now − storage.tsdb.out_of_order_time_window` (0 by default) are dropped as *out-of-order*, and samples too far in the future are rejected as *too far in the future*. A misconfigured exporter emitting stale or skewed timestamps will silently lose data unless you overwrite its clock.

### 3.2 Instrumenting a batch job with a timestamp metric (Pushgateway)

Batch jobs are invisible to a pull model between runs. The pattern is: push a `*_last_success_timestamp_seconds` gauge to Pushgateway on success, then alert on its staleness.

```bash
#!/usr/bin/env bash
# /opt/backup/run-backup.sh  — nightly database backup
set -euo pipefail

JOB="db_backup"
PGW="http://pushgateway:9091"

start="$(date +%s)"
if /opt/backup/pg_dump_to_s3.sh; then
  end="$(date +%s)"
  cat <<EOF | curl -sf --data-binary @- "${PGW}/metrics/job/${JOB}/instance/${HOSTNAME}"
# TYPE db_backup_last_success_timestamp_seconds gauge
# HELP db_backup_last_success_timestamp_seconds Unix time of the last successful backup.
db_backup_last_success_timestamp_seconds ${end}
# TYPE db_backup_duration_seconds gauge
db_backup_duration_seconds $((end - start))
EOF
else
  # Do NOT push a success timestamp on failure — let staleness fire the alert.
  exit 1
fi
```

Pushgateway automatically decorates every group with `push_time_seconds`, so you get freshness even for jobs that forget to emit their own timestamp.

### 3.3 Recording rules — pre-compute ages once

Age expressions are cheap, but if a dozen dashboards and alerts subtract `time()` from the same metric, hoist it into a recording rule so the panels stay readable and evaluation is consistent:

```yaml
# /etc/prometheus/rules/timestamp-recording.yml
groups:
  - name: timestamp.recording
    interval: 30s
    rules:
      - record: instance:process_uptime:seconds
        expr: time() - process_start_time_seconds

      - record: instance:cert_time_to_expiry:seconds
        expr: probe_ssl_earliest_cert_expiry - time()

      - record: job:batch_last_success_age:seconds
        expr: time() - db_backup_last_success_timestamp_seconds

      - record: instance:clock_skew:seconds
        expr: node_time_seconds - timestamp(node_time_seconds)
```

### 3.4 Alerting rules — deadlines, freshness, skew, restarts

```yaml
# /etc/prometheus/rules/timestamp-alerts.yml
groups:
  - name: timestamp.alerts
    rules:
      # --- Certificate deadline: warn at 21 days, page at 7 ---
      - alert: CertificateExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 21
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "TLS cert on {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"

      - alert: CertificateExpiringCritical
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 7
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "TLS cert on {{ $labels.instance }} expires in under 7 days ({{ $value | humanize }} days)"

      # --- Batch job freshness: nightly job must succeed at least every 26h ---
      - alert: BackupStale
        expr: (time() - db_backup_last_success_timestamp_seconds) > 26 * 3600
        # absent() catches the case where the metric never appeared at all
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "db_backup has not succeeded in {{ $value | humanizeDuration }}"

      - alert: BackupMetricMissing
        expr: absent(db_backup_last_success_timestamp_seconds)
        for: 30m
        labels:
          severity: critical
        annotations:
          summary: "No db_backup_last_success_timestamp_seconds series exists — job never reported"

      # --- Fresh restart detection ---
      - alert: ProcessFlapping
        expr: changes(process_start_time_seconds[15m]) > 2
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.job }}/{{ $labels.instance }} restarted {{ $value }} times in 15m"

      # --- Clock skew, business-hours aware suppression ---
      - alert: NodeClockSkew
        expr: |
          abs(node_time_seconds - timestamp(node_time_seconds)) > 0.5
          and abs(node_timex_offset_seconds) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Clock on {{ $labels.instance }} skewed by {{ $value | humanizeDuration }}"

      # --- Scrape staleness independent of the `up` alert ---
      - alert: StaleTarget
        expr: (time() - timestamp(up)) > 300
        labels:
          severity: warning
        annotations:
          summary: "Freshest sample from {{ $labels.instance }} is {{ $value | humanizeDuration }} old"
```

---

## 4. CLI and real terminal output

Inspect the raw exposition, then confirm the timestamp arithmetic with `promtool`.

```console
$ curl -s http://app:8080/metrics | grep -E 'process_start_time_seconds'
# HELP process_start_time_seconds Start time of the process since unix epoch in seconds.
# TYPE process_start_time_seconds gauge
process_start_time_seconds 1.754640000e+09
```

```console
$ date +%s
1754683215

$ promtool query instant http://localhost:9090 'time() - process_start_time_seconds'
process_start_time_seconds{instance="app:8080", job="app"} => 43215 @[1754683215]
```

43 215 s ≈ 12 h uptime — consistent with `1754683215 − 1754640000`.

Certificate countdown, in days:

```console
$ promtool query instant http://localhost:9090 \
    '(probe_ssl_earliest_cert_expiry - time()) / 86400'
{instance="https://api.example.com", job="blackbox-tls"} => 12.83 @[1754683230]
{instance="https://dashboard.example.com", job="blackbox-tls"} => 64.11 @[1754683230]
```

`timestamp()` vs the value — proving they differ:

```console
$ promtool query instant http://localhost:9090 'node_time_seconds'
node_time_seconds{instance="node1:9100"} => 1754683231.44 @[1754683230]

$ promtool query instant http://localhost:9090 'timestamp(node_time_seconds)'
node_time_seconds{instance="node1:9100"} => 1754683230 @[1754683230]

$ promtool query instant http://localhost:9090 \
    'node_time_seconds - timestamp(node_time_seconds)'
{instance="node1:9100"} => 1.44 @[1754683230]        # ~1.44s skew — investigate NTP
```

Calendar helpers are UTC — verify before writing time-window logic:

```console
$ promtool query instant http://localhost:9090 'hour()'
{} => 14 @[1754683230]

$ promtool query instant http://localhost:9090 'day_of_week()'
{} => 5 @[1754683230]        # 5 = Friday (0 = Sunday)
```

Batch-job staleness and the missing-series case:

```console
$ promtool query instant http://localhost:9090 \
    'time() - db_backup_last_success_timestamp_seconds'
db_backup_last_success_timestamp_seconds{instance="db01", job="db_backup"} => 5122 @[1754683240]

$ promtool query instant http://localhost:9090 'absent(db_backup_last_success_timestamp_seconds{job="db_backup"})'
# (empty result) => series exists, so absent() returns nothing — good.
```

Validate the rule files before reload:

```console
$ promtool check rules /etc/prometheus/rules/timestamp-alerts.yml
Checking /etc/prometheus/rules/timestamp-alerts.yml
  SUCCESS: 7 rules found

$ curl -s -X POST http://localhost:9090/-/reload && echo reloaded
reloaded
```

---

## 5. Verification and failure diagnosis

**A. `time() - X` is negative or absurdly large.**
Either the exporter emits milliseconds instead of seconds (value ≈ `1.75e12` instead of `1.75e9` → the age is a huge negative number), or you subtracted in the wrong order. Check the magnitude:

```console
$ promtool query instant http://localhost:9090 'process_start_time_seconds'
process_start_time_seconds{...} => 1.754640000e+12 @[...]   # ← milliseconds! divide by 1000
```

Fix with `process_start_time_seconds / 1000` or correct the instrumentation. A correct epoch-seconds value in 2026 has 10 integer digits (`1.75…e+09`).

**B. Alert on staleness never fires when a job dies.**
`time() - X > threshold` requires series `X` to still exist. If the target disappears entirely, the series goes stale after the lookback (5 m) and the expression yields *no result* — not a breach. Always pair a freshness alert with `absent()` (see `BackupMetricMissing`). This is the single most common false-negative in this topic.

**C. `timestamp()` returns the same number as `time()`.**
Expected for a freshly-scraped series: the sample timestamp ≈ evaluation time. A *large* gap means staleness (`time() - timestamp(up)` is your staleness gauge). If `timestamp()` on a live target is minutes behind, suspect `honor_timestamps: true` on an exporter shipping backdated timestamps.

**D. Samples silently missing after enabling an exporter's own timestamps.**
Check the Prometheus target scrape errors and the TSDB rejection counters:

```console
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=rate(prometheus_target_scrapes_sample_out_of_bounds_total[5m])' | jq '.data.result'
[
  { "metric": {"instance":"legacy:9200"}, "value": [1754683250, "3.2"] }
]
```

Non-zero `..._out_of_bounds_total` or `..._sample_duplicate_timestamp_total` means the exporter's embedded timestamps are stale/duplicated. Set `honor_timestamps: false` on that job.

**E. Time-window / business-hours logic misbehaves at DST or across midnight.**
Remember all helpers are **UTC** and `day_of_week()` counts Sunday as 0. A "weekdays 09–17 local" gate written against local hours will be wrong by the UTC offset. Convert once, comment the offset, and re-check with `promtool query instant '... hour()'` at a known wall-clock time.

**F. Cross-checking event time against wall clock during backfill/range queries.**
`time()` is per-step, so a `time() - X` recording rule backfilled over history is correct at every step; but an *instant* console query only shows "now". When auditing a past incident use the `@` modifier to pin evaluation:

```console
$ promtool query instant http://localhost:9090 \
    'time() - process_start_time_seconds @ 1754600000'
{...} => 39871 @[1754683260]     # age as it was at epoch 1754600000
```

---

## 6. References

- Prometheus — Querying functions (`time`, `timestamp`, `hour`, `day_of_week`, `year`, …): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — Querying basics, `@` modifier and `offset`: https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — Configuration, `scrape_config` and `honor_timestamps`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus — Exposition formats (optional per-sample timestamp): https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus — Alerting rules and templating (`humanizeDuration`): https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Pushgateway — `push_time_seconds` and batch-job pattern: https://github.com/prometheus/pushgateway#about-timestamps
- node_exporter (`node_time_seconds`, `node_boot_time_seconds`, `node_timex_offset_seconds`): https://github.com/prometheus/node_exporter
- blackbox_exporter (`probe_ssl_earliest_cert_expiry`): https://github.com/prometheus/blackbox_exporter
- kube-state-metrics (`kube_pod_start_time`): https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf