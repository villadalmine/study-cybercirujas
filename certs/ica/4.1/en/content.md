# 4.1 Configuring Authorization

> Domain 4 — Securing Workloads · Exam weight: 9
> Scope: Istio `AuthorizationPolicy` (L7 HTTP RBAC and L4 network RBAC), its interaction with `PeerAuthentication` / `RequestAuthentication`, `CUSTOM` external authorization, and enforcement in both sidecar and ambient data planes.

---

## 1. The production problem: identity-aware access control inside the mesh

In a Kubernetes cluster, the classic access-control primitive is the `NetworkPolicy`: it filters on pod/namespace selectors and IP CIDRs at L3/L4. That model breaks down for three reasons that matter in production:

1. **Pod IPs are ephemeral and non-identifying.** A `NetworkPolicy` that "allows the `payments` service" really allows *whatever pod currently holds a matching label and IP*. A compromised pod, an IP reuse, or a spoofed source defeats it. There is no cryptographic proof of *who* the caller is.
2. **The interesting policy is at L7.** "`checkout` may call `POST /charge` but not `DELETE /accounts/*`" cannot be expressed with IP/port rules. You need method, path, host, header, and JWT-claim awareness.
3. **Enforcement should be local and distributed.** A central policy decision point (PDP) that every request must traverse is a latency tax and a single point of failure.

Istio solves this with **workload identity + local enforcement**:

- Every workload receives a **SPIFFE identity** encoded in an X.509 SVID, minted by istiod and rotated automatically. The identity string is `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>` (e.g. `spiffe://cluster.local/ns/foo/sa/sleep`). This is the *principal*.
- **Mutual TLS** (via `PeerAuthentication`) proves that identity on every connection. Without mTLS, the peer principal is empty and identity-based rules cannot match.
- **Authorization is enforced by the Envoy sidecar (or ztunnel/waypoint in ambient), on the inbound path of the destination**, using Envoy's RBAC filter. istiod compiles each `AuthorizationPolicy` into Envoy RBAC config and pushes it via xDS. There is **no central PDP in the request path** — each proxy decides locally in microseconds.

```
                         istiod (control plane)
                 compiles AuthorizationPolicy -> Envoy RBAC/ext_authz config
                                     │ xDS
        ┌────────────────────────────┼────────────────────────────┐
        ▼                                                           ▼
  ┌───────────┐   mTLS (SPIFFE SVID)          inbound RBAC   ┌───────────┐
  │  sleep    │ ────────────────────────────────────────▶   │  httpbin  │
  │  sidecar  │   principal:                                 │  sidecar  │  ── enforce ──▶ app
  └───────────┘   cluster.local/ns/foo/sa/sleep              └───────────┘   (allow/deny)
```

This is the zero-trust posture the ICA exam tests: **authenticate the peer (mTLS), authenticate the end-user (JWT), then authorize the request (AuthorizationPolicy) — as close to the workload as possible.**

---

## 2. The `AuthorizationPolicy` model

### 2.1 CRD anatomy

```yaml
apiVersion: security.istio.io/v1        # v1beta1 still accepted, v1 is current
kind: AuthorizationPolicy
metadata:
  name: <name>
  namespace: <ns>                       # placement defines default scope (see 2.3)
spec:
  # WHERE it applies (pick at most one binding style):
  selector:                             # sidecar/ztunnel workloads, by label
    matchLabels:
      app: httpbin
  # targetRefs:                         # Gateway API / waypoint binding (ambient, gateways)
  #   - group: gateway.networking.k8s.io
  #     kind: Gateway
  #     name: my-waypoint

  action: ALLOW                         # ALLOW (default) | DENY | AUDIT | CUSTOM
  # provider:                           # required only for action: CUSTOM
  #   name: <extensionProvider-name>

  rules:                                # list; a request matches the policy if ANY rule matches
    - from:                             # SOURCE identity (matched with OR across list, AND within)
        - source:
            principals: ["cluster.local/ns/foo/sa/sleep"]   # mTLS peer identity (SPIFFE, no "spiffe://")
            requestPrincipals: ["<iss>/<sub>"]              # end-user identity from a validated JWT
            namespaces: ["foo"]                              # peer namespace (requires mTLS)
            ipBlocks: ["10.0.0.0/8"]                         # directly-connected source IP
            remoteIpBlocks: ["203.0.113.0/24"]               # original client IP from XFF (trusted proxies)
            # not* variants exist for every field above
      to:                               # OPERATION (L7)
        - operation:
            hosts: ["httpbin.foo.svc.cluster.local"]
            ports: ["8000"]
            methods: ["GET", "POST"]
            paths: ["/api/*", "/status/*"]
            # notHosts / notPorts / notMethods / notPaths
      when:                             # CONDITIONS on request attributes
        - key: request.auth.claims[groups]
          values: ["admin", "sre"]
        - key: request.headers[x-internal]
          values: ["true"]
```

**Matching semantics (memorize this):**

- Within a single `source`/`operation`/`when` block, fields are **AND**-ed.
- Values inside one field's list are **OR**-ed.
- Multiple `from`/`to`/`when` entries in one rule are **AND**-ed across categories but **OR**-ed within a category list.
- Multiple `rules` are **OR**-ed: the policy matches if *any* rule matches.
- An **empty rule `{}` matches every request**; an **empty `spec: {}` has zero rules and matches nothing.**

### 2.2 Actions and the evaluation order

Istio evaluates the actions in a **fixed layered order**, and the first layer to reach a decision wins:

```
   request
     │
     ▼
 ┌─────────┐  deny         ┌────────┐ deny      ┌────────┐  no ALLOW policy exists?
 │ CUSTOM  │──────────────▶│  DENY  │──────────▶│ ALLOW  │───── yes ──▶ ALLOW (default open)
 │(ext_authz)│  allow ──┐  │        │  allow ──┐│        │      no  ──▶ match? yes→ALLOW / no→DENY
 └─────────┘          └───▶└────────┘        └──▶└────────┘
```

1. **CUSTOM** policies are checked first (delegated to an external authorizer). A `deny` here is final.
2. **DENY** policies next. If any matches → request denied.
3. **ALLOW** policies last. If ALLOW policies exist for the workload and *none* match → denied. If one matches → allowed.
4. If **no ALLOW/DENY/CUSTOM** policy applies to the workload → **allowed by default** (open mesh).

The critical, exam-favourite corner cases:

| Intent | `spec` | Behaviour |
|---|---|---|
| **Deny everything** (baseline) | `spec: {}` (action defaults to ALLOW, 0 rules) | Nothing matches an ALLOW → **all requests denied** |
| Explicit deny-all | `action: DENY`, `rules: [{}]` | Empty rule matches all → **all denied** |
| Allow-all | `action: ALLOW`, `rules: [{}]` | Empty rule matches all → **all allowed** |
| Require valid JWT (any user) | `action: ALLOW`, `from.source.requestPrincipals: ["*"]` | Only requests carrying a validated token pass |

> **Trap:** placing `spec: {}` in the root namespace (`istio-system`) creates a **mesh-wide deny-all**. This is the recommended zero-trust baseline, but applied carelessly it will black-hole the entire mesh, including probes and telemetry paths that traverse the proxy.

### 2.3 Scope (placement precedence)

| Placement | `selector`/`targetRefs`? | Scope |
|---|---|---|
| Root namespace (`istio-system`) | none | **Entire mesh** |
| Root namespace | present | Selected workloads across mesh |
| Workload namespace | none | **All workloads in that namespace** |
| Workload namespace | `selector` present | **Only matching workloads** |

DENY and ALLOW at different scopes compose according to §2.2 (DENY still wins over ALLOW regardless of scope).

### 2.4 Trade-off tables

**Actions**

| Action | Precedence | Enforcement | Typical use | Failure mode to watch |
|---|---|---|---|---|
| `ALLOW` | 3rd | Local RBAC | Allowlist a set of callers/operations | Presence of *any* ALLOW makes the workload deny-by-default for that scope — an incomplete allowlist locks out valid traffic |
| `DENY` | 2nd | Local RBAC | Blocklist (e.g. block `DELETE`) | Negative fields (`notPaths`) invert logic and are easy to write insecurely |
| `AUDIT` | side-channel | Marks request for audit; **no allow/deny effect** | Dry-run a rule before enforcing | Requires an audit-capable provider; otherwise it is silently inert |
| `CUSTOM` | 1st | Delegates to ext_authz service | OPA, oauth2-proxy, OIDC, corporate PDP | Adds a network hop and a `failOpen`/`failClosed` decision on the sidecar |

**Layer of enforcement**

| Dimension | L4 network RBAC (`envoy.filters.network.rbac`) | L7 HTTP RBAC (`envoy.filters.http.rbac`) |
|---|---|---|
| Fields supported | principals, namespaces, ipBlocks, ports, SNI | + methods, paths, hosts, headers, JWT claims, `request.auth.*` |
| Requires protocol detection | No (TCP/mTLS) | Yes (HTTP/HTTPS with L7 parsing) |
| Sidecar mode | ✅ | ✅ |
| Ambient — **ztunnel** | ✅ (L4 only) | ❌ |
| Ambient — **waypoint** | ✅ | ✅ (waypoint required for L7 rules) |

**Identity source in `from.source`**

| Field | Origin | Prerequisite | Trust boundary |
|---|---|---|---|
| `principals` | mTLS peer SVID (SPIFFE) | `PeerAuthentication` STRICT/PERMISSIVE with mTLS present | Strong (cryptographic) |
| `namespaces` | mTLS peer SVID | mTLS | Strong |
| `requestPrincipals` | Validated JWT (`<iss>/<sub>`) | `RequestAuthentication` present | Strong (signed token) |
| `ipBlocks` | L3 packet source IP | none | Weak (spoofable; at a gateway this is the LB/node IP) |
| `remoteIpBlocks` | Original client IP from `X-Forwarded-For` | Gateway configured with `numTrustedProxies`/`externalTrafficPolicy: Local` | Only as strong as your proxy chain |

**Where Istio authz fits vs. neighbours**

| Control | Layer | Identity | Granularity |
|---|---|---|---|
| Kubernetes `NetworkPolicy` | L3/L4 | Pod labels / IP | Namespace/pod, port |
| Istio `AuthorizationPolicy` (L4) | L4 | SPIFFE peer identity | Service account, namespace, port |
| Istio `AuthorizationPolicy` (L7) | L7 | Peer + end-user (JWT) | Method, path, host, claim |
| API-gateway/ext_authz (`CUSTOM`) | L7 | Delegated | Arbitrary (OPA policy, session) |

Use them together (defense in depth): `NetworkPolicy` as a coarse L3 fence, Istio L4 for identity, Istio L7 for operation-level rules, `CUSTOM` when you need business logic the CRD cannot express.

---

## 3. Complete manifests

The examples target a namespace `foo` running the standard `httpbin` (server) and `sleep` (client) samples, with mesh-wide STRICT mTLS. All manifests are complete and syntactically valid.

### 3.1 mTLS prerequisite and zero-trust baseline

```yaml
# 00-peer-strict.yaml — require mTLS everywhere (principals depend on this)
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system          # root namespace => mesh-wide
spec:
  mtls:
    mode: STRICT
---
# 01-deny-all.yaml — mesh-wide default-deny (zero trust baseline)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}                            # 0 rules => nothing satisfies ALLOW => deny everything
```

### 3.2 Least-privilege ALLOW (peer identity + operation + condition)

```yaml
# 02-allow-sleep-get.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-allow-sleep
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/foo/sa/sleep"]   # only the sleep SA
      to:
        - operation:
            methods: ["GET"]
            paths: ["/get", "/status/*"]
      when:
        - key: request.headers[x-tier]
          values: ["internal"]
```

### 3.3 DENY (blocklist a dangerous operation)

```yaml
# 03-deny-mutations.yaml — nobody may mutate, regardless of ALLOW policies
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-deny-mutations
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: DENY
  rules:
    - to:
        - operation:
            methods: ["DELETE", "PUT", "PATCH"]
```

DENY wins over any ALLOW, so this is an absolute guardrail.

### 3.4 End-user (JWT) authentication + authorization

`RequestAuthentication` only *validates* tokens — a request with **no** token still passes it. You must add an `AuthorizationPolicy` requiring `requestPrincipals` to actually **require** a token.

```yaml
# 04-jwt.yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-on-httpbin
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  jwtRules:
    - issuer: "https://accounts.example.com"
      jwksUri: "https://accounts.example.com/.well-known/jwks.json"
      audiences:
        - "httpbin.foo.svc.cluster.local"
      forwardOriginalToken: true
      fromHeaders:
        - name: Authorization
          prefix: "Bearer "
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-require-jwt
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["https://accounts.example.com/*"]  # <iss>/<sub>; * = any subject
      when:
        - key: request.auth.claims[groups]
          values: ["sre"]                                          # claim-based RBAC
```

> **The classic mistake:** deploying only the `RequestAuthentication` and expecting it to block anonymous traffic. It does not. Anonymous requests (no `Authorization` header) are *not rejected* by `RequestAuthentication`; only requests with an **invalid** token are (401). The `AuthorizationPolicy` above closes that gap.

### 3.5 `CUSTOM` — delegate to an external authorizer (OPA / oauth2-proxy)

First register the ext_authz provider in the mesh config (`istiod` reads `extensionProviders`):

```yaml
# 05-meshconfig-extauthz.yaml (IstioOperator overlay)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    extensionProviders:
      - name: "opa-ext-authz-grpc"
        envoyExtAuthzGrpc:
          service: "opa.opa-system.svc.cluster.local"
          port: 9191
          timeout: 0.5s
          failOpen: false                # fail CLOSED: deny if OPA is unreachable
      - name: "oauth2-proxy"
        envoyExtAuthzHttp:
          service: "oauth2-proxy.auth.svc.cluster.local"
          port: 4180
          includeRequestHeadersInCheck: ["authorization", "cookie"]
          headersToUpstreamOnAllow: ["authorization", "x-auth-request-user"]
          headersToDownstreamOnDeny: ["set-cookie", "content-type"]
```

Then reference it from a `CUSTOM` policy (evaluated *first*, before DENY/ALLOW):

```yaml
# 06-custom-authz.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-ext-authz
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: CUSTOM
  provider:
    name: "opa-ext-authz-grpc"          # must match an extensionProviders entry
  rules:
    - to:
        - operation:
            paths: ["/admin/*"]         # only send /admin/* to OPA; rest handled by ALLOW/DENY
```

`failOpen: false` is the production-safe default — an unreachable authorizer must **not** silently authorize `/admin/*`.

### 3.6 `AUDIT` — dry-run a rule before enforcing

```yaml
# 07-audit.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: httpbin-audit-deletes
  namespace: foo
spec:
  selector:
    matchLabels:
      app: httpbin
  action: AUDIT
  rules:
    - to:
        - operation:
            methods: ["DELETE"]
```

`AUDIT` marks matching requests for auditing (Envoy "shadow" RBAC rules) but never allows or denies. **It only produces output when an audit-capable logging provider is configured on your platform** — otherwise it is inert. Use it to measure blast radius before flipping a rule to `DENY`.

### 3.7 Source-IP allowlisting at the ingress gateway

`ipBlocks` at a gateway matches the *directly connected* IP (usually the LB/node), not the real client. To match the true client you need `remoteIpBlocks` **and** a trusted-proxy configuration so Envoy trusts `X-Forwarded-For`:

```yaml
# 08-gateway-topology.yaml (tell Envoy how many proxies to trust for XFF)
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    defaultConfig:
      gatewayTopology:
        numTrustedProxies: 1            # e.g. one external LB in front of the gateway
---
# 09-ingress-ip-allowlist.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ingress-ip-allowlist
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks: ["203.0.113.0/24"]   # real client CIDR
```

### 3.8 Hardening: enforce path normalization

L7 path rules can be bypassed by path-encoding tricks (`/admin/../foo`, double slashes, `%2f`) if Envoy and your app normalize differently. Enable normalization mesh-wide:

```yaml
# 10-path-normalization.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    pathNormalization:
      normalization: MERGE_SLASHES     # NONE | BASE | MERGE_SLASHES | DECODE_AND_MERGE_SLASHES
```

---

## 4. CLI commands and real terminal output

### 4.1 Apply and verify the baseline

```console
$ kubectl apply -f 00-peer-strict.yaml -f 01-deny-all.yaml
peerauthentication.security.istio.io/default created
authorizationpolicy.security.istio.io/deny-all created

$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.foo:8000/get
403

$ kubectl -n foo exec deploy/sleep -c sleep -- curl -sS http://httpbin.foo:8000/get
RBAC: access denied
```

The literal body `RBAC: access denied` with HTTP **403** is the L7 RBAC signature. (At L4, a denied TCP connection is simply reset — `curl: (56) Recv failure: Connection reset by peer`.)

### 4.2 Grant least privilege, re-test

```console
$ kubectl apply -f 02-allow-sleep-get.yaml
authorizationpolicy.security.istio.io/httpbin-allow-sleep created

# missing the required header -> still denied
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.foo:8000/get
403

# with the header the ALLOW rule matches -> 200
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" -H "x-tier: internal" http://httpbin.foo:8000/get
200

# a POST is not in the allowlist -> denied
$ kubectl -n foo exec deploy/sleep -c sleep -- \
    curl -sS -o /dev/null -w "%{http_code}\n" -X POST -H "x-tier: internal" http://httpbin.foo:8000/post
403
```

### 4.3 Inspect the compiled RBAC config on the proxy

The inbound listener on a sidecar is the virtual inbound `0.0.0.0:15006`; the L7 RBAC filter lives inside its HTTP filter chain and its policies are named `ns[<ns>]-policy[<name>]-rule[<index>]`:

```console
$ POD=$(kubectl -n foo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

$ istioctl proxy-config listener "$POD.foo" --port 15006 -o json \
    | jq -r '.. | objects
             | select(.name? == "envoy.filters.http.rbac")
             | .typed_config.rules.policies | keys[]'
ns[foo]-policy[httpbin-allow-sleep]-rule[0]
```

Higher-level summary of every authz policy attached to a workload (columns vary slightly by `istioctl` version):

```console
$ istioctl experimental authz check "$POD.foo"
ACTION   AuthorizationPolicy                            RULES
ALLOW    ns[foo]-policy[httpbin-allow-sleep]-rule[0]    1
DENY     ns[foo]-policy[httpbin-deny-mutations]-rule[0] 1
```

### 4.4 Confirm mTLS and effective policy for a pod

```console
$ istioctl experimental describe pod "$POD.foo"
Pod: httpbin-7b7c4d5f8-abcde.foo
   Pod Revision: default
--------------------
Service: httpbin.foo
   Port: http 8000/HTTP targets pod port 80
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
--------------------
RBAC policies: ns[foo]-policy[httpbin-allow-sleep]-rule[0], ns[foo]-policy[httpbin-deny-mutations]-rule[0]
```

`Workload mTLS mode: STRICT` confirms that `principals`/`namespaces` rules are enforceable; if it read `DISABLE`, every identity-based rule would silently never match.

### 4.5 Turn on RBAC debug logging to see *why* a decision was made

```console
$ istioctl proxy-config log "$POD.foo" --level rbac:debug
active loggers:
  rbac: debug

$ kubectl -n foo logs "$POD" -c istio-proxy --tail=50 | grep -i rbac
2026-08-08T12:03:41.882Z  debug  envoy rbac  checking request:
    requestedServerName: outbound_.8000_._.httpbin.foo.svc.cluster.local,
    sourceIP: 10.244.0.31:41922, directRemoteIP: 10.244.0.31:41922,
    ssl.uriSanPeerCertificate: spiffe://cluster.local/ns/foo/sa/sleep,
    headers: ':method','POST'  ':path','/post'
2026-08-08T12:03:41.882Z  debug  envoy rbac  enforced denied,
    matched policy ns[foo]-policy[httpbin-deny-mutations]-rule[0]
```

The log names the *exact rule* that decided the request and shows the peer SPIFFE identity that mTLS presented — this is the single most useful production diagnostic for authz.

### 4.6 Static validation before rollout

```console
$ istioctl analyze -n foo
✔ No validation issues found when analyzing namespace: foo.
```

`istioctl analyze` will warn, for example, when a policy references `requestPrincipals` but no `RequestAuthentication` is attached to the workload (the field would silently have no effect), or when a `selector` matches no pods.

---

## 5. Verification and failure-diagnosis guide

### 5.1 Decision tree for "unexpected 403 / RBAC: access denied"

```
403 "RBAC: access denied"
 ├─ Is there a DENY policy matching this request?
 │     istioctl x authz check <pod>  → look for a matching DENY rule
 │     kubectl logs -c istio-proxy | grep rbac → "enforced denied, matched policy ..."
 │        └─ yes → that DENY (or the mesh/ns deny-all) is intended precedence; DENY beats ALLOW.
 ├─ Is there an ALLOW policy on the workload but none matching?
 │     Remember: presence of ANY ALLOW makes the scope default-deny.
 │        └─ widen/complete the allowlist (method? path? header? principal?).
 ├─ Is the caller's identity what you think?
 │     Debug log ssl.uriSanPeerCertificate == spiffe://.../sa/<expected>?
 │        └─ empty → mTLS not established → principals/namespaces cannot match.
 │           Check PeerAuthentication (STRICT?) and that BOTH ends are meshed.
 └─ CUSTOM provider path? failOpen:false + unreachable ext_authz → deny.
       Check the ext_authz service endpoints and the sidecar's ext_authz debug log.
```

### 5.2 Diagnosis for "unexpectedly allowed"

```
Request that should be blocked succeeds (200)
 ├─ No ALLOW/DENY policy on the workload → default OPEN. Add a deny-all baseline.
 ├─ Policy has L7 fields but traffic is plain TCP / port not app-protocol-detected
 │     → L7 rules require HTTP; declare the port protocol (name it http-*/use appProtocol).
 ├─ Ambient mode: L7 rule with no waypoint → ztunnel enforces L4 only, L7 silently ignored.
 │     → attach a waypoint and bind the policy via targetRefs.
 ├─ Path bypass (/admin/../x, //admin, %2f) → enable meshConfig.pathNormalization.
 └─ requestPrincipals rule but only RequestAuthentication deployed → anonymous requests pass
       (RequestAuthentication does not reject missing tokens). Require requestPrincipals: ["*"].
```

### 5.3 Common failure modes

| Symptom | Root cause | Fix |
|---|---|---|
| Everything 403 after first ALLOW policy | Any ALLOW makes the scope default-deny | Complete the allowlist or scope the policy with `selector` |
| `principals`/`namespaces` never match | mTLS not established → empty peer identity | `PeerAuthentication` STRICT; ensure both ends are in the mesh |
| Anonymous traffic still reaches app | `RequestAuthentication` alone doesn't require a token | Add ALLOW with `requestPrincipals: ["*"]` |
| `ipBlocks` at gateway matches LB IP, not client | L3 source is the last hop | Use `remoteIpBlocks` + `numTrustedProxies` / `externalTrafficPolicy: Local` |
| L7 rules ignored (paths/methods) | TCP traffic, or ambient without waypoint | Set port protocol to HTTP; attach a waypoint |
| Path allowlist bypassed | Divergent path normalization | `meshConfig.pathNormalization: MERGE_SLASHES` (or stricter) |
| `CUSTOM` policy authorizes on outage | `failOpen: true` on the provider | Set `failOpen: false` for sensitive paths |
| `AUDIT` produces nothing | No audit provider configured | Wire an audit-capable logging provider, or use it only as a dry-run marker |
| DENY with `notPaths` blocks too much/little | Negative matching inverts intent | Prefer positive matching; test with `AUDIT` first |

### 5.4 Verification checklist before declaring a policy "enforcing"

1. `istioctl analyze` is clean for the namespace.
2. `istioctl x describe pod` shows the expected `Workload mTLS mode` and the policy under `RBAC policies:`.
3. `istioctl proxy-config listener … | jq …` shows the compiled `envoy.filters.http.rbac` (or `network.rbac`) policy keys.
4. A **positive** and a **negative** `curl` from a known-identity client both return the expected codes (200 / 403).
5. With `rbac:debug`, the deny/allow log line names the exact rule you intended.
6. For JWT, test three cases: **no token → 403**, **invalid token → 401**, **valid token wrong claim → 403**, **valid token right claim → 200**.

---

## 6. References

- Istio — Authorization concepts: https://istio.io/latest/docs/concepts/security/#authorization
- Istio — `AuthorizationPolicy` reference (fields, actions, matching): https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Authorization policy conditions (supported `when` keys): https://istio.io/latest/docs/reference/config/security/conditions/
- Istio — Authorization tasks (HTTP/TCP, deny-all, allow patterns): https://istio.io/latest/docs/tasks/security/authorization/
- Istio — Authorization with JWT: https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
- Istio — Custom (external) authorization: https://istio.io/latest/docs/tasks/security/authorization/authz-custom/
- Istio — `RequestAuthentication` reference: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Istio — `PeerAuthentication` reference (mTLS prerequisite): https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Security best practices (path normalization, positive matching, deny-all): https://istio.io/latest/docs/ops/best-practices/security/
- Istio — Ambient L4/L7 authorization and waypoints: https://istio.io/latest/docs/ambient/usage/l7-features/
- Envoy — HTTP RBAC filter: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter
- Envoy — External authorization (`ext_authz`) filter: https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter
- SPIFFE — identity model (workload principals): https://spiffe.io/docs/latest/spiffe-about/overview/
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum