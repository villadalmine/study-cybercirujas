# KCSA Study Material: Domain 2.1 — API Server Hardening & Security Architecture

## 1. Production Motivation & Architectural Problem

The `kube-apiserver` is the central nexus of the Kubernetes control plane. It is the sole component that directly communicates with `etcd`, serving as the stateless gateway for all operational, management, and programmatic interactions within the cluster. Every `kubectl` command, internal controller loop, dynamic admission request, and Kubelet node status update must route through and be evaluated by the API server.

```
                     +-----------------------------------------------------------------------+
                     |                          kube-apiserver                               |
                     |                                                                       |
  +---------------+  |  +------------------+  +-----------------+  +-------------------+  |   +----------+
  |  Client       |---> |  1. Authentication--> 2. Authorization--> 3. Admission Control---> | etcd     |
  | (kubectl/SDK) |  |  +------------------+  +-----------------+  +-------------------+  |   | Storage  |
  +---------------+  +-----------------------------------------------------------------------+   +----------+
```

### Production Failure Modes & Vulnerability Vectors in Default Configurations

1. **Unauthenticated / Anonymous Access Risks:**
   In non-hardened clusters, `--anonymous-auth=true` (the historical default) permits unauthenticated clients to reach the API server pipeline. If RBAC permissions inadvertently bind roles to `system:unauthenticated` or `system:authenticated`, malicious actors can enumerate API groups, discover cluster topology, or read sensitive metadata via endpoints such as `/metrics` or `/api/v1`.

2. **Plaintext Secret Exposure in Storage (`etcd`):**
   By default, `kube-apiserver` writes resource state (including `v1/Secret` objects) into `etcd` in unencrypted, raw JSON/protobuf formats. An attacker who gains read access to the underlying `etcd` host disk, volume snapshots, or `etcd` client certificates can retrieve raw TLS private keys, service account tokens, and database passwords without interacting with the API authorization layer.

3. **Service Account Token Exfiltration & Privilege Escalation:**
   Legacy Kubernetes deployments automatically mount long-lived Secret-based service account tokens into every pod container filesystem at `/var/run/secrets/kubernetes.io/serviceaccount/token`. If an application pod is compromised via remote code execution (RCE), an attacker can extract this static token and invoke the API server. If RBAC bindings are overly permissive (e.g., granting cluster-admin or wildcard `verbs: ["*"]`), the attacker achieves full cluster compromise.

4. **Dynamic Admission Webhook Deadlocks & Denial of Service (DoS):**
   Dynamic admission controllers (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`) extend API server evaluation logic by invoking external HTTPS endpoints. A poorly configured webhook with `failurePolicy: Fail`, high `timeoutSeconds`, and missing `namespaceSelector` exclusions can block critical system namespaces (`kube-system`). If the external webhook pod crashes or experiences network latency, `kube-apiserver` rejects or hangs on all resource creations—including the pods needed to recover the webhook service itself.

5. **Resource Starvation via Unthrottled API Requests:**
   Without API Priority and Fairness (APF) enabled and configured, flood traffic (such as rogue controller loops, excessive status updates, or brute-force external scans) can exhaust API server memory and worker threads (goroutines), causing control plane unresponsiveness (`HTTP 503 / 429`) for critical system controllers.

---

## 2. Technical Architectural Comparisons & Trade-offs

### 2.1 Authentication Strategies Matrix

| Strategy | Mechanical Architecture | Security Posture | Operational Overhead | Production Trade-off |
| :--- | :--- | :--- | :--- | :--- |
| **X.509 Client Certificates** | Client proves identity via mTLS; Common Name (CN) maps to User, Organization (O) to Groups. | **High** (Cryptographically signed, non-forgeable). | **High** (No native revocation standard like CRL/OCSP inside API server; requires CA rotation). | Excellent for static control plane components (Kubelet, Scheduler); poor for user identity management due to revocation constraints. |
| **OpenID Connect (OIDC)** | Bearer JWT signed by external IdP (Okta, Keycloak); API server verifies signature using public JWKS. | **Very High** (Short-lived tokens, centralized identity & MFA enforcement). | **Medium** (Requires IdP integration and external flag configuration). | Recommended standard for human users. Token lifetime controlled by IdP; no local token storage inside the cluster. |
| **Webhook Token Authentication** | API server POSTs `TokenReview` JSON object to an external HTTPS endpoint to validate bearer tokens. | **High** (Dynamic remote validation). | **High** (Network overhead per uncached authentication request; dependency on webhook availability). | Ideal for custom authentication bridges, legacy enterprise integrations, or cloud provider identity layers. |
| **Service Account Bound Tokens (Bound Tokens API)** | Projected volumes generate short-lived JWTs bound to pod identity, time, and specific audience. | **Very High** (Audience-bound, auto-rotating, invalidated on pod deletion). | **Low** (Handled natively by API server and Kubelet via `TokenRequest` API). | Replaces legacy static Secret tokens. Prevents cross-cluster token replay attacks via audience restriction. |

### 2.2 Authorization Engines Matrix

```
                      Authorization Pipeline Request Evaluation
                                          │
                                          ▼
                                ┌───────────────────┐
                                │   NodeAuthorizer  │ ──(Pass/Next)──►
                                └───────────────────┘
                                          │ (Allow)
                                          ▼
                                ┌───────────────────┐
                                │        RBAC       │ ──(Pass/Next)──►
                                └───────────────────┘
                                          │ (Allow)
                                          ▼
                                ┌───────────────────┐
                                │  Webhook (OPA/etc)│ ──(Pass/Deny)──► Result
                                └───────────────────┘
```

| Engine | Mechanics | Flexibility | Performance Impact | Best Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Node Authorizer** | Special-purpose authorizer enforcing that Kubelets can only read/write resources related to their specific node. | Static scope based on node identity. | Negligible (~microseconds). | Mandatory for securing Kubelet-to-APIServer boundaries (`--authorization-mode=Node,RBAC`). |
| **RBAC (Role-Based Access Control)** | Evaluates declarative `Roles`, `ClusterRoles`, `RoleBindings`, and `ClusterRoleBindings`. | Moderate (Granular to API groups, resources, verbs, names). | Low (In-memory evaluation cache). | Default standard for intra-cluster service accounts, workloads, and user access. |
| **ABAC (Attribute-Based Access Control)** | Evaluates rules defined in a static JSON policy file on the API server host. | Low (Requires API server restart to change policies). | Low. | Deprecated in production. High operational friction and security risk due to static maintenance. |
| **Webhook (e.g., OPA / Gatekeeper)** | API server sends `SubjectAccessReview` JSON payload to remote authorization engine. | Extremely High (Context-aware logic, IP range filtering, time-based access). | Medium (Network round-trip latency added to authorization phase). | Advanced enterprise compliance requirements where standard RBAC cannot evaluate external context. |

---

## 3. Production Manifests and Configuration Architecture

### Manifest 1: Hardened `kube-apiserver.yaml` Static Pod Manifest
Location: `/etc/kubernetes/manifests/kube-apiserver.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 192.168.1.10:6443
  creationTimestamp: null
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.1.10
    - --allow-privileged=false
    - --anonymous-auth=false
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction,PodSecurity,ServiceAccount
    - --enable-bootstrap-token-auth=true
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --encryption-provider-config=/etc/kubernetes/security/encryption-config.yaml
    - --audit-policy-file=/etc/kubernetes/security/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --secure-port=6443
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256
    - --tls-min-version=VersionTLS12
    image: registry.k8s.io/kube-apiserver:v1.30.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 192.168.1.10
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-apiserver
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 192.168.1.10
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/security
      name: k8s-security
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: k8s-audit-logs
      readOnly: false
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/ssl/certs
      type: DirectoryOrCreate
    name: ca-certs
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: /etc/kubernetes/security
      type: DirectoryOrCreate
    name: k8s-security
  - hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
    name: k8s-audit-logs
```

---

### Manifest 2: Enterprise `EncryptionConfiguration` (AES-CBC Data Encryption at Rest)
Location on host: `/etc/kubernetes/security/encryption-config.yaml`

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIGEgc2VjcmV0IGlzIGEgc2VjcmV0IQ==
      - identity: {}
```

> **Security Note:** The `identity: {}` provider must be placed second during key rotation cycles so that unencrypted data can still be read while new writes are encrypted with `key1` (`aescbc`).

---

### Manifest 3: High-Fidelity Security `AuditPolicy` Configuration
Location on host: `/etc/kubernetes/security/audit-policy.yaml`

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Do not log system status checks or health probes
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/livez*"
      - "/readyz*"

  # 2. Log Secret and ConfigMap changes at Metadata level to protect payload confidentiality while auditing access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # 3. Log RBAC policy alterations at RequestResponse level (critical for auditing privilege escalations)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 4. Log pod executive access and port forwarding attempts at RequestResponse level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/portforward", "pods/attach"]

  # 5. Default catch-all for all other namespace-scoped operational modifications
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    executionData: true
```

---

### Manifest 4: Production-Grade `ValidatingWebhookConfiguration`
Location: `/tmp/validating-webhook.yaml`

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: security-policy-validation
spec:
  webhooks:
    - name: pod-security-enforcer.security.domain.internal
      rules:
        - apiGroups: [""]
          apiVersions: ["v1"]
          operations: ["CREATE", "UPDATE"]
          resources: ["pods"]
          scope: "Namespaced"
      clientConfig:
        service:
          name: webhook-validator-svc
          namespace: security-system
          path: "/validate-pods"
          port: 443
        caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
      admissionReviewVersions: ["v1"]
      sideEffects: None
      timeoutSeconds: 3
      failurePolicy: Fail
      namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: ["kube-system", "security-system"]
```

---

## 4. CLI Execution Commands & Production Terminal Outputs

### Step 4.1: Inspecting API Server Client Certificate Details and SANs

```bash
$ openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 3 "Subject Alternative Name"
```
**Expected Output:**
```text
            X509v3 Subject Alternative Name: 
                DNS:k8s-control-01, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.10
    Signature Algorithm: sha256WithRSAEncryption
```

---

### Step 4.2: Verifying Hardened Anonymous Authentication Removal (`--anonymous-auth=false`)

```bash
$ curl -k -s -i https://127.0.0.1:6443/api/v1/namespaces
```
**Expected Output:**
```http
HTTP/2 401 
audit-id: 2d86a45b-76b1-4f76-8094-81fd001ec862
content-type: application/json
x-content-type-options: nosniff
content-length: 165
date: Fri, 07 Aug 2026 23:35:10 GMT

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

---

### Step 4.3: Validating etcd Encryption at Rest via Direct Key Retrieval

First, create a test secret in the `default` namespace:

```bash
$ kubectl create secret generic production-db-credentials --from-literal=password='SuperSecretPass2026!' -n default
```
**Expected Output:**
```text
secret/production-db-credentials created
```

Now, directly inspect `etcd` storage using `etcdctl` to verify the payload is stored as encrypted ciphertext:

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
  --endpoints=https://127.0.0.1:2379 \
  get /registry/secrets/default/production-db-credentials
```
**Expected Output:**
```text
/registry/secrets/default/production-db-credentials
k8s:enc:aescbc:v1:key1:[>!{`	|.+Z/~"=#!g!|,~1
	.G,%`
```
*(Notice the prefix `k8s:enc:aescbc:v1:key1:` confirming successful encryption via the `aescbc` provider).*

---

### Step 4.4: Querying API Server Control Plane Health Endpoints

```bash
$ kubectl get --raw "/healthz?verbose"
```
**Expected Output:**
```text
[ping] connection succeeded
[log] response ok
[etcd] response ok
[poststarthook/start-kube-apiserver-admission-initializer] response ok
[poststarthook/generic-apiserver-start-informers] response ok
[poststarthook/priority-and-fairness-config-consumer] response ok
[poststarthook/bootstrap-controller] response ok
[poststarthook/start-cluster-authentication-info-controller] response ok
[poststarthook/start-kube-apiserver-identity-lease-controller] response ok
[poststarthook/start-kube-apiserver-identity-lease-garbage-collector] response ok
healthz check passed
```

---

### Step 4.5: Inspecting API Priority and Fairness (APF) Throttling Configurations

```bash
$ kubectl get flowschemas.flowcontrol.apiserver.k8s.io
```
**Expected Output:**
```text
NAME                    TIME-WINDOW   MATCHING-PRECEDENCE   DISTINGUISHER-METHOD   AGE
exempt                  0s            0                     <none>                 42d
probes                  0s            100                   <none>                 42d
system-leader-election  0s            200                   ByUser                 42d
workload-leader-election 0s           300                   ByUser                 42d
system-nodes            0s            400                   ByUser                 42d
kube-controller-manager 0s            800                   ByUser                 42d
kube-scheduler          0s            900                   ByUser                 42d
service-accounts        0s            9000                  ByNamespace            42d
global-default          0s            9900                  ByUser                 42d
catch-all               0s            10000                 ByUser                 42d
```

---

## 5. Verification & Troubleshooting Runbook

```
                         API Server Failure Troubleshooting Flow
                                           │
                                           ▼
                            Is kube-apiserver pod running?
                                   │              │
                           (No)    │              │ (Yes)
              ┌────────────────────┘              └────────────────────┐
              ▼                                                        ▼
   Check Static Pod Manifest                     Check API Server Logs & Status
   - Location: /etc/kubernetes/manifests/        - kubectl get --raw /readyz
   - View Container Logs:                        - Check Audit Logs: /var/log/kubernetes/
     crictl logs <container-id>                    audit.log
              │                                                        │
              ▼                                                        ▼
   Common Causes:                                 Common Causes:
   1. Syntax error in EncryptionConfig/           1. Admission Webhook Timeout (HTTP 500)
      AuditPolicy YAML file                       2. APF Flow Schema Throttling (HTTP 429)
   2. Certificate Expiry / Path mismatch          3. etcd Connectivity/Disk Latency
   3. Unsupported flag values
```

### Scenario 1: `kube-apiserver` CrashLoopBackOff After Configuring Encryption or Audit Policies

#### Root Cause Analysis
If an underlying file referenced by command-line flags (e.g., `--encryption-provider-config` or `--audit-policy-file`) contains invalid YAML syntax, missing keys, or unreachable mount paths within the static pod definition, `kube-apiserver` will fail runtime initialization and instantly terminate.

#### Diagnostic Workflow & Resolution Steps

1. Check static pod status on the control plane node via `crictl`:

```bash
$ crictl ps -a --name kube-apiserver
```
**Expected Output:**
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPTS            POD ID
c1a2b3c4d5e6        a89f412c2a0b        20 seconds ago      Exited              kube-apiserver      3                   f9e8d7c6b5a4
```

2. Extract trailing error logs from the exited container:

```bash
$ crictl logs c1a2b3c4d5e6
```
**Expected Diagnostic Log Snippet:**
```text
F0807 23:42:15.123456       1 server.go:302] error starting api server: error opening encryption provider configuration file "/etc/kubernetes/security/encryption-config.yaml": error loading configuration file: yaml: unmarshal errors: line 7: field keyss not found in type apiserver.Configuration
```

3. **Remediation:** Correct the syntax error (`keyss` -> `keys`) in `/etc/kubernetes/security/encryption-config.yaml`. The Kubelet monitors `/etc/kubernetes/manifests` and `/etc/kubernetes/security`, and will automatically restart the static pod once saved.

---

### Scenario 2: Dynamic Admission Webhook Lockout (API Request Deadlock)

#### Root Cause Analysis
A `ValidatingWebhookConfiguration` configured with `failurePolicy: Fail` points to a webhook endpoint that is unroutable, crashing, or timing out. Any incoming API creation request matching the rule hangs until `timeoutSeconds` expires, then fails with `HTTP 500 / Internal Server Error`.

#### Diagnostic Workflow & Resolution Steps

1. Test resource creation and observe the exact API server rejection error:

```bash
$ kubectl run test-pod --image=nginx:alpine -n default
```
**Expected Output:**
```text
Error from server (InternalError): Internal error occurred: failed calling webhook "pod-security-enforcer.security.domain.internal": failed to call webhook: Post "https://webhook-validator-svc.security-system.svc:443/validate-pods?timeout=3s": context deadline exceeded
```

2. Temporary Emergency Remediation:
Bypass or delete the blocking webhook configuration by directly interacting with the API server (or using administrative credentials):

```bash
$ kubectl delete validatingwebhookconfiguration security-policy-validation --ignore-not-found
```
**Expected Output:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io "security-policy-validation" deleted
```

3. **Architectural Prevention:**
Always ensure critical system namespaces are exempted using `namespaceSelector`:

```yaml
namespaceSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: ["kube-system", "security-system"]
```

---

### Scenario 3: Investigating Rate Limiting and API Priority & Fairness Throttling (`HTTP 429`)

#### Root Cause Analysis
Client requests exceeding the concurrency limits set by `PriorityLevelConfiguration` and `FlowSchema` are queued. Once queue depth is exhausted, the API server rejects incoming traffic with `HTTP 429 Too Many Requests`.

#### Diagnostic Workflow & Resolution Steps

1. Inspect API server metrics for APF drops using `curl` with client certificate auth:

```bash
$ kubectl get --raw "/metrics" | grep "apiserver_flowcontrol_rejected_requests_total"
```
**Expected Diagnostic Output:**
```text
# HELP apiserver_flowcontrol_rejected_requests_total [ALPHA] Number of requests rejected by API Priority and Fairness system
# TYPE apiserver_flowcontrol_rejected_requests_total counter
apiserver_flowcontrol_rejected_requests_total{flow_schema="service-accounts",priority_level="workload-high",reason="queue-full"} 142
```

2. Identify the saturated priority level and check its current concurrency limits:

```bash
$ kubectl get prioritylevelconfiguration workload-high -o yaml
```

3. **Remediation:** Adjust `handseat` concurrency configuration or increase `queueLengthLimit` in the target `PriorityLevelConfiguration` object to accommodate bursty microservice traffic patterns.

---

## 6. References

- **CNCF KCSA Curriculum Specification:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Official Documentation — Controlling API Access:**  
  https://kubernetes.io/docs/concepts/security/controlling-access/
- **Kubernetes Official Documentation — Encrypting Confidential Data at Rest:**  
  https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- **Kubernetes Official Documentation — Auditing Architecture & Policies:**  
  https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- **Kubernetes Official Documentation — Dynamic Admission Control Webhooks:**  
  https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Kubernetes Official Documentation — API Priority and Fairness:**  
  https://kubernetes.io/docs/concepts/cluster-administration/flow-control/