# 4.1 Observability with Cilium

**Domain weight: 20 %.** This is the single heaviest observability block in the CCA blueprint, and it is graded on whether you understand *where the data comes from* — not on whether you can recite `hubble observe`. The material below is written to production depth: datapath origin of every event, the cardinality and retention trade-offs that decide whether your platform survives contact with a real cluster, complete manifests, and a diagnostic ladder.

---

## 1. The production problem

### 1.1 IP-keyed telemetry is structurally broken in Kubernetes

Every classical network observability tool — NetFlow, sFlow, IPFIX, VPC Flow Logs, `conntrack -L`, `tcpdump` — has the same primary key: the 5-tuple `(src IP, src port, dst IP, dst port, proto)`. That key is stable in a datacenter where a server keeps its address for three years. In Kubernetes it is garbage within minutes:

| Property | Traditional network | Kubernetes |
|---|---|---|
| Address lifetime | Months–years | Seconds–hours (Pod IPs are recycled aggressively) |
| Address → workload mapping | Static, in an IPAM/CMDB | Only in the apiserver, only while the Pod exists |
| Number of addresses per host | 1–4 | 30–250 (one per Pod, plus service VIPs) |
| Post-mortem lookup | `dig -x`, CMDB | Impossible — the Pod is gone and the IP belongs to someone else |
| NAT | At the edge | Everywhere: `kube-proxy` DNAT, node SNAT, egress gateway SNAT |

The practical consequence: an incident review at 09:00 for a flow log line written at 02:40 saying `10.0.7.19:52344 → 10.0.3.4:5432 DENIED` is **unanswerable**. `10.0.7.19` now belongs to a different tenant's Pod. You have a log line and no way to attribute it.

A second, subtler failure: **kube-proxy/iptables gives you no verdict signal at all.** When a `NetworkPolicy` drops a packet, iptables increments a counter on an anonymous chain. There is no record of *which* Pod tried to reach *which* Pod, or *which rule* denied it. Teams compensate by running `tcpdump` on nodes — which does not scale (it captures on one interface, on one node, with no identity), or by putting a sidecar proxy next to every Pod — which taxes every request with two extra userspace hops and only sees L7 traffic that the proxy is configured to intercept.

### 1.2 Identity is the primary key

Cilium's answer is to make the observability key **the security identity**, not the address.

Cilium assigns every endpoint a numeric *security identity* derived from a deterministic hash of its security-relevant labels (namespace, `app`, and whatever the operator whitelists). Two Pods of the same Deployment in the same namespace share one identity. That identity is:

* propagated in the datapath — in the tunnel header (VXLAN/Geneve) in encapsulation mode, or resolved from the `cilium_ipcache` BPF map in native-routing mode;
* used by the policy engine as the match key in the `cilium_policy_*` BPF maps;
* attached to **every** observability event Cilium emits.

So a Hubble flow is keyed by `(identity, identity)`, and the IP is decoration. `tenant-a/checkout (ID:14213) → tenant-b/postgres (ID:9917) DROPPED (Policy denied)` is still true and still attributable three months later, when both Pods have been replaced forty times.

**Identity ranges you must recognise on the exam and in an incident:**

| Range / value | Meaning |
|---|---|
| `1` | `reserved:host` — the local node itself (incl. host-network Pods) |
| `2` | `reserved:world` — anything outside the cluster with no CIDR identity |
| `3` | `reserved:unmanaged` — an endpoint Cilium has not (yet) managed |
| `4` | `reserved:health` — cilium-health endpoints |
| `5` | `reserved:init` — endpoint whose labels are not yet resolved |
| `6` | `reserved:remote-node` — another node in the cluster (or in the mesh) |
| `7` | `reserved:kube-apiserver` |
| `8` | `reserved:ingress` — Cilium Ingress/Gateway API Envoy |
| `256 – 65535` | Cluster-scoped identities, allocated from CRDs or the kvstore |
| `≥ 16777216` (1<<24) | **Local-scoped** identities — CIDR and FQDN identities, node-local, never propagated |

The last row is an operational trap: a CIDR identity is meaningful only on the node that allocated it. Comparing identity numbers across nodes for `toCIDR`/`toFQDN` traffic is wrong. Compare the *labels*.

### 1.3 Where the events come from

Hubble does not sniff. It consumes events that the eBPF datapath already produces at the exact point where the decision was made.

```
                        ┌──────────────────────── one Kubernetes node ────────────────────────┐
                        │                                                                     │
   pod veth  ─ tc ingress/egress ─┐                                                           │
   host netdev ─ tc / XDP ────────┤                                                           │
   socket (cgroup/sock_ops) ──────┤                                                           │
                                  ▼                                                           │
                    ┌──────────────────────────────┐                                          │
                    │  eBPF datapath programs      │                                          │
                    │   trace_notify()   TraceNotify                                          │
                    │   send_drop_notify() DropNotify                                         │
                    │   send_policy_verdict_notify() PolicyVerdictNotify                      │
                    │   debug_msg()      DebugMsg                                             │
                    └───────────────┬──────────────┘                                          │
                                    │ bpf_perf_event_output()                                 │
                                    ▼                                                         │
                    ┌──────────────────────────────┐                                          │
                    │ cilium_events                │  BPF_MAP_TYPE_PERF_EVENT_ARRAY,          │
                    │ (per-CPU perf ring buffer)   │  size = --bpf-events-*-map-size          │
                    └───────────────┬──────────────┘                                          │
                                    │                                                         │
   Envoy L7 proxy  ──┐              │                                                         │
   DNS proxy       ──┼─ gRPC ──► ┌──▼─────────────────────────────────────────┐               │
                     │           │  cilium-agent : monitor consumer           │               │
                     │           │  decode → enrich (endpoint mgr, ipcache,   │               │
                     │           │  identity cache, service cache, k8s meta)  │               │
                     │           └──┬───────────────┬───────────────┬─────────┘               │
                     │              │               │               │                         │
                     │              ▼               ▼               ▼                         │
                     │      ┌───────────────┐ ┌────────────┐ ┌──────────────────┐             │
                     │      │ Hubble ring   │ │ Hubble     │ │ Hubble exporter  │             │
                     │      │ buffer (RAM)  │ │ metrics    │ │ (JSON to a file) │             │
                     │      │ capacity N    │ │ :9965      │ │ /var/run/cilium/ │             │
                     │      └──────┬────────┘ └────────────┘ │  hubble/events.log             │
                     │             │                         └──────────────────┘             │
                     │             │ gRPC Observer API                                        │
                     │   unix:///var/run/cilium/hubble.sock  and  TCP :4244 (mTLS)            │
                     └─────────────┴──────────────────────────────┬───────────────────────────┘
                                                                  │
                                  ┌───────────────────────────────▼──────────────┐
                                  │ hubble-relay  :4245   (stateless fan-out)    │
                                  │ discovers peers via the `hubble-peer` Service│
                                  └───────┬─────────────────────┬────────────────┘
                                          │                     │
                                 hubble CLI              hubble-ui (backend+frontend)
```

Four things follow from this diagram, and each is an exam-grade fact:

1. **Events are produced where the verdict happens.** A `DropNotify` carries the exact eBPF drop reason code and the observation point. There is no inference, no heuristic, no reconstruction from packet captures.
2. **The agent is the only enrichment point.** `hubble-relay` performs *no* enrichment — it is a stateless gRPC multiplexer. If a flow shows `ID:0` or a bare IP with no pod name, the problem is on the agent of the node that produced it (ipcache gap, identity not yet allocated, traffic genuinely from outside).
3. **Hubble's history is a RAM ring buffer**, per node. Nothing is written to disk unless you enable the exporter.
4. **L7 events are a different pipeline.** They come from the Envoy proxy and the DNS proxy over gRPC, not from eBPF. No proxy redirect → no L7 flow, no matter how you configure Hubble.

### 1.4 The retention truth — the number that kills most deployments

The per-node buffer is set by `--hubble-event-buffer-capacity` (Helm: it is a `cilium-config` key; the value must be `2^n − 1`). The default is **4095 flows**.

$$\text{retention}_{\text{seconds}} \approx \frac{\text{buffer capacity}}{\text{flows per second on that node}}$$

| Node flow rate | capacity 4095 (default) | capacity 65535 | capacity 1048575 |
|---|---|---|---|
| 50 flows/s (quiet) | ~82 s | ~22 min | ~5.8 h |
| 500 flows/s (typical prod node) | ~8 s | ~2.2 min | ~35 min |
| 2 000 flows/s (busy ingress node) | **~2 s** | ~33 s | ~8.7 min |
| 20 000 flows/s (under scan/DDoS) | ~0.2 s | ~3 s | ~52 s |

At 2 000 flows/s the default buffer holds **two seconds** of history. By the time an alert fires, a human reads it, and someone runs `hubble observe --last 500`, the evidence has been overwritten thousands of times over. Raising capacity costs roughly `capacity × ~O(1 KB)` of agent RSS per node — 65 535 flows is on the order of tens of MB, 1 048 575 is on the order of a gigabyte and is almost never the right answer.

**The architectural conclusion — internalise this, it is the whole point of the domain:** Hubble's ring buffer is a *live debugging surface*, not a datastore. Production observability with Cilium is three planes, and you need all three:

| Plane | Answers | Retention | Cost |
|---|---|---|---|
| **Ring buffer** (`hubble observe`) | "What is happening *right now* between these two workloads?" | Seconds–minutes | RAM per node |
| **Metrics** (`:9965` → Prometheus) | "Is the drop rate up? Which namespace? Since when?" | Weeks–months | Cardinality (see §2.4) |
| **Flow log export** (file → Vector/Fluent Bit → Loki/S3) | "Reconstruct 02:40 last Tuesday, flow by flow." | Whatever your log store does | Disk + ingest $ |

Deployments that ship only the first plane are the ones that discover, mid-incident, that they have nothing.

---

## 2. Technical comparisons and trade-offs

### 2.1 Approaches to network observability in Kubernetes

| Approach | Identity-aware | L7 | Overhead model | Retention | Post-mortem usable | Blind spots |
|---|---|---|---|---|---|---|
| `tcpdump` on the node | ✗ (IPs only) | Manual decode | High while running; none otherwise | Whatever you write | Only if you captured *before* | One node, one interface, no verdict, encrypted L7 opaque |
| `conntrack -L` / iptables counters | ✗ | ✗ | Negligible | None (live table) | ✗ | No drop attribution, no identity, table churn |
| Cloud VPC flow logs | ✗ (node IPs after SNAT) | ✗ | Provider-side | Days–months | Partially | Pod-to-Pod inside a node is invisible; SNAT collapses all Pods to the node IP |
| Sidecar service mesh telemetry | ✓ (workload) | ✓ | +2 userspace hops, ~50–100 MB RSS *per Pod* | Metrics/traces only | Via traces | L3/L4 and non-HTTP protocols invisible; nothing outside the mesh |
| eBPF sampling profilers (e.g. Pixie) | Partial | ✓ | Sampling-dependent | Short | Partial | Not the policy decision point — cannot tell you *why* a packet was dropped |
| **Hubble** | ✓ (identity + k8s metadata) | ✓ via proxy redirect | Event emission in the datapath; agent decode+enrich | RAM ring buffer + export | ✓ if exported | XDP-stage drops, encrypted payload, anything the proxy does not redirect |
| Tetragon | ✓ (process + k8s) | ✗ (network) | Per-event, kernel-side filtering | Export-based | ✓ if exported | Not a network flow tool — it answers *which binary*, not *which flow* |

**Boundary you must be able to state:** Hubble answers **network** questions — who talked to whom, was it forwarded or dropped, and why. Tetragon answers **runtime** questions — which process, which syscall, which file, which capability. They share the eBPF substrate and the Kubernetes identity model; they are not substitutes.

### 2.2 The four ways to reach Hubble data

| Access path | Endpoint | Scope | Auth | When to use |
|---|---|---|---|---|
| Agent Unix socket | `/var/run/cilium/hubble.sock` | **This node only** | Filesystem (in-pod) | Deep node-level debugging; `kubectl exec` into the agent |
| Agent TCP | `:4244` (`hubble-peer` Service) | This node only | mTLS | Consumed by relay; not for humans |
| **hubble-relay** | `:4245` | **Whole cluster** | mTLS to agents; optional TLS to clients | Default for `hubble` CLI and UI |
| Hubble UI | relay → `hubble-ui` | Cluster, namespace-scoped | Whatever you put in front of it | Service map, exploration, non-expert users |
| Metrics | agent `:9965` | Per node, aggregated | None by default (**see §5.6**) | Prometheus, alerting, dashboards |
| Flow log export | file on node | Per node, all flows matching filters | Filesystem | Long-term retention, SIEM, compliance |

The failure mode this table prevents: `hubble observe` run *inside* an agent Pod returns only that node's flows and people conclude "traffic is not being seen". It is being seen — on another node.

### 2.3 Monitor aggregation — the fidelity/volume dial

`monitor-aggregation` controls how many **trace** events the datapath emits. It does *not* suppress drop events.

| Level | Behaviour | Events/s (relative) | What you lose |
|---|---|---|---|
| `none` | One event per packet, both directions | 100× | Nothing. Unusable at scale — will saturate the perf buffer. |
| `low` | Aggregate forwarded traffic per connection per `monitor-aggregation-interval` | ~5× | Per-packet timing |
| `medium` *(default)* | As `low`, plus re-emit when the TCP flags in `monitor-aggregation-flags` change (default `all`) | 1× | Steady-state per-packet detail; you still see SYN/FIN/RST |
| `maximum` | Most aggressive aggregation | ~0.5× | Mid-connection flag transitions; retransmission visibility |

Companion keys: `monitor-aggregation-interval` (default `5s`), `monitor-aggregation-flags` (default `all` — `syn,fin,rst`).

**Rule:** never lower aggregation cluster-wide to debug one thing. Aggregation is a datapath-global knob; going to `none` on a 200-node cluster to chase one retransmission problem is how you cause the outage you were investigating. Debug with `cilium monitor` on the single affected node instead.

### 2.4 Hubble metrics — the cardinality budget

Metrics are enabled per-metric with an option string: `<metric>:<opt>=<v>;<opt>=<v>`. The context options decide your Prometheus bill.

| Context value | Label produced | Distinct values (order of) | Verdict |
|---|---|---|---|
| `identity` | full label set | thousands | ✗ Never in metrics |
| `ip` | `source_ip` / `destination_ip` | **= number of Pods that ever existed** | ✗ Unbounded — this is the #1 cause of Prometheus OOM with Cilium |
| `pod` | `namespace/pod-name` | = Pods ever existed | ✗ Unbounded |
| `pod-short` | `namespace/deployment-ish` | = workloads | ⚠ Bounded but large |
| `dns` | FQDN | = distinct FQDNs contacted | ⚠ Unbounded for egress-to-internet |
| `namespace` | `namespace` | = namespaces | ✓ Safe |
| `workload` / `workload-name` | owner workload | = Deployments/StatefulSets | ✓ Safe, best signal/cost ratio |
| `app` | `app` label | = apps | ✓ Safe |
| `reserved-identity` | `world`, `host`, `remote-node`… | ~8 | ✓ Safe |

Cardinality is multiplicative: `sourceContext × destinationContext × metric's own labels × nodes`. `httpV2` with `labelsContext=source_ip,destination_ip` on a 100-node cluster with 5 000 Pods produces series counts in the tens of millions. Prometheus will die.

| Metric | Series driver | Recommended in prod |
|---|---|---|
| `drop` | `reason` × `protocol` × context | ✓ Always — this is your policy-regression alarm |
| `flow` | `type` × `subtype` × `verdict` × `protocol` × context | ✓ Always |
| `tcp` | `flag` × `family` × context | ✓ Cheap, catches RST storms |
| `dns` (`query;ignoreAAAA`) | `rcode` × `qtypes` × context | ✓ NXDOMAIN alerting is high-value |
| `icmp` | `family` × `type` | ✓ Cheap |
| `httpV2` | `method` × `status` × `reporter` + histogram buckets | ✓ Only where L7 redirect exists |
| `flows-to-world` | `protocol` × `verdict` | ✓ Egress-exposure signal |
| `port-distribution` | **`port`** × `protocol` × context | ✗ One series per destination port — scanners generate 65 535 |
| `http` (v1) | — | ✗ Superseded by `httpV2` |

`httpV2:exemplars=true` plus `hubble.metrics.enableOpenMetrics=true` attaches trace IDs to histogram buckets, which is what lets a Grafana user click a latency spike and land in the Tempo/Jaeger trace. It requires the OpenMetrics exposition format.

### 2.5 Getting L7 visibility — the three mechanisms

L7 flows exist only if traffic is redirected to the Envoy or DNS proxy. There is no passive L7 parsing.

| Mechanism | How | Enforcement side-effect | Status |
|---|---|---|---|
| **CiliumNetworkPolicy with L7 rules** | `toPorts[].rules.http` / `.dns` / `.kafka` | **Yes** — the policy also enforces; anything not matched is denied | ✓ The durable, recommended route |
| Pod annotation `policy.cilium.io/proxy-visibility` | `<Egress/53/UDP/DNS>,<Ingress/80/TCP/HTTP>` | No — visibility only | ⚠ Legacy; being phased out in favour of L7 policy. Verify support in your minor version before depending on it |
| Ingress / Gateway API / Service Mesh | Envoy already in path | Its own | ✓ Free L7 flows for north–south traffic |

Cost model: redirecting a port to Envoy moves that traffic through userspace. This is per-port and per-endpoint, not per-Pod-global like a sidecar mesh — but it is not free. Redirect the ports you need to see, not all of them.

`enable-l7-proxy` (default `true`) is the master switch; if it is off, all three mechanisms silently produce nothing.

### 2.6 Retention backends

| Backend | Setup | Retention | Query | Cost | Notes |
|---|---|---|---|---|---|
| Ring buffer only | default | seconds–minutes | `hubble observe` | RAM | Not a retention strategy |
| Static file exporter | `hubble.export.static` | Until rotated | `jq` on the node | Disk | One filter set, restart to change |
| **Dynamic file exporter** | `hubble.export.dynamic` + ConfigMap | Until rotated | `jq` / shipper | Disk | **Hot-reloadable**, multiple named exporters with independent filters |
| File → Vector/Fluent Bit → Loki/OpenSearch/S3 | §3.6 | Your log store's | LogQL / DSL | Ingest + storage | The production answer |
| OpenTelemetry (`hubble-otel`, community adapter) | separate component | Trace backend's | Trace UI | Extra pipeline | Correlates flows with spans; verify project maturity before committing |
| Isovalent Enterprise Timescape | commercial | Months | Hubble UI / CLI over history | License | Purpose-built flow historian; out of CCA scope but know it exists |

### 2.7 TLS provisioning between relay and agents

`hubble.tls.auto.method`:

| Method | Mechanism | Rotation | Use when |
|---|---|---|---|
| `helm` | Certs generated at `helm template` time | **Manual** — every `helm upgrade` with a new CA breaks relay until agents restart | Lab only |
| `cronJob` | In-cluster CronJob regenerates before expiry | Automatic | Default choice with no PKI |
| `certmanager` | cert-manager `Issuer` | Automatic, auditable | You already run cert-manager |
| disabled (`hubble-disable-tls: true`) | Plaintext `:4244` | — | ✗ Never: `:4244` exposes every flow in the cluster |

---

## 3. Complete manifests

### 3.1 Production Helm values

```yaml
# cilium-values.yaml — Cilium with a full three-plane observability stack.
# Apply with:
#   helm upgrade --install cilium cilium/cilium \
#     --version 1.16.5 \
#     --namespace kube-system \
#     -f cilium-values.yaml \
#     --wait

k8sServiceHost: api.prod.example.internal
k8sServicePort: 6443

kubeProxyReplacement: true
routingMode: native
ipv4NativeRoutingCIDR: "10.128.0.0/12"
autoDirectNodeRoutes: true
bpf:
  masquerade: true

# L7 proxy is the precondition for every HTTP/DNS/Kafka flow Hubble will ever show.
l7Proxy: true

# --- Datapath event fidelity -------------------------------------------------
# 'medium' keeps per-connection granularity plus TCP flag transitions.
# Drop notifications are NOT affected by aggregation and are always emitted.
monitorAggregation: medium
monitorAggregationInterval: 5s
monitorAggregationFlags: all

# Perf ring buffer between eBPF and the agent. Raise on high-flow-rate clusters;
# 'hubble_lost_events_total{source="perf_event_ring_buffer"}' is the signal that
# this is too small.
bpf:
  masquerade: true
  events:
    drop:
      enabled: true
    policyVerdict:
      enabled: true
    trace:
      enabled: true

operator:
  replicas: 2
  prometheus:
    enabled: true
    port: 9963
    serviceMonitor:
      enabled: true

prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true
    trustCRDsExist: true

envoy:
  enabled: true
  prometheus:
    enabled: true
    port: 9964
    serviceMonitor:
      enabled: true

hubble:
  enabled: true

  # Agent-side gRPC listener consumed by hubble-relay.
  listenAddress: ":4244"

  # ---- Plane 1: the live ring buffer ---------------------------------------
  # MUST be 2^n - 1. 65535 flows is roughly tens of MB of agent RSS per node and
  # buys ~30 s of history on a 2000 flow/s node. See the retention table.
  eventBufferCapacity: 65535
  # 0 = auto-size the decode queue from the number of CPUs.
  eventQueueSize: 0

  # ---- Plane 2: metrics ----------------------------------------------------
  metrics:
    enabled:
      - "dns:query;ignoreAAAA;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload"
      - "drop:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
      - "tcp:labelsContext=source_namespace,destination_namespace"
      - "flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace"
      - "icmp:labelsContext=source_namespace,destination_namespace"
      - "flows-to-world:any-drop;port;syn-only"
      - "httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction"
      # DELIBERATELY OMITTED — one series per destination port, unbounded under
      # a port scan:
      #   - "port-distribution"
    port: 9965
    # OpenMetrics exposition — required for exemplars (trace-ID linking).
    enableOpenMetrics: true
    serviceMonitor:
      enabled: true
      interval: "30s"
      # Drop the highest-cardinality series at scrape time as a second line of
      # defence, in case someone re-enables a risky metric.
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "hubble_port_distribution_total"
          action: drop
    dashboards:
      enabled: true
      namespace: monitoring
      label: grafana_dashboard
      labelValue: "1"
      annotations:
        grafana_folder: "Cilium"

  # ---- Plane 3: durable flow logs -----------------------------------------
  export:
    fileMaxSizeMb: 100
    fileMaxBackups: 5
    static:
      enabled: false
    dynamic:
      enabled: true
      config:
        configMapName: cilium-flowlog-config
        # We manage the ConfigMap ourselves (see 3.3) so it can be edited and
        # hot-reloaded without a Helm release.
        createConfigMap: false

  # ---- TLS ------------------------------------------------------------------
  tls:
    enabled: true
    auto:
      enabled: true
      method: cronJob
      certValidityDuration: 365
      schedule: "0 3 1 */3 *"

  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 1Gi
    prometheus:
      enabled: true
      port: 9966
      serviceMonitor:
        enabled: true
    podDisruptionBudget:
      enabled: true
      maxUnavailable: 1
    tolerations: []
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            k8s-app: hubble-relay

  ui:
    enabled: true
    rollOutPods: true
    replicas: 1
    # Exposed via Gateway API in 3.7 — never with a bare LoadBalancer.
    ingress:
      enabled: false
    backend:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 512Mi
    frontend:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          memory: 256Mi
```

### 3.2 The `cilium-config` keys this produces — verify, don't assume

```console
$ kubectl -n kube-system get configmap cilium-config -o yaml | \
    grep -E '^\s+(enable-hubble|hubble-|monitor-aggregation|enable-l7-proxy)'
  enable-hubble: "true"
  enable-l7-proxy: "true"
  hubble-disable-tls: "false"
  hubble-event-buffer-capacity: "65535"
  hubble-event-queue-size: "0"
  hubble-export-file-max-backups: "5"
  hubble-export-file-max-size-mb: "100"
  hubble-flowlogs-config-path: /flowlog-config/flowlogs.yaml
  hubble-listen-address: :4244
  hubble-metrics: dns:query;ignoreAAAA;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload drop:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction tcp:labelsContext=source_namespace,destination_namespace flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;labelsContext=source_namespace,destination_namespace icmp:labelsContext=source_namespace,destination_namespace flows-to-world:any-drop;port;syn-only httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction
  hubble-metrics-server: :9965
  hubble-metrics-server-enable-tls: "false"
  hubble-socket-path: /var/run/cilium/hubble.sock
  monitor-aggregation: medium
  monitor-aggregation-flags: all
  monitor-aggregation-interval: 5s
```

`cilium-config` is read at agent startup. Editing it by hand requires `kubectl -n kube-system rollout restart ds/cilium`. The **one exception** is the dynamic flow-log config below, which is watched and hot-reloaded.

### 3.3 Dynamic flow log exporter — hot-reloadable, filtered

```yaml
# cilium-flowlog-config.yaml
# Mounted into cilium-agent at /flowlog-config/flowlogs.yaml and WATCHED:
# edits take effect without restarting the DaemonSet.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-flowlog-config
  namespace: kube-system
data:
  flowlogs.yaml: |
    flowLogs:
      # ---------------------------------------------------------------------
      # 1. SECURITY: every non-forwarded verdict, cluster-wide, full fidelity.
      #    This is the stream that answers "who tried what" during an incident.
      # ---------------------------------------------------------------------
      - name: security-denies
        filePath: /var/run/cilium/hubble/security-denies.log
        fieldMask: []
        includeFilters:
          - verdict: ["DROPPED", "ERROR", "AUDIT"]
        excludeFilters: []
        end: "2027-12-31T23:59:59.000Z"

      # ---------------------------------------------------------------------
      # 2. EGRESS EXPOSURE: anything leaving the cluster boundary.
      #    reserved:world as the destination identity.
      # ---------------------------------------------------------------------
      - name: egress-to-world
        filePath: /var/run/cilium/hubble/egress-world.log
        fieldMask:
          - time
          - verdict
          - source.namespace
          - source.pod_name
          - source.workloads
          - destination.identity
          - destination.labels
          - IP.destination
          - l4
          - l7.dns
          - node_name
        includeFilters:
          - destination_label: ["reserved:world"]
        excludeFilters:
          # Node-to-node health probes are not egress.
          - source_label: ["reserved:health"]

      # ---------------------------------------------------------------------
      # 3. PCI SCOPE: full L3/L4/L7 record for one regulated namespace.
      #    Narrow filter, so the volume is bounded and the retention can be long.
      # ---------------------------------------------------------------------
      - name: pci-payments
        filePath: /var/run/cilium/hubble/pci-payments.log
        fieldMask: []
        includeFilters:
          - source_pod: ["payments/"]
          - destination_pod: ["payments/"]
        excludeFilters: []

      # ---------------------------------------------------------------------
      # 4. DNS: every resolution, for exfiltration analysis and NXDOMAIN triage.
      #    Requires an L7 DNS policy (3.5) for the DNS proxy to be in path.
      # ---------------------------------------------------------------------
      - name: dns-audit
        filePath: /var/run/cilium/hubble/dns.log
        fieldMask:
          - time
          - verdict
          - source.namespace
          - source.workloads
          - l7.dns
          - node_name
        includeFilters:
          - event_type:
              - type: 129   # L7 event
        excludeFilters: []
```

