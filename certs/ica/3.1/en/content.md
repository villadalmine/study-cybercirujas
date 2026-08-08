# 3.1 Configuring Ingress and Egress Traffic

> **Certification:** Istio Certified Associate (ICA) · **Domain:** Traffic Management · **Exam weight:** 5%
> **Scope:** North–south traffic control at the mesh boundary — admitting external clients (ingress) and governing calls to services outside the mesh registry (egress), using Istio's `Gateway`/`VirtualService`/`ServiceEntry`/`Sidecar` APIs and the Kubernetes Gateway API.

---

## 1. Motivation: the architectural problem at the mesh boundary

A service mesh gives you uniform mTLS, retries, and observability *between* workloads that carry an Envoy sidecar. But two classes of traffic cross the mesh boundary and are, by default, **outside** that control plane's guarantees:

- **Ingress (north → south):** a client on the public Internet — a browser, a partner API, a CI runner — has no sidecar and no Istio identity. If it hits your `Service` of `type: LoadBalancer` directly, none of the mesh's policy engine (authorization, rate limiting, mTLS, telemetry) applies. The connection terminates on a pod that trusts whatever reached it.
- **Egress (south → north/out):** an in-mesh pod calling `api.stripe.com`, an RDS endpoint, or an internal legacy mainframe. By default Istio's `outboundTrafficPolicy` is `ALLOW_ANY`, so the sidecar passes *any* unknown destination straight through. That is convenient and it is also a **data-exfiltration hole and a compliance failure**: a compromised pod can reach anything the node routing allows, and your SIEM sees a flat egress with no per-workload attribution.

The production pain that motivates this topic:

1. **A single, auditable entry point.** You do not want N services each exposing a LoadBalancer. You want one hardened edge (`istio-ingressgateway`) where TLS terminates, certs rotate, WAF/authz sits, and every request is logged with a trace ID.
2. **Certificate lifecycle decoupled from apps.** TLS material must live as Kubernetes secrets consumed by the gateway (via SDS), rotated by cert-manager, never baked into application images.
3. **A controlled, allow-listed, monitorable exit.** Regulated environments (PCI-DSS, SOC 2) require that egress to third parties leaves from **known, fixed IPs** and is **allow-listed by hostname**. That means forcing egress through a dedicated **egress gateway** so the external firewall can pin a small IP set, and switching the mesh to `REGISTRY_ONLY` so an undeclared destination is *denied*, not silently forwarded.
4. **TLS origination offload.** Legacy apps that speak plain HTTP should not be rewritten to add HTTPS; the mesh originates TLS to the external endpoint on their behalf, and the CA bundle is managed centrally.

The rest of this module builds both edges: the ingress path (`Gateway` + `VirtualService` + TLS secret via SDS), and the egress path (`ServiceEntry` + `Sidecar` scoping + egress `Gateway` + `DestinationRule` TLS origination), with the failure-diagnosis workflow that separates "config applied" from "config working."

---

## 2. Technical comparison and trade-offs

### 2.1 Ways to admit north–south traffic

| Dimension | Kubernetes `Ingress` | **Istio `Gateway` + `VirtualService`** | **Kubernetes Gateway API** (`Gateway`+`HTTPRoute`) |
|---|---|---|---|
| API group | `networking.k8s.io/v1` | `networking.istio.io/v1` | `gateway.networking.k8s.io/v1` |
| Data plane | Any ingress controller | Envoy (`istio-ingressgateway`) | Envoy (Istio implementation) |
| Protocol reach | HTTP(S) only | HTTP, HTTPS, gRPC, TCP, TLS/SNI, mongo/mysql etc. | HTTP, TLS, TCP, gRPC (per-Route kind) |
| L7 routing power | Path/host, controller-specific annotations | Full: weighted, header/regex match, mirror, fault, retry, timeout, rewrite | HTTPRoute matchers + filters; mesh extensions via VirtualService still needed for advanced cases |
| TLS termination | Secret ref, controller-dependent | `credentialName` → SDS; SIMPLE/MUTUAL/PASSTHROUGH | `certificateRefs` → SDS |
| Role separation | None (one object) | Weak (Gateway vs VS by convention) | **Strong, built in** (infra team owns `Gateway`, app team owns `HTTPRoute`, `ReferenceGrant` gates cross-namespace) |
| Portability | High (but annotations aren't) | Istio-specific | **Vendor-neutral** — Istio's strategic direction |
| Istio's stance | Supported, discouraged | Classic, fully featured | **Recommended going forward** |

**Rule of thumb:** for anything richer than host/path — weighted canary, header routing, mTLS passthrough, TCP — use the Istio `Gateway`/`VirtualService` pair or the Gateway API. Plain `Ingress` cannot express weighted or header-based routing portably. The Gateway API is where Istio is investing; know both for the exam.

### 2.2 `Server.tls.mode` — what the gateway does with the handshake

| `tls.mode` | Terminates TLS? | Client cert verified? | Routing key | Typical use |
|---|---|---|---|---|
| `SIMPLE` | Yes | No | HTTP host/path (post-decrypt) | Standard public HTTPS site |
| `MUTUAL` | Yes | Yes (against `caCertificates`) | HTTP host/path | B2B / partner mTLS at the edge |
| `OPTIONAL_MUTUAL` | Yes | If presented | HTTP host/path | mTLS optional, e.g. migration |
| `PASSTHROUGH` | **No** | No | **SNI only** (`spec.tls.match.sniHosts` in VS) | End-to-end TLS to the backend; gateway never sees plaintext |
| `ISTIO_MUTUAL` | Yes | Yes (Istio certs) | HTTP host/path | Gateway ↔ in-mesh, Istio-managed certs |
| `AUTO_PASSTHROUGH` | No | No | SNI | Multi-cluster east-west gateway |

Key consequence: with `PASSTHROUGH` you route on `sniHosts` in a **`tls:`** block of the `VirtualService`, not `http:` — the gateway is blind to L7. With `SIMPLE`/`MUTUAL` you route on `http:` because the payload is decrypted.

### 2.3 Egress posture: `meshConfig.outboundTrafficPolicy.mode`

| Mode | Behaviour for an **undeclared** host | Security posture | Operational cost |
|---|---|---|---|
| `ALLOW_ANY` (default) | Sidecar passthrough — connects blind | Weak: exfiltration path, no policy | Low — nothing to declare |
| `REGISTRY_ONLY` | **Blocked** unless a `ServiceEntry` exists | Strong: default-deny egress, full attribution | Higher — every external dependency must be declared |

`REGISTRY_ONLY` is the production-grade choice, but it is a **breaking change**: any external call not backed by a `ServiceEntry` starts failing (`502`/`503`). Roll it out behind an inventory of `ServiceEntry` objects and a monitored canary.

### 2.4 Egress routing paths

| Path | How | Fixed exit IP? | Policy/telemetry at exit? | Complexity |
|---|---|---|---|---|
| Sidecar passthrough (`ALLOW_ANY`) | Nothing | No | No | None |
| `ServiceEntry` only | Register host | No (per-node) | Per-sidecar only | Low |
| **Egress gateway** | `ServiceEntry` + egress `Gateway` + `VirtualService` + `DestinationRule` | **Yes** (gateway pods) | Yes (central chokepoint) | High |

Use the egress gateway when an external firewall must allow-list your source IPs, when you need TLS origination offload, or when you want one place to enforce and observe all outbound third-party traffic.

---

## 3. Complete, unabridged manifests

Assume a default Istio install with the `istio-ingressgateway` and `istio-egressgateway` deployments in `istio-system`, and an app namespace `prod` labelled for sidecar injection.

```bash
$ kubectl create namespace prod
$ kubectl label namespace prod istio-injection=enabled
```

### 3.1 Ingress — TLS termination with SDS (`SIMPLE`)

**(a) TLS secret** — must live in the **same namespace as the ingress gateway** (`istio-system`) for `credentialName` lookup, unless you enable cross-namespace secret refs.

```bash
$ kubectl create -n istio-system secret tls shop-tls-cert \
    --key=shop.example.com.key \
    --cert=shop.example.com.crt
secret/shop-tls-cert created
```

**(b) Gateway** — binds to the ingress Envoy, opens 443, redirects 80.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: shop-gateway
  namespace: prod
spec:
  selector:
    istio: ingressgateway            # matches the istio-ingressgateway pod label
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: shop-tls-cert  # Kubernetes secret in istio-system, delivered via SDS
    hosts:
    - "shop.example.com"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "shop.example.com"
    tls:
      httpsRedirect: true            # 301 all cleartext to https
```

**(c) VirtualService** — binds the gateway to a backend with a 90/10 canary and hardened retry/timeout.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: shop
  namespace: prod
spec:
  hosts:
  - "shop.example.com"
  gateways:
  - shop-gateway                     # only traffic entering via this gateway
  http:
  - match:
    - uri:
        prefix: /api
    route:
    - destination:
        host: shop-api.prod.svc.cluster.local
        subset: v1
        port:
          number: 8080
      weight: 90
    - destination:
        host: shop-api.prod.svc.cluster.local
        subset: v2
        port:
          number: 8080
      weight: 10
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,connect-failure,refused-stream
    timeout: 10s
  - route:                           # default: everything else to the web frontend
    - destination:
        host: shop-web.prod.svc.cluster.local
        port:
          number: 80
```

**(d) DestinationRule** — defines the `v1`/`v2` subsets and enforces in-mesh mTLS to the backend.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: shop-api
  namespace: prod
spec:
  host: shop-api.prod.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL             # gateway→backend uses Istio certs
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

#### Same edge, Kubernetes Gateway API form

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shop-gateway
  namespace: prod
spec:
  gatewayClassName: istio
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    hostname: "shop.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - name: shop-tls-cert
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: prod
spec:
  parentRefs:
  - name: shop-gateway
  hostnames:
  - "shop.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: shop-api
      port: 8080
      weight: 90
    - name: shop-api-v2
      port: 8080
      weight: 10
  - backendRefs:
    - name: shop-web
      port: 80
```

### 3.2 Ingress — end-to-end TLS with `PASSTHROUGH`

When the backend must terminate its own TLS (compliance, or the app owns the cert), the gateway routes on SNI only:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: passthrough-gateway
  namespace: prod
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - "secure.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: passthrough
  namespace: prod
spec:
  hosts:
  - "secure.example.com"
  gateways:
  - passthrough-gateway
  tls:                               # NOTE: tls block, not http — no L7 visibility
  - match:
    - port: 443
      sniHosts:
      - secure.example.com
    route:
    - destination:
        host: secure-backend.prod.svc.cluster.local
        port:
          number: 8443
```

### 3.3 Egress — flip the mesh to default-deny

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |-
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
```

> In practice set this via `IstioOperator`/Helm (`meshConfig.outboundTrafficPolicy.mode: REGISTRY_ONLY`) so it survives upgrades; the ConfigMap shown is what it renders to.

### 3.4 Egress — declare an external dependency with a `ServiceEntry`

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: stripe-api
  namespace: prod
spec:
  hosts:
  - api.stripe.com
  ports:
  - number: 443
    name: https
    protocol: TLS                    # keep app-originated TLS opaque; route on SNI
  resolution: DNS
  location: MESH_EXTERNAL
```

With `REGISTRY_ONLY`, this single object is the difference between the call succeeding and a `502`.

### 3.5 Egress — scope a workload's reachable set with a `Sidecar`

Beyond security, `Sidecar` resources slash the config each proxy holds (memory/CPU at scale) by pushing only the listed hosts.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: prod
spec:
  egress:
  - hosts:
    - "prod/*"                       # every service in prod
    - "istio-system/*"              # control plane + gateways
    - "prod/api.stripe.com"         # the declared external host
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY              # per-namespace default-deny, overrides mesh default
```

### 3.6 Egress — full egress gateway with TLS origination (canonical pattern)

Force plain-HTTP app traffic to `edition.cnn.com` out through `istio-egressgateway`, where Istio **originates TLS** to port 443. The app sends HTTP/80; the third party's firewall sees only the egress gateway's IPs.

**(a) ServiceEntry** — register both ports:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: cnn
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
```

**(b) Egress Gateway** — a server on port 80, gateway-internal mTLS:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: prod
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: https-port-for-tls-origination
      protocol: HTTPS
    hosts:
    - edition.cnn.com
    tls:
      mode: ISTIO_MUTUAL             # sidecar → egress gateway is Istio mTLS
```

**(c) DestinationRule for the egress gateway subset** — sets the mTLS/SNI toward the gateway:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
  namespace: prod
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: cnn
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 80
        tls:
          mode: ISTIO_MUTUAL
          sni: edition.cnn.com
```

**(d) VirtualService** — two hops: mesh → egress gateway, egress gateway → external:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway
  - mesh                             # the reserved keyword for all sidecars
  http:
  - match:
    - gateways:
      - mesh                         # traffic leaving the app sidecars
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: cnn
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway          # traffic now at the egress gateway
      port: 80
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 443               # forward to the real HTTPS port
      weight: 100
```

**(e) DestinationRule for TLS origination** — the gateway wraps the HTTP request in TLS to 443:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE                 # originate one-way TLS (use MUTUAL + client certs for mTLS)
```

---

## 4. CLI commands and real terminal output

### 4.1 Confirm gateways are healthy and get the external IP

```bash
$ kubectl -n istio-system get pods -l istio=ingressgateway
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-7d6f8c9b4c-nq2xw   1/1     Running   0          6d

$ export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ export SECURE_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
$ echo "$INGRESS_HOST:$SECURE_PORT"
203.0.113.42:443
```

### 4.2 Apply and lint before trusting anything

```bash
$ kubectl apply -f shop-ingress.yaml
gateway.networking.istio.io/shop-gateway created
virtualservice.networking.istio.io/shop created
destinationrule.networking.istio.io/shop-api created

$ istioctl analyze -n prod
✔ No validation issues found when analyzing namespace: prod.
```

A representative failure `analyze` catches early:

```bash
$ istioctl analyze -n prod
Error [IST0101] (VirtualService prod/shop) Referenced host+subset in destinationrule not found:
  "shop-api.prod.svc.cluster.local+v3"
Error: Analyzers found issues when analyzing namespace: prod.
```

### 4.3 Prove the ingress path end-to-end

```bash
$ curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}\n" \
    --resolve shop.example.com:443:$INGRESS_HOST \
    https://shop.example.com/api/products
200 0

# cleartext must 301 to https
$ curl -sI --resolve shop.example.com:80:$INGRESS_HOST http://shop.example.com/ | head -1
HTTP/1.1 301 Moved Permanently
```

### 4.4 Inspect what the ingress Envoy actually programmed

```bash
$ istioctl proxy-config listeners deploy/istio-ingressgateway -n istio-system
ADDRESSES PORT  MATCH                        DESTINATION
0.0.0.0   443   SNI: shop.example.com        Route: https.443.https.shop-gateway.prod
0.0.0.0   80    ALL                          Route: http.80.http.shop-gateway.prod
0.0.0.0   15021 ALL                          Inline Route: /healthz/ready*

$ istioctl proxy-config routes deploy/istio-ingressgateway -n istio-system \
    --name https.443.https.shop-gateway.prod -o json | \
    jq '.[0].virtualHosts[0].routes[] | {prefix:.match.prefix, cluster:.route.cluster, weight:.route.weightedClusters}'
{
  "prefix": "/api",
  "cluster": null,
  "weight": {
    "clusters": [
      { "name": "outbound|8080|v1|shop-api.prod.svc.cluster.local", "weight": 90 },
      { "name": "outbound|8080|v2|shop-api.prod.svc.cluster.local", "weight": 10 }
    ]
  }
}
```

Confirm the TLS secret reached the gateway over SDS (the #1 ingress failure):

```bash
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
RESOURCE NAME    TYPE           STATUS     VALID CERT   SERIAL NUMBER      NOT AFTER
shop-tls-cert    Cert Chain     ACTIVE     true         3a:9f:...:c1       2026-11-04T09:12:00Z
default          Cert Chain     ACTIVE     true         6b:22:...:0e       2026-08-09T00:00:00Z
```

If `shop-tls-cert` is absent or `VALID CERT` is `false`, the secret name/namespace is wrong or the PEM is malformed — the browser will get a handshake reset, not a 4xx.

### 4.5 Egress: prove default-deny, then prove the gateway path

```bash
# a pod in prod, with REGISTRY_ONLY and no ServiceEntry yet:
$ kubectl -n prod exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
502

# after applying the ServiceEntry + egress-gateway manifests:
$ kubectl apply -f cnn-egress.yaml
serviceentry.networking.istio.io/cnn created
gateway.networking.istio.io/istio-egressgateway created
destinationrule.networking.istio.io/egressgateway-for-cnn created
virtualservice.networking.istio.io/direct-cnn-through-egress-gateway created
destinationrule.networking.istio.io/originate-tls-for-edition-cnn-com created

$ kubectl -n prod exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
200
```

Confirm the request left through the egress gateway (not straight out of the sidecar):

```bash
$ kubectl -n istio-system logs deploy/istio-egressgateway | tail -1
[2026-08-08T14:07:31.402Z] "GET /politics HTTP/2" 200 - via_upstream -
  "-" 0 1088342 214 213 "10.244.2.15"
  "curl/8.5.0" "b3f1e2..." "edition.cnn.com" "151.101.65.67:443"
  outbound|443||edition.cnn.com ...
```

The presence of this line in the **egress gateway** log — with upstream `edition.cnn.com:443` — proves both the two-hop routing and TLS origination.

---

## 5. Verification and failure-diagnosis guide

Work the boundary as a pipeline. Each stage has its own tool and its own failure signature.

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| `curl` to ingress hangs / conn refused | No external IP; wrong port; gateway pod down | `kubectl -n istio-system get svc,pods -l istio=ingressgateway` | Provision LB / check `selector` matches pod labels |
| TLS handshake reset on 443 | Secret missing/wrong ns/malformed, or `credentialName` typo | `istioctl pc secret deploy/istio-ingressgateway -n istio-system` | Recreate `kubectl create secret tls` in `istio-system` |
| `404` from gateway (`server: istio-envoy`) | VS `hosts` or `gateways` mismatch; SNI ≠ VS host | `istioctl pc routes deploy/istio-ingressgateway -n istio-system` | Align VS `hosts`/`gateways`; check `--resolve`/SNI |
| `503 UH` (no healthy upstream) | Subset labels don't match pods; wrong port; no endpoints | `istioctl pc endpoints deploy/istio-ingressgateway -n istio-system \| grep shop-api` | Fix `DestinationRule` subset labels / Service port |
| PASSTHROUGH backend 404s | Routing on `http:` instead of `tls.match.sniHosts` | `istioctl pc listeners ...` (expect SNI match) | Move rules into the `tls:` block, match `sniHosts` |
| External call returns `502` | `REGISTRY_ONLY` + missing/typo'd `ServiceEntry` host | `kubectl -n prod get serviceentry`; `istioctl analyze -n prod` | Add/correct the `ServiceEntry` |
| Egress works but **skips** egress gateway | VS `mesh`→gateway hop missing; `Sidecar` egress too narrow | `istioctl pc routes deploy/sleep.prod` for the ext host | Add the mesh-match route; widen `Sidecar.egress.hosts` |
| `503` at egress gateway on TLS origination | Double TLS (app already HTTPS + origination), or SNI wrong | egress gateway logs; check `DestinationRule` `tls.mode`/`sni` | Send HTTP from app; match SNI to real host |
| Cert expired mid-flight | No rotation / cert-manager not renewing | `istioctl pc secret ...` → `NOT AFTER` | Wire cert-manager; SDS reloads without pod restart |

**The canonical diagnostic ladder for a mesh-boundary bug:**

```bash
# 1. Is the config even valid and self-consistent?
$ istioctl analyze -n prod

# 2. Did the config reach the right proxy? (control-plane sync)
$ istioctl proxy-status
NAME                                   CLUSTER   CDS   LDS   EDS   RDS   ECDS   ISTIOD          VERSION
istio-ingressgateway-...   Kubernetes  SYNCED SYNCED SYNCED SYNCED  IGNORED istiod-...   1.24.1
sleep-...prod              Kubernetes  SYNCED SYNCED SYNCED SYNCED  IGNORED istiod-...   1.24.1
#   ^ any STALE/NOT SENT here = push problem, stop and fix istiod before debugging routes.

# 3. What did Envoy actually program? (listeners → routes → clusters → endpoints)
$ istioctl proxy-config listeners <proxy>
$ istioctl proxy-config routes    <proxy>
$ istioctl proxy-config clusters  <proxy>
$ istioctl proxy-config endpoints <proxy>

# 4. Read the response flags from the access log — they name the failure.
#    UH = no healthy upstream, NR = no route, UF = upstream conn fail,
#    URX = retry limit, RBAC = authz deny.
$ kubectl -n istio-system logs deploy/istio-ingressgateway | tail -5
```

The discipline the exam rewards: **"applied" ≠ "synced" ≠ "programmed" ≠ "reachable."** `kubectl apply` proves only that etcd accepted the object. `istioctl proxy-status` proves istiod pushed it. `istioctl proxy-config` proves Envoy compiled it. Only `curl` + access-log response flags prove the request completes. Diagnose in that order and each failure class is isolated to exactly one rung.

---

## 6. References

- Istio — Ingress Gateways: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — Securing Gateways with TLS (SDS `credentialName`): https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
- Istio — Accessing External Services / `outboundTrafficPolicy`: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — Egress Gateways: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
- Istio — Egress Gateway TLS Origination: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
- Istio — TLS Origination for Egress Traffic: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio API — `Gateway`: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio API — `VirtualService`: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio API — `ServiceEntry`: https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio API — `DestinationRule` (incl. `ClientTLSSettings`): https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio API — `Sidecar`: https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — Kubernetes Gateway API support: https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/
- Istio — `istioctl proxy-config` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-proxy-config
- Istio — Envoy access-log response flags (debugging): https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Kubernetes — Gateway API (`Gateway`, `HTTPRoute`, `ReferenceGrant`): https://gateway-api.sigs.k8s.io/
- CNCF — ICA Curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf