# Timestamp Metrics — Guided Exercises

> **Certification:** Prometheus Certified Associate (PCA)
> **Domain 1 · Topic 1.7 — Timestamp Metrics** · Exam weight: 4
>
> Every Prometheus sample is a *(timestamp, value)* pair. This topic is about the two ways time shows up in Prometheus and the constant confusion between them:
>
> 1. **The sample's timestamp** — metadata attached to every sample, saying *when this observation was taken*. You read it with the `timestamp()` function.
> 2. **A metric whose value happens to be a Unix time** — e.g. `process_start_time_seconds`, `node_boot_time_seconds`, `..._last_success_timestamp_seconds`. This is an ordinary float that you subtract from `time()` to get an age.
>
> These exercises make you produce, observe and reason about both, plus the `honor_timestamps` scrape option and staleness. Each block ends with verification questions; answers are collapsed at the bottom.

---

## Exercise 0 — Stand up a reproducible lab

You need a live Prometheus, a self-instrumented target (Prometheus itself already exposes `process_start_time_seconds`), a node_exporter for `node_boot_time_seconds`, a Pushgateway for the batch-job pattern, and one hand-rolled target that emits an **explicit** timestamp so you can exercise `honor_timestamps`.

**Steps**

1. Create a working directory and the Prometheus config:

   ```bash
   mkdir -p ts-lab && cd ts-lab
   ```

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: 'prometheus'
       static_configs:
         - targets: ['prometheus:9090']

     - job_name: 'node'
       static_configs:
         - targets: ['node-exporter:9100']

     - job_name: 'pushgateway'
       honor_labels: true
       static_configs:
         - targets: ['pushgateway:9091']

     - job_name: 'stamped'          # our hand-rolled target, edited in Ex. 4
       # honor_timestamps: true      # (default) — we will flip this later
       static_configs:
         - targets: ['stamped:8000']
   ```

2. Bring up the stack:

   ```yaml
   # docker-compose.yml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       command: ["--config.file=/etc/prometheus/prometheus.yml"]
       volumes: ["./prometheus.yml:/etc/prometheus/prometheus.yml:ro",
                 "./rules.yml:/etc/prometheus/rules.yml:ro"]
       ports: ["9090:9090"]
     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports: ["9100:9100"]
     pushgateway:
       image: prom/pushgateway:v1.9.0
       ports: ["9091:9091"]
     stamped:
       image: python:3.12-slim
       working_dir: /app
       volumes: ["./stamped.py:/app/stamped.py:ro"]
       command: ["python", "stamped.py"]
       ports: ["8000:8000"]
   ```

   ```bash
   touch rules.yml stamped.py     # placeholders, filled in later
   docker compose up -d prometheus node-exporter pushgateway
   ```

3. Confirm the two core targets are `UP`:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | grep -o '"job":"[a-z-]*","[^}]*"health":"[a-z]*"'
   ```

   Expected (order may vary):

   ```
   "job":"prometheus", ... "health":"up"
   "job":"node", ...       "health":"up"
   ```

**Verify your understanding**

- **Q0.1** With `scrape_interval: 15s`, how far apart are two consecutive samples of the *same* series on the time axis, and what unit does Prometheus store that gap in internally?
- **Q0.2** Nothing in this config sets a timestamp for the samples of the `prometheus` or `node` jobs. So where does each sample's timestamp come from?

---

## Exercise 1 — The anatomy of one sample: value vs. timestamp

**Steps**

1. Scrape Prometheus's own metrics endpoint by hand and isolate the start-time metric:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^process_start_time_seconds'
   ```

   Expected (your number will differ):

   ```
   process_start_time_seconds 1.7549280e+09
   ```

   This line is the classic Prometheus **text exposition format**: `metric_name value`. There is *no* trailing timestamp token here — the value `1.7549280e+09` is a Unix time **in seconds** that is the metric's *value*, not the sample's timestamp.

2. Now query the same metric through the API and look at what a stored sample really is:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=process_start_time_seconds{job="prometheus"}' \
     | python3 -m json.tool
   ```

   Expected shape:

   ```json
   {
     "status": "success",
     "data": {
       "resultType": "vector",
       "result": [
         {
           "metric": {"__name__": "process_start_time_seconds", "instance": "prometheus:9090", "job": "prometheus"},
           "value": [1754928315.123, "1754928000"]
         }
       ]
     }
   }
   ```

3. Read the `"value"` array carefully. It is **`[ <sample timestamp, seconds>, "<sample value>" ]`**:
   - `1754928315.123` — the *sample's timestamp*: the query evaluation time, injected by the engine.
   - `"1754928000"` — the *value*: when this Prometheus process started.

