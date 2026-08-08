# 3.1 Configuring Secure Service-to-Service Communication

> **Certification:** CNPE — Cloud Native Platform Engineer
> **Domain 3:** Security (weight of this topic: 3)
> **Profile:** Principal Platform Architect / Senior SRE — production depth

---

## 1. The architectural problem: why the network is not a trust boundary

In a monolith, service-to-service communication is a function call inside one address space. In a Kubernetes platform, the *same* business transaction crosses a dozen Pods, three namespaces, and possibly two clusters. Every one of those hops is a TCP connection over a shared, flat overlay network. The default posture of that overlay is the exact opposite of what security requires:

- **Kubernetes networking is allow-all by default.** The [Kubernetes networking model](https://kubernetes.io/docs/concepts/services-networking/) mandates that every Pod can reach every other Pod without NAT. Absent a `NetworkPolicy`, a compromised `nginx` frontend can open a socket directly to your `postgres` primary, your `vault` API, and the cloud metadata endpoint at `169.254.169.254`.
- **Cleartext east-west traffic.** Application developers reach for `http://payments.svc.cluster.local` because it "just works." That traffic traverses `veth` pairs, a CNI overlay (VXLAN/Geneve), and possibly the physical NIC of a worker node. Anyone with `CAP_NET_RAW` in the node's network namespace, or a tap on the fabric, reads it.
- **Network location is not identity.** A source IP tells you which Pod *sent* a packet, not *what* it is. Pod IPs are ephemeral and recycled within seconds. An `AuthorizationPolicy` keyed on IP is authorizing a lease, not a workload.

The production failure mode this topic exists to prevent is **lateral movement**. Perimeter security (an ingress WAF, a cloud SG) stops nothing once an attacker has a foothold *inside* the mesh — an SSRF in one service, a leaked service-account token, a vulnerable dependency. The 2017-era "castle and moat" model assumes the inside is trusted. Cloud-native security inverts this into **zero trust**: *never trust, always verify*, on every single hop, using cryptographic identity rather than IP address.

Secure service-to-service communication is therefore built from three orthogonal controls that a platform engineer composes, never confuses:

| Control | OSI layer | Question it answers | Primitive |
|---|---|---|---|
| **Network segmentation** | L3/L4 | *Can this Pod even open a socket to that Pod?* | `NetworkPolicy` (CNI-enforced) |
| **Mutual authentication + encryption** | L4/L7 (TLS) | *Is the peer cryptographically who it claims, and is the wire confidential?* | mTLS via service mesh / SPIFFE |
| **Authorization** | L7 | *Is `frontend` allowed to call `GET /admin` on `payments`?* | mesh `AuthorizationPolicy` / OPA |

These are defense-in-depth layers, not alternatives. NetworkPolicy without mTLS still leaks cleartext to anything you *did* allow; mTLS without NetworkPolicy still lets a broken sidecar be bypassed at L3. Production platforms run both.

---

## 2. The identity substrate: SPIFFE / SPIRE

Before any of the enforcement mechanisms, you need a way to give a workload a **verifiable, cryptographic identity that does not depend on network location**. This is the problem SPIFFE (Secure Production Identity Framework For Everyone), a CNCF Graduated project, solves — and it is the foundation on which Istio and Linkerd build.

- A **SPIFFE ID** is a URI: `spiffe://trust-domain/path`, e.g. `spiffe://prod.example.com/ns/payments/sa/checkout`.
- An **SVID** (SPIFFE Verifiable Identity Document) is that ID delivered as either an X.509 certificate (SAN = the SPIFFE URI) or a JWT.
- **SPIRE** is the reference implementation. A `spire-server` is the CA/root of trust; a `spire-agent` DaemonSet on each node **attests** the workload — proving *this PID, in this Pod, with this service account* is who it claims — via node and workload attestation plugins, then issues a short-lived X.509 SVID.

The critical property: SVIDs are **short-lived** (default TTL of one hour, often minutes) and **auto-rotated**. There is no long-lived secret to steal. This is what makes "identity" survive Pod IP churn — the identity is bound to the workload's provable properties, not its address.

Istio's Citadel/istiod and Linkerd's identity controller are, in effect, SPIFFE-compliant CAs issuing X.509 SVIDs where the SAN encodes the workload identity (`spiffe://cluster.local/ns/<ns>/sa/<sa>`). When you later write an `AuthorizationPolicy` matching `principals: ["cluster.local/ns/frontend/sa/web"]`, you are matching the SPIFFE ID inside the peer's certificate — cryptographic identity, not IP.

---

## 3. Layer 3/4: NetworkPolicy — the segmentation floor

`NetworkPolicy` is the portable, CNI-agnostic primitive for *who can talk to whom* at L3/L4. It is a namespaced object, additive (policies are OR-ed), and **enforced by the CNI plugin — not the API server**. This is the number-one production gotcha: applying a `NetworkPolicy` on a cluster whose CNI does not enforce it (e.g. plain flannel) is a **silent no-op**. The object is accepted, `kubectl get netpol` shows it, and nothing is enforced.

### 3.1 Default-deny is the only correct starting point

A `NetworkPolicy` is deny-by-default *for the traffic direction it selects*, but only for Pods it selects. The standard production pattern is to first apply a namespace-wide default-deny, then open holes explicitly.

```yaml
# default-deny-all.yaml — deny all ingress AND egress in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}          # empty selector = every Pod in the namespace
  policyTypes:
    - Ingress
    - Egress
  # no ingress/egress rules => nothing is allowed
```

An empty `podSelector: {}` selects every Pod; declaring `policyTypes` with no matching rules denies that direction entirely. **The most common self-inflicted outage here is forgetting to re-allow DNS.** Once egress is default-denied, Pods cannot reach `kube-dns`/CoreDNS on UDP/TCP 53, so *every* service lookup fails with `SERVFAIL` and the symptom looks like a total network break rather than a policy issue.

```yaml
# allow-dns-egress.yaml — re-open DNS to kube-system CoreDNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### 3.2 A least-privilege ingress rule

```yaml
# checkout-allow-from-frontend.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-allow-from-frontend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: checkout
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: frontend
          podSelector:
            matchLabels:
              app: web
      ports:
        - protocol: TCP
          port: 8443
```

**The AND/OR trap.** In the `from` block above, `namespaceSelector` and `podSelector` are inside the **same list element** → they are AND-ed (a Pod labelled `app=web` *in the `frontend` namespace*). Written as two separate list items (each with a leading `-`), they would be OR-ed (any Pod in `frontend`, *or* any `app=web` Pod in any namespace). This single indentation difference is the most common over-permissive `NetworkPolicy` bug in real clusters. Verify it, never assume it.

### 3.3 The limits of standard NetworkPolicy (and why meshes exist)

| Capability | Standard `NetworkPolicy` | Why it matters |
|---|---|---|
| L3/L4 (IP, port, namespace/pod labels) | ✅ | Coarse segmentation |
| L7 (HTTP path, method, gRPC service) | ❌ | Can't say "allow `GET`, deny `DELETE`" |
| Egress by FQDN / DNS name | ❌ (needs Cilium/Calico CRD) | Can't allow `api.stripe.com` without pinning IPs |
| Cryptographic workload identity | ❌ (matches IP/labels, spoofable at L3) | IP ≠ identity |
| Encryption of the traffic | ❌ | Segmentation ≠ confidentiality |

CNI-specific CRDs extend this: **CiliumNetworkPolicy** adds L7 (HTTP/DNS/Kafka) filtering and FQDN egress enforced in eBPF; **Calico** adds `GlobalNetworkPolicy`, tiers, and DNS rules. But none of them authenticate the peer — for that you need mTLS.

```yaml
# cilium-l7-and-fqdn.yaml — L7 method filtering + egress by DNS name (Cilium only)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: checkout-l7
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: checkout
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: frontend
            app: web
      toPorts:
        - ports:
            - port: "8443"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/v1/.*"
              - method: "POST"
                path: "/api/v1/charge"
  egress:
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

---

## 4. Layer 4/7: mutual TLS and the service mesh

mTLS is the mechanism that turns "a connection from IP 10.4.2.7" into "a connection from `spiffe://cluster.local/ns/frontend/sa/web`, encrypted." In ordinary (one-way) TLS the *client* verifies the *server*. In **mutual** TLS, both sides present certificates and both verify the other's against a common trust bundle — so the server also learns, cryptographically, who the client is.

Doing this by hand in every application (loading certs, rotating them hourly, pinning the CA, re-doing it per language) is the reason **service meshes** exist. The mesh injects a sidecar proxy (or runs an ambient/eBPF datapath) that transparently:

1. Terminates the app's plaintext socket locally (loopback).
2. Establishes mTLS to the destination proxy using an auto-rotated SVID.
3. Fetches certs dynamically over **SDS** (Secret Discovery Service) so keys never touch disk.
4. Enforces L7 authorization before handing bytes to the app.

### 4.1 Data-plane architectures compared

| Architecture | Examples | Per-Pod overhead | Latency (p50 added) | Blast radius of upgrade | Notes |
|---|---|---|---|---|---|
| **Sidecar (Envoy)** | Istio (classic), Consul | 1 container + ~40–70 MB RAM/pod | ~0.5–1.5 ms | Per-pod (rolling restart to upgrade proxy) | Most feature-complete L7; heaviest |
| **Sidecar (micro-proxy)** | Linkerd (linkerd2-proxy, Rust) | ~10–20 MB RAM/pod | ~0.2–0.5 ms | Per-pod | Simpler, faster, less L7 surface |
| **Ambient / sidecar-less** | Istio ambient (ztunnel + waypoint) | Per-node ztunnel; waypoint only for L7 | ~0.3–0.8 ms (L4 path) | Per-node | mTLS at node level; L7 only where a waypoint is deployed |
| **eBPF-native** | Cilium Service Mesh | Per-node agent, no sidecar | lowest | Per-node | mTLS/L7 in kernel; younger L7 feature set |

The trade-off a platform architect actually weighs: **sidecars give per-workload isolation and the richest L7 policy at the cost of RAM×Pods and a proxy in every restart path**; **ambient/eBPF slash the overhead and decouple proxy upgrades from app rollouts, but move enforcement to a shared node component** (larger per-node blast radius, and L4-only unless you add waypoints). At 50 Pods, sidecar overhead is noise. At 50,000 Pods, `70 MB × 50,000 = 3.5 TB` of RAM spent on proxies is the entire reason ambient mode was built.

### 4.2 Istio: PeerAuthentication (the mTLS knob)

`PeerAuthentication` governs what a *server* workload accepts. Its `mtls.mode` is the single most consequential field for migrations:

| Mode | Server accepts plaintext | Server accepts mTLS | Use for |
|---|---|---|---|
| `DISABLE` | ✅ | ❌ | Explicit opt-out (e.g. scraping by a non-mesh Prometheus) |
| `PERMISSIVE` | ✅ | ✅ | **Migration** — mesh & non-mesh clients coexist |
| `STRICT` | ❌ | ✅ | **Target state** — reject all cleartext |

The correct production rollout is **`PERMISSIVE` → observe → `STRICT`**, never a big-bang flip. Going `STRICT` while a legacy client is still plaintext is an instant, self-inflicted outage.

```yaml
# mesh-wide STRICT mTLS, applied in the istio-system (root) namespace
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system     # root namespace => mesh-wide default
spec:
  mtls:
    mode: STRICT
---
# per-port carve-out: the metrics port stays plaintext for a non-mesh scraper
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: checkout-metrics-plaintext
  namespace: payments
spec:
  selector:
    matchLabels:
      app: checkout
  mtls:
    mode: STRICT
  portLevelMtls:
    "9090":
      mode: DISABLE
```

### 4.3 Istio: AuthorizationPolicy (L7 authZ on the mTLS identity)

`PeerAuthentication` only decides *whether* a connection is mutually authenticated. **`AuthorizationPolicy`** decides *what that authenticated identity is allowed to do* — and it is default-**allow** until the first `ALLOW` policy selects a workload, at which point that workload becomes default-**deny** for everything not explicitly allowed. A common belt-and-suspenders pattern is an explicit empty deny-all first.

```yaml
# 1) Namespace deny-all baseline
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: payments
spec:
  {}                          # selects all pods, no rules => deny everything
---
# 2) Allow only frontend/web to call specific methods+paths on checkout,
#    and ONLY when the peer is mutually authenticated as that SPIFFE identity.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: checkout-allow-frontend
  namespace: payments
spec:
  selector:
    matchLabels:
      app: checkout
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/frontend/sa/web"   # the SPIFFE ID in the client cert
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/v1/charge", "/api/v1/status/*"]
      when:
        - key: request.auth.claims[iss]              # optional JWT origin check
          values: ["https://accounts.example.com"]
```

`principals` matches the SPIFFE ID from the **peer certificate** (requires mTLS — with plaintext there is no principal to match, so the rule can never fire). `requestPrincipals`/`request.auth.*` matches JWT end-user identity via a companion `RequestAuthentication` — the two are independent: mTLS proves *service* identity, JWT proves *end-user* identity.

### 4.4 Istio: DestinationRule (client-side TLS origination)

For traffic the mesh *originates* to a workload (or an external TLS endpoint), `DestinationRule.trafficPolicy.tls` sets the client behavior. `ISTIO_MUTUAL` uses the mesh-issued SVID automatically.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: checkout-mtls
  namespace: payments
spec:
  host: checkout.payments.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL      # use the mesh mTLS identity for outbound calls
```

### 4.5 Linkerd: the same concepts, different CRDs

Linkerd auto-enrolls every meshed Pod in mTLS with zero configuration — mTLS is **on by default** for all TCP traffic between meshed Pods, using the identity issuer. Authorization is then expressed via the **policy CRDs** `Server`, `ServerAuthorization` / `AuthorizationPolicy`, and `MeshTLSAuthentication`.

```yaml
# Define the port on checkout that we are protecting
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata:
  name: checkout-api
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: checkout
  port: 8443
  proxyProtocol: HTTP/2
---
# Only meshed clients bearing this service-account identity may hit that Server
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: frontend-web-identity
  namespace: payments
spec:
  identities:
    - "web.frontend.serviceaccount.identity.linkerd.cluster.local"
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: checkout-allow-frontend
  namespace: payments
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: checkout-api
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: frontend-web-identity
```

To make the default *deny* rather than allow, Linkerd exposes the `config.linkerd.io/default-inbound-policy` annotation (namespace or pod) or the install-time `proxy.defaultInboundPolicy` — set it to `deny` for zero-trust, `cluster-authenticated` to require any meshed identity, etc.

---

## 5. Certificate management: cert-manager and trust distribution

The CA that signs SVIDs and the trust bundle that verifies them must themselves be managed. In production this is **cert-manager** (CNCF), which issues and rotates X.509 certs from an `Issuer`/`ClusterIssuer`, and **trust-manager** for distributing the CA bundle to every namespace.

```yaml
# Root CA for the mesh, backed by cert-manager, stored in a Secret istiod consumes.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-root
  namespace: istio-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  isCA: true
  commonName: istio-ca
  secretName: cacerts            # istiod reads its intermediate CA from this Secret
  duration: 87600h               # 10y root
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-root
    kind: Issuer
```

The rotation property is what matters operationally: **leaf SVIDs live ~24 h or less and rotate automatically; the intermediate CA rotates on `renewBefore`; the root is long-lived and offline where possible.** A platform that manually copies a static `tls.crt` into a Secret has recreated the long-lived-secret problem the whole mesh exists to eliminate.

---

## 6. Verification and failure diagnosis

Security controls that are not verified are decorative. Below is the diagnostic ladder — from "is it even enforced" to "is the identity what I think it is."

### 6.1 Is mTLS actually happening? (Istio)

```console
$ istioctl proxy-config secret deploy/checkout -n payments
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           2f9c...a17                           2026-08-08T09:14:03Z     2026-08-07T09:12:03Z
ROOTCA            CA             ACTIVE     true           1a4b...f02                           2036-08-04T00:00:00Z     2026-08-04T00:00:00Z
```

`VALID CERT true` and a `NOT AFTER` ~24 h out confirm the workload has a live, rotating SVID. An empty list means the sidecar never got a cert — check `istiod` health and the SA token projection.

```console
$ istioctl authn tls-check checkout.payments.svc.cluster.local -n payments
HOST:PORT                                        STATUS     SERVER     CLIENT     AUTHN POLICY        DESTINATION RULE
checkout.payments.svc.cluster.local:8443         OK         STRICT     ISTIO_MUTUAL   default/istio-system   checkout-mtls/payments
```

`STATUS OK` with `SERVER STRICT` / `CLIENT ISTIO_MUTUAL` is the healthy state. The dangerous state is **`CONFLICT`** — server is `STRICT` but no `DestinationRule` originates mTLS on the client, so calls fail with connection resets that look like the app crashing.

### 6.2 Prove cleartext is rejected under STRICT

From an *un-meshed* Pod, a plaintext request to a `STRICT` service must fail. This is the positive test that the policy is real:

```console
$ kubectl run tester --image=curlimages/curl -n default --rm -it -- \
    curl -sS http://checkout.payments.svc.cluster.local:8443/api/v1/status
curl: (56) Recv failure: Connection reset by peer
command terminated with exit code 56
```

From a *meshed* Pod in the allowed identity, the same call succeeds:

```console
$ kubectl exec -n frontend deploy/web -c web -- \
    curl -sS -o /dev/null -w "%{http_code}\n" http://checkout.payments.svc.cluster.local:8443/api/v1/status
200
```

An identity that is *authenticated but not authorized* is rejected by the `AuthorizationPolicy`, not the TLS layer — the tell is **HTTP 403 with the Envoy RBAC body**, not a reset:

```console
$ kubectl exec -n reporting deploy/audit -c audit -- \
    curl -sS http://checkout.payments.svc.cluster.local:8443/api/v1/charge
RBAC: access denied
```

### 6.3 Inspect the negotiated TLS on the wire

```console
$ kubectl exec -n frontend deploy/web -c istio-proxy -- \
    openssl s_client -connect checkout.payments.svc.cluster.local:8443 -alpn istio 2>/dev/null \
    | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
        X509v3 Subject Alternative Name: critical
            URI:spiffe://cluster.local/ns/payments/sa/checkout
```

The SAN `URI:spiffe://…` **is** the workload identity. If it is missing or is a DNS name instead of a SPIFFE URI, the cert is not a mesh SVID and your `principals:` rules will never match.

### 6.4 NetworkPolicy verification

```console
$ kubectl get networkpolicy -n payments
NAME                           POD-SELECTOR   AGE
default-deny-all               <none>         5d
allow-dns-egress               <none>         5d
checkout-allow-from-frontend   app=checkout   5d

$ kubectl describe networkpolicy checkout-allow-from-frontend -n payments
...
  Allowing ingress traffic:
    To Port: 8443/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=frontend
      PodSelector: app=web
```

**Enforcement is not proven by the object existing.** Prove it with traffic — a denied source must time out (not reset), because L3 policy drops packets silently:

```console
$ kubectl run np-tester --image=nicolaka/netshoot -n reporting --rm -it -- \
    nc -vz -w3 checkout.payments.svc.cluster.local 8443
nc: connect to checkout.payments.svc.cluster.local port 8443 (tcp) timed out: Operation now in progress
```

The **reset-vs-timeout distinction is the single most useful diagnostic signal** on this topic: a **timeout** points at L3/L4 (`NetworkPolicy` drop), a **connection reset** points at L4 TLS (mTLS `STRICT` rejecting plaintext), and a **403 `RBAC: access denied`** points at L7 (`AuthorizationPolicy`). Match the symptom to the layer before you touch a manifest.

### 6.5 Mesh and policy health

```console
$ istioctl analyze -n payments
Info [IST0102] (Namespace payments) The namespace is not enabled for Istio injection...
Warning [IST0128] (PeerAuthentication checkout-metrics-plaintext.payments) referenced port 9090 not found in any selected workload

$ linkerd check --proxy
linkerd-identity
----------------
√ certificate config is valid
√ trust anchors are within their validity period
√ issuer cert is within its validity period
√ issuer cert is issued by the trust anchor

linkerd-data-plane
------------------
√ data plane proxies are healthy
√ data plane is up-to-date
Status check results are √
```

`linkerd check --proxy` verifying that **issuer certs are within validity and chain to the trust anchor** is exactly the check that catches the classic 3 a.m. outage: an expired intermediate CA that silently breaks *all* mTLS handshakes cluster-wide.

---

## 7. Putting it together: the production reference pattern

A hardened `payments` namespace layers all three controls:

1. **`default-deny-all` + `allow-dns-egress`** NetworkPolicies → nothing talks unless explicitly allowed at L3/L4 (and DNS still works).
2. **`checkout-allow-from-frontend`** NetworkPolicy → only `frontend/web` may open TCP/8443.
3. **Mesh-wide `STRICT` `PeerAuthentication`** → every accepted connection must be mutually authenticated; cleartext is rejected.
4. **`deny-all` + `checkout-allow-frontend` `AuthorizationPolicy`** → only the SPIFFE identity `cluster.local/ns/frontend/sa/web` may call the specific methods/paths.
5. **cert-manager-backed CA** → SVIDs are short-lived and auto-rotated; no static secret to steal.

The result: a compromised Pod in `reporting` cannot even open a socket (L3 timeout); if it could, it cannot complete the handshake (no valid SVID → reset); if it somehow had one, it is not the allowed principal (L7 403). That is defense in depth — three independent failures required, not one.

---

## 8. References

- Kubernetes — Cluster Networking / Services model: https://kubernetes.io/docs/concepts/services-networking/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- SPIFFE / SPIRE (CNCF, Graduated) — concepts and SVIDs: https://spiffe.io/docs/latest/spiffe-about/overview/
- Istio — Mutual TLS / PeerAuthentication: https://istio.io/latest/docs/concepts/security/#mutual-tls-authentication
- Istio — Authorization Policy reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — `PeerAuthentication` API: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Ambient mesh (ztunnel / waypoint): https://istio.io/latest/docs/ambient/overview/
- Linkerd — Automatic mTLS: https://linkerd.io/2/features/automatic-mtls/
- Linkerd — Authorization policy (`Server`, `AuthorizationPolicy`, `MeshTLSAuthentication`): https://linkerd.io/2/features/server-policy/
- Cilium — Network Policy (L7, DNS/FQDN) and Service Mesh: https://docs.cilium.io/en/stable/security/policy/
- Calico — Network policy: https://docs.tigera.io/calico/latest/network-policy/
- cert-manager — issuing and rotating certificates: https://cert-manager.io/docs/
- trust-manager — trust bundle distribution: https://cert-manager.io/docs/trust/trust-manager/
- CNPE Curriculum (source of record): https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf