# 703.2 — Basic Kubernetes Operations

**LPI DevOps Tools Engineer — Exam 701-100, v2.0.0 · Weight 11.67**
*Level: Platform Architect / Senior SRE. Kubernetes reference version: v1.32–v1.33.*

---

## 1. The production problem this objective solves

Before Kubernetes, deploying a service meant answering an operational question imperatively: *"which host, which port, which process supervisor, and who restarts it at 03:00?"* Every answer was a side effect written into a runbook, a Chef recipe, or a person's memory. The failure mode was **configuration drift**: the fleet's actual state slowly diverged from what anyone believed was deployed, and the divergence was only discovered during an incident.

Kubernetes replaces that with a **level-triggered reconciliation model**. You do not tell the cluster *what to do*; you write down *what must be true* — the **desired state** — into a replicated datastore (etcd) through a single authoritative REST API. A set of independent controllers continuously observes the **actual state** and issues the minimum set of actions to close the gap. Nothing is edge-triggered: if a controller misses an event, crashes, and restarts, its next full resync converges anyway.

```
                 ┌──────────────────────────────────────────┐
   kubectl ──►   │  kube-apiserver  (the ONLY writer to etcd)│ ◄── controllers
   (HTTP/REST)   │  authn → authz → admission → validation   │     (watch + act)
                 └────────────────┬─────────────────────────┘
                                  │ persists desired state
                                  ▼
                                 etcd
                                  ▲
        ┌─────────────────────────┴───────────────────────────┐
        │           reconciliation loops (level-triggered)    │
        │  deployment-ctl → replicaset-ctl → scheduler        │
        │  endpointslice-ctl, node-ctl, job-ctl, ...          │
        └─────────────────────────┬───────────────────────────┘
                                  ▼
                  kubelet (per node)  ──►  CRI runtime (containerd/CRI-O)
```

Three architectural consequences drive everything in this objective:

1. **Every object is a REST resource.** `kubectl` is a thin, mostly stateless HTTP client. Anything `kubectl` does, a `curl` against the API server can do. This is why `kubectl --v=8` is the single most useful debugging flag in the ecosystem.
2. **Controllers own their objects through `ownerReferences`.** A Deployment does not create Pods; it creates a ReplicaSet, which creates Pods. Understanding this three-level chain is the difference between fixing a rollout and cargo-culting `kubectl delete pod`.
3. **Identity is by label selector, never by name.** Services do not route to Pod names; they route to whatever matches a selector *right now*. This is what makes rolling updates possible, and it is also the root cause of the most common outage in a junior cluster: a selector that silently matches nothing.

> **Exam scoping note.** LPI 703.2 tests fluent, correct use of `kubectl` and the core object set (Pods, Deployments, ReplicaSets, Services, ConfigMaps, Secrets, namespaces, labels). The production material below goes deeper than the exam requires by design — the failure-diagnosis section in particular is what separates passing the exam from operating a cluster.

---

## 2. The client: how `kubectl` actually works

`kubectl` is not magic. It performs, in order:

1. **Loads a kubeconfig** (`--kubeconfig`, else `$KUBECONFIG` — a colon-separated *list*, merged left-to-right — else `~/.kube/config`).
2. **Resolves the current context** → cluster (server URL + CA), user (credentials or an `exec` credential plugin), and default namespace.
3. **Runs API discovery** against `/api` and `/apis`, caching the result under `~/.kube/cache/discovery/<host>/`. This is how `kubectl get po` knows that `po` → `pods` → `/api/v1/namespaces/<ns>/pods`.
4. **Maps the verb** (`get`, `apply`, `delete`) to an HTTP method and issues the request.

```console
$ kubectl config get-contexts
CURRENT   NAME              CLUSTER      AUTHINFO         NAMESPACE
*         prod-eu-west-1    prod-eu      sre-oidc         platform
          staging           staging      staging-admin    default

$ kubectl config set-context --current --namespace=payments
Context "prod-eu-west-1" modified.

$ kubectl version
Client Version: v1.33.1
Kustomize Version: v5.6.0
Server Version: v1.32.4
```

**Version skew policy:** `kubectl` is supported within one minor version of the API server (`n-1`, `n`, `n+1`). A v1.33 client against a v1.32 server is supported; a v1.35 client is not, and will silently omit fields the server does not understand.

### 2.1 Discovery and self-documentation

These two commands remove the need to memorise APIs — learn them before learning any manifest.

```console
$ kubectl api-resources --namespaced=true -o wide | head -8
NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND          VERBS
configmaps    cm           v1           true         ConfigMap     create,delete,get,list,patch,update,watch
endpoints     ep           v1           true         Endpoints     create,delete,get,list,patch,update,watch
events        ev           v1           true         Event         create,delete,get,list,patch,update,watch
pods          po           v1           true         Pod           create,delete,get,list,patch,update,watch
secrets                    v1           true         Secret        create,delete,get,list,patch,update,watch
services      svc          v1           true         Service       create,delete,get,list,patch,update,watch
deployments   deploy       apps/v1      true         Deployment    create,delete,get,list,patch,update,watch

$ kubectl explain deployment.spec.strategy.rollingUpdate.maxSurge
KIND:       Deployment
VERSION:    apps/v1
FIELD: maxSurge <IntOrString>
DESCRIPTION:
    The maximum number of pods that can be scheduled above the desired number of
    pods. Value can be an absolute number (ex: 5) or a percentage of desired pods
    (ex: 10%). This can not be 0 if MaxUnavailable is 0. [...]
```

`kubectl explain --recursive deployment.spec` prints the entire subtree — the offline schema reference.

### 2.2 Imperative vs declarative vs server-side apply

This is a real architectural decision, not a style preference.

| Mode | Command | Conflict handling | Audit trail | Production verdict |
|---|---|---|---|---|
| Imperative | `kubectl create/run/expose/scale/set image` | Last writer wins; `create` fails if object exists | None outside shell history | **Ad-hoc + exam speed only.** Never in CI. |
| Imperative replace | `kubectl replace -f` | Full object overwrite; drops fields you omitted | Manifest in git | Dangerous: silently deletes fields other controllers set. |
| Declarative CSA | `kubectl apply -f` | 3-way merge vs `last-applied-configuration` annotation | Manifest in git | Default for years; annotation bloats objects and breaks with multiple writers. |
| **Declarative SSA** | `kubectl apply --server-side` | Per-field ownership tracked in `metadata.managedFields`; conflicts are **errors** | Manifest in git + field managers | **Recommended.** Makes "who changed this field" answerable. |

```console
$ kubectl apply --server-side --field-manager=gitops-ci -f deploy/api.yaml
deployment.apps/payments-api serverside-applied

$ kubectl apply --server-side --field-manager=sre-hotfix -f deploy/api-scaled.yaml
error: Apply failed with 1 conflict: conflict with "gitops-ci" using apps/v1:
- .spec.replicas
Please review the fields above--they currently have other managers. Helper commands:
* You may co-own fields by updating your manifest to match the existing value...
* You may want to use `--force-conflicts` to overwrite the currently managed fields...
```

That error is a **feature**: it caught a human about to overwrite a GitOps-managed field. Under client-side apply the same operation would have succeeded silently and been reverted at the next reconcile, producing a "flapping replica count" incident nobody could explain.

**Non-negotiable pre-flight pair** — put both in CI before any cluster mutation:

```console
$ kubectl apply -f deploy/ --dry-run=server
deployment.apps/payments-api configured (server dry run)
service/payments-api unchanged (server dry run)

$ kubectl diff -f deploy/api.yaml
diff -u -N /tmp/LIVE-3910/apps.v1.Deployment.payments.payments-api /tmp/MERGED-2277/...
--- LIVE
+++ MERGED
@@ -31,7 +31,7 @@
       containers:
       - name: api
-        image: registry.internal/payments-api:1.14.2
+        image: registry.internal/payments-api:1.15.0
```

`--dry-run=server` runs **full admission** (webhooks, quota, validation) without persisting; `--dry-run=client` only renders locally and catches nothing but syntax. `kubectl diff` exits `1` when a difference exists — usable directly as a drift gate.

---

## 3. Namespaces, labels, selectors, annotations

### 3.1 Namespaces: a scope, not a security boundary

A namespace scopes **names**, **quota** (`ResourceQuota`, `LimitRange`), **RBAC RoleBindings**, and the DNS search path. It does **not** by itself isolate network traffic (needs `NetworkPolicy`), does not isolate the node kernel, and does not partition cluster-scoped objects (Nodes, PersistentVolumes, StorageClasses, ClusterRoles, CRDs).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    kubernetes.io/metadata.name: payments      # set automatically by the apiserver
    app.kubernetes.io/part-of: commerce
    environment: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.32
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.cpu: "80"
    limits.memory: 160Gi
    pods: "150"
    count/deployments.apps: "40"
    persistentvolumeclaims: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: payments-defaults
  namespace: payments
spec:
  limits:
    - type: Container
      default:                 # applied as limits when unspecified
        cpu: 500m
        memory: 512Mi
      defaultRequest:          # applied as requests when unspecified
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 16Gi
      min:
        cpu: 10m
        memory: 32Mi
```

The `LimitRange` is what makes a `ResourceQuota` on `requests.cpu` survivable: once a quota on a compute resource exists, **every** Pod in that namespace must declare that resource, and a `LimitRange` supplies the default instead of rejecting the Pod.

### 3.2 Labels vs annotations

| | Labels | Annotations |
|---|---|---|
| Purpose | **Identifying** metadata — selection, grouping | **Non-identifying** metadata — tooling payloads |
| Queryable | Yes: `-l`, selectors, `--field-selector` complement | No selector support |
| Size limit | Key ≤ 63 chars (+ 253-char prefix), value ≤ 63 chars, restricted charset | Up to 256 KB total, arbitrary bytes |
| Typical use | `app.kubernetes.io/name`, `tier`, `environment` | `kubernetes.io/change-cause`, checksums, ingress config, `kubectl.kubernetes.io/last-applied-configuration` |
| Index cost | Watched and indexed by controllers | Ignored by selectors |

Adopt the [recommended label set](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/) — it is what makes cross-tool queries (`kubectl`, Prometheus, cost reporting) join correctly:

```yaml
labels:
  app.kubernetes.io/name: payments-api
  app.kubernetes.io/instance: payments-api-prod
  app.kubernetes.io/version: "1.15.0"
  app.kubernetes.io/component: api
  app.kubernetes.io/part-of: commerce
  app.kubernetes.io/managed-by: argocd
```

Selector grammar, both forms:

```console
# equality-based
$ kubectl get pods -l app.kubernetes.io/name=payments-api,environment=production

# set-based: in, notin, exists (key), not-exists (!key)
$ kubectl get pods -l 'environment in (production,canary),!debug' --show-labels
NAME                            READY   STATUS    RESTARTS   AGE   LABELS
payments-api-7d9f4c8b5c-2kq7z   1/1     Running   0          12m   app.kubernetes.io/name=payments-api,environment=production,pod-template-hash=7d9f4c8b5c
payments-api-7d9f4c8b5c-9wxvn   1/1     Running   0          12m   app.kubernetes.io/name=payments-api,environment=production,pod-template-hash=7d9f4c8b5c

# field selectors are a different mechanism — server-side, limited field set
$ kubectl get pods --field-selector status.phase=Running,spec.nodeName=worker-03
```

**Architectural trap:** `spec.selector.matchLabels` on a Deployment/StatefulSet/DaemonSet is **immutable**. Changing it requires deleting and recreating the controller. Choose selectors that encode *identity only* (`app.kubernetes.io/name` + `instance`) and never include volatile values such as `version` — otherwise every release becomes a delete/recreate with downtime.

---

## 4. Workload controllers: choosing the right one

| Controller | Identity | Ordering | Storage | Scaling | Use when |
|---|---|---|---|---|---|
| **Pod** (bare) | Ephemeral, no owner | — | Any | None; never rescheduled if node dies | Debugging only. Never in production. |
| **ReplicaSet** | Random suffix | None | Shared/ephemeral | Manual | Never directly — a Deployment implementation detail. |
| **Deployment** | Random suffix, disposable | None | Ephemeral or shared RWX | Manual + HPA | Stateless services. **The default.** |
| **StatefulSet** | Stable ordinal `web-0..n-1`, stable DNS | Ordered create/delete/update (configurable) | Per-replica PVC via `volumeClaimTemplates` | Manual + HPA (careful) | Databases, quorum systems, anything needing stable identity. |
| **DaemonSet** | One per matching node | Per-node rolling | `hostPath`/ephemeral | Implicit (node count) | Log shippers, CNI, node exporters, CSI node plugins. |
| **Job** | Random suffix | Optional `Indexed` | Ephemeral | `parallelism`/`completions` | Batch to completion: migrations, ETL. |
| **CronJob** | Creates Jobs | Per schedule | Ephemeral | Via Job | Scheduled batch. Watch `concurrencyPolicy`. |

The Deployment ownership chain, visible in the object graph:

```console
$ kubectl get deploy,rs,pod -l app.kubernetes.io/name=payments-api
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/payments-api   4/4     4            4           9d

NAME                                      DESIRED   CURRENT   READY   AGE
replicaset.apps/payments-api-7d9f4c8b5c   4         4         4       12m
replicaset.apps/payments-api-6c4b7f9d84   0         0         0       9d

NAME                                READY   STATUS    RESTARTS   AGE
pod/payments-api-7d9f4c8b5c-2kq7z   1/1     Running   0          12m
pod/payments-api-7d9f4c8b5c-9wxvn   1/1     Running   0          12m
pod/payments-api-7d9f4c8b5c-hj4tp   1/1     Running   0          11m
pod/payments-api-7d9f4c8b5c-vn8rq   1/1     Running   0          11m

$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z -o jsonpath='{.metadata.ownerReferences}' | jq
[
  {
    "apiVersion": "apps/v1",
    "kind": "ReplicaSet",
    "name": "payments-api-7d9f4c8b5c",
    "uid": "0a4f...c31",
    "controller": true,
    "blockOwnerDeletion": true
  }
]
```

The `7d9f4c8b5c` suffix is the **pod-template-hash**: a hash of the Pod template, added to both the ReplicaSet name and the Pod labels. It is how a Deployment tells "old" replicas from "new" ones during a rollout, and it is why the old ReplicaSet is kept at 0 replicas — that object *is* the rollback target.

**Cascading deletion** is governed by `ownerReferences` + finalizers:

```console
$ kubectl delete deploy payments-api --cascade=background   # default: GC deletes children async
$ kubectl delete deploy payments-api --cascade=foreground    # blocks until children are gone
$ kubectl delete deploy payments-api --cascade=orphan        # keeps ReplicaSet+Pods running
```

`--cascade=orphan` is the emergency lever for "detach the workload from a broken controller without dropping traffic".

---

## 5. The Pod: a complete production manifest

This is the reference Pod spec every other manifest in this material derives from. Nothing is elided.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payments-api-reference
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  # --- scheduling -----------------------------------------------------------
  serviceAccountName: payments-api
  automountServiceAccountToken: false        # explicit: this Pod does not call the API
  nodeSelector:
    kubernetes.io/os: linux
    node.kubernetes.io/instance-type: m6i.2xlarge
  tolerations:
    - key: workload
      operator: Equal
      value: payments
      effect: NoSchedule
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: payments-api
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: payments-api

  # --- security -------------------------------------------------------------
  securityContext:                            # pod-level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault

  # --- lifecycle ------------------------------------------------------------
  restartPolicy: Always                       # Always | OnFailure | Never
  terminationGracePeriodSeconds: 45
  dnsPolicy: ClusterFirst

  # --- init containers ------------------------------------------------------
  initContainers:
    - name: wait-for-db
      image: registry.internal/base/postgres-client:16.3
      command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          until pg_isready -h "$DB_HOST" -p 5432 -t 3; do
            echo "waiting for ${DB_HOST}:5432 ..." >&2
            sleep 2
          done
          echo "database reachable"
      env:
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: payments-api-config
              key: DB_HOST
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

    # native sidecar: an initContainer with restartPolicy Always starts before the
    # app containers, keeps running alongside them, and is terminated last.
    # (beta and on by default since v1.29, GA in v1.33)
    - name: log-forwarder
      image: registry.internal/observability/fluent-bit:3.1.6
      restartPolicy: Always
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
        - name: fluentbit-config
          mountPath: /fluent-bit/etc
          readOnly: true
      resources:
        requests: { cpu: 50m,  memory: 64Mi }
        limits:   { cpu: 200m, memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

  # --- application container ------------------------------------------------
  containers:
    - name: api
      image: registry.internal/payments-api:1.15.0
      imagePullPolicy: IfNotPresent
      ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        - name: metrics
          containerPort: 9090
          protocol: TCP

      args: ["--config=/etc/payments/config.yaml", "--log-format=json"]

      env:
        - name: POD_NAME
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef: { fieldPath: metadata.namespace }
        - name: NODE_NAME
          valueFrom:
            fieldRef: { fieldPath: spec.nodeName }
        - name: POD_IP
          valueFrom:
            fieldRef: { fieldPath: status.podIP }
        - name: MEM_LIMIT_BYTES
          valueFrom:
            resourceFieldRef:
              containerName: api
              resource: limits.memory
              divisor: "1"
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: payments-db
              key: password
      envFrom:
        - configMapRef:
            name: payments-api-config

      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
          ephemeral-storage: "1Gi"
        limits:
          cpu: "2"
          memory: "512Mi"          # == request → predictable OOM boundary
          ephemeral-storage: "2Gi"

      startupProbe:                 # protects a slow JVM/dotnet start from liveness
        httpGet: { path: /healthz/startup, port: http }
        periodSeconds: 5
        failureThreshold: 60        # up to 5 min to become live
      livenessProbe:                # "is the process wedged?" → restart
        httpGet: { path: /healthz/live, port: http }
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      readinessProbe:               # "should it receive traffic?" → endpoint churn
        httpGet: { path: /healthz/ready, port: http }
        periodSeconds: 5
        timeoutSeconds: 2
        successThreshold: 1
        failureThreshold: 2

      lifecycle:
        preStop:
          exec:
            # Bridge the async gap between endpoint removal and SIGTERM.
            command: ["/bin/sh", "-c", "sleep 10"]

      volumeMounts:
        - name: config
          mountPath: /etc/payments
          readOnly: true
        - name: tls
          mountPath: /etc/payments/tls
          readOnly: true
        - name: applogs
          mountPath: /var/log/app
        - name: tmp
          mountPath: /tmp

      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }

  # --- volumes --------------------------------------------------------------
  volumes:
    - name: config
      configMap:
        name: payments-api-files
        defaultMode: 0444
    - name: tls
      secret:
        secretName: payments-api-tls
        defaultMode: 0400
    - name: fluentbit-config
      configMap:
        name: fluent-bit-config
    - name: applogs
      emptyDir:
        sizeLimit: 512Mi
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
```

### 5.1 Lifecycle: phases vs conditions vs container states

Three orthogonal state machines that people routinely conflate.

| Layer | Values | Meaning |
|---|---|---|
| `status.phase` | `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown` | Coarse, **never** a health signal. A `CrashLoopBackOff` Pod is phase `Running`. |
| `status.conditions` | `PodScheduled`, `PodReadyToStartContainers`, `Initialized`, `ContainersReady`, `Ready` | The real progression. `Ready=False` is what removes it from Service endpoints. |
| `containerStatuses[].state` | `waiting{reason}`, `running{startedAt}`, `terminated{exitCode,reason}` | Per-container truth: `ImagePullBackOff`, `CrashLoopBackOff`, `OOMKilled` live here. |

```console
$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z \
    -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"\t"}{.reason}{"\n"}{end}'
PodReadyToStartContainers=True
Initialized=True
Ready=True
ContainersReady=True
PodScheduled=True
```

### 5.2 Probes — the semantic table people get wrong

| Probe | Failure action | Correct implementation | Classic mistake |
|---|---|---|---|
| `startupProbe` | Disables the other two until it passes once | Cheap "process is up" check with a generous `failureThreshold` | Omitting it, then setting a huge `initialDelaySeconds` on liveness — which also delays restarts forever |
| `livenessProbe` | **Kills the container** (restart, backoff) | Purely local: event loop responsive, no deadlock. **No dependency checks.** | Checking the database → a DB blip restarts every replica simultaneously and turns a degradation into an outage |
| `readinessProbe` | Removes the Pod from **all** Service endpoints | May check hard dependencies; must flip back to healthy | Making it identical to liveness, so the Pod never sheds traffic gracefully |

`terminationGracePeriodSeconds` can be overridden per-probe (`livenessProbe.terminationGracePeriodSeconds`) so a wedged process is SIGKILLed fast without shortening the graceful shutdown of a healthy one.

### 5.3 QoS classes and eviction order

QoS is **derived**, never declared:

| Class | Condition | Behaviour under node pressure | `oom_score_adj` |
|---|---|---|---|
| `Guaranteed` | Every container sets cpu **and** memory, with `requests == limits` | Evicted last | −997 |
| `Burstable` | At least one request set, but not fully equal to limits | Evicted after BestEffort, worst-offender-over-requests first | 2–999 (scaled) |
| `BestEffort` | No requests or limits anywhere | **Evicted first** | 1000 |

```console
$ kubectl get pods -o custom-columns=\
NAME:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName
NAME                            QOS         NODE
payments-api-7d9f4c8b5c-2kq7z   Burstable   worker-03
payments-worker-5f7c9d4b6-x8k2p Guaranteed  worker-01
debug-shell                     BestEffort  worker-05
```

**Production rule:** always set `memory` request == limit (memory is incompressible — exceeding the limit is an instant OOM kill, so "bursting" is a fiction), and set a `cpu` request but consider omitting the `cpu` limit for latency-sensitive services, because CFS quota throttling produces tail-latency spikes even when the node is idle. That deliberately yields `Burstable`, and that is the correct trade-off for a request-serving API.

---

## 6. Deployments and rollouts

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  annotations:
    kubernetes.io/change-cause: "release 1.15.0 — idempotent refund handler (JIRA PAY-4192)"
spec:
  replicas: 4
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  minReadySeconds: 15
  selector:
    matchLabels:                       # IMMUTABLE — identity only
      app.kubernetes.io/name: payments-api
      app.kubernetes.io/component: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                      # absolute values beat percentages at low replica counts
      maxUnavailable: 0                # zero-downtime: never dip below `replicas`
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-api
        app.kubernetes.io/component: api
        app.kubernetes.io/version: "1.15.0"
      annotations:
        # forces a rollout when the ConfigMap content changes
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543a1e2c3d4b5f6a7b8c9d0e1f2a3b4c5d6"
    spec:
      serviceAccountName: payments-api
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: payments-api
      containers:
        - name: api
          image: registry.internal/payments-api:1.15.0
          ports:
            - { name: http, containerPort: 8080 }
            - { name: metrics, containerPort: 9090 }
          envFrom:
            - configMapRef: { name: payments-api-config }
            - secretRef:    { name: payments-api-secrets }
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits:   { memory: 512Mi }
          startupProbe:
            httpGet: { path: /healthz/startup, port: http }
            periodSeconds: 5
            failureThreshold: 60
          livenessProbe:
            httpGet: { path: /healthz/live, port: http }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /healthz/ready, port: http }
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              exec: { command: ["/bin/sh", "-c", "sleep 10"] }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 64Mi }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: payments
spec:
  minAvailable: 3                      # or maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-api
      app.kubernetes.io/component: api
```

### 6.1 Rollout strategy trade-offs

| Strategy | Downtime | Extra capacity | Version overlap | Rollback speed | When |
|---|---|---|---|---|---|
| `Recreate` | Full outage | 0 | None | Slow (full restart) | Singleton with RWO volume; schema-incompatible upgrade |
| `RollingUpdate` `maxUnavailable:0, maxSurge:1` | None | +1 Pod | Yes — N and N+1 serve simultaneously | Fast (old RS retained) | **Default for stateless HTTP** |
| `RollingUpdate` `maxUnavailable:1, maxSurge:0` | Capacity dip | 0 | Yes | Fast | Cluster is capacity-constrained / quota-bound |
| Blue-green (two Deployments + Service selector flip) | None | 2× | No | Instant (flip back) | Incompatible wire protocol change |
| Canary (second Deployment, shared Service selector) | None | +k Pods | Yes | Fast | Risky change needing real traffic validation |

The consequence of *any* rolling strategy is **version overlap**: your API and your database schema must be backward compatible for the duration of the rollout. This is the expand/contract migration pattern, and it is a design constraint imposed by the orchestrator, not an optional practice.

### 6.2 Driving and observing a rollout

```console
$ kubectl set image deployment/payments-api api=registry.internal/payments-api:1.15.0
deployment.apps/payments-api image updated

$ kubectl annotate deployment/payments-api \
    kubernetes.io/change-cause="release 1.15.0 — idempotent refund handler (PAY-4192)" --overwrite
deployment.apps/payments-api annotated

$ kubectl rollout status deployment/payments-api --timeout=300s
Waiting for deployment "payments-api" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "payments-api" rollout to finish: 1 old replicas are pending termination...
deployment "payments-api" successfully rolled out

$ echo $?
0
```

`kubectl rollout status` exits non-zero on timeout or on a failed `Progressing` condition — **that is your CI deployment gate**. Never `kubectl apply && exit 0`.

```console
$ kubectl rollout history deployment/payments-api
deployment.apps/payments-api
REVISION  CHANGE-CAUSE
7         release 1.14.2 — connection pool tuning (PAY-4088)
8         release 1.15.0 — idempotent refund handler (PAY-4192)

$ kubectl rollout history deployment/payments-api --revision=7 | head -12
deployment.apps/payments-api with revision #7
Pod Template:
  Labels:  app.kubernetes.io/component=api
           app.kubernetes.io/name=payments-api
           app.kubernetes.io/version=1.14.2
           pod-template-hash=6c4b7f9d84
  Containers:
   api:
    Image:  registry.internal/payments-api:1.14.2
    Ports:  8080/TCP, 9090/TCP

$ kubectl rollout undo deployment/payments-api --to-revision=7
deployment.apps/payments-api rolled back
```

Emergency brake for a rollout going wrong mid-flight:

```console
$ kubectl rollout pause deployment/payments-api
deployment.apps/payments-api paused
# ... investigate; the partially-updated state is frozen, both versions serving ...
$ kubectl rollout resume deployment/payments-api    # or: kubectl rollout undo ...
deployment.apps/payments-api resumed
```

A stalled rollout surfaces as a condition, not a log line:

```console
$ kubectl get deploy payments-api -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
Available=False (MinimumReplicasUnavailable)
Progressing=False (ProgressDeadlineExceeded)
```

`ProgressDeadlineExceeded` means: `progressDeadlineSeconds` elapsed without a single new replica becoming available. It does **not** roll back automatically — Kubernetes has no automatic rollback. Your pipeline must call `kubectl rollout undo`.

---

## 7. Services, endpoints and DNS

A Service is a **stable virtual identity** in front of a churning set of Pods. The Service controller allocates a `clusterIP` from the service CIDR; the EndpointSlice controller watches Pods matching `spec.selector` and publishes the **ready** ones; `kube-proxy` on every node programs the dataplane to DNAT the ClusterIP to a real Pod IP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
  labels:
    app.kubernetes.io/name: payments-api
spec:
  type: ClusterIP
  selector:                             # matches Pod labels, NOT the Deployment
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  ports:
    - name: http
      port: 80                          # the ClusterIP port
      targetPort: http                  # named container port — survives port renumbering
      protocol: TCP
    - name: metrics
      port: 9090
      targetPort: metrics
      protocol: TCP
  sessionAffinity: None
  internalTrafficPolicy: Cluster
---
# Headless Service: no ClusterIP, DNS returns one A record per ready Pod.
# Required by StatefulSets and by client-side load balancing (gRPC).
apiVersion: v1
kind: Service
metadata:
  name: payments-api-headless
  namespace: payments
spec:
  clusterIP: None
  publishNotReadyAddresses: false
  selector:
    app.kubernetes.io/name: payments-api
    app.kubernetes.io/component: api
  ports:
    - { name: http, port: 8080, targetPort: http }
```

### 7.1 Service types

| Type | Reachable from | Allocates | Cost / caveats |
|---|---|---|---|
| `ClusterIP` | Inside the cluster only | Virtual IP | Default; invisible outside. |
| `NodePort` | `<AnyNodeIP>:30000–32767` | ClusterIP + a port on **every** node | Port sprawl, no TLS termination, client must know node IPs. Fine for on-prem behind an external LB. |
| `LoadBalancer` | Public/private LB VIP | ClusterIP + NodePort + cloud LB | One cloud LB **per Service** — the cost driver that pushes teams to Ingress/Gateway. |
| `ExternalName` | DNS CNAME only | Nothing | No proxying, no port remapping; used to alias external hosts. |
| Headless (`clusterIP: None`) | In-cluster DNS | Nothing | Client does its own load balancing; mandatory for StatefulSet stable identity. |

`externalTrafficPolicy` trade-off for `NodePort`/`LoadBalancer`:

| Value | Client source IP | Extra hop | Balance |
|---|---|---|---|
| `Cluster` (default) | **Lost** (SNAT) | Yes — may hop to another node | Even |
| `Local` | Preserved | No | Uneven — proportional to Pods per node; nodes with 0 Pods fail the LB health check |

### 7.2 kube-proxy dataplane modes

| Mode | Rule complexity | Update cost at scale | Notes |
|---|---|---|---|
| `iptables` | O(n) chains, sequential match | Full-table rewrite; seconds of latency at ~5k Services | Long-standing default. |
| `ipvs` | Hash table, O(1) match | Incremental | Requires kernel `ip_vs` modules; several scheduling algorithms (`rr`, `lc`, `dh`). |
| `nftables` | Verdict maps, O(1) | Incremental, atomic | Modern replacement for the iptables backend; GA in v1.33. |

None of this changes your manifests — that is the point of the abstraction. It changes your *incident response*, because "the Service exists but traffic does not flow" is diagnosed differently in each mode.

### 7.3 EndpointSlices — where truth lives

```console
$ kubectl get endpointslices -l kubernetes.io/service-name=payments-api
NAME                 ADDRESSTYPE   PORTS       ENDPOINTS                                   AGE
payments-api-x4m9t   IPv4          8080,9090   10.244.2.17,10.244.1.9,10.244.3.22 + 1 more 9d

$ kubectl get endpointslice payments-api-x4m9t -o yaml | sed -n '1,30p'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
addressType: IPv4
endpoints:
- addresses:
  - 10.244.2.17
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: worker-03
  targetRef:
    kind: Pod
    name: payments-api-7d9f4c8b5c-2kq7z
    namespace: payments
  zone: eu-west-1a
```

`ENDPOINTS: <none>` is the single most common "the Service is broken" root cause, and it always means one of exactly three things: (a) the selector matches no Pods, (b) matching Pods are not `Ready`, (c) `targetPort` names no port the container declares.

### 7.4 DNS

`CoreDNS` serves `<service>.<namespace>.svc.cluster.local`. Inside a Pod:

```console
$ kubectl run dnstest --rm -it --image=registry.internal/base/netshoot:0.13 --restart=Never -- bash
If you don't see a command prompt, try pressing enter.

dnstest:~# cat /etc/resolv.conf
search payments.svc.cluster.local svc.cluster.local cluster.local eu-west-1.compute.internal
nameserver 10.96.0.10
options ndots:5

dnstest:~# dig +short payments-api.payments.svc.cluster.local
10.96.211.44

dnstest:~# dig +short payments-api-headless.payments.svc.cluster.local
10.244.1.9
10.244.2.17
10.244.3.22
10.244.0.31

dnstest:~# curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://payments-api/healthz/ready
200 0.004221s
```

`options ndots:5` means any name with fewer than 5 dots is first tried against every entry of `search` — so `api.example.com` (2 dots) generates four failed lookups before the correct one. On latency-sensitive workloads, either use a fully-qualified name with a trailing dot (`api.example.com.`) or lower `ndots` via `spec.dnsConfig`.

---

## 8. Configuration: ConfigMaps and Secrets

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-config
  namespace: payments
immutable: false
data:                                   # env-style keys, consumed via envFrom
  LOG_LEVEL: "info"
  DB_HOST: "postgres-primary.data.svc.cluster.local"
  DB_PORT: "5432"
  DB_MAX_CONNS: "40"
  FEATURE_IDEMPOTENT_REFUNDS: "true"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-api-files
  namespace: payments
immutable: true                         # rev-locked; a change means a new object name
data:
  config.yaml: |
    server:
      addr: ":8080"
      readTimeout: 5s
      writeTimeout: 10s
      shutdownGracePeriod: 30s
    telemetry:
      metricsAddr: ":9090"
      tracing:
        enabled: true
        sampleRatio: 0.05
    refunds:
      idempotencyWindow: 24h
      maxRetries: 3
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-api-secrets
  namespace: payments
type: Opaque
stringData:                             # write-only convenience: server stores base64 in .data
  DB_PASSWORD: "PLACEHOLDER_INJECTED_BY_EXTERNAL_SECRETS"
  HMAC_SIGNING_KEY: "PLACEHOLDER_INJECTED_BY_EXTERNAL_SECRETS"
---
apiVersion: v1
kind: Secret
metadata:
  name: payments-api-tls
  namespace: payments
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==   # truncated for brevity
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCg==
```

### 8.1 Injection mechanisms compared

| Mechanism | Live update? | Visible in `/proc/<pid>/environ`? | `subPath` safe? | Use for |
|---|---|---|---|---|
| `env.valueFrom.configMapKeyRef` | **No** — fixed at container start | Yes | n/a | Small scalars where a restart-on-change is acceptable |
| `envFrom.configMapRef` | **No** | Yes | n/a | Bulk 12-factor config |
| `env.valueFrom.secretKeyRef` | **No** | **Yes — leaks into crash dumps and `kubectl describe` of the spec** | n/a | Avoid for high-value secrets |
| ConfigMap **volume** | Yes (kubelet sync, ~60 s + cache TTL) | No | **No** — `subPath` mounts never update | Config files with SIGHUP reload |
| Secret **volume** | Yes | No | No | **Preferred for secrets**: file-mode 0400, tmpfs-backed |
| Projected volume | Yes | No | No | Combining CM + Secret + downward API + SA token in one directory |

**The `subPath` trap** is worth stating explicitly because it produces a silent, permanent staleness: mounting `configMap` with `subPath: config.yaml` to place a single file into an existing directory bypasses the kubelet's atomic symlink swap, so the file is written once at container start and **never updated again**. Mount the whole volume into a dedicated directory instead.

**The Secret trap:** `data` is base64 — an *encoding*, not encryption. Anyone with `get secrets` in the namespace has the plaintext, and by default etcd stores it in the clear. Production requires (a) `EncryptionConfiguration` with a KMS provider on the API server, (b) RBAC that does not grant `get`/`list` on `secrets` broadly, and (c) an external secret store (Vault, cloud SM) syncing in.

### 8.2 Making config changes actually roll out

Since env-injected config is fixed at container start, changing a ConfigMap does **nothing** to running Pods. Two correct patterns:

```console
# Pattern A — checksum annotation in the Pod template (works with any tooling)
$ CS=$(kubectl get cm payments-api-config -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1)
$ kubectl patch deployment payments-api --type=merge -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$CS\"}}}}}"
deployment.apps/payments-api patched

# Pattern B — immutable, content-addressed ConfigMap names (kustomize configMapGenerator)
#   payments-api-files-7t2gd94hbf  →  a new name is a new Pod template is a new rollout
```

The blunt instrument, when neither is wired up:

```console
$ kubectl rollout restart deployment/payments-api
deployment.apps/payments-api restarted
```

This works by stamping `kubectl.kubernetes.io/restartedAt` into the Pod template — a normal rolling update, PDB-respecting, not a `delete pod` storm.

---

## 9. Batch and stateful workloads

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: payments-schema-migrate-1150
  namespace: payments
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 3
  activeDeadlineSeconds: 900
  ttlSecondsAfterFinished: 86400        # GC the Job object after 24 h
  podFailurePolicy:
    rules:
      - action: FailJob                 # a config error must not burn all retries
        onExitCodes:
          containerName: migrate
          operator: In
          values: [78]                  # EX_CONFIG
      - action: Ignore                  # preemption is not the workload's fault
        onPodConditions:
          - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never              # Never or OnFailure — Always is rejected
      serviceAccountName: payments-migrator
      containers:
        - name: migrate
          image: registry.internal/payments-migrate:1.15.0
          args: ["up", "--dsn=$(DSN)"]
          env:
            - name: DSN
              valueFrom:
                secretKeyRef: { name: payments-db, key: dsn }
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { memory: 256Mi }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: payments-reconcile
  namespace: payments
spec:
  schedule: "17 2 * * *"
  timeZone: "Europe/Madrid"             # stable since v1.27 — do not rely on node TZ
  concurrencyPolicy: Forbid             # Allow | Forbid | Replace
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  suspend: false
  jobTemplate:
    spec:
      backoffLimit: 2
      ttlSecondsAfterFinished: 604800
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: reconcile
              image: registry.internal/payments-reconcile:1.15.0
              resources:
                requests: { cpu: 500m, memory: 1Gi }
                limits:   { memory: 1Gi }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: payments-ledger
  namespace: payments
spec:
  serviceName: payments-ledger          # MUST be a headless Service
  replicas: 3
  podManagementPolicy: OrderedReady     # OrderedReady | Parallel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0                      # >0 → canary the highest ordinals only
  selector:
    matchLabels:
      app.kubernetes.io/name: payments-ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payments-ledger
    spec:
      terminationGracePeriodSeconds: 120
      securityContext:
        runAsNonRoot: true
        runAsUser: 10002
        fsGroup: 10002
      containers:
        - name: ledger
          image: registry.internal/payments-ledger:3.2.1
          ports:
            - { name: peer, containerPort: 7000 }
            - { name: client, containerPort: 7001 }
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: PEERS
              value: "payments-ledger-0.payments-ledger,payments-ledger-1.payments-ledger,payments-ledger-2.payments-ledger"
          readinessProbe:
            tcpSocket: { port: client }
            periodSeconds: 5
          resources:
            requests: { cpu: "2", memory: 8Gi }
            limits:   { cpu: "4", memory: 8Gi }
          volumeMounts:
            - { name: data, mountPath: /var/lib/ledger }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-nvme
        resources:
          requests:
            storage: 200Gi
---
apiVersion: v1
kind: Service
metadata:
  name: payments-ledger
  namespace: payments
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: payments-ledger
  ports:
    - { name: peer, port: 7000 }
    - { name: client, port: 7001 }
```

