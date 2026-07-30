# 2.2 Manage Kubernetes Secrets

**Domain weight: 5**

## Why this topic matters for CKS

A Kubernetes `Secret` is *not* a secure vault. By default it is a namespaced API object holding **base64-encoded** (not encrypted) data, stored in plaintext inside etcd. The CKS exam expects you to know exactly where the trust boundaries are and how to tighten them: encryption at rest, RBAC scoping, safe consumption inside Pods, short-lived ServiceAccount tokens, and delegation to external secret stores.

Tasks in this area are almost always hands-on: edit the `kube-apiserver` static Pod manifest, write an `EncryptionConfiguration`, prove a Secret is encrypted in etcd, or fix an over-permissive Role.

---

## 1. What a Secret actually is

```bash
kubectl create secret generic db-creds \
  --from-literal=username=app \
  --from-literal=password='S3cr3t!'
```

```
secret/db-creds created
```

```bash
kubectl get secret db-creds -o yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: default
type: Opaque
data:
  password: UzNjcjN0IQ==
  username: YXBw
```

Decoding is trivial for anyone with read access — this is encoding, not protection:

```bash
kubectl get secret db-creds -o jsonpath='{.data.password}' | base64 -d
```

```
S3cr3t!
```

Key properties to internalize:

| Property | Detail |
|---|---|
| Scope | Namespaced. A Secret can only be mounted by Pods in the same namespace. |
| Size limit | 1 MiB per Secret (etcd/apiserver constraint). Large blobs belong elsewhere. |
| Storage | etcd, **plaintext by default** — anyone with etcd disk access, a backup, or a snapshot reads everything. |
| `kubectl describe` | Shows key names and byte counts only, never values. Useful for demos, not a security control. |
| `data` vs `stringData` | `data` requires base64; `stringData` accepts plaintext and is encoded on write (write-only field, never returned by the API). |

### Secret types

The `type` field drives validation of required keys:

| Type | Required keys | Typical use |
|---|---|---|
| `Opaque` | none | Arbitrary key/value (default) |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | Ingress / webhook serving certs |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `imagePullSecrets` |
| `kubernetes.io/basic-auth` | `username`, `password` | Basic auth credentials |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | Git-over-SSH, sidecars |
| `kubernetes.io/service-account-token` | `token` (populated by controller) | **Legacy** long-lived SA tokens |
| `bootstrap.kubernetes.io/token` | `token-id`, `token-secret` | `kubeadm join` bootstrap |

---

## 2. Creating Secrets

### Imperative (fastest path in the exam)

```bash
# From literals
kubectl create secret generic api-key --from-literal=key=abc123

# From files — the file name becomes the key
kubectl create secret generic ssh-key --from-file=ssh-privatekey=/root/.ssh/id_ed25519

# Rename the key explicitly
kubectl create secret generic ca --from-file=ca.crt=/etc/kubernetes/pki/ca.crt

# From a dotenv file (KEY=VALUE per line)
kubectl create secret generic app-env --from-env-file=./app.env

# TLS
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key

# Registry credentials
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=ci \
  --docker-password='pull-token'
```

Generate YAML without touching the cluster — the idiom to remember:

```bash
kubectl create secret generic db-creds \
  --from-literal=password='S3cr3t!' \
  --dry-run=client -o yaml > db-creds.yaml
```

### Declarative with `stringData`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
stringData:
  username: app
  password: "S3cr3t!"
  config.ini: |
    [db]
    host=postgres.prod.svc
```

### Immutable Secrets

Marking a Secret immutable prevents accidental or malicious updates and lets the kubelet stop watching it (less apiserver load):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
immutable: true
data:
  password: UzNjcjN0IQ==
```

```bash
kubectl patch secret db-creds -p '{"stringData":{"password":"new"}}'
```

```
Error from server: Secret "db-creds" is invalid: data: Forbidden: field is immutable when `immutable` is set
```

To change the value you must delete and recreate — which is a deliberate, auditable action. Note that Pods consuming an immutable Secret via volume will **not** see updates.

---

## 3. Consuming Secrets in Pods safely

### Environment variables (convenient, weaker)

```yaml
    env:
      - name: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-creds
            key: password
            optional: false
    envFrom:
      - secretRef:
          name: app-env
```

Why env vars are the weaker option:

- Readable via `/proc/<pid>/environ` by anything in the same PID namespace, and often dumped by crash handlers, APM agents, and `docker inspect`-style tooling.
- Frequently printed by application startup logs or error reporters.
- **Never updated** when the Secret changes — the Pod must be recreated.
- Child processes inherit them by default.

### Volume mounts (preferred)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      volumeMounts:
        - name: creds
          mountPath: /etc/app/creds
          readOnly: true
  volumes:
    - name: creds
      secret:
        secretName: db-creds
        defaultMode: 0400
        items:
          - key: password
            path: db_password
```

```bash
kubectl exec app -- ls -l /etc/app/creds
```

```
total 0
lrwxrwxrwx 1 root root 18 Jul 29 10:14 db_password -> ..data/db_password
```

Points to remember:

- Secret volumes are backed by `tmpfs` (RAM) — they never land on the node's disk.
- `items` projects only the keys you need — least privilege inside the container.
- `defaultMode: 0400` narrows file permissions; combine with `runAsUser` so the right UID owns the file.
- Volume-mounted Secrets are **updated in place** by the kubelet after a change (eventually consistent, roughly the kubelet sync period plus cache TTL). The `..data` symlink swap makes updates atomic.
- **`subPath` mounts do not receive updates.** This is a classic gotcha.

### `imagePullSecrets`

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

Or per Pod:

```yaml
spec:
  imagePullSecrets:
    - name: regcred
```

### Projected volumes

Combine a Secret, a ConfigMap, and a short-lived SA token into one directory:

```yaml
  volumes:
    - name: bundle
      projected:
        defaultMode: 0400
        sources:
          - secret:
              name: db-creds
              items:
                - key: password
                  path: db/password
          - configMap:
              name: app-config
          - serviceAccountToken:
              path: token
              audience: vault
              expirationSeconds: 3600
```

---

## 4. Who can read your Secrets

### RBAC: never grant blanket Secret access

```yaml
# BAD — reads every Secret in the namespace
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
```

```yaml
# BETTER — a single named Secret, get only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: prod
  name: db-creds-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-creds"]
    verbs: ["get"]
```

Critical subtlety: **`resourceNames` does not restrict `list` or `watch`.** Those verbs operate on a collection, not a named object, so granting `list` on `secrets` with `resourceNames` set either fails to restrict anything meaningful or is simply ineffective. If a subject has `list` on secrets, it can read every Secret in scope — including the values, because `list` returns full objects.

Verify effective permissions:

```bash
kubectl auth can-i list secrets -n prod --as=system:serviceaccount:prod:app
```

```
no
```

```bash
kubectl auth can-i get secret/db-creds -n prod --as=system:serviceaccount:prod:app
```

```
yes
```

### The Pod-creation escalation path

Anyone who can **create a Pod** in a namespace can mount any Secret in that namespace and exfiltrate it — no `get secrets` permission required. Treat `create pods` (and every controller that creates Pods: Deployments, Jobs, CronJobs, StatefulSets, DaemonSets) as equivalent to read access over all Secrets in that namespace.

Consequences for design:
- Use namespaces as the real secret boundary; do not co-locate unrelated workloads.
- Restrict who can create workloads in namespaces holding sensitive Secrets.
- `escalate`/`bind` restrictions do not help here — this is not an RBAC escalation, it is intended behavior.

### Node-level scoping

```bash
grep -E 'authorization-mode|enable-admission-plugins' /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
```

- **Node authorizer** limits each kubelet to reading only the Secrets referenced by Pods actually scheduled on its node.
- **`NodeRestriction`** admission plugin prevents a kubelet from editing its own Node object or other nodes' Pods, closing the path where a compromised kubelet labels itself to attract sensitive workloads.

Both must be present. Without the Node authorizer, one compromised node's credentials can read every Secret in the cluster.

### Disable unnecessary token mounting

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
automountServiceAccountToken: false
```

Or per Pod (`spec.automountServiceAccountToken: false`), which overrides the ServiceAccount setting. If a workload never talks to the API server, it should not carry an API credential.

---

## 5. ServiceAccount tokens

Modern clusters use **bound, short-lived, audience-scoped** tokens instead of the old non-expiring Secret-based tokens.

- Since v1.24, creating a ServiceAccount no longer auto-creates a token Secret.
- Pods receive a token through a **projected `serviceAccountToken` volume**, injected automatically, which the kubelet rotates before expiry (default ~1 hour, refreshed at ~80% of lifetime).
- The token is bound to the Pod and ServiceAccount: when the Pod is deleted, the token stops being valid.

Request an ad-hoc token:

```bash
kubectl create token app --duration=10m
```

```
eyJhbGciOiJSUzI1NiIsImtpZCI6Ii4uLiJ9.eyJhdWQ...
```

Inspect the injected token inside a Pod:

```bash
kubectl exec app -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

```
ca.crt
namespace
token
```

Creating a legacy long-lived token is still possible but should be treated as a finding:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-legacy-token
  annotations:
    kubernetes.io/service-account.name: app
type: kubernetes.io/service-account-token
```

These tokens never expire and survive ServiceAccount reuse. Recent Kubernetes versions track their last use (via a `kubernetes.io/legacy-token-last-used` annotation) and can clean up unused ones, but the correct answer in a hardening review is to remove them and switch callers to the TokenRequest API.

Audit-scoped token example for an external consumer (audience binding stops token replay against the API server):

```yaml
          - serviceAccountToken:
              path: vault-token
              audience: https://vault.example.com
              expirationSeconds: 600
```

`expirationSeconds` has a floor of 600.

---

## 6. Encryption at rest

This is the highest-value practical skill in this topic. Goal: `kube-apiserver` encrypts Secrets before writing them to etcd.

### Step 1 — generate a key

```bash
head -c 32 /dev/urandom | base64
```

```
7ZQ2rH0mQ5nJv9pC1xK3aLdF8sYtB6uWeR4iO0gN2sM=
```

### Step 2 — write the EncryptionConfiguration

```bash
mkdir -p /etc/kubernetes/enc
cat > /etc/kubernetes/enc/enc.yaml <<'EOF'
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
              secret: 7ZQ2rH0mQ5nJv9pC1xK3aLdF8sYtB6uWeR4iO0gN2sM=
      - identity: {}
EOF
chmod 600 /etc/kubernetes/enc/enc.yaml
```

Rules that decide behavior:

- **Order matters.** The first key of the first provider encrypts new writes. All listed providers/keys are tried for decryption.
- Keeping `identity` **last** allows reading existing plaintext data. Putting `identity` **first** disables encryption for new writes — that is how you decrypt a cluster.
- `resources` accepts wildcards such as `*.` (all core-group resources) or `*.*` (everything).

### Provider comparison

| Provider | Algorithm | Notes |
|---|---|---|
| `identity` | none | Plaintext. Default when no config is supplied. |
| `secretbox` | XSalsa20 + Poly1305 | Authenticated, fast, strong. |
| `aesgcm` | AES-GCM, random nonce | Authenticated, fast — **but the key must be rotated roughly every 200,000 writes**; nonce reuse is catastrophic. |
| `aescbc` | AES-CBC + PKCS#7 | Widely used in exam/lab material; not authenticated encryption, so the docs no longer recommend it for new clusters. |
| `kms` (v2) | envelope encryption via external KMS plugin | **Recommended for production.** The DEK-wrapping key never touches the API server host. |

KMS v1 is deprecated; new clusters should use KMS v2. Local-key providers store the key on the control-plane filesystem, so an attacker with control-plane root access still wins — that is precisely the gap KMS closes.

### Step 3 — wire it into the API server

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
        - --encryption-provider-config-automatic-reload=true
        # ... existing flags
      volumeMounts:
        - name: enc
          mountPath: /etc/kubernetes/enc
          readOnly: true
  volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
```

Saving the manifest makes the kubelet restart the static Pod. Watch it come back:

```bash
crictl ps | grep kube-apiserver
```

```
9f3c1a2b8d4e   3   Running   kube-apiserver   0   k8s_kube-apiserver_kube-apiserver-cp_kube-system_...
```

`--encryption-provider-config-automatic-reload=true` lets you rotate keys by editing the file without restarting the API server. Without it, every key change requires an apiserver restart.

In an HA cluster, apply the **identical** configuration file to every control-plane node before relying on it — otherwise one API server cannot decrypt what another wrote.

### Step 4 — prove it works

Create a new Secret and read the raw etcd value:

```bash
kubectl create secret generic enc-test --from-literal=password=topsecret

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | hexdump -C | head -5
```

Encrypted (note the `k8s:enc:aescbc:v1:key1:` prefix and no readable value):

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 65 6e 63 2d 74 65  |s/default/enc-te|
00000020  73 74 0a 6b 38 73 3a 65  6e 63 3a 61 65 73 63 62  |st.k8s:enc:aescb|
00000030  63 3a 76 31 3a 6b 65 79  31 3a 1d 4f b7 a9 6c 22  |c:v1:key1:.O..l"|
00000040  8e 33 0b c5 71 fa 20 db  9c 47 e1 5a 3f 08 62 d4  |.3..q. ..G.Z?.b.|
```

An **unencrypted** Secret looks like this instead — the value is right there:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
...
00000060  70 61 73 73 77 6f 72 64  12 09 74 6f 70 73 65 63  |password..topsec|
00000070  72 65 74                                          |ret|
```

### Step 5 — re-encrypt pre-existing Secrets

Encryption only applies on write. Existing Secrets stay plaintext until rewritten:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

```
secret/db-creds replaced
secret/regcred replaced
...
```

If you encrypted other resources too, run the equivalent for each (`kubectl get configmaps -A -o json | kubectl replace -f -`).

### Key rotation

1. Add the new key as the **second** entry under the existing provider and reload/restart every API server (all servers must be able to *decrypt* with the new key before any of them *encrypts* with it).
2. Move the new key to **first** position; reload/restart again — new writes now use it.
3. Re-encrypt everything: `kubectl get secrets -A -o json | kubectl replace -f -`.
4. Remove the old key and reload/restart a final time.

```yaml
      - aescbc:
          keys:
            - name: key2   # new — now the write key
              secret: <new-32-byte-base64>
            - name: key1   # old — kept only for decryption
              secret: <old-32-byte-base64>
```

Skipping the ordering dance in an HA cluster causes `Internal error occurred: ... no matching key was found for the provided keyID` on reads.

### What encryption at rest does *not* protect

- The etcd network path (use etcd peer/client TLS: `--cert-file`, `--key-file`, `--peer-*`, `--client-cert-auth=true`).
- Anyone with API read access to Secrets — the API server decrypts transparently for them.
- The key file itself on the control-plane node (mitigate with KMS).
- etcd backups taken *before* re-encryption.

---

## 7. External secret stores

The strongest posture is to keep sensitive material out of etcd altogether.

**Secrets Store CSI Driver** — mounts secrets from an external provider (Vault, AWS Secrets Manager, Azure Key Vault, GCP Secret Manager) directly into the Pod as a `tmpfs` volume:

```yaml
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: vault-db-creds
```

Properties worth citing in an exam answer:
- Values are fetched at Pod start and can be rotated by the driver; nothing is persisted in etcd unless you explicitly enable secret syncing.
- The Pod authenticates to the provider with its **projected ServiceAccount token** (audience-bound), so there is no bootstrap credential to leak.
- Access is auditable and revocable in the external system, independent of Kubernetes RBAC.

**External Secrets Operator / Vault Agent Injector** are the alternative pattern: they *do* materialize a Kubernetes Secret (ESO) or inject files via a sidecar (Vault Agent). ESO gives you central management and rotation but keeps the etcd exposure — so encryption at rest still matters.

**GitOps hygiene:** never commit raw Secret manifests. Use SOPS, Sealed Secrets, or a store reference (`ExternalSecret`, `SecretProviderClass`) so the repository holds only ciphertext or pointers.

---

## 8. Detecting and auditing Secret access

Audit Secret access at `Metadata` level only. Using `Request` or `RequestResponse` for secrets writes the secret values into the audit log — a self-inflicted breach:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log bodies for these
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods"]
```

Hunting for problems:

```bash
# Who can read secrets cluster-wide?
kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

# Roles granting list/watch on secrets
kubectl get roles,clusterroles -A -o json \
  | jq -r '.items[] | select(.rules[]? | (.resources[]?=="secrets") and (.verbs[]? | IN("list","watch","*"))) | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)"'

# Legacy long-lived SA token Secrets
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
```

Also check for secrets leaking through the wrong channels: `command`/`args` in Pod specs, ConfigMaps used as pseudo-Secrets, annotations, container image layers (`docker history`), and CI logs.

---

## 9. Hardening checklist

1. Enable encryption at rest for `secrets` (KMS v2 in production, local provider otherwise) and re-encrypt existing objects.
2. Enable `--authorization-mode=Node,RBAC` plus the `NodeRestriction` admission plugin.
3. No `list`/`watch` on `secrets` for workload identities; scope `get` with `resourceNames`.
4. Treat Pod-creation rights in a namespace as read access to that namespace's Secrets; separate sensitive workloads by namespace.
5. Prefer volume mounts over environment variables; set `defaultMode: 0400` and `readOnly: true`, and project only the needed `items`.
6. Set `automountServiceAccountToken: false` wherever the API is not used; use projected, audience-bound, short-lived tokens elsewhere.
7. Delete legacy `kubernetes.io/service-account-token` Secrets.
8. Mark stable Secrets `immutable: true`.
9. Protect etcd itself: client/peer TLS, `--client-cert-auth=true`, encrypted and access-controlled backups, host-level file permissions on `/etc/kubernetes/enc`.
10. Audit Secret access at `Metadata` level; never log request bodies for secrets.
11. Keep secrets out of Git, images, `args`, and application logs.

---

## Referencias

- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum
- Secrets (concepts): https://kubernetes.io/docs/concepts/configuration/secret/
- Good practices for Kubernetes Secrets: https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Managing Secrets using kubectl: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Managing Secrets using Configuration File: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/
- Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Encrypting Confidential Data at Rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using a KMS provider for data encryption: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- EncryptionConfiguration API reference: https://kubernetes.io/docs/reference/config-api/apiserver-encryption.v1/
- Configure Service Accounts for Pods: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Managing Service Accounts: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Using RBAC Authorization: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Node Authorization: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Using Admission Controllers (`NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Projected Volumes: https://kubernetes.io/docs/concepts/storage/projected-volumes/
- Pull an Image from a Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Secrets Store CSI Driver: https://secrets-store-csi-driver.sigs.k8s.io/
- Operating etcd clusters for Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/