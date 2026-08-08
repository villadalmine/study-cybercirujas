# Exercises — Topic 3.6: Using Resilience Features

> Environment assumed for every exercise below: an Istio-enabled Kubernetes cluster with automatic sidecar injection on the working namespace, `istioctl` and `kubectl` on your PATH, and Istio 1.20+ (all manifests use the `networking.istio.io/v1` API, which is GA and back-compatible with `v1beta1`). Run everything from a single namespace — the examples use `default`. Resilience in Istio is enforced by the client-side Envoy sidecar, so every knob you set here lives in the caller's proxy, not the server's.

---

## Exercise 0 — Lay down the test bench

You will drive traffic with **Fortio** (a load generator that reports per-code histograms) against **httpbin** (a server whose `/delay`, `/status`, and `/get` endpoints let you manufacture latency and errors on demand).

**Steps**

1. Confirm injection is on for the namespace you will use:

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl get namespace default --show-labels
   ```

2. Deploy the server and the client:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/sample-client/fortio-deploy.yaml
   ```

3. Verify both pods run **2/2** (app container + `istio-proxy`):

   ```bash
   kubectl get pods -l app=httpbin
   kubectl get pods -l app=fortio
   ```

   Expected:

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7d6bf9b4c5-abcde   2/2     Running   0          25s
   fortio-deploy-9c8b7-xyz    2/2     Running   0          20s
   ```

4. Capture the Fortio pod name into a shell variable and fire one sanity request:

   ```bash
   export FORTIO_POD=$(kubectl get pods -l app=fortio -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/get
   ```

   Expected: an HTTP `200` with a JSON body echoing the request headers — note the `X-Envoy-*` headers, which prove the request traversed the sidecar.

**Check your understanding**

- **Q0.1** — Why must the `fortio` command be run inside the `-c fortio` container and not the `-c istio-proxy` container?
- **Q0.2** — Resilience policies you are about to configure are enforced by *which* pod's Envoy — httpbin's or fortio's? Why does that distinction matter for how you'll read the metrics?

---

## Exercise 1 — Request timeouts

A timeout bounds how long the client Envoy will wait for a complete upstream response before giving up with `504 Gateway Timeout`. Without one, a slow backend can pin client resources indefinitely.

**Steps**

1. Baseline the latency of a deliberately slow endpoint. `httpbin/delay/N` waits `N` seconds before responding:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/5
   ```

   Expected: a `200` after ~5 s. No timeout is in force yet.

2. Route `httpbin` through a `VirtualService` that caps the wait at 3 seconds:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts:
       - httpbin
     http:
       - route:
           - destination:
               host: httpbin
         timeout: 3s
   ```

   ```bash
   kubectl apply -f httpbin-timeout.yaml
   ```

3. Hit the 5-second endpoint again and time it:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/5
   ```

   Expected: the call returns in ~3 s with:

   ```
   HTTP/1.1 504 Gateway Timeout
   upstream request timeout
   ```

4. Confirm the endpoint that fits *inside* the budget still succeeds:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/delay/1
   ```

   Expected: `200` after ~1 s.

5. Read the client sidecar's access log to see Envoy's own verdict:

   ```bash
   kubectl logs "$FORTIO_POD" -c istio-proxy --tail=5 | grep delay
   ```

   Expected: a log line whose response-flags field contains **`UT`** (Upstream request Timeout) for the `/delay/5` call.

**Check your understanding**

- **Q1.1** — The `timeout` was set on the `VirtualService` (a routing object), yet it is enforced by fortio's Envoy. Reconcile those two facts.
- **Q1.2** — What is the Envoy response flag for a request killed by the route timeout, and what HTTP status does the client receive?
- **Q1.3** — You later add a retry policy with `perTryTimeout: 2s` while keeping the overall `timeout: 3s`. If every attempt is slow, roughly how many attempts can physically fit before the overall timeout fires, and which budget wins?

---

## Exercise 2 — Retries

Retries let the client Envoy transparently re-issue a failed request to (potentially) another healthy endpoint. They mask *transient* faults — a single flaky replica, a dropped connection — but they cannot fix a request that is deterministically broken.

**Steps**

1. Inspect the retry policy Istio applies **by default**, even with no config. Dump the effective route config from fortio's proxy:

   ```bash
   istioctl proxy-config route "$FORTIO_POD" --name 8000 -o json \
     | grep -A6 retryPolicy
   ```

   Expected (defaults): `numRetries: 2`, `retryOn: "connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes"`.

2. Replace the `VirtualService` with an explicit retry policy over an always-failing endpoint. `httpbin/status/503` returns `503` every time:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts:
       - httpbin
     http:
       - route:
           - destination:
               host: httpbin
         retries:
           attempts: 3
           perTryTimeout: 2s
           retryOn: 5xx,reset,connect-failure
   ```

   ```bash
   kubectl apply -f httpbin-retries.yaml
   ```

3. Reset the sidecar's counters so you measure only this run, then send **one** logical request:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/status/503
   ```

   Expected: the client still receives `503` — the endpoint is deterministically broken, so retries cannot save it.

4. Prove the retries actually happened by reading the client Envoy's cluster stats:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*upstream_rq_retry'
   ```

   Expected (one logical request → the original try plus 3 retries):

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry: 3
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry_limit_exceeded: 1
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_retry_success: 0
   ```

5. Contrast with a *non-retriable* code. `httpbin/status/400` returns a client error, which `retryOn: 5xx` does not match:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio curl -quiet http://httpbin:8000/status/400
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*upstream_rq_retry:'
   ```

   Expected: `upstream_rq_retry: 0` — a `400` is not retried.

**Check your understanding**

- **Q2.1** — With `attempts: 3`, how many total requests can hit the upstream for one client call, and why did `/status/503` still return an error to the caller?
- **Q2.2** — `retryOn: 5xx` matched `503` but not `400`. State the general principle about which failures are worth retrying and which are not.
- **Q2.3** — A colleague wants to be "safe" and sets `attempts: 10` on a write endpoint (`POST`) that is failing under load. Name two distinct hazards this creates.
- **Q2.4** — Retries and the Exercise-1 timeout interact. If `perTryTimeout: 2s` and `attempts: 3` but the route `timeout` is `3s`, why might you observe only *one* attempt instead of three?

---

## Exercise 3 — Circuit breaking (connection-pool limits)

Circuit breaking here means shedding load: when concurrent connections or pending requests to a service exceed a ceiling, the client Envoy immediately returns `503` instead of queueing, protecting a struggling backend from being overwhelmed. This is configured on the **`DestinationRule`**, not the VirtualService.

**Steps**

1. Remove the retry VirtualService so it doesn't mask overflow errors, then apply an aggressive circuit breaker:

   ```bash
   kubectl delete virtualservice httpbin --ignore-not-found
   ```

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
   kubectl apply -f httpbin-circuit-breaker.yaml
   ```

2. With **one** connection at a time (`-c 1`) the breaker should not trip:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 1 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Expected: `Code 200 : 20 (100.0 %)`.

3. Now push **two** concurrent connections (`-c 2`), exceeding `maxConnections: 1` + `http1MaxPendingRequests: 1`:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
   ```

   Expected: a mix — some requests tripped the breaker:

   ```
   Code 200 : 15 (75.0 %)
   Code 503 : 5 (25.0 %)
   ```

4. Quantify how many requests the breaker shed by reading the overflow counter:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*pending'
   ```

   Expected:

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_active: 0
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 5
   cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_total: 39
   ```

   The `upstream_rq_pending_overflow` count matches the `503`s Fortio reported.

5. (Optional) Turn the pressure up to `-c 3` and observe the `503` share climb, then confirm each shed request carries the `UO` (Upstream Overflow / circuit-breaking) response flag in fortio's access log:

   ```bash
   kubectl logs "$FORTIO_POD" -c istio-proxy --tail=20 | grep -o 'response_flags[":= ]*[A-Z]*' | sort | uniq -c
   ```

**Check your understanding**

- **Q3.1** — On which resource (`VirtualService` or `DestinationRule`) do connection-pool circuit breakers live, and why is that the semantically correct home?
- **Q3.2** — The limits are `maxConnections: 1` and `http1MaxPendingRequests: 1`. Explain, in terms of those two numbers, why `-c 1` yielded 100% success but `-c 2` shed roughly a quarter of requests.
- **Q3.3** — `upstream_rq_pending_overflow` was `5` and fortio reported `5` × `503`. Which Envoy **response flag** corresponds to this, and how does it differ from the `UT` flag you saw in Exercise 1?
- **Q3.4** — These limits are enforced *per client Envoy instance*. If you scale fortio to 3 replicas, does the *effective* concurrency the httpbin backend can see stay at 1? Explain.

---

## Exercise 4 — Outlier detection (passive health checking → ejection)

Outlier detection is Envoy's passive health check: it watches per-endpoint responses and temporarily **ejects** an endpoint from the load-balancing pool after it emits consecutive errors, then probes it back later. Combined with a multi-replica Deployment, it routes around a single sick pod without any external health-check probe.

**Steps**

1. Scale httpbin to 3 replicas so there is a pool to eject from:

   ```bash
   kubectl scale deployment httpbin --replicas=3
   kubectl rollout status deployment/httpbin
   ```

2. Extend the `DestinationRule` with an `outlierDetection` block (keep or drop the connection pool — shown here standalone for clarity):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 100
         minHealthPercent: 0
   ```

   ```bash
   kubectl apply -f httpbin-outlier.yaml
   ```

3. Inspect the endpoints and their health as fortio's Envoy currently sees them:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local"
   ```

   Expected: three endpoints, all `HEALTHY`.

4. Make one specific replica fail every request. Pick a pod, exec into its **app** container, and (httpbin has no kill switch, so simulate by stopping the server process) crash it so its connections reset:

   ```bash
   VICTIM=$(kubectl get pods -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$VICTIM" -c httpbin -- pkill gunicorn || true
   ```

   > This makes the victim endpoint refuse/reset connections, which outlier detection counts against it (connection failures are treated as `5xx` unless `splitExternalLocalOriginErrors` is set).

5. Drive steady traffic so the detector accumulates consecutive errors within an `interval`:

   ```bash
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 3 -qps 20 -t 30s -loglevel Warning http://httpbin:8000/get
   ```

6. While that runs (or right after), re-inspect endpoint health and the ejection counters:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local"

   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep 'httpbin.*outlier'
   ```

   Expected: the victim endpoint now shows `UNHEALTHY`, and stats show a non-zero ejection, e.g.:

   ```
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_active: 1
   cluster.outbound|8000||httpbin.default.svc.cluster.local.outlier_detection.ejections_enforced_consecutive_5xx: 1
   ```

   The Fortio success rate should stay high (~near 100% after the first few errors) because traffic is now steered to the two healthy replicas.

7. Wait past `baseEjectionTime` (30 s) after the pod recovers (`kubectl rollout restart deployment/httpbin` to bring the victim back) and confirm the endpoint returns to `HEALTHY` and `ejections_active` drops to `0`.

**Check your understanding**

- **Q4.1** — Distinguish outlier detection from a Kubernetes **readinessProbe**. Both remove bad backends — what does Envoy's passive check catch that the kubelet probe may miss, and vice versa?
- **Q4.2** — `consecutive5xxErrors: 3`, `interval: 5s`, `baseEjectionTime: 30s`. In plain language, describe the exact sequence of events that leads to an endpoint being ejected and later re-admitted.
- **Q4.3** — Why does `maxEjectionPercent: 100` matter here, and what dangerous behavior (panic routing) can occur if outlier detection is left at its conservative default while a majority of endpoints are actually unhealthy?
- **Q4.4** — Outlier detection is also the *prerequisite* for one of the other resilience features in this topic. Which one, and why can't that feature work without it?

---

## Exercise 5 — Failover (locality-aware load balancing)

Locality failover keeps traffic in the caller's own zone/region while all is well, and shifts it to a backup locality only when the local endpoints go unhealthy. It builds directly on outlier detection: Envoy groups endpoints into **priority levels** by locality, and only demotes to a lower-priority locality when the higher one is ejected.

> A *live* cross-zone failover needs a genuinely multi-zone cluster (nodes with distinct `topology.kubernetes.io/region`/`zone` labels). This exercise configures the policy and reads the resulting priority topology from Envoy, which is what you will be asked to reason about on the exam even on a single-zone lab.

**Steps**

1. Configure failover in the `DestinationRule`. Failover **requires** outlier detection to be present (kept from Exercise 4):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       loadBalancer:
         localityLbSetting:
           enabled: true
           failover:
             - from: us-east
               to: us-west
       outlierDetection:
         consecutive5xxErrors: 3
         interval: 5s
         baseEjectionTime: 30s
         maxEjectionPercent: 100
   ```

   ```bash
   kubectl apply -f httpbin-failover.yaml
   ```

2. Inspect how Envoy has bucketed the endpoints into **priorities** by locality:

   ```bash
   istioctl proxy-config endpoints "$FORTIO_POD" \
     --cluster "outbound|8000||httpbin.default.svc.cluster.local" -o json \
     | grep -E '"priority"|region|zone|"address"'
   ```

   Expected on a multi-zone cluster: endpoints in the caller's own region carry `priority: 0`; the `us-west` failover target appears at `priority: 1`. (On a single-zone lab every endpoint is `priority 0` — note that and move on.)

3. Reason about the failover trigger: with all local (`priority 0`) endpoints healthy, `100%` of traffic stays local. Only when outlier detection ejects enough of `priority 0` does Envoy promote `priority 1`. Verify the load-balancing weights conceptually by checking the cluster's `load_assignment` priorities:

   ```bash
   istioctl proxy-config cluster "$FORTIO_POD" \
     --fqdn httpbin.default.svc.cluster.local -o json \
     | grep -A3 localityLbSetting
   ```

4. (Multi-zone only) Eject the entire local locality by killing all local httpbin replicas and confirm traffic shifts to `us-west` while Fortio success rate stays high; then restore and confirm traffic snaps back to local.

**Check your understanding**

- **Q5.1** — Failover shares a hard dependency with Exercise 4. What is it, and what would happen (functionally) if you configured `localityLbSetting.failover` but *omitted* `outlierDetection`?
- **Q5.2** — Distinguish `localityLbSetting.failover` from `localityLbSetting.distribute`. When would you choose each?
- **Q5.3** — Under normal (all-healthy) conditions, what fraction of traffic does a `failover` policy send to the backup locality, and why is that the right default for cost and latency?
- **Q5.4** — Locality is derived from node labels. Name the two `topology.kubernetes.io/*` labels Istio reads, and explain how a pod scheduled on an unlabeled node is treated for locality routing.

---

## Exercise 6 — Compose the full resilience stack (capstone)

Real services layer these features. Here you combine timeout + retries (VirtualService) with circuit breaking + outlier detection (DestinationRule) on one host and reason about their interaction order.

**Steps**

1. Apply both objects together:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts: [httpbin]
     http:
       - route:
           - destination:
               host: httpbin
         timeout: 5s
         retries:
           attempts: 3
           perTryTimeout: 1s
           retryOn: 5xx,reset,connect-failure,retriable-status-codes
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     trafficPolicy:
       connectionPool:
         tcp: { maxConnections: 10 }
         http: { http1MaxPendingRequests: 10, maxRequestsPerConnection: 10 }
       outlierDetection:
         consecutive5xxErrors: 5
         interval: 10s
         baseEjectionTime: 30s
         maxEjectionPercent: 50
   ```

   ```bash
   kubectl apply -f httpbin-resilience-stack.yaml
   ```

2. Verify the merged effective config Envoy actually runs:

   ```bash
   istioctl proxy-config route "$FORTIO_POD" --name 8000 -o yaml | grep -A8 retryPolicy
   istioctl proxy-config cluster "$FORTIO_POD" --fqdn httpbin.default.svc.cluster.local -o yaml \
     | grep -A15 -E 'outlierDetection|circuitBreakers'
   ```

3. Drive mixed load and watch retries, overflow, and ejections move together:

   ```bash
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request POST reset_counters
   kubectl exec "$FORTIO_POD" -c fortio -- /usr/bin/fortio load \
     -c 15 -qps 0 -t 20s -loglevel Warning http://httpbin:8000/get
   kubectl exec "$FORTIO_POD" -c istio-proxy -- pilot-agent request GET stats \
     | grep -E 'httpbin.*(pending_overflow|rq_retry:|outlier_detection.ejections_active)'
   ```

**Check your understanding**

- **Q6.1** — Order the features by *when* they act on a single doomed request: connection-pool limit, per-try timeout, retry, overall route timeout, outlier ejection. Which of these can happen *before the request is even sent to the wire*?
- **Q6.2** — Why is stacking a large `attempts` value on top of an aggressive circuit breaker potentially self-defeating during an overload?
- **Q6.3** — `maxEjectionPercent: 50` with `consecutive5xxErrors: 5`: give a scenario where this combination *keeps a partially degraded service serving* rather than blackholing it.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**Q0.1** — `fortio` is the client application; it lives in the app container. The `istio-proxy` container runs Envoy, whose job is to *intercept* fortio's traffic transparently, not to originate application requests. Running `fortio` in the proxy container would bypass the sidecar's iptables interception (Envoy talks to itself) and you'd measure the wrong path.

**Q0.2** — Istio resilience policies (timeouts, retries, circuit breaking, outlier detection, failover) are enforced by the **client-side** Envoy — here, **fortio's** sidecar. That is why every metric in these exercises is read from `$FORTIO_POD -c istio-proxy`, not from httpbin. The `DestinationRule`/`VirtualService` are keyed by the *destination host*, but they program the *caller's* proxy for calls to that host.

### Exercise 1

**Q1.1** — The `VirtualService` is a declarative routing intent for the `httpbin` host. The control plane (istiod) compiles that intent into Envoy route config and pushes it to every sidecar that might call `httpbin` — including fortio's. The timeout is therefore *declared* on the route but *enforced* by the calling Envoy on each request. Server-side has no part in it.

**Q1.2** — Response flag **`UT`** (Upstream request Timeout); the client receives **`504 Gateway Timeout`** with body `upstream request timeout`.

**Q1.3** — With `perTryTimeout: 2s` and an overall `timeout: 3s`, only the first attempt (2 s) fully fits; a second attempt would start at t≈2 s and be cut off by the overall 3 s budget after ~1 s. So roughly **one full attempt plus a truncated second**. The **overall route `timeout` always wins** — it is the hard wall-clock ceiling across *all* tries; `perTryTimeout` only bounds each individual attempt.

### Exercise 2

**Q2.1** — `attempts: 3` means up to **1 original + 3 retries = 4 upstream requests** for one client call. It still failed because `/status/503` is *deterministically* broken — every replica returns `503` — so retrying only re-encounters the same error. Retries mask *transient*, not *systematic*, failures.

**Q2.2** — Retry only failures that are **idempotent to retry and plausibly transient**: connection resets, `503`/`unavailable`, `connect-failure`, refused streams. Do **not** retry deterministic client errors (`4xx` like `400`, `404`, `401`) — the request itself is malformed or unauthorized, so a retry cannot change the outcome and just wastes capacity.

**Q2.3** — (1) **Retry amplification / retry storms**: 10× the traffic hammering an already-overloaded backend makes the outage worse. (2) **Non-idempotent side effects**: retrying a `POST` that partially succeeded (e.g., the write landed but the response was lost) can duplicate the write — double charges, duplicate records. Only retry writes when the endpoint is idempotent or protected by an idempotency key.

**Q2.4** — The overall route `timeout: 3s` is the hard ceiling across all attempts. With `perTryTimeout: 2s`, the first attempt can consume up to 2 s; after a retry backoff the remaining budget may be under 1 s, so subsequent attempts get cut short or never start. If the very first attempt eats the whole 3 s, you observe a single attempt then a `504`. Budget the overall timeout ≥ `attempts × perTryTimeout` (plus backoff) if you actually want all retries to have a chance.

### Exercise 3

**Q3.1** — On the **`DestinationRule`** (`trafficPolicy.connectionPool`). Circuit breaking is a property of *how the client connects to a destination workload* — connection and request concurrency ceilings — which is exactly what `DestinationRule` governs. `VirtualService` governs *routing/matching* (where a request goes), a different concern.

**Q3.2** — `maxConnections: 1` allows one active upstream connection; `http1MaxPendingRequests: 1` allows one additional request to queue while that connection is busy. So the pipeline depth is effectively 2 in flight. With `-c 1` there is never more than one outstanding request → nothing overflows → 100% `200`. With `-c 2`, the second concurrent request frequently finds both the single connection *and* the single pending slot occupied, so Envoy trips the breaker and returns `503` for the excess — ~25% here.

**Q3.3** — Response flag **`UO`** (Upstream Overflow — circuit breaking). It differs from **`UT`** (timeout): `UO` means Envoy **never sent** the request upstream because a concurrency ceiling was already saturated (fast fail / load shed); `UT` means the request *was* sent but the upstream didn't respond within the budget.

**Q3.4** — No. Connection-pool limits are enforced **per client Envoy instance**, independently. With 3 fortio replicas each allowing `maxConnections: 1`, the httpbin backend can see up to **3** concurrent connections in aggregate. Circuit-breaker limits are *local* to each proxy, not a global cluster-wide quota.

### Exercise 4

**Q4.1** — A Kubernetes **readinessProbe** is an *active* check the kubelet performs on a fixed endpoint/interval; it removes a pod from *Service* endpoints when the probe fails. **Outlier detection** is *passive* — it judges endpoints on the *real* production responses Envoy is already receiving, so it catches partial/intermittent failures a coarse readiness probe passes (e.g., the health endpoint is fine but a dependency the real traffic hits is timing out). Conversely, readiness catches a pod that is *starting up* or has *no live traffic yet*, which passive detection can't see because there are no responses to judge. They are complementary.

**Q4.2** — Ejection sequence: Envoy tallies responses per endpoint. When an endpoint returns **3 consecutive `5xx`** (connection resets count as `5xx` by default), then at the next analysis **`interval` (every 5 s)** Envoy ejects it — removes it from the LB pool — for **`baseEjectionTime` (30 s)**. Re-admission: after 30 s it is returned to the pool and probed with real traffic; if it fails again the ejection duration grows (multiplied by the ejection count), backing off repeat offenders.

**Q4.3** — `maxEjectionPercent` caps how much of the pool Envoy is *allowed* to eject. The default is conservative (10%), so with a small pool Envoy may **refuse to eject** additional bad endpoints even though they're failing. Worse, Envoy has a **panic threshold**: if the fraction of *healthy* endpoints drops below ~50%, it decides its health view is untrustworthy and **routes to all endpoints regardless of health** (panic routing) — sending traffic back to the sick ones. Setting `maxEjectionPercent: 100` (and/or tuning `minHealthPercent`) lets Envoy eject as many as are genuinely bad; but you must weigh that against panic routing when *most* endpoints are down.

**Q4.4** — **Locality failover** (Exercise 5). Envoy only demotes traffic from the local locality (priority 0) to a backup locality (priority 1) once the local endpoints are marked unhealthy — and the *only* mechanism that marks them unhealthy without active health checks is **outlier detection**. Without it, no endpoint ever becomes "unhealthy," so failover never triggers.

### Exercise 5

**Q5.1** — Hard dependency: **outlier detection must be configured.** Failover promotes a lower-priority locality only when higher-priority endpoints are *unhealthy*, and outlier detection is what produces that unhealthy signal. Omit it and failover is inert — all localities effectively stay at full health, so traffic never shifts even when the local zone is failing.

**Q5.2** — `failover` = **priority-based**: traffic stays 100% in the local locality until it's unhealthy, then spills to the named backup — for *availability* (disaster/zone-outage tolerance). `distribute` = **weighted split**: you explicitly send fixed percentages to named localities (e.g., 70/30) regardless of health — for *deliberate cross-zone traffic shaping*. Choose `failover` for keep-it-local-until-it-breaks; choose `distribute` when you want a specific standing cross-zone distribution.

**Q5.3** — Under all-healthy conditions a `failover` policy sends **0%** to the backup locality — 100% stays local. That is correct because same-zone traffic has the **lowest latency and avoids cross-zone data-transfer cost**; the backup is a cold standby that only takes load during a failure.

**Q5.4** — `topology.kubernetes.io/region` and `topology.kubernetes.io/zone` (Istio also honors a sub-zone via the `topology.istio.io/subzone` label). A pod on a node lacking these labels has **empty/unknown locality**; it is treated as a distinct locality that matches no `from`/`to` failover rule, so it participates as an ungrouped endpoint and does not benefit from locality-aware priority routing.

### Exercise 6

**Q6.1** — Order of action on one doomed request:
1. **Connection-pool limit (circuit breaking)** — evaluated *before the request leaves the client Envoy*; if saturated, `503 UO`, nothing hits the wire.
2. **Per-try timeout** — bounds each individual attempt once it's sent.
3. **Retry** — fires after a failed/timed-out attempt, subject to `retryOn`.
4. **Overall route timeout** — the wall-clock ceiling spanning all attempts+backoffs.
5. **Outlier ejection** — a *background* consequence: the failing endpoint's errors accrue and it's ejected at the next interval, affecting *future* requests, not this one.
The ones that can act **before the wire**: the **connection-pool circuit breaker** (and, indirectly, outlier ejection having already removed an endpoint from the pool).

**Q6.2** — During overload the circuit breaker is *shedding* load precisely because the backend is saturated. Large `attempts` re-injects each shed/failed request several times, multiplying the offered load against a service that is already at its limit — a **retry storm** that deepens the overload and can trip the breaker for everyone. Retries help isolated transient faults; they are counterproductive as a response to systemic saturation. Keep `attempts` small and pair with retry budgets/backoff.

**Q6.3** — With 3+ replicas, `consecutive5xxErrors: 5` ejects only endpoints that are *clearly* failing, and `maxEjectionPercent: 50` guarantees at most half the pool can be removed at once. So if two of four replicas go bad, Envoy ejects them and concentrates traffic on the two healthy ones — the service **stays up at reduced capacity** instead of Envoy ejecting everything (which would trigger panic routing or leave no endpoints) and blackholing the service. It trades some exposure to a bad endpoint for a guarantee that a majority-outage never wipes the whole pool.

</details>

---

### Sources

- Istio — *Circuit Breaking* task: https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — *Request Timeouts* task: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — *Network resilience and testing* (retries, timeouts, circuit breaking concepts): https://istio.io/latest/docs/concepts/traffic-management/#network-resilience-and-testing
- Istio — `HTTPRetry` reference: https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
- Istio — `ConnectionPoolSettings` reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings
- Istio — `OutlierDetection` reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/#OutlierDetection
- Istio — `LocalityLoadBalancerSetting` reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/#LocalityLoadBalancerSetting
- Istio — *Locality Load Balancing: Failover* task: https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/failover/
- Envoy — *Outlier detection* and *Circuit breaking* architecture: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier and https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- CNCF ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf