# Topic 5.3 — Exporters — Guided Exercises

> **PCA domain: Instrumentation and Exporters.** An *exporter* is a bridge process: it reads state from a system that does not speak Prometheus (the kernel, a database, an HTTP endpoint) and re-publishes it in the Prometheus text exposition format on an HTTP `/metrics` endpoint that a Prometheus server can scrape. These exercises build a working pipeline — Node Exporter, the textfile collector, and the Blackbox exporter — and then break it on purpose so you can diagnose it.
>
> **Prerequisites:** a Linux host, a running `prometheus` binary (v2.x), `curl`, and outbound internet. Commands assume `bash`. Version numbers in downloads are examples — check the release page for the current one.
>
> **Reference:** exporter concepts and the official list — <https://prometheus.io/docs/instrumenting/exporters/>

---

## Exercise 1 — Deploy the Node Exporter and read its output

The Node Exporter is the reference exporter for `*NIX` hardware and kernel metrics. Running it teaches you the shape of every exporter: a self-contained binary that serves `/metrics`.

**Steps:**

1. Download and unpack the binary (adjust the version to the current release):

   ```bash
   VERSION=1.8.2
   curl -sSLO https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz
   tar xzf node_exporter-${VERSION}.linux-amd64.tar.gz
   cd node_exporter-${VERSION}.linux-amd64
   ```

2. Start it in the foreground and read the startup log:

   ```bash
   ./node_exporter
   ```

   Expected (abbreviated):

   ```
   level=info msg="Starting node_exporter" version="(version=1.8.2, ...)"
   level=info msg="Enabled collectors" ... collector=cpu ... collector=filesystem ... collector=meminfo ...
   level=info msg="Listening on" address=[::]:9100
   ```

3. In a second terminal, scrape it by hand and look at a single metric family:

   ```bash
   curl -s localhost:9100/metrics | grep -A2 '^# HELP node_cpu_seconds_total'
   ```

   Expected:

   ```
   # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
   # TYPE node_cpu_seconds_total counter
   node_cpu_seconds_total{cpu="0",mode="idle"} 40663.94
   ```

4. List which collectors are compiled in and enabled/disabled by default:

   ```bash
   ./node_exporter --help 2>&1 | grep -E 'collector\.(cpu|systemd|textfile)'
   ```

5. Restart the exporter with one optional collector on and one default collector off:

   ```bash
   ./node_exporter --collector.systemd --no-collector.arp
   ```

> **Comprehension check — Exercise 1**
> 1. What are the two comment lines that precede `node_cpu_seconds_total`, and what does each declare?
> 2. `node_cpu_seconds_total` has a `mode` label with values like `idle`, `system`, `user`. Why is this one metric family with a label instead of separate metrics `node_cpu_idle_seconds`, `node_cpu_system_seconds`, …?
> 3. The value shown is `40663.94` and the `# TYPE` is `counter`. Is the raw number `40663.94` useful on its own to a student looking at CPU usage? What must PromQL do to it first?
> 4. What is the practical difference between `--collector.systemd` and `--no-collector.arp` in step 5?

---

## Exercise 2 — Scrape the exporter from Prometheus and validate with `up`

An exporter that no one scrapes produces no time series. Here you wire the Node Exporter into a Prometheus server and confirm the target is healthy using the synthetic `up` metric.

**Steps:**

1. Write `prometheus.yml` with a job that scrapes the exporter:

   ```yaml
   global:
     scrape_interval: 15s

   scrape_configs:
     - job_name: 'node'
       static_configs:
         - targets: ['localhost:9100']
   ```

2. Start Prometheus pointed at that file:

   ```bash
   ./prometheus --config.file=prometheus.yml
   ```

3. Open <http://localhost:9090/targets> (or query the API). Confirm the `node` target shows **State = UP**.

4. Query the synthetic health metric from the CLI:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up{job="node"}' | \
     python3 -m json.tool
   ```

   Expected (abbreviated):

   ```json
   {
     "status": "success",
     "data": {
       "result": [
         {
           "metric": {"__name__": "up", "instance": "localhost:9100", "job": "node"},
           "value": [1723296000, "1"]
         }
       ]
     }
   }
   ```

5. Inspect the two metrics Prometheus attaches to every scrape, regardless of exporter:

   ```
   scrape_duration_seconds{job="node"}
   scrape_samples_scraped{job="node"}
   ```

6. Stop the Node Exporter (`Ctrl-C` in its terminal). Wait ~30s, then re-run the `up` query from step 4.

> **Comprehension check — Exercise 2**
> 1. Where does the `up` metric come from? Is it exported by the Node Exporter, or produced by Prometheus itself?
> 2. In step 4 the `instance` label is `localhost:9100`, not `localhost` — where did that value originate, and what default target label was set from it?
> 3. After you kill the exporter in step 6, what value does `up{job="node"}` take, and does the series disappear or stay present?
> 4. `scrape_samples_scraped` counts the samples returned by the exporter in one scrape. If this number suddenly doubles from one release of the exporter to the next, what operational risk does that flag?

---

## Exercise 3 — Extend metrics with the textfile collector

You cannot always run a long-lived HTTP daemon — think of a nightly backup script or a cron job. The **textfile collector** solves this: the Node Exporter reads `*.prom` files from a directory and merges their contents into its own `/metrics`. This is the canonical way to expose batch-job and custom business metrics.

**Steps:**

1. Create the collector directory and restart the Node Exporter pointing at it:

   ```bash
   sudo mkdir -p /var/lib/node_exporter/textfile_collector
   ./node_exporter \
     --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
   ```

2. Write a metric file **atomically** — write to a temp file, then `mv` (rename) into place so the collector never reads a half-written file:

   ```bash
   DIR=/var/lib/node_exporter/textfile_collector
   cat > "$DIR/backup.prom.$$" <<'EOF'
   # HELP job_last_success_timestamp_seconds Unix time of the last successful backup.
   # TYPE job_last_success_timestamp_seconds gauge
   job_last_success_timestamp_seconds{job="db_backup"} 1723295400
   # HELP job_duration_seconds Duration of the last backup run.
   # TYPE job_duration_seconds gauge
   job_duration_seconds{job="db_backup"} 42.7
   EOF
   mv "$DIR/backup.prom.$$" "$DIR/backup.prom"
   ```

3. Confirm the metric now appears in the exporter output:

   ```bash
   curl -s localhost:9100/metrics | grep job_last_success
   ```

   Expected:

   ```
   job_last_success_timestamp_seconds{job="db_backup"} 1723295400
   ```

4. Check the collector's own health metric, which the Node Exporter adds automatically:

   ```bash
   curl -s localhost:9100/metrics | grep node_textfile_scrape_error
   ```

   Expected:

   ```
   node_textfile_scrape_error 0
   ```

5. Break it: write a file with a malformed line (a duplicate metric line with a different value, which the parser rejects) and re-check `node_textfile_scrape_error`:

   ```bash
   printf 'broken_metric 1\nbroken_metric 2\n' > "$DIR/bad.prom"
   curl -s localhost:9100/metrics | grep node_textfile_scrape_error
   ```

6. Delete the bad file and confirm the error metric returns to `0`:

   ```bash
   rm "$DIR/bad.prom"
   ```

> **Comprehension check — Exercise 3**
> 1. Why is the write-to-temp-then-`mv` pattern in step 2 essential? What could a scrape observe if you wrote directly to `backup.prom` with a redirect?
> 2. For a nightly backup, why is `job_last_success_timestamp_seconds` (an absolute Unix timestamp) a better exposed metric than a boolean `backup_ok 1`? Write the PromQL that would alert if the last success is older than 25 hours.
> 3. In step 5, does `node_textfile_scrape_error` becoming `1` stop the *other* textfile metrics (from `backup.prom`) from being served?
> 4. Why should a batch job expose `job_duration_seconds` as a `gauge` and not a `counter`?

---

## Exercise 4 — The Blackbox exporter and the multi-target relabeling pattern

The Blackbox exporter probes endpoints (HTTP, TCP, ICMP, DNS) from the outside. Its design is different: you do **not** hardcode targets in the exporter — you pass the target as a URL parameter at scrape time. Wiring this correctly requires the multi-target `relabel_configs` pattern, one of the most commonly tested exporter topics.

**Steps:**

1. Download, unpack, and start the Blackbox exporter with its default config:

   ```bash
   VERSION=0.25.0
   curl -sSLO https://github.com/prometheus/blackbox_exporter/releases/download/v${VERSION}/blackbox_exporter-${VERSION}.linux-amd64.tar.gz
   tar xzf blackbox_exporter-${VERSION}.linux-amd64.tar.gz
   cd blackbox_exporter-${VERSION}.linux-amd64
   ./blackbox_exporter --config.file=blackbox.yml
   ```

2. Probe a target manually. Note that **you** supply `target` and `module`, not the exporter:

   ```bash
   curl -s 'http://localhost:9115/probe?target=https://prometheus.io&module=http_2xx' | \
     grep -E '^probe_(success|http_status_code|duration_seconds)'
   ```

   Expected (abbreviated):

   ```
   probe_success 1
   probe_http_status_code 200
   probe_duration_seconds 0.183
   ```

3. Now add the scrape job to `prometheus.yml`. Read the four relabeling rules carefully — they are the whole point of this exercise:

   ```yaml
   scrape_configs:
     - job_name: 'blackbox-http'
       metrics_path: /probe
       params:
         module: [http_2xx]
       static_configs:
         - targets:
             - https://prometheus.io
             - https://example.com
       relabel_configs:
         # 1. Move the target from __address__ into the ?target= URL param
         - source_labels: [__address__]
           target_label: __param_target
         # 2. Expose the probed URL as the human-readable instance label
         - source_labels: [__param_target]
           target_label: instance
         # 3. Point the actual scrape at the blackbox exporter, not the target
         - target_label: __address__
           replacement: localhost:9115
   ```

4. Reload Prometheus (`kill -HUP <pid>` or restart) and open <http://localhost:9090/targets>. You should see **two** `blackbox-http` targets, one per probed URL, each with an `instance` label of the site being probed.

5. Query the probe results across all targets:

   ```
   probe_success{job="blackbox-http"}
   probe_http_duration_seconds{job="blackbox-http"}
   ```

6. Inspect the certificate-expiry metric the `http_2xx` module emits for HTTPS targets, and write an expiry alert expression:

   ```
   (probe_ssl_earliest_cert_expiry - time()) / 86400
   ```

> **Comprehension check — Exercise 4**
> 1. Walk through the three relabel rules. After they run, what is the value of `__address__`, `__param_target`, and `instance` for the `https://prometheus.io` target?
> 2. If you **omit** relabel rule 3, what will Prometheus try to scrape, and why will every probe fail?
> 3. `module: [http_2xx]` is set under `params`. What is the mechanical relationship between this and the `&module=http_2xx` you typed by hand in step 2?
> 4. Where does `probe_success` physically get computed — on the Prometheus server, or inside the Blackbox exporter process? Which host's network path does `probe_duration_seconds` measure?
> 5. Why is this called the "multi-target exporter pattern," and why can't you just put `localhost:9115` directly in `static_configs.targets` like you did for the Node Exporter?

---

## Exercise 5 — Diagnose a broken exporter pipeline

Exporter problems in production almost always surface as `up == 0` or as missing/stale series. This exercise gives you a repeatable diagnostic ladder.

**Steps:**

1. With Prometheus and the Node Exporter running normally, confirm the baseline:

   ```
   up{job="node"}          # expect 1
   ```

2. **Fault A — wrong port.** Edit the `node` job target to `localhost:9101` (nothing listens there), reload Prometheus, and observe the target on `/targets`. Note the error string.

3. From the shell, reproduce what Prometheus sees:

   ```bash
   curl -v http://localhost:9101/metrics
   ```

   Expected:

   ```
   *   Trying 127.0.0.1:9101...
   * connect to 127.0.0.1 port 9101 failed: Connection refused
   ```

4. Revert the port to `9100`. **Fault B — exporter alive but slow/partial.** Introduce a scrape timeout mismatch by adding to the `node` job:

   ```yaml
       scrape_interval: 5s
       scrape_timeout: 10s
   ```

   Reload and read the error Prometheus reports.

5. Fix the timeout (`scrape_timeout` must be ≤ `scrape_interval`). Now inspect the two diagnostic series that distinguish "target down" from "target slow":

   ```
   up{job="node"}                       # 1 = HTTP scrape succeeded
   scrape_duration_seconds{job="node"}  # how long the scrape took
   ```

6. **Fault C — stale series.** Kill the Node Exporter. Query in the Prometheus expression browser:

   ```
   up{job="node"}                 # goes to 0
   node_cpu_seconds_total         # what happens to these series?
   ```

   Wait 5 minutes and re-query `node_cpu_seconds_total`.

> **Comprehension check — Exercise 5**
> 1. In Fault A, `up` is `0` and the target error is `connection refused`. Does Prometheus keep the `node_*` metrics from the last good scrape, or drop them immediately? What single series should an alert use to catch this class of failure generically?
> 2. Fault B fails at **config load**, not at scrape time. Why does Prometheus refuse a `scrape_timeout` that is larger than `scrape_interval`?
> 3. `up == 1` but `scrape_duration_seconds` is climbing toward your `scrape_timeout`. What is this telling you about the exporter, and why is it invisible if you only alert on `up`?
> 4. In Fault C, after the exporter dies the `node_cpu_seconds_total` series are marked *stale* rather than kept forever. Roughly how long after the last successful scrape does a series stop being returned by an instant query, and why does that matter for `rate()` calculations spanning the outage?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

1. `# HELP node_cpu_seconds_total …` is human-readable documentation for the metric family; `# TYPE node_cpu_seconds_total counter` declares its metric type (counter). Both are part of the text exposition format and precede the samples of that family. (Format spec: <https://prometheus.io/docs/instrumenting/exposition_formats/>.)
2. Because `cpu` and `mode` are *dimensions* of the same measurement. Modelling them as labels on one family lets PromQL aggregate freely — `sum by (mode) (rate(node_cpu_seconds_total[5m]))` — and lets new CPUs or modes appear without changing the metric name. Separate metric names would be un-aggregatable and would hardcode the cardinality.
3. No — `40663.94` is the cumulative seconds since boot, a monotonically increasing counter. On its own it is meaningless for "current CPU usage." PromQL must apply `rate()` (or `irate()`) over a range to turn the counter into a per-second rate: `rate(node_cpu_seconds_total{mode="idle"}[5m])`.
4. `--collector.systemd` **enables** a collector that is off by default (systemd unit states). `--no-collector.arp` **disables** a collector (ARP entries) that is on by default. Collectors are toggled individually to control cardinality and scrape cost.

### Exercise 2

1. `up` is synthesized by the **Prometheus server**, not the exporter. After each scrape Prometheus writes `up{job,instance}` = `1` if the HTTP scrape succeeded and the payload parsed, `0` otherwise. No exporter emits it.
2. It came from the `targets: ['localhost:9100']` entry. Prometheus sets the internal `__address__` label from it, and by default copies `__address__` into the visible `instance` label.
3. `up{job="node"}` becomes `0`, and the series **stays present** (it keeps being written on every scrape attempt). This is exactly why `up` is the standard "is the target reachable" signal — it exists whether or not the exporter responds.
4. A doubling of `scrape_samples_scraped` means a cardinality explosion in the exporter's output — more series to ingest, store, and query on every scrape. It can silently blow up TSDB memory and cross `sample_limit` thresholds, so it is worth alerting on.

### Exercise 3

1. The collector may scan and parse the file at any instant. A plain redirect (`> backup.prom`) truncates then rewrites, so a scrape landing mid-write reads a truncated or empty file and either drops metrics or sets `node_textfile_scrape_error 1`. `mv` within the same filesystem is an atomic rename: the collector always sees either the old complete file or the new complete file, never a partial one.
2. A boolean `backup_ok 1` cannot distinguish "succeeded 10 minutes ago" from "last succeeded a week ago and has been failing since" — and if the job dies entirely, nothing updates the boolean, so it stays `1` forever (stale-positive). An absolute timestamp keeps aging, so you can alert on *staleness*:

   ```
   time() - job_last_success_timestamp_seconds{job="db_backup"} > 25 * 3600
   ```
3. No. The textfile collector parses each file independently; `bad.prom` failing sets `node_textfile_scrape_error` to `1` and drops only that file's metrics. `backup.prom`'s metrics continue to be served. The error metric is your signal to investigate.
4. A backup's duration is not cumulative and can go up or down between runs (it is an instantaneous measurement of the last run), so it is a `gauge`. A `counter` must be monotonically increasing and is meant to be consumed via `rate()`; neither property fits "duration of the most recent run."

### Exercise 4

1. After the three rules run for `https://prometheus.io`:
   - `__param_target` = `https://prometheus.io` (rule 1 copied it from `__address__`)
   - `instance` = `https://prometheus.io` (rule 2 copied it from `__param_target`)
   - `__address__` = `localhost:9115` (rule 3 overwrote it)

   So Prometheus scrapes `http://localhost:9115/probe?module=http_2xx&target=https://prometheus.io`, and the resulting series carry a readable `instance` of the probed site.
2. Without rule 3, `__address__` still equals the probed URL (e.g. `https://prometheus.io`), so Prometheus tries to scrape `https://prometheus.io/probe?...`. That site is not a Blackbox exporter, so every scrape fails — you would be asking the target to probe itself.
3. They are the same URL parameter, injected two different ways. `params: { module: [http_2xx] }` tells Prometheus to append `&module=http_2xx` to every request to `/probe`, exactly as you typed it by hand in step 2. `params` is the declarative equivalent of the query string.
4. `probe_success` is computed **inside the Blackbox exporter** — it performs the probe and reports the outcome; Prometheus only scrapes the result. `probe_duration_seconds` measures the network path from the **Blackbox exporter host** to the target, not from Prometheus. (Docs: <https://github.com/prometheus/blackbox_exporter>.)
5. One exporter instance serves many targets, chosen per scrape via the `target` parameter, so a single `localhost:9115` fronts an arbitrary list of probed endpoints — that is the "multi-target" pattern. You cannot list `localhost:9115` directly as the target because then every series would collapse onto `instance="localhost:9115"` and you would lose which URL was probed; the relabeling is what preserves per-URL identity while routing the actual HTTP scrape to the exporter.

### Exercise 5

1. On `connection refused` the scrape fails, so Prometheus does not receive the `node_*` samples for that cycle; those series are marked stale and stop being returned shortly after (see A4). It keeps `up{job="node"} = 0`. The generic alert for this whole class is `up == 0` (optionally `for: <duration>`), because `up` is emitted regardless of exporter state.
2. Prometheus enforces `scrape_timeout <= scrape_interval` at config validation: a timeout longer than the interval would let one scrape still be running when the next is due, so it fails fast rather than silently overlapping scrapes and skewing timing.
3. It means the exporter is responding but taking longer and longer to build its payload — a large collector, a slow backend query, or cardinality growth. If you only watch `up`, this is invisible until the scrape finally exceeds `scrape_timeout` and flips `up` to `0`; watching `scrape_duration_seconds` gives you early warning while `up` is still `1`.
4. After the last successful scrape, a target's series become stale and stop being returned by instant queries after roughly the staleness horizon (about **5 minutes** by default). During that window an instant query still returns the last value; past it, the series vanishes until scraping resumes. This matters for `rate()`: a gap longer than the range window (or the staleness horizon) leaves no adjacent samples to compute a rate over, so `rate()` returns no data across the outage rather than a fabricated value.

</details>

---

**Sources**

- Prometheus — Exporters and integrations: <https://prometheus.io/docs/instrumenting/exporters/>
- Prometheus — Text exposition formats: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus — Monitoring Linux host metrics with the Node Exporter: <https://prometheus.io/docs/guides/node-exporter/>
- `prometheus/node_exporter` (textfile collector, collector flags): <https://github.com/prometheus/node_exporter>
- `prometheus/blackbox_exporter` (multi-target probing, module config): <https://github.com/prometheus/blackbox_exporter>
- Prometheus — Configuration (`relabel_configs`, `scrape_timeout`, `params`): <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PCA Curriculum: <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>