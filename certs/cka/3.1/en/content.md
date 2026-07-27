# 3.1 Application Deployments: rolling updates and rollbacks

## What is a Deployment?

A **Deployment** is the standard Kubernetes workload controller for managing stateless applications. It does not manage Pods directly: it creates and manages a **ReplicaSet**, which in turn maintains the requested count of Pods. This layered architecture (Deployment → ReplicaSet → Pods) enables rolling updates and instant rollbacks.

```
Deployment
   └── ReplicaSet (current revision)
          └── Pod, Pod, Pod...
```

Whenever `spec.template` changes in a Deployment (e.g. updated container image tags), Kubernetes does not modify active Pods in-place: it provisions a **new ReplicaSet** matching the updated template and incrementally migrates replicas from the old ReplicaSet to the new one. Previous ReplicaSets are retained with 0 active replicas to preserve revision history for rollbacks.

## Creating a Deployment

```bash
kubectl create deployment nginx --image=nginx:1.25 --replicas=3
```

Or via declarative YAML:

```yaml
# nginx-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 5
```

```bash
kubectl apply -f nginx-deploy.yaml
kubectl get deployments
```

```
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
nginx   3/3     3            3           12s
```

`selector.matchLabels` **must** match `template.metadata.labels`. Selectors are immutable post-creation — altering selectors requires re-creating the Deployment object.

## Deployment Strategies: `RollingUpdate` vs `Recreate`

`spec.strategy.type` controls how old Pod versions transition to new versions:

- **`Recreate`**: Terminates all existing Pods simultaneously before launching new instances. Guarantees downtime. Used when applications cannot support concurrent multi-version execution (e.g. database schema migrations).
- **`RollingUpdate`** (default): Replaces Pods incrementally without downtime when configured correctly.

### `rollingUpdate` Parameters

- **`maxUnavailable`**: Maximum count or percentage of Pods allowed unavailable during rollouts relative to requested replicas. Default `25%`.
- **`maxSurge`**: Maximum count or percentage of Pods allowed above requested replica counts during rollouts. Default `25%`.

Example with `replicas: 4`, `maxSurge: 1`, `maxUnavailable: 0`: Kubernetes creates 1 new Pod instance (5 Pods total), waits until `readinessProbe` succeeds, then terminates 1 old Pod (returning to 4 Pods total), repeating until all replicas update. Guarantees at least 4 available Pods at all times → zero downtime.

Setting `maxSurge: 0` and `maxUnavailable: 1` prevents surge Pod creation: an old Pod terminates before a new Pod launches, reducing resource spikes at the cost of temporary capacity drops.

> **Readiness probes** are essential: new Pods are not treated as "available" during rolling updates until readiness probes pass. Without configured probes, Kubernetes treats uninitialized Pods as available immediately.

## Triggering Deployment Updates

Modifying any parameter under `spec.template` triggers a rollout. Common methods:

```bash
# Update container image
kubectl set image deployment/nginx nginx=nginx:1.27

# Edit manifest directly
kubectl edit deployment nginx

# Re-apply updated YAML manifest
kubectl apply -f nginx-deploy.yaml
```

⚠️ Modifying replica counts via `kubectl scale` **does not** generate a new revision or trigger rolling updates — it merely adjusts replica targets on the active ReplicaSet.

## Monitoring Rollouts

```bash
kubectl rollout status deployment/nginx
```

```
Waiting for deployment "nginx" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx" rollout to finish: 1 old replicas are pending termination...
deployment "nginx" successfully rolled out
```

Inspect rollout events for troubleshooting:

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
OldReplicaSets:  <none>
NewReplicaSet:   nginx-7d9f8c9b6d (3/3 replicas created)
Events:
  Normal  ScalingReplicaSet  2m  deployment-controller  Scaled up replica set nginx-7d9f8c9b6d to 1
  Normal  ScalingReplicaSet  2m  deployment-controller  Scaled down replica set nginx-6c7f5d8b9c to 2
  ...
```

If new Pods fail readiness checks (e.g. invalid image tag), rollouts pause indefinitely in `Progressing` state. Detect timeouts via:

```bash
kubectl rollout status deployment/nginx --timeout=30s
```

```
error: timed out waiting for the condition
```

`spec.progressDeadlineSeconds` (default 600s) flags Deployments with condition `ProgressDeadlineExceeded` if rollouts fail to complete within time limits.

## Revision History

Rollout history is retained up to `revisionHistoryLimit` (default 10 in `apps/v1`).

```bash
kubectl rollout history deployment/nginx
```

```
deployment.apps/nginx
REVISION  CHANGE-CAUSE
1         <none>
2         kubectl set image deployment/nginx nginx=nginx:1.27
```

Populate `CHANGE-CAUSE` annotations manually:

```bash
kubectl annotate deployment/nginx kubernetes.io/change-cause="bump nginx to 1.27" --overwrite
```

Inspect specific revision details:

```bash
kubectl rollout history deployment/nginx --revision=2
```

```
deployment.apps/nginx with revision #2
Pod Template:
  Labels:       app=nginx
                pod-template-hash=7d9f8c9b6d
  Containers:
   nginx:
    Image:      nginx:1.27
    ...
```

Each revision maps directly to an underlying ReplicaSet:

```bash
kubectl get replicasets -l app=nginx
```

```
NAME               DESIRED   CURRENT   READY   AGE
nginx-6c7f5d8b9c   0         0         0       10m
nginx-7d9f8c9b6d   3         3         3       2m
```

## Rollbacks

Roll back to the immediately preceding revision:

```bash
kubectl rollout undo deployment/nginx
```

Roll back to a specific target revision:

```bash
kubectl rollout undo deployment/nginx --to-revision=1
```

```
deployment.apps/nginx rolled back
```

Rollbacks execute as rolling updates (honoring `maxSurge` and `maxUnavailable` limits). Kubernetes scales up the previous ReplicaSet while scaling down the failed ReplicaSet.

> **Exam Note**: Deleting a historical ReplicaSet removes its corresponding revision from rollback targets even if listed in `rollout history`.

## Pausing and Resuming Rollouts

Pause rollouts to apply multiple updates (image, resources, env vars) in a single consolidated revision:

```bash
kubectl rollout pause deployment/nginx
kubectl set image deployment/nginx nginx=nginx:1.27
kubectl set resources deployment/nginx -c=nginx --limits=cpu=200m,memory=256Mi
kubectl rollout resume deployment/nginx
```

While paused, updates do not trigger new ReplicaSet creations until `resume` executes.

## Manual Scaling

```bash
kubectl scale deployment/nginx --replicas=5
```

## Quick Reference Summary

| Action | Command |
|---|---|
| Create | `kubectl create deployment <name> --image=<img>` |
| Update image | `kubectl set image deployment/<name> <container>=<img>` |
| Rollout status | `kubectl rollout status deployment/<name>` |
| Revision history | `kubectl rollout history deployment/<name>` |
| View revision details | `kubectl rollout history deployment/<name> --revision=N` |
| Rollback to previous | `kubectl rollout undo deployment/<name>` |
| Rollback to revision N | `kubectl rollout undo deployment/<name> --to-revision=N` |
| Pause rollout | `kubectl rollout pause deployment/<name>` |
| Resume rollout | `kubectl rollout resume deployment/<name>` |
| Scale replicas | `kubectl scale deployment/<name> --replicas=N` |

## Common Pitfalls

- Modifying `metadata.labels` on the Deployment object (rather than `template.metadata.labels`) does not trigger rollouts.
- `ImagePullBackOff` errors on new Pods stall rollouts; Deployments maintain old versions as `AVAILABLE` up to `maxUnavailable` caps.
- Setting `revisionHistoryLimit: 0` disables historical ReplicaSet retention, preventing rollbacks.
- `kubectl rollout restart deployment/<name>` forces a rolling restart of all Pods without modifying specs (useful for updating mounted Secrets or forcing image re-pulls).

## References

- Deployments — Kubernetes Concepts: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- kubectl rollout reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout
- Performing a Rolling Update: https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/
- ReplicaSet — Kubernetes Concepts: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
