# Guided Exercises — Topic 3.3: Defining Traffic Policies with Destination Rules

> **Certification:** Istio Certified Associate (ICA) · **Domain 3 — Traffic Management** · Topic weight: 5
>
> **What this topic is really about.** A `VirtualService` decides *where* a request goes (routing). A `DestinationRule` decides *what happens to it once the destination is chosen* (the traffic **policy** applied to the resulting upstream cluster) and *how the destination is subdivided into named `subsets`*. In Envoy terms, a `DestinationRule` configures the **upstream cluster**: its load-balancing algorithm, connection pool ceilings, passive health checking (outlier detection), and the TLS the sidecar originates toward it. Routing (VirtualService) runs first; policy (DestinationRule) is applied to the endpoint you land on. Get that ordering wrong and your circuit breaker or mTLS setting silently never fires.
>
> **Environment assumed.** A running Istio mesh (`istioctl version` succeeds), the `default` namespace labeled for sidecar injection (`kubectl label namespace default istio-injection=enabled`), and `kubectl`/`istioctl` on your PATH. Where an exercise needs a load generator or a target it deploys `fortio`, `httpbin`, and `sleep` from the Istio samples. Manifests use `apiVersion: networking.istio.io/v1` (the current stable API; `v1beta1` remains accepted and is byte-for-byte equivalent for these fields).

---

## Exercise 1 — Subsets: naming versions and wiring them to a VirtualService

**Goal:** Define `subsets` on a `DestinationRule` and prove that a `VirtualService` can only route to a subset that a `DestinationRule` has declared. You will see how each subset becomes a *distinct Envoy cluster*.

### Steps

1. Deploy the Bookinfo sample (it ships three versions of `reviews` behind one Service):

   ```bash
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   kubectl rollout status deploy/reviews-v1 deploy/reviews-v2 deploy/reviews-v3
   ```

2. Confirm the three versions share one Service but differ by the `version` label:

   ```bash
   kubectl get pods -l app=reviews --show-labels
   ```

   Expected (abridged):

   ```
   NAME                          READY   STATUS    LABELS
   reviews-v1-6b7f...            2/2     Running   app=reviews,version=v1,...
   reviews-v2-79c8...            2/2     Running   app=reviews,version=v2,...
   reviews-v3-5b4d...            2/2     Running   app=reviews,version=v3,...
   ```

3. Create a `DestinationRule` that carves the `reviews` host into three named subsets keyed on that label:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     subsets:
     - name: v1
       labels:
         version: v1
     - name: v2
       labels:
         version: v2
     - name: v3
       labels:
         version: v3
   ```

   ```bash
   kubectl apply -f reviews-destinationrule.yaml
   ```

4. Inspect the upstream clusters Envoy now programs into the `productpage` sidecar. Each subset appears as its own cluster:

   ```bash
   PP=$(kubectl get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local
   ```

   Expected:

   ```
   SERVICE FQDN                              PORT   SUBSET   DIRECTION   TYPE
   reviews.default.svc.cluster.local         9080   -        outbound    EDS
   reviews.default.svc.cluster.local         9080   v1       outbound    EDS
   reviews.default.svc.cluster.local         9080   v2       outbound    EDS
   reviews.default.svc.cluster.local         9080   v3       outbound    EDS
   ```

   The subset is encoded in the Envoy cluster name as `outbound|9080|v2|reviews.default.svc.cluster.local`.

5. Pin all traffic to `v2` with a `VirtualService` that references the subset **by name**:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
     - reviews
     http:
     - route:
       - destination:
           host: reviews
           subset: v2
   ```

   ```bash
   kubectl apply -f reviews-vs-v2.yaml
   ```

6. Now deliberately break it. Edit the `VirtualService` to route to `subset: v4` (a name no `DestinationRule` defines), re-apply, and generate traffic:

   ```bash
   kubectl exec "$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')" \
     -c sleep -- curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/productpage
   ```

   Expected: the reviews section fails and the productpage renders the "reviews service unavailable" fallback; the sidecar log for `productpage` shows `503 UH` (no healthy upstream — the cluster does not exist because no subset defines `v4`).

7. Restore the working `subset: v2` route before moving on.

> **Check your understanding — Exercise 1**
> 1. What is the functional difference between the `spec.host` field of a `DestinationRule` and a subset's `labels` block?
> 2. In step 4 you saw a subset-less cluster *and* three subset clusters for the same FQDN. When is the subset-less (`SUBSET -`) cluster used?
> 3. In step 6, why does routing to an undefined subset produce a `503`, and which component (VirtualService or DestinationRule) is the real source of truth for whether a subset "exists"?
> 4. Could you achieve the same v2-only routing with a `VirtualService` alone, no `DestinationRule`? Why or why not?

---

## Exercise 2 — Load balancing policy and session affinity (consistent hashing)

**Goal:** Set the load-balancing algorithm at the `DestinationRule` level, verify it is programmed into Envoy, and switch to **consistent hashing** to get sticky sessions without a stateful backend.

### Steps

1. Set an explicit simple load balancer on the whole `reviews` host and re-apply the DestinationRule from Exercise 1 with a `trafficPolicy` added at the top level:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     trafficPolicy:
       loadBalancer:
         simple: LEAST_REQUEST
     subsets:
     - name: v1
       labels:
         version: v1
     - name: v2
       labels:
         version: v2
       trafficPolicy:
         loadBalancer:
           simple: ROUND_ROBIN     # subset override
     - name: v3
       labels:
         version: v3
   ```

   ```bash
   kubectl apply -f reviews-lb.yaml
   ```

2. Confirm the *effective* algorithm per cluster. The top-level policy applies to `v1`/`v3`, while `v2` carries its own:

   ```bash
   istioctl proxy-config cluster "$PP" \
     --fqdn reviews.default.svc.cluster.local --subset v2 -o json \
     | grep -i lbPolicy
   ```

   Expected:

   ```json
   "lbPolicy": "ROUND_ROBIN",
   ```

   Repeat with `--subset v1` and observe `"lbPolicy": "LEAST_REQUEST"`.

3. Now switch `reviews` to **consistent hashing** on an HTTP header, so every request carrying the same `x-user` value always lands on the same endpoint (session affinity):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     trafficPolicy:
       loadBalancer:
         consistentHash:
           httpHeaderName: x-user
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
     - name: v3
       labels: { version: v3 }
   ```

   ```bash
   kubectl apply -f reviews-hash.yaml
   ```

4. Verify Envoy now uses a ring-hash based policy:

   ```bash
   istioctl proxy-config cluster "$PP" \
     --fqdn reviews.default.svc.cluster.local --subset v1 -o json \
     | grep -iE 'lbPolicy|ringHash|maglev'
   ```

   Expected (ring hash is the default consistent-hash implementation):

   ```json
   "lbPolicy": "RING_HASH",
   ```

5. Review the other consistent-hash keys you could have used instead of a header — `httpCookie` (Istio can *generate* the cookie if it is absent), `useSourceIp: true`, or `httpQueryParameterName`:

   ```yaml
   consistentHash:
     httpCookie:
       name: session-id
       ttl: 3600s
   ```

> **Check your understanding — Exercise 2**
> 1. Rank these `simple` values by what problem each solves: `ROUND_ROBIN`, `LEAST_REQUEST`, `RANDOM`, `PASSTHROUGH`. Which one tells Envoy to *not* load-balance and hand the connection straight to the original destination IP?
> 2. In step 2, why did `v2` report `ROUND_ROBIN` while `v1` reported `LEAST_REQUEST` from the *same* DestinationRule?
> 3. Consistent hashing gives you sticky sessions — but stickiness to *what*, exactly? What happens to an existing client's affinity when a backend pod is added or removed, and why is that a smaller disruption than a naive `hash(key) % N` scheme?
> 4. You set `consistentHash` at the top level in step 3 but the field lives under `loadBalancer`, which is mutually exclusive with `simple`. What would applying both in the same `loadBalancer` block do?

---

## Exercise 3 — Connection pool limits: circuit breaking on overload

**Goal:** Use `connectionPool` to cap concurrent connections and pending requests, then drive load past those limits and watch Envoy shed the excess with `503`s (the "circuit breaker tripping"). Confirm the trip in Envoy's raw stats.

### Steps

1. Deploy `httpbin` (the victim) and `fortio` (the load generator):

   ```bash
   kubectl apply -f samples/httpbin/httpbin.yaml
   kubectl apply -f samples/httpbin/sample-client/fortio-deploy.yaml
   kubectl rollout status deploy/httpbin deploy/fortio-deploy
   ```

2. Apply a deliberately tiny connection pool so it is easy to overflow:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         tcp:
           maxConnections: 1
         http:
           http1MaxPendingRequests: 1
           maxRequestsPerConnection: 1
   ```

   ```bash
   kubectl apply -f httpbin-cb.yaml
   ```

3. Send a **single** request first (1 connection, well within the limit — this must succeed):

   ```bash
   FORTIO=$(kubectl get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 1 -qps 0 -n 1 -loglevel Warning http://httpbin:8000/get
   ```

   Expected: `Code 200 : 1 (100.0 %)`.

4. Now trip it: **two concurrent connections**, twenty requests, against a pool sized for one:

   ```bash
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Expected (proportions vary run to run — the point is that a slice is rejected):

   ```
   Code 200 : 15 (75.0 %)
   Code 503 : 5 (25.0 %)
   ```

5. Prove *why* those `503`s happened — Envoy increments a pending-overflow counter, not a backend error:

   ```bash
   kubectl exec "$FORTIO" -c istio-proxy -- \
     pilot-agent request GET stats | grep httpbin | grep -E 'pending|cx_overflow'
   ```

   Expected (non-zero overflow is the smoking gun):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 5
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_cx_overflow: 0
   ```

6. Correlate with request telemetry: overflowed requests carry the Envoy response flag `UO` (upstream overflow). In the sidecar access log or in the `istio_requests_total` metric they appear as `response_flags="UO"`.

7. Raise the ceilings (`maxConnections: 10`, `http1MaxPendingRequests: 10`), re-apply, re-run step 4, and confirm the `503` share drops toward zero.

> **Check your understanding — Exercise 3**
> 1. Distinguish `tcp.maxConnections`, `http.http1MaxPendingRequests`, and `http.maxRequestsPerConnection`. Which one governs *queued* requests waiting for a free connection?
> 2. A request rejected by the connection pool returns `503` with response flag `UO`. How is that fundamentally different, for the *client's* interpretation, from a `503` returned by the actual httpbin backend?
> 3. In step 3 a single connection succeeded but step 4 with `-c 2` failed a quarter of requests. Explain the mechanism in terms of the pool size of 1.
> 4. Why is capping the connection pool considered a *load-shedding / fail-fast* mechanism rather than a resilience mechanism? What does the caller need to do to actually benefit from it?

---

## Exercise 4 — Outlier detection: passive health checking that ejects bad endpoints

**Goal:** Add `outlierDetection` so Envoy *passively* watches upstream responses and temporarily ejects an endpoint that keeps returning errors — a per-endpoint circuit breaker layered on top of the connection-pool one.

### Steps

1. Scale `httpbin` to three replicas so there is something to eject *from*:

   ```bash
   kubectl scale deploy/httpbin --replicas=3
   kubectl rollout status deploy/httpbin
   ```

2. Add outlier detection to the DestinationRule (keeping a generous connection pool this time so the pool is not what trips):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         http:
           http1MaxPendingRequests: 100
         tcp:
           maxConnections: 100
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 66
         minHealthPercent: 34
   ```

   ```bash
   kubectl apply -f httpbin-outlier.yaml
   ```

3. Make one endpoint reliably fail. `httpbin` has a `/status/{code}` endpoint; drive repeated `500`s at the service so at least one endpoint accumulates three consecutive failures:

   ```bash
   kubectl exec "$FORTIO" -c fortio -- /usr/bin/fortio load \
     -c 3 -qps 0 -n 60 -loglevel Warning http://httpbin:8000/status/500
   ```

4. Watch the ejection counters climb:

   ```bash
   kubectl exec "$FORTIO" -c istio-proxy -- \
     pilot-agent request GET stats | grep httpbin | grep outlier_detection
   ```

   Expected (a non-zero `ejections_active` while an endpoint is in penalty):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_enforced_consecutive_5xx: 2
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_active: 1
   ```

5. Confirm the safety valve: with `maxEjectionPercent: 66` and three endpoints, Envoy will eject at most two — never all three — even under total failure, because `minHealthPercent`/`maxEjectionPercent` prevent an empty pool. Verify the healthy endpoint count in the cluster does not drop to zero:

   ```bash
   istioctl proxy-config endpoint "$FORTIO" --cluster \
     "outbound|8000||httpbin.default.svc.cluster.local"
   ```

6. Stop the failing load and wait `baseEjectionTime` (30s). The endpoint is re-admitted; a *repeat* offender is ejected for `2 × baseEjectionTime`, then `3 ×`, and so on (the penalty grows with the ejection count).

> **Check your understanding — Exercise 4**
> 1. Outlier detection is called *passive* health checking. What is it observing, and how does that differ from an *active* health probe (like a Kubernetes readiness probe)?
> 2. What do `consecutive5xxErrors`, `interval`, and `baseEjectionTime` each control? Which one determines how *often* Envoy evaluates ejection, and which determines how *long* the first ejection lasts?
> 3. With three endpoints, `maxEjectionPercent: 66`, and all three failing, how many can Envoy eject — and why is refusing to eject the last one the correct behavior?
> 4. `outlierDetection` and `connectionPool` can both produce `503`s. Which one protects you from a *single sick pod*, and which protects the *whole upstream* from being overwhelmed?

---

## Exercise 5 — TLS traffic policy, plus port-level and subset overrides

**Goal:** Use the `tls` block of a `trafficPolicy` to control the TLS the sidecar *originates* toward the upstream — both mesh-internal (`ISTIO_MUTUAL`) and TLS origination to an external service — and see how `portLevelSettings` and per-subset policy override the top-level policy.

### Steps

1. Set mesh mTLS explicitly for a client-side host. `ISTIO_MUTUAL` tells the sidecar to originate mutual TLS using the Istio-managed workload certificates (no key/cert paths needed):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin-mtls
   spec:
     host: httpbin
     trafficPolicy:
       tls:
         mode: ISTIO_MUTUAL
   ```

   ```bash
   kubectl apply -f httpbin-mtls.yaml
   ```

   > **Gotcha to internalize:** if server-side `PeerAuthentication` is `STRICT` but a `DestinationRule` sets `tls.mode: DISABLE` for that same host, the client sends plaintext into an mTLS-only port and every request fails with `503`. `DestinationRule.tls` (client origination) and `PeerAuthentication` (server acceptance) must agree.

2. Demonstrate **TLS origination** to an external HTTPS site. Register the external host, then have the DestinationRule upgrade the sidecar's plaintext-to-`edition.cnn.com:80` into real TLS on port 443:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata:
     name: edition-cnn-com
   spec:
     hosts:
     - edition.cnn.com
     ports:
     - number: 80
       name: http-port
       protocol: HTTP
       targetPort: 443
     resolution: DNS
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: originate-tls-cnn
   spec:
     host: edition.cnn.com
     trafficPolicy:
       portLevelSettings:
       - port:
           number: 80
         tls:
           mode: SIMPLE       # sidecar originates one-way TLS
           sni: edition.cnn.com
   ```

   ```bash
   kubectl apply -f cnn-tls-origination.yaml
   SLEEP=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP" -c sleep -- \
     curl -sIL http://edition.cnn.com/politics | head -n1
   ```

   Expected: `HTTP/1.1 200 OK` — the app spoke *plain HTTP to port 80*, and the sidecar transparently wrapped it in TLS.

3. Combine everything into one DestinationRule showing the **override hierarchy** — a top-level default, a per-port override, and a per-subset override:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews-layered
   spec:
     host: reviews
     trafficPolicy:                 # (A) applies to every subset & port unless overridden
       loadBalancer:
         simple: LEAST_REQUEST
       connectionPool:
         tcp:
           maxConnections: 100
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
       trafficPolicy:               # (B) subset override — replaces (A) for v2
         loadBalancer:
           simple: ROUND_ROBIN
         portLevelSettings:
         - port:
             number: 9080
           loadBalancer:            # (C) port override — most specific, wins for v2:9080
             consistentHash:
               useSourceIp: true
     - name: v3
       labels: { version: v3 }
   ```

   ```bash
   kubectl apply -f reviews-layered.yaml
   ```

4. Verify the effective policy at each level:

   ```bash
   # v1 → inherits (A)
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local \
     --subset v1 -o json | grep -i lbPolicy      # LEAST_REQUEST
   # v2:9080 → (C) wins
   istioctl proxy-config cluster "$PP" --fqdn reviews.default.svc.cluster.local \
     --subset v2 -o json | grep -iE 'lbPolicy|ringHash'   # RING_HASH (from useSourceIp)
   ```

> **Check your understanding — Exercise 5**
> 1. What do `DISABLE`, `SIMPLE`, `MUTUAL`, and `ISTIO_MUTUAL` each mean for the TLS the sidecar *originates*? Which one requires you to supply your own client cert/key, and which uses Istio's automatic workload certs?
> 2. In step 2 the application issued a plain `http://` request but the connection to CNN was encrypted. Where did the TLS handshake happen, and what does that buy an application that has no TLS code?
> 3. State the precedence order among top-level `trafficPolicy`, per-subset `trafficPolicy`, and `portLevelSettings`. In step 3, what load-balancer policy is actually in effect for `v2` on port `9080`, and for `v3` on port `9080`?
> 4. A subset defines a `trafficPolicy` with *only* `loadBalancer`. Does it still inherit the top-level `connectionPool`, or does declaring a subset `trafficPolicy` wipe out everything not restated? (Reason from what you saw, then check the answer.)

---

## Cleanup

```bash
kubectl delete destinationrule reviews reviews-layered httpbin httpbin-mtls originate-tls-cnn --ignore-not-found
kubectl delete virtualservice reviews --ignore-not-found
kubectl delete serviceentry edition-cnn-com --ignore-not-found
kubectl delete -f samples/httpbin/sample-client/fortio-deploy.yaml --ignore-not-found
kubectl delete -f samples/httpbin/httpbin.yaml --ignore-not-found
kubectl delete -f samples/bookinfo/platform/kube/bookinfo.yaml --ignore-not-found
```

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

1. **`spec.host`** selects *which* service (by short name or FQDN) the rule governs — it is the destination the policy and subsets attach to. A subset's **`labels`** block is an endpoint *filter*: among the pods behind that host, a subset is exactly those whose pod labels match every key/value listed. `host` picks the service; `labels` slice that service into addressable groups.
2. The subset-less cluster (`SUBSET -`) is the default upstream used whenever a route targets the host **without** naming a subset — e.g. a `VirtualService` route with just `host: reviews` and no `subset:`, or direct service traffic that isn't matched by any subset-specific route. It load-balances across *all* endpoints of the service.
3. Routing to `subset: v4` fails because Istio programs one Envoy cluster **per declared subset**; `v4` is declared nowhere, so no cluster exists, and Envoy answers `503 UH` (no healthy upstream). The **DestinationRule is the source of truth** for which subsets exist — a `VirtualService` can only *reference* names the DestinationRule created. A subset name in a VirtualService is a dangling pointer until a DestinationRule defines it.
4. **No.** A `VirtualService` route's `subset` field is only meaningful if a `DestinationRule` has defined that subset. Without a DestinationRule you can route to the `reviews` *host*, but you cannot express "only the `v2` endpoints" — the VirtualService has no label-selection capability of its own; subset definition is exclusively a DestinationRule concern.

### Exercise 2

1. `ROUND_ROBIN` — spread requests evenly, order-based (simple, predictable). `LEAST_REQUEST` — send to the endpoint with the fewest active requests (best default for uneven request costs; Istio's recommended general-purpose choice). `RANDOM` — pick uniformly at random, no coordination (good when you can't trust request-count signals). `PASSTHROUGH` — **do not load-balance**; forward the connection to the original destination IP the caller asked for (used for pass-through/opaque scenarios). `PASSTHROUGH` is the one that disables balancing.
2. Because a **per-subset `trafficPolicy` overrides the top-level `trafficPolicy`** for that subset only. The DestinationRule's top-level `loadBalancer: LEAST_REQUEST` applies to `v1` and `v3`, but `v2` restated `loadBalancer: ROUND_ROBIN`, so `v2`'s cluster is programmed with round-robin.
3. Stickiness is to a **specific upstream endpoint (pod)**, keyed by the chosen attribute (header, cookie, source IP, or query param) — every request with the same key value hashes to the same endpoint. When an endpoint is added/removed, consistent hashing (ring/Maglev) remaps only the fraction of keys that landed near the changed node on the hash ring — roughly `1/N` of keys move — whereas `hash(key) % N` changes the divisor and **reshuffles almost every key**. That bounded disruption is the whole point of consistent hashing.
4. `simple` and `consistentHash` are **mutually exclusive within one `loadBalancer`**; you set one *or* the other. Supplying both is invalid configuration — Istio will reject it (or one is ignored). Consistent hashing *is* the load-balancing algorithm in that case, so there is nothing for `simple` to also specify.

### Exercise 3

1. `tcp.maxConnections` caps the number of concurrent TCP connections the sidecar opens to the upstream. `http.http1MaxPendingRequests` caps requests **queued** waiting for a connection/stream to free up — this is the "pending" queue. `http.maxRequestsPerConnection` limits how many requests reuse a single connection before it is closed (1 = no keep-alive reuse). The **pending** limit governs queued requests.
2. A `503 UO` means the request **never reached httpbin** — the local sidecar rejected it to protect the pool; the backend is likely healthy. A backend `503` means httpbin itself failed to serve. For the caller, `UO` says "back off / retry later, the path is saturated," whereas a backend `503` says "the service errored." Conflating them leads to blaming a healthy backend for a client-side overload.
3. The pool allows one connection and one pending request. With `-c 1` a single connection is always available, so the request succeeds. With `-c 2`, two connections compete for a pool of size 1: one proceeds, the second can only be *queued*, and once the single pending slot is also taken any further concurrent request overflows and is rejected with `503 UO`. Hence a fraction fails.
4. Because it **rejects excess load immediately** instead of letting it queue unbounded and drag latency/memory across the whole service — it fails *fast* rather than degrading everyone. It is only *resilience* if the caller cooperates: the client (or a `VirtualService` retry policy) must **retry with backoff**, ideally against another endpoint. Without retry logic, fail-fast just surfaces the `503` to the user.

### Exercise 4

1. Passive health checking **observes real production responses** (5xx counts, connection failures, timeouts) flowing through Envoy and ejects endpoints that misbehave — no synthetic traffic. An active probe (Kubernetes readiness probe) *generates* dedicated health requests on a schedule. Passive detection reacts to what users actually experience and needs no extra endpoint, but only "sees" a bad pod once real requests have already hit it.
2. `consecutive5xxErrors` — how many back-to-back 5xx (server-origin errors) trigger ejection. `interval` — how **often** Envoy sweeps the pool to evaluate/apply ejection. `baseEjectionTime` — how **long** the *first* ejection lasts (subsequent ejections multiply by the ejection count). So `interval` = evaluation cadence, `baseEjectionTime` = first penalty duration.
3. At most **two** (66% of three, floored). Envoy refuses to eject the third even though it is also failing, because `maxEjectionPercent`/`minHealthPercent` guarantee a non-empty pool — ejecting the last endpoint would leave *nowhere* to route, turning a partial outage into a total one. Keeping one endpoint (even a sick one) preserves a chance of success and lets recovery be observed.
4. `outlierDetection` protects you from a **single sick pod** by removing it from rotation while the others keep serving. `connectionPool` protects the **whole upstream** (and the caller) from being overwhelmed by capping concurrency and shedding excess. One is per-endpoint quarantine; the other is aggregate rate/concurrency limiting.

### Exercise 5

1. `DISABLE` — send plaintext, no TLS. `SIMPLE` — originate standard one-way (server-authenticated) TLS, like a normal HTTPS client. `MUTUAL` — originate mutual TLS using **your own** supplied `clientCertificate`/`privateKey`/`caCertificates`. `ISTIO_MUTUAL` — originate mutual TLS using **Istio's automatically provisioned workload certificates** (SPIFFE identities), no paths required. `MUTUAL` needs your own cert/key; `ISTIO_MUTUAL` uses Istio's.
2. The **sidecar (Envoy) originated the TLS handshake** on the outbound path: the app spoke plain HTTP to port 80, the `ServiceEntry` + `DestinationRule` (`tls.mode: SIMPLE`, port `80→443`) told the sidecar to establish TLS with `edition.cnn.com` on 443. This buys a TLS-unaware application **encryption in transit, SNI, and certificate handling for free** — offloaded to the mesh, centrally managed and auditable, with no application code change.
3. Precedence, most specific wins: **`portLevelSettings` (per port) > per-subset `trafficPolicy` > top-level `trafficPolicy`.** For `v2` on port `9080`, the port-level `consistentHash.useSourceIp` (C) wins → **RING_HASH**. For `v3` on port `9080`, `v3` declared no subset policy, so it inherits the **top-level** `LEAST_REQUEST` (A).
4. It **still inherits** the top-level `connectionPool`. A subset `trafficPolicy` overrides the top level **field by field**, not wholesale — restating only `loadBalancer` replaces just the load-balancer setting; `connectionPool`, `outlierDetection`, `tls`, etc. that the subset does *not* restate continue to come from the top-level policy. (This is why `v2` in Exercise 5 still enjoyed the top-level `maxConnections: 100` even though it only restated the load balancer.)

</details>

---

### Sources

- Istio reference — DestinationRule (fields: `host`, `subsets`, `trafficPolicy`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio concepts — Destination rules & subsets: https://istio.io/latest/docs/concepts/traffic-management/#destination-rules
- LoadBalancerSettings (`simple`, `consistentHash`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#LoadBalancerSettings
- ConnectionPoolSettings (`tcp`, `http`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings
- OutlierDetection (passive health checking): https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
- ClientTLSSettings (`DISABLE`/`SIMPLE`/`MUTUAL`/`ISTIO_MUTUAL`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Task — Circuit Breaking (connection pool + outlier detection with fortio): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Task — TLS origination for an external service: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Task — Traffic shifting / subsets with VirtualService: https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- ICA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf