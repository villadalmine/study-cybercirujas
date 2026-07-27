# 3.4 Self-healing primitives and robust deployments

## Core Concepts

Kubernetes does not deploy standalone Pods in production environments: Pods are designed as ephemeral and disposable resources (node failures, process crashes, resource evictions). System robustness and self-healing stem not from preventing Pod failures, but from active **controllers** continuous monitoring of declared specifications against observed cluster states via the API server. This continuous state reconciliation is known as the **reconciliation loop** pattern underlying all workload controllers.

Key primitives for the CKA exam:

- **High-level Controllers**: Deployment, ReplicaSet, DaemonSet, StatefulSet, Job, CronJob.
- **Pod-level Self-Healing**: `restartPolicy`, liveness, readiness, and startup probes.
- **Voluntary Disruption Resilience**: PodDisruptionBudget (PDB).

---

## ReplicaSet: Ensuring Target Replica Counts

A `ReplicaSet` (RS) guarantees that a specified number of Pod replicas remain running at all times. If a managed Pod terminates (crashes, host node failures, manual deletions), the ReplicaSet controller detects the deficit via API server watches and provisions a replacement Pod instance.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web-rs
spec:
  replicas: 3
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
```

In practice, ReplicaSets are managed declaratively via `Deployment` objects rather than created directly.

```console
$ kubectl delete pod web-rs-abc12
pod "web-rs-abc12" deleted

$ kubectl get pods -l app=web
NAME            READY   STATUS    RESTARTS   AGE
web-rs-def34    1/1     Running   0          40s   # Replacement Pod created by RS
web-rs-ghi56    1/1     Running   0          5m
web-rs-jkl78    1/1     Running   0          5m
```

`selector.matchLabels` determines Pod ownership for a ReplicaSet. `template` specifications are used exclusively when instantiating new Pods; existing Pod labels are not modified retroactively.

---

## Deployment: Declarative ReplicaSet Management

A `Deployment` wraps ReplicaSets to provide **rolling updates**, **rollbacks**, and revision history tracking. Modifying the `template` inside a Deployment provisions a new ReplicaSet, incrementally scaling down the previous ReplicaSet to 0 while scaling up the new ReplicaSet to target `replicas`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
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
```

- `maxUnavailable`: Maximum allowed unavailable Pod count during updates.
- `maxSurge`: Maximum allowed extra Pods above requested `replicas` during updates.
- `strategy.type: Recreate`: Terminates all old Pods before creating new ones (required when workloads cannot run concurrently, e.g. `ReadWriteOnce` volume constraints).

Deployments serve as application-level self-healing controllers: if Pods are deleted, underlying ReplicaSets recreate them; if a ReplicaSet is deleted, the Deployment controller recreates it from the specification `template`.

```console
$ kubectl rollout status deployment/web
deployment "web" successfully rolled out

$ kubectl get rs -l app=web
NAME               DESIRED   CURRENT   READY   AGE
web-7c9f8d6b4      3         3         3       2m
web-5b6d7c8f9      0         0         0       10m   # Previous RS scaled to 0
```

---

## DaemonSet: One Pod Per Node Topology

A `DaemonSet` guarantees that **every node** (or a targeted subset filtered via `nodeSelector`/affinity) executes exactly one copy of a Pod. It is the primitive for cluster infrastructure agents (log shippers, CNI plugins, monitoring daemons) where self-healing implies coverage across node topologies rather than fixed replica counts.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      tolerations:
      - operator: Exists   # Schedule onto nodes with taints (e.g. control-plane)
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.8.0
```

When new nodes join a cluster, the DaemonSet controller automatically schedules a Pod onto the new node. When nodes are removed, corresponding Pods terminate without rescheduling to remaining nodes.

---

## Job and CronJob: Batch Workloads

Unlike Deployments and ReplicaSets designed for long-running processes, a `Job` guarantees that one or more Pods execute to **successful completion** a specified number of times, managing retry behavior upon failure.

```yaml
apiVersion: apps/v1
kind: Job
metadata:
  name: db-migration
spec:
  backoffLimit: 4          # Retries before marking Job failed
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: myapp/migrate:1.0
```

- `backoffLimit`: Max retry attempts using exponential backoff delays.
- `restartPolicy` in Job pod templates **must** be set to `OnFailure` or `Never` (`Always` is prohibited).
- `activeDeadlineSeconds`: Terminates running Jobs exceeding time limits.

```console
$ kubectl get jobs
NAME           COMPLETIONS   DURATION   AGE
db-migration   1/1           14s        1m
```

A `CronJob` executes Jobs on a time-based schedule:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid       # Prevent concurrent job executions
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: myapp/backup:1.0
```

`concurrencyPolicy: Forbid` prevents slow executions from overlapping with subsequent scheduled runs.

---

## `restartPolicy`: Node-Level Container Self-Healing

Each Pod configures a `restartPolicy` (default `Always`) enforced locally by node **kubelet** agents:

| Value | Behavior |
|---|---|
| `Always` | Restarts container processes upon termination regardless of exit code. Default for Deployments/ReplicaSets. |
| `OnFailure` | Restarts container processes strictly when exit codes indicate non-zero failures. Typical for Jobs. |
| `Never` | Never restarts terminated container processes. Typical for single-shot Jobs or debugging. |

```console
$ kubectl get pod crashy -o jsonpath='{.status.containerStatuses[0].restartCount}'
7
```

High `RESTARTS` counts in `kubectl get pods` indicate containers failing repeatedly (`CrashLoopBackOff`); backoff delays between restart attempts increase exponentially (10s, 20s, 40s... up to 5 minutes).

---

## Health Probes: Failure Detection Mechanisms

Self-healing requires detecting application failures. Kubernetes provides three probe mechanisms supporting `exec`, `httpGet`, `tcpSocket`, or `grpc` checks:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-probes
spec:
  containers:
  - name: app
    image: myapp:1.0
    startupProbe:
      httpGet:
        path: /startupz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 10
      failureThreshold: 3
    readinessProbe:
      tcpSocket:
        port: 8080
      periodSeconds: 5
```

- **`livenessProbe`**: Upon failure, the **kubelet kills and restarts the container** (enforcing `restartPolicy`). Detects application deadlocks or unresponsive processes.
- **`readinessProbe`**: Upon failure, the Pod is **removed from Service Endpoints** (halting inbound traffic) **without triggering container restarts**. Used to isolate Pods warming up or experiencing transient loads.
- **`startupProbe`**: Disables liveness and readiness checks until startup checks pass. Protects slow-starting applications from premature liveness kills during initialization.

```console
$ kubectl describe pod web-probes | grep -A3 Events
Events:
  Warning  Unhealthy  2m (x3 over 3m)  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 500
  Normal   Killing    2m               kubelet  Container app failed liveness probe, will be restarted
```

---

## PodDisruptionBudget: Voluntary Disruption Resilience

While probes and controllers protect against **involuntary** failures (crashes, node hardware faults), `kubectl drain` maintenance operations represent **voluntary** disruptions. A `PodDisruptionBudget` (PDB) limits concurrent Pod evictions during voluntary operations.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2        # Or maxUnavailable: 1 (mutually exclusive)
  selector:
    matchLabels:
      app: web
```

During node drains, `kubectl drain` respects PDB configurations, blocking evictions if remaining active Pods drop below `minAvailable`:

```console
$ kubectl drain node-1 --ignore-daemonsets
node/node-1 cordoned
evicting pod default/web-7c9f8d6b4-x9k2p
error when evicting pods/"web-7c9f8d6b4-x9k2p": global timeout reached: 
  Cannot evict pod as it would violate the pod's disruption budget.
```

Note: PDBs **do not** prevent involuntary disruptions (node hardware crashes bypass PDB checks); PDBs apply exclusively to operations invoking the Eviction API.

---

## Combined Workflow Summary

1. **Deployment** specifies target state (`replicas`, image, strategy) → manages underlying **ReplicaSets**.
2. **ReplicaSet** maintains target Pod counts → replaces deleted or crashed Pods.
3. **kubelet** enforces `restartPolicy` locally when container processes terminate.
4. **livenessProbe** triggers kubelet container restarts when processes hang or deadlock.
5. **readinessProbe** removes unready Pods from Service Endpoints without restarting containers.
6. **PodDisruptionBudget** limits voluntary Pod evictions during administrative drains.
7. **DaemonSet** and **Job/CronJob** adapt reconciliation loops for node-topology and finite batch workloads respectively.

---

## References

- Workload Resources: https://kubernetes.io/docs/concepts/workloads/controllers/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Pod Lifecycle: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Configure Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- PodDisruptionBudget: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
