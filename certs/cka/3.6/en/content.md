# 3.6 Manage Role-Based Access Control (RBAC)

## What is RBAC?

RBAC (Role-Based Access Control) is the authorization engine in Kubernetes that regulates whether a `subject` (a User, Group, or `ServiceAccount`) can perform specific API actions on target `resources` across a cluster. Authorization evaluates **after** authentication: the API server authenticates the caller's identity, then RBAC evaluates whether that identity possesses permissions to execute the requested operation.

RBAC is enabled on the `kube-apiserver` via authorization flags (`--authorization-mode=RBAC`). Modern Kubernetes distributions enable RBAC by default:

```bash
kubectl api-versions | grep rbac.authorization.k8s.io
```

```
rbac.authorization.k8s.io/v1
```

RBAC objects are **declarative** API resources (`Role`, `ClusterRole`, `RoleBinding`, `ClusterRoleBinding`) under API group `rbac.authorization.k8s.io/v1`.

---

## Core RBAC Objects

RBAC separates permissions (**what actions can be performed**) from assignments (**who can perform them**).

| Object | Scope | Function |
|---|---|---|
| `Role` | Namespaced | Specifies permission `rules` within a single namespace |
| `ClusterRole` | Cluster-wide | Specifies permission `rules` across all namespaces, cluster-scoped resources (Nodes, PVs), or non-resource URLs (`/healthz`) |
| `RoleBinding` | Namespaced | Binds a `Role` (or `ClusterRole`) to `subjects`, limiting scope to a single namespace |
| `ClusterRoleBinding` | Cluster-wide | Binds a `ClusterRole` to `subjects` across all namespaces |

Key distinction for the CKA exam: A `RoleBinding` **can** reference a `ClusterRole`. This allows reusing common `ClusterRoles` (e.g. read-only pod viewer roles) across multiple namespaces while scoping granted permissions strictly to individual target namespaces. Conversely, a `ClusterRoleBinding` **cannot** reference a namespaced `Role`.

---

## Anatomy of RBAC Rules

`Role` and `ClusterRole` specifications declare permission `rules`. Each rule combines three core fields:

```yaml
rules:
- apiGroups: [""]              # "" indicates core API group (pods, services, configmaps...)
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

- **apiGroups**: The target resource API group. The core group uses an empty string `""`. Other groups include `apps` (Deployments), `batch` (Jobs/CronJobs), and `rbac.authorization.k8s.io`.
- **resources**: Target resource types specified in plural form (`pods`, `deployments`, `configmaps`). Subresources use slash syntax (e.g. `pods/log`, `pods/exec`).
- **verbs**: Allowed operations. Common verbs include `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`. Wildcards (`*`) grant all verbs.
- **resourceNames** (optional): Restricts rules to specific named instances (e.g. restricting `get` access exclusively to ConfigMap `app-config`). Cannot be used with `create` verbs.

Example rule specifying `resourceNames`:

```yaml
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["get", "watch"]
```

---

## Creating Roles and RoleBindings

### Imperative Creation

```bash
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  --namespace=dev
```

```bash
kubectl create rolebinding read-pods-binding \
  --role=pod-reader \
  --serviceaccount=dev:app-sa \
  --namespace=dev
```

`--serviceaccount=dev:app-sa` uses `namespace:name` syntax to bind permissions to ServiceAccount `app-sa` in namespace `dev`. Users or Groups use `--user=` or `--group=`.

### Declarative Definition

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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods-binding
  namespace: dev
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

`roleRef.apiGroup` is always `rbac.authorization.k8s.io`. **`roleRef` fields are immutable** once created. Updating bound role targets requires deleting and recreating the Binding object.

---

## ClusterRole and ClusterRoleBinding

`ClusterRole` objects serve three primary use cases:

1. Granting access to **cluster-scoped** resources (`nodes`, `persistentvolumes`, `namespaces`, `clusterroles`).
2. Granting access to **non-resource endpoints** (`/healthz`, `/metrics`).
3. Defining reusable permission templates applied across namespaces via `RoleBinding`.

```bash
kubectl create clusterrole node-reader \
  --verb=get,list,watch \
  --resource=nodes
```

```bash
kubectl create clusterrolebinding node-reader-binding \
  --clusterrole=node-reader \
  --user=jane
```

Non-resource URL rules are specified exclusively inside `ClusterRole` objects using `nonResourceURLs`:

```yaml
rules:
- nonResourceURLs: ["/healthz", "/healthz/*"]
  verbs: ["get"]
```

---

## Built-In Default ClusterRoles

Kubernetes provides built-in `ClusterRole` templates:

| ClusterRole | Purpose |
|---|---|
| `view` | Read-only access to most namespaced resources (excludes full `Secret` contents) |
| `edit` | Read/write access to namespaced resources (excludes modifying Roles/RoleBindings) |
| `admin` | Full administrative control within a namespace (includes local Role/RoleBinding management) |
| `cluster-admin` | Full administrative control across the entire cluster (superuser) |

```bash
kubectl create rolebinding dev-team-edit \
  --clusterrole=edit \
  --user=carlos \
  --namespace=staging
```

Binding built-in `ClusterRoles` using namespaced `RoleBindings` grants scoped access without writing custom role rules.

---

## ServiceAccounts and RBAC

Pods execute under an assigned `ServiceAccount` (defaulting to `default` per namespace). ServiceAccounts serve as primary `subjects` in `RoleBindings` when workloads interact with the Kubernetes API server.

```bash
kubectl create serviceaccount app-sa -n dev
```

```yaml
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
```

Best practices:
- Avoid granting `cluster-admin` bindings to application ServiceAccounts unless strictly required.
- Set `automountServiceAccountToken: false` on Pods or ServiceAccounts when workloads do not require API server communication.
- ServiceAccounts lacking RoleBindings hold default `system:authenticated` permissions (typically unprivileged).

---

## Verifying Permissions: `kubectl auth can-i`

Test and debug RBAC authorizations using `kubectl auth can-i`:

```bash
kubectl auth can-i create deployments --namespace=dev
```

```
yes
```

Simulate specific ServiceAccount or User identities:

```bash
kubectl auth can-i delete pods --namespace=dev --as=system:serviceaccount:dev:app-sa
```

```
no
```

List all permitted API actions for an identity:

```bash
kubectl auth can-i --list --namespace=dev --as=system:serviceaccount:dev:app-sa
```

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                             []                  []               [get list watch]
```

---

## Aggregated ClusterRoles

A `ClusterRole` can dynamically aggregate rules from other `ClusterRoles` matching a `labelSelector` via `aggregationRule`. Built-in roles (`view`, `edit`, `admin`) use aggregation rules to incorporate custom extension permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-edit
  labels:
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
- apiGroups: ["monitoring.coreos.com"]
  resources: ["prometheusrules", "servicemonitors"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

Labeling `monitoring-edit` automatically injects its rule specs into the built-in `edit` ClusterRole. The `rules` block on aggregated ClusterRoles is managed dynamically by aggregation controllers.

---

## Common Troubleshooting Patterns

1. **"Forbidden" API Errors**: Identify the caller identity (`system:serviceaccount:<ns>:<name>`), then run `kubectl auth can-i ... --as=...` to reproduce authorization decisions.
2. **Mismatched RoleBinding Namespaces**: `RoleBinding` permissions apply strictly within their declared `metadata.namespace`.
3. **Mismatched `roleRef.kind`**: Verify `roleRef.kind` matches target resource definitions (`Role` vs `ClusterRole`).
4. **Inspecting Role Rules**:
   ```bash
   kubectl describe clusterrole edit
   ```

---

## References

- Official RBAC Authorization Documentation: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/#role-and-clusterrole
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- kubectl auth can-i Reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
