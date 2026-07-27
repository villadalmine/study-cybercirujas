# 1.2 Choose and Use the Right Workload Resource

## Overview

Kubernetes never runs Pods directly in production. Instead, a **workload resource** (a *controller*) manages Pods on your behalf: creating them, replacing them when they fail, scaling them, or running them on a schedule. Choosing the correct workload resource for a given application pattern — long-running stateless service, per-node agent, stateful clustered app, or batch task — is a core CKAD skill, since the wrong choice leads to data loss, missed scheduling, or unnecessary operational overhead.

The main workload resources on the exam are:

| Resource | Purpose | Pod identity | Typical use case |
|---|---|---|---|
| **Deployment** | Stateless, scalable apps | Interchangeable | Web servers, APIs, microservices |
| **ReplicaSet** | Maintains N replicas of a Pod | Interchangeable | Rarely created directly; managed by Deployment |
| **StatefulSet** | Stateful apps needing stable identity/storage | Stable, ordered | Databases, message queues, clustered apps |
| **DaemonSet** | One Pod per (matching) node | Tied to node | Log collectors, node monitoring, CNI/CSI agents |
| **Job** | Run to completion, once or N times | Ephemeral | Batch processing, migrations, one-off tasks |
| **CronJob** | Job on a schedule | Ephemeral | Backups, scheduled reports, cleanup tasks |

All of these ultimately create and manage **Pods** using a Pod template embedded in their spec.

---

## Pod (bare)

A bare Pod with no controller is technically valid but has no self-healing: if the node fails or the Pod is deleted, nothing recreates it. Use bare Pods only for quick debugging (`kubectl run`) or truly one-off, disposable workloads. In real deployments, always wrap Pods in a controller.

```bash
kubectl run debug-pod --image=busybox --restart=Never -- sleep 3600
```

`--restart=Never` is what makes `kubectl run` create a bare Pod instead of a Deployment.

---

## Deployment

The default choice for **stateless** applications. A Deployment manages a ReplicaSet, which in turn manages Pods. It provides:

- Declarative rolling updates and rollbacks (`kubectl rollout`)
- Horizontal scaling (`kubectl scale`, or via HPA)
- Self-healing — a controller loop replaces crashed/deleted Pods to maintain the desired replica count

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
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
        image: nginx:1.25
```

```bash
kubectl get deployment web
```
```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/3     3            3           12s
```

Pod names look like `web-<replicaset-hash>-<random>` (e.g. `web-7d9f6c8b5-x2j4k`) — the middle segment is inherited from the owning ReplicaSet, confirming the ownership chain Deployment → ReplicaSet → Pod.

Rolling update / rollback:

```bash
kubectl set image deployment/web nginx=nginx:1.27
kubectl rollout status deployment/web
kubectl rollout undo deployment/web
```

**When to use:** any app where every Pod is identical and interchangeable, with no need for stable network identity or per-replica persistent storage.

---

## ReplicaSet

A ReplicaSet's sole job is to keep a specified number of identical Pods running, matched via a label selector. In practice you rarely create ReplicaSets directly — Deployments create and own them to enable rolling updates. Knowing this relationship matters for the exam because troubleshooting a Deployment often means inspecting its ReplicaSet:

```bash
kubectl get rs -l app=web
kubectl describe rs web-7d9f6c8b5
```

If you delete a Pod managed by a ReplicaSet, it is immediately recreated; if you delete the ReplicaSet itself (without `--cascade=orphan`), its Pods are deleted too.

---

## StatefulSet

Used when Pods need a **stable, unique identity** — a predictable network name and, optionally, dedicated persistent storage that survives rescheduling. Typical for clustered, stateful software (databases, Kafka, ZooKeeper, Elasticsearch).

Key properties:
- Pods get **stable ordinal names**: `<name>-0`, `<name>-1`, `<name>-2`, …
- Pods are created, scaled, and deleted **in order** (0, then 1, then 2…) and terminated in reverse order
- Each Pod gets a stable DNS entry via a **headless Service** (`clusterIP: None`)
- `volumeClaimTemplates` provision a dedicated PersistentVolumeClaim per Pod, which is **not** deleted automatically when the Pod is removed — it survives rescheduling and reattaches to the same ordinal

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db-headless
  replicas: 3
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: postgres
        image: postgres:16
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 5Gi
```

```bash
kubectl get pods -l app=db
```
```
NAME    READY   STATUS    RESTARTS   AGE
db-0    1/1     Running   0          40s
db-1    1/1     Running   0          25s
db-2    1/1     Running   0          10s
```

```bash
kubectl get pvc
```
```
NAME          STATUS   VOLUME   CAPACITY   ACCESS MODES
data-db-0     Bound    pvc-a1   5Gi        RWO
data-db-1     Bound    pvc-b2   5Gi        RWO
data-db-2     Bound    pvc-c3   5Gi        RWO
```

**When to use:** stable network identity or stable per-replica storage is required, or startup/shutdown must happen in a defined order.

---

## DaemonSet

Ensures that **exactly one copy** of a Pod runs on every node (or every node matching a selector/taint tolerance) in the cluster. As nodes are added, DaemonSet Pods are automatically scheduled onto them; as nodes are removed, those Pods are garbage-collected. There is no `replicas` field — the node count *is* the replica count.

Common uses: log shippers (Fluentd/Fluent Bit), node monitoring agents (node-exporter), CNI/CSI/kube-proxy plugins.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-logger
spec:
  selector:
    matchLabels:
      app: node-logger
  template:
    metadata:
      labels:
        app: node-logger
    spec:
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:3.0
```

```bash
kubectl get daemonset node-logger
```
```
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
node-logger   3         3         3       3            3           <none>
```

To restrict a DaemonSet to a subset of nodes, add a `nodeSelector` or `affinity` in the Pod template. To run on control-plane/tainted nodes, add the matching `tolerations`.

**When to use:** a workload must run once per node (infrastructure/agent pattern), not "N replicas somewhere in the cluster."

---

## Job

Runs Pods to **completion** rather than indefinitely — appropriate for finite, batch-style work. A Job tracks successful completions and retries failed Pods according to `backoffLimit`.

Key fields:
- `completions`: total successful Pod completions needed (default 1)
- `parallelism`: how many Pods may run concurrently (default 1)
- `backoffLimit`: retries before marking the Job failed (default 6)
- `restartPolicy` in the Pod template must be `Never` or `OnFailure` (never `Always`)

```bash
kubectl create job db-migrate --image=migrate/migrate -- migrate -path /migrations -database $DB_URL up
```

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-report
spec:
  completions: 5
  parallelism: 2
  backoffLimit: 3
  template:
    spec:
      containers:
      - name: report
        image: report-gen:1.0
      restartPolicy: OnFailure
```

```bash
kubectl get job batch-report
```
```
NAME           COMPLETIONS   DURATION   AGE
batch-report   5/5           38s        40s
```

Waiting for completion (useful in scripts/exam):

```bash
kubectl wait --for=condition=complete job/batch-report --timeout=120s
```

**When to use:** the task has a defined end (data migration, report generation, one-off script) rather than running forever.

---

## CronJob

Creates Jobs on a repeating **schedule**, using standard cron syntax. Each scheduled firing creates a new Job object (and thus new Pods), following the `jobTemplate`.

```bash
kubectl create cronjob nightly-backup --image=backup-tool:1.0 --schedule="0 2 * * *" -- /run-backup.sh
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: backup-tool:1.0
            args: ["/run-backup.sh"]
          restartPolicy: OnFailure
```

Important fields:
- `concurrencyPolicy`: `Allow` (default, overlapping runs permitted), `Forbid` (skip new run if previous still active), `Replace` (cancel current run, start new one)
- `startingDeadlineSeconds`: how late a missed run can still be started
- `successfulJobsHistoryLimit` / `failedJobsHistoryLimit`: how many completed Job objects to retain for inspection

```bash
kubectl get cronjob nightly-backup
```
```
NAME             SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
nightly-backup   0 2 * * *   <none>     False     0        <none>          5s
```

Trigger a run immediately without waiting for the schedule (handy for testing on the exam):

```bash
kubectl create job --from=cronjob/nightly-backup manual-test-run
```

Suspend a CronJob without deleting it:

```bash
kubectl patch cronjob nightly-backup -p '{"spec":{"suspend":true}}'
```

**When to use:** the same batch task needs to run repeatedly on a time-based schedule.

---

## Decision Checklist

Given a scenario, ask in order:

1. **Does it need to run once and finish, or repeatedly on a schedule?** → Job / CronJob
2. **Does it need exactly one instance per node (agent/daemon pattern)?** → DaemonSet
3. **Does it need stable network identity and/or per-replica persistent storage, with ordered startup?** → StatefulSet
4. **Otherwise, is it a long-running, stateless, horizontally scalable app?** → Deployment

---

## Referencias

- Workloads overview: https://kubernetes.io/docs/concepts/workloads/
- Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- kubectl `create` reference (deployment/job/cronjob generators): https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf