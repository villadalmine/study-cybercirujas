# KCSA Exam Study Guide: Theme 3.3 — Authentication

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain Weight:** 3.14%  
**Target Audience:** Principal Platform Engineers, Senior SREs, and Cloud Native Security Architects  

---

## 1. Production Motivation and Architectural Problem Statement

In a zero-trust production environment, authentication is the first critical line of defense in the API Server request execution pipeline. Before an HTTP request reaches Authorization (RBAC) or Admission Control (Validating/Mutating Webhooks), the `kube-apiserver` must definitively establish the identity of the caller (human user, machine process, or service account).

```
                        Kubernetes API Server Request Execution Pipeline
                        
  +---------------+     +------------------+     +-------------------+     +------------------+     +---------------+
  |  HTTP Request | --> |  Authentication  | --> |   Authorization   | --> | Admission Control| --> | etcd Storage  |
  |  (Bearer/Cert)|     | (Find matching   |     | (RBAC Checks:     |     | (Mutating/Valid.)|     | (State        |
  |               |     |  authenticator)  |     |  Can X do Y?)     |     | Webhooks         |     |  Mutation)    |
  +---------------+     +------------------+     +-------------------+     +------------------+     +---------------+
                                 |                         |                        |
                           401 Unauthorized          403 Forbidden            422 Unprocessable
```

### Architectural Challenges in Production

1. **Non-Revocable Credentials (The X.509 Trap):**  
   Kubernetes does not feature a built-in Certificate Revocation List (CRL) or OCSP stapling mechanism within `kube-apiserver`. An X.509 client certificate issued for 1 year remains valid until expiration unless the cluster Certificate Authority (CA) is fully rotated—an operational disaster in production.

2. **Legacy Static ServiceAccount Tokens (Pre-v1.24 Risk):**  
   Historically, ServiceAccount tokens were static JWTs stored infinitely as `v1.Secret` objects in `etcd`. Theft of a secret backing a ServiceAccount allowed perpetual cluster access with no audience restriction or time-bound expiration (`exp`).

3. **Multi-Cluster Identity Fragmentation:**  
   Managing local certificates or static kubeconfig files per engineer across hundreds of multi-region clusters creates identity drift, lacks centralized auditability, and breaks single sign-on (SSO) and offboarding workflows.

4. **Identity Spoofing via Front Proxies:**  
   When using an Authenticating Proxy (e.g., ingress proxies or service meshes injecting `X-Remote-User` headers), misconfiguring mutual TLS (mTLS) or header validation allows malicious actors to impersonate `system:masters` by injecting custom HTTP headers.

---

## 2. Technical Comparisons & Trade-off Tables

Kubernetes supports multiple authentication modules evaluated sequentially by `kube-apiserver`. The first authenticator to successfully parse the request returns the identity metadata: `Username`, `UID`, `Groups`, and `Extra`.

| Authentication Mechanism | Credential Type & Lifespan | Revocation Capability | Centralized IdP Support | Performance Overhead | Primary Production Use Case | Security Risk Level |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **OIDC (OpenID Connect)** | Short-lived JWT (`exp`: 5m–1h) | High (via IdP token refresh / revocation) | Native (Okta, Keycloak, Entra ID, Dex) | Low (In-memory public key validation via JWKS) | Human User & SSO Authentication | **Low** (Recommended) |
| **Bound ServiceAccount Tokens** | Short-lived JWT (`exp`: 10m–24h) | High (Token invalid on Pod deletion or SA removal) | Internal K8s PKI / OIDC Provider | Low (Public key verification) | In-Cluster Workloads & Pod-to-APIServer Auth | **Low** (Recommended) |
| **X.509 Client Certificates** | TLS Client Cert (Typically 30d–365d) | **None natively** (Requires full CA re-keying) | No (Manual PKI issuance required) | Very Low (TLS Handshake overhead) | Master node components & Bootstrap (`kubelet`, `kube-proxy`) | **High** (For human users) |
| **Webhook Token Authenticator** | Bearer Token (Custom TTL) | High (Delegated to external Webhook service) | Indirect (Delegates to external validation API) | High (Network latency per uncached auth request) | Legacy platform integrations & custom auth portals | **Medium** |
| **Authenticating Proxy** | Arbitrary Header (`X-Remote-User`) | High (Delegated to Proxy layer) | Yes (Handled by proxy layer) | Low (Proxy inspects & injects headers) | Enterprise API Gateways & Service Mesh Ingress | **High** (If mTLS proxy validation fails) |

---

## 3. Production Manifests and Infrastructure Configurations

### 3.1 `kube-apiserver` Manifest excerpt (Production Flags)

Below is an explicit, syntactically valid static pod manifest configuration `/etc/kubernetes/manifests/kube-apiserver.yaml` configured for OIDC, Bound ServiceAccount Tokens, and Webhook Authentication.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
spec:
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.30.0
    command:
    - kube-apiserver
    - --advertise-address=10.0.1.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    
    # --- ServiceAccount Token Signing & Projection Configuration ---
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    
    # --- OpenID Connect (OIDC) Authentication Setup ---
    - --oidc-issuer-url=https://idp.company.internal/auth/realms/production
    - --oidc-client-id=kubernetes-cluster-prod
    - --oidc-username-claim=email
    - --oidc-username-prefix=oidc:
    - --oidc-groups-claim=groups
    - --oidc-groups-prefix=oidc-group:
    - --oidc-ca-file=/etc/kubernetes/pki/idp-ca.crt
    
    # --- Webhook Token Authentication Configuration ---
    - --authentication-token-webhook-config-file=/etc/kubernetes/auth/webhook-auth-config.yaml
    - --authentication-token-webhook-cache-ttl=5m0s
    
    # --- Authenticating Proxy Security Headers ---
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/auth
      name: k8s-auth-config
      readOnly: true
  volumes:
  - name: k8s-certs
    hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
  - name: k8s-auth-config
    hostPath:
      path: /etc/kubernetes/auth
      type: DirectoryOrCreate
```

---

### 3.2 CertificateSigningRequest (CSR) Manifest (`certificates.k8s.io/v1`)

This manifest requests a short-lived client certificate for a DevOps engineer belonging to the `platform-engineers` group.

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alex-platform-engineer-csr
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0nTUlJQ2ZqQ0NBYXdDQVFBd0dERVhNQVVHQTFVRUF3d01ZV3hsZUMxd2JHRjBaMjl5YlMxcGJpQmJNUndHd0FZRFZRUUtEQkJ3YkdGMDBaMjl5YlMxMWJXVm5jM1FnVjJWdGJGQWdNQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUJEd0F3Z2dFQkFMNz...==
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800 # 8 Hours TTL
  usages:
  - client auth
```

---

### 3.3 Projected ServiceAccount Token Pod Manifest

Manifest demonstrating modern, bound short-lived token injection using `projected` volumes with audience restriction and custom TTL:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-vault-agent
  namespace: security-tools
spec:
  serviceAccountName: vault-auth-sa
  containers:
  - name: vault-agent
    image: hashicorp/vault:1.15.0
    command: ["vault", "agent", "-config=/etc/vault/vault-agent.hcl"]
    volumeMounts:
    - mountPath: /var/run/secrets/tokens
      name: vault-token
  volumes:
  - name: vault-token
    projected:
      sources:
      - serviceAccountToken:
          path: vault-identity-token
          expirationSeconds: 1800 # 30 Minutes TTL
          audience: https://vault.company.internal
```

---

### 3.4 Webhook Token Authentication Kubeconfig File

File located at `/etc/kubernetes/auth/webhook-auth-config.yaml`:

```yaml
apiVersion: v1
kind: Config
clusters:
- name: external-auth-service
  cluster:
    certificate-authority: /etc/kubernetes/pki/auth-webhook-ca.crt
    server: https://auth-webhook.security.internal/v1/authenticate
users:
- name: kube-apiserver-client
  user:
    client-certificate: /etc/kubernetes/pki/apiserver-webhook-client.crt
    client-key: /etc/kubernetes/pki/apiserver-webhook-client.key
contexts:
- context:
    cluster: external-auth-service
    user: kube-apiserver-client
  name: webhook-auth
current-context: webhook-auth
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Generating and Submitting an X.509 CertificateSigningRequest

```bash
$ openssl req -new -newkey rsa:2048 -nodes \
    -keyout alex.key \
    -out alex.csr \
    -subj "/CN=alex@company.com/O=platform-engineers/O=secops"

$ export CSR_BASE64=$(cat alex.csr | base64 | tr -d '\n')

$ cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alex-access-request
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800
  usages:
  - client auth
EOF
```
**Output:**
```
certificatesigningrequest.certificates.k8s.io/alex-access-request created
```

```bash
$ kubectl get csr alex-access-request
```
**Output:**
```
NAME                  AGE   SIGNERNAME                            REQUESTOR           REQUESTEDDURATION   CONDITION
alex-access-request   12s   kubernetes.io/kube-apiserver-client   kubernetes-admin    8h                  Pending
```

```bash
$ kubectl certificate approve alex-access-request
```
**Output:**
```
certificatesigningrequest.certificates.k8s.io/alex-access-request approved
```

```bash
$ kubectl get csr alex-access-request -o jsonpath='{.status.certificate}' | base64 --decode > alex.crt
$ openssl x509 -in alex.crt -noout -subject -issuer -dates
```
**Output:**
```
subject=O = platform-engineers + O = secops, CN = alex@company.com
issuer=CN = kubernetes-ca
notBefore=Aug  7 18:30:00 2026 GMT
notAfter=Aug  8 02:30:00 2026 GMT
```

---

### 4.2 Inspecting and Decoding a Bound ServiceAccount Token (JWT)

```bash
$ kubectl exec -n security-tools secure-vault-agent -- cat /var/run/secrets/tokens/vault-identity-token > sa_token.jwt

$ jq -R 'split(".") | .[0,1] | @base64d | fromjson' sa_token.jwt
```
**Output:**
```json
{
  "alg": "RS256",
  "kid": "k8s-sa-key-1"
}
{
  "aud": [
    "https://vault.company.internal"
  ],
  "exp": 1786134000,
  "iat": 1786132200,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "security-tools",
    "pod": {
      "name": "secure-vault-agent",
      "uid": "a3c4f981-22e1-4c12-8f99-9189283710ab"
    },
    "serviceaccount": {
      "name": "vault-auth-sa",
      "uid": "887a02b1-5e88-410a-b112-0099411234aa"
    }
  },
  "nbf": 1786132200,
  "sub": "system:serviceaccount:security-tools:vault-auth-sa"
}
```

---

### 4.3 Testing the `TokenReview` API Endpoint via `kubectl`

Execute a direct API query to evaluate an arbitrary token against the Kubernetes authentication layer:

```bash
$ cat <<EOF | kubectl raw /apis/authentication.k8s.io/v1/tokenreviews -H "Content-Type: application/json" -f -
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "spec": {
    "token": "$(cat sa_token.jwt)",
    "audiences": [
      "https://vault.company.internal"
    ]
  }
}
EOF
```
**Output:**
```json
{
  "apiVersion": "authentication.k8s.io/v1",
  "kind": "TokenReview",
  "metadata": {
    "creationTimestamp": null
  },
  "spec": {
    "token": "eyJhbGciOiJSUzI1NiIs..."
  },
  "status": {
    "authenticated": true,
    "user": {
      "username": "system:serviceaccount:security-tools:vault-auth-sa",
      "uid": "887a02b1-5e88-410a-b112-0099411234aa",
      "groups": [
        "system:serviceaccounts",
        "system:serviceaccounts:security-tools",
        "system:authenticated"
      ]
    },
    "audiences": [
      "https://vault.company.internal"
    ]
  }
}
```

---

## 5. Verification, Diagnostics, and Failure Troubleshooting

When an HTTP client receives an authentication failure, it encounters HTTP status `401 Unauthorized` (whereas authorization failures trigger `403 Forbidden`).

```
                Authentication Diagnostic Flowchart
                
                 HTTP Client Request
                         |
                +-----------------+
                | Returns Status? |
                +-----------------+
                  /             \
            HTTP 401           HTTP 403
               /                 \
    Authentication Failure     Authorization Failure (RBAC)
    [Check Authn Module]       [Check Roles & Binding]
               |
    +-----------------------------+
    | Inspect kube-apiserver logs |
    |      (--v=4 or higher)      |
    +-----------------------------+
               |
    +-------------------------------------------------------------+
    |  Common Errors:                                             |
    |  - "token is expired"                                       |
    |  - "oidc: validate token failed"                            |
    |  - "certificate has expired or is not yet valid"            |
    |  - "invalid bearer token"                                   |
    +-------------------------------------------------------------+
```

### 5.1 Step-by-Step Diagnostic Matrix

#### Symptom 1: OIDC Authentication Fails with `401 Unauthorized`
* **Log Error (`kube-apiserver` journalctl / pod logs):**  
  `OIDC authn failed: oidc: validate token failed: token is expired (iat: 1786130000, exp: 1786133600, now: 1786133605)`
* **Root Cause:** Clock skew between API Server nodes and Identity Provider (IdP), or expired client JWT.
* **Remediation:**  
  1. Synchronize NTP daemons across control-plane nodes: `$ chronyc tracking`.
  2. Increase OIDC clock skew tolerance via `--oidc-signing-algs` or refresh token flow in `kubectl` OIDC helper plugin (`kubelogin`).

#### Symptom 2: Webhook Token Authentication Timeouts
* **Log Error (`kube-apiserver`):**  
  `Unable to authenticate the request due to an error: Post "https://auth-webhook.security.internal/v1/authenticate": context deadline exceeded`
* **Root Cause:** Network Policy blocking egress from `kube-apiserver` to external webhook service, or DNS failure.
* **Remediation:**  
  1. Test connectivity directly from control-plane host:  
     `$ curl -vvv --cacert /etc/kubernetes/pki/auth-webhook-ca.crt https://auth-webhook.security.internal/v1/authenticate`
  2. Verify API server static pod network namespace and egress firewalls.

#### Symptom 3: Impersonation Rejected on Authenticating Proxy
* **Log Error (`kube-apiserver`):**  
  `x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while verifying candidate authority certificate)`
* **Root Cause:** The CA certificate specified in `--requestheader-client-ca-file` does not match the CA that issued the proxy client certificate presenting `X-Remote-User`.
* **Remediation:**  
  Inspect the proxy's TLS client certificate:  
  `$ openssl x509 -in /etc/proxy/client.crt -noout -issuer -subject`  
  Ensure the CA bundle matches `/etc/kubernetes/pki/front-proxy-ca.crt`.

---

### 5.2 Diagnostic Commands Cheat Sheet

```bash
# 1. Enable Verbose Authentication Logging on API Server
$ kubectl get pod -n kube-system -l component=kube-apiserver

# 2. View Real-Time Authn Debug Stream
$ kubectl logs -n kube-system kube-apiserver-master-1 --tail=100 -f | grep -iE "auth|token|oidc|jwt"

# 3. Test Raw Authentication Endpoint as User
$ curl -k -v --cert alex.crt --key alex.key https://10.0.1.10:6443/api/v1/namespaces

# 4. Verify OIDC Discovery Endpoint Accessibility
$ curl -s https://idp.company.internal/auth/realms/production/.well-known/openid-configuration | jq .jwks_uri
```

---

## 6. References

* **Kubernetes Official Documentation — Authenticating:**  
  https://kubernetes.io/docs/reference/access-authn-authz/authentication/
* **Kubernetes Official Documentation — Service Account Token Volumes:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
* **Kubernetes Official Documentation — CertificateSigningRequests:**  
  https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
* **Kubernetes API Reference — TokenReview v1:**  
  https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/
* **CNCF KCSA Official Curriculum PDF:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf