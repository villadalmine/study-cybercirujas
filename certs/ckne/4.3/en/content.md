# 4.3 Managing TLS Certificates for Gateway API

> **Exam weight: 6.24%.** This topic covers where TLS terminates in Gateway API, how a listener finds its certificate, who owns that certificate, how it is rotated, and how the Gateway re-encrypts traffic to backends. On the exam, most failures come from a Secret the Gateway is not allowed to read, or a listener whose hostname does not match its certificate. They rarely come from cryptography.

---

## 1. Motivation: the production problem

With the Ingress API, TLS was a flat list: `spec.tls[].secretName` plus `hosts`. It had three structural weaknesses:

1. **Ownership was mixed.** The team that wrote the Ingress also chose the certificate. In a multi-tenant cluster, any application team could put a Secret in front of any hostname the controller served. Nothing modelled who was *allowed* to use a certificate.
2. **Cross-namespace references were not portable.** Each controller invented its own annotation to share a wildcard certificate across namespaces, with its own security model or none.
3. **Only the frontend hop was covered.** Re-encrypting traffic from the proxy to the Pod (backend TLS) was always done through implementation-specific annotations, so it was not portable.

Gateway API fixes this by splitting responsibilities by **role** and using explicit resources:

| Role (Gateway API persona) | Owns | TLS responsibility |
|---|---|---|
| Infrastructure provider | `GatewayClass` | Supported TLS modes, cipher suites, default protocol versions |
| Cluster operator / platform team | `Gateway`, `ReferenceGrant`, certificate issuance | Which listeners terminate TLS, with which certificates, for which hostnames |
| Application developer | `HTTPRoute`, `TLSRoute`, `BackendTLSPolicy`, the `Service` | Attaching routes to the listener, and the requirement that their backend speaks TLS |

The key architectural point is that **the certificate lives on the listener, not on the route**. An application team cannot bring its own certificate for a hostname. It can only attach routes to a listener the platform team has already configured with a valid certificate. That is the security model the exam expects you to use.

---

## 2. The three places TLS can live

```
            Client                    Gateway (proxy)                     Backend Pod
   ┌────────────────────┐   (1)   ┌──────────────────────┐   (3)   ┌──────────────────┐
   │ TLS ClientHello     │───────▶│ Listener :443        │───────▶│ Service :8443     │
   │ SNI=app.example.com │        │ tls.mode=Terminate   │  TLS    │ serving cert       │
   └────────────────────┘        │ certificateRefs ──▶ Secret      │ (issued by int. CA)│
                                  └──────────────────────┘         └──────────────────┘
        (2) tls.mode=Passthrough: the Gateway only reads SNI and forwards the
            encrypted TCP stream untouched → TLSRoute → the backend terminates.
```

| Segment | Gateway API mechanism | Who decrypts | Resource that carries the configuration |
|---|---|---|---|
| (1) Frontend termination | `listener.tls.mode: Terminate` | The Gateway | `Gateway.spec.listeners[].tls.certificateRefs` |
| (2) Passthrough | `listener.tls.mode: Passthrough` | The backend | `TLSRoute` (routes by SNI only) |
| (3) Backend re-encryption | `BackendTLSPolicy` | The backend (again) | `BackendTLSPolicy.spec.validation` |
| mTLS, client → Gateway | Frontend client-certificate validation | The Gateway validates the client certificate | `Gateway.spec.tls.frontend` (recent, check your channel) |
| mTLS, Gateway → backend | Gateway client certificate | The backend validates the Gateway | `Gateway.spec.tls.backend.clientCertificateRef` (experimental) |

### Terminate vs Passthrough: trade-offs

| Criterion | `Terminate` + `HTTPRoute` | `Passthrough` + `TLSRoute` |
|---|---|---|
| Layer 7 visibility (paths, headers, filters) | Full | None: only SNI is visible |
| Where the private key lives | In a Secret the Gateway can read | Only in the backend |
| Rotation | Centralised (cert-manager on the Gateway) | Per application |
| End-to-end encryption | Only with `BackendTLSPolicy` | Yes, by construction |
| Header-based observability, retries, redirects | Yes | No |
| Typical use | Web and API traffic | Databases, non-HTTP protocols, compliance rules that forbid the proxy seeing plaintext, applications that validate their own client certificates |
| Maturity | `HTTPRoute`: Standard channel | `TLSRoute` spent most of its life in the Experimental channel. Check which channel your installed CRDs ship it in |

Rule of thumb: **Terminate** when the platform has to apply L7 policy. **Passthrough** when the backend has to own the cryptographic identity.

---

## 3. The certificate as a Kubernetes object

`certificateRefs` points by default to a `Secret` of type `kubernetes.io/tls` with two keys: `tls.crt` (the PEM chain, leaf first) and `tls.key` (the PEM private key).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-example-com-tls
  namespace: infra-gateway
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJ...  # base64 of the full PEM chain
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JSUV...  # base64 of the PEM key
```

A Secret is almost never written by hand. To create one from files:

```
$ kubectl create secret tls app-example-com-tls \
    --cert=fullchain.pem --key=privkey.pem -n infra-gateway
secret/app-example-com-tls created
```

`kubectl create secret tls` checks that the key matches the certificate before it creates the object. That is the first free check you get.

Production details that break real deployments:

- **The intermediate chain belongs in `tls.crt`.** If you put only the leaf, `curl` on your laptop may still work because it has cached intermediates. Minimal clients (Go, Java without AIA fetching, IoT devices) fail with `unable to get local issuer certificate`.
- **Key types.** RSA 2048+ and ECDSA P-256 are universal. Ed25519 in `tls.key` is not supported by every data plane.
- **Size limit.** A Secret has a 1 MiB limit, which only matters if you bundle huge CA sets.

---

## 4. Listeners with TLS: complete manifests

### 4.1 GatewayClass and Gateway with HTTPS termination, plus an HTTP→HTTPS redirect

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: prod-gw-class
spec:
  controllerName: example.net/gateway-controller   # replace with your implementation's controllerName
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: infra-gateway
spec:
  gatewayClassName: prod-gw-class
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https-app
      protocol: HTTPS
      port: 443
      hostname: app.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: app-example-com-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access/edge: "true"
    - name: https-wildcard
      protocol: HTTPS
      port: 443
      hostname: "*.apps.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: wildcard-apps-example-com-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access/edge: "true"
```

Points to understand:

- **Two listeners on the same port 443 are legal** because their `hostname` values differ. The data plane chooses the listener, and so the certificate, **by the client's SNI**. The spec calls such a set of listeners *distinct*: same port and protocol, different hostnames.
- **The most specific match wins.** A request with SNI `app.example.com` uses the `https-app` listener. `foo.apps.example.com` uses the wildcard. The wildcard covers **one** DNS label: `a.b.apps.example.com` does not match.
- `"*.apps.example.com"` is **quoted**. Without the quotes, YAML reads the `*` as an alias.
- A listener with `protocol: HTTPS` **requires** `tls`. A listener with `protocol: HTTP` must not have it.
- `certificateRefs` is a list. Some implementations accept several certificates (for example RSA and ECDSA) and pick one based on what the client supports. The spec only requires support for at least one, so check your implementation before you depend on a second.

The route and the redirect, owned by the application team:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-https
  namespace: team-app
spec:
  parentRefs:
    - name: edge
      namespace: infra-gateway
      sectionName: https-app
  hostnames:
    - app.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app
          port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: infra-gateway
spec:
  parentRefs:
    - name: edge
      namespace: infra-gateway
      sectionName: http
  hostnames:
    - app.example.com
    - "*.apps.example.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

The redirect lives in `infra-gateway` because the `http` listener only accepts routes from its own namespace (`from: Same`). That is deliberate: the platform team controls which plaintext traffic is accepted.

The `team-app` namespace needs the label that `allowedRoutes` selects on:

```
$ kubectl label namespace team-app gateway-access/edge=true
namespace/team-app labeled
```

### 4.2 Cross-namespace certificates: `ReferenceGrant`

A common pattern is to keep certificates in a locked-down namespace (`certs`) that only the security team and cert-manager can write to, while the Gateway lives in `infra-gateway`. A `certificateRef` to another namespace is **rejected by default**. The owner of the target namespace has to allow it explicitly:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge-shared-certs
  namespace: infra-gateway
spec:
  gatewayClassName: prod-gw-class
  listeners:
    - name: https-api
      protocol: HTTPS
      port: 443
      hostname: api.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: api-example-com-tls
            namespace: certs
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-infra-gateway-to-read-tls
  namespace: certs
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: infra-gateway
  to:
    - group: ""
      kind: Secret
      name: api-example-com-tls
```

Rules to memorise:

- **The `ReferenceGrant` lives in the target namespace** (where the Secret is), never in the source namespace. Only the owner of a resource can grant access to it.
- `from` identifies **kind and namespace**, not the name of a specific Gateway. Every Gateway in `infra-gateway` can use the Secret.
- `to.name` is optional. Without it, the grant covers **every Secret in the namespace**. In production, always restrict by name.
- `ReferenceGrant` is served at `v1beta1` in the Standard channel. Check with `kubectl api-resources | grep referencegrant` which version your installed CRDs serve.
- Delete the `ReferenceGrant` and the controller must **stop using** the certificate. The listener goes to `ResolvedRefs=False`, and depending on the implementation it stops serving that hostname. That makes it a revocation mechanism.

### 4.3 Passthrough with `TLSRoute`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge-passthrough
  namespace: infra-gateway
spec:
  gatewayClassName: prod-gw-class
  listeners:
    - name: tls-passthrough
      protocol: TLS
      port: 8443
      hostname: db.example.com
      tls:
        mode: Passthrough
      allowedRoutes:
        kinds:
          - kind: TLSRoute
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access/edge: "true"
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: db-passthrough
  namespace: team-app
spec:
  parentRefs:
    - name: edge-passthrough
      namespace: infra-gateway
      sectionName: tls-passthrough
  hostnames:
    - db.example.com
  rules:
    - backendRefs:
        - name: postgres-tls
          port: 5432
```

In `Passthrough` mode, **`certificateRefs` must not be set**, because the Gateway has no key. Before you use a `TLSRoute`, check which API version your CRDs serve (`kubectl explain tlsroute | head`). It has historically been `v1alpha2` in the Experimental channel. On newer Gateway API releases it may be served under another version or promoted, so write the manifest for the version your cluster actually serves.

---

## 5. Automated issuance and rotation with cert-manager

Rotating certificates by hand does not scale, and a forgotten expiry is one of the most common causes of production outages. cert-manager integrates with Gateway API in two ways:

1. **Gateway shim (annotation):** annotate the `Gateway`, and cert-manager creates a `Certificate` for each listener that has `hostname`, `tls.mode: Terminate` and a `certificateRef` to a Secret **in the same namespace as the Gateway**.
2. **ACME HTTP-01 solver over Gateway API:** cert-manager creates a temporary `HTTPRoute` that answers `/.well-known/acme-challenge/...`.

Gateway API support has to be enabled explicitly. With Helm, in recent versions:

```
$ helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
    --set config.kind=ControllerConfiguration \
    --set config.enableGatewayAPI=true
```

On older versions the equivalent is the controller flag `--enable-gateway-api`. **The Gateway API CRDs must be installed before cert-manager starts.** If they are not, cert-manager logs that it cannot find them and ignores Gateways until you restart it:

```
$ kubectl -n cert-manager rollout restart deployment cert-manager
deployment.apps/cert-manager restarted
```

### 5.1 Issuers: HTTP-01 (single hostnames) and DNS-01 (wildcards)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-http01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform-team@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: edge
                namespace: infra-gateway
                kind: Gateway
                sectionName: http
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform-team@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-dns01-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
        selector:
          dnsZones:
            - example.com
```

- **HTTP-01 cannot issue wildcards.** The ACME protocol (RFC 8555) only allows `*.domain` through DNS-01.
- The HTTP-01 `parentRefs` must point to a listener on **port 80** that accepts routes from the namespace where cert-manager creates the solver's `HTTPRoute`. That is the namespace of the `Certificate`, which with the shim is the Gateway's namespace. If `allowedRoutes` does not allow that namespace, the challenge never becomes reachable.

### 5.2 Gateway annotated for automatic issuance

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge
  namespace: infra-gateway
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod-http01
spec:
  gatewayClassName: prod-gw-class
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https-app
      protocol: HTTPS
      port: 443
      hostname: app.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            group: ""
            name: app-example-com-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access/edge: "true"
```

What cert-manager generates, as seen in the cluster:

```
$ kubectl get certificate -n infra-gateway
NAME                  READY   SECRET                AGE
app-example-com-tls   True    app-example-com-tls   3m12s

$ kubectl get certificate app-example-com-tls -n infra-gateway -o jsonpath='{.spec.dnsNames}{"\n"}'
["app.example.com"]
```

The shim's limits, which justify writing the `Certificate` explicitly instead:

| Situation | Shim (annotation) | Explicit `Certificate` |
|---|---|---|
| One certificate per listener, same namespace | Ideal | Works, but more YAML |
| Wildcard with DNS-01 | Works if the annotation points at the DNS-01 issuer | Works |
| Certificate in another namespace (`certs`) + `ReferenceGrant` | **Not supported**: the shim ignores refs to other namespaces | Required |
| One SAN certificate shared by several listeners | Limited | Full control of `dnsNames` |
| Key algorithm, `duration`, `renewBefore`, `rotationPolicy` | Only through additional annotations | Full control |

Explicit `Certificate` for the shared wildcard:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-apps-example-com
  namespace: certs
spec:
  secretName: wildcard-apps-example-com-tls
  issuerRef:
    name: letsencrypt-prod-dns01
    kind: ClusterIssuer
    group: cert-manager.io
  dnsNames:
    - "*.apps.example.com"
    - apps.example.com
  duration: 2160h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
```

`rotationPolicy: Always` generates a **new key** on every renewal, which is the default in recent cert-manager versions. Rotation is seamless: cert-manager updates the Secret in place, the Gateway controller watches the Secret and reprograms the data plane without restarting it. Existing connections keep the old certificate until they close, and new handshakes get the new one.

### 5.3 Rotation lifecycle

```
Certificate (READY=True) ──renewBefore reached──▶ CertificateRequest ──▶ Order ──▶ Challenge
        ▲                                                                                  │
        │                  Secret updated (tls.crt / tls.key)  ◀──────── issued ───────────┘
        │                                  │
        └──── Gateway controller watches ──┘──▶ data plane reloads the certificate (SNI → new cert)
```

---

## 6. Backend TLS: `BackendTLSPolicy`

Terminating at the Gateway leaves the Gateway→Pod hop in plaintext. In zero-trust or regulated environments (PCI-DSS, HIPAA), that hop also has to be encrypted and the backend's identity **validated**. `BackendTLSPolicy` is a *policy attachment* resource: it targets a `Service` and tells every Gateway that routes to it how to open TLS to that Service.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: internal-ca
  namespace: team-app
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIUK1x9...replace-with-your-internal-CA-PEM...
    -----END CERTIFICATE-----
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: team-app
spec:
  selector:
    app: payments
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      appProtocol: https
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: payments-backend-tls
  namespace: team-app
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: payments
      sectionName: https
  validation:
    caCertificateRefs:
      - group: ""
        kind: ConfigMap
        name: internal-ca
    hostname: payments.team-app.svc.cluster.local
```

Semantics:

- `validation.hostname` has two jobs: it is **the SNI the Gateway sends** to the backend, and it is the name checked against the backend certificate's SAN. The backend's serving certificate must include that name.
- `caCertificateRefs` (a ConfigMap with the `ca.crt` key) and `wellKnownCACertificates: System` (the data plane's public trust store) are **mutually exclusive**. Use the internal CA for in-cluster services and `System` for external backends with public certificates.
- `subjectAltNames` (optional) lets you validate a URI SAN, for example a SPIFFE ID such as `spiffe://cluster.local/ns/team-app/sa/payments`, instead of the hostname.
- `sectionName` limits the policy to one port of the Service. Without it, the policy applies to every port.
- **Version:** `BackendTLSPolicy` was `v1alpha3` in the Experimental channel and graduated to the Standard channel as `v1` in recent Gateway API releases. On an older cluster, write `apiVersion: gateway.networking.k8s.io/v1alpha3`. Always check with `kubectl api-resources | grep -i backendtls`.

A policy reports its status **per ancestor**, meaning per Gateway that uses it:

```
$ kubectl get backendtlspolicy payments-backend-tls -n team-app \
    -o jsonpath='{range .status.ancestors[*]}{.ancestorRef.name}{" "}{.conditions[?(@.type=="Accepted")].status}{" "}{.conditions[?(@.type=="Accepted")].reason}{"\n"}{end}'
edge True Accepted
```

### mTLS at the edge (introduction)

Gateway API has been adding **client certificate validation** at the frontend (`Gateway.spec.tls.frontend`, with `caCertificateRefs` and per-port overrides) and **a client certificate the Gateway presents to backends** (`Gateway.spec.tls.backend.clientCertificateRef`). These are the newest fields of the TLS model. Their location in the spec moved between releases (per listener in early versions, per Gateway later), and not every implementation supports them. On the exam and in production, first check that the field appears in `kubectl explain gateway.spec.tls` on your cluster. If it does not, you will use the implementation's own policy (for example, its own ClientTrafficPolicy or equivalent).

---

## 7. Verification and diagnostics

### 7.1 The Gateway's status is the source of truth

Each listener publishes conditions. For TLS, three matter:

| Condition | Healthy | TLS-related failure `reason` values |
|---|---|---|
| `ResolvedRefs` | `True` / `ResolvedRefs` | `InvalidCertificateRef` (Secret missing, wrong type, malformed PEM), `RefNotPermitted` (no `ReferenceGrant`) |
| `Accepted` | `True` / `Accepted` | `UnsupportedProtocol`, `HostnameConflict` (via `Conflicted`) |
| `Programmed` | `True` / `Programmed` | `Invalid`, `Pending`: the data plane has not loaded the config |

```
$ kubectl get gateway edge -n infra-gateway
NAME   CLASS           ADDRESS        PROGRAMMED   AGE
edge   prod-gw-class   203.0.113.10   True         41m

$ kubectl get gateway edge -n infra-gateway \
    -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
http            1   Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
https-app       1   Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
https-wildcard  0   Accepted=True(Accepted) Programmed=False(Invalid) ResolvedRefs=False(InvalidCertificateRef)
```

`attachedRoutes: 0` on `https-wildcard` combined with `InvalidCertificateRef` points to the Secret, not the routes:

```
$ kubectl describe gateway edge -n infra-gateway | sed -n '/Name:  *https-wildcard/,/Supported Kinds/p'
    Name:             https-wildcard
    Conditions:
      Last Transition Time:  2026-09-30T10:14:03Z
      Message:               Secret infra-gateway/wildcard-apps-example-com-tls does not exist.
      Reason:                InvalidCertificateRef
      Status:                False
      Type:                  ResolvedRefs
```

The exact text of `Message` depends on the implementation. `Reason` and `Type` are defined by the spec and are portable.

### 7.2 Inspecting the certificate in the Secret

```
$ kubectl get secret app-example-com-tls -n infra-gateway -o jsonpath='{.type}{"\n"}'
kubernetes.io/tls

$ kubectl get secret app-example-com-tls -n infra-gateway -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
subject=CN=app.example.com
issuer=C=US, O=Let's Encrypt, CN=R11
notBefore=Sep 12 08:21:44 2026 GMT
notAfter=Dec 11 08:21:43 2026 GMT
X509v3 Subject Alternative Name:
    DNS:app.example.com
```

Check that the key matches the certificate. The two hashes must be identical:

```
$ kubectl get secret app-example-com-tls -n infra-gateway -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -pubkey | openssl sha256
SHA2-256(stdin)= 4f1c0e9b7d2a...
$ kubectl get secret app-example-com-tls -n infra-gateway -o jsonpath='{.data.tls\.key}' | base64 -d \
    | openssl pkey -pubout | openssl sha256
SHA2-256(stdin)= 4f1c0e9b7d2a...
```

Count the certificates in the chain. A leaf alone is 1, and 2 or more means the intermediates are there:

```
$ kubectl get secret app-example-com-tls -n infra-gateway -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | grep -c 'BEGIN CERTIFICATE'
2
```

### 7.3 What the data plane actually serves (SNI)

```
$ GW=$(kubectl get gateway edge -n infra-gateway -o jsonpath='{.status.addresses[0].value}')

$ openssl s_client -connect "$GW:443" -servername app.example.com </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName
subject=CN=app.example.com
X509v3 Subject Alternative Name:
    DNS:app.example.com

$ curl -sv --resolve app.example.com:443:$GW https://app.example.com/ -o /dev/null 2>&1 \
    | grep -E 'SSL connection|subject:|issuer:|expire date|HTTP/'
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
*  subject: CN=app.example.com
*  expire date: Dec 11 08:21:43 2026 GMT
*  issuer: C=US; O=Let's Encrypt; CN=R11
> GET / HTTP/2
< HTTP/2 200
```

`--resolve` forces the correct SNI without touching DNS. That is essential for testing before cutting DNS over. **Always test with `-servername`.** Without SNI, the Gateway serves whatever default certificate it has (or aborts the handshake), and you will diagnose the wrong listener.

Checking the redirect:

```
$ curl -sI --resolve app.example.com:80:$GW http://app.example.com/
HTTP/1.1 301 Moved Permanently
location: https://app.example.com/
```

### 7.4 Diagnosing cert-manager

```
$ kubectl get certificate,certificaterequest,order,challenge -n infra-gateway
NAME                                              READY   SECRET                AGE
certificate.cert-manager.io/app-example-com-tls   False   app-example-com-tls   6m

NAME                                                       APPROVED   DENIED   READY   ISSUER                    AGE
certificaterequest.cert-manager.io/app-example-com-tls-1   True                False   letsencrypt-prod-http01   6m

NAME                                                          STATE     AGE
order.acme.cert-manager.io/app-example-com-tls-1-3620581941   pending   6m

NAME                                                                        STATE     DOMAIN            AGE
challenge.acme.cert-manager.io/app-example-com-tls-1-3620581941-1874226   pending   app.example.com   6m

$ kubectl describe challenge -n infra-gateway | grep -A2 Reason
  Reason:      Waiting for HTTP-01 challenge propagation: failed to perform self check GET request 'http://app.example.com/.well-known/acme-challenge/Xq...': Get "http://app.example.com/.well-known/acme-challenge/Xq...": dial tcp 203.0.113.10:80: connect: connection refused
```

The cert-manager CLI summarises the whole chain:

```
$ cmctl status certificate app-example-com-tls -n infra-gateway
Name: app-example-com-tls
Namespace: infra-gateway
Conditions:
  Ready: False, Reason: DoesNotExist, Message: Issuing certificate as Secret does not exist
...
```

Check that the solver's `HTTPRoute` was attached to the listener:

```
$ kubectl get httproute -n infra-gateway -l acme.cert-manager.io/http01-solver=true
NAME                 HOSTNAMES             AGE
cm-acme-http-solver-x7k2p   ["app.example.com"]   6m
$ kubectl get httproute cm-acme-http-solver-x7k2p -n infra-gateway \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}{"\n"}'
NotAllowedByListeners
```

`NotAllowedByListeners` means the `http` listener's `allowedRoutes` does not admit the namespace where the solver was created.

### 7.5 Fault matrix

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `ResolvedRefs=False`, `RefNotPermitted` | Secret in another namespace with no `ReferenceGrant` | `kubectl get referencegrant -n <secret-ns>` | Create the grant **in the Secret's namespace** |
| `ResolvedRefs=False`, `InvalidCertificateRef` | Secret missing, type is not `kubernetes.io/tls`, or PEM is malformed | `openssl x509` / `openssl pkey` on the data | Recreate with `kubectl create secret tls` |
| The browser shows `NET::ERR_CERT_COMMON_NAME_INVALID` | Listener `hostname` is not covered by the certificate's SAN, or a multi-level wildcard | `openssl s_client -servername` + SAN | Align `dnsNames` with `hostname` |
| Works in the browser, fails in Go or Java: `unknown authority` | `tls.crt` has no intermediate chain | `grep -c 'BEGIN CERTIFICATE'` | Store the full chain |
| A different certificate is served than expected | No SNI in the test, or a less specific listener catches the request | `curl --resolve` | Test with SNI; check `hostname` values |
| HTTP/2: `421 Misdirected Request` | Connection coalescing: the client reuses a connection whose certificate (wildcard or SAN) covers another host served by a different listener | Browser DevTools, data plane logs | Expected behaviour. Separate certificates per listener if it hurts |
| `Certificate` stuck with the challenge `pending` | Solver route not attached, port 80 closed, or DNS not pointing at the Gateway | §7.4 | Adjust `allowedRoutes` / `parentRefs` / DNS |
| Wildcard never issues | HTTP-01 issuer used for `*.` | `kubectl describe order` | Use DNS-01 |
| 502/503 after adding `BackendTLSPolicy` | `validation.hostname` is not in the backend certificate's SAN, or the wrong CA | `kubectl get backendtlspolicy -o yaml` (`status.ancestors`) + data plane logs | Reissue the backend certificate with the correct SAN |
| Policy `Accepted=False`, `NoValidCACertificate` / `InvalidCACertificateRef` | ConfigMap has no `ca.crt` key, or the PEM is invalid | `kubectl get cm internal-ca -o yaml` | Fix the ConfigMap |
| Gateway ignores the annotation | cert-manager without Gateway API support, or started before the CRDs existed | cert-manager logs | `enableGatewayAPI=true` + restart |

---

## 8. Production design decisions

| Decision | Option A | Option B | Recommendation |
|---|---|---|---|
| Granularity | One certificate per hostname | A shared wildcard | Per hostname for critical services (limits the blast radius of a compromised key). Wildcard for dynamic subdomains such as PR previews |
| Where Secrets live | Gateway namespace (the shim works) | Dedicated `certs` namespace + `ReferenceGrant` | Dedicated namespace when several Gateways share certificates or strict RBAC is required |
| Issuer | Public ACME (Let's Encrypt) | Internal CA (cert-manager `CA` / Vault / private ACME) | Public for the frontend. Internal for `BackendTLSPolicy` |
| Frontend vs end-to-end | Terminate only | Terminate + `BackendTLSPolicy` | End-to-end when the network between Gateway and Pod is not trusted, or when compliance requires it |
| L7 vs confidentiality | Terminate | Passthrough | Passthrough only if the proxy must not see plaintext |

Operational checklist:

1. Alert on expiry. cert-manager exports `certmanager_certificate_expiration_timestamp_seconds`. Alert when fewer than 14 days remain, which means the automatic renewal has already failed.
2. Put RBAC on `get secrets` in the certificate namespace. The Gateway controller needs it, and application teams do not.
3. Put `ReferenceGrant` under review (GitOps + CODEOWNERS). It is the only mechanism that grants access to private keys.
4. Test rotation: `cmctl renew <cert>` in staging and check with `openssl s_client` that the new `notBefore` is served without dropped connections.
5. Use Let's Encrypt **staging** while developing issuers. The production rate limits block a domain for days.

```
$ cmctl renew app-example-com-tls -n infra-gateway
Manually triggered issuance of Certificate infra-gateway/app-example-com-tls
```

---

## 9. Exam summary

- The certificate lives in `Gateway.spec.listeners[].tls.certificateRefs`, and the Secret is `kubernetes.io/tls`.
- `HTTPS` + `Terminate` requires `certificateRefs`. `TLS` + `Passthrough` forbids them and uses `TLSRoute`.
- A Secret in another namespace needs a **`ReferenceGrant` in the Secret's namespace**.
- Certificate selection is by **SNI** against the listener's `hostname`. The most specific match wins, and a wildcard covers one label.
- cert-manager: the `cert-manager.io/cluster-issuer` or `cert-manager.io/issuer` annotation on the Gateway. Gateway API support must be enabled. Wildcards need DNS-01.
- `BackendTLSPolicy` targets a `Service`, validates with a CA from a ConfigMap or `System`, and `hostname` is the SNI and the SAN it checks.
- Diagnose from `status.listeners[].conditions` (`ResolvedRefs`, `Programmed`) and confirm with `openssl s_client -servername`.

---

## References

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Gateway API: TLS configuration guide: https://gateway-api.sigs.k8s.io/guides/tls/
- Gateway API: HTTP redirects and rewrites: https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/
- Gateway API: `Gateway` resource: https://gateway-api.sigs.k8s.io/reference/api-types/gateway/
- Gateway API: `ReferenceGrant`: https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
- Gateway API: `BackendTLSPolicy`: https://gateway-api.sigs.k8s.io/reference/api-types/policy/backendtlspolicy/
- Gateway API: API reference: https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
- Gateway API: TLS passthrough / `TLSRoute`: https://gateway-api.sigs.k8s.io/guides/tls/#listeners-and-tls
- cert-manager: Gateway API integration: https://cert-manager.io/docs/usage/gateway/
- cert-manager: ACME HTTP-01 solver: https://cert-manager.io/docs/configuration/acme/http01/
- cert-manager: ACME DNS-01 solver: https://cert-manager.io/docs/configuration/acme/dns01/
- cert-manager: `Certificate` resource: https://cert-manager.io/docs/usage/certificate/
- cert-manager: cmctl: https://cert-manager.io/docs/reference/cmctl/
- Kubernetes: TLS Secrets: https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- RFC 8555, ACME (wildcards only through DNS-01): https://www.rfc-editor.org/rfc/rfc8555
- RFC 6066, TLS extensions (SNI): https://www.rfc-editor.org/rfc/rfc6066