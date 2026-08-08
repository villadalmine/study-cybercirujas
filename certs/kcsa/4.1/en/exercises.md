# KCSA Study Guide: Topic 4.1 - Kubernetes Trust Boundaries and Data Flow

**Exam Weight**: 2.29%  
**Domain**: Cluster Architecture, Hardening, and Threat Modeling  
**Target Certification**: CNCF Kubernetes and Cloud Native Security Associate (KCSA)

---

## 1. Deep Technical Architecture & Mechanics

Understanding Kubernetes trust boundaries requires decomposing the cluster into distinct security zones, identifying data transition vectors across those zones, and analyzing the underlying cryptographic and Linux primitives enforcing isolation.

```
                   +-------------------------------------------------------+
                   |                 CONTROL PLANE ZONE                    |
                   |                                                       |
 [ kubectl / API ] ---> [ kube-apiserver ] <===( mTLS )===> [ etcd ]       |
     (Client)      |           |                                           |
                   +-----------|-------------------------------------------+
                               | (mTLS / Port 10250)
                               v
                   +-------------------------------------------------------+
                   |                 NODE / DATA PLANE ZONE                |
                   |                                                       |
                   |       [ Kubelet ] <===( gRPC / UNIX Domain Socket )   |
                   |            |                                          |
                   |            v                                          |
                   |     [ Container Runtime (containerd/CRI-O) ]          |
                   |            |                                          |
                   |            v (runc / Linux Namespaces & Cgroups)      |
                   |    +-------------------------------+                  |
                   |    | Pod A (Namespace X)           |                  |
                   |    |  - veth0                      |                  |
                   |    +-------------------------------+                  |
                   |            |                                          |
                   |            | (CNI Network Layer / eBPF / iptables)    |
                   |            v                                          |
                   |    +-------------------------------+                  |
                   |    | Pod B (Namespace Y)           |                  |
                   |    +-------------------------------+                  |
                   +-------------------------------------------------------+
```

### 1.1 Kubernetes Trust Boundaries

#### 1. Control Plane vs. Node (Data Plane) Boundary
*   **The Invariant**: Nodes are fundamentally untrusted or less trusted than the Control Plane. A compromised worker node must never grant an attacker lateral movement to compromise the entire cluster control plane or access control plane credentials.
*   **Mechanics**:
    *   **Kubelet Identification**: Kubelets authenticate to `kube-apiserver` using X.509 client certificates with `O=system:nodes` and `CN=system:node:<node-name>`.
    *   **NodeRestriction Admission Controller**: Enforces that a Kubelet can only modify its own `Node` object, read `Secret` and `ConfigMap` objects bound to Pods scheduled on its specific node, and modify its own `PodStatus` and `PV/PVC` bindings.
    *   **Kubelet API (Port 10250)**: The `kube-apiserver` communicates downstream to Kubelet for `exec`, `logs`, and `port-forward` operations. Kubelet must require Webhook Authentication and RBAC Authorization to prevent unauthenticated arbitrary command execution on the host.

#### 2. Pod-to-Pod (East-West Network) Boundary
*   **The Invariant**: By default, the Kubernetes flat network model allows any Pod to send IP packets to any other Pod across any namespace without isolation.
*   **Mechanics**:
    *   **Network Namespaces**: Each Pod is instantiated with its own Linux Network Namespace (`netns`), connected to the host via a virtual ethernet pair (`veth`).
    *   **CNI Enforcement**: Container Network Interfaces (e.g., Calico, Cilium) enforce boundary security by translating Kubernetes `NetworkPolicy` custom resources into kernel packet-filtering primitives (`iptables` rules, `IPVS`, or `eBPF` BPF programs attached to `tc` or `cgroup` hooks).
    *   **mTLS Layer**: NetworkPolicies operate up to Layer 4 (TCP/UDP). Layer 7 identity verification and payload confidentiality require an application-level proxy (Service Mesh / SPIFFE/SPIRE) executing mutual TLS handshakes.

#### 3. API Server to Storage (`etcd`) Boundary
*   **The Invariant**: `etcd` is the single source of truth for the entire cluster state, storing plain-text representations of all resources including `Secret` objects. Access to `etcd` equates to full cluster root access.
*   **Mechanics**:
    *   **Network Isolation**: `etcd` should accept connections *only* from `kube-apiserver` over dedicated mTLS interfaces (typically port 2379).
    *   **Data at Rest Encryption**: By default, `kube-apiserver` writes raw JSON/protobuf representations of API objects to `etcd`. `EncryptionConfiguration` allows configuring envelope encryption using provider plugins (e.g., KMS v2 over gRPC) or static key providers (AES-GCM, Secretbox) so that raw disk reads of `etcd` WAL files yield ciphertext.

#### 4. Container Workload Boundary (Linux Kernel Isolation)
*   **The Invariant**: A container is merely a constrained Linux process sharing the host kernel.
*   **Mechanics**:
    *   **Namespaces**: `pid`, `net`, `ipc`, `mnt`, `uts`, `user`, `cgroup`.
    *   **Control Groups (cgroups v2)**: Resource starvation protection (CPU, Memory, I/O, pids).
    *   **Capabilities & Seccomp**: Dropping Linux capabilities (`CAP_SYS_ADMIN`, `CAP_NET_RAW`) restricts root within the container, while Syscall Filtering (`seccomp`) limits accessible kernel syscalls (e.g., blocking `unshare`, `clone` flags).

---

### 1.2 Data Flow Vectors & Authentication Lifecycle

```
[ Pod Container ] 
       |
       | 1. Reads Projected Token File
       v (/var/run/secrets/kubernetes.io/serviceaccount/token)
 [ OIDC JWT Token ] -- 2. Bearer Auth --> [ kube-apiserver ]
                                               |
                                               +--> 3. AuthN Validation (RS256 Signature against SA Public Key)
                                               +--> 4. AuthZ Check (RBAC: SubjectAccessReview)
                                               +--> 5. Admission Control (Validating / Mutating / CEL)
                                               +--> 6. Encryption Envelope (AES-GCM)
                                               v
                                            [ etcd ]
```

#### Bound Service Account Tokens (Projected ServiceAccount Tokens)
*   **Legacy Behavior (Vulnerable)**: Pre-v1.21 ServiceAccount tokens were static, non-expiring JWTs stored directly inside Secret objects and mounted blindly into Pods. If leaked, they provided indefinite API access from anywhere.
*   **Modern Bound Token Mechanics (`TokenRequest` API)**:
    *   Tokens are dynamic, time-bound (e.g., 3600s), and cryptographic signatures are verified using RS256 via the API server's OIDC discovery endpoint (`/.well-known/openid-configuration`).
    *   **Audience Binding (`aud`)**: The token contains claims restricting valid recipients (e.g., `https://kubernetes.default.svc`). API servers enforce that target services match the presented token audience.
    *   **Object Binding (`sub` / `pod` claims)**: Tokens are bound to the specific Pod instance lifetime (`uid`). If the Pod is terminated, the token is invalidated immediately by `kube-apiserver`.

---

## 2. Production Manifests & Configuration Reference

### 2.1 API Server Encryption Configuration (`EncryptionConfiguration`)

This manifest configures `kube-apiserver` to encrypt `Secret` objects at rest using `aescbc` (or `aesgcm`) before writing to `etcd`.

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
              # Base64 encoded 32-byte (256-bit) random key
              secret: c2VjcmV0IGlzIGEgc2VjcmV0IGlzIGEgc2VjcmV0IGlzIGE=
      - identity: {} # Fallback mechanism allowing unencrypted reads during rotation
```

---

### 2.2 Microsegmentation Zero-Trust NetworkPolicy

This manifest establishes a strict default-deny network boundary for both ingress and egress in namespace `production`, then explicitly authorizes minimal required data flows.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-payment-service-flow
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: payment-service
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: api-gateway
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: production
    ports:
    - protocol: TCP
      port: 8443
  egress:
  # Allow CoreDNS access for service discovery
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  # Allow egress to PostgreSQL database pods only
  - to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: postgresql
    ports:
    - protocol: TCP
      port: 5432
```

---

### 2.3 Hardened Workload Manifest (Security Context & Bound Tokens)

This manifest enforces strict Pod Security Standards (`Restricted` level), drops all kernel capabilities, mounts a read-only root filesystem, and uses projected time-bound ServiceAccount tokens.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-workload
  namespace: production
  labels:
    app: secure-workload
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-workload
  template:
    metadata:
      labels:
        app: secure-workload
    spec:
      serviceAccountName: secure-sa
      automountServiceAccountToken: false # Disable default static token mounting
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: registry.k8s.io/pause:3.9
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        volumeMounts:
        - name: bound-sa-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
      volumes:
      - name: bound-sa-token
        projected:
          sources:
          - serviceAccountToken:
              audience: https://kubernetes.default.svc
              expirationSeconds: 3600
              path: token
```

---

## 3. Hands-On Guided Exercises

### Exercise 1: Auditing Control Plane to Node Boundaries & Kubelet Isolation

#### Goal
Inspect and verify Kubelet authentication/authorization settings and test NodeRestriction boundary enforcement against API tampering.

#### Step 1.1: Verify Kubelet Authentication and Authorization Configuration
Run a command on the control plane node to inspect how `kubelet` is configured to authenticate incoming requests on port 10250.

```bash
$ ps aux | grep kubelet | grep -E '--anonymous-auth|--authorization-mode'
```

*Expected Output:*
```text
root      2104  1.2  2.4 1948212 98304 ?       Ssl  18:10   0:15 /usr/bin/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubeconfig.conf --kubeconfig=/etc/kubernetes/kubelet.conf --config=/var/lib/kubelet/config.yaml --anonymous-auth=false --authorization-mode=Webhook
```

#### Step 1.2: Verify NodeRestriction Admission Controller is Enabled
Check `kube-apiserver` flag parameters to ensure `NodeRestriction` is active.

```bash
$ kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' | jq . | grep NodeRestriction
```

*Expected Output:*
```text
  "- --enable-admission-plugins=NodeRestriction,MutatingAdmissionWebhook,ValidatingAdmissionWebhook",
```

#### Step 1.3: Simulate Unauthorized Cross-Node Mutation
Extract the credentials of worker node `worker-1` from `/etc/kubernetes/kubelet.conf` on that node, and attempt to edit labels on another node (`worker-2`).

```bash
$ kubectl --kubeconfig=/etc/kubernetes/kubelet.conf label node worker-2 security-tier=compromised
```

*Expected Output:*
```text
Error from server (Forbidden): nodes "worker-2" is forbidden: node "worker-1" is not allowed to modify node "worker-2"
```

---

#### Verification Questions - Exercise 1

1. If `--anonymous-auth=true` were set on Kubelet without RBAC authorization enabled on port 10250, what exact vulnerability vector opens up for an attacker inside the pod network?
2. Why does the `NodeRestriction` admission plugin allow Kubelet `system:node:worker-1` to modify `spec.unschedulable` on `worker-1`, but denies modifying `metadata.labels` on `worker-2`?

---

### Exercise 2: Implementing API Server Encryption at Rest & ServiceAccount Token Projection

#### Goal
Verify API server secret encryption mechanics in `etcd`, inspect raw storage byte structures, and analyze projected token JWT claims.

#### Step 2.1: Inspect Unencrypted Storage in `etcd`
Create a test secret in namespace `default` prior to applying encryption.

```bash
$ kubectl create secret generic unencrypted-db-pass --from-literal=password='SuperSecretPass123!'
```

*Expected Output:*
```text
secret/unencrypted-db-pass created
```

Access the `etcd` database directly using `etcdctl` to view the stored data bytes.

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/unencrypted-db-pass
```

*Expected Output:*
```text
/registry/secrets/default/unencrypted-db-pass
k8s

v1Secret
...
unencrypted-db-passdefault"*
passwordSuperSecretPass123!
```
*(Notice cleartext string `SuperSecretPass123!` is readable on raw storage).*

#### Step 2.2: Apply `EncryptionConfiguration` to `kube-apiserver`
Save the manifest from Section 2.1 to `/etc/kubernetes/enc/encryption-config.yaml` on the control plane host. Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` to add:

```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

Mount the file into the `kube-apiserver` pod volumes. Wait for `kube-apiserver` to restart automatically.

#### Step 2.3: Create Encrypted Secret and Verify Encryption Header
Create a new secret after enabling encryption.

```bash
$ kubectl create secret generic encrypted-db-pass --from-literal=password='UltraEncryptedPass456!'
```

Query `etcdctl` for the newly created key:

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/encrypted-db-pass
```

*Expected Output:*
```text
/registry/secrets/default/encrypted-db-pass
k8s:enc:aescbc:v1:key1:%`[`~
                                  ;%,Y#I8....
```
*(Notice the `k8s:enc:aescbc:v1:key1:` prefix indicating active provider envelope encryption).*

#### Step 2.4: Inspect Projected Service Account Token Claims
Deploy the workload manifest from Section 2.3 and extract the JWT token mounted at `/var/run/secrets/tokens/token`.

```bash
$ TOKEN=$(kubectl exec -n production deploy/secure-workload -c app -- cat /var/run/secrets/tokens/token)
$ echo $TOKEN | jq -R 'split(".") | .[1] | @base64d | fromjson'
```

*Expected Output:*
```json
{
  "aud": [
    "https://kubernetes.default.svc"
  ],
  "exp": 1754600000,
  "iat": 1754596400,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "nbf": 1754596400,
  "sub": "system:serviceaccount:production:secure-sa",
  "kubernetes.io": {
    "namespace": "production",
    "pod": {
      "name": "secure-workload-7599c4c7-x2k4p",
      "uid": "a3b8c9d0-1234-5678-90ab-cdef12345678"
    },
    "serviceaccount": {
      "name": "secure-sa",
      "uid": "f9e8d7c6-5432-10fe-dcba-098765432109"
    }
  }
}
```

---

#### Verification Questions - Exercise 2

1. Why does applying an `EncryptionConfiguration` to `kube-apiserver` NOT automatically encrypt secrets that were created *before* the configuration file was added? What command forces their encryption?
2. What is the security advantage of setting `automountServiceAccountToken: false` at the Pod spec level when using projected volume tokens?

---

### Exercise 3: Enforcing East-West Zero-Trust Boundaries via Network Policies

#### Goal
Validate network boundary isolation by implementing Default-Deny policy rules and observing real packet drop behavior.

#### Step 3.1: Deploy Verification Test Pods
Create two namespaces: `alpha` and `beta`. Deploy a web server in `beta` and a curl client in `alpha`.

```bash
$ kubectl create ns alpha
$ kubectl create ns beta
$ kubectl run web --image=nginx -n beta --labels=app=web
$ kubectl expose pod web --port=80 -n beta
$ kubectl run client --image=radial/busyboxplus:curl -n alpha -i --tty -- sh
```

#### Step 3.2: Verify Default Inter-Namespace Connectivity
From the `client` shell in namespace `alpha`, test access to `web.beta.svc.cluster.local`.

```bash
[ client-pod ] # curl --connect-timeout 3 http://web.beta.svc.cluster.local
```

*Expected Output:*
```text
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

#### Step 3.3: Apply Default Deny All Policy in Target Namespace
Apply the `default-deny-all` manifest to namespace `beta`.

```bash
$ kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: beta
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

#### Step 3.4: Re-test Traffic Flow Across the Boundary
Attempt the connection again from the `client` pod in namespace `alpha`.

```bash
[ client-pod ] # curl --connect-timeout 3 http://web.beta.svc.cluster.local
```

*Expected Output:*
```text
curl: (28) Connection timed out after 3001 milliseconds
```

---

#### Verification Questions - Exercise 3

1. If a CNI plugin does NOT support `NetworkPolicy` objects (e.g., standard Flannel in default mode), what happens when you apply a `NetworkPolicy` object to the cluster? How does this impact your security boundaries?
2. You create an ingress `NetworkPolicy` that selects `app: web` and specifies a `from` rule matching `namespaceSelector: { matchLabels: { environment: production } }`. If the namespace `production` does NOT have any labels applied to its `Namespace` object, will traffic be permitted or denied?

---

## 4. Official References & Documentation

*   **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
*   **Kubernetes Threat Model & Boundaries**: [https://kubernetes.io/docs/concepts/security/threat-model/](https://kubernetes.io/docs/concepts/security/threat-model/)
*   **Controlling Access to the API**: [https://kubernetes.io/docs/concepts/security/controlling-access/](https://kubernetes.io/docs/concepts/security/controlling-access/)
*   **NodeRestriction Admission Plugin**: [https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction)
*   **Encrypting Secret Data at Rest**: [https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
*   **ServiceAccount Token Projection**: [https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection)
*   **Kubernetes Network Policies**: [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## 5. Answers & Detailed Explanations

<details>
<summary>Click to view Exercise Solutions and Answer Key</summary>

### Exercise 1 Solutions

1. **Answer**:  
   If `--anonymous-auth=true` and Kubelet authorization mode is `AlwaysAllow` (or missing Webhook mode), port 10250 allows unauthenticated access directly to the Kubelet API. Anyone inside the Pod network (or host network) can make HTTP POST requests to `https://<node-ip>:10250/run/<namespace>/<pod>/<container>` or `https://<node-ip>:10250/exec/...` and instantly execute arbitrary code as `root` inside containers on that node, bypassing `kube-apiserver` authentication and RBAC completely.

2. **Answer**:  
   `NodeRestriction` restricts `system:node:<node-name>` credentials based on the node identity encoded in the client X.509 certificate (`CN=system:node:worker-1`). It enforces an explicit rule: a node can only update its own Node spec/status and Pods running on itself. Allowing `worker-1` to modify `worker-2` would allow a compromised worker node to taint `worker-2`, remove security labels, or redirect workloads scheduled for `worker-2` to itself.

---

### Exercise 2 Solutions

1. **Answer**:  
   The `EncryptionConfiguration` provider only encrypts data during the *write* operation (`Put` API call) to `etcd`. Existing secrets stored prior to updating `kube-apiserver` remain stored in cleartext inside `etcd`.  
   To encrypt all existing secrets, run a command that forces an in-place rewrite of all secret objects:
   ```bash
   $ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   ```

2. **Answer**:  
   Setting `automountServiceAccountToken: false` prevents Kubernetes from mounting the legacy token Secret volume to `/var/run/secrets/kubernetes.io/serviceaccount`. If an attacker gains Remote Code Execution (RCE) in a container that does not actually need API access, no default ambient token will be available in the container filesystem for exfiltration. Using projected volumes explicitly forces strict least-privilege binding only when required.

---

### Exercise 3 Solutions

1. **Answer**:  
   Kubernetes APIs accept and persist `NetworkPolicy` custom resources regardless of whether the installed CNI supports them. If the CNI (e.g., standard Flannel) lacks policy enforcement capabilities, it ignores the resource entirely. The API server returns success (`networkpolicy.networking.k8s.io created`), giving operators a false sense of security, but no network boundaries (`iptables`/`eBPF` rules) are programmed, leaving all ingress/egress completely open.

2. **Answer**:  
   Denied. `namespaceSelector` matches labels on `Namespace` API objects, NOT the metadata namespace name string unless the automatic label `kubernetes.io/metadata.name: production` is explicitly present (available in modern Kubernetes releases). If target namespaces lack the specified label (e.g., `environment: production`), the selector evaluates to an empty set of namespaces, blocking all traffic from those sources.

</details>