**Verify your understanding**

- **Q1.1** In the API response, which element of the `value` array is *metadata about when the observation exists* and which is *the observed quantity*? Why do they hold two different-looking numbers even though both look like Unix times?
- **Q1.2** In the raw exposition line `process_start_time_seconds 1.7549280e+09`, is `1.7549280e+09` a timestamp or a value? What will become of this series' *sample* timestamp once Prometheus stores it?
- **Q1.3** Prometheus stores each sample's value as a `float64` and its timestamp as an `int64`. Given that, what is the resolution (smallest representable gap) of a sample timestamp?

---

## Exercise 2 — `timestamp()` reads the metadata, not the value

The `timestamp()` function (added in Prometheus 2.0) returns, for each element of an instant vector, **the sample's timestamp expressed in seconds since the Unix epoch** — deliberately independent of the sample's value.

**Steps**

1. In the Prometheus UI (`http://localhost:9090/graph`) or via `curl`, evaluate the metric value:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=process_start_time_seconds{job="prometheus"}' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928000"]
   ```

2. Now wrap it in `timestamp()` and evaluate again:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=timestamp(process_start_time_seconds{job="prometheus"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928311"]
   ```

3. Compare the two results:
   - Plain metric → value `1754928000` (process start).
   - `timestamp(...)` → value `1754928311` (the timestamp of the **most recent scraped sample**, i.e. roughly *now*, snapped back to the last scrape at most one `scrape_interval` ago).

4. Confirm `timestamp()` ignores the underlying value entirely by applying it to a metric whose value is a tiny integer:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928309"]
   ```

   `up` has value `1`, yet `timestamp(up)` returns a ~10-digit Unix time — proof that `timestamp()` reports *when the sample was recorded*, never the number stored in it.

**Verify your understanding**

- **Q2.1** `timestamp(up)` returns something like `1754928309` while `up` itself returns `1`. Explain, in one sentence, why the two numbers have nothing to do with each other.
- **Q2.2** You evaluate `timestamp(up)` and get a value that is 12 seconds smaller than `time()`. What does that 12-second gap physically represent, and what is its expected upper bound in this lab?
- **Q2.3** True or false: `timestamp(process_start_time_seconds)` tells you when the process started. Justify.

---

## Exercise 3 — Turning a timestamp-valued metric into an age

The idiom for "how old is X" is always the same: **`time() - <a_metric_whose_value_is_a_unix_time_in_seconds>`**. `time()` returns the query's evaluation time in seconds since the epoch.

**Steps**

1. Compute this Prometheus process's uptime from its start-time metric:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-process_start_time_seconds{job="prometheus"}' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"700.5498733520508"]
   ```

   → ~700 seconds of uptime.

2. Compute host uptime from node_exporter's boot-time metric:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-node_boot_time_seconds' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"864321.4470000267"]
   ```

   → ~10 days.

3. Contrast that with a **wrong** but tempting formula that uses `timestamp()` on the same metric:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(node_boot_time_seconds)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"7.550000190734863"]
   ```

   → ~7 seconds. That is *time since last scrape*, **not** host uptime — because `timestamp()` returned the scrape time, not the boot time.

**Verify your understanding**

- **Q3.1** You want the **age of the host** (how long since boot). Which is correct: `time() - node_boot_time_seconds` or `time() - timestamp(node_boot_time_seconds)`? What does the *other* expression actually measure?
- **Q3.2** A colleague writes `node_boot_time_seconds - time()` to get uptime and it always comes out negative. What did they get wrong, and what does the negative number equal in magnitude?
- **Q3.3** Why must a "point in time" metric be expressed as **seconds since the Unix epoch** (per Prometheus naming conventions, suffix `_timestamp_seconds` / `_time_seconds`) for `time() - metric` to be meaningful? What breaks if someone exposes it in milliseconds?

---

## Exercise 4 — Explicit timestamps in exposition and `honor_timestamps`

The text format allows an **optional** third token: `metric_name{labels} <value> <timestamp_ms>`, where the timestamp is **milliseconds** since the epoch (an `int64`). Whether Prometheus keeps that timestamp or overwrites it with scrape time is governed by the per-scrape option `honor_timestamps` (default **`true`**).

**Steps**

1. Write a tiny target that emits an explicit timestamp deliberately **60 seconds in the past**:

   ```python
   # stamped.py
   import time
   from http.server import BaseHTTPRequestHandler, HTTPServer

   class H(BaseHTTPRequestHandler):
       def do_GET(self):
           ts_ms = int((time.time() - 60) * 1000)   # 60s in the past, in ms
           body = (
               "# HELP demo_reading A gauge exposed with an explicit past timestamp\n"
               "# TYPE demo_reading gauge\n"
               f"demo_reading{{source=\"sensor-a\"}} 42 {ts_ms}\n"
           ).encode()
           self.send_response(200)
           self.send_header("Content-Type", "text/plain; version=0.0.4")
           self.end_headers()
           self.wfile.write(body)
       def log_message(self, *a): pass

   HTTPServer(("0.0.0.0", 8000), H).serve_forever()
   ```

2. Start it and add it to the scrape (the `stamped` job is already in `prometheus.yml`):

   ```bash
   docker compose up -d stamped
   curl -s http://localhost:8000/       # confirm the third token is present
   ```

   ```
   demo_reading{source="sensor-a"} 42 1754928650000
   ```

3. With `honor_timestamps` at its default (`true`), reload and inspect where Prometheus placed the sample on the time axis:

   ```bash
   docker compose kill -s HUP prometheus     # or restart
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(demo_reading)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928710.9,"60.90000009536743"]
   ```

   → ~60 s: Prometheus **honored** the exposed timestamp, so the sample sits 60 s in the past even though it was scraped just now.

4. Now flip the option. Edit `prometheus.yml`, set `honor_timestamps: false` on the `stamped` job, reload, and re-measure:

   ```yaml
     - job_name: 'stamped'
       honor_timestamps: false
       static_configs:
         - targets: ['stamped:8000']
   ```

   ```bash
   docker compose kill -s HUP prometheus
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(demo_reading)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928760.4,"5.400000095367432"]
   ```

   → now only ~5 s (one scrape ago): Prometheus **ignored** the exposed token and stamped the sample with scrape time.

**Verify your understanding**

- **Q4.1** In the exposition line `demo_reading{source="sensor-a"} 42 1754928650000`, name each of the three tokens and give the unit of the third.
- **Q4.2** With `honor_timestamps: true`, why did `time() - timestamp(demo_reading)` return ~60 even though the scrape happened milliseconds ago?
- **Q4.3** What is the default value of `honor_timestamps`, and what does setting it to `false` do to any timestamps a target exposes?
- **Q4.4** A target keeps re-exposing the *same* explicit timestamp on every scrape (its clock is stuck). With `honor_timestamps: true`, what happens to the second and later samples, and why does Prometheus consider that series stale a few minutes later even though the target is `up`?

---

## Exercise 5 — Detecting stalled scrapes and clock skew

Because `timestamp(up)` reports the wall-clock of the *last successful scrape*, `time() - timestamp(up)` is a portable "seconds since I last heard from this target" probe.

**Steps**

