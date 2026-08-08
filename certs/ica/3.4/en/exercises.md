# 3.4 Configuring Traffic Shifting — Guided Exercises

Traffic shifting is the controlled migration of request volume from one workload version to another by **weight**, decoupled from the number of running pod replicas. In Istio this is expressed entirely in the control plane: a `DestinationRule` names the *subsets* (the versions), and a `VirtualService` assigns a percentage `weight` to each subset inside an `HTTPRoute`. The Envoy sidecars enforce the split per-request — Kubernetes `Service` scaling and readiness are irrelevant to the ratio.

These exercises build a canary rollout from a pinned baseline, drive it to completion, roll it back, then combine weighting with header matching and traffic mirroring. Every step is verifiable from the CLI.

**Lab topology.** The official `helloworld` sample ships two deployments — `helloworld-v1` and `helloworld-v2` — both fronted by one `Service` (`helloworld:5000`), each returning a body that names its version. A `sleep` pod inside the mesh is the client, so we can count the response distribution deterministically.

Reference sources:
- Traffic shifting task — https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- VirtualService `HTTPRouteDestination.weight` — https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRouteDestination
- DestinationRule subsets — https://istio.io/latest/docs/reference/config/networking/destination-rule/#Subset
- Traffic mirroring task — https://istio.io/latest/docs/tasks/traffic-management/mirroring/

---

## Exercise 1 — Establish a pinned baseline (100% v1)

Before shifting anything, you must be able to *stop* the shift. The safe starting point is a `VirtualService` that sends **all** traffic to a single subset. Without an explicit rule, Istio round-robins across every endpoint of the `Service`, mixing versions — that is not a controlled state.

1. Create the mesh namespace and enable sidecar injection:

   ```bash
   kubectl create namespace demo
   kubectl label namespace demo istio-injection=enabled --overwrite
   ```

2. Deploy the two versions and the client:

   ```bash
   kubectl -n demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/helloworld/helloworld.yaml
   kubectl -n demo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/sleep/sleep.yaml
   kubectl -n demo rollout status deploy/helloworld-v1
   kubectl -n demo rollout status deploy/helloworld-v2
   ```

3. Confirm that, *with no routing rule*, traffic is split roughly 50/50 by default (each version has one endpoint):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected (approximate — plain round-robin, not a policy):

   ```
     11 version: v1
      9 version: v2
   ```

4. Declare the subsets with a `DestinationRule`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: helloworld
     namespace: demo
   spec:
     host: helloworld
     subsets:
     - name: v1
       labels:
         version: v1
     - name: v2
       labels:
         version: v2
   ```

5. Pin 100% of traffic to `v1` with a `VirtualService`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 100
       - destination:
           host: helloworld
           subset: v2
         weight: 0
   ```

6. Apply both and re-run the distribution check:

   ```bash
   kubectl -n demo apply -f destinationrule.yaml -f virtualservice.yaml
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected:

   ```
     20 version: v1
   ```

**Comprehension check 1**

1. Both versions still have one running pod each. Why did the distribution change from ~50/50 to 100/0 without touching any `Deployment`?
2. What breaks if you apply the `VirtualService` from step 5 **before** the `DestinationRule` from step 4?
3. The rule sends 100% to `v1`. What is the practical difference between including `subset: v2` with `weight: 0` versus omitting the `v2` destination entirely?

---

## Exercise 2 — Introduce a 10% canary

Now shift a small slice to `v2` while keeping the rollback path open. A canary weight lets a real fraction of production traffic exercise the new version before you trust it.

1. Patch the weights to 90/10:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 90
       - destination:
           host: helloworld
           subset: v2
         weight: 10
   ```

2. Apply and sample a larger population so the ratio is meaningful:

   ```bash
   kubectl -n demo apply -f virtualservice.yaml
   for i in $(seq 1 100); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected (statistical, not exact):

   ```
     88 version: v1
     12 version: v2
   ```

3. Inspect what the *client's* Envoy actually programmed — the weights become weighted clusters in the route config:

   ```bash
   istioctl -n demo proxy-config routes deploy/sleep --name 5000 -o json \
     | grep -A2 -i 'weightedClusters\|weight'
   ```

   Expected fragment:

   ```json
   "weightedClusters": {
     "clusters": [
       { "name": "outbound|5000|v1|helloworld.demo.svc.cluster.local", "weight": 90 },
       { "name": "outbound|5000|v2|helloworld.demo.svc.cluster.local", "weight": 10 }
     ]
   }
   ```

**Comprehension check 2**

1. In step 3 the split is enforced on the **`sleep` sidecar** (the caller), not on the `helloworld` pods. What does that tell you about *where* Istio's L7 traffic-shifting decision is made, and why does that matter for latency and blast radius?
2. If you scaled `helloworld-v2` from 1 replica to 10, would the observed split move toward 50/50? Explain.
3. You sampled 100 requests and saw 12 land on `v2`. Is the rule broken? What would you change to reduce the noise in this measurement?

---

## Exercise 3 — Progressive rollout to 100%, then roll back

A rollout is a sequence of weight edits, each gated on the previous stage's telemetry. Here you advance 10 → 50 → 100, then perform an instant rollback.

1. Move to 50/50:

   ```bash
   kubectl -n demo patch virtualservice helloworld --type merge -p '
   spec:
     http:
     - route:
       - destination: {host: helloworld, subset: v1}
         weight: 50
       - destination: {host: helloworld, subset: v2}
         weight: 50'
   ```

2. Verify the halfway point over 100 requests (expect ≈50/50), then cut over fully to `v2`:

   ```yaml
   # virtualservice-v2.yaml — single destination, weight is now optional
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v2
   ```

   ```bash
   kubectl -n demo apply -f virtualservice-v2.yaml
   for i in $(seq 1 30); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected:

   ```
     30 version: v2
   ```

3. Simulate a regression discovered in production and **roll back instantly** to `v1`:

   ```bash
   kubectl -n demo patch virtualservice helloworld --type merge -p '
   spec:
     http:
     - route:
       - destination: {host: helloworld, subset: v1}'
   ```

4. Confirm the rollback took effect and time how fast it propagated (Envoy picks up the pushed config in well under a second — no pod restart):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected:

   ```
     20 version: v1
   ```

**Comprehension check 3**

1. In step 2 the final rule has a single `destination` and **no `weight` field**, yet Istio accepts it. What is the rule about when `weight` is required versus optional across an `HTTPRoute`'s destinations?
2. What happens at apply time if you write `weight: 60` for `v1` and `weight: 30` for `v2` (sum = 90)? Is it rejected, silently normalized, or something else?
3. The rollback in step 3 required no `kubectl rollout undo` and no image change. Explain, in terms of the data plane, why traffic shifting gives you a faster rollback than a Kubernetes `Deployment` rolling update.

---

## Exercise 4 — Header-gated canary combined with weighting

Weighting is blind to *who* the caller is. Combining a `match` block with a weighted block lets you route a known cohort (internal testers) deterministically to `v2` while the anonymous public is still shifted only by percentage. **Order matters: `HTTPRoute` entries are evaluated top-down, first match wins.**

1. Apply a two-rule `VirtualService`: `end-user: tester` always gets `v2`; everyone else gets a 95/5 canary:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - match:
       - headers:
           end-user:
             exact: tester
       route:
       - destination:
           host: helloworld
           subset: v2
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 95
       - destination:
           host: helloworld
           subset: v2
         weight: 5
   ```

2. Prove the cohort is pinned — the tester header always lands on `v2`:

   ```bash
   for i in $(seq 1 10); do
     kubectl -n demo exec deploy/sleep -c sleep -- \
       curl -s -H 'end-user: tester' helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected:

   ```
     10 version: v2
   ```

3. Prove the anonymous public still follows the 95/5 weighting:

   ```bash
   for i in $(seq 1 100); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected (≈95/5):

   ```
     96 version: v1
      4 version: v2
   ```

**Comprehension check 4**

1. What happens to a request carrying `end-user: tester` if you **swap the order** of the two `http` entries (weighted block first, matched block second)?
2. The matched block routes to a single subset with no `weight`. Could you also apply a weight *inside* a matched block (e.g. header cohort split 70/30)? What does that let you model?
3. A request with header `end-user: qa-bot` arrives. Which block serves it, and why?

---

## Exercise 5 — Mirror (shadow) traffic to validate v2 with zero user risk

Mirroring copies live requests to a second subset **fire-and-forget**: the mirrored responses are discarded, so `v2` handles real production traffic patterns without any user ever seeing its output. This is the safest possible pre-canary validation.

1. Send 100% of live traffic to `v1`, and mirror 100% of it to `v2`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: helloworld
     namespace: demo
   spec:
     hosts:
     - helloworld
     http:
     - route:
       - destination:
           host: helloworld
           subset: v1
         weight: 100
       mirror:
         host: helloworld
         subset: v2
       mirrorPercentage:
         value: 100.0
   ```

2. Confirm the client only ever *sees* `v1` (mirrored responses are dropped):

   ```bash
   for i in $(seq 1 20); do
     kubectl -n demo exec deploy/sleep -c sleep -- curl -s helloworld:5000/hello
   done | grep -o 'version: v[0-9]' | sort | uniq -c
   ```

   Expected:

   ```
     20 version: v1
   ```

3. Confirm `v2` is nonetheless receiving the shadow load by watching its logs — note the `-shadow` suffix Istio appends to the mirrored request's `Host`/`Authority`:

   ```bash
   kubectl -n demo logs deploy/helloworld-v2 -c helloworld --tail=5
   ```

   Expected (one shadow line per live request):

   ```
   127.0.0.1 - - [.. ] "GET /hello HTTP/1.1" 200 60 "-" "curl/8.5.0"
   servicing request for helloworld-shadow:5000
   ```

**Comprehension check 5**

1. `v2` is a database-writing service. Why is mirroring **dangerous** here despite the client never seeing v2's response, and what property of the mirrored request lets a well-designed backend detect and reject the shadow write?
2. The `weight` on the primary `route` destination is `100`. Does the `mirrorPercentage` of `100.0` add to that, making it "200% of traffic"? Explain the accounting.
3. You lower `mirrorPercentage.value` to `10.0`. What is now mirrored, and what is still served to real users?

---

## Cleanup

```bash
kubectl delete namespace demo
```

---

<details>
<summary>Answers</summary>

**Comprehension check 1**

1. Traffic shifting in Istio is a **control-plane routing decision**, not a replica-count effect. The `VirtualService` weight is compiled into weighted clusters in each caller's Envoy route table; the sidecar then chooses the subset per request regardless of how many pods each subset has. Replica count only affects load *within* a chosen subset, never the inter-subset ratio.
2. Nothing routes: the `VirtualService` references `subset: v1`/`subset: v2`, but those subset names are defined by the `DestinationRule`. Without the `DestinationRule`, the subsets are unknown and Envoy has no matching cluster — requests to those routes fail (typically HTTP 503 `NR`/`no healthy upstream`). `istioctl analyze` flags this as a referenced-but-undefined subset. Apply the `DestinationRule` first (or both together; ordering within a single `apply` is fine because the config converges).
3. Functionally identical for routing — both send 0% to `v2`. But listing `v2` with `weight: 0` keeps the destination *declared*, which makes progressive edits a one-field change and keeps the intent visible in the manifest and in Kiali's graph. Omitting it is cleaner but hides that `v2` exists in the routing picture. It is a readability/operability trade-off, not a behavioral one.

**Comprehension check 2**

1. The split is enforced on the **caller's sidecar** (client-side load balancing). Istio pushes the routing table to every proxy, so the decision happens at the source before the request leaves the caller — there is no extra network hop to a central router, which keeps latency low and means a single caller's misconfiguration can't affect other callers' splits. The blast radius of a bad weight is bounded by config push, and rollback is another push, not a redeploy.
2. No. Scaling `v2` to 10 replicas changes load balancing *inside* the `v2` subset (10 endpoints share v2's 10%), but the inter-subset weight stays 90/10. Weight is independent of replica count — that decoupling is the entire point of weighted traffic shifting.
3. Not broken. With a 10% weight over 100 samples the count follows a binomial distribution; 12 (or 7, or 14) is normal sampling noise. To tighten the measurement, increase the sample size (e.g. 1000+ requests) or use a load generator like `fortio` — the observed ratio converges to 10% as N grows.

**Comprehension check 3**

1. `weight` is **optional when a route has a single destination** (it implicitly gets 100%). When a route has **two or more** destinations, every destination must carry a `weight` and the weights **must sum to 100**. That is why the final single-destination rule needs no weight, while the 90/10 and 50/50 rules require both fields.
2. It is **rejected at admission**. Istio validates that multiple weighted destinations sum to exactly 100; a sum of 90 fails webhook validation (`kubectl apply` returns an error) rather than being silently normalized. Always make the weights total 100.
3. Rolling back a weight is a **pure control-plane operation**: Istiod recomputes the route config and pushes it to the sidecars, which swap the active weighted clusters in-place — no image pull, no pod termination, no readiness wait. A `Deployment` rolling update must schedule, pull, start, and pass readiness probes on new/old pods, so it is bounded by pod lifecycle time. Traffic shifting rollback is effectively instantaneous (a single config push, typically sub-second).

**Comprehension check 4**

1. If the weighted (unmatched) block comes first, it has **no `match` condition, so it matches everything** — including the tester's request — and first-match-wins means the `end-user: tester` block below it becomes dead code that is never reached. The tester would then be subject to the 95/5 split like everyone else. Specific `match` rules must always precede the catch-all.
2. Yes. A `match` block and weighted destinations are orthogonal: you can put multiple weighted destinations *inside* a matched block to split a specific cohort (e.g. testers 70% to `v2`, 30% to `v1`). This models per-cohort canaries — different rollout speeds for internal users versus the public.
3. The **weighted (second) block** serves it. The first block matches only the exact value `tester`; `qa-bot` doesn't match, so evaluation falls through to the catch-all weighted route and the request is subject to the 95/5 split.

**Comprehension check 5**

1. Mirroring copies the **full request, including its body and side effects** — a mirrored `POST`/write hits `v2`'s real code path and would perform a real database write, even though the *response* is discarded. The danger is duplicated or corrupt state, not a visible response. Istio appends `-shadow` to the mirrored request's `Host`/`Authority` header (e.g. `helloworld-shadow`), so a mirror-aware backend can detect it and short-circuit writes (or route to a throwaway/shadow datastore). Never mirror to a version that mutates shared state unless it is shadow-safe.
2. No double counting of *served* traffic. The `weight: 100` governs the traffic real users receive (all to `v1`). `mirrorPercentage` is an **independent copy** of a percentage of that served traffic, sent fire-and-forget to the mirror destination; those responses are dropped and never counted toward the route weights. It does generate additional real load on `v2` (100% of requests here), which is a capacity consideration, but it is not part of the 100% routing accounting.
3. With `mirrorPercentage.value: 10.0`, **10% of the live requests are duplicated to `v2`** as shadow traffic; the other 90% are not mirrored. **100% of users are still served by `v1`** — lowering the mirror percentage only reduces the shadow load on `v2`, never what real users see.

</details>