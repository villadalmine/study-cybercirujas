# 3.7 Using Fault Injection

> **Certification:** Istio Certified Associate (ICA) · **Domain 3 – Traffic Management** · **Topic weight: 5%**

---

## 1. Motivation: the production problem fault injection solves

A microservice mesh fails in ways that unit tests never reach. The interesting failures are **emergent**: a downstream service that is *slow but not down*, a dependency that returns `503` for 2% of requests, a retry storm that amplifies a transient blip into an outage. These are precisely the conditions your resilience configuration — timeouts, retries, circuit breakers, connection pools — is *supposed* to absorb. The architectural problem is that **you cannot know whether that configuration works until the failure actually happens**, and by then it is a production incident.

The classic trap is the **hidden hard-coded timeout**. A service team sets a client-side timeout in application code years ago; nobody remembers it. Operations later configures a longer mesh-level timeout, assuming it is authoritative. The two disagree, and the disagreement is invisible until a real dependency slows down. Fault injection lets you *reproduce that slowdown on demand, in a controlled blast radius*, and observe the mismatch before a customer does.

Istio implements fault injection **at Layer 7, inside the Envoy sidecar**, decoupled entirely from application code. This is the decisive property: you are testing the *real* service, over the *real* network path, with the *real* resilience config, without recompiling anything or touching the service under test. The fault is a property of the **route**, evaluated by the `envoy.filters.http.fault` filter in the proxy that owns that route config.

Two failure primitives cover the majority of real-world faults:

- **Delay** — inject latency before forwarding. Simulates an overloaded, GC-pausing, or network-degraded upstream. Tests **timeouts** and **latency budgets**.
- **Abort** — return a synthetic HTTP/gRPC error *without* contacting the upstream. Simulates a crashed, overloaded, or misbehaving upstream. Tests **retries**, **fallbacks**, and **circuit-breaker** behaviour.

### Where the fault is applied — the mechanics

For mesh-internal traffic, the VirtualService route config is programmed into the **client-side (source) sidecar** — the Envoy that owns the outbound listener for the destination host. That proxy runs the HTTP fault filter *before* the router forwards upstream. Consequences that trip people up in production:

1. **The source pod must be in the mesh.** If the caller has no sidecar (or is excluded from injection), the outbound route config — and therefore the fault — is never evaluated. No fault is applied.
2. **Injected aborts never reach the upstream.** The upstream sees zero traffic for aborted requests; the error is synthesised locally. This is why abort is cheap and instantaneous.
3. **Injected delays consume the caller's request budget.** The delay is added to the caller's observed latency and counts against *its* timeout — which is exactly what makes it a useful test.
4. **Percentage is sampled per-request**, independently, against a runtime value. 10% does not mean "every 10th request"; it means each request has an independent 10% probability.

```
                    source pod (in mesh)                         destination pod
   ┌──────────────────────────────────────────┐            ┌───────────────────────┐
   │  app  ──▶  istio-proxy (Envoy)            │            │  istio-proxy ──▶ app  │
   │            ├─ outbound listener :9080     │            │                       │
   │            ├─ HTTP conn manager           │            │                       │
   │            │    └─ envoy.filters.http.fault│──abort?──╳ (upstream NEVER hit)   │
   │            │         ├─ delay  (sleep)     │            │                       │
   │            │         └─ abort  (503/…)     │            │                       │
   │            └─ router ─────────────────────────delay?──▶ │  (hit after latency)  │
   └──────────────────────────────────────────┘            └───────────────────────┘
```

---

## 2. Technical comparisons and trade-offs

### 2.1 Delay vs Abort

| Dimension | **Delay** | **Abort** |
|---|---|---|
| Envoy action | Hold the request `fixedDelay`, then forward | Return a synthetic status; do **not** forward |
| Simulates | Slow/overloaded upstream, network latency, GC pause | Crashed upstream, 5xx storms, connection refused |
| Resilience config it exercises | Timeouts, latency budgets, deadline propagation | Retries, `retryOn` matching, fallbacks, outlier detection |
| Upstream load impact | Upstream is still hit (after the delay) | Upstream receives **no** traffic for aborted requests |
| Caller latency impact | Increases by `fixedDelay` | Effectively zero (immediate error) |
| Interaction with retries | Delay is re-incurred on each retry attempt | Retried **only if** the status matches `retryOn` |
| Cost of running | Holds a request slot for the delay duration (watch connection pools) | Negligible |
| Common false-negative | Retries mask the latency; timeout larger than delay | Status not in `retryOn`, so no retry path is tested |

### 2.2 Fault injection layer — Istio vs alternatives

| Tool | Layer | Granularity | Injects | App changes | Blast-radius control | Best for |
|---|---|---|---|---|---|---|
| **Istio fault injection** | L7 (HTTP/gRPC, in Envoy) | Per-route, per-header, per-% | Delay, HTTP/gRPC abort | None | Header/route match, % | Deterministic, targeted resilience tests inside a mesh |
| **Chaos Mesh** | L3/L4 + pod/OS | Pod, node, network, IO, kernel | Pod kill, netem delay/loss, partition | None | Label selectors | Infra-level chaos (node loss, packet loss, disk) |
| **Litmus** | Pod/infra | Experiment CRDs | Pod/network/resource chaos | None | Label selectors | GameDays, scheduled chaos pipelines |
| **Toxiproxy** | L4 proxy | Per-connection | Latency, bandwidth, slicing | Reconfigure endpoint to proxy | Per-proxy | Local/integration test harnesses |
| **App-level (e.g. Failsafe/Resilience4j test hooks)** | In-process | Method call | Exceptions, delay | **Yes** | Code path | Unit/component tests |

**Trade-off summary.** Istio operates at L7, so it understands HTTP status codes and gRPC statuses and can target a *single user* by header — something an L3 netem rule cannot do. Its limitation is the flip side: it only faults traffic that traverses an Envoy proxy on an HTTP/gRPC route. To fault a raw TCP dependency, a DNS lookup, or the node itself, you need L3/L4 chaos (Chaos Mesh). In production, the two are **complementary**: Istio for request-path resilience, Chaos Mesh for infrastructure resilience.

### 2.3 `percentage` vs `percent` (API footgun)

| Field | Type | Range | Status | Meaning if omitted |
|---|---|---|---|---|
| `fault.delay.percentage.value` | double | `0.0`–`100.0` | **Current** | Treated as **100%** |
| `fault.abort.percentage.value` | double | `0.0`–`100.0` | **Current** | Treated as **100%** |
| `fault.delay.percent` | int32 | `0`–`100` | **Deprecated** | — |

> **Diagnosis gotcha:** omitting the percentage entirely means **100%** injection, not 0%. A VirtualService that faults "just to see what happens" without a percentage will fault *every* matching request. Always set an explicit `percentage.value`, and always scope with a `match` when testing in a shared environment.

---

## 3. Complete, syntactically valid manifests

The examples target the standard **Bookinfo** application. Requests flow `productpage → reviews → ratings`. We inject faults on the `productpage → reviews` and `reviews → ratings` edges.

### 3.1 Prerequisite: DestinationRules (subsets)

Fault-injecting VirtualServices route to named subsets, which must be declared once in a DestinationRule.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
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
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ratings
  namespace: bookinfo
spec:
  host: ratings
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

### 3.2 Delay fault — targeted at one user (Bookinfo bug reproduction)

Inject a **7 s** delay on `ratings`, but **only** for requests carrying `end-user: jason`. All other traffic is routed normally. This is the canonical resilience test.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      delay:
        percentage:
          value: 100.0      # 100% of jason's requests
        fixedDelay: 7s
    route:
    - destination:
        host: ratings
        subset: v1
  - route:                  # everyone else: no fault
    - destination:
        host: ratings
        subset: v1
```

**Why this exposes a bug.** `reviews:v2/v3` has a **10 s** hard-coded application timeout on its call to `ratings`, so a 7 s delay *should* pass. But `productpage → reviews` carries a **3 s timeout with 1 retry = 6 s** total budget. Because `7s > 6s`, the `productpage → reviews` call times out at ~6 s and the page renders *"Sorry, product reviews are currently unavailable for this book."* The two timeouts disagree — the exact hidden-timeout failure fault injection is designed to surface.

### 3.3 Abort fault — synthetic 500 for one user

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    fault:
      abort:
        percentage:
          value: 100.0
        httpStatus: 500
    route:
    - destination:
        host: ratings
        subset: v1
  - route:
    - destination:
        host: ratings
        subset: v1
```

The page loads **immediately** for jason and shows *"Ratings service is currently unavailable"* — `reviews` degrades gracefully because ratings returns a hard error fast, unlike the delay case.

### 3.4 Partial abort + gRPC abort (steady-state error-rate simulation)

Fault **10%** of unmatched (all-user) traffic with a `503`, and demonstrate the gRPC form for a gRPC upstream.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings-partial
  namespace: bookinfo
spec:
  hosts:
  - ratings
  http:
  - fault:
      abort:
        percentage:
          value: 10.0       # each request independently has a 10% chance
        httpStatus: 503
    route:
    - destination:
        host: ratings
        subset: v1
---
# gRPC upstream variant — abort with a gRPC status instead of HTTP
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: grpc-catalog
  namespace: bookinfo
spec:
  hosts:
  - catalog.bookinfo.svc.cluster.local
  http:
  - fault:
      abort:
        percentage:
          value: 5.0
        grpcStatus: "UNAVAILABLE"   # maps to gRPC code 14
    route:
    - destination:
        host: catalog.bookinfo.svc.cluster.local
```

### 3.5 Fault + timeout + retries in one route (interplay under test)

This is the manifest you actually run to validate a resilience policy end to end. It injects a delay **and** declares the mesh-level timeout/retry you want to prove correct.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-resilience
  namespace: bookinfo
spec:
  hosts:
  - reviews
  http:
  - fault:
      delay:
        percentage:
          value: 50.0
        fixedDelay: 5s
    timeout: 3s              # mesh timeout: 5s delay > 3s ⇒ deadline exceeded
    retries:
      attempts: 2
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,retriable-4xx,reset
    route:
    - destination:
        host: reviews
        subset: v2
```

> **Semantics to internalise:** the injected 5 s delay is re-incurred on *every* retry attempt. With `perTryTimeout: 2s` and a 5 s delay, **each** attempt is cut at 2 s. Note `retryOn` here does **not** include `503`; an injected *abort* of `503` would therefore **not** be retried. To test the retry path with an abort, inject a status listed in `retryOn` (e.g. `retriable-4xx` → `503`? no — use `gateway-error` covers 502/503/504). Match the injected status to your `retryOn` set or the retry code path is never exercised — a silent false negative.

---

## 4. CLI commands and real terminal output

### 4.1 Apply and confirm the resources exist

```console
$ kubectl apply -f ratings-delay-jason.yaml -n bookinfo
virtualservice.networking.istio.io/ratings configured

$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.

$ kubectl get virtualservice ratings -n bookinfo -o jsonpath='{.spec.http[0].fault}' | jq
{
  "delay": {
    "fixedDelay": "7s",
    "percentage": {
      "value": 100
    }
  }
}
```

### 4.2 Prove the fault is programmed into Envoy (not just accepted by the API)

The API accepting a manifest does **not** prove the proxy applied it. Inspect the source sidecar's route config. The fault lives under `typedPerFilterConfig["envoy.filters.http.fault"]`.

```console
$ REVIEWS_POD=$(kubectl get pod -n bookinfo -l app=reviews,version=v2 -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config route "$REVIEWS_POD.bookinfo" --name 9080 -o json \
    | jq '.[].virtualHosts[] | select(.name|test("ratings")) | .routes[].typedPerFilterConfig'
{
  "envoy.filters.http.fault": {
    "@type": "type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault",
    "delay": {
      "fixedDelay": "7s",
      "percentage": {
        "numerator": 100,
        "denominator": "HUNDRED"
      }
    }
  }
}
```

> If this block is **absent**, the fault is not active on that path — check that you are inspecting the **source** (caller) proxy, that the route matches (headers/subset), and that `istioctl analyze` is clean.

### 4.3 Trigger and observe — delay

```console
$ GATEWAY_URL=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):80

# Without the header: fast, normal
$ curl -s -o /dev/null -w 'HTTP %{http_code}  total=%{time_total}s\n' \
    "http://$GATEWAY_URL/productpage"
HTTP 200  total=0.048s

# As user jason: the injected 7s delay trips the 6s productpage→reviews budget
$ curl -s -o /dev/null -w 'HTTP %{http_code}  total=%{time_total}s\n' \
    -b 'session=jason-cookie' -H 'end-user: jason' \
    "http://$GATEWAY_URL/productpage"
HTTP 200  total=6.031s
```

The page returns `200` in ~6 s (the `reviews` timeout budget), **not** 7 s — the reviews section shows the "unavailable" error. That 1-second gap between injected delay and observed latency *is* the bug.

### 4.4 Trigger and observe — abort

```console
$ curl -s -H 'end-user: jason' "http://$GATEWAY_URL/productpage" | grep -o 'Ratings service is currently unavailable'
Ratings service is currently unavailable

# Direct call from an in-mesh client to see the raw synthetic status
$ kubectl exec -n bookinfo deploy/productpage-v1 -c productpage -- \
    curl -s -o /dev/null -w '%{http_code}\n' -H 'end-user: jason' http://ratings:9080/ratings/0
500
```

### 4.5 Envoy fault counters — the ground truth

Envoy increments dedicated counters every time a fault actually fires. These are the authoritative proof of injection.

```console
$ kubectl exec -n bookinfo "$REVIEWS_POD" -c istio-proxy -- \
    pilot-agent request GET stats | grep -E 'fault\.(delays_injected|aborts_injected|active_faults)'
http.outbound_0.0.0.0_9080.fault.aborts_injected: 0
http.outbound_0.0.0.0_9080.fault.delays_injected: 42
http.outbound_0.0.0.0_9080.fault.active_faults: 0
http.outbound_0.0.0.0_9080.fault.faults_overflow: 0
```

`delays_injected: 42` confirms 42 requests were actually delayed. `active_faults` shows concurrent in-flight delays (watch this against connection-pool limits under load). `faults_overflow` increments when Envoy's `max_active_faults` cap is hit and a fault is *skipped* — a critical, easily-missed reason a load test sees fewer faults than the configured percentage.

---

## 5. Verification and failure diagnosis

### 5.1 Verification ladder (cheapest first)

| Rung | Question | Command | Proves |
|---|---|---|---|
| 1 | Is the manifest valid & consistent? | `istioctl analyze -n bookinfo` | Config sane, subsets exist |
| 2 | Is the fault in the API object? | `kubectl get vs … -o jsonpath='{.spec.http[*].fault}'` | Author intent stored |
| 3 | Is it programmed into the **source** proxy? | `istioctl proxy-config route <src-pod> -o json` | Envoy actually has the filter config |
| 4 | Does a request behave as expected? | `curl -w '%{http_code} %{time_total}'` | Observable behaviour |
| 5 | Did Envoy really fire the fault? | `pilot-agent request GET stats \| grep fault` | Ground-truth counters |

Never stop at rung 2. "The API accepted it" and "the proxy is applying it" are different statements — the gap between them is where most fault-injection debugging happens.

### 5.2 Diagnosis table

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| No fault ever fires | Source pod not in mesh, or you inspected the wrong (destination) proxy | Rung 3 shows no `envoy.filters.http.fault` on the **caller** | Ensure caller has sidecar injection; inspect the source proxy |
| Fault fires for *everyone* | `percentage` omitted (defaults to 100%) or `match` missing | Rung 2 shows no `percentage`; rung 5 counter ≈ total requests | Add explicit `percentage.value` and a header `match` |
| Fewer faults than % under load | `faults_overflow` — hit `max_active_faults`, or retries re-sample | `…fault.faults_overflow > 0` | Reduce concurrency, or account for the cap in test math |
| Injected abort not retried | Status not in `retryOn` | Route has retries but abort status excluded | Inject a status in `retryOn`, or add it |
| Delay smaller than observed effect | Retries multiply the delay (delay re-incurred per attempt) | `…upstream_rq_retry` counter climbing | Set `perTryTimeout`; reason about `attempts × delay` |
| Fault on wrong host | Matched a different subset/route order | `istioctl proxy-config route` shows match order | Put the specific `match` block **before** the catch-all route |
| `503 UF`/`NR` instead of injected code | Subset/DestinationRule missing, no healthy endpoints | `istioctl proxy-config endpoint <pod>` empty | Create the DestinationRule subset the route targets |

### 5.3 Correlating with distributed traces

Because the fault is an Envoy filter on the request path, injected delays and aborts appear in the span timeline. In the trace UI the delayed span shows the added latency inside the caller's Envoy egress, and an aborted request produces a span tagged with the synthetic `error=true` / `http.status_code=500` — visually distinguishing a *synthetic* fault from a genuine upstream failure. This is how you confirm, during a GameDay, that observed latency came from injection and not a real regression.

### 5.4 Safe rollback

Fault injection is a live edit to the data plane. Remove it cleanly and re-verify to zero:

```console
$ kubectl delete virtualservice ratings -n bookinfo
virtualservice.networking.istio.io "ratings" deleted
# or restore the fault-free baseline:
$ kubectl apply -f samples/bookinfo/networking/virtual-service-all-v1.yaml -n bookinfo

$ kubectl exec -n bookinfo "$REVIEWS_POD" -c istio-proxy -- \
    pilot-agent request GET stats | grep fault.delays_injected
http.outbound_0.0.0.0_9080.fault.delays_injected: 42   # counter frozen; no new injections
```

Best practices for production meshes: **always scope with a header `match`** so only synthetic test users are affected; keep the percentage explicit and low for steady-state chaos; run injection through a change-managed, time-boxed window; and treat `faults_overflow` and connection-pool saturation as first-class signals when injecting *delays* under load.

---

## 6. References

- Istio — Fault Injection task (delay & abort walkthrough): https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio — Virtual Service API reference (`HTTPFaultInjection`, `Delay`, `Abort`): https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPFaultInjection
- Istio — Request Timeouts task: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — Request Routing & the Bookinfo application: https://istio.io/latest/docs/examples/bookinfo/
- Istio — Traffic Management concepts: https://istio.io/latest/docs/concepts/traffic-management/
- Envoy — HTTP fault injection filter (`envoy.filters.http.fault`): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter
- Envoy — Fault filter runtime & statistics (`delays_injected`, `aborts_injected`, `active_faults`, `faults_overflow`): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter#statistics
- Istio — `istioctl proxy-config route` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config-route
- CNCF — ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf