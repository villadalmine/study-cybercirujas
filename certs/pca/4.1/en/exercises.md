# PCA — Topic 4.1: Dashboarding Basics

## Guided Exercises

> **Scenario.** You run Prometheus in production but stakeholders keep asking "is the box healthy?" over Slack. In this lab you build the visualization layer end to end: from Prometheus' own expression browser, to a Grafana time series panel, to a templated dashboard, to dashboards-as-code. You finish with the legacy Prometheus console templates so you recognize them in the field.
>
> **Prerequisites:** Docker + Docker Compose v2, ports `3000`, `9090`, `9100` free. ~15 minutes.

### Lab setup

Create a working directory and these files.

**`prometheus.yml`**

```yaml
global:
  scrape_interval: 15s        # feeds $__rate_interval later; remember this number

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: node
    static_configs:
      - targets: ["node_exporter:9100"]   # container DNS name, not localhost
```

**`docker-compose.yml`**

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.53.0
    container_name: prometheus
    ports: ["9090:9090"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./consoles:/etc/prometheus/consoles:ro
      - ./console_libraries:/etc/prometheus/console_libraries:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.console.templates=/etc/prometheus/consoles
      - --web.console.libraries=/etc/prometheus/console_libraries
      - --web.enable-lifecycle

  node_exporter:
    image: prom/node-exporter:v1.8.1
    container_name: node_exporter
    ports: ["9100:9100"]

  grafana:
    image: grafana/grafana:11.1.0
    container_name: grafana
    ports: ["3000:3000"]
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
```

Create the directories that the volumes expect (empty for now):

```bash
mkdir -p consoles console_libraries grafana/provisioning/datasources \
         grafana/provisioning/dashboards grafana/dashboards
docker compose up -d
```

Expected:

```
[+] Running 4/4
 ✔ Network dashboards_default  Created
 ✔ Container node_exporter     Started
 ✔ Container prometheus        Started
 ✔ Container grafana           Started
```

---

## Exercise 1 — The Prometheus expression browser

The cheapest dashboard is the one Prometheus already ships. Before Grafana, learn to read the built-in UI.

1. Open `http://localhost:9090/graph`.
2. In the query box type `up` and press **Execute**. Stay on the **Table** tab. You should see one row per scrape target:

   ```
   up{instance="localhost:9090", job="prometheus"}   1
   up{instance="node_exporter:9100", job="node"}     1
   ```
3. Switch to the **Graph** tab. Notice `up` renders as flat lines at `1`. Instant values become a line because Prometheus draws one point per step across the selected time range.
4. Replace the query with a **counter** and try to graph it raw:

   ```promql
   node_cpu_seconds_total{mode="idle"}
   ```

   On the Graph tab you get monotonically rising lines — not useful.
5. Now wrap it in `rate()` over a range vector and Execute again:

   ```promql
   rate(node_cpu_seconds_total{mode="idle"}[5m])
   ```

   You now get one line per CPU core hovering near `~1` (idle seconds accrued per second per core).
6. On the Graph tab, change the range control from `1h` to `15m`, then click the **Res. (s)** field and set an explicit resolution (step) of `15`. Re-run and watch the line get denser.
7. Confirm the same data over the HTTP API (this is exactly what a dashboard tool calls under the hood):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq
   ```

   ```json
   {
     "status": "success",
     "data": {
       "resultType": "vector",
       "result": [
         { "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
           "value": [ 1723130400, "1" ] },
         { "metric": { "__name__": "up", "instance": "node_exporter:9100", "job": "node" },
           "value": [ 1723130400, "1" ] }
       ]
     }
   }
   ```

**Comprehension check 1**

- **1a.** On the **Table** tab you can only display an *instant vector*, never a *range vector* like `node_cpu_seconds_total[5m]`. Why?
- **1b.** Why did step 5 need `rate(...[5m])` instead of graphing the counter directly?
- **1c.** In step 7, which two API endpoints back the Table tab and the Graph tab respectively, and what is the structural difference in their responses?

---

## Exercise 2 — Add Prometheus as a Grafana data source

1. Open `http://localhost:3000` and log in with `admin` / `admin` (skip the password change).
2. Go to **Connections → Data sources → Add data source → Prometheus**.
3. Set **Prometheus server URL** to:

   ```
   http://prometheus:9090
   ```
4. Leave the connection mode at its default. Scroll down and click **Save & test**. You should see:

   ```
   ✔ Successfully queried the Prometheus API.
   ```
5. **Break it on purpose to learn the failure mode.** Change the URL to `http://localhost:9090` and **Save & test** again. It fails:

   ```
   ✗ Post "http://localhost:9090/api/v1/query": dial tcp 127.0.0.1:9090: connect: connection refused
   ```

   Restore it to `http://prometheus:9090`.
6. Now do the same thing **as code**. Delete the UI data source, then create **`grafana/provisioning/datasources/prometheus.yaml`**:

   ```yaml
   apiVersion: 1
   datasources:
     - name: Prometheus
       uid: prometheus            # stable uid so dashboards can reference it
       type: prometheus
       access: proxy              # Grafana backend proxies the request
       url: http://prometheus:9090
       isDefault: true
       jsonData:
         httpMethod: POST
         timeInterval: 15s        # MUST match scrape_interval; drives $__rate_interval
   ```
7. Reload Grafana and verify the provisioned source exists:

   ```bash
   docker compose restart grafana
   curl -s http://admin:admin@localhost:3000/api/datasources | jq '.[] | {name, uid, url}'
   ```

   ```json
   { "name": "Prometheus", "uid": "prometheus", "url": "http://prometheus:9090" }
   ```

**Comprehension check 2**

- **2a.** In step 5, Prometheus was clearly up (Exercise 1 proved it). Why did `http://localhost:9090` fail with `access: proxy`, and in which mode *would* `localhost` be the correct host?
- **2b.** A provisioned data source cannot be edited or deleted from the Grafana UI (the fields are greyed out). Why is that the intended behavior, and how do you change it?
- **2c.** What breaks in your dashboards if `jsonData.timeInterval` is left unset or set to `1s` instead of `15s`?

---

## Exercise 3 — Build your first Time series panel

1. Go to **Dashboards → New → New dashboard → Add visualization**. Choose the **Prometheus** data source.
2. In the query editor, switch to **Code** mode and enter:

   ```promql
   sum by (mode) (rate(node_cpu_seconds_total[$__rate_interval]))
   ```
3. In the **Legend** field of the query row, type:

   ```
   {{mode}}
   ```

   Each series is now labeled `idle`, `system`, `user`, `iowait`, … instead of the full metric string.
4. Confirm the panel type is **Time series** (top-right visualization picker).
5. On the right panel, set **Standard options → Unit → Time → seconds (s)** (CPU-seconds per second is a ratio, but this keeps hover values readable). Set **Graph styles → Stacking → Normal** to see the mode breakdown add up.
6. Change the query type from **Range** to **Instant** (the toggle in the query options row) and observe the panel: a time series panel with an instant query shows only the latest point. Switch it back to **Range**.
7. Click **Apply**, then **Save dashboard** as `Node CPU`.

**Comprehension check 3**

- **3a.** Why is `$__rate_interval` the recommended range for `rate()` inside a Grafana panel, rather than a hard-coded `[5m]`?
- **3b.** The legend format `{{mode}}` uses double curly braces. Is this PromQL syntax? Where is it evaluated?
- **3c.** You picked a **Time series** visualization. Name two other built-in visualizations and one metric shape each is better suited to than a time series.

---

## Exercise 4 — Dashboard variables (templating)

Hard-coded instances don't scale. Add a dropdown so one dashboard serves every node.

1. Open your `Node CPU` dashboard → **Settings (gear) → Variables → New variable**.
2. Configure:
   - **Select variable type:** `Query`
   - **Name:** `instance`
   - **Data source:** `Prometheus`
   - **Query type:** `Label values`
   - **Label:** `instance`
   - **Metric:** `node_cpu_seconds_total`

   The **Preview of values** at the bottom should show `node_exporter:9100`. (Under the hood this is the `label_values(node_cpu_seconds_total, instance)` function.)
3. Enable **Multi-value** and **Include All option**, then **Apply**.
4. Back on the dashboard, edit the panel query to filter by the variable:

   ```promql
   sum by (mode) (rate(node_cpu_seconds_total{instance=~"$instance"}[$__rate_interval]))
   ```

   Note the `=~` regex matcher — required because a multi-value variable expands to `node_exporter:9100|other:9100`.
5. Use the `instance` dropdown at the top of the dashboard to switch selection and watch the panel re-query.
6. Add a second, purely cosmetic variable to see the contrast: **New variable → Type: `Custom`**, name `threshold`, values `70,80,90`. This one never touches Prometheus.

**Comprehension check 4**

- **4a.** `label_values(node_cpu_seconds_total, instance)` — is this a PromQL function? If not, what is it and who evaluates it?
- **4b.** Why must the panel use `instance=~"$instance"` (regex) rather than `instance="$instance"` (equality) once Multi-value is enabled?
- **4c.** What is the practical difference between a `Query` variable and a `Custom` variable in terms of load on Prometheus?

---

## Exercise 5 — Provision a dashboard from JSON (dashboards-as-code)

Click-built dashboards are not reproducible. Ship them as files.

1. Create the provider **`grafana/provisioning/dashboards/default.yaml`**:

   ```yaml
   apiVersion: 1
   providers:
     - name: default
       orgId: 1
       folder: ''
       type: file
       disableDeletion: false
       updateIntervalSeconds: 10
       allowUiUpdates: false
       options:
         path: /var/lib/grafana/dashboards
   ```
2. Create the dashboard model **`grafana/dashboards/node-cpu.json`**:

   ```json
   {
     "uid": "node-cpu",
     "title": "Node CPU (provisioned)",
     "schemaVersion": 39,
     "editable": true,
     "time": { "from": "now-1h", "to": "now" },
     "templating": {
       "list": [
         {
           "name": "instance",
           "type": "query",
           "datasource": { "type": "prometheus", "uid": "prometheus" },
           "query": { "query": "label_values(node_cpu_seconds_total, instance)", "refId": "StandardVariableQuery" },
           "includeAll": true,
           "multi": true
         }
       ]
     },
     "panels": [
       {
         "type": "timeseries",
         "title": "CPU usage by mode",
         "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
         "datasource": { "type": "prometheus", "uid": "prometheus" },
         "targets": [
           {
             "refId": "A",
             "expr": "sum by (mode) (rate(node_cpu_seconds_total{instance=~\"$instance\"}[$__rate_interval]))",
             "legendFormat": "{{mode}}"
           }
         ]
       }
     ]
   }
   ```
3. Restart Grafana so the provider picks up the files:

   ```bash
   docker compose restart grafana
   ```
4. Confirm the dashboard was loaded from disk (note `provisioned: true`):

   ```bash
   curl -s http://admin:admin@localhost:3000/api/dashboards/uid/node-cpu \
     | jq '{title: .dashboard.title, provisioned: .meta.provisioned}'
   ```

   ```json
   { "title": "Node CPU (provisioned)", "provisioned": true }
   ```
5. Open it at `http://localhost:3000/d/node-cpu`. Notice the datasource is bound by **`uid: prometheus`** — the same uid you pinned in Exercise 2. If the uids didn't match, the panel would render **"Datasource prometheus was not found."**

**Comprehension check 5**

- **5a.** Why did the panel JSON reference the data source by `uid`, and why does pinning `uid: prometheus` in the *data source* provisioning file matter for portability across environments?
- **5b.** With `disableDeletion: false` and `allowUiUpdates: false`, what happens if a colleague edits this dashboard in the UI and clicks Save?
- **5c.** The panel JSON contains no numeric IDs and no `version` field, yet Grafana accepts it. Why is `uid` the field that actually matters for provisioning idempotency?

---

## Exercise 6 — (Advanced / legacy) Prometheus console templates

Before Grafana was ubiquitous, Prometheus served its own HTML dashboards via Go templates. You will still meet these on older stacks; the PCA expects you to recognize them.

1. Create **`consoles/hello.html`** — a self-contained template that calls the `query` function server-side:

   ```html
   <!DOCTYPE html>
   <html>
   <head><title>Targets up</title></head>
   <body>
     <h1>Targets currently up</h1>
     <table border="1" cellpadding="4">
       <tr><th>job</th><th>instance</th><th>up</th></tr>
       {{ range query "up" }}
       <tr>
         <td>{{ .Labels.job }}</td>
         <td>{{ .Labels.instance }}</td>
         <td>{{ .Value }}</td>
       </tr>
       {{ end }}
     </table>
     <p>Rendered by Prometheus at <code>{{ .Path }}</code></p>
   </body>
   </html>
   ```
2. The compose file already mounts `./consoles` and sets `--web.console.templates=/etc/prometheus/consoles`. Recreate Prometheus so it sees the new file:

   ```bash
   docker compose up -d prometheus
   ```
3. Open `http://localhost:9090/consoles/hello.html`. Prometheus renders the table **on the server** by running the `up` query and iterating the result vector — no browser JavaScript, no Grafana.
4. Confirm the same via curl (you get finished HTML, not JSON):

   ```bash
   curl -s http://localhost:9090/consoles/hello.html | grep -A1 node_exporter
   ```
   ```
   <td>node_exporter:9100</td>
   <td>1</td>
   ```

**Comprehension check 6**

- **6a.** A Grafana panel and this console template both display the value of `up`, but the query executes in fundamentally different places. Contrast where and when each one runs the PromQL.
- **6b.** Why do the two `--web.console.*` flags exist as a pair, and what does `--web.console.libraries` normally provide that our minimal template deliberately avoids?
- **6c.** Given Grafana exists, name one legitimate operational situation where a server-rendered console template is still the pragmatic choice.

---

## Teardown

```bash
docker compose down -v
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1a.** The Table (Console) tab shows a single evaluation at one instant, so it can only render an **instant vector** (one sample per series). A range vector like `[5m]` is a *set* of samples per series over a window — it has no single value to place in a cell, and the UI rejects it (`Error executing query: invalid expression type "range vector"`). Range vectors are only legal as arguments to functions such as `rate()`, `increase()`, or `avg_over_time()`, which collapse them back to an instant vector.

**1b.** `node_cpu_seconds_total` is a **counter** — it only ever increases and resets to 0 on process restart. Its absolute value (millions of accumulated seconds) is meaningless on a graph; what you care about is the *per-second increase*. `rate(...[5m])` computes the per-second average rate of increase over the 5-minute window and is counter-reset aware, turning the ever-rising line into a readable "CPU-seconds per second per core" rate.

**1c.** The **Table** tab calls `/api/v1/query` (an *instant query*): the response `resultType` is `vector` and each series carries a single `value: [ts, "n"]`. The **Graph** tab calls `/api/v1/query_range` (a *range query* with `start`, `end`, `step`): the response `resultType` is `matrix` and each series carries a `values: [[ts,"n"], …]` array — one point per step, which is what makes a line.

### Exercise 2

**2a.** With `access: proxy` (the default, shown as "Server" in the UI), the **Grafana backend** makes the HTTP request. Inside the Grafana container, `localhost` is the Grafana container itself, which has nothing on `:9090`, so the connection is refused. The URL must be resolvable *from Grafana's network namespace* — hence the Docker DNS name `http://prometheus:9090`. `localhost` would only be correct in **direct/Browser** access mode, where the end user's browser issues the request (and even then only if Prometheus were published on the user's own machine, and CORS allowed it).

**2b.** Provisioned resources are declared as **code**, so Grafana treats the files as the source of truth and locks the UI to prevent drift between what's on disk and what's in the database. To change it you edit the provisioning YAML and reload Grafana (restart, or `docker compose restart grafana`) — not the UI.

**2c.** `timeInterval` is the data source's notion of the scrape interval and it feeds `$__rate_interval`. If unset, Grafana can't compute a safe rate window and may pick a range that yields fewer than the ~4 samples `rate()` needs, producing **gappy or empty graphs** at wide time ranges. Setting it to `1s` (a lie about the real 15s scrape) makes `$__rate_interval` far too small, so `rate()` frequently sees <2 samples in-window and returns no data.

### Exercise 3

**3a.** A hard-coded `[5m]` breaks at both extremes of zoom: zoom out far enough and 5 minutes is smaller than one pixel's step, causing aliasing/gaps; zoom in and 5m over-smooths. `$__rate_interval` is computed per render as roughly `max(4 × scrape_interval, $__interval + scrape_interval)`, guaranteeing at least ~4 samples in the window at any zoom level while staying as tight as possible. It adapts the rate window to the panel width and the data source's scrape interval automatically.

**3b.** No — `{{mode}}` is **not** PromQL. It is Grafana's **legend template**, interpolated by Grafana *after* the query returns, substituting the value of the `mode` label from each result series. PromQL never sees it.

**3c.** Examples (any two): **Stat** (a single current value / big number, e.g. `up` or current requests/s); **Gauge** or **Bar gauge** (a value against a threshold range, e.g. disk % used); **Table** (label-rich instant vectors you want to inspect row by row, e.g. per-target `up`); **Heatmap** (histogram/bucket data over time, e.g. request-latency distribution). Time series is for values that evolve over time as lines.

### Exercise 4

**4a.** It is **not** a PromQL function. `label_values()` is a **Grafana template/variable function** (part of the Prometheus data source in Grafana). It is evaluated by Grafana to populate the variable's dropdown — it queries the label API and returns the distinct values of a label. You cannot use it in a panel `expr`.

**4b.** A multi-value variable interpolates to an alternation string, e.g. `node_exporter:9100|db01:9100`. With equality (`instance="..."`) Prometheus looks for a single label literally equal to that pipe-joined string and matches nothing. The regex matcher `=~` treats the pipes as alternation, matching any of the selected instances (and the `All` option, which expands to `.*` or the full list).

**4c.** A **Query** variable runs a real query against Prometheus every time it refreshes (on load, on time-range change, or on interval, per its refresh setting), so it adds label-API load. A **Custom** variable is a static, hand-typed list stored in the dashboard JSON — it never touches Prometheus and has zero backend cost.

### Exercise 5

**5a.** Panels bind to a data source by **`uid`**, not by name, because names can differ or be duplicated across Grafana instances while a `uid` is a stable handle. By pinning `uid: prometheus` in the data source provisioning file, every environment (dev, staging, prod) exposes the *same* uid, so the identical dashboard JSON resolves its data source everywhere without edits. If you relied on auto-generated uids, the same JSON would show "Datasource not found" in a different environment.

**5b.** With `allowUiUpdates: false`, the UI Save is rejected/not persisted for provisioned dashboards — the file on disk remains the source of truth, and Grafana re-syncs from it on the next `updateIntervalSeconds` tick, discarding the UI change. (`disableDeletion: false` only governs whether the dashboard can be deleted, not edited.)

**5c.** Provisioning keys idempotency off **`uid`**. On each sync Grafana upserts the dashboard whose `uid` matches, replacing its contents — so re-applying the same file is a no-op and changing the file updates in place instead of creating duplicates. Numeric `id` and `version` are managed by Grafana's database and are intentionally omitted from provisioned JSON; supplying them would fight Grafana's own bookkeeping.

### Exercise 6

**6a.** The **Grafana panel** sends PromQL to Prometheus's HTTP API *at view time, from the client/browser session*; Prometheus returns JSON and Grafana renders it in the browser. The **console template** runs the PromQL *inside the Prometheus server itself*, at the moment the page is requested, via the Go-template `query` function; Prometheus returns finished HTML. One is client-driven and API-based; the other is server-side rendered with no separate tool and no browser-side querying.

**6b.** `--web.console.templates` points at the directory of `.html` templates to serve under `/consoles/`; `--web.console.libraries` points at reusable template fragments and JS helpers (the `prom_*` head/menu/graph partials and `prometheus.js` graphing widget) that richer consoles `{{ template ... }}` into their pages. Our minimal template writes raw HTML and only uses the `query` function, so it needs no libraries — which is why it renders even with an empty `console_libraries` directory.

**6c.** Any one of: a **minimal, dependency-free status page** on a locked-down host where you can't run or reach a separate Grafana; a **quick internal read-only view** rendered directly by Prometheus with no extra service to operate, authenticate, or patch; or an **air-gapped/embedded appliance** where adding Grafana is disproportionate to the need. The trade-off is no rich interactivity and a template feature the project treats as legacy.

</details>

---

### Sources

- Prometheus — Expression browser & visualization: https://prometheus.io/docs/visualization/browser/
- Prometheus — Querying basics (instant vs range vectors): https://prometheus.io/docs/prometheus/latest/querying/basics/
- Prometheus — HTTP API (`/api/v1/query`, `/api/v1/query_range`): https://prometheus.io/docs/prometheus/latest/querying/api/
- Prometheus — Console templates & template examples: https://prometheus.io/docs/visualization/consoles/ · https://prometheus.io/docs/prometheus/latest/configuration/template_examples/
- Grafana — Prometheus data source & query editor (`$__rate_interval`): https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Grafana — Provisioning data sources and dashboards: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Grafana — Variables and templating (`label_values`, multi-value): https://grafana.com/docs/grafana/latest/dashboards/variables/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum