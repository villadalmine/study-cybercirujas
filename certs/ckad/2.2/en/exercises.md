# CKAD 2.2 — Understand Deployments and How to Perform Rolling Updates

*Reference: [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf) (Domain 2.2, weight 5%)*

These exercises assume a working cluster (`kind`, `minikube`, or similar) and `kubectl` configured against it. Work in a scratch namespace so cleanup is trivial.

```bash
kubectl create namespace ckad-222
kubectl config set-context --current --namespace=ckad-222
```

---

## Exercise 1 — Create a Deployment and inspect its object hierarchy

A `Deployment` is a controller that manages `ReplicaSet` objects, which in turn manage `Pod` objects. Understanding this three-layer chain is essential for CKAD — most rolling-update behavior is really ReplicaSet churn driven by the Deployment controller.

1. Create a Deployment imperatively:
   ```bash
   kubectl create deployment web --image=nginx:1.25 --replicas=3
   ```
2. List the objects it created, most specific first:
   ```bash
   kubectl get deployment web
   kubectl get replicaset -l app=web
   kubectl get pods -l app=web -o wide
   ```
3. Look at the ownership chain with `-o yaml` or `describe`:
   ```bash
   kubectl get replicaset -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}'
   kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}' 
   ```
4. Export the Deployment to a manifest for later edits and inspect the `spec.selector` and `spec.template`:
   ```bash
   kubectl get deployment web -o yaml > web-deploy.yaml
   grep -A3 "selector:" web-deploy.yaml
   ```

### Check your understanding
1. If you delete the ReplicaSet directly with `kubectl delete rs <name>`, what happens to the three Pods, and why?
2. Why must `spec.selector.matchLabels` on the Deployment be a subset of (and immutable relative to) the labels in `spec.template.metadata.labels`?

---

## Exercise 2 — Scale a Deployment two ways

1. Scale imperatively to 5 replicas:
   ```bash
   kubectl scale deployment web --replicas=5
   kubectl get pods -l app=web
   ```
2. Scale back down declaratively by editing the manifest and reapplying:
   ```bash
   sed -i 's/replicas: 5/replicas: 2/' web-deploy.yaml
   kubectl apply -f web-deploy.yaml
   kubectl get pods -l app=web
   ```
3. Try scaling with `kubectl edit deployment web` and change `replicas` inline, save, and confirm the Pod count converges again.

### Check your understanding
1. Why does mixing imperative `kubectl scale` and a stale local YAML file (with an old `replicas` value) create a source-of-truth problem if you later run `kubectl apply -f web-deploy.yaml`?
2. Which field does the Deployment controller actually reconcile against to decide how many Pods to run — the ReplicaSet's `spec.replicas`, or something else?

---

## Exercise 3 — Trigger a rolling update by changing the image

1. Confirm the current image and the `RollingUpdate` strategy defaults:
   ```bash
   kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
   kubectl describe deployment web | grep -A2 "Image:"
   ```
2. Trigger a rolling update with `kubectl set image`:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.26 --record=false
   ```
3. Immediately watch the rollout in a second terminal (or run this, it blocks until done):
   ```bash
   kubectl rollout status deployment/web
   ```
4. While the rollout is progressing, list ReplicaSets — you should briefly see two:
   ```bash
   kubectl get rs -l app=web
   ```
5. Confirm all Pods now run the new image:
   ```bash
   kubectl get pods -l app=web -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
   ```

### Check your understanding
1. Why does `kubectl set image` create a *new* ReplicaSet instead of mutating the existing one's Pods in place?
2. What determines how many old Pods are terminated and how many new Pods are created before the next batch, during the transition you observed in step 4?
3. Would editing `spec.template.metadata.labels` (not the image) also trigger a rollout? Why or why not?

---

## Exercise 4 — Read rollout history and diagnose a stuck rollout

1. Generate some history by making two more changes with change-cause annotations:
   ```bash
   kubectl annotate deployment web kubernetes.io/change-cause="bump to 1.26" --overwrite
   kubectl set image deployment/web nginx=nginx:1.27 
   kubectl annotate deployment web kubernetes.io/change-cause="bump to 1.27" --overwrite
   ```
2. View the revision history:
   ```bash
   kubectl rollout history deployment/web
   ```
3. Inspect a specific revision's Pod template:
   ```bash
   kubectl rollout history deployment/web --revision=2
   ```
4. Now deliberately break a rollout using a nonexistent tag:
   ```bash
   kubectl set image deployment/web nginx=nginx:this-tag-does-not-exist
   kubectl rollout status deployment/web --timeout=20s
   ```
5. Diagnose it:
   ```bash
   kubectl get pods -l app=web
   kubectl describe pod -l app=web | grep -A5 Events
   kubectl get deployment web -o jsonpath='{.status.conditions}{"\n"}'
   ```

### Check your understanding
1. `kubectl rollout status` timed out or hung in step 4. What Deployment status condition (`type` field) reflects this, and what does its `reason` typically say for an image pull failure?
2. Given `spec.progressDeadlineSeconds` (default 600s), what does the Deployment controller do to the *old* ReplicaSet while the new one is stuck — does it scale it to zero immediately?

---

## Exercise 5 — Roll back to a working revision

1. With the broken rollout from Exercise 4 still in place, roll back one step:
   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   ```
2. Confirm the image is healthy again:
   ```bash
   kubectl get pods -l app=web -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
   ```
3. Roll back to a specific, older revision instead of just "previous":
   ```bash
   kubectl rollout history deployment/web
   kubectl rollout undo deployment/web --to-revision=1
   kubectl get pods -l app=web -o jsonpath='{.items[*].spec.containers[*].image}{"\n"}'
   ```

### Check your understanding
1. `kubectl rollout undo` works by creating a new revision that copies an old ReplicaSet's Pod template — true or false? What does this imply about the revision *number* after a rollback?
2. What Deployment field controls how many old ReplicaSets are kept around (and thus how far back you can `--to-revision`), and what's its default?

---

## Exercise 6 — Tune the RollingUpdate strategy (maxSurge / maxUnavailable)

1. Edit the Deployment to set an explicit strategy:
   ```bash
   kubectl patch deployment web -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
   ```
2. Trigger a rollout and watch Pod counts closely — with 2 replicas, `maxUnavailable:0` and `maxSurge:1` you should see 3 Pods briefly, never fewer than 2 Ready:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.25
   kubectl get pods -l app=web -w
   ```
   (Ctrl+C once it settles back to 2.)
3. Now try the opposite extreme — allow faster, more disruptive rollouts:
   ```bash
   kubectl patch deployment web -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
   kubectl set image deployment/web nginx=nginx:1.26
   kubectl get pods -l app=web -w
   ```

### Check your understanding
1. With `replicas: 2`, `maxSurge: 1`, `maxUnavailable: 0`, what is the maximum number of Pods that can exist simultaneously during the rollout, and what is the minimum number that must stay Ready?
2. Why is `maxSurge: 0` combined with `maxUnavailable: 0` an invalid combination for `RollingUpdate`?
3. When would you choose `Recreate` instead of `RollingUpdate` as the strategy `type`?

---

## Exercise 7 — Pause, stage multiple changes, then resume

1. Pause the Deployment so further spec edits don't immediately trigger a rollout:
   ```bash
   kubectl rollout pause deployment/web
   ```
2. Make two changes while paused — they should NOT create separate ReplicaSets yet:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27
   kubectl set resources deployment/web -c=nginx --limits=cpu=200m,memory=256Mi
   kubectl get rs -l app=web
   ```
3. Resume, and confirm both changes roll out together as a single new revision:
   ```bash
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   kubectl rollout history deployment/web
   ```

### Check your understanding
1. Why is pausing useful for batching multiple `spec.template` changes into a single rollout instead of triggering one rollout per `kubectl set` command?
2. If you `kubectl rollout undo` while a Deployment is still paused, does anything visible happen to the running Pods? Why or why not?

---

## Cleanup

```bash
kubectl delete namespace ckad-222
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
1. The three Pods are deleted along with the ReplicaSet. The Deployment controller then notices the ReplicaSet matching its `spec.selector` is gone (or under-replicated) and creates a new ReplicaSet, which creates three fresh Pods — so you end up with new Pods, not the originals, and there's a brief availability gap.
2. The selector defines *permanently* which Pods the Deployment (and its ReplicaSets) own. If it weren't a stable subset of the template labels, changing the template could silently orphan running Pods or cause the Deployment to adopt unrelated Pods matching a broader selector. Kubernetes enforces `spec.selector` as immutable after creation specifically to prevent this class of bug.

### Exercise 2
1. `kubectl scale` mutates the live object's `spec.replicas` directly (an imperative, one-off change) without touching your local file. If you later `kubectl apply -f web-deploy.yaml` with a stale `replicas` value, the apply overwrites the live value back down (or up) to whatever the file says — silently undoing your scale command. This is the classic imperative/declarative drift problem; the fix is to treat the YAML file as the single source of truth and re-export or hand-edit it after any imperative change you want to keep.
2. The Deployment controller reconciles based on the **Deployment's own** `spec.replicas`, then propagates that count to the active ReplicaSet's `spec.replicas`. You never edit the ReplicaSet directly in normal operation — it's fully owned/managed by the Deployment.

### Exercise 3
1. Deployments implement rolling updates by creating a brand-new ReplicaSet (with the new Pod template hash) and gradually shifting replica counts from the old ReplicaSet to the new one, rather than mutating existing Pods. Pods are immutable with respect to their container image (you can't change a running Pod's image), so a new Pod template requires new Pods, which requires a new ReplicaSet (ReplicaSets are also matched/created by a hash of the Pod template).
2. The `spec.strategy.rollingUpdate.maxSurge` and `maxUnavailable` fields (defaulting to `25%` each) — surge caps how many *extra* Pods above the desired count can exist during the transition, and unavailable caps how many Pods below the desired count are tolerated.
3. Yes — any change to `spec.template` (including its metadata labels, env vars, image, resources, etc.) changes the Pod template hash and triggers a new rollout. Only changes outside `spec.template` (like `spec.replicas` or `spec.paused`) do *not* trigger a rollout.

### Exercise 4
1. The condition is `type: Progressing` with `status: "False"` and `reason: ProgressDeadlineExceeded` (visible once `progressDeadlineSeconds` elapses); before that deadline, you'd typically see Pods stuck in `ImagePullBackOff`/`ErrImagePull` via `kubectl describe pod` events.
2. No — the old ReplicaSet is kept scaled up (or only partially scaled down, per the strategy's `maxUnavailable`) as long as the new ReplicaSet isn't fully Ready. The controller won't finish shifting replicas away from a healthy old ReplicaSet toward a broken new one, which is exactly what keeps the Deployment available during a bad rollout.

### Exercise 5
1. True. `rollout undo` doesn't "revert" fields in place — it finds the target ReplicaSet (identified by its stored revision annotation) and makes the Deployment's `spec.template` match that ReplicaSet's template again, which itself is just a new rollout. Consequently, the revision counter keeps incrementing forward (e.g., undoing back to revision 1's content becomes revision 4, not "revision 1 again") — revision history is a strictly increasing log, not a movable pointer.
2. `spec.revisionHistoryLimit`, defaulting to `10`. Old ReplicaSets beyond that limit (scaled to 0) get garbage-collected, so you lose the ability to `--to-revision` back to them.

### Exercise 6
1. Maximum Pods = `replicas + maxSurge` = 2 + 1 = 3. Minimum Ready = `replicas - maxUnavailable` = 2 - 0 = 2. So the rollout must always keep both original Pods available while surging one extra new Pod before removing an old one.
2. Because it would leave the controller with no room to maneuver: it couldn't create extra Pods (surge=0) and couldn't remove any existing Pods either (unavailable=0), making it impossible to ever introduce a Pod with the new template. Kubernetes rejects/normalizes this combination.
3. `Recreate` is appropriate when the workload cannot tolerate two Pod versions running simultaneously — e.g., an application with a shared, non-backward-compatible volume or schema, or a singleton process bound to an exclusive resource. It terminates all old Pods before creating any new ones, trading availability for version-consistency guarantees.

### Exercise 7
1. Each `kubectl set image` / `kubectl set resources` call independently touches `spec.template`, and normally each would trigger its own rollout (its own new ReplicaSet, its own gradual Pod replacement). Pausing suppresses new-rollout creation while still recording changes to the Deployment's spec, so `resume` produces exactly one rollout that carries all the accumulated changes — fewer intermediate ReplicaSets, less Pod churn, one coherent rollout to watch/roll back.
2. No visible change to running Pods happens immediately — while paused, the Deployment controller does not reconcile ReplicaSets/Pods toward `spec.template`, so an `undo` while paused only rewrites the (paused) Deployment's `spec.template` back to the target revision's content; the actual Pod-level rollout only starts once you `rollout resume`.

</details>