# 2.6 Managing Traffic with the Gateway API (Gateway, HTTPRoutes)

> **Scope of this topic.** Topic 3.1 covers the Gateway API as a model: its resource hierarchy, where it came from, and how implementations differ. This topic covers the day-to-day work: building listeners, attaching routes, routing by path, header and method, rewriting and redirecting, splitting and mirroring traffic, setting timeouts, delegating across namespaces, and finding out why a route "does nothing". The main goal is to read the `status` of every resource and tell from it what the data plane is actually doing.

---

## 1. Motivation: the production problem

### 1.1 Where Ingress runs out

A mature cluster usually has one shared edge, such as a cloud load balancer and a fleet of Envoy or NGINX proxies, used by 20 to 200 application teams. With `networking.k8s.io/v1` Ingress, that setup runs into four structural problems.

1. **The spec has too few features, so annotations fill the gap.** Ingress only understands host and path. Canary weights, header matching, rewrites, redirects, timeouts and mirroring all live in controller-specific annotations such as `nginx.ingress.kubernetes.io/canary-weight`. Those annotations are untyped strings. The API server doesn't validate them, and they don't carry over to another controller. A typo is accepted without complaint and then silently ignored.
2. **Ownership has no boundary.** An Ingress mixes infrastructure concerns (TLS certificate, which load balancer to use) with application concerns (paths, backends). Any team that can create an Ingress can claim any hostname. Two teams claiming `api.example.com/` in different namespaces produce a controller-specific merge, or a "last writer wins" result.
3. **Status is thin.** `Ingress.status` has only `loadBalancer.ingress[]`. You can't tell from the API whether a rule was accepted, whether the backend Service exists, or whether a TLS secret was valid.
4. **It is HTTP only.** TCP, UDP, TLS passthrough and gRPC need separate CRDs or ConfigMaps.

### 1.2 What the Gateway API changes

The Gateway API (SIG-Network, `gateway.networking.k8s.io`) splits the edge into **role-oriented resources** with explicit attachment handshakes:

```
   Infrastructure provider          Cluster operator / platform           Application team
 ┌────────────────────────┐      ┌──────────────────────────────┐      ┌──────────────────────┐
 │ GatewayClass           │◄─────│ Gateway (namespace: infra)   │◄─────│ HTTPRoute (ns: store)│
 │ controllerName: ...    │      │  listeners: http/80,https/443│      │  parentRefs: gateway │
 │ (cluster-scoped)       │      │  allowedRoutes: selector     │      │  rules → Service     │
 └────────────────────────┘      └──────────────────────────────┘      └──────────┬───────────┘
                                                                                   │ backendRefs
                                                                        ┌──────────▼───────────┐
                                                                        │ Service / endpoints  │
                                                                        └──────────────────────┘
```

Attachment only works when **both sides agree**:

- The **route** asks to attach through `parentRefs`.
- The **Gateway** allows it through `listeners[].allowedRoutes` (which namespaces and which kinds may attach) and through `listeners[].hostname` (the route's hostnames must intersect the listener's).
- A reference that crosses namespaces to a **backend or secret** also needs a `ReferenceGrant` created by the owner of the target namespace.

Every step writes structured **conditions** back into `status`. That makes the edge debuggable with `kubectl` alone, and CKNE-style troubleshooting tasks are built on this.

### 1.3 API maturity (what you can rely on)

| Resource / feature | API version | Release channel | Notes |
|---|---|---|---|
| `GatewayClass`, `Gateway`, `HTTPRoute` | `v1` | Standard | GA since Gateway API v1.0 (Oct 2023) |
| `GRPCRoute` | `v1` | Standard | GA since v1.1 |
| `ReferenceGrant` | `v1beta1` | Standard | Stable in practice; still served as `v1beta1` |
| `HTTPRoute.rules[].timeouts` | `v1` | Standard | Promoted to Standard in v1.2 (GEP-1742) |
| `HTTPRoute.rules[].retry` | `v1` | **Experimental** | GEP-1731; needs the experimental CRDs |
| `TCPRoute`, `UDPRoute`, `TLSRoute` | `v1alpha2` | Experimental | Not part of this topic |

