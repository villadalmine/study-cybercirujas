# KCSA Exam Preparation: Domain 2 – Kubernetes Ecosystem Security Architecture
## Topic 2.10: Client Security (Weight: 2.0%)

---

## 1. Deep Dive: Technical Architecture & Mechanics

Client security in Kubernetes governs how end-users, automated processes, scripts, and internal applications establish authenticated, authorized, and encrypted channels to the `kube-apiserver`. Securing the client-side attack surface involves strict cryptographic identity validation, credentials isolation, privilege boundary enforcement, and traffic interception mitigation.

```
+-----------------------------------------------------------------------------------+
|                                 CLIENT SIDE ENVIRONMENT                           |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  |  X.509 Client Cert |     |  Kubeconfig File    |     |  Exec Auth Plugin    |  |
|  |  (CN=user, O=group)|     |  (~/.kube/config)   |     |  (AWS IAM / OIDC)    |  |
|  +---------+----------+     +----------+----------+     +----------+-----------+  |
|            |                           |                           |              |
+------------|---------------------------|---------------------------|--------------+
             |                           |                           |               
             +---------------------------+---------------------------+               
                                         |                                           
                             mTLS / HTTPS Request (Port 6443)                        
                                         |                                           
+----------------------------------------v------------------------------------------+
|                             KUBERNETES API SERVER                                 |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  |                          Authentication Pipeline                            |  |
|  |                                                                             |  |
|  |  1. X.509 Client Certs  --> Extract CN (User), O (Group)                    |  |
|  |  2. OIDC / Bearer Token --> Validate JWT Signatures & Claims (sub, aud)    |  |
|  |  3. Webhook / Exec Auth  --> Call External Identity Provider                |  |
|  +-------------------------------------+---------------------------------------+  |
|                                        |                                          |
|                                        v                                          |
|  +-----------------------------------------------------------------------------+  |
|  |                          Authorization (RBAC Engine)                        |  |
|  |  Match (User, Groups) against Roles / ClusterRoles & RoleBindings           |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.1 X.509 Client Certificate Authentication
- **Mechanism:** The `kube-apiserver` relies on mutual TLS (mTLS) to authenticate clients presenting X.509 certificates signed by a trusted Certificate Authority (CA) passed via `--client-ca-file`.
- **Identity Extraction:**
  - `Subject: CN = <username>` maps to the Kubernetes user identity.
  - `Subject: O = <groupname>` maps to the Kubernetes group membership. Multiple `O` fields yield multiple group memberships.
- **Security Limitation:** Kubernetes lacks an inline Certificate Revocation List (CRL) or Online Certificate Status Protocol (OCSP) checking mechanism within `kube-apiserver`. Once issued, an X.509 certificate remains valid until expiration unless the underlying CA is rotated. Therefore, short lifespans or alternative token-based methods (OIDC/Webhook) are mandatory in high-security architectures.

### 1.2 Kubeconfig Mechanics & Exec Credential Plugins
- **Kubeconfig File Structure (`~/.kube/config`):** Encapsulates `clusters` (server endpoints + CA certificates), `users` (credentials), and `contexts` (binding cluster + user + default namespace).
- **Exec Credential Plugins (`client.authentication.k8s.io/v1beta1`):** Enables client tools (e.g., `kubectl`, `helm`) to invoke an external binary (e.g., `aws-iam-authenticator`, `gke-gcloud-auth-plugin`, `kubelogin`) to dynamically acquire short-lived bearer tokens.
- **Attack Vectors:**
  - **Arbitrary Command Execution:** Malicious or compromised kubeconfig files containing `user.exec` definitions can execute arbitrary host commands when parsed by `kubectl`.
  - **Insecure File Permissions:** Exposure of `~/.kube/config` with permissions wider than `0600` allows local privilege escalation and credential theft.

### 1.3 ServiceAccount Client Tokens & Token Request API
- **Legacy ServiceAccount Tokens (Pre-v1.24):** Static, non-expiring JWTs stored directly in Secret objects. Exposed high risks of lateral movement upon container compromise.
- **Projected ServiceAccount Tokens (`boundServiceAccountToken`):**
  - Issued via the `TokenRequest` API with configurable time-to-live (`expirationSeconds`) and target audience binding (`audience`).
  - Automatically mounted via `projected` volume plugins in Pods.
  - Cryptographically signed by the API server using RS256/ES256 algorithms.
  - Bound to the exact pod identity; if the Pod is deleted, the token becomes invalid.

### 1.4 Client Interception and Proxy Security Hazards
- **`kubectl proxy`:** Opens a local HTTP server that proxies requests to the `kube-apiserver`. By default, it strips authentication headers and exposes unauthenticated control plane access if bound to non-loopback interfaces (e.g., `0.0.0.0`).
- **`kubectl port-forward`:** Establishes a direct TCP tunnel to a specific Pod/Service via SPDY/HTTP2 multiplexing. While encrypted via the API server TLS tunnel, improper local port binding can expose internal workload endpoints to local network eavesdroppers.

---

## 2. Hands-On Guided Production Exercises

### Exercise 1: Provisioning Short-Lived X.509 Client Certificates via the Kubernetes CSR API and Enforcing RBAC Boundaries

#### Scenario
You are tasked with onboarding a developer, `dev-security-analyst`, who requires read-only access to Pods in the `sec-audit` namespace. You must generate a client keypair, submit a `CertificateSigningRequest` (CSR) to the Kubernetes API, approve it, extract the signed certificate, and scope access using RBAC.

#### Step 1: Create the `sec-audit` namespace
```bash
kubectl create namespace sec-audit
```
```text
namespace/sec-audit created
```

#### Step 2: Generate a private key and Certificate Signing Request (CSR) locally
Generate a 2048-bit RSA private key and a CSR specifying `CN=dev-security-analyst` and `O=sec-auditors`.

```bash
openssl req -new -newkey rsa:2048 -nodes \
  -keyout dev-security-analyst.key \
  -out dev-security-analyst.csr \
  -subj "/CN=dev-security-analyst/O=sec-auditors"
```
```text
Generating a RSA private key
................+++++
................................+++++
writing new private key to 'dev-security-analyst.key'
-----
```

#### Step 3: Base64-encode the CSR content and construct the Kubernetes CSR manifest
Encode the CSR without line breaks and embed it into a `CertificateSigningRequest` object.

```bash
CSR_BASE64=$(cat dev-security-analyst.csr | base64 | tr -d '\n')

cat <<EOF > csr-dev-security-analyst.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: dev-security-analyst-csr
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400  # 24 Hours
  usages:
  - client auth
EOF

kubectl apply -f csr-dev-security-analyst.yaml
```
```text
certificatesigningrequest.certificates.k8s.io/dev-security-analyst-csr created
```

#### Step 4: Verify and approve the CSR using `kubectl`
```bash
kubectl get csr dev-security-analyst-csr
```
```text
NAME                        AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
dev-security-analyst-csr    5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Pending
```

Approve the CSR:
```bash
kubectl certificate approve dev-security-analyst-csr
```
```text
certificatesigningrequest.certificates.k8s.io/dev-security-analyst-csr approved
```

#### Step 5: Extract the signed X.509 client certificate
```bash
kubectl get csr dev-security-analyst-csr -o jsonpath='{.status.certificate}' | base64 -d > dev-security-analyst.crt
```

Inspect the certificate using `openssl`:
```bash
openssl x509 -in dev-security-analyst.crt -text -noout | grep -E "Subject:|Issuer:|Not After"
```
```text
        Issuer: CN = kubernetes
        Not After : Aug  8 19:43:36 2026 GMT
        Subject: CN = dev-security-analyst, O = sec-auditors
```

#### Step 6: Create an RBAC Role and RoleBinding scoped to `sec-audit`
```bash
cat <<EOF > rbac-sec-audit.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: sec-audit
  name: pod-read-only
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods-dev-security-analyst
  namespace: sec-audit
subjects:
- kind: User
  name: dev-security-analyst
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-read-only
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f rbac-sec-audit.yaml
```
```text
role.rbac.authorization.k8s.io/pod-read-only created
rolebinding.rbac.authorization.k8s.io/read-pods-dev-security-analyst created
```

#### Step 7: Verify client authorization using `kubectl auth can-i`
```bash
kubectl auth can-i list pods --namespace sec-audit --as=dev-security-analyst
```
```text
yes
```

```bash
kubectl auth can-i delete pods --namespace sec-audit --as=dev-security-analyst
```
```text
no
```

```bash
kubectl auth can-i list pods --namespace default --as=dev-security-analyst
```
```text
no
```

---

### Verification Questions – Exercise 1

**Question 1.1:** Why can an administrator **not** revoke an individual X.509 client certificate before its expiration date (`expirationSeconds: 86400`) directly via `kubectl` or `kube-apiserver` API configuration?
- A) The API server automatically invalidates certificates when the corresponding `CertificateSigningRequest` object is deleted.
- B) Kubernetes does not implement CRLs or OCSP checking against client certificates presented at the mTLS layer.
- C) X.509 client certificates are cached in `etcd` and can only be invalidated by clearing the `etcd` memory pool.
- D) `kube-apiserver` checks certificate validity against OpenSSL environment variables, which require a control-plane pod restart to update.

**Question 1.2:** In the certificate subject `/CN=dev-security-analyst/O=sec-auditors`, how does the Kubernetes authorization engine evaluate the `O=sec-auditors` attribute?
- A) As a target Namespace restricting where the user can execute commands.
- B) As a ServiceAccount name inside the default namespace.
- C) As a Group identity, enabling RBAC bindings that reference `kind: Group` and `name: sec-auditors`.
- D) As an encryption key identifier for Secret decrypt operations.

---

### Exercise 2: Hardening Kubeconfig Files, Restricting File Permissions, and Mitigating Exec Credential Plugin Risks

#### Scenario
You are auditing client-side workstation security. You need to configure a dedicated kubeconfig context for `dev-security-analyst`, enforce strict POSIX file permissions, and analyze the security implications of `exec` credential plugins.

#### Step 1: Configure isolated credentials and contexts inside a dedicated kubeconfig file
Set cluster details, client credentials, and context parameters in `sec-analyst.kubeconfig`.

```bash
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt

# Set cluster entry
kubectl --kubeconfig=sec-analyst.kubeconfig config set-cluster production-cluster \
  --server=${CLUSTER_SERVER} \
  --embed-certs=true \
  --certificate-authority=ca.crt

# Set user credentials with X.509 cert and key
kubectl --kubeconfig=sec-analyst.kubeconfig config set-credentials dev-security-analyst \
  --client-certificate=dev-security-analyst.crt \
  --client-key=dev-security-analyst.key \
  --embed-certs=true

# Set context entry
kubectl --kubeconfig=sec-analyst.kubeconfig config set-context sec-audit-context \
  --cluster=production-cluster \
  --user=dev-security-analyst \
  --namespace=sec-audit

# Use context
kubectl --kubeconfig=sec-analyst.kubeconfig config use-context sec-audit-context
```
```text
Cluster "production-cluster" set.
User "dev-security-analyst" set.
Context "sec-audit-context" created.
Switched to context "sec-audit-context".
```

#### Step 2: Enforce strict file permissions on the kubeconfig file
Inspect current permissions and restrict access exclusively to the file owner (`0600`).

```bash
ls -l sec-analyst.kubeconfig
```
```text
-rw-r--r-- 1 root root 4120 Aug  7 19:43 sec-analyst.kubeconfig
```

Remediate file permissions:
```bash
chmod 0600 sec-analyst.kubeconfig
ls -l sec-analyst.kubeconfig
```
```text
-rw------- 1 root root 4120 Aug  7 19:43 sec-analyst.kubeconfig
```

#### Step 3: Test access using the hardened kubeconfig file
```bash
kubectl --kubeconfig=sec-analyst.kubeconfig get pods
```
```text
No resources found in sec-audit namespace.
```

Attempting to access unauthorized resources:
```bash
kubectl --kubeconfig=sec-analyst.kubeconfig get secrets --namespace default
```
```text
Error from server (Forbidden): secrets is forbidden: User "dev-security-analyst" cannot list resource "secrets" in API group "" in the namespace "default"
```

#### Step 4: Analyze Exec Credential Plugin Mechanics and Security Risks
Inspect how `exec` authentication plugins work in kubeconfig manifests.

```bash
cat <<EOF > exec-demo.kubeconfig
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: $(cat ca.crt | base64 | tr -d '\n')
  name: demo-cluster
contexts:
- context:
    cluster: demo-cluster
    user: exec-user
  name: demo-context
current-context: demo-context
users:
- name: exec-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: echo
      args:
      - '{"apiVersion": "client.authentication.k8s.io/v1beta1", "kind": "ExecCredential", "status": {"token": "dummy-token"}}'
      interactiveMode: Never
EOF
```

> [!WARNING]
> Kubeconfig `exec` plugins execute binaries on the local host with the privileges of the user running `kubectl`. Never accept or run `kubectl` commands using untrusted kubeconfig files without inspecting the `users[].user.exec` section for malicious command execution or parameter injection.

---

### Verification Questions – Exercise 2

**Question 2.1:** What is the primary security vulnerability introduced by opening read permissions (`chmod 0644`) on a user's `~/.kube/config` file containing embedded client certificates and keys?
- A) The API server automatically downgrades HTTPS connections to plain HTTP for unprivileged local users.
- B) Any local process running under a different user account on the same machine can extract private keys and impersonate the user against the cluster.
- C) `kubectl` rejects the config file and throws a mandatory `PermissionDeniedError` stopping execution.
- D) Etcd automatically revokes the user's cluster credentials upon detecting file permission changes.

**Question 2.2:** When using an `exec` credential plugin (`client.authentication.k8s.io/v1beta1`), what format must the invoked binary output to stdout for `kubectl` to process authentication successfully?
- A) A raw base64-encoded X.509 client certificate string.
- B) A JSON object of kind `ExecCredential` containing a valid token or client certificate details in its `status` field.
- C) A plain text HTTP header string formatted as `Authorization: Bearer <token>`.
- D) An encrypted YAML file containing the user's password.

---

### Exercise 3: Implementing Short-Lived Bound ServiceAccount Tokens and Audience Validation

#### Scenario
You are deploying a security agent pod in the `sec-audit` namespace. The agent requires an API token to authenticate against an external vault system as well as the Kubernetes API. You must configure projected volume tokens with constrained audiences and custom expiration settings, and cryptographically audit the resulting JWT.

#### Step 1: Create a ServiceAccount in the `sec-audit` namespace
```bash
kubectl create serviceaccount sec-agent-sa --namespace sec-audit
```
```text
serviceaccount/sec-agent-sa created
```

#### Step 2: Deploy a Pod utilizing Projected ServiceAccount Tokens
Define a Pod manifest that projects two distinct tokens into `/var/run/secrets/tokens`:
1. `k8s-token`: Audience `https://kubernetes.default.svc`, expiration 3600 seconds.
2. `vault-token`: Audience `https://vault.internal.sec`, expiration 7200 seconds.

```bash
cat <<EOF > pod-bound-tokens.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sec-agent-pod
  namespace: sec-audit
spec:
  serviceAccountName: sec-agent-sa
  containers:
  - name: agent
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: token-vol
      mountPath: /var/run/secrets/tokens
      readOnly: true
  volumes:
  - name: token-vol
    projected:
      sources:
      - serviceAccountToken:
          audience: https://kubernetes.default.svc
          expirationSeconds: 3600
          path: k8s-token
      - serviceAccountToken:
          audience: https://vault.internal.sec
          expirationSeconds: 7200
          path: vault-token
EOF

kubectl apply -f pod-bound-tokens.yaml
```
```text
pod/sec-agent-pod created
```

#### Step 3: Verify token projection inside the container
Wait for the Pod to reach the `Running` state:

```bash
kubectl wait --for=condition=Ready pod/sec-agent-pod --namespace sec-audit --timeout=30s
```
```text
pod/sec-agent-pod condition met
```

Inspect mounted token files:
```bash
kubectl exec -n sec-audit sec-agent-pod -- ls -la /var/run/secrets/tokens
```
```text
total 0
drwxrwxrwt    2 root     root            80 Aug  7 19:43 .
drwxr-xr-x    3 root     root            20 Aug  7 19:43 ..
lrwxrwxrwx    1 root     root            16 Aug  7 19:43 k8s-token -> ..data/k8s-token
lrwxrwxrwx    1 root     root            18 Aug  7 19:43 vault-token -> ..data/vault-token
```

#### Step 4: Extract and inspect JWT claims of the bound tokens
Extract the `vault-token` from the Pod and decode its payload using `jq` and `base64`.

```bash
VAULT_TOKEN=$(kubectl exec -n sec-audit sec-agent-pod -- cat /var/run/secrets/tokens/vault-token)

# Parse JWT Header and Payload
echo "$VAULT_TOKEN" | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .
```
```json
{
  "aud": [
    "https://vault.internal.sec"
  ],
  "exp": 1786148616,
  "iat": 1786141416,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "nbf": 1786141416,
  "sub": "system:serviceaccount:sec-audit:sec-agent-sa",
  "kubernetes.io": {
    "namespace": "sec-audit",
    "pod": {
      "name": "sec-agent-pod",
      "uid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    },
    "serviceaccount": {
      "name": "sec-agent-sa",
      "uid": "f9e8d7c6-b5a4-3210-fedc-ba0987654321"
    }
  }
}
```

> [!NOTE]
> Notice that the `aud` (audience) claim is restricted to `https://vault.internal.sec` and the payload contains exact bindings to the Pod's `name` and `uid`. If this token is presented to the Kubernetes API server instead of Vault, the API server rejects it because its audience does not match `https://kubernetes.default.svc`.

---

### Verification Questions – Exercise 3

**Question 3.1:** What happens when an attacker steals a projected `boundServiceAccountToken` with `audience: https://vault.internal.sec` and attempts to use it to perform administrative requests against the `kube-apiserver`?
- A) The request succeeds because all ServiceAccount tokens have cluster-wide validity regardless of audience claims.
- B) The API server rejects the token because the `aud` claim in the JWT does not match the API server's expected audience list.
- C) The API server accepts the request, but downgrades the user's permission to `system:unauthenticated`.
- D) Etcd flags the Pod's ServiceAccount as compromised and automatically deletes the container.

**Question 3.2:** How do short-lived projected ServiceAccount tokens mitigate the security risks associated with legacy Kubernetes ServiceAccount Secret tokens?
- A) Projected tokens are encrypted using symmetrical AES keys stored in hardware security modules (HSM).
- B) Projected tokens feature dynamic rotation, strict time-based expiry (`exp`), specific target audience restrictions (`aud`), and cryptographically bound Pod object references (`pod.uid`).
- C) Legacy secret tokens could only be transmitted over plain HTTP, whereas projected tokens enforce HTTPS.
- D) Projected tokens do not use JSON Web Tokens (JWT) and rely entirely on static basic authentication header credentials.

---

### Exercise 4: Client Connection Hardening: mTLS Enforcement, CA Pinning, and Proxy Mitigation

#### Scenario
You are auditing client connections to the `kube-apiserver`. You must analyze the security risks of skipping TLS verification (`--insecure-skip-tls-verify`), observe `kubectl proxy` default behaviors, and enforce client transport security.

#### Step 1: Demonstrate the hazard of `--insecure-skip-tls-verify`
Attempt a request to the API server forcing TLS verification bypass:

```bash
kubectl get nodes --insecure-skip-tls-verify=true --v=6
```
```text
I0807 19:43:36.123456   12345 loader.go:395] Config loaded from file: /root/.kube/config
I0807 19:43:36.130000   12345 round_trippers.go:553] GET https://127.0.0.1:6443/api/v1/nodes 200 OK in 7 milliseconds
...
```

> [!CAUTION]
> Setting `insecure-skip-tls-verify: true` in kubeconfig disables server certificate verification. This exposes client communications to Man-in-the-Middle (MitM) attacks, allowing rogue proxies to intercept, inspect, and mutate cluster API traffic including authentication tokens and secrets.

#### Step 2: Analyze `kubectl proxy` exposure risks
Start a `kubectl proxy` instance bound to all interfaces (`0.0.0.0`) in the background.

```bash
kubectl proxy --address='0.0.0.0' --port=8001 &
PROXY_PID=$!
sleep 2
```
```text
Starting to serve on [::]:8001
```

Query the proxy unauthenticated via `curl` on HTTP:
```bash
curl -s http://127.0.0.1:8001/version
```
```json
{
  "major": "1",
  "minor": "30",
  "gitVersion": "v1.30.0",
  "gitCommit": "7c40c5571b0e56881dd7820525696aec6cfc0f1d",
  "gitTreeState": "clean",
  "buildDate": "2024-04-17T17:28:44Z",
  "goVersion": "go1.22.2",
  "compiler": "gc",
  "platform": "linux/amd64"
}
```

Terminate the insecure proxy process:
```bash
kill $PROXY_PID
```

> [!IMPORTANT]
> `kubectl proxy` strips client authentication headers and exposes an unauthenticated HTTP entrypoint to the API server. If bound to `0.0.0.0` or accessible across network boundaries without secondary authentication, it provides full unauthenticated cluster access matching the privileges of the local `kubectl` context.

---

### Verification Questions – Exercise 4

**Question 4.1:** An engineer sets `insecure-skip-tls-verify: true` inside a CI/CD pipeline kubeconfig to bypass self-signed certificate errors. What specific threat does this introduce?
- A) The API server disables RBAC authorization checks for all requests originating from that pipeline.
- B) The pipeline becomes vulnerable to Man-in-the-Middle (MitM) attacks where an attacker can intercept and modify cluster resources or steal bearer tokens.
- C) Kubernetes automatically deletes the service account used by the pipeline after 10 requests.
- D) The client private key is transmitted in plaintext over DNS queries.

**Question 4.2:** What is the fundamental difference between `kubectl proxy` and `kubectl port-forward` regarding authentication to the `kube-apiserver`?
- A) `kubectl proxy` encrypts traffic using SSH, whereas `kubectl port-forward` uses plain HTTP.
- B) `kubectl proxy` creates an HTTP server that handles API server authentication on behalf of the client, whereas `kubectl port-forward` tunnels direct TCP connections to a pod without acting as an API server proxy.
- C) `kubectl port-forward` bypasses all RBAC authorization checks on the control plane.
- D) `kubectl proxy` can only be executed by the `root` user on worker nodes.

---

## 3. Official References & Standards

- **Kubernetes Documentation – Authenticators:**  
  https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- **Kubernetes Documentation – Organizing Cluster Access Using Kubeconfig Files:**  
  https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- **Kubernetes Documentation – ServiceAccount Token Volume Projection:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection
- **Kubernetes Documentation – Managing Certificates with CSR API:**  
  https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/
- **CNCF KCSA Curriculum Specification:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

---

## 4. Verification Solutions & Explanations

<details>
<summary>Click to expand Answer Key & Detailed Technical Explanations</summary>

### Exercise 1 Solutions

#### Question 1.1
- **Correct Answer:** **B**
- **Detailed Explanation:** Kubernetes `kube-apiserver` authenticates X.509 client certificates at the TLS transport layer using standard CA verification routines. Kubernetes does not integrate an inline Certificate Revocation List (CRL) or Online Certificate Status Protocol (OCSP) verification loop. Once an X.509 certificate is signed by a trusted CA, it remains valid until its cryptographic `Not After` timestamp expires. To invalidate access earlier, administrators must either rotate the cluster client CA entirely or implement RBAC bindings that explicitly block or remove permissions for that `User`/`Group`.

#### Question 1.2
- **Correct Answer:** **C**
- **Detailed Explanation:** When `kube-apiserver` parses an X.509 client certificate, it extracts the Subject `CommonName` (`CN`) as the Kubernetes `User` string, and every `Organization` (`O`) entry as a Kubernetes `Group` string. In RBAC policies, a `RoleBinding` or `ClusterRoleBinding` can bind permissions directly to `kind: Group` with `name: sec-auditors`.

---

### Exercise 2 Solutions

#### Question 2.1
- **Correct Answer:** **B**
- **Detailed Explanation:** Kubeconfig files often contain embedded plain-text client private keys (`client-key-data`) or bearer tokens. If POSIX file permissions allow world/group read access (`0644` or `0666`), any unauthorized process or user logged into the local operating system can read the file, extract client keys or tokens, and impersonate that identity against the Kubernetes cluster.

#### Question 2.2
- **Correct Answer:** **B**
- **Detailed Explanation:** Client exec credential plugins communicate with `kubectl` via standard input/output streams. The plugin binary must output a valid JSON structure conforming to `apiVersion: client.authentication.k8s.io/v1beta1` and `kind: ExecCredential`. The output must populate `.status.token` or `.status.clientCertificateData`/`.status.clientKeyData` for `kubectl` to attach credentials to outbound API requests.

---

### Exercise 3 Solutions

#### Question 3.1
- **Correct Answer:** **B**
- **Detailed Explanation:** ServiceAccount tokens generated via the `TokenRequest` API are structured JSON Web Tokens (JWTs) containing an `aud` (audience) claim array. The `kube-apiserver` validates that its own identifier (typically `https://kubernetes.default.svc` or custom cluster domain) is present in the `aud` claim. If an attacker attempts to use a token scoped specifically for `https://vault.internal.sec` against the `kube-apiserver`, token validation fails during request authentication.

#### Question 3.2
- **Correct Answer:** **B**
- **Detailed Explanation:** Legacy ServiceAccount tokens were non-expiring secrets stored permanently in etcd and mounted as plain text files without audience limits. Projected bound ServiceAccount tokens resolve these vulnerabilities by introducing short expiration periods (`expirationSeconds`), explicit audience bindings (`aud`), automatic lifecycle rotation managed by the kubelet, and cryptographic binding to the Pod's specific `name` and `uid`.

---

### Exercise 4 Solutions

#### Question 4.1
- **Correct Answer:** **B**
- **Detailed Explanation:** Disabling TLS verification (`insecure-skip-tls-verify: true`) instructs the HTTP client (`kubectl` or SDKs) to skip validating the server's TLS certificate chain and hostname against trusted CAs. An attacker positioned on the network path can intercept traffic via ARP spoofing, DNS poisoning, or rogue proxies, presenting a forged certificate to read sensitive payload data (including authentication headers) or inject malicious responses.

#### Question 4.2
- **Correct Answer:** **B**
- **Detailed Explanation:** `kubectl proxy` acts as an authenticating reverse proxy: it listens on a local port, terminates incoming unauthenticated HTTP requests, injects the user's active `kubectl` authentication credentials, and forwards requests to the API server REST endpoint. In contrast, `kubectl port-forward` opens an encrypted SPDY/HTTP2 multiplexed tunnel through the API server directly to a target Pod/Service port, without exposing or proxying the API server REST interface itself.

</details>