> `fieldMask: []` means "every field" — the JSON line is large (~1–2 KB). Masks are the main lever on log volume; the `egress-to-world` exporter above emits roughly a quarter of a full record.

### 3.4 ServiceMonitor and alerting rules

If you are **not** using the chart's `serviceMonitor` (e.g. a Prometheus Agent outside the operator), the Service and ServiceMonitor are:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: hubble-metrics
  namespace: kube-system
  labels:
    k8s-app: hubble
spec:
  clusterIP: None
  type: ClusterIP
  selector:
    k8s-app: cilium
  ports:
    - name: hubble-metrics
      port: 9965
      protocol: TCP
      targetPort: hubble-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hubble
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: hubble
  endpoints:
    - port: hubble-metrics
      interval: 30s
      path: /metrics
      honorLabels: true
      relabelings:
        # Preserve which node produced the sample — indispensable for
        # localising a single-node datapath fault.
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          replacement: ${1}
          action: replace
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "hubble_port_distribution_total"
          action: drop
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hubble-observability
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: hubble.pipeline-health
      rules:
        # The observability pipeline itself is dropping data. If this fires,
        # every other Hubble-derived alert is under-reporting.
        - alert: HubbleLostEvents
          expr: sum by (node, source) (rate(hubble_lost_events_total[5m])) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Hubble is losing events on {{ $labels.node }} (source: {{ $labels.source }})"
            description: >-
              source=perf_event_ring_buffer -> raise the BPF events map size or
              increase monitor-aggregation.
              source=observer_events / hubble_ring_buffer -> the agent decode
              loop is behind; check cilium-agent CPU throttling.
            runbook_url: "https://docs.cilium.io/en/stable/observability/troubleshooting/"

        - alert: HubbleRelayDown
          expr: up{job="hubble-relay"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "hubble-relay is not scrapeable — cluster-wide flow queries are blind"

        - alert: HubblePeerCoverageDegraded
          expr: |
            count(up{job="hubble-metrics"} == 1)
              < 0.95 * count(kube_node_info)
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Fewer than 95% of nodes are exporting Hubble metrics"

    - name: hubble.network-signals
      rules:
        # A policy regression: drops appear where there were none.
        - alert: PolicyDropSpike
          expr: |
            sum by (destination_namespace, destination_workload) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
            ) > 1
            and
            sum by (destination_namespace, destination_workload) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m] offset 1h)
            ) < 0.05
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "New policy denies against {{ $labels.destination_namespace }}/{{ $labels.destination_workload }}"
            description: >-
              hubble observe --namespace {{ $labels.destination_namespace }}
              --verdict DROPPED --last 200

        - alert: DNSNXDomainSurge
          expr: |
            sum by (source_namespace, source_workload) (
              rate(hubble_dns_responses_total{rcode="NXDOMAIN"}[5m])
            ) > 20
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "NXDOMAIN surge from {{ $labels.source_namespace }}/{{ $labels.source_workload }}"
            description: >-
              Either a bad Service name / ndots search-path storm, or DNS-based
              exfiltration. Check: hubble observe --type l7 --namespace
              {{ $labels.source_namespace }} --protocol dns

        - alert: UnexpectedEgressToWorld
          expr: |
            sum by (source_namespace, source_workload) (
              rate(hubble_flows_to_world_total{verdict="FORWARDED"}[10m])
            ) > 0
            unless on (source_namespace)
            (kube_namespace_labels{label_egress_allowed="true"} == 1)
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.source_namespace }}/{{ $labels.source_workload }} is reaching the internet from a namespace not labelled egress-allowed"

        - alert: TCPResetStorm
          expr: sum by (destination_namespace) (rate(hubble_tcp_flags_total{flag="RST"}[5m])) > 50
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "RST storm toward {{ $labels.destination_namespace }} — backlog exhaustion or a half-open policy"
```

### 3.5 CiliumNetworkPolicy that unlocks L7 visibility (and enforces)

```yaml
---
# DNS visibility for a whole namespace. The matchPattern "*" makes the DNS proxy
# observe every query without restricting which names may be resolved, so this is
# visibility-first with enforcement available later by tightening the pattern.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-visibility
  namespace: tenant-a
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
---
# HTTP visibility + enforcement on the api workload.
# Everything not matched by these rules is denied at L7 with 403 — this is the
# trade-off of the CNP route: you get flows, and you get enforcement whether you
# wanted it or not.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-visibility
  namespace: tenant-a
spec:
  description: "L7 HTTP visibility and method/path allowlist for the orders API"
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/v2/orders(/.*)?$"
              - method: "POST"
                path: "/v2/orders$"
              - method: "GET"
                path: "/healthz$"
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "payments.partner.example.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
---
# Cluster-wide baseline that makes DROPPED flows meaningful: without a
# default-deny somewhere, "no drops" tells you nothing, because nothing is
# being evaluated. Roll this out in AUDIT mode first (see 5.7).
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: default-deny-with-baseline
spec:
  description: "Default deny for tenant namespaces, with DNS and node health allowed"
  endpointSelector:
    matchExpressions:
      - key: io.kubernetes.pod.namespace
        operator: In
        values: ["tenant-a", "tenant-b", "payments"]
  ingress:
    - fromEntities:
        - health
        - remote-node
  egress:
    - toEntities:
        - cluster
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

### 3.6 Shipping flow logs off the node — complete Vector DaemonSet

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
data:
  vector.yaml: |
    data_dir: /var/lib/vector

    sources:
      hubble_flows:
        type: file
        include:
          # The exporter rotates with a lumberjack-style suffix; glob the
          # rotated files too so nothing is lost between rotations.
          - /var/run/cilium/hubble/*.log
          - /var/run/cilium/hubble/*.log.*
        read_from: beginning
        fingerprint:
          strategy: checksum
          lines: 1
        max_line_bytes: 262144

    transforms:
      parse:
        type: remap
        inputs: [hubble_flows]
        drop_on_error: true
        reroute_dropped: true
        source: |
          . = object!(parse_json!(.message))
          # Hubble wraps the payload: {"flow":{...},"node_name":"...","time":"..."}
          .flow = object(.flow) ?? {}
          .k8s_node        = string(.node_name) ?? "unknown"
          .verdict         = string(.flow.verdict) ?? "UNKNOWN"
          .src_namespace   = string(.flow.source.namespace) ?? "outside"
          .dst_namespace   = string(.flow.destination.namespace) ?? "outside"
          .src_workload    = string(.flow.source.workloads[0].name) ?? (string(.flow.source.pod_name) ?? "unknown")
          .dst_workload    = string(.flow.destination.workloads[0].name) ?? (string(.flow.destination.pod_name) ?? "unknown")
          .drop_reason     = string(.flow.drop_reason_desc) ?? ""
          .exporter        = split(string!(.file), "/")[-1]
          .timestamp       = parse_timestamp(string!(.flow.time), "%+") ?? now()

      drop_noise:
        type: filter
        inputs: [parse]
        condition: |
          !(.src_namespace == "kube-system" && .dst_namespace == "kube-system" && .verdict == "FORWARDED")

    sinks:
      loki:
        type: loki
        inputs: [drop_noise]
        endpoint: http://loki-gateway.observability.svc.cluster.local
        encoding:
          codec: json
        out_of_order_action: accept
        # Label set is deliberately low-cardinality: everything else stays in
        # the log line and is queried with LogQL JSON filters.
        labels:
          job: hubble
          cluster: prod-eu-west-1
          node: "{{ k8s_node }}"
          verdict: "{{ verdict }}"
          src_namespace: "{{ src_namespace }}"
          dst_namespace: "{{ dst_namespace }}"
          exporter: "{{ exporter }}"
        batch:
          max_bytes: 4194304
          timeout_secs: 5

      parse_failures:
        type: blackhole
        inputs: [parse.dropped]
        print_interval_secs: 300
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hubble-flowlog-shipper
  namespace: observability
  labels:
    app.kubernetes.io/name: hubble-flowlog-shipper
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: hubble-flowlog-shipper
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hubble-flowlog-shipper
      annotations:
        checksum/config: "REPLACED-BY-CI"
    spec:
      serviceAccountName: hubble-flowlog-shipper
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: vector
          image: timberio/vector:0.42.0-debian
          args: ["--config", "/etc/vector/vector.yaml"]
          env:
            - name: VECTOR_SELF_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: VECTOR_LOG
              value: warn
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false     # must read root-owned files under /var/run/cilium
            runAsUser: 0
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /etc/vector
              readOnly: true
            - name: hubble-flowlogs
              mountPath: /var/run/cilium/hubble
              readOnly: true
            - name: data
              mountPath: /var/lib/vector
      volumes:
        - name: config
          configMap:
            name: hubble-flowlog-shipper
        - name: hubble-flowlogs
          hostPath:
            path: /var/run/cilium/hubble
            type: DirectoryOrCreate
        - name: data
          hostPath:
            path: /var/lib/hubble-flowlog-shipper
            type: DirectoryOrCreate
```

> **Verify the host path before trusting this.** The directory the agent writes to on the host is whatever the DaemonSet mounts for the export path:
> `kubectl -n kube-system get ds cilium -o json | jq '.spec.template.spec.volumes[] | select(.name|test("hubble"))'`

### 3.7 Exposing Hubble UI safely

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  parentRefs:
    - name: internal-gateway
      namespace: infra
      sectionName: https
  hostnames:
    - "hubble.internal.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove: ["X-Forwarded-Client-Cert"]
      backendRefs:
        - name: hubble-ui
          port: 80
---
# Hubble UI has no authentication of its own and renders every flow in the
# cluster. Restrict reachability to the identity of the authenticating proxy.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: hubble-ui-restrict
  namespace: kube-system
spec:
  endpointSelector:
    matchLabels:
      k8s-app: hubble-ui
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: infra
            app.kubernetes.io/name: oauth2-proxy
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
---
# Prometheus must be able to reach the hubble metrics port on every node.
# Under a default-deny host firewall this is the rule people forget, and the
# symptom is "metrics disappeared after we enabled host policies".
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-prometheus-scrape-hubble
spec:
  nodeSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9965"   # hubble metrics
              protocol: TCP
            - port: "9962"   # cilium-agent metrics
              protocol: TCP
            - port: "9964"   # cilium-envoy metrics
              protocol: TCP
```

---

## 4. CLI: real commands and real output

### 4.1 Bring-up and the health ladder

```console
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                 OK
 \__/¯¯\__/    Operator:               OK
 /¯¯\__/¯¯\    Envoy DaemonSet:        OK
 \__/¯¯\__/    Hubble Relay:           OK
    \__/       ClusterMesh:            disabled

DaemonSet              cilium             Desired: 42, Ready: 42/42, Available: 42/42
DaemonSet              cilium-envoy       Desired: 42, Ready: 42/42, Available: 42/42
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay       Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium             Running: 42
                       cilium-envoy       Running: 42
                       cilium-operator    Running: 2
                       hubble-relay       Running: 2
                       hubble-ui          Running: 1
Cluster Pods:          1834/1834 managed by Cilium
Helm chart version:    1.16.5
```

```console
$ cilium hubble port-forward &
[1] 48211
ℹ️  Hubble Relay is available at 127.0.0.1:4245

$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 2,752,470/2,752,470 (100.00%)
Flows/s: 18,431.92
Connected Nodes: 42/42
```

Read that output carefully — it is three independent facts:

* **`Connected Nodes: 42/42`** — relay has a live gRPC session to every agent. `41/42` means one node is a blind spot and every query silently under-reports.
* **`Current/Max Flows`** — the *sum* of all nodes' ring buffers (42 × 65 535 ≈ 2.75 M). `100.00%` means every buffer is full, which is normal steady state, not an error.
* **`Flows/s: 18,431`** across 42 nodes ≈ 440 flows/s per node → about **150 seconds** of history. That is your real forensic window.

```console
$ hubble list nodes
NAME                                     STATUS      AGE      FLOWS/S   CURRENT/MAX-FLOWS
ip-10-128-14-7.eu-west-1.compute.internal  Connected  38h12m   612.44    65535/65535 (100.00%)
ip-10-128-19-3.eu-west-1.compute.internal  Connected  38h12m   418.02    65535/65535 (100.00%)
ip-10-128-22-91.eu-west-1.compute.internal Unavailable 0s      0.00      0/0 (0.00%)
...
```

`Unavailable` on a single node is the highest-value early signal in this whole domain: that node's flows, drops and L7 events are simply not in any query result.

### 4.2 `hubble observe` — the query grammar

```console
$ hubble observe --namespace tenant-a --last 5
Sep  1 12:11:01.982: tenant-a/frontend-6d8f9c7b5-jz4kp:41556 (ID:14201) -> kube-system/coredns-7db6d8ff4d-lq2mn:53 (ID:16785) dns-request proxy FORWARDED (DNS Query api.tenant-a.svc.cluster.local. A)
Sep  1 12:11:01.984: kube-system/coredns-7db6d8ff4d-lq2mn:53 (ID:16785) -> tenant-a/frontend-6d8f9c7b5-jz4kp:41556 (ID:14201) dns-response proxy FORWARDED (DNS Answer "10.96.14.9" TTL: 30 (Proxy api.tenant-a.svc.cluster.local. A))
Sep  1 12:11:02.101: tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) -> tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:11:02.114: tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) -> tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) http-request FORWARDED (HTTP/1.1 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders)
Sep  1 12:11:02.147: tenant-a/api-5f7d84c6d9-lm2xt:8080 (ID:14208) -> tenant-a/frontend-6d8f9c7b5-jz4kp:48122 (ID:14201) http-response FORWARDED (HTTP/1.1 200 33ms (GET http://api.tenant-a.svc.cluster.local:8080/v2/orders))
```

Anatomy of a compact line:

```
Sep  1 12:11:02.114: tenant-a/frontend-...:48122 (ID:14201) -> tenant-a/api-...:8080 (ID:14208) http-request FORWARDED (HTTP/1.1 GET ...)
└── timestamp ──┘   └────── source ─────┘ └identity┘  │  └──── destination ────┘└identity┘ └ type ─┘ └verdict┘ └──── summary ────┘
                                                      └─ arrow: -> one direction observed,
                                                                 <> both/unknown direction
```

The filter surface that matters in practice:

```console
# Everything denied toward a namespace, right now, following.
$ hubble observe --to-namespace payments --verdict DROPPED --follow

# Both directions of a specific workload pair.
$ hubble observe --from-pod tenant-a/checkout --to-pod tenant-b/postgres --last 100

# By identity, when the Pod is already gone.
$ hubble observe --identity 14213 --last 200

# By label selector — survives Pod churn.
$ hubble observe --label app=checkout --to-label app=postgres

# Everything leaving the cluster.
$ hubble observe --to-identity 2 --verdict FORWARDED --last 50

# Everything to one external name (requires DNS proxy in path).
$ hubble observe --to-fqdn "*.amazonaws.com" --last 50

# Negation: all drops that are NOT policy denies.
$ hubble observe --verdict DROPPED --not --drop-reason POLICY_DENIED

# Time windows against the ring buffer.
$ hubble observe --since 5m --until 1m --namespace tenant-a
$ hubble observe --first 20 --namespace tenant-a     # oldest in the buffer
$ hubble observe --all --namespace tenant-a          # drain the whole buffer

# HTTP-specific.
$ hubble observe --protocol http --http-status 5+ --last 50
$ hubble observe --http-method POST --http-path "/v2/orders"

# Node scoping.
$ hubble observe --node-name ip-10-128-14-7.eu-west-1.compute.internal --verdict DROPPED
```

A denied flow, and the policy-verdict event that explains it:

```console
$ hubble observe --from-pod tenant-a/checkout --verdict DROPPED --last 4
Sep  1 12:14:55.301: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:55.301: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:56.318: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:58.334: tenant-a/checkout-7d9c5f8b4-2wq9x:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) Policy denied DROPPED (TCP Flags: SYN)
```

Three facts extracted in one screen:

* `policy-verdict:none INGRESS DENIED` — **`INGRESS`** is the decisive word. The deny is on `postgres`'s ingress policy, not `checkout`'s egress. You are editing the wrong CNP if you go to `tenant-a`.
* `:none` is the matched-rule descriptor: no rule matched at all (as opposed to `L3-Only`, `L3-L4`, `L4-Only`).
* The 1 s / 2 s spacing with `TCP Flags: SYN` is the client's SYN retransmission — confirming this is connection setup failing, not a mid-stream reset.

### 4.3 Observation points — reading position in the datapath

`--type trace` events carry a *trace observation point* that tells you exactly how far the packet travelled before the event.

```console
$ hubble observe --type trace --from-pod tenant-a/frontend --to-pod tenant-b/api --last 12 -o compact
Sep  1 12:20:10.001: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) from-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.001: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) to-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.002: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) from-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:20:10.002: tenant-a/frontend-...:49900 (ID:14201) -> tenant-b/api-...:8080 (ID:14208) to-endpoint FORWARDED (TCP Flags: SYN)
```

| Observation point | Position | It appeared → conclude | It is missing → conclude |
|---|---|---|---|
| `from-endpoint` | tc egress of the source Pod's veth | The packet left the Pod | The application never sent it — go to the app, not the network |
| `to-proxy` | Redirected into Envoy/DNS proxy | L7 redirect is active | No L7 policy/redirect on this port |
| `from-proxy` | Leaving the proxy | Proxy allowed it | Proxy denied at L7 — look for the `http-request … DROPPED` event |
| `to-overlay` | Entering the VXLAN/Geneve tunnel | Encap mode, packet is heading to another node | Native routing, or the destination is node-local |
| `from-overlay` | Decapsulated on the destination node | It crossed the network | **Underlay problem** — MTU, security group, tunnel port 8472 blocked |
| `to-stack` / `from-stack` | Handed to/from the host kernel stack | Host routing is involved | — |
| `to-network` / `from-network` | Physical NIC | Leaving/entering the node | — |
| `to-endpoint` | tc ingress of the destination veth | It was delivered | Delivered nowhere — policy, or the endpoint is not ready |

**The diagnostic method this table encodes:** list the observation points a packet reached, find the last one, and the fault is between it and the next expected one. `from-endpoint` + `to-overlay` with no `from-overlay` on the peer is an underlay/MTU problem — not a Cilium policy problem — and you have proven it in one command instead of a two-hour argument with the network team.

### 4.4 Structured output and `jq` recipes

```console
$ hubble observe --verdict DROPPED --last 1 -o json | jq .
{
  "flow": {
    "time": "2026-09-01T12:14:55.301418Z",
    "verdict": "DROPPED",
    "drop_reason": 133,
    "ethernet": {
      "source": "b6:9a:1f:0c:44:e1",
      "destination": "12:3a:77:0e:b2:04"
    },
    "IP": {
      "source": "10.128.14.211",
      "destination": "10.128.19.87",
      "ipVersion": "IPv4"
    },
    "l4": {
      "TCP": {
        "source_port": 52344,
        "destination_port": 5432,
        "flags": { "SYN": true }
      }
    },
    "source": {
      "ID": 1842,
      "identity": 14213,
      "namespace": "tenant-a",
      "labels": [
        "k8s:app=checkout",
        "k8s:io.cilium.k8s.namespace.labels.tenant=a",
        "k8s:io.kubernetes.pod.namespace=tenant-a"
      ],
      "pod_name": "checkout-7d9c5f8b4-2wq9x",
      "workloads": [{ "name": "checkout", "kind": "Deployment" }]
    },
    "destination": {
      "identity": 9917,
      "namespace": "tenant-b",
      "labels": [
        "k8s:app=postgres",
        "k8s:io.kubernetes.pod.namespace=tenant-b"
      ],
      "pod_name": "postgres-0",
      "workloads": [{ "name": "postgres", "kind": "StatefulSet" }]
    },
    "Type": "L3_L4",
    "node_name": "ip-10-128-19-3.eu-west-1.compute.internal",
    "event_type": { "type": 1, "sub_type": 133 },
    "traffic_direction": "INGRESS",
    "drop_reason_desc": "POLICY_DENIED",
    "Summary": "TCP Flags: SYN"
  },
  "node_name": "ip-10-128-19-3.eu-west-1.compute.internal",
  "time": "2026-09-01T12:14:55.301418Z"
}
```

```console
# Top denied workload pairs in the current buffer — the single most useful
# one-liner during a policy rollout.
$ hubble observe --verdict DROPPED --all -o json 2>/dev/null | \
    jq -r '.flow | "\(.source.namespace)/\(.source.workloads[0].name // .source.pod_name) -> \(.destination.namespace)/\(.destination.workloads[0].name // .destination.pod_name) [\(.l4.TCP.destination_port // .l4.UDP.destination_port // "-")] \(.drop_reason_desc)"' | \
    sort | uniq -c | sort -rn | head -15
    412 tenant-a/checkout -> tenant-b/postgres [5432] POLICY_DENIED
     87 tenant-a/worker -> outside/ [443] POLICY_DENIED
     31 payments/ledger -> kube-system/coredns [53] POLICY_DENIED
      9 tenant-c/batch -> tenant-c/redis [6379] POLICY_DENIED

# Which node produced them (localises a single-node datapath fault).
$ hubble observe --verdict DROPPED --all -o json 2>/dev/null | \
    jq -r '.node_name' | sort | uniq -c | sort -rn | head
    397 ip-10-128-19-3.eu-west-1.compute.internal
    142 ip-10-128-14-7.eu-west-1.compute.internal

# Slowest HTTP responses observed by the proxy.
$ hubble observe --protocol http --all -o json 2>/dev/null | \
    jq -r 'select(.flow.l7.http.code != null) |
           "\(.flow.l7.latency_ns/1000000 | floor)ms \(.flow.l7.http.code) \(.flow.l7.http.method) \(.flow.l7.http.url)"' | \
    sort -rn | head -10
1842ms 200 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders?expand=lines
 913ms 500 POST http://api.tenant-a.svc.cluster.local:8080/v2/orders
 402ms 200 GET http://api.tenant-a.svc.cluster.local:8080/v2/orders
```

**Building exporter filters without guessing.** Compose the filter interactively with the CLI, then print the wire representation and paste it into the ConfigMap of §3.3:

```console
$ hubble observe --namespace payments --verdict DROPPED --protocol tcp --print-raw-filters
allowlist:
    - '{"source_pod":["payments/"],"verdict":["DROPPED"],"protocol":["tcp"]}'
    - '{"destination_pod":["payments/"],"verdict":["DROPPED"],"protocol":["tcp"]}'

# And replay a filter set to confirm it matches what you expect:
$ hubble observe --allowlist '{"source_pod":["payments/"],"verdict":["DROPPED"]}' --last 5
```

### 4.5 When Hubble is not enough — the raw datapath

`cilium monitor` reads the perf ring buffer directly, with **no** aggregation applied by Hubble and no enrichment layer that could be lying to you.

```console
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --related-to 1842
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8e21ac4b to endpoint 1842, ifindex 27, file bpf_lxc.c:2114, , identity 14213->9917: 10.128.14.211:52344 -> 10.128.19.87:5432 tcp SYN
xx drop (Policy denied) flow 0x1c7730fa to endpoint 1842, ifindex 27, file bpf_lxc.c:2114, , identity 14213->9917: 10.128.14.211:52344 -> 10.128.19.87:5432 tcp SYN
```

`file bpf_lxc.c:2114` is the exact source location in the datapath that dropped the packet. Hubble never shows you this; `cilium monitor` does, and it is decisive when you suspect the drop reason is being mislabelled.

```console
# What identity does this Pod actually have?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg endpoint list | head -8
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                    IPv4            STATUS
           ENFORCEMENT        ENFORCEMENT
1842       Enabled            Enabled           14213      k8s:app=checkout                               10.128.14.211   ready
                                                           k8s:io.kubernetes.pod.namespace=tenant-a
2011       Disabled           Disabled          4          reserved:health                                10.128.14.9     ready
3094       Enabled            Enabled           9917       k8s:app=postgres                               10.128.19.87    ready

# Which identity owns an IP, cluster-wide (this is the ipcache Hubble enriches from)?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg ip list | grep 10.128.19.87
10.128.19.87/32   9917

# What is actually programmed in the policy map for that endpoint?
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg bpf policy get 3094
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                 PORT/PROTO   PROXY PORT   BYTES     PACKETS
Allow    Ingress     14201      k8s:io.cilium.k8s.policy.name=api-ingress   5432/TCP     NONE         184220    1402
Allow    Egress      0          reserved:unknown                            ANY          NONE         92110     801

# Cilium's own drop counters, by reason — cross-check against hubble_drop_total.
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg metrics list | grep -E 'drop_count|forward_count'
cilium_drop_count_total                 reason="Policy denied" direction="INGRESS"    412
cilium_drop_count_total                 reason="Stale or unroutable IP" direction="EGRESS"   3
cilium_forward_count_total              direction="INGRESS"                        18420114
cilium_forward_count_total              direction="EGRESS"                         17993201
```

---

## 5. Verification and failure diagnosis

### 5.1 The health ladder — run top to bottom, stop at the first failure

```console
# 1. Is the control plane healthy at all?
$ cilium status --wait

# 2. Is Hubble enabled on every agent, with the config you think?
$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-hubble}{"\n"}{.data.hubble-listen-address}{"\n"}{.data.hubble-event-buffer-capacity}{"\n"}'
true
:4244
65535

# 3. Does relay see every node?
$ hubble status | grep 'Connected Nodes'
Connected Nodes: 42/42

# 4. Is any node losing events?
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s localhost:9965/metrics | grep -E '^hubble_lost_events_total'
hubble_lost_events_total{source="perf_event_ring_buffer"} 0
hubble_lost_events_total{source="observer_events"} 0

# 5. Is Prometheus actually scraping it?
$ kubectl -n monitoring exec -it sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=count(up{job="hubble-metrics"}==1)' | jq -r '.data.result[0].value[1]'
42

# 6. Are flows actually being written to disk?
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- ls -la /var/run/cilium/hubble/
total 41284
drwxr-xr-x 2 root root      4096 Sep  1 03:00 .
drwxr-xr-x 4 root root       120 Aug 30 22:14 ..
-rw-r--r-- 1 root root  11284471 Sep  1 12:22 dns.log
-rw-r--r-- 1 root root   2093118 Sep  1 12:22 egress-world.log
-rw-r--r-- 1 root root  28914003 Sep  1 12:22 pci-payments.log
-rw-r--r-- 1 root root    884201 Sep  1 12:22 security-denies.log

# 7. Is the shipper keeping up?
$ kubectl -n observability logs ds/hubble-flowlog-shipper --tail=5 | grep -i 'error\|lag' || echo "clean"
clean

# 8. End-to-end: does a synthetic deny appear in Loki within the SLO?
$ kubectl -n tenant-a run probe --rm -it --restart=Never --image=busybox:1.36 -- \
    timeout 3 nc -zv 10.128.19.87 5432 ; echo "---" ; sleep 20 ; \
  logcli query --limit 5 '{job="hubble",verdict="DROPPED",src_namespace="tenant-a"}'
```

### 5.2 Failure catalogue

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| `hubble observe` returns nothing at all | Hubble disabled | `kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-hubble}'` | `hubble.enabled=true`, restart DaemonSet |
| `hubble status` → `connection refused` on 4245 | No port-forward, or relay down | `kubectl -n kube-system get deploy hubble-relay` | `cilium hubble port-forward` |
| Relay `CrashLoopBackOff`, logs `x509: certificate signed by unknown authority` | Agents and relay hold certs from different CA generations (classic after a `helm upgrade` with `tls.auto.method=helm`) | `kubectl -n kube-system logs deploy/hubble-relay` | Delete `hubble-*-certs` Secrets, re-run the cert CronJob, restart relay **and** the agent DaemonSet. Move to `cronJob` or `certmanager` |
| `Connected Nodes: 41/42` | One agent not serving 4244 | `hubble list nodes \| grep -v Connected` | Check that agent's logs and readiness; check host firewall on 4244 |
| Flows visible but `ID:0` / no pod names | ipcache/identity gap on the producing node, or genuinely external traffic | `cilium-dbg ip list \| grep <ip>` | If the IP is a cluster Pod and absent from ipcache: restart that agent; check operator identity GC |
| Zero L7/HTTP flows | No proxy redirect | `cilium-dbg endpoint get <id> -o json \| jq '.[0].status.policy.realized.l4'` for a `proxy-port` | Add a CNP with L7 rules (§3.5); verify `enable-l7-proxy: "true"` |
| Zero DNS flows | No DNS L7 rule | `hubble observe --protocol dns --last 5` | Add the `matchPattern: "*"` DNS egress rule |
| `hubble_lost_events_total{source="perf_event_ring_buffer"}` rising | eBPF→agent perf buffer overrun | metric + `cilium monitor` printing "lost N events" | Raise BPF events map size; raise `monitorAggregation` to `medium`/`maximum`; investigate the traffic spike |
| `hubble_lost_events_total{source="observer_events"}` rising | Agent decode/enrich loop is behind | agent CPU throttling: `container_cpu_cfs_throttled_seconds_total{container="cilium-agent"}` | Raise the agent CPU limit; reduce enabled metrics |
| `hubble observe --since 10m` returns only 30 s | Ring buffer smaller than the window | `hubble status` → Flows/s vs Current/Max | Raise `eventBufferCapacity`; **and** enable export — the buffer is not the answer |
| Prometheus OOMKilled after enabling Hubble metrics | Cardinality (`ip`/`pod`/`port-distribution`) | `topk(10, count by (__name__)({__name__=~"hubble_.*"}))` | Switch contexts to `workload-name`/`namespace`; drop `port-distribution` |
| Hubble metrics vanished after enabling host firewall | Scrape port blocked by a host policy | `hubble observe --to-identity 1 --to-port 9965 --verdict DROPPED` | Apply the CCNP in §3.7 |
| Flow log file exists but never grows | Filters match nothing, or wrong exporter name | `kubectl -n kube-system logs ds/cilium -c cilium-agent \| grep -i flowlog` | Rebuild filters with `hubble observe --print-raw-filters` |
| Node disk filling under `/var/run/cilium/hubble` | `fileMaxSizeMb × fileMaxBackups × exporters` exceeds the budget, or the shipper is dead | `du -sh /var/run/cilium/hubble` | Tighten `fieldMask`/filters; fix the shipper; lower `fileMaxBackups` |
| Drops appear in `cilium_drop_count_total` but not in Hubble | Drop happened at XDP, before the tc-layer notification | compare agent metrics vs `hubble_drop_total` | Expected for XDP-stage drops; investigate with `cilium-dbg` and XDP counters |

### 5.3 Drop reasons you must be able to read

`drop_reason_desc` in the JSON, `(reason)` in `cilium monitor`, the `reason` label in `hubble_drop_total`.

| Code | `drop_reason_desc` | What it actually means | First move |
|---|---|---|---|
| 133 | `POLICY_DENIED` | No policy rule allowed it | Read `traffic_direction` on the policy-verdict event — it tells you which side to fix |
| 181 | `POLICY_DENY` | An **explicit deny** rule matched (deny beats allow, always) | Find the CCNP/CNP with `ingressDeny`/`egressDeny` |
| 189 | `POLICY_AUTH_REQUIRED` | Mutual authentication required, handshake incomplete | Check the SPIFFE/mutual-auth integration |
| 151 | `UNROUTABLE` / stale IP | Destination IP is not in ipcache — endpoint deleted, or identity not propagated | `cilium-dbg ip list`; check kvstore/CRD sync and clustermesh |
| 158 | `NO_SERVICE_TRANSLATION` | Service VIP with no backend in the LB map | `cilium-dbg service list`; check Endpoints/EndpointSlice |
| 160 | `NO_TUNNEL_ENDPOINT` | Tunnel mode, no tunnel entry for the destination node | `cilium-dbg bpf tunnel list`; node not joined |
| 171 | `INVALID_IDENTITY` | Identity in the packet is unknown locally | Identity allocation lag; kvstore/operator health |
| 190 / 191 | `CT_NO_MAP_FOUND` / `SNAT_NO_MAP_FOUND` | Conntrack or NAT map exhausted | `cilium_bpf_map_pressure`; raise `bpf-ct-global-*-max` / NAT map size |
| 136 | `FRAG_NEEDED` | Packet too large, DF set | **MTU mismatch** — the classic tunnel-overhead bug |
| 177 | `NOT_IN_SRC_RANGE` | Service `loadBalancerSourceRanges` rejected the client | Widen the range, or it is working as configured |
| 174 | `IS_CLUSTER_IP` | Traffic to a ClusterIP arrived where it cannot be translated | kube-proxy replacement / socket-LB configuration |

`cilium_bpf_map_pressure` deserves a standing alert of its own: a full conntrack map produces drops that look exactly like intermittent application flakiness.

### 5.4 Runbook — "service A cannot reach service B"

```console
# 0. Establish the identities. Everything downstream is keyed on these.
$ kubectl -n tenant-a get pod -l app=checkout -o jsonpath='{.items[0].status.podIP}{"\n"}'
10.128.14.211
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | grep checkout
1842  Enabled  Enabled  14213  k8s:app=checkout  10.128.14.211  ready

# 1. Is anything at all observed between them? Label filters survive Pod churn.
$ hubble observe --label app=checkout --to-label app=postgres --last 20
# → nothing at all: the client never sent a packet. Go to the application,
#   DNS resolution, or the Service definition. Stop here.
# → flows present: continue.

# 2. Is it a policy verdict? This event names the direction authoritatively.
$ hubble observe --label app=checkout --to-label app=postgres --type policy-verdict --last 5
Sep  1 12:14:55.301: tenant-a/checkout-...:52344 (ID:14213) <> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
#   INGRESS  -> fix postgres's ingress rules, in tenant-b.
#   EGRESS   -> fix checkout's egress rules, in tenant-a.

# 3. Which policy is (not) programmed? Verify realised state, not the YAML.
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf policy get 3094 | grep 5432
# No row for identity 14213 on 5432/TCP -> the allow rule is genuinely absent.

# 4. Confirm the selector actually selects. The #1 cause is a label typo.
$ kubectl -n tenant-b get cnp -o yaml | yq '.items[].spec.ingress[].fromEndpoints'
- matchLabels:
    app: checkout          # <-- missing io.kubernetes.pod.namespace: tenant-a
#   In a CNP, an unqualified matchLabels is namespace-scoped: this selects
#   'app=checkout' in tenant-b, which does not exist. Cross-namespace requires
#   the namespace label explicitly.

# 5. If it is NOT a policy drop, walk the observation points (§4.3).
$ hubble observe --label app=checkout --to-label app=postgres --type trace --last 20 -o compact
#   from-endpoint present, to-overlay present, from-overlay ABSENT on the peer
#   -> underlay: MTU, security group, or UDP 8472 blocked. Not a Cilium policy issue.

# 6. Confirm the fix, with evidence.
$ hubble observe --label app=checkout --to-label app=postgres --last 5
Sep  1 12:31:02.883: tenant-a/checkout-...:52360 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
Sep  1 12:31:02.883: tenant-a/checkout-...:52360 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) to-endpoint FORWARDED (TCP Flags: SYN)
```

### 5.5 Runbook — the observability pipeline is dropping data

`HubbleLostEvents` fired. The `source` label decides everything.

```console
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s localhost:9965/metrics | grep hubble_lost_events_total
hubble_lost_events_total{source="perf_event_ring_buffer"} 184201
hubble_lost_events_total{source="observer_events"} 0
```

**`perf_event_ring_buffer` > 0** — the kernel produced events faster than the agent read them; the loss is in the eBPF→userspace hop.
1. Confirm it is a traffic event, not a regression: `rate(hubble_flows_processed_total[5m])` on that node vs. the fleet.
2. If it is a scan or a legitimate spike: raise `monitorAggregation` to `maximum` **temporarily**, and raise the BPF events map size.
3. Verify the agent is not CPU-starved: `rate(container_cpu_cfs_throttled_seconds_total{container="cilium-agent"}[5m])`.

**`observer_events` > 0** — the agent read the events but its decode/enrich/fan-out loop is behind.
1. Almost always CPU limits or too many enabled metrics with expensive contexts.
2. Raise the `cilium-agent` CPU limit; drop the most expensive metric contexts.
3. Raise `hubble-event-queue-size` off `0` only after ruling out CPU.

Either way, record the gap. A period with `lost_events > 0` is a period where "no drops were observed" is **not** evidence that no drops occurred — and a security review that treats it as evidence is drawing a false conclusion.

### 5.6 Runbook — Prometheus fell over after enabling Hubble metrics

```promql
# Which Hubble metric is producing the series?
topk(10, count by (__name__) ({__name__=~"hubble_.*"}))

# Which label is unbounded within the worst offender?
count(count by (destination_ip) (hubble_flows_processed_total))
count(count by (destination_workload) (hubble_flows_processed_total))
```

If `destination_ip` returns tens of thousands and `destination_workload` returns hundreds, you have your answer. The fix is in `hubble.metrics.enabled` — replace `sourceContext=ip`/`pod` with `workload-name|reserved-identity`, delete `port-distribution`, and roll the DaemonSet. Keep the `metricRelabelings` drop in the ServiceMonitor (§3.4) as a permanent guard, so a future values-file edit cannot repeat the incident before anyone reviews it.

The `|` in `sourceContext=workload-name|reserved-identity` is a fallback chain: use the workload name when there is one, fall back to the reserved identity (`world`, `host`, `remote-node`) when there is not. Without the fallback, external traffic collapses into an empty label and you lose the ability to distinguish egress from intra-cluster traffic.

### 5.7 Policy audit mode — observe before you enforce

Never roll a default-deny into a live cluster and read the drops afterwards. Put the endpoints into audit mode, collect what *would have been* denied, write the allow rules, then enforce.

```console
# Turn on audit for one endpoint (per-endpoint, node-local, not persisted).
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg endpoint config 3094 PolicyAuditMode=Enabled
Endpoint 3094 configuration updated successfully

# Verdicts now surface as AUDIT instead of DROPPED — traffic still flows.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict AUDIT --last 5
Sep  1 13:02:11.774: tenant-a/checkout-...:53102 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
Sep  1 13:02:14.019: ops/backup-runner-...:41880 (ID:15501) -> tenant-b/postgres-0:5432 (ID:9917) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)

# Let it run a full business cycle — including the nightly batch window, which
# is what everybody forgets — then enumerate the required allows.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict AUDIT --all -o json 2>/dev/null | \
    jq -r '.flow | "\(.source.namespace):\(.source.labels[] | select(startswith("k8s:app=")) ) -> \(.l4.TCP.destination_port // .l4.UDP.destination_port)"' | \
    sort -u
ops:k8s:app=backup-runner -> 5432
tenant-a:k8s:app=checkout -> 5432
tenant-a:k8s:app=reporting -> 5432

# Write the CNP from that list, apply it, and only then:
$ kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- \
    cilium-dbg endpoint config 3094 PolicyAuditMode=Disabled

# Enforcement is live. Verify no legitimate traffic turned into a DROP.
$ hubble observe --to-pod tenant-b/postgres-0 --verdict DROPPED --last 20
No flows returned.
```

`PolicyAuditMode` is per-endpoint and node-local — it does not survive Pod rescheduling, and it must be set on every node hosting a replica. That property makes it a deliberate, time-boxed investigation tool, not a configuration state to leave switched on.

### 5.8 Cluster Mesh — the scope boundary

`hubble-relay` in upstream Cilium connects to the `hubble-peer` Service of **its own cluster**. In a Cluster Mesh, a flow leaving cluster A for cluster B is observed twice — once by A's agent (egress) and once by B's agent (ingress) — and neither relay holds both halves.

```console
$ hubble observe --to-identity 9917 --last 3
Sep  1 13:20:44.118: tenant-a/checkout-...:54210 (ID:14213) -> tenant-b/postgres-0:5432 (ID:9917) to-network FORWARDED (TCP Flags: SYN)
# Flow ends at to-network. The other half lives in cluster-b's relay.
```

Two workable answers, in order of preference:

1. **Correlate in the log store.** Both clusters export flows to the same Loki/OpenSearch with a `cluster` label. Cross-cluster reconstruction becomes a query, and it works after the fact — which is what post-mortems need. This is the design in §3.6.
2. **Query each cluster's relay.** Keep a `hubble` CLI context per cluster (`hubble config` / `--server`) and run the query twice. Fine for live debugging, useless for history.

Identity consistency is a prerequisite either way: for a flow in cluster B to name a cluster-A workload, the identity allocation must be shared or label-equivalent across the mesh. Mismatched identity allocation shows up exactly as `ID:0` / unnamed sources on cross-cluster flows.

---

## References

- CNCF Cilium Certified Associate (CCA) curriculum — https://github.com/cncf/curriculum and https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- Cilium documentation — Network Observability with Hubble — https://docs.cilium.io/en/stable/observability/
- Cilium documentation — Hubble internals and architecture — https://docs.cilium.io/en/stable/overview/component-overview/
- Cilium documentation — Running Prometheus & Grafana / Hubble metrics reference — https://docs.cilium.io/en/stable/observability/metrics/
- Cilium documentation — Hubble Exporter (static and dynamic flow logs) — https://docs.cilium.io/en/stable/observability/hubble-exporter/
- Cilium documentation — Configuring Hubble Relay and TLS — https://docs.cilium.io/en/stable/observability/hubble/configuration/
- Cilium documentation — Layer 7 Protocol Visibility — https://docs.cilium.io/en/stable/observability/visibility/
- Cilium documentation — Network Policy (CiliumNetworkPolicy and CiliumClusterwideNetworkPolicy) — https://docs.cilium.io/en/stable/security/policy/
- Cilium documentation — Policy Enforcement Modes and Audit Mode — https://docs.cilium.io/en/stable/security/policy/intro/
- Cilium documentation — Identity-Based security and reserved identities — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Cilium documentation — Troubleshooting (`cilium monitor`, `cilium-dbg`, drop reasons) — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium documentation — Helm reference (`hubble.*` values) — https://docs.cilium.io/en/stable/helm-reference/
- Cilium documentation — Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/
- Hubble CLI source and releases — https://github.com/cilium/hubble
- Hubble UI source — https://github.com/cilium/hubble-ui
- Cilium eBPF datapath drop reason definitions (`bpf/lib/common.h`) — https://github.com/cilium/cilium/blob/main/bpf/lib/common.h
- Hubble flow API (protobuf definitions for the JSON output) — https://github.com/cilium/cilium/tree/main/api/v1/flow
- Tetragon (runtime/process observability, adjacent to Hubble) — https://tetragon.io/docs/
- Prometheus Operator ServiceMonitor and PrometheusRule API — https://prometheus-operator.dev/docs/api-reference/api/
- Vector `file` source and `loki` sink — https://vector.dev/docs/reference/configuration/sources/file/ and https://vector.dev/docs/reference/configuration/sinks/loki/