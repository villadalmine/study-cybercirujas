# PCA 3.5 — Service Discovery · Guided Exercises

> **Domain:** Prometheus Fundamentals → Configuration and Scraping · **Exam weight:** 3
> **Goal:** learn how Prometheus *turns a source of truth into a set of scrape targets*. Every discovery mechanism ends in the same place — a target group with an `__address__` and a bag of `__meta_*` labels — which is then reshaped by `relabel_configs` before the first scrape ever happens. If you understand that pipeline, every SD backend (static, file, HTTP, Kubernetes, DNS, Consul, EC2…) becomes the same exercise with a different label prefix.

### Environment

You need a single Linux host with:

- `prometheus` and `promtool` on `PATH` (v2.45+; any recent 2.x/3.x is fine),
- `node_exporter` running on `:9100` (a convenient real target),
- `curl`, `jq`, `python3`, and (Exercise 5) `kind` + `kubectl`.

Always start Prometheus with the lifecycle API enabled so you can hot-reload without killing the process:

```bash
prometheus --config.file=prometheus.yml --web.enable-lifecycle
```

Reload after every config change with either signal or API:

```bash
curl -sf -X POST http://localhost:9090/-/reload      # needs --web.enable-lifecycle
# or:  kill -HUP "$(pgrep -x prometheus)"
```

Source of truth for everything below:
- Configuration & all `*_sd_config` blocks — https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Relabeling — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- HTTP SD — https://prometheus.io/docs/prometheus/latest/http_sd/
- File SD guide — https://prometheus.io/docs/guides/file-sd/

---

## Exercise 1 — Static targets and the target lifecycle

### Steps

1. Write a minimal config with two static targets — Prometheus itself and `node_exporter`:

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['localhost:9100']
           labels:
             env: lab
   ```

2. Validate it *before* loading it — SD is not tested here, only syntax:

   ```bash
   promtool check config prometheus.yml
   ```
   ```console
   Checking prometheus.yml
    SUCCESS: prometheus.yml is valid prometheus config file syntax
   ```

3. Start Prometheus (see Environment) and query the targets API, filtering the interesting fields:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | {scrapePool, discoveredLabels, labels, health}'
   ```
   ```json
   {
     "scrapePool": "node",
     "discoveredLabels": {
       "__address__": "localhost:9100",
       "__metrics_path__": "/metrics",
       "__scheme__": "http",
       "__scrape_interval__": "15s",
       "__scrape_timeout__": "10s",
       "env": "lab",
       "job": "node"
     },
     "labels": {
       "env": "lab",
       "instance": "localhost:9100",
       "job": "node"
     },
     "health": "up"
   }
   ```

4. Note what appears in `labels` that you never wrote: `instance`. Open the web UI at `http://localhost:9090/targets` and confirm the `node` target is `UP`.

### Check your understanding

- **1a.** `discoveredLabels` has `__address__` but `labels` does not. Where did `__address__` go, and why is it absent from the final label set?
- **1b.** You never set `instance`, yet it appears. What is its default value, and at which stage is it filled in?
- **1c.** Which URL will Prometheus actually scrape for the `node` target, and which three `__meta`/`__`-prefixed labels determined it?

---

## Exercise 2 — File-based service discovery and hot reload

### Steps

1. Replace the `node` job's `static_configs` with `file_sd_configs` pointing at a directory glob:

   ```yaml
     - job_name: node
       file_sd_configs:
         - files:
             - 'targets/*.json'
           refresh_interval: 30s
   ```

2. Create the target files. File SD re-reads these on change *and* every `refresh_interval`, with **no Prometheus reload required**:

   ```bash
   mkdir -p targets
   cat > targets/prod.json <<'EOF'
   [
     { "targets": ["localhost:9100"], "labels": { "env": "prod" } }
   ]
   EOF
   ```

3. Reload once (because you changed `prometheus.yml` itself), then confirm the target is live:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="node") | .discoveredLabels'
   ```
   ```json
   {
     "__address__": "localhost:9100",
     "__meta_filepath": "/path/to/targets/prod.json",
     "__metrics_path__": "/metrics",
     "__scheme__": "http",
     "__scrape_interval__": "15s",
     "__scrape_timeout__": "10s",
     "env": "prod",
     "job": "node"
   }
   ```

4. Now add a second target file **without touching `prometheus.yml` and without reloading**:

   ```bash
   cat > targets/staging.json <<'EOF'
   [
     { "targets": ["localhost:9101"], "labels": { "env": "staging" } }
   ]
   EOF
   ```

5. Wait up to `refresh_interval` (or a few seconds — file changes are also detected by inotify) and re-query. You should now see two targets, one `up` and one `down` (nothing is listening on `:9101`). Confirm the file SD refresh with the metric:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_sd_file_scan_duration_seconds_count' | jq '.data.result'
   ```

### Check your understanding

- **2a.** You added `staging.json` with no reload and it was picked up. Name the *two* independent mechanisms that cause File SD to re-read its files.
- **2b.** Editing `prometheus.yml`'s `files:` glob required a reload, but editing the contents of `prod.json` did not. Why is that distinction fundamental to how File SD is meant to be used?
- **2c.** What is `__meta_filepath`, and why is it useful even though it disappears from the final labels?

---

## Exercise 3 — Relabeling: `replace`, `keep`, `drop`, and reading dropped targets

### Steps

`relabel_configs` runs as an ordered pipeline over each discovered target, *before* scraping. Here you will (a) promote a `__meta_*` label into a real label, and (b) filter targets so only production is scraped.

1. Add a `relabel_configs` block to the `node` job (which still uses File SD from Exercise 2):

   ```yaml
     - job_name: node
       file_sd_configs:
         - files: ['targets/*.json']
       relabel_configs:
         # (a) derive a real label from the source filename
         - source_labels: [__meta_filepath]
           regex: '.*/([^/]+)\.json'
           replacement: '$1'
           target_label: sd_file

         # (b) keep only targets whose env label is "prod"; drop the rest
         - source_labels: [env]
           regex: prod
           action: keep
   ```

2. Reload and inspect **active** targets — only `prod` survives, and it now carries `sd_file="prod"`:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="node") | .labels'
   ```
   ```json
   {
     "env": "prod",
     "instance": "localhost:9100",
     "job": "node",
     "sd_file": "prod"
   }
   ```

3. Now inspect **dropped** targets. A `keep` that fails does not error — it silently removes the target, which is the single most common "why isn't my target showing up?" cause:

   ```bash
   curl -s 'http://localhost:9090/api/v1/targets?state=dropped' \
     | jq '.data.droppedTargets[] | .discoveredLabels | {__address__, env}'
   ```
   ```json
   {
     "__address__": "localhost:9101",
     "env": "staging"
   }
   ```

4. Open `http://localhost:9090/service-discovery` in the browser. For the `node` pool it shows every discovered target with **"Discovered Labels"** on the left and **"Target Labels"** on the right; dropped targets show the right column struck through. This page is the ground truth for debugging relabeling.

### Check your understanding

- **3a.** The `keep` rule dropped `localhost:9101`, but `/api/v1/targets` (default) showed no error and no target. Where did it go, and what query flag reveals it?
- **3b.** In the `sd_file` rule, why does `__meta_filepath` (a `__`-prefixed meta label) survive long enough to be read, while `__address__` is also `__`-prefixed but is *kept* as the scrape address? State the general rule about `__`-prefixed labels after relabeling.
- **3c.** If you swapped the order so the `keep` rule ran **first** and the `sd_file` `replace` rule ran second, would the surviving `prod` target still get `sd_file="prod"`? Would anything about the *dropped* target change?
- **3d.** What is the difference between `relabel_configs` and `metric_relabel_configs`, and which one could *not* have been used to filter out the staging target?

---

## Exercise 4 — HTTP-based service discovery

File SD requires files on the Prometheus host. HTTP SD moves the source of truth to any HTTP endpoint that returns the same target-group JSON — the modern, language-agnostic way to write a custom SD integration.

### Steps

1. Create a target-group document and serve it over HTTP. Prometheus requires the response to be `200 OK` with `Content-Type: application/json`:

   ```bash
   mkdir -p httpsd && cd httpsd
   cat > targets.json <<'EOF'
   [
     {
       "targets": ["localhost:9100"],
       "labels": { "job": "node", "env": "prod", "team": "sre" }
     }
   ]
   EOF
   python3 -m http.server 8080 &   # serves .json as application/json
   cd ..
   ```

2. Point a job at the endpoint:

   ```yaml
     - job_name: http-sd-node
       http_sd_configs:
         - url: http://localhost:8080/targets.json
           refresh_interval: 30s
   ```

3. Reload and confirm the target, noting the HTTP-SD meta label:

   ```bash
   curl -sf -X POST http://localhost:9090/-/reload
   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="http-sd-node") | .discoveredLabels'
   ```
   ```json
   {
     "__address__": "localhost:9100",
     "__meta_url": "http://localhost:8080/targets.json",
     "__metrics_path__": "/metrics",
     "__scheme__": "http",
     "__scrape_interval__": "15s",
     "__scrape_timeout__": "10s",
     "env": "prod",
     "job": "node",
     "team": "sre"
   }
   ```

4. Break it on purpose: stop the `http.server`, wait `refresh_interval`, and re-query. The target **remains** at its last-known state, and a discovery-failure metric increments:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_sd_http_failures_total' \
     | jq '.data.result[].value[1]'
   ```

### Check your understanding

- **4a.** After you killed the HTTP server, the target did not disappear. Why does Prometheus keep the last-successful target list on a discovery failure instead of dropping everything, and what would be the operational danger of the opposite behaviour?
- **4b.** HTTP SD and File SD both consume the exact same JSON shape (`[{ "targets": [...], "labels": {...} }]`). What does that tell you about where in the pipeline the *choice of SD backend* stops mattering?
- **4c.** If the endpoint returned `Content-Type: text/plain`, what would happen, and where would you see the reason?

---

## Exercise 5 — Kubernetes service discovery (roles + annotation-driven scraping)

> Requires a cluster. Quick disposable one: `kind create cluster --name pca`. Run Prometheus **in** the cluster (RBAC granted) or point a local Prometheus at the API server; the relabel logic is identical.

### Steps

1. Understand the roles first — each yields a different target set and label prefix:

   | `role` | one target per… | key `__meta` labels |
   |---|---|---|
   | `node` | Kubelet | `__meta_kubernetes_node_name`, `__meta_kubernetes_node_label_*` |
   | `pod` | pod **container port** | `__meta_kubernetes_pod_name`, `__meta_kubernetes_pod_annotation_*`, `__meta_kubernetes_pod_container_port_number` |
   | `endpoints` | address in a Service's Endpoints | `__meta_kubernetes_service_name`, `__meta_kubernetes_endpoint_ready` |
   | `endpointslice` | address in an EndpointSlice | `__meta_kubernetes_endpointslice_*` |
   | `service` | Service ClusterIP:port (blackbox) | `__meta_kubernetes_service_annotation_*` |
   | `ingress` | Ingress path (blackbox) | `__meta_kubernetes_ingress_*` |

2. Configure the canonical annotation-driven pod job. This is *entirely* relabeling — SD gives you every pod port; the rules select and rewrite:

   ```yaml
     - job_name: kubernetes-pods
       kubernetes_sd_configs:
         - role: pod
       relabel_configs:
         # keep only pods annotated prometheus.io/scrape: "true"
         - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
           action: keep
           regex: "true"

         # optional custom metrics path from annotation
         - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
           action: replace
           target_label: __metrics_path__
           regex: (.+)

         # rewrite host:port using the annotated port (address:port ⇐ podIP + annotation)
         - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
           action: replace
           regex: ([^:]+)(?::\d+)?;(\d+)
           replacement: $1:$2
           target_label: __address__

         # promote all pod labels to metric labels
         - action: labelmap
           regex: __meta_kubernetes_pod_label_(.+)

         # carry namespace and pod name as stable labels
         - source_labels: [__meta_kubernetes_namespace]
           target_label: namespace
         - source_labels: [__meta_kubernetes_pod_name]
           target_label: pod
   ```

3. Deploy an annotated workload and verify it is discovered:

   ```bash
   kubectl create deployment web --image=nginx
   kubectl patch deployment web --type merge -p '{
     "spec":{"template":{"metadata":{"annotations":{
       "prometheus.io/scrape":"true","prometheus.io/port":"80"}}}}}'

   curl -s http://localhost:9090/api/v1/targets \
     | jq '.data.activeTargets[] | select(.scrapePool=="kubernetes-pods") | {labels, health}'
   ```

4. Diagnose exclusions on `/service-discovery`: pods **without** the annotation appear as dropped by the very first `keep` rule — proving the whole cluster was discovered and then filtered, not "missed".

### Check your understanding

- **5a.** With `role: pod`, an nginx pod exposing one container port produces exactly one target; a pod with three declared container ports produces three. Why — and which `__meta` label distinguishes them?
- **5b.** In the `__address__` rewrite rule, the `regex` is `([^:]+)(?::\d+)?;(\d+)` and the separator between the two source labels is `;`. Walk through what `$1` and `$2` capture, and why the middle `(?::\d+)?` is optional.
- **5c.** You want to scrape a Service as one logical target (blackbox-style, load-balanced by the ClusterIP) rather than each backing pod individually. Which role do you choose, and why is `endpoints`/`pod` the *wrong* answer for that intent?
- **5d.** A teammate says "the pod job missed my new service." Given this config, what is the more precise statement, and exactly which page confirms it?

---

## Exercise 6 — DNS service discovery and a diagnosis drill

### Steps

1. Add a DNS-SRV job. `dns_sd_configs` periodically resolves the names and turns each returned record into a target:

   ```yaml
     - job_name: dns-srv
       dns_sd_configs:
         - names:
             - '_node-exporter._tcp.svc.lab.local'
           type: SRV
           refresh_interval: 30s
       relabel_configs:
         - source_labels: [__meta_dns_srv_record_target]
           target_label: srv_host
   ```
   *(For an A/AAAA record you must also supply a `port:`, because A records carry no port; SRV records do.)*

2. Validate syntax and reload:

   ```bash
   promtool check config prometheus.yml && curl -sf -X POST http://localhost:9090/-/reload
   ```

3. Inspect the DNS meta labels that SD attaches (visible on `/service-discovery` even when resolution fails):

   - `__meta_dns_name` — the query name,
   - `__meta_dns_srv_record_target` / `__meta_dns_srv_record_port` — the resolved SRV host/port,
   - `__meta_dns_mname` — the SOA record's primary name server.

4. **Diagnosis drill.** For each symptom below, decide *which single page or query* you would open first, then confirm by reproducing it with the jobs you already built:

   | Symptom | First place to look |
   |---|---|
   | Target listed but `health: down`, `lastError: "connection refused"` | `/targets` → `Error` column |
   | Target you expected is entirely absent | `/service-discovery` → is it in the *dropped* column? |
   | SD backend returns nothing at all | `prometheus_sd_*_failures_total` / `_sd_*_refresh_*` metrics |
   | Right target, wrong `instance`/labels | `/service-discovery` → Discovered vs Target labels diff |

### Check your understanding

- **6a.** Why can `dns_sd_configs` with `type: A` **require** an explicit `port`, while `type: SRV` must **not** need one?
- **6b.** A target shows `health: down` with `lastError: context deadline exceeded`. Is this a service-discovery problem? Justify using the discovered-vs-target-labels distinction.
- **6c.** You see `up == 0` for a job but `/service-discovery` shows the target in the *dropped* column. Which of the two — scrape failure or relabel drop — is happening, and why can only one of them be true at a time for a given address?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** `__address__` is not deleted — it is *consumed*. After relabeling, Prometheus uses `__address__` (plus `__scheme__` and `__metrics_path__`) to build the scrape URL, then strips every remaining `__`-prefixed label from the final metric label set. So it still governs the scrape; it just isn't attached to the resulting time series.
- **1b.** `instance` defaults to the value of `__address__` (`localhost:9100`). It is filled in *after* relabeling, at the moment the `__`-prefixed labels are dropped — which is why you can override `instance` in `relabel_configs` but, if you don't, it mirrors the address.
- **1c.** Scrape URL = `http://localhost:9100/metrics`, built from `__scheme__` (`http`) + `__address__` (`localhost:9100`) + `__metrics_path__` (`/metrics`).

### Exercise 2
- **2a.** (1) A filesystem watch (inotify) that reacts to file create/modify/delete, and (2) the periodic `refresh_interval` full re-scan (default 5 minutes) as a safety net for missed/coalesced events and networked filesystems.
- **2b.** The `files:` glob is *Prometheus configuration* (loaded once at start/reload); the file *contents* are *data* that File SD owns and polls continuously. The whole point of File SD is that a separate system (config management, a script, an operator) rewrites the target files at runtime and Prometheus follows them with no reload — decoupling "what to scrape" from "how Prometheus is configured."
- **2c.** `__meta_filepath` is the absolute path of the file a target came from, injected by File SD. It disappears from final labels (all `__meta_*` are dropped after relabeling) but you can read it during relabeling to derive real labels (e.g. environment or shard from the filename), which Exercise 3 does.

### Exercise 3
- **3a.** A `keep` whose regex doesn't match removes the target from the active set and files it under **dropped targets**. The default `/api/v1/targets` omits them; `?state=dropped` (or `?state=any`) reveals them, and `/service-discovery` shows them with the target-labels column struck through. No error is raised — this silence is the classic "missing target" trap.
- **3b.** General rule: `__`-prefixed labels are available *throughout* relabeling and are only stripped at the *end*, just before the target is finalized. So `__meta_filepath` is fully readable while rules run; it's dropped afterward like every other `__` label. `__address__` is also dropped from the final label set — it isn't "kept as a label," it's *consumed* to build the scrape URL first. Both follow the same rule; they differ only in what reads them.
- **3c.** Order matters, but not here for the survivor: relabel rules on the *same target* run in sequence and `keep`/`drop` only decide whether that target continues — they don't undo earlier `replace`s. So the surviving `prod` target still gets `sd_file="prod"` regardless of order. The dropped staging target is unaffected either way (it's dropped before or after a rule that, for it, does nothing). The order *would* matter if a later rule depended on a label a `keep`/`drop` used — but drop/keep never mutate labels.
- **3d.** `relabel_configs` runs at **discovery time**, on target `__meta_*`/address labels, deciding *which targets to scrape and how*. `metric_relabel_configs` runs at **ingestion time**, on each scraped sample's labels, deciding *which series to keep/rename*. You could **not** have used `metric_relabel_configs` to filter out the staging target, because that target would still have been discovered and scraped — the staging endpoint would be contacted (and, being down, would produce scrape errors). Only `relabel_configs` prevents the scrape from happening at all.

### Exercise 4
- **4a.** On a discovery-refresh failure Prometheus keeps the last-successful target group so a transient SD outage (network blip, endpoint restart) doesn't flap every target to "gone," which would blank dashboards, fire spurious `up==0`/absent alerts, and stop scraping healthy services. The opposite behaviour would couple the availability of your *monitoring* to the availability of your *SD control plane* — a single point of failure amplifying incidents.
- **4b.** It tells you the SD backend's job ends the moment it produces a target group `{targets, labels}`. From that point — relabeling, address building, scraping, ingestion — the pipeline is identical no matter which SD produced the group. Choosing File vs HTTP vs Kubernetes changes only *how the group is sourced and which `__meta_*` labels it carries*, nothing downstream.
- **4c.** HTTP SD rejects a non-`application/json` `Content-Type`; the target list from that endpoint is not updated (last-known state is retained), `prometheus_sd_http_failures_total` increments, and the reason is logged by Prometheus (and the endpoint shows a failure on `/service-discovery`).

### Exercise 5
- **5a.** `role: pod` creates one target per **declared container port**, because a pod can expose several ports each needing its own scrape address. One nginx port → one target; three declared ports → three targets. `__meta_kubernetes_pod_container_port_number` (with `_name`/`_protocol`) distinguishes them. (Pods with no declared ports still yield one target on the pod IP with no port — hence the port-rewrite relabel rule.)
- **5b.** Source labels are joined by the separator `;`, giving `"<podIP>[:<port>];<annotationPort>"`. `([^:]+)` captures the IP as `$1`; `(?::\d+)?` optionally matches and discards an existing `:port` already on `__address__` (a pod that *did* declare a port), so it isn't duplicated; `;` matches the separator; `(\d+)` captures the annotation port as `$2`. `replacement: $1:$2` rebuilds `podIP:annotationPort`. The middle group is optional because some targets arrive with a port on `__address__` and some without.
- **5c.** Use `role: service`: it produces one target per Service ClusterIP:port, so scrapes go through the Service VIP and are load-balanced to whatever pod answers — the blackbox/"is the service reachable" intent. `endpoints`/`pod` enumerate the *individual backends*, which is per-instance whitebox scraping — the opposite intent; you'd get N targets and bypass the VIP.
- **5d.** Precise statement: "this job is `role: pod`, so it never discovers *Services* at all — it discovers *pods*, and my pod was either not annotated `prometheus.io/scrape: "true"` (dropped by the first `keep`) or has no matching port." `/service-discovery` for the `kubernetes-pods` pool confirms it: the pod will be present in the dropped column with its discovered `__meta` labels.

### Exercise 6
- **6a.** SRV records encode both host **and** port (`_service._proto.name → target:port`), so Prometheus derives the port from the record — supplying one would be ambiguous/ignored. A/AAAA records return only IP addresses with no port, so Prometheus cannot know where to scrape unless you provide `port:` explicitly.
- **6b.** It is **not** a service-discovery problem. Discovery clearly succeeded — the target exists with resolved *discovered labels* and a built scrape URL (that's what let Prometheus try at all). `context deadline exceeded` is a *scrape-time* timeout against that address (slow/unreachable endpoint, wrong port, firewall). SD's job (producing the target) is done; the failure is downstream at scrape. You'd confirm on `/targets` (Error column), not `/service-discovery`.
- **6c.** It's a **relabel drop**, not a scrape failure. If the address is in the *dropped* column, the target was removed during relabeling and is therefore **never scraped** — so there is no `up` series for it at all (an "`up == 0`" you see must belong to a *different*, still-active target/instance, or the panel is showing a stale/other series). For a given finalized address the two are mutually exclusive: a target is either kept (and then scraped, producing `up` = 0 or 1) *or* dropped (and never scraped, producing no `up`). A target cannot be simultaneously dropped and scraped.

</details>