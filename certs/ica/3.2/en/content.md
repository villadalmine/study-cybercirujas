# 3.2 — Configuring Routing within a Service Mesh

> **Exam domain:** Traffic Management · **Weight:** 5 · **Platform:** Istio (sidecar and ambient data planes; this topic is authored against the sidecar/Envoy model, which is what the ICA exam tests) · **API group under test:** `networking.istio.io/v1` (backward-compatible with `v1beta1`).

---

## 1. The production problem: why the mesh owns L7 routing

Kubernetes gives you exactly one routing primitive at the service layer: `kube-proxy` (iptables/IPVS) load-balances across the ready endpoints of a `Service` using round-robin (or random), at **L4**, with no awareness of HTTP semantics. That is sufficient to reach a workload; it is insufficient to *operate* one. The moment you need any of the following, `kube-proxy` cannot help you, and you are pushed either into application code or into a mesh:

- **Progressive delivery** — route 1% of traffic to `v2`, watch the golden signals, ramp to 100%. `kube-proxy` splits by *endpoint count*, so "1%" means "run 99 v1 pods and 1 v2 pod", coupling traffic weight to replica count.
- **Request-scoped routing** — send users whose `x-tier: premium` header is set to a canary; mirror production traffic to a shadow deployment for load testing without a user-visible response.
- **Resilience policy decoupled from code** — timeouts, retries with budgets, and per-endpoint circuit breaking, applied uniformly and changed without a redeploy.
- **Fault injection as a first-class control** — inject 5xx or latency to validate that upstream retry/timeout behavior actually holds under partial failure.

Istio moves all of this to the **data plane**: an Envoy sidecar (or ambient `ztunnel` + `waypoint`) intercepts every request and enforces the routing rules you declare. The control plane (`istiod`) compiles your CRDs into Envoy xDS configuration (LDS/RDS/CDS/EDS) and pushes it to every proxy. **The exam objective is the CRD layer**: how `VirtualService`, `DestinationRule`, `Gateway`, `ServiceEntry`, and `Sidecar` compose to express routing.

### The architectural split you must internalize

Istio deliberately separates **"where does this request go?"** from **"how do I talk to whatever it reached?"**. This is the single most-tested conceptual point in 3.2.

| Concern | Object | Envoy xDS mapping | Answers |
|---|---|---|---|
| **Routing** — match a request and pick a destination (host + subset + weight) | `VirtualService` | Route configuration (RDS), virtual hosts, route rules | "Which service/subset, with what weight, under what match, timeout, retry, fault?" |
| **Destination policy** — what happens *after* a destination is chosen | `DestinationRule` | Cluster (CDS): load balancer, subset definitions, connection pool, outlier detection, TLS | "How do I load-balance to it, what defines its subsets, when do I eject a bad endpoint?" |
| **Mesh entry** — expose a host at the edge | `Gateway` | Listener (LDS) on the gateway proxy | "What port/protocol/host does the ingress accept?" |
| **Mesh registry extension** — make an external host routable | `ServiceEntry` | Adds a cluster + endpoints to the registry | "Can the mesh route to `api.stripe.com`?" |
| **Proxy scope / egress** | `Sidecar` | Restricts imported LDS/CDS/RDS | "Which hosts does this workload's proxy even know about?" |

A `VirtualService` **routes**; it cannot define a subset. A `DestinationRule` **defines subsets and policy**; it cannot match a request. A canary needs *both*, and forgetting this is the most common self-inflicted 503.

---

## 2. VirtualService vs DestinationRule vs Gateway — the trade-off matrix

| Capability | VirtualService | DestinationRule | Gateway |
|---|---|---|---|
| Match on URI / header / method / query | ✅ | ❌ | ❌ (host/port/TLS only) |
| Weighted split (canary / blue-green) | ✅ (`route[].weight`) | ❌ | ❌ |
| Define subsets (`v1`, `v2`) | ❌ (only *references* them) | ✅ (`subsets[]` by label) | ❌ |
| Load-balancing algorithm | ❌ | ✅ (`trafficPolicy.loadBalancer`) | ❌ |
| Connection pool limits | ❌ | ✅ | ❌ |
| Outlier detection (circuit breaking) | ❌ | ✅ | ❌ |
| Timeouts / retries | ✅ | ❌ | ❌ |
| Fault injection (delay/abort) | ✅ | ❌ | ❌ |
| Traffic mirroring | ✅ | ❌ | ❌ |
| HTTP→HTTPS redirect / URI rewrite | ✅ | ❌ | ❌ (redirect via VS) |
| Bind to ingress listener | ✅ (`gateways:`) | ❌ | ✅ (defines the listener) |
| mTLS mode to upstream | ❌ | ✅ (`trafficPolicy.tls`) | ✅ (server TLS termination) |

**Rule of thumb for the exam:** if the verb is *match, split, retry, time out, inject, mirror, redirect, rewrite* → `VirtualService`. If the verb is *balance, pool, eject, define-subset, encrypt-upstream* → `DestinationRule`. If the verb is *accept at the edge* → `Gateway`.

### Route evaluation order — first match wins

Within a `VirtualService`, `http[]` rules are evaluated **top to bottom, first match wins**. There is no "most specific" scoring like Ingress path matching. This has a hard operational consequence:

> **Always place the most specific match (header/URI) *above* the catch-all default route.** If your default weighted split is first, the header-based canary rule below it is dead code.

Precedence across resources for the same host: Istio merges `VirtualService`es targeting the same host, but ordering across multiple VS objects is **not guaranteed** — production practice is **one VirtualService per host** to keep evaluation order deterministic.

---

## 3. Complete, production-grade manifests

The running example is a `reviews` service in namespace `bookinfo` with three versions (`v1`, `v2`, `v3`), fronted by an ingress gateway on `bookinfo.example.com`.

### 3.0 Prerequisite: the DestinationRule that names the subsets

Nothing below works until subsets exist. A subset is a **named label selector over the service's pods** — Envoy turns each into a distinct cluster.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local   # FQDN is safest; short name resolves relative to the DR's namespace
  trafficPolicy:                             # default policy for ALL subsets unless overridden
    loadBalancer:
      simple: LEAST_REQUEST                  # ROUND_ROBIN | LEAST_REQUEST | RANDOM | PASSTHROUGH
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 3s
      http:
        http1MaxPendingRequests: 64
        http2MaxRequests: 1000
        maxRequestsPerConnection: 0          # 0 = unlimited (no forced connection recycling)
        idleTimeout: 30s
    outlierDetection:                        # circuit breaking: eject unhealthy endpoints
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50                 # never eject more than half the pool at once
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
    trafficPolicy:                           # per-subset override: v2 gets a stricter LB
      loadBalancer:
        simple: ROUND_ROBIN
  - name: v3
    labels:
      version: v3
```

> **`host` resolution trap:** a bare `host: reviews` is resolved against the DestinationRule's *own* namespace and the proxy's default search domains. Under strict multi-tenant setups this silently points at the wrong service. Use the FQDN in production.

### 3.1 Default weighted routing — the canary primitive

Weights are proportional integers over the request stream, **completely independent of replica count**. They should sum to 100 by convention (Istio normalizes if they do not, but relying on that is bad hygiene).

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - name: canary-90-10
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 90
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v2
      weight: 10
```

### 3.2 Request-scoped routing — header, URI, method, and query matching

Match conditions are **ANDed within one `match` entry** and **ORed across entries in the `match[]` list**. Specific rules go first.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  # 1) Internal QA: header end-user=jason AND path prefix /api/v2 → v2
  - name: qa-header-route
    match:
    - headers:
        end-user:
          exact: jason
      uri:
        prefix: /api/v2
      method:
        exact: GET
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v2

  # 2) Beta cohort: query param ?beta=true OR header x-tier=premium → v3
  - name: beta-cohort
    match:
    - queryParams:
        beta:
          exact: "true"
    - headers:
        x-tier:
          exact: premium
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3

  # 3) Catch-all default MUST be last
  - name: default
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
```

Supported string match types on `uri`, `headers`, `queryParams`, `authority`, `scheme`, `method`: `exact`, `prefix`, `regex` (RE2 syntax). Header names are matched case-insensitively per HTTP semantics; header **values** are case-sensitive.

### 3.3 Timeouts, retries, and fault injection — resilience without code

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
  namespace: bookinfo
spec:
  hosts:
  - ratings.bookinfo.svc.cluster.local
  http:
  - name: resilient-default
    route:
    - destination:
        host: ratings.bookinfo.svc.cluster.local
        subset: v1
    timeout: 2s                       # end-to-end request timeout (includes retries)
    retries:
      attempts: 3                     # up to 3 retries → 4 total tries
      perTryTimeout: 500ms            # per-attempt cap; attempts*perTryTimeout can exceed `timeout`,
                                      # in which case `timeout` wins and truncates the budget
      retryOn: 5xx,reset,connect-failure,retriable-4xx
      retryRemoteLocalities: true     # allow retries to spill to another locality
    fault:                            # chaos engineering, declared
      delay:
        percentage:
          value: 10.0                 # 10% of requests
        fixedDelay: 3s
      abort:
        percentage:
          value: 5.0                  # 5% of requests
        httpStatus: 503
```

> **Retry semantics that trip people up:** the total `timeout` is the hard wall. With `attempts: 3` and `perTryTimeout: 500ms` but `timeout: 2s`, you get at most `2s / 500ms = 4` tries' worth of wall-clock — the `timeout` truncates the retry budget. Only **idempotent** conditions belong in `retryOn`; retrying non-idempotent POSTs on `retriable-4xx` will duplicate side effects.

### 3.4 Traffic mirroring (shadowing) — test with production traffic, discard the response

Mirrored requests are **fire-and-forget**: the sidecar sends a copy to the mirror destination, but the mirror's response is **discarded** and never affects the user. The `Host`/`Authority` header on the mirrored request is tagged with `-shadow` so the shadow workload can distinguish it.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - name: mirror-to-v2
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 100
    mirror:
      host: reviews.bookinfo.svc.cluster.local
      subset: v2
    mirrorPercentage:
      value: 100.0     # mirror 100% of live traffic to v2; v2 sees prod load, users only ever see v1
```

### 3.5 Redirect and rewrite

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: legacy-redirect
  namespace: bookinfo
spec:
  hosts:
  - bookinfo.example.com
  gateways:
  - bookinfo-gateway
  http:
  # Permanent redirect of an old path
  - match:
    - uri:
        prefix: /old-reviews
    redirect:
      uri: /reviews
      redirectCode: 301
  # Rewrite: external /api/reviews → internal /reviews on the reviews service
  - match:
    - uri:
        prefix: /api/reviews
    rewrite:
      uri: /reviews
    route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
```

### 3.6 Edge routing — Gateway + VirtualService bound to it

A `Gateway` defines the **listener** (port/protocol/host/TLS) on the ingress proxy. It does **no** routing by itself — you bind a `VirtualService` to it via `gateways:` and reference the gateway by `<namespace>/<name>` (or bare name if same namespace).

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  selector:
    istio: ingressgateway          # matches the istio-ingressgateway Deployment's pod labels
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "bookinfo.example.com"
    tls:
      mode: SIMPLE                 # terminate TLS at the gateway
      credentialName: bookinfo-tls # references a Kubernetes secret in the gateway's namespace
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "bookinfo.example.com"
    tls:
      httpsRedirect: true          # 301 all :80 traffic to :443
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  hosts:
  - "bookinfo.example.com"
  gateways:
  - bookinfo-gateway              # bind to the edge listener above
  - mesh                          # ALSO apply to in-mesh sidecar traffic (reserved keyword)
  http:
  - match:
    - uri:
        prefix: /productpage
    route:
    - destination:
        host: productpage.bookinfo.svc.cluster.local
        port:
          number: 9080
```

> **The `mesh` reserved gateway:** omitting `gateways:` defaults to `["mesh"]` — the rule applies only to sidecar-to-sidecar traffic. If you list a gateway name, you **must** also add `mesh` explicitly to keep east-west routing. Forgetting this is why "my canary works from outside but not service-to-service."

### 3.7 ServiceEntry — making an external host routable (and splittable)

External hosts are not in the mesh registry, so you cannot write a `VirtualService` for them until a `ServiceEntry` adds them. This lets you apply timeouts/retries/splits to third-party APIs.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-payments
  namespace: bookinfo
spec:
  hosts:
  - api.payments.example.com
  location: MESH_EXTERNAL
  resolution: DNS
  ports:
  - number: 443
    name: https
    protocol: TLS
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: external-payments-timeout
  namespace: bookinfo
spec:
  hosts:
  - api.payments.example.com
  http: []                          # (for TLS/TCP passthrough use tls:/tcp:; shown here for shape)
  tls:
  - match:
    - port: 443
      sniHosts:
      - api.payments.example.com
    route:
    - destination:
        host: api.payments.example.com
```

### 3.8 Sidecar — scoping what a proxy knows (routing performance + blast radius)

By default every sidecar receives config for **every** service in the mesh. At scale this bloats Envoy memory and slows pushes. A `Sidecar` resource restricts the import set — and doubles as an egress control.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: bookinfo
spec:
  egress:
  - hosts:
    - "./*"                          # this namespace
    - "istio-system/*"               # the control-plane namespace
    - "bookinfo/*"
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY              # block egress to anything not in the registry (deny-by-default)
```

---

## 4. CLI and terminal I/O

Apply and inspect the objects. Outputs below are representative of Istio 1.2x.

```console
$ kubectl apply -f reviews-destinationrule.yaml -f reviews-virtualservice.yaml
destinationrule.networking.istio.io/reviews created
virtualservice.networking.istio.io/reviews created

$ kubectl get virtualservice,destinationrule -n bookinfo
NAME                                          GATEWAYS               HOSTS                                    AGE
virtualservice.networking.istio.io/reviews                          ["reviews.bookinfo.svc.cluster.local"]   12s
virtualservice.networking.istio.io/bookinfo   ["bookinfo-gateway"]   ["bookinfo.example.com"]                 12s

NAME                                          HOST                                     AGE
destinationrule.networking.istio.io/reviews   reviews.bookinfo.svc.cluster.local       12s
```

**Analyze before you trust it** — `istioctl analyze` catches the most common routing bug (a VirtualService referencing a subset no DestinationRule defines):

```console
$ istioctl analyze -n bookinfo
✔ No validation issues found when analyzing namespace: bookinfo.
```

A deliberately broken case — VirtualService points at `subset: v4`, which no DestinationRule defines:

```console
$ istioctl analyze -n bookinfo
Error [IST0101] (VirtualService reviews.bookinfo) Referenced host+subset in destinationrule not found: "reviews.bookinfo.svc.cluster.local+v4"
Error: Analyzers found issues when analyzing namespace: bookinfo.
See https://istio.io/v1.24/docs/reference/config/analysis for more information about causes and resolutions.
```

**Confirm the split empirically** — hammer the endpoint and count the version each request hit:

```console
$ for i in $(seq 1 100); do
    kubectl exec deploy/productpage -n bookinfo -c productpage -- \
      curl -s reviews:9080/reviews/0 | grep -o '"podname": "reviews-v[0-9]'
  done | sort | uniq -c
     91 "podname": "reviews-v1
      9 "podname": "reviews-v2
```

91/9 across 100 samples is exactly the 90/10 weighting within sampling noise — proof the weights, not the replica counts, drove the split.

**Verify the compiled Envoy config** — routes, clusters, and their endpoints:

```console
$ istioctl proxy-config routes deploy/productpage -n bookinfo --name 9080 -o json | \
    jq '.[].virtualHosts[].routes[].route.weightedClusters // empty'
{
  "clusters": [
    { "name": "outbound|9080|v1|reviews.bookinfo.svc.cluster.local", "weight": 90 },
    { "name": "outbound|9080|v2|reviews.bookinfo.svc.cluster.local", "weight": 10 }
  ],
  "totalWeight": 100
}

$ istioctl proxy-config cluster deploy/productpage -n bookinfo --fqdn reviews.bookinfo.svc.cluster.local
SERVICE FQDN                            PORT  SUBSET  DIRECTION   TYPE     DESTINATION RULE
reviews.bookinfo.svc.cluster.local      9080  -       outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v1      outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v2      outbound    EDS      reviews.bookinfo
reviews.bookinfo.svc.cluster.local      9080  v3      outbound    EDS      reviews.bookinfo

$ istioctl proxy-config endpoints deploy/productpage -n bookinfo --cluster \
    "outbound|9080|v2|reviews.bookinfo.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.2.15:9080     HEALTHY     OK                outbound|9080|v2|reviews.bookinfo.svc.cluster.local
```

---

## 5. Verification and failure diagnosis

### The diagnostic ladder — climb it in order

1. **Do the CRDs validate against each other?** → `istioctl analyze -n <ns>`. Catches missing subsets (IST0101), conflicting VSes, and host typos for free, before any traffic.
2. **Did the config actually reach the proxy?** → `istioctl proxy-status` (a.k.a. `ps`). Every proxy must show `SYNCED` for CDS/LDS/EDS/RDS. `STALE` means `istiod` pushed but the proxy hasn't ACKed; `NOT SENT` means the config never got compiled for that proxy.
3. **Is the route present in Envoy?** → `istioctl proxy-config routes <pod> --name <port>`. If your route isn't here, the VS isn't binding — usually a `hosts:` FQDN mismatch or a missing `mesh` gateway.
4. **Does the cluster exist and have endpoints?** → `istioctl proxy-config cluster` then `... endpoints`. **No endpoints = 503 UH (no healthy upstream).** Almost always a subset label that matches zero pods.
5. **What did Envoy actually decide, per request?** → the sidecar access log, with `response_flags`.

```console
$ istioctl proxy-status
NAME                                     CLUSTER      CDS        LDS        EDS        RDS        ISTIOD          VERSION
productpage-xxxx.bookinfo                Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED     istiod-abc123   1.24.0
reviews-v2-yyyy.bookinfo                 Kubernetes   SYNCED     SYNCED     SYNCED     STALE      istiod-abc123   1.24.0
```

### The one debugging tool that resolves most tickets: Envoy `response_flags`

Read the sidecar access log and decode the flag column. This single field tells you *which layer* dropped the request.

```console
$ kubectl logs deploy/productpage -n bookinfo -c istio-proxy --tail=3
[2026-08-08T14:22:31.005Z] "GET /reviews/0 HTTP/1.1" 503 UH ... "outbound|9080|v4|reviews.bookinfo.svc.cluster.local" -
[2026-08-08T14:22:33.410Z] "GET /reviews/0 HTTP/1.1" 200 -  ... "outbound|9080|v1|reviews.bookinfo.svc.cluster.local" 10.244.1.9:9080
[2026-08-08T14:22:35.887Z] "GET /reviews/0 HTTP/1.1" 504 UT ... "outbound|9080|v1|reviews.bookinfo.svc.cluster.local" 10.244.1.9:9080
```

| Flag | Meaning | Most likely routing cause |
|---|---|---|
| `UH` | No healthy upstream | Subset matches **zero** pods (bad `labels`), or all endpoints ejected by outlier detection |
| `UF` | Upstream connection failure | `connectTimeout` exceeded, or mTLS mode mismatch (PERMISSIVE vs STRICT vs DISABLE) |
| `UT` | Upstream request timeout | Your `timeout`/`perTryTimeout` fired — the upstream was too slow |
| `NR` | No route configured | VS `hosts`/`match` didn't match; request fell through with no default route |
| `URX` | Retry/redirect limit exceeded | Retries exhausted per `retries.attempts` |
| `DI` | Delay injected | Your `fault.delay` fired (expected during chaos tests) |
| `FI` | Fault (abort) injected | Your `fault.abort` fired |

### The classic canary failures and their fixes

| Symptom | Root cause | Fix |
|---|---|---|
| `503 UH` on the canary version only | `VirtualService` references `subset: vX` but `DestinationRule` has no such subset, or its `labels` match no pods | Run `istioctl analyze`; confirm `kubectl get pods -l version=vX` returns pods; add/repair the subset |
| Split works externally, not service-to-service | VS lists a gateway name but dropped the implicit `mesh` gateway | Add `- mesh` to `spec.gateways` |
| Header route never fires | Catch-all default route placed **above** the specific match | Reorder: specific `match` rules first, default last |
| Weights ignored, traffic tracks replica count | No `DestinationRule` / subsets at all, so Envoy falls back to the plain service cluster (L4 round-robin) | Create the DestinationRule with subsets |
| Retries duplicate a payment | `retryOn` includes retriable conditions on a non-idempotent POST | Scope retries to idempotent routes only |
| Intermittent `503 UF` after enabling STRICT mTLS | `DestinationRule.trafficPolicy.tls.mode` not `ISTIO_MUTUAL` while `PeerAuthentication` is STRICT | Set upstream `tls.mode: ISTIO_MUTUAL` or align the PeerAuthentication mode |

---

## 6. Referencias

- Istio — Traffic Management (concepts): https://istio.io/latest/docs/concepts/traffic-management/
- Istio — VirtualService API reference: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — DestinationRule API reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Gateway API reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — ServiceEntry API reference: https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio — Sidecar API reference: https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio task — Request routing: https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio task — Traffic shifting (weighted): https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio task — Traffic mirroring: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio task — Fault injection: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio task — Setting request timeouts: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio task — Circuit breaking (outlier detection): https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — Configuration analysis messages (IST0101 etc.): https://istio.io/latest/docs/reference/config/analysis/
- Istio — Debugging Envoy and istiod (proxy-config / proxy-status): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Envoy — Response flags reference: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf