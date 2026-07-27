# 4.2 Understanding authentication, authorization and admission control

## The API Server Request Flow

Every request sent to `kube-apiserver` passes through three sequential stages, in exact order:

```
Client (kubectl, Pod, controller) 
    │
    ▼
1. Authentication  → Who are you?
    │
    ▼
2. Authorization   → Do you have permission for this action?
    │
    ▼
3. Admission Control → Does the submitted object comply with cluster policies?
    │
    ▼
Etcd Persistence
```

If authentication fails → `401 Unauthorized`. If authorization fails → `403 Forbidden`. If an admission controller fails → object is rejected (or modified) with an error. Remembering this order is essential for the exam: identity first, permissions second, and object validation/mutation last.

---

## 1. Authentication

Kubernetes has no native `User` resource object. It distinguishes two identity categories:

- **Normal Users**: Managed outside the cluster (x509 certificates, OIDC, external tokens). No API object exists to create or manage normal users.
- **ServiceAccounts**: First-class Kubernetes API objects (`kubectl get sa`), designed for in-cluster processes (Pods communicating with the API server).

### Supported Authentication Methods

| Method | Typical Use Case |
|---|---|
| Client certificates (x509) | Administrator `kubectl`, control plane components |
| Bearer tokens (ServiceAccount tokens) | Pods calling API server |
| Bootstrap tokens | Joining nodes to cluster |
| OIDC tokens | Integration with external Identity Providers (Google, Azure AD, Okta, etc.) |
| Webhook token authentication | Delegating token verification to an external service |

### kubeconfig

`kubectl` does not intrinsically know your identity; it reads credentials from `kubeconfig` (typically `~/.kube/config`), which defines **clusters**, **users**, and **contexts**:

```bash
kubectl config view --minify
```

```yaml
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://192.168.49.2:8443
  name: minikube
contexts:
- context:
    cluster: minikube
    namespace: dev
    user: minikube
  name: minikube
current-context: minikube
users:
- name: minikube
  user:
    client-certificate: /home/user/.minikube/profiles/minikube/client.crt
    client-key: /home/user/.minikube/profiles/minikube/client.key
```

Switching contexts or namespaces without manually editing files:

```bash
kubectl config set-context --current --namespace=dev
kubectl config use-context another-cluster
```

### ServiceAccounts

Every namespace has a `default` ServiceAccount. Any Pod omitting `serviceAccountName` uses it automatically.

```bash
kubectl create serviceaccount ci-bot -n dev
kubectl get sa ci-bot -n dev -o yaml
```

Assigning a ServiceAccount to a Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  serviceAccountName: ci-bot
  containers:
  - name: app
    image: nginx
```

Since Kubernetes 1.24, ServiceAccount tokens **are no longer automatically created as Secrets**. Kubelet injects short-lived tokens via **projected volumes** (`TokenRequest API`), mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. To issue an explicit token on-demand:

```bash
kubectl create token ci-bot -n dev --duration=1h
```

Or manually declare an explicit static Secret (legacy mechanism, used only when static long-lived token is required):

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: ci-bot-token
  annotations:
    kubernetes.io/service-account.name: ci-bot
```

Verifying active token from inside a container:

```bash
kubectl exec -it app -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

---

## 2. Authorization

Once authenticated, API server evaluates whether the identity can execute the requested action (verb + resource + namespace). Supported modes configured via `--authorization-mode` on `kube-apiserver`:

- **Node**: Authorizes requests from kubelets for resources related to their specific node.
- **ABAC** (Attribute-Based Access Control): File-based policy rules, rarely used today.
- **RBAC** (Role-Based Access Control): Standard mode and primary focus of the exam.
- **Webhook**: Delegates authorization decisions to an external HTTP service.

Production clusters typically set `--authorization-mode=Node,RBAC`.

### RBAC: The Four Objects

| Object | Scope | Defines |
|---|---|---|
| `Role` | Namespace | Rules (verbs on resources) within a namespace |
| `ClusterRole` | Cluster-wide | Rules, including non-namespaced resources (nodes, PVs) |
| `RoleBinding` | Namespace | Grants a `Role` (or `ClusterRole`) to subjects in a namespace |
| `ClusterRoleBinding` | Cluster-wide | Grants a `ClusterRole` to subjects cluster-wide |

A `ClusterRole` bound via a `RoleBinding` grants permissions **only in the binding's namespace** — a common pattern to reuse generic roles (`view`, `edit`, `admin`) without duplication.

**Example — Read-only Role for Pods in `dev`:**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-pod-reader
  namespace: dev
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: dev
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Equivalent imperative creation:

```bash
kubectl create role pod-reader --verb=get,list,watch --resource=pods -n dev
kubectl create rolebinding ci-bot-pod-reader \
  --role=pod-reader --serviceaccount=dev:ci-bot -n dev
```

**Example — ClusterRole + ClusterRoleBinding for viewing Nodes (non-namespaced resource):**

```bash
kubectl create clusterrole node-viewer --verb=get,list --resource=nodes
kubectl create clusterrolebinding ci-bot-node-viewer \
  --clusterrole=node-viewer --serviceaccount=dev:ci-bot
```

### Checking Permissions: `kubectl auth can-i`

Essential exam command to verify RBAC without guessing:

```bash
kubectl auth can-i list pods --namespace dev \
  --as=system:serviceaccount:dev:ci-bot
# yes

kubectl auth can-i delete deployments --namespace dev \
  --as=system:serviceaccount:dev:ci-bot
# no

kubectl auth can-i '*' '*' --as=system:serviceaccount:dev:ci-bot
# no  (verifies cluster-admin status)
```

Listing all effective permissions for a subject:

```bash
kubectl auth can-i --list --as=system:serviceaccount:dev:ci-bot -n dev
```

```
Resources                                       Non-Resource URLs  Resource Names  Verbs
pods                                             []                 []              [get list watch]
```

---

## 3. Admission Control

**Admission controllers** are the final gateway before persisting objects to etcd. They run in two distinct phases in order:

1. **Mutating admission controllers**: Can modify incoming objects (e.g. inject sidecars, set default values).
2. **Validating admission controllers**: Accept or reject objects, but cannot mutate.

```
Authorization OK
    │
    ▼
Mutating admission (built-in) → Mutating webhooks
    │
    ▼
Object schema validation (OpenAPI)
    │
    ▼
Validating admission (built-in) → Validating webhooks
    │
    ▼
Persist in etcd
```

### Relevant Built-in Admission Controllers

Enabled/disabled via `kube-apiserver` flags:

```bash
kube-apiserver --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ResourceQuota,PodSecurity
```

| Controller | Function |
|---|---|
| `NamespaceLifecycle` | Rejects object creation in non-existent or terminating namespaces |
| `LimitRanger` | Enforces default/limit configurations from `LimitRange` objects |
| `ResourceQuota` | Rejects objects exceeding namespace `ResourceQuota` |
| `PodSecurity` | Replaces PodSecurityPolicy; enforces Pod Security Standards per namespace |
| `DefaultStorageClass` | Assigns default StorageClass to PVCs omitting `storageClassName` |
| `ServiceAccount` | Assigns `default` ServiceAccount to Pods omitting explicit account |
| `MutatingAdmissionWebhook` / `ValidatingAdmissionWebhook` | Delegates to external webhooks (see below) |

### PodSecurity Admission

Replaces legacy PodSecurityPolicy (removed in 1.25). Configured using **namespace labels**:

```bash
kubectl label namespace dev \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=baseline
```

Levels: `privileged`, `baseline`, `restricted`. Modes: `enforce` (rejects), `warn` (allows with warning), `audit` (allows, records in audit log).

Example rejection creating a privileged Pod in a `restricted` namespace:

```bash
kubectl run privileged-pod --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"privileged-pod","image":"nginx","securityContext":{"privileged":true}}]}}' \
  -n dev
```

```
Error from server (Forbidden): pods "privileged-pod" is forbidden: violates PodSecurity "restricted:latest": 
privileged (container "privileged-pod" must not set securityContext.privileged=true)
```

### Dynamic Admission Control: Webhooks

When built-in controllers are insufficient, register a `ValidatingWebhookConfiguration` or `MutatingWebhookConfiguration` pointing to an HTTP service:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: require-labels
webhooks:
- name: require-labels.example.com
  clientConfig:
    service:
      name: label-validator
      namespace: policy-system
      path: "/validate"
    caBundle: <base64-ca-cert>
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
```

`failurePolicy: Fail` rejects requests if webhook call fails (fail-closed); `Ignore` allows request through (fail-open). This distinction is frequently examined.

---

## References

- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Dynamic Admission Control — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
