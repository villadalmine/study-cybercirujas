# Guided Exercises: Application Delivery (KCNA — Topic 2.1)

These exercises assume a local cluster (`kind`, `minikube`, or Docker Desktop) with `kubectl` configured and, for the last exercise, `helm` installed.

## Exercise 1: Rolling Update of a Deployment

The default deployment strategy for a `Deployment` in Kubernetes is **RollingUpdate**: it replaces old Pods with new ones incrementally, with no downtime, creating a new `ReplicaSet` on each update.

1. Create a Deployment with an initial image:
```
kubectl create deployment web --image=nginx:1.25 --replicas=4
```
2. Confirm that an associated `ReplicaSet` was created:
```
kubectl get replicaset -l app=web
```
3. Trigger an update by changing the image:
```
kubectl set image deployment/web nginx=nginx:1.27
```
4. Watch the rollout progress in real time:
```
kubectl rollout status deployment/web
```
5. List the revision history:
```
kubectl rollout history deployment/web
```
6. Roll back to the previous revision:
```
kubectl rollout undo deployment/web
```

**Comprehension questions:**
1. Why doesn't `kubectl rollout undo` delete the previous `ReplicaSet` instead of reusing it?
2. If the new Pod never passes its `readinessProbe`, what happens to the rollout?

## Exercise 2: Controlling `maxSurge` and `maxUnavailable`

These two fields, within `spec.strategy.rollingUpdate`, define how many extra Pods the rollout can create and how many it can leave unavailable during the transition.

1. Export the current Deployment manifest:
```
kubectl get deployment web -o yaml > web.yaml
```
2. Edit `web.yaml` and add inside `spec`:
```
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```
3. Apply the change:
```
kubectl apply -f web.yaml
```
4. Trigger another image update and watch how many Pods are `Running` simultaneously during the rollout:
```
kubectl set image deployment/web nginx=nginx:1.25
kubectl get pods -l app=web -w
```

**Comprehension questions:**
1. With `maxUnavailable: 0` and `maxSurge: 1`, can the total number of Pods during the rollout exceed the configured `replicas`? Why?
2. What combination of values would bring the behavior closer to a Recreate (kill everything before creating the new ones)?

## Exercise 3: Manual Blue-Green and Canary with labels

Kubernetes doesn't have a native "Blue-Green" or "Canary" object: these strategies are built by combining `Deployments` with labels and a `Service`'s `selector`.

1. Create the "blue" (stable) version:
```
kubectl create deployment app-blue --image=nginx:1.25 --replicas=3
kubectl label deployment app-blue track=blue
```
2. Expose a Service pointing to `track=blue`:
```
kubectl expose deployment app-blue --name=app --port=80 --selector=track=blue
```
3. Create the "green" (new) version without traffic yet:
```
kubectl create deployment app-green --image=nginx:1.27 --replicas=3
kubectl label deployment app-green track=green
```
4. Once you validate that "green" works, change the Service's `selector` to cut over traffic all at once:
```
kubectl patch service app -p '{"spec":{"selector":{"track":"green"}}}'
```
5. To simulate a **canary**, instead of cutting over all traffic at once, let the Service select a common label (`app=app`) present in both Deployments and adjust the replica ratio between "stable" and "canary" (for example 9 vs 1) to control what percentage of traffic the new version receives.

**Comprehension questions:**
1. In step 4, why is the traffic cutover instantaneous even though the "blue" Pods keep running?
2. In the canary-by-replica-ratio approach, what guarantees (or doesn't guarantee) that exactly 10% of requests go to the new version?
3. What advantage does blue-green have over canary in terms of rollback speed, and what disadvantage in terms of resource usage?

## Exercise 4: Packaging and versioning with Helm

Helm manages applications as **charts** (packages of templated manifests) and **releases** (installed instances), with its own revision history independent from a Deployment's.

1. Add a chart repository and update the local index:
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```
2. Install a release with default values:
```
helm install mi-nginx bitnami/nginx --version 15.5.0
```
3. Check the status and the effective values used:
```
helm status mi-nginx
helm get values mi-nginx
```
4. Update the release by overriding a value (for example the number of replicas):
```
helm upgrade mi-nginx bitnami/nginx --set replicaCount=2
```
5. List the release's revision history:
```
helm history mi-nginx
```
6. Roll back to the previous revision:
```
helm rollback mi-nginx 1
```

**Comprehension questions:**
1. How does `helm rollback`'s history differ from the `kubectl rollout undo` history seen in Exercise 1?
2. If two different charts create a `Deployment` with the same name in the same namespace, what happens when installing the second one with `helm install`?
3. Why is it recommended to pin `--version` when installing a chart from a third-party repo?

<details>
<summary>See answers</summary>

**Exercise 1**
1. Because Kubernetes keeps the previous `ReplicaSets` (up to the `revisionHistoryLimit` limit) scaled to 0 replicas, precisely so that a rollback only needs to scale them back up instead of recreating Pods from scratch.
2. The rollout gets "stuck" (`progressing` but never completing): the old Pods don't finish being replaced because the controller waits for the new Pod to be `Ready` before proceeding further, according to the configured strategy.

**Exercise 2**
1. No: with `maxSurge: 1` there can be at most `replicas + 1` Pods in total during the rollout, and with `maxUnavailable: 0` there are never fewer than `replicas` Pods available. The total never exceeds `replicas + maxSurge`.
2. `maxSurge: 0` and `maxUnavailable: 100%` (or a value equal to `replicas`) forces the old Pods to be torn down before creating the new ones, replicating `Recreate` behavior.

**Exercise 3**
1. Because the cutover is done by the `Service`, not the Pods: when the `selector` changes, the `Endpoints`/`EndpointSlice` is recalculated immediately and stops routing traffic to Pods with `track=blue`, even though those Pods keep `Running`.
2. It only guarantees it approximately: `kube-proxy` balances between the Pods that match the Service's selector without weighting by version, so the actual traffic proportion depends on how many Pods of each track exist, not on an explicitly configured percentage (fine-grained traffic control requires a service mesh or ingress controller with weighted routing support).
3. Advantage: rollback is instantaneous (just switch the selector back), without waiting for Pods to be recreated. Disadvantage: it requires keeping double the resources running (both versions at full replica count) while validation lasts.

**Exercise 4**
1. `helm rollback` reverts the entire release (all resources managed by the chart: Deployments, Services, ConfigMaps, etc. as a single versioned unit), while `kubectl rollout undo` only reverts a specific `Deployment` and its associated `ReplicaSet`.
2. It fails (or generates a conflict/error), because Kubernetes doesn't allow two resources of the same type with the same name in the same namespace; Helm doesn't resolve name collisions between different releases.
3. Because without pinning a version, `helm install` pulls the latest version published in the repo, which may introduce breaking or untested behavior changes, breaking the reproducibility of the deployment.

</details>

---
Reference source: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)