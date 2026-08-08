# ICA 2.3 — Troubleshooting the Mesh Data Plane

> **Exam domain weight: 6.** This topic sits at the intersection of every other domain: a misconfigured `VirtualService`, a `PeerAuthentication` in the wrong mode, a subset that no endpoint matches, or a control-plane push that never lands — they all surface as a data-plane symptom (a `503`, a hanging request, a proxy that never turns `Ready`). Mastering the data plane means being able to walk from *symptom* → *which Envoy config object is wrong* → *why istiod produced it* without guessing.

---

## 1. Motivation and the production architectural problem

Istio's data plane is a fleet of **Envoy sidecars** (`istio-proxy` containers) injected next to every workload, plus the gateway Envoys at the edge. The control plane (`istiod`) never touches a single request; it only *configures* those Envoys through the **xDS** gRPC protocol. This split is the whole point of a service mesh — and it is also the entire troubleshooting problem:

**The config you write is not the config that runs.** You author intent as Kubernetes CRDs (`VirtualService`, `DestinationRule`, `PeerAuthentication`, `Sidecar`, `Gateway`). `istiod` watches those, the service registry (Kubernetes `Endpoints`/`EndpointSlice`), and the certificate authority, then *translates* all of it into concrete Envoy primitives — **listeners, routes, clusters, endpoints, secrets** — and streams them to each proxy. A production incident is almost always a mismatch between one of these layers:

```
 Author intent        Control plane           Data plane                Reality
 ┌───────────┐   watch  ┌─────────┐   xDS/gRPC  ┌────────────┐  request  ┌──────────┐
 │ CRDs +    │────────▶ │ istiod  │───────────▶ │ Envoy       │◀────────▶ │ upstream │
 │ K8s Svc   │          │ (Pilot) │  :15012     │ LDS/RDS/    │  :15001   │ pods     │
 │ Endpoints │          │         │             │ CDS/EDS/SDS │  :15006   │          │
 └───────────┘          └─────────┘             └────────────┘           └──────────┘
   Layer 1                Layer 2                  Layer 3                  Layer 4
```

A failure can live at any layer:

| Layer | It looks like | The authoritative check |
|---|---|---|
| 1 — Intent | Analyzer warnings, conflicting hosts, subset with no matching pod | `istioctl analyze` |
| 2 — Distribution | Proxy shows `STALE`/`NOT SENT`, push errors in istiod logs | `istioctl proxy-status` |
| 3 — Effective config | Listener/route/cluster present but wrong | `istioctl proxy-config …` |
| 4 — Runtime | `503`/`504`, TLS handshake failures, hangs | Envoy access logs + `RESPONSE_FLAGS` |

The disciplined method is to **descend the layers in order**. Most engineers jump straight to Layer 4 (reading `503`s) and burn an hour; the fast path is to confirm Layers 1–2 are green first, because if the proxy never received the config, no amount of log reading at Layer 4 will explain it.

### Why the sidecar model makes this hard

- **iptables transparency.** The `istio-init` container (or the `istio-cni` plugin) installs `iptables` rules that redirect all inbound traffic to Envoy port **15006** and all outbound to **15001**. The application believes it is talking directly to `reviews:9080`; in reality it talks to its own sidecar. When something "can't connect," the first question is *which side of the iptables redirect broke*.
- **Eventual consistency.** xDS is push-based and asynchronous. Config is *eventually* consistent, so a race between "pod started" and "config arrived" produces transient `503 UH`/`NR` that vanish on retry — a class of bug that only exists because the data plane and control plane are decoupled.
- **Per-proxy view.** Each Envoy has its *own* effective config. A `VirtualService` may be applied correctly to proxy A and missing on proxy B (different namespace, different `Sidecar` scope). You must always debug **the specific proxy** that is failing, never "the mesh" in the abstract.

---

## 2. The sidecar anatomy: ports, xDS, and where each failure lands

Every `istio-proxy` container exposes a fixed set of ports. Knowing them cold is half of data-plane debugging, because the symptom often names the port.

| Port | Bound by | Purpose | Failure signature |
|---|---|---|---|
| **15000** | Envoy | Admin API (`/config_dump`, `/stats`, `/clusters`, `/logging`) | If unreachable, Envoy itself is dead |
| **15001** | Envoy | Outbound capture (iptables `REDIRECT`) | Outbound `503`s, mesh egress broken |
| **15006** | Envoy | Inbound capture (iptables `REDIRECT`) | Inbound mTLS / auth failures |
| **15008** | Envoy | HBONE tunnel (ambient / mTLS mux) | Ambient L4 path failures |
| **15020** | pilot-agent | Merged Prometheus metrics + agent | Scrape gaps, agent health |
| **15021** | pilot-agent | `/healthz/ready` readiness | Pod stuck `0/2 Running`, never `Ready` |
| **15053** | pilot-agent | DNS proxy (local resolution) | `ServiceEntry` DNS not resolving |
| **15090** | Envoy | Raw Envoy telemetry (`/stats/prometheus`) | Missing Envoy-level metrics |
| **15012** | istiod | xDS + CA (TLS/mTLS) — proxy dials *out* here | `NR`/`STALE`, cert rotation stuck |
| **15014** | istiod | Control-plane monitoring | istiod observability gaps |
| **15017** | istiod | Injection + validation webhook | Sidecar not injected, CRD rejected |

### xDS: the five discovery services

`istiod` streams five resource types to each proxy over a single ADS (Aggregated Discovery Service) gRPC stream on **15012**. The debugging tool `istioctl proxy-config` maps one-to-one onto them:

| xDS API | Envoy resource | `proxy-config` subcommand | Answers the question |
|---|---|---|---|
| **LDS** | Listeners | `listeners` | Is Envoy even listening for this traffic? |
| **RDS** | Routes | `routes` | Once matched, where does the request go? |
| **CDS** | Clusters | `clusters` | Does the destination cluster exist? What's its LB/TLS policy? |
| **EDS** | Endpoints | `endpoints` | Does the cluster have any healthy backend IPs? |
| **SDS** | Secrets | `secret` | Are the mTLS certs present and valid? |

The ordering matters for reasoning about a request: **a request hits a LISTENER (LDS), matches a ROUTE (RDS), which selects a CLUSTER (CDS), which resolves to ENDPOINTS (EDS), secured by SECRETS (SDS).** Break the chain at any link and you get a distinct, diagnosable failure — see §5.

---

## 3. The three-tier diagnostic toolchain (trade-offs)

You have three fundamentally different ways to inspect the data plane. Choosing the wrong one wastes time or, worse, gives you a *stale* answer.

| Tool | Source of truth | Latency | Best for | Trap |
|---|---|---|---|---|
| `istioctl analyze` | **Layer 1** — CRDs in etcd | Instant | Config *intent* errors before they ship | Says nothing about what Envoy actually runs |
| `istioctl proxy-status` | **Layer 2** — istiod's view of each proxy's ACK'd version | Instant | "Did the config land?" (SYNCED/STALE/NOT SENT) | Reports *distribution*, not *correctness* |
| `istioctl proxy-config` | **Layer 3** — the proxy's live `config_dump` (:15000) | Instant | The *effective* Envoy config on one proxy | Big output; you must know which resource to read |
| Envoy access logs / `/stats` | **Layer 4** — runtime | Real-time | *Why this specific request* failed (`RESPONSE_FLAGS`) | Off by default in some profiles; noisy |
| `istioctl x describe pod` | Synthesizes 1–3 | Instant | Human-readable "what applies to this pod" | Summarized — hides edge cases |

> **Rule of thumb:** `analyze` catches it before deploy, `proxy-status` tells you *if it deployed*, `proxy-config` tells you *what deployed*, and access logs tell you *why the request died*. Descend in that order.

### `proxy-config` vs. `config_dump` directly

`istioctl proxy-config clusters <pod>` is a friendly wrapper over Envoy's raw `GET localhost:15000/config_dump`. The wrapper is almost always what you want (it filters, formats, and adds columns). Drop to the raw dump only when you need a field the wrapper hides:

```
$ kubectl exec deploy/productpage-v1 -c istio-proxy -- \
    curl -s localhost:15000/config_dump | jq '.configs[].dynamic_active_clusters | length'
```

---

## 4. Complete lab: a reproducible mesh with an injected fault

The following manifests stand up a minimal but production-shaped scenario you can break and fix. It assumes Istio is installed with the `demo` or `default` profile and the `istio-injection=enabled` label.

### 4.1 Namespace, deployment, and service

```yaml
# 00-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    istio-injection: enabled          # sidecar auto-injection webhook (:15017)
---
# 01-catalog.yaml — two subsets (v1, v2) so we can break subset routing
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-v1
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels: { app: catalog, version: v1 }
  template:
    metadata:
      labels: { app: catalog, version: v1 }
    spec:
      containers:
        - name: catalog
          image: hashicorp/http-echo:1.0
          args: ["-text=catalog-v1", "-listen=:9080"]
          ports:
            - containerPort: 9080
              name: http-catalog        # port name MUST start with http- for L7 features
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-v2
  namespace: shop
spec:
  replicas: 1
  selector:
    matchLabels: { app: catalog, version: v2 }
  template:
    metadata:
      labels: { app: catalog, version: v2 }
    spec:
      containers:
        - name: catalog
          image: hashicorp/http-echo:1.0
          args: ["-text=catalog-v2", "-listen=:9080"]
          ports:
            - containerPort: 9080
              name: http-catalog
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
  namespace: shop
spec:
  selector: { app: catalog }           # selects BOTH v1 and v2 pods
  ports:
    - name: http                       # protocol inferred from name → HTTP/L7
      port: 9080
      targetPort: 9080
```

> **Production gotcha (Layer 1):** the Service port **must be named** with an Istio-recognized prefix (`http`, `http2`, `grpc`, `tcp`, `tls`, `mongo`, …) or set `appProtocol`. An unnamed or mis-named port makes Istio treat the traffic as opaque **TCP**, silently disabling routing, retries, and L7 telemetry — a top-3 cause of "my `VirtualService` does nothing."

### 4.2 The routing rules (with a deliberate bug in §4.4)

```yaml
# 02-routing.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: catalog
  namespace: shop
spec:
  host: catalog.shop.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL               # use mesh mTLS to upstream
    connectionPool:
      tcp: { maxConnections: 100 }
      http:
        http1MaxPendingRequests: 10
        maxRequestsPerConnection: 0
    outlierDetection:                  # passive health checking / ejection
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: catalog
  namespace: shop
spec:
  hosts: ["catalog.shop.svc.cluster.local"]
  http:
    - name: canary
      route:
        - destination: { host: catalog.shop.svc.cluster.local, subset: v1 }
          weight: 90
        - destination: { host: catalog.shop.svc.cluster.local, subset: v2 }
          weight: 10
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: connect-failure,refused-stream,5xx
      timeout: 10s
```

### 4.3 A client we can `curl` from

```yaml
# 03-client.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  namespace: shop
spec:
  replicas: 1
  selector: { matchLabels: { app: sleep } }
  template:
    metadata:
      labels: { app: sleep }
    spec:
      containers:
        - name: sleep
          image: curlimages/curl:8.9.1
          command: ["/bin/sleep", "infinity"]
```

### 4.4 Enforce STRICT mTLS (this is where we plant the fault in §5.3)

```yaml
# 04-peerauth.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: shop
spec:
  mtls:
    mode: STRICT                       # reject any plaintext on inbound :15006
```

Apply and confirm both containers are up:

```
$ kubectl apply -f 00-namespace.yaml -f 01-catalog.yaml -f 02-routing.yaml -f 03-client.yaml -f 04-peerauth.yaml
namespace/shop created
deployment.apps/catalog-v1 created
deployment.apps/catalog-v2 created
service/catalog created
destinationrule.networking.istio.io/catalog created
virtualservice.networking.istio.io/catalog created
deployment.apps/sleep created
peerauthentication.security.istio.io/default created

$ kubectl -n shop get pods
NAME                          READY   STATUS    RESTARTS   AGE
catalog-v1-6c9f4b7d8f-4nq2z   2/2     Running   0          40s
catalog-v1-6c9f4b7d8f-r7t9k   2/2     Running   0          40s
catalog-v2-77d5c8b6c4-lm2xp   2/2     Running   0          40s
sleep-5d9f8c7b6d-w8kqv        2/2     Running   0          40s
```

`READY 2/2` = app container + injected `istio-proxy`. A pod stuck at `1/2` or `0/2` is your first data-plane signal (see §5.1).

---

## 5. Diagnostic playbook — from symptom to root cause

### 5.1 Symptom: pod never becomes `Ready` (`0/2` or `1/2`)

The proxy's readiness gate is `pilot-agent` serving `/healthz/ready` on **15021**. It reports `Ready` only after Envoy has received its *initial* config from istiod. If it never flips, the proxy cannot reach istiod.

```
$ kubectl -n shop describe pod catalog-v1-6c9f4b7d8f-4nq2z | sed -n '/Events/,$p'
Events:
  Type     Reason     Message
  ----     ------     -------
  Warning  Unhealthy  Readiness probe failed: Get "http://10.244.1.7:15021/healthz/ready":
                      dial tcp 10.244.1.7:15021: connect: connection refused

$ kubectl -n shop logs catalog-v1-6c9f4b7d8f-4nq2z -c istio-proxy | grep -i "connect\|error" | head
warning envoy config    StreamAggregatedResources gRPC config stream to xds-grpc closed:
                        14, connection error: desc = "transport: Error while dialing:
                        dial tcp 10.96.0.10:15012: i/o timeout"
```

**Root-cause ladder:**
1. Confirm istiod is up: `kubectl -n istio-system get pods -l app=istiod`.
2. Confirm the proxy can resolve/reach `istiod.istio-system.svc:15012` — a `NetworkPolicy` blocking egress to `istio-system` is the classic culprit.
3. Confirm the injected certs are valid: `istioctl proxy-config secret <pod>` (see §5.3).

### 5.2 Symptom: config edits don't take effect — is it even distributed?

Always start with `proxy-status`. This is Layer 2: it compares the config version istiod *sent* against what each proxy *ACK'd*.

```
$ istioctl proxy-status
NAME                                       CLUSTER      CDS        LDS        EDS        RDS          ECDS         ISTIOD                       VERSION
catalog-v1-6c9f4b7d8f-4nq2z.shop           Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
catalog-v2-77d5c8b6c4-lm2xp.shop           Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
sleep-5d9f8c7b6d-w8kqv.shop                Kubernetes   STALE      SYNCED     SYNCED     STALE        NOT SENT     istiod-5c7b9f8d6-2xk4p       1.23.2
```

| State | Meaning | Action |
|---|---|---|
| `SYNCED` | Envoy ACK'd the latest push | Healthy — move to Layer 3 |
| `STALE` | istiod sent an update; proxy hasn't ACK'd | Proxy overloaded, network flaky, or a NACK — read istiod logs |
| `NOT SENT` | istiod has nothing of this type to send | Usually benign (e.g. no ECDS resources) |

A **persistent `STALE`** means a rejected (NACK'd) config. Find it in istiod:

```
$ kubectl -n istio-system logs deploy/istiod | grep -i "nack\|rejected\|error" | tail
warning ads   ADS:LDS: ACK ERROR sleep-5d9f8c7b6d-w8kqv.shop Internal:Error adding/updating
              listener(s) 0.0.0.0_9080: error initializing configuration '...':
              duplicate listener 0.0.0.0_9080 found
```

That NACK tells you exactly which resource Envoy refused — the fix belongs at Layer 1.

### 5.3 Symptom: `503` on every request — walk the LDS→RDS→CDS→EDS chain

From the client, the request fails immediately:

```
$ kubectl -n shop exec deploy/sleep -c sleep -- curl -s -o /dev/null -w "%{http_code}\n" catalog:9080
503
```

`503` from the *local* sidecar is an **upstream** failure. Read the access log and — critically — the **`RESPONSE_FLAGS`**, Envoy's one-token explanation of *why*.

```
$ kubectl -n shop logs deploy/sleep -c istio-proxy | tail -1
[2026-08-08T14:22:07.451Z] "GET / HTTP/1.1" 503 UH
  "-" "-" 0 19 1 - "-" "curl/8.9.1" "8f2a...-" "catalog:9080"
  "-" outbound|9080|v1|catalog.shop.svc.cluster.local - 10.96.44.12:9080 10.244.2.9:39820 - default
```

The token after the status is the response flag: **`UH` = No Healthy Upstream.** Here is the canonical flag table — memorize the top rows, they cover ~90% of incidents:

| Flag | Meaning | Where the fault usually is |
|---|---|---|
| **UH** | No healthy upstream — cluster has zero healthy endpoints | EDS empty (subset labels wrong), or outlier detection ejected all hosts |
| **NR** | No route configured for the request | RDS/VirtualService host or port mismatch |
| **NC** | No cluster found | CDS missing — DestinationRule/subset absent |
| **UF** | Upstream connection failure | mTLS mismatch, upstream down, network policy |
| **UC** | Upstream connection termination (RST mid-stream) | Upstream crashed, or plaintext↔mTLS mismatch |
| **UO** | Upstream overflow — circuit breaker tripped | `connectionPool` limits too low for load |
| **URX** | Retry/attempt limit exceeded | Upstream persistently failing; retries exhausted |
| **UT** | Upstream request timeout | `timeout`/`perTryTimeout` shorter than backend |
| **DC** | Downstream connection termination | Client hung up |
| **RL** | Rate limited (local) | `EnvoyFilter`/local rate limit |
| **LH** | Local health-check failed | App failing its own health probe |

`UH` says the cluster exists but has **no healthy endpoints**. Descend to Layer 3 and read the cluster and its endpoints:

```
$ istioctl proxy-config cluster deploy/sleep.shop --fqdn catalog.shop.svc.cluster.local --subset v1
SERVICE FQDN                            PORT     SUBSET   DIRECTION     TYPE     DESTINATION RULE
catalog.shop.svc.cluster.local          9080     v1       outbound      EDS      catalog.shop

$ istioctl proxy-config endpoints deploy/sleep.shop --cluster \
    "outbound|9080|v1|catalog.shop.svc.cluster.local"
ENDPOINT   STATUS   OUTLIER CHECK   CLUSTER
                                    outbound|9080|v1|catalog.shop.svc.cluster.local
```

Empty endpoint list → the **subset selector matched no pods**, or **outlier detection ejected them**. Cross-check the subset labels against the pods:

```
$ kubectl -n shop get pods -l app=catalog --show-labels
NAME                          READY   STATUS    LABELS
catalog-v1-6c9f4b7d8f-4nq2z   2/2     Running   app=catalog,version=v1,...
catalog-v2-77d5c8b6c4-lm2xp   2/2     Running   app=catalog,version=v2,...
```

If the `DestinationRule` subset said `labels: { version: v1.0 }` but pods carry `version: v1`, EDS is empty and you get `UH` on the 90% of traffic routed to `v1`. **The subset is a label selector; a typo there is invisible to `kubectl` and only shows as an empty EDS.**

If the endpoints *do* exist but show `STATUS: UNHEALTHY / OUTLIER CHECK: FAILED`, then **outlier detection** (§4.2) ejected them after 5 consecutive `5xx` — the fix is upstream stability, not routing.

### 5.4 Symptom: `503 UF`/`UC` with a mTLS mismatch (the STRICT trap)

The most common real-world data-plane incident: a client without a sidecar (or in `DISABLE` mode) talks to a service under `STRICT` `PeerAuthentication`. Envoy on the receiving side demands a client cert; plaintext gets reset.

Reproduce by curling from a **non-mesh** pod (no sidecar) into `catalog`:

```
$ kubectl run raw --image=curlimages/curl:8.9.1 -n default --restart=Never -- \
    sleep infinity
$ kubectl -n default exec raw -- curl -s -o /dev/null -w "%{http_code}\n" \
    catalog.shop:9080
000        # connection reset — TLS handshake with no client cert
```

On the *receiving* proxy the log shows `UF`/`UC` and a TLS error:

```
$ kubectl -n shop logs catalog-v1-6c9f4b7d8f-4nq2z -c istio-proxy | grep -i tls | tail -1
warning envoy conn_handler   TLS error: 268435612:SSL routines:
                             OPENSSL_internal:HTTP_REQUEST  ← plaintext hit an mTLS listener
```

**Diagnose mTLS authoritatively** with `x describe` — it prints the *effective* policy for a pod, reconciling `PeerAuthentication` + `DestinationRule`:

```
$ istioctl x describe pod catalog-v1-6c9f4b7d8f-4nq2z.shop
Pod: catalog-v1-6c9f4b7d8f-4nq2z.shop
   Pod Revision: default
   Pod Ports: 9080 (catalog), 15090 (istio-proxy)
--------------------
Service: catalog.shop
   Port: http 9080/HTTP targets pod port 9080
DestinationRule: catalog.shop for "catalog.shop.svc.cluster.local"
   Matching subsets: v1,v2
   Traffic Policy TLS Mode: ISTIO_MUTUAL
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT     ← inbound requires client certs
```

And confirm the certs actually exist and are unexpired (SDS / Layer 3):

```
$ istioctl proxy-config secret catalog-v1-6c9f4b7d8f-4nq2z.shop
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2a:f1:...:9c         2026-08-09T14:20:03Z     2026-08-08T14:18:03Z
ROOTCA            CA             ACTIVE     true           01                   2036-08-05T09:11:44Z     2026-08-05T09:11:44Z
```

`VALID CERT: false` or an expired `NOT AFTER` points at cert rotation failure (proxy can't reach the CA on `15012`). Here certs are valid — the fault is purely that the caller sent plaintext. **Fix options, with trade-offs:**

| Fix | Effect | Trade-off |
|---|---|---|
| Move caller into the mesh (inject sidecar) | Caller presents a cert → mTLS succeeds | Correct long-term; requires the caller be mesh-managed |
| `PeerAuthentication mode: PERMISSIVE` | Accept *both* mTLS and plaintext | Weakens zero-trust; use only during migration |
| Port-level `PeerAuthentication` exception | STRICT everywhere but one port PERMISSIVE | Surgical; risk of drift/forgotten exception |

### 5.5 Symptom: `404`/`NR` — the request matched no route

`NR` means the request reached a listener but **no route matched**. Read the effective routes and confirm the `domains`/`match` actually cover your request:

```
$ istioctl proxy-config routes deploy/sleep.shop --name 9080 -o json | \
    jq '.[].virtualHosts[] | {name, domains}'
{
  "name": "catalog.shop.svc.cluster.local:9080",
  "domains": [
    "catalog.shop.svc.cluster.local",
    "catalog.shop.svc.cluster.local:9080",
    "catalog", "catalog:9080",
    "catalog.shop", "catalog.shop:9080",
    "catalog.shop.svc", "catalog.shop.svc:9080",
    "10.96.44.12", "10.96.44.12:9080"
  ]
}
```

If your `curl` used a Host header (`-H "Host: catalog.other"`) not in `domains`, you get `NR`. For gateways, `NR` most often means the `VirtualService` isn't bound to the `Gateway` (missing `gateways:` entry or wrong `hosts`).

### 5.6 Symptom: intermittent `503 UC`/`URX` under load — connection pools & idle resets

Envoy multiplexes upstream connections. Two production classics:

- **`maxRequestsPerConnection: 0`** (unlimited) + an upstream (or intermediate LB) that closes idle keep-alives → Envoy reuses a half-closed connection → `UC`. Setting `maxRequestsPerConnection: 1` or a short `idleTimeout` mitigates it.
- **Circuit breaking (`UO`)** when `http1MaxPendingRequests`/`maxConnections` are too low for real load. The definitive proof is the Envoy counter, not a guess:

```
$ kubectl -n shop exec deploy/sleep -c istio-proxy -- \
    curl -s localhost:15000/stats | grep 'catalog.*v1.*overflow'
cluster.outbound|9080|v1|catalog.shop.svc.cluster.local.upstream_cx_pool_overflow: 0
cluster.outbound|9080|v1|catalog.shop.svc.cluster.local.upstream_rq_pending_overflow: 142
```

`upstream_rq_pending_overflow: 142` = 142 requests rejected by the pending-request circuit breaker → raise `http1MaxPendingRequests` or scale the backend. **The counter is the truth; the log flag `UO` is just the symptom.**

---

## 6. Cross-cutting tools you should reach for

### 6.1 `istioctl analyze` — catch Layer-1 errors before they ship

```
$ istioctl analyze -n shop
Warning [IST0101] (VirtualService catalog.shop) Referenced host+subset in
  destination is not found: "catalog.shop.svc.cluster.local+v3".
Error [IST0106] (DestinationRule catalog.shop) Schema validation error:
  subsets[2].labels: unknown field
Info  [IST0102] (Namespace shop) The namespace is enabled for Istio injection.
```

Run this in CI against your rendered manifests — it turns a runtime `NR`/`NC` incident into a build failure.

### 6.2 Turn up Envoy log verbosity live (no restart)

```
$ istioctl proxy-config log deploy/sleep.shop --level upstream:debug,router:debug
active loggers:
  ...
  router: debug
  upstream: debug

# ... reproduce the failure, read logs, then reset ...
$ istioctl proxy-config log deploy/sleep.shop --level warning
```

This changes Envoy's admin logging on `:15000` in place — invaluable for a transient bug you can't afford to lose to a pod restart.

### 6.3 Enable access logging mesh-wide when the profile disabled it

If access logs are empty, the mesh may have `accessLogFile` unset. Turn it on with a `Telemetry` resource (preferred over patching the mesh config):

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-access-logs
  namespace: istio-system          # istio-system = mesh-wide default
spec:
  accessLogging:
    - providers:
        - name: envoy               # the built-in Envoy file access log provider
```

### 6.4 The compact decision tree

```
503 / failure at the client sidecar
│
├─ pod not 2/2 Ready? ──────────────▶ §5.1  (proxy ↔ istiod on :15012, certs, NetworkPolicy)
│
├─ proxy-status STALE/persistent? ──▶ §5.2  (NACK — read istiod logs, fix the CRD)
│
└─ read access log RESPONSE_FLAGS:
     UH ─▶ empty EDS: subset labels? outlier ejection?      §5.3
     NC ─▶ missing cluster: DestinationRule/subset absent   §5.3
     NR ─▶ no route: VirtualService host/gateway binding    §5.5
     UF/UC + TLS error ─▶ mTLS mode mismatch (STRICT trap)   §5.4
     UO/URX ─▶ circuit breaking: check *overflow stats       §5.6
     UT ─▶ timeout shorter than backend latency             §5.6
```

---

## 7. Verification checklist (production-ready gate)

Before declaring a data-plane issue resolved, all of the following must hold for the affected proxy:

1. **Injection:** `kubectl get pod <p> -o jsonpath='{.spec.containers[*].name}'` includes `istio-proxy`, and the pod is `2/2 Ready`.
2. **Distribution:** `istioctl proxy-status` shows `SYNCED` for CDS/LDS/EDS/RDS on that proxy.
3. **No intent errors:** `istioctl analyze -n <ns>` returns no `Error`-level findings.
4. **Cluster present:** `istioctl proxy-config cluster <p> --fqdn <svc>` lists the destination.
5. **Endpoints healthy:** `istioctl proxy-config endpoints <p> --cluster <c>` shows ≥1 endpoint with `STATUS: HEALTHY`.
6. **Route matches:** `istioctl proxy-config routes <p>` `domains` include the caller's authority.
7. **mTLS coherent:** `istioctl x describe pod <p>` shows the intended mode; `proxy-config secret <p>` shows `VALID CERT: true` and a future `NOT AFTER`.
8. **Runtime clean:** a live `curl` returns the expected status, and the access-log `RESPONSE_FLAGS` field is `-` (no flag).
9. **No circuit-breaker overflow:** `upstream_rq_pending_overflow` / `upstream_cx_overflow` counters are stable (not incrementing) under representative load.

Only when 1–9 are green is the data-plane path proven end-to-end — from control-plane distribution down to a real request on the wire.

---

## Referencias

- Istio — Diagnostic Tools overview: https://istio.io/latest/docs/ops/diagnostic-tools/
- Istio — Debugging Envoy and Istiod (`proxy-status`, `proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — Understand your mesh with `istioctl describe`: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/
- Istio — Component debugging & config distribution: https://istio.io/latest/docs/ops/diagnostic-tools/component-debugging/
- Istio — Common problems / troubleshooting (503s, mTLS): https://istio.io/latest/docs/ops/common-problems/
- Istio — Network / traffic management problems: https://istio.io/latest/docs/ops/common-problems/network-issues/
- Istio — Security / mTLS problems: https://istio.io/latest/docs/ops/common-problems/security-issues/
- Istio — Ports used by the sidecar and control plane: https://istio.io/latest/docs/ops/deployment/application-requirements/
- Istio — Mutual TLS & `PeerAuthentication`: https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — Circuit breaking / outlier detection: https://istio.io/latest/docs/tasks/traffic-management/circuit-breaking/
- Istio — Enabling Envoy access logs: https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Istio — `Telemetry` API: https://istio.io/latest/docs/reference/config/telemetry/
- Envoy — Access log format & `%RESPONSE_FLAGS%`: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy — Admin interface (`/config_dump`, `/stats`, `/clusters`, `/logging`): https://www.envoyproxy.io/docs/envoy/latest/operations/admin
- Envoy — xDS / Aggregated Discovery Service protocol: https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf