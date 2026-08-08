# 3.3 Defining Traffic Policies with Destination Rules

> **Exam domain 3 — Traffic Management. Topic weight: 5.**
> This is the object that turns Istio from "smart DNS with retries" into a genuine L7 resilience layer. A `VirtualService` decides *where* a request goes; a `DestinationRule` decides *how the connection to that place behaves*: load-balancing algorithm, connection-pool limits, passive health-checking (circuit breaking), session affinity, and client-side TLS/mTLS. Understanding the split between the two objects — and the Envoy machinery each one programs — is the core of this topic.

---

## 1. The architectural problem

Consider a `reviews` service with three deployments (`v1`, `v2`, `v3`) behind one Kubernetes `Service`. Kubernetes gives you exactly one lever: `kube-proxy` iptables/IPVS load-balancing across all Ready endpoints, round-robin, connection-level, no L7 awareness. That model breaks in production in four specific ways:

1. **No sub-service targeting.** All three versions share the ClusterIP. You cannot send 1 % of traffic to `v3` for a canary, because `kube-proxy` cannot distinguish `v3` pods from `v1` pods — they are all endpoints of the same Service. Routing needs *named subsets*.
2. **No load shedding under partial failure.** If one `reviews-v1` pod's heap is thrashing and every request takes 30 s, `kube-proxy` keeps sending it its share. Latency propagates upstream: `productpage` threads block on the slow pod, the thread pool exhausts, and a single sick replica takes down the whole page. This is the classic *cascading failure* / *thundering herd*. You need **passive health checking** that ejects the bad endpoint automatically.
3. **No back-pressure.** A traffic spike opens unbounded connections and queues unbounded pending requests against a downstream that can only handle N concurrent. Without a **connection pool** ceiling, the downstream falls over instead of shedding the excess with a fast `503`.
4. **No client-side transport control.** You cannot force mTLS on a per-destination basis, originate TLS toward an external HTTPS API, or pin session affinity to a specific replica for a stateful cache.

A `DestinationRule` addresses all four. It is applied **after** the routing decision, at the point where the client sidecar (Envoy) is about to open a connection to a concrete upstream cluster. Everything it configures maps onto an **Envoy Cluster**: `lb_policy`, `circuit_breakers`, `outlier_detection`, and the `transport_socket` (TLS).

---

## 2. Where the DestinationRule sits: the two-object model

Istio deliberately separates *routing* from *post-routing policy*. This is the single most tested conceptual point in domain 3.

| Concern | `VirtualService` | `DestinationRule` |
|---|---|---|
| Question answered | *Which* host/subset gets this request? | *How* do I talk to that host/subset? |
| Envoy object programmed | `RouteConfiguration` / `route` (RDS) | `Cluster` (CDS) |
| Matches on | headers, path, weight, port, sourceLabels | nothing — it applies to *all* traffic to `host` |
| Defines | HTTP match/rewrite/redirect, **traffic split weights**, retries, timeouts, fault injection, mirroring | **subsets**, loadBalancer, connectionPool, outlierDetection, tls |
| Owns the subset **name** | *references* it (`destination.subset`) | *defines* it (`subsets[].name` + `labels`) |
| Applies before or after routing | performs routing | applies after routing, per upstream cluster |

**Critical dependency:** a subset referenced in a `VirtualService` route (`destination.subset: v3`) must be **defined** in a `DestinationRule` for the same `host`. If it isn't, Envoy has no such cluster and every request to it returns `503 NR`/no cluster. `istioctl analyze` flags this before it ships.

### How one DestinationRule expands into Envoy clusters

For a host `reviews.default.svc.cluster.local:9080` with subsets `v1/v2/v3`, Pilot emits **four** Envoy clusters — the base cluster plus one per subset:

```
outbound|9080||reviews.default.svc.cluster.local     # base (no subset)
outbound|9080|v1|reviews.default.svc.cluster.local   # subset v1 → its own CB/LB/outlier config
outbound|9080|v2|reviews.default.svc.cluster.local
outbound|9080|v3|reviews.default.svc.cluster.local
```

Each subset cluster carries its **own** circuit breakers and outlier detection. This is why circuit breaking is per-subset, not per-service: ejecting a bad `v3` endpoint never touches `v1`'s pool.

---

## 3. Subsets: label-based sub-service definition

Subsets are the vocabulary the `VirtualService` uses to talk about versions. They are pure label selectors evaluated against pod labels (usually the `version` label, but any label works).

```yaml
apiVersion: networking.istio.io/v1beta1   # v1 is GA since Istio 1.22; v1beta1 is the widely-compatible form
kind: DestinationRule
metadata:
  name: reviews
  namespace: default
spec:
  host: reviews.default.svc.cluster.local   # prefer the FQDN; short names resolve against this DR's namespace
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

The matching `VirtualService` then routes by subset name:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
  namespace: default
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1        # <-- must exist in the DestinationRule above
      weight: 90
    - destination:
        host: reviews
        subset: v3
      weight: 10
```

**Subset trafficPolicy inheritance.** A subset inherits the host-level `trafficPolicy` and can override it field-by-field:

```yaml
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:                       # host-level default for all subsets
    connectionPool:
      tcp: { maxConnections: 100 }
    loadBalancer:
      simple: LEAST_REQUEST
  subsets:
  - name: v3
    labels: { version: v3 }
    trafficPolicy:                     # v3 overrides ONLY loadBalancer; inherits the connectionPool
      loadBalancer:
        consistentHash:
          httpCookie: { name: user, ttl: 0s }
```

**Gotcha — `host` scoping and `exportTo`.** A short `host: reviews` in a DR in namespace `default` resolves to `reviews.default`. If your DR lives in a shared namespace and the service lives elsewhere, always write the FQDN. Use `exportTo: ["."]` to keep a DR private to its own namespace, or `["*"]` (default) to make it mesh-wide. Two DRs exporting to the same host from different namespaces is a real source of silent conflicts — `istioctl analyze` reports `DestinationRuleConflict` (only the oldest wins).

---

## 4. Load balancing

`trafficPolicy.loadBalancer` selects the Envoy `lb_policy` for the cluster.

| Algorithm (`simple:`) | Envoy policy | Behaviour | Use when | Cost / trap |
|---|---|---|---|---|
| `ROUND_ROBIN` | `ROUND_ROBIN` | Strict rotation across healthy endpoints | Uniform, stateless, homogeneous replicas | Ignores in-flight load; a slow pod still gets its turn |
| `LEAST_REQUEST` | `LEAST_REQUEST` (P2C) | Picks the endpoint with fewest active requests, using power-of-two-choices | Heterogeneous latency, mixed pod sizes — **the modern default** | Slightly more state; needs accurate active-request counts |
| `RANDOM` | `RANDOM` | Uniform random pick | High endpoint count, no locality needs | No load awareness |
| `PASSTHROUGH` | `CLUSTER_PROVIDED` | Forward to the original destination IP; no LB | Headless services, client already chose the IP | Bypasses subset/endpoint LB entirely |
| `consistentHash` | `RING_HASH` / `MAGLEV` | Deterministic hash → same key lands on same endpoint | **Session affinity**, sticky caches, sharded state | Rebalances on endpoint churn; hot keys create hot pods |

> **Version note:** Istio's default load-balancing algorithm changed from `ROUND_ROBIN` to `LEAST_REQUEST` in **Istio 1.21**. On older control planes the default is `ROUND_ROBIN`. Never rely on the implicit default in production — declare it.

### Consistent-hash session affinity

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: cart
  namespace: shop
spec:
  host: cart.shop.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:               # sticky by cookie; Istio injects it if absent
          name: SESSION
          ttl: 3600s
        minimumRingSize: 1024     # ringHash granularity; larger = smoother distribution, more memory
```

Hash-key options (choose exactly one): `httpHeaderName`, `httpCookie`, `httpQueryParameterName`, `useSourceIp: true`, or `maglev`/`ringHash` tuning. `useSourceIp` is common for gRPC where cookies don't exist; but behind a load balancer that SNATs, every request appears to come from one IP and affinity collapses to a single pod — verify `x-forwarded-for` handling first.

### Locality-aware load balancing

For multi-zone clusters, weight traffic toward same-zone endpoints and fail over across zones:

```yaml
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
        failover:                 # if local zone is unhealthy, spill to the named region
        - from: us-east-1
          to: us-east-2
    outlierDetection:             # REQUIRED — locality failover only triggers when outlier detection ejects the local zone
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

**Trap:** `localityLbSetting` failover is a no-op unless `outlierDetection` is configured. Envoy only shifts to the failover locality once local endpoints are marked unhealthy, and only outlier detection (or active health checks, which Istio doesn't expose here) marks them so.

---

## 5. Connection pool — *active* circuit breaking

`connectionPool` sets hard ceilings. When traffic exceeds them, Envoy fails fast with `503 UO` (**U**pstream **O**verflow) instead of queuing or opening unbounded sockets. This is the *active* half of circuit breaking — it acts on volume, before any errors occur.

| Field | Layer | Meaning | Envoy default | Istio default |
|---|---|---|---|---|
| `tcp.maxConnections` | L4 | Max concurrent TCP conns to the upstream cluster | 1024 | effectively unbounded (2³²-1) |
| `tcp.connectTimeout` | L4 | TCP connect timeout | 10s | 10s |
| `tcp.tcpKeepalive.{time,interval,probes}` | L4 | SO_KEEPALIVE tuning | off | off |
| `http.http1MaxPendingRequests` | L7 | Max queued requests waiting for a connection (HTTP/1.1) | 1024 | effectively unbounded |
| `http.http2MaxRequests` | L7 | Max concurrent requests across all connections | 1024 | effectively unbounded |
| `http.maxRequestsPerConnection` | L7 | Requests before a connection is recycled (`1` = disable keep-alive) | 0 (unlimited) | 0 |
| `http.maxRetries` | L7 | Max concurrent retries (cluster-wide budget) | 3 | effectively unbounded |
| `http.idleTimeout` | L7 | Idle time before closing an upstream connection | 1h | 1h |
| `http.h2UpgradePolicy` | L7 | Auto-upgrade HTTP/1.1 → HTTP/2 | DEFAULT | DEFAULT |

> **The most important non-obvious fact in this topic:** Istio does **not** inherit Envoy's small `1024`/`3` defaults. Unless you configure `connectionPool`, the limits are effectively *unbounded* and outlier detection is *off*. A cluster with no DestinationRule has **no circuit breaking at all**. "It's Istio, so it's protected" is false.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ratings-cb
  namespace: default
spec:
  host: ratings.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100        # cap L4 fan-out
        connectTimeout: 250ms
        tcpKeepalive:
          time: 7200s
          interval: 75s
          probes: 9
      http:
        http1MaxPendingRequests: 10   # tiny pending queue → shed the spike fast
        http2MaxRequests: 100
        maxRequestsPerConnection: 10  # recycle connections, avoids stale LB state
        maxRetries: 3
        idleTimeout: 30s
```

When `http1MaxPendingRequests: 10` is breached, callers see `503` with response flag `UO` and Envoy increments `upstream_rq_pending_overflow`. That's the pool doing its job — fast rejection is the feature, not a bug.

---

## 6. Outlier detection — *passive* circuit breaking

`outlierDetection` ejects individual endpoints that misbehave. It is *passive*: it observes real request outcomes (5xx, connection failures) and removes the offending host from the LB pool for a cooling-off period. This is what stops one sick pod from poisoning the service.

| Field | Meaning | Istio default |
|---|---|---|
| `consecutive5xxErrors` | Eject after N consecutive `5xx` (includes locally-generated 503s unless split) | 5 (when block present) |
| `consecutiveGatewayErrors` | Eject after N consecutive `502/503/504` only | — |
| `consecutiveLocalOriginFailures` | Eject after N connect failures/resets (needs `splitExternalLocalOriginErrors: true`) | — |
| `interval` | How often the ejection sweep runs | 10s |
| `baseEjectionTime` | Minimum ejection duration; multiplied by ejection count (back-off) | 30s |
| `maxEjectionPercent` | Ceiling on the % of endpoints that may be ejected at once | 10% |
| `minHealthPercent` | Below this healthy %, outlier detection is disabled to avoid ejecting the last survivors | 0 (off) |
| `splitExternalLocalOriginErrors` | Separate connection-level failures (local) from upstream 5xx (external) | false |

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews-resilient
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 50        # allow up to half the pool to be ejected
      minHealthPercent: 20          # ...but stop ejecting once <20% remain healthy
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
  subsets:
  - name: v1
    labels: { version: v1 }
  - name: v2
    labels: { version: v2 }
  - name: v3
    labels: { version: v3 }
```

### The panic-threshold trap

Envoy has a separate `healthy_panic_threshold`, **default 50 %**. If outlier detection ejects so many endpoints that fewer than 50 % remain healthy, Envoy enters *panic mode* and **load-balances across ALL endpoints, including the ejected ones** — on the theory that "everything is broken, so ejecting is pointless." The visible symptom is: you configured circuit breaking, a majority of pods go bad, and traffic *still* flows to bad pods. Two levers interact:

- `maxEjectionPercent` caps how many you *can* eject (default only 10 % — often too low; you eject one pod and stop).
- Panic mode overrides ejection when the *healthy* fraction is too low.

For a 3-replica service, `maxEjectionPercent: 10` means you can never eject even one pod (10 % of 3 rounds to 0). Set it explicitly. Match it against your replica count.

---

## 7. TLS and mTLS — the client side of the connection

`trafficPolicy.tls` controls what the **client** sidecar does when originating the connection. This is the counterpart to `PeerAuthentication`, which controls what the **server** sidecar accepts. Getting the interaction wrong is the number-one cause of `503 UF` in a freshly-secured mesh.

| `tls.mode` | What the client sidecar does | Certificates |
|---|---|---|
| `DISABLE` | Plaintext | none |
| `SIMPLE` | Originate one-way TLS (validate server, no client cert) — **TLS origination** to external HTTPS | optional `caCertificates` / `credentialName` |
| `MUTUAL` | Mutual TLS with **operator-supplied** certs | `clientCertificate` + `privateKey` + `caCertificates` |
| `ISTIO_MUTUAL` | Mutual TLS using Istio's **auto-provisioned** workload certs (SPIFFE) | managed by Istio |

### Interaction with auto-mTLS and PeerAuthentication

Since Istio 1.5, **auto-mTLS** configures client sidecars to use `ISTIO_MUTUAL` automatically whenever the destination has a sidecar — you don't need a DR for mTLS to work. The subtlety:

- A DestinationRule disables auto-mTLS **only when it explicitly sets `tls.mode`**. A DR that sets `loadBalancer`/`connectionPool` but no `tls` block leaves auto-mTLS intact.
- `tls.mode: DISABLE` against a server whose `PeerAuthentication` is `STRICT` → the server rejects plaintext → **connection reset → `503 UF`**. This is the classic self-inflicted outage: someone adds a DR for load-balancing, copies a `tls: DISABLE` snippet from a blog, and silently drops mesh mTLS on that route.

| Server `PeerAuthentication` | Client DR `tls.mode` | Result |
|---|---|---|
| STRICT | (none / auto-mTLS) | ✅ mTLS |
| STRICT | ISTIO_MUTUAL | ✅ mTLS (explicit) |
| STRICT | DISABLE | ❌ `503 UF` — server refuses plaintext |
| PERMISSIVE | DISABLE | ✅ plaintext (server accepts both) |
| DISABLE | ISTIO_MUTUAL | ❌ handshake fails — server speaks plaintext only |

### TLS origination to an external service

Let the sidecar terminate/originate TLS so the app speaks plain HTTP internally while the wire is HTTPS:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-payments
  namespace: default
spec:
  hosts:
  - api.payments.example.com
  ports:
  - number: 443
    name: https
    protocol: TLS
  - number: 80
    name: http
    protocol: HTTP           # app calls port 80 in plaintext
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: external-payments-tls
  namespace: default
spec:
  host: api.payments.example.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80
      tls:
        mode: SIMPLE          # sidecar upgrades the plaintext :80 call to real TLS :443 upstream
        sni: api.payments.example.com
```

### Port-level overrides

`portLevelSettings` lets one service expose, say, a plaintext metrics port and an mTLS data port under one DestinationRule:

```yaml
  trafficPolicy:
    tls: { mode: ISTIO_MUTUAL }        # default for all ports
    portLevelSettings:
    - port: { number: 9090 }           # metrics port opts out
      tls: { mode: DISABLE }
```

---

## 8. Full production manifest — everything composed

A single, syntactically-complete `DestinationRule` combining subsets, LB, active + passive circuit breaking, mTLS, and a per-subset override:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews-prod
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  exportTo:
  - "."                                     # keep this DR private to the default namespace
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL                     # mesh mTLS, explicit
    loadBalancer:
      simple: LEAST_REQUEST
      localityLbSetting:
        enabled: true
    connectionPool:
      tcp:
        maxConnections: 200
        connectTimeout: 250ms
        tcpKeepalive:
          time: 7200s
          interval: 75s
      http:
        http1MaxPendingRequests: 32
        http2MaxRequests: 200
        maxRequestsPerConnection: 100
        maxRetries: 3
        idleTimeout: 30s
        h2UpgradePolicy: UPGRADE
    outlierDetection:
      consecutive5xxErrors: 5
      consecutiveGatewayErrors: 5
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
      minHealthPercent: 20
      splitExternalLocalOriginErrors: true
      consecutiveLocalOriginFailures: 3
  subsets:
  - name: v1
    labels: { version: v1 }
  - name: v2
    labels: { version: v2 }
  - name: v3
    labels: { version: v3 }
    trafficPolicy:                           # v3 is a sticky, cookie-affine canary
      loadBalancer:
        consistentHash:
          httpCookie:
            name: reviews-session
            ttl: 0s
      connectionPool:
        http:
          http1MaxPendingRequests: 8         # tighter pool for the unproven version
```

Apply and confirm acceptance:

```console
$ kubectl apply -f reviews-prod.yaml
destinationrule.networking.istio.io/reviews-prod created

$ istioctl analyze -n default
✔ No validation issues found when analyzing namespace: default.
```

---

## 9. Verification and failure diagnosis

Configuration that `kubectl apply`s cleanly can still be wrong. The proof is in the Envoy config that Pilot actually pushed, not the YAML.

### Step 1 — Confirm the clusters and their policy exist

```console
$ istioctl proxy-config cluster deploy/productpage-v1 -n default \
    --fqdn reviews.default.svc.cluster.local
SERVICE FQDN                          PORT  SUBSET  DIRECTION   TYPE  DESTINATION RULE
reviews.default.svc.cluster.local     9080  -       outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v1      outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v2      outbound    EDS   reviews-prod.default
reviews.default.svc.cluster.local     9080  v3      outbound    EDS   reviews-prod.default
```

An empty `DESTINATION RULE` column, or missing subset rows, means the DR isn't binding (wrong `host`, wrong namespace, or `exportTo` scoping). Inspect the effective circuit-breaker and LB config:

```console
$ istioctl proxy-config cluster deploy/productpage-v1 -n default \
    --fqdn reviews.default.svc.cluster.local --subset v3 -o json \
  | jq '{lb: .lbPolicy, cb: .circuitBreakers.thresholds[0], od: .outlierDetection}'
{
  "lb": "RING_HASH",
  "cb": {
    "maxConnections": 200,
    "maxPendingRequests": 8,
    "maxRequests": 200,
    "maxRetries": 3
  },
  "od": {
    "consecutive5xx": 5,
    "interval": "5s",
    "baseEjectionTime": "30s",
    "maxEjectionPercent": 50
  }
}
```

This proves the subset override took effect (`RING_HASH` and `maxPendingRequests: 8`, not the host-level `LEAST_REQUEST`/`32`).

### Step 2 — Watch outlier detection eject an endpoint

```console
$ istioctl proxy-config endpoint deploy/productpage-v1 -n default \
    --cluster "outbound|9080|v1|reviews.default.svc.cluster.local"
ENDPOINT             STATUS       OUTLIER CHECK   CLUSTER
10.244.1.21:9080     HEALTHY      OK              outbound|9080|v1|reviews.default.svc.cluster.local
10.244.2.34:9080     UNHEALTHY    FAILED          outbound|9080|v1|reviews.default.svc.cluster.local
```

`OUTLIER CHECK: FAILED` = ejected. Confirm with the Envoy admin `/clusters` health flag and the enforcement counter:

```console
$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    curl -s localhost:15000/clusters | grep 'v1|reviews' | grep health_flags
outbound|9080|v1|reviews.default.svc.cluster.local::10.244.2.34:9080::health_flags::/failed_outlier_check

$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=v1.reviews.*outlier'
cluster.outbound|9080|v1|reviews.default.svc.cluster.local.outlier_detection.ejections_active: 1
cluster.outbound|9080|v1|reviews.default.svc.cluster.local.outlier_detection.ejections_enforced_total: 4
```

### Step 3 — Confirm the connection pool is shedding

```console
$ kubectl exec deploy/productpage-v1 -n default -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=v3.reviews.*(overflow|pending)'
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_rq_pending_overflow: 57
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_cx_overflow: 12
cluster.outbound|9080|v3|reviews.default.svc.cluster.local.upstream_rq_pending_active: 8
```

`upstream_rq_pending_overflow: 57` = 57 requests fast-rejected with `503 UO`. That is the circuit breaker working as designed.

### Failure-mode reference

| Symptom | `response_flags` | Likely cause | Fix |
|---|---|---|---|
| `503 no healthy upstream` | `UH` | All endpoints ejected, or subset labels match zero pods | Check `proxy-config endpoint`; verify `version` label on pods |
| `503 upstream connect error … reset before headers` | `UF` | mTLS mismatch — DR `DISABLE` vs `PeerAuthentication STRICT` | Remove `tls: DISABLE` or set `ISTIO_MUTUAL` |
| `503` under load, `upstream_rq_pending_overflow` rising | `UO` | Connection pool ceiling hit (working as intended, or set too low) | Raise `http1MaxPendingRequests` / `maxConnections` |
| `503 NR` / no cluster | `NR` | VirtualService references a subset not defined in any DR | Add the subset; run `istioctl analyze` |
| Traffic still hitting a known-bad pod | — | Panic mode (<50 % healthy) or `maxEjectionPercent` too low (default 10 %) | Raise `maxEjectionPercent`; check replica count vs threshold |
| Two DRs, one silently ignored | — | `DestinationRuleConflict` — same host from two namespaces | Consolidate; oldest DR wins |
| Session affinity not sticking | — | `useSourceIp` behind a SNAT LB, or client dropped the cookie | Switch to `httpCookie`/`httpHeaderName`; check `x-forwarded-for` |

Always finish with the static analyzer, which catches subset/host/conflict errors that Envoy would only surface at request time:

```console
$ istioctl analyze -A
Error [IST0101] (VirtualService reviews.default) Referenced host+subset in "destination"
  not found: "reviews+v4"
Warning [IST0134] (DestinationRule reviews-prod.default) maxEjectionPercent (10) with 3
  replicas ejects 0 hosts; outlier detection is effectively disabled.
```

---

## 10. Referencias

- Istio — *Destination Rule* (API reference): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — *Traffic Management* concepts (VirtualService vs DestinationRule): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — *Circuit Breaking* task (connectionPool + outlierDetection): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — *Locality Load Balancing*: https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/
- Istio — *Mutual TLS Migration* and auto-mTLS: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Egress TLS Origination*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio — *Debugging Envoy and Istiod* (`istioctl proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio 1.21 release notes — default load-balancer change to `LEAST_REQUEST`: https://istio.io/latest/news/releases/1.21.x/announcing-1.21/change-notes/
- Envoy — *Outlier detection* (panic threshold, ejection semantics): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- Envoy — *Circuit breaking* (thresholds, `UO` overflow): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking
- CNCF — *ICA Curriculum* (Traffic Management domain): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf