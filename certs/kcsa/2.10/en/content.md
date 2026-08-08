# 2.10 Client Security

## 1. Motivation and Production Architectural Problem

In Kubernetes architecture, the `kube-apiserver` serves as the central control plane interface. Every interaction—whether executed by human operators (`kubectl`), CI/CD automation pipelines, custom controllers, or external integrations—originates from a client. Client Security defines the security controls, credential management patterns, and transport mechanics applied to client entities before and during interaction with the API server.

```
+-----------------------------------------------------------------------------------+
|                                  CLIENT BOUNDARY                                  |
|                                                                                   |
|  [ Human Operator ]        [ CI/CD Pipeline ]         [ Workload / SDK ]          |
|   (kubectl / Lens)         (Runner / Vault)          (client-go / Operator)       |
+---------+-------------------------+--------------------------+--------------------+
          |                         |                          |
          | X.509 Cert / OIDC Token | Short-Lived Token        | ServiceAccount Token
          v                         v                          v
+-----------------------------------------------------------------------------------+
|                        TRANSPORT SECURITY (mTLS / TLS 1.3)                        |
+-----------------------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------------------+
|                              KUBERNETES API SERVER                                |
|                                                                                   |
|  1. Authentication Handlers (X509, Bearer Token, Webhook, Front-Proxy)            |
|  2. Authorization Handlers  (RBAC / ABAC / Node)                                  |
|  3. Admission Controllers   (Validating / Mutating)                               |
+-----------------------------------------------------------------------------------+
```

### Production Threat Vectors & Failure Modes

1. **Static, Non-Revocable Credentials (X.509 Client Certificates):**
   * **Problem:** Kubernetes `kube-apiserver` authenticates clients presenting valid X.509 certificates signed by a trusted Certificate Authority (specified via `--client-ca-file`). However, the API server **does not support Certificate Revocation Lists (CRLs) or Online Certificate Status Protocol (OCSP) stapling**.
   * **Impact:** If an engineer's private key or an automated client cert is leaked, the credential remains valid until its cryptographic expiration date (which might be months or years in the future). The only remediation is rotating the entire cluster root CA or deploying an external revoking authenticating proxy.

2. **Insecure `kubeconfig` Storage & Credential Hygiene:**
   * **Problem:** Standard `kubeconfig` files (`~/.kube/config`) often store plaintext static bearer tokens, unencrypted base64 client certificate private keys (`client-key-data`), or hardcoded credentials.
   * **Impact:** Inappropriate file permissions (e.g., `0644` instead of `0600`) allow local non-privileged processes, container breakouts, or malware to extract administrative credentials. Hardcoding static credentials in repository check-outs leads to secrets exposure in source control.

3. **Unauthenticated Exposure via Client Proxies (`kubectl proxy`):**
   * **Problem:** `kubectl proxy` establishes a local HTTP server that automatically injects the user's ambient `kubeconfig` credentials into requests forwarded to `kube-apiserver`.
   * **Impact:** Binding `kubectl proxy` to `0.0.0.0` or setting broad `--accept-hosts` patterns transforms the local host into an unauthenticated open proxy. Anyone on the local network can query or mutate the Kubernetes API with the privileges of the running operator.

4. **Bypassing Network & RBAC Scopes via `kubectl port-forward`:**
   * **Problem:** `kubectl port-forward` establishes a SPDY/WebSocket tunnel from the client through the API server down to the Kubelet subresource (`/portforward`), bypassing Pod Ingress policies, Service Mesh authorization controls, and cluster NetworkPolicies.
   * **Impact:** Unfiltered local access to database ports, metrics endpoints, or admin interfaces exposed on Pod loopback interfaces without TLS.

### Internal Mechanics of Client Authentication

When a client initiates an HTTPS request to `kube-apiserver`:
1. **TLS Handshake:** The server presents its certificate. If mutual TLS (mTLS) is enabled, the client presents its client certificate during the handshake.
2. **Authentication Handler Pipeline:** The API server processes the request sequentially through configured authenticators:
   * **RequestHeader Authenticator:** Checks headers injected by front-end proxies.
   * **X509 Authenticator:** Validates client certificate signatures against `client-ca-file`. Extracts `CN` (Common Name) as the Username and `O` (Organization) as Groups.
   * **Bearer Token Authenticator:** Validates tokens via OpenID Connect (OIDC), Webhook token authenticators, or internal ServiceAccount tokens (`v1.JWT`).
   * **Exec Credential Plugin:** Runs client-side binaries (`client.authentication.k8s.io/v1beta1`) via `client-go` IPC to dynamically acquire short-lived bearer tokens (e.g., AWS IAM, GCP Identity, Azure AD, Vault).

---

## 2. Technical Comparisons with Trade-off Tables

### Client Authentication Strategies

| Authentication Strategy | Credential Lifespan | Revocation Support | Secret Storage Location | Attack Vector / Vulnerability | Production Suitability |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **X.509 Client Certificates** | Long-lived (typically 90d–1y) | **None** (Requires Cluster CA Rotation) | Local file (`client-key-data` in kubeconfig) | Key leakage leads to permanent unauthorized cluster access until expiration. | **Anti-Pattern** for human users; acceptable only for internal node/control-plane bootstrap. |
| **Static Bearer Tokens / Static SA Tokens** | Indefinite (Legacy SA tokens) | Manual deletion of Secret resource | Secret manifest / local file | Plaintext exposure in git/logs; no automatic rotation. | **Deprecated / High Risk**. |
| **OIDC / Identity Provider (Keycloak, Okta, Dex)** | Short-lived Access Tokens (5m–1h) | **Immediate** (Revoke at IdP / Refresh Token revocation) | Identity Provider / Memory | Session hijacking of unexpired access tokens. | **Recommended** for all human users. |
| **Exec Credential Plugins (`client-go`)** | Dynamic / Short-lived (typically 15m–1h) | Enforced via external IAM (AWS/GCP/Azure/Vault) | OS Keychain / External IAM CLI cache | Exploitation of binary execution path if helper binary is compromised. | **Recommended Enterprise Standard** for cloud-native infrastructure. |
| **Bound Service Account Tokens (`TokenRequest` API)** | Short-lived (Customizable: 10m–24h) | Automatic garbage collection / Pod termination | Memory (`/var/run/secrets/kubernetes.io/serviceaccount/token`) | Exfiltration of token file while pod is running. | **Recommended Standard** for automated in-cluster clients. |

### Client Access Vectors

| Access Vector | Transport Protocol | Client Authentication Behavior | Authorization Enforcement | Primary Security Risk | Recommended Production Usage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Direct API Server (`https://apiserver:6443`)** | HTTPS / TLS 1.3 | Authenticates via client certificate, OIDC bearer token, or exec plugin. | Standard RBAC / ABAC evaluated per request. | Exposure of control plane IP to untrusted networks if firewalling is missing. | **Standard Production Endpoint** protected by VPN/Zero-Trust Access. |
| **`kubectl proxy`** | Plain HTTP (locally) $\rightarrow$ HTTPS (to API) | Strips client auth locally; automatically appends client credentials upstream. | Evaluated upstream using local operator's RBAC context. | Local binding to `0.0.0.0` turns host into unauthenticated open API gateway. | **Restricted Debugging Only**. Must bind strictly to `127.0.0.1`. |
| **`kubectl port-forward`** | SPDY / WebSockets over HTTPS | Authenticates client at API server layer for `/portforward` subresource. | Checks RBAC for `pods/portforward` `create` verb. | Bypasses NetworkPolicies, Ingress TLS, and Service Mesh authentication. | **Break-Glass Diagnostics Only**. Audit `pods/portforward` RBAC permissions heavily. |
| **Ingress / Gateway API** | HTTPS / HTTP2 | Client authenticates against application layer (OAuth2-Proxy, mTLS). | Application / Ingress Controller authorization policies. | Misconfigured TLS pass-through or application-layer vulnerabilities. | **Standard Path** for application client traffic (non-Kubernetes API). |

---

## 3. Complete Syntactically Valid Manifests & Infrastructure Code

### Manifest 1: Secure `kubeconfig` Utilizing Exec Credential Plugin (`client.authentication.k8s.io/v1beta1`)

This configuration avoids storing static keys or tokens in `~/.kube/config`. It invokes `kubelogin` (OIDC exec plugin) to fetch short-lived OAuth2 tokens dynamically.

```yaml
apiVersion: v1
kind: Config
current-context: production-us-east-1
clusters:
- name: production-us-east-1
  cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg== # Base64 encoded CA Cert
    server: https://k8s-api.prod.example.com:6443
contexts:
- name: production-us-east-1
  context:
    cluster: production-us-east-1
    user: secops-operator@example.com
    namespace: platform-security
users:
- name: secops-operator@example.com
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl-oidc_login
      args:
      - get-token
      - --oidc-issuer-url=https://idp.example.com/auth/realms/production
      - --oidc-client-id=kubernetes-cluster-prod
      - --oidc-client-secret-env=OIDC_CLIENT_SECRET
      - --oidc-extra-scope=groups
      - --oidc-extra-scope=email
      env:
      - name: OIDC_CLIENT_SECRET
        valueFrom:
          exec:
            command: /usr/local/bin/fetch-vault-secret
            args:
            - secret/data/k8s/oidc#client_secret
      interactiveMode: Never
      provideClusterInfo: true
```

### Manifest 2: Kubernetes `CertificateSigningRequest` (`certificates.k8s.io/v1`) for Short-Lived Client Access

To issue short-lived X.509 client certificates via the native Kubernetes API, use the `CertificateSigningRequest` API with explicit `expirationSeconds`.

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: developer-jane-doe-csr
  labels:
    security.example.com/environment: production
    security.example.com/requested-by: jane.doe
spec:
  request: MIIBVzCBzAIBADARMA8GA1UEAwwIamFuZS5kb2UwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC3... # Base64 encoded PKCS#10 CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800 # 8 Hours TTL (Enforces short lifespan)
  usages:
  - client auth
```

### Manifest 3: Least-Privilege RBAC `ClusterRole` and `ClusterRoleBinding` for Client Identity

Defines restricted read-only permissions for human operators authenticated via OIDC belonging to the `oidc:platform-auditors` group.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-auditor-restricted
  labels:
    rbac.example.com/tier: auditor
rules:
- apiGroups: [""]
  resources:
  - namespaces
  - pods
  - services
  - configmaps
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources:
  - deployments
  - statefulsets
  - daemonsets
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources:
  - secrets
  verbs: [] # Explicitly forbid listing or viewing cluster secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bind-platform-auditors
subjects:
- kind: Group
  name: oidc:platform-auditors # Group mapped directly from IdP claim
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-auditor-restricted
  apiGroup: rbac.authorization.k8s.io
```

### Manifest 4: Pod Manifest Enforcing Bound Service Account Tokens (`TokenRequest` API)

Standardizes in-cluster client authentication using short-lived, audience-bound tokens projected via `projected` volumes.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: security-agent-client
  namespace: platform-monitoring
spec:
  serviceAccountName: security-agent-sa
  automountServiceAccountToken: false # Disable default un-bound token automount
  containers:
  - name: agent
    image: registry.example.com/secops/security-agent:v2.4.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - mountPath: /var/run/secrets/tokens
      name: bound-sa-token
      readOnly: true
  volumes:
  - name: bound-sa-token
    projected:
      sources:
      - serviceAccountToken:
          audience: https://vault.example.com/v1/auth/kubernetes
          expirationSeconds: 3600 # 1 Hour TTL
          path: vault-token
      - serviceAccountToken:
          audience: https://kubernetes.default.svc
          expirationSeconds: 1800 # 30 Minutes TTL
          path: k8s-api-token
```

---

## 4. Real CLI Commands and Terminal Outputs ($)

### Scenario A: Generating, Submitting, Approving, and Assembling a Short-Lived X.509 Client Credential

#### Step 1: Generate Private Key and PKCS#10 Certificate Request locally
```bash
$ openssl req -new -newkey rsa:4096 -nodes \
    -keyout jane-doe.key \
    -out jane-doe.csr \
    -subj "/CN=jane.doe/O=oidc:platform-auditors"
```
```text
Generating a RSA private key
................................................................................................+++++
................+++++
writing new private key to 'jane-doe.key'
-----
```

#### Step 2: Generate and apply the Kubernetes CSR object
```bash
$ CSR_BASE64=$(cat jane-doe.csr | tr -d '\n' | base64 | tr -d '\n')
$ cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: jane-doe-access-csr
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800
  usages:
  - client auth
EOF
```
```text
certificatesigningrequest.certificates.k8s.io/jane-doe-access-csr created
```

#### Step 3: Approve the CSR as a Cluster Security Administrator
```bash
$ kubectl certificate approve jane-doe-access-csr
```
```text
certificatesigningrequest.certificates.k8s.io/jane-doe-access-csr approved
```

#### Step 4: Extract the issued client certificate and build an isolated `kubeconfig`
```bash
$ kubectl get csr jane-doe-access-csr -o jsonpath='{.status.certificate}' | base64 --decode > jane-doe.crt

$ kubectl config --kubeconfig=jane-kubeconfig set-cluster prod-cluster \
    --server=https://10.0.100.1:6443 \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true
```
```text
Cluster "prod-cluster" set.
```

```bash
$ kubectl config --kubeconfig=jane-kubeconfig set-credentials jane.doe \
    --client-certificate=jane-doe.crt \
    --client-key=jane-doe.key \
    --embed-certs=true
```
```text
User "jane.doe" set.
```

```bash
$ kubectl config --kubeconfig=jane-kubeconfig set-context prod-auditor \
    --cluster=prod-cluster \
    --user=jane.doe
```
```text
Context "prod-auditor" created.
```

```bash
$ chmod 600 jane-kubeconfig
$ rm -f jane-doe.csr jane-doe.crt jane-doe.key
```

### Scenario B: Hardening and Running `kubectl proxy` Safely

#### Step 1: Launch `kubectl proxy` securely bound ONLY to loopback with explicit host acceptance matching
```bash
$ kubectl proxy --address='127.0.0.1' --port=8001 --accept-hosts='^localhost$,^127\.0\.0\.1$' &
```
```text
Starting to serve on 127.0.0.1:8001
```

#### Step 2: Verify local access via proxy
```bash
$ curl -s http://127.0.0.1:8001/version
```
```json
{
  "major": "1",
  "minor": "30",
  "gitVersion": "v1.30.2",
  "gitCommit": "39683505b630ff2121012f3c3b162b7b8a306000",
  "gitTreeState": "clean",
  "buildDate": "2024-06-12T11:43:10Z",
  "goVersion": "go1.22.4",
  "compiler": "gc",
  "platform": "linux/amd64"
}
```

#### Step 3: Verify network isolation (Attempt access via non-loopback IP fails)
```bash
$ curl -s --max-time 2 http://192.168.1.50:8001/version
```
```text
curl: (7) Failed to connect to 192.168.1.50 port 8001 after 0 ms: Connection refused
```

---

## 5. Verification and Failure Diagnostic Guide

### Diagnostic Matrix for Client Security Failures

```
                              CLIENT SECURITY FAILURE DIAGNOSIS
                                              |
      +---------------------------------------+---------------------------------------+
      |                                       |                                       |
[ TLS / mTLS Error ]               [ 401 Unauthorized ]                    [ Security Leak ]
      |                                       |                                       |
      v                                       v                                       v
Check CA Trust / Cert Expiry    Check Exec Plugin / Token Output       Scan kubeconfig File Permissions
`openssl x509 -text`            `kubectl -v=9`                         `ls -la ~/.kube/config`
`openssl verify -CAfile`        Execute plugin directly                `grep -E "client-key-data"`
```

#### Scenario 1: TLS Handshake Failure (`x509: certificate signed by unknown authority` / `tls: bad certificate`)

* **Symptom:** `kubectl` returns:
  `Unable to connect to the server: x509: certificate signed by unknown authority` or API server logs print `http: TLS handshake error from 10.0.1.15:45210: remote error: tls: bad certificate`.

* **Root Cause 1:** The `certificate-authority-data` in the client's `kubeconfig` does not match the cluster CA signing the API server's serving certificate.
* **Root Cause 2:** The API server's `--client-ca-file` does not include the root/intermediate CA that signed the client's certificate.

* **Diagnostic Commands:**
  ```bash
  # 1. Inspect expiration and issuer of client certificate embedded in kubeconfig
  $ kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 --decode | openssl x509 -text -noout -dates -issuer -subject
  ```
  ```text
  notBefore=Jul  1 10:00:00 2024 GMT
  notAfter=Jul  1 18:00:00 2024 GMT
  issuer=CN = kubernetes-ca
  subject=CN = jane.doe, O = oidc:platform-auditors
  ```

  ```bash
  # 2. Test TLS handshake directly using OpenSSL client
  $ openssl s_client -connect 10.0.100.1:6443 \
      -CAfile /etc/kubernetes/pki/ca.crt \
      -cert jane-doe.crt -key jane-doe.key
  ```
  ```text
  CONNECTED(00000003)
  depth=1 CN = kubernetes-ca
  verify return:1
  depth=0 CN = kube-apiserver
  verify return:1
  ---
  Certificate chain
   0 s:CN = kube-apiserver
   i:CN = kubernetes-ca
  ---
  Server certificate
  -----BEGIN CERTIFICATE-----
  ...
  ```

#### Scenario 2: Authentication failure via Exec Credential Plugin (`401 Unauthorized`)

* **Symptom:** Executing `kubectl get pods` yields `Error from server (Unauthorized): Secure Connection Failed`.

* **Diagnostic Commands:**
  ```bash
  # 1. Run kubectl with maximum verbosity level 9 to inspect raw HTTP request headers
  $ kubectl get pods -v=9
  ```
  ```text
  I0807 19:55:12.102341   12840 round_trippers.go:553] GET https://10.0.100.1:6443/api/v1/namespaces/default/pods
  I0807 19:55:12.102390   12840 round_trippers.go:560] Request Headers:
  I0807 19:55:12.102401   12840 round_trippers.go:564]     Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
  I0807 19:55:12.215402   12840 round_trippers.go:579] Response Status: 401 Unauthorized in 113 milliseconds
  ```

  ```bash
  # 2. Directly execute the credential helper specified in kubeconfig to capture stderr/stdout
  $ kubectl-oidc_login get-token \
      --oidc-issuer-url=https://idp.example.com/auth/realms/production \
      --oidc-client-id=kubernetes-cluster-prod
  ```
  ```json
  {
    "kind": "ExecCredential",
    "apiVersion": "client.authentication.k8s.io/v1beta1",
    "spec": {},
    "status": {
      "expirationTimestamp": "2024-08-07T20:55:12Z",
      "token": "eyJhbGciOiJSUzI1NiIs..."
    }
  }
  ```

  ```bash
  # 3. Decode JWT Token payload to verify signature expiration and audience claims
  $ TOKEN=$(kubectl-oidc_login get-token --oidc-issuer-url=https://idp.example.com/auth/realms/production --oidc-client-id=kubernetes-cluster-prod | jq -r '.status.token')
  $ jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$TOKEN"
  ```
  ```json
  {
    "exp": 1723064112,
    "iat": 1723060512,
    "iss": "https://idp.example.com/auth/realms/production",
    "aud": "kubernetes-cluster-prod",
    "sub": "jdoe_88412",
    "groups": [
      "oidc:platform-auditors"
    ]
  }
  ```
  *If `exp` is in the past, synchronization between local machine system time (NTP) and IdP clock must be verified.*

#### Scenario 3: Auditing Local Client Security & `kubeconfig` File Vulnerabilities

* **Audit Task:** Locate all `kubeconfig` files across developer workstations or build agents with overly permissive permissions (`>0600`) or embedded private keys.

  ```bash
  # Search for kubeconfig files with insecure permissions
  $ find ~/.kube -type f -name "config*" ! -perm 0600 -exec ls -l {} +
  ```
  ```text
  -rw-r--r-- 1 operator staff 5642 Aug  7 14:22 /home/operator/.kube/config
  ```

  ```bash
  # Remediation command
  $ chmod 0600 ~/.kube/config
  ```

  ```bash
  # Audit for embedded unencrypted X.509 private keys stored in plaintext
  $ grep -Hn "client-key-data" ~/.kube/config*
  ```
  ```text
  /home/operator/.kube/config:24:    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ==
  ```
  *Remediation: Migrate from embedded static `client-key-data` to short-lived OIDC or Exec Plugin architecture (`client.authentication.k8s.io/v1beta1`).*

---

## 6. References

* **Kubernetes Official Documentation - Organizing Cluster Access Using kubeconfig Files:**
  [https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
* **Kubernetes Official Documentation - Authenticating:**
  [https://kubernetes.io/docs/reference/access-authn-authz/authentication/](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
* **Kubernetes Official Documentation - Client Go Credential Plugins:**
  [https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins)
* **Kubernetes Official Documentation - Certificate Signing Requests:**
  [https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
* **CNCF KCSA Exam Curriculum:**
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)