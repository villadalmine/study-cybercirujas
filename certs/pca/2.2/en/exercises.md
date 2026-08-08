# Guided Exercises — Topic 2.2: Configuration and Scraping (PCA)

These labs walk you through the mechanics of how Prometheus discovers, configures, and scrapes targets. You will edit `prometheus.yml`, reload it safely, and observe how the relabeling pipeline rewrites a target's identity before a single sample is stored. Work through them in order — each builds on the running instance from the previous one.

**Prerequisites**

- A Linux host with the `prometheus` and `promtool` binaries (v2.53+ or v3.x — the configuration surface used here is identical across both) and `node_exporter` extracted somewhere on `$PATH` or in the current directory.
- `curl` and `jq` installed.
- Three free terminals. All commands assume you `cd` into an empty working directory first: `mkdir -p ~/pca-lab && cd ~/pca-lab`.

> The exam is version-agnostic on flags, but where a behavior changed between major versions it is called out explicitly.

---

## Exercise 1 — The global block, `promtool`, and a first scrape job

The `global` block sets defaults that every scrape job inherits unless it overrides them. You will never memorize a target's effective interval by reading one job in isolation — you read it against `global`.

**Steps**

1. Create the smallest useful config. Save this as `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s      # how often to scrape each target
     scrape_timeout: 10s       # give up on a scrape after this long
     evaluation_interval: 15s  # how often to evaluate rules (not scraping)
     external_labels:
       cluster: pca-lab
       replica: A

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Validate the file **before** starting anything. Never start Prometheus on an unvalidated config in production — a syntax error can leave a reload half-applied:

   ```bash
   promtool check config prometheus.yml
   ```

   Expected output:

   ```
   Checking prometheus.yml
    SUCCESS: prometheus.yml is valid prometheus config file syntax
   ```

3. Start Prometheus in the **first** terminal, enabling the lifecycle API so you can reload over HTTP later:

   ```bash
   prometheus \
     --config.file=prometheus.yml \
     --web.enable-lifecycle
   ```

4. In the **second** terminal, confirm the target is up and read the interval Prometheus actually assigned it:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq '.data.activeTargets[] | {job: .labels.job, health, scrapeInterval, scrapeUrl}'
   ```

   Expected (abridged):

   ```json
   {
     "job": "prometheus",
     "health": "up",
     "scrapeInterval": "15s",
     "scrapeUrl": "http://localhost:9090/metrics"
   }
   ```

5. Query the synthetic `up` metric and note the labels Prometheus attached without you asking:

   ```bash
   curl -s 'localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Expected:

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1712345678.9, "1" ]
     }
   ]
   ```

**Comprehension questions**

- **1a.** You wrote `targets: ["localhost:9090"]` but never wrote an `instance` label. Where did `instance="localhost:9090"` come from?
- **1b.** The scrape URL is `http://localhost:9090/metrics`. You didn't set a scheme or a path. What are the defaults, and which config keys would you change to override them?
- **1c.** `external_labels` are set, yet they do **not** appear on the `up` result above. When *do* they get attached, and to what?
- **1d.** What does `up == 1` actually prove, and what does it *not* prove about the target?

---

## Exercise 2 — Adding a second job and overriding `global`

**Steps**

1. Start `node_exporter` in the **third** terminal (it listens on `:9100` by default):

   ```bash
   ./node_exporter
   ```

2. Add a second scrape job that overrides the global interval and timeout. Edit `prometheus.yml`, appending under `scrape_configs`:

   ```yaml
     - job_name: node
       scrape_interval: 5s     # override global 15s — this job is scraped 3x more often
       scrape_timeout: 4s      # must be <= scrape_interval
       static_configs:
         - targets: ["localhost:9100"]
           labels:
             env: dev          # a custom target label, applied to every series from this target
   ```

