# CNCF KCSA Study Guide: Topic 3.3 – Authentication

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Cluster Security & Architecture  
**Topic:** 3.3 Authentication  
**Exam Weight:** ~3.14%  

---

## 1. Architectural Deep-Dive & Internal Mechanics

Authentication is the first defensive boundary of the `kube-apiserver` control plane. When an HTTP request reaches the API server, it traverses an ordered chain of authentication handlers. The API server does not manage user accounts internally; instead, it delegates identity verification to configured authenticators and extracts identity attributes: **Username**, **UID**, **Groups**, and **Extra Fields**.

```
                           +-------------------------------------------------------------+
                           |                    kube-apiserver                           |
                           |                                                             |
 Incoming HTTP Request     | +---------------------------------------------------------+ |
-------------------------> | | Authentication Handler Chain                            | |
 (Bearer Token / Cert)     | |                                                         | |
                           | |  [ 1. RequestHeader (Auth Proxy) ]                      | |
                           | |                 | (Pass/Fail)                           | |
                           | |  [ 2. X.509 Client Certificates ]                       | |
                           | |                 | (Pass/Fail)                           | |
                           | |  [ 3. OIDC / JWT Tokens ]                               | |
                           | |                 | (Pass/Fail)                           | |
                           | |  [ 4. Webhook Token Authenticator ]                     | |
                           | |                 | (Pass/Fail)                           | |
                           | |  [ 5. ServiceAccount Tokens (TokenRequest/Bound) ]      | |
                           | |                 | (Pass/Fail)                           | |
                           | |  [ 6. Anonymous Authenticator ]                         | |
                           | +----------------------+----------------------------------+ |
                           |                        | Identity Context                   |
                           |                        v                                    |
                           |          Username: system:serviceaccount:default:vault-sa   |
                           |          Groups:   [system:serviceaccounts, ...]            |
                           |          UID:      b971a62d-45c1-4d32-8df2-001a4e21a8f9    |
                           |                        |                                    |
                           |                        v                                    |
                           |         [ Next Stage: Authorization (RBAC/ABAC) ]           |
                           +-------------------------------------------------------------+
```

### Authentication Handler Chain Execution Mechanics

1. **Short-Circuit Evaluation**: Authenticators run sequentially. The first authenticator that successfully parses and validates credentials stops evaluation and returns the authenticated `user.Info` struct. If an authenticator fails to inspect credentials (e.g., no Bearer token provided in header), it passes control to the next authenticator. If an authenticator explicitly encounters an invalid credential (e.g., expired signature), it returns a `401 Unauthorized` HTTP status immediately.
2. **Anonymous Access**: If all enabled authenticators fail to claim the request and `--anonymous-auth=true` (default), the request is assigned the identity `system:anonymous` within the `system:unauthenticated` group.

---

### Core Authentication Mechanisms: Architecture & Trade-Offs

#### 1. X.509 Client Certificates
* **Internal Mechanics**: The TLS layer offloads validation during the initial handshake. The `kube-apiserver` parses the Subject field of the client certificate using its `--client-ca-file` CA root bundle.
  * `Subject.CommonName (CN)` maps directly to the Kubernetes **Username** (e.g., `CN=jane.doe`).
  * `Subject.Organization (O)` fields map to Kubernetes **Groups** (e.g., `O=platform-engineering`, `O=secops`).
* **Architectural Trade-Offs & Security Risks**:
  * **Pros**: Low latency (validated entirely in-memory during TLS handshake, zero network call overhead).
  * **Cons**: **No native revocation mechanism**. Kubernetes `kube-apiserver` does not evaluate CRLs (Certificate Revocation Lists) or OCSP (Online Certificate Status Protocol). If a private key leaks, the certificate remains valid until expiration. Mitigations require re-keying the Cluster CA or using short-lived certificates issued via short-term PKI tools (such as HashiCorp Vault or cert-manager).

#### 2. Bound ServiceAccount Tokens (TokenRequest API & Projected Volumes)
* **Internal Mechanics**: Modern Kubernetes clusters (v1.20+) use *Bound Service Account Tokens*. Older static secrets (`Secret` objects of type `kubernetes.io/service-account-token`) are deprecated.
  * `kube-apiserver` acts as an OIDC Identity Provider (IdP). It signs JSON Web Tokens (JWTs) using its private key (`--service-account-signing-key-file`).
  * The `kubelet` projects these short-lived tokens into Pod containers using the `projected` volume plugin.
  * Tokens are bound to:
    1. **Time** (`exp` claim, auto-rotated by `kubelet` at 80% of lifetime).
    2. **Audience** (`aud` claim, ensuring tokens intended for one service cannot be replayed to another).
    3. **Pod Identity & Object Lineage** (`kubernetes.io` claims referencing pod name, UID, service account name, and secret/pod lifecycle binding).
* **Validation**: Verified in-memory by `kube-apiserver` using public key cryptography (`--service-account-key-file`), or validated by external apps using the API server's public keys hosted at standard OIDC discovery endpoints (`/.well-known/openid-configuration` and `/openid/v1/jwks`).

#### 3. OpenID Connect (OIDC) Authentication
* **Internal Mechanics**: Integrates enterprise Identity Providers (Okta, Keycloak, Ping Identity, Azure AD) without storing credentials in Kubernetes.
  * User authenticates with IdP via OAuth2/OIDC flow to receive an `id_token` (signed JWT).
  * User passes `id_token` as a Bearer token in the `Authorization: Bearer <JWT>` header to `kube-apiserver`.
  * `kube-apiserver` validates the signature out-of-band by fetching public keys from the IdP's `jwks_uri`.
  * Claims map to identity: `--oidc-username-claim` (e.g., `email` or `sub`) and `--oidc-groups-claim` (e.g., `groups`).
* **Architectural Trade-Offs**: Stateless for `kube-apiserver`, highly centralized identity governance, supports MFA enforced at the IdP.

#### 4. Webhook Token Authentication
* **Internal Mechanics**: `kube-apiserver` posts a `TokenReview` JSON object containing the bearer token to an external HTTPS endpoint specified by `--authentication-token-webhook-config-file`.
* **Flow**:
  1. Client sends HTTP request with Bearer token.
  2. `kube-apiserver` wraps token into `authentication.k8s.io/v1` `TokenReview` request body.
  3. External Webhook validates token against remote auth database (e.g., LDAP, custom IAM) and returns `status.authenticated: true` alongside `user` attributes.
  4. Response is cached in memory by `kube-apiserver` based on `--authentication-token-webhook-cache-ttl`.

---

## 2. Production Manifests & Configuration Reference

### Manifest 2.1: CertificateSigningRequest (CSR) for User Identity

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: secops-analyst-csr
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0NQ... # Base64 encoded PKCS#10 CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800 # 8 Hours (Production ephemeral access pattern)
  usages:
  - client auth
```

### Manifest 2.2: Pod with Projected ServiceAccount Token (Custom Audience & Lifetime)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hashicorp-vault-client
  namespace: production
spec:
  serviceAccountName: vault-auth-sa
  containers:
  - name: vault-agent
    image: hashicorp/vault:1.15.2
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - mountPath: /var/run/secrets/tokens
      name: vault-token-volume
  volumes:
  - name: vault-token-volume
    projected:
      sources:
      - serviceAccountToken:
          path: vault-serviceaccount-token
          expirationSeconds: 7200 # 2 hours
          audience: https://vault.internal.net
```

### Manifest 2.3: TokenReview API Payload (Used by Out-of-Band Auth Systems)

```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: "eyJhbGciOiJSUzI1NiIsImtpZCI6Il..."
  audiences:
  - https://kubernetes.default.svc.cluster.local
```

### Manifest 2.4: Webhook Token Authenticator Kubeconfig File

```yaml
# /etc/kubernetes/pki/webhook-auth-config.yaml
apiVersion: v1
kind: Config
clusters:
- name: external-auth-service
  cluster:
    certificate-authority: /etc/kubernetes/pki/webhook-ca.crt
    server: https://auth-webhook.security.svc.cluster.local:8443/validate-token
users:
- name: kube-apiserver
  user:
    client-certificate: /etc/kubernetes/pki/apiserver-webhook-client.crt
    client-key: /etc/kubernetes/pki/apiserver-webhook-client.key
contexts:
- name: webhook
  context:
    cluster: external-auth-service
    user: kube-apiserver
current-context: webhook
```

---

## 3. Hands-On Guided Exercises

### Exercise 1: Provisioning X.509 Client Identities & Analyzing Certificate Constraints

In this exercise, you will manually construct an X.509 private key and Certificate Signing Request (CSR) with specific Subject attributes, submit it to the Kubernetes `certificates.k8s.io` API, approve it, configure `kubectl` to use it, and inspect authentication behavior.

#### Step 1.1: Generate Private Key and PKCS#10 Certificate Request
Execute OpenSSL commands to generate an EC private key and a CSR containing `CN=sre-operator` and group membership `O=platform-engineers` and `O=secops-team`.

```bash
openssl genrsa -out sre-operator.key 2048

openssl req -new -key sre-operator.key -out sre-operator.csr -subj "/CN=sre-operator/O=platform-engineers/O=secops-team"
```

#### Step 1.2: Generate Manifest and Submit CSR to Kubernetes API
Convert the CSR file to a single-line base64 payload and transmit it via `kubectl`.

```bash
export CSR_BASE64=$(cat sre-operator.csr | tr -d '\n' | base64 | tr -d '\n')

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-operator-access
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF
```

**Expected Output:**
```
certificatesigningrequest.certificates.k8s.io/sre-operator-access created
```

#### Step 1.3: Inspect CSR Condition and Grant Approval
Verify the pending state of the CSR using `kubectl get csr`, then execute the approval command.

```bash
kubectl get csr sre-operator-access

kubectl certificate approve sre-operator-access
```

**Expected Output:**
```
NAME                  AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
sre-operator-access   12s   kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Pending
certificatesigningrequest.certificates.k8s.io/sre-operator-access approved
```

#### Step 1.4: Extract Signed Certificate and Configure Kubectl Context
Fetch the issued certificate from `.status.certificate`, build a dedicated kubeconfig entry, and verify identity recognition using `self-subject-review`.

```bash
kubectl get csr sre-operator-access -o jsonpath='{.status.certificate}' | base64 --decode > sre-operator.crt

kubectl config set-credentials sre-operator \
  --client-certificate=sre-operator.crt \
  --client-key=sre-operator.key \
  --embed-certs=true

kubectl config set-context sre-operator-context \
  --cluster=$(kubectl config view -o jsonpath='{.clusters[0].name}') \
  --user=sre-operator

kubectl alpha auth self-subject-review --context=sre-operator-context
```

**Expected Output:**
```
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
status:
  userInfo:
    groups:
    - platform-engineers
    - secops-team
    - system:authenticated
    username: sre-operator
```

---

#### Verification Questions — Exercise 1

* **Question 1.1**: What specific attribute in the CSR defined the Kubernetes user groups assigned to the authenticated entity?
* **Question 1.2**: If the `sre-operator.key` file is compromised 1 hour after generation, what native `kubectl` or `kube-apiserver` command can an SRE run to instantly revoke this X.509 certificate before its 24-hour expiration?
* **Question 1.3**: Why did `SelfSubjectReview` list `system:authenticated` under `groups` even though it was not defined in the OpenSSL `-subj` parameter?

---

### Exercise 2: Bound ServiceAccount Tokens, JWT Claims Parsing, and OIDC Discovery

In this exercise, you will provision a ServiceAccount, deploy a Pod using a Projected ServiceAccount Volume with a custom target audience, inspect the token claims via command line, and validate the token out-of-band via `kube-apiserver` OIDC public key endpoints.

#### Step 2.1: Provision ServiceAccount and Workload Manifest
Execute the following block to create a custom ServiceAccount and launch an interactive debugging Pod configured with projected volume tokens.

```bash
kubectl create namespace auth-test

kubectl create serviceaccount database-migrator -n auth-test

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: token-inspector
  namespace: auth-test
spec:
  serviceAccountName: database-migrator
  containers:
  - name: inspector
    image: alpine:3.19
    command: ["sleep", "3600"]
    volumeMounts:
    - mountPath: /var/run/secrets/tokens/custom
      name: custom-token
    - mountPath: /var/run/secrets/tokens/default
      name: default-token
  volumes:
  - name: custom-token
    projected:
      sources:
      - serviceAccountToken:
          path: vault-aud-token
          expirationSeconds: 3600
          audience: https://spire.internal.domain
  - name: default-token
    projected:
      sources:
      - serviceAccountToken:
          path: k8s-default-token
          expirationSeconds: 7200
EOF
```

**Expected Output:**
```
namespace/auth-test created
serviceaccount/database-migrator created
pod/token-inspector created
```

#### Step 2.2: Extract Projected Token and Decode JWT Payload
Wait for the Pod to reach `Running` status, extract the projected token mounted at `/var/run/secrets/tokens/custom/vault-aud-token`, and split/decode the payload section of the JWT using standard shell tools (`jq` and `base64`).

```bash
kubectl wait --for=condition=Ready pod/token-inspector -n auth-test --timeout=30s

TOKEN=$(kubectl exec -n auth-test token-inspector -- cat /var/run/secrets/tokens/custom/vault-aud-token)

echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```

**Expected Output:**
```json
{
  "aud": [
    "https://spire.internal.domain"
  ],
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "auth-test",
    "pod": {
      "name": "token-inspector",
      "uid": "a24c18f1-432d-45f8-8090-671e227e7d95"
    },
    "serviceaccount": {
      "name": "database-migrator",
      "uid": "e7b0d911-09df-4c3d-bc87-991df9911e32"
    },
    "warnafter": 2808
  },
  "nbf": 1700000000,
  "sub": "system:serviceaccount:auth-test:database-migrator"
}
```

#### Step 2.3: Query Kubernetes OIDC Discovery and JWKS Endpoint
Query the cluster's public discovery documents to inspect the signing keys used by `kube-apiserver` to sign this ServiceAccount token.

```bash
APISERVER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl get --raw /.well-known/openid-configuration | jq .

kubectl get --raw /openid/v1/jwks | jq .
```

**Expected Output (Truncated):**
```json
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://10.96.0.1:443/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
{
  "keys": [
    {
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "kid": "Z9X0vM...",
      "n": "u1A8v...",
      "e": "AQAB"
    }
  ]
}
```

#### Step 2.4: Execute Manual Token Review via API
Send an authentication `TokenReview` request to `kube-apiserver` to verify if the extracted token is valid for the cluster's default audience vs. the SPIRE custom audience.

```bash
cat <<EOF | kubectl create -f -
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: "${TOKEN}"
  audiences:
  - https://spire.internal.domain
EOF
```

**Expected Output:**
```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
status:
  authenticated: true
  user:
    extra:
      authentication.kubernetes.io/pod-name:
      - token-inspector
      authentication.kubernetes.io/pod-uid:
      - a24c18f1-432d-45f8-8090-671e227e7d95
    groups:
    - system:serviceaccounts
    - system:serviceaccounts:auth-test
    - system:authenticated
    uid: e7b0d911-09df-4c3d-bc87-991df9911e32
    username: system:serviceaccount:auth-test:database-migrator
```

---

#### Verification Questions — Exercise 2

* **Question 2.1**: If an attacker steals the token mounted at `/var/run/secrets/tokens/custom/vault-aud-token` and attempts to send a `kubectl` API call directly to `https://kubernetes.default.svc.cluster.local` (without altering the cluster's default target audience checks), why will authentication fail or get restricted?
* **Question 2.2**: Which component of the Kubernetes control plane is responsible for auto-rotating the projected token mounted inside the container before the `exp` timestamp elapses?
* **Question 2.3**: What is the difference in structure and security between modern `Bound ServiceAccount Tokens` and legacy Kubernetes ServiceAccount tokens (`v1.23` and older)?

---

### Exercise 3: Advanced Diagnostic Techniques & Authentication Debugging

In this exercise, you will generate authentication failure scenarios, query API server audit traces, inspect `kubectl` verbosity outputs, and use diagnostic tools to trace failed identity resolution.

#### Step 3.1: Enable Verbose Kubectl Tracing for Authentication Headers
Run a request with `--v=9` log verbosity to trace exact HTTP headers, Bearer tokens, and handshake steps transmitted to the control plane.

```bash
kubectl get pods --namespace=default --v=9 2>&1 | grep -A 4 "Authorization: Bearer"
```

**Expected Output (Truncated):**
```
I0807 19:50:34.102938  10492 round_trippers.go:466] curl -v -XGET  -H "Accept: application/json, */*" -H "User-Agent: kubectl/v1.30.0" -H "Authorization: Bearer eyJhbGciOiJSUzI1..." 'https://127.0.0.1:6443/api/v1/namespaces/default/pods'
```

#### Step 3.2: Simulate an Unauthenticated/Malformed Token Request
Pass an invalid signature token to the API endpoint and analyze the returning HTTP status code and response payload.

```bash
curl -k -i -H "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.INVALID_PAYLOAD.INVALID_SIG" \
  ${APISERVER_URL}/api/v1/namespaces
```

**Expected Output:**
```http
HTTP/2 401 
audit-id: 79f42d2a-c21a-4d2b-930b-33ba50c3de41
content-type: application/json
x-content-type-options: nosniff
date: Fri, 07 Aug 2026 19:50:34 GMT
content-length: 165

{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "Unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

#### Step 3.3: Analyze Kube-APIServer Logs for Authentication Failure Diagnostics
Inspect the API server system logs (or control plane container logs) filtering for authentication error events and JWT validation errors.

```bash
# On a controlplane node running kube-apiserver as a static pod
crictl logs $(crictl ps --name kube-apiserver -q) 2>&1 | grep -E "invalid bearer token|Authentication failed" | tail -n 5
```

**Expected Output:**
```
E0807 19:50:34.184912       1 jwt.go:121] "jwt validate failed" err="invalid signature"
E0807 19:50:34.185001       1 handler.go:242] "Unable to authenticate the request" err="[invalid bearer token, Unable to authenticate the request due to an invalid token]"
```

---

#### Verification Questions — Exercise 3

* **Question 3.1**: What HTTP status code does the `kube-apiserver` return when authentication fails entirely vs. when authentication succeeds but the identity lacks permissions?
* **Question 3.2**: When examining `kube-apiserver` logs for an expired ServiceAccount token, what specific claim in the JWT is flagged by the API server during validation failure?

---

## 4. Official References & Standards

* [Kubernetes Official Documentation: Authenticators](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
* [Kubernetes Tasks: Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
* [Kubernetes Reference: CertificateSigningRequest API v1](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/certificate-signing-request-v1/)
* [OIDC 1.0 Core Specification](https://openid.net/specs/openid-connect-core-1_0.html)
* [RFC 7519: JSON Web Token (JWT)](https://datatracker.ietf.org/doc/html/rfc7519)

---

## 5. Answer Key & Comprehensive Solutions

<details>
<summary>Click to expand solutions for Exercise Verification Questions</summary>

### Exercise 1 Solutions

* **Question 1.1**: 
  * **Answer**: The **`Organization` (`O`)** fields in the Distinguished Name (DN) string of the OpenSSL CSR Subject (`/CN=sre-operator/O=platform-engineers/O=secops-team`). The `kube-apiserver` X.509 authenticator maps every `O` entry directly into a Kubernetes Group membership.

* **Question 1.2**: 
  * **Answer**: **There is no native `kubectl` command to revoke an X.509 client certificate.** The `kube-apiserver` does not check Certificate Revocation Lists (CRLs) or OCSP endpoints. To invalidate the certificate immediately, an SRE must either:
    1. Rotate/re-key the cluster's Root Client CA (`--client-ca-file`), forcing re-issuance of all client certificates.
    2. Deploy an explicit RBAC deny-list (if supported by an authorization proxy/mesh) or remove all RBAC bindings for the compromised user `CN` and groups `O`.
    3. Block access at an upstream API gateway or authentication proxy layer.

* **Question 1.3**: 
  * **Answer**: `system:authenticated` is an **automatically assigned system group**. The `kube-apiserver` appends `system:authenticated` to every request that successfully completes any authenticator in the chain (unless the request is processed by the Anonymous authenticator, which assigns `system:unauthenticated`).

---

### Exercise 2 Solutions

* **Question 2.1**: 
  * **Answer**: When `kube-apiserver` authenticates a token, it checks the token's `aud` (audience) claim against its acceptable audiences (by default, its own API server identity/URL). Because this token was requested with `audience: https://spire.internal.domain`, `kube-apiserver` will reject the token with an invalid audience error if presented directly to the API server endpoints, preventing **token replay attacks** across disparate services.

* **Question 2.2**: 
  * **Answer**: The **`kubelet`** daemon running on the worker node. The `kubelet` monitors projected volume token lifetimes and proactively requests a fresh token via the `TokenRequest` API when the token reaches 80% of its total time-to-live (`expirationSeconds`), updating the mounted file atomically without restarting the Pod container.

* **Question 2.3**: 
  * **Answer**: 
    * **Legacy Tokens**: Were static `Secret` objects stored unencrypted in `etcd`, possessed no expiration date (`exp`), had no audience restriction (`aud`), and were not bound to Pod lifecycle events or Pod UIDs. If stolen, they remained valid indefinitely.
    * **Bound ServiceAccount Tokens**: Are dynamic, short-lived JWTs issued directly by the control plane (`TokenRequest` API), bound to specific audiences, expiration limits, Pod names, and Pod UIDs. They are auto-rotated by `kubelet` and invalidated when the associated Pod object is deleted.

---

### Exercise 3 Solutions

* **Question 3.1**: 
  * **Answer**:
    * **Authentication Failure**: Returns HTTP **`401 Unauthorized`** (meaning: "I do not know who you are or your credentials are invalid").
    * **Authorization Failure**: Returns HTTP **`403 Forbidden`** (meaning: "I know who you are, but your identity does not have RBAC/ABAC permission to perform this action").

* **Question 3.2**: 
  * **Answer**: The **`exp` (Expiration Time)** claim. When `kube-apiserver` parses the payload claims against the current system UTC epoch time, an expired token triggers an error log output such as `token has expired` or `token is expired by X seconds`.

</details>