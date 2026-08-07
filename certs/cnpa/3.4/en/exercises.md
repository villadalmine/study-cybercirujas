# Incident Response and Remediation in Platform Engineering — Guided Exercises

**Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
**Domain 3, Topic 3.4** · Exam weight: 2.3
**Reference syllabus:** [CNPA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

> **Scope of these exercises.** You will walk the full incident lifecycle the way a platform team lives it: **detect → triage → diagnose → mitigate → remediate → learn**. The lab uses vanilla Kubernetes plus the CNCF observability stack (Prometheus, Alertmanager) and GitOps (Argo CD). Every manifest is complete and syntactically valid; every command is real and paired with the output you should expect.
>
> **Prerequisites.** A working cluster (`kind`, `minikube`, k3s, or any conformant cluster) with `kubectl` v1.29+, cluster-admin on a throwaway namespace, and — for Exercises 3 and 4 — the Prometheus Operator and Argo CD installed. If you lack either, the steps still teach the mechanics; the questions do not depend on the addons being live.
>
> Create the shared namespace once:
>
> ```bash
> kubectl create namespace incident-lab
> kubectl config set-context --current --namespace=incident-lab
> ```

---

## Exercise 1 — Detection and triage: reading the signals

**Goal:** Distinguish the two most common pod-level failure modes a platform on-call sees — `CrashLoopBackOff` from an application error versus a resource-limit `OOMKilled` — using only the Kubernetes API as your first-line evidence.

1. Deploy a workload guaranteed to exceed its own memory limit. Save as `memory-hog.yaml` and apply it:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: memory-hog
     namespace: incident-lab
     labels:
       app: memory-hog
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: memory-hog
     template:
       metadata:
         labels:
           app: memory-hog
       spec:
         containers:
         - name: hog
           image: polinux/stress:1.0.4
           command: ["stress"]
           # Allocates 250 MiB, but the limit below is 128Mi -> the kernel OOM-kills it.
           args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
           resources:
             requests:
               memory: "64Mi"
               cpu: "50m"
             limits:
               memory: "128Mi"
               cpu: "100m"
   ```

   ```bash
   kubectl apply -f memory-hog.yaml
   ```

2. Watch the pod cycle. Leave this running for ~60 seconds, then Ctrl-C:

   ```bash
   kubectl get pod -l app=memory-hog -w
   ```

   Expected transitions:

   ```
   NAME                          READY   STATUS      RESTARTS   AGE
   memory-hog-6c9f7d8b5c-abcde   0/1     Pending     0          0s
   memory-hog-6c9f7d8b5c-abcde   0/1     ContainerCreating   0   2s
   memory-hog-6c9f7d8b5c-abcde   0/1     OOMKilled   0          6s
   memory-hog-6c9f7d8b5c-abcde   0/1     CrashLoopBackOff   1   18s
   memory-hog-6c9f7d8b5c-abcde   0/1     OOMKilled   2          40s
   ```

3. Read the container's *last termination state* — this is where the kernel's verdict is recorded:

   ```bash
   kubectl describe pod -l app=memory-hog
   ```

   Focus on the `Last State` block:

   ```
       State:          Waiting
         Reason:       CrashLoopBackOff
       Last State:     Terminated
         Reason:       OOMKilled
         Exit Code:    137
         Started:      Fri, 07 Aug 2026 14:22:03 +0000
         Finished:     Fri, 07 Aug 2026 14:22:04 +0000
       Restart Count:  2
   ```

4. Pull the exit code out programmatically — this is the shape you would put in a runbook or an automated triage script:

   ```bash
   kubectl get pod -l app=memory-hog \
     -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}{" "}{.items[0].status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
   ```

   ```
   OOMKilled 137
   ```

5. Try to read the crashed container's logs. Note the failure, then read the *previous* instance's logs:

   ```bash
   kubectl logs -l app=memory-hog                 # current container may not have started yet
   kubectl logs -l app=memory-hog --previous      # -p: the last terminated container
   ```

6. Get the cluster-level event stream, newest last, and filter to the object. Events are your timeline source of truth for the next exercises:

   ```bash
   kubectl get events --sort-by='.lastTimestamp' --field-selector involvedObject.kind=Pod
   ```

   ```
   LAST SEEN   TYPE      REASON      OBJECT                            MESSAGE
   45s         Normal    Scheduled   pod/memory-hog-6c9f7d8b5c-abcde   Successfully assigned incident-lab/... to node-1
   43s         Normal    Pulled      pod/memory-hog-6c9f7d8b5c-abcde   Container image "polinux/stress:1.0.4" already present on machine
   18s         Warning   BackOff     pod/memory-hog-6c9f7d8b5c-abcde   Back-off restarting failed container hog
   ```

> **Comprehension check 1**
> 1. What does exit code **137** mean, and how is it composed? Why is it a strong signal of `OOMKilled` even before you read the `Reason` field?
> 2. The pod shows `Reason: OOMKilled` but `STATUS: CrashLoopBackOff`. These are not contradictory — explain what each field is describing.
> 3. In the manifest, which single field decides whether the kernel kills this container: `requests.memory` or `limits.memory`? What does the *other* field control?
> 4. Why is `kubectl logs --previous` the correct command here, and what would plain `kubectl logs` have shown you during a `CrashLoopBackOff`?
> 5. `BackOff` appears as a `Warning` event, not the OOM kill itself. Why does the OOM kill not appear as a Kubernetes event at all, and where *is* it recorded?

---

## Exercise 2 — Live diagnosis with ephemeral containers and node debug

**Goal:** Diagnose a running workload that ships as a **distroless** image (no shell, no `ps`, no `curl`) — the modern production default — without rebuilding it or `exec`-ing tools that do not exist. This is the platform team's paved-road answer to "the app team can't debug their own hardened container."

1. Deploy a healthy distroless workload:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: distroless-api
     namespace: incident-lab
   spec:
     replicas: 1
     selector:
       matchLabels: { app: distroless-api }
     template:
       metadata:
         labels: { app: distroless-api }
       spec:
         containers:
         - name: api
           image: gcr.io/distroless/static-debian12:nonroot
           command: ["/bin/sh"]          # intentionally wrong: there is no shell
           args: ["-c", "sleep 3600"]
   ```

   Apply it, then confirm it fails to start because the image has no `/bin/sh`:

   ```bash
   kubectl apply -f distroless.yaml
   kubectl get pod -l app=distroless-api
   kubectl describe pod -l app=distroless-api | grep -A2 'Last State'
   ```

   ```
       Last State:     Terminated
         Reason:       StartError
         Message:      failed to create containerd task: ... exec: "/bin/sh": stat /bin/sh: no such file or directory
   ```

2. Fix the command so the container runs (distroless `static` has no shell, so run a long-lived no-op binary via the app itself; for the lab, switch to the `busybox`-free approach of a valid entrypoint):

   ```bash
   kubectl set image deployment/distroless-api api=registry.k8s.io/pause:3.9
   kubectl patch deployment distroless-api --type=json \
     -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"},
          {"op":"remove","path":"/spec/template/spec/containers/0/args"}]'
   kubectl rollout status deployment/distroless-api
   ```

3. Now the container runs but you cannot exec into it — `pause` has no shell either. Attach an **ephemeral debug container** that shares the target's process namespace:

   ```bash
   POD=$(kubectl get pod -l app=distroless-api -o jsonpath='{.items[0].metadata.name}')
   kubectl debug -it "$POD" \
     --image=busybox:1.36 \
     --target=api \
     -- sh
   ```

   Inside the ephemeral container, inspect the *target's* filesystem and processes:

   ```sh
   / # ps aux                     # visible because --target shares the PID namespace
   PID   USER     COMMAND
   1     65532    /pause
   14    root     sh
   / # ls /proc/1/root/           # the target container's root filesystem
   / # cat /proc/1/status | grep -i vmrss
   / # exit
   ```

4. Confirm the ephemeral container was recorded on the pod (it is appended, never restarts the pod, and cannot be removed):

   ```bash
   kubectl get pod "$POD" -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
   ```

   ```
   debugger-7x2kq
   ```

5. Debug at the **node** level — for kubelet, container-runtime, or kernel problems that no pod can see. This launches a privileged pod that mounts the node's root filesystem at `/host`:

   ```bash
   NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')
   kubectl debug node/"$NODE" -it --image=busybox:1.36 -- sh
   ```

   ```sh
   / # chroot /host
   # journalctl -u kubelet --no-pager | tail -n 20
   # crictl ps | head
   # df -h /var/lib/kubelet
   # exit
   ```

> **Comprehension check 2**
> 1. Why can an **ephemeral container** debug a distroless pod when `kubectl exec` cannot? Name two things about ephemeral containers that make them safe to add to a *running production* pod.
> 2. What does `--target=api` change compared to omitting it? What must be true about the pod (or the ephemeral container's config) for `ps aux` to see PID 1 of the target?
> 3. You added an ephemeral container by mistake with the wrong image. How do you remove it from the running pod? What does that tell you about using this on a customer-facing pod?
> 4. `kubectl debug node/<node>` gives you `/host`. Why is `chroot /host` (or reading under `/host`) necessary, and what class of incidents does node debug reach that pod-level debug never can?
> 5. From a platform-engineering standpoint, why is standardizing on distroless images *and* documenting `kubectl debug` a better paved road than shipping every image with a shell and a debug toolset baked in?

---

## Exercise 3 — From signal to page: SLO burn-rate alerting

**Goal:** Build an alert that pages a human only when the **error budget** is burning fast enough to matter — the multi-window, multi-burn-rate pattern from the Google SRE Workbook — and route it through Alertmanager with inhibition and silences. This is what turns raw metrics into a *right-sized* incident.

*Assumes the Prometheus Operator is installed and a request-counter metric `http_requests_total{job="checkout",code=~"5.."}` exists. Substitute your own service/metric names as needed.*

1. Define recording rules and a two-tier burn-rate alert for a **99.9% availability SLO**. Save as `slo-rules.yaml`:

   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: checkout-slo
     namespace: incident-lab
     labels:
       release: prometheus        # must match the operator's ruleSelector
   spec:
     groups:
     - name: checkout-slo.rules
       interval: 30s
       rules:
       # Error ratio pre-computed over each window we alert on.
       - record: job:slo_errors_per_request:ratio_rate5m
         expr: |
           sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
             /
           sum(rate(http_requests_total{job="checkout"}[5m]))
       - record: job:slo_errors_per_request:ratio_rate1h
         expr: |
           sum(rate(http_requests_total{job="checkout",code=~"5.."}[1h]))
             /
           sum(rate(http_requests_total{job="checkout"}[1h]))
       - record: job:slo_errors_per_request:ratio_rate6h
         expr: |
           sum(rate(http_requests_total{job="checkout",code=~"5.."}[6h]))
             /
           sum(rate(http_requests_total{job="checkout"}[6h]))
     - name: checkout-slo.alerts
       rules:
       # FAST burn: 14.4x budget consumption. Two windows (5m AND 1h) must agree.
       # 14.4x over 1h exhausts ~2% of a 30-day budget -> page now.
       - alert: CheckoutErrorBudgetFastBurn
         expr: |
           job:slo_errors_per_request:ratio_rate5m > (14.4 * 0.001)
           and
           job:slo_errors_per_request:ratio_rate1h > (14.4 * 0.001)
         for: 2m
         labels:
           severity: page
           slo: checkout-availability
         annotations:
           summary: "Checkout burning error budget 14.4x (fast)"
           runbook_url: "https://runbooks.internal/checkout/error-budget-fast-burn"
       # SLOW burn: 6x consumption. Wider windows (30m AND 6h) -> ticket, not a 3am page.
       - alert: CheckoutErrorBudgetSlowBurn
         expr: |
           job:slo_errors_per_request:ratio_rate6h > (6 * 0.001)
         for: 15m
         labels:
           severity: ticket
           slo: checkout-availability
         annotations:
           summary: "Checkout burning error budget 6x (slow)"
           runbook_url: "https://runbooks.internal/checkout/error-budget-slow-burn"
   ```

   ```bash
   kubectl apply -f slo-rules.yaml
   ```

2. Confirm Prometheus loaded the rules and evaluate the recorded ratio. Port-forward and query:

   ```bash
   kubectl -n monitoring port-forward svc/prometheus-operated 9090 &
   curl -s 'http://localhost:9090/api/v1/rules' | jq '.data.groups[].name'
   curl -s --data-urlencode 'query=job:slo_errors_per_request:ratio_rate5m' \
     http://localhost:9090/api/v1/query | jq '.data.result'
   ```

3. Configure Alertmanager routing so `severity: page` goes to the pager and `severity: ticket` goes to a queue, and add an **inhibition** so a fast burn suppresses the slow-burn noise. Save as `alertmanager.yaml`:

   ```yaml
   route:
     receiver: default
     group_by: ['slo', 'namespace']
     group_wait: 30s
     group_interval: 5m
     repeat_interval: 4h
     routes:
     - matchers: [ 'severity="page"' ]
       receiver: pagerduty
       continue: false
     - matchers: [ 'severity="ticket"' ]
       receiver: ticket-queue
   receivers:
   - name: default
   - name: pagerduty
     pagerduty_configs:
     - routing_key: <your-integration-key>
   - name: ticket-queue
     webhook_configs:
     - url: http://ticketing.internal/hook
   inhibit_rules:
   # A fast burn (page) silences the slow burn (ticket) for the same SLO.
   - source_matchers: [ 'severity="page"' ]
     target_matchers: [ 'severity="ticket"' ]
     equal: ['slo']
   ```

4. During a *planned* maintenance you do not want to be paged. Create a time-boxed **silence** with `amtool`:

   ```bash
   kubectl -n monitoring port-forward svc/alertmanager-operated 9093 &
   amtool --alertmanager.url=http://localhost:9093 silence add \
     slo=checkout-availability \
     --duration=1h \
     --comment="Planned checkout DB failover — INC-4471" \
     --author="oncall@platform"
   amtool --alertmanager.url=http://localhost:9093 silence query
   ```

> **Comprehension check 3**
> 1. Compute the error budget: for a **99.9%** availability SLO over a 30-day window, how many minutes of "down" (or equivalent failed requests) does the budget allow? Show the arithmetic.
> 2. Why does the fast-burn alert require **both** the 5m *and* the 1h window to exceed the threshold (`and`), instead of just the short window? What failure mode of single-window alerting does this eliminate?
> 3. Where does the number **14.4** come from? What does "14.4x burn rate" mean in plain terms about how fast the 30-day budget is being consumed?
> 4. Contrast **inhibition** with a **silence**: which one is a standing rule encoded in config, which one is an ad-hoc time-boxed mute, and which is the right tool for a planned maintenance window?
> 5. Fast burn pages (`severity: page`); slow burn only tickets (`severity: ticket`). Justify this in terms of on-call human cost and the difference between "the budget will be gone in an hour" and "the budget will be gone in four days."

---

## Exercise 4 — Mitigation and remediation: rollback strategies

**Goal:** Stop the bleeding first (mitigate), then fix it correctly (remediate). You will roll back a bad deploy two ways — the imperative `kubectl rollout undo` for the 3am case, and the GitOps `git revert` for the durable fix — and understand why a platform standardizes on the second.

1. Deploy a known-good v1 and record the rollout so revisions carry a change-cause:

   ```bash
   kubectl create deployment web --image=nginx:1.27.0 --replicas=3
   kubectl annotate deployment/web kubernetes.io/change-cause="v1: nginx 1.27.0 baseline"
   kubectl rollout status deployment/web
   ```

2. Ship a bad v2 (a tag that will `ImagePullBackOff`), with a rollout guard so the platform notices the deploy is stuck:

   ```bash
   kubectl patch deployment/web -p '{"spec":{"progressDeadlineSeconds":60}}'
   kubectl set image deployment/web nginx=nginx:9.99.0-does-not-exist
   kubectl annotate deployment/web kubernetes.io/change-cause="v2: bump to 9.99.0 (BAD)" --overwrite
   ```

3. Observe the rollout fail to progress. `kubectl rollout status` returns non-zero when `progressDeadlineSeconds` is exceeded — this is the signal a CD pipeline should gate on:

   ```bash
   kubectl rollout status deployment/web --timeout=90s ; echo "exit=$?"
   ```

   ```
   Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
   error: deployment "web" exceeded its progress deadline
   exit=1
   ```

   Confirm the surviving old replicas are still serving — the rolling update *mitigated itself* by not tearing down healthy pods:

   ```bash
   kubectl get pods -l app=web
   ```

   ```
   NAME                   READY   STATUS             RESTARTS   AGE
   web-5c8d7f9b6-aaaaa    1/1     Running            0          4m     # old ReplicaSet
   web-5c8d7f9b6-bbbbb    1/1     Running            0          4m
   web-6f4b2c1a7-ccccc    0/1     ImagePullBackOff   0          70s    # new ReplicaSet
   ```

4. Inspect revision history, then **roll back** to the previous revision:

   ```bash
   kubectl rollout history deployment/web
   ```

   ```
   REVISION  CHANGE-CAUSE
   1         v1: nginx 1.27.0 baseline
   2         v2: bump to 9.99.0 (BAD)
   ```

   ```bash
   kubectl rollout undo deployment/web              # back to the immediately-previous revision
   # or target explicitly:  kubectl rollout undo deployment/web --to-revision=1
   kubectl rollout status deployment/web
   ```

   ```
   deployment "web" successfully rolled out
   ```

5. **The durable fix — GitOps.** In a GitOps world the cluster is not the source of truth; Git is. An imperative `kubectl rollout undo` will be *reverted back to the broken state* by the controller on its next sync, because Git still says v2. The correct remediation is to revert the commit:

   ```bash
   # In the config repo that Argo CD / Flux watches:
   git revert <sha-of-the-v2-bump> --no-edit
   git push
   # Argo CD detects OutOfSync and re-syncs the cluster to the reverted manifest:
   argocd app sync web
   argocd app history web
   ```

   ```
   ID  DATE                 REVISION
   0   2026-08-07 13:40 UTC  a1b2c3d (v1 baseline)
   1   2026-08-07 14:05 UTC  d4e5f6a (v2 BAD)
   2   2026-08-07 14:12 UTC  b7c8d9e (revert of v2)
   ```

> **Comprehension check 4**
> 1. What object actually stores the "previous version" that `kubectl rollout undo` restores? How does `revisionHistoryLimit` bound your ability to roll back, and what is its default?
> 2. During step 3, two old pods kept `Running` while the new ones failed. Which two Deployment `strategy` fields produced that behavior, and what would `maxUnavailable: 0` have guaranteed?
> 3. Why did `kubectl rollout status` return **exit code 1**, and why is `progressDeadlineSeconds` the field a CD pipeline should key its automated rollback on rather than a fixed `sleep`?
> 4. In a GitOps setup, why is `kubectl rollout undo` a *trap* as a permanent fix? Describe the exact sequence by which the controller would undo your undo.
> 5. Both `kubectl rollout undo` and `git revert` are valid. State the one situation where you would reach for the imperative command *first*, and what you must do immediately afterward to avoid config drift.

---

## Exercise 5 — Automated remediation and self-healing

**Goal:** Reduce human toil by letting the platform heal itself for the failure classes that do not need judgment. You will make a workload self-restart on a hung process (probes), protect availability during voluntary disruptions (PodDisruptionBudget), and see how these become the first line of defense that keeps the pager quiet.

1. Deploy a workload with the three probe types correctly separated:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: resilient-api
     namespace: incident-lab
   spec:
     replicas: 3
     selector:
       matchLabels: { app: resilient-api }
     template:
       metadata:
         labels: { app: resilient-api }
       spec:
         containers:
         - name: api
           image: registry.k8s.io/e2e-test-images/agnhost:2.47
           args: ["netexec", "--http-port=8080"]
           ports:
           - containerPort: 8080
           # startupProbe: gives a slow starter up to 30s before liveness kicks in.
           startupProbe:
             httpGet: { path: /healthz, port: 8080 }
             failureThreshold: 30
             periodSeconds: 1
           # livenessProbe: restart the container if the process is hung (not merely busy).
           livenessProbe:
             httpGet: { path: /healthz, port: 8080 }
             periodSeconds: 10
             failureThreshold: 3
           # readinessProbe: remove from Service endpoints while unable to serve.
           readinessProbe:
             httpGet: { path: /healthz, port: 8080 }
             periodSeconds: 5
             failureThreshold: 2
           resources:
             requests: { cpu: 50m, memory: 64Mi }
             limits:   { cpu: 200m, memory: 128Mi }
   ```

   ```bash
   kubectl apply -f resilient.yaml
   kubectl rollout status deployment/resilient-api
   ```

2. Break liveness on purpose and watch Kubernetes self-heal via restart. `agnhost` lets you flip the health endpoint:

   ```bash
   POD=$(kubectl get pod -l app=resilient-api -o jsonpath='{.items[0].metadata.name}')
   # Tell the app to start failing /healthz:
   kubectl exec "$POD" -- /agnhost fake-gce-metadata >/dev/null 2>&1 || true
   kubectl exec "$POD" -- sh -c 'curl -s "http://localhost:8080/healthz?code=500" || true'
   kubectl get pod "$POD" -w
   ```

   Expected: after 3 consecutive liveness failures (~30s) the container `RESTARTS` count increments while the pod stays `Running` — the platform remediated without a human.

   ```
   NAME                             READY   STATUS    RESTARTS      AGE
   resilient-api-7d9c...-x1        0/1     Running   0             2m
   resilient-api-7d9c...-x1        0/1     Running   1 (2s ago)    2m40s
   resilient-api-7d9c...-x1        1/1     Running   1 (12s ago)   2m50s
   ```

3. Protect availability during a **voluntary** disruption. Create a PodDisruptionBudget, then drain the node and watch the PDB block the last eviction:

   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: resilient-api-pdb
     namespace: incident-lab
   spec:
     minAvailable: 2
     selector:
       matchLabels: { app: resilient-api }
   ```

   ```bash
   kubectl apply -f pdb.yaml
   NODE=$(kubectl get pod -l app=resilient-api -o jsonpath='{.items[0].spec.nodeName}')
   kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
   ```

   ```
   evicting pod incident-lab/resilient-api-7d9c...-x1
   error when evicting pods/"resilient-api-7d9c...-x9" -n "incident-lab" (will retry):
     Cannot evict pod as it would violate the pod's disruption budget.
   ```

4. Confirm the PDB's current allowance and clean up:

   ```bash
   kubectl get pdb resilient-api-pdb
   ```

   ```
   NAME                MIN AVAILABLE   ALLOWED DISRUPTIONS   AGE
   resilient-api-pdb   2               1                     3m
   ```

   ```bash
   kubectl uncordon "$NODE"
   ```

> **Comprehension check 5**
> 1. Precisely distinguish **livenessProbe**, **readinessProbe**, and **startupProbe**: what remediation action does each *trigger*, and which one removes a pod from Service load-balancing without restarting it?
> 2. A team sets `livenessProbe` too aggressively (short `periodSeconds`, low `failureThreshold`) on a service that is merely *slow* under load. Describe the exact self-inflicted incident this causes and why it makes an overload *worse*.
> 3. In step 3 the drain was blocked. Distinguish a **voluntary** disruption from an **involuntary** one, and state exactly which of the two a PodDisruptionBudget protects against.
> 4. With `minAvailable: 2` on 3 replicas, `ALLOWED DISRUPTIONS` is 1. Compute what it would be with `minAvailable: 3`, and explain the operational deadlock that value creates for node maintenance.
> 5. Why are probes and PDBs described as the "first line" of self-healing, and where is their limit — name one incident class they cannot remediate and would still page a human?

---

## Exercise 6 — The blameless postmortem and root-cause analysis

**Goal:** Close the loop. Turn the evidence you gathered in Exercises 1–5 into a **blameless postmortem** with a defensible root cause, measured incident metrics, and action items that actually prevent recurrence. In platform engineering the postmortem is the artifact that converts an incident into durable reliability.

1. Reconstruct the timeline from hard evidence, not memory. Collect timestamped events across the incident window:

   ```bash
   kubectl get events --sort-by='.lastTimestamp' -A \
     -o custom-columns='TIME:.lastTimestamp,NS:.involvedObject.namespace,KIND:.involvedObject.kind,REASON:.reason,MSG:.message'
   ```

2. Fill in a timeline table (all times UTC). Use the real detect/mitigate/resolve moments:

   | Time (UTC) | Event | Source of truth |
   |---|---|---|
   | 14:02 | Bad image `nginx:9.99.0` deployed | `rollout history`, change-cause |
   | 14:03 | New ReplicaSet stuck `ImagePullBackOff` | `kubectl get events` |
   | 14:06 | `CheckoutErrorBudgetFastBurn` fires, on-call paged | Alertmanager |
   | 14:09 | On-call acknowledges page | PagerDuty |
   | 14:12 | Mitigated via `kubectl rollout undo` | `rollout history` |
   | 14:14 | Error ratio back under SLO threshold | Prometheus |
   | 14:30 | Durable fix: `git revert` merged & synced | Argo CD history |

3. Compute the incident metrics from the timeline:

   ```
   MTTD (detect)  = 14:06 - 14:03 =  3 min   (fault present -> alert fired)
   MTTA (ack)     = 14:09 - 14:06 =  3 min   (alert -> human acknowledges)
   MTTR (recover) = 14:14 - 14:03 = 11 min   (fault present -> service restored)
   ```

4. Run a **5-Whys** to separate the trigger from the root cause:

   ```
   Q: Why did checkout 5xx spike?        A: New pods never became Ready (ImagePullBackOff).
   Q: Why ImagePullBackOff?              A: Image tag nginx:9.99.0 does not exist in the registry.
   Q: Why was a non-existent tag shipped? A: A typo in the deploy PR; no CI step validates the tag pulls.
   Q: Why did CI not catch it?           A: The pipeline builds but never runs `docker manifest inspect` on the target tag.
   Q: Why no progressive rollout guard?  A: progressDeadlineSeconds was default; no automated rollback on stuck rollout.
   ```

5. Write action items that are specific, owned, and dated — and classify each as *prevent*, *detect*, or *mitigate*:

   | Action | Class | Owner | Due |
   |---|---|---|---|
   | Add `docker manifest inspect` gate to CI before merge | Prevent | @platform-ci | 2026-08-14 |
   | Set `progressDeadlineSeconds: 120` in the paved-road Helm chart | Mitigate | @platform-tmpl | 2026-08-12 |
   | Auto-rollback on failed `rollout status` in the CD job | Mitigate | @platform-cd | 2026-08-21 |
   | Add fast-burn alert to the checkout SLO (done — verify coverage) | Detect | @sre-checkout | 2026-08-10 |

> **Comprehension check 6**
> 1. What does **blameless** actually mean in a postmortem, and what concrete behavior change does it buy you at the *organizational* level (why do blameless cultures surface more, not fewer, incidents)?
> 2. Define **MTTD, MTTA, MTTR**. In the timeline above, why is MTTR measured from *fault onset* (14:03) rather than from the page (14:06)?
> 3. Distinguish the **trigger** of this incident from its **root cause**. Which line of the 5-Whys is the trigger, and which is the true root cause you would fix to prevent recurrence?
> 4. Two action items are classed **Mitigate** rather than **Prevent**. Argue why a mature platform ships *both* prevent- and mitigate-class items rather than betting everything on "never ship a bad image again."
> 5. Why must every action item have an **owner and a due date**, and what is the standard failure mode of postmortems that produce a list of good ideas without them?

---

## Answers

<details>
<summary>Click to reveal the answers to all comprehension checks</summary>

### Exercise 1

1. **137 = 128 + 9.** By POSIX convention a process killed by signal *N* exits with code `128 + N`; signal 9 is `SIGKILL`. When a container's memory cgroup hits its limit, the kernel OOM killer sends `SIGKILL`, so the container almost always exits `137`. Seeing `137` therefore strongly implies an OOM kill even before you read the `Reason` — though `137` can also come from any external `SIGKILL` (e.g. a liveness-probe kill), which is why you confirm with the `Reason` field.
2. `STATUS: CrashLoopBackOff` describes the **kubelet's restart backoff state right now** — it is waiting (with exponential backoff, capped at 5 min) before the next restart attempt. `Reason: OOMKilled` under `Last State` describes **why the previous run of the container terminated**. One is the present scheduling state; the other is the past cause of death. They coexist normally.
3. **`limits.memory` decides the kill.** The memory limit becomes the cgroup `memory.max`; exceeding it triggers the OOM killer. `requests.memory` does **not** cap usage — it is used by the scheduler to *place* the pod (reserving capacity on a node) and factors into the pod's QoS class and eviction ranking. Requests are about scheduling and priority; limits are about enforcement.
4. During `CrashLoopBackOff` the current container is usually *not running* (it is in backoff/terminated), so plain `kubectl logs` returns nothing useful or errors with "container ... is waiting to start." `--previous` (`-p`) reads the log of the **last terminated instance**, which holds the actual crash output.
5. The OOM kill is a **kernel/cgroup event on the node**, observed by the kubelet, not an API-server-native lifecycle transition — Kubernetes surfaces it in the container's `state.terminated.reason`, not as a `Warning` Event object. What *does* show up as an event is the kubelet's reaction: `BackOff` (restarting the failed container). The kill itself is recorded in the pod's `containerStatuses[].lastState.terminated` and in the node's kernel log (`dmesg` / `journalctl -k`). See [Assign Memory Resources](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/).

### Exercise 2

1. `kubectl exec` runs a binary that must already exist *inside* the target container's image; a distroless image has no shell or tools, so exec fails. An **ephemeral container** runs a *separate* image (e.g. `busybox`) inside the *same pod*, sharing the pod's network namespace and — with `--target` — the target container's PID namespace, so its tools operate on the target. Two safety properties: (a) adding one **does not restart** the pod or its existing containers; (b) ephemeral containers **have no resource guarantees and cannot be specified in a Deployment/pod template** — they are strictly a live-debug affordance, so they can't silently become part of the workload. See [Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pods/) and [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/).
2. `--target=api` puts the debug container into the **PID namespace of the `api` container**, so `ps` and `/proc/1` refer to the target's processes and root filesystem. Without it, the debug container sees only its own processes. Requirement: the container runtime must support process-namespace targeting (containerd/CRI-O do); alternatively the pod can set `shareProcessNamespace: true`.
3. **You cannot remove it.** Ephemeral containers are append-only on a pod's spec; to be rid of it you must delete and recreate the pod. Implication for a customer-facing pod: attaching debug tooling is non-destructive to the running process but leaves a permanent record on that pod object, and you'll eventually recreate the pod to clean up — plan the debug session accordingly.
4. `kubectl debug node/<node>` schedules a **privileged pod that bind-mounts the node's filesystem at `/host`**; the debug container's own root is still the busybox image, so you `chroot /host` (or read under `/host`) to act as if you were on the node. It reaches incidents *below* the pod boundary: kubelet/container-runtime failures, disk-pressure on `/var/lib/kubelet`, kernel logs, CNI/CSI plugin state, node-level `journalctl` — none of which any application pod can observe.
5. Distroless shrinks the attack surface and image size in production while `kubectl debug` restores full debuggability **on demand, without shipping tools you don't want present at runtime**. Baking a shell + toolset into every image means those tools are permanently available to an attacker and inflate every image; the paved road "hardened by default, debuggable on demand" gives you both security and operability — the platform team documents the one command instead of weakening every image.

### Exercise 3

1. Budget = `(1 − SLO) × window`. For 99.9% over 30 days: `0.001 × 30 days = 0.001 × 43,200 min = 43.2 minutes` of allowed downtime/failure per 30-day window. (Equivalently, 0.1% of all requests may fail.)
2. Requiring **both** windows eliminates **false positives from short spikes and false "all clear" from a long-window lag**. A single short (5m) window is trigger-happy — a 30-second blip pages you. A single long (1h) window is slow to fire *and* slow to reset. The `and` of a short and a long window means the alert fires only when the problem is both *severe right now* (5m) and *sustained* (1h), and it clears quickly once the short window recovers. This is the multi-window, multi-burn-rate pattern from the [Google SRE Workbook, Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/).
3. **14.4** is the burn rate chosen so that at that constant rate you would consume the entire 30-day budget in ~2 days — and, over the 1h alerting window, ~2% of the budget. The math: if you burn budget 14.4× faster than the "just barely meeting SLO" baseline, `30 days ÷ 14.4 ≈ 2.08 days` to exhaustion. "14.4x burn rate" means the error budget is being spent 14.4 times faster than the rate that would exactly exhaust it over the full window.
4. **Inhibition** is a *standing rule in Alertmanager config* — "when alert A is firing, automatically suppress alert B" (here: a page suppresses the redundant ticket for the same SLO). A **silence** is an *ad-hoc, time-boxed, matcher-based mute* created by a human (via UI or `amtool`) with an expiry and a comment. For a **planned maintenance window** the correct tool is a **silence** — it's temporary, attributable (author + comment/ticket), and auto-expires.
5. A page interrupts a human's sleep/focus and should be reserved for "act now or the budget/SLO is lost imminently." Fast burn (budget gone in ~hours) meets that bar. Slow burn (budget gone in ~days) is real but can wait for business hours — a ticket. Paging on slow burn trains on-call to ignore pages (alert fatigue) and wastes the scarcest resource: rested human attention. Right-sizing severity to time-to-exhaustion keeps the pager credible.

### Exercise 4

1. Rollback is stored in the **old ReplicaSet(s)** the Deployment controller keeps. Each revision corresponds to a ReplicaSet scaled to 0 that retains the previous pod template. `revisionHistoryLimit` (default **10**) caps how many old ReplicaSets are retained; set it to 0 and you keep *no* rollback history. See [Deployments — Rolling Back](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment).
2. `strategy.rollingUpdate.maxUnavailable` and `maxSurge`. The rolling update brings up new pods (`maxSurge`) before removing old ones and never lets availability drop below `replicas − maxUnavailable`; because the new pods never became Ready, the update stalled with the old pods still serving. `maxUnavailable: 0` guarantees **zero** old pods are removed until an equal number of new pods are Ready — the strongest availability guarantee (at the cost of needing surge capacity).
3. `kubectl rollout status` returns **exit 1** because the rollout **exceeded `progressDeadlineSeconds`** — the Deployment sets a `Progressing=False` condition with reason `ProgressDeadlineExceeded`. A CD pipeline should key automated rollback on this condition/exit code rather than a fixed `sleep` because it is *event-driven*: it fires exactly when Kubernetes concludes the rollout is not going to make progress, regardless of how long image pulls or readiness legitimately take.
4. In GitOps the **controller continuously reconciles the cluster to Git**. If you `kubectl rollout undo` while Git still declares v2, the controller sees the live state (v1) diverge from desired (v2), marks the app `OutOfSync`, and — on the next sync (auto-sync or manual) — **re-applies v2**, undoing your rollback. The durable fix must change Git (`git revert`) so desired state matches the good version.
5. Reach for imperative `kubectl rollout undo` **first when the service is actively down and every second of MTTR counts** — it is faster than a PR round-trip. Immediately afterward you must **land the corresponding `git revert` (and disable/pause auto-sync until it's merged if necessary)** so the controller doesn't reintroduce the bad state and the repo again matches reality — otherwise you've created config drift.

### Exercise 5

1. **livenessProbe** → on failure, the kubelet **restarts the container** (fix a hung/deadlocked process). **readinessProbe** → on failure, the pod is **removed from the Service's Endpoints** so it receives no traffic, but is **not restarted** (this is the one that de-loads without killing). **startupProbe** → gates the other two: until it succeeds, liveness/readiness are *not* run, giving slow-starting apps time to boot without being killed. See [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).
2. An over-aggressive liveness probe on a *slow-but-alive* service under load will time out, the kubelet kills and restarts the container, capacity drops during the restart, the remaining pods take even more load and get slower, their probes time out too — a **liveness-probe-induced cascading restart / CrashLoopBackOff** that turns a transient overload into a self-sustaining outage. Slowness should be handled by **readiness** (shed traffic), not liveness (kill).
3. A **voluntary** disruption is an operator-initiated action the control plane can pace: `kubectl drain`, node upgrades, cluster autoscaler scale-down. An **involuntary** disruption is unplanned: hardware failure, kernel panic, node OOM, network partition. A **PodDisruptionBudget protects only against voluntary disruptions** — the eviction API honors it; a hardware failure obviously cannot be "denied." See [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/).
4. With `minAvailable: 3` on 3 replicas, `ALLOWED DISRUPTIONS = 3 − 3 = 0`. That means **no pod may ever be voluntarily evicted**, so `kubectl drain` on any node running one of these pods blocks forever — you cannot perform node maintenance or upgrades without deleting the PDB or scaling up first. `minAvailable` must leave headroom (or use `maxUnavailable`) for maintenance to proceed.
5. They are the "first line" because they remediate the highest-frequency, judgment-free failures **automatically and instantly** — a hung process, a not-yet-ready pod, a node being drained — keeping those events off the pager entirely. Their limit: they only restart/reschedule/shed *within existing desired state*. They cannot fix a **bad deploy (every replica is broken the same way)**, a **downstream dependency outage**, a **data-corruption bug**, or a **capacity shortfall with nowhere to schedule** — those still require human judgment (rollback, failover, scale-out).

### Exercise 6

1. **Blameless** means the postmortem examines *systems, processes, and missing guardrails* rather than assigning fault to an individual — it assumes people acted reasonably given the information and tools they had. Organizationally it buys **psychological safety**, which makes engineers *report* near-misses and mistakes instead of hiding them; you therefore *learn about more* incidents and weak signals, and fix systemic causes, rather than driving problems underground. See [Google SRE — Postmortem Culture](https://sre.google/sre-book/postmortem-culture/).
2. **MTTD** = Mean Time To Detect (fault present → detected/alerted). **MTTA** = Mean Time To Acknowledge (alert fired → human acks). **MTTR** = Mean Time To Recover/Restore (fault present → service restored). MTTR is measured from **fault onset (14:03)**, not the page (14:06), because the customer was impacted from 14:03 — recovery time must include the detection gap; measuring from the page would flatter the number by hiding the 3 minutes you were blind.
3. The **trigger** is the proximate cause that set the incident off: *the non-existent image tag `nginx:9.99.0` was shipped* (the ImagePullBackOff line). The **root cause** is the systemic gap that let the trigger reach production and go uncaught: *CI has no step that validates the target image tag actually pulls (no `docker manifest inspect` gate), and there's no automated rollback on a stuck rollout*. You fix the root cause (the missing guardrails), not just the typo.
4. Prevention is never perfect — some bad change will always slip through eventually, and betting solely on "never ship a bad image" is betting on human infallibility. **Mitigate-class** items (short `progressDeadlineSeconds`, auto-rollback on failed rollout) bound the *blast radius and MTTR* of whatever does slip through. A mature platform layers **prevent** (fewer incidents) *and* **mitigate/detect** (smaller, shorter incidents) so that residual failures are cheap — defense in depth.
5. Owner + due date convert intent into accountability and make follow-through *trackable*; without them the item has no one responsible and no deadline to review against. The classic failure mode is the **postmortem that produces a list of good ideas nobody executes** — action items rot, the same incident recurs, and the postmortem process itself loses credibility. Owned, dated, tracked-to-closure action items are what make the postmortem a reliability *investment* rather than a writing exercise.

</details>

---

### Sources

- CNCF — *CNPA Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes — *Debug Running Pods (ephemeral containers, node debug)*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pods/
- Kubernetes — *Assign Memory Resources / OOMKilled*: https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Kubernetes — *Configure Liveness, Readiness and Startup Probes*: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — *Deployments (rolling update, rollback, progressDeadlineSeconds)*: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — *Disruptions & PodDisruptionBudget*: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Prometheus — *Alerting rules*: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus — *Alertmanager (routing, inhibition, silences)*: https://prometheus.io/docs/alerting/latest/alertmanager/
- Google SRE Workbook — *Alerting on SLOs (multi-window, multi-burn-rate)*: https://sre.google/workbook/alerting-on-slos/
- Google SRE Book — *Postmortem Culture: Learning from Failure*: https://sre.google/sre-book/postmortem-culture/
- Argo CD — *Application sync, history & rollback*: https://argo-cd.readthedocs.io/en/stable/user-guide/