3. Validate, then reload over HTTP (no restart, no dropped samples for the other job):

   ```bash
   promtool check config prometheus.yml && \
     curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

   Expected: `200`.

4. Confirm both jobs are present and inspect the effective interval on the new one:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeInterval)\t\(.labels.env // "-")"'
   ```

   Expected:

   ```
   prometheus	15s	-
   node	5s	dev
   ```

5. Deliberately break the timeout rule to see the guardrail. Set `scrape_timeout: 20s` on the `node` job (larger than its 5s interval), validate:

   ```bash
   promtool check config prometheus.yml
   ```

   Expected failure:

   ```
   Checking prometheus.yml
    FAILED: parsing YAML file prometheus.yml: scrape_timeout greater than scrape_interval for scrape config with job name "node"
   ```

6. Revert `scrape_timeout` back to `4s`, validate, and reload.

**Comprehension questions**

- **2a.** The `node` job is scraped every 5s and `prometheus` every 15s. Explain why the HTTP reload in step 3 was safe to run while both were being scraped, versus what a full process restart would have cost.
- **2b.** Why does Prometheus enforce `scrape_timeout <= scrape_interval`? What failure mode is it preventing?
- **2c.** The `env: dev` label was added under `static_configs[].labels`. On how many series does it appear, and how is that different from an `external_labels` entry?

---

## Exercise 3 — Reload paths: SIGHUP vs the lifecycle API vs restart

Knowing *how* to reload is exam-relevant because each path has different guarantees and prerequisites.

**Steps**

1. Confirm the lifecycle endpoint is enabled (it 405s if you forgot the flag):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:9090/-/reload
   ```

   Expected: `200` (with `--web.enable-lifecycle`). Without the flag you would get `403` / `405`.

2. Reload with a UNIX signal instead. Find the PID and send `SIGHUP`:

   ```bash
   pgrep -f 'prometheus --config.file' | head -1 | xargs -r kill -HUP
   ```

   Watch the first terminal — you should see a log line similar to:

   ```
   level=info msg="Loading configuration file" filename=prometheus.yml
   level=info msg="Completed loading of configuration file" filename=prometheus.yml
   ```

3. Introduce an error and attempt a hot reload to prove reloads are transactional. Add a bogus key `scrape_intervl: 5s` (typo) to the `node` job, then:

   ```bash
   curl -s -X POST localhost:9090/-/reload
   ```

   Expected: a non-200 with a body like:

   ```
   error loading config from "prometheus.yml": ... field scrape_intervl not found in type config.plain
   ```

4. Query targets again — the previously running config is still active; the bad file was **not** applied:

   ```bash
   curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
   ```

   Expected: `2` (unchanged).

5. Fix the typo, validate with `promtool`, and reload cleanly.

**Comprehension questions**

- **3a.** List the three ways to apply a new config and state the prerequisite (if any) for each.
- **3b.** In step 3 the reload failed. What happened to the metrics being collected during that failed reload attempt?
- **3c.** A teammate says "just restart Prometheus, it's the same as a reload." Name two concrete things a restart does that a reload does not.
- **3d.** Which reload mechanism would you wire into a Kubernetes `ConfigMap` change, and why is it preferable to SIGHUP in that environment?

---

## Exercise 4 — File-based service discovery (`file_sd_configs`)

Hardcoding targets does not scale. `file_sd_configs` lets an external system write target files that Prometheus watches and reloads *without* a config reload.

**Steps**

1. Create a targets file `targets/nodes.yml`:

   ```bash
   mkdir -p targets
   cat > targets/nodes.yml <<'EOF'
   - targets:
       - "localhost:9100"
     labels:
       env: dev
       role: worker
   EOF
   ```

2. Replace the `static_configs` in the `node` job with file SD. The job now reads:

   ```yaml
     - job_name: node
       scrape_interval: 5s
       scrape_timeout: 4s
       file_sd_configs:
         - files:
             - "targets/*.yml"     # glob; Prometheus watches the directory
           refresh_interval: 30s   # fallback poll if inotify misses a change
   ```

3. Validate and reload:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

4. Now add a target *without touching `prometheus.yml`*. Append a second node file:

   ```bash
   cat > targets/extra.yml <<'EOF'
   - targets: ["localhost:9090"]
     labels:
       env: dev
       role: monitoring
   EOF
   ```

5. Wait a couple of seconds, then observe the new target appear — no reload issued:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.labels.instance)\t\(.labels.role)"'
   ```

   Expected:

   ```
   localhost:9100	worker
   localhost:9090	monitoring
   ```

6. Inspect the discovery-side view, which shows the `__meta_*` labels file SD attaches before relabeling:

   ```bash
   curl -s localhost:9090/api/v1/targets/metadata >/dev/null   # (metadata endpoint)
   curl -s 'localhost:9090/api/v1/targets?state=active' | \
     jq '.data.activeTargets[] | select(.labels.job=="node") | .discoveredLabels' | head -20
   ```

   You will see labels such as `__meta_filepath` identifying which file produced the target.

**Comprehension questions**

- **4a.** In step 5 the new target was picked up with no `/-/reload` and no SIGHUP. Which mechanism inside file SD made that happen, and what is `refresh_interval` a safety net *for*?
- **4b.** What does the `__meta_filepath` discovered label give you operationally when debugging "why is this target here"?
- **4c.** You want to keep the target list in JSON emitted by a CI job. Does `file_sd_configs` support that, and what must the file extension be?

---

## Exercise 5 — The relabeling pipeline (`relabel_configs`)

This is the heart of the topic. `relabel_configs` runs **after** service discovery and **before** the scrape. It can rewrite the address, drop targets entirely, and shape the final `instance`/`job` identity. Get this wrong and you scrape the wrong endpoint or store nothing.

**Steps**

1. Add relabeling to the `node` job so it: (a) keeps only `worker` targets, (b) copies the SD-provided `role` into a clean label, and (c) rewrites `instance` to a friendly hostname. Replace the `node` job body with:

   ```yaml
     - job_name: node
       scrape_interval: 5s
       scrape_timeout: 4s
       file_sd_configs:
         - files: ["targets/*.yml"]
       relabel_configs:
         # 1. Drop any target whose role is not "worker".
         - source_labels: [role]
           regex: worker
           action: keep

         # 2. Build a "host" label from the address, stripping the port.
         - source_labels: [__address__]
           regex: '([^:]+):\d+'
           target_label: host
           replacement: '${1}'

         # 3. Set the final instance label explicitly instead of using __address__.
         - source_labels: [host, env]
           separator: '/'
           target_label: instance
           replacement: '${1}'
   ```

2. Validate and reload:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

3. Observe the effect — only the `worker` survives, and `instance` is no longer `host:port`:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.labels.instance)\t\(.labels.host)\t\(.labels.role)"'
   ```

   Expected:

   ```
   localhost	localhost	worker
   ```

   The `localhost:9090`/`monitoring` target from Exercise 4 is gone — it was dropped by the `keep` action.

4. Prove the scrape address is unaffected by the `instance` rewrite. Even though `instance=localhost`, the scrape still hits port 9100:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | .scrapeUrl'
   ```

   Expected:

   ```
   http://localhost:9100/metrics
   ```

5. Add a `labelmap` example to auto-promote SD meta labels. Append to `relabel_configs`:

   ```yaml
         # Promote every __meta_* label into a plain label of the same suffix.
         - action: labelmap
           regex: __meta_(.+)
           replacement: 'sd_${1}'
   ```

   Reload and confirm labels like `sd_filepath` appear.

**Comprehension questions**

- **5a.** After all relabeling ran, `instance=localhost` but the scrape URL still targets `:9100`. Explain the exact order of operations that makes both statements true. Which special label actually determines the scrape address?
- **5b.** What is the difference in outcome between `action: keep` and `action: drop` with the *same* `source_labels`/`regex`?
- **5c.** Every relabel target label you set starts as a normal label — but a whole class of labels is stripped right before the scrape. Which labels are removed, and why does `__address__` survive long enough to build the URL but not appear on the final series?
- **5d.** You want to hash targets across two replicas so each scrapes half. Which relabel `action` and which config keys implement that, and what stops both replicas from scraping the same target?

---

## Exercise 6 — `metric_relabel_configs`: shaping samples, not targets

`relabel_configs` acts on *targets* before scraping. `metric_relabel_configs` acts on *individual samples* after scraping, right before ingestion — this is where you drop high-cardinality series to protect your TSDB.

**Steps**

1. First, measure what the `node` target actually exposes:

   ```bash
   curl -s localhost:9100/metrics | grep -c '^node_'
   ```

   Note the count (it will be several hundred).

2. Drop a noisy metric family at ingestion. Add to the `node` job:

   ```yaml
       metric_relabel_configs:
         # Never store per-CPU scheduler stats — high cardinality, low value here.
         - source_labels: [__name__]
           regex: 'node_scrape_collector_.*'
           action: drop

         # Drop the "mode=idle" time series specifically (keeps other modes).
         - source_labels: [__name__, mode]
           regex: 'node_cpu_seconds_total;idle'
           action: drop
   ```

3. Validate, reload, and confirm the idle series is gone from storage but the other modes remain:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   sleep 6
   curl -s 'localhost:9090/api/v1/query?query=count(node_cpu_seconds_total)%20by%20(mode)' | \
     jq -r '.data.result[] | "\(.metric.mode)\t\(.value[1])"'
   ```

   Expected: rows for `user`, `system`, `iowait`, etc. — but **no** `idle` row.

4. Confirm the raw exposition still contains `idle` (you dropped it on the server, not the target):

   ```bash
   curl -s localhost:9100/metrics | grep 'node_cpu_seconds_total{cpu="0",mode="idle"}'
   ```

   Expected: the line is still present at the exporter. The drop happened inside Prometheus.

**Comprehension questions**

- **6a.** State the precise stage in the scrape lifecycle where `metric_relabel_configs` runs, relative to `relabel_configs` and to storage.
- **6b.** In step 4 the metric still exists at the exporter but not in Prometheus. What does this tell you about *where* the cardinality cost is and is not reduced (network vs. TSDB)?
- **6c.** Why is `__name__` available as a `source_labels` value in `metric_relabel_configs` but conceptually meaningless in `relabel_configs`?
- **6d.** A colleague adds a `keep` rule matching only `node_memory_.*` to save space. What is the dangerous side effect of using `keep` (vs. targeted `drop`s) in `metric_relabel_configs`?

---

## Exercise 7 — `honor_labels`, `honor_timestamps`, and label collisions

When a target exposes a label that Prometheus also assigns (`job`, `instance`), someone has to lose. `honor_labels` decides who.

**Steps**

1. Create a tiny target that lies about its own `job` label. Save `fake_exporter.txt`:

   ```
   # HELP demo_requests_total A demo counter that ships a job label.
   # TYPE demo_requests_total counter
   demo_requests_total{job="i-set-this-myself"} 42
   ```

   Serve it on port 8000:

   ```bash
   python3 -m http.server 8000 --bind 127.0.0.1 &
   # expose the file at /metrics via a symlink so the path matches
   ln -sf fake_exporter.txt metrics
   ```

   > For a faithful test point `metrics_path` at the served file; the mechanics of the collision are what matter.

2. Add a job that scrapes it with the **default** (`honor_labels: false`), by appending to `prometheus.yml`:

   ```yaml
     - job_name: demo
       metrics_path: /metrics
       honor_labels: false
       static_configs:
         - targets: ["localhost:8000"]
   ```

3. Reload, scrape, and inspect what happened to the conflicting `job` label:

   ```bash
   curl -s -X POST localhost:9090/-/reload >/dev/null; sleep 3
   curl -s 'localhost:9090/api/v1/query?query=demo_requests_total' | \
     jq '.data.result[0].metric'
   ```

   Expected (server label wins; the target's value is preserved under a prefix):

   ```json
   {
     "__name__": "demo_requests_total",
     "job": "demo",
     "instance": "localhost:8000",
     "exported_job": "i-set-this-myself"
   }
   ```

4. Flip `honor_labels: true`, reload, re-query:

   ```json
   {
     "__name__": "demo_requests_total",
     "job": "i-set-this-myself",
     "instance": "localhost:8000"
   }
   ```

**Comprehension questions**

- **7a.** With `honor_labels: false`, where did the target's `job="i-set-this-myself"` go, and which value won?
- **7b.** With `honor_labels: true`, what happened to the server-assigned `job="demo"`? Give one real scenario (hint: federation, or a Pushgateway) where `true` is the correct choice.
- **7c.** `honor_timestamps` is a separate knob. What does setting it to `false` force Prometheus to do with any timestamps embedded in the exposition format, and why would you disable it?

---

## Exercise 8 — Scheme, path, params, and authenticated scrapes

Real targets sit behind HTTPS, custom paths, query parameters, and auth. This exercise assembles the full request-shaping surface.

**Steps**

1. Study a fully-specified job (do not run it — read and predict the resulting scrape URL):

   ```yaml
     - job_name: secured-app
       scheme: https                 # default is http
       metrics_path: /internal/metrics
       params:
         format: ["prometheus"]      # appended as ?format=prometheus
         module: ["http_2xx"]        # blackbox-style multi param
       basic_auth:
         username: scraper
         password_file: /etc/prometheus/scrape_pw   # file, not inline, so it stays out of the config
       tls_config:
         ca_file: /etc/prometheus/ca.crt
         server_name: app.internal
         insecure_skip_verify: false
       static_configs:
         - targets: ["app.internal:8443"]
   ```

2. Reason about the resulting URL and headers before validating. The scrape request is:

   ```
   GET https://app.internal:8443/internal/metrics?format=prometheus&module=http_2xx
   Authorization: Basic <base64(scraper:<contents of scrape_pw>)>
   ```

3. Note the internal labels these keys map to (used in relabeling): `scheme → __scheme__`, `metrics_path → __metrics_path__`, each param → `__param_<name>`, `targets → __address__`.

4. Validate a version with a deliberate mistake — inline `password` **and** `password_file` set — to see the mutual-exclusion guard:

   ```yaml
       basic_auth:
         username: scraper
         password: hunter2
         password_file: /etc/prometheus/scrape_pw
   ```

   `promtool check config` expected failure:

   ```
   FAILED: at most one of basic_auth password & password_file must be configured
   ```

**Comprehension questions**

- **8a.** Reconstruct the full scrape URL from the `secured-app` job by hand, in order (scheme, host, path, query string).
- **8b.** Which four internal labels would you target in `relabel_configs` if you wanted to flip this same job from HTTPS to HTTP and change its path *dynamically* from a service-discovery meta label?
- **8c.** Why is `password_file` preferred over an inline `password`, given that both end up in memory anyway? Think about config in a `ConfigMap` and about `git`.
- **8d.** `insecure_skip_verify: false` with a custom `server_name` — what does `server_name` let you do that a plain hostname target does not?

---

## Exercise 9 — Reading the scrape's own health metrics

Every scrape emits synthetic metrics about *itself*. These are your first diagnostic stop when a target misbehaves.

**Steps**

1. Query the four core per-scrape synthetics for the `node` job:

   ```bash
   for m in up scrape_duration_seconds scrape_samples_scraped scrape_samples_post_metric_relabeling; do
     echo "== $m =="
     curl -s "localhost:9090/api/v1/query?query=${m}%7Bjob%3D%22node%22%7D" | \
       jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
   done
   ```

   Expected shape:

   ```
   == up ==
   localhost	1
   == scrape_duration_seconds ==
   localhost	0.0123
   == scrape_samples_scraped ==
   localhost	540
   == scrape_samples_post_metric_relabeling ==
   localhost	450
   ```

2. Compare `scrape_samples_scraped` (540) with `scrape_samples_post_metric_relabeling` (450). The gap is exactly the samples your Exercise 6 `drop` rules removed.

3. Simulate a slow/dead target: stop `node_exporter` (Ctrl-C in terminal three), wait one scrape interval, and re-query `up`:

   ```bash
   sleep 6
   curl -s 'localhost:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' | jq -r '.data.result[] | .value[1]'
   ```

   Expected: `0`.

4. Confirm the target's health string and last error in the targets API:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.health)\t\(.lastError)"'
   ```

   Expected (example):

   ```
   down	Get "http://localhost:9100/metrics": dial tcp 127.0.0.1:9100: connect: connection refused
   ```

