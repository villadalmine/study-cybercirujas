# Guided Exercises — 4.6 Create & consume Secrets

> **Prerequisites:** A working Kubernetes cluster (minikube, kind, or similar) and `kubectl` configured. Work in a clean namespace:
>
> ```bash
> kubectl create namespace secrets-lab
> kubectl config set-context --current --namespace=secrets-lab
> ```

---

## Exercise 1 — Create a Secret Imperatively

The fastest method on the exam is `kubectl create secret`. An `Opaque` (generic) Secret is created via the `generic` subcommand.

1. Create a Secret with two keys passed as literals:

   ```bash
   kubectl create secret generic db-creds \
     --from-literal=DB_USER=admin \
     --from-literal=DB_PASS='S3cr3t!'
   ```

2. List Secrets in the namespace and check type and key count:

   ```bash
   kubectl get secrets
   ```

3. Inspect Secret details:

   ```bash
   kubectl describe secret db-creds
   kubectl get secret db-creds -o yaml
   ```

4. Notice `describe` displays only key **size in bytes**, whereas `get -o yaml` displays values encoded in **base64**. Decode a value:

   ```bash
   kubectl get secret db-creds -o jsonpath='{.data.DB_PASS}' | base64 -d; echo
   ```

**Comprehension Questions:**

- **1.a)** Why does `kubectl describe secret` hide values while `kubectl get -o yaml` exposes them?
- **1.b)** Is base64 an encryption mechanism? What does this imply regarding who can read a Secret?

---

## Exercise 2 — Create a Secret from Files

When values represent full file contents (SSH key, TLS certificate, configuration file), `--from-file` is preferred.

1. Create two local files:

   ```bash
   echo -n 'admin' > ./username.txt
   echo -n 'S3cr3t!' > ./password.txt
   ```

   (The `-n` prevents a trailing newline character that could break authentication.)

2. Create Secret from files:

   ```bash
   kubectl create secret generic file-creds \
     --from-file=./username.txt \
     --from-file=pass=./password.txt
   ```

3. Verify key names created inside Secret:

   ```bash
   kubectl describe secret file-creds
   ```

**Comprehension Questions:**

- **2.a)** What key name did each file receive inside Secret? Why are they different?
- **2.b)** If `password.txt` were created with `echo 'S3cr3t!'` (omitting `-n`), what would the Secret key contain?

---

## Exercise 3 — Declarative Secrets: `data` vs `stringData`

In a YAML manifest, two fields can store values: `data` (base64-encoded values) or `stringData` (plaintext values encoded by API server automatically).

1. Base64-encode a value manually:

   ```bash
   echo -n 'api-token-123' | base64
   ```

2. Create `secret-declarativo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-secret
   type: Opaque
   data:
     API_TOKEN: YXBpLXRva2VuLTEyMw==
   stringData:
     ENVIRONMENT: production
   ```

3. Apply manifest and verify **both** keys end up encoded under `data`:

   ```bash
   kubectl apply -f secret-declarativo.yaml
   kubectl get secret app-secret -o yaml
   ```

4. Exam tip: generate manifest without writing by hand using `--dry-run`:

   ```bash
   kubectl create secret generic app-secret2 \
     --from-literal=KEY=value \
     --dry-run=client -o yaml > secret2.yaml
   ```

**Comprehension Questions:**

- **3.a)** What practical advantage does `stringData` offer over `data` when writing manifests by hand?
- **3.b)** If the same key appears in both `data` and `stringData`, which value takes precedence?

---

## Exercise 4 — Consuming Secrets as Environment Variables

Two mechanisms exist: key-by-key via `secretKeyRef`, or all keys at once via `envFrom`.

1. Create `pod-env.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-env
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "env | grep -E 'DB_|API_|ENVIRONMENT' && sleep 3600"]
       env:
       - name: DB_USER
         valueFrom:
           secretKeyRef:
             name: db-creds
             key: DB_USER
       envFrom:
       - secretRef:
           name: app-secret
   ```

2. Apply and inspect logs:

   ```bash
   kubectl apply -f pod-env.yaml
   kubectl logs pod-env
   ```

   You should see `DB_USER`, `API_TOKEN`, and `ENVIRONMENT` values in plaintext.

3. Modify Secret and check if Pod detects changes:

   ```bash
   kubectl patch secret db-creds -p '{"stringData":{"DB_USER":"nuevo-admin"}}'
   kubectl exec pod-env -- sh -c 'echo $DB_USER'
   ```

**Comprehension Questions:**

- **4.a)** After `patch`, does container see `admin` or `nuevo-admin`? Why?
- **4.b)** What happens if Pod references a non-existent key using `secretKeyRef`? How is this avoided using `optional`?
- **4.c)** What is the difference between `envFrom.secretRef` and `env[].valueFrom.secretKeyRef` regarding environment variable naming control?

---

## Exercise 5 — Consuming Secrets as Mounted Volumes

When mounted as a volume, each key becomes a file inside container filesystem.

1. Create `pod-vol.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-vol
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sleep", "3600"]
       volumeMounts:
       - name: creds
         mountPath: /etc/creds
         readOnly: true
     volumes:
     - name: creds
       secret:
         secretName: db-creds
         defaultMode: 0400
   ```

2. Apply and inspect volume content:

   ```bash
   kubectl apply -f pod-vol.yaml
   kubectl exec pod-vol -- ls -l /etc/creds
   kubectl exec pod-vol -- cat /etc/creds/DB_PASS; echo
   ```

3. Update Secret and wait (~1 minute):

   ```bash
   kubectl patch secret db-creds -p '{"stringData":{"DB_PASS":"rotated!"}}'
   sleep 70
   kubectl exec pod-vol -- cat /etc/creds/DB_PASS; echo
   ```

4. Variant using `items` to mount **only one key** under custom filename — replace `volumes` section with:

   ```yaml
   volumes:
   - name: creds
     secret:
       secretName: db-creds
       items:
       - key: DB_PASS
         path: db/password.txt
   ```

**Comprehension Questions:**

- **5.a)** Unlike environment variables, what happened to mounted file when Secret was rotated?
- **5.b)** What effect does `defaultMode: 0400` have and why is it a security best practice?
- **5.c)** With `items` variant, what full path contains the password inside container?

---

## Exercise 6 — Specialized Secret Types: `docker-registry` and `tls`

Besides `generic`, `kubectl create secret` provides subcommands for frequent use cases.

1. Create a Secret for private registry authentication:

   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=deployer \
     --docker-password='p4ss' \
     --docker-email=deployer@example.com
   ```

2. Inspect type and key:

   ```bash
   kubectl get secret regcred -o yaml
   ```

3. Attach Secret to a Pod via `imagePullSecrets`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-privado
   spec:
     imagePullSecrets:
     - name: regcred
     containers:
     - name: app
       image: registry.example.com/team/app:1.0
   ```

4. Create a TLS Secret from self-signed certificate:

   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 \
     -keyout tls.key -out tls.crt -days 1 -subj "/CN=demo.local"
   kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key
   kubectl describe secret demo-tls
   ```

**Comprehension Questions:**

- **6.a)** What `type` does `regcred` Secret have and what key does it contain?
- **6.b)** Where is `imagePullSecrets` specified: inside container or in Pod `spec`?
- **6.c)** Which two keys are mandatory for a Secret of type `kubernetes.io/tls`?

---

## Exercise 7 — Immutable Secrets

Marking a Secret as `immutable` prevents accidental modifications and reduces API server load (kubelet stops watching for updates).

1. Mark `app-secret` as immutable:

   ```bash
   kubectl patch secret app-secret -p '{"immutable": true}'
   ```

2. Attempt modifying existing value:

   ```bash
   kubectl patch secret app-secret -p '{"stringData":{"ENVIRONMENT":"staging"}}'
   ```

3. Read error message carefully.

**Comprehension Questions:**

- **7.a)** What single operation remains available to "change" an immutable Secret?
- **7.b)** Can an immutable Secret be reverted to mutable via another `patch`?

---

## Teardown

```bash
kubectl delete namespace secrets-lab
kubectl config set-context --current --namespace=default
rm -f username.txt password.txt tls.key tls.crt secret-declarativo.yaml secret2.yaml pod-env.yaml pod-vol.yaml
```

---

<details>
<summary><strong>Answers</strong></summary>

**1.a)** `describe` intentionally hides values to prevent screen exposure (displays key byte sizes only). `get -o yaml` returns complete object as stored in API, including base64 `data`. Anyone with `get` permissions on Secrets can read values.

**1.b)** No: base64 is **encoding**, not encryption — reversed using `base64 -d` without keys. Secret access must be restricted via RBAC, and real protection at rest requires configuring *encryption at rest* in etcd.

**2.a)** `username.txt` (filename, no key specified) and `pass` (custom key specified via `--from-file=pass=./password.txt`).

**2.b)** Would contain `S3cr3t!\n` — password plus trailing newline. Common error: application authentication fails with seemingly identical passwords.

**3.a)** `stringData` allows writing plaintext values; Kubernetes base64-encodes them automatically, avoiding manual encoding errors.

**3.b)** `stringData` takes precedence: if same key is present in both fields, `stringData` value overrides `data`.

**4.a)** Displays `admin`. Environment variables resolve **once at container startup**; modifying Secret does not update them. Pod recreation (or Deployment rollout) is required to pick up changes.

**4.b)** Container fails at startup (`CreateContainerConfigError`). Prevented by setting `optional: true` in `secretKeyRef`: variable is omitted if Secret or key is missing.

**4.c)** `envFrom.secretRef` injects **all** Secret keys as environment variables using original key names. `secretKeyRef` injects a single key allowing custom environment variable naming.

**5.a)** File **updated live**: `secret` volume mounts refresh automatically (synchronized periodically by kubelet). Key difference from environment variables. Exception: `subPath` mounts do not update live.

**5.b)** Restricts permissions to `r--------` (read-only by owner). Reduces risk of unauthorized container processes reading credentials. Specified in YAML as octal (`0400`) or decimal (`256`).

**5.c)** `/etc/creds/db/password.txt`: `mountPath` (`/etc/creds`) plus item `path` (`db/password.txt`). Only specified key is mounted.

**6.a)** Type `kubernetes.io/dockerconfigjson`, containing single key `.dockerconfigjson` holding base64-encoded Docker credentials JSON.

**6.b)** In Pod `spec`, alongside `containers`. Applies to all images pulled by Pod. Can also be bound to a ServiceAccount to apply across all Pods using it.

**6.c)** `tls.crt` (certificate) and `tls.key` (private key). `kubectl create secret tls` generates them from `--cert` and `--key`.

**7.a)** Delete and recreate (`kubectl delete` + `kubectl create/apply`). Consuming Pods must be recreated to consume new content.

**7.b)** No. Once `immutable: true` is set, field cannot be reverted and data cannot be modified. Only deletion of Secret is permitted.

</details>
