# 3.5 Security

## The 4Cs of Cloud Native Security

Security in a cloud native environment is modeled as concentric layers, where each layer depends on the layers surrounding it being properly secured:

1. **Cloud (or Co-lo/Corporate datacenter)**: the underlying infrastructure (cloud provider, own datacenter). Includes provider IAM, perimeter network security, disk encryption.
2. **Cluster**: the configuration of the Kubernetes cluster itself (API server, etcd, kubelet, admission policies).
3. **Container**: the security of the container image and its runtime (vulnerabilities, privileges, attack surface).
4. **Code**: the security of the application code (dependencies, hardcoded secrets, own vulnerabilities).

A failure in an inner layer cannot be compensated solely by security in outer layers: if the application code has a critical vulnerability, a well-configured cluster reduces the impact but does not eliminate it.

## Cluster-level Security

### API Server: Authentication and Authorization

Every request to the API server goes through three phases:

1. **Authentication**: verifies *who* is making the request (client certificates, service account tokens, OIDC, etc.).
2. **Authorization**: verifies *what that user/service account can do*. The most common mode is **RBAC** (Role-Based Access Control).
3. **Admission Control**: intercepts the request after authentication/authorization but before persisting it in etcd, allowing the object to be validated or mutated.

### RBAC

RBAC is defined with four objects:

- `Role`: permissions within a namespace.
- `ClusterRole`: cluster-level permissions (or reusable across multiple namespaces).
- `RoleBinding`: binds a `Role` (or `ClusterRole`) to a user/group/service account, within a namespace.
- `ClusterRoleBinding`: binds a `ClusterRole` at cluster level.

Example: A `Role` that only allows reading Pods in the `dev` namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: dev
subjects:
- kind: User
  name: jane
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Check permissions for a user or service account:

```console
$ kubectl auth can-i list pods --namespace dev --as jane
yes

$ kubectl auth can-i delete deployments --namespace dev --as jane
no
```

The guiding principle is **least privilege**: grant only the verbs and resources strictly necessary.

### Service Accounts

Each Pod runs with a **ServiceAccount** identity (by default, `default` in its namespace). The ServiceAccount token is automatically mounted into the Pod and used to authenticate against the API server.

```console
$ kubectl create serviceaccount ci-bot -n dev
$ kubectl get sa ci-bot -n dev -o yaml
```

Best practices:
- Disable automatic token mounting if the Pod does not need to talk to the API server (`automountServiceAccountToken: false`).
- Create dedicated ServiceAccounts per application instead of using `default`.

### Secrets

`Secret` objects store sensitive data (passwords, tokens, keys) encoded in base64 (not encrypted by default in etcd, unless **encryption at rest** is enabled).

```console
$ kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password=S3cr3t!

$ kubectl get secret db-creds -o jsonpath='{.data.username}' | base64 -d
admin
```

Considerations:
- Base64 **is not encryption**, it is only reversible encoding.
- Enable `EncryptionConfiguration` to encrypt Secrets in etcd.
- Restrict via RBAC who can `get`/`list` Secrets.
- Consider external secret management solutions (HashiCorp Vault, cloud KMS) integrated via CSI driver or external-secrets.

### Admission Control

**Admission controllers** intercept requests after authN/authZ. They are divided into:

- **Mutating**: can modify the object (e.g., inject a sidecar).
- **Validating**: only accept or reject the object.

Kubernetes supports dynamic webhooks (`MutatingAdmissionWebhook`, `ValidatingAdmissionWebhook`) for custom logic. Projects like **OPA/Gatekeeper** and **Kyverno** are used to enforce policies (e.g., "images without a specific tag are not allowed", "every Pod must have `resources.limits`").

### Network Policies

By default, all Pods in a cluster can communicate with each other without restriction. `NetworkPolicy` allows defining ingress/egress rules at the Pod level, but requires that the **CNI plugin** supports them (e.g., Calico, Cilium; the basic CNI of some providers does not implement them).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: dev
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

This manifest blocks all incoming traffic to Pods in the `dev` namespace, unless another `NetworkPolicy` explicitly allows it.

## Container-level Security

### Pod Security Standards

Kubernetes defines three security profiles for Pods (replacing the deprecated PodSecurityPolicies):

- **Privileged**: unrestricted.
- **Baseline**: blocks known privilege escalations, allows reasonable default configurations.
- **Restricted**: heavily restricted, follows hardening best practices (no root, no privilege escalation, read-only filesystem, etc.).

They are applied via namespace labels, using the **Pod Security Admission** controller (built-in since v1.25):

```console
$ kubectl label namespace dev \
  pod-security.kubernetes.io/enforce=restricted
```

### securityContext

Defines security restrictions at Pod or container level:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
  - name: app
    image: myapp:1.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

Key points: run as non-root user, disable privilege escalation, read-only root filesystem, and drop unnecessary Linux capabilities.

## Code-level Security (Image and Supply Chain)

- **Vulnerability scanning**: tools like Trivy or Grype analyze images for known CVEs before deploying them.
- **Minimal images**: using distroless or Alpine reduces the attack surface.
- **Image signing**: projects like **Sigstore/Cosign** allow signing and verifying the provenance of an image (supply chain security).
- **SBOM (Software Bill of Materials)**: inventory of components in an image, useful for auditing dependencies.

```console
$ trivy image myapp:1.0
```

## Other Relevant Concepts

- **kube-bench**: tool from the CIS (Center for Internet Security) that audits cluster configuration against the CIS Kubernetes Benchmark.
- **Falco**: runtime anomaly detection (e.g., an unexpected process inside a container).
- **mTLS between services**: service meshes (Istio, Linkerd) can automatically encrypt east-west traffic between Pods.

## References

- CNCF Curriculum — KCNA: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Controlling Access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes Docs — RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes Docs — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes Docs — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Docs — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes Docs — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Docs — Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Sigstore: https://www.sigstore.dev/
- CIS Kubernetes Benchmark / kube-bench: https://github.com/aquasecurity/kube-bench
- Falco: https://falco.org/docs/