**StatefulSet operational facts that bite:** PVCs created from `volumeClaimTemplates` are **not** deleted when the StatefulSet is deleted (unless `persistentVolumeClaimRetentionPolicy` says otherwise) — this is deliberate data protection, and it is also why a "clean redeploy" silently reattaches old data. Scaling down does not delete PVCs either; scaling back up reuses them.

```console
$ kubectl get pods -l app.kubernetes.io/name=payments-ledger -o wide
NAME                 READY   STATUS    RESTARTS   AGE   IP            NODE
payments-ledger-0    1/1     Running   0          6d    10.244.1.44   worker-01
payments-ledger-1    1/1     Running   0          6d    10.244.2.51   worker-03
payments-ledger-2    1/1     Running   0          6d    10.244.3.19   worker-05

$ kubectl get pvc -l app.kubernetes.io/name=payments-ledger
NAME                      STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-payments-ledger-0    Bound    pvc-9a1f..   200Gi      RWO            fast-nvme      6d
data-payments-ledger-1    Bound    pvc-3c8b..   200Gi      RWO            fast-nvme      6d
data-payments-ledger-2    Bound    pvc-71de..   200Gi      RWO            fast-nvme      6d
```

---

## 10. Scaling

```console
# manual, imperative
$ kubectl scale deployment/payments-api --replicas=8
deployment.apps/payments-api scaled

# guarded: only act if the current value is what you believe it is
$ kubectl scale deployment/payments-api --current-replicas=8 --replicas=12
deployment.apps/payments-api scaled
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: payments-api
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: payments-api
  minReplicas: 4
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70        # % of the CPU *request*, not the limit
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "30"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
        - { type: Pods,    value: 4,   periodSeconds: 30 }
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300   # damp flapping; look back 5 min
      policies:
        - { type: Percent, value: 25, periodSeconds: 60 }
```

```console
$ kubectl get hpa payments-api
NAME           REFERENCE                 TARGETS                        MINPODS  MAXPODS  REPLICAS  AGE
payments-api   Deployment/payments-api   cpu: 58%/70%, 21/30 (avg)      4        40       6         9d
```

**Critical interaction:** if an HPA owns `spec.replicas`, your GitOps manifest must **not** also declare `replicas`, or the two will fight forever. Under server-side apply this shows up as a field-ownership conflict (good). Under client-side apply it shows up as replica flapping every reconcile (bad). Omit `replicas` from the manifest whenever an HPA targets it.

`averageUtilization` is a percentage of the **request**. A Pod with `requests.cpu: 100m` and no limit, burning 400m, reports 400% and will scale out aggressively — one more reason requests must be honest.

---

## 11. Verification and failure diagnosis

### 11.1 The four-command triage loop

```console
$ kubectl get pods -o wide                      # 1. what is the coarse state?
$ kubectl describe pod <name>                   # 2. events + probe + scheduling detail
$ kubectl logs <name> -c <ctr> --previous       # 3. what did the DEAD container say?
$ kubectl events --for pod/<name> --types=Warning   # 4. cluster-level narrative
```

`--previous` is the one people forget. In a `CrashLoopBackOff` the current container has not started yet, so `kubectl logs` without `--previous` returns nothing useful, and the actual stack trace is in the terminated instance.

```console
$ kubectl get pods -n payments -o wide
NAME                            READY   STATUS             RESTARTS      AGE   IP            NODE        NOMINATED NODE   READINESS GATES
payments-api-6f8c4d9b7-4h2mv    0/1     CrashLoopBackOff   6 (94s ago)   11m   10.244.2.31   worker-03   <none>           <none>
payments-api-6f8c4d9b7-9pk3s    1/1     Running            0             11m   10.244.1.18   worker-01   <none>           <none>
payments-worker-58d9f7c4-tzn8q  0/1     Pending            0             4m    <none>        <none>      <none>           <none>
payments-batch-b7f2x            0/1     ImagePullBackOff   0             2m    10.244.3.7    worker-05   <none>           <none>

$ kubectl describe pod payments-api-6f8c4d9b7-4h2mv -n payments | tail -22
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Wed, 03 Sep 2026 09:41:02 +0200
      Finished:     Wed, 03 Sep 2026 09:41:03 +0200
    Ready:          False
    Restart Count:  6
Events:
  Type     Reason     Age                   From               Message
  ----     ------     ----                  ----               -------
  Normal   Scheduled  11m                   default-scheduler  Successfully assigned payments/payments-api-6f8c4d9b7-4h2mv to worker-03
  Normal   Pulled     11m                   kubelet            Container image "registry.internal/payments-api:1.15.1" already present on machine
  Warning  BackOff    91s (x38 over 10m)    kubelet            Back-off restarting failed container api in pod payments-api-6f8c4d9b7-4h2mv

$ kubectl logs payments-api-6f8c4d9b7-4h2mv -n payments --previous
{"level":"fatal","ts":"2026-09-03T07:41:03Z","msg":"config load failed",
 "error":"open /etc/payments/config.yaml: no such file or directory"}
```

Root cause found in three commands: the release bumped the image but the manifest lost the `config` volumeMount.

### 11.2 Failure catalogue

| Symptom (`STATUS` / condition) | Layer | Most likely causes | Diagnostic |
|---|---|---|---|
| `Pending`, no `nodeName` | Scheduler | Insufficient CPU/mem; no node matches `nodeSelector`/affinity; untolerated taint; unbound PVC; topology spread unsatisfiable | `kubectl describe pod` → `FailedScheduling` message names the predicate; `kubectl describe node \| grep -A5 Allocated` |
| `Pending` with `nodeName` set | kubelet | Node not ready; image pull in progress; CNI not assigning IPs | `kubectl describe node <n>`; `kubectl get pod -o jsonpath='{.status.conditions}'` |
| `ImagePullBackOff` / `ErrImagePull` | Registry | Wrong tag/name; private registry without `imagePullSecrets`; rate limit; wrong architecture | `kubectl describe pod` Events; `kubectl get sa <sa> -o yaml` for `imagePullSecrets` |
| `ErrImageNeverPull` | Policy | `imagePullPolicy: Never` and the image is absent on that node | Preload the image or change the policy |
| `CreateContainerConfigError` | kubelet | Referenced ConfigMap/Secret **key** or object does not exist | `kubectl describe pod`; `kubectl get cm,secret -n <ns>` |
| `CreateContainerError` | Runtime | Bad `command`/`workingDir`; `runAsNonRoot` with a root-only image; read-only rootfs the app writes to | Events + `kubectl logs --previous` |
| `CrashLoopBackOff` | App | Bad config, missing dependency, panic on start, PID 1 exits immediately | `kubectl logs --previous`; check exit code in `describe` |
| `OOMKilled` (exit 137) | Kernel cgroup | Memory limit below real working set; heap not limit-aware (JVM `-XX:MaxRAMPercentage`) | `kubectl get pod -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'` |
| `Running` but `0/1 READY` | Probe | `readinessProbe` failing; wrong port/path; app slower than the probe allows | `describe` → `Unhealthy` events; `kubectl exec` + `curl` the probe path locally |
| `Evicted` | Node pressure | `memory.available`/`nodefs` thresholds; BestEffort QoS | `kubectl describe node` → `Conditions: MemoryPressure/DiskPressure` |
| `Terminating` forever | API/finalizers | Finalizer not removed; unresponsive kubelet; stuck volume detach | `kubectl get pod -o jsonpath='{.metadata.finalizers}'`; last resort `--force --grace-period=0` (**can double-run a StatefulSet Pod — data risk**) |
| Service `ENDPOINTS: <none>` | Service | Selector mismatch; no Ready Pods; `targetPort` names a nonexistent port | `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` |
| Connection refused via Service, works via Pod IP | Dataplane | `targetPort` ≠ container port; `NetworkPolicy` denying; kube-proxy unhealthy | `kubectl port-forward` to Pod vs Service to bisect |
| `Init:0/2`, `Init:Error`, `Init:CrashLoopBackOff` | Init container | Dependency never becomes ready | `kubectl logs <pod> -c <init-container>` |

### 11.3 Getting inside a running (or unhealthy) Pod

```console
$ kubectl exec -it payments-api-7d9f4c8b5c-2kq7z -c api -- /bin/sh
/ $ wget -qO- http://127.0.0.1:8080/healthz/ready ; echo
{"status":"ok","db":"ok","cache":"ok"}
/ $ exit
```

When the image is distroless and has no shell — which every hardened production image should be — use an **ephemeral container**:

```console
$ kubectl debug -it payments-api-7d9f4c8b5c-2kq7z \
    --image=registry.internal/base/netshoot:0.13 \
    --target=api --profile=general -- bash
Targeting container "api". If you don't see processes from this container it may be
because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-p9x2q.

debugger:~# ss -lntp
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096          0.0.0.0:8080        0.0.0.0:*      users:(("payments-api",pid=1,fd=7))
LISTEN  0       4096          0.0.0.0:9090        0.0.0.0:*      users:(("payments-api",pid=1,fd=9))

debugger:~# curl -s localhost:8080/healthz/ready
{"status":"ok","db":"ok","cache":"ok"}
```

`--target=api` shares the target container's **process namespace**, so you see its PIDs, `/proc`, and its listening sockets. The ephemeral container is added to the running Pod — it does not restart it, and it cannot be removed (it disappears with the Pod).

Copy a Pod to debug a crash-looping one without disturbing production traffic:

```console
$ kubectl debug payments-api-6f8c4d9b7-4h2mv --copy-to=api-debug --container=api -- sleep infinity
$ kubectl exec -it api-debug -c api -- sh      # same volumes/env, but the entrypoint is replaced
```

And to debug the node itself:

```console
$ kubectl debug node/worker-03 -it --image=registry.internal/base/netshoot:0.13
Creating debugging pod node-debugger-worker-03-h7k2n with container debugger on node worker-03.
debugger:~# chroot /host journalctl -u kubelet -n 50 --no-pager
```

### 11.4 Local access without exposing anything

```console
$ kubectl port-forward svc/payments-api 8080:80 -n payments
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
Handling connection for 8080

# in another shell
$ curl -s localhost:8080/metrics | grep -m3 '^http_requests_total'
http_requests_total{code="200",method="GET",path="/healthz/ready"} 41823
http_requests_total{code="200",method="POST",path="/v1/payments"} 90114
http_requests_total{code="409",method="POST",path="/v1/refunds"} 27
```

`port-forward` to a **Service** picks one arbitrary backing Pod and tunnels to it — it does not load-balance. To bisect a "some requests fail" problem you must forward to individual Pods.

### 11.5 Resource pressure and node health

```console
$ kubectl top nodes
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
worker-01   3820m        47%    18942Mi         61%
worker-03   7104m        88%    29118Mi         94%
worker-05   1211m        15%    7440Mi          24%

$ kubectl top pods -n payments --sort-by=memory
NAME                            CPU(cores)   MEMORY(bytes)
payments-ledger-1               1902m        7811Mi
payments-ledger-0               1744m        7602Mi
payments-api-7d9f4c8b5c-2kq7z   410m         388Mi

$ kubectl describe node worker-03 | sed -n '/Allocated resources/,/Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                7250m (90%)   14200m (177%)
  memory             28Gi (92%)    30Gi (98%)
  ephemeral-storage  12Gi (14%)    24Gi (28%)
  pods               47            47
```

`kubectl top` requires **metrics-server**; without it you get `error: Metrics API not available`. Note that `describe node` shows **requests**, which is what the scheduler uses — a node at 90% requested but 40% actually used is *full* as far as scheduling is concerned. That gap is the single largest source of cluster cost waste.

### 11.6 Node maintenance

```console
$ kubectl cordon worker-03
node/worker-03 cordoned

$ kubectl drain worker-03 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m
node/worker-03 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/node-exporter-x8k2f, kube-system/cilium-p4m9q
evicting pod payments/payments-api-7d9f4c8b5c-2kq7z
evicting pod payments/payments-ledger-1
error when evicting pods/"payments-ledger-1" -n "payments" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod payments/payments-ledger-1
pod/payments-api-7d9f4c8b5c-2kq7z evicted
pod/payments-ledger-1 evicted
node/worker-03 drained

$ kubectl uncordon worker-03
node/worker-03 uncordoned
```

The PDB rejection followed by a successful retry is the system working correctly: the eviction API refused to break quorum until a replacement Pod became Ready elsewhere. A PDB that can *never* be satisfied (e.g. `minAvailable: 3` on a 3-replica StatefulSet) turns every drain into an infinite retry loop — a common cause of stuck cluster upgrades.

### 11.7 Escalating to the raw API

When `kubectl` output is not enough, look at the wire:

```console
$ kubectl get pod payments-api-7d9f4c8b5c-2kq7z --v=8 2>&1 | grep -E 'GET|Response Status'
I0903 09:52:11.402  round_trippers.go:463] GET https://10.0.0.10:6443/api/v1/namespaces/payments/pods/payments-api-7d9f4c8b5c-2kq7z
I0903 09:52:11.418  round_trippers.go:570] HTTP Statistics: GetConnection 0 ms ... Duration 15 ms
I0903 09:52:11.418  round_trippers.go:577] Response Status: 200 OK in 15 milliseconds

$ kubectl auth can-i delete pods --namespace payments
no

$ kubectl auth can-i --list --namespace payments | head -5
Resources                     Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authorization.k8s.io   []      []               [create]
pods                          []                  []               [get list watch]
deployments.apps              []                  []               [get list watch patch update]
configmaps                    []                  []               [get list watch]

$ kubectl get --raw /healthz?verbose | head -6
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]informer-sync ok
[+]shutdown ok
```

A `403 Forbidden` in `--v=8` output is an RBAC problem, not an application problem — a distinction that saves hours.

---

## 12. End-to-end verification runbook

A copy-pasteable sequence that proves a deployment is genuinely healthy, not just "green in the UI".

```console
# 0. Confirm the target — the most common production accident is the wrong context.
$ kubectl config current-context
prod-eu-west-1
$ kubectl config view --minify -o jsonpath='{..namespace}'; echo
payments

# 1. Validate before touching the cluster.
$ kubectl apply -f deploy/ --dry-run=server >/dev/null && echo "admission OK"
admission OK
$ kubectl diff -f deploy/ ; echo "diff exit=$?"
diff exit=1                                # 1 == there are changes to apply

# 2. Apply with an owned field manager.
$ kubectl apply --server-side --field-manager=release-pipeline -f deploy/
configmap/payments-api-config serverside-applied
secret/payments-api-secrets serverside-applied
deployment.apps/payments-api serverside-applied
service/payments-api serverside-applied
poddisruptionbudget.policy/payments-api serverside-applied
horizontalpodautoscaler.autoscaling/payments-api serverside-applied

# 3. Gate on the rollout, not on the apply.
$ kubectl rollout status deployment/payments-api --timeout=600s
deployment "payments-api" successfully rolled out

# 4. Prove the ReplicaSet generation actually converged.
$ kubectl get deploy payments-api -o jsonpath=\
'{.metadata.generation} {.status.observedGeneration} {.status.updatedReplicas}/{.status.readyReplicas}/{.spec.replicas}'; echo
9 9 4/4/4

# 5. Prove the Service has real endpoints (the step everyone skips).
$ kubectl get endpointslices -l kubernetes.io/service-name=payments-api \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
10.244.1.9 ready=true
10.244.2.17 ready=true
10.244.3.22 ready=true
10.244.0.31 ready=true

# 6. Prove the running image is the one you intended.
$ kubectl get pods -l app.kubernetes.io/name=payments-api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
payments-api-7d9f4c8b5c-2kq7z  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-9wxvn  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-hj4tp  registry.internal/payments-api@sha256:c1f0...9ab3
payments-api-7d9f4c8b5c-vn8rq  registry.internal/payments-api@sha256:c1f0...9ab3

# 7. Prove there were no restarts during the window.
$ kubectl get pods -l app.kubernetes.io/name=payments-api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
payments-api-7d9f4c8b5c-2kq7z  0
payments-api-7d9f4c8b5c-9wxvn  0
payments-api-7d9f4c8b5c-hj4tp  0
payments-api-7d9f4c8b5c-vn8rq  0

# 8. Prove it answers real traffic.
$ kubectl run smoke --rm -i --restart=Never --image=registry.internal/base/curl:8.9 -- \
    curl -sf -o /dev/null -w '%{http_code}\n' http://payments-api.payments.svc.cluster.local/healthz/ready
200
pod "smoke" deleted

# 9. Confirm nothing is warning at the cluster level.
$ kubectl events -n payments --types=Warning --for deployment/payments-api
No events found.
```

Steps 4–7 are the difference between "the deploy command succeeded" and "the deploy worked". `observedGeneration == generation` proves the controller processed your change rather than lagging; the imageID digest proves a mutable tag did not resolve to something unexpected on one node.

---

## 13. Operational gotchas worth internalising

- **`kubectl delete pod` is not a fix.** Under a Deployment it is a controller-triggered replacement; the underlying manifest defect persists and returns on the next scheduling round. Under a StatefulSet with `--force --grace-period=0` it can create a split-brain second writer.
- **Namespace stuck `Terminating`** is virtually always a finalizer on a child resource (frequently a broken aggregated APIService or a CRD whose operator is gone): `kubectl get namespace <ns> -o jsonpath='{.spec.finalizers}'` and `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns> --show-kind --ignore-not-found`.
- **`kubectl get all` does not get all.** It covers a hardcoded shortlist (pods, services, daemonsets, deployments, replicasets, statefulsets, jobs, cronjobs). ConfigMaps, Secrets, PVCs, Ingresses, NetworkPolicies and every CRD are excluded. Never use it to verify a cleanup.
- **Events expire.** Default retention is one hour. If the incident is older, the events are gone — which is why probe failures and OOM kills must be exported to your monitoring backend, not read from `describe`.
- **`latest` tags plus `imagePullPolicy: IfNotPresent`** produce nodes running different code with an identical manifest. Deploy by digest, or at minimum by immutable semver tag.
- **A `preStop` sleep is not superstition.** Endpoint removal (API → EndpointSlice → kube-proxy on every node) and SIGTERM delivery are concurrent and racy. Without a short `preStop` delay, a fraction of in-flight connections hit a socket that is already closing — the classic "5xx spike only during deploys".
- **`kubectl get -w` is not durable.** A watch can be closed by the API server at any time (`too old resource version`); `kubectl` restarts it transparently, but scripts that parse the stream must handle re-listing.
- **Output formats you should reach for reflexively:** `-o wide`, `-o yaml`, `-o json | jq`, `-o jsonpath=...`, `-o custom-columns=...`, `--show-labels`, `--sort-by=.metadata.creationTimestamp`, `--field-selector`, `-A` (all namespaces).

---

## 14. Referencias

**LPI**
- Exam 701-100 objectives (DevOps Tools Engineer, v2.0) — https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer certification overview — https://www.lpi.org/our-certifications/devops-overview/

**Kubernetes — kubectl and the API**
- kubectl reference — https://kubernetes.io/docs/reference/kubectl/
- kubectl command reference (generated) — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands
- kubectl Quick Reference (cheat sheet) — https://kubernetes.io/docs/reference/kubectl/quick-reference/
- Declarative management with configuration files — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Organizing cluster access with kubeconfig — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Version skew policy — https://kubernetes.io/releases/version-skew-policy/

**Objects, labels and namespaces**
- Kubernetes objects — https://kubernetes.io/docs/concepts/overview/working-with-objects/
- Labels and selectors — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Recommended labels — https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
- Annotations — https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/
- Namespaces — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Resource quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Owners and dependents / garbage collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/

**Workloads**
- Pods — https://kubernetes.io/docs/concepts/workloads/pods/
- Pod lifecycle — https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Init containers — https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- Sidecar containers — https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Deployments — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSets — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- StatefulSets — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSets — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs — https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJobs — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/

**Configuration and resources**
- ConfigMaps — https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets — https://kubernetes.io/docs/concepts/configuration/secret/
- Resource management for Pods and containers — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod Quality of Service classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Configure liveness, readiness and startup probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Encrypting confidential data at rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/

**Networking**
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- EndpointSlices — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- DNS for Services and Pods — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Virtual IPs and Service proxies (kube-proxy modes) — https://kubernetes.io/docs/reference/networking/virtual-ips/

**Scheduling, scaling and disruption**
- Assigning Pods to nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints and tolerations — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Horizontal Pod Autoscaling — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Pod Disruption Budgets — https://kubernetes.io/docs/tasks/run-application/configure-pdb/
- Safely drain a node — https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Node-pressure eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/

**Debugging**
- Debug running Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Debug Pods — https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- Debug Services — https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Ephemeral containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- `kubectl debug` reference — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/
- Resource metrics pipeline — https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/