5. Restart `node_exporter` and confirm `up` returns to `1` on the next scrape.

**Comprehension questions**

- **9a.** `scrape_samples_scraped` was 540 but `scrape_samples_post_metric_relabeling` was 450. Which config block accounts for the 90-sample difference, and which of the two numbers reflects what actually lands in the TSDB?
- **9b.** `up == 0` and `scrape_duration_seconds` is still being recorded. How can Prometheus report a duration for a scrape that failed?
- **9c.** You see `scrape_samples_scraped` climbing week over week for one job while others are flat. What does that signal, and which two config blocks are your levers to contain it?
- **9d.** Name the metric you would alert on to catch a target that is *up* but returning suspiciously few samples (a partial/broken exporter), and explain why `up` alone would miss it.

---

## Answers

<details>
<summary>Click to reveal answers to all comprehension questions</summary>

### Exercise 1

- **1a.** When no `instance` label is set, Prometheus automatically sets `instance` to the value of the `__address__` label — which comes from the `targets` entry (`localhost:9090`). This assignment happens at the end of the relabeling phase. See <https://prometheus.io/docs/concepts/jobs_instances/>.
- **1b.** Defaults are `scheme: http` and `metrics_path: /metrics`. Override with the `scheme` and `metrics_path` keys on the scrape job (they map to the internal `__scheme__` and `__metrics_path__` labels). See <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config>.
- **1c.** `external_labels` are **not** attached to stored series and are not visible on instant queries against local data. They are applied only to data that *leaves* the server: remote_write, federation, and alerts sent to Alertmanager. Their purpose is to identify *this* Prometheus among many (hence `cluster`/`replica`). See <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#configuration-file>.
- **1d.** `up == 1` proves only that Prometheus successfully completed an HTTP scrape of the target's metrics endpoint (2xx, parseable, within timeout). It says nothing about whether the exposed values are correct, complete, or fresh — a broken exporter that returns an empty-but-valid page still reports `up == 1`.

### Exercise 2

- **2a.** An HTTP `/-/reload` (or SIGHUP) re-reads the config and reconciles scrape jobs in place: unchanged jobs keep their scrape loops and their in-memory state untouched, so `prometheus`'s 15s cadence is never interrupted. A full process restart tears down every scrape loop, replays the WAL, and re-runs service discovery from scratch, causing a gap in all series and a cold start. 
- **2b.** If a scrape could run longer than the interval, a new scrape would be launched before the previous one finished, piling up overlapping in-flight requests against the target and skewing the sample cadence. Requiring `scrape_timeout <= scrape_interval` guarantees at most one in-flight scrape per target at a time.
- **2c.** `env: dev` under `static_configs[].labels` is a **target label**: it is attached to *every* series scraped from that target and is stored in the TSDB (queryable, part of series identity). An `external_labels` entry is attached only to outbound data (remote_write/federation/alerts) and is not stored locally. Different scope, different lifecycle.

### Exercise 3

- **3a.** (1) HTTP POST to `/-/reload` — requires `--web.enable-lifecycle`. (2) `SIGHUP` to the process — no prerequisite, always available. (3) Full restart — no prerequisite but drops state. See <https://prometheus.io/docs/prometheus/latest/management_api/>.
- **3b.** Nothing was lost. Config reloads are transactional: the new file is parsed and validated first; if it fails, the error is returned and the **previously running config stays fully active**. Scraping continued uninterrupted on the old config.
- **3c.** Any two of: a restart replays the WAL and reloads the head block from disk (a reload does not); a restart resets all scrape loops and staleness state, creating a data gap; a restart re-executes command-line flags (a reload cannot change flags — e.g. `--web.enable-lifecycle`, storage retention, and listen address are flag-only and require a restart to change).
- **3d.** The HTTP `/-/reload` endpoint, typically triggered by a config-reloader sidecar that watches the mounted `ConfigMap` for changes. It is preferable to SIGHUP in Kubernetes because the sidecar can reach the endpoint over the network/localhost without needing to share a process namespace or `kill` privileges against the main container's PID.

### Exercise 4

- **4a.** File SD watches the referenced files/directories for changes (via filesystem notification) and applies target changes immediately, with no config reload. `refresh_interval` (default 5m) is a fallback poll that re-reads the files periodically in case a filesystem event was missed (e.g. on network filesystems or certain container mounts). See <https://prometheus.io/docs/guides/file-sd/>.
- **4b.** `__meta_filepath` tells you exactly which SD file produced a given target, so when a target appears unexpectedly you can trace it back to the specific file (and the system that wrote it) rather than guessing.
- **4c.** Yes — file SD supports `.json`, `.yml`, and `.yaml`. The extension must be one of those; the JSON schema is a list of `{ "targets": [...], "labels": {...} }` objects.

### Exercise 5

- **5a.** Order: SD produces labels (including `__address__`, `__scheme__`, `__metrics_path__`, `__meta_*`) → `relabel_configs` run in sequence, freely reading/writing any label including `instance` → the scrape address is built from the **final** value of `__address__` (combined with `__scheme__`, `__metrics_path__`, `__param_*`) → if `instance` is unset it defaults to `__address__` → all remaining `__`-prefixed labels are stripped before the scrape stores series. So rewriting `instance` never touched `__address__`, which is why the URL still points at `:9100`. The `__address__` label determines the scrape address. See <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>.
- **5b.** `keep` discards every target whose concatenated `source_labels` do **not** match `regex` (whitelist). `drop` discards every target that **does** match (blacklist). Same inputs, opposite survivors.
- **5c.** All labels beginning with `__` (the "internal"/meta labels: `__address__`, `__scheme__`, `__metrics_path__`, `__meta_*`, `__param_*`, `__tmp_*`) are removed at the end of relabeling, right before the scrape. `__address__` survives *through* the relabeling phase because that is when the scrape URL is constructed from it; it is only after the URL is built and `instance` defaulted that the strip happens — so it never becomes a stored label.
- **5d.** `action: hashmod` computes `mod(hash(source_labels), modulus)` into a `target_label` (e.g. `__tmp_hash`), followed by a `keep` action that matches only the shard number belonging to this replica. Because both replicas hash the *same* source labels but each keeps a *different* residue, they partition the targets disjointly. Keys: `source_labels`, `modulus`, `target_label` on the `hashmod` step; `source_labels`+`regex` on the `keep`.

### Exercise 6

- **6a.** `metric_relabel_configs` runs **after** the scrape completes and **after** `relabel_configs` (which ran pre-scrape on the target), operating on each parsed sample, and **before** the sample is written to storage. Pipeline: SD → relabel_configs → scrape → metric_relabel_configs → TSDB.
- **6b.** The cardinality/traffic cost on the **network and at the exporter** is unchanged — Prometheus still fetched every series over the wire. The savings are purely in the **TSDB** (ingestion, index, disk, query cost). To reduce network/exporter cost you must stop exposing the metric at the source or use scrape-side collector flags.
- **6c.** After a scrape, each sample carries its metric name in the `__name__` label, so `metric_relabel_configs` can match on it. In `relabel_configs` there are no samples yet — only target labels — so there is no `__name__` to match; it exists per-series, not per-target.
- **6d.** `keep` in `metric_relabel_configs` drops **everything that does not match**. So a `keep` on `node_memory_.*` silently discards *all* other metric families from that target — including `up`-adjacent synthetics and anything else you rely on — which is a far larger blast radius than intended. Prefer explicit `drop` rules for the few families you want gone.

### Exercise 7

- **7a.** With `honor_labels: false` (default), the server-assigned `job="demo"` wins; the target's own conflicting `job` value is preserved but renamed to `exported_job`. Nothing is lost, but the authoritative `job` is Prometheus's.
- **7b.** With `honor_labels: true`, the server does not overwrite exposed labels: the target's `job="i-set-this-myself"` is kept as `job`, and the server's `job="demo"` is discarded for conflicting names. Correct when the target is itself authoritative about identity — classic cases are **federation** (`/federate` re-exposes series that already carry their true `job`/`instance`) and the **Pushgateway** (pushed metrics carry the originating job's labels). See <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config>.
- **7c.** `honor_timestamps: false` makes Prometheus **ignore** any timestamps embedded in the exposition and assign its own scrape time to every sample. You disable it when a target exports stale or unreliable timestamps (e.g. a caching proxy or a batch exporter) that would otherwise create out-of-order or misleading sample times.

### Exercise 8

- **8a.** `https://app.internal:8443/internal/metrics?format=prometheus&module=http_2xx` — scheme `https`, host:port from the target, path from `metrics_path`, query string from `params` (order of params within the query string is not guaranteed but both are present).
- **8b.** `__scheme__` (http/https), `__metrics_path__` (the path), `__address__` (host:port), and `__param_<name>` (query parameters) — each can be rewritten in `relabel_configs`, typically sourcing values from `__meta_*` labels produced by service discovery.
- **8c.** `password_file` keeps the secret out of the config document itself, so a `prometheus.yml` stored in a `ConfigMap` or committed to `git` never contains the credential — the file is mounted separately (e.g. from a `Secret`). Inline `password` would leak the secret into version control and into anything that reads the config text.
- **8d.** `server_name` sets the SNI value and the name verified against the server certificate's SAN, independent of the address you dial. That lets you connect to a target by IP or a load-balancer address while still validating the certificate against its real DNS name (rather than disabling verification). See <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#tls_config>.

### Exercise 9

- **9a.** `metric_relabel_configs` accounts for the difference (the Exercise 6 `drop` rules removed 90 samples). `scrape_samples_post_metric_relabeling` (450) reflects what actually lands in the TSDB; `scrape_samples_scraped` (540) is the count parsed off the wire before metric relabeling.
- **9b.** `scrape_duration_seconds` measures the time spent attempting the scrape — including a connection that was refused or timed out. A failed scrape still consumes wall-clock time (up to the timeout), so a duration is recorded even when `up == 0`.
- **9c.** Rising `scrape_samples_scraped` for one job signals **cardinality growth** in that target (new label values / new series). Your two containment levers are `metric_relabel_configs` (drop offending series server-side, protects the TSDB) and, ideally, `sample_limit` / target-side changes to stop exposing them (protects network too). A `sample_limit` on the scrape job can also hard-cap ingestion and fail the scrape when exceeded.
- **9d.** Alert on `scrape_samples_post_metric_relabeling` (or `scrape_samples_scraped`) dropping below an expected floor — e.g. `scrape_samples_post_metric_relabeling{job="node"} < 100`. `up` would miss it because a target that returns a valid but nearly-empty page still scrapes successfully (`up == 1`); only the sample count reveals the missing data.

</details>

---

**Sources**

- Prometheus configuration reference — <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- Jobs and instances (auto `instance`, synthetic `up`) — <https://prometheus.io/docs/concepts/jobs_instances/>
- Management / lifecycle API (`/-/reload`) — <https://prometheus.io/docs/prometheus/latest/management_api/>
- File-based service discovery guide — <https://prometheus.io/docs/guides/file-sd/>
- TLS/`tls_config` and web configuration — <https://prometheus.io/docs/prometheus/latest/configuration/https/>
- PCA curriculum — <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>