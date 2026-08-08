# Exercises — 1.3 Optimizing Multi-Tenancy Resource Usage

These exercises assume a working cluster where you have `cluster-admin` (a kind/minikube cluster or a scratch namespace-scoped sandbox with the components installed is fine). Each block is a self-contained lab: run the numbered steps, observe the output, then answer the checkpoint questions before moving on. Model answers are in the collapsible section at the end.

> The exam objective is *optimizing* usage under multi-tenancy, not merely isolating tenants. Keep two questions in mind throughout: **"who is allowed to consume what?"** (quota, fairness, priority) and **"is the cluster packing that consumption efficiently?"** (requests accuracy, bin-packing, consolidation).

---

## Exercise 1 — Tenant boundaries: `ResourceQuota` + `LimitRange`

A tenant that submits Pods with no `requests` is invisible to the scheduler and silently steals capacity. The floor for optimization is making every tenant *declare* what it uses. `LimitRange` supplies defaults and a `ResourceQuota` caps the aggregate.

**Steps:**

1. Create a tenant namespace and label it so policy can select it later:

   ```bash
   kubectl create namespace tenant-a
   kubectl label namespace tenant-a tenant=team-a
   ```

2. Apply a `ResourceQuota` capping the namespace aggregate, and note that it requires every Pod to set the four resource fields it enumerates:

   ```yaml
   # quota.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-a-compute
     namespace: tenant-a
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
       pods: "20"
   ```

   ```bash
   kubectl apply -f quota.yaml
   ```

3. Try to create a Pod with **no** resource stanza and read the error:

   ```bash
   kubectl -n tenant-a run probe --image=nginx:1.27 --restart=Never
   ```

   Expected:

   ```
   Error from server (Forbidden): pods "probe" is forbidden: failed quota:
   tenant-a-compute: must specify limits.cpu for: probe; limits.memory for: probe;
   requests.cpu for: probe; requests.memory for: probe
   ```

4. Add a `LimitRange` supplying defaults, then retry the same Pod:

   ```yaml
   # limits.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-a-defaults
     namespace: tenant-a
   spec:
     limits:
       - type: Container
         default:            # becomes limits if unset
           cpu: 500m
           memory: 512Mi
         defaultRequest:     # becomes requests if unset
           cpu: 250m
           memory: 256Mi
         max:
           cpu: "2"
           memory: 2Gi
   ```

   ```bash
   kubectl apply -f limits.yaml
   kubectl -n tenant-a run probe --image=nginx:1.27 --restart=Never
   kubectl -n tenant-a get pod probe -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   ```

   Expected:

   ```
   {"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"250m","memory":"256Mi"}}
   ```

5. Inspect quota consumption:

   ```bash
   kubectl -n tenant-a describe resourcequota tenant-a-compute
   ```

   Expected (excerpt):

   ```
   Resource         Used   Hard
   --------         ----   ----
   limits.cpu       500m   8
   limits.memory    512Mi  16Gi
   pods             1      20
   requests.cpu     250m   4
   requests.memory  256Mi  8Gi
   ```

**Checkpoint 1:**

- 1a. In step 3 the Pod was rejected *before* the `LimitRange` existed, even though it requested nothing. Why does a `ResourceQuota` that enumerates `requests.cpu`/`limits.cpu` force every Pod in the namespace to declare those fields?
- 1b. The `LimitRange` sets `max.cpu: 2` per container but the quota allows `limits.cpu: 8` for the namespace. What distinct optimization problem does *each* limit solve? Why do you want both?
- 1c. A tenant sets `requests.cpu: 250m, limits.cpu: 2000m` on 10 Pods. It passes quota (`requests.cpu` sums to 2.5, under 4). What risk does this create on the *node*, and which number did the scheduler actually use to place the Pods?

---

## Exercise 2 — QoS, overcommit, and why requests accuracy is the real lever

Bin-packing efficiency is decided by the gap between **requests** (what the scheduler reserves) and **actual usage**. Overcommit exploits that gap; QoS class decides who dies when the gap closes.

**Steps:**

1. Create three Pods, one per QoS class, on the same node:

   ```yaml
   # qos.yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: qos-guaranteed, namespace: tenant-a}
   spec:
     containers:
     - name: app
       image: polinux/stress:latest
       command: ["sleep","3600"]
       resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
   ---
   apiVersion: v1
   kind: Pod
   metadata: {name: qos-burstable, namespace: tenant-a}
   spec:
     containers:
     - name: app
       image: polinux/stress:latest
       command: ["sleep","3600"]
       resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}
   ---
   apiVersion: v1
   kind: Pod
   metadata: {name: qos-besteffort, namespace: tenant-a}
   spec:
     containers:
     - name: app
       image: polinux/stress:latest
       command: ["sleep","3600"]
   ```

   > Note: `qos-besteffort` will only schedule if the namespace has no `ResourceQuota` enumerating requests, or a `LimitRange` supplies them. If your `tenant-a` quota from Exercise 1 is present, apply this in a fresh `tenant-qos` namespace *without* a quota to observe true BestEffort.

2. Read each Pod's assigned class:

   ```bash
   kubectl -n tenant-qos get pod -o custom-columns=\
   'NAME:.metadata.name,QOS:.status.qosClass'
   ```

   Expected:

   ```
   NAME              QOS
   qos-besteffort    BestEffort
   qos-burstable     Burstable
   qos-guaranteed    Guaranteed
   ```

3. Inspect the node's allocatable vs the sum of requests to see the overcommit headroom:

   ```bash
   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl describe node "$NODE" | sed -n '/Allocated resources/,/Events/p'
   ```

   Expected (excerpt):

   ```
   Resource           Requests      Limits
   --------           --------      ------
   cpu                300m (3%)     700m (7%)
   memory             384Mi (2%)    768Mi (6%)
   ```

4. Simulate memory pressure and observe eviction order. Patch the burstable Pod to consume beyond its request (but under its limit) while a stress hog fills the node — then confirm which QoS class the kubelet evicts first:

   ```bash
   kubectl -n tenant-qos get events --field-selector reason=Evicted \
     -o custom-columns='POD:.involvedObject.name,REASON:.reason,MSG:.message'
   ```

   Expected under node memory pressure (order, not exact wording):

   ```
   POD              REASON    MSG
   qos-besteffort   Evicted   The node was low on resource: memory...
   ```

**Checkpoint 2:**

- 2a. Rank the three QoS classes by eviction order under node memory pressure and state the rule the kubelet actually applies (hint: it is not literally "BestEffort first" in all cases — what secondary signal breaks ties among Burstable Pods?).
- 2b. A platform team sets `requests == limits` on every tenant Pod to guarantee QoS. What does this do to cluster **bin-packing density**, and why might a cost-conscious platform *deliberately* keep requests below limits for stateless tenants?
- 2c. You observe node CPU `Requests: 95%` but `kubectl top node` shows 30% actual CPU use. Name two mechanisms to close that gap without changing tenant code, and say which one is safe to automate and which needs guardrails.

---

## Exercise 3 — Fair sharing and quota borrowing with Kueue

Static `ResourceQuota` wastes capacity: tenant-a's idle quota cannot be lent to a busy tenant-b. Kueue models tenants as `ClusterQueue`s inside a shared `cohort`, letting an idle tenant's nominal quota be *borrowed* and reclaimed on demand — the core of efficient batch multi-tenancy.

**Steps:**

1. Install Kueue and define a shared resource pool. Two tenants share one cohort; each has a nominal 4-CPU guarantee but may borrow up to the cohort total:

   ```yaml
   # kueue-tenants.yaml
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: ResourceFlavor
   metadata: {name: default-flavor}
   ---
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: ClusterQueue
   metadata: {name: cq-team-a}
   spec:
     cohort: shared-pool
     namespaceSelector: {}
     resourceGroups:
     - coveredResources: ["cpu","memory"]
       flavors:
       - name: default-flavor
         resources:
         - name: cpu
           nominalQuota: "4"
           borrowingLimit: "4"    # may borrow up to 4 more from the cohort
         - name: memory
           nominalQuota: 8Gi
           borrowingLimit: 8Gi
   ---
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: ClusterQueue
   metadata: {name: cq-team-b}
   spec:
     cohort: shared-pool
     namespaceSelector: {}
     resourceGroups:
     - coveredResources: ["cpu","memory"]
       flavors:
       - name: default-flavor
         resources:
         - name: cpu
           nominalQuota: "4"
           borrowingLimit: "4"
         - name: memory
           nominalQuota: 8Gi
           borrowingLimit: 8Gi
   ---
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: LocalQueue
   metadata: {name: lq-a, namespace: tenant-a}
   spec: {clusterQueue: cq-team-a}
   ```

   ```bash
   kubectl apply -f kueue-tenants.yaml
   ```

2. Submit a batch Job from tenant-a that requests 6 CPU — 2 more than its nominal 4 — while tenant-b is idle:

   ```yaml
   # job-a.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: train-a
     namespace: tenant-a
     labels: {kueue.x-k8s.io/queue-name: lq-a}
   spec:
     suspend: true          # Kueue admits by un-suspending
     parallelism: 6
     completions: 6
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: worker
           image: busybox:1.36
           command: ["sh","-c","sleep 120"]
           resources: {requests: {cpu: "1", memory: 512Mi}}
   ```

   ```bash
   kubectl apply -f job-a.yaml
   kubectl -n tenant-a get workloads.kueue.x-k8s.io
   ```

   Expected — admitted by borrowing 2 CPU from the idle cohort:

   ```
   NAME              QUEUE   ADMITTED BY   AGE
   job-train-a-xxxx  lq-a    cq-team-a     5s
   ```

3. Now make tenant-b demand its guarantee. Add a `LocalQueue` for tenant-b and submit a Job needing its full 4 CPU, and watch reclamation:

   ```bash
   kubectl -n tenant-b get workloads.kueue.x-k8s.io -w
   ```

   Expected: tenant-b's workload is admitted and, if the cohort is now oversubscribed, tenant-a's *borrowed* excess is preempted back down toward its nominal 4 CPU.

4. Confirm the borrowing/lending accounting:

   ```bash
   kubectl get clusterqueue cq-team-a -o jsonpath=\
   '{.status.flavorsUsage}{"\n"}'
   ```

**Checkpoint 3:**

- 3a. In step 2 tenant-a ran 6 CPU worth of work while its `nominalQuota` is 4. Where did the extra 2 CPU come from, and what guarantees tenant-b it can get that capacity back?
- 3b. Contrast this with two plain `ResourceQuota` objects of 4 CPU each. Under the static quota, what happens to tenant-b's idle 4 CPU while tenant-a is overloaded — and what is the cluster-wide utilization cost?
- 3c. Why does the Job set `suspend: true`? What would break about Kueue's admission and fairness model if Jobs started running immediately on creation?

---

## Exercise 4 — Bin-packing: scheduler scoring + descheduler consolidation

By default the scheduler *spreads* Pods (`LeastAllocated`) for resilience. For a cost-optimized multi-tenant platform you often want the opposite — pack tightly onto fewer nodes (`MostAllocated`), then let the autoscaler remove the emptied nodes. The descheduler cleans up drift.

**Steps:**

1. Configure the scheduler for bin-packing via a `KubeSchedulerConfiguration` (this is a scheduler-startup flag, shown here as the config a platform ships):

   ```yaml
   # scheduler-config.yaml
   apiVersion: kubescheduler.config.k8s.io/v1
   kind: KubeSchedulerConfiguration
   profiles:
     - schedulerName: default-scheduler
       pluginConfig:
         - name: NodeResourcesFit
           args:
             scoringStrategy:
               type: MostAllocated       # pack, don't spread
               resources:
                 - name: cpu
                   weight: 1
                 - name: memory
                   weight: 1
   ```

   > On a managed control plane you cannot edit this; on kubeadm it goes in the scheduler static Pod's `--config`. The exam wants you to know *which knob* changes packing behavior.

2. Deploy a descheduler policy that evicts Pods off under-utilized nodes so they can be drained and removed:

   ```yaml
   # descheduler-policy.yaml
   apiVersion: descheduler/v1alpha2
   kind: DeschedulerPolicy
   profiles:
     - name: consolidate
       pluginConfig:
         - name: LowNodeUtilization
           args:
             thresholds:        {cpu: 20, memory: 20, pods: 20}
             targetThresholds:  {cpu: 50, memory: 50, pods: 50}
       plugins:
         balance:
           enabled: [LowNodeUtilization]
   ```

3. Observe distribution before and after. Count Pods per node:

   ```bash
   kubectl get pods -A -o wide --field-selector status.phase=Running \
     | awk 'NR>1{print $8}' | sort | uniq -c | sort -rn
   ```

   Expected shift after bin-packing + descheduling: Pods concentrate onto fewer nodes, leaving one or more nodes below the `thresholds` (20%), which become candidates for autoscaler removal.

4. If using Karpenter, confirm consolidation is enabled so the emptied node is actually reclaimed:

   ```yaml
   # nodepool excerpt
   spec:
     disruption:
       consolidationPolicy: WhenEmptyOrUnderutilized
       consolidateAfter: 30s
   ```

**Checkpoint 4:**

- 4a. `MostAllocated` scoring improves density but hurts a specific non-functional property. Which one, and how do you *keep* that property while still packing (name the two Pod-spec mechanisms)?
- 4b. The descheduler's `LowNodeUtilization` uses `thresholds` **and** `targetThresholds`. Explain the role of each and what would go wrong if you set `thresholds` = `targetThresholds`.
- 4c. Bin-packing only saves money if something removes the emptied nodes. Trace the full chain from "scheduler packs tightly" to "the bill goes down" — which component closes it, and what Pod-level setting can *block* the last step from ever happening?

---

## Exercise 5 — Right-sizing tenants with VPA and cost visibility with OpenCost

Overcommit hides waste; it doesn't remove it. The durable fix is *accurate requests*. VPA recommends them from observed usage; OpenCost turns "requested but unused" into a per-tenant dollar figure you can put in a showback report.

**Steps:**

1. Install VPA in **recommendation-only** mode (no auto-eviction) against a tenant Deployment:

   ```yaml
   # vpa.yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata: {name: web-vpa, namespace: tenant-a}
   spec:
     targetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: web
     updatePolicy:
       updateMode: "Off"      # recommend only; do not evict
   ```

   ```bash
   kubectl apply -f vpa.yaml
   ```

2. After the recommender has observed traffic, read its recommendation:

   ```bash
   kubectl -n tenant-a describe vpa web-vpa | sed -n '/Recommendation/,/Events/p'
   ```

   Expected (excerpt):

   ```
   Container Recommendations:
     Container Name: web
     Lower Bound:   cpu: 25m,  memory: 262144k
     Target:        cpu: 55m,  memory: 300Mi
     Upper Bound:   cpu: 240m, memory: 500Mi
   ```

3. Compare `Target` against what the Deployment actually requests. If the Deployment requests `cpu: 500m` but VPA targets `55m`, you are reserving ~9x the needed CPU per replica.

4. Quantify the waste per tenant with OpenCost:

   ```bash
   kubectl -n opencost port-forward svc/opencost 9003 &
   curl -s "http://localhost:9003/allocation/compute?window=24h&aggregate=namespace" \
     | jq '.data[0]["tenant-a"] | {cpuCoreRequestAverage, cpuCoreUsageAverage, cpuEfficiency, totalCost}'
   ```

   Expected (excerpt):

   ```json
   {
     "cpuCoreRequestAverage": 0.50,
     "cpuCoreUsageAverage": 0.06,
     "cpuEfficiency": 0.12,
     "totalCost": 4.87
   }
   ```

**Checkpoint 5:**

- 5a. VPA gives `Lower Bound`, `Target`, and `Upper Bound`. Which one belongs in the `requests` field of a right-sized Deployment, and what is the practical use of the other two?
- 5b. Why is `updateMode: "Off"` the correct starting point on a multi-tenant platform, and what is the specific danger of `updateMode: "Auto"` for a tenant that runs a single-replica Deployment? (Name the field that mitigates it.)
- 5c. OpenCost reports `cpuEfficiency: 0.12`. In plain terms, what did the tenant pay for versus use — and does *fixing* this (lowering requests to match usage) increase or decrease the number of tenants that fit on the cluster? Explain the mechanism.

---

## Exercise 6 — Tenant tiers with `PriorityClass` and preemption

Not all tenants are equal. When the cluster is full, a production tenant should be able to evict a batch tenant's Pods rather than pend. Priority + preemption is how a platform expresses "this tenant's work wins" without over-provisioning idle headroom.

**Steps:**

1. Define two priority tiers:

   ```yaml
   # priorities.yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: {name: tenant-production}
   value: 1000000
   preemptionPolicy: PreemptLowerPriority
   globalDefault: false
   description: "Interactive/production tenant workloads"
   ---
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: {name: tenant-batch}
   value: 10000
   preemptionPolicy: PreemptLowerPriority
   globalDefault: false
   description: "Preemptible batch/best-effort tenant workloads"
   ```

   ```bash
   kubectl apply -f priorities.yaml
   ```

2. Fill the cluster with low-priority batch Pods, then submit a production Pod that needs room that isn't there:

   ```bash
   kubectl -n tenant-b get pods -l tier=batch -o wide   # batch fills the node
   kubectl -n tenant-a apply -f prod-pod.yaml           # priorityClassName: tenant-production
   kubectl -n tenant-a get events --field-selector reason=Preempted \
     -o custom-columns='POD:.involvedObject.name,MSG:.message'
   ```

   Expected:

   ```
   POD          MSG
   batch-7f9d   Preempted by tenant-a/prod-app on node ...
   ```

3. Protect the batch tenant from *total* starvation by giving its Pods a `PodDisruptionBudget` and confirming preemption still respects graceful termination:

   ```bash
   kubectl -n tenant-b get pdb
   ```

**Checkpoint 6:**

- 6a. When the production Pod preempts a batch Pod, the batch Pod is deleted — but the scheduler does not guarantee the freed space goes to the pre-empting Pod. Why can another Pod "steal" the hole, and what field reduces that race?
- 6b. A team sets `globalDefault: true` on `tenant-production` "to be safe." Explain why this is an anti-pattern for a multi-tenant platform and what actually happens to Pods that specify no `priorityClassName`.
- 6c. Priority/preemption and Kueue (Exercise 3) both arbitrate contention. State the one-line distinction: at which layer does each operate, and why would a platform use *both*?

---

<details>
<summary><strong>Answers</strong></summary>

### Checkpoint 1

**1a.** A `ResourceQuota` that tracks a compute resource (e.g. `requests.cpu`) makes that resource *mandatory* for every Pod in the namespace: the quota admission controller cannot account for a Pod that omits the field, so it rejects it. Enumerating `requests.*` and `limits.*` in the quota is therefore the enforcement mechanism that guarantees the scheduler always has a real number to place against — no more invisible free-riders. (Source: kubernetes.io/docs/concepts/policy/resource-quotas/ — "Requests vs Limits".)

**1b.** They solve different problems. `LimitRange max` is a **per-container/per-Pod ceiling** — it stops one tenant workload from declaring a single giant Pod that no node can schedule or that monopolizes a node. `ResourceQuota hard` is an **aggregate cap** across the whole namespace — it bounds the tenant's total footprint on the cluster. Without `max`, the quota could be consumed by one oversized Pod; without the quota, many correctly-sized Pods could still exhaust the cluster. You want both: shape the individual Pod *and* bound the tenant sum.

**1c.** The scheduler places Pods using **requests** (250m each → 2.5 CPU reserved), so all 10 fit under the 4-CPU quota. But each Pod may burst to its **limit** of 2000m. If enough of them burst simultaneously, node CPU is oversubscribed and Pods are throttled (CPU is compressible, so throttling, not eviction, for CPU). The risk is noisy-neighbor CPU contention and latency spikes; the mismatch between reserved (requests) and allowed (limits) is exactly the overcommit gap Exercise 2 explores.

### Checkpoint 2

**2a.** Eviction order under node memory pressure: **BestEffort first, then Burstable, then Guaranteed.** Within a class the kubelet ranks by how far each Pod's memory usage exceeds its **request** — the Pod most *over* its request (largest usage-minus-request) is killed first. So a Burstable Pod using far above its request can be evicted before another Burstable Pod that is under its request. Guaranteed Pods (requests == limits for every resource) are evicted only as a last resort. (Source: kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/ and pod-qos/.)

**2b.** Setting `requests == limits` everywhere maximizes QoS safety but **minimizes bin-packing density**: the scheduler reserves the full limit for every Pod, so the overcommit gap disappears and the cluster holds far fewer Pods per node. For stateless, burstable tenants a platform deliberately keeps `requests < limits` so the scheduler packs against the (lower) request while individual Pods can still burst into slack — trading a little eviction risk for substantially higher density and lower cost.

**2c.** Two mechanisms: (1) **Lower the requests** to match observed usage (VPA-driven right-sizing) — this is the durable fix but needs guardrails because setting requests too low re-introduces contention and eviction risk, so automate it only in recommend-then-review mode. (2) **Overcommit deliberately** by scheduling more Pods against the slack (bin-packing / higher scheduling density) — safe to automate at the scheduler level because the scheduler still respects requests; the guardrail is monitoring actual usage so you don't pack past real capacity.

### Checkpoint 3

**3a.** The extra 2 CPU came from **borrowing unused nominal quota from the shared `cohort`** — tenant-b was idle, so cq-team-b's 4 CPU were available for cq-team-a to borrow, up to its `borrowingLimit`. Tenant-b's guarantee is its own `nominalQuota`: when tenant-b submits work, Kueue reclaims the borrowed capacity (preempting tenant-a's *borrowed* excess) so tenant-b gets its 4 CPU back. Nominal quota is a floor guarantee; borrowing only ever lends *idle* capacity. (Source: kueue.sigs.k8s.io — cohort / borrowing.)

**3b.** With two static `ResourceQuota` objects, tenant-b's idle 4 CPU is **stranded** — there is no mechanism to lend it to tenant-a, which pends at its 4-CPU cap while half the cluster's guaranteed capacity sits unused. Cluster-wide utilization is capped at the sum of what each tenant happens to be using; the "safety" of static quota is paid for in permanently idle reserved capacity. Kueue's cohort recovers that idle capacity without giving up the guarantee.

**3c.** `suspend: true` hands admission control to Kueue: the Job's Pods are not created until Kueue's controller un-suspends it, which it does only when the workload fits within quota (nominal + borrowable) and fair-sharing order. If Jobs ran immediately, they would bypass Kueue entirely — Pods would hit the scheduler directly, quota accounting and cohort fairness would be meaningless, and there would be no admission point at which to enforce borrowing limits or ordering.

### Checkpoint 4

**4a.** `MostAllocated` packing hurts **availability / fault tolerance** (many tenant Pods on few nodes → one node failure takes out more). You keep resilience while packing with (1) **`topologySpreadConstraints`** to force replicas of a given workload across nodes/zones even under a packing scorer, and (2) **`podAntiAffinity`** to keep replicas of the same app off the same node. Packing decides *cluster* density; these decide *per-workload* spread, so both hold at once.

**4b.** `thresholds` is the **under-utilization line**: nodes *below* it are treated as donors whose Pods may be evicted for consolidation. `targetThresholds` is the **over-utilization line**: nodes *above* it are treated as too full to receive more, and the descheduler moves load off them. The band between them is the acceptable zone. If you set them equal there is no band — every node is simultaneously a donor and over-full, so the descheduler thrashes (evicts Pods that immediately land on nodes it will evict from next cycle).

**4c.** Chain: scheduler `MostAllocated` packs Pods onto fewer nodes → descheduler `LowNodeUtilization` drains the now-under-utilized nodes → those nodes become empty/under-utilized → **Cluster Autoscaler or Karpenter consolidation** removes them → the cloud provider stops billing for the terminated instances → the bill drops. The component that closes it is the autoscaler/Karpenter. A Pod that **cannot be safely evicted blocks the last step**: a Pod with no controller, a restrictive `PodDisruptionBudget`, or the `karpenter.sh/do-not-disrupt` (formerly `do-not-evict`) annotation keeps the node alive, so it is never reclaimed and no money is saved. (Sources: karpenter.sh/docs/concepts/disruption/, github.com/kubernetes-sigs/descheduler.)

### Checkpoint 5

**5a.** Put the **`Target`** into `requests` — it is VPA's best estimate of steady-state need. The **`Lower Bound`** is the floor below which the container would likely be resource-starved (useful as a sanity check that you're not requesting too little); the **`Upper Bound`** informs the **`limit`** and the headroom for bursts. Requesting `Target` and limiting near `Upper Bound` is a common right-sized shape.

**5b.** `updateMode: "Off"` is correct to start because it only *recommends* — it never evicts tenant Pods, so it is observation without disruption on a shared platform. `updateMode: "Auto"` (or `Recreate`) evicts a Pod to apply new requests; for a **single-replica** Deployment that means a hard restart with downtime every time the recommendation shifts. The mitigating field is a **`PodDisruptionBudget`** (VPA respects it), which prevents VPA from evicting the only replica — though for singletons the real fix is `Off`/`Initial` mode or adding replicas.

**5c.** `cpuEfficiency: 0.12` means the tenant *used* ~12% of the CPU it *requested* (paid-for-but-reserved). Fixing it — lowering requests toward actual usage — **increases** the number of tenants that fit, because the scheduler places against requests: smaller requests free reserved capacity on each node, so more Pods/tenants pack onto the same hardware. Efficiency work and density are the same lever seen from two sides. (Source: opencost.io/docs — efficiency and allocation.)

### Checkpoint 6

**6a.** Preemption deletes the victim Pods but only *nominates* the node for the preemptor; between the victim's deletion and the preemptor's rescheduling there is a window in which the scheduler runs other Pods, and a different pending Pod can take the freed space ("preemption is not atomic with placement"). The mitigating field is **`.status.nominatedNodeName`**, which the scheduler sets to reserve the intent, plus keeping the preemptor's priority high enough that it wins the next cycle. Very short victim `terminationGracePeriodSeconds` also narrows the window.

**6b.** `globalDefault: true` makes `tenant-production`'s high value the default for **every** Pod that omits `priorityClassName` across the whole cluster — so batch, system-adjacent, and untagged tenant Pods all become high priority, collapsing the tiering you built and enabling them to preempt each other indiscriminately. Only **one** PriorityClass may be the global default. The correct pattern is `globalDefault: false` on both tiers and requiring tenants to set the class explicitly (or defaulting via admission policy per namespace).

**6c.** **Kueue arbitrates at admission (quota/cohort layer): does this workload get to run at all, and whose fair share does it consume?** **Priority/preemption arbitrates at scheduling (node layer): given already-admitted Pods competing for real node capacity, which one gets the slot and which is evicted?** A platform uses both: Kueue enforces tenant quotas and borrowing fairly *before* Pods exist, while PriorityClass decides contention *among the Pods the scheduler is actively placing* — one governs entitlement, the other governs runtime eviction.

</details>

---

*Sources: Kubernetes documentation — Resource Quotas (`/docs/concepts/policy/resource-quotas/`), Limit Ranges (`/docs/concepts/policy/limit-range/`), Pod QoS (`/docs/concepts/workloads/pods/pod-qos/`), Node-pressure Eviction (`/docs/concepts/scheduling-eviction/node-pressure-eviction/`), Resource Bin Packing (`/docs/concepts/scheduling-eviction/resource-bin-packing/`), Scheduler Configuration (`/docs/reference/scheduling/config/`), Pod Priority and Preemption (`/docs/concepts/scheduling-eviction/pod-priority-preemption/`). Kueue (`kueue.sigs.k8s.io/docs/concepts/`). Descheduler (`github.com/kubernetes-sigs/descheduler`). Vertical Pod Autoscaler (`github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler`). Karpenter Disruption (`karpenter.sh/docs/concepts/disruption/`). OpenCost (`opencost.io/docs/`). CNPE Curriculum (`github.com/cncf/curriculum`).*