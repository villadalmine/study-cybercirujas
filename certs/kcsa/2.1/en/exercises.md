# KCSA Certification Module: Topic 2.1 – API Server Security Architecture & Hardening

**Domain:** Cluster Security Architecture / Control Plane Hardening  
**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Topic:** 2.1 API Server Security  
**Weight:** 2.0  
**Reference Sources:**
- [CNCF KCSA Curriculum v1.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Official Documentation - kube-apiserver Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Kubernetes Official Documentation - Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes Official Documentation - Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Kubernetes Official Documentation - Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

## 1. Architectural Overview & Request Processing Pipeline

The `kube-apiserver` acts as the primary control plane gateway for all cluster interactions. Every request (from human administrators, ServiceAccounts, node kubelets, or external controllers) undergoes a strict, sequential multi-stage processing pipeline before mutating or reading state from `etcd`.

```
                    +-------------------------------------------------------+
                    |                 kube-apiserver Pipeline               |
                    +-------------------------------------------------------+
  Incoming Request  |                                                       |
  (TLS / Port 6443) |---> [ 1. Transport Security (mTLS / TLS 1.3) ]         |
                    |                   |                                   |
                    |                   v                                   |
                    |         [ 2. Authentication (AuthN) ]                 |
                    |                   | (User / Groups / ServiceAccount)  |
                    |                   v                                   |
                    |         [ 3. Authorization (AuthZ) ]                  |
                    |                   | (RBAC / Node / Webhook)           |
                    |                   v                                   |
                    |     [ 4. Admission Control (Mutating) ]               |
                    |                   |                                   |
                    |                   v                                   |
                    |     [ 5. Schema Validation & Object Verification ]    |
                    |                   |                                   |
                    |                   v                                   |
                    |     [ 6. Admission Control (Validating) ]             |
                    |                   |                                   |
                    +-------------------|-----------------------------------+
                                        v
                            [ etcd Persistence Storage ]
```

### Key Security Vectors & Mechanics
1. **Authentication (AuthN):** Validates identity via X.509 client certificates, OIDC, Webhook Tokens, or ServiceAccount JWTs. Anonymous requests (`system:unauthenticated`) must be restricted.
2. **Authorization (AuthZ):** Evaluates if the authenticated identity can perform `verbs` (e.g., `get`, `create`, `delete`) on `resources`. Modes execute in declared order (`--authorization-mode=Node,RBAC`).
3. **Admission Control:** Intercepts requests after AuthZ but prior to etcd persistence. Mutating webhooks patch payloads; Validating webhooks enforce security invariants (e.g., Pod Security Standards).
4. **Audit Logging:** Captures state transitions across four granular stages: `RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`.

---

## 2. Hands-On Guided Exercises

---

### Exercise 1: Control Plane Hardening & TLS Cipher Suite Optimization

#### Scenario
As a Senior SRE, you are tasked with hardening a control plane node. You must disable unauthenticated access, restrict TLS negotiation to strong modern ciphers, and enforce mutual TLS (mTLS) for etcd communications.

#### Step 1.1: Audit the existing API Server static pod configuration
Locate and view the static pod manifest for `kube-apiserver` on your control plane node.

```bash
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Expected Output (Excerpt):**
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.1.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --secure-port=6443
    image: registry.k8s.io/kube-apiserver:v1.30.0
```

#### Step 1.2: Apply Production Hardening Flags
Modify `/etc/kubernetes/manifests/kube-apiserver.yaml` to enforce the following security parameters:
- Disable anonymous authentication: `--anonymous-auth=false`
- Set minimum TLS version to 1.3: `--tls-min-version=VersionTLS13`
- Restrict cipher suites for TLS 1.2 fallbacks: `--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`

```bash
sudo yq eval -i '.spec.containers[0].command += [
  "--anonymous-auth=false",
  "--tls-min-version=VersionTLS13",
  "--tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
]' /etc/kubernetes/manifests/kube-apiserver.yaml
```

#### Step 1.3: Verify kube-apiserver Restart and Port Handshake
Monitor the API Server pod replacement by the local `kubelet`:

```bash
sudo crictl ps --name kube-apiserver
```

**Expected Output:**
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS      POD ID
f3a82910c2d3b       a6a4a87262111       12 seconds ago      Running             kube-apiserver      0             12a4b899c011e
```

Verify TLS negotiation using `openssl`:

```bash
openssl s_client -connect 127.0.0.1:6443 -tls1_2 < /dev/null
```

**Expected Output (Excerpt):**
```text
CONNECTED(00000003)
140683050116416:error:1409442E:SSL routines:ssl3_read_bytes:tlsv1 alert protocol version:../ssl/record/rec_layer_s3.c:1544:SSL alert number 70
---
no peer certificate available
```

#### Step 1.4: Verify Anonymous Request Behavior
Attempt an unauthenticated request to the API Server:

```bash
curl -k -X GET https://127.0.0.1:6443/api/v1/namespaces
```

**Expected Output:**
```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "unauthorized",
  "reason": "Unauthorized",
  "code": 401
}
```

---

#### Verification Questions (Exercise 1)

1. What security vulnerability is introduced when `--anonymous-auth=true` is combined with an overly permissive RBAC binding for `system:unauthenticated` or `system:authenticated`?
2. Why does setting `--tls-min-version=VersionTLS13` render the `--tls-cipher-suites` flag ineffective for TLS 1.3 handshakes?

---

### Exercise 2: Implementing Enterprise Audit Logging & Threat Detection

#### Scenario
Regulatory compliance requires logging all secret modifications at `RequestResponse` level, metadata for all pod operations, and ignoring low-risk read-only system health requests to reduce I/O overhead.

#### Step 2.1: Construct the Audit Policy Manifest
Create a syntactically valid Kubernetes Audit Policy file at `/etc/kubernetes/audit-policy.yaml`:

```yaml
cat <<'EOF' | sudo tee /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # 1. Omit noisy system health check endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/metrics"

  # 2. Ignore system controller leases
  - level: None
    resources:
      - group: ""
        resources: ["endpoints", "services/status"]
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # 3. Log Secret and ConfigMap modifications at RequestResponse level for forensic analysis
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
    verbs: ["create", "update", "patch", "delete"]

  # 4. Log Pod modifications at Request level
  - level: Request
    resources:
      - group: ""
        resources: ["pods"]
    verbs: ["create", "update", "patch", "delete"]

  # 5. Catch-all rule for metadata level for all other requests
  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF
```

#### Step 2.2: Configure `kube-apiserver` Audit Flags & Host Path Volume Mounts
Update `/etc/kubernetes/manifests/kube-apiserver.yaml` to include audit flags and mount the host directories.

Add flags to `spec.containers[0].command`:
- `--audit-log-path=/var/log/kubernetes/audit.log`
- `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`
- `--audit-log-maxage=30`
- `--audit-log-maxbackup=10`
- `--audit-log-maxsize=100`

Add Volume Mounts to `spec.containers[0].volumeMounts`:
```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: audit-log
      readOnly: false
```

Add Volumes to `spec.volumes`:
```yaml
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
```

Apply these edits directly to `/etc/kubernetes/manifests/kube-apiserver.yaml`.

#### Step 2.3: Generate Target Audit Events
Create a test namespace and a Secret to trigger the configured audit rules:

```bash
kubectl create namespace audit-test
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=SuperSecretPass123! \
  -n audit-test
```

#### Step 2.4: Inspect JSON Audit Logs for Forensic Evidence
Query `/var/log/kubernetes/audit.log` to extract the `RequestResponse` event for the created Secret:

```bash
sudo tail -n 100 /var/log/kubernetes/audit.log | jq 'select(.objectRef.resource=="secrets" and .verb=="create")'
```

**Expected Output (Excerpt):**
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-test/secrets?fieldManager=kubectl-create",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": [
      "system:masters",
      "system:authenticated"
    ]
  },
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-test",
    "name": "db-credentials",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 201
  },
  "responseObject": {
    "kind": "Secret",
    "apiVersion": "v1",
    "metadata": {
      "name": "db-credentials",
      "namespace": "audit-test"
    },
    "data": {
      "password": "U3VwZXJTZWNyZXRQYXNzMTIzIQ==",
      "username": "YWRtaW4="
    },
    "type": "Opaque"
  }
}
```

---

#### Verification Questions (Exercise 2)

1. What security risks are introduced by logging sensitive resources (such as `secrets`) at the `RequestResponse` audit level?
2. If an audit event specifies `"stage": "ResponseComplete"`, what does this imply regarding whether the operation succeeded or failed in `etcd`?

---

### Exercise 3: Debugging API Server Authentication & Authorization Pipelines

#### Scenario
A workload ServiceAccount in namespace `production` fails to read ConfigMaps. You must trace the Authorization stage using `kubectl auth can-i` and inspect client certificate identity attributes.

#### Step 3.1: Create Test ServiceAccount and RBAC Artifacts
Deploy a restricted ServiceAccount, Role, and RoleBinding:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-scanner
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: ServiceAccount
  name: app-scanner
  namespace: default
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

#### Step 3.2: Execute Authorization Pre-flight Checks (`kubectl auth can-i`)
Evaluate permissions from the perspective of the `app-scanner` ServiceAccount:

```bash
# Test 1: Check pod reading capability
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=default
```
**Expected Output:** `yes`

```bash
# Test 2: Check secrets reading capability
kubectl auth can-i get secrets \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=default
```
**Expected Output:** `no`

```bash
# Test 3: Check pod reading in another namespace
kubectl auth can-i list pods \
  --as=system:serviceaccount:default:app-scanner \
  --namespace=kube-system
```
**Expected Output:** `no`

#### Step 3.3: Inspect X.509 Certificate Subject Attributes
Extract and inspect the admin client certificate used to authenticate against the API Server:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout | grep -E "(Subject:|Issuer:)"
```

**Expected Output:**
```text
        Issuer: CN = kubernetes
        Subject: O = system:masters, CN = kube-apiserver-kubelet-client
```

---

#### Verification Questions (Exercise 3)

1. How does `kube-apiserver` map X.509 certificate attributes (`Subject: O = ..., CN = ...`) to the Kubernetes authentication context?
2. If `--authorization-mode=Node,RBAC` is configured on `kube-apiserver`, what happens if a request is authorized by the `Node` authorizer but rejected by `RBAC`?

---

### Exercise 4: Dynamic Admission Control Hardening with Validating Webhooks

#### Scenario
You must configure a `ValidatingWebhookConfiguration` to enforce container security standards across the cluster. If the external admission webhook service is unreachable, the API Server must fail closed (`FailurePolicy: Fail`) to prevent unvalidated workload deployments.

#### Step 4.1: Deploy an Admission Webhook Configuration Manifest
Apply the following complete manifest defining a `ValidatingWebhookConfiguration`:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: strict-sec-validation
webhooks:
  - name: validate.security.internal.domain
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: sec-webhook-svc
        namespace: security-system
        path: "/validate-pods"
        port: 443
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVT0daMVlXUnZaRzFzWVhSMFlTNWhjR2x6WlhKMGFXOXVNVDR3REFZRFZRUUQKRXdZd01EQWVGdzB5TkRBek1URXhNREExTVRCYUZ3MHpOREF6TVRBeE1EQTFNVEJhTUJNeExEQUJCZ05WQkFNTQpFN3d3TURDQ0FTSXdEUVlKS29aSXZjTkFRRUJCUUFEZ2dFUEFEQ0NBUW9DZ2dFQkFNNW9xM2g5SnE3UQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    failurePolicy: Fail
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "security-system"]
EOF
```

#### Step 4.2: Verify Admission Blocking Behavior
Attempt to create a pod in the `default` namespace while the underlying webhook backend service `sec-webhook-svc` is intentionally offline:

```bash
kubectl run test-pod --image=nginx:alpine -n default
```

**Expected Output:**
```text
Error from server (InternalError): Internal error occurred: failed calling webhook "validate.security.internal.domain": failed to call webhook: Post "https://sec-webhook-svc.security-system.svc:443/validate-pods?timeout=5s": service "sec-webhook-svc" not found
```

#### Step 4.3: Clean up Webhook to Restore Cluster Operation

```bash
kubectl delete validatingwebhookconfiguration strict-sec-validation
```

---

#### Verification Questions (Exercise 4)

1. What is the operational difference between `failurePolicy: Fail` and `failurePolicy: Ignore` in a `ValidatingWebhookConfiguration`?
2. Why is it a critical security best practice to exclude `kube-system` via `namespaceSelector` when configuring strict validating admission webhooks?

---

## 3. Official Reference Links

- [Kubernetes API Server CLI Options](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Kubernetes Audit Logging Reference](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes Authenticators Documentation](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Dynamic Admission Control Mechanics](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

<details>
<summary><strong>Answers & Comprehensive Technical Explanations</strong></summary>

### Exercise 1 Answers

1. **Vulnerability Mechanics:**  
   When `--anonymous-auth=true` is enabled, unauthenticated HTTP requests are not rejected at the AuthN stage. Instead, they are assigned the identity `system:anonymous` and placed into the `system:unauthenticated` group. If an administrator creates a `ClusterRoleBinding` granting privileges (e.g., `get, list pods` or wildcard `*`) to `system:unauthenticated` or `system:authenticated`, any unauthenticated network attacker with access to port 6443 can execute API calls and compromise the control plane or cluster data.

2. **TLS 1.3 Protocol Mechanics:**  
   In TLS 1.3 (RFC 8446), cipher suite negotiation was decoupled from certificate key exchange mechanisms. Unlike TLS 1.2, cipher suites in TLS 1.3 only define symmetric encryption algorithms (e.g., `TLS_AES_256_GCM_SHA384` or `TLS_CHACHA20_POLY1305_SHA256`). Standard Go `crypto/tls` libraries (which power Go-based control planes like `kube-apiserver`) handle TLS 1.3 cipher suites automatically. The `--tls-cipher-suites` flag in `kube-apiserver` strictly controls TLS 1.2 cipher algorithms.

---

### Exercise 2 Answers

1. **Security Risks of `RequestResponse` Logging for Secrets:**  
   Configuring `level: RequestResponse` for `secrets` forces the API Server to capture the full raw request payload and the API response body in audit log files stored on host disk. In Kubernetes, Secret data values are base64-encoded strings (not encrypted at rest inside standard API payloads). Audit log files stored in plain text on the control plane node host file system (`/var/log/kubernetes/audit.log`) expose plain text credentials, API tokens, and private keys to any host process or operator with read access to that log directory. The recommended compliance pattern is `level: Metadata` for sensitive resources like Secrets.

2. **Stage Execution Mechanics:**  
   An audit log event bearing `"stage": "ResponseComplete"` indicates that the API request completed its full processing pipeline—including validation, schema transformation, and successful commit to `etcd` (for mutating requests)—and that the API Server generated and completed writing the HTTP response back to the client connection. The `responseStatus.code` field (e.g., `200`, `201`, `403`, `500`) within that `ResponseComplete` event provides definitive proof of outcome.

---

### Exercise 3 Answers

1. **X.509 Attribute Mapping Mechanics:**  
   When `kube-apiserver` processes a client certificate validated against `--client-ca-file`, its `x509` authentication module parses the certificate's distinguished name (DN):
   - The **Common Name (`CN`)** is extracted as the authenticated **User** (`req.User = CN`).
   - All **Organization (`O`)** fields are extracted as the user's **Groups** (`req.Groups = [O_1, O_2, ...]`).  
   In the exercise example (`O = system:masters, CN = kube-apiserver-kubelet-client`), the API Server interprets the client identity as user `kube-apiserver-kubelet-client` belonging to group `system:masters`. Because `system:masters` is hardcoded in Kubernetes source code to bypass RBAC evaluation, this identity receives unrestricted administrative access.

2. **Authorization Engine Evaluation Flow:**  
   `kube-apiserver` evaluates authorization modes sequentially as configured in `--authorization-mode` (e.g., `Node,RBAC`).
   - If **any** authorizer explicitly grants access (`DecisionAllow`), evaluation halts immediately, and the request proceeds to Admission Control.
   - If an authorizer does not match or declines (`DecisionNoOpinion`), the API Server passes the request to the next authorizer in line.
   - If all authorizers finish without granting permission, the request is denied (`403 Forbidden`).  
   Therefore, if `Node` authorizes the request, it is approved immediately—the subsequent rejection or lack of permission in `RBAC` is never evaluated.

---

### Exercise 4 Answers

1. **FailurePolicy Operational Differences:**  
   - **`failurePolicy: Fail` (Fail Closed):** If the external admission webhook service encounters a network timeout, DNS failure, 5xx internal server error, or unreachable endpoint, the API Server aborts the operation and rejects the API request. This guarantees strict security enforcement at the expense of potential cluster operational availability if the webhook backend goes down.
   - **`failurePolicy: Ignore` (Fail Open):** If the admission webhook service is unreachable or errors out, the API Server bypasses validation and permits the request to proceed to `etcd`. This prioritizes workload availability over security policy enforcement.

2. **Excluding System Namespaces Best Practice:**  
   If a validating webhook configured with `failurePolicy: Fail` intercepts requests across all namespaces (including `kube-system`), any failure of the webhook service creates a circular dependency dead-lock:
   - Control plane components or core system pods (such as DNS plugins, CNI drivers, or the webhook pod itself if restarting) cannot be created or updated because the webhook validation fails closed.
   - Operators cannot deploy a fix or restart the system pods because the API Server rejects all new Pod creation requests.  
   Excluding infrastructure namespaces (such as `kube-system`) via `namespaceSelector` ensures core system components remain manageable during an emergency outage.

</details>