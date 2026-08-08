# 3.6 — Using Resilience Features

*Circuit breaking · failover · outlier detection · timeouts · retries*

> **Exam weight: 5.** This objective is where Istio stops being "traffic routing" and becomes a **failure-management substrate**. Every lever here is a knob on the sidecar's embedded Envoy proxy. Understanding *which Envoy primitive* each Istio field compiles to is the difference between passing the exam and shipping a retry storm to production.

---

## 1. The production problem: a mesh amplifies failure by default

A service mesh injects a proxy on **every** hop. That proxy will happily forward a request to a host that is quietly dying, retry a request that was doomed the first time, and hold a connection open to a backend that will never answer. Without resilience configuration, the mesh's uniformity works *against* you — a single degraded pod can be amplified into a mesh-wide brownout through three classic mechanisms:

| Failure mode | Mechanism | Symptom |
|---|---|---|
| **Cascading failure** | Caller threads block on a slow dependency → thread pool exhausts → caller becomes slow → *its* callers exhaust → wavefront up the call graph | Whole call chain latency spikes, no single "cause" pod |
| **Retry storm / metastable failure** | A backend hiccups; every client retries N×; effective load becomes `(1+N)×` at the exact moment the backend is weakest → it never recovers even after the trigger clears | Load stays pinned high after the original fault is gone |
| **Gray failure** | A pod passes its Kubernetes liveness/readiness probe (control plane) but returns 503s to *actual* traffic (data plane) | k8s keeps it in the Endpoints list; traffic keeps hitting a broken host |

The five features in this objective map one-to-one onto these problems:

- **Timeouts** bound how long a caller waits → break the *cascade wavefront*.
- **Retries** paper over transient faults → but *must be bounded* or they *are* the storm.
- **Circuit breaking** (connection-pool limits) sheds load before a backend is overwhelmed → break the *metastable loop*.
- **Outlier detection** is passive, data-plane health checking → catch the *gray failure* the readiness probe missed.
- **Failover** (locality load balancing) redirects away from an unhealthy zone/region → survive a *partial* infrastructure outage.

Two API objects hold everything:

| Resource | Owns | Envoy config it compiles to |
|---|---|---|
| **`VirtualService`** (`http.timeout`, `http.retries`) | *Per-route* request behavior | Envoy **route** (`route.timeout`, `route.retry_policy`) |
| **`DestinationRule`** (`trafficPolicy.connectionPool`, `.outlierDetection`, `.loadBalancer.localityLbSetting`) | *Per-cluster* (per upstream host/subset) behavior | Envoy **cluster** (`circuit_breakers`, `outlier_detection`, `lb_policy` + priorities) |

> **Mental model that the exam rewards:** *Retries and timeouts are properties of a request (route). Circuit breaking, outlier detection and failover are properties of a destination (cluster).* If you can't change something with a VirtualService, it belongs in a DestinationRule, and vice-versa.

---

## 2. Timeouts

By default **Istio applies no HTTP request timeout** (`0s` = disabled). This is the single most dangerous default in the mesh: a caller will wait forever for a backend that hung mid-response. You almost always want to set one.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
            subset: v2
      timeout: 2s          # wall-clock budget for the ENTIRE request, retries included
```

**Mechanics:** the timeout is the total budget observed by the sidecar of the *caller*. When it fires, Envoy resets the upstream stream and returns `504 Gateway Timeout` downstream, stamping the access-log response flag **`UT`** (Upstream Timeout). Critically, `timeout` is the envelope for *all* retry attempts — see §3 for the interaction.

Per-request override via the `x-envoy-upstream-rq-timeout-ms` header is **disabled by default** in Istio (`mesh.defaultConfig` does not surface it); do not rely on it in exam answers.

---

## 3. Retries

Istio installs a **default retry policy even if you configure nothing**: `attempts: 2` on the condition set `connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes`. This is why "I never configured retries but I see 3 requests hit my backend" is normal. Override it explicitly per route:

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
    - route:
        - destination:
            host: ratings
            subset: v1
      timeout: 3s
      retries:
        attempts: 3                       # up to 3 RE-tries (4 total attempts)
        perTryTimeout: 800ms              # budget per individual attempt
        retryOn: >-
          connect-failure,refused-stream,unavailable,gateway-error,retriable-4xx,5xx
        retryRemoteLocalities: true       # allow retries to cross into another locality
```

### The budget arithmetic that trips up engineers

`attempts × perTryTimeout` must fit inside the overall `timeout`, or later retries never fire — the wall-clock envelope closes first.

| overall `timeout` | `attempts` | `perTryTimeout` | Effective behavior |
|---|---|---|---|
| `3s` | 3 | `800ms` | ✅ Up to ~3.2s of attempts fit inside 3s → retries 1–2 fire, 3rd may be cut by envelope |
| `1s` | 3 | `800ms` | ⚠️ Only ~1 attempt + a sliver → 2nd/3rd retries silently never happen |
| `10s` | 3 | *(unset)* | 🔥 Each attempt inherits the 10s overall timeout → 3 hung attempts = 30s of amplified load; **never leave `perTryTimeout` unset with retries** |

### `retryOn` conditions (Envoy `retry_on` values)

| Value | Retries when… | Idempotency risk |
|---|---|---|
| `connect-failure` | TCP connect to upstream failed (never reached the app) | **Safe** |
| `refused-stream` | Upstream sent HTTP/2 `REFUSED_STREAM` (not processed) | **Safe** |
| `reset` | Upstream reset the stream before/without response | Safe-ish |
| `unavailable` | gRPC status `UNAVAILABLE` (14) | Depends |
| `gateway-error` | 502, 503, 504 | **Dangerous** — request may have been processed |
| `retriable-4xx` | 409 (configurable) | Depends |
| `5xx` | any 5xx | **Most dangerous** — includes 500 from a request that mutated state |
| `retriable-status-codes` | codes in `x-envoy-retriable-status-codes` | Explicit |
| `retriable-headers` | upstream set `x-envoy-retriable-header-names` | Server opt-in |

> **SRE rule:** retry **only on failures that provably never reached application logic** (`connect-failure`, `refused-stream`, `reset`) for non-idempotent endpoints. Reserve `5xx`/`gateway-error` for reads (`GET`). A blanket `5xx` retry on a `POST /charge` double-bills customers.

---

## 4. Circuit breaking — the connection pool

"Circuit breaking" in Istio is the **`connectionPool`** stanza of a DestinationRule. It compiles to Envoy's **`circuit_breakers`** on the cluster. These are hard ceilings; when a request would exceed a limit, Envoy **immediately** returns `503` with the response flag **`UO`** (Upstream Overflow) and header `x-envoy-overloaded: true` — it fails *fast* instead of queueing. That fast-fail is the entire point: shedding load protects the backend from the metastable retry loop.

By default Istio sets these ceilings to `2^32-1` (`4294967295`) — **effectively unlimited, i.e. circuit breaking is OFF until you configure it.**

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-cb
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100          # max concurrent TCP conns to the whole cluster
        connectTimeout: 250ms        # TCP connect budget (compiles to cluster connect_timeout)
        tcpKeepalive:
          time: 7200s
          interval: 75s
          probes: 9
      http:
        http1MaxPendingRequests: 100 # queued (not yet dispatched) HTTP/1.1 requests
        http2MaxRequests: 1000       # max concurrent requests (HTTP/2 AND the effective HTTP/1 request cap)
        maxRequestsPerConnection: 10 # >1; forces conn recycling (defeats broken keep-alive / helps rebalancing). 1 = disable keep-alive
        maxRetries: 3                # max concurrent retries across the cluster (retry budget, NOT per-request attempts)
        idleTimeout: 30s             # close upstream conn after idle
        h2UpgradePolicy: UPGRADE
```

### Field semantics you must not confuse

| Field | Envoy primitive | What it limits | Overflow flag |
|---|---|---|---|
| `tcp.maxConnections` | `max_connections` | Concurrent L4 connections | `upstream_cx_overflow` |
| `http.http1MaxPendingRequests` | `max_pending_requests` | Requests **waiting for a connection** | `upstream_rq_pending_overflow` → 503 `UO` |
| `http.http2MaxRequests` | `max_requests` | Concurrent **in-flight** requests (also caps HTTP/1) | `upstream_rq_overflow` → 503 `UO` |
| `http.maxRetries` | `max_retries` | Concurrent retries mesh-wide to this cluster | `upstream_rq_retry_overflow` |
| `http.maxRequestsPerConnection` | `max_requests_per_connection` | Requests before a conn is recycled | — |

> **Exam trap:** `maxRetries` (DestinationRule, cluster-level retry *budget*) is **not** `retries.attempts` (VirtualService, per-request retry *count*). One caps how many retries can be *in flight simultaneously* across all callers; the other caps how many times a *single* request is retried.

### Tripping the breaker — reproducible lab

Deploy `httpbin` with an aggressive breaker, then overload it with `fortio`.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin-cb
  namespace: default
spec:
  host: httpbin
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 3m
      maxEjectionPercent: 100
```

```console
$ kubectl apply -f httpbin-cb.yaml
destinationrule.networking.istio.io/httpbin-cb created

$ export FORTIO=$(kubectl get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')

# 2 concurrent connections, 20 requests — exceeds maxConnections=1 + pending=1
$ kubectl exec "$FORTIO" -c fortio -- \
    /usr/bin/fortio load -c 2 -qps 0 -n 20 -loglevel Warning http://httpbin:8000/get
07:41:12 I httprunner.go:82> Starting http test for http://httpbin:8000/get with 2 threads at -1.0 qps
Code 200 : 12 (60.0 %)
Code 503 : 8 (40.0 %)
Response Header Sizes : count 20 avg 138.6 ...
All done 20 calls (plus 0 warmup) 3.２ ms avg, 501.2 qps
```

The 40% of `503`s are the breaker firing. Confirm at the source — the *caller's* Envoy stats, not the server's:

```console
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=httpbin.*(overflow|pending)' 
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_cx_overflow: 5
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_overflow: 8
cluster.outbound|8000||httpbin.default.svc.cluster.local.upstream_rq_pending_total: 20
```

`upstream_rq_pending_overflow: 8` is the ground truth — 8 requests were rejected because the pending queue (depth 1) was full. **This counter is your circuit-breaker SLI.** Alert on its rate of change.

---

## 5. Outlier detection — passive health checking

Outlier detection is the mesh's answer to the **gray failure**: a host that Kubernetes still lists as Ready but that returns errors to real traffic. Envoy watches live request results and **ejects** (temporarily removes from the load-balancing pool) any host that misbehaves. It is *passive* — no synthetic probes; it reads the traffic already flowing.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-od
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5          # eject after 5 consecutive 5xx (or gRPC-mapped) errors
      consecutiveGatewayErrors: 3      # subset of 5xx: 502/503/504 + connect failures
      interval: 10s                    # sweep period: how often ejection is evaluated
      baseEjectionTime: 30s            # first ejection = 30s; multiplies each re-ejection (30s,60s,90s…)
      maxEjectionPercent: 50           # NEVER eject more than 50% of the pool (availability floor)
      minHealthPercent: 40             # below 40% healthy → PANIC MODE: LB to ALL hosts (see below)
      splitExternalLocalOriginErrors: false
```

### How ejection actually works (Envoy internals)

1. Every `interval`, Envoy's outlier-detection engine sweeps the cluster's hosts.
2. A host that hit `consecutive5xxErrors` in a row is **ejected** for `baseEjectionTime`.
3. The ejection duration is `baseEjectionTime × (number of times this host has been ejected)` — repeat offenders stay out **longer** (backoff).
4. After the timer expires the host is returned to the pool; if it fails again it's ejected for a longer interval.
5. **`maxEjectionPercent` is a hard guard rail.** Even if every host is failing, Envoy refuses to eject more than this fraction — otherwise outlier detection would take down a service that is *globally* degraded (e.g. a bad downstream config causing 500s everywhere), turning a partial outage into a total one.

### Panic threshold — the counter-intuitive safety valve

`minHealthPercent` (Envoy's *healthy panic threshold*, default 50%). If ejections drop the healthy pool **below** this fraction, Envoy enters **panic mode** and **load-balances across *all* hosts, including the ejected ones.** The logic: if most of the fleet looks unhealthy, the problem is more likely your *health signal* than the fleet — better to spray traffic everywhere than to hammer the last one or two "healthy" hosts into the ground. Watch the stat `cluster.<name>.lb_healthy_panic`.

### `consecutive5xxErrors` vs `consecutiveGatewayErrors` vs local-origin

| Setting | Counts as an "error" |
|---|---|
| `consecutiveGatewayErrors` | **Gateway** errors only: `502`, `503`, `504`, plus connect failures/timeouts |
| `consecutive5xxErrors` | **All** of the above **plus** application `500`, `501`, `505`, and gRPC error codes |
| `consecutiveLocalOriginFailures` | Only *locally-originated* failures (connect timeout, reset) — never an app-level 5xx. Requires `splitExternalLocalOriginErrors: true` |

`splitExternalLocalOriginErrors: true` separates **"the network/connection to the host failed"** (local origin) from **"the host answered, but with a 5xx"** (external origin). Turn it on when you want to eject a host only for *connectivity* problems and not blame it for legitimate application 500s it merely relayed.

### Verifying an ejection — the definitive check

`istioctl proxy-config endpoint` shows EDS membership but **not** live outlier state. The authoritative view is the Envoy `/clusters` admin page, where an ejected host carries `health_flags::/failed_outlier_check`:

```console
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET clusters | grep 'httpbin.*health_flags'
outbound|8000||httpbin.default.svc.cluster.local::10.244.1.37:80::health_flags::/failed_outlier_check
outbound|8000||httpbin.default.svc.cluster.local::10.244.2.19:80::health_flags::healthy

# Ejection counters
$ kubectl exec "$FORTIO" -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=httpbin.*outlier'
cluster.outbound|8000||httpbin...outlier_detection.ejections_active: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_enforced_consecutive_5xx: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_detected_consecutive_5xx: 1
cluster.outbound|8000||httpbin...outlier_detection.ejections_overflow: 0
```

`ejections_active: 1` = one host is currently out. `ejections_overflow` increments when `maxEjectionPercent` blocked an ejection that *would* otherwise have happened — a signal that your whole backend is unhealthy, not one host.

---

## 6. Failover — locality-aware load balancing

Failover is **outlier detection applied across topology**. When outlier detection ejects the hosts in a caller's *own* zone, Istio uses Envoy's **priority levels** to spill traffic to the next-closest locality — same region other zone, then other region — instead of failing. **Failover requires `outlierDetection` to be configured; without it there is no health signal to trigger the spill.**

Locality is derived from standard node labels, propagated to each endpoint:

| Locality tier | Node label |
|---|---|
| Region | `topology.kubernetes.io/region` |
| Zone | `topology.kubernetes.io/zone` |
| Sub-zone | `topology.istio.io/subzone` |

### 6a. Region-to-region failover

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-failover
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  trafficPolicy:
    outlierDetection:                 # MANDATORY for failover to activate
      consecutive5xxErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failover:
          - from: us-west-1
            to: us-east-1             # if us-west-1 is unhealthy, fail over to us-east-1
          - from: us-east-1
            to: us-west-1
```

### 6b. Weighted distribution (split, not failover)

Use `distribute` to *deliberately* spread traffic (e.g. 80% local zone / 20% peer zone for warm capacity), independent of health:

```yaml
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
          - from: us-west-1/us-west-1a/*
            to:
              "us-west-1/us-west-1a/*": 80
              "us-west-1/us-west-1b/*": 20
```

### 6c. `failoverPriority` — order by label match

`failoverPriority` builds Envoy priority levels by counting matching labels — endpoints sharing more labels with the caller get higher priority:

```yaml
    loadBalancer:
      localityLbSetting:
        enabled: true
        failoverPriority:
          - "topology.kubernetes.io/region"
          - "topology.kubernetes.io/zone"
          - "topology.istio.io/subzone"
```

An endpoint matching region+zone+subzone is priority 0; region+zone is priority 1; region only is priority 2; the rest priority 3. Envoy sends traffic to priority 0 until its healthy fraction drops, then bleeds into priority 1, and so on. This is the smooth, gradual failover you want.

| Knob | Behavior | Health-driven? |
|---|---|---|
| `failover` | Explicit region→region fallback map | ✅ triggered by outlier detection |
| `failoverPriority` | Order localities by label-match depth | ✅ gradual spill by priority |
| `distribute` | Fixed weighted spread across localities | ❌ static, always applied |

Confirm the priorities and health-weighting reached the sidecar:

```console
$ istioctl proxy-config endpoint "$FORTIO" \
    --cluster "outbound|9080||reviews.bookinfo.svc.cluster.local" -o json \
  | jq -r '.[].hostStatuses[] | "\(.address.socketAddress.address)  weight=\(.weight)  \(.healthStatus.edsHealthStatus)"'
10.0.1.12  weight=1  HEALTHY
10.0.1.13  weight=1  HEALTHY
10.0.2.44  weight=1  HEALTHY   # priority-1 (peer zone) endpoint, dormant until local ejected
```

---

## 7. Putting it together — a fully resilient destination

A production DestinationRule + VirtualService pair combining all five levers. This is the shape to reproduce from memory for the exam.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments
  namespace: shop
spec:
  host: payments.shop.svc.cluster.local
  trafficPolicy:
    connectionPool:                 # 4 & circuit breaking
      tcp:
        maxConnections: 200
        connectTimeout: 200ms
      http:
        http1MaxPendingRequests: 64
        http2MaxRequests: 512
        maxRequestsPerConnection: 20
        maxRetries: 16
        idleTimeout: 30s
    outlierDetection:               # 5 & passive health + 6 failover trigger
      consecutiveGatewayErrors: 5
      consecutive5xxErrors: 10
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
      minHealthPercent: 30
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
    loadBalancer:                   # 6 failover
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failoverPriority:
          - "topology.kubernetes.io/region"
          - "topology.kubernetes.io/zone"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payments
  namespace: shop
spec:
  hosts:
    - payments.shop.svc.cluster.local
  http:
    - route:
        - destination:
            host: payments.shop.svc.cluster.local
      timeout: 2s                    # 2 timeout — total envelope
      retries:                       # 3 retries — SAFE conditions only (payments = non-idempotent)
        attempts: 2
        perTryTimeout: 750ms
        retryOn: connect-failure,refused-stream,reset
        retryRemoteLocalities: false # do NOT cross localities on retry for a write path
```

Note the deliberate choices: **reads** would use `retryOn: 5xx,gateway-error` and `retryRemoteLocalities: true`; this **write** path retries only on failures that never reached application logic and never crosses a region on retry.

---

## 8. Verification & failure diagnosis

### 8.1 Response-flag decoder ring

Enable access logs (`meshConfig.accessLogFile: /dev/stdout`) and read the flag in `%RESPONSE_FLAGS%`. This is the fastest path from symptom to root cause.

| Flag | Meaning | Which resilience feature |
|---|---|---|
| `UO` | Upstream **O**verflow | **Circuit breaker** (connection pool) tripped |
| `UH` | No healthy **U**pstream — all hosts ejected or gone | **Outlier detection** ejected everything (or endpoints empty) |
| `UT` | Upstream **T**imeout | **Timeout** (overall or per-try) fired |
| `URX` | Upstream **R**etry limit e**X**ceeded | **Retries** exhausted (`attempts` or `maxRetries` budget) |
| `UF` | Upstream connection **F**ailure | Connect failed (→ retryable with `connect-failure`) |
| `UC` | Upstream **C**onnection termination | Backend reset the connection mid-response |
| `NR` | **N**o **R**oute | VirtualService/routing gap — *not* a resilience issue; a config bug |

```console
$ kubectl logs "$FORTIO" -c istio-proxy | tail -3
[2026-08-08T07:52:01.442Z] "GET /get HTTP/1.1" 503 UO ... "-" "fortio.org/fortio" ... upstream_reset_before_response_started{overflow}
[2026-08-08T07:52:01.501Z] "GET /get HTTP/1.1" 200 -  ...
[2026-08-08T07:52:02.010Z] "GET /get HTTP/1.1" 504 UT ... upstream_response_timeout
```

`503 UO` → circuit breaker. `504 UT` → timeout. Never guess; read the flag.

### 8.2 What compiled to Envoy? (`istioctl`)

```console
# Is the DestinationRule/VirtualService valid & consistent?
$ istioctl analyze -n shop
✔ No validation issues found when analyzing namespace: shop.

# Did the circuit breaker + outlier config actually reach the cluster?
$ istioctl proxy-config cluster "$FORTIO" --fqdn payments.shop.svc.cluster.local -o json \
  | jq '.[0] | {maxConnections:.circuitBreakers.thresholds[0].maxConnections,
                maxPending:.circuitBreakers.thresholds[0].maxPendingRequests,
                outlier:.outlierDetection}'
{
  "maxConnections": 200,
  "maxPending": 64,
  "outlier": {
    "consecutive5xx": 10,
    "interval": "10s",
    "baseEjectionTime": "30s",
    "maxEjectionPercent": 50,
    "enforcingConsecutiveGatewayErrors": 100
  }
}

# Did the route timeout & retry policy reach the route?
$ istioctl proxy-config route "$FORTIO" --name 9080 -o json \
  | jq '.[].virtualHosts[].routes[].route | {timeout, retry:.retryPolicy}'
{
  "timeout": "2s",
  "retry": { "retryOn": "connect-failure,refused-stream,reset",
             "numRetries": 2, "perTryTimeout": "0.750s" }
}
```

If `istioctl proxy-config` shows the values but behavior is wrong, the config *reached* Envoy — look at load and stats. If it does **not** show them, the DestinationRule host FQDN or namespace is wrong, or a competing DR is winning (`istioctl analyze` warns on conflicting DRs for the same host).

### 8.3 The four SLIs to graph and alert on

| Symptom | Envoy stat (prefix `cluster.outbound|<port>||<fqdn>.`) | What a rising value means |
|---|---|---|
| Breaker shedding load | `upstream_rq_pending_overflow`, `upstream_cx_overflow` | Pool too small **or** backend too slow — raise limits or scale backend |
| Hosts being ejected | `outlier_detection.ejections_active` / `..._enforced_total` | A pod (or the whole fleet) is failing |
| Availability floor hit | `outlier_detection.ejections_overflow` | `maxEjectionPercent` blocked ejections → *global* degradation |
| Retries amplifying load | `upstream_rq_retry`, `upstream_rq_retry_overflow` | Retry budget saturated — a storm is forming |

### 8.4 Common failure signatures and fixes

| You observe | Root cause | Fix |
|---|---|---|
| Latency P99 collapses to `timeout` value, `UT` everywhere | Overall `timeout` shorter than the legitimate P99 | Raise `timeout`, or fix the slow backend — don't just retry over it |
| `UO` under normal load | Connection pool sized for *idle*, not *peak* | Size `maxConnections`/`http2MaxRequests` to peak concurrency, not average |
| `503 UH`, no host healthy, whole service down after a bad deploy | Outlier detection ejected *every* pod because they *all* return 500 (bad release) | This is by-design protection; `maxEjectionPercent`/`minHealthPercent` panic mode kept *some* traffic flowing. Roll back the deploy |
| Backend never recovers after a blip | Aggressive `5xx` retries created a retry storm | Restrict `retryOn` to safe conditions; add `maxRetries` budget; add circuit breaker |
| Failover never triggers | `localityLbSetting` present but **no** `outlierDetection` | Add outlier detection — it is the health signal failover depends on |
| Two DestinationRules, config silently ignored | Conflicting DRs for the same host | `istioctl analyze` (warns `IST0110`); merge into one DR |

---

## 9. Trade-offs, defaults, and anti-patterns

| Decision | Cheap / aggressive | Expensive / conservative | Guidance |
|---|---|---|---|
| **Timeout length** | Short → fail fast, but false-positive `504`s under normal tail latency | Long → tolerant, but ties up threads during real hangs | Set to just above legitimate P99, not the mean |
| **Retry `attempts`** | High → hides more transient faults | High → multiplies load, risks storm | 2 is the sane default; pair with `maxRetries` budget + circuit breaker |
| **`retryOn` breadth** | `5xx` → maximum coverage | Narrow → safe for writes | Broad for idempotent reads, `connect-failure,refused-stream,reset` for writes |
| **`maxEjectionPercent`** | 100 → eject anything | Low → keep availability floor | 50 for stateless HTTP; lower for small pools |
| **Circuit breaker limits** | Tight → protects backend, sheds early | Loose → tolerates bursts, risks overwhelm | Size to measured peak concurrency; load-test to the `UO` cliff |

**Anti-patterns the exam and production both punish:**

1. **Retries without `perTryTimeout`** — each attempt inherits the (possibly infinite) overall timeout; a hung backend gets `attempts×` the load for `attempts×` the duration.
2. **Retrying non-idempotent writes on `5xx`** — silent duplicate side effects (double charges, double emails).
3. **Failover configured without outlier detection** — the failover map is inert; nothing triggers the spill.
4. **Circuit breaker sized to average load** — trips under normal peaks (`UO` false positives).
5. **Reading `istioctl proxy-config endpoint` to check ejection** — it shows EDS membership, not live outlier state; use `/clusters` `health_flags::/failed_outlier_check`.
6. **Two DestinationRules for one host** — Istio merges non-deterministically; one silently wins.

---

## Referencias

- Istio — *Traffic Management → Circuit Breaking* (task): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — *Traffic Management concepts (timeouts, retries, circuit breakers, fault injection)*: https://istio.io/latest/docs/concepts/traffic-management/
- Istio — *Setting request timeouts* (task): https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio API — `DestinationRule` (`ConnectionPoolSettings`, `OutlierDetection`, `LoadBalancerSettings.localityLbSetting`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio API — `VirtualService` (`HTTPRoute.timeout`, `HTTPRetry`): https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPRetry
- Istio — *Locality Load Balancing* (failover, distribute, failoverPriority): https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/
- Envoy — *Circuit breaking* architecture: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- Envoy — *Outlier detection* (ejection algorithm, panic threshold, stats): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- Envoy — *Automatic retries* (`retry_on` values, budgets): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter#config-http-filters-router-x-envoy-retry-on
- Envoy — *Access log response flags* (`%RESPONSE_FLAGS%`: UO, UH, UT, URX, UF, UC): https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#command-operators
- `istioctl proxy-config` reference (cluster / route / endpoint): https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf