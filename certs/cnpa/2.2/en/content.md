# 2.2 Secure Service-to-Service Communication

> CNPA — Cloud Native Platform Engineering Associate · Domain 2 (Platform Security) · Exam weight **4.0**
> Level: Principal Platform Architect / Senior SRE — production depth

---

## 1. Motivation and the production architectural problem

The default Kubernetes network is a **flat, fully-routable L3 fabric with implicit trust**: every Pod can open a TCP connection to every other Pod IP in the cluster, on any port, with no authentication and no encryption. `kube-proxy` and the CNI give you *reachability*, not *security*. Two independent failures follow directly from this:

1. **No confidentiality on the wire.** East–west (service-to-service) traffic crosses node boundaries, overlay tunnels (VXLAN/Geneve), and sometimes the physical NIC of a multi-tenant host. A compromised node, a sniffing sidecar, or a mirrored SPAN port sees cleartext credentials, PII and bearer tokens. Compliance regimes (PCI-DSS 4.0 req. 4.2.1, HIPAA §164.312(e), SOC 2 CC6.7) explicitly require encryption of cardholder/PHI data *in transit* — including inside the cluster, not only at the ingress.

2. **No workload identity.** Source IP is the only thing the receiver knows about the caller, and in Kubernetes an IP is ephemeral, recycled, and trivially spoofable by anything sharing the node's network namespace. `NetworkPolicy` narrows *who can reach whom* by label/namespace selectors, but it authorizes a **network location**, not a **cryptographic identity**. A Pod that acquires an IP inside an allowed namespace inherits that IP's privileges.

### The perimeter model breaks

The classic "castle-and-moat" design trusts anything already inside the perimeter. In a microservice platform with hundreds of services this is catastrophic: one RCE in a public-facing service yields lateral movement across the entire east–west plane. This is the exact failure Google's **BeyondProd** and NIST **SP 800-207 (Zero Trust Architecture)** were written to eliminate. The Zero Trust principles that Domain 2.2 tests:

- **Identity-based, not location-based, trust.** Every workload carries a verifiable cryptographic identity, minted per-workload, short-lived, and automatically rotated.
- **Encrypt everything in transit**, unconditionally, even inside the cluster ("assume the network is hostile").
- **Authenticate *and* authorize every request** (mutual authentication), default-deny, least privilege.

### The three orthogonal controls

Producing a secure service-to-service plane means composing three distinct layers. Conflating them is the most common architectural mistake:

| Control | Question it answers | Mechanism | OSI layer |
|---|---|---|---|
| **Reachability / segmentation** | Can these packets even flow? | `NetworkPolicy`, `CiliumNetworkPolicy` | L3/L4 |
| **Encryption + peer authentication** | Is the channel private, and who is on the other end? | mTLS (SPIFFE SVID identities) | L4/L7 (TLS) |
| **Authorization** | Is this identity allowed to call this operation? | `AuthorizationPolicy`, Linkerd `Server`+`AuthorizationPolicy`, RBAC on SPIFFE ID | L7 |

The canonical production target is **default-deny NetworkPolicy for defence-in-depth + STRICT mesh mTLS for identity and encryption + identity-scoped L7 authorization**. mTLS is *not* a replacement for NetworkPolicy: a mesh sidecar still listens on the Pod, and a NetworkPolicy prevents traffic from ever reaching a compromised sidecar's admin/debug ports. Belt and suspenders.

**Workload identity: SPIFFE.** The industry-standard identity document is the **SPIFFE SVID** (Secure Production Identity Framework For Everyone — Verifiable Identity Document), typically an X.509 leaf certificate whose URI SAN encodes the identity:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>
```

Istio, Linkerd and Cilium all converge on SPIFFE. The identity is bound to the Kubernetes **ServiceAccount**, minted by a per-cluster CA, delivered to the proxy over a Unix socket (never written to disk in the mesh case), and rotated on the order of hours.

---

## 2. Technical comparisons and trade-offs

### 2.1 NetworkPolicy vs. service-mesh mTLS

| Dimension | `NetworkPolicy` (L3/L4) | Service-mesh mTLS (L4/L7) |
|---|---|---|
| Unit of trust | Pod label / namespace → **IP** | Cryptographic **workload identity** (SPIFFE SVID) |
| Encryption in transit | **None** | AES-GCM TLS 1.3 |
| Spoofing resistance | Weak (shared-node IP reuse) | Strong (private key per workload) |
| Enforcement point | CNI dataplane (iptables/eBPF) | Sidecar / node proxy (Envoy, linkerd2-proxy, ztunnel) |
| Requires a CNI that implements it | **Yes** (Calico, Cilium; *not* Flannel) | No (mesh brings its own dataplane) |
| L7 semantics (HTTP method/path, gRPC service) | No | Yes |
| Overhead | ~0 (kernel) | +1–3 ms p50 latency, +50–150 MiB RAM/sidecar |
| Survives node compromise | Partially | Yes (private key in-memory, short TTL) |

**Takeaway:** they are complementary, not substitutes. NetworkPolicy is cheap coarse segmentation; mTLS is identity + confidentiality. Production platforms run both.

### 2.2 mTLS implementation strategies

| Strategy | Encryption | Identity source | Code changes | Rotation | Ops burden |
|---|---|---|---|---|---|
| **In-app TLS** (library, e.g. Go `crypto/tls`) | App-managed | Manual PKI / cert-manager | **High** (every service) | Manual/cert-manager | High, error-prone |
| **Sidecar mesh** (Istio sidecar, Linkerd) | Transparent | Mesh CA (SPIFFE) | **Zero** | Automatic (~24 h) | Medium |
| **Ambient / node mesh** (Istio ambient ztunnel, Cilium) | Transparent | Mesh CA / SPIRE (SPIFFE) | Zero | Automatic | Lower per-pod cost |
| **SPIFFE/SPIRE + SDK** | App or proxy | SPIRE (federatable) | Low–Medium | Automatic (SPIRE) | Medium, most portable |

### 2.3 Mesh dataplane comparison

| | **Istio (sidecar)** | **Istio (ambient)** | **Linkerd** | **Cilium mTLS** |
|---|---|---|---|---|
| Proxy | Envoy sidecar per Pod | ztunnel (per-node L4) + optional waypoint (L7) | linkerd2-proxy (Rust) sidecar | eBPF + per-node agent (auth handshake) |
| mTLS transport | TLS 1.3 | HBONE (HTTP/2 CONNECT over mTLS, port 15008) | TLS 1.3 | TLS 1.3, SPIFFE via SPIRE |
| Identity | istiod CA → SPIFFE | istiod CA → SPIFFE | Linkerd identity → SPIFFE-like | SPIRE → SPIFFE |
| L7 authz | `AuthorizationPolicy` (rich) | `AuthorizationPolicy` at waypoint | `Server`+`AuthorizationPolicy` | `CiliumNetworkPolicy` (L7 via Envoy) |
| Per-pod RAM | High (~50–150 MiB) | **Low** (no sidecars) | Low (~10–20 MiB) | **Lowest** (kernel) |
| Config surface | Large | Medium | Small | Medium |
| Best for | Rich L7 policy, WASM, multi-cluster | Cost-sensitive fleets, gradual adoption | Simplicity, latency-critical | eBPF-native shops, L3/L4-first |

### 2.4 mTLS peer-authentication modes (Istio semantics, generalizable)

| Mode | Accepts mTLS | Accepts plaintext | Use case |
|---|---|---|---|
| `DISABLE` | No | Yes | Debug only / explicitly-unmeshed endpoint |
| `PERMISSIVE` | Yes | Yes | **Migration** — sidecar rollout in progress |
| `STRICT` | Yes | **No** | Production steady state (zero-trust) |

> **Migration trap:** `PERMISSIVE` is a *transitional* state. Leaving a namespace `PERMISSIVE` in production means an unmeshed attacker Pod can still speak plaintext to your service — you have the *mechanism* of mTLS without the *guarantee*. The audit control for 2.2 is "no workload effectively `PERMISSIVE` in prod".

### 2.5 Certificate authority / issuance options

| Option | CA | Rotation | Federation | Notes |
|---|---|---|---|---|
| Mesh-native (istiod / Linkerd identity) | Self-signed root or provided intermediate | Automatic | Limited | Simplest; root should be an offline-signed intermediate |
| **cert-manager `istio-csr`** | cert-manager `Issuer` (Vault, ACME, CA) | Automatic | Via issuer | Enterprise PKI integration; per-workload CSR |
| **SPIRE** | SPIRE Server | Automatic | **SPIFFE trust-domain federation** | Most portable; works beyond K8s (VMs, multi-cloud) |

---

## 3. Complete manifests and infrastructure

All examples target a `payments` namespace where a `checkout-api` service (namespace `checkout`, ServiceAccount `checkout-api`) calls a `ledger` gRPC service (namespace `payments`, ServiceAccount `ledger`, port `8443`).

### 3.1 Defence-in-depth NetworkPolicy (default-deny + explicit allow)

```yaml
# 00-default-deny.yaml — deny all ingress in the namespace, then whitelist.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: payments
spec:
  podSelector: {}            # every pod in the namespace
  policyTypes:
    - Ingress
---
# 01-allow-checkout-to-ledger.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-checkout-to-ledger
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: ledger
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: checkout
          podSelector:
            matchLabels:
              app: checkout-api
      ports:
        - protocol: TCP
          port: 8443
---
# 02-allow-mesh-control-plane.yaml — sidecars must reach istiod, and
# telemetry/health probes must reach the pod, or STRICT mTLS "breaks" mysteriously.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-istio-telemetry-and-health
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: ledger
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
      ports:
        - protocol: TCP
          port: 15021   # health/readiness (pilot-agent)
        - protocol: TCP
          port: 15090   # Envoy Prometheus telemetry
```

> **Gotcha the exam probes:** `NetworkPolicy` is additive-deny — an empty `podSelector: {}` with an `Ingress` policyType and no `ingress` rules denies *all* ingress. Forgetting `02-` above is the #1 cause of "everything broke after I enabled STRICT" — the probes and telemetry scrape are themselves cross-namespace flows.

### 3.2 Istio — STRICT mTLS + identity-scoped authorization

```yaml
# 10-peerauth-strict.yaml — force mTLS for the whole namespace.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: payments
spec:
  mtls:
    mode: STRICT
---
# 11-authz-default-deny.yaml — empty ALLOW rules == deny-all for the namespace.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: payments
spec:
  {}                          # no rules, action defaults to ALLOW → denies everything
---
# 12-authz-allow-checkout.yaml — least-privilege: only checkout-api's SPIFFE
# identity may POST /v1/charge on the ledger workload.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-checkout-to-ledger
  namespace: payments
spec:
  selector:
    matchLabels:
      app: ledger
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/checkout/sa/checkout-api"
      to:
        - operation:
            ports: ["8443"]
            methods: ["POST"]
            paths: ["/ledger.v1.Ledger/Charge"]
      when:
        - key: connection.sni
          values: ["ledger.payments.svc.cluster.local"]
---
# 13-destinationrule.yaml — client-side: use ISTIO_MUTUAL so Envoy presents
# its SVID upstream. (Redundant with mesh defaults but explicit == auditable.)
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: ledger-mtls
  namespace: payments
spec:
  host: ledger.payments.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

> The `principals` value is the SPIFFE ID **with the `spiffe://` scheme stripped**. `source.principals` matches the peer certificate (the *authenticated* mTLS identity); `source.namespaces`/`ipBlocks` do not require mTLS and are weaker. Always prefer `principals`.

### 3.3 Istio ambient mesh (sidecar-less) equivalent

```yaml
# Label the namespace into the ambient dataplane — ztunnel handles L4 mTLS,
# no sidecar injection.
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio.io/dataplane-mode: ambient
---
# L7 policy (methods/paths) in ambient requires a waypoint proxy for the service.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ledger-waypoint
  namespace: payments
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008          # HBONE tunnel port
      protocol: HBONE
```

### 3.4 Linkerd — automatic mTLS + server authorization

```yaml
# 20-server.yaml — declare the ledger gRPC port as a policy target.
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata:
  name: ledger-grpc
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: ledger
  port: 8443
  proxyProtocol: gRPC
---
# 21-meshtlsauth.yaml — the caller's mesh identity (SA-derived).
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: checkout-identity
  namespace: payments
spec:
  identities:
    - "checkout-api.checkout.serviceaccount.identity.linkerd.cluster.local"
---
# 22-authorizationpolicy.yaml — only that identity may reach the Server.
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: ledger-allow-checkout
  namespace: payments
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: ledger-grpc
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: checkout-identity
```

Set the namespace default to deny with the proxy annotation (opaque ports get no policy; `deny` requires an explicit allow like the above):

```yaml
# 23-default-deny.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  annotations:
    config.linkerd.io/default-inbound-policy: deny
```

### 3.5 SPIFFE/SPIRE — portable identity plane

```yaml
# 30-spire-server.yaml — StatefulSet + CA. Trust domain cybercirujas.club.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: spire
spec:
  serviceName: spire-server
  replicas: 1
  selector:
    matchLabels: { app: spire-server }
  template:
    metadata:
      labels: { app: spire-server }
    spec:
      serviceAccountName: spire-server
      containers:
        - name: spire-server
          image: ghcr.io/spiffe/spire-server:1.9.6
          args: ["-config", "/run/spire/config/server.conf"]
          ports: [{ containerPort: 8081 }]
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-data
              mountPath: /run/spire/data
      volumes:
        - name: spire-config
          configMap: { name: spire-server }
  volumeClaimTemplates:
    - metadata: { name: spire-data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 1Gi } }
---
# 31-spire-server-config.yaml — the CA + K8s node attestation (PSAT).
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: spire
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port    = "8081"
      trust_domain = "cybercirujas.club"
      data_dir     = "/run/spire/data"
      default_x509_svid_ttl = "1h"
      ca_ttl = "24h"
    }
    plugins {
      DataStore "sql" {
        plugin_data { database_type = "sqlite3" connection_string = "/run/spire/data/datastore.sqlite3" }
      }
      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "leloir" = { service_account_allow_list = ["spire:spire-agent"] }
          }
        }
      }
      KeyManager "disk" { plugin_data { keys_path = "/run/spire/data/keys.json" } }
    }
---
# 32-spire-agent.yaml — DaemonSet; workload attestation via k8s plugin.
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: spire
spec:
  selector: { matchLabels: { app: spire-agent } }
  template:
    metadata: { labels: { app: spire-agent } }
    spec:
      serviceAccountName: spire-agent
      hostPID: true
      containers:
        - name: spire-agent
          image: ghcr.io/spiffe/spire-agent:1.9.6
          args: ["-config", "/run/spire/config/agent.conf"]
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-agent-socket
              mountPath: /run/spire/sockets   # SDS UDS exposed to workloads
      volumes:
        - name: spire-config
          configMap: { name: spire-agent }
        - name: spire-agent-socket
          hostPath: { path: /run/spire/sockets, type: DirectoryOrCreate }
```

Registration entry binding the `ledger` ServiceAccount to a SPIFFE ID (see §4 for the CLI):

```
spiffe://cybercirujas.club/ns/payments/sa/ledger
  ← selectors: k8s:ns:payments , k8s:sa:ledger
```

### 3.6 cert-manager: enterprise PKI backing Istio (`istio-csr`)

```yaml
# 40-ca-issuer.yaml — cluster-wide intermediate CA for the mesh.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca
  namespace: cert-manager
spec:
  ca:
    secretName: istio-ca-key-pair       # PEM cert+key of the intermediate CA
---
# 41-workload-cert.yaml — a per-workload cert if you do in-app TLS instead of a mesh.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ledger-tls
  namespace: payments
spec:
  secretName: ledger-tls
  duration: 2160h        # 90d
  renewBefore: 360h      # rotate 15d before expiry
  commonName: ledger.payments.svc.cluster.local
  dnsNames:
    - ledger.payments.svc.cluster.local
    - ledger.payments
  uris:
    - spiffe://cybercirujas.club/ns/payments/sa/ledger   # SPIFFE ID as URI SAN
  usages:
    - server auth
    - client auth        # BOTH → the cert works for mutual TLS
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  issuerRef:
    name: istio-ca
    kind: Issuer
    group: cert-manager.io
```

### 3.7 Cilium — L3/L4 policy with mutual authentication (SPIFFE via SPIRE)

```yaml
# 50-cilium-mtls.yaml — identity-based, kernel-enforced, mTLS "required".
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ledger-mtls
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: ledger
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: checkout
            app: checkout-api
      authentication:
        mode: "required"     # trigger mutual auth handshake before allowing flow
      toPorts:
        - ports:
            - port: "8443"
              protocol: TCP
```

---

## 4. CLI verification and expected terminal output

### 4.1 Confirm sidecar injection and effective mTLS mode (Istio)

```console
$ istioctl experimental describe pod ledger-7d9f8c6b4-xk2rp -n payments
Pod: ledger-7d9f8c6b4-xk2rp
   Pod Revision: default
   Pod Ports: 8443 (ledger), 15090 (istio-proxy)
--------------------
Service: ledger
   Port: grpc 8443/GRPC targets pod port 8443
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied PeerAuthentication:
   payments/default
--------------------
Checked 1 AuthorizationPolicy for workload ledger.payments
   ALLOW  payments/allow-checkout-to-ledger
```

### 4.2 Inspect the workload's SVID (the mTLS leaf certificate)

```console
$ istioctl proxy-config secret ledger-7d9f8c6b4-xk2rp -n payments
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER          NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           241f0e...c9            2026-08-07T02:03:11Z     2026-08-06T02:01:11Z
ROOTCA            CA             ACTIVE     true           0a1b2c...ff            2027-08-06T00:00:00Z     2026-08-06T00:00:00Z

# Dump the leaf and confirm the SPIFFE URI SAN == the workload identity:
$ istioctl proxy-config secret ledger-7d9f8c6b4-xk2rp -n payments -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/payments/sa/ledger
```

### 4.3 Prove STRICT actually rejects plaintext

```console
# Launch an UNMESHED pod (no sidecar) and try cleartext against a STRICT port.
$ kubectl run probe --rm -it --image=nicolaka/netshoot -n payments \
    --annotations sidecar.istio.io/inject=false -- \
    curl -sv --max-time 5 http://ledger:8443/healthz
*   Trying 10.244.3.17:8443...
* Connected to ledger (10.244.3.17) port 8443
* Recv failure: Connection reset by peer
* Closing connection 0
curl: (56) Recv failure: Connection reset by peer     # ← STRICT rejected plaintext
```

### 4.4 Confirm the request carried a verified peer identity (XFCC)

```console
$ kubectl logs ledger-7d9f8c6b4-xk2rp -n payments -c istio-proxy | tail -1
[2026-08-06T14:03:11.204Z] "POST /ledger.v1.Ledger/Charge HTTP/2" 200 - via_upstream
 - "-" 412 90 6 5 "-" "grpc-go/1.62" "8f2c1e...-" "ledger:8443"
 inbound|8443|| 127.0.0.6:41233 10.244.3.17:8443 10.244.2.9:52344
 outbound_.8443_._.ledger.payments.svc.cluster.local default

# Envoy injects X-Forwarded-Client-Cert with the peer SVID — the ground truth of "who called":
$ kubectl logs ledger-7d9f8c6b4-xk2rp -n payments -c ledger | grep xfcc | tail -1
xfcc="By=spiffe://cluster.local/ns/payments/sa/ledger;
      Hash=1c9d...;URI=spiffe://cluster.local/ns/checkout/sa/checkout-api"
```

### 4.5 Negative authorization test (identity not in AuthorizationPolicy)

```console
# A meshed pod with a DIFFERENT ServiceAccount → mTLS succeeds, authz denies.
$ kubectl exec -it deploy/fraud-scanner -n payments -c fraud-scanner -- \
    grpcurl -d '{"amount":100}' ledger:8443 ledger.v1.Ledger/Charge
ERROR:
  Code: PermissionDenied
  Message: RBAC: access denied            # ← Istio AuthorizationPolicy rejected the SVID
```

### 4.6 Linkerd verification

```console
$ linkerd viz edges deployment -n payments
SRC          DST      SRC_NS      DST_NS    SECURED
checkout     ledger   checkout    payments  √        # √ == mTLS on this edge
prometheus   ledger   linkerd-viz payments  √

$ linkerd viz stat deploy/ledger -n payments
NAME     MESHED   SUCCESS      RPS   LATENCY_P50   LATENCY_P95   LATENCY_P99   TCP_CONN
ledger      1/1   100.00%   4.20rps         12ms          48ms          92ms          6

$ linkerd check --proxy -n payments
linkerd-identity
----------------
√ certificate config is valid
√ trust anchors are using supported crypto algorithm
√ trust anchors are within their validity period
√ issuer cert is issued by the trust anchor
linkerd-data-plane
------------------
√ data plane proxies certificate match CA
√ pod injection disabled on kube-system
Status check results are √
```

### 4.7 SPIRE registration and SVID fetch

```console
$ kubectl exec -n spire spire-server-0 -c spire-server -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID spiffe://cybercirujas.club/ns/payments/sa/ledger \
      -parentID spiffe://cybercirujas.club/spire/agent/k8s_psat/leloir \
      -selector k8s:ns:payments -selector k8s:sa:ledger
Entry ID         : 5f2a8e1c-3b7d-4a90-8c11-0e2f9d6a4b77
SPIFFE ID        : spiffe://cybercirujas.club/ns/payments/sa/ledger
Parent ID        : spiffe://cybercirujas.club/spire/agent/k8s_psat/leloir
Revision         : 0
X509-SVID TTL    : default
Selector         : k8s:ns:payments
Selector         : k8s:sa:ledger

$ kubectl exec -n spire spire-agent-abcde -c spire-agent -- \
    /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
Received 1 svid after 8.14ms
SPIFFE ID:        spiffe://cybercirujas.club/ns/payments/sa/ledger
SVID Valid After: 2026-08-06 14:00:11 +0000 UTC
SVID Valid Until: 2026-08-06 15:00:11 +0000 UTC      # 1h TTL, auto-rotated
```

---

## 5. Verification and failure-diagnosis guide

### 5.1 Systematic diagnostic ladder

1. **Is the proxy injected?** `kubectl get pod -n payments -o jsonpath='{.items[*].spec.containers[*].name}'` — must show `istio-proxy` / `linkerd-proxy`. No proxy → no mTLS, silently.
2. **What is the *effective* mode?** `istioctl x describe pod …` (§4.1). Beware namespace `PeerAuthentication` overridden by a workload-level one.
3. **Is the SVID valid and non-expired?** `istioctl proxy-config secret …` (§4.2). Look at `NOT AFTER`; a stuck istio-agent that can't reach istiod serves a stale/expired cert.
4. **Does the peer present the expected identity?** XFCC header / `openssl s_client -showcerts` URI SAN.
5. **Is it mTLS failing, or authz failing?** They look different: mTLS failure = TCP `connection reset` / TLS handshake error; authz failure = clean HTTP `403 RBAC: access denied` / gRPC `PermissionDenied`. Do not confuse them.
6. **Is a NetworkPolicy silently dropping the flow *before* the proxy?** `connection timed out` (not reset) with no Envoy log entry at all → suspect L3/L4 policy, not mTLS.

### 5.2 Failure-mode reference table

| Symptom | Likely cause | Confirm | Fix |
|---|---|---|---|
| `curl: (56) Connection reset by peer` on cleartext | STRICT mTLS working as intended | §4.3 | Expected — caller must be meshed |
| `503 UC` / `upstream connect error` between meshed pods | Server not actually presenting mTLS (`PERMISSIVE` mismatch, or app port declared as non-TLS) | `istioctl pc listener` shows `transport_socket` absent | Set `PeerAuthentication STRICT` *and* `DestinationRule ISTIO_MUTUAL` |
| `RBAC: access denied` / gRPC `PermissionDenied` | Authorization, not encryption | Envoy log `rbac_access_denied_matched_policy` | Add caller's `principals` to `AuthorizationPolicy` |
| Intermittent handshake failures after ~24 h | CA/SVID rotation not propagating (istiod unreachable, or clock skew) | `proxy-config secret` shows expired `NOT AFTER` | Restore istiod reachability; check NTP; `kubectl rollout restart` proxy |
| Flow times out, **no Envoy log** | `NetworkPolicy` dropping before the sidecar | `cilium monitor --type drop` / calico denied-packet metric | Add allow rule incl. control-plane ports 15021/15090 |
| mTLS "works" but attacker plaintext also works | Left in `PERMISSIVE` | `istioctl x describe` → mode `PERMISSIVE` | Move to `STRICT` after rollout completes |
| `NetworkPolicy` has zero effect | CNI doesn't implement it (Flannel) | `kubectl get pods -n kube-system` for CNI | Use Calico/Cilium, or rely on mesh authz |
| Linkerd edge shows blank under `SECURED` | Opaque/skip-ports or unmeshed peer | `linkerd viz edges` | Mesh the peer; remove `config.linkerd.io/skip-*` |

### 5.3 Manual TLS handshake inspection (ground truth)

```console
# From inside a meshed pod, open a raw mTLS handshake to the target and read the peer chain.
$ kubectl exec -it deploy/checkout-api -n checkout -c istio-proxy -- \
    openssl s_client -connect ledger.payments.svc.cluster.local:8443 \
    -cert /etc/certs/cert-chain.pem -key /etc/certs/key.pem \
    -CAfile /etc/certs/root-cert.pem 2>/dev/null </dev/null \
    | openssl x509 -noout -subject -ext subjectAltName
subject=
X509v3 Subject Alternative Name:
    URI:spiffe://cluster.local/ns/payments/sa/ledger    # ← peer identity verified
```

### 5.4 Continuous audit controls (what an SRE actually alerts on)

- **No effective `PERMISSIVE` in prod:** periodically parse `istioctl x describe` / `kubectl get peerauthentication -A`.
- **SVID TTL headroom:** alert if any `NOT AFTER` is < 2× the rotation interval away (rotation is stuck).
- **Default-deny present:** every prod namespace must have a `default-deny-ingress` NetworkPolicy *and* an empty/deny `AuthorizationPolicy` baseline.
- **mTLS coverage metric:** Istio `istio_requests_total{connection_security_policy="mutual_tls"}` / total should be ~1.0; Linkerd `linkerd viz edges` should show `√` on every edge.

---

## 6. References

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum
- NIST SP 800-207, *Zero Trust Architecture* — https://csrc.nist.gov/publications/detail/sp/800-207/final
- Google *BeyondProd* — https://cloud.google.com/docs/security/beyondprod
- Kubernetes Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Istio Security concepts — https://istio.io/latest/docs/concepts/security/
- Istio `PeerAuthentication` reference — https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio `AuthorizationPolicy` reference — https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio ambient mesh — https://istio.io/latest/docs/ambient/
- Linkerd automatic mTLS — https://linkerd.io/2/features/automatic-mtls/
- Linkerd authorization policy (`Server` / `AuthorizationPolicy`) — https://linkerd.io/2/features/server-policy/
- SPIFFE overview — https://spiffe.io/docs/latest/spiffe-about/overview/
- SPIRE concepts — https://spiffe.io/docs/latest/spire-about/
- cert-manager documentation — https://cert-manager.io/docs/
- cert-manager `istio-csr` — https://cert-manager.io/docs/projects/istio-csr/
- Cilium mutual authentication — https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
- Cilium network policy — https://docs.cilium.io/en/stable/security/policy/