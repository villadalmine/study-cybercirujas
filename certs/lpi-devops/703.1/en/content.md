# 703.1 — Kubernetes Architecture and Usage

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0
**Topic weight:** 6.67
**Level:** Advanced (SRE / Platform Architect)
**Authoring baseline:** Kubernetes v1.33 (statements are flagged when they depend on a specific minor version)

---

## 0. Scope and how to read this material

The objective covers the architecture of a Kubernetes cluster, the role of every control plane and node component, the API object model, and the day-to-day operation of a cluster with `kubectl`. The exam expects you to *recognise and reason about* the components; production expects you to *diagnose them at 03:00*. This document is written for the second bar, because the first is a subset of it.

Concretely, by the end you must be able to answer without looking anything up:

- Which process holds cluster state, which process decides placement, which process makes the placement real, and which process makes the traffic reach it.
- What exactly happens between `kubectl apply -f deploy.yaml` returning `created` and a container running on a node.
- Which component you restart, and which one you must *never* restart blindly, when a cluster is degraded.
- Why `kubectl get nodes` says `NotReady` and which of the six plausible causes is the actual one.

Everything below is verifiable on a real cluster. Every terminal block is a command you can run.

---

## 1. The production problem: why an orchestrator exists at all

### 1.1 The imperative baseline and exactly where it breaks

Before orchestration, a service on a fleet of Linux hosts was deployed by pushing an artifact and running a unit:

```console
$ ansible -i prod.ini web -m copy -a "src=app-2.14.0.tar.gz dest=/opt/app/"
$ ansible -i prod.ini web -m systemd -a "name=app state=restarted"
web-03 | UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh"}
web-01 | CHANGED => {"changed": true, "name": "app", "state": "started"}
web-02 | CHANGED => {"changed": true, "name": "app", "state": "started"}
```

That output is the whole problem in three lines. The run is **edge-triggered**: it describes a transition ("restart now"), not a desired state. `web-03` missed the transition. Nothing in the system remembers that `web-03` is supposed to be running `2.14.0`. The cluster's real state now diverges from the operator's intent, and the only mechanism to detect it is a human re-reading the log.

Layer on the rest of production and the model collapses:

| Requirement | Imperative / config-management answer | Failure mode |
|---|---|---|
| A host dies at 04:12 | A human re-runs the playbook, or an autoscaler builds a host and hopefully converges | Recovery time = human response time |
| Capacity changes | Hand-maintained host→service mapping | Bin-packing done by spreadsheet; 30–60 % idle capacity |
| Rolling update with health gating | Custom scripts per service | Every team writes its own, all differently, all subtly wrong |
| Service discovery | Static config, or a separate Consul cluster | Two sources of truth that drift |
| Config/secret rotation | Push files, restart | No atomicity, no rollback, no audit trail |
| "What is actually running in prod?" | SSH and look | Unanswerable at scale |

### 1.2 The idea Kubernetes is built on: level-triggered reconciliation

Kubernetes replaces the transition with a **declaration** stored in a durable, watchable database, plus a set of independent control loops that continuously drive observed state toward it:

```
        ┌───────────────────────────────────────────────┐
        │  Desired state (spec)   —  written by humans  │
        │  stored in etcd via the API server            │
        └───────────────────┬───────────────────────────┘
                            │ WATCH
                            ▼
                 ┌──────────────────────┐
                 │  Controller loop     │   for ever:
                 │  observe → diff → act│     current := observe()
                 └───────────┬──────────┘     if current != desired:
                             │                    act()
                             ▼                 write status
        ┌───────────────────────────────────────────────┐
        │  Observed state (status) — written by machines │
        └───────────────────────────────────────────────┘
```

Two properties follow, and both matter operationally:

1. **Level-triggered, not edge-triggered.** A controller that misses an event still converges on the next resync, because it re-reads the full desired state rather than replaying a delta. This is why a controller crash is survivable and why Kubernetes tolerates lossy watches.
2. **`spec` is written by users; `status` is written by controllers.** Every object obeys this split. When you edit `status` by hand you are lying to a controller, and it will overwrite you. This is the single most useful mental model for reading any Kubernetes object.

The corollary that surprises newcomers: **Kubernetes never guarantees the desired state is reached — it guarantees it will keep trying.** A `Pending` Pod is not an error; it is a control loop honestly reporting that it cannot satisfy the declaration yet. Most "Kubernetes is broken" incidents are really "a controller is telling me something I did not read".

### 1.3 Orchestrator trade-offs

| Dimension | Kubernetes | Docker Swarm | HashiCorp Nomad | systemd + config management |
|---|---|---|---|---|
| State model | Declarative, level-triggered, extensible API | Declarative, fixed object set | Declarative, job-centric | Imperative, edge-triggered |
| Datastore | etcd (Raft), external process | Built-in Raft | Built-in Raft | None (files) |
| Extensibility | CRDs + controllers + admission webhooks + CRI/CNI/CSI | Effectively none | Plugin-based drivers | Arbitrary, unstructured |
| Workload types | Containers, plus anything a CRD models | Containers | Containers, raw exec, Java, QEMU | Anything |
| Networking | Flat pod network via CNI, pluggable | Overlay (built-in) | Host / bridge / CNI | Host networking |
| Operational cost | High: 5+ components, certs, etcd, upgrades | Low | Medium | Low per host, high at scale |
| Ecosystem | The CNCF landscape; portable skills | Effectively frozen | Small but coherent | N/A |
| When it is the right call | ≥ 3 teams, ≥ 20 services, or you need a platform API | Small static fleet, minimal ops | Mixed workloads, one binary, no k8s appetite | Fewer than ~5 hosts, one service |

The honest summary for an architect: Kubernetes buys you a **programmable, uniform API for the whole platform**, and charges you an entire operational discipline for it. Choose it when the API is the point. Do not choose it to run three containers.

---

## 2. Cluster anatomy

### 2.1 The whole picture

```
 ┌──────────────────────────── CONTROL PLANE NODE (xN) ──────────────────────────┐
 │                                                                               │
 │   ┌────────────┐     ┌─────────────────────────┐        ┌──────────────────┐  │
 │   │   etcd     │◄───►│     kube-apiserver      │◄──────►│ kube-scheduler   │  │
 │   │ :2379/2380 │     │        :6443            │        │     :10259       │  │
 │   └────────────┘     │  authn→authz→admission  │        └──────────────────┘  │
 │      Raft            │  →validate→persist      │        ┌──────────────────┐  │
 │      quorum          │  the ONLY etcd client   │◄──────►│ kube-controller- │  │
 │                      └───────────┬─────────────┘        │ manager :10257   │  │
 │                                  │                      └──────────────────┘  │
 │                                  │                      ┌──────────────────┐  │
 │                                  │                 ◄───►│ cloud-controller-│  │
 │                                  │                      │ manager (opt.)   │  │
 └──────────────────────────────────┼──────────────────────┴──────────────────┴──┘
                                    │  HTTPS, mTLS, WATCH streams
 ┌──────────────────────────────────┼─────────── WORKER NODE (xN) ───────────────┐
 │                                  ▼                                            │
 │   ┌──────────────┐   CRI    ┌───────────────┐   OCI    ┌────────────────┐     │
 │   │   kubelet    │─────────►│  containerd / │─────────►│ runc / crun /  │     │
 │   │   :10250     │          │    CRI-O      │          │ kata / gVisor  │     │
 │   └──────┬───────┘          └───────────────┘          └────────────────┘     │
 │          │ CNI ADD/DEL            │ CSI NodePublish                            │
 │          ▼                        ▼                                            │
 │   ┌──────────────┐        ┌────────────────┐        ┌────────────────────┐    │
 │   │ CNI plugin   │        │  CSI node dvr  │        │ kube-proxy :10249  │    │
 │   │ (Cilium…)    │        │  (EBS, Ceph…)  │        │ or eBPF replacement│    │
 │   └──────────────┘        └────────────────┘        └────────────────────┘    │
 └───────────────────────────────────────────────────────────────────────────────┘
```

Three architectural invariants are worth memorising, because most incorrect mental models violate one of them:

1. **Only the API server talks to etcd.** No other component has an etcd client. If someone proposes "the scheduler reads etcd directly", they are describing a different system.
2. **All communication is hub-and-spoke through the API server.** The scheduler does not call the kubelet. The controller manager does not call the scheduler. They communicate by writing objects that the other watches. This is why the API server is the only true SPOF and why every component keeps working (in a degraded, read-only-ish way) while it is down.
3. **The API server never initiates a connection to a node for normal operation.** The exceptions are `kubectl logs`, `exec`, `attach`, `port-forward` and webhooks/metrics — apiserver→kubelet:10250 and apiserver→webhook. Everything else is node→apiserver. This matters for firewall design.

### 2.2 Control plane components

| Component | Responsibility | Stateful? | Loses quorum/leader → | Default port | Restart blast radius |
|---|---|---|---|---|---|
| `etcd` | The only durable state. Raft consensus. | **Yes** | Cluster becomes read-only, then unavailable | 2379 (client), 2380 (peer) | **Severe** — restart one member at a time only |
| `kube-apiserver` | REST front-end, authn/authz/admission/validation, watch fan-out, the sole etcd client | No (caches) | Nothing can be read or written; running Pods keep running | 6443 | Moderate — safe if HA; kills open watches |
| `kube-scheduler` | Assigns `spec.nodeName` to unscheduled Pods | No | New Pods stay `Pending`; existing Pods unaffected | 10259 (https metrics/health) | Low |
| `kube-controller-manager` | ~40 built-in control loops (Deployment, ReplicaSet, Node, Endpoint, ServiceAccount, PV binder, …) | No | Nothing self-heals; no new ReplicaSets, no node eviction, no endpoint updates | 10257 | Low–moderate |
| `cloud-controller-manager` | Cloud-specific loops: node lifecycle, route, LoadBalancer service | No | LB services stall; node metadata stale | 10258 | Low |

Note the asymmetry: **losing the scheduler or the controller manager freezes change; losing etcd loses the cluster.** Your HA effort belongs mostly in etcd.

### 2.3 Node components

| Component | Responsibility | Runs as | Notes |
|---|---|---|---|
| `kubelet` | The node agent. Watches Pods bound to its node, drives the CRI, runs probes, reports `NodeStatus`, enforces eviction | systemd unit (**never** a Pod) | The one component that must not be containerised — it bootstraps the containers |
| Container runtime | Implements CRI: image pull, sandbox and container lifecycle | systemd unit (`containerd`, `crio`) | Dockershim was removed in **v1.24**; Docker Engine is only usable via `cri-dockerd` |
| `kube-proxy` | Programs the dataplane for Service ClusterIPs/NodePorts | DaemonSet (usually) | Optional if the CNI replaces it (Cilium/Calico eBPF) |
| CNI plugin | Pod network: IPAM, veth/interface setup, routing, NetworkPolicy | DaemonSet + binaries in `/opt/cni/bin` | The kubelet shells out to `/opt/cni/bin` using config in `/etc/cni/net.d` |
| CSI node driver | Mounts volumes into the Pod's mount namespace | DaemonSet | Paired with a controller-side CSI Deployment |

Control plane nodes run *all* of the node components too — the control plane itself is delivered as **static Pods** managed by the kubelet from `/etc/kubernetes/manifests`. That is the bootstrap trick: the kubelet needs no API server to run those Pods, so the API server can be a Pod.

```console
$ ls -1 /etc/kubernetes/manifests/
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml

$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED       STATE     NAME             ATTEMPT  POD ID         POD
1f0c9b1a4d2e7  4a1f3c8b9d21   3 weeks ago   Running   kube-apiserver   0        9a7d3e1b0c4f5  kube-apiserver-cp-1
```

A static Pod is identifiable from the API side by its **mirror Pod**: read-only, named `<pod>-<nodename>`, and impossible to delete via the API — delete the manifest file instead.

### 2.4 End to end: what `kubectl apply` actually triggers

This sequence is the single most examinable and most operationally useful thing in the objective.

1. **`kubectl`** reads `~/.kube/config`, resolves context → cluster URL + credentials, converts the YAML to JSON, and issues `POST /apis/apps/v1/namespaces/prod/deployments` (or `PATCH` with `?fieldManager=kubectl&force=…` for server-side apply).
2. **kube-apiserver — authentication.** The client certificate / bearer token / OIDC ID token is mapped to a username and groups. Failure → `401`.
3. **Authorization.** RBAC (usually) evaluates `verb=create, group=apps, resource=deployments, namespace=prod`. Failure → `403` with the exact rule that was missing.
4. **Mutating admission.** Built-in plugins then `MutatingAdmissionWebhook`s may rewrite the object: defaulting, sidecar injection, `ServiceAccount` token projection.
5. **Schema validation and defaulting**, then **validating admission** (`ValidatingAdmissionWebhook`, `ValidatingAdmissionPolicy` / CEL, `ResourceQuota`).
6. **Persist to etcd** as protobuf, under `/registry/deployments/prod/web`. The write returns a new `resourceVersion`.
7. **Deployment controller** (in kube-controller-manager) sees the ADDED event on its watch, creates a **ReplicaSet** with an `ownerReference` back to the Deployment and a `pod-template-hash` label.
8. **ReplicaSet controller** sees its ReplicaSet has 0/3 Pods and creates 3 Pods with `spec.nodeName` empty.
9. **kube-scheduler** watches for Pods with no `nodeName`, runs **filter → score**, and writes a `Binding` subresource which sets `spec.nodeName`.
10. **kubelet on the chosen node** sees a Pod bound to itself. It calls the CRI to create the **sandbox** (the pause container: it holds the network and IPC namespaces), invokes the **CNI** `ADD` to get an IP, calls **CSI** to mount volumes, pulls images, then starts init containers, then app containers.
11. **kubelet** writes `status.podIP`, `status.phase`, container statuses back to the API server.
12. **EndpointSlice controller** sees a Ready Pod matching a Service selector and adds it to an `EndpointSlice`.
13. **kube-proxy** on every node sees the EndpointSlice change and reprograms iptables/IPVS/nftables so the Service ClusterIP load-balances to the new Pod IP.

Thirteen steps, six independent processes, **zero direct calls between them**. Every arrow is a watch on the API server. Internalise this and cluster debugging becomes "which of these thirteen steps stopped, and what is that component's log saying".

---

## 3. The API server in depth

### 3.1 The resource model

Everything is a REST resource addressed as `/apis/<group>/<version>/namespaces/<ns>/<resource>/<name>`, with the legacy core group at `/api/v1/...` (no group name — a historical artefact you must simply remember).

```console
$ kubectl api-resources --sort-by=name | head -20
NAME                     SHORTNAMES   APIVERSION                       NAMESPACED   KIND
bindings                              v1                               true         Binding
certificatesigningrequests csr         certificates.k8s.io/v1           false        CertificateSigningRequest
configmaps               cm           v1                               true         ConfigMap
controllerrevisions                   apps/v1                          true         ControllerRevision
cronjobs                 cj           batch/v1                         true         CronJob
csidrivers                            storage.k8s.io/v1                false        CSIDriver
daemonsets               ds           apps/v1                          true         DaemonSet
deployments              deploy       apps/v1                          true         Deployment
endpoints                ep           v1                               true         Endpoints
endpointslices                        discovery.k8s.io/v1              true         EndpointSlice
events                   ev           events.k8s.io/v1                 true         Event
horizontalpodautoscalers hpa          autoscaling/v2                   true         HorizontalPodAutoscaler
ingresses                ing          networking.k8s.io/v1             true         Ingress
jobs                                  batch/v1                         true         Job
leases                                coordination.k8s.io/v1           true         Lease
namespaces               ns           v1                               false        Namespace
networkpolicies          netpol       networking.k8s.io/v1             true         NetworkPolicy
nodes                    no           v1                               false        Node
persistentvolumeclaims   pvc          v1                               true         PersistentVolumeClaim
persistentvolumes        pv           v1                               false        PersistentVolume
```

`kubectl explain` is served from the live cluster's OpenAPI document, so it is always correct for *that* cluster — including CRDs. Use it instead of the web docs:

```console
$ kubectl explain deployment.spec.strategy.rollingUpdate.maxUnavailable
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: maxUnavailable <IntOrString>

DESCRIPTION:
    The maximum number of pods that can be unavailable during the update.
    Value can be an absolute number (ex: 5) or a percentage of desired pods
    (ex: 10%). Absolute number is calculated from percentage by rounding down.
```

**Storage version vs served versions.** An object is stored in etcd in exactly one version; the API server converts on read to whichever served version you asked for. This is why `apps/v1beta1` disappearing did not corrupt data — and why `kubectl get deploy -o yaml` shows `apps/v1` regardless of what you applied.

### 3.2 The request pipeline, and where requests die

```
client
  │
  ▼ TLS (client cert / token / OIDC)
[ Authentication ]────────────────► 401 Unauthorized
  │  user=alice groups=[dev, system:authenticated]
  ▼
[ Authorization ] (RBAC → Node → Webhook, first ALLOW wins)
  │                                ► 403 Forbidden
  ▼
[ Mutating admission ]  built-ins → MutatingAdmissionWebhooks
  │                                ► 500 / webhook timeout
  ▼
[ Object schema validation + defaulting ]
  │                                ► 422 Unprocessable / 400
  ▼
[ Validating admission ] ValidatingAdmissionPolicy (CEL) → webhooks → quota
  │                                ► 403 (denied by policy/quota)
  ▼
[ etcd write ]                     ► 409 Conflict (resourceVersion mismatch)
  │
  ▼ 201 Created
```

Two operational rules fall out of this diagram:

- **A failing admission webhook can brick the entire cluster.** A webhook with `failurePolicy: Fail` whose backing Pods are down will reject the very requests needed to fix it. Always scope webhooks with `namespaceSelector`/`objectSelector` and exclude `kube-system`.
- **`403` tells you which rule was missing.** Read the message; do not guess.

```console
$ kubectl auth can-i create deployments --namespace prod --as jane
no - no RBAC policy matched

$ kubectl auth can-i --list --namespace prod --as jane | head -6
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
pods                                            []                  []               [get list watch]
configmaps                                      []                  []               [get list watch]
```

### 3.3 Watch, `resourceVersion`, and optimistic concurrency

Controllers do not poll. They `LIST` once to build a cache, then `WATCH` from the returned `resourceVersion` and consume a stream of ADDED/MODIFIED/DELETED events. This is the mechanism that makes a 5000-node cluster feasible.

```console
$ kubectl get --raw '/api/v1/namespaces/prod/pods?watch=1&resourceVersion=48210332' | head -2
{"type":"MODIFIED","object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"web-7d9f6c8b5-2xk4t","resourceVersion":"48210377",...
{"type":"ADDED","object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"web-7d9f6c8b5-9plmz","resourceVersion":"48210381",...
```

Every object carries `metadata.resourceVersion`, an opaque etcd revision. Updates are **optimistically concurrent**: `PUT` with a stale `resourceVersion` returns `409 Conflict`, and the client must re-read and retry. That is why you see this and why it is *not* an error:

```console
$ kubectl edit deployment web -n prod
error: deployments.apps "web" could not be patched: Operation cannot be fulfilled on deployments.apps "web": the object has been modified; please apply your changes to the latest version and try again
```

`410 Gone` on a watch means the requested `resourceVersion` was compacted away in etcd; the client must re-LIST. A cluster emitting constant `410`s from controllers is telling you etcd compaction is too aggressive or the controllers are too slow.

### 3.4 API Priority and Fairness

APF (GA since **v1.29**) replaced the blunt `--max-requests-inflight` with queueing by priority level, so that a misbehaving client cannot starve the control plane's own loops.

```console
$ kubectl get flowschemas
NAME                           PRIORITYLEVEL     MATCHINGPRECEDENCE   DISTINGUISHERMETHOD   AGE
exempt                         exempt            1                    <none>                61d
probes                         exempt            2                    <none>                61d
system-leader-election         leader-election   100                  ByUser                61d
workload-leader-election       leader-election   200                  ByUser                61d
system-node-high               node-high         400                  ByUser                61d
system-nodes                   system            500                  ByUser                61d
kube-controller-manager        workload-high     800                  ByNamespace           61d
kube-scheduler                 workload-high     800                  ByNamespace           61d
service-accounts               workload-low      9000                 ByUser                61d
global-default                 global-default    9900                 ByUser                61d
catch-all                      catch-all         10000                ByUser                61d

$ kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total | head -3
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="global-default",reason="queue-full"} 0
apiserver_flowcontrol_rejected_requests_total{flow_schema="service-accounts",priority_level="workload-low",reason="queue-full"} 147
apiserver_flowcontrol_rejected_requests_total{flow_schema="catch-all",priority_level="catch-all",reason="time-out"} 0
```

A client that gets throttled receives `429 Too Many Requests` with a `Retry-After`. 147 rejections on `workload-low` above is a real finding: some ServiceAccount is hammering the API server, and you find it with `apiserver_request_total` by `user_agent`.

### 3.5 Health endpoints — the modern replacement for `componentstatuses`

`kubectl get componentstatuses` is deprecated and lies on HA clusters (it only checks the local endpoints). Use the health endpoints:

```console
$ kubectl get --raw '/livez?verbose'
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/start-cluster-authentication-info-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/apiservice-registration-controller ok
[+]autoregister-completion ok
livez check passed

$ kubectl get --raw '/readyz?verbose' | tail -4
[+]shutdown ok
[+]etcd-readiness ok
[+]informer-sync ok
readyz check passed
```

- `/livez` — "should this process be restarted?" Wire it to the kubelet liveness probe.
- `/readyz` — "should this instance receive traffic?" Wire it to the load balancer.
- `/healthz` — deprecated aggregate of both.

Scheduler and controller-manager expose the same on their secure ports:

```console
$ curl -sk https://127.0.0.1:10259/healthz ; echo
ok
$ curl -sk https://127.0.0.1:10257/healthz ; echo
ok
```

---

## 4. etcd — the only thing you can actually lose

### 4.1 Consensus, quorum and the cost of a write

etcd is a strongly consistent key-value store using **Raft**. One member is the leader; all writes go through it and are committed only once a **quorum** (majority) has persisted the entry to its write-ahead log — which means an `fsync` on every member in the quorum. **etcd write latency is disk fsync latency**, which is why etcd on network storage or on a busy shared disk destroys a cluster.

| Members | Quorum needed | Failures tolerated | Verdict |
|---|---|---|---|
| 1 | 1 | 0 | Dev only |
| 2 | 2 | 0 | **Worse than 1** — never do this |
| 3 | 2 | 1 | The standard production choice |
| 4 | 3 | 1 | Same tolerance as 3, more write latency |
| 5 | 3 | 2 | Large/critical clusters |
| 7 | 4 | 3 | Rarely justified; write latency grows |

Even member counts are strictly worse than the odd number below them: same fault tolerance, more coordination. Always odd.

### 4.2 Inspecting etcd

`etcdctl` must be given client certs; on a kubeadm cluster they are in `/etc/kubernetes/pki/etcd/`.

```console
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --cluster --write-out=table
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://10.10.0.10:2379   | 8e9e05c52164694d |   3.5.15|  212 MB |     false |      false |        14 |   48210401 |           48210401 |        |
| https://10.10.0.11:2379   | 91bc3c398fb3c146 |   3.5.15|  212 MB |      true |      false |        14 |   48210401 |           48210401 |        |
| https://10.10.0.12:2379   | fd422379fda50e48 |   3.5.15|  213 MB |     false |      false |        14 |   48210401 |           48210401 |        |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+

$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health --cluster --write-out=table
+--------------------------+--------+-------------+-------+
|         ENDPOINT         | HEALTH |    TOOK     | ERROR |
+--------------------------+--------+-------------+-------+
| https://10.10.0.11:2379  |   true | 9.114231ms  |       |
| https://10.10.0.10:2379  |   true | 10.882712ms |       |
| https://10.10.0.12:2379  |   true | 11.409885ms |       |
+--------------------------+--------+-------------+-------+
```

Read that table like an SRE:

- **`RAFT INDEX` diverging** across members = a member is lagging or partitioned.
- **`RAFT TERM` incrementing** repeatedly = leader elections are flapping, almost always disk or network latency.
- **`DB SIZE` growing without bound** = compaction/defrag is not keeping up. The default quota is 2 GiB; crossing it puts the cluster into a **read-only alarm** and the API server starts failing every write with `etcdserver: mvcc: database space exceeded`.

### 4.3 Backup and restore

This is the one procedure every cluster operator must have muscle memory for.

```console
$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-$(date +%F-%H%M).db
{"level":"info","ts":"2026-09-03T11:58:02.441Z","caller":"snapshot/v3_snapshot.go:65","msg":"created temporary db file","path":"/var/backups/etcd-2026-09-03-1158.db.part"}
{"level":"info","ts":"2026-09-03T11:58:04.902Z","caller":"snapshot/v3_snapshot.go:75","msg":"fetched snapshot","took":"2.451s"}
Snapshot saved at /var/backups/etcd-2026-09-03-1158.db

$ sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/backups/etcd-2026-09-03-1158.db
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 7b4c2f91 | 48210401 |      14872 |     212 MB |
+----------+----------+------------+------------+
```

Restore procedure (destructive, run on every control plane node):

```console
$ sudo mv /etc/kubernetes/manifests/*.yaml /tmp/manifests-parked/    # stops static pods
$ sudo systemctl stop kubelet
$ sudo mv /var/lib/etcd /var/lib/etcd.bak
$ sudo ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd-2026-09-03-1158.db \
    --data-dir=/var/lib/etcd \
    --name=cp-1 \
    --initial-cluster=cp-1=https://10.10.0.10:2380,cp-2=https://10.10.0.11:2380,cp-3=https://10.10.0.12:2380 \
    --initial-advertise-peer-urls=https://10.10.0.10:2380
$ sudo mv /tmp/manifests-parked/*.yaml /etc/kubernetes/manifests/
$ sudo systemctl start kubelet
```

The trap that catches people: **a snapshot restore rewrites the member ID and cluster ID**, so a restored member cannot join surviving members. You restore the *whole* cluster from one snapshot, not a single member. Note also that PersistentVolume *data* is not in etcd — restoring etcd to an older revision while volumes moved on produces a cluster that believes things about storage that are no longer true.

---

## 5. kube-scheduler

### 5.1 Two phases, one decision

For each Pod pulled off the scheduling queue:

1. **Filtering (predicates)** — eliminate nodes that *cannot* run the Pod: insufficient allocatable CPU/memory, taints not tolerated, node selectors/affinity unmatched, volume zone conflict, port conflict, node unschedulable.
2. **Scoring (priorities)** — rank the survivors 0–100 per plugin, weight and sum. Defaults favour spreading across nodes/zones, balanced CPU-memory allocation, image locality, and inter-pod affinity.
3. **Reserve → Permit → Bind** — write a `Binding` setting `spec.nodeName`.

The **scheduling framework** exposes these as ordered extension points: `PreEnqueue`, `QueueSort`, `PreFilter`, `Filter`, `PostFilter`, `PreScore`, `Score`, `NormalizeScore`, `Reserve`, `Permit`, `PreBind`, `Bind`, `PostBind`. Custom schedulers are plugins at these points, not forks.

`PostFilter` is where **preemption** happens: if no node passes filtering, the scheduler looks for a node where evicting lower-`priorityClassName` Pods would make room, and marks victims for graceful deletion.

### 5.2 A complete scheduler configuration

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
leaderElection:
  leaderElect: true
  resourceNamespace: kube-system
  resourceName: kube-scheduler
percentageOfNodesToScore: 50
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: PodTopologySpread
        args:
          defaultingType: System
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: LeastAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 1
    plugins:
      score:
        enabled:
          - name: NodeResourcesFit
            weight: 2
          - name: PodTopologySpread
            weight: 4
        disabled:
          - name: ImageLocality
  - schedulerName: bin-packing-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: MostAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 3
```

Two profiles in one process: workloads that set `spec.schedulerName: bin-packing-scheduler` get dense packing (good for batch, saves nodes), everything else gets spreading (good for availability). This is the standard lever for the availability-vs-cost trade-off.

`percentageOfNodesToScore: 50` is the large-cluster lever: the scheduler stops filtering once it has found enough feasible nodes, trading placement optimality for throughput.

### 5.3 Watching a scheduling decision

```console
$ kubectl get events -n prod --field-selector reason=FailedScheduling
LAST SEEN   TYPE      REASON             OBJECT                        MESSAGE
2m14s       Warning   FailedScheduling   pod/analytics-6b8f9d4c7-vzq2n  0/6 nodes are available: 2 Insufficient cpu, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/6 nodes are available: 2 No preemption victims found for incoming pod, 4 Preemption is not helpful for scheduling.
```

That message is a complete diagnosis: it enumerates every node and the exact predicate that rejected it, then reports whether preemption could help. Read it literally and the fix is obvious — here, either relax the affinity or add capacity to the two matching nodes.

---

## 6. The controller pattern and kube-controller-manager

### 6.1 Anatomy of a controller

Every controller — built-in or your own operator — has the same shape:

```
  Reflector ──LIST+WATCH──► API server
      │
      ▼ push
  DeltaFIFO ──► Informer ──► Indexer (thread-safe local cache)
                   │
                   ▼ ResourceEventHandler (add/update/delete)
              Workqueue (rate-limited, deduplicating, per-key)
                   │
                   ▼
              Worker: syncHandler(namespace/name)
                   │  read desired from cache, read actual, diff, act
                   ▼
              API writes (create/update/patch status)
```

The consequences worth knowing:

- **The workqueue deduplicates by key.** A hundred events for the same object collapse into one reconcile. This is why controllers survive event storms.
- **Reconcile is idempotent and reads full state.** It never trusts the event payload.
- **Rate-limited retries with exponential backoff** on error, which is why a failing reconcile shows up as increasingly rare log lines, not a tight loop.
- **`--concurrent-deployment-syncs` and friends** are the knobs when reconciliation lags on a big cluster.

### 6.2 Leader election

Only one replica of the controller manager and scheduler is active at a time. They contend for a `Lease` object:

```console
$ kubectl get lease -n kube-system kube-controller-manager -o yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  holderIdentity: cp-2_3f9a1e0c-77b4-4f6d-9a2e-1c8b5d0e4a13
  leaseDurationSeconds: 15
  acquireTime: "2026-09-01T08:14:22.000000Z"
  renewTime: "2026-09-03T11:59:41.882000Z"
  leaseTransitions: 3
```

`leaseTransitions: 3` means leadership changed three times — normal after upgrades, alarming if it grows hourly (points at API server latency or a saturated control plane node). The same `Lease` mechanism backs **node heartbeats** in `kube-node-lease`, which is why heartbeats are cheap enough for thousands of nodes.

### 6.3 Ownership and garbage collection

Controllers link objects with `ownerReferences`. This is what makes `kubectl delete deployment web` remove the ReplicaSets and Pods without the Deployment controller doing it explicitly:

```console
$ kubectl get rs -n prod web-7d9f6c8b5 -o jsonpath='{.metadata.ownerReferences}' | jq
[
  {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "name": "web",
    "uid": "b1d9f0a3-5c2e-4a77-9f31-8d0c6e2b4a19",
    "controller": true,
    "blockOwnerDeletion": true
  }
]
```

Deletion propagation policies: `Background` (default — owner deleted immediately, dependents cleaned asynchronously), `Foreground` (owner stays in `deletionTimestamp` state until dependents are gone), `Orphan` (dependents survive). `--cascade=orphan` is the safe way to replace a Deployment without restarting its Pods.

**Finalizers** are the related trap: an object with `metadata.finalizers` will not be removed from etcd until every finalizer is cleared by its controller. A namespace stuck `Terminating` for hours is almost always a finalizer whose controller is gone.

```console
$ kubectl get ns legacy -o jsonpath='{.spec.finalizers}{"\n"}{.status.conditions[?(@.type=="NamespaceFinalizersRemaining")].message}{"\n"}'
["kubernetes"]
Some content in the namespace has finalizers remaining: monitoring.coreos.com/prometheus in 1 resource instances
```

---

## 7. kubelet

### 7.1 What it actually does

The kubelet is the only component that turns API objects into running processes. Its responsibilities:

- Watch Pods where `spec.nodeName == <this node>` (plus static Pods from disk and, optionally, an HTTP endpoint).
- Drive the CRI: `RunPodSandbox`, `PullImage`, `CreateContainer`, `StartContainer`.
- Call the CNI to attach the sandbox to the pod network; call CSI to mount volumes.
- Run liveness/readiness/startup probes and act on them (restart / remove from endpoints).
- Report `NodeStatus` and renew the node `Lease` every 10 s.
- Enforce **node-pressure eviction** and manage cgroups, QoS classes and OOM scores.
- Serve `logs`, `exec`, `attach`, `port-forward` and the stats endpoints on port 10250.

**PLEG** (Pod Lifecycle Event Generator) periodically relists containers from the runtime to detect state changes the runtime did not report. `PLEG is not healthy: pleg was last seen active 3m52s ago` in the kubelet log is a canonical symptom of a wedged container runtime, not of the kubelet.

### 7.2 A production KubeletConfiguration

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
serverTLSBootstrap: true
rotateCertificates: true
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
maxPods: 110
podsPerCore: 0
nodeStatusUpdateFrequency: 10s
nodeStatusReportFrequency: 5m
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
enforceNodeAllocatable:
  - pods
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: "1m30s"
  nodefs.available: "2m"
evictionMaxPodGracePeriod: 60
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
serializeImagePulls: false
maxParallelImagePulls: 5
protectKernelDefaults: true
readOnlyPort: 0
```

The `cgroupDriver` line is not cosmetic. **The kubelet and the container runtime must agree**; if the kubelet says `systemd` and containerd says `cgroupfs`, you get two cgroup hierarchies, unreliable resource accounting and nodes that flap under load. On any modern systemd distribution, both must be `systemd`.

`systemReserved` + `kubeReserved` + `evictionHard` are subtracted from capacity to give **allocatable**. Skipping them is the number-one cause of nodes dying under memory pressure: the kubelet and sshd get OOM-killed alongside the workload, and you lose the node instead of a Pod.

```console
$ kubectl describe node worker-03 | sed -n '/^Capacity:/,/^System Info:/p'
Capacity:
  cpu:                16
  ephemeral-storage:  103890480Ki
  hugepages-2Mi:      0
  memory:             65806300Ki
  pods:               110
Allocatable:
  cpu:                15
  ephemeral-storage:  95723312Ki
  hugepages-2Mi:      0
  memory:             63185884Ki
  pods:               110
```

### 7.3 QoS classes — how eviction picks victims

| QoS class | Condition | OOM score adjust | Evicted |
|---|---|---|---|
| `Guaranteed` | Every container sets `requests == limits` for **both** cpu and memory | −997 | Last |
| `Burstable` | At least one request set, but not equal to limits | 2 … 999 (scaled by request) | Second |
| `BestEffort` | No requests or limits anywhere | 1000 | **First** |

Under node memory pressure the kubelet ranks Pods by QoS class, then by how far usage exceeds requests, then by Pod priority. `BestEffort` Pods on a production node are a self-inflicted outage waiting for a traffic spike.

---

## 8. Networking: the model, and kube-proxy modes

### 8.1 The four rules of the Kubernetes network model

1. Every Pod gets its own routable IP address.
2. Pods on any node can reach Pods on any node **without NAT**.
3. Agents on a node (kubelet, daemons) can reach all Pods on that node.
4. The IP a Pod sees for itself is the IP others use to reach it.

Kubernetes implements *none* of this. A **CNI plugin** does. That is why a fresh cluster has `NotReady` nodes and `Pending` CoreDNS Pods until you install one.

There are three separate address spaces, and confusing them causes most networking incidents:

| Space | Typical range | Allocated by | Routable outside the cluster? |
|---|---|---|---|
| Node network | Your LAN/VPC | Your infrastructure | Yes |
| Pod CIDR | `10.244.0.0/16` | CNI IPAM, subdivided per node | Only if the CNI is in routed mode |
| Service CIDR (ClusterIP) | `10.96.0.0/12` | kube-apiserver | **No — these IPs are virtual and exist only as dataplane rules** |

A ClusterIP does not answer ping and has no interface. It is a rule in iptables/IPVS/nftables/eBPF, on every node.

### 8.2 kube-proxy modes compared

| Mode | Mechanism | Rule complexity | Update cost at 10 000 services | LB algorithms | Notes |
|---|---|---|---|---|---|
| `iptables` | Chains of `KUBE-SVC-*` / `KUBE-SEP-*` with statistic module | O(n) linear match | O(n) — full table rewrite, seconds of latency | Random only | Default for years; degrades badly above a few thousand services |
| `ipvs` | Kernel L4 load balancer, hash table | O(1) lookup | Incremental, milliseconds | rr, wrr, lc, wlc, sh, dh, sed, nq | Requires `ip_vs` modules; still uses some iptables for masquerade/NodePort |
| `nftables` | Native nftables sets and maps | O(1) via verdict maps | Incremental | Random | Alpha v1.29, beta v1.31, **GA v1.33**; the intended successor to `iptables` mode |
| `kernelspace` | Windows HNS/VFP | — | — | — | Windows nodes only |
| *(eBPF replacement)* | Cilium/Calico replace kube-proxy entirely | O(1) eBPF maps | Incremental | Maglev/random | **Not a kube-proxy mode** — kube-proxy is removed; also gives DSR and better observability |

```console
$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^(mode|ipvs:)' -A3
mode: "ipvs"
ipvs:
  excludeCIDRs: null
  minSyncPeriod: 0s
  scheduler: "rr"

$ sudo ipvsadm -Ln | head -12
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.0.1:443 rr
  -> 10.10.0.10:6443              Masq    1      4          0
  -> 10.10.0.11:6443              Masq    1      3          0
  -> 10.10.0.12:6443              Masq    1      5          0
TCP  10.96.0.10:53 rr
  -> 10.244.1.7:53                Masq    1      0          0
  -> 10.244.2.9:53                Masq    1      0          0
TCP  10.98.14.201:80 rr
  -> 10.244.3.15:8080             Masq    1      12         3
  -> 10.244.4.22:8080             Masq    1      11         4
```

For the `iptables` equivalent:

```console
$ sudo iptables -t nat -L KUBE-SERVICES -n | head -8
Chain KUBE-SERVICES (2 references)
target     prot opt source     destination
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0  10.96.0.1      /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  0.0.0.0/0  10.96.0.10     /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  0.0.0.0/0  10.96.0.10     /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
KUBE-SVC-XGLOHA7QRQ3V22RZ  tcp  --  0.0.0.0/0  10.98.14.201   /* prod/web:http cluster IP */ tcp dpt:80
```

### 8.3 Cluster DNS

CoreDNS runs as a Deployment, exposed by the `kube-dns` Service at the tenth address of the Service CIDR by convention. The kubelet injects it into every Pod's `/etc/resolv.conf`:

```console
$ kubectl run -it --rm dnstest --image=busybox:1.36 --restart=Never -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

`ndots:5` means any name with fewer than 5 dots is tried against every search domain first — so `api.example.com` generates four failing lookups before the correct one. On DNS-heavy workloads this is a measurable latency and QPS problem; the fix is a trailing dot (`api.example.com.`) or a per-Pod `dnsConfig` with a lower `ndots`.

The FQDN scheme you must know cold: `<service>.<namespace>.svc.<cluster-domain>`, and for headless services `<pod-hostname>.<service>.<namespace>.svc.<cluster-domain>`.

---

## 9. Container runtime and CRI

The kubelet speaks **CRI**, a gRPC API over a Unix socket, split into `RuntimeService` and `ImageService`. Docker Engine never implemented CRI; the kubelet carried an adapter called dockershim, which was **removed in v1.24**.

| Runtime | CRI native | Socket | Positioning |
|---|---|---|---|
| `containerd` | Yes (CRI plugin) | `/run/containerd/containerd.sock` | The default nearly everywhere; graduated CNCF project |
| `CRI-O` | Yes (built only for Kubernetes) | `/run/crio/crio.sock` | Minimal surface, versioned in lockstep with Kubernetes |
| Docker Engine | No — needs `cri-dockerd` | `/run/cri-dockerd.sock` | Extra hop; only for legacy constraints |
| Kata Containers | Via containerd/CRI-O `RuntimeClass` | — | Hardware-isolated VM per Pod, for hostile multitenancy |
| gVisor (`runsc`) | Via `RuntimeClass` | — | Userspace kernel; syscall filtering with a performance cost |

`crictl` is the node-level debugging tool. It talks to the CRI socket directly, so it works when the API server is down — which is exactly when you need it.

```console
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a | head -6
CONTAINER      IMAGE          CREATED         STATE      NAME                     ATTEMPT  POD ID         POD
7c1e9a4b2f08d  b19406328e70   4 minutes ago   Running    web                      0        3a8e0d7c1b9f2  web-7d9f6c8b5-2xk4t
0a4d2c8e91b73  8c811b4aec35   9 minutes ago   Exited     migrate                  2        3a8e0d7c1b9f2  web-7d9f6c8b5-2xk4t
1f0c9b1a4d2e7  4a1f3c8b9d21   3 weeks ago     Running    kube-apiserver           0        9a7d3e1b0c4f5  kube-apiserver-cp-1

$ sudo crictl logs --tail 5 0a4d2c8e91b73
2026/09/03 11:52:10 connecting to postgres://db.prod.svc.cluster.local:5432
2026/09/03 11:52:40 dial tcp: i/o timeout
2026/09/03 11:52:40 migration failed: cannot reach database
$ sudo crictl imagefsinfo
{"status":{"timestamp":"1756901940000000000","fsId":{"mountpoint":"/var/lib/containerd"},"usedBytes":{"value":"18374912000"},"inodesUsed":{"value":"284431"}}}
```

Use `crictl`, never `docker`, on a containerd node — and note that `crictl` is a *debugging* tool: containers it creates are not managed by the kubelet and will be garbage-collected.

---

## 10. The object model in practice

### 10.1 Pod → ReplicaSet → Deployment

The Pod is the scheduling and network unit: one or more containers sharing a network namespace, IPC namespace and volumes. Pods are deliberately **not** self-healing — a controller owns that.

A complete, production-shaped Deployment with everything an SRE actually requires:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: prod
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/component: frontend
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 6
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
        app.kubernetes.io/component: frontend
    spec:
      serviceAccountName: web
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: web
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: web
      initContainers:
        - name: schema-migrate
          image: registry.example.com/storefront/migrate:2.14.0
          args: ["--wait-for-db=60s"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
      containers:
        - name: web
          image: registry.example.com/storefront/web:2.14.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: web-db
                  key: password
          envFrom:
            - configMapRef:
                name: web-config
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 15
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/web
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: prod
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  internalTrafficPolicy: Cluster
  sessionAffinity: None
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: prod
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: web
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 6
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 4
          periodSeconds: 30
      selectPolicy: Max
```

Design notes an architect is expected to justify:

- **`maxUnavailable: 0` with `maxSurge: 2`** — never dip below capacity during a rollout; costs two extra Pods' worth of resource for the duration.
- **`memory` limit == request, no CPU limit** — memory is incompressible so the limit prevents a noisy neighbour killing the node; a CPU limit only introduces CFS throttling and tail latency. This is the current mainstream SRE consensus, and it makes the Pod `Burstable`, not `Guaranteed` — a deliberate trade.
- **`preStop: sleep 10` plus `terminationGracePeriodSeconds: 45`** — Pod deletion removes the endpoint and sends SIGTERM *concurrently*. Without the sleep, kube-proxy on some node will still send traffic to a shutting-down Pod. This is the fix for "we get 502s during every deploy".
- **`startupProbe` with `failureThreshold: 30`** — decouples slow start (up to 150 s) from an aggressive liveness probe. Without it, a slow-booting app gets killed in a restart loop forever.
- **PDB `minAvailable: 4` of 6** — bounds *voluntary* disruption (`kubectl drain`, node upgrades). It does **not** protect against node crashes.

### 10.2 Services and EndpointSlices

```console
$ kubectl -n prod get svc web -o wide
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.98.14.201   <none>        80/TCP    31d   app.kubernetes.io/name=web

$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                       AGE
web-8k4mz   IPv4          8080    10.244.3.15,10.244.4.22,10.244.5.31 + 3 more   31d

$ kubectl -n prod get endpointslice web-8k4mz -o jsonpath='{range .endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.nodeName}{"\n"}{end}'
10.244.3.15	true	worker-01
10.244.4.22	true	worker-02
10.244.5.31	true	worker-03
10.244.3.19	true	worker-01
10.244.4.27	false	worker-02
10.244.5.33	true	worker-03
```

**`ready: false` on one endpoint is the whole diagnosis** for "one in six requests fails" — that Pod is failing its readiness probe and correctly excluded from load balancing. EndpointSlices replaced the single `Endpoints` object precisely because a 5000-endpoint Service produced one enormous object rewritten on every change, saturating the API server.

| Service type | Reachable from | Implemented by | Use for |
|---|---|---|---|
| `ClusterIP` | Inside the cluster only | kube-proxy dataplane | East-west traffic (the default, and correct 90 % of the time) |
| `NodePort` | `<any-node-ip>:30000-32767` | kube-proxy dataplane | External LB you manage yourself; bare metal |
| `LoadBalancer` | Cloud LB VIP | cloud-controller-manager or MetalLB | Cloud north-south entry |
| `ExternalName` | CNAME in cluster DNS | CoreDNS only — no proxying | Aliasing an out-of-cluster dependency |
| Headless (`clusterIP: None`) | DNS returns Pod IPs directly | CoreDNS only | StatefulSets, client-side LB, gRPC |

---

## 11. `kubectl`: the operator's interface

### 11.1 kubeconfig

```yaml
apiVersion: v1
kind: Config
preferences: {}
current-context: prod-admin
clusters:
  - name: prod
    cluster:
      server: https://api.prod.example.com:6443
      certificate-authority: /home/sre/.kube/prod-ca.crt
  - name: staging
    cluster:
      server: https://api.staging.example.com:6443
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
contexts:
  - name: prod-admin
    context:
      cluster: prod
      user: sre-oidc
      namespace: prod
  - name: staging-admin
    context:
      cluster: staging
      user: staging-admin
      namespace: default
users:
  - name: sre-oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl-oidc_login
        args:
          - get-token
          - --oidc-issuer-url=https://sso.example.com/realms/platform
          - --oidc-client-id=kubernetes
        interactiveMode: IfAvailable
  - name: staging-admin
    user:
      client-certificate: /home/sre/.kube/staging-admin.crt
      client-key: /home/sre/.kube/staging-admin.key
```

Three separate lists — clusters, users, contexts — joined by a context. The `exec` credential plugin is how every real organisation authenticates: short-lived OIDC tokens, no long-lived certificates on laptops. Precedence: `--kubeconfig` > `$KUBECONFIG` (colon-separated, merged) > `~/.kube/config`.

```console
$ kubectl config get-contexts
CURRENT   NAME            CLUSTER   AUTHINFO        NAMESPACE
*         prod-admin      prod      sre-oidc        prod
          staging-admin   staging   staging-admin   default

$ kubectl config use-context staging-admin
Switched to context "staging-admin".

$ kubectl config set-context --current --namespace=payments
Context "staging-admin" modified.
```

### 11.2 Imperative, declarative, and server-side apply

| Approach | Command | Where it belongs |
|---|---|---|
| Imperative | `kubectl create deployment web --image=…` | Interactive exploration, exam speed, never in Git |
| Imperative with local file | `kubectl create -f web.yaml` | Fails on re-run; not idempotent |
| Declarative (client-side apply) | `kubectl apply -f manifests/` | The long-standing default; merges via `last-applied-configuration` annotation |
| **Server-side apply** | `kubectl apply --server-side -f …` | Multiple controllers own different fields of one object; conflicts are reported, not silently overwritten |

The generators remain the fastest way to produce a correct skeleton:

```console
$ kubectl create deployment web --image=nginx:1.27 --replicas=3 --dry-run=client -o yaml > web.yaml
$ kubectl create service clusterip web --tcp=80:8080 --dry-run=client -o yaml >> web.yaml
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied
service/web serverside-applied
```

Server-side apply records **field managers**, which is how you find out who is fighting you over a field:

```console
$ kubectl -n prod get deploy web -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
kubectl	Apply
kube-controller-manager	Update
flux	Apply
```

Two `Apply` managers on the same object is exactly the "someone reverts my change every 5 minutes" bug.

### 11.3 The commands that matter under pressure

```console
$ kubectl -n prod get pods -o wide --sort-by=.status.startTime | tail -4
NAME                    READY   STATUS             RESTARTS        AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-7d9f6c8b5-9plmz     1/1     Running            0               4m12s   10.244.5.33   worker-03   <none>           <none>
web-7d9f6c8b5-2xk4t     0/1     CrashLoopBackOff   6 (2m11s ago)   9m48s   10.244.3.19   worker-01   <none>           <none>

$ kubectl -n prod get pods --field-selector status.phase!=Running
NAME                    READY   STATUS             RESTARTS        AGE
web-7d9f6c8b5-2xk4t     0/1     CrashLoopBackOff   6 (2m11s ago)   9m48s

$ kubectl -n prod logs web-7d9f6c8b5-2xk4t --previous --tail=20
panic: open /var/run/secrets/db/password: permission denied

goroutine 1 [running]:
main.mustReadSecret(...)

$ kubectl -n prod describe pod web-7d9f6c8b5-2xk4t | tail -12
Events:
  Type     Reason     Age                    From               Message
  ----     ------     ----                   ----               -------
  Normal   Scheduled  9m50s                  default-scheduler  Successfully assigned prod/web-7d9f6c8b5-2xk4t to worker-01
  Normal   Pulled     9m48s                  kubelet            Container image "registry.example.com/storefront/web:2.14.0" already present on machine
  Normal   Created    8m11s (x4 over 9m48s)  kubelet            Created container: web
  Normal   Started    8m11s (x4 over 9m48s)  kubelet            Started container web
  Warning  BackOff    4m30s (x21 over 9m2s)  kubelet            Back-off restarting failed container web in pod web-7d9f6c8b5-2xk4t_prod

$ kubectl -n prod get events --sort-by=.lastTimestamp | tail -5
9m50s   Normal    Scheduled          pod/web-7d9f6c8b5-2xk4t   Successfully assigned prod/web-7d9f6c8b5-2xk4t to worker-01
8m11s   Normal    Created            pod/web-7d9f6c8b5-2xk4t   Created container: web
4m30s   Warning   BackOff            pod/web-7d9f6c8b5-2xk4t   Back-off restarting failed container web
2m14s   Warning   FailedScheduling   pod/analytics-6b8f9d4c7-vzq2n  0/6 nodes are available: 2 Insufficient cpu...
1m02s   Normal    ScalingReplicaSet  deployment/web            Scaled up replica set web-7d9f6c8b5 to 7
```

Debugging a distroless container without a shell is what **ephemeral containers** are for:

```console
$ kubectl -n prod debug -it web-7d9f6c8b5-9plmz --image=nicolaka/netshoot --target=web -- bash
Defaulting debug container name to debugger-x7k2p.
If you don't see a command prompt, try pressing enter.
netshoot:~# nslookup db.prod.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	db.prod.svc.cluster.local
Address: 10.99.201.14
netshoot:~# curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/readyz
200 0.004131s
```

`--target=web` shares the target container's process namespace, so `ps`, `/proc/<pid>` and `nsenter` all work against the real workload. To debug a node itself:

```console
$ kubectl debug node/worker-01 -it --image=busybox:1.36
Creating debugging pod node-debugger-worker-01-4xp2m with container debugger on node worker-01.
/ # chroot /host journalctl -u kubelet -n 5 --no-pager
Sep 03 12:02:19 worker-01 kubelet[1184]: E0903 12:02:19.774112 1184 pod_workers.go:1301] "Error syncing pod" err="failed to \"StartContainer\" for \"web\" with CrashLoopBackOff: \"back-off 5m0s restarting failed container=web pod=web-7d9f6c8b5-2xk4t_prod(9c1d...)\""
```

Rollout control:

```console
$ kubectl -n prod rollout status deployment/web --timeout=5m
Waiting for deployment "web" rollout to finish: 4 out of 6 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 5 of 6 updated replicas are available...
deployment "web" successfully rolled out

$ kubectl -n prod rollout history deployment/web
deployment.apps/web
REVISION  CHANGE-CAUSE
3         Update image to 2.13.4
4         Update image to 2.14.0

$ kubectl -n prod rollout undo deployment/web --to-revision=3
deployment.apps/web rolled back
```

Custom output is how you turn `kubectl` into a query tool instead of piping to `awk`:

```console
$ kubectl get nodes -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KERNEL:.status.nodeInfo.kernelVersion'
NODE        VERSION   RUNTIME                 KERNEL
cp-1        v1.33.2   containerd://1.7.22     6.8.0-45-generic
cp-2        v1.33.2   containerd://1.7.22     6.8.0-45-generic
cp-3        v1.33.2   containerd://1.7.22     6.8.0-45-generic
worker-01   v1.33.2   containerd://1.7.22     6.8.0-45-generic
worker-02   v1.32.6   containerd://1.7.20     6.8.0-40-generic
worker-03   v1.33.2   containerd://1.7.22     6.8.0-45-generic

$ kubectl get pods -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn
     34 worker-01
     31 worker-03
     28 worker-02
     11 cp-1
```

---

## 12. Building the cluster: kubeadm and HA topologies

### 12.1 HA topology trade-offs

| Topology | etcd placement | Nodes for 1-failure tolerance | Blast radius of a control plane node loss | When |
|---|---|---|---|---|
| Single node (`k3s`, `kind`, `minikube`) | Local | 1 | Total | Dev, CI |
| Stacked etcd | On the control plane nodes | 3 | Loses an API server **and** an etcd member simultaneously | Default; the right answer for most clusters |
| External etcd | Separate etcd cluster | 3 CP + 3 etcd = 6 | Loses only an API server | Large clusters, or etcd must be tuned/backed up independently |

### 12.2 Complete kubeadm configuration

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.0.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: 10.10.0.10
  taints:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.2
clusterName: prod-eu-west
controlPlaneEndpoint: "api.prod.example.com:6443"
imageRepository: registry.k8s.io
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: quota-backend-bytes
        value: "8589934592"
      - name: auto-compaction-mode
        value: periodic
      - name: auto-compaction-retention
        value: "8h"
apiServer:
  certSANs:
    - api.prod.example.com
    - 10.10.0.10
    - 10.10.0.11
    - 10.10.0.12
    - 127.0.0.1
  extraArgs:
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
    - name: enable-admission-plugins
      value: NodeRestriction,ResourceQuota,PodSecurity
    - name: request-timeout
      value: 300s
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
      pathType: File
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
    - name: node-monitor-grace-period
      value: 40s
    - name: terminated-pod-gc-threshold
      value: "500"
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
rotateCertificates: true
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
  strictARP: true
```

```console
$ sudo kubeadm init --config kubeadm-config.yaml --upload-certs
[init] Using Kubernetes version: v1.33.2
[preflight] Running pre-flight checks
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [api.prod.example.com cp-1 kubernetes kubernetes.default ...] and IPs [10.96.0.1 10.10.0.10 10.10.0.11 10.10.0.12 127.0.0.1]
[kubeconfig] Writing "admin.conf" kubeconfig file
[control-plane] Creating static Pod manifest for "kube-apiserver"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[apiclient] All control plane components are healthy after 8.502341 seconds
[upload-certs] Using certificate key:
7a1c9e0b4d3f5a82c6e1b0d94f7a2c38e5b6d1092f4a7c30b8e1d6f5a290c4b3

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes by running:

  kubeadm join api.prod.example.com:6443 --token 9x2k4d.8fj3ka0dm2nvq1zx \
    --discovery-token-ca-cert-hash sha256:e91b0c2a7d4f8e35b16a9c0d7f2e4b8a35c1d9e0f7a2b4c6d8e1f0a3b5c7d9e1 \
    --control-plane --certificate-key 7a1c9e0b4d3f5a82c6e1b0d94f7a2c38e5b6d1092f4a7c30b8e1d6f5a290c4b3

Then you can join any number of worker nodes by running:

  kubeadm join api.prod.example.com:6443 --token 9x2k4d.8fj3ka0dm2nvq1zx \
    --discovery-token-ca-cert-hash sha256:e91b0c2a7d4f8e35b16a9c0d7f2e4b8a35c1d9e0f7a2b4c6d8e1f0a3b5c7d9e1
```

`--discovery-token-ca-cert-hash` is the mutual part of the trust: the token proves the node to the cluster, the hash proves the cluster's CA to the node. Skipping it (`--discovery-token-unsafe-skip-ca-verification`) makes joins vulnerable to a MITM.

### 12.3 Version skew — the rule that governs upgrades

| Component | Allowed skew relative to `kube-apiserver` |
|---|---|
| Other `kube-apiserver` instances (HA) | Within 1 minor version of each other |
| `kube-controller-manager`, `kube-scheduler`, `cloud-controller-manager` | Up to 1 minor version older; **never newer** |
| `kubelet`, `kube-proxy` | Up to 3 minor versions older (since v1.28); **never newer** |
| `kubectl` | One minor newer or older |

Order is fixed and non-negotiable: **etcd → kube-apiserver (all of them) → controller-manager/scheduler → kubelets → kube-proxy → addons**, and one minor version at a time. Never skip a minor release.

```console
$ sudo kubeadm upgrade plan
[upgrade/config] Reading configuration from the cluster...
COMPONENT                 CURRENT   TARGET
kubelet                   6 x v1.33.2   v1.34.1
kube-apiserver            v1.33.2   v1.34.1
kube-controller-manager   v1.33.2   v1.34.1
kube-scheduler            v1.33.2   v1.34.1
kube-proxy                v1.33.2   v1.34.1
CoreDNS                   v1.11.3   v1.11.3
etcd                      3.5.15    3.5.16

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.34.1
```

---

## 13. Verification and failure diagnosis

### 13.1 The health ladder — run this top to bottom, always in this order

```console
# 1. Can I reach the API at all?
$ kubectl cluster-info
Kubernetes control plane is running at https://api.prod.example.com:6443
CoreDNS is running at https://api.prod.example.com:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

# 2. Is the API server itself healthy?
$ kubectl get --raw '/readyz?verbose' | grep -v ' ok$'
readyz check passed

# 3. Is etcd healthy and does it have quorum?  (see §4.2)

# 4. Are the nodes healthy?
$ kubectl get nodes
NAME        STATUS     ROLES           AGE   VERSION
cp-1        Ready      control-plane   61d   v1.33.2
cp-2        Ready      control-plane   61d   v1.33.2
cp-3        Ready      control-plane   61d   v1.33.2
worker-01   Ready      <none>          61d   v1.33.2
worker-02   NotReady   <none>          61d   v1.32.6
worker-03   Ready      <none>          61d   v1.33.2

# 5. Is the control plane's own workload healthy?
$ kubectl -n kube-system get pods
NAME                            READY   STATUS    RESTARTS      AGE
coredns-668d6bf9bc-4mvxs        1/1     Running   0             12d
coredns-668d6bf9bc-tq7lk        1/1     Running   0             12d
etcd-cp-1                       1/1     Running   2 (21d ago)   61d
kube-apiserver-cp-1             1/1     Running   2 (21d ago)   61d
kube-controller-manager-cp-1    1/1     Running   4 (21d ago)   61d
kube-proxy-9dk2m                1/1     Running   0             61d
kube-scheduler-cp-1             1/1     Running   4 (21d ago)   61d

# 6. What is the cluster complaining about, cluster-wide?
$ kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -10

# 7. Is anything under resource pressure?
$ kubectl top nodes
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
cp-1        412m         5%     3120Mi          19%
worker-01   11204m       74%    48210Mi         78%
worker-03   9880m        65%    41022Mi         66%
```

### 13.2 Playbook: node `NotReady`

`NotReady` means the kubelet stopped renewing its Lease or is reporting a bad condition. Six candidate causes, in the order you should eliminate them:

```console
$ kubectl describe node worker-02 | sed -n '/^Conditions:/,/^Addresses:/p'
Conditions:
  Type             Status    LastHeartbeatTime                 Reason                       Message
  ----             ------    -----------------                 ------                       -------
  MemoryPressure   Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  DiskPressure     Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  PIDPressure      Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  Ready            Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
```

`Unknown` = no heartbeat, so the problem is on the node or the network. Go to the node:

```console
$ ssh worker-02 'systemctl is-active kubelet containerd; journalctl -u kubelet -p err -n 5 --no-pager'
active
active
Sep 03 11:40:58 worker-02 kubelet[1184]: E0903 11:40:58.221009 1184 kubelet_node_status.go:544] "Error updating node status, will retry" err="error getting node \"worker-02\": Get \"https://api.prod.example.com:6443/api/v1/nodes/worker-02\": dial tcp 10.10.0.5:6443: i/o timeout"
Sep 03 11:41:07 worker-02 kubelet[1184]: E0903 11:41:07.884213 1184 controller.go:145] "Failed to ensure lease exists, will retry" err="Get \"https://api.prod.example.com:6443/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/worker-02\": dial tcp 10.10.0.5:6443: i/o timeout"
```

| Candidate cause | How to confirm | Fix |
|---|---|---|
| kubelet dead | `systemctl is-active kubelet` | `systemctl start kubelet`; read `journalctl -xeu kubelet` first |
| Container runtime wedged | `crictl info` hangs; `PLEG is not healthy` in log | Restart containerd; check disk |
| Network path to API server broken | `curl -k https://<endpoint>:6443/livez` from the node — as above | Firewall / route / LB health |
| CNI not installed or crashed | `Ready` condition says `network plugin returns error: cni plugin not initialized` | Check the CNI DaemonSet Pod on that node |
| Disk full | `df -h /var/lib/kubelet /var/lib/containerd`; `DiskPressure=True` | Image GC, log rotation, grow the volume |
| Expired kubelet client certificate | `openssl x509 -enddate -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem` | Re-bootstrap; enable `rotateCertificates` |

After `node-monitor-grace-period` (40 s) the node controller marks it `Unknown`; after the Pods' `tolerationSeconds` (default 300 s for `node.kubernetes.io/unreachable:NoExecute`) their Pods are evicted and rescheduled. Total time to recovery ≈ 5.5 minutes by default. That number is a design parameter — know it before someone asks why failover took so long.

### 13.3 Playbook: Pod not running

```
STATUS?
├─ Pending ──────► kubectl describe pod → Events
│                  ├─ FailedScheduling: no resources / taints / affinity / topology → §5.3
│                  ├─ no Events at all → scheduler down? kubectl -n kube-system logs kube-scheduler-cp-1
│                  └─ scheduled but stuck → volume not bound: kubectl get pvc
├─ ContainerCreating ► describe → Events
│                  ├─ FailedCreatePodSandBox / CNI error → CNI DaemonSet on that node
│                  ├─ FailedMount / timeout waiting for attach → CSI driver, node logs
│                  └─ FailedToRetrieveImagePullSecret → imagePullSecrets, SA
├─ ImagePullBackOff ► describe → Events → "manifest unknown" (bad tag) |
│                     "unauthorized" (registry creds) | "no such host" (DNS/proxy on node)
├─ CrashLoopBackOff ► kubectl logs --previous
│                  ├─ app error in logs → application bug / config
│                  ├─ exit code 137 → OOMKilled: kubectl get pod -o jsonpath='{..lastState.terminated}'
│                  ├─ exit code 1 immediately, no logs → bad command/args, missing file
│                  └─ liveness probe killing a slow starter → add startupProbe
├─ Running 0/1 ────► readiness probe failing: kubectl describe → "Readiness probe failed:"
│                    kubectl exec into the Pod and curl the probe path yourself
├─ Terminating ────► stuck finalizer, or preStop/SIGTERM not honoured
│                    kubectl get pod -o jsonpath='{.metadata.finalizers}'
└─ Evicted ────────► node pressure: describe node → DiskPressure/MemoryPressure; §7.3
```

Concrete OOM confirmation, which people routinely guess at instead of checking:

```console
$ kubectl -n prod get pod web-7d9f6c8b5-2xk4t -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
{
  "containerID": "containerd://0a4d2c8e91b73...",
  "exitCode": 137,
  "finishedAt": "2026-09-03T12:01:44Z",
  "reason": "OOMKilled",
  "startedAt": "2026-09-03T11:59:12Z"
}
```

`exitCode: 137` = 128 + SIGKILL(9). `reason: OOMKilled` is authoritative: raise the memory limit or fix the leak. Do not raise CPU.

### 13.4 Playbook: Service has no endpoints

```console
$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS    ENDPOINTS   AGE
api-2f8kq   IPv4          <unset>  <unset>     6m
```

Empty. Exactly three causes, checked in order:

```console
# 1. Does the selector match any Pod?
$ kubectl -n prod get svc api -o jsonpath='{.spec.selector}{"\n"}'
{"app":"api"}
$ kubectl -n prod get pods -l app=api
No resources found in prod namespace.
$ kubectl -n prod get pods --show-labels | grep api
api-5f7d8c9b4-lm2xp   1/1   Running   0   6m   app.kubernetes.io/name=api,pod-template-hash=5f7d8c9b4
```

Label mismatch — the Service selects `app=api`, the Pods carry `app.kubernetes.io/name=api`. If the selector had matched, the next two checks are: are the Pods `Ready` (a not-ready Pod is excluded by design), and does `targetPort` match a real `containerPort` name or number.

Then verify the dataplane end to end from inside the cluster:

```console
$ kubectl -n prod run curl --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
    curl -sS -o /dev/null -w 'code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s\n' http://api.prod.svc.cluster.local/healthz
code=200 dns=0.003114s connect=0.004902s total=0.011776s
pod "curl" deleted
```

### 13.5 Playbook: certificate expiry

Silent until it is catastrophic. kubeadm-issued client/serving certificates last **one year**; the CA lasts ten.

```console
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Nov 12, 2026 09:14 UTC   70d             no
apiserver                  Nov 12, 2026 09:14 UTC   70d             no
apiserver-etcd-client      Nov 12, 2026 09:14 UTC   70d             no
apiserver-kubelet-client   Nov 12, 2026 09:14 UTC   70d             no
controller-manager.conf    Nov 12, 2026 09:14 UTC   70d             no
etcd-healthcheck-client    Nov 12, 2026 09:14 UTC   70d             no
etcd-peer                  Nov 12, 2026 09:14 UTC   70d             no
etcd-server                Nov 12, 2026 09:14 UTC   70d             no
front-proxy-client         Nov 12, 2026 09:14 UTC   70d             no
scheduler.conf             Nov 12, 2026 09:14 UTC   70d             no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME
ca                      Aug 30, 2035 09:14 UTC   3283d
etcd-ca                 Aug 30, 2035 09:14 UTC   3283d
front-proxy-ca          Aug 30, 2035 09:14 UTC   3283d

$ sudo kubeadm certs renew all
certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
[...]
Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
```

`kubeadm upgrade` renews these implicitly, which is why clusters that are upgraded regularly never hit this — and clusters left alone for 13 months die on a Sunday. Kubelet certificates are the exception: `rotateCertificates: true` renews them automatically via the CSR API.

### 13.6 Reading the request path end to end

When the failure is "kubectl behaves strangely", stop guessing and look at the wire:

```console
$ kubectl -v=8 get pods -n prod 2>&1 | head -12
I0903 12:06:07.113455   28417 loader.go:395] Config loaded from file:  /home/sre/.kube/config
I0903 12:06:07.118902   28417 round_trippers.go:463] GET https://api.prod.example.com:6443/api/v1/namespaces/prod/pods?limit=500
I0903 12:06:07.118931   28417 round_trippers.go:469] Request Headers:
I0903 12:06:07.118942   28417 round_trippers.go:473]     Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json
I0903 12:06:07.118951   28417 round_trippers.go:473]     User-Agent: kubectl/v1.33.2 (linux/amd64) kubernetes/0d8f1cb
I0903 12:06:07.118958   28417 round_trippers.go:473]     Authorization: Bearer <masked>
I0903 12:06:07.331204   28417 round_trippers.go:574] Response Status: 403 Forbidden in 212 milliseconds
I0903 12:06:07.331512   28417 request.go:1212] Response Body: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"jane@example.com\" cannot list resource \"pods\" in API group \"\" in the namespace \"prod\"","reason":"Forbidden","code":403}
Error from server (Forbidden): pods is forbidden: User "jane@example.com" cannot list resource "pods" in API group "" in the namespace "prod"
```

Verbosity levels worth remembering: `-v=6` URLs and status, `-v=7` request headers, `-v=8` request/response bodies, `-v=9` bodies untruncated.

---

## 14. Self-assessment: prove you have the objective

Run each of these on a real cluster (`kind`, `minikube` or kubeadm on three VMs). If you cannot do one from memory, re-read the corresponding section.

1. Name every process on a control plane node and the port it listens on; verify with `ss -lntp`.
2. Explain, without notes, the thirteen steps from `kubectl apply` to a running container (§2.4).
3. Delete `/etc/kubernetes/manifests/kube-scheduler.yaml`, create a Pod, observe it stays `Pending`, restore the file, watch it schedule.
4. Take an etcd snapshot, create a Deployment, restore the snapshot, and prove the Deployment is gone.
5. Break a Service by editing its selector; find the empty EndpointSlice; fix it.
6. Set a memory limit of `10Mi` on a Java or Node app; identify `exitCode 137 / OOMKilled` from `lastState`.
7. Switch `kube-proxy` from `iptables` to `ipvs`; verify with `ipvsadm -Ln` that ClusterIPs appear as virtual servers.
8. Drain a node with a PDB in place; observe `Cannot evict pod as it would violate the pod's disruption budget`.
9. From a `netshoot` ephemeral container, resolve a Service FQDN, a headless Service, and an `ExternalName`.
10. Run `kubeadm certs check-expiration` and explain which certificate, if expired, would prevent the API server from talking to etcd.

**Terms and utilities you must be fluent with:** `kubectl` (`get`, `describe`, `logs`, `exec`, `apply`, `delete`, `explain`, `api-resources`, `top`, `drain`, `cordon`, `rollout`, `debug`, `auth can-i`, `config`), `kubeadm`, `kubelet`, `kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `kube-proxy`, `etcd`/`etcdctl`, `crictl`, `containerd`/`CRI-O`, `~/.kube/config`, `/etc/kubernetes/manifests`, Pod, ReplicaSet, Deployment, DaemonSet, StatefulSet, Job, Service, EndpointSlice, Namespace, ConfigMap, Secret, PersistentVolume(Claim), Node, Label, Selector, Annotation, Taint, Toleration.

---

## 15. Referencias

**Exam objectives**
- LPI Exam 701 objectives (DevOps Tools Engineer) — https://www.lpi.org/our-certifications/exam-701-objectives/

**Architecture and components**
- Kubernetes Components — https://kubernetes.io/docs/concepts/overview/components/
- Cluster Architecture — https://kubernetes.io/docs/concepts/architecture/
- Nodes — https://kubernetes.io/docs/concepts/architecture/nodes/
- Communication between Nodes and the Control Plane — https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/
- Controllers — https://kubernetes.io/docs/concepts/architecture/controller/
- Leases — https://kubernetes.io/docs/concepts/architecture/leases/
- Garbage Collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/

**API machinery**
- The Kubernetes API — https://kubernetes.io/docs/concepts/overview/kubernetes-api/
- API Concepts (watch, resourceVersion, pagination) — https://kubernetes.io/docs/reference/using-api/api-concepts/
- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- API Priority and Fairness — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes API health endpoints — https://kubernetes.io/docs/reference/using-api/health-checks/
- Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/

**etcd**
- Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcd documentation — https://etcd.io/docs/
- etcd FAQ (cluster size, quorum) — https://etcd.io/docs/v3.5/faq/

**Scheduling**
- kube-scheduler — https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Scheduling Framework — https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/
- Scheduler Configuration — https://kubernetes.io/docs/reference/scheduling/config/
- Pod Priority and Preemption — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Node-pressure Eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/

**kubelet, runtime and resources**
- kubelet reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- KubeletConfiguration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Container Runtimes — https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Container Runtime Interface (CRI) — https://kubernetes.io/docs/concepts/architecture/cri/
- Reserve Compute Resources for System Daemons — https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/
- Pod QoS Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Debugging Kubernetes nodes with crictl — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- containerd — https://containerd.io/docs/
- CRI-O — https://cri-o.io/

**Networking**
- Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and Service Proxies (proxy modes) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- EndpointSlices — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- DNS for Services and Pods — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Network Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/

**Workloads**
- Pods — https://kubernetes.io/docs/concepts/workloads/pods/
- Deployments — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Disruptions and PodDisruptionBudget — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Horizontal Pod Autoscaling — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

**kubectl and cluster lifecycle**
- kubectl reference — https://kubernetes.io/docs/reference/kubectl/
- Organizing Cluster Access Using kubeconfig Files — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- kubeadm init — https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
- Creating Highly Available Clusters with kubeadm — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- Certificate Management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Version Skew Policy — https://kubernetes.io/releases/version-skew-policy/

**Debugging**
- Troubleshooting Clusters — https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Debug Running Pods (ephemeral containers) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Determine the Reason for Pod Failure — https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/