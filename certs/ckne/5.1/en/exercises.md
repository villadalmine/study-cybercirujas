# Guided Exercises — 5.1 Analyzing Network Health Using Metrics

> **Exam weight:** 5% · **Certification:** CKNE (Certified Kubernetes Network Engineer)
>
> These exercises build a lab where every network layer (node NIC, conntrack, kube-proxy, the CNI datapath and CoreDNS) exposes Prometheus metrics. You then break things on purpose and find each failure through metrics alone. Each block ends with questions. The answers are collapsed at the end.

**Reference sources**

- CKNE program: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes metrics reference (kube-proxy, kubelet): https://kubernetes.io/docs/reference/instrumentation/metrics/
- kube-proxy flags and config: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- CoreDNS `prometheus` plugin: https://coredns.io/plugins/metrics/ · `forward` plugin: https://coredns.io/plugins/forward/
- DNS for Services and Pods (`ndots`, `dnsConfig`): https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Cilium metrics reference: https://docs.cilium.io/en/stable/observability/metrics/
- Cilium on kind: https://docs.cilium.io/en/stable/installation/kind/
- node_exporter: https://github.com/prometheus/node_exporter
- Prometheus histograms and quantiles: https://prometheus.io/docs/practices/histograms/
- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

---

## Where the metrics live

Keep this map open. When a metric seems to be missing, the cause is usually an endpoint bound to loopback or a target that is never scraped. The metric itself is rarely the problem.

| Component | Port | Path | Default bind | What it tells you |
|---|---|---|---|---|
| CoreDNS | 9153 | `/metrics` | `:9153` (all interfaces) | Query rate, rcodes, latency, cache, upstream health |
| kube-proxy | 10249 | `/metrics` | `127.0.0.1:10249` (loopback) | Rule sync latency, rule counts, programming lag |
| kube-proxy | 10256 | `/healthz` | `0.0.0.0:10256` | Liveness of the proxier (also used by cloud LBs for `externalTrafficPolicy: Local`) |
| Cilium agent | 9962 | `/metrics` | when `prometheus.enabled=true` | Drops by reason, BPF map pressure, endpoint state |
| Cilium operator | 9963 | `/metrics` | when `operator.prometheus.enabled=true` | IPAM, identity GC |
| Hubble | 9965 | `/metrics` | when `hubble.metrics.enabled` set | Flow-derived metrics: verdicts, drops, TCP flags, DNS, HTTP |
| node_exporter | 9100 | `/metrics` | host network | NIC bytes/drops/errors, conntrack, TCP stack counters |
| kubelet/cAdvisor | 10250 | `/metrics/cadvisor` | node IP, TLS + authn | Per-pod network bytes/packets/drops |

---

## Exercise 1 — Build the lab

**Goal:** a three-node kind cluster running Cilium as the CNI, with kube-proxy still in iptables mode so you can study it, and kube-prometheus-stack scraping everything.

**Prerequisites:** `docker`, `kind`, `kubectl`, `helm`, `jq`, `curl`.

### Steps

1. Save the cluster definition as `kind-netmetrics.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: netmetrics
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Create the cluster and confirm the nodes are `NotReady`. That is expected, because no CNI exists yet:

```bash
kind create cluster --config kind-netmetrics.yaml
kubectl get nodes
```

```
NAME                       STATUS     ROLES           AGE   VERSION
netmetrics-control-plane   NotReady   control-plane   40s   v1.3x.x
netmetrics-worker          NotReady   <none>          20s   v1.3x.x
netmetrics-worker2         NotReady   <none>          20s   v1.3x.x
```

3. Install kube-prometheus-stack **first**. Its `ServiceMonitor`/`PrometheusRule` CRDs must exist before the Cilium chart renders its own `ServiceMonitor` objects. The three `*NilUsesHelmValues=false` flags make Prometheus select monitors and rules from **any** release instead of only its own. Without them, the Cilium monitors and your own rules would be ignored silently.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set kubeEtcd.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set prometheus.prometheusSpec.scrapeInterval=15s \
  --set prometheus.prometheusSpec.evaluationInterval=15s \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
```

4. Install Cilium with agent, operator and Hubble metrics enabled, each with a `ServiceMonitor`:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm install cilium cilium/cilium --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --set operator.prometheus.enabled=true \
  --set operator.prometheus.serviceMonitor.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp}" \
  --set hubble.metrics.serviceMonitor.enabled=true
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl get nodes
```

5. Deploy the test workloads. Save as `netlab.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netlab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: netlab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: netlab
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: netlab
  labels:
    app: client
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:latest
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
---
apiVersion: v1
kind: Pod
metadata:
  name: iperf-server
  namespace: netlab
  labels:
    app: iperf-server
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:latest
      command: ["iperf3", "-s"]
      ports:
        - containerPort: 5201
```

```bash
kubectl apply -f netlab.yaml
kubectl -n netlab wait --for=condition=Ready pod --all --timeout=3m
kubectl -n netlab get pods -o wide
```

6. Open a tunnel to Prometheus and define a helper that prints query results. `prometheus-operated` is the governing Service the Prometheus Operator always creates, so its name does not depend on the Helm release name.

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null 2>&1 &
promq() {
  curl -s http://localhost:9090/api/v1/query --data-urlencode "query=$1" \
    | jq -r '.data.result[] | "\(.metric | del(.__name__)) => \(.value[1])"'
}
promq 'count by (job) (up)'
```

Example output (job names come from the chart; yours may differ slightly):

```
{"job":"apiserver"} => 1
{"job":"coredns"} => 2
{"job":"kube-proxy"} => 3
{"job":"kubelet"} => 9
{"job":"node-exporter"} => 3
...
```

7. Check health rather than presence. `count(up)` counts targets that are being **scraped**, whether or not the scrapes succeed:

```bash
promq 'up == 0'
```

### Questions

- **Q1.1** Why must kube-prometheus-stack be installed before the Cilium chart when `*.serviceMonitor.enabled=true`?
- **Q1.2** `count by (job) (up)` returns `3` for `kube-proxy`. Does that prove kube-proxy metrics are available? What query does?
- **Q1.3** Why did we set `serviceMonitorSelectorNilUsesHelmValues=false`, and what is the symptom if you forget it?

---

## Exercise 2 — Read raw endpoints before trusting a dashboard

**Goal:** go straight to each exporter with no Prometheus in between. On an exam node or during an incident this is often the only thing available.

### Steps

1. **CoreDNS.** Port-forward to the Deployment and look at the metric *types*:

```bash
kubectl -n kube-system port-forward deploy/coredns 9153:9153 >/dev/null 2>&1 &
sleep 2
curl -s localhost:9153/metrics | grep -E '^# TYPE coredns_(dns|cache|forward|proxy)'
```

Example output (exact names depend on the CoreDNS version):

```
# TYPE coredns_cache_entries gauge
# TYPE coredns_cache_hits_total counter
# TYPE coredns_cache_misses_total counter
# TYPE coredns_dns_request_duration_seconds histogram
# TYPE coredns_dns_requests_total counter
# TYPE coredns_dns_responses_total counter
# TYPE coredns_forward_healthcheck_broken_total counter
# TYPE coredns_forward_healthcheck_failures_total counter
# TYPE coredns_proxy_request_duration_seconds histogram
```

2. Look at one histogram's series:

```bash
curl -s localhost:9153/metrics | grep '^coredns_dns_request_duration_seconds' | head -20
```

```
coredns_dns_request_duration_seconds_bucket{server="dns://:53",type="A",zone=".",le="0.00025"} 812
coredns_dns_request_duration_seconds_bucket{server="dns://:53",type="A",zone=".",le="0.0005"} 1490
...
coredns_dns_request_duration_seconds_bucket{server="dns://:53",type="A",zone=".",le="+Inf"} 1602
coredns_dns_request_duration_seconds_sum{server="dns://:53",type="A",zone="."} 0.93
coredns_dns_request_duration_seconds_count{server="dns://:53",type="A",zone="."} 1602
```

3. **kube-proxy.** Its metrics port is normally bound to loopback on the node, so you query it *from the node*. In kind, a node is a Docker container:

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E 'metricsBindAddress|mode:'
docker exec netmetrics-worker curl -s 127.0.0.1:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules' | grep -v _bucket
docker exec netmetrics-worker curl -s 127.0.0.1:10256/healthz; echo
```

Example `healthz` output:

```
{"lastUpdated": "2026-09-30 10:12:44.1 +0000 UTC","currentTime": "2026-09-30 10:12:51.7 +0000 UTC", "nodeEligible": true}
```

4. **Cilium agent.** The agent ships its own metrics lister, so you can check a metric on the node without Prometheus:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg metrics list | grep -E 'drop_count|forward_count' | head
```

5. **Hubble metrics** come from a separate port on the same agent pod:

```bash
kubectl -n kube-system port-forward ds/cilium 9965:9965 >/dev/null 2>&1 &
sleep 2
curl -s localhost:9965/metrics | grep -E '^# TYPE hubble_'
```

### Questions

- **Q2.1** `coredns_dns_request_duration_seconds_bucket{le="0.0005"} 1490` and `{le="+Inf"} 1602`. What fraction of A queries finished within 0.5 ms since process start? Why is this number almost useless for alerting?
- **Q2.2** If `metricsBindAddress` shows `127.0.0.1:10249` (or is empty), what happens when Prometheus scrapes `<nodeIP>:10249`? What does `up` report?
- **Q2.3** In the `healthz` output, what does it mean if `lastUpdated` falls far behind `currentTime`?
- **Q2.4** `kubectl exec ds/cilium` picks **one** agent pod. Why does that matter when you look for drops for a specific pod?

---

## Exercise 3 — Fix a scrape target that is "up" in config but down in reality

**Goal:** make kube-proxy metrics reachable, and learn the security trade-off that comes with it.

### Steps

1. Check the target health:

```bash
promq 'up{job="kube-proxy"}'
```

If every value is `1`, your kind version already binds to `0.0.0.0`. Read along, then go to Exercise 4. If the values are `0`, continue.

2. Look at why the scrape fails, using the targets API:

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | select(.labels.job=="kube-proxy") | "\(.scrapeUrl) \(.health) \(.lastError)"'
```

```
http://172.18.0.3:10249/metrics down Get "http://172.18.0.3:10249/metrics": dial tcp 172.18.0.3:10249: connect: connection refused
```

3. Rebind the metrics server and roll the DaemonSet:

```bash
kubectl -n kube-system get cm kube-proxy -o yaml \
  | sed 's#metricsBindAddress: .*#metricsBindAddress: 0.0.0.0:10249#' \
  | kubectl apply -f -
kubectl -n kube-system rollout restart ds/kube-proxy
kubectl -n kube-system rollout status ds/kube-proxy
sleep 30
promq 'up{job="kube-proxy"}'
```

### Questions

- **Q3.1** The error says `connection refused`, not `i/o timeout`. What does each error tell you about the path between Prometheus and the target?
- **Q3.2** `0.0.0.0:10249` exposes unauthenticated metrics on every node IP. Name two production-grade ways to reduce that exposure while still scraping.
- **Q3.3** Why does editing the ConfigMap alone not change anything?

---

## Exercise 4 — DNS health: rate, rcode mix and the `ndots` amplifier

**Goal:** read DNS health as a *ratio*, and observe the query amplification caused by the default `ndots:5`.

### Steps

1. Inspect the client's resolver configuration:

```bash
kubectl -n netlab exec client -- cat /etc/resolv.conf
```

```
search netlab.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

2. Take a baseline of responses by rcode:

```bash
promq 'sum by (rcode) (increase(coredns_dns_responses_total[2m]))'
```

3. Generate 300 lookups of an **external** name that uses the search list. The name has fewer than 5 dots, so the resolver tries every search suffix first:

```bash
kubectl -n netlab exec client -- sh -c \
  'for i in $(seq 1 300); do dig +search +short api.github.com A >/dev/null; done'
```

4. Wait about 30 s (two scrape intervals), then compare:

```bash
promq 'sum by (rcode) (increase(coredns_dns_responses_total[2m]))'
```

Example output:

```
{"rcode":"NOERROR"} => 312
{"rcode":"NXDOMAIN"} => 905
```

5. Now repeat with a fully qualified name (trailing dot):

```bash
kubectl -n netlab exec client -- sh -c \
  'for i in $(seq 1 300); do dig +search +short api.github.com. A >/dev/null; done'
sleep 30
promq 'sum by (rcode) (increase(coredns_dns_responses_total[1m]))'
```

6. Compute the SERVFAIL and NXDOMAIN ratios the way you would alert on them. Division by a total always happens **after** aggregation:

```bash
promq 'sum(rate(coredns_dns_responses_total{rcode="NXDOMAIN"}[5m])) / sum(rate(coredns_dns_responses_total[5m]))'
promq 'sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m])) / sum(rate(coredns_dns_responses_total[5m]))'
```

7. Break down query volume by record type and transport:

```bash
promq 'sum by (type, proto) (rate(coredns_dns_requests_total[5m]))'
```

### Questions

- **Q4.1** For each `dig +search api.github.com`, how many queries reached CoreDNS, and why? Why might your NXDOMAIN:NOERROR ratio be *higher* than 3:1 on some hosts?
- **Q4.2** In production a high NXDOMAIN ratio is often "normal". When should it worry you, and which PromQL change would separate the harmless case from the harmful one?
- **Q4.3** Name three ways to cut the `ndots` amplification. Say which one is applied per pod and which is applied cluster-wide.
- **Q4.4** Why is `sum(rate(x{rcode="SERVFAIL"}[5m])) / sum(rate(x[5m]))` correct, while `rate(x{rcode="SERVFAIL"}[5m]) / rate(x[5m])` usually returns nothing?

---

## Exercise 5 — DNS latency and cache effectiveness

**Goal:** compute a correct p99 from a histogram and interpret cache metrics.

### Steps

1. p99 DNS latency across all CoreDNS replicas:

```bash
promq 'histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))'
```

2. The same, split per replica (`instance`) and per record type:

```bash
promq 'histogram_quantile(0.99, sum by (le, instance) (rate(coredns_dns_request_duration_seconds_bucket[5m])))'
promq 'histogram_quantile(0.99, sum by (le, type) (rate(coredns_dns_request_duration_seconds_bucket[5m])))'
```

3. Upstream latency only. This is time spent waiting for the `forward` target (metric name valid for CoreDNS ≥ 1.10; older versions use `coredns_forward_request_duration_seconds`):

```bash
curl -s localhost:9153/metrics | grep -E '^coredns_(proxy|forward)_request_duration_seconds_count'
promq 'histogram_quantile(0.99, sum by (le, to) (rate(coredns_proxy_request_duration_seconds_bucket[5m])))'
```

4. Cache hit ratio, plus what is currently cached:

```bash
promq 'sum(rate(coredns_cache_hits_total[5m])) / (sum(rate(coredns_cache_hits_total[5m])) + sum(rate(coredns_cache_misses_total[5m])))'
promq 'sum by (type) (coredns_cache_entries)'
promq 'sum by (type) (rate(coredns_cache_hits_total[5m]))'
```

5. Repeat the Exercise 4 load loop and re-run step 4. Watch the `denial` hits climb.

### Questions

- **Q5.1** Why must you `sum by (le)` **after** `rate()` and **before** `histogram_quantile()`? What goes wrong if you compute a quantile per replica and then average them?
- **Q5.2** Your p99 comes back as exactly `0.256`, which is the upper edge of one bucket, and stays there. What does that tell you about the true value?
- **Q5.3** Cache `type="denial"` hits are high. Is that good or bad here, and what does it say about your workload?
- **Q5.4** Overall p99 is 180 ms, but the `coredns_proxy_request_duration_seconds` p99 is 170 ms. Where would you look next, and where would you *not* look?

---

## Exercise 6 — kube-proxy: rule sync cost and programming lag

**Goal:** see how Service count drives iptables sync cost, and detect a stuck proxier.

### Steps

1. Confirm the metrics your version exposes. Names have changed across releases; the source of truth is the Kubernetes metrics reference:

```bash
docker exec netmetrics-worker curl -s 127.0.0.1:10249/metrics \
  | grep -E '^# TYPE kubeproxy_' | awk '{print $3, $4}'
```

2. Baseline:

```bash
promq 'sum by (instance, table) (kubeproxy_sync_proxy_rules_iptables_total)'
promq 'histogram_quantile(0.99, sum by (le, instance) (rate(kubeproxy_sync_proxy_rules_duration_seconds_bucket[5m])))'
```

3. Create 300 Services, all selecting the existing `web` pods, so each one produces real endpoint rules:

```bash
for i in $(seq 1 300); do
  kubectl -n netlab create service clusterip "bulk-$i" --tcp=80:80 --dry-run=client -o yaml \
    | sed 's/app: bulk-'"$i"'/app: web/'
  echo '---'
done | kubectl apply -f - >/dev/null
kubectl -n netlab get svc --no-headers | wc -l
```

4. Wait a minute and query again:

```bash
promq 'sum by (instance, table) (kubeproxy_sync_proxy_rules_iptables_total)'
promq 'histogram_quantile(0.99, sum by (le, instance) (rate(kubeproxy_sync_proxy_rules_duration_seconds_bucket[5m])))'
promq 'histogram_quantile(0.99, sum by (le) (rate(kubeproxy_network_programming_duration_seconds_bucket[5m])))'
```

5. Staleness check. The proxier records when a sync was *requested* and when one *completed*:

```bash
promq 'time() - max by (instance) (kubeproxy_sync_proxy_rules_last_timestamp_seconds)'
promq 'max by (instance) (kubeproxy_sync_proxy_rules_last_queued_timestamp_seconds) - max by (instance) (kubeproxy_sync_proxy_rules_last_timestamp_seconds)'
```

6. Cross-check against the node. Metrics describe what kube-proxy *thinks* it did; the kernel shows what exists:

```bash
docker exec netmetrics-worker sh -c 'iptables-save -t nat | grep -c "^-A KUBE-SVC-"'
```

7. Clean up the bulk Services:

```bash
kubectl -n netlab get svc -o name | grep bulk- | xargs kubectl -n netlab delete >/dev/null
```

### Questions

- **Q6.1** What is the difference between `kubeproxy_sync_proxy_rules_duration_seconds` and `kubeproxy_network_programming_duration_seconds`? Which one maps to the user-visible symptom "the new pod gets no traffic for 20 s"?
- **Q6.2** Why is `time() - last_timestamp_seconds > N` a weak staleness alert, and why is `last_queued - last_timestamp > N` a stronger one?
- **Q6.3** With Cilium in `kubeProxyReplacement=true` mode, which of these queries return nothing, and where would the equivalent signal come from?
- **Q6.4** Since Kubernetes 1.28 the iptables proxier does partial syncs by default. How can that make the duration histogram look healthier than a worst-case full sync?

---

## Exercise 7 — Node and pod level: throughput, drops, conntrack, retransmissions

**Goal:** tell apart the host network namespace (node_exporter) and pod network namespaces (cAdvisor), and see what each one can and cannot show.

### Steps

1. Generate 60 s of traffic from `client` to `iperf-server`:

```bash
IPERF_IP=$(kubectl -n netlab get pod iperf-server -o jsonpath='{.status.podIP}')
kubectl -n netlab exec client -- iperf3 -c "$IPERF_IP" -t 60 >/tmp/iperf-clean.txt &
sleep 40
```

2. While it runs, compare pod-level throughput with node-level throughput (bits per second):

```bash
promq 'sum by (pod) (rate(container_network_transmit_bytes_total{namespace="netlab"}[1m])) * 8'
promq 'sum by (instance, device) (rate(node_network_transmit_bytes_total{device!~"lo|lxc.*|cilium.*"}[1m])) * 8'
```

3. Interface error and drop counters. These are the first place to look for NIC, ring-buffer or driver trouble:

```bash
promq 'sum by (instance, device) (rate(node_network_receive_drop_total[5m]))'
promq 'sum by (instance, device) (rate(node_network_receive_errs_total[5m]))'
promq 'sum by (namespace, pod) (rate(container_network_receive_packets_dropped_total{namespace="netlab"}[5m]))'
```

4. Conntrack utilization, cross-checked against the kernel:

```bash
promq 'max by (instance) (node_nf_conntrack_entries / node_nf_conntrack_entries_limit)'
docker exec netmetrics-worker sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max'
```

5. Inject 5% packet loss **inside the client pod's network namespace** (this is why the pod has `NET_ADMIN`):

```bash
wait
kubectl -n netlab exec client -- tc qdisc add dev eth0 root netem loss 5%
kubectl -n netlab exec client -- nstat -n
kubectl -n netlab exec client -- iperf3 -c "$IPERF_IP" -t 30 | tail -4
kubectl -n netlab exec client -- nstat -az TcpRetransSegs TcpOutSegs
```

Example output:

```
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-30.00  sec   402 MBytes   112 Mbits/sec  2381             sender
...
#kernel
TcpRetransSegs                  2381               0.0
TcpOutSegs                      279311             0.0
```

6. Now ask the node-level metric about the same period, for the node where `client` runs:

```bash
CLIENT_NODE=$(kubectl -n netlab get pod client -o jsonpath='{.spec.nodeName}')
echo "$CLIENT_NODE"
promq 'rate(node_netstat_Tcp_RetransSegs[2m]) / rate(node_netstat_Tcp_OutSegs[2m])'
```

7. Remove the impairment:

```bash
kubectl -n netlab exec client -- tc qdisc del dev eth0 root
```

8. Listen-queue overflows. These are a server-side saturation signal that shows up as client SYN timeouts:

```bash
promq 'sum by (instance) (rate(node_netstat_TcpExt_ListenOverflows[5m]))'
```

### Questions

- **Q7.1** The pod saw ~0.85% retransmissions (2381/279311), yet the node's `node_netstat_Tcp_RetransSegs` ratio barely moved. Why? What *would* make the node metric move?
- **Q7.2** In step 2, why do we exclude `lxc.*` and `cilium.*` devices from the node query? What would you double-count if you didn't?
- **Q7.3** `node_nf_conntrack_entries / node_nf_conntrack_entries_limit` reaches 1.0. What exact symptom do users see, and which kernel log line confirms it?
- **Q7.4** In kind, every "node" shares one kernel. How does that distort the conntrack and NIC readings compared with a real cluster?
- **Q7.5** `node_network_receive_drop_total` rises on `eth0` while `node_network_receive_errs_total` stays flat. List two likely causes and the node-level command you would check next.

---

## Exercise 8 — CNI datapath: drops by reason with Cilium and Hubble

**Goal:** make the datapath tell you *why* packets die, and learn the difference between agent metrics and flow metrics.

### Steps

1. Baseline:

```bash
promq 'sum by (reason, direction) (rate(cilium_drop_count_total[2m]))'
promq 'sum by (verdict) (rate(hubble_flows_processed_total[2m]))'
```

2. Apply a default-deny ingress policy to the `web` pods. Save as `deny-web.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-default-deny-ingress
  namespace: netlab
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-web.yaml
kubectl -n netlab exec client -- sh -c \
  'for i in $(seq 1 20); do curl -s -o /dev/null -m 1 http://web || true; done'
```

3. Query the drop metrics from both sources:

```bash
sleep 30
promq 'sum by (reason, direction) (increase(cilium_drop_count_total[2m]))'
promq 'sum by (reason, protocol) (increase(hubble_drop_total[2m]))'
promq 'sum by (verdict) (increase(hubble_flows_processed_total[2m]))'
```

Example output:

```
{"direction":"INGRESS","reason":"Policy denied"} => 42
{"protocol":"TCP","reason":"POLICY_DENIED"} => 42
{"verdict":"DROPPED"} => 42
{"verdict":"FORWARDED"} => 1870
```

4. Find the agent on the node where a `web` pod runs and look at the flows themselves. Metrics tell you *how many*; flows tell you *who*:

```bash
WEB_NODE=$(kubectl -n netlab get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName="$WEB_NODE" -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
  hubble observe --namespace netlab --verdict DROPPED --last 5
```

```
Sep 30 10:41:02.117: netlab/client:48122 (ID:28411) <> netlab/web-6d8f7c9b8-x2k4q:80 (ID:9120) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 10:41:02.117: netlab/client:48122 (ID:28411) <> netlab/web-6d8f7c9b8-x2k4q:80 (ID:9120) Policy denied DROPPED (TCP Flags: SYN)
```

5. Datapath capacity. BPF maps have a fixed size; when a map fills, new flows get dropped:

```bash
promq 'max by (map_name) (cilium_bpf_map_pressure)'
promq 'sum by (endpoint_state) (cilium_endpoint_state)'
```

6. Remove the policy and confirm the drops stop:

```bash
kubectl delete -f deny-web.yaml
kubectl -n netlab exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web
```

### Questions

- **Q8.1** `cilium_drop_count_total` labels the reason `Policy denied`, while `hubble_drop_total` labels it `POLICY_DENIED`. Why do the two exist side by side, and which one is still there if Hubble is disabled?
- **Q8.2** Policy drops are *intended* behaviour. Write a PromQL expression that alerts only on drops that are **not** policy verdicts.
- **Q8.3** Why do we not add `source_pod` / `destination_pod` labels to Hubble metrics by default, even though they would make this exercise easier?
- **Q8.4** `cilium_bpf_map_pressure{map_name=~".*ct.*"}` approaches 1.0. What user-visible failure do you expect, and how is it related to Q7.3?
- **Q8.5** `hubble_dns_queries_total` returned nothing even though `dns` is in `hubble.metrics.enabled`. Why?

---

## Exercise 9 — Incident drill: upstream DNS failure

**Goal:** diagnose a partial DNS outage from metrics alone: internal names work, external names fail.

### Steps

1. Point CoreDNS at an unreachable upstream. `192.0.2.0/24` is TEST-NET-1, which is guaranteed not to route:

```bash
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' > /tmp/Corefile.orig
kubectl -n kube-system get cm coredns -o yaml \
  | sed 's#forward . /etc/resolv.conf#forward . 192.0.2.53#' \
  | kubectl apply -f -
```

2. Wait for the `reload` plugin to pick up the change (up to ~45 s), then generate a mix of internal and external lookups:

```bash
sleep 45
kubectl -n netlab exec client -- sh -c '
  for i in $(seq 1 30); do
    dig +short +tries=1 +timeout=2 web.netlab.svc.cluster.local >/dev/null
    dig +short +tries=1 +timeout=2 example.com. >/dev/null
  done'
```

3. Diagnose using only metrics:

```bash
promq 'sum by (rcode) (increase(coredns_dns_responses_total[2m]))'
promq 'sum by (plugin, rcode) (increase(coredns_dns_responses_total[2m]))'
promq 'sum by (to) (increase(coredns_forward_healthcheck_failures_total[2m]))'
promq 'sum(increase(coredns_forward_healthcheck_broken_total[5m]))'
promq 'histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[2m])))'
```

4. Restore the original upstream:

```bash
kubectl -n kube-system get cm coredns -o yaml \
  | sed 's#forward . 192.0.2.53#forward . /etc/resolv.conf#' \
  | kubectl apply -f -
sleep 45
kubectl -n netlab exec client -- dig +short example.com.
```

### Questions

- **Q9.1** Which label on `coredns_dns_responses_total` lets you tell, in a single query, that cluster names are healthy while external names fail?
- **Q9.2** `forward_healthcheck_failures_total` increases per upstream. What does `forward_healthcheck_broken_total` mean, and what does `forward` do in that state?
- **Q9.3** Overall p99 latency jumped even though half the queries (internal ones) were fast. Explain in terms of the histogram.
- **Q9.4** A teammate says "CoreDNS is fine: the pods are Running, readiness is green". Which CoreDNS endpoint backs readiness, and why does it not catch this failure?

---

## Exercise 10 — Encode it: recording rules and alerts

**Goal:** turn the queries from Exercises 4–9 into a `PrometheusRule` that production can run.

### Steps

1. Save as `network-health-rules.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: network-health
  namespace: monitoring
spec:
  groups:
    - name: network-health.recording
      interval: 30s
      rules:
        - record: rcode:coredns_dns_responses:ratio_rate5m
          expr: |
            sum by (rcode) (rate(coredns_dns_responses_total[5m]))
              / ignoring (rcode) group_left
            sum(rate(coredns_dns_responses_total[5m]))
        - record: cluster:coredns_dns_request_duration_seconds:p99_rate5m
          expr: |
            histogram_quantile(0.99,
              sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))
        - record: instance:node_nf_conntrack:utilization
          expr: |
            node_nf_conntrack_entries / node_nf_conntrack_entries_limit
        - record: instance:node_tcp_retrans:ratio_rate5m
          expr: |
            rate(node_netstat_Tcp_RetransSegs[5m])
              / clamp_min(rate(node_netstat_Tcp_OutSegs[5m]), 1)
    - name: network-health.alerts
      rules:
        - alert: CoreDNSServfailRatioHigh
          expr: |
            rcode:coredns_dns_responses:ratio_rate5m{rcode="SERVFAIL"} > 0.01
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "CoreDNS SERVFAIL ratio is {{ $value | humanizePercentage }}"
            description: "Check the forward upstreams with coredns_forward_healthcheck_failures_total."
        - alert: CoreDNSLatencyHigh
          expr: |
            cluster:coredns_dns_request_duration_seconds:p99_rate5m > 0.25
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "CoreDNS p99 latency is {{ $value | humanizeDuration }}"
        - alert: KubeProxyRuleSyncStuck
          expr: |
            (
              kubeproxy_sync_proxy_rules_last_queued_timestamp_seconds
              - kubeproxy_sync_proxy_rules_last_timestamp_seconds
            ) > 120
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "kube-proxy on {{ $labels.instance }} has pending changes it has not programmed"
        - alert: NodeConntrackNearLimit
          expr: |
            instance:node_nf_conntrack:utilization > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Conntrack table on {{ $labels.instance }} is {{ $value | humanizePercentage }} full"
        - alert: NodeTcpRetransmissionsHigh
          expr: |
            instance:node_tcp_retrans:ratio_rate5m > 0.02
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Host-namespace TCP retransmission ratio on {{ $labels.instance }} is {{ $value | humanizePercentage }}"
        - alert: NodeNetworkReceiveDrops
          expr: |
            sum by (instance, device) (
              rate(node_network_receive_drop_total{device!~"lo|lxc.*|cilium.*|veth.*"}[5m])
            ) > 10
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.instance }}/{{ $labels.device }} drops {{ $value }} packets/s on receive"
        - alert: CiliumUnexpectedDrops
          expr: |
            sum by (reason) (
              rate(cilium_drop_count_total{reason!~"Policy denied|Policy denied by denylist"}[5m])
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cilium datapath drops for reason {{ $labels.reason }} at {{ $value }}/s"
        - alert: CiliumBpfMapPressure
          expr: |
            max by (map_name) (cilium_bpf_map_pressure) > 0.9
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "BPF map {{ $labels.map_name }} is {{ $value | humanizePercentage }} full"
```

2. Apply it and confirm Prometheus loaded it (a rule file that fails to load is ignored without any other visible error):

```bash
kubectl apply -f network-health-rules.yaml
sleep 30
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[] | select(.name|startswith("network-health")) | .rules[] | "\(.name) \(.health) \(.lastError // "")"'
```

```
rcode:coredns_dns_responses:ratio_rate5m ok
cluster:coredns_dns_request_duration_seconds:p99_rate5m ok
...
CiliumBpfMapPressure ok
```

3. Fire one alert on purpose: repeat Exercise 9 step 1 and keep generating external lookups for 6 minutes. Then:

```bash
curl -s http://localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | "\(.labels.alertname) \(.state)"'
```

Restore CoreDNS afterwards (Exercise 9 step 4).

### Questions

- **Q10.1** Why does `instance:node_tcp_retrans:ratio_rate5m` use `clamp_min(..., 1)` in the denominator?
- **Q10.2** Explain `/ ignoring (rcode) group_left` in the first recording rule. What error do you get without `group_left`?
- **Q10.3** Why record the p99 instead of computing it inside each alert, and what is the risk of recording a quantile and then aggregating it again?
- **Q10.4** Which alert in this file is known to be blind to pod-level traffic, and what would you add to cover that gap?

---

## Cleanup

```bash
pkill -f 'kubectl.*port-forward' || true
kind delete cluster --name netmetrics
```

---

## Answers

<details>
<summary><strong>Exercise 1</strong></summary>

**Q1.1** With `serviceMonitor.enabled=true` the Cilium chart renders `monitoring.coreos.com/v1` `ServiceMonitor` objects. If that CRD does not exist yet, the install fails with `no matches for kind "ServiceMonitor"`. The chart has a `trustCRDsExist` escape hatch for templating pipelines, but in a live install the CRD must be registered first.

**Q1.2** No. `up` has one series per target, whatever the scrape result, so `count(up)` counts targets Prometheus *tried* to scrape. Availability is `up{job="kube-proxy"} == 1`, or better `min by (job) (up)`. Better still, check that a real series exists: `count(kubeproxy_sync_proxy_rules_duration_seconds_count)`.

**Q1.3** By default kube-prometheus-stack sets the Prometheus `serviceMonitorSelector` to `release: <its release name>`, so it only picks up monitors carrying that label. Monitors from other charts (Cilium) and your own `PrometheusRule` objects would exist in the API but never appear in Prometheus. The symptom is silent: no error, no target, no rule. Setting the flag to `false` makes the selector empty, which means "select all".

</details>

<details>
<summary><strong>Exercise 2</strong></summary>

**Q2.1** 1490 / 1602 ≈ 93%. The counters are cumulative since process start. They mix a day of history with the last minute and never drop, so a latency regression barely moves them. Alerts must use `rate()` over a window, then `histogram_quantile()`.

**Q2.2** The kernel refuses the connection on the node IP, because nothing listens there, only on `127.0.0.1`. Prometheus marks the target `up = 0`, and `lastError` shows `connection refused`.

**Q2.3** kube-proxy's last successful sync happened long ago. The proxier is stuck, crashing in its sync loop or unable to reach the API server. Once the gap exceeds the configured threshold, `/healthz` also starts returning 503. Load balancers that use this port for `externalTrafficPolicy: Local` will then take the node out of rotation.

**Q2.4** Cilium metrics are **per node**: each agent counts only the packets its own datapath handled. A policy drop at a `web` pod's ingress is counted by the agent on *that pod's* node. Execing into a random agent can show zero drops and mislead you. Aggregate in Prometheus, or pick the agent with `--field-selector spec.nodeName=`.

</details>

<details>
<summary><strong>Exercise 3</strong></summary>

**Q3.1** `connection refused` means the packet reached the host and the kernel answered with a RST, because nothing is listening on that IP:port. Routing and firewalling are fine; the bind address is wrong. `i/o timeout` means no answer came back at all. Suspect a firewall, a security group, a NetworkPolicy on the Prometheus side, or a routing problem.

**Q3.2** (a) Bind to the node's internal IP only, or keep loopback and scrape through a node-local sidecar or proxy (for example kube-rbac-proxy) that adds authn/authz and TLS. (b) Restrict port 10249 with host firewall rules or cloud security groups to the monitoring subnet. With Cilium, host firewall policies can do this too. Scraping over a private network from a dedicated monitoring node pool also narrows exposure.

**Q3.3** kube-proxy reads its configuration file once at startup; the ConfigMap is mounted as a file. The pods have to be restarted, and `rollout restart` does that by changing a pod-template annotation.

</details>

<details>
<summary><strong>Exercise 4</strong></summary>

**Q4.1** `api.github.com` has two dots, fewer than `ndots:5`, so the resolver treats it as relative. It tries `api.github.com.netlab.svc.cluster.local`, `.svc.cluster.local`, `.cluster.local` (three NXDOMAIN) and then the absolute name (NOERROR): four queries per lookup. The ratio can be higher because (a) the node's own search domains, inherited by kind from the Docker host, are appended to the pod's search list, adding more NXDOMAINs, and (b) many resolvers (glibc, musl) also send AAAA queries in parallel, which doubles everything. `dig` sends only the type you ask for, but real applications usually send both.

**Q4.2** NXDOMAIN from search-list expansion is noise, but it is a *cost*: CoreDNS load, conntrack entries for UDP, latency multiplied per lookup. It becomes harmful when (a) it drives CoreDNS CPU or latency up, or (b) the NXDOMAIN answers are for names that *should* exist: a typo in a Service name, a deleted Service. To separate the two, split by `type` and compare with the NOERROR rate. A rising NXDOMAIN rate while NOERROR stays flat suggests a broken client, not ndots. Hubble's `hubble_dns_responses_total` with query labels, or the CoreDNS `log` plugin sampled, shows *which* names.

**Q4.3** (a) Per pod: `spec.dnsConfig.options: [{name: ndots, value: "2"}]`. (b) Per call: use FQDNs with a trailing dot in application config. (c) Cluster-wide: enable CoreDNS `autopath @kubernetes`, which answers the search chain server-side in one round trip (it needs `pods verified`, which costs memory). NodeLocal DNSCache does not remove the queries, but it absorbs them on the node, reducing latency and conntrack pressure on UDP.

**Q4.4** Binary operators match series by **all** labels. The numerator has `rcode="SERVFAIL"`, while the denominator series carry other rcodes as well as other labels (`plugin`, `instance`, `server`, `zone`). The only matching pair is SERVFAIL/SERVFAIL, which gives 1, or nothing at all if SERVFAIL is zero. Summing both sides to the same label set (here none) makes them match one-to-one.

</details>

<details>
<summary><strong>Exercise 5</strong></summary>

**Q5.1** Buckets are counters, so you first turn them into per-second rates, then add the rates of the same `le` across replicas and types into one combined distribution, and only then interpolate the quantile. Averaging per-replica quantiles is mathematically wrong: quantiles do not compose. One slow replica serving 5% of traffic can have a terrible p99 that the average hides, or it can exaggerate its weight.

**Q5.2** `histogram_quantile` interpolates linearly *inside* the bucket where the rank falls. A value pinned to a boundary usually means the rank lands at the edge of a bucket that holds most of the mass. The real p99 is anywhere in that bucket's range, with no finer resolution. For finer answers, use native histograms (if enabled), narrower buckets, or trust `_sum/_count` for the mean.

**Q5.3** Here it is good for CoreDNS, which answers the repeated search-list NXDOMAINs from cache instead of re-running the `kubernetes` plugin or the upstream. It is also a symptom: the workload makes lots of queries that are *meant* to fail, which is the ndots amplification. Denial caching is controlled by `cache`'s `denial` settings; a TTL too long can hide a newly created Service for that long.

**Q5.4** Nearly all end-to-end latency is upstream wait, so look at `forward` targets: the node's `/etc/resolv.conf` resolvers, the VPC DNS, a corporate resolver and the network path to it, including egress conntrack or SNAT. Do not start with CoreDNS CPU or the `kubernetes` plugin; they account for ~10 ms.

</details>

<details>
<summary><strong>Exercise 6</strong></summary>

**Q6.1** `sync_proxy_rules_duration_seconds` measures how long one sync loop run takes (build the ruleset plus `iptables-restore`). `network_programming_duration_seconds` measures the end-to-end time from the object change in the API (for example an EndpointSlice update) until the rules are programmed on that node. It includes queueing, API watch delay and the sync. The "new pod gets no traffic" symptom maps to network programming duration.

**Q6.2** kube-proxy re-syncs periodically even when nothing changes, so `last_timestamp` keeps moving on an idle cluster. A 5-minute threshold works, but it can only tell you "no sync at all". It misses a proxier that syncs but keeps failing to apply part of the rules, and it needs tuning against `syncPeriod`/`minSyncPeriod`. `last_queued - last_timestamp` is positive only when a change is **waiting** longer than the last completion, which is exactly "there is work kube-proxy has not done". It is near zero or negative when idle, so it has no false positives from quiet clusters.

**Q6.3** All `kubeproxy_*` queries, and `up{job="kube-proxy"}`, because kube-proxy is not deployed. Service load-balancing moves into eBPF. The equivalent signals are Cilium's: `cilium_bpf_map_pressure` on the LB/service maps, `cilium_services_events_total`, datapath drop reasons such as `No service backend`, and agent-side Kubernetes event processing metrics (`cilium_k8s_client_*`, `cilium_kubernetes_events_total`).

**Q6.4** A partial sync only rewrites the chains for Services whose endpoints changed. Most samples in the histogram are cheap partials, so p99 hides the full-sync cost that still happens periodically and after some changes. On versions that expose separate `kubeproxy_sync_full_proxy_rules_duration_seconds` and `..._partial_...` histograms, alert on the full one.

</details>

<details>
<summary><strong>Exercise 7</strong></summary>

**Q7.1** `/proc/net/snmp` and `/proc/net/netstat` are **per network namespace**. node_exporter runs with `hostNetwork: true`, so it reads the host namespace's TCP stack. The client pod's TCP connection lives in the pod namespace, and its retransmit counters are there. The node metric moves only for host-namespace sockets: kubelet, hostNetwork pods, NodePort traffic terminated on the host, or proxies running on the host. Pod-level visibility needs pod-scoped tooling: `nstat` in the pod, eBPF-based exporters, or Hubble's flow data.

**Q7.2** With a veth-based CNI, every pod byte crosses the pod's host-side veth (`lxc*` in Cilium) **and** the node's uplink (`eth0`) when it leaves the node. `cilium_host`, `cilium_net` and overlay devices (`cilium_vxlan`) carry the same bytes again. Summing all devices counts the same traffic two or three times. Keep uplink devices only for node throughput, and use cAdvisor's per-pod metrics for pod throughput.

**Q7.3** New connections fail: SYNs or first UDP packets are dropped before they reach the application. Clients see random connect timeouts while established connections keep working. The kernel logs `nf_conntrack: table full, dropping packet`. `node_nf_conntrack_stat_*` metrics (if that collector is enabled) show rising `drop`/`insert_failed`. DNS over UDP is often the first victim.

**Q7.4** All kind nodes are containers on one host kernel. `nf_conntrack_max` is a host-wide limit, and NIC counters on `eth0` describe a Docker veth, not a physical NIC. Physical ring-buffer drops, driver errors and real link capacity cannot show up. Use kind for learning the queries, not for sizing.

**Q7.5** Likely causes: the RX ring buffer overflows under bursts (`ethtool -S eth0 | grep -iE 'drop|miss|fifo'`, `ethtool -g eth0`), softirq/NAPI backlog exhaustion (`/proc/net/softnet_stat`, second column), or packets the stack deliberately discards (unknown VLAN, wrong protocol). Errors staying flat points to capacity or configuration rather than a physical or CRC fault. Also check that the RX queue IRQs are not all pinned to one CPU (`/proc/interrupts`).

</details>

<details>
<summary><strong>Exercise 8</strong></summary>

**Q8.1** `cilium_drop_count_total` is a counter maintained by the agent from datapath drop notifications, with a human-readable reason string. It is part of the agent metrics (`prometheus.enabled`) and stays available without Hubble. `hubble_drop_total` is derived from Hubble's flow stream and uses the protobuf `DropReason` enum names. It exists only when Hubble and its `drop` metric are on, and it can carry extra context labels (namespace, workload) if you configure them.

**Q8.2**

```
sum by (reason) (rate(cilium_drop_count_total{reason!~"Policy denied.*"}[5m])) > 0
```

(The file in Exercise 10 lists the policy reasons explicitly and uses a threshold to avoid alerting on single packets. Reasons such as `Stale or unroutable IP`, `Invalid source ip`, `CT: Map insertion failed` or `No mapping for NAT masquerade` point to datapath or state bugs, not intent.)

**Q8.3** Cardinality. Every label combination is a separate time series. Pod-level labels multiply series by (pods × peers × reasons × protocols) and churn with every rollout, which makes Prometheus memory and query cost blow up. Use per-workload context sparingly (`labelsContext=source_namespace,destination_namespace,...`), and answer the "who" through flows (`hubble observe`), not metrics.

**Q8.4** The eBPF conntrack map is full, so new connections cannot be tracked. The agent garbage-collects entries, but between GC runs inserts fail, and you see drops with a CT-insert reason and timeouts on new connections. It is the eBPF counterpart of Q7.3's netfilter table: same symptom, different table. With kube-proxy in iptables mode you can exhaust either or both. Fixes are sizing (`bpf.ctTcpMax`/`bpf.ctAnyMax` or `bpf.mapDynamicSizeRatio`) and finding the flow leak (short-lived UDP, scanners).

**Q8.5** Hubble learns DNS names only when DNS traffic passes through Cilium's L7 DNS proxy. That happens only for endpoints selected by a `CiliumNetworkPolicy` with `toPorts.rules.dns` (for example `matchPattern: "*"`). Without such a policy, DNS packets are only L3/L4 flows, and the `dns` metric handler has nothing to count.

</details>

<details>
<summary><strong>Exercise 9</strong></summary>

**Q9.1** `plugin`. Internal answers are labelled `plugin="kubernetes"` with `rcode="NOERROR"`, while external answers failing inside `forward` show up as `rcode="SERVFAIL"` attributed to `forward` (or with an empty `plugin` when the error is written by the server). `sum by (plugin, rcode)` shows both populations at once.

**Q9.2** `healthcheck_failures_total{to=...}` counts failed health probes against one upstream. `healthcheck_broken_total` increases when **all** upstreams are unhealthy at once. In that state `forward` still sends queries to a randomly picked upstream, on the assumption that the health checks may be wrong, so clients see slow SERVFAILs rather than immediate ones.

**Q9.3** p99 is the value below which 99% of observations fall. If ~50% of queries take seconds (upstream timeout before SERVFAIL), the 99th percentile rank falls well inside the slow population, so the fast half cannot pull it down. Even a few percent of slow queries is enough to own the p99. That is why tail latency catches partial failures that averages hide.

**Q9.4** Readiness uses the `ready` plugin (`:8181/ready`), which reports whether each plugin that implements readiness is ready. For `kubernetes` that means its API caches have synced. Liveness uses `health` (`:8080/health`). Neither probes the upstream path. A CoreDNS that serves the cluster zone perfectly while every external lookup fails is "Ready". Only the rcode and latency metrics show the outage.

</details>

<details>
<summary><strong>Exercise 10</strong></summary>

**Q10.1** On an idle host `rate(OutSegs)` can be 0, and dividing by zero produces `NaN` or `+Inf`, which causes spurious alert flapping or holes in the data. `clamp_min(..., 1)` floors the denominator at 1 segment/s: the ratio stays defined, and it stays near zero when there is no traffic.

**Q10.2** The left side has one series per `rcode`; the right side is a single series with no labels. `ignoring (rcode)` tells the matcher to ignore `rcode` when pairing, so every left series matches the one right series. That is a many-to-one match, and `group_left` declares that the left ("many") side keeps its labels. Without it, Prometheus returns `many-to-one matching must be explicit (group_left/group_right)`.

**Q10.3** Recording rules evaluate the expensive `sum by (le)` over every bucket series once per interval instead of in every alert and dashboard panel, and they give alerts a stable, cheap series. The risk: a recorded quantile is a final number. Averaging, summing or taking a max of recorded p99s across clusters or instances is statistically meaningless (see Q5.1). If you need to aggregate further, record the **bucket rates** (`sum by (le, cluster) (rate(..._bucket[5m]))`) and compute the quantile at the end.

**Q10.4** `NodeTcpRetransmissionsHigh`, because it reads only the host network namespace (Q7.1). Complement it with pod-scope signals: Hubble flow metrics (`hubble_tcp_flags_total` for RST/SYN patterns, `hubble_flows_processed_total` by verdict), application-level RED metrics, and, where available, an eBPF exporter that reads per-socket TCP retransmissions across namespaces. `NodeNetworkReceiveDrops` is also blind to per-pod veth drops by design; `container_network_receive_packets_dropped_total` covers those.

</details>