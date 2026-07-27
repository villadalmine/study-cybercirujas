# Guided Exercises — 3.2 Use ConfigMaps and Secrets to configure applications

> Reference: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with `kubectl` configured.

```bash
kubectl create namespace cm-secrets-lab
kubectl config set-context --current --namespace=cm-secrets-lab
```

---

## Exercise 1 — Create a ConfigMap from Literals

1. Create a ConfigMap with two key-value pairs using `--from-literal`:

```bash
kubectl create configmap app-config \
  --from-literal=APP_COLOR=blue \
  --from-literal=APP_MODE=production
```

2. Inspect created object:

```bash
kubectl get configmap app-config -o yaml
kubectl describe configmap app-config
```

### Questions

1. Which YAML manifest key stores key-value pairs in a ConfigMap?
2. Can a ConfigMap store binary data directly? If not, which field is used?

---

## Exercise 2 — Create a ConfigMap from a File

1. Generate a local properties file:

```bash
cat <<EOF > app.properties
LOG_LEVEL=debug
MAX_CONNECTIONS=100
EOF
```

2. Create ConfigMap from file:

```bash
kubectl create configmap app-config-file --from-file=app.properties
```

3. Inspect generated key name inside ConfigMap:

```bash
kubectl get configmap app-config-file -o jsonpath='{.data}'
```

4. Re-create specifying a custom key name:

```bash
kubectl create configmap app-config-file-2 --from-file=custom-key=app.properties
```

### Questions

3. Which default key name does Kubernetes assign when creating ConfigMaps via `--from-file=app.properties` without explicit keys?
4. What practical distinction separates `--from-file` targeting a single file vs a directory?

---

## Exercise 3 — Consume ConfigMap as Individual Environment Variables

1. Manifest a Pod consuming specific keys from `app-config` via `env`:

```yaml
# pod-env-single.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-env-single
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "env | grep APP_ && sleep 3600"]
    env:
    - name: APP_COLOR
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_COLOR
```

2. Apply manifest and inspect container logs:

```bash
kubectl apply -f pod-env-single.yaml
kubectl logs pod-env-single
```

### Questions

5. If key `APP_COLOR` is missing from ConfigMap `app-config`, what happens to Pod startup?

---

## Exercise 4 — Bulk Environment Variables via `envFrom`

1. Update Pod manifest to ingest **all** keys from `app-config` using `envFrom`:

```yaml
# pod-envfrom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-envfrom
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "env | sort && sleep 3600"]
    envFrom:
    - configMapRef:
        name: app-config
      prefix: CFG_
```

2. Apply and verify prefixed variables:

```bash
kubectl apply -f pod-envfrom.yaml
kubectl logs pod-envfrom | grep CFG_
```

### Questions

6. What occurs if multiple `envFrom` sources define overlapping keys?
7. What function does `prefix` perform inside `envFrom`?

---

## Exercise 5 — Mount ConfigMap as a Volume

1. Manifest a Pod mounting `app-config-file` as a read-only volume:

```yaml
# pod-cm-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-cm-volume
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
      readOnly: true
  volumes:
  - name: config-vol
    configMap:
      name: app-config-file
```

2. Apply manifest and inspect mounted file paths:

```bash
kubectl apply -f pod-cm-volume.yaml
kubectl exec pod-cm-volume -- ls /etc/config
kubectl exec pod-cm-volume -- cat /etc/config/app.properties
```

### Questions

8. How does each ConfigMap key map inside the mounted directory?
9. Which volume field projects only specific keys rather than all keys?

---

## Exercise 6 — Create a Generic Secret

1. Create a `generic` Secret with credentials:

```bash
kubectl create secret generic db-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cr3tP@ss'
```

2. Inspect storage formatting:

```bash
kubectl get secret db-secret -o yaml
```

3. Decode values manually:

```bash
kubectl get secret db-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
echo
```

### Questions

10. Are values in `data` blocks encrypted or base64 encoded?
11. What cluster configurations protect Secrets in `etcd`?

---

## Exercise 7 — Consume Secrets as Environment Variables

1. Manifest a Pod injecting `DB_PASSWORD` via `secretKeyRef`:

```yaml
# pod-secret-env.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-env
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo DB_PASSWORD=$DB_PASSWORD && sleep 3600"]
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_PASSWORD
```

2. Apply and verify:

```bash
kubectl apply -f pod-secret-env.yaml
kubectl logs pod-secret-env
```

### Questions

12. Why are environment variables considered more vulnerable to exposure than mounted volume files?

---

## Exercise 8 — Mount Secrets as Volumes

1. Manifest a Pod mounting `db-secret` as a restricted volume:

```yaml
# pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-volume
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: secret-vol
      mountPath: /etc/secret
      readOnly: true
  volumes:
  - name: secret-vol
    secret:
      secretName: db-secret
      defaultMode: 0400
```

2. Apply and verify file permissions:

```bash
kubectl apply -f pod-secret-volume.yaml
kubectl exec pod-secret-volume -- ls -l /etc/secret
kubectl exec pod-secret-volume -- cat /etc/secret/DB_USER
```

### Questions

13. What file permission mode does `0400` represent in octal notation?

---

## Exercise 9 — Configuration Update Propagation

1. Patch key values in ConfigMap `app-config-file`:

```bash
kubectl patch configmap app-config-file \
  --type merge \
  -p '{"data":{"app.properties":"LOG_LEVEL=info\nMAX_CONNECTIONS=200\n"}}'
```

2. Inspect mounted file contents in `pod-cm-volume`:

```bash
kubectl exec pod-cm-volume -- cat /etc/config/app.properties
```

3. Inspect environment variables in `pod-envfrom`:

```bash
kubectl exec pod-envfrom -- env | grep CFG_LOG_LEVEL
```

### Questions

14. Why do mounted volume files receive updates while environment variables remain stale?
15. Do `subPath` mounted volume files receive automatic updates?

---

## Exercise 10 — Immutable ConfigMaps and Secrets

1. Manifest an immutable ConfigMap:

```yaml
# cm-immutable.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-immutable
data:
  APP_VERSION: "1.0.0"
immutable: true
```

```bash
kubectl apply -f cm-immutable.yaml
```

2. Attempt key modifications:

```bash
kubectl patch configmap app-config-immutable \
  --type merge -p '{"data":{"APP_VERSION":"2.0.0"}}'
```

3. Observe API server error responses.

### Questions

16. What operational benefits does `immutable: true` provide in large clusters?
17. What workflow updates applications consuming immutable ConfigMaps?

---

## Teardown

```bash
kubectl delete namespace cm-secrets-lab
```

---

<details>
<summary>View Answers</summary>

1. Stored under the `data` map (or `binaryData` for base64 encoded binary files).
2. Binary data uses `binaryData` with base64 values.
3. Default key name matches the source filename (`app.properties`).
4. Individual files map filenames to keys. Directory paths import each file as separate keys.
5. Pod startup fails with `CreateContainerConfigError`.
6. Later sources in `envFrom` arrays override earlier duplicate keys.
7. `prefix` prepends strings to all imported environment variable names.
8. Each key maps to an individual file containing key values.
9. Use `configMap.items` specifying `key` and `path`.
10. Base64 encoded only (not encrypted).
11. Enable API server **encryption at rest**, restrict etcd access, and use strict RBAC.
12. Environment variables appear in process environment dumps and `kubectl describe` outputs.
13. Read-only permissions for file owner (`0400`).
14. Kubelet background sync updates mounted volume files. Environment variables evaluate once at container startup.
15. No. `subPath` mounted files do not receive automatic updates.
16. Prevents accidental edits and reduces API server watch traffic overhead.
17. Create a new versioned ConfigMap resource and update Pod references.

</details>
