# 5.1 Analyzing Network Health Using Metrics

## 1. Why metrics are the first tool for network incidents

Network problems in Kubernetes rarely look like network problems when they start. The on-call engineer sees symptoms like these:

- *"Checkout p99 latency doubled, but CPU and memory are flat."*
- *"Pods on one node time out when they resolve names. Everywhere else is fine."*
- *"New connections fail about 1% of the time, but only at peak traffic."*
- *"Since the CNI upgrade, some Service calls hang for exactly 5 seconds."*

Each of these has a different root cause at a different layer:

| Symptom | Possible root cause | Layer |
|---|---|---|
| p99 latency up | TCP retransmissions from a lossy NIC or an oversubscribed uplink | L1–L4 on the node |
| DNS timeouts on one node | conntrack table full, so UDP/53 packets are dropped silently | Kernel netfilter |
| ~1% of connects fail | SYN backlog overflow (`ListenOverflows`) on the backend | Kernel TCP stack |
| 5 s hangs | DNS over UDP losing packets (the conntrack race on parallel A/AAAA queries), so the resolver retries after its 5 s timeout | Kernel + resolver |
| Calls fail after a CNI change | eBPF policy drops (`Policy denied`) or stale Service programming | CNI dataplane |

`kubectl logs` shows none of these. `kubectl top` does not report network at all. Packet captures show the truth, but they are expensive, local to one node, and only useful once you know **where** to look. Metrics tell you where to look. A well-built metrics pipeline answers three questions in under a minute:

1. **Is the network actually the problem?** (as opposed to the app, storage or CPU throttling)
2. **Which layer?** NIC, kernel stack, conntrack, CNI dataplane, Service proxy, DNS, or L7 gateway.
3. **Which scope?** One node, one pod, one namespace, or the whole cluster.

The CKNE expects you to find the right signal source, write correct PromQL over it, know the typical failure signatures, and fix the scrape pipeline itself when it is the thing that is broken.

---

## 2. Where network metrics come from

Network signals come from different components, and each one sees a different part of the path. Knowing which component exports what matters more than memorizing metric names.

```
            ┌────────────────────────────────────────────────────────────┐
  L7        │ Gateway / Envoy  (envoy_cluster_upstream_*, envoy_http_*)  │
            ├────────────────────────────────────────────────────────────┤
  DNS       │ CoreDNS :9153    (coredns_dns_*, coredns_forward_*)        │
            ├────────────────────────────────────────────────────────────┤
  Service   │ kube-proxy :10249 (kubeproxy_sync_proxy_rules_*)           │
  dataplane │   — or — Cilium agent :9962 (cilium_*), Hubble :9965       │
            ├────────────────────────────────────────────────────────────┤
  Pod netns │ kubelet/cAdvisor  (container_network_*)                    │
            ├────────────────────────────────────────────────────────────┤
  Kernel    │ node_exporter :9100 (node_netstat_*, node_nf_conntrack_*,  │
  + NIC     │   node_network_*, node_softnet_*, node_sockstat_*)         │
            └────────────────────────────────────────────────────────────┘
```

| Source | Default endpoint | What it sees | Blind spots |
|---|---|---|---|
| **node_exporter** | `:9100/metrics` (DaemonSet, `hostNetwork`) | Physical/virtual interfaces, TCP/UDP counters from `/proc/net/netstat` and `/proc/net/snmp`, conntrack usage, softirq backlog drops | No pod or Service identity. Only interfaces and counters. |
| **cAdvisor** (inside kubelet) | `https://<node>:10250/metrics/cadvisor` | Bytes, packets, errors and drops per **pod** network namespace | No L4 detail. No drop reason. Host-network pods look like the node. |
| **CoreDNS** `prometheus` plugin | `:9153/metrics` | Queries, rcodes, latency histograms, cache and upstream health | Cannot see queries that never reached it (dropped on the way) |
| **kube-proxy** | `127.0.0.1:10249/metrics` (loopback by default) | How long and how often rules are synced, network programming latency | Does not see packets at all, only the control loop |
| **Cilium agent** | `:9962/metrics` (when enabled) | eBPF drops **with a reason**, forwards, BPF map pressure, policy, endpoint state | Only when Cilium is the CNI |
| **Hubble metrics** | `:9965/metrics` (when enabled) | Flow-derived L3–L7 metrics: drops, DNS, TCP flags, HTTP, with workload labels | Cardinality cost. Only the metrics you enable. |
| **Envoy** (Gateway API data plane) | admin `/stats/prometheus` | Upstream connection failures, timeouts, retries, 5xx | Only traffic that goes through the gateway |

**Design rule:** correlate across at least two layers before you conclude anything. A spike in `cilium_drop_count_total{reason="Policy denied"}` together with a rise in `coredns_dns_requests_total` retries is a policy regression. The same drop spike with flat DNS traffic may just be a port scanner hitting a default-deny namespace.

---

## 3. Methodology: USE, RED, and counter semantics

### 3.1 Choosing the right lens

| Method | Apply to | Signals | Network example |
|---|---|---|---|
| **USE** (Utilization, Saturation, Errors) | *Resources*: NICs, conntrack table, BPF maps, socket backlogs | Utilization %, queue depth or overflow, error counters | conntrack entries/limit, `softnet` squeezes, `rx_drop`, `ListenOverflows` |
| **RED** (Rate, Errors, Duration) | *Services*: CoreDNS, gateways, anything request-driven | Requests/s, error ratio, latency histogram | DNS QPS, SERVFAIL ratio, p99 DNS latency, Envoy 5xx ratio |
| **Golden signals** (Latency, Traffic, Errors, Saturation) | The user-facing edge | RED plus saturation | Gateway p99, bytes/s, 5xx, upstream connection pool overflow |

In practice you use RED to **detect** ("users are affected") and USE to **explain** ("because conntrack on node-7 is at 100%").

### 3.2 Counters, `rate()`, and why raw values mean nothing

Almost every network metric is a **monotonic counter** (the `_total` suffix). The raw value is meaningless: `node_network_receive_drop_total = 48213` tells you nothing until you know over what period. Always derive a rate:

| Function | Semantics | Use it for |
|---|---|---|
| `rate(x[5m])` | Per-second average over the window, extrapolated, counter-reset aware | Alerts, dashboards, recording rules |
| `irate(x[5m])` | Per-second rate from the **last two samples** in the window | Zoomed-in, volatile graphs. Never in alerts: it misses spikes between samples. |
| `increase(x[1h])` | `rate × window`: the approximate count over the window | "How many drops in the last hour?" Can return non-integers because of extrapolation. |
| `resets(x[1h])` | Number of counter resets | Finding exporter or agent restarts that confuse your analysis |

Practical rules:

- **The range window should be at least 4× the scrape interval.** With a 30 s scrape, `[2m]` is the minimum and `[5m]` is the safe default. With too short a window, `rate()` returns nothing when a sample is missed.
- **Apply `rate()` first, then aggregate.** `sum(rate(x[5m]))` is correct. `rate(sum(x)[5m:])` is wrong, because summing counters first hides the resets of individual series and creates false spikes.
- **Error ratios need the matching denominator.** Retransmitted segments divided by *sent* segments, dropped packets divided by *received* packets, SERVFAIL divided by *all responses*. An absolute rate of "10 drops/s" is noise on a 25 Gbit/s node and an emergency on a quiet one.
- **Latency comes from histograms**, and the aggregation must keep `le`:

```promql
histogram_quantile(
  0.99,
  sum by (le, server) (rate(coredns_dns_request_duration_seconds_bucket[5m]))
)
```

If you drop `le` from `sum by`, `histogram_quantile` returns nothing. Also, you cannot average percentiles across instances. Aggregate the buckets, then compute the quantile.

---

## 4. Building the pipeline

The reference stack is **kube-prometheus-stack** (Prometheus Operator + Prometheus + Alertmanager + node_exporter + kube-state-metrics + Grafana). The Operator introduces CRDs that turn scrape configuration into Kubernetes objects:

| CRD | Purpose | Selects |
|---|---|---|
| `ServiceMonitor` | Scrape the endpoints behind a Service | Services by label, a port by **name** |
| `PodMonitor` | Scrape pods directly (no Service needed) | Pods by label, a container port by name |
| `PrometheusRule` | Recording and alerting rules | Selected by the `Prometheus` object's `ruleSelector` |

### 4.1 kube-prometheus-stack values focused on networking

```yaml
# values-monitoring.yaml
# helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
#   -n monitoring --create-namespace -f values-monitoring.yaml
prometheus:
  prometheusSpec:
    scrapeInterval: 30s
    evaluationInterval: 30s
    retention: 15d
    # Pick up ServiceMonitors/PodMonitors/Rules from ANY namespace, with ANY labels.
    # The default (true) only selects objects labelled release=<helm release name>,
    # which is the most common reason a new ServiceMonitor is ignored.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        memory: 4Gi

prometheus-node-exporter:
  hostNetwork: true
  extraArgs:
    - --collector.netstat
    - --collector.conntrack
    - --collector.softnet
    - --collector.sockstat
    # Keep interfaces, but drop per-veth series from node_exporter: pods are covered by cAdvisor
    - --collector.netdev.device-exclude=^(veth.*|lxc.*|cali.*|lo)$
    - --collector.netclass.ignored-devices=^(veth.*|lxc.*|cali.*|lo)$

# Built-in scrape of CoreDNS (creates a Service in kube-system on port 9153)
coreDns:
  enabled: true
  service:
    port: 9153
    targetPort: 9153

# kube-proxy binds metrics to 127.0.0.1:10249 by default; see section 4.3
kubeProxy:
  enabled: true
  service:
    port: 10249
    targetPort: 10249

kubelet:
  enabled: true
  serviceMonitor:
    cAdvisor: true

grafana:
  enabled: true
  defaultDashboardsEnabled: true
```

### 4.2 A ServiceMonitor for CoreDNS (the explicit version)

If you do not rely on the chart's built-in `coreDns` block, for example on a cluster where the monitoring stack was installed differently, you write the ServiceMonitor yourself. In kubeadm clusters the `kube-dns` Service already exposes a port named `metrics` on 9153:

```
$ kubectl -n kube-system get svc kube-dns -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}{"/"}{.protocol}{"\n"}{end}'
dns	53/UDP
dns-tcp	53/TCP
metrics	9153/TCP
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: coredns
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: network-observability
spec:
  jobLabel: k8s-app
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: kube-dns
  endpoints:
    - port: metrics          # the Service port NAME, not the number
      interval: 15s
      scheme: http
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
      metricRelabelings:
        # Drop the Go runtime noise; keep only DNS and process health
        - sourceLabels: [__name__]
          regex: "go_(gc|memstats)_.*"
          action: drop
```

### 4.3 Exposing kube-proxy metrics

kube-proxy binds `metricsBindAddress` to `127.0.0.1:10249` by default, so Prometheus running in a pod cannot reach it. On kubeadm clusters the configuration lives in a ConfigMap:

```
$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E 'metricsBindAddress|mode'
metricsBindAddress: ""
mode: iptables
```

An empty value means the built-in default (`127.0.0.1:10249`). Change it to bind all interfaces, then roll the DaemonSet:

```
$ kubectl -n kube-system get cm kube-proxy -o yaml \
    | sed 's/metricsBindAddress: ""/metricsBindAddress: "0.0.0.0:10249"/' \
    | kubectl apply -f -
configmap/kube-proxy configured

$ kubectl -n kube-system rollout restart ds/kube-proxy
daemonset.apps/kube-proxy restarted

$ kubectl -n kube-system rollout status ds/kube-proxy
daemon set "kube-proxy" successfully rolled out
```

> **Trade-off:** `0.0.0.0:10249` exposes an unauthenticated endpoint on every node IP. Restrict it with host firewalling or a node-level network policy (Cilium `CiliumClusterwideNetworkPolicy` with `nodeSelector`), or bind it to the node's internal IP only. The endpoint is read-only but reveals the cluster topology.

### 4.4 Cilium and Hubble metrics

With Cilium as the CNI, and especially with kube-proxy replacement, the Service dataplane lives in eBPF and kube-proxy metrics do not exist. You enable the equivalents through Helm:

```yaml
# values-cilium-metrics.yaml
# helm upgrade cilium cilium/cilium -n kube-system --reuse-values -f values-cilium-metrics.yaml
prometheus:
  enabled: true              # cilium-agent on :9962
  serviceMonitor:
    enabled: true
    labels:
      app.kubernetes.io/part-of: network-observability
operator:
  prometheus:
    enabled: true            # cilium-operator on :9963
    serviceMonitor:
      enabled: true
hubble:
  enabled: true
  metrics:
    enableOpenMetrics: true  # needed for exemplars
    # Each entry is "<handler>[:<options>]". Every extra context label multiplies cardinality.
    enabled:
      - "dns:query;ignoreAAAA"
      - "drop:sourceContext=namespace;destinationContext=namespace"
      - "tcp"
      - "flow:sourceContext=namespace;destinationContext=namespace"
      - "port-distribution"
      - "icmp"
      - "httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: true
  relay:
    enabled: true
```

**Cardinality warning:** `labelsContext=source_ip,destination_ip` creates one series per IP pair and can generate millions of series in a busy cluster. Use `namespace` or `workload` contexts for metrics. For per-IP forensics use `hubble observe`, which queries a ring buffer and costs no TSDB storage.

### 4.5 Do not let your own NetworkPolicies blind you

In a default-deny cluster, Prometheus scrapes are just more traffic that must be allowed. A common self-inflicted outage: someone applies default-deny to `kube-system`, CoreDNS keeps serving (clients are allowed), but its `up` metric goes to 0 and every DNS alert goes silent.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape-coredns
  namespace: kube-system
spec:
  podSelector:
    matchLabels:
      k8s-app: kube-dns
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9153
```

Remember that NetworkPolicies are additive. This policy only *adds* the scrape path. Existing policies that allow DNS on 53 from all namespaces keep working.

---

## 5. Metric catalog per layer, with PromQL

### 5.1 NIC and interface health (node_exporter)

| Metric | Meaning | Healthy |
|---|---|---|
| `node_network_receive_bytes_total` / `transmit_bytes_total` | Throughput per `device` | Below ~70% of link speed sustained |
| `node_network_receive_packets_total` / `transmit_packets_total` | Packet rate (denominator for ratios) | — |
| `node_network_receive_errs_total` / `transmit_errs_total` | CRC, frame and FIFO errors reported by the driver | ~0; any sustained value means hardware, cable or driver |
| `node_network_receive_drop_total` / `transmit_drop_total` | Packets dropped by the kernel or driver (ring buffer full, no protocol handler, etc.) | Very low ratio |
| `node_network_speed_bytes` | Negotiated link speed (bytes/s) | Matches the expected NIC speed |
| `node_network_up` | Operstate up (1) or not (0) | 1 for data interfaces |
| `node_network_carrier_changes_total` | Link flaps | Flat |
| `node_softnet_dropped_total` | Packets dropped because the per-CPU backlog (`netdev_max_backlog`) was full | 0 |
| `node_softnet_times_squeezed_total` | NAPI poll ran out of budget with work left (`netdev_budget`) | Low; rising means softirq CPU saturation |

Interface utilization (the USE *utilization* signal):

```promql
# Receive utilization of physical interfaces, 0..1
sum by (instance, device) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|lxc.*|cali.*|cilium.*|flannel.*|cni.*|vxlan.*|docker.*"}[5m]))
/
on (instance, device) node_network_speed_bytes > 0
```

The `> 0` filters out virtual devices that report speed `-1` or `0`, which would otherwise produce `+Inf` or negative values.

Receive drop ratio (the USE *errors* signal):

```promql
sum by (instance, device) (rate(node_network_receive_drop_total[5m]))
/
sum by (instance, device) (rate(node_network_receive_packets_total[5m]))
```

Softirq saturation (the USE *saturation* signal):

```promql
sum by (instance) (rate(node_softnet_dropped_total[5m])) > 0
or
sum by (instance) (rate(node_softnet_times_squeezed_total[5m])) > 50
```

How to read the combinations:

| Pattern | Likely cause | Next step |
|---|---|---|
| `rx_errs` rising, drops flat | Physical layer: cable, SFP, duplex mismatch | `ethtool -S <dev>`, check switch port counters |
| `rx_drop` rising, `softnet_dropped` flat | NIC ring buffer overflow | `ethtool -g <dev>`, raise the RX ring size |
| `softnet_dropped`/`times_squeezed` rising | One CPU handles all interrupts (no RSS/RPS), or softirq is starved | `/proc/interrupts`, IRQ affinity, RPS, `net.core.netdev_budget` |
| Carrier changes rising | Flapping link or bond member | Bond status, LACP, switch logs |

### 5.2 Kernel TCP/UDP stack and conntrack

| Metric | Meaning |
|---|---|
| `node_netstat_Tcp_RetransSegs` / `node_netstat_Tcp_OutSegs` | Retransmitted segments vs total sent |
| `node_netstat_TcpExt_TCPSynRetrans` | SYN retransmits: the *connection setup* is failing |
| `node_netstat_TcpExt_ListenOverflows` / `ListenDrops` | Accept queue full: the app is not calling `accept()` fast enough, or `somaxconn` is too low |
| `node_netstat_Tcp_OutRsts` | RSTs sent: refused connections, closed ports, aborted sockets |
| `node_netstat_Tcp_CurrEstab` | Established connections (gauge) |
| `node_netstat_Udp_RcvbufErrors` / `Udp_InErrors` | UDP socket buffer overflow, common on busy DNS or metrics receivers |
| `node_sockstat_TCP_tw` | Sockets in TIME_WAIT: ephemeral port pressure on clients |
| `node_nf_conntrack_entries` / `node_nf_conntrack_entries_limit` | Conntrack table usage vs `nf_conntrack_max` |
| `node_nf_conntrack_stat_drop` / `_insert_failed` / `_early_drop` | Conntrack failures (needs the `conntrack` collector and a node_exporter version that reads `/proc/net/stat/nf_conntrack`) |

TCP retransmission ratio. This is the most useful single "is the network lossy?" signal:

```promql
sum by (instance) (rate(node_netstat_Tcp_RetransSegs[5m]))
/
sum by (instance) (rate(node_netstat_Tcp_OutSegs[5m]))
```

| Retrans ratio | Interpretation |
|---|---|
| < 0.1% | Healthy LAN |
| 0.1% – 1% | Worth watching; normal on WAN/Internet egress |
| > 1% sustained inside a cluster | Real loss: congestion, MTU black hole, faulty NIC, overlay problems |

Conntrack saturation, the classic silent killer:

```promql
max by (instance) (node_nf_conntrack_entries / node_nf_conntrack_entries_limit)
```

When the table is full the kernel logs `nf_conntrack: table full, dropping packet` and drops **new** flows. Existing connections keep working, which is why the symptom looks like "some requests fail, randomly". DNS over UDP is hit first because every query is a new flow. kube-proxy sets `nf_conntrack_max` from its `conntrack.maxPerCore` × CPU count (with a floor of `conntrack.min`). If the ratio sits at the ceiling, either raise that configuration or reduce the flow churn (for example, with NodeLocal DNSCache, which turns pod DNS traffic into node-local traffic that is excluded from conntrack).

Accept queue overflows, which show up as "~1% of connects fail":

```promql
sum by (instance) (rate(node_netstat_TcpExt_ListenOverflows[5m])) > 0
```

Map the node to the pods it runs, then check the backend's `net.core.somaxconn`, its listen backlog, and whether its CPU is throttled (`container_cpu_cfs_throttled_periods_total`).

### 5.3 Pod-level traffic (cAdvisor via kubelet)

Containers in a pod share one network namespace, so cAdvisor's network metrics describe the **pod**. Aggregate by `namespace, pod`, and filter on the pod's interface (usually `eth0`):

```promql
# Top 10 pods by receive throughput
topk(10,
  sum by (namespace, pod) (rate(container_network_receive_bytes_total{interface="eth0"}[5m]))
)
```

```promql
# Pods whose interface is dropping packets
sum by (namespace, pod) (
  rate(container_network_receive_packets_dropped_total{interface="eth0"}[5m])
  + rate(container_network_transmit_packets_dropped_total{interface="eth0"}[5m])
) > 0
```

```promql
# Namespace egress: which tenant saturates the node?
sum by (namespace) (rate(container_network_transmit_bytes_total{interface="eth0"}[5m]))
```

Caveats:

- Pods with `hostNetwork: true` have no dedicated netns. Their traffic appears on the node's interfaces, not in cAdvisor per-pod series.
- With some CNIs, packets dropped by eBPF on the **host** side of the veth never show up as drops inside the pod netns. Pod-level drop counters stay at 0 while Cilium reports the drop. Use CNI metrics for drop reasons.

### 5.4 DNS: CoreDNS (RED)

CoreDNS metrics come from the `prometheus` plugin (`prometheus :9153` in the Corefile). Key series:

| Metric | Labels | Use |
|---|---|---|
| `coredns_dns_requests_total` | `server, zone, proto, family, type` | Rate: QPS per record type and protocol |
| `coredns_dns_responses_total` | `server, zone, rcode, plugin` | Errors: SERVFAIL / REFUSED ratios. NXDOMAIN is often normal (search-path expansion). |
| `coredns_dns_request_duration_seconds_bucket` | `server, zone, type, le` | Duration: latency histogram |
| `coredns_cache_hits_total` / `coredns_cache_misses_total` | `server, type` | Cache effectiveness |
| `coredns_forward_requests_total` | `to` | Upstream load |
| `coredns_forward_responses_total` | `to, rcode` | Upstream errors |
| `coredns_forward_healthcheck_broken_total` | — | **All** upstreams failed their health check |
| `coredns_panics_total` | — | Plugin panics |

RED queries:

```promql
# Rate
sum by (type) (rate(coredns_dns_requests_total[5m]))

