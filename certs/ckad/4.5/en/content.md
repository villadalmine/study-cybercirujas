# 4.5 Understand ConfigMaps

## What is a ConfigMap?

A **ConfigMap** is a Kubernetes API object that decouples application configuration from the container image running it. Instead of hardcoding values such as service URLs, feature flags, log levels, or configuration files inside the container image, they are externalized into a ConfigMap and injected into the Pod at runtime.

A ConfigMap stores `key: value` pairs as plain text (non-binary). **It is not intended for sensitive data** — for sensitive data, use the `Secret` object (Topic 4.6), which shares a similar usage model with additional security measures (though unencrypted at rest by default without extra configuration).

Key points evaluated in the exam:
- Creating ConfigMaps imperatively and declaratively.
- Consuming ConfigMaps as **environment variables** or **mounted volume files**.
- Understanding what happens when a ConfigMap currently in use by a Pod is updated.

## Creating ConfigMaps

### Imperative Creation

```bash
# From key=value literals
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=debug \
  --from-literal=GREETING="hello world"

# From a file (filename becomes the key)
echo "color.background=blue" > ui.properties
kubectl create configmap ui-config --from-file=ui.properties

# From a file with an explicit key name
kubectl create configmap ui-config --from-file=custom_key=ui.properties

# From an entire directory (one key per file)
kubectl create configmap ui-config --from-file=./config-dir/

# From an env-file (KEY=VALUE per line, unquoted)
cat <<EOF > app.env
LOG_LEVEL=debug
GREETING=hello world
EOF
kubectl create configmap app-config --from-env-file=app.env
```

### Declarative Creation

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "debug"
  GREETING: "hello world"
  app.properties: |
    max.connections=100
    timeout=30s
```

```bash
kubectl apply -f app-config.yaml
```

### Inspecting ConfigMaps

```bash
kubectl get configmaps
```

```
NAME               DATA   AGE
app-config         3      12s
kube-root-ca.crt   1      4d
```

```bash
kubectl describe configmap app-config
```

```
Name:         app-config
Namespace:    default
Labels:       <none>
Annotations:  <none>

Data
====
LOG_LEVEL:
----
debug
GREETING:
----
hello world
app.properties:
----
max.connections=100
timeout=30s

BinaryData
====

Events:  <none>
```

## Consuming ConfigMaps in a Pod

### As Individual Environment Variables

Target a specific key using `env.valueFrom.configMapKeyRef`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: envvar-pod
spec:
  containers:
  - name: app
    image: nginx
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
```

### All Keys as Environment Variables

With `envFrom`, all keys from the ConfigMap are injected at once; each key becomes an environment variable name:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: envfrom-pod
spec:
  containers:
  - name: app
    image: nginx
    envFrom:
    - configMapRef:
        name: app-config
```

```bash
kubectl exec envfrom-pod -- env | grep -E 'LOG_LEVEL|GREETING'
```

```
LOG_LEVEL=debug
GREETING=hello world
```

> Note: `envFrom` only works for keys with valid environment variable names (alphanumeric and `_`). Invalid keys are skipped and Kubernetes generates a `Warning` event (`InvalidVariableNames`).

### As Mounted Files (Volume)

Recommended when the application expects a configuration file (e.g. `app.properties`, `nginx.conf`) instead of environment variables:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: volume-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
  volumes:
  - name: config-vol
    configMap:
      name: app-config
```

Each key in the ConfigMap appears as a file inside `/etc/config`, containing the key's value as file content:

```bash
kubectl exec volume-pod -- ls /etc/config
```

```
GREETING
LOG_LEVEL
app.properties
```

```bash
kubectl exec volume-pod -- cat /etc/config/app.properties
```

```
max.connections=100
timeout=30s
```

### Mounting a Single Key via `subPath`

When you need only a specific file without overriding the target directory:

```yaml
    volumeMounts:
    - name: config-vol
      mountPath: /etc/nginx/nginx.conf
      subPath: nginx.conf
```

> Important: Using `subPath` prevents the file from **automatically updating** when the ConfigMap changes (unlike full directory volume mounts). This subtle difference is often tested in exams.

### Projecting Specific Keys in Volume

You can filter and rename projected keys:

```yaml
  volumes:
  - name: config-vol
    configMap:
      name: app-config
      items:
      - key: app.properties
        path: application.properties
```

## Updating ConfigMaps and Change Propagation

```bash
kubectl edit configmap app-config
# or
kubectl create configmap app-config --from-literal=LOG_LEVEL=info --dry-run=client -o yaml | kubectl apply -f -
```

Propagation rules to keep in mind:

| Consumption Method | Hot Updated? |
|---|---|
| Environment variables (`env` / `envFrom`) | **No.** Pod must be restarted (container recreated) to receive updated values. |
| Mounted volume (entire directory) | **Yes.** Kubelet periodically synchronizes mounted files (default ~1 minute, based on kubelet `sync period`), though the application inside must support hot-reloading file changes. |
| Volume with `subPath` | **No.** File remains pinned to its value at mount time. |

A common pattern to trigger a rollout on config changes is embedding a hash of the ConfigMap as a annotation/label in the Deployment `template`, so changes automatically trigger a new Pod rollout.

### `immutable: true`

Since Kubernetes 1.21, ConfigMaps support `immutable: true`, preventing subsequent modifications. Used for configurations that should never change during object lifetime, improving `kube-apiserver` performance (prevents kubelet watch overhead) and avoiding accidental updates:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "debug"
immutable: true
```

To modify an immutable ConfigMap's values, create a new ConfigMap (e.g. version/hash suffix) and update references in Pod/Deployment manifests.

## Limits and Best Practices

- A ConfigMap has a total size limit of **1 MiB** (enforced by `etcd`).
- If a key referenced in `configMapKeyRef` does not exist, the Pod enters `CreateContainerConfigError` state unless marked `optional: true`.
- For large configuration files or binary data, consider persistent volumes or `initContainers` instead of ConfigMaps.
- Use versioned ConfigMap names (or `immutable: true`) in production for predictable rollbacks alongside Deployment updates.

## References

- ConfigMaps official documentation: https://kubernetes.io/docs/concepts/configuration/configmap/
- Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- `kubectl create configmap` CLI reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-configmap
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
