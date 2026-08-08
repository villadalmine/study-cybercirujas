# 4.2 Configuring Authentication (mTLS, JWT)

## 1. The production problem: identity in a zero-trust mesh

In a classic three-tier deployment, "security" was largely a perimeter concern: a firewall or load balancer terminated TLS at the edge, and everything behind it was trusted L3/L4 network. That model collapses in Kubernetes for three structural reasons:

1. **Pod IPs are ephemeral and reused.** An `iptables`/`NetworkPolicy` rule that trusts `10.244.3.17` trusts *whatever pod holds that IP right now*. After a rollout, that IP may belong to a different workload, possibly a different tenant. IP is not identity.
2. **East-west traffic dwarfs north-south traffic.** The overwhelming majority of connections are service-to-service, inside the cluster, where traditionally there was *no* authentication at all. A single compromised pod could speak plaintext to every other service.
3. **The network is not the trust boundary.** In multi-tenant clusters, shared nodes, and multi-cluster meshes, the underlay is explicitly assumed hostile. This is the **zero-trust** premise: authenticate and authorize *every* hop, cryptographically, on the basis of *workload identity*, not network location.

Istio answers this by moving authentication into the sidecar data plane (Envoy) and giving every workload a **cryptographic identity** that is:

- **Independent of IP, node, and namespace topology.**
- **Rooted in the Kubernetes ServiceAccount**, so it maps onto RBAC you already manage.
- **Encoded as a SPIFFE identity** in an X.509 SAN, so it is portable across clusters and interoperable with the wider SPIFFE ecosystem.

Istio splits "who is calling" into two orthogonal questions, and this split is the single most important mental model for this topic:

| Question | Istio term | Resource | Transport | Identity object |
|---|---|---|---|---|
| Which **workload** opened this connection? | Peer authentication | `PeerAuthentication` | mutual TLS (X.509) | SPIFFE ID (`source.principals`) |
| Which **end user / caller** is behind this request? | Request authentication | `RequestAuthentication` | JWT (bearer token) | `<issuer>/<subject>` (`source.requestPrincipals`) |

These are **additive, not alternatives**. A request from the `checkout` pod carrying a user's JWT has *both* a peer identity (the pod) and a request identity (the user). Production policies routinely assert both: "traffic must come from a workload in the `payments` namespace **and** carry a valid Auth0 token with audience `api.internal`."

> **Critical distinction that the exam and production both punish:** neither `PeerAuthentication` nor `RequestAuthentication` *authorizes* anything. They establish and *validate* identity. **Enforcement is always the job of `AuthorizationPolicy`.** A `RequestAuthentication` with no matching `AuthorizationPolicy` will happily let through requests that carry *no token at all* — it only rejects tokens that are *present and invalid*. Section 4 and 5 make this concrete.

---

## 2. The authentication data path

### 2.1 Workload identity: SPIFFE + the Istio CA

Every workload identity is a **SPIFFE ID** of the form:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

For a pod running under ServiceAccount `bookinfo-productpage` in namespace `default` with the default trust domain `cluster.local`:

```
spiffe://cluster.local/ns/default/sa/bookinfo-productpage
```

This string is embedded as a **URI Subject Alternative Name (SAN)** in the workload's X.509 leaf certificate. It is *not* the Common Name — Istio deliberately puts identity in the SAN so it survives modern TLS validation (CN-based identity is deprecated in the ecosystem).

`istiod` embeds a Certificate Authority. By default it uses a **self-signed root** generated on first start (stored in the `istio-ca-secret` in `istio-system`). In production you almost always replace this with a CA rooted in your PKI by supplying `cacerts` (see §7.4).

### 2.2 Certificate provisioning and rotation (the SDS flow)

Understanding this flow is what separates "I applied a PeerAuthentication" from "I can debug why one pod won't mTLS." The `istio-agent` (a.k.a. `pilot-agent`) runs inside every sidecar container and brokers certificates:

```
        pod: reviews-v3
 ┌───────────────────────────────────────────────┐
 │  ┌───────────┐        ┌────────────────────┐   │
 │  │  Envoy    │◀──SDS──│  istio-agent       │   │        ┌──────────────┐
 │  │ (data     │  UDS   │  (pilot-agent)     │──gRPC/mTLS─▶│   istiod     │
 │  │  plane)   │        │                    │  CSR + SA  │   (Istio CA) │
 │  └───────────┘        └────────────────────┘  JWT       └──────────────┘
 │        ▲                        │                              │
 │        │ key + cert chain       │  1. generate key + CSR       │
 │        └── over Unix socket ◀───┘  2. attach SA JWT token      │
 │            (never touches disk,    3. istiod → TokenReview ────┘
 │             never leaves the pod)  4. istiod signs, returns cert
 └───────────────────────────────────────────────┘
```

Step by step:

1. `istio-agent` generates a **private key in memory** and a CSR. The private key **never leaves the pod and is never written to disk**.
2. It authenticates to `istiod`'s CA gRPC endpoint using the pod's **projected ServiceAccount token**.
3. `istiod` calls the Kubernetes **`TokenReview`** API to prove the token is genuine and bound to that SA/pod.
4. `istiod` signs a leaf certificate with the SPIFFE SAN and returns the chain.
5. `istio-agent` pushes key+cert to Envoy over the **SDS** API on a Unix domain socket (`./etc/istio/proxy/SDS`). Certs live only in Envoy's memory.
6. The agent **proactively rotates** the certificate. Default workload cert lifetime is **24h** (`WorkloadCertTTL`), and the agent refreshes at roughly half-life, so a compromised leaf has a short blast radius. Rotation is hitless — Envoy hot-swaps the secret with no connection drops.

This is why a workload can lose mTLS even with a perfect `PeerAuthentication`: if the SA token projection is broken, `istiod` is unreachable, or clock skew invalidates the token, the CSR loop fails and Envoy never receives a cert.

---

## 3. Peer authentication (mTLS)

### 3.1 The four modes and where they apply

`PeerAuthentication` sets the **server-side** expectation: what the receiving sidecar will *accept*.

| Mode | Server accepts | Server rejects | Typical use |
|---|---|---|---|
| `UNSET` | inherits parent scope | — | default; let a broader policy decide |
| `PERMISSIVE` | mTLS **and** plaintext | nothing | **migration** — mesh default so legacy/non-mesh clients don't break |
| `STRICT` | mTLS only | all plaintext | **steady-state production** target |
| `DISABLE` | plaintext only | mTLS | carve-outs: a port scraped by non-mesh infra, or app already does its own TLS |

**Scope precedence — narrowest wins:**

```
workload-level (has selector)  >  namespace-level (no selector, in that ns)  >  mesh-level (no selector, in root ns)
```

- **Mesh-wide**: a `PeerAuthentication` with *no* `selector`, applied in the **root namespace** (`istio-system` by default, set by `meshConfig.rootNamespace`).
- **Namespace-wide**: no `selector`, applied *in the target namespace*.
- **Workload-specific**: has a `selector.matchLabels`; may also set `portLevelMtls` for per-port overrides.

`portLevelMtls` keys are the **workload's container `targetPort`** (the port Envoy actually listens on), *not* the Kubernetes Service port. Getting this wrong is a classic silent failure.

### 3.2 Client side: `DestinationRule` TLS modes

`PeerAuthentication` governs the *receiver*. The *sender's* behaviour is governed by a `DestinationRule` `trafficPolicy.tls.mode`. When you rely on auto-mTLS (the default since Istio 1.5), Istio infers this for you: if the destination advertises mTLS, the client sidecar originates mTLS automatically. You override it explicitly when you need to.

| `DestinationRule` `tls.mode` | Client behaviour | When |
|---|---|---|
| *(unset / auto-mTLS)* | mTLS if server offers it, else plaintext | default; let Istio negotiate |
| `ISTIO_MUTUAL` | mTLS using **Istio-issued** certs (SPIFFE identity) | force mesh mTLS to a `STRICT` server |
| `MUTUAL` | mTLS with **your own** supplied client cert/key | mesh → external service requiring client certs |
| `SIMPLE` | one-way TLS (client validates server, no client cert) | mesh → external HTTPS endpoint |
| `DISABLE` | plaintext | talking to a `DISABLE` port |

> **The #1 mTLS outage in the field:** a `PeerAuthentication: STRICT` on the server **combined with** a stale `DestinationRule: tls.mode: DISABLE` (often left over from a manual TLS setup) on the client side. The client sends plaintext, the STRICT server resets the connection, and you get `503 UC`/`upstream connect error or disconnect/reset before headers` with *no obvious cause*. §7.2 shows how to catch it.

### 3.3 Manifests

**(a) Mesh-wide STRICT** — the production end state, applied in the root namespace:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default            # conventional name for the mesh-wide policy
  namespace: istio-system  # must equal meshConfig.rootNamespace
spec:
  mtls:
    mode: STRICT
```

**(b) The safe migration pattern** — mesh PERMISSIVE, tighten one namespace to STRICT once you've verified it has no plaintext callers:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE        # whole mesh stays lenient during rollout
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: payments-strict
  namespace: payments       # only this namespace enforces
spec:
  mtls:
    mode: STRICT
```

**(c) Workload + port-level override** — STRICT for the workload, but expose a Prometheus scrape port in plaintext because the scraper is outside the mesh:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: reviews-mtls
  namespace: default
spec:
  selector:
    matchLabels:
      app: reviews          # only pods with this label
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:                   # container targetPort, NOT the Service port
      mode: DISABLE         # /metrics scraped by non-mesh Prometheus
```

**(d) Client-side `DestinationRule`** — force Istio mTLS to a host (belt-and-suspenders alongside a STRICT server, and required if you also define subsets):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-istio-mtls
  namespace: default
spec:
  host: reviews.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

---

## 4. Request authentication (JWT)

`RequestAuthentication` tells the sidecar **how to validate a JWT**: where to find it, which issuer signed it, and where to fetch the signing keys (JWKS).

### 4.1 The manifest and every field that matters

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth0
  namespace: default
spec:
  selector:
    matchLabels:
      app: productpage
  jwtRules:
    - issuer: "https://your-tenant.eu.auth0.com/"      # MUST equal the token's `iss` claim, byte-for-byte
      audiences:                                        # if set, token `aud` must contain one of these
        - "https://api.internal.example.com"
      jwksUri: "https://your-tenant.eu.auth0.com/.well-known/jwks.json"
      # forwardOriginalToken: keep the Authorization header for upstream services
      forwardOriginalToken: true
      # fromHeaders / fromParams: override where the token is read from.
      # Default is `Authorization: Bearer <token>`. Example for a custom header:
      fromHeaders:
        - name: x-jwt-assertion
          prefix: "Bearer "
      # outputClaimToHeaders: surface a claim to upstream apps as a header
      outputClaimToHeaders:
        - header: x-jwt-email
          claim: email
```

Key semantics that trip people up:

- **`issuer` is compared exactly** to the `iss` claim — a trailing slash mismatch (`auth0.com` vs `auth0.com/`) is the most common cause of "valid token, still 401."
- **`jwksUri` vs inline `jwks`.** `jwksUri` lets `istiod` fetch and cache the key set (and refresh on rotation); use inline `jwks` only for air-gapped/offline validation. The **agent fetches JWKS, not Envoy** — if `istiod` (or the agent) cannot reach the JWKS URL at config time, validation for that rule fails open/closed depending on version, so *network egress to the IdP matters*.
- **`audiences` is optional but should almost always be set** — without it, any correctly-signed token from that issuer is accepted, regardless of who it was minted for (a confused-deputy risk across microservices that share an IdP).

### 4.2 The gotcha: validation is not enforcement

Apply *only* the `RequestAuthentication` above and test:

```console
$ curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/api/v1/products
200
```

**A request with no token returns 200.** `RequestAuthentication` rejects a *bad* token but never *requires* one. To require a token you must add an `AuthorizationPolicy`:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: default
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]   # "*" = ANY authenticated principal → a valid JWT is now mandatory
```

Now:

```console
$ curl -s -o /dev/null -w "%{http_code}\n" http://productpage:9080/api/v1/products
403                                    # RBAC: access denied — no principal

$ curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $BAD" http://productpage:9080/api/v1/products
401                                    # Jwt verification fails — token present but invalid

$ curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $GOOD" http://productpage:9080/api/v1/products
200
```

Note the **two different status codes**, which is a precise diagnostic signal:
- **`401`** comes from the JWT filter — a token was present and failed validation (bad signature, wrong issuer, expired, wrong audience).
- **`403`** comes from the RBAC/authorization filter — the request lacked a required principal (no token at all, or valid token but policy denied).

---

## 5. Composing peer + request identity in one policy

Real production policy asserts *both* planes. The `requestPrincipals` for a JWT identity is `"<issuer>/<subject>"`. Below: only workloads from the `frontend` namespace (peer/mTLS identity) **and** carrying an Auth0 token for a specific subject (request/JWT identity) may `POST` to `/api/v1/orders`.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: orders-write
  namespace: payments
spec:
  selector:
    matchLabels:
      app: orders
  action: ALLOW
  rules:
    - from:
        - source:
            principals:            # PEER identity (from mTLS cert SAN)
              - "cluster.local/ns/frontend/sa/checkout"
            requestPrincipals:     # REQUEST identity (from JWT iss/sub)
              - "https://your-tenant.eu.auth0.com/*"
      to:
        - operation:
            methods: ["POST"]
            paths: ["/api/v1/orders"]
      when:
        - key: request.auth.claims[scope]
          values: ["orders:write"]     # claim-based fine-grained authz
```

Two subtleties:
- `principals` (peer) **require mTLS** to be established; if the namespace is not STRICT and the caller sends plaintext, `principals` is empty and this rule can never match — the request is denied. Peer-identity authz therefore *presumes* mTLS.
- The `when` block reaches into validated JWT claims (`request.auth.claims[...]`), which only exist because the `RequestAuthentication` validated and populated them.

**DENY beats ALLOW.** If any `AuthorizationPolicy` with `action: DENY` matches, the request is denied regardless of ALLOW rules. And the moment *any* ALLOW policy selects a workload, that workload switches to **default-deny** for everything not explicitly allowed. This ordering (CUSTOM → DENY → ALLOW, default-deny once an ALLOW exists) is the evaluation model you must internalise.

---

## 6. CLI and terminal verification

### 6.1 Confirm the sidecar actually holds Istio-issued certs

```console
$ istioctl proxy-config secret productpage-v1-6b746f74dc-8xk2p
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2f8a...c41                           2026-08-09T14:22:11Z     2026-08-08T14:20:11Z
ROOTCA            CA             ACTIVE     true           1b03...9de                           2036-08-05T09:11:44Z     2026-08-05T09:11:44Z
```

- `default` is the **workload leaf** (note the ~24h validity window — that's the rotation TTL).
- `ROOTCA` is the trust anchor Envoy uses to verify peers.
- `VALID CERT: true` on `default` means SDS delivered a live cert; `false`/absent means the CSR loop is broken (see §7).

### 6.2 Read the SPIFFE identity out of the live leaf certificate

```console
$ istioctl proxy-config secret productpage-v1-6b746f74dc-8xk2p -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep -A1 "Subject Alternative Name"
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/default/sa/bookinfo-productpage
```

That URI SAN **is** the workload identity every `principals:` clause is matched against. This is the ground-truth check when an authorization rule "should match but doesn't."

### 6.3 Describe a pod's effective mesh security posture

```console
$ istioctl x describe pod productpage-v1-6b746f74dc-8xk2p
Pod: productpage-v1-6b746f74dc-8xk2p
   Pod Revision: default
   Pod Ports: 9080 (productpage), 15090 (istio-proxy)
--------------------
Service: productpage
   Port: http 9080/HTTP targets pod port 9080
DestinationRule: reviews-istio-mtls for "reviews.default.svc.cluster.local"
   Traffic Policy TLS Mode: ISTIO_MUTUAL
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied PeerAuthentication:
   default.istio-system

RequestAuthentication jwt-auth0/default selects this pod
   Issuer: https://your-tenant.eu.auth0.com/

Checked 1 RBAC policies (AuthorizationPolicy require-jwt/default) for this pod.
```

This single command answers "is this pod STRICT, which JWT issuer applies, and which authz policies gate it" — the fastest triage for an auth incident.

### 6.4 Static config analysis before you ship

```console
$ istioctl analyze -n default
Info [IST0102] (Namespace default) The namespace is not enabled for Istio injection...
Warning [IST0128] (PeerAuthentication reviews-mtls.default) PeerAuthentication defines port-level
   mTLS for port 9090 but the workload selector matches no ports named or numbered 9090.
Error: Analyzers found issues when analyzing namespace: default.
```

`istioctl analyze` catches the port-level mismatch from §3.1 **before** it becomes a 503.

---

## 7. Verification and failure diagnosis

### 7.1 Prove mTLS is actually on the wire (not just configured)

Config says STRICT; verify the *bytes* are encrypted. Watch the server sidecar's Envoy access logs for the peer's SPIFFE ID:

```console
$ kubectl logs deploy/reviews -c istio-proxy | tail -1 | jq '{code:.response_code, mtls:.connection_termination_details, peer:.downstream_peer_uri_san}'
{
  "code": 200,
  "mtls": null,
  "peer": "spiffe://cluster.local/ns/default/sa/bookinfo-productpage"
}
```

A populated `downstream_peer_uri_san` = the connection was mTLS and the client presented a verified cert. Empty on a STRICT port = something is wrong, and the request would have been reset.

### 7.2 Diagnose the "STRICT + plaintext client" reset

Symptom: `503 upstream connect error or disconnect/reset before headers. reset reason: connection termination`.

```console
# 1. Is the destination STRICT?
$ istioctl x describe pod $(kubectl get pod -l app=reviews -o name | head -1 | cut -d/ -f2) | grep "mTLS mode"
   Workload mTLS mode: STRICT

# 2. Is a stale DestinationRule forcing the CLIENT to plaintext?
$ kubectl get destinationrule -A -o json \
  | jq -r '.items[] | select(.spec.host|test("reviews")) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.trafficPolicy.tls.mode)"'
default/legacy-reviews: DISABLE          # ← the culprit: client sends plaintext to a STRICT server
```

Fix: delete/patch the `DISABLE` rule, or set it to `ISTIO_MUTUAL`. Re-test with §7.1.

### 7.3 Diagnose JWT failures

Envoy's JWT filter is terse to clients (`401 Jwt verification fails`) but verbose in debug logs:

```console
$ istioctl proxy-config log deploy/productpage --level "jwt:debug,rbac:debug"
$ kubectl logs deploy/productpage -c istio-proxy | grep -iE "jwt|rbac" | tail -3
[jwt_authn] Jwt issuer https://wrong-issuer/ is not configured
[jwt_authn] verification completed with: Jwt issuer is not configured
[rbac] enforced denied, matched policy none
```

Decision table:

| Client sees | Envoy log clue | Root cause | Fix |
|---|---|---|---|
| `401 Jwt issuer is not configured` | `issuer ... is not configured` | token `iss` ≠ `jwtRules.issuer` (often a trailing `/`) | align `issuer` exactly to the `iss` claim |
| `401 Jwt verification fails` | `Jwt verification fails: expired` | expired token / clock skew | check `nbf`/`exp`, node NTP |
| `401 Audiences ... not allowed` | `audiences ... not in ...` | `aud` claim ∉ `audiences` | add the audience or fix the IdP app |
| `401` intermittently | `Jwks remote fetch is failed` | agent can't reach `jwksUri` | open egress to IdP; check `RequestAuthentication` for a stale JWKS URL |
| `403 RBAC: access denied` | `rbac ... matched policy none` | valid/absent token but authz denies | fix `requestPrincipals` / `principals` in the `AuthorizationPolicy` |

Decode the token you're actually sending — half of JWT tickets are the wrong token:

```console
$ echo "$GOOD" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, aud, exp, sub, scope}'
{
  "iss": "https://your-tenant.eu.auth0.com/",
  "aud": "https://api.internal.example.com",
  "exp": 1786312931,
  "sub": "auth0|6a3f...",
  "scope": "orders:write profile"
}
```

### 7.4 Health checks and STRICT mTLS

Under STRICT, kubelet HTTP `livenessProbe`/`readinessProbe` requests originate *outside the mesh* (kubelet has no Istio cert) and would be reset. Istio's default profile solves this by **rewriting app HTTP probes** so the kubelet hits port `15021` on the sidecar, which proxies to the app. Verify it's on:

```console
$ kubectl get pod productpage-v1-6b746f74dc-8xk2p -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/rewriteAppHTTPProbers}'
true
```

If probes fail *only after* turning on STRICT, this rewrite is disabled (or you use `exec`/`gRPC` probes, or a raw `tcpSocket` probe against an app port). Re-enable `rewriteAppHTTPProbers`, or expose the probe port via `portLevelMtls: DISABLE`.

### 7.5 Plug in your own CA (production hardening)

Never ship the self-signed istiod root to production. Provision an intermediate signed by your enterprise root and load it *before* installing Istio:

```console
$ kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem \
    --from-file=ca-key.pem \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem
secret/cacerts created

# istiod picks it up automatically; confirm workloads now chain to YOUR root:
$ istioctl proxy-config secret deploy/productpage -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="ROOTCA").secret.trustedCa.inlineBytes' \
  | base64 -d | openssl x509 -noout -issuer
issuer=O = Example Corp, CN = Example Corp Root CA
```

---

## 8. References

- Istio — Mutual TLS / Authentication (concepts): https://istio.io/latest/docs/concepts/security/#authentication
- Istio — `PeerAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — `RequestAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Istio — `AuthorizationPolicy` API reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Mutual TLS Migration task: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — Authentication Policy task (mTLS modes): https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — End-user (JWT) authentication task: https://istio.io/latest/docs/tasks/security/authentication/jwt-route/
- Istio — Plug in CA Certificates: https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
- Istio — Istio Certificate Management / SDS: https://istio.io/latest/docs/tasks/security/cert-management/
- Istio — `DestinationRule` TLS settings (`ClientTLSSettings`): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — Security best practices: https://istio.io/latest/docs/ops/best-practices/security/
- SPIFFE — ID and X.509-SVID specifications: https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- CNCF — ICA (Istio Certified Associate) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf