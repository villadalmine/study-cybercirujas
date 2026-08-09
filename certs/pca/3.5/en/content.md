# 3.5 Service Discovery

> **Domain:** Prometheus Fundamentals — Configuration and Scraping
> **Exam weight:** 3
> **Level:** Advanced (SRE / Platform Architect)

---

## 1. The production problem: pull-based monitoring on ephemeral infrastructure

Prometheus is a **pull** system. The server initiates every scrape by opening an HTTP connection to a target's `/metrics` endpoint. This design decision — deliberate and central to Prometheus's operational model — creates a hard requirement that has no equivalent in push systems: **Prometheus must know the address of every target before it can collect a single sample.**

On a fleet of pet servers with fixed hostnames this is trivial. You write them into the config once and forget. But the environments where Prometheus is actually deployed — Kubernetes clusters, cloud auto-scaling groups, Nomad jobs, Consul service meshes — share a property that breaks that assumption completely:

- **Targets are ephemeral.** A Pod's IP is assigned at scheduling time, lives for the Pod's lifetime, and is recycled seconds after it dies. A `Deployment` rollout replaces every IP. An HPA scale-up event creates ten new targets with ten new addresses in under a minute.
- **Cardinality of *targets* is dynamic.** The set of things to scrape is a function of cluster state, not of a config file. You cannot enumerate it ahead of time because it did not exist ahead of time.
- **Identity ≠ address.** The address (`10.244.3.17:8080`) is an implementation detail that changes constantly. The *identity* the SRE cares about (`job="checkout"`, `namespace="payments"`, `pod="checkout-7d9f…"`) must survive the churn. Time series continuity depends on stable labels, not stable IPs.

A `static_configs` block cannot express any of this. If you hardcode Pod IPs, every rollout silently breaks monitoring: half your targets go `down`, your `up == 0` alerts fire (correctly, then incorrectly), and the actual replacements are invisible because nothing told Prometheus they exist.

**Service Discovery (SD)** is the subsystem that resolves this. It continuously queries an authoritative source of truth about the infrastructure (the Kubernetes API, the Consul catalog, an EC2 `DescribeInstances` call, a file on disk) and produces a live, self-updating list of targets — each decorated with rich metadata. **Relabeling** is the companion mechanism that transforms that raw metadata into the final scrape configuration: which targets to keep, what address to hit, what path and scheme to use, and what identity labels each series will carry.

The architectural insight to internalize: in Prometheus, **the scrape configuration is computed, not declared.** SD provides the raw material; relabeling is the program that turns it into targets. Master relabeling and you master service discovery — every SD mechanism funnels through the same relabeling pipeline.

### The discovery → relabel → scrape lifecycle

```
┌──────────────────┐   discovered      ┌──────────────────┐   final       ┌───────────┐
│  SD mechanism    │   targets +       │  relabel_configs │   target set  │  Scrape   │
│ (k8s, consul,    │──  __meta_* ─────▶│  (keep/drop/     │────────────▶ │  manager  │
│  file, dns, ec2) │   labels          │   replace/…)     │   __address__ │           │
└──────────────────┘                   └──────────────────┘   + labels    └───────────┘
        ▲                                                                        │
        │ periodic refresh                                                       │ GET /metrics
        │ (watch / poll)                                                         ▼
   source of truth                                                       ┌──────────────────┐
   (API server, catalog…)                                               │ metric_relabel_   │
                                                                          │ configs (per      │
                                                                          │ sample, post-scrape)│
                                                                          └──────────────────┘
```

Two relabeling stages, often confused, at opposite ends of the pipeline:

| Stage | Runs | Operates on | Purpose |
|---|---|---|---|
| `relabel_configs` | **Before** the scrape, on the target's `__meta_*` label set | Target labels | Select targets (`keep`/`drop`), set `__address__`/`__scheme__`/`__metrics_path__`, attach identity labels |
| `metric_relabel_configs` | **After** the scrape, on every ingested sample | Series labels | Drop noisy series, rewrite labels, control cardinality |

