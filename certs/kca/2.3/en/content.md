# 2.3 Controller Configuration with Flags

> **Exam domain 2.3 — weight 3.0.** This topic covers the `kube-controller-manager` (KCM) binary, the individual control loops it hosts, and how their behaviour is tuned exclusively through command-line flags (there is no `kubectl` verb for this — you edit a process). At the KCA/production level you are expected to reason about *why* a default was chosen, what breaks when you move it, and how to prove the change took effect.

---

## 1. Motivation and the production architecture problem

### 1.1 What the controller manager actually is

Kubernetes is a declarative system built on **control loops**. A controller is a non-terminating loop that:

1. **Observes** the desired state (a spec in etcd, delivered via a *shared informer* watch).
2. **Compares** it against observed cluster state (status).
3. **Acts** to drive actual toward desired (create/update/delete API objects, call a cloud API, taint a node…).

The `kube-controller-manager` is a **single binary** that runs ~35 of these loops as goroutines inside **one process**, sharing one informer cache and one client to the API server. This is a deliberate packaging decision: co-locating the loops amortises the cost of watching the API server (one watch stream feeds many controllers) and lets them share the same leader-election lease.

```
                      ┌───────────────────────────────────────────────┐
                      │           kube-controller-manager             │
                      │  (single leader-elected process per cluster)  │
   API server  ◄──────┤                                               │
   (watch/list)       │  ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
        ▲             │  │ node     │ │ deploy   │ │ garbage       │  │
        │  writes     │  │ lifecycle│ │ controller│ │ collector    │  │
        └─────────────┤  └──────────┘ └──────────┘ └───────────────┘  │
                      │  ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
                      │  │ endpoint │ │ SA/token │ │ resourcequota │  │
                      │  │ slice    │ │ replicaset│ │ …             │  │
                      │  └──────────┘ └──────────┘ └───────────────┘  │
                      │        shared informer cache + workqueues     │
                      └───────────────────────────────────────────────┘
```

The **problem** the flags solve: the defaults are tuned for a *generic, medium* cluster. A 2,000-node cluster, a cluster on a flaky WAN, a cluster with 100k pods churning through CronJobs, and a 3-node edge cluster all need *different* reconciliation concurrency, failure-detection windows, and API-server pressure. None of that is expressible in a CRD or a `Deployment` — the KCM is (in a kubeadm cluster) a **static pod** whose behaviour is fixed at process start by its `command:` argv. Configuration *is* the flag set.

### 1.2 Why "with flags" specifically

Three properties make flag-based configuration a distinct operational skill:

- **No hot reload.** Changing a flag means the KCM process restarts. On a kubeadm control plane, editing the static pod manifest triggers the kubelet to recreate the pod. During that gap another replica must hold (or acquire) the leader lease, or *no controller runs at all* — deployments stop scaling, failed nodes stop evicting pods, tokens stop being minted.
- **Cluster-wide blast radius.** A single wrong flag (e.g. `--node-monitor-grace-period=4s`) affects *every* node and *every* workload. There is no namespace scoping.
- **Silent misconfiguration.** A typo'd flag name crashes the pod loudly (good). But a *valid* value that is wrong for your topology — say, `--kube-api-qps=100` on an already-saturated API server — degrades the whole cluster quietly. Verification (§5) is therefore not optional.

### 1.3 The split: `kube-controller-manager` vs `cloud-controller-manager`

Cloud-specific loops (node address/zone enrichment, route programming, `LoadBalancer` Service provisioning) were historically compiled into the KCM. They are now factored into a separate **`cloud-controller-manager`** (CCM) so the cloud vendor ships and versions their integration independently. When you run `--cloud-provider=external` on the kubelet and KCM, three controllers move out of the KCM to the CCM:

| Controller | In KCM (in-tree) | In CCM (external) |
|---|---|---|
| `cloud-node` / `cloud-node-lifecycle` | ✅ (legacy) | ✅ |
| `route` | ✅ (legacy) | ✅ |
| `service` (LB) | ✅ (legacy) | ✅ |
| Everything else (deployment, node IPAM, GC, …) | ✅ | ✅ (stays in KCM) |

This document focuses on the KCM; the CCM shares the same flag grammar (`--controllers`, `--leader-elect*`, `--concurrent-*`).

---

## 2. The control loops and their tunables (technical comparison)

### 2.1 The full controller inventory

`--controllers` is the master switch. Its help text enumerates every loop:

```
--controllers strings   Default: [*]
  '*' enables all on-by-default controllers, 'foo' enables 'foo', '-foo' disables 'foo'.
  All controllers:
    attachdetach, bootstrapsigner, cloud-node-lifecycle, clusterrole-aggregation,
    cronjob, csrapproving, csrcleaner, csrsigning, daemonset, deployment,
    disruption, endpoint, endpointslice, endpointslicemirroring, ephemeral-volume,
    garbagecollector, horizontalpodautoscaling, job, namespace, nodeipam,
    nodelifecycle, persistentvolume-binder, persistentvolume-expander, podgc,
    pv-protection, pvc-protection, replicaset, replicationcontroller,
    resourcequota, root-ca-cert-publisher, route, service, serviceaccount,
    serviceaccount-token, statefulset, tokencleaner, ttl, ttl-after-finished
  Disabled-by-default controllers:
    bootstrapsigner, tokencleaner
```

`*` means **all on-by-default** loops. `bootstrapsigner` and `tokencleaner` are **off** unless named explicitly — they exist for the kubeadm TLS-bootstrap flow and most managed clusters leave them off.

Composition rules:
- `--controllers=*` → every on-by-default controller.
- `--controllers=*,-nodeipam` → all defaults **except** node IPAM (typical when Calico/Cilium own pod CIDR allocation).
- `--controllers=*,bootstrapsigner,tokencleaner` → defaults **plus** the two opt-in loops (kubeadm sets this).
- `--controllers=deployment,replicaset` → *only* those two (rarely useful; used to shard controllers across processes).

### 2.2 Node failure detection — the highest-stakes tunables

The `nodelifecycle` controller decides *when a node is dead* and *how fast pods leave it*. This is where most production incidents originate.

| Flag | Default | Meaning | Lower it → | Raise it → |
|---|---|---|---|---|
| `--node-monitor-period` | `5s` | How often KCM re-checks each node's health from the informer cache | Faster reaction, more CPU/API reads | Sluggish detection |
| `--node-monitor-grace-period` | `40s` | No heartbeat for this long ⇒ node marked `NotReady` (must be a multiple of `node-monitor-period`; ≈ 5× kubelet `nodeStatusUpdateFrequency` of 10s to absorb 3 missed updates) | Faster failover, **more false positives** on transient network blips → flapping evictions | Slower failover, more stable |
| `--node-startup-grace-period` | `1m0s` | Grace for a *newly registered* node before health checks apply | Premature NotReady on slow boots | Longer window before a stuck new node is flagged |
| `--large-cluster-size-threshold` | `50` | Above this node count, the *secondary* (slower) eviction rate applies per zone | — | Treats bigger clusters as "small" (aggressive) |
| `--node-eviction-rate` | `0.1` | Nodes/sec from which pods are evicted when a zone is healthy (0.1 = 1 node every 10s) | Slower drain, gentler on rescheduling storm | Faster drain, risk of thundering-herd reschedule |
| `--secondary-node-eviction-rate` | `0.01` | Eviction rate once a large zone is deemed unhealthy | — | — |
| `--unhealthy-zone-threshold` | `0.55` | Fraction of NotReady nodes in a zone that flips it to "unhealthy" and throttles eviction | More conservative | Less protection against zone-wide false positives |

**Critical mechanics — taint-based eviction.** When a node exceeds the grace period, the controller does **not** delete pods directly. It applies a taint:

- `node.kubernetes.io/not-ready` (kubelet reported problems), or
- `node.kubernetes.io/unreachable` (KCM lost the heartbeat).

Pods carry a **default toleration** `tolerationSeconds: 300` injected by the `DefaultTolerationSeconds` admission plugin. So the *observable* time-to-eviction for a hard node failure is:

```
T_evict ≈ node-monitor-grace-period (40s)  +  tolerationSeconds (300s)  ≈ 340s
```

Tuning `--node-monitor-grace-period` alone therefore only moves the *first* 40s. To make stateless workloads reschedule faster you must **also** lower the pod-level toleration (per-pod, not a KCM flag):

```yaml
tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
```

> **Deprecation note.** The legacy timer flag `--pod-eviction-timeout` and `--enable-taint-manager` belonged to the old non-taint eviction path. Taint-based eviction is now the only mechanism (`TaintBasedEvictions` went GA long ago); on current releases `--pod-eviction-timeout` is a no-op / removed. Do not tune it. Source: Kubernetes "Taints and Tolerations" docs.

### 2.3 Reconciliation concurrency — throughput vs API pressure

Each controller runs *N* worker goroutines draining its workqueue. More workers = faster catch-up after a burst, at the cost of API-server QPS and KCM memory.

| Flag | Default | Governs |
|---|---|---|
| `--concurrent-deployment-syncs` | `5` | Deployment rollouts |
| `--concurrent-replicaset-syncs` | `5` | ReplicaSet scaling |
| `--concurrent-statefulset-syncs` | `5` | StatefulSet ordered ops |
| `--concurrent-daemonset-syncs` | `2` | DaemonSet rollouts |
| `--concurrent-job-syncs` | `5` | Job completions |
| `--concurrent-cron-job-syncs` | `5` | CronJob scheduling |
| `--concurrent-endpoint-syncs` | `5` | legacy `Endpoints` |
| `--concurrent-endpointslice-syncs` | `5` | `EndpointSlice` (the scalable path) |
| `--concurrent-service-syncs` | `1` | Service (LB) reconcile — deliberately serial |
| `--concurrent-namespace-syncs` | `10` | Namespace deletion/finalizers |
| `--concurrent-resource-quota-syncs` | `5` | Quota accounting |
| `--concurrent-gc-syncs` | `20` | Owner-reference garbage collection |
| `--concurrent-serviceaccount-token-syncs` | `5` | SA token minting |
| `--concurrent-horizontal-pod-autoscaler-syncs` | `5` | HPA evaluation |

**The governing constraint** is the client rate limiter to the API server:

| Flag | Default | Effect |
|---|---|---|
| `--kube-api-qps` | `20` | Sustained requests/sec the KCM client will issue |
| `--kube-api-burst` | `30` | Token-bucket burst ceiling |

Raising `--concurrent-*-syncs` without raising `--kube-api-qps`/`--kube-api-burst` accomplishes little: extra workers just block on the shared client limiter. On large clusters a common pairing is `--kube-api-qps=100 --kube-api-burst=100` **only after** confirming the API server and etcd can absorb it (watch `apiserver_flowcontrol_*` and etcd `wal_fsync` latency). This is a **coupled** tuning: concurrency and QPS move together, and both are bounded by API-server capacity, not by the KCM.

### 2.4 Garbage / lifecycle housekeeping

| Flag | Default | Meaning | Trade-off |
|---|---|---|---|
| `--terminated-pod-gc-threshold` | `12500` | `podgc` starts deleting terminated pods once this many exist | Lower ⇒ leaner etcd & cleaner `kubectl get pods`, but more delete churn; `0` disables GC (pods pile up) |
| `--horizontal-pod-autoscaler-sync-period` | `15s` | HPA recompute interval | Lower ⇒ snappier autoscaling, more metrics API load |
| `--horizontal-pod-autoscaler-downscale-stabilization` | `5m0s` | Window HPA remembers past recommendations to avoid flapping down | Lower ⇒ faster scale-down, risk of oscillation |
| `--horizontal-pod-autoscaler-tolerance` | `0.1` | ±10% dead-band before HPA acts | — |
| `--cluster-signing-duration` | `8760h0m0s` (1 y) | TTL of certs signed by `csrsigning` (kubelet serving/client certs) | Shorter ⇒ tighter rotation, more CSR traffic |
| `--attach-detach-reconcile-sync-period` | `1m0s` | Volume attach/detach reconcile cadence | — |

### 2.5 Identity, security, IPAM

| Flag | Default | Purpose |
|---|---|---|
| `--use-service-account-credentials` | `false` | Each controller uses its **own** ServiceAccount (`system:serviceaccount:kube-system:<controller>`) instead of one shared identity → per-controller RBAC and audit attribution. **Set to `true` in production.** |
| `--service-account-private-key-file` | — | Private key used by `serviceaccount-token` to sign SA JWTs (must pair with the API server's `--service-account-key-file` public half) |
| `--root-ca-file` | — | CA bundle `root-ca-cert-publisher` injects into every namespace's `kube-root-ca.crt` ConfigMap |
| `--cluster-signing-cert-file` / `--cluster-signing-key-file` | — | CA the `csrsigning` controller uses to sign CSRs |
| `--allocate-node-cidrs` | `false` | `nodeipam` carves pod CIDRs from `--cluster-cidr` per node |
| `--cluster-cidr` | — | Aggregate pod network |
| `--node-cidr-mask-size` | `24` (IPv4) | Per-node pod subnet size (24 ⇒ 254 pods/node of address space) |
| `--service-cluster-ip-range` | — | Must match the API server's value (used by some cloud-route logic) |

### 2.6 Leader election — availability of the control loops themselves

Because KCM is not a Deployment with N active replicas, HA is achieved by running multiple KCM processes (one per control-plane node) that **race for a `Lease`**. Exactly one is active; the rest hot-stand-by. If the leader dies, a standby acquires the lease and resumes reconciliation.

| Flag | Default | Meaning | Tuning tension |
|---|---|---|---|
| `--leader-elect` | `true` | Enable the race | Turn **off** only for a single-replica dev cluster |
| `--leader-elect-lease-duration` | `15s` | How long a non-leader waits before it may claim an unrenewed lease | Shorter ⇒ faster failover, but a slow leader can lose the lease under GC pause → split churn |
| `--leader-elect-renew-deadline` | `10s` | Leader must renew within this or it self-demotes (**must be < lease-duration**) | — |
| `--leader-elect-retry-period` | `2s` | Interval between acquire/renew attempts | — |
| `--leader-elect-resource-lock` | `leases` | Lock object type (`leases` — do not use the removed `endpoints`/`configmaps` locks) | — |
| `--leader-elect-resource-name` | `kube-controller-manager` | Lease object name in `kube-system` | — |

The safe relationship is `retry-period < renew-deadline < lease-duration`. Compressing all three speeds failover to a few seconds but makes the leader fragile to stop-the-world pauses; a paused leader that misses `renew-deadline` demotes, and a brief period of *no active controller* follows until a standby wins.

---

## 3. Complete, unabridged manifests and infrastructure

### 3.1 The KCM static pod (kubeadm layout, `/etc/kubernetes/manifests/kube-controller-manager.yaml`)

This is the actual file the kubelet watches. The entire configuration surface is the `command:` argv.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
  labels:
    component: kube-controller-manager
    tier: control-plane
  annotations:
    kubernetes.io/config.hash: 9c3f7b2a1e5d4c8b0a6f2d9e7c1b3a4f
    kubernetes.io/config.seen: "2026-08-13T09:14:22.113847Z"
    kubernetes.io/config.source: file
spec:
  priorityClassName: system-node-critical
  priority: 2000001000
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: kube-controller-manager
      image: registry.k8s.io/kube-controller-manager:v1.31.1
      command:
        - kube-controller-manager
        - --allocate-node-cidrs=true
        - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --bind-address=127.0.0.1
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --cluster-cidr=10.244.0.0/16
        - --cluster-name=kubernetes
        - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
        - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
        - --controllers=*,bootstrapsigner,tokencleaner
        - --kubeconfig=/etc/kubernetes/controller-manager.conf
        - --leader-elect=true
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --root-ca-file=/etc/kubernetes/pki/ca.crt
        - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
        - --service-cluster-ip-range=10.96.0.0/12
        - --use-service-account-credentials=true
        # --- production tuning overlay (added by the operator) ---
        - --node-monitor-grace-period=40s
        - --node-monitor-period=5s
        - --kube-api-qps=50
        - --kube-api-burst=75
        - --concurrent-deployment-syncs=10
        - --concurrent-endpointslice-syncs=10
        - --terminated-pod-gc-threshold=2000
        - --leader-elect-lease-duration=15s
        - --leader-elect-renew-deadline=10s
        - --leader-elect-retry-period=2s
      resources:
        requests:
          cpu: 200m
      livenessProbe:
        httpGet:
          host: 127.0.0.1
          path: /healthz
          port: 10257
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
      startupProbe:
        httpGet:
          host: 127.0.0.1
          path: /healthz
          port: 10257
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 24
      volumeMounts:
        - name: ca-certs
          mountPath: /etc/ssl/certs
          readOnly: true
        - name: flexvolume-dir
          mountPath: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: kubeconfig
          mountPath: /etc/kubernetes/controller-manager.conf
          readOnly: true
  hostAliases:
    - ip: 127.0.0.1
      hostnames: [localhost]
  volumes:
    - name: ca-certs
      hostPath:
        path: /etc/ssl/certs
        type: DirectoryOrCreate
    - name: flexvolume-dir
      hostPath:
        path: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/controller-manager.conf
        type: FileOrCreate
status: {}
```

> **Note on `--bind-address=127.0.0.1`.** The KCM's secure port (`10257`, serving `/metrics` and `/healthz`) is bound to loopback so it is not exposed on the node network. To scrape metrics from Prometheus you either change this to `0.0.0.0` (and rely on RBAC + TLS) or scrape via a sidecar/kube-rbac-proxy. Do **not** blindly open it without authn/authz.

### 3.2 Declaring the flags the kubeadm way (`ClusterConfiguration`)

Editing the static pod by hand is not durable — a `kubeadm upgrade` regenerates it. Encode tuning in the cluster config so it survives upgrades:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.1
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
controllerManager:
  extraArgs:
    # kubeadm v1beta4 uses a list of name/value pairs (repeatable flags supported)
    - name: node-monitor-grace-period
      value: 40s
    - name: node-monitor-period
      value: 5s
    - name: kube-api-qps
      value: "50"
    - name: kube-api-burst
      value: "75"
    - name: concurrent-deployment-syncs
      value: "10"
    - name: concurrent-endpointslice-syncs
      value: "10"
    - name: terminated-pod-gc-threshold
      value: "2000"
    - name: use-service-account-credentials
      value: "true"
    - name: controllers
      value: "*,bootstrapsigner,tokencleaner,-nodeipam"   # Cilium owns IPAM
```

Apply on an existing control plane:

```bash
$ sudo kubeadm init phase control-plane controller-manager \
    --config /etc/kubernetes/kubeadm-config.yaml
```

### 3.3 Component-config file instead of raw flags (`KubeControllerManagerConfiguration`)

Many `--concurrent-*` and leader-election settings also exist as a structured config, referenced with a single `--config` flag. This is the direction Kubernetes is moving (fewer bare flags):

```yaml
apiVersion: kubecontrollermanager.config.k8s.io/v1alpha1
kind: KubeControllerManagerConfiguration
generic:
  leaderElection:
    leaderElect: true
    leaseDuration: 15s
    renewDeadline: 10s
    retryPeriod: 2s
    resourceLock: leases
    resourceName: kube-controller-manager
    resourceNamespace: kube-system
  controllers:
    - "*"
    - "bootstrapsigner"
    - "tokencleaner"
kubeControllerManagerClientConnection:
  qps: 50
  burst: 75
nodeLifecycleController:
  nodeMonitorGracePeriod: 40s
  nodeStartupGracePeriod: 1m0s
deploymentController:
  concurrentDeploymentSyncs: 10
podGCController:
  terminatedPodGCThreshold: 2000
serviceAccountController:
  concurrentSATokenSyncs: 10
```

Referenced from the pod as `--config=/etc/kubernetes/kcm-config.yaml` (mounted read-only). Flags and `--config` can coexist; explicit flags win over config-file values for the same field.

---

## 4. CLI commands and real terminal output

### 4.1 Confirm the pod is up and see the exact argv that took effect

```bash
$ kubectl -n kube-system get pod -l component=kube-controller-manager -o wide
NAME                                    READY   STATUS    RESTARTS      AGE    IP              NODE
kube-controller-manager-cp-1            1/1     Running   0             3h12m  10.0.0.11       cp-1
kube-controller-manager-cp-2            1/1     Running   1 (2h ago)    3h12m  10.0.0.12       cp-2
kube-controller-manager-cp-3            1/1     Running   0             3h12m  10.0.0.13       cp-3
```

The single source of truth for *what the running process is actually using* is its argv, not the manifest on disk (they can drift):

```bash
$ ps -C kube-controller-manager -o args --no-headers | tr ' ' '\n' | grep -E 'monitor|qps|burst|controllers|leader'
--controllers=*,bootstrapsigner,tokencleaner
--leader-elect=true
--node-monitor-grace-period=40s
--node-monitor-period=5s
--kube-api-qps=50
--kube-api-burst=75
--leader-elect-lease-duration=15s
--leader-elect-renew-deadline=10s
--leader-elect-retry-period=2s
```

### 4.2 Prove which control loops actually started

Every loop logs a `Starting controller`/`Started` line at boot. This is how you verify `--controllers` did what you meant:

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -iE 'Started controller|Starting .* controller' | head
I0813 09:14:31.882014       1 controllermanager.go:337] "Started controller" controller="deployment"
I0813 09:14:31.884771       1 controllermanager.go:337] "Started controller" controller="replicaset"
I0813 09:14:31.889902       1 controllermanager.go:337] "Started controller" controller="node-lifecycle"
I0813 09:14:31.893310       1 controllermanager.go:337] "Started controller" controller="endpointslice"
I0813 09:14:31.897655       1 controllermanager.go:337] "Started controller" controller="garbage-collector"
I0813 09:14:31.902118       1 controllermanager.go:337] "Started controller" controller="serviceaccount-token"
I0813 09:14:31.905540       1 controllermanager.go:337] "Started controller" controller="resourcequota"
I0813 09:14:31.9081...
```

A disabled loop is announced too:

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -i 'not enabled'
I0813 09:14:31.774213       1 controllermanager.go:322] "Warning: controller is disabled" controller="nodeipam"
```

### 4.3 Inspect the leader-election Lease

```bash
$ kubectl -n kube-system get lease kube-controller-manager
NAME                      HOLDER                                            AGE
kube-controller-manager   cp-1_3f6c1d9a-8b02-4e77-9c1a-1d2e3f4a5b6c         3h13m

$ kubectl -n kube-system get lease kube-controller-manager -o yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  holderIdentity: cp-1_3f6c1d9a-8b02-4e77-9c1a-1d2e3f4a5b6c
  leaseDurationSeconds: 15
  acquireTime: "2026-08-13T06:01:44.882000Z"
  renewTime: "2026-08-13T09:15:02.114000Z"      # updated every ~retry-period
  leaseTransitions: 4                             # how many times leadership moved
```

`leaseTransitions` climbing steadily is a red flag (flapping leader — usually renew-deadline too tight or KCM CPU-starved).

### 4.4 Scrape the metrics that reflect flag behaviour

```bash
$ TOKEN=$(kubectl -n kube-system create token default)
$ kubectl -n kube-system exec kube-controller-manager-cp-1 -- \
    curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:10257/metrics \
  | grep -E 'workqueue_depth|leader_election_master_status|node_collector_evictions_total' | head
# HELP workqueue_depth [ALPHA] Current depth of workqueue
workqueue_depth{name="deployment"} 0
workqueue_depth{name="endpoint_slice"} 3
workqueue_depth{name="garbage_collector_attempt_to_delete"} 0
# HELP leader_election_master_status Gauge of if the reporting system is master
leader_election_master_status{name="kube-controller-manager"} 1
# HELP node_collector_evictions_total Number of Node evictions that happened since ...
node_collector_evictions_total{zone=""} 0
```

`workqueue_depth` persistently non-zero for a controller means its `--concurrent-*-syncs` (and/or `--kube-api-qps`) is too low for the churn — the actionable signal for raising concurrency.

### 4.5 Observe node-failure timing driven by the flags

```bash
# Kill the kubelet on a worker to simulate a hard node failure
$ ssh worker-3 'sudo systemctl stop kubelet'

# ~40s later (node-monitor-grace-period) the node flips NotReady:
$ kubectl get nodes -w
NAME       STATUS   ROLES    AGE   VERSION
worker-3   Ready    <none>   9d    v1.31.1
worker-3   NotReady <none>   9d    v1.31.1        # T+40s

# The controller applies the unreachable taint (NoExecute):
$ kubectl describe node worker-3 | grep -A2 Taints
Taints:  node.kubernetes.io/unreachable:NoExecute
         node.kubernetes.io/unreachable:NoSchedule

# Pods without a shorter toleration are evicted at T+40s+300s (default tolerationSeconds):
$ kubectl get events --field-selector reason=TaintManagerEviction -A
LAST SEEN   TYPE     REASON                 OBJECT              MESSAGE
2s          Normal   TaintManagerEviction   pod/web-7c9f-abcde  Marking for deletion Pod default/web-7c9f-abcde
```

---

## 5. Verification and failure diagnosis

### 5.1 Safe change procedure (edit → self-heal → verify)

```bash
# 1. Snapshot before touching anything
$ sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/kcm.yaml.bak

# 2. Edit the static pod manifest (kubelet detects the write and recreates the pod)
$ sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml

# 3. Watch the kubelet recreate it — mirror pod bounces:
$ kubectl -n kube-system get pod kube-controller-manager-cp-1 -w
NAME                           READY   STATUS    RESTARTS   AGE
kube-controller-manager-cp-1   0/1     Pending   0          0s
kube-controller-manager-cp-1   0/1     Running   0          2s
kube-controller-manager-cp-1   1/1     Running   0          12s

# 4. Verify the new argv is live (§4.1) and no crash loop
$ kubectl -n kube-system get pod kube-controller-manager-cp-1 -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
{"running":{"startedAt":"2026-08-13T09:20:14Z"}}
```

If the pod does not reappear within ~30s, the kubelet rejected the manifest — check `journalctl -u kubelet`.

### 5.2 Failure: a bad flag crash-loops the pod

```bash
# You typo'd --node-monitor-grace-period=40  (missing the unit)
$ kubectl -n kube-system get pod kube-controller-manager-cp-1
NAME                           READY   STATUS             RESTARTS      AGE
kube-controller-manager-cp-1   0/1     CrashLoopBackOff   4 (23s ago)   96s

# The container writes the parse error to stderr, then exits 1:
$ kubectl -n kube-system logs kube-controller-manager-cp-1 --previous | tail -3
E0813 09:24:02.118      1 run.go:74] "command failed" err="invalid argument \"40\" for \"--node-monitor-grace-period\" flag: time: missing unit in duration \"40\""
```

Fix: durations need units (`40s`). Restore from the backup if you cannot edit fast enough — the cluster runs *without a controller manager* while it crash-loops (other replicas cover it if HA).

### 5.3 Failure: unknown flag (regression after upgrade)

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-2 --previous | tail -2
Error: unknown flag: --pod-eviction-timeout
```

A removed flag (like `--pod-eviction-timeout`) survives in a hand-edited manifest across an upgrade and then breaks. Always reconcile custom flags against `kube-controller-manager --help` for the target version before upgrading.

### 5.4 Failure: split-brain / flapping leadership

```bash
$ kubectl -n kube-system get lease kube-controller-manager \
    -o jsonpath='{.spec.leaseTransitions}{"\n"}'
37                       # climbing fast → leadership is bouncing

$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -i 'lost lease\|stopped leading'
I0813 09:31:10.4471  1 leaderelection.go:285] "failed to renew lease kube-system/kube-controller-manager: timed out waiting for the condition"
E0813 09:31:10.4479  1 controllermanager.go:305] "leaderelection lost"
```

Causes and fixes:
- **`renew-deadline` too tight vs KCM CPU throttling** → give KCM more CPU (raise the pod `requests`) or relax `--leader-elect-renew-deadline`.
- **etcd/API-server latency spikes** → the Lease write can't land in time; fix the datastore, don't paper over it by widening timeouts.
- **Clock skew across control-plane nodes** → run NTP.

### 5.5 Failure: a controller silently isn't running

Symptom: ServiceAccounts get no token secret, or terminated pods never get GC'd, yet KCM is `Running`.

```bash
# Did the loop start?  (empty output = it never started → check --controllers)
$ kubectl -n kube-system logs kube-controller-manager-cp-1 \
    | grep -i 'Started controller' | grep -i 'serviceaccount-token'
                                    # <-- nothing: the loop is disabled

$ ps -C kube-controller-manager -o args --no-headers | grep -o -- '--controllers=[^ ]*'
--controllers=deployment,replicaset       # someone pinned an allow-list and dropped the rest
```

Fix: restore `--controllers=*,...` unless you are *intentionally* sharding controllers across processes (advanced; each shard must own a disjoint set and the union must be complete).

### 5.6 Failure: raised concurrency made things *worse*

Raising `--concurrent-*-syncs` and `--kube-api-qps` without checking API-server capacity throttles everyone via API Priority & Fairness:

```bash
$ kubectl -n kube-system exec kube-controller-manager-cp-1 -- \
    curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:10257/metrics \
  | grep -E 'rest_client_rate_limiter_duration_seconds_sum'
rest_client_rate_limiter_duration_seconds_sum{...} 812.4     # client is self-throttling heavily
```

`rest_client_rate_limiter_duration_seconds` climbing means the KCM's *own* client limiter (`--kube-api-qps`) is the bottleneck; but if `apiserver_flowcontrol_rejected_requests_total` on the API server is also rising, you've pushed past server capacity — back the concurrency **and** QPS down, or scale the API server/etcd first. Concurrency without headroom is negative work.

### 5.7 Quick verification checklist

| Claim | One-line proof |
|---|---|
| Flag X took effect | `ps -C kube-controller-manager -o args` shows it |
| Loop Y is running | `logs … | grep 'Started controller'` names it |
| We are the leader here | `/metrics` → `leader_election_master_status … 1` |
| Leadership is stable | `lease … .spec.leaseTransitions` is not climbing |
| Concurrency is adequate | `workqueue_depth{name="…"}` ≈ 0 at steady state |
| Not self-throttling | `rest_client_rate_limiter_duration_seconds` flat |
| Node timing is as designed | node → `NotReady` at ≈ `node-monitor-grace-period` |

---

## Referencias

- kube-controller-manager flag reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- Controllers concept (control-loop model): https://kubernetes.io/docs/concepts/architecture/controller/
- Cloud Controller Manager (KCM/CCM split): https://kubernetes.io/docs/concepts/architecture/cloud-controller/
- Node lifecycle, health & taint-based eviction: https://kubernetes.io/docs/concepts/architecture/nodes/
- Taints and Tolerations (NoExecute eviction, tolerationSeconds): https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Leader election / coordination Leases: https://kubernetes.io/docs/concepts/cluster-administration/coordinated-leader-election/
- Configure the aggregation & controller manager options via kubeadm (`ClusterConfiguration.controllerManager.extraArgs`): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/
- KubeControllerManagerConfiguration (v1alpha1 component config): https://kubernetes.io/docs/reference/config-api/kube-controller-manager-config.v1alpha1/
- API Priority and Fairness (interaction with `--kube-api-qps`/`--kube-api-burst`): https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- System component metrics (`workqueue_depth`, `leader_election_master_status`, `rest_client_rate_limiter_duration_seconds`): https://kubernetes.io/docs/reference/instrumentation/metrics/
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf