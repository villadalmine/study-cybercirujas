# CKAD 1.35 — Domain 1.2: Choose and Use the Right Workload Resource

**Exam weight:** 5
**Reference:** [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

These guided exercises build hands-on fluency with the workload resources a CKAD candidate must pick between: `Deployment`, `ReplicaSet`, `DaemonSet`, `Job`, `CronJob`, and `StatefulSet`. Run every step yourself against a real cluster (`kind`, `minikube`, or any cluster you have `kubectl` access to) — reading the steps is not a substitute for typing them.

---

## Exercise 1 — Deployment: the default for stateless, long-running apps

1. Create a namespace to keep this exercise isolated:
   ```bash
   kubectl create namespace workloads
   kubectl config set-context --current --namespace=workloads
   ```
2. Create a Deployment imperatively, running 3 replicas of `nginx`:
   ```bash
   kubectl create deployment web --image=nginx:1.25 --replicas=3
   ```
3. Inspect the object hierarchy it created:
   ```bash
   kubectl get deployment,replicaset,pod -o wide
   ```
4. Trigger a rolling update by changing the image:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27
   kubectl rollout status deployment/web
   ```
5. Check the rollout history and undo it:
   ```bash
   kubectl rollout history deployment/web
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   ```

**Check your understanding:**
- After step 4, how many ReplicaSets exist for `web`, and what happened to the pods from the old one?
- What field on the Deployment controls how many old ReplicaSets are kept in history for rollback?
- Why does a Deployment manage a ReplicaSet instead of managing Pods directly?

---

## Exercise 2 — Scaling and self-healing

1. Scale the Deployment up:
   ```bash
   kubectl scale deployment/web --replicas=5
   kubectl get pods -w
   ```
   Press `Ctrl+C` once you see 5 pods `Running`.
2. Delete one pod manually:
   ```bash
   kubectl delete pod -l app=web --field-selector=status.phase=Running --wait=false $(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
   ```
   (Simpler: `kubectl delete pod <one-pod-name>`.)
3. Immediately list pods again:
   ```bash
   kubectl get pods -l app=web
   ```

**Check your understanding:**
- Why does a new pod appear even though you never told anything to "recreate" it? Which controller is actually watching and reconciling — the Deployment or the ReplicaSet?
- If you had deleted the Deployment instead of a Pod, what would have happened to the ReplicaSet and Pods?

---

## Exercise 3 — DaemonSet: one pod per node

1. Check how many nodes your cluster has:
   ```bash
   kubectl get nodes
   ```
2. Create a DaemonSet manifest, `log-agent-ds.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: log-agent
     namespace: workloads
   spec:
     selector:
       matchLabels:
         app: log-agent
     template:
       metadata:
         labels:
           app: log-agent
       spec:
         containers:
         - name: log-agent
           image: busybox:1.36
           command: ["sh", "-c", "sleep 3600"]
   ```
3. Apply it and compare the pod count to the node count:
   ```bash
   kubectl apply -f log-agent-ds.yaml
   kubectl get daemonset log-agent
   kubectl get pods -l app=log-agent -o wide
   ```
4. Cordon one node (if your cluster has more than one) and observe:
   ```bash
   kubectl cordon <node-name>
   kubectl get pods -l app=log-agent -o wide
   ```

**Check your understanding:**
- Why is `replicas` never a field on a DaemonSet spec?
- After cordoning a node, does the existing DaemonSet pod on that node get evicted? What does cordoning actually prevent?
- Name two real-world use cases where a DaemonSet is the correct choice over a Deployment.

---

## Exercise 4 — Job: run-to-completion workloads

1. Create a Job manifest, `data-import-job.yaml`:
   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: data-import
     namespace: workloads
   spec:
     completions: 3
     parallelism: 2
     backoffLimit: 2
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: importer
           image: busybox:1.36
           command: ["sh", "-c", "echo importing batch $RANDOM; sleep 5"]
   ```
2. Apply it and watch the pods:
   ```bash
   kubectl apply -f data-import-job.yaml
   kubectl get pods -l job-name=data-import -w
   ```
   Press `Ctrl+C` once all 3 have completed.
3. Check the Job's final status:
   ```bash
   kubectl get job data-import
   kubectl describe job data-import
   ```
4. Force a failure to observe `backoffLimit`: create a second Job that always exits non-zero:
   ```bash
   kubectl create job always-fail --image=busybox:1.36 -- sh -c "exit 1"
   kubectl get pods -l job-name=always-fail -w
   ```
   Press `Ctrl+C` after a few retries.

**Check your understanding:**
- With `completions: 3` and `parallelism: 2`, at most how many pods run at the same time, and why isn't it 3?
- Why is `restartPolicy: Never` (or `OnFailure`) required for a Job's pod template, and what happens if you set `Always`?
- What eventually happens to `always-fail`'s pods once `backoffLimit` is exceeded — does the Job keep retrying forever?

---

## Exercise 5 — CronJob: scheduled Jobs

1. Create a CronJob that runs every minute:
   ```bash
   kubectl create cronjob hello-cron --image=busybox:1.36 --schedule="*/1 * * * *" -- sh -c "date; echo hello"
   ```
2. Wait about 2 minutes, then list the Jobs it spawned:
   ```bash
   kubectl get cronjob hello-cron
   kubectl get jobs --selector=cronjob-name=hello-cron 2>/dev/null || kubectl get jobs
   ```
3. Inspect the logs of the most recent run:
   ```bash
   kubectl logs -l job-name=$(kubectl get jobs -o jsonpath='{.items[-1:].metadata.name}')
   ```
4. Suspend the CronJob so it stops scheduling new runs:
   ```bash
   kubectl patch cronjob hello-cron -p '{"spec":{"suspend":true}}'
   ```
5. Trigger one ad-hoc run from the CronJob's template, independent of the schedule:
   ```bash
   kubectl create job hello-manual --from=cronjob/hello-cron
   kubectl logs -l job-name=hello-manual
   ```

**Check your understanding:**
- What is the relationship between a CronJob, the Jobs it creates, and the Pods those Jobs create — three levels or two?
- Which fields on the CronJob spec cap how many old completed/failed Jobs are kept around?
- After `suspend: true`, does the currently running Job (if any) get killed, or does it just stop scheduling *future* runs?

---

## Exercise 6 — Choosing the right resource (decision exercise)

For each scenario below, decide which workload resource is the correct fit **before** checking the answers: `Deployment`, `DaemonSet`, `Job`, `CronJob`, or `StatefulSet`.

1. A stateless REST API that must always have 4 replicas running and support zero-downtime rolling updates.
2. A log-shipping agent (like Fluentd) that must run exactly once on every node in the cluster, including new nodes as they join.
3. A nightly database backup that runs at 02:00 and must not overlap with the previous run if it's still going.
4. A one-off database schema migration that must run to completion exactly once before the app starts.
5. A 3-node etcd-like cluster where each member needs a stable network identity (`etcd-0`, `etcd-1`, `etcd-2`) and its own persistent volume that survives pod rescheduling.

**Check your understanding:**
- For scenario 5, what would break if you used a Deployment with a shared PersistentVolumeClaim instead of a StatefulSet?
- For scenario 3, which CronJob field controls the "must not overlap" requirement?

---

## Cleanup

```bash
kubectl delete namespace workloads
kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- After the rolling update, **two** ReplicaSets exist: the new one (scaled to 3, matching current replicas) and the old one (scaled to 0, kept for rollback history). The old pods are terminated as the new ReplicaSet's pods become Ready, following the `RollingUpdate` strategy (`maxSurge`/`maxUnavailable`).
- `spec.revisionHistoryLimit` (default `10`) controls how many old ReplicaSets are retained.
- A Deployment delegates replica management to a ReplicaSet so that rolling updates can work by creating a *new* ReplicaSet and scaling it up while scaling the old one down — this gives Deployments rollback history and controlled, incremental rollout, which a bare set of Pods or a single ReplicaSet cannot provide on its own.

### Exercise 2
- The **ReplicaSet** is the controller actually watching the desired-replica count and creating a replacement Pod; the Deployment only manages the ReplicaSet, not Pods directly.
- Deleting the Deployment triggers garbage collection of its owned ReplicaSet(s) and, transitively, their Pods (via `ownerReferences`), unless you delete with `--cascade=orphan`.

### Exercise 3
- DaemonSet has no `replicas` field because its scale is derived automatically from the number of (matching) nodes — one pod per eligible node, growing and shrinking as nodes join or leave.
- Cordoning (`kubectl cordon`) only marks a node `Unschedulable=true`, which prevents **new** pods from being scheduled there; it does **not** evict existing pods, so the DaemonSet pod keeps running. (`kubectl drain` would evict it — but DaemonSet pods tolerate drain by default and get recreated immediately unless you pass `--ignore-daemonsets` is false... actually drain requires `--ignore-daemonsets` to proceed at all, and the DaemonSet pod is simply skipped/left running.)
- Examples: log/metrics collection agents (Fluentd, Filebeat), node-level monitoring (node-exporter), CNI/CSI node plugins, or a security agent that must be present on every node.

### Exercise 4
- At most **2** pods run concurrently — that's what `parallelism: 2` caps at, even though `completions: 3` is the total needed. The Job schedules a 3rd pod only after one of the first two finishes.
- `restartPolicy: Never`/`OnFailure` is required because a Job pod is expected to terminate (successfully or not) — `Always` is for long-running workloads and is rejected/invalid for Job pod templates since it conflicts with the run-to-completion model.
- Once `backoffLimit` (2 in this case, meaning up to 2 retries after the first failure = 3 attempts total) is exceeded, the Job is marked `Failed` and stops creating new pods — it does not retry forever.

### Exercise 5
- Three levels: **CronJob → Job → Pod**. The CronJob creates a new Job object on each scheduled tick, and that Job creates Pod(s) exactly like a standalone Job would.
- `spec.successfulJobsHistoryLimit` and `spec.failedJobsHistoryLimit` cap retained Job objects (defaults: 3 and 1).
- `suspend: true` only stops **future** scheduling; any Job/Pod that is already running at the time you suspend continues running to completion (or failure) unaffected.

### Exercise 6
1. **Deployment** — stateless, replica-based, needs rolling updates.
2. **DaemonSet** — exactly one pod per node, automatically adjusts to cluster membership.
3. **CronJob** — time-based schedule with a non-overlap requirement.
4. **Job** — run-to-completion, exactly once, no schedule.
5. **StatefulSet** — stable identity + per-replica persistent storage.

- With a Deployment + shared PVC, all replicas would (depending on access mode) either fight over the same volume or fail to mount `ReadWriteOnce` storage from multiple nodes simultaneously; pods also get random names/IPs on reschedule instead of stable, ordinal identities (`etcd-0`, etc.) that peers can address reliably.
- `spec.concurrencyPolicy` (set to `Forbid` to disallow overlap; `Replace` to cancel the still-running job and start a new one; `Allow` — the default — permits overlap).

</details>