This document is about the first stage. `metric_relabel_configs` is covered under exposition/cardinality.

---

## 2. Service Discovery mechanisms: technical comparison

Prometheus ships ~20 built-in SD integrations. All feed the same relabeling pipeline; they differ in the *source of truth*, the *refresh model* (watch vs. poll), and the `__meta_*` labels they expose.

| Mechanism | Config key | Refresh model | Source of truth | Typical use | Auth surface |
|---|---|---|---|---|---|
| **Static** | `static_configs` | None (config reload only) | The config file itself | Prometheus self-scrape, fixed exporters, node exporter on bare metal | none |
| **File** | `file_sd_configs` | Poll (inotify + `refresh_interval` fallback, default 5m) | JSON/YAML files on disk | Glue layer for anything scriptable; CMDBs; custom controllers | file perms |
| **Kubernetes** | `kubernetes_sd_configs` | **Watch** (streaming, near-real-time) | Kubernetes API server | The dominant case: Pods, Services, Endpoints, Nodes, Ingresses | ServiceAccount / kubeconfig |
| **Consul** | `consul_sd_configs` | Watch (blocking queries) | Consul catalog | Service-mesh & VM fleets registered in Consul | ACL token |
| **DNS** | `dns_sd_configs` | Poll (`refresh_interval`, default 30s) | DNS `A`/`AAAA`/`SRV` records | Headless Services, legacy service registries exposing DNS | none |
| **EC2 / Azure / GCE** | `ec2_sd_configs`, … | Poll (default 60s) | Cloud provider API | VM fleets / ASGs outside Kubernetes | IAM / SP credentials |
| **HTTP** | `http_sd_configs` | Poll (`refresh_interval`, default 60s) | Any HTTP endpoint returning target JSON | Generic integration with custom infra APIs | bearer/basic/mTLS |

### Watch vs. poll — the latency trade-off that matters in production

The single most important operational difference is **how fast a new target becomes scrapable**:

| Property | Watch-based (Kubernetes, Consul) | Poll-based (File*, DNS, EC2, HTTP) |
|---|---|---|
| New-target latency | Sub-second to a few seconds | Up to one `refresh_interval` |
| Load on source of truth | One long-lived stream/connection | One request every interval × every Prometheus |
| Behaviour under source outage | Serves last-known state; reconnects | Serves last-known state; retries next tick |
| Thundering herd risk | Low (streaming) | Real — many Prometheis polling the same API | 
| Tuning knob | none needed | `refresh_interval` (latency vs. load) |

\* File SD is poll-based on paper but uses inotify, so on a local filesystem it reacts to file writes almost immediately; `refresh_interval` is the safety net for filesystems where inotify is unreliable (NFS).

**Rule of thumb:** prefer watch-based SD wherever the source of truth supports it. Reserve poll-based SD for sources that only expose a request/response API, and treat `refresh_interval` as a load-vs-freshness dial, not a default to ignore.

---

## 3. Complete, production manifests

### 3.1 Kubernetes RBAC for Prometheus SD

Kubernetes SD requires the Prometheus ServiceAccount to have **read access to the objects it discovers**. This is the single most common cause of "no targets" in a fresh install — SD silently discovers nothing because the API returns `403`. Grant exactly the verbs SD uses (`get`, `list`, `watch`), no more.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/metrics      # required to proxy /metrics through the kubelet
      - nodes/proxy
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources:
      - endpointslices    # for role: endpointslice
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses         # for role: ingress
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: monitoring
```

### 3.2 `prometheus.yml` — the canonical Kubernetes scrape configuration

This is the reference configuration every production Prometheus derives from. Read the `relabel_configs` line by line — they *are* the service discovery logic.

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: prod-eu-west-1
    replica: "0"

scrape_configs:

  # ── Job 1: Prometheus scraping itself (static — the base case) ──────────────
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # ── Job 2: Kubernetes API servers (endpoints of the default/kubernetes svc) ─
  - job_name: kubernetes-apiservers
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      # Keep ONLY the endpoints of the apiserver Service (default/kubernetes:https)
      - source_labels:
          - __meta_kubernetes_namespace
          - __meta_kubernetes_service_name
          - __meta_kubernetes_endpoint_port_name
        action: keep
        regex: default;kubernetes;https

  # ── Job 3: Kubelets — cAdvisor + node metrics via the API server proxy ──────
  - job_name: kubernetes-nodes
    kubernetes_sd_configs:
      - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      # Promote every node label to a series label (node_label_* → *)
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      # Rewrite the target to hit the API server, then proxy to the kubelet.
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics

  # ── Job 4: Pods, opt-in via annotations (the classic auto-discovery job) ────
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 1. Opt-in: scrape only pods annotated prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true

      # 2. Override the scrape scheme if prometheus.io/scheme is set (http|https)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)

      # 3. Override the metrics path if prometheus.io/path is set
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # 4. Override the port: combine pod IP with prometheus.io/port
      #    __address__ arrives as "<ip>:<declared-container-port>"; we rewrite it.
      - source_labels:
          - __address__
          - __meta_kubernetes_pod_annotation_prometheus_io_port
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      # 5. Promote all pod labels to series labels
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)

      # 6. Attach stable identity labels
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node

  # ── Job 5: Services via their Endpoints (scrapes the backing pods) ──────────
  - job_name: kubernetes-service-endpoints
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels:
          - __address__
          - __meta_kubernetes_service_annotation_prometheus_io_port
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
```

**Key subtleties an interviewer (and the exam) probes:**

- **`role: endpoints` scrapes Pods, not the Service VIP.** Discovering via `role: service` would scrape the Service ClusterIP, which load-balances across replicas — you'd get metrics from *a random replica each scrape*, destroying per-instance time series. `role: endpoints` (or `endpointslice`) enumerates the actual backing Pods, giving one target per replica. This is why the "service" job above uses `role: endpoints`, not `role: service`.
- **The double-underscore labels are the control plane.** `__address__`, `__scheme__`, `__metrics_path__`, and `__param_<name>` are *magic* labels consumed by the scrape manager and then discarded. Any label starting with `__` is dropped before ingestion unless you explicitly copy it. That is why identity labels (`namespace`, `pod`, …) must be `replace`d out of `__meta_*` — the `__meta_*` originals never reach storage.
- **`labelmap` copies, it does not filter.** It's how you turn arbitrary Kubernetes labels into series labels wholesale. Beware cardinality: promoting *every* pod label can inject high-cardinality labels (e.g. `pod-template-hash`) you don't want.

### 3.3 File-based SD — the universal escape hatch

File SD decouples target production from Prometheus. Any process — a cron job, a CMDB exporter, a custom controller — writes JSON/YAML target files; Prometheus watches the directory and reloads within milliseconds (inotify), or at `refresh_interval` as a fallback.

`prometheus.yml` fragment:

```yaml
  - job_name: file-sd-blackbox
    file_sd_configs:
      - files:
          - /etc/prometheus/file_sd/*.json
          - /etc/prometheus/file_sd/*.yml
        refresh_interval: 5m        # inotify handles fast changes; this is the safety net
    relabel_configs:
      - source_labels: [env]
        target_label: environment
```

Target file `/etc/prometheus/file_sd/edge-routers.json` (written by your automation):

```json
[
  {
    "targets": ["10.20.0.11:9100", "10.20.0.12:9100"],
    "labels": {
      "job": "node",
      "env": "prod",
      "region": "eu-west-1",
      "role": "edge-router"
    }
  },
  {
    "targets": ["10.30.0.5:9100"],
    "labels": {
      "job": "node",
      "env": "staging",
      "region": "eu-west-1"
    }
  }
]
```

The labels in the file become `__meta`-equivalent target labels directly (plus `__meta_filepath` pointing at the source file, useful for debugging which file produced a target). Because the format is trivial and language-agnostic, file SD is the recommended path for any source Prometheus doesn't natively support.

### 3.4 Consul SD

```yaml
  - job_name: consul-services
    consul_sd_configs:
      - server: consul.service.consul:8500
        token_file: /etc/prometheus/consul-token
        # Restrict to specific services; omit to discover everything (rarely wise)
        services: ["checkout", "payments", "inventory"]
    relabel_configs:
      # Only keep instances tagged for scraping
      - source_labels: [__meta_consul_tags]
        regex: .*,metrics,.*
        action: keep
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_node]
        target_label: instance
      - source_labels: [__meta_consul_dc]
        target_label: datacenter
```

Note the `__meta_consul_tags` pattern: Consul tags arrive as a single string joined and wrapped by the tag separator (default `,`), so the regex matches `,metrics,` in the middle — this reliably matches a whole tag rather than a substring of another tag.

### 3.5 DNS SD (headless Services, SRV records)

```yaml
  - job_name: dns-srv-cassandra
    dns_sd_configs:
      - names:
          - _prometheus._tcp.cassandra.prod.svc.cluster.local
        type: SRV
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__meta_dns_name]
        target_label: dns_srv_record
```

With `type: SRV`, Prometheus reads both host and port from the SRV record. With `type: A`/`AAAA` you must set the port via a `port:` field, because A records carry no port.

---

## 4. CLI verification and live inspection

### 4.1 Validate config before it ever reaches the server

`promtool` catches syntactic and semantic config errors offline. Never reload a Prometheus with an unvalidated config in production — a bad reload can leave the server running the *old* config while you believe it took the new one.

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
 SUCCESS: 2 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/rules/node.yml
 SUCCESS: 14 rules found

Checking /etc/prometheus/rules/k8s.yml
 SUCCESS: 31 rules found
```

A malformed relabel action is caught here, not at runtime:

```console
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  FAILED: parsing YAML file /etc/prometheus/prometheus.yml: unknown relabel action "kepp"
```

### 4.2 Trigger a live config reload (no restart)

```console
$ curl -sf -X POST http://localhost:9090/-/reload && echo "reloaded"
reloaded
```

(Requires `--web.enable-lifecycle`. Confirm the reload actually took effect via `prometheus_config_last_reload_successful == 1` and `prometheus_config_last_reload_success_timestamp_seconds`.)

```console
$ curl -s 'http://localhost:9090/api/v1/query?query=prometheus_config_last_reload_successful' \
    | jq -r '.data.result[0].value[1]'
1
```

### 4.3 Inspect active targets — the ground truth of SD

The `/api/v1/targets` API is the authoritative view of what SD produced. `discoveredLabels` shows the raw `__meta_*` set *before* relabeling; `labels` shows the final set *after*. Diffing them is how you debug relabeling.

```console
$ curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[0]'
{
  "discoveredLabels": {
    "__address__": "10.244.3.17:8080",
    "__meta_kubernetes_namespace": "payments",
    "__meta_kubernetes_pod_annotation_prometheus_io_scrape": "true",
    "__meta_kubernetes_pod_annotation_prometheus_io_port": "9102",
    "__meta_kubernetes_pod_container_port_number": "8080",
    "__meta_kubernetes_pod_name": "checkout-7d9f6c8b4d-x2klq",
    "__meta_kubernetes_pod_node_name": "ip-10-0-3-14.eu-west-1.compute.internal",
    "__meta_kubernetes_pod_label_app": "checkout",
    "__metrics_path__": "/metrics",
    "__scheme__": "http",
    "job": "kubernetes-pods"
  },
  "labels": {
    "app": "checkout",
    "instance": "10.244.3.17:9102",
    "job": "kubernetes-pods",
    "namespace": "payments",
    "node": "ip-10-0-3-14.eu-west-1.compute.internal",
    "pod": "checkout-7d9f6c8b4d-x2klq"
  },
  "scrapePool": "kubernetes-pods",
  "scrapeUrl": "http://10.244.3.17:9102/metrics",
  "globalUrl": "http://10.244.3.17:9102/metrics",
  "lastError": "",
  "lastScrape": "2026-08-08T10:42:11.884Z",
  "lastScrapeDuration": 0.021344,
  "health": "up"
}
```

Read the story in that object: SD discovered the Pod at `:8080` (its container port), the `prometheus.io/port: "9102"` annotation triggered the `__address__` rewrite to `:9102`, and the final `instance` reflects the rewritten address. Everything checks out — `health: up`.

Filter to just the unhealthy ones during an incident:

```console
$ curl -s http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[]
             | select(.health!="up")
             | "\(.health)\t\(.scrapeUrl)\t\(.lastError)"'
down    http://10.244.5.9:9102/metrics    Get "http://10.244.5.9:9102/metrics": dial tcp 10.244.5.9:9102: connect: connection refused
down    http://10.244.2.3:9102/metrics    context deadline exceeded
```

### 4.4 See what SD *dropped* — the invisible half

Targets removed by a `drop`/`keep` relabel rule appear as `droppedTargets`, not `activeTargets`. This is where "my Pod exists but isn't being scraped and there's no error anywhere" is solved: it was dropped by relabeling, so it never became a target and never produced an error.

```console
$ curl -s 'http://localhost:9090/api/v1/targets?state=dropped' \
    | jq '.data.droppedTargets[0].discoveredLabels
          | {ns: .__meta_kubernetes_namespace,
             pod: .__meta_kubernetes_pod_name,
             scrape: .__meta_kubernetes_pod_annotation_prometheus_io_scrape}'
{
  "ns": "default",
  "pod": "nginx-6799fc88d8-7v9qz",
  "scrape": null
}
```

`scrape: null` → the Pod has no `prometheus.io/scrape` annotation → the `keep … regex: true` rule dropped it. Working as designed. (By default Prometheus keeps a bounded number of dropped targets in memory per pool; tune with `keep_dropped_targets` if you need to see more, or fewer to save memory in huge clusters.)

### 4.5 The web UI equivalents

- **`/targets`** — the human view of §4.3, grouped by scrape pool, with health, last scrape, and last error.
- **`/service-discovery`** — the human view of the discovered-vs-final label diff (§4.3/§4.4), including dropped targets and *which relabel action* dropped them. This is the single most useful page for debugging SD and relabeling.
- **`/config`** — the *effective* running config after the last successful reload; verify the server is actually running the config you think it is.

---

## 5. Failure diagnosis playbook

A disciplined decision tree, from "target totally absent" to "target present but broken." Work top-down — each rung assumes the ones above passed.

| Symptom | Where to look | Likely cause & fix |
|---|---|---|
| **Target not in `/targets` *or* `/service-discovery` at all** | Source of truth | SD isn't discovering it. RBAC `403` (check Prometheus logs for `Failed to watch …: forbidden`); wrong `role`; namespace/label selector excludes it; object genuinely absent (`kubectl get endpoints -n <ns>`). |
| **Target appears under `droppedTargets` / greyed in `/service-discovery`** | `relabel_configs` | A `keep`/`drop` rule removed it. The `/service-discovery` page names the offending action. Usually a missing/mismatched annotation (`prometheus.io/scrape != "true"`). |
| **`health: down`, error `connection refused`** | The target itself | Nothing listening on that address:port. Wrong port in relabeling; exporter crashed; `prometheus.io/port` annotation points at the wrong port. `kubectl exec` + `curl localhost:<port>/metrics`. |
| **`health: down`, error `context deadline exceeded`** | Network / target latency | `scrape_timeout` too low for a slow `/metrics`; NetworkPolicy blocking Prometheus → Pod; overloaded target. Raise `scrape_timeout` (must be ≤ `scrape_interval`) or fix the network path. |
| **`health: down`, error `server returned HTTP status 401/403`** | Auth | Missing/expired bearer token or client cert; wrong `authorization`/`tls_config`. |
| **`health: down`, error `x509: certificate signed by unknown authority`** | TLS | Missing/incorrect `ca_file`, or `__scheme__` set to `https` against an HTTP endpoint. |
| **`health: up` but `instance` label wrong / duplicated series** | Relabeling of `__address__` | `__address__` not rewritten to the metrics port, so two jobs scrape the same Pod on two ports, or `instance` collides across replicas. |
| **New Pods take minutes to appear** | Refresh model | You're on a poll-based SD (DNS/EC2/HTTP) with a large `refresh_interval`; or you used `role: service` (VIP) instead of `role: endpoints`. |
| **`up` metric missing entirely for a job** | Job wiring | Job produced zero targets — the whole `keep` chain matched nothing. Check `count(up{job="X"})` and the `/service-discovery` page for that pool. |

### Worked example: "the Pod is running but not being scraped"

```console
# 1. Does SD see the Pod at all?  (search discovered labels for the pod name)
$ curl -s 'http://localhost:9090/api/v1/targets?state=any' \
    | jq -r '.data.activeTargets[].discoveredLabels.__meta_kubernetes_pod_name,
             .data.droppedTargets[].discoveredLabels.__meta_kubernetes_pod_name' \
    | grep checkout-7d9f6c8b4d-x2klq
checkout-7d9f6c8b4d-x2klq        # ← present, so RBAC & discovery are fine

# 2. Active or dropped?  It wasn't in activeTargets → it's dropped. Why?
$ kubectl get pod checkout-7d9f6c8b4d-x2klq -n payments \
    -o jsonpath='{.metadata.annotations}' | jq .
{
  "prometheus.io/port": "9102"
}
#    → prometheus.io/scrape is MISSING. The `keep … regex: true` rule dropped it.

# 3. Fix: add the opt-in annotation.
$ kubectl annotate pod checkout-7d9f6c8b4d-x2klq -n payments prometheus.io/scrape=true
pod/checkout-7d9f6c8b4d-x2klq annotated

# 4. Confirm it flipped to active (k8s SD is watch-based, so this is near-instant).
$ sleep 2; curl -s http://localhost:9090/api/v1/targets \
    | jq -r '.data.activeTargets[]
             | select(.labels.pod=="checkout-7d9f6c8b4d-x2klq")
             | .health'
up
```

The general principle: **`discoveredLabels` tells you what SD found; `labels` tells you what survived relabeling; the gap between them is your bug.** For persistent workloads, set the annotation on the Pod template in the `Deployment`, not on the live Pod (which is recreated on rollout).

### Meta-monitoring you should always have

```promql
# Any target down, grouped by job — the canonical scrape-health alert.
sum by (job) (up == 0)

# SD produced fewer targets than expected for a critical job.
count(up{job="kubernetes-pods"}) < 3

# Config reload failed — you may be running stale config.
prometheus_config_last_reload_successful == 0

# Scrapes routinely exceed their timeout budget.
scrape_duration_seconds > scrape_timeout_seconds  # via the scrape's own timeout
```

---

## Referencias

- Configuration reference (`scrape_config`, all `*_sd_config` blocks): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- `kubernetes_sd_config` (roles and `__meta_kubernetes_*` labels): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config
- `relabel_config` (actions, `source_labels`, regex, defaults): https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- `file_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config
- `consul_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#consul_sd_config
- `dns_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#dns_sd_config
- `ec2_sd_config`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#ec2_sd_config
- File-based service discovery guide: https://prometheus.io/docs/guides/file-sd/
- HTTP API — `/api/v1/targets`: https://prometheus.io/docs/prometheus/latest/querying/api/#targets
- Relabeling concepts guide: https://prometheus.io/docs/prometheus/latest/configuration/relabeling/
- `promtool` management: https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- Kubernetes RBAC (verbs, ClusterRole): https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- CNCF PCA curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf