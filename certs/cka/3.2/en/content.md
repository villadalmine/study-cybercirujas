# 3.2 Use ConfigMaps and Secrets to configure applications

## Decoupling Application Configuration

Pods should avoid hardcoding configuration parameters (database endpoints, feature flags, API tokens, certificates) directly inside container images. Kubernetes provides two native objects for decoupling configuration data from application source code:

- **ConfigMap**: Non-sensitive, plain-text configuration data (key-value pairs or file blocks).
- **Secret**: Sensitive operational data (passwords, tokens, TLS certs, SSH keys). Stored as `base64` encoded strings (not encrypted by default) — base64 encoding is an encoding scheme, not an encryption mechanism.

Both resources are namespaced and injected into Pods via two mechanisms: as **environment variables** or as **mounted volume files**.

---

## ConfigMaps

### Imperative Creation

```bash
# From key-value literals
kubectl create configmap app-config \
  --from-literal=APP_MODE=production \
  --from-literal=LOG_LEVEL=info

# From a file asset (filename becomes the key)
kubectl create configmap nginx-config --from-file=nginx.conf

# From a directory (creates one key per file in the directory)
kubectl create configmap app-files --from-file=./config-dir/

# From an environment file (KEY=VALUE format per line)
kubectl create configmap app-env --from-env-file=app.env
```

Verification:

```bash
kubectl get configmap app-config -o yaml
```

Output:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
data:
  APP_MODE: production
  LOG_LEVEL: info
```

### Declarative Creation

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  APP_MODE: "production"
  LOG_LEVEL: "info"
  app.properties: |
    db.host=postgres.svc
    db.port=5432
```

```bash
kubectl apply -f configmap.yaml
```

Note the `app.properties` key: keys can contain multi-line file content (e.g. `nginx.conf`, `application.yaml`) using the YAML block scalar syntax (`|`).

### Ingesting ConfigMaps as Environment Variables

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod
spec:
  containers:
  - name: app
    image: nginx:1.27
    env:
    - name: APP_MODE          # Individual key mapping
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_MODE
    envFrom:
    - configMapRef:            # Ingest all keys as env vars
        name: app-config
```

With `envFrom`, every key in the ConfigMap automatically translates into a container environment variable sharing the exact key name. Keys containing invalid variable names are skipped and recorded as events.

### Mounting ConfigMaps as Volumes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod-vol
spec:
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
  volumes:
  - name: config-volume
    configMap:
      name: app-config
```

Each ConfigMap key maps to an individual file inside `/etc/config` (`/etc/config/APP_MODE`, `/etc/config/LOG_LEVEL`), with file contents matching key values. Restrict mounted items via `items`:

```yaml
  volumes:
  - name: config-volume
    configMap:
      name: app-config
      items:
      - key: app.properties
        path: application.properties
```

---

## Secrets

### Common Types

| Type | Purpose |
|---|---|
| `Opaque` | Default key-value data container |
| `kubernetes.io/dockerconfigjson` | Credentials for private container registry pulls |
| `kubernetes.io/tls` | TLS certificate and private key pairs |
| `kubernetes.io/basic-auth` | Basic authentication username/password pairs |
| `kubernetes.io/ssh-auth` | SSH private keys |
| `kubernetes.io/service-account-token` | ServiceAccount token credentials |

### Imperative Creation

```bash
kubectl create secret generic db-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cr3tP@ss'

# Secret for private registry pulls
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=user \
  --docker-password=pass \
  --docker-email=user@example.com

# TLS Secret
kubectl create secret tls web-tls \
  --cert=tls.crt --key=tls.key
```

### Declarative Creation

Data values in `data` blocks must be `base64` encoded:

```bash
echo -n 'admin' | base64        # YWRtaW4=
echo -n 'S3cr3tP@ss' | base64   # UzNjcjN0UEBzcw==
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  DB_USER: YWRtaW4=
  DB_PASSWORD: UzNjcjN0UEBzcw==
```

Alternative: Use `stringData` to write plain-text values; API servers automatically convert entries to base64 upon object persistence.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
stringData:
  DB_USER: admin
  DB_PASSWORD: S3cr3tP@ss
```

### Consuming Secrets

Matches ConfigMap patterns, substituting `configMapKeyRef`/`configMapRef`/`configMap` with `secretKeyRef`/`secretRef`/`secret`:

```yaml
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_PASSWORD
    envFrom:
    - secretRef:
        name: db-secret
```

```yaml
  volumes:
  - name: secret-volume
    secret:
      secretName: db-secret
      defaultMode: 0400        # Mounted file permissions
```

Private container image pull Secrets are referenced at the Pod spec level:

```yaml
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - name: app
    image: registry.example.com/app:1.0
```

### Verification

```bash
kubectl get secret db-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# S3cr3tP@ss
```

`kubectl describe secret` suppresses secret values (reporting byte lengths only) to prevent accidental data leaks.

---

## Configuration Update Behavior

- **As environment variables**: Values are injected during container startup. Post-creation edits to ConfigMaps/Secrets do not update running container processes until Pods are re-created (e.g. rolling updates).
- **As mounted volumes**: The kubelet periodically syncs volume contents (controlled by `--sync-frequency`, default ~1 minute) and updates target files **without restarting Pods**. Applications must support file watching to reload updated configurations automatically.
- **`subPath` mounts**: ConfigMap or Secret files mounted via `subPath` do not receive automatic update syncs.

## `immutable: true`

ConfigMaps and Secrets support setting `immutable: true`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
immutable: true
data:
  APP_MODE: production
```

Prevents accidental edits, reduces API server load (disables background watch syncs), and mandates versioning resource names (`app-config-v2`) on updates.

---

## Exam Tips

- Leverage `kubectl create configmap|secret ... --dry-run=client -o yaml > file.yaml` to generate base YAML manifests quickly.
- Remember `kubectl edit secret <name>` displays base64 values, not plain text.
- Secrets do not encrypt data at rest out of the box; etcd encryption at rest requires configuring `EncryptionConfiguration` on API servers.
- If a key referenced in `configMapKeyRef`/`secretKeyRef` is missing without `optional: true`, Pod creation fails with `CreateContainerConfigError`.

---

## References

- Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- ConfigMaps: https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Managing Secrets using kubectl: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Define Environment Variables for a Container: https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Pull an Image from a Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