# Errors: SERVFAIL ratio
sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]))
/
sum(rate(coredns_dns_responses_total[5m]))

# Duration: p99 per CoreDNS server block
histogram_quantile(0.99,
  sum by (le, server) (rate(coredns_dns_request_duration_seconds_bucket[5m]))
)

# Cache hit ratio
sum(rate(coredns_cache_hits_total[5m]))
/
(sum(rate(coredns_cache_hits_total[5m])) + sum(rate(coredns_cache_misses_total[5m])))
```

The `ndots:5` signature: with the default pod `resolv.conf`, looking up `api.example.com` first tries `api.example.com.<ns>.svc.cluster.local`, then `.svc.cluster.local`, then `.cluster.local` (plus search domains inherited from the node), and only then the absolute name. In metrics this looks like:

- A very high NXDOMAIN share (often 60–80%) that is **not** an error.
- Doubled traffic from the A/AAAA pair: `type="AAAA"` roughly equal to `type="A"`.

Fixes are application-side (trailing dot in FQDNs, `dnsConfig.options: ndots: 2`) or platform-side (NodeLocal DNSCache, the `autopath` plugin).

Correlating DNS with the kernel: CoreDNS latency is fine, but clients report timeouts. That means the queries never reach CoreDNS. Check `node_nf_conntrack_entries` against its limit and `node_netstat_Udp_RcvbufErrors` on the clients' nodes, and check CNI drops towards the CoreDNS pod IPs.

### 5.5 Service dataplane: kube-proxy

kube-proxy metrics describe the **control loop** that writes iptables, IPVS or nftables rules. They do not describe packets:

| Metric | Meaning |
|---|---|
| `kubeproxy_sync_proxy_rules_duration_seconds` (histogram) | How long one full or partial sync takes |
| `kubeproxy_sync_proxy_rules_last_timestamp_seconds` | When rules were last successfully synced |
| `kubeproxy_network_programming_duration_seconds` (histogram) | Time from an EndpointSlice change until it is programmed on this node: the real "Service convergence" SLI |
| `kubeproxy_sync_proxy_rules_iptables_total` | Number of iptables rules (iptables mode), which tracks scale |
| `kubeproxy_sync_proxy_rules_endpoint_changes_pending` | Endpoint updates waiting to be programmed |

```promql
# p99 sync time per node: in iptables mode it grows with Services × endpoints
histogram_quantile(0.99,
  sum by (le, instance) (rate(kubeproxy_sync_proxy_rules_duration_seconds_bucket[5m]))
)

# Nodes where rules have gone stale (default full resync is every 30s)
time() - kubeproxy_sync_proxy_rules_last_timestamp_seconds > 300

# How long a scale-up or rollout takes to become reachable, p99
histogram_quantile(0.99,
  sum by (le) (rate(kubeproxy_network_programming_duration_seconds_bucket[5m]))
)
```

| Mode | Sync cost scaling | Metric symptom at scale |
|---|---|---|
| `iptables` | Grows with the total number of rules; partial syncs help (1.28+) | `sync_proxy_rules_duration` in seconds; `network_programming_duration` p99 high during rollouts |
| `ipvs` | Service lookup is a hash; rule updates are incremental | Low sync times; watch conntrack instead |
| `nftables` | Incremental with set/map-based lookups | Low sync times at large Service counts |
| eBPF (Cilium KPR) | No kube-proxy; BPF maps | Use `cilium_*` metrics, not `kubeproxy_*` |

### 5.6 Service dataplane: Cilium agent

The key point: Cilium tells you **why** a packet was dropped.

| Metric | Labels | Use |
|---|---|---|
| `cilium_drop_count_total` | `reason, direction` | Drops per reason, per node |
| `cilium_drop_bytes_total` | `reason, direction` | Dropped volume |
| `cilium_forward_count_total` | `direction` | Forwarded packets (denominator) |
| `cilium_bpf_map_pressure` | `map_name` | Fill ratio of BPF maps (conntrack, NAT, policy); 1.0 = full |
| `cilium_endpoint_state` | `endpoint_state` | Endpoints stuck in `not-ready` or `waiting-for-identity` |
| `cilium_policy_change_total` / `cilium_policy` | — | Policy churn and count |

```promql
# Drops per reason across the cluster
sum by (reason) (rate(cilium_drop_count_total[5m]))

# Excluding intentional policy denials: these are the unexpected ones
sum by (instance, reason) (rate(cilium_drop_count_total{reason!="Policy denied"}[5m])) > 0

# BPF map pressure: the eBPF version of "conntrack table full"
max by (instance, map_name) (cilium_bpf_map_pressure) > 0.9
```

Common reasons and what they mean:

| `reason` | Meaning | Typical fix |
|---|---|---|
| `Policy denied` | A NetworkPolicy or CiliumNetworkPolicy blocked the flow | Expected, or a missing allow rule; confirm with `hubble observe --verdict DROPPED` |
| `Stale or unroutable IP` | Traffic to a pod IP that no longer exists | Clients caching old IPs; endpoint churn |
| `CT: Map insertion failed` | BPF conntrack map full | Raise `bpf-ct-global-*-max` / `bpf-map-dynamic-size-ratio` |
| `Invalid source ip` | Source IP does not match the endpoint (spoofing, misrouted traffic) | Check for asymmetric routing or a stale IPAM state |
| `Unsupported L3 protocol` | For example, IPv6 when IPv6 is disabled | Align the dual-stack configuration |

### 5.7 Hubble flow metrics

Hubble metrics are derived from flows and carry workload context:

```promql
# Policy drops per destination namespace: who is being blocked?
sum by (destination_namespace, reason) (rate(hubble_drop_total[5m]))

# DNS errors observed on the wire (from the client side, independent of CoreDNS)
sum by (rcode) (rate(hubble_dns_responses_total{rcode!="No Error"}[5m]))

# TCP RST share: connections actively refused
sum(rate(hubble_tcp_flags_total{flag="RST"}[5m]))
/
sum(rate(hubble_tcp_flags_total{flag="SYN"}[5m]))

# L7 error ratio between workloads (httpV2 handler)
sum by (source_workload, destination_workload) (rate(hubble_http_requests_total{status=~"5.."}[5m]))
/
sum by (source_workload, destination_workload) (rate(hubble_http_requests_total[5m]))
```

Why both CoreDNS and Hubble DNS metrics? CoreDNS sees queries that **arrived**. Hubble sees queries that **left the client**. The gap between them is your packet loss on the path to DNS.

### 5.8 Gateway data plane (Envoy)

For Gateway API implementations built on Envoy, upstream health comes from Envoy's cluster stats:

```promql
# Upstream 5xx ratio per Envoy cluster (≈ per backend Service)
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}[5m]))
/
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total[5m]))

# Connection failures to backends: network, not application
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_cx_connect_fail[5m])) > 0

# Upstream request timeouts
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_timeout[5m])) > 0
```

`upstream_cx_connect_fail` rising while the backends' own metrics look healthy points at the path between the gateway and the pods (policy, stale endpoints, MTU), not at the application.

---

## 6. Recording rules and alerts

Recording rules precompute expensive expressions so dashboards stay fast and alerts stay consistent. Naming convention: `level:metric:operations`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: network-health
  namespace: monitoring
  labels:
    app.kubernetes.io/part-of: network-observability
    release: kube-prometheus-stack
spec:
  groups:
    - name: network-health.recording
      interval: 30s
      rules:
        - record: instance:node_network_receive_bytes_physical:rate5m
          expr: |
            sum by (instance) (
              rate(node_network_receive_bytes_total{device!~"lo|veth.*|lxc.*|cali.*|cilium.*|flannel.*|cni.*|vxlan.*|docker.*"}[5m])
            )
        - record: instance:node_network_transmit_bytes_physical:rate5m
          expr: |
            sum by (instance) (
              rate(node_network_transmit_bytes_total{device!~"lo|veth.*|lxc.*|cali.*|cilium.*|flannel.*|cni.*|vxlan.*|docker.*"}[5m])
            )
        - record: instance:node_tcp_retrans:ratio_rate5m
          expr: |
            sum by (instance) (rate(node_netstat_Tcp_RetransSegs[5m]))
              /
            sum by (instance) (rate(node_netstat_Tcp_OutSegs[5m]))
        - record: instance:node_nf_conntrack:usage_ratio
          expr: |
            max by (instance) (node_nf_conntrack_entries / node_nf_conntrack_entries_limit)
        - record: cluster:coredns_servfail:ratio_rate5m
          expr: |
            sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]))
              /
            sum(rate(coredns_dns_responses_total[5m]))
        - record: server:coredns_dns_request_duration_seconds:p99_rate5m
          expr: |
            histogram_quantile(0.99,
              sum by (le, server) (rate(coredns_dns_request_duration_seconds_bucket[5m]))
            )

    - name: network-health.alerts
      rules:
        - alert: NodeConntrackTableNearFull
          expr: instance:node_nf_conntrack:usage_ratio > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Conntrack table above 85% on {{ $labels.instance }}"
            description: "Conntrack usage is {{ $value | humanizePercentage }}. At 100% the kernel drops NEW flows (DNS first). Check nf_conntrack_max and flow churn."

        - alert: NodeConntrackTableFull
          expr: instance:node_nf_conntrack:usage_ratio > 0.98
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Conntrack table full on {{ $labels.instance }}"
            description: "New connections are being dropped. Look for 'nf_conntrack: table full' in the kernel log."

        - alert: NodeTCPRetransmitRatioHigh
          expr: instance:node_tcp_retrans:ratio_rate5m > 0.01
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "TCP retransmission ratio above 1% on {{ $labels.instance }}"
            description: "Retransmit ratio is {{ $value | humanizePercentage }}. Suspect packet loss, congestion or an MTU black hole."

        - alert: NodeNetworkReceiveDrops
          expr: |
            sum by (instance, device) (rate(node_network_receive_drop_total{device!~"lo|veth.*|lxc.*|cali.*"}[5m]))
              /
            sum by (instance, device) (rate(node_network_receive_packets_total{device!~"lo|veth.*|lxc.*|cali.*"}[5m]))
              > 0.001
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Receive drop ratio above 0.1% on {{ $labels.instance }}/{{ $labels.device }}"
            description: "Check the NIC ring buffers (ethtool -g), softnet backlog and IRQ distribution."

        - alert: NodeNetworkInterfaceFlapping
          expr: increase(node_network_carrier_changes_total{device!~"lo|veth.*|lxc.*|cali.*"}[15m]) > 2
          labels:
            severity: warning
          annotations:
            summary: "Interface {{ $labels.device }} on {{ $labels.instance }} is flapping"

        - alert: NodeTCPListenOverflows
          expr: sum by (instance) (rate(node_netstat_TcpExt_ListenOverflows[5m])) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "TCP accept queue overflowing on {{ $labels.instance }}"
            description: "A listener is not accepting connections fast enough; clients see failed or slow connects."

        - alert: CoreDNSServfailRatioHigh
          expr: cluster:coredns_servfail:ratio_rate5m > 0.02
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "More than 2% of DNS responses are SERVFAIL"
            description: "Check the upstream health (coredns_forward_*), the CoreDNS logs and egress policies towards the upstream resolvers."

        - alert: CoreDNSLatencyHigh
          expr: server:coredns_dns_request_duration_seconds:p99_rate5m > 0.25
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "CoreDNS p99 latency above 250ms on {{ $labels.server }}"

        - alert: CoreDNSForwardHealthcheckBroken
          expr: increase(coredns_forward_healthcheck_broken_total[5m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "All CoreDNS upstream resolvers are failing health checks"

        - alert: KubeProxyRulesStale
          expr: time() - kubeproxy_sync_proxy_rules_last_timestamp_seconds > 600
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "kube-proxy on {{ $labels.instance }} has not synced rules for 10 minutes"
            description: "Service changes are not being programmed on this node. Check the kube-proxy logs and API server connectivity."

        - alert: CiliumUnexpectedDrops
          expr: sum by (instance, reason) (rate(cilium_drop_count_total{reason!="Policy denied"}[5m])) > 5
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cilium dropping packets on {{ $labels.instance }} (reason: {{ $labels.reason }})"

        - alert: CiliumBPFMapPressureHigh
          expr: max by (instance, map_name) (cilium_bpf_map_pressure) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "BPF map {{ $labels.map_name }} above 90% on {{ $labels.instance }}"

        - alert: NetworkComponentScrapeDown
          expr: up{job=~".*(coredns|kube-dns|kube-proxy|cilium|hubble|node-exporter).*"} == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Metrics target {{ $labels.job }} on {{ $labels.instance }} is down"
            description: "Network alerts for this component are blind. Check the ServiceMonitor selectors, the port name and NetworkPolicies on the scrape path."
```

Alert design notes:

| Decision | Rationale |
|---|---|
| Ratios, not absolute rates | A threshold that scales with traffic works the same on small and large nodes |
| `for: 10–15m` on ratios | Filters out micro-bursts; conntrack "full" gets `2m` because the impact is immediate |
| `reason!="Policy denied"` | Intentional denials are not incidents; alert on policy drops only per namespace, when you have a baseline |
| A dedicated `up == 0` alert | A silent exporter means no alert, and that looks like a healthy network |

---

## 7. Hands-on workflow from the CLI

### 7.1 Verify that the targets are scraped

```
$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
Forwarding from 127.0.0.1:9090 -> 9090

$ curl -s 'http://localhost:9090/api/v1/targets?state=active' \
    | jq -r '.data.activeTargets[] | select(.labels.job | test("coredns|kube-proxy|cilium|node-exporter")) | [.labels.job, .labels.instance, .health, .lastError] | @tsv'
coredns	10.244.0.12:9153	up
coredns	10.244.1.7:9153	up
kube-proxy	192.168.10.11:10249	up
kube-proxy	192.168.10.12:10249	down	Get "http://192.168.10.12:10249/metrics": dial tcp 192.168.10.12:10249: connect: connection refused
node-exporter	192.168.10.11:9100	up
node-exporter	192.168.10.12:9100	up
```

`connection refused` on one kube-proxy target means that node's kube-proxy is still bound to `127.0.0.1`: it has not been restarted since the ConfigMap change.

### 7.2 Read an exporter directly (no Prometheus in between)

```
$ kubectl -n kube-system port-forward svc/kube-dns 9153:9153 &
Forwarding from 127.0.0.1:9153 -> 9153

$ curl -s localhost:9153/metrics | grep -E '^coredns_dns_responses_total'
coredns_dns_responses_total{plugin="cache",rcode="NOERROR",server="dns://:53",view="",zone="."} 48211
coredns_dns_responses_total{plugin="kubernetes",rcode="NOERROR",server="dns://:53",view="",zone="."} 10573
coredns_dns_responses_total{plugin="kubernetes",rcode="NXDOMAIN",server="dns://:53",view="",zone="."} 61902
coredns_dns_responses_total{plugin="forward",rcode="SERVFAIL",server="dns://:53",view="",zone="."} 1377
```

A high NXDOMAIN count from `plugin="kubernetes"` is the `ndots` search-path expansion. SERVFAIL from `plugin="forward"` points at the upstream resolvers.

Pod network counters, through the API server proxy to the kubelet:

```
$ kubectl get --raw "/api/v1/nodes/worker-2/proxy/metrics/cadvisor" \
    | grep '^container_network_receive_packets_dropped_total' | grep 'interface="eth0"' | head -3
container_network_receive_packets_dropped_total{container="",id="/kubepods/burstable/pod3f1c…",image="",interface="eth0",name="",namespace="payments",pod="api-7d9c6b5f4-x2klq"} 0 1759221512000
container_network_receive_packets_dropped_total{container="",id="/kubepods/besteffort/pod91a2…",image="",interface="eth0",name="",namespace="kube-system",pod="coredns-5d78c9869d-4hq8w"} 0 1759221512000
container_network_receive_packets_dropped_total{container="",id="/kubepods/burstable/pod0b7e…",image="",interface="eth0",name="",namespace="ingest",pod="collector-0"} 412 1759221512000
```

Note `container=""`: network series are pod-level, as described in section 5.3.

### 7.3 Run PromQL from the shell

```
$ curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=topk(3, instance:node_nf_conntrack:usage_ratio)' \
    | jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
192.168.10.14:9100	0.9921
192.168.10.12:9100	0.4133
192.168.10.11:9100	0.3870
```

Node `.14` is at 99% conntrack usage. Confirm it on the node itself:

```
$ kubectl debug node/worker-4 -it --image=nicolaka/netshoot -- bash
Creating debugging pod node-debugger-worker-4-7kq2p with container debugger on node worker-4.

worker-4:~# cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
261901
262144

worker-4:~# conntrack -S | head -2
cpu=0   	found=0 invalid=1043 insert=0 insert_failed=8812 drop=8812 early_drop=0 error=2 search_restart=117
cpu=1   	found=0 invalid=988 insert=0 insert_failed=9120 drop=9120 early_drop=0 error=1 search_restart=103

worker-4:~# conntrack -L -o extended 2>/dev/null | awk '{print $3, $NF}' | sort | uniq -c | sort -rn | head -3
 188412 udp [UNREPLIED]
  51220 tcp [ASSURED]
  12011 tcp [UNREPLIED]
```

188k `udp [UNREPLIED]` entries point to a client flooding UDP (often DNS towards an unreachable upstream, or a misconfigured metrics/statsd sender). Find the source with `conntrack -L -p udp | awk '{print $4}' | sort | uniq -c | sort -rn | head`.

Kernel TCP counters, to cross-check node_exporter:

```
worker-4:~# nstat -az TcpRetransSegs TcpOutSegs TcpExtListenOverflows TcpExtTCPSynRetrans
#kernel
TcpOutSegs                      918273412          0.0
TcpRetransSegs                  1382201            0.0
TcpExtListenOverflows           0                  0.0
TcpExtTCPSynRetrans             22019              0.0

worker-4:~# ethtool -S eth0 | grep -Ei 'drop|err|miss' | grep -v ': 0$'
     rx_missed_errors: 18234
     rx_no_buffer_count: 18234
```

`rx_no_buffer_count` means the NIC ring buffer overflowed. Check the current size with `ethtool -g eth0` and raise it with `ethtool -G eth0 rx 4096` (then persist it through the node configuration).

### 7.4 Cilium: from metric to flow

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg metrics list | grep drop_count
cilium_drop_count_total    direction="EGRESS" reason="Policy denied"             3121.000000
cilium_drop_count_total    direction="INGRESS" reason="Policy denied"            842.000000
cilium_drop_count_total    direction="EGRESS" reason="Stale or unroutable IP"    57.000000

$ hubble observe --verdict DROPPED --last 5 -o compact
Sep 30 10:14:02.118: payments/api-7d9c6b5f4-x2klq:48122 (ID:51211) <> kube-system/coredns-5d78c9869d-4hq8w:53 (ID:1882) policy-verdict:none EGRESS DENIED (UDP)
Sep 30 10:14:02.119: payments/api-7d9c6b5f4-x2klq:48122 (ID:51211) <> kube-system/coredns-5d78c9869d-4hq8w:53 (ID:1882) Policy denied DROPPED (UDP)
...
```

The metric says *how much* and *why*. The flow says *who*: here, a new egress default-deny in `payments` without a DNS allow rule.

### 7.5 Validate the rules before shipping them

```
$ kubectl -n monitoring get prometheusrule network-health -o jsonpath='{.spec}' > /tmp/network-health.json

$ promtool check rules /tmp/network-health.json
Checking /tmp/network-health.json
  SUCCESS: 19 rules found

$ curl -s 'http://localhost:9090/api/v1/rules?type=alert' \
    | jq -r '.data.groups[] | select(.name=="network-health.alerts") | .rules[] | "\(.state)\t\(.name)"'
firing	NodeConntrackTableFull
inactive	NodeTCPRetransmitRatioHigh
inactive	CoreDNSServfailRatioHigh
...
```

JSON is valid YAML, so `promtool` accepts the extracted `spec` directly. If a rule group is missing from `/api/v1/rules`, the `PrometheusRule` was not selected. See section 8.2.

---

## 8. Diagnosis guide

### 8.1 Symptom → metric → cause

| Symptom | First metric to check | Confirming metric | Probable cause | Fix |
|---|---|---|---|---|
| Random connection failures at peak | `node_nf_conntrack_entries / _limit` | `conntrack -S` `insert_failed` | Conntrack table exhaustion | Raise `conntrack.maxPerCore`/`nf_conntrack_max`; reduce churn (NodeLocal DNSCache, keep-alives) |
| p99 latency up, CPU flat | `instance:node_tcp_retrans:ratio_rate5m` | `rx_drop`, `softnet_dropped` | Loss on the path; MTU black hole on the overlay | Check MTU (overlay overhead: VXLAN 50 B, Geneve ≥ 50 B, WireGuard 80 B); ring buffers; congestion |
| 5 s DNS delays | `hubble_dns_queries_total` vs `coredns_dns_requests_total` | `node_netstat_Udp_RcvbufErrors`, conntrack | UDP loss / conntrack races on parallel A+AAAA | NodeLocal DNSCache, `single-request-reopen`, TCP for DNS |
| DNS SERVFAIL spike | `coredns_dns_responses_total{rcode="SERVFAIL"}` by `plugin` | `coredns_forward_responses_total`, `forward_healthcheck_broken` | Upstream down or egress blocked | Fix the upstreams; allow CoreDNS egress to them |
| Service unreachable after scaling | `kubeproxy_network_programming_duration_seconds` p99 | `kubeproxy_sync_proxy_rules_last_timestamp_seconds` | Slow or stuck rule programming | Check the kube-proxy logs; move to nftables/IPVS/eBPF at scale |
| Only one node misbehaves | Any node metric grouped `by (instance)` | `node_network_carrier_changes_total`, `rx_errs` | Hardware, NIC or driver problem on that node | Cordon, drain and investigate |
| Traffic blocked after a policy change | `cilium_drop_count_total{reason="Policy denied"}` | `hubble observe --verdict DROPPED` | Missing allow rule (often DNS egress) | Add the rule; test with `--dry-run` or audit mode first |
| Gateway returns 503 | `envoy_cluster_upstream_cx_connect_fail` | `envoy_cluster_upstream_rq_timeout`, backend `up` | No healthy endpoints, or the path is blocked | Check EndpointSlices, policies between the gateway and backends |
| Clients fail to connect, backend "fine" | `node_netstat_TcpExt_ListenOverflows` on the backend's node | `container_cpu_cfs_throttled_periods_total` | Accept queue overflow | Raise the backlog/`somaxconn`; remove CPU throttling; scale out |

### 8.2 When the problem is the pipeline itself

| Symptom | Check | Cause | Fix |
|---|---|---|---|
| ServiceMonitor exists, no target in `/targets` | `kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.serviceMonitorSelector}'` | Label selector mismatch (for example, it requires `release: kube-prometheus-stack`) | Add the label, or set `serviceMonitorSelectorNilUsesHelmValues: false` |
| Target listed, `down`, `connection refused` | `curl` from a pod in the monitoring namespace | Exporter bound to `127.0.0.1` (kube-proxy), wrong port | Change the bind address; fix `targetPort` |
| Target `down`, `context deadline exceeded` | `kubectl get netpol -A` | NetworkPolicy dropping the scrape | Allow ingress from the monitoring namespace on the metrics port |
| ServiceMonitor never matches endpoints | `kubectl get svc <svc> -o yaml` → `ports[].name` | `endpoints[].port` refers to a name that does not exist (or to the number) | Use the Service port **name** |
| Rules missing from `/api/v1/rules` | `spec.ruleSelector` / `ruleNamespaceSelector` on the `Prometheus` object | Label or namespace not selected | Align the labels; `ruleSelectorNilUsesHelmValues: false` |
| Queries return nothing, the target is up | `count by (__name__)({job="coredns"})` | Metric renamed across versions, or dropped by `metricRelabelings` | Check the exporter's `/metrics` output directly |
| Prometheus OOMs after enabling Hubble | `prometheus_tsdb_head_series` | Per-IP label contexts | Use namespace or workload context; drop labels with relabeling |
| `rate()` graphs have holes | `scrape_duration_seconds`, the scrape interval | Window < 4× scrape interval, or scrape timeouts | Widen the range; raise `scrapeTimeout` |

Cardinality check:

```promql
topk(10, count by (__name__) ({__name__=~"hubble_.*|cilium_.*|coredns_.*|container_network_.*"}))
```

### 8.3 Triage order under pressure

1. **Are the targets up?** `up{job=~"...network components..."}`. No data is not the same as healthy data.
2. **Scope.** Group the key ratios `by (instance)`. One node → hardware or node configuration. All nodes → control plane, DNS, or policy.
3. **L7/DNS RED.** Are users affected? SERVFAIL ratio, gateway 5xx, DNS p99.
4. **Dataplane.** Cilium drop reasons, or kube-proxy sync freshness.
5. **Kernel USE.** Conntrack ratio, retransmits, listen overflows, softnet drops.
6. **NIC.** `rx_errs`, `rx_drop`, carrier changes, then `ethtool -S` on the node.
7. **Pinpoint.** `hubble observe` or `tcpdump` on the exact node and pod the metrics pointed to.

---

## 9. Exam-oriented summary

- Know **which component exports which signal**: node_exporter for the kernel and NICs, cAdvisor for pods, CoreDNS on 9153, kube-proxy on 10249 (loopback by default), Cilium on 9962, Hubble on 9965.
- **Never alert on raw counters.** Use `rate()` over a window of at least 4× the scrape interval, then aggregate. Use ratios with the right denominator.
- `histogram_quantile` needs `le` preserved in the aggregation.
- Conntrack usage ratio, TCP retransmission ratio, SERVFAIL ratio and Cilium drop reasons cover most real incidents.
- ServiceMonitors select Services **by label** and ports **by name**. Prometheus selects ServiceMonitors by label too. Both selectors are common failure points.
- NetworkPolicies apply to scrape traffic. A default-deny can blind your monitoring without breaking the service.

---

## References

- CNCF / Linux Foundation, CKNE certification: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes, Metrics for Kubernetes system components: https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Kubernetes, Kubernetes metrics reference: https://kubernetes.io/docs/reference/instrumentation/metrics/
- Kubernetes, kube-proxy configuration (v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Kubernetes, Debugging DNS resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Kubernetes, NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Prometheus, Query functions (`rate`, `irate`, `increase`, `histogram_quantile`): https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus, Histograms and summaries: https://prometheus.io/docs/practices/histograms/
- Prometheus, Recording rules naming: https://prometheus.io/docs/practices/rules/
- Prometheus node_exporter: https://github.com/prometheus/node_exporter
- cAdvisor, Prometheus metrics: https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md
- Prometheus Operator, API reference (ServiceMonitor, PodMonitor, PrometheusRule): https://prometheus-operator.dev/docs/api-reference/api/
- kube-prometheus-stack Helm chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- CoreDNS, `prometheus` (metrics) plugin: https://coredns.io/plugins/metrics/
- CoreDNS, `forward` plugin (health check metrics): https://coredns.io/plugins/forward/
- Cilium, Monitoring & Metrics: https://docs.cilium.io/en/stable/observability/metrics/
- Cilium, Running Prometheus & Grafana: https://docs.cilium.io/en/stable/observability/grafana/
- Envoy, Cluster statistics: https://www.envoyproxy.io/docs/envoy/latest/configuration/upstream/cluster_manager/cluster_stats
- Linux kernel, Netfilter conntrack sysctls: https://docs.kernel.org/networking/nf_conntrack-sysctl.html