Every feature also has a **support level**: *Core* (every conformant implementation must support it), *Extended* (portable, but optional; check the implementation's conformance report) or *Implementation-specific*. Path matching, header matching and weighted `backendRefs` are Core. Method matching, query parameter matching, `URLRewrite`, `RequestMirror`, `ResponseHeaderModifier` and timeouts are Extended.

---

## 2. Resource model and field anatomy

### 2.1 Who owns what

| Resource | Scope | Typical owner | Decides | RBAC recommendation |
|---|---|---|---|---|
| `GatewayClass` | Cluster | Infra provider / platform | Which controller implements Gateways of this class; parameters (`parametersRef`) | Cluster admins only |
| `Gateway` | Namespace | Platform/SRE team | Ports, protocols, TLS termination, hostnames, which namespaces may attach | Platform namespace only (`infra`) |
| `HTTPRoute` | Namespace | Application team | Matching, filters, backends, weights, timeouts | App namespaces |
| `ReferenceGrant` | Namespace (target side) | Owner of the target namespace | Which foreign namespaces/kinds may reference local objects | Owner of target namespace |

### 2.2 Gateway: listeners are the contract

A Gateway is a list of **listeners**. Each listener is a tuple of `(port, protocol, hostname)` plus TLS settings and an attachment policy. The rules that matter:

- `listeners[].name` must be unique within the Gateway. Routes target a single listener through `parentRefs[].sectionName` = listener name.
- Two listeners on the same port must be distinguishable by hostname. Identical `(port, protocol, hostname)` tuples produce `Conflicted=True` with reason `HostnameConflict`. Incompatible protocols on the same port produce `ProtocolConflict`.
- `hostname` is optional. If it is absent, the listener matches every host. A leading wildcard label `*.example.com` is a **suffix match**: it matches `a.example.com` and `a.b.example.com`, but **not** `example.com`.
- `allowedRoutes.namespaces.from` is `Same` (default), `All` or `Selector`.
- `tls.mode` is `Terminate` (default for HTTPS) or `Passthrough`. `Passthrough` requires `protocol: TLS` and TLSRoute, not HTTPRoute.

### 2.3 HTTPRoute: rules, matches, filters, backends

```
HTTPRoute.spec
├── parentRefs[]        → which Gateway (and optionally which listener: sectionName / port)
├── hostnames[]         → must intersect with the listener hostname
└── rules[]
    ├── matches[]       → OR between entries; AND inside one entry
    │   ├── path        {type: Exact | PathPrefix | RegularExpression, value}
    │   ├── headers[]   {type: Exact | RegularExpression, name, value}
    │   ├── queryParams[]
    │   └── method
    ├── filters[]       → RequestHeaderModifier, ResponseHeaderModifier, RequestRedirect,
    │                      URLRewrite, RequestMirror, ExtensionRef
    ├── backendRefs[]   → {name, namespace, port, weight, filters[]}
    └── timeouts        → {request, backendRequest}
```

Semantics you have to know by heart:

- **Default match.** A rule with no `matches` behaves as `path: {type: PathPrefix, value: /}`.
- **PathPrefix is element-wise.** `/api` matches `/api`, `/api/` and `/api/v1`, but **not** `/apiv1`. A trailing slash in the match value is ignored.
- **Within one `matches[]` entry, conditions are ANDed.** Separate entries are ORed.
- **Weights are relative.** `90` and `10` means 90%. So does `9` and `1`. Weight `0` means no traffic. The default weight is `1`.
- **An invalid backend returns 500 for its share of traffic.** If a `backendRef` points to a Service that doesn't exist, or to a namespace with no `ReferenceGrant`, the implementation must return **HTTP 500** for the fraction of requests that would have gone there. It doesn't redistribute them. A Service that exists but has **no ready endpoints** usually produces **503** from the proxy (Envoy: `no healthy upstream`).
- **Incompatible filters.** `RequestRedirect` and `URLRewrite` can't be used in the same rule. A rule with `RequestRedirect` answers the request itself, so it has no `backendRefs`.

### 2.4 Match precedence (a classic exam trap)

When several rules, possibly in **different HTTPRoutes attached to the same listener**, match a request, the spec requires this ordering. Each criterion only applies to break a tie in the previous one:

1. An `Exact` path match.
2. A `PathPrefix` match with the **largest number of characters**.
3. A `method` match.
4. The **largest number of header matches**.
5. The **largest number of query-param matches**.

If the tie survives across routes, the implementation picks:

6. The **oldest Route** by `creationTimestamp`.
7. Then alphabetical order of `{namespace}/{name}`.

Within one route, a remaining tie goes to the **first matching rule in list order**.

Two consequences follow:

- A header-based canary rule (`PathPrefix /` + header) **beats** a plain `PathPrefix /` rule, whatever order you wrote them in, because it has more header matches.
- A team that creates a route claiming `PathPrefix /` on a shared hostname **does not** shadow another team's `PathPrefix /cart`, because the longer prefix wins. The oldest-route tiebreak protects existing tenants from newer conflicting routes.

---

## 3. Lab environment

The examples use **Envoy Gateway** as the implementation. Every manifest except the GatewayClass `controllerName` is portable to any conformant implementation (Istio, Cilium, NGINX Gateway Fabric, Contour, kgateway and others).

### 3.1 Install the CRDs and a controller

```bash
# Gateway API Standard channel CRDs (server-side apply: the CRDs exceed the client-side annotation limit)
$ kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io serverside-applied

$ kubectl get crd -o custom-columns=NAME:.metadata.name,BUNDLE:.metadata.annotations.gateway\\.networking\\.k8s\\.io/bundle-version,CHANNEL:.metadata.annotations.gateway\\.networking\\.k8s\\.io/channel | grep gateway
gatewayclasses.gateway.networking.k8s.io    v1.3.0   standard
gateways.gateway.networking.k8s.io          v1.3.0   standard
grpcroutes.gateway.networking.k8s.io        v1.3.0   standard
httproutes.gateway.networking.k8s.io        v1.3.0   standard
referencegrants.gateway.networking.k8s.io   v1.3.0   standard

# Controller (its Helm chart also ships Gateway API CRDs; install only one set)
$ helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 \
    -n envoy-gateway-system --create-namespace
$ kubectl -n envoy-gateway-system wait --for=condition=Available deploy/envoy-gateway --timeout=5m
deployment.apps/envoy-gateway condition met
```

> **Diagnostic habit.** The `bundle-version` and `channel` annotations on the CRDs tell you which fields the API server will **accept**. If you apply a manifest with `retry:` against Standard-channel CRDs, the API server prunes or rejects the unknown field. The route "works", but without retries.

### 3.2 Namespaces, the GatewayClass and backend workloads

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: infra
---
apiVersion: v1
kind: Namespace
metadata:
  name: store
  labels:
    gateway-access: shared
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    gateway-access: shared
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store-v1
  namespace: store
spec:
  replicas: 2
  selector:
    matchLabels:
      app: store
      version: v1
  template:
    metadata:
      labels:
        app: store
        version: v1
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0
          args:
            - "-text=store-v1"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
---
apiVersion: v1
kind: Service
metadata:
  name: store-v1
  namespace: store
spec:
  selector:
    app: store
    version: v1
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store-v2
  namespace: store
spec:
  replicas: 2
  selector:
    matchLabels:
      app: store
      version: v2
  template:
    metadata:
      labels:
        app: store
        version: v2
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0
          args:
            - "-text=store-v2"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: http
---
apiVersion: v1
kind: Service
metadata:
  name: store-v2
  namespace: store
spec:
  selector:
    app: store
    version: v2
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0
          args:
            - "-text=payments-api"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
              name: http
---
apiVersion: v1
kind: Service
metadata:
  name: payments-api
  namespace: payments
spec:
  selector:
    app: payments-api
  ports:
    - name: http
      port: 8080
      targetPort: http
```

```
$ kubectl get gatewayclass
NAME    CONTROLLER                                      ACCEPTED   AGE
envoy   gateway.envoyproxy.io/gatewayclass-controller   True       14s
```

If `ACCEPTED` stays `Unknown`, no running controller claims that `controllerName`. Check for a typo, or for a controller that isn't installed. Nothing downstream will ever be programmed.

---

## 4. The shared Gateway

### 4.1 TLS material

```bash
$ openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=*.example.com" \
    -addext "subjectAltName=DNS:*.example.com,DNS:example.com" \
    -keyout wildcard.key -out wildcard.crt
$ kubectl -n infra create secret tls wildcard-example-com --cert=wildcard.crt --key=wildcard.key
secret/wildcard-example-com created
```

### 4.2 Gateway manifest

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gw
  namespace: infra
spec:
  gatewayClassName: envoy
  listeners:
    # Plain HTTP: only accepts routes from infra itself (used for the HTTPS redirect)
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.example.com"
      allowedRoutes:
        namespaces:
          from: Same
    # HTTPS: terminates TLS, accepts HTTPRoutes from labelled tenant namespaces
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: wildcard-example-com
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: shared
        kinds:
          - group: gateway.networking.k8s.io
            kind: HTTPRoute
```

```
$ kubectl apply -f shared-gw.yaml
gateway.gateway.networking.k8s.io/shared-gw created

$ kubectl -n infra get gateway shared-gw
NAME        CLASS   ADDRESS        PROGRAMMED   AGE
shared-gw   envoy   172.18.255.200 True         41s

$ kubectl -n infra get gateway shared-gw \
    -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
http    0   Accepted=True Programmed=True ResolvedRefs=True Conflicted=False
https   0   Accepted=True Programmed=True ResolvedRefs=True Conflicted=False
```

Envoy Gateway turns the Gateway into an Envoy Deployment plus a `LoadBalancer` Service in its own namespace. Other implementations differ: Istio puts them in the Gateway's namespace, and Cilium uses its embedded Envoy.

```
$ kubectl -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=shared-gw,gateway.envoyproxy.io/owning-gateway-namespace=infra
NAME                            TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)                      AGE
envoy-infra-shared-gw-5b7c9d2e  LoadBalancer   10.96.143.12   172.18.255.200   80:31827/TCP,443:30512/TCP   44s
```

On a cluster with no LoadBalancer provider, `PROGRAMMED` may still be `True` while `ADDRESS` stays empty. In that case, port-forward to the proxy Service:

```bash
$ SVC=$(kubectl -n envoy-gateway-system get svc -o name \
    -l gateway.envoyproxy.io/owning-gateway-name=shared-gw,gateway.envoyproxy.io/owning-gateway-namespace=infra)
$ kubectl -n envoy-gateway-system port-forward "$SVC" 8080:80 8443:443
```

For the rest of the topic:

```bash
$ export GW_IP=$(kubectl -n infra get gateway shared-gw -o jsonpath='{.status.addresses[0].value}')
```

### 4.3 Attachment models: trade-offs

| `allowedRoutes.namespaces.from` | Who can attach | Strength | Risk | Typical use |
|---|---|---|---|---|
| `Same` (default) | Routes in the Gateway's namespace only | Maximum control | Platform team becomes a ticket queue | Redirect routes, per-team Gateways |
| `Selector` | Namespaces whose labels match | Delegation controlled by namespace labels | Whoever can label namespaces can attach; restrict `namespaces` patch RBAC | Shared multi-tenant edge |
| `All` | Any namespace | Zero friction | Any tenant can claim any hostname within the listener | Dev clusters only |

| Topology | Isolation | Cost | Blast radius | Operational note |
|---|---|---|---|---|
| One shared Gateway, many routes | Logical (hostname and allowedRoutes) | 1 LB, 1 proxy fleet | A bad config push or overload hits all tenants | Needs precedence discipline |
| One Gateway per team | Strong (separate proxy fleets) | N load balancers | Contained per team | More IPs, more certs |
| One Gateway per environment/zone | Medium | Moderate | Per environment | Common compromise |

---

## 5. Traffic management patterns

### 5.1 HTTP → HTTPS redirect (owned by the platform)

The route lives in `infra`, because only `infra` may attach to the `http` listener. It binds explicitly to that listener with `sectionName`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: infra
spec:
  parentRefs:
    - name: shared-gw
      sectionName: http
  hostnames:
    - "*.example.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

```
$ curl -sI --resolve shop.example.com:80:$GW_IP http://shop.example.com/cart?id=7
HTTP/1.1 301 Moved Permanently
location: https://shop.example.com/cart?id=7
date: Wed, 30 Sep 2026 10:14:02 GMT
content-length: 0
```

The path and query string are preserved. When `scheme` changes and `port` is omitted, the redirect uses the scheme's well-known port (443), so the `Location` header has no port.

### 5.2 Host and path routing with a prefix rewrite

The application team routes `shop.example.com`. Requests to `/store/*` go to `store-v1` with the `/store` prefix removed, because the backend serves at `/`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: store-v1
          port: 80
    - matches:
        - path:
            type: Exact
            value: /healthz
      filters:
        - type: RequestRedirect
          requestRedirect:
            path:
              type: ReplaceFullPath
              replaceFullPath: /store/
            statusCode: 302
```

```
$ kubectl -n store get httproute shop
NAME   HOSTNAMES              AGE
shop   ["shop.example.com"]   9s

$ curl -sk --resolve shop.example.com:443:$GW_IP https://shop.example.com/store/items
store-v1

$ curl -skI --resolve shop.example.com:443:$GW_IP https://shop.example.com/healthz | head -2
HTTP/2 302
location: https://shop.example.com/store/
```

Rules of thumb:

- `ReplacePrefixMatch` is only valid on a rule whose match is `PathPrefix`. The implementation rejects it on an `Exact` or `RegularExpression` match (`Accepted=False`, reason `UnsupportedValue`).
- `hostname` inside `urlRewrite` rewrites the `Host` header sent upstream. This is useful when the backend is a virtual-hosted service.

### 5.3 Header- and method-based canary

Internal testers send `x-canary: true` and get v2. Everyone else stays on v1. `POST` requests to `/store/checkout` are pinned to v1, whatever the header says.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-canary
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
          headers:
            - type: Exact
              name: x-canary
              value: "true"
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: store-v2
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /store/checkout
          method: POST
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: store-v1
          port: 80
```

Work through the precedence. This route and the `shop` route from 5.2 both target the same listener and hostname, so their rules merge into one routing table:

| Request | Candidate matches | Winner | Why |
|---|---|---|---|
| `GET /store/items` | `shop` `/store` | `store-v1` | Only match |
| `GET /store/items` + `x-canary: true` | `shop` `/store`; canary `/store` + header | `store-v2` | Same prefix length; more header matches |
| `POST /store/checkout` + `x-canary: true` | `/store`; `/store` + header; `/store/checkout` + POST | `store-v1` | Longest prefix (`/store/checkout`) wins **before** method or headers are considered |

```
$ curl -sk --resolve shop.example.com:443:$GW_IP https://shop.example.com/store/items
store-v1
$ curl -sk --resolve shop.example.com:443:$GW_IP -H 'x-canary: true' https://shop.example.com/store/items
store-v2
$ curl -sk --resolve shop.example.com:443:$GW_IP -H 'x-canary: true' -X POST https://shop.example.com/store/checkout
store-v1
```

> The third result catches people out. If the checkout path must also follow the canary header, add a rule with `/store/checkout` + `POST` + header. It then has the longest prefix, a method and a header, so it wins.

### 5.4 Weighted traffic split (progressive delivery)

Replace the single backend in the `shop` rule with a weighted pair. Promote by editing the weights: 100/0 → 90/10 → 50/50 → 0/100.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /store
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: store-v1
          port: 80
          weight: 90
        - name: store-v2
          port: 80
          weight: 10
```

```
$ for i in $(seq 1 200); do
    curl -sk --resolve shop.example.com:443:$GW_IP https://shop.example.com/store/
  done | sort | uniq -c
    181 store-v1
     19 store-v2
```

A split is statistical. Expect about ±3% noise at 200 requests. Weighting is **per request**, not per user. If the session must stay on one version, route on a header or cookie (5.3) instead. An implementation may also offer session persistence, which is still experimental in the Gateway API (GEP-1619).

Patch the weights in place during a rollout:

```bash
$ kubectl -n store patch httproute shop --type=json -p='[
  {"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},
  {"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}]'
httproute.gateway.networking.k8s.io/shop patched
```

Progressive delivery controllers such as Argo Rollouts (Gateway API plugin) and Flagger automate exactly this patch, gated on metrics.

### 5.5 Request mirroring (shadow traffic)

Copy live traffic to v2 to validate it under real load. Responses from the mirror are **discarded**, so clients only ever see the primary backend's answer.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-shadow
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - shadow.example.com
  rules:
    - filters:
        - type: RequestMirror
          requestMirror:
            backendRef:
              name: store-v2
              port: 80
      backendRefs:
        - name: store-v1
          port: 80
```

```
$ curl -sk --resolve shadow.example.com:443:$GW_IP https://shadow.example.com/
store-v1
$ kubectl -n store logs -l version=v2 --tail=2 --prefix
[pod/store-v2-7c9f8d5b6-x2kqm/echo] 2026/09/30 10:21:07 shadow.example.com-shadow 10.244.1.17:48122 "GET / HTTP/1.1" 200 9 "curl/8.9.1" 26.1µs
```

Envoy appends `-shadow` to the `Host` of mirrored requests, which lets the backend tell mirrored traffic apart.

**Production warning.** Mirrored non-idempotent requests (`POST /charge`) **run for real** on the shadow backend. Mirror only read paths, or make sure the shadow writes to a sandboxed datastore.

### 5.6 Header manipulation

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-headers
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - api.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: x-tenant
                value: store
            add:
              - name: x-forwarded-by
                value: shared-gw
            remove:
              - x-debug-token
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - name: strict-transport-security
                value: "max-age=31536000; includeSubDomains"
            remove:
              - server
      backendRefs:
        - name: store-v1
          port: 80
```

- `set` overwrites the header, `add` appends to it, and `remove` deletes it.
- The request filter keeps clients from spoofing `x-tenant`, because `set` overwrites whatever the client sent.
- The `strict-transport-security` value contains `; `, so it is quoted. YAML would parse this one unquoted, but quoting header values is a safe habit.

`filters` can also go **on an individual `backendRef`**. Those filters apply only to requests sent to that backend. For example, tag canary traffic with `x-version: v2` only on the v2 `backendRef`.

### 5.7 Timeouts

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments-timeouts
  namespace: payments
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - pay.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      timeouts:
        request: 10s
        backendRequest: 3s
      backendRefs:
        - name: payments-api
          port: 8080
```

| Field | Covers | Timeout response |
|---|---|---|
| `timeouts.request` | Whole client request, from the gateway receiving it to the response, including any retries | Gateway returns 504 |
| `timeouts.backendRequest` | A single attempt from the gateway to the backend | That attempt fails. With retries configured, another attempt may follow |

Constraint: `backendRequest` ≤ `request`. The API rejects an inversion through CEL validation. Setting `0s` disables the timeout. Retries (`rules[].retry`: `codes`, `attempts`, `backoff`) are Experimental-channel only. Without them, the Standard-channel way to get retries is the implementation's own policy CRD (for example Envoy Gateway's `BackendTrafficPolicy`).

### 5.8 Cross-namespace backends: ReferenceGrant

The `store` team wants `shop.example.com/pay` to go directly to the Service in `payments`. The route references a foreign Service, so the **payments** team has to allow it:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-pay
  namespace: store
spec:
  parentRefs:
    - name: shared-gw
      namespace: infra
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /pay
      backendRefs:
        - name: payments-api
          namespace: payments
          port: 8080
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-store-routes
  namespace: payments
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: store
  to:
    - group: ""
      kind: Service
      name: payments-api
```

The three cross-namespace mechanisms are often confused:

| Reference | Direction | Authorized by | Lives in |
|---|---|---|---|
| Route → Gateway (`parentRefs`) | App ns → infra ns | `Gateway.listeners[].allowedRoutes` | Gateway |
| Route → Service (`backendRefs`) | App ns → other app ns | `ReferenceGrant` (`from: HTTPRoute`, `to: Service`) | Target (Service) namespace |
| Gateway → Secret (`certificateRefs`) | infra ns → cert ns | `ReferenceGrant` (`from: Gateway`, `to: Secret`) | Target (Secret) namespace |

A `ReferenceGrant` is a one-way handshake: the owner of the **target** namespace opts in. Deleting it revokes access immediately. The route goes to `ResolvedRefs=False` and requests to it get 500.

---

## 6. Technical comparisons

### 6.1 Ingress vs Gateway API for traffic management

| Capability | Ingress (`networking.k8s.io/v1`) | Gateway API (`HTTPRoute`) |
|---|---|---|
| Host / path routing | Spec (`Prefix`, `Exact`, `ImplementationSpecific`) | Spec (`PathPrefix`, `Exact`, `RegularExpression`) |
| Header / query / method match | Annotations (controller-specific) | Spec (Core / Extended) |
| Weighted split | Annotations (e.g. a second "canary" Ingress) | `backendRefs[].weight` |
| Redirect / rewrite | Annotations | `RequestRedirect`, `URLRewrite` filters |
| Mirroring | Annotations or not available | `RequestMirror` filter |
| Timeouts | Annotations | `rules[].timeouts` |
| Cross-namespace backends | Not supported | `ReferenceGrant` |
| Role separation | None (one object) | GatewayClass / Gateway / Route |
| Status | LB address only | Per-parent `Accepted`, `ResolvedRefs`; per-listener `attachedRoutes` |
| Portability | Low beyond basic routing | Conformance-tested per feature |

Migrating existing Ingress objects: `ingress2gateway` (kubernetes-sigs) converts Ingress resources and common NGINX annotations to Gateway API manifests. Always review what it produces.

### 6.2 Traffic-shifting techniques

| Technique | Selector | Deterministic per client? | Blast radius | Rollback | Best for |
|---|---|---|---|---|---|
| Header match (5.3) | Explicit header / cookie | Yes | Only opted-in clients | Delete rule | Internal dogfooding, QA |
| Weighted split (5.4) | Random per request | No | % of all traffic | Set weight 0 | Progressive rollout under real traffic |
| Mirror (5.5) | All matching requests (copied) | N/A (no response to client) | None for clients; full load on shadow | Remove filter | Load/regression validation before cut-over |
| Separate hostname | DNS / Host | Yes | Only callers of new host | DNS/route change | API version coexistence |

### 6.3 Filter compatibility

| Filter | Support | Placement | Compatible with `backendRefs` in same rule? | Notes |
|---|---|---|---|---|
| `RequestHeaderModifier` | Core | rule, backendRef | Yes | max 16 entries per set/add/remove |
| `ResponseHeaderModifier` | Extended | rule, backendRef | Yes | |
| `RequestRedirect` | Core | rule | No (gateway answers directly) | Incompatible with `URLRewrite` |
| `URLRewrite` | Extended | rule, backendRef | Yes | `ReplacePrefixMatch` needs a `PathPrefix` match |
| `RequestMirror` | Extended | rule, backendRef | Yes | Mirror responses are discarded |
| `ExtensionRef` | Implementation-specific | rule, backendRef | Depends | Points to an implementation CRD |

---

## 7. Verification and failure diagnosis

### 7.1 The status chain: read top-down

```
GatewayClass   .status.conditions         Accepted
      │
Gateway        .status.conditions         Accepted, Programmed
               .status.addresses[]        (data-plane address)
      │
Listener       .status.listeners[]        Accepted, Programmed, ResolvedRefs, Conflicted
               .attachedRoutes            (count of routes bound to this listener)
      │
HTTPRoute      .status.parents[]          one entry PER parentRef, written by the controller
               .conditions                Accepted, ResolvedRefs
      │
Service        EndpointSlices             ready endpoints
```

### 7.2 Conditions and reasons reference

| Object | Condition | Bad value + reason | Meaning | Fix |
|---|---|---|---|---|
| GatewayClass | `Accepted` | `Unknown` (no reason update) | No controller owns `controllerName` | Install controller / fix name |
| Gateway | `Accepted` | `False` / `InvalidParameters`, `UnsupportedAddress` | Bad `spec.addresses` or class params | Fix spec |
| Gateway | `Programmed` | `False` / `AddressNotAssigned` | Data plane has no address (no LB provider, IP pool exhausted) | LB provider, MetalLB pool, `addresses` |
| Listener | `ResolvedRefs` | `False` / `InvalidCertificateRef` | Secret missing, wrong type, or bad PEM | Recreate `kubernetes.io/tls` secret |
| Listener | `ResolvedRefs` | `False` / `RefNotPermitted` | Secret in another ns without ReferenceGrant | ReferenceGrant `from: Gateway` |
| Listener | `ResolvedRefs` | `False` / `InvalidRouteKinds` | `allowedRoutes.kinds` lists an unsupported kind | Fix kinds |
| Listener | `Conflicted` | `True` / `HostnameConflict`, `ProtocolConflict` | Two listeners clash on port/hostname/protocol | Distinct hostnames or ports |
| HTTPRoute | `Accepted` | `False` / `NotAllowedByListeners` | Namespace not permitted by `allowedRoutes` | Label ns / change `from` |
| HTTPRoute | `Accepted` | `False` / `NoMatchingListenerHostname` | Route hostnames don't intersect listener hostname | Fix `hostnames` |
| HTTPRoute | `Accepted` | `False` / `NoMatchingParent` | `sectionName`/`port` names no listener | Fix `sectionName` |
| HTTPRoute | `Accepted` | `False` / `UnsupportedValue` | A match/filter the implementation doesn't support | Check conformance / change filter |
| HTTPRoute | `ResolvedRefs` | `False` / `BackendNotFound` | Service doesn't exist | Create Service / fix name, port |
| HTTPRoute | `ResolvedRefs` | `False` / `RefNotPermitted` | Cross-ns backend without ReferenceGrant | Add ReferenceGrant in target ns |
| HTTPRoute | `ResolvedRefs` | `False` / `InvalidKind` | `backendRefs` kind not supported | Use `Service` |
| HTTPRoute | *(no `status.parents` at all)* | none | No controller recognizes the parent (Gateway doesn't exist in the referenced ns, or its class isn't owned by any controller) | Fix `parentRefs[].namespace` / name |

### 7.3 A diagnostic runbook

**Step 1: Is the class accepted and the Gateway programmed?**

```
$ kubectl get gatewayclass,gateway -A
NAME                                     CONTROLLER                                      ACCEPTED   AGE
gatewayclass.gateway.networking.k8s.io/envoy  gateway.envoyproxy.io/gatewayclass-controller  True   2h

NAMESPACE   NAME                                          CLASS   ADDRESS          PROGRAMMED   AGE
infra       gateway.gateway.networking.k8s.io/shared-gw   envoy   172.18.255.200   True         2h
```

**Step 2: Are routes attaching to the listener you expect?**

```
$ kubectl -n infra get gateway shared-gw \
    -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\n"}{end}'
http    1
https   4
```

If you just created a route and the count didn't go up, the route was rejected. Go to Step 3.

**Step 3: Read the route's parent status.**

```bash
$ kubectl -n store get httproute shop-pay \
    -o jsonpath='{range .status.parents[*]}{.parentRef.name}/{.parentRef.sectionName}{"\n"}{range .conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}{end}'
shared-gw/https
  Accepted=True Accepted: Route is accepted
  ResolvedRefs=False RefNotPermitted: Backend ref to Service payments/payments-api not permitted by any ReferenceGrant
```

The same data as YAML (`kubectl -n store get httproute shop-pay -o yaml`, status section):

```yaml
status:
  parents:
    - parentRef:
        group: gateway.networking.k8s.io
        kind: Gateway
        name: shared-gw
        namespace: infra
        sectionName: https
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
      conditions:
        - type: Accepted
          status: "True"
          reason: Accepted
          message: Route is accepted
          observedGeneration: 1
          lastTransitionTime: "2026-09-30T10:12:44Z"
        - type: ResolvedRefs
          status: "False"
          reason: RefNotPermitted
          message: "Backend ref to Service payments/payments-api not permitted by any ReferenceGrant"
          observedGeneration: 1
          lastTransitionTime: "2026-09-30T10:12:44Z"
```

The data plane confirms the spec's "500 for invalid backends" behaviour:

```
$ curl -sk -o /dev/null -w '%{http_code}\n' --resolve shop.example.com:443:$GW_IP https://shop.example.com/pay
500
```

`Accepted=True` together with `ResolvedRefs=False` means the route **is** in the proxy config, but the broken backend's share of traffic returns 500. Always check both conditions. `Accepted=True` alone doesn't mean it works.

**Step 4: Check that `observedGeneration` is current.** If `metadata.generation` is higher than the conditions' `observedGeneration`, the controller hasn't processed your latest edit yet. The controller may be down, stuck, or leader-election may be failing.

```
$ kubectl -n store get httproute shop -o jsonpath='{.metadata.generation}{" vs "}{.status.parents[0].conditions[0].observedGeneration}{"\n"}'
4 vs 4
```

**Step 5: Check the backends' endpoints.**

```
$ kubectl -n store get endpointslices -l kubernetes.io/service-name=store-v2
NAME             ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
store-v2-8xkq2   IPv4          8080    10.244.1.17,10.244.2.9    2h
```

An empty `ENDPOINTS` column (a readiness probe failing, or a label selector mismatch) produces **503** at the gateway while every Gateway API condition stays green. This is the most common "all green but broken" case.

**Step 6: Test from outside with the right Host/SNI.**

```bash
# --resolve sets both the SNI and the Host header; -H 'Host:' alone does NOT set SNI over TLS
$ curl -skv --resolve shop.example.com:443:$GW_IP https://shop.example.com/store/ 2>&1 | grep -E '^(< HTTP|\* SSL connection|\*  subject)'
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
*  subject: CN=*.example.com
< HTTP/2 200
```

A `404` with no body from the gateway means **no route matched** the (host, path, headers) tuple. The request reached the proxy, but no rule claimed it. Compare what you sent against the `hostnames` and `matches`.

**Step 7: Controller and data-plane logs.**

```bash
$ kubectl -n envoy-gateway-system logs deploy/envoy-gateway --since=10m | grep -iE 'error|invalid|httproute'
$ kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=shared-gw -c envoy --tail=20
```

Envoy access logs show `response_flags`. `NR` means no route, `UH` means no healthy upstream, and `UT` means upstream timeout. That maps straight onto 404, 503 and 504.

### 7.4 Failure scenarios (symptom → cause)

| Symptom | Evidence | Root cause |
|---|---|---|
| `curl` returns 404 for a new route | `attachedRoutes` unchanged; route `Accepted=False NotAllowedByListeners` | Namespace missing label `gateway-access: shared` |
| Route accepted on `http` but you meant `https` | `status.parents[].parentRef.sectionName: http` | Missing `sectionName`: route attached to **every** listener that allows it |
| 404 for `example.com` but works for `www.example.com` | `NoMatchingListenerHostname` | `*.example.com` does not match the apex; add a listener or hostname for `example.com` |
| 10% of requests return 500 | `ResolvedRefs=False BackendNotFound` | Typo in canary Service name in the weighted pair |
| All requests 503 | Conditions green, EndpointSlice empty | Pods not Ready / selector mismatch |
| Intermittent 504 on slow endpoint | Envoy `UT` flag | `timeouts.backendRequest` shorter than backend p99 |
| Canary header ignored on one path | Longer-prefix rule without header | Precedence: longest prefix beats header count |
| Route has no `status` at all | `status: {}` | `parentRefs[].namespace` omitted: it defaults to the **route's** namespace, where no Gateway exists |
| HTTPS listener `Programmed=False` | Listener `InvalidCertificateRef` | Secret type `Opaque` instead of `kubernetes.io/tls`, or key/cert mismatch |
| Change to `retry:` field has no effect | Field missing in `kubectl get -o yaml` | Standard-channel CRDs pruned the Experimental field |

---

## 8. Condensed exam checklist

- Know the attachment triangle: `parentRefs` (route) + `allowedRoutes` and `hostname` (listener) + `ReferenceGrant` (target namespace, for backends and secrets).
- Always set `parentRefs[].namespace` when the Gateway is in another namespace, and `sectionName` when you want a single listener.
- Write matches remembering that AND applies inside an entry and OR applies across entries. Predict the winner with the precedence rules: Exact > longest prefix > method > headers > query params > oldest route > name.
- Redirect: `RequestRedirect` with no `backendRefs`. Rewrite: `URLRewrite` with `ReplacePrefixMatch` on a `PathPrefix` match. Never both in one rule.
- A split is `backendRefs[].weight`. Mirroring is a filter whose responses are discarded.
- Debug in order: GatewayClass `Accepted` → Gateway `Programmed` + address → listener conditions + `attachedRoutes` → route `Accepted` **and** `ResolvedRefs` → EndpointSlices → `curl --resolve`.
- HTTP codes to recognize: 404 means no route matched; 500 means an invalid backend reference; 503 means no ready endpoints; 504 means a timeout.

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes documentation: Gateway API: https://kubernetes.io/docs/concepts/services-networking/gateway/
- Gateway API: API overview and roles: https://gateway-api.sigs.k8s.io/docs/concepts/api-overview/
- Gateway API: security model and role separation: https://gateway-api.sigs.k8s.io/concepts/security-model/
- Gateway API: `Gateway` resource: https://gateway-api.sigs.k8s.io/reference/api-types/gateway/
- Gateway API: `HTTPRoute` resource (matching, filters, precedence): https://gateway-api.sigs.k8s.io/reference/api-types/httproute/
- Gateway API: `ReferenceGrant`: https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
- Gateway API: full API specification (conditions and reasons): https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
- Gateway API guide: HTTP routing: https://gateway-api.sigs.k8s.io/guides/http-routing/
- Gateway API guide: HTTP redirects and rewrites: https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/
- Gateway API guide: HTTP header modifiers: https://gateway-api.sigs.k8s.io/guides/http-header-modifier/
- Gateway API guide: traffic splitting: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/
- Gateway API guide: HTTP request mirroring: https://gateway-api.sigs.k8s.io/guides/http-request-mirroring/
- Gateway API guide: cross-namespace routing: https://gateway-api.sigs.k8s.io/guides/multiple-ns/
- Gateway API guide: TLS: https://gateway-api.sigs.k8s.io/guides/tls/
- Gateway API guide: migrating from Ingress: https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/
- GEP-1742: HTTPRoute timeouts: https://gateway-api.sigs.k8s.io/geps/gep-1742/
- GEP-1731: HTTPRoute retries: https://gateway-api.sigs.k8s.io/geps/gep-1731/
- Gateway API: conformance and support levels: https://gateway-api.sigs.k8s.io/docs/concepts/conformance/
- Gateway API: implementations list: https://gateway-api.sigs.k8s.io/implementations/
- Gateway API releases (CRD bundles): https://github.com/kubernetes-sigs/gateway-api/releases
- ingress2gateway: https://github.com/kubernetes-sigs/ingress2gateway
- Envoy Gateway documentation: https://gateway.envoyproxy.io/docs/