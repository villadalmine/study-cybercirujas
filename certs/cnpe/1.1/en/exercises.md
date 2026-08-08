# Guided Exercises — CNPE 1.1: Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> **Scenario.** You are on the platform team that operates a shared Kubernetes cluster as an Internal Developer Platform (IDP). Two tenant teams — `team-alpha` (a stateless API) and `team-beta` (a stateful data service) — onboard onto your "paved road." Your job in this lab is to encode the three architectural pillars — **compute**, **storage**, and **networking** — as *guardrails* the tenants inherit, not as one-off requests they file tickets for. Every step below is something a platform engineer runs when defining that blueprint.
>
> **Prerequisites.** A cluster where you are `cluster-admin` (kind, minikube, or a managed cluster), `kubectl` ≥ 1.29, the Gateway API CRDs installable, and a CNI that enforces `NetworkPolicy` (Cilium, Calico — kind's default kindnet does **not** enforce policies, so use `kind` with Calico or a managed cluster for Exercise 3). Commands assume a POSIX shell.

---

## Exercise 1 — Compute guardrails: quota, defaults, and priority

A platform without compute guardrails lets one tenant's runaway `Deployment` starve every other tenant and evict the control-plane's own critical add-ons. The best practice is **defense in depth**: a hard ceiling per namespace (`ResourceQuota`), sane per-container defaults so pods are never `BestEffort` by accident (`LimitRange`), and a documented eviction order (`PriorityClass`).

### Steps

1. Create the tenant namespace and label it so policy tooling can target it:

   ```bash
   kubectl create namespace team-alpha
   kubectl label namespace team-alpha platform.example.com/tenant=alpha tier=standard
   ```

2. Apply a `ResourceQuota` that caps both the *requests* (what the scheduler reserves) and the *limits* (the hard cgroup ceiling), plus object counts:

   ```yaml
   # quota-alpha.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-alpha-quota
     namespace: team-alpha
   spec:
     hard:
       requests.cpu: "10"
       requests.memory: 20Gi
       limits.cpu: "20"
       limits.memory: 40Gi
       pods: "50"
       count/services.loadbalancers: "2"
       persistentvolumeclaims: "10"
   ```

   ```bash
   kubectl apply -f quota-alpha.yaml
   ```

3. Apply a `LimitRange` so that any container submitted *without* explicit resources still lands in the `Burstable` QoS class instead of `BestEffort`:

   ```yaml
   # limitrange-alpha.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: team-alpha-limits
     namespace: team-alpha
   spec:
     limits:
       - type: Container
         min:            { cpu: 100m,  memory: 64Mi }
         max:            { cpu: "2",   memory: 2Gi }
         default:        { cpu: 500m,  memory: 256Mi }   # applied as the limit
         defaultRequest: { cpu: 250m,  memory: 128Mi }   # applied as the request
   ```

   ```bash
   kubectl apply -f limitrange-alpha.yaml
   kubectl describe resourcequota team-alpha-quota -n team-alpha
   ```

   Expected (abridged):

   ```
   Name:            team-alpha-quota
   Namespace:       team-alpha
   Resource         Used  Hard
   --------         ----  ----
   limits.cpu       0     20
   limits.memory    0     40Gi
   pods             0     50
   requests.cpu     0     10
   requests.memory  0     20Gi
   ```

4. Try to violate the guardrail — submit a bare pod with **no** resources and watch the `LimitRange` inject them:

   ```bash
   kubectl run probe --image=registry.k8s.io/pause:3.9 -n team-alpha
   kubectl get pod probe -n team-alpha \
     -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   ```

   Expected:

   ```
   {"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"128Mi"}}
   ```

5. Define a cluster-scoped `PriorityClass` for platform add-ons so they win eviction races against tenant workloads, and a low one tenants can opt into for batch jobs:

   ```yaml
   # priorityclasses.yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: { name: platform-critical }
   value: 1000000
   globalDefault: false
   description: "Platform add-ons (ingress, CSI, observability). Evicted last."
   ---
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: { name: tenant-batch }
   value: 100
   preemptionPolicy: Never
   globalDefault: false
   description: "Best-effort batch. Never preempts others; evicted first."
   ```

   ```bash
   kubectl apply -f priorityclasses.yaml
   kubectl get priorityclass
   ```

### Comprehension questions — Block 1

1. A tenant sets `requests.cpu: 8` on a Deployment of 2 replicas but leaves limits blank. Given the `LimitRange` and `ResourceQuota` above, does the second replica schedule? Show the arithmetic that decides it.
2. Why does the quota constrain **both** `requests.*` and `limits.*` rather than just one? What failure mode does each column prevent?
3. The `tenant-batch` PriorityClass sets `preemptionPolicy: Never`. What is the practical difference between a *low value* and a *non-preempting* priority — and why do you want both for batch?
4. A `ResourceQuota` that sets `requests.cpu`/`limits.cpu` forces every pod in the namespace to declare those fields. Which object above prevents that constraint from turning into a wall of rejected pods for tenants who forget?

---

## Exercise 2 — Storage architecture: tiers, topology, and the reclaim contract

A platform exposes storage as **tiers with meaning** (`fast-ssd`, `standard`, `archive`) rather than leaking the cloud provider's driver names to tenants. Two architectural decisions dominate: the **binding mode** (which decides *when* a volume is provisioned relative to scheduling) and the **reclaim policy** (which decides whether a deleted PVC destroys the tenant's data).

### Steps

1. Inspect what the cluster ships with — most managed clusters mark exactly one class `(default)`:

   ```bash
   kubectl get storageclass
   ```

   Example:

   ```
   NAME              PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
   gp2 (default)     ebs.csi.aws.com   Delete          WaitForFirstConsumer   true                   40d
   ```

2. Define a **tiered** set of classes as platform-owned abstractions. Note `WaitForFirstConsumer` (topology-aware) and `allowVolumeExpansion: true` on both:

   ```yaml
   # storageclasses.yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast-ssd
     annotations:
       storageclass.kubernetes.io/is-default-class: "false"
   provisioner: ebs.csi.aws.com
   parameters: { type: gp3, iops: "6000", throughput: "250" }
   reclaimPolicy: Delete
   allowVolumeExpansion: true
   volumeBindingMode: WaitForFirstConsumer
   ---
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: standard-retain
   provisioner: ebs.csi.aws.com
   parameters: { type: gp3 }
   reclaimPolicy: Retain        # data survives PVC deletion — for stateful tenants
   allowVolumeExpansion: true
   volumeBindingMode: WaitForFirstConsumer
   ```

   ```bash
   kubectl apply -f storageclasses.yaml
   ```

3. Give `team-beta` a `StatefulSet` whose `volumeClaimTemplates` bind the retain tier. This is the correct pattern for per-replica durable storage:

   ```yaml
   # statefulset-beta.yaml
   apiVersion: apps/v1
   kind: StatefulSet
   metadata: { name: db, namespace: team-beta }
   spec:
     serviceName: db
     replicas: 3
     selector: { matchLabels: { app: db } }
     template:
       metadata: { labels: { app: db } }
       spec:
         containers:
           - name: db
             image: registry.k8s.io/pause:3.9
             volumeMounts: [ { name: data, mountPath: /var/lib/db } ]
     volumeClaimTemplates:
       - metadata: { name: data }
         spec:
           accessModes: [ "ReadWriteOnce" ]
           storageClassName: standard-retain
           resources: { requests: { storage: 20Gi } }
   ```

   ```bash
   kubectl create namespace team-beta
   kubectl apply -f statefulset-beta.yaml
   kubectl get pvc -n team-beta
   ```

   Expected — one PVC per ordinal, each `Bound` only once its pod is scheduled:

   ```
   NAME        STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS      AGE
   data-db-0   Bound    pvc-a1b2..   20Gi       RWO            standard-retain   30s
   data-db-1   Bound    pvc-c3d4..   20Gi       RWO            standard-retain   20s
   data-db-2   Bound    pvc-e5f6..   20Gi       RWO            standard-retain   10s
   ```

4. Demonstrate online expansion (no downtime) — edit the PVC request upward:

   ```bash
   kubectl patch pvc data-db-0 -n team-beta \
     --type merge -p '{"spec":{"resources":{"requests":{"storage":"40Gi"}}}}'
   kubectl get pvc data-db-0 -n team-beta \
     -o jsonpath='{.status.capacity.storage}{"\n"}'
   ```

5. Prove the reclaim contract. Delete PVC `data-db-2`, then inspect the underlying `PersistentVolume`:

   ```bash
   kubectl delete pvc data-db-2 -n team-beta
   kubectl get pv | grep data-db-2
   ```

   Expected — the PV moves to `Released`, **not** `Deleted`, because the tier is `Retain`:

   ```
   pvc-e5f6..   20Gi   RWO   Retain   Released   team-beta/data-db-2   standard-retain
   ```

### Comprehension questions — Block 2

1. `WaitForFirstConsumer` versus `Immediate`: on a multi-AZ cluster, what concrete scheduling failure does `Immediate` binding cause for a single-attach (`ReadWriteOnce`) EBS volume, and how does the topology-aware mode avoid it?
2. `team-beta`'s tier is `Retain`. After you deleted `data-db-2`, its PV is `Released`. Can a *new* PVC named `data-db-2` automatically re-bind to that PV? What must the operator do first, and why is that friction the point?
3. You scaled the `StatefulSet` from 3 replicas down to 1. What happens to `data-db-1` and `data-db-2`? Why does Kubernetes deliberately **not** delete those PVCs on scale-down?
4. Why is exposing tiers named `fast-ssd`/`standard-retain` — rather than telling tenants to write `provisioner: ebs.csi.aws.com, type: gp3` themselves — an *architectural* decision and not just cosmetics? Name one migration it enables.

---

## Exercise 3 — Network architecture: default-deny and north-south ingress

The two network questions a platform must answer are **east-west** (which pods may talk to which — solved with `NetworkPolicy` in a default-deny posture) and **north-south** (how traffic enters — solved with the `Gateway API`, the successor to Ingress). A namespace with no policies is fully open; the best practice is to make *deny* the inherited default and require tenants to open holes explicitly.

### Steps

1. Establish a **default-deny** baseline for all ingress and egress in the tenant namespace:

   ```yaml
   # default-deny.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: default-deny-all, namespace: team-alpha }
   spec:
     podSelector: {}                 # selects every pod in the namespace
     policyTypes: [ Ingress, Egress ]
   ```

   ```bash
   kubectl apply -f default-deny.yaml
   ```

2. Punch two precise holes: allow DNS egress to CoreDNS (or nothing resolves), and allow ingress **only** from the ingress-gateway namespace:

   ```yaml
   # allow-dns-and-gateway.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-dns-egress, namespace: team-alpha }
   spec:
     podSelector: {}
     policyTypes: [ Egress ]
     egress:
       - to:
           - namespaceSelector:
               matchLabels: { kubernetes.io/metadata.name: kube-system }
         ports:
           - { protocol: UDP, port: 53 }
           - { protocol: TCP, port: 53 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-from-gateway, namespace: team-alpha }
   spec:
     podSelector: { matchLabels: { app: api } }
     policyTypes: [ Ingress ]
     ingress:
       - from:
           - namespaceSelector:
               matchLabels: { kubernetes.io/metadata.name: gateway-system }
         ports:
           - { protocol: TCP, port: 8080 }
   ```

   ```bash
   kubectl apply -f allow-dns-and-gateway.yaml
   ```

3. Verify the posture with two probes — one that must fail, one that must succeed:

   ```bash
   # cross-tenant call MUST be blocked (times out)
   kubectl run t -n team-beta --rm -it --image=nicolaka/netshoot --restart=Never -- \
     curl -m 3 http://api.team-alpha.svc.cluster.local:8080 ; echo "exit=$?"

   # DNS resolution MUST still work (egress hole is open)
   kubectl run t -n team-alpha --rm -it --image=nicolaka/netshoot --restart=Never -- \
     nslookup kubernetes.default
   ```

   Expected: the first prints `exit=28` (curl timeout — traffic dropped); the second resolves the `10.96.0.1` ClusterIP.

4. Provision north-south entry with the **Gateway API** — a platform-owned `Gateway`, then a tenant-owned `HTTPRoute` that attaches to it. This is the role split the API was designed for:

   ```yaml
   # gateway.yaml  (owned by the platform team, in gateway-system)
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata: { name: platform-gw, namespace: gateway-system }
   spec:
     gatewayClassName: cilium        # or nginx, istio, envoy-gateway, ...
     listeners:
       - name: http
         protocol: HTTP
         port: 80
         allowedRoutes:
           namespaces: { from: All }
   ---
   # httproute.yaml  (owned by team-alpha)
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata: { name: api-route, namespace: team-alpha }
   spec:
     parentRefs:
       - { name: platform-gw, namespace: gateway-system }
     hostnames: [ "alpha.apps.example.com" ]
     rules:
       - matches: [ { path: { type: PathPrefix, value: / } } ]
         backendRefs: [ { name: api, port: 8080 } ]
   ```

   ```bash
   kubectl apply -f gateway.yaml -f httproute.yaml
   kubectl get gateway platform-gw -n gateway-system
   ```

   Expected — the Gateway reports a programmed address:

   ```
   NAME          CLASS    ADDRESS         PROGRAMMED   AGE
   platform-gw   cilium   203.0.113.10    True         15s
   ```

### Comprehension questions — Block 3

1. In Step 2, `allow-from-gateway` selects `app: api` while `default-deny-all` selects `{}` (everything). NetworkPolicies are purely additive with no deny rules — so how do these two objects combine to produce "allow port 8080 from the gateway, deny everything else to the api pods"?
2. Why must you *explicitly* allow egress to `kube-system:53` after a default-deny-egress? What symptom does a tenant see if you forget, and why is it so confusing to debug?
3. The `Gateway` lives in `gateway-system` and the `HTTPRoute` in `team-alpha`. Which team owns which object, and what platform-architecture problem does this two-resource split solve that a single monolithic `Ingress` object could not?
4. Your cluster uses kindnet as its CNI. You apply `default-deny-all` and the cross-tenant curl in Step 3 **still succeeds**. Nothing is wrong with your YAML — what is the architectural root cause, and what does it teach you about the relationship between the `NetworkPolicy` API and the data plane?

---

## Exercise 4 — Composing the three pillars: spread, autoscale, and fail

The pillars are not independent. A resilient tenant workload needs compute *placement* (topology spread so one AZ failure ≠ outage), compute *elasticity* (HPA), and it must respect the storage constraint that an `RWO` volume pins a pod to one node. This exercise composes them and then forces a failure to observe the guardrails holding.

### Steps

1. Deploy `team-alpha`'s API with a `topologySpreadConstraint` across zones and a `PodDisruptionBudget` so voluntary disruptions can't take it fully down:

   ```yaml
   # api-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: api, namespace: team-alpha }
   spec:
     replicas: 4
     selector: { matchLabels: { app: api } }
     template:
       metadata: { labels: { app: api } }
       spec:
         containers:
           - name: api
             image: registry.k8s.io/e2e-test-images/agnhost:2.45
             args: [ "netexec", "--http-port=8080" ]
             ports: [ { containerPort: 8080 } ]
             resources:
               requests: { cpu: 250m, memory: 128Mi }
               limits:   { cpu: 500m, memory: 256Mi }
         topologySpreadConstraints:
           - maxSkew: 1
             topologyKey: topology.kubernetes.io/zone
             whenUnsatisfiable: DoNotSchedule
             labelSelector: { matchLabels: { app: api } }
   ---
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata: { name: api-pdb, namespace: team-alpha }
   spec:
     minAvailable: 2
     selector: { matchLabels: { app: api } }
   ```

   ```bash
   kubectl apply -f api-deploy.yaml
   kubectl get pods -n team-alpha -l app=api \
     -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels'
   ```

2. Add a Service and an `HPA` targeting 60% CPU:

   ```yaml
   # api-hpa.yaml
   apiVersion: v1
   kind: Service
   metadata: { name: api, namespace: team-alpha }
   spec:
     selector: { app: api }
     ports: [ { port: 8080, targetPort: 8080 } ]
   ---
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata: { name: api-hpa, namespace: team-alpha }
   spec:
     scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: api }
     minReplicas: 4
     maxReplicas: 12
     metrics:
       - type: Resource
         resource: { name: cpu, target: { type: Utilization, averageUtilization: 60 } }
   ```

   ```bash
   kubectl apply -f api-hpa.yaml
   kubectl get hpa api-hpa -n team-alpha
   ```

   Expected (once metrics-server reports):

   ```
   NAME      REFERENCE         TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
   api-hpa   Deployment/api    cpu: 12%/60%  4         12        4          1m
   ```

3. Force the interaction between HPA and the quota from Exercise 1. Each replica requests 250m CPU; the quota's `requests.cpu` is `10`. Drive load and watch what caps scaling first:

   ```bash
   # generate load from inside the cluster
   kubectl run load -n team-alpha --image=busybox --restart=Never -- \
     /bin/sh -c "while true; do wget -q -O- http://api:8080/; done"
   watch kubectl get hpa,pods -n team-alpha -l app=api
   ```

4. Inspect *why* scaling stops if it stops short of `maxReplicas: 12`:

   ```bash
   kubectl describe hpa api-hpa -n team-alpha | sed -n '/Conditions/,/Events/p'
   kubectl get events -n team-alpha --field-selector reason=FailedCreate
   ```

### Comprehension questions — Block 4

1. Do the math: with `requests.cpu: 250m` per replica and a `ResourceQuota` of `requests.cpu: 10`, what is the *maximum* replica count the quota permits — and does the HPA's `maxReplicas: 12` or the quota bind first? What event reason appears when the loser is hit?
2. `whenUnsatisfiable: DoNotSchedule` with `maxSkew: 1` across 3 zones — describe the scheduling behavior when a fourth-zone node is unavailable and 4 replicas must place across 3 zones. When would you soften this to `ScheduleAnyway`, and what do you trade away?
3. Explain the collision between an `RWO` PersistentVolume and an HPA scale-up: if the `team-beta` StatefulSet's pods each own an `RWO` volume, why can't an HPA simply "add replicas" the way it does for the stateless `api` Deployment? What is the storage pillar imposing on the compute pillar?
4. A `PodDisruptionBudget` of `minAvailable: 2` is set. During a node drain for a cluster upgrade, the platform's automation tries to evict 3 of the 4 api pods at once. What does the eviction API do, and how does this connect the compute pillar to the *operability* of the whole platform?

---

## Answers

<details>
<summary>Click to reveal answers for all four exercise blocks</summary>

### Block 1 — Compute guardrails

1. **Yes, the second replica schedules — but not because of the requests you'd expect.** The tenant set `requests.cpu: 8` per container. Two replicas = `16` requested CPU, which **exceeds** the quota's `requests.cpu: 10`. So the *first* replica consumes 8/10; the second would need 16/10 and is **rejected** by the quota with `forbidden: exceeded quota`. The Deployment shows `1/2` ready and an event on the ReplicaSet. The trap is that the `LimitRange`'s `max: cpu 2` also *rejects* an 8-CPU container outright at admission — so in practice the pod never even reaches the quota check; the `LimitRange` `maximum cpu usage per Container is 2` denies it first. Either way the answer is the workload is capped; the arithmetic to internalize is *sum of requests across all pods ≤ quota hard request*.

2. **`requests.*` governs schedulability; `limits.*` governs the blast radius.** The requests column prevents *overcommit at the scheduler*: it caps how much the namespace can *reserve*, so tenants can't lock up capacity other tenants need even while idle. The limits column caps the *cgroup ceiling*: it prevents a namespace from bursting (memory especially) into node-wide OOM pressure that harms neighbors on the same node. Constraining only requests would let a namespace burst without bound; constraining only limits would let it reserve capacity it never uses via low requests. You need both because they act at different layers (scheduler vs. kubelet/cgroup).

3. **Value decides *who wins* a preemption; `preemptionPolicy` decides *whether this pod is allowed to trigger one*.** A low *value* means when the scheduler must choose a victim, this pod loses (it's evicted first under pressure). `preemptionPolicy: Never` means this pod, when it can't schedule, will **not** evict anyone else to make room — it just waits `Pending`. For batch you want both: low value so real-time workloads reclaim capacity by evicting the batch job, and non-preempting so a burst of queued batch jobs never disrupts latency-sensitive tenants just to start faster.

4. **The `LimitRange`.** A `ResourceQuota` that constrains `requests.cpu`/`limits.cpu` makes those fields *mandatory* for every pod — any pod omitting them is rejected. The `LimitRange`'s `default`/`defaultRequest` inject those fields at admission for pods that don't set them, so tenant manifests without resources are *mutated into compliance* instead of rejected. This is why the two objects are always deployed as a pair: the quota is the wall, the LimitRange is the door.

### Block 2 — Storage architecture

1. **`Immediate` binding provisions the volume the moment the PVC is created, before the scheduler has chosen a node — so the EBS volume can be created in AZ `us-east-1a` while the only node with spare capacity is in `us-east-1b`.** An `RWO` EBS volume can only attach to a node in its *own* AZ, so the pod is stuck `Pending` forever with a `volume node affinity conflict`. `WaitForFirstConsumer` defers provisioning until the scheduler picks the node; the volume is then created in that node's zone, guaranteeing they match. This is *the* reason topology-aware binding is the platform default on multi-AZ clusters.

2. **No, it cannot auto-rebind.** A `Released` PV still references the *UID* of the deleted PVC in its `claimRef`, so a new PVC with the same name (but a new UID) won't bind. The operator must manually `kubectl patch pv ... -p '{"spec":{"claimRef":null}}'` to clear the reference (making it `Available`), after deciding whether the old data should be reused or wiped. That friction *is the point* of `Retain`: deleting a PVC on a stateful tier must not silently destroy data, and re-binding must be a deliberate human act, not an automatic one.

3. **Nothing happens to `data-db-1` and `data-db-2` — the PVCs and their PVs survive.** StatefulSet scale-down deletes the *pods* but deliberately **orphans** the PVCs (this is governed by `persistentVolumeClaimRetentionPolicy`, which defaults to `Retain` on scale-down). The rationale: scale-down is often temporary or a mistake, and a database's data is not disposable. If you scale back up to 3, `db-2` re-attaches its existing `data-db-2` and recovers its state. Deleting the data on scale-down would make an accidental `--replicas=1` catastrophic.

4. **It decouples the tenant's contract from the implementation.** Tenants request a *capability* (`fast-ssd`, durable) not a *vendor* (`ebs.csi.aws.com, type: gp3`). This is what lets the platform team migrate the class's `provisioner`/`parameters` — e.g. from `gp2` to `gp3`, or from EBS to a different CSI driver during a cloud migration — by editing one StorageClass, without a single tenant manifest changing. It also lets the platform enforce policy (encryption, IOPS floors) uniformly. Leaking driver names into tenant YAML would freeze the implementation and force a fleet-wide edit for any change.

### Block 3 — Network architecture

1. **NetworkPolicies are whitelist-only and additive: a pod selected by *any* policy is default-deny for the traffic direction of that policy, and only the *union* of matching `allow` rules is permitted.** `default-deny-all` selects every pod and opens nothing → all ingress denied. `allow-from-gateway` selects `app: api` and opens one hole (TCP 8080 from `gateway-system`). For the api pods, the effective ingress set is the union of the two policies' allow rules = `{port 8080 from gateway-system}`. Everything else stays denied. There is no explicit deny needed (or possible) — the *absence* of an allow rule, once *any* policy selects the pod, is the deny.

2. **A default-deny-egress policy blocks the pod's UDP/53 packets to CoreDNS, so every hostname lookup fails.** The confusing symptom: `curl https://api.internal` returns `Could not resolve host` or hangs, and the tenant assumes *ingress* to the target is broken or the service is down — when the actual failure is their *own pod's egress to DNS*. It's notoriously hard to debug because the error surfaces at the application layer far from the policy. That's why "allow DNS egress" is the mandatory first companion rule to any default-deny-egress baseline.

3. **The platform team owns the `Gateway` (and `GatewayClass`); the tenant owns the `HTTPRoute`.** This is the Gateway API's deliberate **role-oriented** model: infrastructure concerns (which load balancer, TLS certs, listener ports, allowed hostnames) are configured once by the platform on the `Gateway`, while routing concerns (paths, backends, header matches) are self-served by tenants via `HTTPRoute` objects that *attach* to the shared gateway. A monolithic `Ingress` conflated both roles into one object owned by one party, forcing either tenants to touch shared infra config or the platform to file tickets for every route change. The split is what makes north-south entry a paved road.

4. **The root cause: `NetworkPolicy` is an API, not an enforcer — kindnet does not implement policy enforcement.** The API server happily stores your `NetworkPolicy` object, but nothing drops packets unless the CNI's data plane (Cilium, Calico, etc.) programs the rules (via eBPF or iptables). kindnet has no policy controller, so every policy is a no-op. The lesson is architectural: choosing a CNI is a *networking best-practice decision*, because your entire east-west security posture is only as real as the data plane that enforces it. "The policy exists" and "the traffic is blocked" are different claims — verify with an actual probe (Step 3), never by `kubectl get networkpolicy`.

### Block 4 — Composing the pillars

1. **Quota binds first.** Each replica requests 250m CPU; quota `requests.cpu: 10` ÷ 0.25 = **40 replicas** of headroom from CPU requests alone — but the namespace also runs the `probe` pod, the `load` pod, and any others, all drawing on the same 10-CPU budget, and there is also `pods: 50`. The HPA's `maxReplicas: 12` is well under 40, so on CPU the *HPA* caps first at 12. **However**, if other pods in the namespace have consumed enough of the 10-CPU request budget that fewer than 12×0.25 = 3 CPU remain, the *quota* binds first: the HPA raises the Deployment's replica count, but the ReplicaSet can't create the pods and you see `FailedCreate` events with `exceeded quota: team-alpha-quota, requested: requests.cpu=250m, used: ..., limited: requests.cpu=10`. The HPA reports `ScalingLimited` and gets stuck below `desiredReplicas`. Takeaway: the quota is a *silent ceiling on autoscaling* — the two guardrails must be sized consistently or tenants get mystifying "HPA says 12 but I have 8 pods" behavior.

2. **With `maxSkew: 1` and 3 available zones, 4 replicas place as 2-1-1 (one zone gets the extra, skew = 2−1 = 1, satisfied).** If a fourth zone's node is unavailable and you *require* a 1-1-1-1 spread but only 3 zones can host pods, the 4th replica sees that placing it anywhere makes skew = 2 while an empty (unschedulable) zone exists — with `DoNotSchedule` it stays **`Pending`** rather than violate the constraint. You soften to `ScheduleAnyway` when *availability* matters more than *perfect balance* — the scheduler then treats spread as a soft preference and places the pod, accepting temporary skew. The trade: you regain schedulability (no stuck-Pending replica) but lose the guarantee that one zone failure can't take down a disproportionate share of replicas. Stateless front-ends often use `ScheduleAnyway`; quorum systems that must survive an AZ loss use `DoNotSchedule`.

3. **An HPA on an `RWO`-backed StatefulSet can add pods, but each new pod needs its *own* new `RWO` PVC from the `volumeClaimTemplate` — it does not share the existing volume.** RWO means single-node read-write attach, so replicas cannot mount the same volume; "scaling" a stateful service means provisioning fresh independent storage and, usually, joining a replication/sharding protocol at the application layer — which the HPA knows nothing about. This is why HPAs are natural for *stateless* Deployments and problematic for stateful sets: the storage pillar imposes that compute elasticity for stateful data isn't free horizontal replication; it's data placement and (often) a rebalance the platform must orchestrate outside the HPA. The compute pillar cannot treat a stateful replica as fungible the way it treats a stateless one.

4. **The eviction API (`/eviction` subresource) honors the PDB: it will evict pods only while `≥ minAvailable` remain available, and *rejects* (HTTP 429, `Cannot evict pod as it would violate the pod's disruption budget`) any eviction that would drop below 2.** So the drain evicts at most 2 of the 4, then blocks and retries until the Deployment reschedules replacements elsewhere and they become Ready, before evicting more. This connects compute to platform operability: node drains for upgrades, autoscaler scale-down, and maintenance are all *voluntary disruptions* gated by PDBs. Without the PDB the drain would evict all 4 at once and cause an outage; with it, the platform's lifecycle automation (upgrades, patching, consolidation) can proceed safely and unattended. The PDB is the contract that makes the cluster *operable* without coordinating with every tenant.

</details>

---

### Sources

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Resource Quotas — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Limit Ranges — https://kubernetes.io/docs/concepts/policy/limit-range/
- Pod Priority and Preemption — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Storage Classes & volume binding mode — https://kubernetes.io/docs/concepts/storage/storage-classes/
- StatefulSet PVC retention — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Gateway API — https://gateway-api.sigs.k8s.io/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Horizontal Pod Autoscaler — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Pod Disruption Budgets — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/