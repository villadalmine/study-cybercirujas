# Topic 2.1 — Troubleshooting Configuration (Istio Certified Associate)

> **Domain:** Troubleshooting · **Exam weight:** 7 · **Profile:** SRE / Platform Architect
> **Scope:** Diagnosing why an Istio configuration object (`VirtualService`, `DestinationRule`, `Gateway`, `ServiceEntry`, `Sidecar`, `PeerAuthentication`, `AuthorizationPolicy`) does *not* produce the effective dataplane behavior you expect — and doing it methodically, from the control plane down to a single Envoy filter chain.

---

## 1. Motivation and the production architectural problem

In a service mesh, **the configuration you write is never the configuration that runs.** You author *intent* as Kubernetes CRDs. `istiod` (the Pilot component) watches those CRDs plus the Kubernetes service registry (`Service`, `EndpointSlice`, `Pod`), compiles them into **Envoy xDS resources**, and streams them over an mTLS gRPC channel to every sidecar. The sidecar's Envoy is the thing that actually accepts, routes, secures, and rejects traffic.

This compilation pipeline is where production incidents are born. A `VirtualService` that is syntactically valid, passes admission, and shows `SYNCED` in `proxy-status` can still send 100% of traffic to a black hole because a `subset` name doesn't match a `DestinationRule`, a port isn't named per convention, or a `PeerAuthentication` mode contradicts a `DestinationRule` TLS mode. **None of these are schema errors.** The API server accepts them happily.

```
                       Kubernetes API server
   ┌───────────────────────┴───────────────────────────┐
   │  Istio CRDs                Service registry        │
   │  VirtualService            Service                 │
   │  DestinationRule           EndpointSlice           │
   │  Gateway / ServiceEntry    Pod (labels, ports)     │
   │  Sidecar / PeerAuth        Node                     │
   └───────────────────────┬───────────────────────────┘
                           │ watch (informers)
                    ┌──────▼───────┐
                    │    istiod     │   compile intent → xDS
                    │  (Pilot/CA)   │   push over ADS (gRPC)
                    └──────┬───────┘
             mTLS xDS :15012│  (LDS/RDS/CDS/EDS/SDS/ECDS)
        ┌───────────────────┼────────────────────┐
   ┌────▼─────┐        ┌────▼─────┐         ┌────▼─────┐
   │ Envoy    │        │ Envoy    │   ...   │ Envoy    │
   │ sidecar  │        │ sidecar  │         │ ingressgw│
   └──────────┘        └──────────┘         └──────────┘
```

**The architect's problem statement:** at any point in this pipeline the intent can be *dropped, contradicted, shadowed by a higher-priority object, or silently downgraded to L4*. Troubleshooting configuration is the discipline of **locating which rung of that ladder broke the intent**, using the least expensive tool that can prove it. The failure classes you must recognize on sight:

| Symptom seen by client | Most common configuration root cause |
|---|---|
| `503 UC` upstream connect error / reset before headers | mTLS mismatch (`PeerAuthentication STRICT` vs `DestinationRule tls: DISABLE`) |
| `503 NR` no route / `404` from mesh | `VirtualService` host/route doesn't match, or not bound to the `Gateway` |
| `no healthy upstream` / `503 UH` | `subset` labels select zero pods; all endpoints unhealthy / ejected |
| `503` "cluster not found" (`NC`) | `DestinationRule` subset referenced by `VirtualService` doesn't exist |
| L7 routing rules silently ignored | Service port not named per convention → treated as raw TCP |
| Sidecar never applies config | Namespace/pod not injected; config scoped out by a `Sidecar` resource |
| Config never reaches proxy (`STALE`) | istiod push rejected (NACK), overloaded, or version skew |

---

## 2. The xDS model and config-sync semantics (know these cold)

Envoy is configured by the **xDS APIs**, aggregated onto a single gRPC stream (ADS) so that ordering across resource types is deterministic. Every column in `istioctl proxy-status` is one of these:

| xDS | Resource | What it configures | Typical failure when broken |
|---|---|---|---|
| **LDS** | Listeners | Sockets/ports Envoy binds; per-port filter chains | Port not listening; wrong protocol filter |
| **RDS** | Routes | HTTP route tables referenced by HCM | `404`/`NR`; header/URI match never hit |
| **CDS** | Clusters | Upstream groups (per service+subset+port) | subset "cluster not found" (`NC`) |
| **EDS** | Endpoints | Actual pod IPs behind each cluster | `no healthy upstream` (`UH`) |
| **SDS** | Secrets | mTLS certs, CA roots, gateway TLS | cert not rotated; TLS handshake fails |
| **ECDS** | Extension configs | WASM/ext filters | filter not applied |

**Config-sync status values** (per column):

| Status | Meaning | Action |
|---|---|---|
| `SYNCED` | istiod ACK'd — Envoy has the last version istiod sent | Config *arrived*; verify it's *correct* |
| `NOT SENT` | istiod hasn't pushed this type (nothing to send yet) | Usually benign (e.g. `ECDS NOT SENT` with no WASM) |
| `STALE` | istiod sent an update, Envoy hasn't ACK'd | Push in flight, NACK, overload, or a stuck proxy |
| `NOT SENT` / blank + version skew | proxy older than control plane | Check `istioctl version`, sidecar image |

> **Critical mental model:** `SYNCED` proves *delivery*, never *correctness*. The single most common troubleshooting error is stopping at a green `proxy-status`. It only means "Envoy has what istiod computed" — if istiod computed a route to nowhere, that route is faithfully `SYNCED`.

---

## 3. The tooling ladder — cheapest proof first

| Rung | Tool | Answers | Cost | Reads live dataplane? |
|---|---|---|---|---|
| 0 | `istioctl validate -f x.yaml` | Is the YAML schema-valid before apply? | free | no |
| 1 | `istioctl analyze` | Do objects reference each other correctly (semantic)? | free | cluster state, static |
| 2 | `istioctl proxy-status` | Did config *reach* each proxy? | free | control plane |
| 3 | `istioctl x describe pod <p>` | What config *effectively* applies to this pod? | free | live |
| 4 | `istioctl proxy-config {clusters,listeners,routes,endpoints,secret}` | What does Envoy *actually* have? | free | live |
| 5 | Envoy admin `:15000/config_dump`, `/stats`, `/clusters` | Ground truth + counters | free | live |
| 6 | Envoy access logs + `RESPONSE_FLAGS` | What did a *real request* do? | cheap | live |
| 7 | `istioctl proxy-config log --level debug`, istiod logs, ControlZ | Trace the compile/push itself | expensive | live |

**Static (rungs 0–1) vs runtime (rungs 3–6) — trade-offs:**

| | Static analysis (`analyze`) | Runtime inspection (`proxy-config`) |
|---|---|---|
| Sees | Cross-object references, conventions, conflicts | The compiled Envoy reality |
| Misses | Anything Envoy computed differently, endpoint health, live TLS | Intent-level "why" (which CRD caused this) |
| Speed | Instant, pre-deploy in CI | Requires a running, injected pod |
| Best for | Catch class of bug before merge | "It's deployed and still wrong" |
| Blind spot | Won't tell you a pod is `STALE` | Won't tell you a `subset` typo unless you diff clusters |

Use them together: `analyze` in CI to stop the class of bug, `proxy-config`/`describe` at 2 a.m. when it shipped anyway.

---

## 4. Full reproducible manifests — a broken mesh and its fix

Below is a **complete, self-contained** scenario you can apply and diagnose. It embeds the two highest-frequency production configuration bugs: an **mTLS mode conflict** (503 UC) and a **subset mismatch** (503 NC).

### 4.1 Workloads and Service (note the port naming — this matters)

```yaml
# reviews.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    istio-injection: enabled          # sidecar auto-injection ON for this namespace
---
apiVersion: v1
kind: Service
metadata:
  name: reviews
  namespace: shop
  labels:
    app: reviews
spec:
  selector:
    app: reviews
  ports:
    - name: http                      # MUST be named http/http2/grpc/tcp/tls...
      port: 9080                       # unnamed or "tcp-9080" => L7 rules silently dropped
      targetPort: 9080
      appProtocol: http               # explicit, future-proof alternative to name prefix
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: reviews-v1, namespace: shop }
spec:
  replicas: 1
  selector: { matchLabels: { app: reviews, version: v1 } }
  template:
    metadata:
      labels: { app: reviews, version: v1 }   # <-- version label subsets key off
    spec:
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v1:1.18.0
          ports: [{ containerPort: 9080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: reviews-v2, namespace: shop }
spec:
  replicas: 1
  selector: { matchLabels: { app: reviews, version: v2 } }
  template:
    metadata:
      labels: { app: reviews, version: v2 }
    spec:
      containers:
        - name: reviews
          image: docker.io/istio/examples-bookinfo-reviews-v2:1.18.0
          ports: [{ containerPort: 9080 }]
```

### 4.2 The BROKEN routing + security intent

```yaml
# broken-config.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: shop
spec:
  mtls:
    mode: STRICT                       # server side: plaintext will be REJECTED
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: shop
spec:
  host: reviews.shop.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE                    # BUG #1: client sends plaintext to a STRICT server -> 503 UC
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: shop
spec:
  hosts: [ reviews.shop.svc.cluster.local ]
  http:
    - route:
        - destination:
            host: reviews.shop.svc.cluster.local
            subset: v3                 # BUG #2: subset v3 not defined in DestinationRule -> 503 NC
          weight: 100
```

### 4.3 The FIXED intent (both bugs resolved)

```yaml
# fixed-config.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: shop
spec:
  host: reviews.shop.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL               # FIX #1: match STRICT server; Istio-managed mTLS
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: shop
spec:
  hosts: [ reviews.shop.svc.cluster.local ]
  http:
    - route:
        - destination:
            host: reviews.shop.svc.cluster.local
            subset: v1                 # FIX #2: reference a subset that exists
          weight: 100
```

### 4.4 Mesh-level config to *make troubleshooting possible* (observability)

Access logs are OFF by default in many installs; without them, `RESPONSE_FLAGS` analysis is impossible. Turn them on mesh-wide and widen the metrics allow-list:

```yaml
# istio-observability.yaml  (IstioOperator, apply with: istioctl install -f ...)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    accessLogFile: /dev/stdout                 # emit Envoy access logs to sidecar stdout
    accessLogEncoding: JSON                     # structured, greppable
    enableTracing: true
    defaultConfig:
      proxyStatsMatcher:
        inclusionRegexps:
          - ".*outlier_detection.*"
          - ".*circuit_breakers.*"
          - ".*upstream_rq_retry.*"
          - ".*_cx_.*"                           # connection-level stats for UC/UF debugging
  values:
    global:
      logging:
        level: "default:info"
```

---

## 5. CLI commands and real terminal output ($)

### 5.1 Rung 1 — semantic static analysis catches both bugs *before* they page you

```console
$ istioctl analyze -n shop
Error [IST0101] (VirtualService reviews.shop) Referenced host+subset in destinationrule not found: "reviews+v3"
Warning [IST0102] (Namespace shop) The namespace is not enabled for Istio injection. Run 'kubectl label namespace shop istio-injection=enabled' ...
Info  [IST0118] (Service reviews.shop Port http/9080) Port name http (port: 9080) doesn't follow the naming convention... (suppressed when appProtocol is set)

Error: Analyzers found issues when analyzing namespace: shop.
See https://istio.io/latest/docs/reference/config/analysis for more information about causes and resolutions.
$ echo $?
1
```

> `IST0101` is the subset typo (BUG #2). The mTLS conflict (BUG #1) is *not* caught statically here — it only manifests at runtime, which is why you never trust `analyze` alone. Message-code reference: <https://istio.io/latest/docs/reference/config/analysis/>.

### 5.2 Rung 2 — did config reach the proxies?

```console
$ istioctl proxy-status
NAME                                   CLUSTER      CDS      LDS      EDS      RDS      ECDS       ISTIOD                      VERSION
reviews-v1-6d5cc7b8f9-2xk4p.shop       Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-5c6b9f8b6-7t9qz      1.20.1
reviews-v2-77b9d6c4c5-lm8sd.shop       Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-5c6b9f8b6-7t9qz      1.20.1
productpage-v1-6f9c8b7d5-abc12.shop    Kubernetes   SYNCED   STALE    SYNCED   SYNCED   NOT SENT   istiod-5c6b9f8b6-7t9qz      1.20.1
```

`productpage`'s `LDS STALE` = istiod pushed a listener update the proxy hasn't ACK'd. Check istiod for a NACK before touching the app:

```console
$ kubectl -n istio-system logs deploy/istiod | grep -iE "nack|rejected|error" | tail -3
2026-08-08T14:22:07.114Z warn  ads   ADS:LDS: ACK ERROR productpage-v1-...shop-1.2.3.4
    Internal:Error adding/updating listener(s) 0.0.0.0_9080: error building filter chain
```

### 5.3 Rung 3 — what *effectively* applies to a pod (the most underused command)

```console
$ istioctl experimental describe pod reviews-v1-6d5cc7b8f9-2xk4p -n shop
Pod: reviews-v1-6d5cc7b8f9-2xk4p.shop
   Pod Revision: default
   Pod Ports: 9080 (reviews), 15090 (istio-proxy)
--------------------
Service: reviews.shop
   Port: http 9080/HTTP targets pod port 9080
DestinationRule: reviews.shop for "reviews.shop.svc.cluster.local"
   Matching subsets: v1
      (Non-matching subsets v2)
   Traffic Policy TLS Mode: DISABLE            #  <-- red flag vs STRICT server
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
   Skipping VirtualService reviews.shop: no destination matches subset (subset "v3" not found)

WARNING: Pod is PERMISSIVE? No — server requires STRICT but client DestinationRule DISABLEs TLS.
```

This single view aligns **client TLS mode (DISABLE)** against **server mTLS mode (STRICT)** — the smoking gun for the 503 UC — *and* reports the dangling `subset v3`.

### 5.4 Rung 4 — Envoy's actual clusters, routes, endpoints

```console
$ istioctl proxy-config clusters productpage-v1-6f9c8b7d5-abc12 -n shop --fqdn reviews.shop.svc.cluster.local
SERVICE FQDN                          PORT   SUBSET   DIRECTION   TYPE   DESTINATION RULE
reviews.shop.svc.cluster.local        9080   -        outbound    EDS    reviews.shop
reviews.shop.svc.cluster.local        9080   v1       outbound    EDS    reviews.shop
reviews.shop.svc.cluster.local        9080   v2       outbound    EDS    reviews.shop
#  Note: there is NO "v3" row -> the VirtualService routes to a cluster that does not exist -> 503 NC
```

```console
$ istioctl proxy-config routes productpage-v1-6f9c8b7d5-abc12 -n shop --name 9080 -o json \
    | jq '.[].virtualHosts[] | select(.name|test("reviews")) | .routes[].route.cluster'
"outbound|9080|v3|reviews.shop.svc.cluster.local"     #  <-- points at a nonexistent cluster
```

```console
$ istioctl proxy-config endpoints reviews-v1-6d5cc7b8f9-2xk4p -n shop \
    --cluster "outbound|9080|v1|reviews.shop.svc.cluster.local"
ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
10.244.1.23:9080     HEALTHY     OK                outbound|9080|v1|reviews.shop.svc.cluster.local
```

(If STATUS showed `UNHEALTHY` or the list were empty, that is your `503 UH no healthy upstream` — a `subset`-labels-select-zero-pods or failing-health-check problem, not a routing problem.)

### 5.5 Rung 5 — Envoy admin ground truth (via pilot-agent, no extra tooling)

```console
$ kubectl exec productpage-v1-6f9c8b7d5-abc12 -c istio-proxy -n shop -- \
    pilot-agent request GET clusters | grep 'reviews.*health_flags' | head
outbound|9080|v1||reviews.shop.svc.cluster.local::10.244.1.23:9080::health_flags::healthy

$ kubectl exec productpage-v1-6f9c8b7d5-abc12 -c istio-proxy -n shop -- \
    pilot-agent request GET stats | grep -E 'reviews.*(upstream_cx_connect_fail|ssl.connection_error)'
cluster.outbound|9080|v1||reviews.shop.svc.cluster.local.ssl.connection_error: 47
cluster.outbound|9080|v1||reviews.shop.svc.cluster.local.upstream_cx_connect_fail: 0
```

`ssl.connection_error: 47` climbing while `cx_connect_fail: 0` is the TLS-handshake fingerprint of the mTLS mismatch: TCP connects fine, the TLS layer is rejected.

### 5.6 Rung 6 — a real request, decoded via RESPONSE_FLAGS

```console
$ kubectl exec productpage-v1-6f9c8b7d5-abc12 -c istio-proxy -n shop -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://reviews:9080/health
503

$ kubectl logs productpage-v1-6f9c8b7d5-abc12 -c istio-proxy -n shop | tail -1
{"response_code":503,"response_flags":"UC","upstream_host":"10.244.1.23:9080",
 "upstream_cluster":"outbound|9080|v1||reviews.shop.svc.cluster.local",
 "route_name":"default","method":"GET","path":"/health",
 "response_code_details":"upstream_reset_before_response_started{connection_termination}",
 "duration":2,"bytes_received":0}
```

**`RESPONSE_FLAGS` — the decoder ring every ICA candidate must memorize:**

| Flag | Meaning | Typical config cause |
|---|---|---|
| `UC` | Upstream connection termination | **mTLS mismatch**, upstream crash on connect |
| `UF` | Upstream connection failure | endpoint unreachable, wrong port |
| `UH` | No healthy upstream | subset selects 0 pods; all ejected |
| `NR` | No route configured | `VirtualService` host/match miss; not bound to gateway |
| `NC` | Upstream cluster not found | **subset referenced but not in `DestinationRule`** |
| `UO` | Upstream overflow | circuit breaker (`connectionPool`) tripped |
| `URX` | Retry/connect-attempt limit reached | retries exhausted |
| `UT` | Upstream request timeout | `timeout` too low / slow backend |
| `DC` | Downstream connection termination | client hung up |
| `UAEX` | Unauthorized external service | `AuthorizationPolicy` DENY |
| `RL` / `RLSE` | Rate limited locally / rate-limit svc error | ratelimit filter |
| `DI` / `FI` | Fault injection: delay / abort | intentional `VirtualService` fault |

### 5.7 Verifying effective mTLS and the fix

```console
$ istioctl x describe pod reviews-v1-6d5cc7b8f9-2xk4p -n shop | grep -A2 'PeerAuth\|TLS Mode'
   Traffic Policy TLS Mode: ISTIO_MUTUAL
Effective PeerAuthentication:
   Workload mTLS mode: STRICT           #  client ISTIO_MUTUAL now matches server STRICT

$ kubectl exec productpage-v1-6f9c8b7d5-abc12 -c istio-proxy -n shop -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://reviews:9080/health
200
```

### 5.8 Deeper control-plane introspection (when the proxy view isn't enough)

```console
# Ask istiod what it BELIEVES each proxy has ACK'd (server-side truth):
$ istioctl experimental internal-debug syncz | jq '.[] | {proxy:.ProxyID, cds:.ClusterSent}' | head

# Registry istiod computed from the k8s service registry:
$ istioctl experimental internal-debug registryz -n istio-system | jq '.[] | .hostname' | grep reviews

# Live-reconfigure Envoy log verbosity for one component without a restart:
$ istioctl proxy-config log productpage-v1-6f9c8b7d5-abc12 -n shop --level "upstream:debug,router:debug"
active loggers:
  ...
  router: debug
  upstream: debug

# Human-readable web UI for istiod internals:
$ istioctl dashboard controlz deploy/istiod.istio-system
http://localhost:9876
```

> Raw istiod debug endpoints (`/debug/syncz`, `/debug/registryz`, `/debug/endpointz`, `/debug/configz`, `/debug/adsz`, `/debug/config_distribution`) are exposed on the monitoring interface but are **authenticated/gated**; prefer `istioctl x internal-debug`, which tunnels through istiod's authorized channel rather than requiring a raw port-forward.

---

## 6. Verification and failure-diagnosis guide

### 6.1 Deterministic diagnosis decision tree

```
Client sees error
│
├─ 5xx? ── read Envoy access log RESPONSE_FLAGS on the *source* sidecar
│    ├─ NR  → routing: `pc routes <pod>` — does a route match host/port/headers?
│    │         gateway path? `analyze` for IST0132 (host not in Gateway).
│    ├─ NC  → subset: `pc clusters --fqdn <svc>` — is the referenced subset present?
│    │         `analyze` → IST0101. Fix DestinationRule/VirtualService subset names.
│    ├─ UH  → endpoints: `pc endpoints --cluster ...` — 0 endpoints or all UNHEALTHY?
│    │         Check subset labels vs pod labels; readiness; outlier ejection.
│    ├─ UC/UF→ connection/TLS: `x describe pod` — client tls mode vs server mTLS mode.
│    │         `pc secret <pod>` — cert present/valid? stats: ssl.connection_error.
│    ├─ UO  → circuit breaking: connectionPool limits; `cx_pool_overflow` stat.
│    └─ UT  → timeout: VirtualService http.timeout vs real backend latency.
│
├─ Rule "does nothing" (L7 match ignored)?
│    → port not named per convention → treated as TCP. `analyze` IST0118.
│      Fix Service port name (http/http2/grpc/...) or set appProtocol.
│
├─ Config never took effect at all?
│    → `proxy-status`: STALE? istiod NACK in logs. NOT injected? IST0102/IST0103.
│      Scoped out by a `Sidecar` egressHosts / importedNamespaces?
│
└─ Two configs fighting?
     → `analyze`: IST0109 conflicting mesh-gateway VirtualService hosts;
       IST0110 conflicting Sidecar workload selectors. Order/priority matters.
```

### 6.2 The config-troubleshooting checklist (run top-to-bottom)

1. **Prove schema + semantics offline:** `istioctl validate -f` then `istioctl analyze -n <ns> --all-namespaces`. Fix every `Error [ISTxxxx]`; triage `Warning`. Wire this into CI so the class never re-ships.
2. **Prove delivery:** `istioctl proxy-status` — any `STALE`/version-skew? If yes, grep istiod logs for `NACK`/`rejected` before blaming app config.
3. **Prove effective intent:** `istioctl x describe pod <p>` — reconciles Service ↔ DestinationRule ↔ VirtualService ↔ PeerAuthentication into one view; surfaces subset mismatches and TLS-mode conflicts.
4. **Prove the compiled reality:** `proxy-config clusters|routes|listeners|endpoints|secret` — confirm the exact Envoy resource exists and points where you expect. Diff against a known-good pod.
5. **Prove request behavior:** enable access logs (`meshConfig.accessLogFile: /dev/stdout`), issue a real request, decode `RESPONSE_FLAGS` + `response_code_details`.
6. **Confirm the fix by counters, not by "it worked once":** re-check `ssl.connection_error`, `upstream_rq_5xx`, and outlier-detection stats are flat after the change; re-run `x describe pod` to confirm modes now agree.

### 6.3 Pitfalls that pass every free check

- **`SYNCED` ≠ correct.** Delivery is proven; correctness is not (§2).
- **`analyze` scope.** It only inspects namespaces you point it at; run `--all-namespaces` for cross-namespace `Gateway`/`ServiceEntry`/root-namespace policy interactions.
- **Root-namespace mesh policy.** A `PeerAuthentication`/`AuthorizationPolicy` in `istio-system` (the mesh root) silently governs *every* namespace; a workload-level 503 can originate three layers up.
- **`Sidecar` resource scoping.** A restrictive `Sidecar` `egress.hosts` prunes clusters/endpoints from a proxy — your config is *correct* but was never sent to that proxy. Confirm with `proxy-config clusters`, not `analyze`.
- **Port protocol downgrade.** Unnamed / mis-prefixed Service ports demote the port to raw TCP; every HTTP-level `VirtualService` rule becomes a no-op with *no error anywhere* except `IST0118` (Info-level, easy to miss).

---

## 7. References (official sources)

- Istio — Diagnostic Tools overview: <https://istio.io/latest/docs/ops/diagnostic-tools/>
- `istioctl analyze` (config analysis): <https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/>
- Analysis message reference (IST0xxx codes): <https://istio.io/latest/docs/reference/config/analysis/>
- Understand your mesh with `istioctl describe`: <https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/>
- Debugging Envoy and istiod (`proxy-status`, `proxy-config`, ControlZ): <https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/>
- Common problems — traffic management (503 NR/NC/UC, subsets): <https://istio.io/latest/docs/ops/common-problems/network-issues/>
- Common problems — security / mutual TLS: <https://istio.io/latest/docs/ops/common-problems/security-issues/>
- Requirements for Pods and Services (port naming convention): <https://istio.io/latest/docs/ops/deployment/application-requirements/>
- `istioctl` command reference: <https://istio.io/latest/docs/reference/commands/istioctl/>
- Envoy access logging & `%RESPONSE_FLAGS%`: <https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage>
- Envoy xDS / ADS protocol: <https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol>
- ICA curriculum (CNCF): <https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf>