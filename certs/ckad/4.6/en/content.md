# 4.6 — Create & consume Secrets

## What is a Secret?

A **Secret** is a Kubernetes object designed to store small amounts of sensitive data: passwords, tokens, TLS keys, image registry credentials. It operates almost identically to a **ConfigMap**, but with one key conceptual difference: declaring a data item as a Secret signals confidentiality, enabling cluster-level security controls (mounting in `tmpfs`, encryption at rest if configured, restrictive RBAC policies).

A critical point tested on exams: values in a Secret are encoded in **base64, which is not encryption**. Anyone with read access to the Secret object can trivially decode its content. Base64 encoding exists to represent binary data in YAML/JSON documents, not to provide confidentiality.

```bash
echo "cGFzc3dvcmQxMjM=" | base64 -d
# password123
```

## Secret Types

| Type (`type`) | Purpose |
|---|---|
| `Opaque` | Arbitrary key-value data (default) |
| `kubernetes.io/dockerconfigjson` | Credentials for pulling private container images |
| `kubernetes.io/tls` | TLS certificate and private key (`tls.crt` / `tls.key`) |
| `kubernetes.io/basic-auth` | Username and password (`username` / `password`) |
| `kubernetes.io/ssh-auth` | SSH private key (`ssh-privatekey`) |
| `kubernetes.io/service-account-token` | ServiceAccount token (legacy management) |

For CKAD, `Opaque`, `docker-registry`, and `tls` are the most frequently tested types.

## Creating Secrets

### Imperative with `kubectl` (Fastest Exam Approach)

**From Literals:**

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASS='S3cr3t!'
```

**From Files** (filename becomes key unless explicitly specified):

```bash
kubectl create secret generic app-keys \
  --from-file=api-key.txt \
  --from-file=custom-name=./token.txt
```

**From Environment File** (`KEY=value` format per line):

```bash
kubectl create secret generic app-env --from-env-file=prod.env
```

**TLS Secret:**

```bash
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key
```

**Private Registry Secret:**

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=deployer \
  --docker-password='p4ss' \
  --docker-email=dev@example.com
```

### Declarative with YAML

Two fields exist for secret data:

- `data`: **Base64-encoded** values.
- `stringData`: **Plaintext** values; API server base64-encodes them automatically. Write-only field (when reading back the object, values appear under `data`).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
stringData:
  DB_USER: admin
  DB_PASS: S3cr3t!
```

Equivalent using `data`:

```bash
echo -n 'admin' | base64      # YWRtaW4=
echo -n 'S3cr3t!' | base64    # UzNjcjN0IQ==
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
data:
  DB_USER: YWRtaW4=
  DB_PASS: UzNjcjN0IQ==
```

> **Warning regarding `echo`:** Always use `echo -n` to avoid embedding a trailing newline character in base64 strings. Trailing newlines produce subtle authentication failures.

Exam shortcut: generate manifest without applying using `--dry-run=client -o yaml`:

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --dry-run=client -o yaml > secret.yaml
```

## Inspecting and Decoding Secrets

```bash
kubectl get secrets
# NAME       TYPE     DATA   AGE
# db-creds   Opaque   2      1m

kubectl describe secret db-creds
# Data
# ====
# DB_PASS:  7 bytes
# DB_USER:  5 bytes
```

`describe` displays key size, not contents. To decode a specific value:

```bash
kubectl get secret db-creds -o jsonpath='{.data.DB_PASS}' | base64 -d
# S3cr3t!
```

## Consuming Secrets in a Pod

### 1. Individual Environment Variables (`secretKeyRef`)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx
    env:
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-creds
          key: DB_PASS
```

### 2. All Keys as Environment Variables (`envFrom`)

```yaml
    envFrom:
    - secretRef:
        name: db-creds
    # optional prefix for injected keys
    - secretRef:
        name: db-creds
      prefix: DB_
```

Each Secret key becomes an environment variable named after the key.

### 3. As Volume Mount (One File Per Key)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: creds
      mountPath: /etc/creds
      readOnly: true
  volumes:
  - name: creds
    secret:
      secretName: db-creds
```

Inside container:

```bash
kubectl exec app -- ls /etc/creds
# DB_PASS
# DB_USER
kubectl exec app -- cat /etc/creds/DB_PASS
# S3cr3t!
```

Project specific keys and customize file permissions using `items` and `defaultMode`:

```yaml
  volumes:
  - name: creds
    secret:
      secretName: db-creds
      defaultMode: 0400
      items:
      - key: DB_PASS
        path: database/password
```

### 4. As `imagePullSecrets`

```yaml
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - name: app
    image: registry.example.com/team/app:1.0
```

Can also be assigned to a ServiceAccount so all consuming Pods inherit it:

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```

## Critical Secret Behaviors

- **Mounted volumes update live; environment variables do not.** Updating a Secret refreshes mounted volume files automatically (with minor propagation latency; non-applicable for `subPath`). Environment variables remain static until Pod restart.
- **Non-existent Secret:** Referencing a missing Secret prevents Pod startup (`CreateContainerConfigError`), unless marked `optional: true`.
- **Namespace isolation:** A Pod can only consume Secrets residing in its own namespace.
- **Immutability:** Setting `immutable: true` prevents updates to the Secret (must be deleted and recreated); improves performance and avoids accidental modifications.
- **Size limit:** 1 MiB total Secret size limit.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
immutable: true
stringData:
  DB_PASS: S3cr3t!
```

## Secret vs ConfigMap (Exam Summary)

| | ConfigMap | Secret |
|---|---|---|
| Data type | Non-sensitive configuration | Sensitive credentials, keys, tokens |
| Encoding | Plaintext | base64 (`data`) or plaintext (`stringData`) |
| Consumption | env, `envFrom`, volumes | env, `envFrom`, volumes, `imagePullSecrets` |
| Env reference | `configMapKeyRef` | `secretKeyRef` |

## Exam Strategy Tips

1. Create Secrets **imperatively** (`kubectl create secret generic ... --from-literal=...`): faster and avoids base64 encoding errors.
2. If YAML is required, combine with `--dry-run=client -o yaml`.
3. Verify consumption via `kubectl exec <pod> -- env | grep <VAR>` or `kubectl exec <pod> -- cat <path>`.
4. If Pod enters `CreateContainerConfigError`, run `kubectl describe pod` to check for missing Secret or key names.

## References

- Secrets concepts: https://kubernetes.io/docs/concepts/configuration/secret/
- Managing Secrets using kubectl: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Managing Secrets using configuration files: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/
- Distribute credentials securely using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Pull an image from a private registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
