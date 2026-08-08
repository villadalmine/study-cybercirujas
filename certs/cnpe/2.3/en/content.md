# 2.3 Diagnosing and Remediating Platform Issues and Incident Scenarios

> **Domain 2 — Platform Operations · Exam weight: 6.67%**
> Certified Cloud Native Platform Engineer (CNPE)

---

## 1. The production problem: a platform is a control loop under duress

A platform is not the sum of its Kubernetes clusters. It is the *contract* the platform team offers to internal consumers — self-service APIs, golden paths, guaranteed SLOs — and the machinery that keeps that contract true while the substrate underneath it (nodes, CNI, CSI, control plane, the cloud provider) fails continuously and independently. Incident diagnosis on a platform is therefore fundamentally different from debugging a single application:

- **The blast radius is multi-tenant.** A saturated `kube-apiserver`, an exhausted CNI IP pool, a wedged admission webhook, or a throttled etcd degrades *every* workload at once. The question is rarely "why is this pod broken" and almost always "which shared dependency is failing, and how many tenants does it take down."
- **The failure is usually emergent, not local.** A node runs out of ephemeral storage → kubelet starts evicting → evicted pods reschedule onto the next node → that node fills → cascading eviction. No single component is "buggy." The *interaction* is the incident.
- **Signal is drowned by scale.** A 200-node cluster emits millions of events per minute. The diagnostic skill is not "read the logs," it is *knowing which of dozens of signals to pull first, in what order, and what a healthy baseline looks like.*
- **You operate the diagnosis surface itself.** When Prometheus is down you cannot query metrics; when the API server is throttled `kubectl` hangs. A platform engineer must diagnose *through* a degraded control plane, which means understanding what still works when the primary tools do not.

The architectural consequence: **diagnosis must be layered and hypothesis-driven**, not a random walk through dashboards. The rest of this topic builds that layered method, the signals each layer exposes, and the remediation patterns — from immediate mitigation to durable fix — that a CNPE is expected to execute under a live incident.

The framing throughout follows the incident lifecycle codified by Google SRE and the CNCF TAG App Delivery / Observability guidance:

```
Detect → Triage → Diagnose → Mitigate → Remediate → Learn
   │        │         │          │           │          │
  SLO/    severity  root-cause  restore    permanent  blameless
  alert   + scope   isolation   service    fix        postmortem
```

**Mitigate before you remediate.** The first job under an incident is to stop the bleeding (restore the SLO), *not* to find the root cause. Root-causing a saturated API server while customers are down is a career-limiting mistake. Diagnosis to the point of *safe mitigation* is the priority; full root cause belongs to the postmortem.

---

## 2. The diagnostic method: signals, layers, and structured reasoning

### 2.1 The four telemetry signals and when each wins

| Signal | Answers | Cardinality cost | Latency to insight | Best first move for… |
|---|---|---|---|---|
| **Metrics** | "Is it broken, how badly, since when?" | Low (aggregated) | Seconds (pre-aggregated) | Detection, trend, saturation, SLO burn |
| **Logs** | "What exactly happened in this component?" | High (per-event) | Seconds–minutes (need query) | Error messages, stack traces, admission denials |
| **Traces** | "Where in the request path is the latency/error?" | Very high (per-span) | Minutes (need sampling + query) | Distributed latency, cross-service errors |
| **Events (k8s)** | "What did the control plane decide/try?" | Medium (ephemeral, 1h TTL) | Seconds | Scheduling, eviction, image pull, probe failures |

The exam-relevant judgment is **ordering**: metrics tell you *that* and *how bad*; events tell you *what the control plane attempted*; logs tell you *why a component failed*; traces tell you *where in a request path*. A platform incident is triaged metrics → events → logs → traces, narrowing scope at each step. Reaching for traces first when the API server is throttled wastes the only thing you have less of than money: time under an active SLO burn.

### 2.2 Two complementary analysis frameworks

**The USE method (Brendan Gregg) — for *resources* (nodes, disks, CPU, memory, network, IP pools):**
For every resource, check **U**tilization, **S**aturation, **E**rrors. Saturation (queue depth, wait time, throttling) is the leading indicator; utilization alone lies — a node at 60% CPU utilization with a run-queue of 40 is saturated and failing.

**The RED method (Tom Wilkie) — for *services* (the API server, ingress, any request-serving workload):**
For every service, track **R**ate, **E**rrors, **D**uration. This maps directly onto the **Four Golden Signals** (Latency, Traffic, Errors, Saturation).

| Framework | Applies to | The three questions | Leading indicator |
|---|---|---|---|
| **USE** | Resources (node, disk, CNI pool, etcd disk) | Utilization / Saturation / Errors | **Saturation** |
| **RED** | Request-driven services (apiserver, ingress, app) | Rate / Errors / Duration | **Errors + Duration** |
| **Golden Signals** | Any user-facing service | Latency / Traffic / Errors / Saturation | **Saturation** predicts the rest |

Rule of thumb under incident: **USE the nodes, RED the services.** If both look clean, the fault is in a *control-plane decision* (scheduling, admission, networking policy) — go to events.

### 2.3 The platform diagnostic layers (top-down triage)

```
┌─────────────────────────────────────────────────────────┐
│ L7  Application / tenant workload   → app logs, traces   │
│ L6  Ingress / Service mesh / LB     → RED, mesh metrics  │
│ L5  Networking: CNI, kube-proxy,    → conntrack, IP pool │
│     DNS (CoreDNS), NetworkPolicy    → dns latency        │
│ L4  Scheduling & admission          → events, webhooks   │
│ L3  Control plane: apiserver, etcd, → apiserver_*, etcd_*│
│     controller-mgr, scheduler       → request latency    │
│ L2  Node: kubelet, containerd, CSI  → USE, node cond.    │
│ L1  Infra: host OS, kernel, cloud   → dmesg, cloud API   │
└─────────────────────────────────────────────────────────┘
```

Incidents almost always announce themselves at L7 (a tenant is broken) but *originate* lower. The method is **top-down to localize, bottom-up to confirm**: start where the symptom appears, walk *down* the stack asking "is the layer below me healthy?" until you find the first unhealthy layer — that is your suspect. Then confirm by reproducing the failure from that layer *upward*.

---

## 3. Establishing the baseline: you cannot diagnose without "normal"

The single most common diagnostic failure is having no baseline. "API server p99 latency is 800ms" is meaningless without knowing it is normally 40ms. Every platform must ship a **Golden Signals baseline** as code. Below is a complete, production-grade `PrometheusRule` set covering the control-plane golden signals a CNPE is expected to reason about.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-golden-signals
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: platform
spec:
  groups:
    - name: control-plane.rules
      rules:
        # ---- API server: RATE (traffic) ----
        - record: apiserver:request_rate:sum
          expr: sum(rate(apiserver_request_total[5m])) by (verb, resource)

        # ---- API server: ERRORS (5xx ratio) ----
        - record: apiserver:request_error_ratio:ratio_rate5m
          expr: |
            sum(rate(apiserver_request_total{code=~"5.."}[5m]))
              /
            sum(rate(apiserver_request_total[5m]))

        # ---- API server: DURATION (read p99, excluding WATCH) ----
        - record: apiserver:read_latency:p99
          expr: |
            histogram_quantile(0.99,
              sum(rate(apiserver_request_duration_seconds_bucket{verb=~"GET|LIST"}[5m]))
              by (le, resource))

        # ---- etcd: SATURATION (fsync + disk) ----
        - record: etcd:wal_fsync:p99
          expr: |
            histogram_quantile(0.99,
              sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) by (le))
        - record: etcd:backend_commit:p99
          expr: |
            histogram_quantile(0.99,
              sum(rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])) by (le))

    - name: control-plane.alerts
      rules:
        - alert: APIServerHighErrorRate
          expr: apiserver:request_error_ratio:ratio_rate5m > 0.05
          for: 5m
          labels: { severity: critical, tier: control-plane }
          annotations:
            summary: "kube-apiserver 5xx ratio above 5% for 5m"
            description: "5xx ratio is {{ $value | humanizePercentage }}. Check apiserver saturation, etcd latency, and admission webhook timeouts."
            runbook_url: "https://runbooks.internal/apiserver-5xx"

        - alert: APIServerReadLatencyHigh
          expr: apiserver:read_latency:p99 > 1
          for: 10m
          labels: { severity: warning, tier: control-plane }
          annotations:
            summary: "apiserver read p99 > 1s (LIST/GET)"
            description: "p99 read latency {{ $value }}s. Likely large LIST calls, missing pagination, or etcd saturation."

        - alert: EtcdWALFsyncSlow
          expr: etcd:wal_fsync:p99 > 0.05
          for: 5m
          labels: { severity: critical, tier: control-plane }
          annotations:
            summary: "etcd WAL fsync p99 > 50ms — disk cannot keep up"
            description: "etcd requires fast fsync. p99 {{ $value }}s. Check disk IOPS/throttling; this is the leading cause of cluster-wide latency."

        # ---- Node saturation (USE: Saturation) ----
        - alert: NodeMemoryPressure
          expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
          for: 2m
          labels: { severity: critical, tier: node }
          annotations:
            summary: "Node {{ $labels.node }} under MemoryPressure — evictions imminent"

        # ---- SLO burn-rate (multi-window, Google SRE style) ----
        - alert: PlatformErrorBudgetFastBurn
          expr: |
            (
              apiserver:request_error_ratio:ratio_rate5m > (14.4 * 0.001)
            and
              (sum(rate(apiserver_request_total{code=~"5.."}[1h]))
                / sum(rate(apiserver_request_total[1h]))) > (14.4 * 0.001)
            )
          for: 2m
          labels: { severity: critical, tier: slo }
          annotations:
            summary: "Fast burn: consuming 30-day error budget in ~2 days"
            description: "SLO 99.9%. 14.4x burn rate on both 5m and 1h windows."
```

**Why multi-window burn-rate alerting matters (exam-relevant):** a single-threshold error alert either pages too eagerly (noisy) or too late (SLO already blown). The multi-window / multi-burn-rate approach from the *SRE Workbook* pages only when a *fast* window (5m) **and** a *slow* window (1h) both exceed a burn rate that would exhaust the budget in a fixed time — 14.4× burns a 30-day budget in ~2 days. It suppresses transient spikes while still catching sustained degradation.

| Alerting strategy | Detects fast outages | Detects slow burns | False-page rate | Recommended |
|---|---|---|---|---|
| Static threshold (`errors > N`) | ✅ | ❌ | High | ❌ |
| Single-window burn rate | ✅ | ⚠️ | Medium | ⚠️ |
| **Multi-window multi-burn-rate** | ✅ | ✅ | Low | ✅ |

---

## 4. Scenario catalogue: the failures a CNPE must diagnose and remediate

Each scenario below follows the same structure: **symptom → hypothesis → diagnosis (real CLI + output) → mitigation → remediation.** These are the canonical incident classes that map to this exam objective.

### 4.1 CrashLoopBackOff — the workload cannot stay up

**Symptom:** a tenant reports their deployment "won't start"; pods cycle `Running → Error → CrashLoopBackOff`.

`CrashLoopBackOff` is not an error, it is the kubelet's *exponential back-off* (10s, 20s, 40s … capped at 5m) between restart attempts of a container that keeps exiting. The real error is *why* it exits. Diagnosis is a decision tree.

```console
$ kubectl get pods -n team-payments -o wide
NAME                        READY   STATUS             RESTARTS      AGE   IP           NODE
checkout-7d9f8c6b4-2xk9p    0/1     CrashLoopBackOff   6 (44s ago)   8m    10.244.3.17  node-3
checkout-7d9f8c6b4-p4m2s    0/1     CrashLoopBackOff   6 (39s ago)   8m    10.244.5.22  node-5

$ kubectl describe pod -n team-payments checkout-7d9f8c6b4-2xk9p
...
Containers:
  checkout:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Fri, 07 Aug 2026 14:22:10 +0000
      Finished:     Fri, 07 Aug 2026 14:22:11 +0000
    Restart Count:  6
Events:
  Type     Reason     Age                 From     Message
  ----     ------     ----                ----     -------
  Normal   Pulled     8m (x6 over 8m)     kubelet  Container image "checkout:1.4.2" already present on machine
  Normal   Created    8m (x6 over 8m)     kubelet  Created container checkout
  Warning  BackOff    3m (x25 over 8m)    kubelet  Back-off restarting failed container
```

Exit Code 1 = application error → go to the *previous* container's logs (the current one hasn't started):

```console
$ kubectl logs -n team-payments checkout-7d9f8c6b4-2xk9p --previous
2026-08-07T14:22:11Z FATAL config: required env DATABASE_URL is empty
panic: missing DATABASE_URL

$ kubectl get pod -n team-payments checkout-7d9f8c6b4-2xk9p \
    -o jsonpath='{.spec.containers[0].envFrom}' | jq
[
  { "secretRef": { "name": "checkout-db" } }
]

$ kubectl get secret -n team-payments checkout-db
Error from server (NotFound): secrets "checkout-db" not found
```

**Root cause found:** the Secret the pod depends on was never created (or was deleted). Now decode the exit-code decision tree that lets you triage *any* CrashLoop fast:

| Exit code / reason | Meaning | First move |
|---|---|---|
| **0** but restarting | Process finished; wrong `restartPolicy` or missing long-running cmd | Check `command`/`args`, restartPolicy |
| **1 / 2** | Generic app error | `kubectl logs --previous` |
| **137** (128+9) | SIGKILL — **OOMKilled** or failed liveness | `describe` → `Reason: OOMKilled`; check limits |
| **139** (128+11) | SIGSEGV — binary/arch mismatch, native crash | Check image arch (`arm64` vs `amd64`) |
| **143** (128+15) | SIGTERM — killed during graceful shutdown | preStop/termination grace too short |
| `CreateContainerConfigError` | Missing ConfigMap/Secret referenced in env | `describe` events, verify refs exist |
| `RunContainerError` | Runtime rejected (bad mount, seccomp, cap) | containerd logs, securityContext |

**Mitigation vs remediation:**
- *Mitigation* (stop the paging, buy time): if a bad rollout, `kubectl rollout undo deploy/checkout -n team-payments` to the last-good ReplicaSet.
- *Remediation* (durable): recreate the Secret via the GitOps source of truth so it cannot silently disappear again, and add an admission policy (§4.6) that blocks deployments referencing nonexistent Secrets, plus a startup gate.

```console
$ kubectl rollout undo deployment/checkout -n team-payments
deployment.apps/checkout rolled back
$ kubectl rollout status deployment/checkout -n team-payments
Waiting for deployment "checkout" rollout to finish: 1 of 2 updated replicas are available...
deployment "checkout" successfully rolled out
```

### 4.2 OOMKilled and the memory-limit trade-off

`OOMKilled` (exit 137) happens when a container's working set exceeds its `resources.limits.memory` and the cgroup OOM killer reaps it. This is a *per-container* limit, distinct from *node* MemoryPressure eviction (§4.3).

```console
$ kubectl get pod api-6b5-x2p -n team-search -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
OOMKilled

$ kubectl describe pod api-6b5-x2p -n team-search | grep -A3 Limits
    Limits:
      memory:  256Mi
    Requests:
      memory:  128Mi

# Confirm with the metric: working set vs limit over time
$ kubectl top pod api-6b5-x2p -n team-search
NAME          CPU(cores)   MEMORY(bytes)
api-6b5-x2p   340m         255Mi          # pinned at the 256Mi ceiling → OOM
```

The architectural trade-off in setting memory limits:

| Strategy | Pro | Con | When |
|---|---|---|---|
| **No memory limit** | Never OOMKilled by own limit | One tenant's leak can starve the node → global eviction | Never in multi-tenant |
| **requests == limits (Guaranteed QoS)** | Predictable, last to be evicted, no CPU throttling surprises | Wastes headroom; must right-size | Latency-critical, DBs |
| **requests < limits (Burstable QoS)** | Efficient bin-packing, absorbs spikes | Can be evicted under node pressure; noisy-neighbor risk | Most stateless services |
| **VPA-driven** | Auto right-sizing from history | Recreates pods to resize (disruptive); conflicts with HPA on same metric | Batch, non-latency-critical |

**Mitigation:** raise the limit to unblock (`kubectl set resources deploy/api -n team-search --limits=memory=512Mi`) — but this is a band-aid if the app is *leaking*. **Remediation:** confirm leak vs. legitimate growth via the working-set trend; if leaking, fix the app; if legitimately under-provisioned, right-size via VPA in *recommendation* mode first, then enforce a LimitRange so no tenant ships an un-limited container:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: mem-guardrails
  namespace: team-search
spec:
  limits:
    - type: Container
      default:            # applied if the pod omits limits
        memory: 512Mi
        cpu: "1"
      defaultRequest:
        memory: 256Mi
        cpu: 250m
      max:
        memory: 4Gi       # hard ceiling: no single container can request more
      min:
        memory: 64Mi
```

### 4.3 Node NotReady and the eviction cascade

**Symptom:** many pods across one node go `Terminating`/`Unknown`; the node shows `NotReady`. This is the multi-tenant blast-radius case.

```console
$ kubectl get nodes
NAME     STATUS     ROLES    AGE    VERSION
node-1   Ready      <none>   210d   v1.30.4
node-2   Ready      <none>   210d   v1.30.4
node-4   NotReady   <none>   210d   v1.30.4        # ← suspect

$ kubectl describe node node-4 | sed -n '/Conditions:/,/Addresses:/p'
Conditions:
  Type                 Status    Reason                       Message
  ----                 ------    ------                       -------
  MemoryPressure       False     KubeletHasSufficientMemory   kubelet has sufficient memory
  DiskPressure         True      KubeletHasDiskPressure       kubelet has disk pressure
  PIDPressure          False     KubeletHasSufficientPID      kubelet has sufficient PID
  Ready                False     KubeletNotReady              container runtime is down: ...
```

`DiskPressure=True` + runtime down. Two things are happening: the kubelet is evicting pods to reclaim ephemeral storage, *and* the container runtime has wedged. Confirm on the node (SSH / debug node) — note that when the API path to the node is compromised you still need the node-level view:

```console
$ kubectl debug node/node-4 -it --image=busybox
Creating debugging pod node-debugger-node-4-xxxx ...
/ # chroot /host
# df -h /var/lib/containerd
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1     50G   50G   20K 100% /var/lib/containerd     # ← disk full
# journalctl -u containerd --no-pager | tail -5
containerd[812]: error: write /var/lib/containerd/...: no space left on device
# du -sh /var/lib/containerd/io.containerd.content.v1.content/* | sort -h | tail -3
41G  /var/lib/containerd/io.containerd.content.v1.content/blobs   # image cache bloat
```

**The cascade mechanism (must understand):** when a node goes NotReady, the node controller waits `--node-monitor-grace-period` (default 40s) then taints it `node.kubernetes.io/not-ready:NoExecute`. Pods without a matching toleration get an eviction timer (`tolerationSeconds`, default 300s), after which they're evicted and rescheduled — onto other nodes, which may then fill up too. This is why a *single* full disk can become a *cluster-wide* incident.

| Node condition | Trigger threshold (default) | Kubelet action | Cascade risk |
|---|---|---|---|
| `MemoryPressure` | `memory.available < 100Mi` | Evict Best-Effort → Burstable pods | High (reschedule storm) |
| `DiskPressure` | `nodefs.available < 10%` or `imagefs.available < 15%` | GC images/containers, then evict | High + runtime wedge |
| `PIDPressure` | `pid.available < threshold` | Evict pods | Medium |
| `Ready=False` | kubelet not posting status | Taint `not-ready`, evict after grace | **Cluster-wide** |

**Mitigation:** `kubectl cordon node-4` (stop new scheduling), then on the node prune the image cache to break DiskPressure immediately:

```console
# crictl rmi --prune
Deleted: sha256:9f2a...   (41 GiB reclaimed)
# systemctl restart containerd
$ kubectl uncordon node-4          # only after Ready=True
```

**Remediation:** the durable fix is *preventing* one node from filling — configure kubelet eviction thresholds and image GC, set ephemeral-storage requests/limits per container, and separate `imagefs` onto its own volume so image bloat cannot starve the runtime state. Add a `NodeDiskPressure` alert *before* the 100% cliff.

### 4.4 Pending pods — the scheduler said no

**Symptom:** pods stuck `Pending`, `0/N nodes available`. The scheduler is telling you exactly why in the events — read it literally.

```console
$ kubectl get pod ml-train-0 -n team-ml
NAME         READY   STATUS    RESTARTS   AGE
ml-train-0   0/1     Pending   0          6m

$ kubectl describe pod ml-train-0 -n team-ml | sed -n '/Events:/,$p'
Events:
  Type     Reason            Age    From               Message
  ----     ------            ----   ----               -------
  Warning  FailedScheduling  6m     default-scheduler  0/12 nodes are available:
           3 Insufficient cpu, 5 node(s) had untolerated taint {gpu: true},
           4 node(s) didn't match Pod's node affinity/selector.
```

The message decomposes exactly: 3 nodes lack CPU, 5 are GPU-tainted and the pod doesn't tolerate it, 4 don't match affinity. Decision table for the common `FailedScheduling` reasons:

| Scheduler message | Cause | Fix |
|---|---|---|
| `Insufficient cpu/memory` | No node has enough *allocatable* left | Scale nodes / lower requests / Cluster Autoscaler |
| `had untolerated taint {…}` | Node tainted, pod lacks toleration | Add toleration, or target un-tainted nodes |
| `didn't match node affinity/selector` | `nodeSelector`/affinity too strict | Relax affinity or label nodes |
| `had volume node affinity conflict` | PV is zone-bound; pod scheduled elsewhere | topology-aware `WaitForFirstConsumer` StorageClass |
| `pod has unbound immediate PersistentVolumeClaims` | PVC unbound, no provisioner | Fix StorageClass / provisioner |
| `too many pods` | Node at max-pods (CNI IP limit) | More nodes / prefix delegation |

Check *allocatable* vs *requested* — the classic confusion is looking at `kubectl top` (actual use) when the scheduler cares about *requests*:

```console
$ kubectl describe node node-7 | sed -n '/Allocated resources:/,/Events:/p'
Allocated resources:
  Resource           Requests      Limits
  --------           --------      ------
  cpu                3800m (95%)   6 (150%)
  memory             6144Mi (80%)  8Gi (106%)
# 95% of CPU already *requested* → a 500m pod cannot fit even if actual use is 20%
```

**Mitigation:** if a Cluster Autoscaler is present, verify it's scaling and not blocked; otherwise temporarily lower the pod's CPU request to fit. **Remediation:** enable/repair the autoscaler, and prevent scheduling starvation between tenants with `ResourceQuota` + priority classes so batch (`ml-train`) is preemptible but latency-critical services are not.

### 4.5 DNS and networking failures — the "intermittent, unexplainable" class

DNS is the most common source of "flaky, works-sometimes" platform incidents. CoreDNS latency or the classic conntrack race manifests as sporadic timeouts that no single log line explains.

**Symptom:** services report intermittent `dial tcp: lookup <svc> ... i/o timeout`, ~1–5% of requests, no pattern.

```console
$ kubectl run -it --rm dnstest --image=nicolaka/netshoot --restart=Never -- \
    sh -c 'for i in $(seq 1 20); do time nslookup checkout.team-payments.svc.cluster.local >/dev/null; done'
...
real    0m0.012s        # fast
real    0m5.031s        # ← 5s: the classic UDP timeout, a lost packet + retry
real    0m0.009s
real    0m5.028s        # ← again
...

# CoreDNS health:
$ kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20 | grep -i -E 'error|SERVFAIL|timeout'
[ERROR] plugin/errors: 2 checkout.team-payments.svc.cluster.local. A: read udp i/o timeout

$ kubectl -n kube-system top pod -l k8s-app=kube-dns
NAME                       CPU(cores)   MEMORY(bytes)
coredns-5d78c9-abcde       340m         70Mi        # pinned CPU → throttled, dropping
```

**The two root causes and their fixes:**

| Root cause | Signature | Remediation |
|---|---|---|
| **CoreDNS under-provisioned / throttled** | CoreDNS CPU pinned, cache misses, `i/o timeout` in its logs | Scale replicas + HPA; add `cache` plugin; tune `MaxConcurrent` |
| **conntrack race (5s timeout)** | Exactly-5s DNS latency, `insert_failed` in conntrack stats | `NodeLocal DNSCache` (TCP to upstream) — the definitive fix |
| **`ndots:5` search-domain amplification** | Every external lookup does 4–5 failed cluster queries first | `dnsConfig` with `ndots:2` for external-heavy pods |

The `ndots:5` amplification is worth internalizing: with the default `search` list, resolving `api.stripe.com` first tries `api.stripe.com.team-payments.svc.cluster.local`, then `…svc.cluster.local`, then `…cluster.local`, then the host domain — *four* NXDOMAIN round-trips before the real query. Under load this 5× the DNS QPS. Confirm and fix:

```console
$ kubectl exec deploy/checkout -n team-payments -- cat /etc/resolv.conf
search team-payments.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

```yaml
# Remediation: NodeLocal DNSCache (definitive conntrack-race fix) is a DaemonSet;
# per-pod ndots tuning for an external-API-heavy workload:
apiVersion: apps/v1
kind: Deployment
metadata: { name: checkout, namespace: team-payments }
spec:
  template:
    spec:
      dnsConfig:
        options:
          - name: ndots
            value: "2"        # api.stripe.com (2 dots) resolved absolutely, no search amplification
          - name: single-request-reopen   # mitigates the UDP A/AAAA race in glibc
      containers:
        - name: checkout
          image: checkout:1.4.2
```

**NetworkPolicy as a silent failure source:** a mis-scoped `NetworkPolicy` denies traffic with *no error* — the packet is simply dropped, appearing as a client-side timeout. Diagnose by testing connectivity with policies temporarily relaxed in a canary namespace, and by reading the CNI's policy logs (Cilium: `hubble observe --verdict DROPPED`).

```console
$ hubble observe --namespace team-payments --verdict DROPPED --last 20
Aug  7 14:40:02  checkout-7d9f → postgres-0   TCP  DROPPED  (Policy denied)
```

### 4.6 Admission webhook wedge — the whole cluster stops accepting changes

**Symptom:** *every* create/update fails cluster-wide with a webhook timeout. This is the highest-blast-radius L4 failure and a favorite exam scenario because the failure mode depends on `failurePolicy`.

```console
$ kubectl apply -f deploy.yaml
Error from server (InternalError): Internal error occurred: failed calling webhook
"validate.kyverno.svc": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/validate?timeout=10s":
context deadline exceeded

$ kubectl get validatingwebhookconfigurations
NAME                          WEBHOOKS   AGE
kyverno-policy-validating     1          89d

$ kubectl -n kyverno get pods
NAME                       READY   STATUS             RESTARTS   AGE
kyverno-7c9d5b6f4-qz8kn    0/1     CrashLoopBackOff   9          22m    # ← webhook backend down
```

**The architectural trap:** the webhook is configured `failurePolicy: Fail` (fail-closed). When its backing pod dies, *no admission request can be satisfied*, so no deployment — including the fix for the webhook itself — can be applied. You are locked out of your own cluster.

| `failurePolicy` | Behavior when webhook unreachable | Security posture | Availability posture |
|---|---|---|---|
| **`Fail`** (default) | Deny the request | Strong (no bypass) | Fragile — webhook is a SPOF for all writes |
| **`Ignore`** | Allow the request | Weak (policy silently skipped) | Resilient |

**Mitigation (break-glass):** delete the wedged webhook configuration so the API server stops calling it — this instantly restores write access. This is the canonical break-glass procedure and must be documented in the runbook:

```console
$ kubectl delete validatingwebhookconfigurations kyverno-policy-validating
validatingwebhookconfiguration.admission.registration.k8s.io "kyverno-policy-validating" deleted
$ kubectl apply -f deploy.yaml
deployment.apps/checkout created          # writes restored
```

**Remediation:** three durable controls, all exam-relevant:
1. Scope the webhook with `namespaceSelector` to *exclude* `kube-system` and the policy engine's own namespace, so a policy failure can never brick the control plane.
2. Run the webhook backend HA (≥2 replicas, PodDisruptionBudget) with tight `timeoutSeconds` (≤10s) so a slow backend fails fast rather than hanging every request.
3. Consider `failurePolicy: Ignore` for non-security-critical policies, accepting the trade-off above.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kyverno-policy-validating
webhooks:
  - name: validate.kyverno.svc
    failurePolicy: Fail
    timeoutSeconds: 10                 # fail fast, do not hang every write for 30s
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kyverno]   # never gate the control plane or the engine itself
    matchPolicy: Equivalent
    sideEffects: None
    admissionReviewVersions: ["v1"]
    rules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
        scope: Namespaced
    clientConfig:
      service:
        namespace: kyverno
        name: kyverno-svc
        path: /validate
        port: 443
```

### 4.7 etcd / API server saturation — the control plane is the incident

When `kubectl` itself is slow or timing out, the control plane is the victim. The two dominant causes are **etcd disk saturation** (slow fsync) and **expensive LIST calls** hammering the API server.

```console
$ time kubectl get pods -A
... (hangs 22s) ...
real    0m22.140s

# What is the API server spending time on? (priority-and-fairness + inflight)
$ kubectl get --raw '/metrics' | grep apiserver_current_inflight_requests
apiserver_current_inflight_requests{request_kind="mutating"} 12
apiserver_current_inflight_requests{request_kind="readOnly"} 400   # ← saturated read path

# Who is issuing the expensive LISTs?
$ kubectl get --raw '/metrics' | grep 'apiserver_request_total{.*verb="LIST".*resource="pods"' | sort -t= -k2 -n | tail
apiserver_request_total{...verb="LIST",resource="pods",...} 1.4e6   # one client LISTing all pods repeatedly

# etcd health / fsync:
$ kubectl -n kube-system exec etcd-cp-1 -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status -w table
+------------------+------------------+---------+---------+-----------+------------+
|     ENDPOINT     |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
+------------------+------------------+---------+---------+-----------+------------+
| 127.0.0.1:2379   | 8e9e05c52164694d |  3.5.12 |  7.9 GB |      true |         42 |
+------------------+------------------+---------+---------+-----------+------------+
# 7.9 GB is near the 8 GB default quota → NOSPACE alarm imminent
```

| Control-plane saturation cause | Signature | Mitigation | Remediation |
|---|---|---|---|
| **etcd DB near quota** | DB size ≈ `--quota-backend-bytes`, `NOSPACE` alarm | `etcdctl defrag` + `alarm disarm` | Raise quota, compaction policy, evict large objects (huge ConfigMaps/Secrets) |
| **etcd slow fsync** | `wal_fsync p99 > 50ms` | Move etcd to faster disk / dedicate IOPS | Dedicated NVMe, no co-tenant disk |
| **Expensive LIST storm** | high `readOnly` inflight, one client dominating | APF `FlowSchema` to throttle the client | Fix client to use `watch`/informers + pagination |
| **Missing pagination** | large `LIST` p99 latency | — | Client must use `limit`/`continue` |

**Mitigation for the LIST storm — API Priority and Fairness (APF)** lets you isolate the offending client into a low-priority flow so it cannot starve legitimate traffic (this is the modern replacement for `--max-requests-inflight`):

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: throttle-noisy-controller
spec:
  priorityLevelConfiguration:
    name: low-priority          # a PriorityLevelConfiguration with small concurrency share
  matchingPrecedence: 900
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: ServiceAccount
          serviceAccount:
            name: legacy-reconciler
            namespace: team-legacy
      resourceRules:
        - verbs: ["list", "get"]
          apiGroups: [""]
          resources: ["pods"]
          clusterScope: true
          namespaces: ["*"]
```

**etcd defrag mitigation (do this on followers first, then the leader, one at a time):**

```console
$ kubectl -n kube-system exec etcd-cp-1 -- etcdctl ... defrag
Finished defragmenting etcd member[127.0.0.1:2379]
$ kubectl -n kube-system exec etcd-cp-1 -- etcdctl ... alarm disarm
memberID:8e9e05c52164694d alarm:NOSPACE  (disarmed)
```

---

## 5. Cross-cutting remediation patterns and their trade-offs

Diagnosis identifies the fault; remediation restores service and prevents recurrence. The CNPE must choose the *right level* of intervention for the incident phase.

| Remediation lever | Latency to effect | Blast radius | Reversible? | Use for |
|---|---|---|---|---|
| **`kubectl rollout undo`** | Seconds | One workload | ✅ (rollout redo) | Bad app/config deploy |
| **`cordon` + `drain`** | Seconds–minutes | One node | ✅ (uncordon) | Sick node, before repair |
| **Scale replicas / HPA bump** | Seconds | One workload | ✅ | Load-driven saturation |
| **Delete webhook config (break-glass)** | Instant | Cluster policy | ✅ (re-apply) | Webhook wedge lockout |
| **APF FlowSchema** | Seconds | One client | ✅ | Noisy-neighbor on apiserver |
| **etcd defrag / alarm disarm** | Minutes | Control plane | ⚠️ (I/O heavy) | etcd quota/fragmentation |
| **Feature flag / kill switch** | Instant | One feature | ✅ | Bad feature, not deploy |
| **Full GitOps revert (PR)** | Minutes | As scoped | ✅ (audited) | Durable config fix |

**The mitigation-vs-remediation discipline (exam framing):** *mitigation* returns the service to its SLO; *remediation* removes the possibility of the same incident. A rollback is a mitigation — the bad code still exists and can be redeployed. The remediation is the code fix *plus* the guardrail (admission policy, quota, alert) that would have caught it. A postmortem that ends at "we rolled back" has not remediated; it has deferred.

**Change correlation is the fastest diagnostic.** In practice, >70% of platform incidents are change-induced. Before deep-diving telemetry, ask "what changed?" — correlate the incident start time against deploy history, GitOps sync events, and node/AMI rollouts:

```console
$ kubectl get events -A --sort-by=.lastTimestamp | tail -15
$ kubectl rollout history deployment/checkout -n team-payments
REVISION  CHANGE-CAUSE
6         kubectl set image checkout=checkout:1.4.2  (2026-08-07T14:19Z)   # ← 3 min before alert
$ argocd app history checkout           # if GitOps: last sync + commit SHA
```

---

## 6. Verification and diagnosis guide (the runnable checklist)

A remediation is not complete until *verified*. Assert the fix with the same signals that detected the incident — never declare victory from a single `kubectl get`.

### 6.1 Top-down triage sequence (memorize this order)

```console
# 1. SCOPE — is it one workload, one namespace, one node, or cluster-wide?
$ kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
$ kubectl get nodes
$ kubectl get events -A --sort-by=.lastTimestamp | tail -20

# 2. CONTROL PLANE — is the diagnosis surface itself healthy?
$ kubectl get --raw='/readyz?verbose'
[+]ping ok
[+]etcd ok
[+]poststarthook/... ok
readyz check passed
$ kubectl get --raw '/metrics' | grep apiserver_current_inflight_requests

# 3. THE SUSPECT LAYER — describe, then logs, then previous logs
$ kubectl describe <resource> <name> -n <ns>          # events first
$ kubectl logs <pod> -n <ns> --previous               # why did it die
$ kubectl logs <pod> -n <ns> -c <container> --since=10m

# 4. NETWORK / DNS (if intermittent) — from inside the mesh
$ kubectl run -it --rm netshoot --image=nicolaka/netshoot --restart=Never -- \
    sh -c 'nslookup <svc>; curl -sv http://<svc>:<port>/healthz'

# 5. NODE (if a node is implicated) — get underneath the API
$ kubectl debug node/<node> -it --image=busybox -- chroot /host \
    sh -c 'df -h; free -m; dmesg -T | tail; journalctl -u kubelet --no-pager | tail'
```

### 6.2 Verification-after-fix matrix

| You changed… | Verify it worked by… | Watch for regression via… |
|---|---|---|
| Rolled back a deploy | `kubectl rollout status` = success, pods `Ready` | Error-rate metric back to baseline for 15m |
| Raised a memory limit | No new `OOMKilled` in `lastState`; `kubectl top` < limit | Working-set trend flat, not climbing (leak) |
| Uncordoned a node | Node `Ready=True`, pods scheduling, disk/mem back under threshold | Node condition alerts silent for 30m |
| Deleted a wedged webhook | `kubectl apply` of a test object succeeds | Re-apply webhook HA'd; write success ratio 100% |
| APF FlowSchema | `apiserver_flowcontrol_rejected_requests_total` on low-priority; inflight drops | apiserver read p99 back under baseline |
| etcd defrag | `endpoint status` DB size dropped; `alarm list` empty | `wal_fsync p99 < 50ms` sustained |

### 6.3 The blameless postmortem contract

Every SEV1/SEV2 closes with a postmortem whose value is the *action items*, not the narrative. The CNPE-relevant structure:

```markdown
## Incident 2026-08-07 — checkout CrashLoop (SEV2, 14m TTR)
- **Impact:** 100% checkout failures, 14 min, ~$X GMV, 0.02% of monthly error budget.
- **Detection:** PlatformErrorBudgetFastBurn fired at 14:22 (alert, not customer).
- **Trigger (what changed):** deploy of checkout:1.4.2 at 14:19; the referenced
  Secret `checkout-db` had been deleted in an unrelated namespace cleanup at 13:50.
- **Root cause (5-whys):** app has no startup validation → deploy referenced a
  missing Secret → no admission gate blocked it → no alert on Secret deletion.
- **Mitigation:** rollout undo at 14:34 (restored to 1.4.1).
- **Remediation (owner + due date, tracked as tickets):**
  1. [ ] Admission policy: block Deployments referencing nonexistent Secrets.
  2. [ ] App: fail readiness (not process crash) on missing config, with clear msg.
  3. [ ] Alert on Secret deletion in prod namespaces.
- **What went well / where we got lucky:** alert beat customers; rollback was clean.
```

**Time-to-Detect (TTD) + Time-to-Mitigate (TTM) = the numbers that matter.** Diagnosis skill compresses TTM; good alerting compresses TTD. The exam objective is fundamentally about compressing both under real conditions.

---

## 7. References

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Google SRE Book, *Monitoring Distributed Systems* (Four Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Workbook, *Alerting on SLOs* (multi-window multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Google SRE Book, *Effective Troubleshooting* — https://sre.google/sre-book/effective-troubleshooting/
- Google SRE Book, *Postmortem Culture: Learning from Failure* — https://sre.google/sre-book/postmortem-culture/
- Kubernetes — *Debug Running Pods* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — *Debugging Kubernetes Nodes with kubectl debug* — https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debugging/
- Kubernetes — *Node-pressure Eviction* — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — *Pod Quality of Service Classes* — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes — *API Priority and Fairness* — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes — *Dynamic Admission Control* (webhooks, failurePolicy) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes — *Resource Quotas* / *Limit Ranges* — https://kubernetes.io/docs/concepts/policy/resource-quotas/ · https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — *Autoscaling DNS (NodeLocal DNSCache)* — https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Kubernetes — *Operating etcd clusters* (defrag, quota, alarms) — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- CoreDNS — *Scaling and Configuration* — https://coredns.io/manual/toc/
- etcd — *Maintenance (compaction, defragmentation, alarms)* — https://etcd.io/docs/latest/op-guide/maintenance/
- Prometheus Operator — *PrometheusRule* — https://prometheus-operator.dev/docs/developer/alerting/
- Brendan Gregg — *The USE Method* — https://www.brendangregg.com/usemethod.html
- Tom Wilkie / Grafana — *The RED Method* — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- CNCF TAG Observability — *Observability Whitepaper* — https://github.com/cncf/tag-observability/blob/main/whitepaper.md
- Cilium — *Observing Network Flows with Hubble* — https://docs.cilium.io/en/stable/observability/hubble/