1. Baseline the freshness of every target:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up)' \
     | python3 -c 'import sys,json; [print(r["metric"]["job"], r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'
   ```

   ```
   prometheus 4.90
   node       9.90
   pushgateway 1.90
   stamped    6.40
   ```

   All small — every job is within roughly one `scrape_interval`.

2. Simulate a dead target and watch the number climb:

   ```bash
   docker compose stop node-exporter
   sleep 90
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929050.0,"85.0"]
   ```

   → ~85 s and rising. But keep watching:

   ```bash
   sleep 240
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929290.0,"[]"]   # empty result — see below
   ```

   Once no sample for `up{job="node"}` has appeared within the default 5-minute lookback delta, the series goes **stale** and drops out of instant-vector evaluation, so the expression returns *nothing*.

3. Restore the target:

   ```bash
   docker compose start node-exporter
   ```

**Verify your understanding**

- **Q5.1** Why is `time() - timestamp(up)` a good "scrape freshness" signal, and what does a steadily increasing value indicate?
- **Q5.2** After the target was down ~5 minutes, the expression returned an empty result instead of a large number. Which Prometheus mechanism causes that, and what is the default window before it kicks in?
- **Q5.3** Given Q5.2, why is `time() - timestamp(up)` unreliable for alerting on *long* outages, and what simpler expression (using `up` itself, or `absent()`) would you pair with it to catch a fully-vanished target?

---

## Exercise 6 — The batch-job freshness pattern (Pushgateway + alert)

Batch jobs don't run long enough to be scraped, so they **push** a "last success" timestamp to the Pushgateway; you then alert when it grows too old. This is the canonical *timestamp metric* in production.

**Steps**

1. Simulate a successful batch run by pushing a `_last_success_timestamp_seconds` gauge (value = now, in **seconds**):

   ```bash
   cat <<EOF | curl -s --data-binary @- \
     http://localhost:9091/metrics/job/nightly_backup/instance/host01
   # TYPE backup_last_success_timestamp_seconds gauge
   # HELP backup_last_success_timestamp_seconds Unix time of the last successful backup
   backup_last_success_timestamp_seconds $(date +%s)
   EOF
   ```

2. Confirm Prometheus scraped it from the Pushgateway and compute its age:

   ```bash
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-backup_last_success_timestamp_seconds' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929400.0,"18.0"]
   ```

   → 18 s old — fresh.

3. Add an alerting rule and load it:

   ```yaml
   # rules.yml
   groups:
     - name: batch-freshness
       rules:
         - alert: BackupStale
           expr: time() - backup_last_success_timestamp_seconds > 24 * 3600
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "Backup for {{ $labels.instance }} has not succeeded recently"
             description: "Last success was {{ $value | humanizeDuration }} ago."
   ```

   ```bash
   docker compose kill -s HUP prometheus
   curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"BackupStale","state":"[a-z]*"'
   ```

   ```
   "name":"BackupStale","state":"inactive"
   ```

4. Fake an old run to trip the alert *now* (push a timestamp 30 hours in the past):

   ```bash
   cat <<EOF | curl -s --data-binary @- \
     http://localhost:9091/metrics/job/nightly_backup/instance/host01
   backup_last_success_timestamp_seconds $(( $(date +%s) - 30*3600 ))
   EOF
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-backup_last_success_timestamp_seconds > 24*3600' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929500.0,"108020.0"]
   ```

   → ~30 h > 24 h: the expression now returns a value, so after the `for: 5m` window the alert becomes `firing`.

**Verify your understanding**

- **Q6.1** Why does a batch job push a *last-success timestamp* rather than, say, a boolean `backup_ok`? What failure mode does the timestamp catch that a boolean set only on success would miss?
- **Q6.2** The value pushed is `$(date +%s)`. What unit is that, and why does the alert expression compare against `24 * 3600` rather than `24`?
- **Q6.3** Why is `honor_labels: true` set on the `pushgateway` scrape job (recall the config in Ex. 0), and what would break in this pattern without it?
- **Q6.4** If the Pushgateway were restarted and lost the pushed series, `time() - backup_last_success_timestamp_seconds` would return empty rather than a huge number — so `BackupStale` would silently stop firing. Which function would you add a companion alert on to detect the metric *disappearing*?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0
- **A0.1** 15 seconds apart (one `scrape_interval`). Internally Prometheus stores each sample's timestamp as an **`int64` of milliseconds since the Unix epoch**, so the gap is stored as `15000`.
- **A0.2** From the **scrape**: because none of these targets exposes an explicit timestamp token, Prometheus assigns each sample the wall-clock time at which the scrape occurred. (Source: https://prometheus.io/docs/concepts/data_model/ and https://prometheus.io/docs/instrumenting/exposition_formats/)

### Exercise 1
- **A1.1** The **first** element (`1754928315.123`) is metadata — the sample's timestamp, i.e. *when the observation exists on the time axis*. The **second** element (`"1754928000"`) is the observed quantity — here it happens to also be a Unix time (process start), which is why both look date-like, but they are conceptually unrelated: one is *when we looked*, the other is *what we saw*.
- **A1.2** It is a **value** (the process start time). Its *sample* timestamp is not present in that line, so Prometheus will assign it the **scrape time** when it stores the series.
- **A1.3** Values are `float64`; timestamps are `int64` **milliseconds**, so the smallest representable gap between two sample timestamps is **1 millisecond**.

### Exercise 2
- **A2.1** `up` returns its stored *value* (`1` = scrape succeeded); `timestamp(up)` returns the *sample's timestamp* (when that sample was recorded). `timestamp()` never looks at the value, so the two numbers are independent by construction.
- **A2.2** The gap is the time between the last successful scrape of that series and the query's evaluation instant — i.e. how long ago Prometheus last recorded the sample. Its expected upper bound is roughly one `scrape_interval` (~15 s) plus scrape jitter, as long as the target is healthy.
- **A2.3** **False.** `timestamp(process_start_time_seconds)` returns *when the sample was scraped* (~now). The process start time is the metric's **value**; you read it directly, not through `timestamp()`. (Source: https://prometheus.io/docs/prometheus/latest/querying/functions/#timestamp)

### Exercise 3
- **A3.1** `time() - node_boot_time_seconds` is correct — it subtracts the boot instant (the metric's value) from now, yielding host uptime. `time() - timestamp(node_boot_time_seconds)` measures *time since the last scrape* of that series (~seconds), because `timestamp()` returns scrape time, not the value.
- **A3.2** They reversed the operands. `time()` (now) is larger than `node_boot_time_seconds` (a past instant), so `boot - now` is negative; its magnitude equals the correct uptime. Fix: `time() - node_boot_time_seconds`.
- **A3.3** `time()` returns **seconds** since the epoch, so the metric must also be seconds for the subtraction to be dimensionally consistent (base SI unit, per https://prometheus.io/docs/practices/naming/). If it were milliseconds, `time() - metric` would produce a nonsensical, hugely negative number (subtracting ~1.75e12 from ~1.75e9).

### Exercise 4
- **A4.1** Token 1 = metric name **with labels** (`demo_reading{source="sensor-a"}`); token 2 = the **value** (`42`); token 3 = the **explicit sample timestamp**, in **milliseconds** since the Unix epoch (`1754928650000`).
- **A4.2** With `honor_timestamps: true`, Prometheus stored the sample at the exposed timestamp (60 s in the past), not at scrape time. So `timestamp(demo_reading)` returns that past time, and `time()` minus it ≈ 60.
- **A4.3** Default is **`true`**. Setting it to `false` makes Prometheus **discard** any timestamp the target exposes and stamp every sample with the scrape time instead. (Source: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- **A4.4** Every scrape carries the same (or older) timestamp, so after the first, subsequent samples are **out of order / duplicate** for that series and get dropped — the series stops advancing. Once no *newer* sample lands within the 5-minute lookback delta, the series is treated as **stale** and disappears from queries, even though the target's HTTP endpoint is still `up`. This is the classic hazard of exposing explicit timestamps and why it is discouraged for ordinary metrics.

### Exercise 5
- **A5.1** `timestamp(up)` is the wall-clock of the last successful scrape; subtracting it from `time()` gives seconds since Prometheus last heard from the target. A steadily increasing value means scrapes are no longer landing (target hung, network broken, or scrape timing out).
- **A5.2** **Staleness handling.** After no sample for the series within the **lookback delta (default 5 minutes)**, the series is considered stale and is excluded from instant-vector evaluation, so the expression returns an empty result. (Source: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness)
- **A5.3** Because once the series goes stale the expression yields *nothing* — it can't report "10 minutes old," it reports empty — so a threshold on it never fires for long outages. Pair it with `up{job="node"} == 0` (target scraped but failing) and/or `absent(up{job="node"})` (target vanished entirely) to catch the outage the freshness expression can no longer see.

### Exercise 6
- **A6.1** A last-success *timestamp* lets you compute *how long since the last good run* with `time() - metric`, so a job that stops running entirely (never pushes again) is caught as the age grows. A boolean set only on success gets **stuck at `1`** forever after the last success and can't distinguish "succeeded recently" from "hasn't run in a week."
- **A6.2** `date +%s` is **seconds** since the epoch, matching `time()`. The threshold is `24 * 3600` because both sides are in seconds, so 24 hours must be written as **86 400 seconds**, not `24`.
- **A6.3** `honor_labels: true` tells Prometheus **not** to overwrite the `job`/`instance` labels that the Pushgateway already carries (the pushed `job=nightly_backup`, `instance=host01`) with the scrape job's own `job="pushgateway"`. Without it, every pushed series would be relabeled to `job="pushgateway"`, collapsing/renaming the batch identity and breaking per-job alerting. (Source: https://prometheus.io/docs/practices/pushing/ and https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- **A6.4** Alert on **`absent(backup_last_success_timestamp_seconds)`** (optionally scoped per job/instance), which fires precisely when the series is gone — covering the blind spot where the age expression returns empty and `BackupStale` can no longer trip.

</details>

---

**Sources**
- Data model (samples = timestamp+value): https://prometheus.io/docs/concepts/data_model/
- Exposition format (optional millisecond timestamp): https://prometheus.io/docs/instrumenting/exposition_formats/
- `honor_timestamps` scrape option: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- `timestamp()` and `time()` functions: https://prometheus.io/docs/prometheus/latest/querying/functions/#timestamp · https://prometheus.io/docs/prometheus/latest/querying/functions/#time
- Staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Metric naming / base units: https://prometheus.io/docs/practices/naming/
- Batch jobs & Pushgateway: https://prometheus.io/docs/practices/pushing/
- PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf