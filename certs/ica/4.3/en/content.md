# 4.3 Securing Edge Traffic with TLS

## 1. The architectural problem: the edge is the trust boundary

Inside a well-configured Istio mesh, every hop between workloads is already encrypted and mutually authenticated by the sidecar proxies (PeerAuthentication `STRICT` + Istio-issued mTLS). But that guarantee **stops at the mesh boundary**. A client on the public internet does not have an Istio sidecar, does not hold a SPIFFE identity, and does not speak Istio mutual TLS. The first packet a browser or partner API sends arrives at the **ingress gateway** — a standalone Envoy running *without* an application container next to it — and everything before that Envoy is untrusted network.

Securing edge traffic with TLS is therefore about three distinct decisions, and confusing them is the most common production incident in this area:

1. **Where does TLS terminate?** At the gateway (termination), at the backend pod (passthrough), or both with re-encryption on the mesh side?
2. **Who authenticates whom?** Server-only TLS (the client trusts the server), or mutual TLS at the edge (the gateway also demands a client certificate from external callers)?
3. **How do the private keys reach Envoy?** Mounted as files into the gateway pod (requires a redeploy to rotate) or delivered dynamically over the **Secret Discovery Service (SDS)** from a Kubernetes secret (hot-reloaded, no restart)?

The failure modes are asymmetric and expensive. Terminate where you shouldn't and you have plaintext on a wire you assumed was encrypted. Mount a key as a file and a certificate rotation now needs a rolling restart of the ingress during which connections drop. Put the TLS secret in the wrong namespace and the gateway silently serves the *previous* certificate — or none — while every free check (DNS, the LoadBalancer, the VirtualService) still passes. This topic is weighted 8 because the edge is simultaneously the most exposed surface and the one where a misconfiguration is invisible until a client sees a certificate error.

The reference model to hold in your head:

```
                          ┌──────────────────── Istio mesh (mTLS everywhere) ─────────────┐
   Internet               │                                                               │
   client ──TLS/443──▶ istio-ingressgateway ──ISTIO_MUTUAL──▶ sidecar ──▶ app pod         │
   (browser,          (Envoy, no app          (re-encrypted,        (plaintext localhost) │
    partner API)       container)              SPIFFE identity)                           │
                          │                                                               │
                          └───────────────────────────────────────────────────────────────┘
      ▲ untrusted network ▲ trust boundary ▲ authenticated, encrypted intra-mesh
```

The gateway is where a certificate the *public* trusts (from Let's Encrypt, DigiCert, an internal PKI) is presented, and where Istio's own SPIFFE-based mTLS begins on the inside.

---

## 2. A taxonomy of edge TLS modes

### 2.1 Termination vs. passthrough vs. re-encryption

| Strategy | TLS terminates at | Gateway can route on L7 (path/header)? | Backend sees | When to use |
|---|---|---|---|---|
| **Edge termination** (`SIMPLE`/`MUTUAL`) | Ingress gateway | **Yes** — Envoy decrypts, so HTTP routing, header rewrites, retries all work | plaintext (then re-encrypted by sidecar mTLS to the app) | The default. You control the mesh and want L7 features + observability. |
| **Passthrough** (`PASSTHROUGH`) | Backend pod | **No** — Envoy only sees the TLS handshake; routes by **SNI** only | the original ciphertext, end-to-end | The backend must own the private key (regulatory), or it terminates a protocol Istio shouldn't decrypt. |
| **Re-encryption** | Gateway, then re-encrypts to backend | Yes at the edge | new TLS session (mesh mTLS) | This *is* the normal Istio behavior: `SIMPLE` termination at the edge + `ISTIO_MUTUAL` sidecar mTLS to the app. |

The subtle point most operators miss: with Istio you almost never do "plaintext to the backend." Edge termination + sidecar mTLS *is* re-encryption. The gateway decrypts the client's TLS, applies L7 policy, then the gateway's own sidecar-equivalent re-encrypts with Istio mTLS to the destination workload. You get L7 control **and** wire encryption all the way to the pod.

### 2.2 The `tls.mode` field — the whole decision surface

| `mode` | Gateway presents server cert? | Gateway verifies client cert? | TLS terminated? | Primary use |
|---|---|---|---|---|
| `SIMPLE` | Yes | No | Yes | Standard HTTPS termination (browser → gateway). |
| `MUTUAL` | Yes | **Yes** (against CA) | Yes | Edge mTLS: only clients holding a cert signed by your CA get through. |
| `OPTIONAL_MUTUAL` | Yes | If presented | Yes | Migration: accept both mTLS and one-way TLS clients during rollout. |
| `PASSTHROUGH` | No | No | **No** — SNI routing only | Backend terminates TLS; gateway is a dumb L4 SNI router. |
| `ISTIO_MUTUAL` | Uses Istio certs | Uses Istio certs | Yes | mTLS using the mesh's own SPIFFE certs (typically east-west / mesh-internal gateways, not public edge). |
| `AUTO_PASSTHROUGH` | No | No | No | Multi-cluster east-west gateways; routes by SNI encoding cluster/endpoint. Not a public-edge mode. |

Only `SIMPLE`, `MUTUAL`, `OPTIONAL_MUTUAL` and `PASSTHROUGH` are edge-facing choices. `ISTIO_MUTUAL` and `AUTO_PASSTHROUGH` are mesh-plumbing modes and appear on internal gateways.

### 2.3 How the key reaches Envoy: SDS vs. file mount

| | **SDS (`credentialName`)** | **File mount (`serverCertificate`/`privateKey`)** |
|---|---|---|
| Source | Kubernetes Secret, pushed by istiod over gRPC SDS | Files baked into / mounted onto the gateway pod |
| Rotation | Hot-reload, **no restart**, no dropped connections | Requires re-mounting → **rolling restart** of the gateway |
| Blast radius of a bad cert | One secret | The whole gateway deployment |
| cert-manager integration | Native (it writes a Secret) | Awkward (needs volume plumbing) |
| Namespace constraint | Secret must live where the **gateway workload** runs (default `istio-system`) | N/A |
| Recommendation | **Always prefer this.** | Legacy / air-gapped only. |

**The single most important operational fact in this topic:** with `credentialName`, the referenced Secret must exist in the **namespace of the ingress gateway deployment** (by default `istio-system`), **not** the namespace of the `Gateway` resource or the application. This mismatch is the number-one silent edge-TLS failure. (Cross-namespace secret references are possible only via the Kubernetes Gateway API with a `ReferenceGrant`, covered in §10.)

---

## 3. Anatomy of the ingress gateway

The ingress gateway is a `Deployment` + `Service` of type `LoadBalancer` created by the Istio install. It is a plain Envoy with no application container — it exists to receive external traffic and apply `Gateway` + `VirtualService` config.

```
$ kubectl get deploy,svc -n istio-system -l istio=ingressgateway
NAME                                   READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/istio-ingressgateway   1/1     1            1           14d

NAME                           TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                                      AGE
service/istio-ingressgateway   LoadBalancer   10.96.114.201   203.0.113.10    15021:31021/TCP,80:30080/TCP,443:31443/TCP   14d
```

Note the port mapping. The **service** exposes 80 and 443, but the Envoy container binds unprivileged ports internally (`8080`, `8443`) because it runs as non-root:

```
$ kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}{" -> "}{.targetPort}{"\n"}{end}'
status-port     15021 -> 15021
http2           80 -> 8080
https           443 -> 8443
```

Consequence you *will* hit while debugging: you configure the `Gateway` with `port.number: 443` (the **service** port), but `istioctl proxy-config listener` reports the Envoy listener on **8443**. Both are correct; they're different layers.

Capture the ingress address once and reuse it:

```
$ export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ export SECURE_INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
    -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
$ echo "$INGRESS_HOST:$SECURE_INGRESS_PORT"
203.0.113.10:443
```

(On clusters without an external LoadBalancer — kind, minikube, bare-metal without MetalLB — read `.spec.ports[?(@.name=="https")].nodePort` and use a node IP instead.)

---

## 4. Simple TLS termination — the complete path

### 4.1 Generate a CA and a server certificate (lab PKI)

In production these come from cert-manager or your PKI (§9); here we build them by hand so every field is visible.

```
$ mkdir -p certs && cd certs

# Root CA
$ openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
    -subj '/O=Example Inc./CN=example.com' \
    -keyout example.com.key -out example.com.crt
Generating a RSA private key
............................+++++
writing new private key to 'example.com.key'
-----

# Server key + CSR for httpbin.example.com
$ openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
    -keyout httpbin.example.com.key \
    -subj '/CN=httpbin.example.com/O=httpbin organization'

# Sign the server cert with the CA, adding a SAN (browsers require SAN, not CN)
$ openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
    -set_serial 1 -in httpbin.example.com.csr \
    -extfile <(printf "subjectAltName=DNS:httpbin.example.com") \
    -out httpbin.example.com.crt
Certificate request self-signature ok
subject=CN = httpbin.example.com, O = httpbin organization
```

### 4.2 Create the SDS secret **in the gateway's namespace**

```
$ kubectl create -n istio-system secret tls httpbin-credential \
    --key=httpbin.example.com.key \
    --cert=httpbin.example.com.crt
secret/httpbin-credential created
```

A `kubernetes.io/tls` secret holds exactly `tls.crt` and `tls.key`. That is all `SIMPLE` mode needs.

### 4.3 The `Gateway` resource

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: istio-system          # co-located with the workload; keeps secret + gateway together
spec:
  selector:
    istio: ingressgateway          # binds this config to the ingress gateway pods
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential   # -> secret httpbin-credential in THIS namespace
      minProtocolVersion: TLSV1_2          # refuse TLS 1.0/1.1 at the edge
    hosts:
    - httpbin.example.com
```

### 4.4 The `VirtualService` that actually routes the request

A `Gateway` opens a port and terminates TLS; it does **not** decide where the request goes. You always pair it with a `VirtualService`. Terminating TLS with no bound `VirtualService` is the classic "handshake succeeds, then 404" symptom.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
  namespace: default
spec:
  hosts:
  - httpbin.example.com
  gateways:
  - istio-system/httpbin-gateway    # namespace/name — MUST match the Gateway's location
  http:
  - match:
    - uri:
        prefix: /status
    - uri:
        prefix: /delay
    route:
    - destination:
        host: httpbin.default.svc.cluster.local
        port:
          number: 8000
```

Two cross-references that must line up exactly, or you get a silent 404:
- `VirtualService.spec.hosts` ⊇ the host the client sends (and ⊆ the `Gateway` server's `hosts`).
- `VirtualService.spec.gateways` names the gateway as `namespace/name`. A bare `httpbin-gateway` is resolved in the VirtualService's *own* namespace (`default`), which will not find a gateway in `istio-system`.

### 4.5 Deploy the sample backend and apply everything

```
$ kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/httpbin/httpbin.yaml
serviceaccount/httpbin created
service/httpbin created
deployment.apps/httpbin created

$ kubectl apply -f httpbin-gateway.yaml -f httpbin-vs.yaml
gateway.networking.istio.io/httpbin-gateway created
virtualservice.networking.istio.io/httpbin created
```

### 4.6 Verify the handshake and the route end-to-end

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
* Added httpbin.example.com:443:203.0.113.10 to DNS cache
*   Trying 203.0.113.10:443...
* Connected to httpbin.example.com (203.0.113.10) port 443
* ALPN: curl offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.2 (IN), TLS handshake, Server hello (2):
* TLSv1.2 (IN), TLS handshake, Certificate (11):
* Server certificate:
*  subject: CN=httpbin.example.com; O=httpbin organization
*  start date: Aug  8 00:00:00 2026 GMT
*  expire date: Aug  8 00:00:00 2027 GMT
*  subjectAltName: host "httpbin.example.com" matched cert's "httpbin.example.com"
*  issuer: O=Example Inc.; CN=example.com
*  SSL certificate verify ok.
* using HTTP/2
> GET /status/418 HTTP/2
> Host: httpbin.example.com
>
< HTTP/2 418
< server: istio-envoy
< x-more-info: http://tools.ietf.org/html/rfc2324

    -=[ teapot ]=-
```

`SSL certificate verify ok` + `server: istio-envoy` + the expected status proves the full path: TLS terminated at the gateway with the right cert, and the `VirtualService` routed to the backend.

---

## 5. HTTP→HTTPS redirect and multi-host SNI

Real edges serve many hosts and must not accept plaintext. A single `Gateway` can carry multiple `server` blocks, each with its own SNI host set and its own certificate, plus a port-80 server that only issues a 301 redirect.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: edge-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  # 1) Plaintext port 80 exists ONLY to bounce clients to HTTPS.
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - httpbin.example.com
    - api.example.com
    tls:
      httpsRedirect: true          # 301 to https:// — no plaintext ever routed
  # 2) httpbin over its own cert.
  - port:
      number: 443
      name: https-httpbin
      protocol: HTTPS
    hosts:
    - httpbin.example.com
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential
      minProtocolVersion: TLSV1_2
  # 3) api on a different cert — Envoy selects the cert by SNI.
  - port:
      number: 443
      name: https-api
      protocol: HTTPS
    hosts:
    - api.example.com
    tls:
      mode: SIMPLE
      credentialName: api-credential
      minProtocolVersion: TLSV1_2
```

Two servers can share port 443 because Envoy demultiplexes on the **SNI** in the ClientHello and presents the matching certificate. This is why a client that omits SNI (e.g. `curl https://203.0.113.10` with no `Host`/`--resolve`) gets a TLS error, not a helpful HTTP response — Envoy has no way to pick a certificate.

Verify the redirect:

```
$ curl -sI -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:80:$INGRESS_HOST" \
    "http://httpbin.example.com/status/200"
HTTP/1.1 301 Moved Permanently
location: https://httpbin.example.com/status/200
server: istio-envoy
```

Verify SNI-based cert selection:

```
$ echo | openssl s_client -connect "$INGRESS_HOST:443" -servername api.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN = api.example.com, O = Example Inc.

$ echo | openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN = httpbin.example.com, O = httpbin organization
```

Same IP, same port, two different certificates — selected purely by SNI.

---

## 6. Mutual TLS at the edge (`MUTUAL`)

Edge mTLS makes the gateway demand a client certificate signed by a CA you trust — the standard pattern for B2B/partner APIs and zero-trust ingress. The client is authenticated by **cryptographic possession of a key**, not an API token.

### 6.1 Build a client cert and the mTLS secret

```
$ openssl req -out client.example.com.csr -newkey rsa:2048 -nodes \
    -keyout client.example.com.key -subj '/CN=client.example.com/O=partner org'
$ openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
    -set_serial 2 -in client.example.com.csr -out client.example.com.crt
Certificate request self-signature ok
```

For `MUTUAL`, the SDS secret needs the CA that signs **client** certs in addition to the server keypair. Create a generic secret carrying `tls.crt`, `tls.key`, and `ca.crt`:

```
$ kubectl create -n istio-system secret generic httpbin-credential-mtls \
    --from-file=tls.key=certs/httpbin.example.com.key \
    --from-file=tls.crt=certs/httpbin.example.com.crt \
    --from-file=ca.crt=certs/example.com.crt
secret/httpbin-credential-mtls created
```

> Istio locates the client-verification CA two ways: the `ca.crt` key inside the same secret (shown here), **or** a separate secret named `<credentialName>-cacert`. The single-secret form is cleaner and rotates atomically.

### 6.2 Gateway in `MUTUAL` mode

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: httpbin-mtls-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: MUTUAL
      credentialName: httpbin-credential-mtls   # provides server keypair + ca.crt for client verification
      minProtocolVersion: TLSV1_2
    hosts:
    - httpbin.example.com
```

### 6.3 Prove it rejects unauthenticated clients and accepts authenticated ones

Without a client cert — rejected during the handshake:

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:443:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    "https://httpbin.example.com/status/200"
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.2 (IN), TLS handshake, Server hello (2):
* TLSv1.2 (IN), TLS handshake, Request CERT (13):
* TLSv1.2 (OUT), TLS alert, unknown CA (560):
* OpenSSL/3.0.2: error:0A000418:SSL routines::tlsv1 alert unknown ca
curl: (35) error:0A000418:SSL routines::tlsv1 alert unknown ca
```

With the client cert + key — accepted:

```
$ curl -v -HHost:httpbin.example.com \
    --resolve "httpbin.example.com:443:$INGRESS_HOST" \
    --cacert certs/example.com.crt \
    --cert certs/client.example.com.crt \
    --key certs/client.example.com.key \
    "https://httpbin.example.com/status/200"
* TLSv1.2 (IN), TLS handshake, Request CERT (13):
* TLSv1.2 (OUT), TLS handshake, Certificate (11):
* TLSv1.2 (OUT), TLS handshake, Finished (20):
* SSL certificate verify ok.
< HTTP/2 200
< server: istio-envoy
```

### 6.4 mTLS authenticates the connection, it does not authorize the identity

`MUTUAL` proves the client holds *a* cert signed by your CA — it does **not** restrict *which* client. To authorize by identity, layer an `AuthorizationPolicy` on the ingress that matches the certificate's subject/SAN. Istio exposes the verified client identity via the `X-Forwarded-Client-Cert` (XFCC) header and as a request principal:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-known-partners
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
  - from:
    - source:
        # SAN/DN pulled from the presented client certificate
        principals: ["client.example.com", "partner-b.example.com"]
```

Now a valid-but-unlisted cert completes the handshake yet gets a `403 RBAC: access denied`. This separation — authentication at the TLS layer, authorization at the policy layer — is the exam-relevant mental model.

---

## 7. TLS passthrough — SNI routing without decryption

When the backend must terminate TLS itself (it owns the key for compliance, or it speaks a protocol Istio should not touch), use `PASSTHROUGH`. The gateway becomes a Layer-4 router that reads only the SNI from the ClientHello and forwards the encrypted stream untouched.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: passthrough-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH        # gateway holds NO cert; it never decrypts
    hosts:
    - nginx.example.com
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nginx
  namespace: istio-system
spec:
  hosts:
  - nginx.example.com
  gateways:
  - passthrough-gateway
  tls:                          # NOTE: tls match, not http — there is no L7 to match on
  - match:
    - port: 443
      sniHosts:
      - nginx.example.com       # sniHosts is mandatory in passthrough; it's the only routing key
    route:
    - destination:
        host: my-nginx.default.svc.cluster.local
        port:
          number: 443
```

Critical differences from termination, and common exam traps:
- The `VirtualService` uses a **`tls`** match block with **`sniHosts`**, not an `http` block. There is no decrypted request, so path/header matching is impossible.
- `sniHosts` is **required**. Omitting it means nothing routes.
- The backend pod presents its own certificate; the client's trust chain must validate against *that* cert, and the gateway's certificate is irrelevant.

You cannot combine passthrough with any L7 feature — retries, header rewrites, path routing, or observability of URLs — because the gateway never sees plaintext. That is the price of end-to-end encryption to the pod.

---

## 8. Protocol and cipher hardening

Compliance regimes (PCI-DSS, FedRAMP) mandate a minimum TLS version and an approved cipher list. Configure these per-server:

```yaml
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential
      minProtocolVersion: TLSV1_2        # reject TLS 1.0 / 1.1
      maxProtocolVersion: TLSV1_3
      cipherSuites:                      # applies to TLS 1.2 and below ONLY
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
```

| Field | Meaning | Gotcha |
|---|---|---|
| `minProtocolVersion` | Lowest TLS version accepted | Default is Envoy's default (currently TLS 1.2). Set it explicitly for auditability. |
| `maxProtocolVersion` | Highest TLS version accepted | Rarely restricted; leave at TLS 1.3. |
| `cipherSuites` | Allowed cipher list | **Ignored for TLS 1.3** — its cipher suites are fixed by the RFC and not configurable in Envoy. `cipherSuites` only constrains TLS ≤ 1.2. |

Mesh-wide defaults can be set once in the `MeshConfig` (`meshConfig.tlsDefaults.minProtocolVersion`, `.cipherSuites`) so every gateway and sidecar inherits them; the per-`Gateway` fields then override only where needed.

Verify what the edge actually negotiates — never trust the manifest, trust the wire:

```
# Should fail: TLS 1.1 must be refused
$ openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com -tls1_1 2>&1 | grep -E 'Protocol|handshake failure|alert'
140704...:error:0A0000102:SSL routines::unsupported protocol
* TLSv1.1 (OUT), TLS alert, protocol version (582):

# Should succeed: TLS 1.3, and report the negotiated cipher
$ openssl s_client -connect "$INGRESS_HOST:443" -servername httpbin.example.com -tls1_3 2>/dev/null \
    | grep -E 'Protocol|Cipher'
    Protocol  : TLSv1.3
    Cipher    : TLS_AES_256_GCM_SHA384
```

Scan the full negotiated posture with `nmap`:

```
$ nmap --script ssl-enum-ciphers -p 443 "$INGRESS_HOST"
PORT    STATE SERVICE
443/tcp open  https
| ssl-enum-ciphers:
|   TLSv1.2:
|     ciphers:
|       TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|       TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 (secp256r1) - A
|     cipher preference: server
|   TLSv1.3:
|     ciphers:
|       TLS_AES_256_GCM_SHA384 (ecdh_x25519) - A
|_  least strength: A
```

No TLSv1.0/1.1 sections = the floor is enforced.

---

## 9. Automating certificates with cert-manager

Hand-rolled certs are for labs; production edges use cert-manager to issue and **rotate** certificates automatically. Because Istio's `credentialName` reads a Kubernetes Secret and hot-reloads it over SDS, cert-manager integrates with zero glue: cert-manager writes the Secret, istiod pushes it to the gateway, no restart.

`ClusterIssuer` (ACME / Let's Encrypt, HTTP-01 solved through the same ingress gateway):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: istio
```

`Certificate` — cert-manager writes the resulting keypair into `istio-system` where the gateway will read it:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin-example-com
  namespace: istio-system          # MUST be the gateway's namespace for credentialName to see it
spec:
  secretName: httpbin-credential   # <-- exactly the name the Gateway references
  duration: 2160h                  # 90d
  renewBefore: 360h                # rotate 15d before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  dnsNames:
  - httpbin.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

The `Gateway` from §4.3 needs no change — it already references `credentialName: httpbin-credential`. Observe issuance and rotation:

```
$ kubectl get certificate -n istio-system httpbin-example-com
NAME                  READY   SECRET               AGE
httpbin-example-com   True    httpbin-credential   47s

$ kubectl describe certificate -n istio-system httpbin-example-com | grep -A4 Events
Events:
  Type    Reason     Age   From          Message
  ----    ------     ----  ----          -------
  Normal  Issuing    50s   cert-manager  Issuing certificate as Secret does not exist
  Normal  Requested  49s   cert-manager  Created new CertificateRequest resource
  Normal  Issued     18s   cert-manager  Certificate issued successfully
```

When cert-manager rotates the Secret, istiod detects the change and SDS-pushes the new cert to the running gateway. Confirm the live gateway picked it up without a restart in §11.

For an internal PKI instead of ACME, swap the `ClusterIssuer` for a `ca` issuer (a Secret holding your intermediate CA) or a `vault`/`venafi` issuer — the `Certificate` and `Gateway` are unchanged.

---

## 10. The Kubernetes Gateway API equivalent

Istio implements the upstream **Kubernetes Gateway API** (`gateway.networking.k8s.io`) alongside its own CRDs. For new edge deployments this is the direction of travel; the exam expects familiarity with the mapping.

Simple termination expressed in Gateway API:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: default
spec:
  gatewayClassName: istio          # provisions a dedicated gateway Deployment/Service
  listeners:
  - name: https
    hostname: httpbin.example.com
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate              # == Istio SIMPLE
      certificateRefs:
      - kind: Secret
        name: httpbin-credential
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: default
spec:
  parentRefs:
  - name: httpbin-gateway
  hostnames:
  - httpbin.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /status
    backendRefs:
    - name: httpbin
      port: 8000
```

Concept translation:

| Istio API | Kubernetes Gateway API |
|---|---|
| `Gateway` (`networking.istio.io`) | `Gateway` (`gateway.networking.k8s.io`) + `GatewayClass` |
| `tls.mode: SIMPLE` | `tls.mode: Terminate` |
| `tls.mode: PASSTHROUGH` | `tls.mode: Passthrough` (on a `TLSRoute`) |
| `tls.credentialName` | `tls.certificateRefs[].name` |
| `VirtualService` (http) | `HTTPRoute` |
| `VirtualService` (tls/sni) | `TLSRoute` |
| Secret must be in `istio-system` | Secret is in the **`Gateway`'s** namespace; cross-namespace needs a `ReferenceGrant` |

Two important behavioral differences:
- With `gatewayClassName: istio`, Istio **provisions a new, dedicated gateway** Deployment+Service per `Gateway` object (in the `Gateway`'s namespace), rather than reusing the shared `istio-ingressgateway`. The certificate Secret therefore lives beside that gateway, not in `istio-system`.
- Cross-namespace certificate/backend references are a first-class, *explicit* grant (`ReferenceGrant`) rather than an implicit istio-system placement — a security improvement.

`ReferenceGrant` allowing a `Gateway` in `default` to read a Secret in `certs`:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-to-cert
  namespace: certs
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: default
  to:
  - group: ""
    kind: Secret
```

---

## 11. Verification and failure diagnosis

Edge TLS fails silently far more often than loudly. Work the ladder from "is the config accepted" up to "does the wire behave," and *independently confirm* the certificate actually loaded into the running Envoy — a `Gateway` that references a missing secret still applies cleanly.

### 11.1 Static config validation first (free, catches most mistakes)

```
$ istioctl analyze -n istio-system
Error [IST0101] (Gateway httpbin-gateway.istio-system) Referenced credentialName not found:
  "httpbin-credential" in namespace "istio-system"
Warning [IST0132] (VirtualService httpbin.default) one or more host [httpbin.example.com]
  defined in gateway istio-system/httpbin-gateway not found in the current namespace routes
```

`istioctl analyze` cross-checks Gateway↔Secret↔VirtualService binding and is the fastest way to catch the top-three failures (missing secret, wrong namespace, unbound host).

### 11.2 Confirm the cert is actually loaded into the running gateway

This is the check that separates "the secret exists" from "Envoy is serving it." SDS delivery can lag or fail even when the Secret is present.

```
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system
RESOURCE NAME                                   TYPE           STATUS     VALID CERT     SERIAL NUMBER   NOT AFTER                NOT BEFORE
kubernetes://httpbin-credential                 Cert Chain     ACTIVE     true           1               2027-08-08T00:00:00Z     2026-08-08T00:00:00Z
kubernetes://httpbin-credential-cacert          Cert Chain     ACTIVE     true           <n/a>           2027-08-08T00:00:00Z     2026-08-08T00:00:00Z
default                                          Cert Chain     ACTIVE     true           ...             ...                      ...
```

`STATUS: ACTIVE` + `VALID CERT: true` for `kubernetes://<credentialName>` is the proof the SDS push landed. If the row is missing, the secret is absent, in the wrong namespace, or malformed (wrong keys). Dump the full leaf to inspect SAN/expiry as Envoy sees it:

```
$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
    -o json | jq -r '.dynamicActiveSecrets[]
    | select(.name=="kubernetes://httpbin-credential")
    | .secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -subject -dates -ext subjectAltName
subject=CN = httpbin.example.com, O = httpbin organization
notBefore=Aug  8 00:00:00 2026 GMT
notAfter=Aug  8 00:00:00 2027 GMT
X509v3 Subject Alternative Name:
    DNS:httpbin.example.com
```

### 11.3 Confirm the listener and its filter chain exist

```
$ istioctl proxy-config listener deploy/istio-ingressgateway -n istio-system --port 8443
ADDRESS PORT  MATCH                          DESTINATION
0.0.0.0 8443  SNI: httpbin.example.com       Route: https.443.https.httpbin-gateway.istio-system
```

No row on 8443 ⇒ the `Gateway`'s HTTPS server never programmed a listener (usually a `selector` that matches no gateway pods, or an invalid TLS block). The `Route:` name is the join key to the `VirtualService`.

### 11.4 The access-log flags — read the response code Envoy assigns

```
$ kubectl logs -n istio-system deploy/istio-ingressgateway | tail -1
[2026-08-08T12:00:00.123Z] "GET /status/418 HTTP/2" 418 - via_upstream -
  "-" 0 135 4 3 "203.0.113.55" "curl/8.5.0" "b1e2..." "httpbin.example.com"
  "10.244.1.7:80" outbound|8000||httpbin.default.svc.cluster.local ...
```

The response-flags field is the fastest diagnosis in the mesh. The ones that show up at the TLS edge:

| Flag | Meaning at the edge | Likely cause |
|---|---|---|
| `NR` | No route configured | `VirtualService` not bound to this gateway, or host/SNI mismatch → **404** |
| `NC` | No cluster | Route matched but the destination `host`/`port` doesn't resolve to a service |
| `UF` | Upstream connection failure | Backend down, or **mesh mTLS mismatch** on the re-encrypt hop |
| `UH` | No healthy upstream | All backend endpoints unhealthy |
| `-` (via_upstream) | Success | Request reached the backend |

### 11.5 Symptom → cause quick table

| Symptom | Most likely cause | Confirm with |
|---|---|---|
| TLS handshake fails, no HTTP at all | Client sent no **SNI**; Envoy can't select a cert | add `--resolve`/`-servername`; `s_client -servername` works, bare IP fails |
| `curl: (60) SSL certificate problem: unable to get local issuer` | Client doesn't trust the server CA | `--cacert` with the issuing CA; check leaf SAN matches host |
| Handshake OK, then **404 not found** | `VirtualService` unbound or host mismatch | log flag `NR`; `istioctl analyze`; check `spec.gateways` = `ns/name` |
| Handshake OK, then **503 UF/UH** | Re-encrypt hop fails (mesh mTLS) or backend down | log flag `UF`/`UH`; check `PeerAuthentication`/`DestinationRule` |
| `unknown ca` alert during handshake | `MUTUAL` mode; client cert not signed by the gateway's `ca.crt` | provide `--cert/--key`; verify `ca.crt` in the secret |
| Gateway serves **old** certificate after rotation | Secret updated but in the wrong namespace, or SDS didn't push | `proxy-config secret` shows stale serial → fix namespace / restart istiod push |
| `503` only after a cert renew | File-mounted cert (not SDS) needs a restart | migrate to `credentialName`/SDS |

### 11.6 Prove hot rotation worked (no restart)

After cert-manager renews, the serial in the live gateway should change with **zero** gateway restarts:

```
$ kubectl get pods -n istio-system -l istio=ingressgateway   # note RESTARTS stays 0
NAME                                    READY   STATUS    RESTARTS   AGE
istio-ingressgateway-6b9c7c8f7-x4k2p    1/1     Running   0          14d

$ istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system \
    | grep httpbin-credential
kubernetes://httpbin-credential   Cert Chain   ACTIVE   true   4   2027-11-06T00:00:00Z   2026-08-08T00:00:00Z
#                                                              ^ serial incremented, RESTARTS still 0 → SDS hot-reload confirmed
```

---

## 12. References

- Istio — *Secure Gateways* (SIMPLE/MUTUAL TLS termination, `credentialName`/SDS): https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
- Istio — *Ingress Gateways* (Gateway + VirtualService binding): https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — *TLS Ingress with a file-mounted cert* (file vs SDS trade-off): https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/
- Istio API reference — `Gateway` / `Server` / `ServerTLSSettings` (`mode`, `minProtocolVersion`, `cipherSuites`, `httpsRedirect`): https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio API reference — `VirtualService` (`tls`/`sniHosts` routing for passthrough): https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — *Kubernetes Gateway API* support (`gatewayClassName: istio`, `ReferenceGrant`): https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/
- Istio — *Authorization Policy* (identity from client certs at the edge): https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — *Debugging Envoy and Istiod* / `istioctl proxy-config` (`secret`, `listener`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — *Global mesh TLS defaults* (`meshConfig.tlsDefaults`): https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Envoy — *TLS / transport socket* (cipher and TLS-version semantics, TLS 1.3 fixed ciphers): https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/transport_sockets/tls/v3/common.proto
- cert-manager — *Istio / Gateway certificate integration*: https://cert-manager.io/docs/usage/istio/
- Kubernetes Gateway API — *TLS configuration* (`Terminate`/`Passthrough`, `certificateRefs`, `ReferenceGrant`): https://gateway-api.sigs.k8s.io/guides/tls/
- CNCF — *ICA Curriculum* (Istio Certified Associate exam domains): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf