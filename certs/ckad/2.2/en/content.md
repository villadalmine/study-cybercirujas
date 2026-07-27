# 2.2 Understand Deployments and How to Perform Rolling Updates

## 2.2.1 What Is a Deployment

A **Deployment** is the standard Kubernetes controller for running stateless (and generally any restart-tolerant) workloads. It provides declarative updates for Pods by managing an underlying **ReplicaSet**, which in turn manages the Pods themselves. You describe the desired state — container image, replica count, update strategy — and the Deployment controller continuously reconciles the cluster toward that state.

Deployments exist to solve three problems:

- **Self-healing at scale** — inherited from ReplicaSet: if a Pod dies, a new one is created to match the desired replica count.
- **Controlled updates** — changing the Pod template (e.g., a new image) triggers a new ReplicaSet and a gradual rollout instead of an all-at-once replacement.
- **Rollback** — every change to the Pod template is recorded as a revision, so you can revert to a previous known-good state.

## 2.2.2 Deployment → ReplicaSet → Pod

A Deployment never manages Pods directly — it manages ReplicaSets, and each ReplicaSet manages Pods:

```
Deployment (nginx)
 └─ ReplicaSet (nginx-7d7c4d8b7f)   ← current revision
     ├─ Pod (nginx-7d7c4d8b7f-abcde)
     └─ Pod (nginx-7d7c4d8b7f-fghij)
```

When you change the Pod template (image, env vars, labels in the template, etc.), the Deployment controller creates a **new** ReplicaSet with a new pod-template hash, and shifts replicas from the old ReplicaSet to the new one according to the update strategy. The old ReplicaSet is kept (scaled to 0) up to `revisionHistoryLimit`, which is what enables rollback.

```bash
kubectl get rs -l app=nginx
```
```
NAME                DESIRED   CURRENT   READY   AGE
nginx-7d7c4d8b7f     3         3         3       2m
nginx-8f6b9c8d6      0         0         0       10m
```

Changing only labels/selectors that don't touch `spec.template` (e.g., scaling replicas) does **not** create a new ReplicaSet — it just resizes the existing one.

## 2.2.3 Deployment Manifest Structure

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 3
  revisionHistoryLimit: 5
  minReadySeconds: 5
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app: nginx
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25.3
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 5
```

Key fields for the exam:

| Field | Purpose |
|---|---|
| `spec.selector.matchLabels` | Must match `spec.template.metadata.labels`; **immutable** after creation. |
| `spec.replicas` | Desired Pod count. |
| `spec.strategy.type` | `RollingUpdate` (default) or `Recreate`. |
| `spec.minReadySeconds` | Minimum time a new Pod must be Ready before it's considered available (slows down rollout speed to catch crash-loops). |
| `spec.revisionHistoryLimit` | How many old ReplicaSets to retain for rollback (default 10). |
| `spec.progressDeadlineSeconds` | Time before the controller reports the Deployment as failed to progress. |

## 2.2.4 Creating a Deployment

Imperative (quick, exam-friendly):

```bash
kubectl create deployment nginx --image=nginx:1.25.3 --replicas=3
```

Generate YAML without creating it (useful to then edit and `apply`):

```bash
kubectl create deployment nginx --image=nginx:1.25.3 --replicas=3 --dry-run=client -o yaml > deployment.yaml
kubectl apply -f deployment.yaml
```

Verify:

```bash
kubectl get deployment nginx
```
```
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
nginx   3/3     3            3           15s
```

## 2.2.5 Update Strategies: RollingUpdate and Recreate

### RollingUpdate (default)

Replaces Pods incrementally, keeping the application available throughout. Controlled by two parameters under `spec.strategy.rollingUpdate`:

- **`maxUnavailable`** — max number/percentage of Pods that can be unavailable during the update (default `25%`).
- **`maxSurge`** — max number/percentage of Pods that can be created above the desired replica count during the update (default `25%`).

Example with `replicas: 4`, `maxSurge: 1`, `maxUnavailable: 1`: the controller can scale up to 5 total Pods and down to 3 available Pods at any point during the rollout, replacing one old Pod at a time as new ones become Ready.

`maxUnavailable: 0` guarantees full capacity at all times (requires `maxSurge` ≥ 1, at the cost of temporarily using more resources).

### Recreate

Terminates **all** existing Pods before creating new ones. Causes downtime, but is required when the new and old versions cannot run concurrently (e.g., they'd conflict over a shared resource, or the app doesn't support two schema versions running at once).

```yaml
spec:
  strategy:
    type: Recreate
```

## 2.2.6 Performing a Rolling Update

The most common trigger is an image change. Three equivalent ways to do it:

**1. `kubectl set image`**

```bash
kubectl set image deployment/nginx nginx=nginx:1.27.0 --record
```
```
deployment.apps/nginx image updated
```

**2. `kubectl edit`**

```bash
kubectl edit deployment nginx
# change spec.template.spec.containers[0].image, save and exit
```

**3. Declarative `kubectl apply`** (recommended for GitOps-style workflows — edit the YAML's image field, then):

```bash
kubectl apply -f deployment.yaml
```

Any of these changes `spec.template`, which is what makes the Deployment controller cut a new ReplicaSet and start the rollout — changing `metadata` (e.g. annotations) alone does not.

## 2.2.7 Monitoring Rollout Status

```bash
kubectl rollout status deployment/nginx
```
```
Waiting for deployment "nginx" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx" rollout to finish: 1 old replicas are pending termination...
deployment "nginx" successfully rolled out
```

Inspect Deployment conditions for detail on rollout progress and health:

```bash
kubectl describe deployment nginx
```
```
...
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
...
```

`Progressing=False` with `Reason: ProgressDeadlineExceeded` means the rollout stalled past `progressDeadlineSeconds` — a strong signal to check Pod events (e.g., `ImagePullBackOff`, failing readiness probe).

## 2.2.8 Rollout History and Rollback

Every `spec.template` change is a new **revision**, tracked via the `deployment.kubernetes.io/revision` annotation on the ReplicaSet.

```bash
kubectl rollout history deployment/nginx
```
```
deployment.apps/nginx
REVISION  CHANGE-CAUSE
1         kubectl create deployment nginx --image=nginx:1.25.3 --replicas=3
2         kubectl set image deployment/nginx nginx=nginx:1.27.0 --record
```

`--record` (deprecated but still common on the exam) populates `CHANGE-CAUSE`; alternatively set it explicitly:

```bash
kubectl annotate deployment nginx kubernetes.io/change-cause="update to nginx:1.27.0"
```

Inspect a specific revision:

```bash
kubectl rollout history deployment/nginx --revision=2
```
```
deployment.apps/nginx with revision #2
Pod Template:
  Labels:       app=nginx
                pod-template-hash=6f8cbc8f4b
  Containers:
   nginx:
    Image:      nginx:1.27.0
    ...
```

**Undo the last rollout:**

```bash
kubectl rollout undo deployment/nginx
```
```
deployment.apps/nginx rolled back
```

**Roll back to a specific revision:**

```bash
kubectl rollout undo deployment/nginx --to-revision=1
```

A rollback is itself a rolling update in reverse — it goes through the same `maxSurge`/`maxUnavailable`-controlled process and creates a new revision number (Kubernetes does not "rewind" the counter).

## 2.2.9 Pausing and Resuming Rollouts

Pausing lets you batch multiple template changes (image + env vars + resources) into a single rollout instead of triggering one per change:

```bash
kubectl rollout pause deployment/nginx
kubectl set image deployment/nginx nginx=nginx:1.27.0
kubectl set resources deployment/nginx -c=nginx --limits=cpu=200m,memory=256Mi
kubectl rollout resume deployment/nginx
```

While paused, `kubectl rollout status` will not report progress and no new ReplicaSet rollout occurs until `resume`.

## 2.2.10 Scaling a Deployment

Scaling changes `spec.replicas` only — it does **not** create a new revision or trigger a rolling update:

```bash
kubectl scale deployment nginx --replicas=5
```
```
deployment.apps/nginx scaled
```

Autoscaling (conceptually relevant, detailed elsewhere in the curriculum):

```bash
kubectl autoscale deployment nginx --min=3 --max=10 --cpu-percent=70
```

## 2.2.11 Readiness Probes and Rollout Safety

Rolling updates rely entirely on **readiness probes** to know when a new Pod can be considered "available" and safe to route traffic to. Without a readiness probe, a Pod is considered ready as soon as its containers start — which can roll out a broken version to 100% of traffic before anyone notices.

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

Combined with `minReadySeconds`, this creates a safety window: a new Pod must pass its readiness probe and then stay ready for `minReadySeconds` before the controller proceeds to replace the next old Pod. This is the primary mechanism for catching a bad rollout early, before it reaches full replica count.

## 2.2.12 Troubleshooting Stuck Rollouts

Typical exam scenario: a rollout hangs with `x out of y new replicas updated`.

```bash
kubectl get pods -l app=nginx
```
```
NAME                     READY   STATUS             RESTARTS   AGE
nginx-6f8cbc8f4b-2kxqz   0/1     ImagePullBackOff   0          90s
nginx-7d7c4d8b7f-abcde   1/1     Running            0          10m
nginx-7d7c4d8b7f-fghij   1/1     Running            0          10m
```

```bash
kubectl describe pod nginx-6f8cbc8f4b-2kxqz
```
```
Events:
  Warning  Failed     Failed to pull image "nginx:1.27.x": rpc error: ...
  Warning  BackOff    Back-off pulling image "nginx:1.27.x"
```

Because `maxUnavailable` protects the old, healthy Pods, they keep serving traffic and the Deployment stays `Available: True` even while `Progressing` is stuck — this is the rolling-update strategy working as intended. Fix path: correct the image tag and re-apply, or roll back:

```bash
kubectl rollout undo deployment/nginx
```

## References

- Deployments — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Performing a Rolling Update — https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/
- `kubectl rollout` reference — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout
- `kubectl` Deployment commands (`set image`, `scale`, `autoscale`) — https://kubernetes.io/docs/reference/kubectl/generated/kubectl_set/kubectl_set_image/
- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- ReplicaSet — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf