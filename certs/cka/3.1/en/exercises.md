# Guided Exercises — 3.1 Application Deployments: rolling update and rollback

> Reference: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working Kubernetes cluster with `kubectl` configured.

## Exercise 1 — Setting Up Working Namespace

1. Create a dedicated namespace:
   ```bash
   kubectl create namespace deploy-lab
   ```
2. Set as default namespace for current context:
   ```bash
   kubectl config set-context --current --namespace=deploy-lab
   ```
3. Confirm active context settings:
   ```bash
   kubectl config view --minify | grep namespace
   ```

**Comprehension Questions**
- What is the difference between passing `-n deploy-lab` on every command vs setting active namespace in the context?
- Which command resets context namespace back to `default`?

---

## Exercise 2 — Creating Deployments Declaratively

1. Create manifest `web-deploy.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     labels:
       app: web
   spec:
     replicas: 4
     revisionHistoryLimit: 5
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
           image: nginx:1.25.3
           ports:
           - containerPort: 80
   ```
2. Apply to cluster:
   ```bash
   kubectl apply -f web-deploy.yaml
   ```
3. Annotate change cause:
   ```bash
   kubectl annotate deployment web kubernetes.io/change-cause="initial deploy nginx:1.25.3"
   ```

**Comprehension Questions**
- Why is `kubectl apply` preferred over `kubectl create` for lifecycle management?
- What does `revisionHistoryLimit` control, and why is it critical for rollbacks?

---

## Exercise 3 — Inspecting Deployment → ReplicaSet → Pod Relationships

1. List Deployment and ReplicaSet resources:
   ```bash
   kubectl get deployment web
   kubectl get replicaset -l app=web
   ```
2. List Pods and observe name suffixes:
   ```bash
   kubectl get pods -l app=web -o wide
   ```
3. Inspect ReplicaSet details:
   ```bash
   kubectl describe replicaset -l app=web
   ```

**Comprehension Questions**
- Which object actually creates and manages Pods: Deployment or ReplicaSet?
- How does the hash suffix on ReplicaSets and Pods relate to Deployment pod templates?

---

## Exercise 4 — Scaling Deployments

1. Scale to 6 replicas:
   ```bash
   kubectl scale deployment web --replicas=6
   ```
2. Confirm ReplicaSet adjusts Pod counts:
   ```bash
   kubectl get pods -l app=web
   ```

**Comprehension Questions**
- Does scaling generate a new revision in rollout history? Explain.

---

## Exercise 5 — Rolling Updates via Image Change

1. Update container image:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.3
   ```
2. Annotate change cause:
   ```bash
   kubectl annotate deployment web kubernetes.io/change-cause="update to nginx:1.27.3" --overwrite
   ```
3. Track rollout progress:
   ```bash
   kubectl rollout status deployment/web
   ```
4. Observe Pod lifecycle transitions in a separate terminal:
   ```bash
   kubectl get pods -l app=web -w
   ```

**Comprehension Questions**
- Does a rolling update terminate all old Pods before creating new ones? Explain how service availability is preserved.
- Which command confirms updated container images in Deployment specs?

---

## Exercise 6 — Configuring Rolling Update Parameters

1. Inspect active rollout strategy:
   ```bash
   kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
   ```
2. Patch Deployment specifying `maxSurge` and `maxUnavailable`:
   ```bash
   kubectl patch deployment web -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
   ```
3. Update container image to observe effects:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.4
   kubectl get pods -l app=web -w
   ```

**Comprehension Questions**
- With `maxUnavailable: 0` and `maxSurge: 1`, what is the maximum number of Pods running simultaneously during updates when `replicas: 6`?
- Which combination of `maxSurge`/`maxUnavailable` prioritizes rollout speed over resource conservation?

---

## Exercise 7 — Inspecting Revision History

1. List rollout history:
   ```bash
   kubectl rollout history deployment/web
   ```
2. Inspect details of a specific revision:
   ```bash
   kubectl rollout history deployment/web --revision=2
   ```

**Comprehension Questions**
- What specific information does `--revision=N` display that is absent from summary listings?
- If `kubernetes.io/change-cause` annotations are omitted, what appears in rollout history listings?

---

## Exercise 8 — Simulating Failed Rollouts

1. Specify a non-existent image tag to simulate deployment failure:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.99-does-not-exist
   ```
2. Observe rollout stalling:
   ```bash
   kubectl rollout status deployment/web --timeout=30s
   ```
3. Diagnose failure cause:
   ```bash
   kubectl get pods -l app=web
   kubectl describe pod -l app=web | grep -A5 Events
   ```

**Comprehension Questions**
- Why do old Pods continue serving traffic when a rollout stalls?
- What event reason appears on new Pods (e.g. `ImagePullBackOff` or `ErrImagePull`)?

---

## Exercise 9 — Rollback to Previous Revision

1. Revert Deployment to previous revision:
   ```bash
   kubectl rollout undo deployment/web
   ```
2. Confirm rollout completion:
   ```bash
   kubectl rollout status deployment/web
   ```
3. Confirm active container image:
   ```bash
   kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

**Comprehension Questions**
- Does `kubectl rollout undo` create a new revision number or reuse old revision numbers?
- What occurs if attempting `undo` after `revisionHistoryLimit` purges target revisions?

---

## Exercise 10 — Rollback to Specific Target Revisions

1. Inspect available revisions:
   ```bash
   kubectl rollout history deployment/web
   ```
2. Perform targeted rollback to revision 1:
   ```bash
   kubectl rollout undo deployment/web --to-revision=1
   ```
3. Confirm result:
   ```bash
   kubectl rollout status deployment/web
   kubectl describe deployment web | grep Image
   ```

**Comprehension Questions**
- What advantage does `--to-revision` offer over plain `undo` when multiple intermediate rollouts fail?

---

## Exercise 11 — Pausing and Resuming Rollouts

1. Pause Deployment rollout:
   ```bash
   kubectl rollout pause deployment/web
   ```
2. Apply multiple template changes:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5
   kubectl set resources deployment/web -c nginx --limits=cpu=200m,memory=256Mi
   ```
3. Confirm Pods remain unchanged while paused:
   ```bash
   kubectl get pods -l app=web
   ```
4. Resume rollout applying all changes in a single revision:
   ```bash
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   ```

**Comprehension Questions**
- What performance benefit does pausing provide before applying multiple modifications?
- Does `kubectl rollout status` report progress while paused?

---

## Exercise 12 — Teardown

1. Delete Deployment:
   ```bash
   kubectl delete deployment web
   ```
2. Delete namespace:
   ```bash
   kubectl delete namespace deploy-lab
   ```
3. Reset context namespace back to `default`:
   ```bash
   kubectl config set-context --current --namespace=default
   ```

**Comprehension Questions**
- When deleting a Deployment, what happens to its ReplicaSets and Pods?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- Setting default namespace in context avoids repeating `-n deploy-lab` on every command.
- `kubectl config set-context --current --namespace=default`.

**Exercise 2**
- `kubectl apply` computes declarative diffs idempotently. `kubectl create` fails if resources exist.
- `revisionHistoryLimit` controls retained historical ReplicaSet counts available for rollbacks.

**Exercise 3**
- ReplicaSet creates and manages Pods. Deployments manage ReplicaSets.
- `pod-template-hash` is computed from template specs. Template changes generate new hash values and ReplicaSets.

**Exercise 4**
- No. Scaling alters replica targets on existing ReplicaSets without changing `pod template` specs.

**Exercise 5**
- No. Rolling updates replace Pods incrementally adhering to `maxUnavailable`/`maxSurge` limits to ensure continuous availability.
- `kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}'`.

**Exercise 6**
- Peak count is 7 Pods (`replicas: 6` + `maxSurge: 1`).
- High `maxSurge` and `maxUnavailable` values increase rollout speed at the expense of temporary resource usage spikes.

**Exercise 7**
- `--revision=N` displays full pod template specs (image, labels, resources) for that revision.
- `CHANGE-CAUSE` column displays `<none>`.

**Exercise 8**
- Rolling update strategies preserve old Pods until new Pods pass readiness checks.
- `ErrImagePull` followed by `ImagePullBackOff`.

**Exercise 9**
- Creates a new incremental revision number matching target revision specs.
- Rollbacks fail if target revision ReplicaSets were purged.

**Exercise 10**
- `--to-revision` skips intermediate failed revisions, reverting directly to a known stable revision.

**Exercise 11**
- Prevents generating multiple intermediate rollouts and ReplicaSets, consolidating changes into one revision.
- No. `kubectl rollout status` reports no active rollout while paused.

**Exercise 12**
- Garbage collection cascades: deleting Deployments deletes owned ReplicaSets, which deletes owned Pods.

</details>
