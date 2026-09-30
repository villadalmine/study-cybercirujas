# 4.4 Implementing Pod-level Authentication and Authorization

> **Exam weight:** 6.24%. The weight is moderate, but the topic runs through the whole CKNE domain. Every network policy, service mesh and zero-trust question ends up asking two things: *who is this Pod*, and *what is it allowed to do*.

---

## 1. Motivation: the production problem

### 1.1 An IP address is not an identity

A classic `NetworkPolicy` decides at L3/L4: *"traffic from Pods with label `app=frontend` may reach port 8080 of Pods with label `app=api`."* That is necessary, but in production it is not enough:

| NetworkPolicy assumption | What happens in production |
|---|---|
| "The source IP identifies the Pod" | Pod IPs get reused within seconds after a restart. SNAT at egress gateways, NodeLocal DNS or `hostNetwork` Pods can hide the real IP |
| "The label represents the workload" | Anyone with `patch pods` in the namespace can add `app=frontend` to their own Pod and inherit its access |
| "The network inside the cluster is trusted" | The traffic is plaintext on the wire. A compromised node, a CNI in promiscuous mode or a misconfigured tap can read and inject it |
| "Port 8080 is the API" | L4 cannot tell `GET /healthz` from `DELETE /v1/users` |
| "It only applies within the cluster" | L3 labels mean nothing across clusters or to VMs outside Kubernetes |

**Pod-level authentication and authorization** replaces "where does the packet come from" with "which cryptographic identity presents this request, and what is it allowed to do." That is the operational core of zero trust:

1. **Authentication (AuthN):** the Pod proves who it is with a credential that cannot be forged or reused: a signed X.509 certificate (mTLS) or a JWT with a restricted audience.
2. **Authorization (AuthZ):** the receiver checks that identity against a declarative policy. L4 checks look at identity, namespace and port. L7 checks look at method, path, headers and JWT claims.
3. **Confidentiality and integrity:** mTLS encrypts and authenticates every connection as a side effect.

### 1.2 The three planes of Pod identity

A Pod has identities for three different audiences. It is common to confuse them:

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Pod (ServiceAccount: api)                    │
│                                                                       │
│  (A) Pod → kube-apiserver        (B) Pod → Pod (mesh)    (C) Pod → external service │
│  Bound SA token (JWT)            X.509 SVID (mTLS)       JWT with custom audience   │
│  aud: kubernetes API             SAN: spiffe://…/sa/api  aud: vault / sts / api-x   │
│  AuthZ: RBAC                     AuthZ: AuthorizationPolicy AuthZ: the receiver     │
│                                  / CiliumNetworkPolicy    (TokenReview / OIDC)      │
└──────────────────────────────────────────────────────────────────────┘
```

All three rest on the same primitive: the **Kubernetes ServiceAccount**. The mesh does not invent identities. It turns `namespace/serviceaccount` into a SPIFFE ID and issues a certificate for it.

---

## 2. The foundation: ServiceAccounts and bound tokens

### 2.1 How bound tokens work

Since Kubernetes 1.22, the token mounted in a Pod is **not** the legacy token stored in a Secret. It is a *bound service account token* issued through the `TokenRequest` API. It has these properties:

- **Audience-bound (`aud`):** it is only valid for the audience it was issued for.
- **Time-bound (`exp`):** 1 hour by default, and the kubelet rotates it at about 80% of its lifetime. For legacy clients, the API server can issue it with an extended lifetime (`--service-account-extend-token-expiration`, one year) and log its use as stale.
- **Object-bound:** it is tied to the Pod's UID. If the Pod is deleted, the API server rejects the token even before `exp`. Since 1.30+, it also carries the Node name and a `jti` for traceability.

Decoded payload of a real token:

```json
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1790000000,
  "iat": 1789996400,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "5b1f6d3e-2a41-4c7e-9a0b-7f0c1e2d3a4b",
  "kubernetes.io": {
    "namespace": "payments",
    "node": {
      "name": "worker-02",
      "uid": "c0a8f1e2-1111-4a2b-9c3d-000000000001"
    },
    "pod": {
      "name": "api-7d9c6b5f4-x2k8m",
      "uid": "a1b2c3d4-2222-4e5f-8a9b-000000000002"
    },
    "serviceaccount": {
      "name": "api",
      "uid": "e5f6a7b8-3333-4c1d-9e2f-000000000003"
    }
  },
  "nbf": 1789996400,
  "sub": "system:serviceaccount:payments:api"
}
```

### 2.2 Legacy tokens compared with bound tokens

| Property | Legacy token (Secret `kubernetes.io/service-account-token`) | Bound token (TokenRequest / projected) |
|---|---|---|
| Expiry | Never | Configurable (`expirationSeconds`, minimum 600 s) |
| Audience | Implicitly the API server | Explicit, per volume |
| Revocation | Delete the Secret | Automatic when the Pod is deleted |
| Storage | etcd (Secret) | Not persisted. Generated on demand |
| Rotation | Manual | Kubelet, automatic |
| Recommended | No. Kubernetes 1.30+ flags unused ones and cleans them up (`LegacyServiceAccountTokenCleanUp`) | Yes |

### 2.3 A hardened ServiceAccount and a Pod with a custom-audience token

This complete manifest disables the default automount and projects **two** tokens: one for the API server with a short expiry, and one for an external service (`vault`):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
        version: v1
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: ghcr.io/stefanprodan/podinfo:6.7.1
          ports:
            - name: http
              containerPort: 9898
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: kube-api-token
              mountPath: /var/run/secrets/kubernetes.io/serviceaccount
              readOnly: true
            - name: vault-token
              mountPath: /var/run/secrets/tokens
              readOnly: true
      volumes:
        - name: kube-api-token
          projected:
            defaultMode: 0440
            sources:
              - serviceAccountToken:
                  path: token
                  expirationSeconds: 3600
              - configMap:
                  name: kube-root-ca.crt
                  items:
                    - key: ca.crt
                      path: ca.crt
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef:
                        apiVersion: v1
                        fieldPath: metadata.namespace
        - name: vault-token
          projected:
            defaultMode: 0440
            sources:
              - serviceAccountToken:
                  path: vault-token
                  audience: vault
                  expirationSeconds: 900
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: payments
spec:
  selector:
    app: api
  ports:
    - name: http
      port: 8080
      targetPort: http
```

> **Note:** with `automountServiceAccountToken: false`, the Istio sidecar still works. `istio-proxy` requests its own token for istiod through its own projected volume, `istio-token`, with `aud: istio-ca`. That is exactly the pattern shown here, and it shows why separate audiences matter: a stolen `istio-ca` token is useless against the API server.

### 2.4 Pod → API server: least-privilege RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-config-reader
  namespace: payments
rules:
  - apiGroups:
      - ""
    resources:
      - configmaps
    resourceNames:
      - api-settings
    verbs:
      - get
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-config-reader
  namespace: payments
subjects:
  - kind: ServiceAccount
    name: api
    namespace: payments
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: api-config-reader
```

Verification:

```
$ kubectl auth can-i get configmaps/api-settings -n payments \
    --as=system:serviceaccount:payments:api
yes

$ kubectl auth can-i list secrets -n payments \
    --as=system:serviceaccount:payments:api
no

$ kubectl create token api -n payments --duration=10m > /tmp/t
$ kubectl --token="$(cat /tmp/t)" auth whoami
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:payments:api
UID                                                 e5f6a7b8-3333-4c1d-9e2f-000000000003
Groups                                              [system:serviceaccounts system:serviceaccounts:payments system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=5b1f6d3e-2a41-4c7e-9a0b-7f0c1e2d3a4b]
```

### 2.5 Pod → Pod without a mesh: TokenReview

When there is no mesh, a service can authenticate its callers by validating the projected token against the API server. This is the pattern Vault's Kubernetes auth method uses:

1. The client sends `Authorization: Bearer <token with aud=api-backend>`.
2. The server calls `TokenReview` with `spec.audiences: ["api-backend"]`.
3. The API server checks the signature, expiry, audience **and that the Pod still exists**.

```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: "eyJhbGciOiJSUzI1NiIsImtpZCI6IjF...<elided>"
  audiences:
    - api-backend
```

```
$ kubectl create -f tokenreview.yaml -o yaml | yq '.status'
audiences:
  - api-backend
authenticated: true
user:
  extra:
    authentication.kubernetes.io/credential-id:
      - JTI=0f3c...
    authentication.kubernetes.io/node-name:
      - worker-02
    authentication.kubernetes.io/pod-name:
      - frontend-5c7b9d-abcde
    authentication.kubernetes.io/pod-uid:
      - 9d8e...
  groups:
    - system:serviceaccounts
    - system:serviceaccounts:web
    - system:authenticated
  uid: 7a6b...
  username: system:serviceaccount:web:frontend
```

The server's ServiceAccount needs the `system:auth-delegator` ClusterRole, which allows `create` on `tokenreviews`. The alternative that avoids calling the API server on every request is to validate the JWT offline against `/.well-known/openid-configuration` and `/openid/v1/jwks`, the issuer's OIDC discovery endpoints. That trades latency for revocation: offline validation does not notice that the Pod was deleted until `exp`.

---

## 3. Mesh identity: SPIFFE and mTLS

### 3.1 SPIFFE in one paragraph

SPIFFE defines a workload identity as a URI, `spiffe://<trust-domain>/<path>`, delivered as an **SVID**: an X.509 certificate with the ID in the SAN URI field, or a JWT. Istio and Linkerd both derive it from the ServiceAccount:

```
spiffe://cluster.local/ns/payments/sa/api
         └─trust domain┘   └namespace┘  └ServiceAccount┘
```

In Istio policies, the `principals` field uses this ID **without** the `spiffe://` prefix: `cluster.local/ns/payments/sa/api`.

### 3.2 How a certificate is issued (Istio sidecar)

```
 istio-proxy (pilot-agent)                         istiod (CA)
 ─────────────────────────                         ───────────
 1. Reads the projected token (aud=istio-ca)
 2. Generates a key pair + CSR
 3. CreateCertificate(CSR, token) ──── gRPC/TLS ──►
                                                   4. TokenReview(token) → SA=payments/api
                                                   5. Signs SVID with SAN spiffe://cluster.local/ns/payments/sa/api
                                  ◄────────────── 6. Cert chain (24 h TTL by default)
 7. Delivers it to Envoy over SDS (it never touches disk)
 8. Rotates it before expiry
```

In **ambient** mode, `ztunnel` does the same thing *on behalf of* every Pod on its node. It requests an SVID per ServiceAccount and presents it over HBONE (HTTP/2 CONNECT with mTLS on port 15008).

### 3.3 Implementation comparison

| Dimension | Istio (sidecar) | Istio (ambient) | Linkerd | Cilium mutual auth | SPIRE (standalone) |
|---|---|---|---|---|---|
| Identity | SPIFFE X.509 from the SA | SPIFFE X.509 from the SA | SPIFFE X.509 from the SA (`*.identity.linkerd.cluster.local` + URI SAN) | SPIFFE via SPIRE | SPIFFE X.509/JWT, flexible attestation |
| Where TLS terminates | Envoy per Pod | ztunnel per node | linkerd2-proxy per Pod | Handshake out of band. The data path is not encrypted by mTLS (combine with WireGuard/IPsec) | The application or a proxy |
| mTLS by default | PERMISSIVE (accepts both) | Always, between ambient Pods | Yes, automatic between meshed Pods | Opt-in per policy | N/A |
| L4 AuthZ | `AuthorizationPolicy` | `AuthorizationPolicy` (in ztunnel) | `Server` + `AuthorizationPolicy` + `MeshTLSAuthentication` | `CiliumNetworkPolicy` with `authentication.mode: required` | External |
| L7 AuthZ | Yes (Envoy) | Only with a **waypoint** | Yes (`HTTPRoute` as the target) | Yes, the L7 policy is separate (Envoy) | External |
| End-user JWT | `RequestAuthentication` | Waypoint | No native support | No | JWT-SVID |
| Cost per Pod | ~50–100 MiB RAM + sidecar CPU | Almost none per Pod. ztunnel per node | ~10–20 MiB (Rust proxy) | eBPF, no proxy for L4 | Agent per node |
| Maturity | GA | GA (1.24+) | GA | **Beta** | CNCF graduated |

**Architectural trade-offs:**

- **Sidecar compared with ambient:** a sidecar gives L7 policy on every hop, at the price of memory and a rollout (restart) to update it. Ambient separates the concerns: cheap L4 policy in ztunnel, and L7 only where you put a waypoint. An L7 policy (with `paths` or `methods`) applied to an ambient workload **without a waypoint** is not applied as intended: ztunnel cannot evaluate L7 attributes and the rule turns into a deny. That is a classic exam and production trap.
- **Cilium mutual auth:** it authenticates the *identity* with SPIFFE before allowing the flow, but that handshake does not encrypt the payload. For confidentiality you need WireGuard or IPsec transparent encryption. Topic 4.2 covered these.
- **Linkerd:** zero-config mTLS and very low overhead, but its policy model is more verbose (three CRDs), and it has no native end-user JWT authentication.

---

## 4. Istio: authentication (PeerAuthentication)

### 4.1 Modes and precedence

| `mtls.mode` | Inbound behavior |
|---|---|
| `UNSET` | Inherits from the parent level. If nothing is set, it behaves like PERMISSIVE |
| `PERMISSIVE` | Accepts both mTLS and plaintext. Use it for migration |
| `STRICT` | Only mTLS. Plaintext gets a connection reset |
| `DISABLE` | No mTLS inbound |

Precedence runs from the most specific to the least specific: **workload (selector) > namespace > mesh** (the root namespace, normally `istio-system`). `portLevelMtls` is only valid on policies that have a `selector`.

> The **client** side (outbound) is governed by *auto mTLS*: the client's Envoy sends mTLS if the destination has a sidecar, which it knows from the endpoint metadata. A `DestinationRule` with `tls.mode: DISABLE` pointing at a STRICT destination causes 503s. That is the most common cause of "I turned on STRICT and everything broke."

### 4.2 Complete manifests: progressive migration

```yaml
# 1) Mesh-wide: PERMISSIVE during migration
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE
---
# 2) Migrated namespace: STRICT
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: payments
spec:
  mtls:
    mode: STRICT
---
# 3) Workload exception: the metrics port accepts plaintext
#    (Prometheus outside the mesh)
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: api-metrics-exception
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  mtls:
    mode: STRICT
  portLevelMtls:
    "9797":
      mode: PERMISSIVE
```

> `portLevelMtls` uses the **container** port (targetPort), not the Service port.

### 4.3 How to prove nobody still talks plaintext before you switch to STRICT

With PERMISSIVE on, the telemetry shows how each connection arrived:

```
$ kubectl exec -n istio-system deploy/prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=sum(rate(istio_requests_total{destination_workload_namespace="payments",connection_security_policy!="mutual_tls"}[5m]))by(source_workload,source_workload_namespace)'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"source_workload":"legacy-cron","source_workload_namespace":"batch"},"value":[1790000000,"0.2"]}]}}
```

`batch/legacy-cron` still sends plaintext. Inject it, or keep a PERMISSIVE exception for it, **before** you switch `payments` to STRICT.

---

## 5. Istio: authorization (AuthorizationPolicy)

### 5.1 The evaluation algorithm (memorize it)

```
Request arrives at the workload
   │
   ├─► Is there a CUSTOM policy that matches? ── ext_authz denies ──► DENY
   │
   ├─► Is there a DENY policy that matches? ────────────────────────► DENY
   │
   ├─► Are there no ALLOW policies for this workload? ──────────────► ALLOW
   │
   ├─► Does any ALLOW policy match? ────────────────────────────────► ALLOW
   │
   └─► Otherwise ───────────────────────────────────────────────────► DENY
```

Consequences:

- **The first ALLOW policy you apply to a workload turns everything else into deny.** That is the right behavior, but it catches you out mid-deploy.
- An ALLOW policy with `spec: {}` (no `rules`) matches **nothing**, so it means *deny-all* for the selected workload.
- An ALLOW policy with `rules: [{}]` matches **everything**, so it means *allow-all*.
- DENY always wins over ALLOW, whatever order they were created in.
- `AUDIT` only marks the request for logging. It does not change the decision.

### 5.2 Anatomy of a rule

```
rules:            # OR between rules
  - from: [...]   # OR between sources;     AND with `to` and `when`
    to:   [...]   # OR between operations
    when: [...]   # AND between conditions
```

Inside a single `source` or `operation`, the fields combine with **AND**, and the values inside a list combine with **OR**. The `notPrincipals`, `notPaths` and similar fields are the negations.

| Field | Layer | Requires mTLS or JWT | Works in ambient without a waypoint |
|---|---|---|---|
| `source.principals` | L4 | mTLS | Yes |
| `source.namespaces` | L4 | mTLS | Yes |
| `source.ipBlocks` / `remoteIpBlocks` | L3 | No | Yes |
| `source.requestPrincipals` | L7 | JWT | No |
| `to.operation.ports` | L4 | No | Yes |
| `to.operation.methods` / `paths` / `hosts` | L7 | No | No |
| `when: request.auth.claims[...]` | L7 | JWT | No |
| `when: request.headers[...]` | L7 | No | No |

> **Critical:** `principals` and `namespaces` are extracted from the peer's certificate. With PERMISSIVE and a plaintext client, those fields are **empty**. An ALLOW rule on `principals` will not match and the request is denied. A DENY rule with `notPrincipals` would deny it. Identity-based authorization requires STRICT, or at least real mTLS on the connection being evaluated.

### 5.3 Complete scenario: default-deny plus explicit allow

Topology:

```
 web/frontend (SA frontend) ──GET /api/*──►  payments/api (SA api)  ◄── monitoring/prometheus (SA prometheus) GET /metrics
 batch/reporter (SA reporter) ──GET /api/reports──► payments/api
 anything else ──✗──► payments/api
```

```yaml
# Namespace default-deny: an ALLOW policy with no rules = nothing matches = deny
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: payments
spec: {}
---
# frontend: read and write under /api/, but never admin
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-allow-frontend
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/web/sa/frontend
      to:
        - operation:
            methods:
              - GET
              - POST
            paths:
              - /api/*
            notPaths:
              - /api/admin/*
            ports:
              - "9898"
---
# reporter: reports only, read-only, and only during business hours (via header set by the gateway)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-allow-reporter
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/batch/sa/reporter
      to:
        - operation:
            methods:
              - GET
            paths:
              - /api/reports
              - /api/reports/*
---
# Prometheus: scrape only
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-allow-metrics
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces:
              - monitoring
      to:
        - operation:
            methods:
              - GET
            paths:
              - /metrics
---
# Hard guardrail: no identity outside the mesh's own trust domain may use DELETE,
# and nobody at all may reach /api/admin from outside the payments namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-deny-guardrails
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: DENY
  rules:
    - from:
        - source:
            notNamespaces:
              - payments
      to:
        - operation:
            paths:
              - /api/admin/*
    - from:
        - source:
            notPrincipals:
              - "cluster.local/*"
      to:
        - operation:
            methods:
              - DELETE
```

> `"cluster.local/*"` is quoted: a value that starts with `*` or contains special characters must be quoted in YAML. Istio supports prefix, suffix and exact matches (`*` only at the start or end).

### 5.4 Mesh-wide default deny (root namespace)

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: global-deny-all
  namespace: istio-system
spec: {}
```

This denies **everything** in the mesh, including ingress gateway traffic, until an ALLOW exists at the gateway and at each destination. In production, roll it out namespace by namespace, and use `action: AUDIT` or the `istio_requests_total{response_code="403"}` metrics to measure the impact first.

### 5.5 Test clients

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: web
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: web
  labels:
    app: client
spec:
  serviceAccountName: frontend
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command:
        - sleep
        - infinity
---
apiVersion: v1
kind: Namespace
metadata:
  name: rogue
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: rogue
  labels:
    app: frontend
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command:
        - sleep
        - infinity
```

The Pod in `rogue` **copies the label** `app=frontend`. A NetworkPolicy based on `podSelector` alone would let it through. Here it fails, because its SVID says `ns/rogue/sa/default`:

```
$ kubectl exec -n web client -- curl -s -o /dev/null -w '%{http_code}\n' \
    http://api.payments:8080/api/info
200

$ kubectl exec -n web client -- curl -s -w '\n%{http_code}\n' \
    http://api.payments:8080/api/admin/users
RBAC: access denied
403

$ kubectl exec -n web client -- curl -s -w '\n%{http_code}\n' -X DELETE \
    http://api.payments:8080/api/info
RBAC: access denied
403

$ kubectl exec -n rogue client -- curl -s -w '\n%{http_code}\n' \
    http://api.payments:8080/api/info
RBAC: access denied
403
```

And from a Pod **without** a sidecar (plaintext against STRICT):

```
$ kubectl run nomesh -n default --rm -it --image=curlimages/curl:8.10.1 \
    --restart=Never -- curl -sv http://api.payments:8080/api/info
*   Trying 10.96.143.12:8080...
* Connected to api.payments (10.96.143.12) port 8080
> GET /api/info HTTP/1.1
* Recv failure: Connection reset by peer
curl: (56) Recv failure: Connection reset by peer
```

**Symptom by cause:**

| Symptom | Likely cause |
|---|---|
| `403 RBAC: access denied` | L7 AuthorizationPolicy denied the request (the sidecar or waypoint responds) |
| `Connection reset by peer` in HTTP or TCP | STRICT mTLS with a plaintext client, **or** an L4 authz deny (TCP, ztunnel) |
| `503 upstream connect error ... reset reason: connection termination` | The client sends plaintext because a DestinationRule has `tls: DISABLE`, or there is a SAN mismatch |
| `401 Jwt verification fails` | RequestAuthentication: invalid token, wrong issuer, expired token or unreachable JWKS |
| `403 RBAC: access denied` with a valid JWT | The token authenticates, but no rule requires or accepts it (`requestPrincipals` or claims) |

---

## 6. Istio: end-user authentication (RequestAuthentication + JWT)

`RequestAuthentication` **validates** JWTs, but it does not **require** them:

- Valid token → the request is authenticated and `requestPrincipal = <iss>/<sub>`.
- Invalid token → 401.
- **No token → allowed**, as anonymous.

To require a token, combine it with an AuthorizationPolicy.

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: api-jwt
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  jwtRules:
    - issuer: "https://idp.example.com/realms/prod"
      jwksUri: "https://idp.example.com/realms/prod/protocol/openid-connect/certs"
      audiences:
        - payments-api
      forwardOriginalToken: true
      outputClaimToHeaders:
        - header: x-user-tenant
          claim: tenant
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-require-jwt
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals:
              - "*"
      to:
        - operation:
            paths:
              - /api/orders
              - /api/orders/*
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-orders-writers
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/web/sa/frontend
            requestPrincipals:
              - "https://idp.example.com/realms/prod/*"
      to:
        - operation:
            methods:
              - POST
            paths:
              - /api/orders
      when:
        - key: request.auth.claims[groups]
          values:
            - order-writers
        - key: request.auth.audiences
          values:
            - payments-api
```

The ALLOW rule shows **dual identity**. The request must come from the `frontend` workload (mTLS, L4) **and** carry a user token from the right group (JWT, L7). A stolen user token is useless from another Pod, and a compromised frontend is useless without a user token.

```
$ kubectl exec -n web client -- curl -s -w '\n%{http_code}\n' -X POST \
    http://api.payments:8080/api/orders
RBAC: access denied
403

$ kubectl exec -n web client -- curl -s -w '\n%{http_code}\n' -X POST \
    -H "Authorization: Bearer invalid.token.here" \
    http://api.payments:8080/api/orders
Jwt is not in the form of Header.Payload.Signature with two dots and 3 sections
401

$ kubectl exec -n web client -- curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    -H "Authorization: Bearer $TOKEN" http://api.payments:8080/api/orders
200
```

> **Gotcha:** `jwksUri` is fetched by **istiod**, and the result is pushed into the Envoy config. If istiod has no egress to the IdP, Envoy gets a placeholder JWKS and **every** token fails with 401. Check the istiod logs (`jwks`) or use `jwks:` inline in air-gapped environments.

---

## 7. Ambient mode: L4 in ztunnel, L7 in a waypoint

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: payments
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
---
# L4: enforced by ztunnel on the destination node (selector on the Pods)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-l4
  namespace: payments
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/web/sa/frontend
              - cluster.local/ns/payments/sa/waypoint
---
# L7: enforced by the waypoint (targetRefs to the Service)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-l7
  namespace: payments
spec:
  targetRefs:
    - kind: Service
      group: ""
      name: api
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/web/sa/frontend
      to:
        - operation:
            methods:
              - GET
            paths:
              - /api/*
```

Points that matter in ambient:

- **A `selector` policy is enforced in ztunnel. A `targetRefs` policy (Service or Gateway) is enforced in the waypoint.**
- When there is a waypoint, the destination Pod sees the connection as coming **from the waypoint**. That is why the L4 policy must allow `sa/waypoint`, and why the original identity check moves to the waypoint's L7 policy.
- If you put `paths` in a `selector` policy in ambient, ztunnel cannot evaluate it. For ALLOW, the rule is dropped (and denies the traffic). For DENY, the whole rule is treated as matching. `istioctl analyze` warns you about this.

```
$ istioctl waypoint status -n payments
NAMESPACE     NAME         STATUS     TYPE        REASON        MESSAGE
payments      waypoint     True       Programmed  Programmed    Resource programmed, assigned to service(s) waypoint.payments.svc.cluster.local:15008

$ istioctl ztunnel-config workloads | grep payments
payments   api-7d9c6b5f4-x2k8m   10.244.2.17  worker-02  payments/waypoint  HBONE
payments   api-7d9c6b5f4-q9zlp   10.244.1.33  worker-01  payments/waypoint  HBONE
```

---

## 8. Linkerd: Server, MeshTLSAuthentication and AuthorizationPolicy

Linkerd separates *what* is protected (a `Server` or `HTTPRoute`), *who* is authenticated (`MeshTLSAuthentication` or `NetworkAuthentication`) and the binding between them (`AuthorizationPolicy`). Once a `Server` exists, traffic to it that is not explicitly authorized is denied.

```yaml
apiVersion: policy.linkerd.io/v1beta3
kind: Server
metadata:
  name: api-http
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: api
  port: http
  proxyProtocol: HTTP/1
---
apiVersion: policy.linkerd.io/v1alpha1
kind: MeshTLSAuthentication
metadata:
  name: frontend-identity
  namespace: payments
spec:
  identityRefs:
    - kind: ServiceAccount
      name: frontend
      namespace: web
---
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: api-allow-frontend
  namespace: payments
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: api-http
  requiredAuthenticationRefs:
    - group: policy.linkerd.io
      kind: MeshTLSAuthentication
      name: frontend-identity
```

The cluster-wide default is set with the `config.linkerd.io/default-inbound-policy` annotation (`all-unauthenticated`, `all-authenticated`, `cluster-authenticated`, `cluster-unauthenticated`, `deny`) on the namespace or workload, or at install time.

```
$ linkerd viz authz -n payments deploy/api
ROUTE    SERVER    AUTHORIZATION                            UNAUTHORIZED  SUCCESS     RPS  LATENCY_P50  LATENCY_P95  LATENCY_P99
default  api-http  authorizationpolicy/api-allow-frontend        0.0rps  100.00%  4.2rps          2ms          5ms          9ms
default  api-http                                                1.3rps        -        -            -            -            -
```

The row with no `AUTHORIZATION` and `UNAUTHORIZED` > 0 is traffic being rejected. With `proxyProtocol: HTTP/1` the client gets `403`. With `opaque`, the connection is refused.

---

## 9. Cilium: identity-aware network policy with mutual authentication

Cilium already derives a *security identity* (a numeric ID) from the labels of each Pod and enforces L3/L4 with eBPF. Mutual authentication (beta) adds a SPIFFE handshake between agents, backed by SPIRE, before it allows the flow:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-require-mutual-auth
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: web
            io.cilium.k8s.policy.serviceaccount: frontend
      authentication:
        mode: required
      toPorts:
        - ports:
            - port: "9898"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/.*"
```

Notes:

- `io.cilium.k8s.policy.serviceaccount` anchors the rule to the **ServiceAccount**, not to an arbitrary label that anyone could copy.
- `authentication.mode: required` makes the first packet wait until the agents have authenticated both identities against SPIRE. With the auth result cached per identity pair, later flows go straight through.
- The `http` rules are handled by Cilium's Envoy (L7 proxy), and a deny returns `403 Access denied`.
- The mutual auth handshake **does not encrypt** the traffic. Enable `encryption.enabled=true` (WireGuard) as well to get confidentiality.

```
$ cilium config view | grep -E 'mesh-auth|encryption'
enable-wireguard                                 true
mesh-auth-enabled                                true
mesh-auth-mutual-enabled                         true
mesh-auth-spiffe-trust-domain                    spiffe.cilium

$ hubble observe -n payments --to-label app=api --verdict DROPPED
Sep 30 10:12:41.201: rogue/client:51234 (ID:48211) <> payments/api-7d9c6b5f4-x2k8m:9898 (ID:30112) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 10:12:41.201: rogue/client:51234 (ID:48211) <> payments/api-7d9c6b5f4-x2k8m:9898 (ID:30112) Policy denied DROPPED (TCP Flags: SYN)
```

---

## 10. Verification and diagnostics guide

### 10.1 Is the Pod in the mesh, and which identity does it have?

```
$ kubectl get pod -n payments -l app=api \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
api-7d9c6b5f4-x2k8m	api	api istio-proxy
api-7d9c6b5f4-q9zlp	api	api istio-proxy

$ istioctl proxy-config secret -n payments deploy/api
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           3f2a9c1b7e5d4a6b8c0d1e2f3a4b5c6d     2026-10-01T10:05:11Z     2026-09-30T10:03:11Z
ROOTCA            CA             ACTIVE     true           9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d     2036-09-01T08:00:00Z     2026-09-03T08:00:00Z
```

Extract the SAN from the certificate to confirm the SPIFFE ID:

```
$ istioctl proxy-config secret -n payments deploy/api -o json \
    | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -ext subjectAltName
X509v3 Subject Alternative Name: critical
    URI:spiffe://cluster.local/ns/payments/sa/api
```

If the SAN shows `sa/default`, the Deployment is not using the ServiceAccount you think it is, and every `principals` rule will fail.

### 10.2 Which policies apply to the Pod?

```
$ istioctl x describe pod -n payments api-7d9c6b5f4-x2k8m
Pod: api-7d9c6b5f4-x2k8m
   Pod Revision: default
   Pod Ports: 9898 (api), 15090 (istio-proxy)
--------------------
Service: api
   Port: http 8080/HTTP targets pod port 9898
--------------------
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied PeerAuthentication:
   default.payments, api-metrics-exception.payments
Applied AuthorizationPolicy:
   deny-all.payments, api-allow-frontend.payments, api-allow-reporter.payments,
   api-allow-metrics.payments, api-deny-guardrails.payments, api-require-jwt.payments,
   api-orders-writers.payments

$ istioctl x authz check -n payments api-7d9c6b5f4-x2k8m
ACTION   AuthorizationPolicy                  RULES
DENY     api-deny-guardrails.payments         2
DENY     api-require-jwt.payments             1
ALLOW    deny-all.payments                    0
ALLOW    api-allow-frontend.payments          1
ALLOW    api-allow-reporter.payments          1
ALLOW    api-allow-metrics.payments           1
ALLOW    api-orders-writers.payments          1
```

### 10.3 Static analysis

```
$ istioctl analyze -n payments
Warning [IST0127] (AuthorizationPolicy payments/api-allow-reporter) No matching workloads for this resource with the following labels: app=reporter
Info [IST0118] (Service payments/api) Port name http-metrics (port: 9797, targetPort: 9797) doesn't follow the naming convention of Istio port.
```

IST0127 means the `selector` points at nothing. It often comes from a typo in a label or from applying the policy in the wrong namespace (the policy lives in the **destination's** namespace).

### 10.4 Why was a specific request denied?

Enable RBAC debug logging on the destination's Envoy:

```
$ istioctl proxy-config log -n payments deploy/api --level rbac:debug
active loggers:
  rbac: debug

$ kubectl logs -n payments deploy/api -c istio-proxy --tail=20 | grep -i rbac
2026-09-30T10:14:02.118Z debug envoy rbac external/envoy/source/extensions/filters/http/rbac/rbac_filter.cc:192 checking request: requestedServerName: outbound_.8080_._.api.payments.svc.cluster.local, sourceIP: 10.244.3.41:48812, directRemoteIP: 10.244.3.41:48812, remoteIP: 10.244.3.41:48812,localAddress: 10.244.2.17:9898, ssl: uriSanPeerCertificate: spiffe://cluster.local/ns/rogue/sa/default, dnsSanPeerCertificate: , subjectPeerCertificate: , headers: ':authority', 'api.payments:8080'
':path', '/api/info'
':method', 'GET'
2026-09-30T10:14:02.118Z debug envoy rbac external/envoy/source/extensions/filters/http/rbac/rbac_filter.cc:232 enforced denied, matched policy none
```

- `uriSanPeerCertificate` is the identity Envoy saw. If it is empty, the connection **did not** arrive over mTLS.
- `matched policy none` → no ALLOW matched (implicit deny).
- `matched policy ns[payments]-policy[api-deny-guardrails]-rule[0]` → an explicit DENY.

Counters without debug logging:

```
$ kubectl exec -n payments deploy/api -c istio-proxy -- \
    pilot-agent request GET stats | grep -E 'rbac\.(allowed|denied)'
http.inbound_0.0.0.0_9898;.rbac.allowed: 18422
http.inbound_0.0.0.0_9898;.rbac.denied: 37
```

Remember to restore the logger with `--level rbac:warning`.

### 10.5 Is mTLS really negotiated between two Pods?

```
$ istioctl proxy-config cluster -n web client \
    --fqdn api.payments.svc.cluster.local -o json \
    | jq -r '.[0].transportSocketMatches[]?.name'
tlsMode-istio
tlsMode-disabled
```

Both matches present means auto mTLS is active: Envoy picks `tlsMode-istio` for endpoints with a sidecar. If you only see a `transportSocket` with no TLS, check for a `DestinationRule`:

```
$ kubectl get destinationrule -A -o json \
    | jq -r '.items[] | select(.spec.host|test("api")) | "\(.metadata.namespace)/\(.metadata.name) \(.spec.trafficPolicy.tls.mode // "unset")"'
web/api-legacy DISABLE
```

That `DISABLE` is the 503 you were chasing.

### 10.6 Failure matrix

| Failure | Diagnosis | Fix |
|---|---|---|
| Everything returns 403 after applying one policy | You applied the workload's first ALLOW. There is now an implicit deny | Add ALLOWs for the other legitimate callers (probes are rewritten by the sidecar and are not affected; Prometheus and other scrapers are) |
| `principals` never match | The SAN shows another SA, the trust domain is not `cluster.local`, or the connection is plaintext | `proxy-config secret` + `openssl`. Check `meshConfig.trustDomain` and `trustDomainAliases` |
| Policy has no effect | The policy is in the wrong namespace, or its `selector` does not match | `istioctl analyze`, `x describe pod` |
| L7 policy is ignored or breaks traffic in ambient | No waypoint, or the policy uses `selector` instead of `targetRefs` | Deploy a waypoint, label with `istio.io/use-waypoint`, use `targetRefs` |
| 401 on every JWT | istiod cannot reach `jwksUri`, or the issuer does not match exactly (trailing slash) | istiod logs. Compare `iss` in the token with `issuer` byte for byte |
| Request without JWT gets through | RequestAuthentication does not require a token | DENY with `notRequestPrincipals: ["*"]` |
| Pod cannot call the API server | `automountServiceAccountToken: false` with no manual projection, or insufficient RBAC | `kubectl auth can-i --as=system:serviceaccount:ns:sa` |
| TokenReview returns `authenticated: false` | Wrong audience, the Pod was deleted, or the token expired | Decode the JWT (`aud`, `exp`, `kubernetes.io.pod.uid`) and pass `spec.audiences` |
| Linkerd: 403 after creating a `Server` | A `Server` with no `AuthorizationPolicy` denies all traffic | Create the `MeshTLSAuthentication` + `AuthorizationPolicy` pair |
| Cilium: SYNs dropped with `authentication.mode: required` | SPIRE is down or the agents are not registered | `cilium status`, the SPIRE server logs, `hubble observe --verdict DROPPED` |

---

## 11. Production design checklist

1. **One ServiceAccount per workload.** Never `default`. Identity is only as granular as the SA.
2. **`automountServiceAccountToken: false`** by default. Project tokens explicitly, with an `audience` and a short `expirationSeconds`.
3. **Migrate mTLS in stages:** mesh PERMISSIVE → measure `connection_security_policy` → namespace STRICT → mesh STRICT.
4. **Default deny per namespace** (`spec: {}`), then explicit ALLOWs based on `principals`, not IPs or labels.
5. **DENY policies for invariants** ("nobody outside `payments` touches `/admin`"). They survive any badly written ALLOW.
6. **Dual identity** for sensitive operations: workload (mTLS) **and** user (JWT with `aud` and claims).
7. **Defense in depth:** keep L3/L4 `NetworkPolicy` or `CiliumNetworkPolicy` alongside mesh authorization. If the proxy is bypassed (hostNetwork, `excludeInboundPorts`, `NET_ADMIN`), the CNI still filters.
8. **Restrict who can modify identity:** RBAC on `serviceaccounts`, `pods` (`serviceAccountName`), `authorizationpolicies` and `peerauthentications`. Anyone who can create a Pod with an arbitrary SA in a namespace inherits that SA's identity. Consider Pod Security Admission and admission policies (`ValidatingAdmissionPolicy`) to pin which SAs each team can use.
9. **Observability of denials:** alert on `istio_requests_total{response_code="403"}` and on `rbac.denied`, split by `source_principal`.

---

## Referencias

- CNCF / Linux Foundation, CKNE certification: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes, Service Accounts (concepts): https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes, Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes, Managing Service Accounts (bound tokens, TokenRequest, OIDC discovery): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes, Projected Volumes: https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Kubernetes, Authenticating: https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Kubernetes, Authorization overview: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes, Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes, TokenReview API: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/
- Istio, Security concepts: https://istio.io/latest/docs/concepts/security/
- Istio, PeerAuthentication reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio, AuthorizationPolicy reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio, RequestAuthentication reference: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Istio, Mutual TLS Migration: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Linkerd, Authorization Policy reference: https://linkerd.io/2/reference/authorization-policy/
- Cilium, Mutual Authentication: https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
- SPIFFE, Overview: https://spiffe.io/docs/latest/spiffe-about/overview/