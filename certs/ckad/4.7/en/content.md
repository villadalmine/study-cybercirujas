# 4.7 Understand ServiceAccounts

**Exam:** CKAD (v1.35) · **Weight:** 3

---

## 1. What It Is and Why It Exists

A **ServiceAccount** is a Kubernetes identity designed for **processes running inside Pods**, as opposed to **User** accounts used by humans (via certificates, OIDC, etc.) to communicate via `kubectl`. When a Pod needs to call the API server — to read its own `ConfigMap`, list other Pods, create a Job, or interact with an Operator — it must authenticate using the identity of its assigned ServiceAccount rather than the user who created the Pod.

`ServiceAccount` is a native, namespaced core API resource (`v1`):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: default
```

By itself, a ServiceAccount **grants no permissions**. It is strictly an identity ("who you are"); what that identity is allowed to do is determined by RBAC (`Role`/`RoleBinding`, Topic 4.2). This topic focuses on identity mechanics: creation, assignment to Pods, token generation/usage, and inspection — rather than writing authorization rules.

## 2. The Default ServiceAccount

Every namespace contains a ServiceAccount named `default` created automatically upon namespace initialization:

```bash
$ kubectl get serviceaccounts
NAME      SECRETS   AGE
default   0         3h
```

Any Pod that **omits** `spec.serviceAccountName` is automatically assigned the namespace's `default` ServiceAccount. While convenient, this poses security risks: if `default` carries broad RBAC permissions (e.g. via an overly permissive `RoleBinding`), **every** Pod in that namespace inherits those permissions implicitly. Best practices dictate avoiding running workloads under `default` when API access is needed, and omitting RBAC grants to `default` altogether.

```bash
$ kubectl get pod web -o jsonpath='{.spec.serviceAccountName}{"\n"}'
default
```

## 3. Creating and Assigning Custom ServiceAccounts

Imperative creation:

```bash
$ kubectl create serviceaccount app-sa
serviceaccount/app-sa created
```

Declarative creation uses standard YAML. To assign it to a Pod (or Deployment/Job/CronJob `template`), specify `spec.serviceAccountName`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  serviceAccountName: app-sa
  containers:
  - name: app
    image: nginx:1.27
```

```bash
$ kubectl apply -f pod.yaml
pod/web created

$ kubectl get pod web -o jsonpath='{.spec.serviceAccountName}{"\n"}'
app-sa
```

`serviceAccountName` **is immutable** once a Pod is created — changing it requires recreating the Pod, which in a Deployment happens naturally when updating `spec.template.spec.serviceAccountName` to trigger a rolling update.

A legacy field `serviceAccount` (without `Name`) exists strictly for backward compatibility — modern manifests and `kubectl` commands must use `serviceAccountName`.

## 4. ServiceAccount Tokens: Modern vs Legacy Mechanics

When a Pod runs with a ServiceAccount, kubelet automatically mounts a **token** used for API server authentication alongside cluster CA certificate and namespace files. This occurs for both `default` and custom ServiceAccounts.

```bash
$ kubectl exec web -- ls /var/run/secrets/kubernetes.io/serviceaccount/
ca.crt
namespace
token

$ kubectl exec web -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
default
```

Token generation mechanism underwent significant evolution:

| | **Legacy (pre-1.24)** | **Modern (BoundServiceAccountTokenVolume, GA since 1.22, default since 1.24)** |
|---|---|---|
| Mechanism | A `Secret` of type `kubernetes.io/service-account-token` created automatically per ServiceAccount and listed in `serviceAccountName.secrets[]` | **Projected volume** with `serviceAccountToken` source, generated dynamically at runtime via **TokenRequest API** |
| Expiration | Non-expiring (valid until Secret deletion) | Time-bound (default 1 hour lifetime, **auto-renewed** by kubelet before expiration while Pod is running) |
| Audience | Unrestricted (valid for any consumer trusting cluster CA) | **Audience-bound** — restricted by default to local cluster API server |
| Pod-bound | No — token exists independently of Pod | Yes — embeds Pod claims (`kubernetes.io/pod-name`, UID), invalidated upon Pod deletion |
| Auto Secret creation | Automatic | **None** — `kubectl get sa` shows `SECRETS: 0` unless created manually |

In modern clusters (1.24+), `kubectl create serviceaccount` **no longer** creates automatic Secrets. If a long-lived token is explicitly required (e.g. external non-cluster tools unable to handle token rotation), it must be created manually:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-sa-token
  annotations:
    kubernetes.io/service-account.name: app-sa
type: kubernetes.io/service-account-token
```

The token controller automatically populates `data.token`, `data.ca.crt`, and `data.namespace` fields when applied. Manual token Secret creation is an exception; the exam expects mastery of **projected tokens** as standard behavior.

Short-lived debug tokens can also be requested without persisting API objects:

```bash
$ kubectl create token app-sa --duration=10m
eyJhbGciOiJSUzI1NiIsImtpZCI6Ii1QYnRZ...   # JWT expiring in 10 minutes
```

## 5. How Pods Authenticate to API Server

Inside containers, mounted token and CA files enable authentication against API server endpoints without additional credentials — a pattern used by controllers and Operators (Topic 4.1):

```bash
$ kubectl exec web -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  curl -sS --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/default/pods
'
{
  "kind": "Status",
  "status": "Failure",
  "message": "pods is forbidden: User \"system:serviceaccount:default:app-sa\" cannot list resource \"pods\" in API group \"\" in the namespace \"default\"",
  "reason": "Forbidden",
  ...
}
```

This `Forbidden` error marks where authentication ends and RBAC (Topic 4.2) begins: authentication succeeded (API server identified ServiceAccount as `system:serviceaccount:<namespace>:<name>`), but no `Role`/`RoleBinding` grants `list` permissions on `pods`. `kubernetes.default.svc` is internal cluster DNS name for the API server.

Test ServiceAccount permissions rapidly without executing inside Pods:

```bash
$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa
no

$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa -n kube-system
no
```

## 6. `automountServiceAccountToken`

Mounting tokens is enabled by default, but workloads not calling API server (e.g. static web servers) should disable it to reduce attack surface. Unnecessary token mounting allows compromised containers to inherit cluster identity. `automountServiceAccountToken: false` disables mounting and can be set at two levels:

```yaml
# ServiceAccount level: applies to consuming Pods unless overridden
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
automountServiceAccountToken: false
```

```yaml
# Pod level: overrides ServiceAccount setting
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: false
  containers:
  - name: app
    image: nginx:1.27
```

Pod-level `spec.automountServiceAccountToken` takes precedence over ServiceAccount setting. If omitted at Pod level, it inherits ServiceAccount setting; if omitted at both levels, defaults to `true` (mounted).

```bash
$ kubectl get pod web -o yaml | grep -A1 serviceaccount/token
    - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      name: kube-api-access-x7z2p

$ kubectl exec web -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

## 7. ServiceAccount + RBAC Integration

Topic 4.2 covers `Role`/`ClusterRole` and `RoleBinding`/`ClusterRoleBinding` details. Here we review ServiceAccounts as binding `subjects`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-sa-pod-reader
  namespace: default
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: default        # mandatory: binding does not assume subject namespace
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
$ kubectl apply -f rolebinding.yaml
rolebinding.rbac.authorization.k8s.io/app-sa-pod-reader created

$ kubectl auth can-i list pods --as=system:serviceaccount:default:app-sa
yes
```

A `ClusterRoleBinding` referencing a ServiceAccount subject grants cluster-wide permissions, even though ServiceAccount is a namespaced object. Reusing pre-defined `ClusterRoles` (`view`, `edit`, `admin`) scoped to a single namespace via namespaced `RoleBinding` is standard practice.

## 8. `imagePullSecrets` in ServiceAccounts

ServiceAccounts can attach `imagePullSecrets` (`kubernetes.io/dockerconfigjson` Secrets, see 4.6) that apply **automatically to consuming Pods** without declaring `imagePullSecrets` per Pod/Deployment:

```bash
$ kubectl patch serviceaccount app-sa \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
serviceaccount/app-sa patched

$ kubectl get sa app-sa -o yaml | grep -A1 imagePullSecrets
imagePullSecrets:
- name: regcred
```

Any Pod using `app-sa` inherits private registry credentials. **Note:** Admission controller copies ServiceAccount `imagePullSecrets` only when Pod omits them (`len(pod.Spec.ImagePullSecrets) == 0`). If a Pod defines explicit `imagePullSecrets`, ServiceAccount pull secrets are ignored; Pods requiring both must list both explicitly.

## 9. Inspection and Helpful Commands

```bash
$ kubectl get serviceaccounts -A
NAMESPACE   NAME      SECRETS   AGE
default     app-sa    0         5m
default     default   0         3h
kube-system default   0         3h
...

$ kubectl describe serviceaccount app-sa
Name:                app-sa
Namespace:           default
Labels:              <none>
Annotations:         <none>
Image pull secrets:  regcred
Mountable secrets:   <none>
Tokens:              <none>
Events:              <none>

$ kubectl get rolebinding,clusterrolebinding -A \
  -o jsonpath='{range .items[?(@.subjects[0].name=="app-sa")]}{.metadata.name}{"\n"}{end}'
app-sa-pod-reader

$ kubectl delete serviceaccount app-sa
serviceaccount "app-sa" deleted
```

Deleting a ServiceAccount **does not delete** referencing `RoleBinding`/`ClusterRoleBinding` objects — bindings remain pointing to a missing subject (no error, zero permissions granted).

## 10. Best Practices and Common Pitfalls

- **Do not use `default` for API-consuming workloads.** Create dedicated ServiceAccounts per application/role for RBAC auditability.
- **Set `automountServiceAccountToken: false` when API access is unneeded.** Reduces attack surface without functional overhead.
- **Do not expect automatic Secret creation on ServiceAccounts.** In 1.24+, `SECRETS: 0` in `kubectl get sa` is normal — tokens use projected volumes.
- **Always specify subject namespace in bindings.** Omitting `namespace:` in `RoleBinding`/`ClusterRoleBinding` subjects causes binding failures or target misalignment.
- **Use `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>` to test RBAC.** Fast verification method during exam tasks.
- **Expired token ≠ revoked Secret.** Under modern token mechanics, expired tokens return `401 Unauthorized` and are auto-renewed by kubelet while Pod runs.

## References

- Configure Service Accounts for Pods — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Service Account Tokens (TokenRequest API, BoundServiceAccountTokenVolume) — https://kubernetes.io/docs/concepts/security/service-accounts/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- `kubectl create token` — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-token
- `kubectl auth can-i` — https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
