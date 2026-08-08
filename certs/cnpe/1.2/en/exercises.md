# Exercises — Topic 1.2: Using Cost Management Solutions for Right-Sizing and Scaling

> **Certification:** CNPE (Certified Cloud Native Platform Engineer) · **Exam weight:** 5%
> **Format:** Each exercise is a numbered lab you execute against a running cluster. Comprehension checks follow every block. All answers are collapsed at the end.

## Prerequisites

You need a cluster where you can install controllers and read node cost data. Any of `kind`, `minikube`, or a managed cluster (EKS/GKE/AKS) works, but cluster-level scaling (Exercise 6) requires a cloud provider or a simulated autoscaler.

```bash
# Verify tooling and cluster reachability
kubectl version --output=yaml | grep -E 'gitVersion'
helm version --short
kubectl get nodes -o wide
```

Expected (abridged):

```
gitVersion: v1.30.2          # client
gitVersion: v1.30.2          # server
v3.15.2+g...
NAME             STATUS   ROLES           AGE   VERSION   INTERNAL-IP
ip-10-0-1-23     Ready    <none>          9d    v1.30.2   10.0.1.23
ip-10-0-2-88     Ready    <none>          9d    v1.30.2   10.0.2.88
```

Install the **metrics-server** — VPA, HPA, KRR and OpenCost recommendations all depend on the metrics pipeline it feeds.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}'   # dev clusters only; drop on managed clusters with valid kubelet certs
```

Wait for the API to register and confirm live usage flows:

```bash
kubectl top nodes
```

```
NAME             CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-1-23     241m         12%    1876Mi          49%
ip-10-0-2-88     198m         9%     1543Mi          40%
```

> Source: metrics-server — https://github.com/kubernetes-sigs/metrics-server

---

## Exercise 1 — Establish a cost baseline with OpenCost

**Goal:** deploy the CNCF cost-monitoring reference implementation and read per-workload cost allocation. You cannot right-size what you cannot price.

1. Deploy a Prometheus scraped target for OpenCost (skip if you already run Prometheus and point OpenCost at it instead):

   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm upgrade --install prometheus prometheus-community/prometheus \
     --namespace prometheus --create-namespace \
     --set prometheus-pushgateway.enabled=false \
     --set alertmanager.enabled=false
   ```

2. Install OpenCost, pointing it at that Prometheus service:

   ```bash
   kubectl create namespace opencost
   helm repo add opencost https://opencost.github.io/opencost-helm-chart
   helm upgrade --install opencost opencost/opencost \
     --namespace opencost \
     --set opencost.prometheus.internal.serviceName=prometheus-server \
     --set opencost.prometheus.internal.namespaceName=prometheus \
     --set opencost.prometheus.internal.port=80
   ```

3. Wait for the pod and expose the allocation API locally:

   ```bash
   kubectl -n opencost rollout status deploy/opencost
   kubectl -n opencost port-forward svc/opencost 9003:9003 &
   ```

4. Query the **allocation** endpoint for the last day, aggregated by namespace, and pull only the fields that matter for right-sizing decisions:

   ```bash
   curl -sG 'http://localhost:9003/allocation/compute' \
     --data-urlencode 'window=24h' \
     --data-urlencode 'aggregate=namespace' \
     --data-urlencode 'accumulate=true' \
   | jq '.data[0] | to_entries[] | {ns: .key,
         cpuCost: .value.cpuCost,
         ramCost: .value.ramCost,
         cpuEfficiency: .value.cpuEfficiency,
         ramEfficiency: .value.ramEfficiency,
         totalCost: .value.totalCost}'
   ```

   Expected (abridged):

   ```json
   { "ns": "checkout", "cpuCost": 4.11, "ramCost": 1.92,
     "cpuEfficiency": 0.09, "ramEfficiency": 0.31, "totalCost": 6.03 }
   { "ns": "prometheus", "cpuCost": 0.88, "ramCost": 1.40,
     "cpuEfficiency": 0.52, "ramEfficiency": 0.61, "totalCost": 2.28 }
   ```

5. Note the two cost dimensions OpenCost reports independently: **cost** (what you pay for the *requested/allocated* resources) and **efficiency** (`usage ÷ request`). Record the `checkout` namespace numbers — you will act on them in Exercises 2–4.

> Sources: OpenCost docs — https://www.opencost.io/docs/ · Allocation API — https://www.opencost.io/docs/integrations/api

### Comprehension check — 1

1. OpenCost reports `cpuCost` for `checkout` as `4.11` while `cpuEfficiency` is `0.09`. In plain terms, what is that pairing telling you, and roughly how much of that $4.11 is waste?
2. Why does OpenCost require a metrics source like Prometheus rather than reading cost directly from the `kubectl top` pipeline?
3. A namespace shows `cpuEfficiency: 0.52` but `ramEfficiency: 0.61`. If you must right-size only one dimension first, which do you touch, and why is looking at *both* independently important?

---

## Exercise 2 — Right-sizing recommendations with VPA (recommender-only) and Goldilocks

**Goal:** produce concrete request recommendations from observed usage without letting anything reschedule your pods yet.

1. Install the Vertical Pod Autoscaler components (recommender, updater, admission-controller):

   ```bash
   git clone https://github.com/kubernetes/autoscaler.git
   cd autoscaler/vertical-pod-autoscaler
   ./hack/vpa-up.sh
   kubectl -n kube-system get pods | grep vpa
   ```

   ```
   vpa-admission-controller-6b8b9d7c9c-4nq2p   1/1   Running
   vpa-recommender-7c9b7fbb9d-x7lmp            1/1   Running
   vpa-updater-5f9c7d8b7c-tq2vd               1/1   Running
   ```

2. Deploy the over-provisioned workload you priced in Exercise 1 — note it **requests 1 full CPU** but does almost nothing:

   ```yaml
   # checkout.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: checkout
     namespace: checkout
   spec:
     replicas: 3
     selector:
       matchLabels: { app: checkout }
     template:
       metadata:
         labels: { app: checkout }
       spec:
         containers:
           - name: web
             image: registry.k8s.io/e2e-test-images/agnhost:2.47
             args: ["serve-hostname"]
             resources:
               requests:
                 cpu: "1000m"
                 memory: "512Mi"
               limits:
                 cpu: "1000m"
                 memory: "512Mi"
   ```

   ```bash
   kubectl create namespace checkout
   kubectl apply -f checkout.yaml
   ```

3. Attach a VPA in **`updateMode: "Off"`** — this is the critical, non-disruptive setting: the recommender computes targets but the updater never evicts a pod:

   ```yaml
   # checkout-vpa.yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata:
     name: checkout
     namespace: checkout
   spec:
     targetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: checkout
     updatePolicy:
       updateMode: "Off"              # recommend only, never act
     resourcePolicy:
       containerPolicies:
         - containerName: "web"
           controlledResources: ["cpu", "memory"]
   ```

   ```bash
   kubectl apply -f checkout-vpa.yaml
   ```

4. After ~5–10 minutes of observed traffic, read the recommendation:

   ```bash
   kubectl -n checkout describe vpa checkout | sed -n '/Recommendation/,/Events/p'
   ```

   ```
   Recommendation:
     Container Recommendations:
       Container Name:  web
       Lower Bound:
         Cpu:     15m
         Memory:  104857600
       Target:
         Cpu:     25m
         Memory:  134217728
       Uncapped Target:
         Cpu:     25m
         Memory:  134217728
       Upper Bound:
         Cpu:     412m
         Memory:  262144000
   ```

5. Rather than reading VPA objects one by one, install **Goldilocks** to render the same recommender output as a dashboard across a whole namespace:

   ```bash
   helm repo add fairwinds-stable https://charts.fairwinds.com/stable
   helm upgrade --install goldilocks fairwinds-stable/goldilocks \
     --namespace goldilocks --create-namespace
   kubectl label namespace checkout goldilocks.fairwinds.com/enabled=true
   kubectl -n goldilocks port-forward svc/goldilocks-dashboard 8080:80 &
   ```

   Open `http://localhost:8080`. Goldilocks shows a **Guaranteed** column (request = limit, set to the VPA target) and a **Burstable** column (request = VPA target, limit higher), so you can pick a QoS class as well as a number.

> Sources: VPA — https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler · Goldilocks — https://goldilocks.docs.fairwinds.com/

### Comprehension check — 2

1. The VPA `Target` is `25m` CPU but you requested `1000m`. What is the concrete meaning of `Lower Bound`, `Target`, and `Upper Bound`, and which one would you actually put into the manifest?
2. Why is `updateMode: "Off"` the correct choice for a *recommendation* workflow, and what specifically would `updateMode: "Auto"` do differently that makes it dangerous to switch on blindly in production?
3. Goldilocks offers both a "Guaranteed" and a "Burstable" recommendation for the same container. What is the underlying Kubernetes QoS trade-off between choosing one over the other for a latency-sensitive checkout service?
4. Explain why you should **not** run VPA in `Auto` mode on the same Deployment that an HPA scales on CPU. (This is the classic conflict.)

---

## Exercise 3 — Cross-check with KRR (Prometheus-based recommender)

**Goal:** get a second, independent right-sizing opinion that uses historical Prometheus data (percentiles over a window) rather than VPA's live estimator, and reconcile the two.

1. Run KRR against your existing Prometheus without installing anything in-cluster (KRR is a client-side CLI):

   ```bash
   pip install robusta-krr
   krr simple \
     --prometheus-url http://localhost:9090 \
     -n checkout \
     --cpu-percentile 95 \
     --memory-buffer-percentage 15
   ```

   > Port-forward Prometheus first: `kubectl -n prometheus port-forward svc/prometheus-server 9090:80 &`

2. Read the tabular recommendation:

   ```
   Namespace   Name       Container   Pods   Type   CPU Requests            Memory Requests
   checkout    checkout   web         3      —      1000m -> 30m  (-97%)    512Mi -> 150Mi (-71%)
   ```

3. Compare the three numbers you now hold for the same container:

   | Source | CPU request | Memory request | Method |
   |---|---|---|---|
   | Current manifest | 1000m | 512Mi | human guess |
   | VPA (Ex. 2) | 25m | 128Mi | live recommender, moving window |
   | KRR (Ex. 3) | 30m | 150Mi | Prometheus p95 + 15% buffer |

4. Decide the value to commit. Take the **more conservative** of the two recommenders for a production service, and add explicit headroom on memory (which cannot be compressed) but keep CPU tight (which can throttle without OOM). A defensible landing point here: `cpu: 30m`, `memory: 192Mi`.

> Source: KRR — https://github.com/robusta-dev/krr

### Comprehension check — 3

1. VPA said `25m` CPU; KRR said `30m` CPU at p95. Why does a percentile-based tool tend to be a *safer* input for a production request than VPA's target, and what does the choice of percentile (p95 vs p99 vs p50) actually control?
2. The recommendation cut memory by 71%. Why is it correct to be *more* cautious cutting memory requests than CPU requests — what happens at runtime when each is exceeded?
3. You have two independent recommenders that disagree by 20%. Argue why running two tools was worth the effort rather than trusting VPA alone.

---

## Exercise 4 — Scale horizontally on the *right-sized* request

**Goal:** now that requests reflect reality, attach an HPA. HPA percentages are meaningless until the denominator (the request) is correct — this is why right-sizing must precede scaling.

1. Patch the Deployment to the value you chose in Exercise 3:

   ```bash
   kubectl -n checkout set resources deploy/checkout \
     --requests=cpu=30m,memory=192Mi \
     --limits=memory=192Mi
   # Note: no CPU limit — allow bursting; rely on request + HPA for scaling.
   ```

2. Create an HPA (`autoscaling/v2`) targeting 70% of the *request*:

   ```yaml
   # checkout-hpa.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: checkout
     namespace: checkout
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: checkout
     minReplicas: 2
     maxReplicas: 20
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: 70
     behavior:
       scaleDown:
         stabilizationWindowSeconds: 300   # avoid flapping on brief dips
         policies:
           - type: Percent
             value: 50
             periodSeconds: 60
       scaleUp:
         stabilizationWindowSeconds: 0
         policies:
           - type: Percent
             value: 100
             periodSeconds: 30
   ```

   ```bash
   kubectl apply -f checkout-hpa.yaml
   ```

3. Watch the HPA resolve the metric and hold at `minReplicas`:

   ```bash
   kubectl -n checkout get hpa checkout
   ```

   ```
   NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS
   checkout   Deployment/checkout   6%/70%          2         20        2
   ```

4. Generate load and observe a scale-up event, then let it stabilize back down:

   ```bash
   kubectl -n checkout run load --image=busybox --restart=Never -- \
     /bin/sh -c "while true; do wget -q -O- http://checkout:9376; done"
   kubectl -n checkout describe hpa checkout | sed -n '/Events/,$p'
   ```

   ```
   Events:
     Type    Reason             Message
     Normal  SuccessfulRescale  New size: 6; reason: cpu resource utilization above target
     Normal  SuccessfulRescale  New size: 3; reason: All metrics below target
   ```

> Source: HPA — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

### Comprehension check — 4

1. If you had left the request at `1000m` and set `averageUtilization: 70`, the HPA would essentially never scale. Explain arithmetically why the wrong request breaks the scaler, using the observed usage (~25m).
2. What is the purpose of the asymmetric `behavior` block — fast scale-up (`stabilizationWindowSeconds: 0`) but slow scale-down (`300`)? Frame the answer in terms of cost *and* reliability.
3. The manifest sets a memory limit but no CPU limit. Justify that choice for a scalable service in the language of the Linux cgroup behaviour behind CPU throttling vs OOM-killing.
4. `minReplicas: 2` costs money at idle. Give the reliability reason it is usually still correct, and name one Kubernetes-native mechanism that protects those replicas during voluntary disruptions.

---

## Exercise 5 — Scale the cluster, not just the pods: node right-sizing and consolidation

**Goal:** pod-level savings are wasted if the nodes underneath stay half-empty. Configure node-level scaling to *consolidate* and bin-pack, and read the cost impact.

1. **(Cluster Autoscaler path)** Confirm the node group can scale to zero and that the autoscaler sees your pods' new small requests. On a managed cluster, the important annotations live on the autoscaler deployment:

   ```bash
   kubectl -n kube-system get deploy cluster-autoscaler \
     -o jsonpath='{.spec.template.spec.containers[0].command}' | tr ',' '\n' | grep -E 'scale-down|utilization'
   ```

   ```
   --scale-down-utilization-threshold=0.5
   --scale-down-unneeded-time=10m
   ```

2. **(Karpenter path — preferred for right-sizing at the node layer)** Define a `NodePool` that consolidates under-utilized nodes and lets Karpenter pick the *cheapest instance type that fits*:

   ```yaml
   # nodepool.yaml
   apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: default
   spec:
     template:
       spec:
         requirements:
           - key: karpenter.sh/capacity-type
             operator: In
             values: ["spot", "on-demand"]     # let Karpenter prefer spot
           - key: kubernetes.io/arch
             operator: In
             values: ["amd64", "arm64"]         # allow cheaper Graviton where compatible
         nodeClassRef:
           group: karpenter.k8s.aws
           kind: EC2NodeClass
           name: default
     disruption:
       consolidationPolicy: WhenEmptyOrUnderutilized
       consolidateAfter: 1m
     limits:
       cpu: "1000"
   ```

   ```bash
   kubectl apply -f nodepool.yaml
   ```

3. Trigger and observe consolidation. After your right-sizing (Ex. 2–4) freed capacity, Karpenter should replace or remove nodes:

   ```bash
   kubectl get nodeclaims
   kubectl logs -n kube-system deploy/karpenter -c controller | grep -i consolidat | tail -3
   ```

   ```
   {"level":"INFO","message":"disrupting via consolidation delete, 1 candidate", "nodes":"ip-10-0-2-88"}
   {"level":"INFO","message":"disrupting via consolidation replace, cheaper instance type", "from":"m5.xlarge","to":"m6g.large"}
   ```

4. Protect availability during that churn with a `PodDisruptionBudget`, so consolidation cannot take your service below quorum:

   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: checkout
     namespace: checkout
   spec:
     minAvailable: 2
     selector:
       matchLabels: { app: checkout }
   ```

5. Re-run the Exercise 1 OpenCost query. `checkout` total cost should drop sharply and `cpuEfficiency` should rise toward the HPA target band.

> Sources: Karpenter disruption — https://karpenter.sh/docs/concepts/disruption/ · Cluster Autoscaler — https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler · PDB — https://kubernetes.io/docs/tasks/run-application/configure-pdb/

### Comprehension check — 5

1. You cut every pod's CPU request by ~97%, but the monthly node bill did not move at all for the first hour. Explain the mechanism gap and which controller closes it.
2. `consolidationPolicy: WhenEmptyOrUnderutilized` can *replace* a running node with a cheaper one ("consolidation replace"). Why is a `PodDisruptionBudget` a hard prerequisite before enabling this in production?
3. Cluster Autoscaler's `--scale-down-utilization-threshold=0.5` means a node is a scale-down candidate below 50% requested. After right-sizing, why might this threshold now *trigger consolidation that previously never fired*, and how does that connect Exercises 2–4 to node cost?
4. Karpenter is allowed to pick `spot` and `arm64`. Name the workload property that must hold for spot to be safe, and the build property that must hold for arm64 to be safe.

---

## Exercise 6 — Close the FinOps loop: alert on drift, not just on spend

**Goal:** right-sizing decays. New deployments arrive over-provisioned; traffic patterns shift. Turn the one-off exercise into a recurring signal.

1. Write a Prometheus recording/alerting rule that fires when a namespace's CPU efficiency (from OpenCost / kube-state-metrics) stays low while its cost is non-trivial — the exact anti-pattern you found in Exercise 1:

   ```yaml
   # cost-efficiency-alert.yaml
   groups:
     - name: finops.rules
       rules:
         - alert: NamespaceCpuOverProvisioned
           expr: |
             (
               sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[1h]))
               /
               sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
             ) < 0.20
           for: 6h
           labels: { severity: warning, team: finops }
           annotations:
             summary: "Namespace {{ $labels.namespace }} CPU efficiency below 20% for 6h"
             runbook: "Run KRR/VPA against this namespace and right-size requests."
   ```

2. Apply it and verify the expression evaluates before trusting the alert:

   ```bash
   kubectl -n prometheus create configmap finops-rules --from-file=cost-efficiency-alert.yaml
   # In the Prometheus UI, run the bare expr and confirm 'checkout' is NOT listed after Ex. 4.
   ```

3. Add a **guardrail**, not just a detector, so new workloads cannot land wildly over-provisioned. Set a `LimitRange` default and a `ResourceQuota` ceiling per namespace:

   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: sane-defaults
     namespace: checkout
   spec:
     limits:
       - type: Container
         default:            { cpu: "200m", memory: "256Mi" }   # applied when a container omits limits
         defaultRequest:     { cpu: "50m",  memory: "128Mi" }   # applied when a container omits requests
         max:                { cpu: "2",    memory: "2Gi" }     # hard ceiling per container
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: ns-budget
     namespace: checkout
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: "8Gi"
   ```

4. State the loop you have now built and can defend in the exam:
   **measure (OpenCost) → recommend (VPA/KRR) → apply (requests) → scale (HPA) → consolidate (Karpenter/CA) → guardrail (LimitRange/Quota) → detect drift (alert) → repeat.**

> Sources: LimitRange — https://kubernetes.io/docs/concepts/policy/limit-range/ · ResourceQuota — https://kubernetes.io/docs/concepts/policy/resource-quotas/ · FinOps Foundation, Kubernetes cost — https://www.finops.org/framework/

### Comprehension check — 6

1. The alert uses a *ratio* (usage ÷ request) with `for: 6h` rather than an absolute usage threshold. Give two reasons the ratio + duration form is better for catching over-provisioning than "usage < 100m".
2. A `LimitRange` `defaultRequest` and a `ResourceQuota` `requests.cpu` interact. Explain what happens when someone deploys 100 pods that each *omit* requests into this namespace — walk the admission sequence.
3. Right-sizing is described as a *loop*, not a one-time task. Name two forces that make a request that was correct last month wrong this month.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

1. `cpuCost: 4.11` is what you are billed for the CPU you **reserved** (requests × node CPU price × time); `cpuEfficiency: 0.09` means only 9% of that reserved CPU was actually *used*. So roughly **91% of the $4.11 ≈ $3.74** is paying for idle, reserved-but-unused CPU. Cost prices the reservation; efficiency prices the waste inside it.
2. Cost is a function of *time-weighted usage and allocation*: you need a time-series of each container's requests and actual usage over the window, joined with node pricing. `kubectl top` is an instantaneous snapshot with no history and no persistence — you cannot integrate it over a day or attribute it per namespace. Prometheus stores the time-series that OpenCost integrates; that is why it is a hard dependency.
3. Touch **RAM first here** because `0.61 > 0.52` is misleading only if you look at cost too — you act on the dimension with the *most reserved-but-idle dollars*, which is usually the lower-efficiency one (CPU at 0.52) unless RAM is the larger cost line. The reason to keep them **independent** is that CPU is *compressible* (throttled) while memory is *not* (OOM-killed); a single blended "efficiency" number would hide which resource you can safely trim and which one will crash the pod if you cut it too far.

### Exercise 2

1. `Lower Bound` = the smallest request VPA thinks is safe right now (below this, the pod is likely under-provisioned); `Target` = the recommended request VPA would set; `Upper Bound` = the largest request VPA currently justifies (above this is waste). You put the **`Target`** into the manifest (optionally with a manual memory buffer). Bounds exist so the updater does not thrash on values already "close enough" to target.
2. `updateMode: "Off"` computes and publishes recommendations but the **updater never evicts pods** — zero disruption, pure advisory. `updateMode: "Auto"` (`Recreate`) lets the updater **evict and recreate** pods to apply new requests, causing restarts you did not schedule; blindly enabling it can cause rolling restarts, brief unavailability, and interaction bugs with rollout controllers.
3. **Guaranteed** (request = limit) gives the pod QoS class `Guaranteed`: it is the *last* to be evicted under node memory pressure and gets no CPU throttling surprises, but you pay for the full limit as reserved capacity even when idle — better tail-latency, higher cost/lower density. **Burstable** (request < limit) is cheaper and denser but the pod can be throttled or, under contention, evicted before Guaranteed pods — worse worst-case latency. For latency-sensitive checkout you often accept Guaranteed's cost for the eviction/throttle protection.
4. Both controllers would fight over the same signal: HPA scales *replica count* to hold CPU utilization near the target, which changes per-pod CPU usage; VPA in `Auto` simultaneously rewrites the CPU *request*, which changes the denominator HPA divides by. They chase each other — HPA adds pods, VPA shrinks requests, HPA sees higher utilization, and the system oscillates. The supported combination is VPA on **memory only** (or `Off`/recommendation mode) while HPA scales on CPU.

### Exercise 3

1. A percentile is an explicit statement about how much of your *observed* load you promise to serve without throttling: p95 sizes the request so that 95% of observed CPU samples fit inside it, leaving only the top 5% to burst. That is safer than VPA's target, which is a moving statistical estimate tuned for density, not tail coverage. Choosing p50 sizes to the median (cheapest, most throttling), p99 sizes for the tail (safest, most expensive) — the percentile *is* the cost/reliability dial.
2. CPU is **compressible**: exceeding the request/limit causes the scheduler/cgroup to *throttle* the process — it runs slower but survives. Memory is **incompressible**: exceeding the memory limit triggers the kernel **OOM killer**, which terminates the container. An overly tight CPU request degrades latency; an overly tight memory request crashes the workload. Asymmetric caution follows directly.
3. VPA's live recommender and KRR's Prometheus-percentile method have different failure modes: VPA can under-size on bursty or recently-started workloads (short window), and KRR can over-size if the percentile window includes an anomalous spike. When two *independent* methods agree within 20%, your confidence in the number is high; when they diverge, the gap itself flags a workload worth a human look. A single tool gives you a number with no error bar.

### Exercise 4

1. HPA scales to hold `usage / request ≈ target`. With `request = 1000m` and `usage ≈ 25m`, utilization is `25/1000 = 2.5%`, far under the `70%` target, so the HPA computes desired replicas as `ceil(current × 2.5/70)` → it would try to scale *down* to `minReplicas` and never scale up until usage exceeded `700m` per pod — which this workload never reaches. The wrong denominator makes the percentage meaningless, so the scaler is effectively disabled. Right-sizing the request to `30m` makes `70%` correspond to a real load level (~21m) the pod actually hits.
2. Fast scale-up protects **reliability**: when load spikes you want capacity *now*, so zero stabilization and a 100%/30s policy. Slow scale-down protects both **reliability and cost stability**: a 300s window prevents removing pods on a brief dip and then immediately re-adding them (flapping), which would churn pods, cost scheduling latency, and risk under-capacity if the dip was noise. You accept a little extra cost on the way down to buy stability.
3. A **memory limit** is needed because memory is incompressible — without a ceiling a leak can consume the node and take neighbours down (OOM). A **CPU limit** is deliberately omitted because a CPU limit installs a cgroup CFS quota that *throttles* the container even when the node has spare CPU, hurting latency for no benefit; the CPU *request* already guarantees the scheduler reserves the pod's share, and the HPA — not a hard cap — is the correct mechanism to add capacity. So: cap the thing that kills the node, don't cap the thing that only throttles itself.
4. `minReplicas: 2` guarantees the service survives the loss of a single pod/node and can serve during a rolling update — a single replica has no redundancy. The Kubernetes-native protection for those replicas during *voluntary* disruptions (node drains, consolidation, upgrades) is a **PodDisruptionBudget**.

### Exercise 5

1. Cutting *pod requests* only changes what the scheduler reserves; it does not remove nodes. Nodes are billed whole. Until a **node autoscaler** (Cluster Autoscaler or Karpenter) notices the now-underutilized nodes and drains/removes or consolidates them, the freed pod capacity just becomes empty space you still pay for. The node-level controller closes the gap between pod-level savings and the actual bill.
2. "Consolidation replace" evicts pods off a node to move them onto a cheaper/fuller node — a **voluntary disruption**. Without a PDB, Karpenter could evict enough replicas simultaneously to drop the service below its serving quorum. The PDB (`minAvailable: 2`) forces the disruption to proceed one-safe-step at a time, so consolidation can save money without an outage.
3. Before right-sizing, pods requested `1000m` each, so a node hosting a few of them looked "well-utilized" (requests near capacity) and never crossed under the 50% threshold — even though real *usage* was tiny. After you drop requests to `30m`, the same node's *requested* utilization collapses below 50%, so it finally becomes a scale-down candidate and the autoscaler consolidates it. That is the causal link: pod right-sizing (Ex. 2–4) is what *unlocks* node-level consolidation and turns efficiency into a lower bill.
4. **Spot** is safe only for workloads that tolerate **interruption** — replicas are stateless/restartable and the app handles node reclaim gracefully (multiple replicas + PDB + fast reschedule). **arm64** is safe only if the workload's container images are **built for arm64** (multi-arch/Graviton-compatible binaries); a linux/amd64-only image will crash-loop on an arm64 node.

### Exercise 6

1. (a) A ratio normalizes across workload sizes — `usage < 100m` would false-positive on every small legitimate service and miss a huge over-provisioned one whose absolute usage is still >100m; efficiency `<20%` flags *waste* regardless of size. (b) `for: 6h` filters out transient idleness (nightly lulls, deploy gaps) so you alert on *sustained* over-provisioning, not on a quiet afternoon. Together they catch "consistently reserving far more than used," which is exactly over-provisioning.
2. On admission, for each pod that omits requests, the **LimitRange** admission plugin injects `defaultRequest` (`cpu: 50m`) into the container spec *before* quota is evaluated. Then the **ResourceQuota** admission check sums `requests.cpu` across the namespace against the `4` (= 4000m) ceiling. 100 pods × 50m = 5000m > 4000m, so once the running total crosses 4 CPU the quota admission plugin **rejects** the remaining pod creations with a quota-exceeded error. LimitRange fills the blank; ResourceQuota enforces the cap; the quota needs the defaults to exist or unrequested pods would count as zero and bypass it.
3. Any two of: **traffic/usage patterns change** (growth, seasonality, a new feature raising per-request cost); **the workload changes** (a new image, dependency, or JVM/GC setting shifts the real footprint); **the platform changes** (node instance types, kernel/runtime, or co-tenant pressure alter observed usage); **replica topology changes** (HPA min/max or sharding changes per-pod load). Because the inputs drift, yesterday's correct request becomes today's over- or under-provisioning — hence the loop.

</details>