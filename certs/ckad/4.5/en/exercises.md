# Guided Exercises — CKAD 4.5: Understand ConfigMaps

**Certification:** CKAD v1.35 · **Domain:** 4. Application Environment, Configuration and Security · **Topic:** 4.5 Understand ConfigMaps · **Weight:** 3

**Reference Source:** [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with configured `kubectl` (minikube, kind, or similar) and permissions to create resources in a dedicated namespace.

---

## Block 1 — Creating ConfigMaps from Various Sources

1. Create a working namespace to isolate resources:

   ```bash
   kubectl create namespace ckad-cm
   kubectl config set-context --current --namespace=ckad-cm
   ```

2. Create a ConfigMap from literal `key=value` pairs:

   ```bash
   kubectl create configmap app-config \
     --from-literal=APP_COLOR=blue \
     --from-literal=APP_MODE=production
   ```

3. Inspect generated object:

   ```bash
   kubectl get configmap app-config -o yaml
   ```

   Notice both keys are grouped under `data:` as independent key-value entries.

4. Create a local properties file:

   ```bash
   cat <<EOF > game.properties
   enemies=aliens
   lives=3
   EOF
   ```

5. Generate a ConfigMap from that file:

   ```bash
   kubectl create configmap game-config --from-file=game.properties
   kubectl describe configmap game-config
   ```

6. Repeat previous step forcing custom key naming (instead of default filename):

   ```bash
   kubectl create configmap game-config-2 \
     --from-file=game-conf=game.properties
   kubectl get configmap game-config-2 -o yaml
   ```

7. Create a ConfigMap from an "env file" (`KEY=value` per line format, unquoted and unspaced around `=`):

   ```bash
   cat <<EOF > app.env
   LOG_LEVEL=debug
   MAX_CONNECTIONS=100
   EOF

   kubectl create configmap env-config --from-env-file=app.env
   kubectl get configmap env-config -o yaml
   ```

**Comprehension Questions — Block 1**

1. What structural difference exists between ConfigMap created with `--from-file=game.properties` (step 5) vs `--from-env-file=app.env` (step 7)?
2. In step 6, what does syntax `--from-file=game-conf=game.properties` control?
3. If you needed a ConfigMap containing an entire `nginx.conf` file as a single text block under a single key, would you use `--from-literal`, `--from-file`, or `--from-env-file`?

---

## Block 2 — Consuming ConfigMaps as Environment Variables

1. Create a Pod referencing a specific key from `app-config` ConfigMap as an individual environment variable:

   ```yaml
   # pod-env-single.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-env-single
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "printenv COLOR && sleep 3600"]
         env:
           - name: COLOR
             valueFrom:
               configMapKeyRef:
                 name: app-config
                 key: APP_COLOR
   ```

   ```bash
   kubectl apply -f pod-env-single.yaml
   kubectl logs pod-env-single
   ```

2. Create a second Pod importing **all** ConfigMap keys at once via `envFrom`:

   ```yaml
   # pod-envfrom.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-envfrom
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "printenv | sort && sleep 3600"]
         envFrom:
           - configMapRef:
               name: app-config
   ```

   ```bash
   kubectl apply -f pod-envfrom.yaml
   kubectl exec pod-envfrom -- printenv | grep APP_
   ```

3. Modify `pod-env-single.yaml` to reference a non-existent key (e.g. `APP_TIMEOUT`) and re-apply under a different Pod name. Observe resulting status:

   ```bash
   kubectl apply -f pod-env-single.yaml
   kubectl get pod pod-env-single
   kubectl describe pod pod-env-single
   ```

4. Add `optional: true` to `configMapKeyRef` for that non-existent key and re-apply. Verify Pod starts successfully (with variable undefined).

**Comprehension Questions — Block 2**

1. What status and reason did `kubectl describe pod` display in step 3 prior to adding `optional: true`?
2. What practical advantage does `envFrom` offer over declaring each variable with `env` + `configMapKeyRef` when ConfigMap contains numerous keys?
3. If a ConfigMap key is named `app.mode` (containing a dot) and imported via `envFrom`, what happens to that entry when converted into a shell environment variable?

---

## Block 3 — Consuming ConfigMaps as Volumes

1. Create a Pod mounting `game-config` completely as a volume:

   ```yaml
   # pod-vol.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-vol
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: config-volume
             mountPath: /etc/config
     volumes:
       - name: config-volume
         configMap:
           name: game-config
   ```

   ```bash
   kubectl apply -f pod-vol.yaml
   kubectl exec pod-vol -- ls /etc/config
   kubectl exec pod-vol -- cat /etc/config/game.properties
   ```

2. Modify volume projection to include only a specific key projected under a different filename using `items`:

   ```yaml
   volumes:
     - name: config-volume
       configMap:
         name: game-config
         items:
           - key: game.properties
             path: game-settings.conf
   ```

   Re-apply and confirm `/etc/config` contains exclusively `game-settings.conf`.

3. Change `mountPath` to a container directory with pre-existing content (e.g. `/etc`) and observe pre-existing files.

4. Revert `mountPath` back to `/etc/config` and use `subPath` to mount a single key as a standalone file inside an existing directory without hiding existing contents:

   ```yaml
   volumeMounts:
     - name: config-volume
       mountPath: /etc/config/game.properties
       subPath: game.properties
   ```

**Comprehension Questions — Block 3**

1. In step 3, what happened to pre-existing contents of mounted directory?
2. What practical difference exists between using `items` (step 2) vs `subPath` (step 4) when projecting a single ConfigMap key?
3. Why is `subPath` recommended when injecting a single configuration file into a directory already containing image files (e.g. `/etc/nginx/conf.d/`)?

---

## Block 4 — Updating ConfigMaps and Observing Change Propagation

1. With `pod-vol.yaml` running (full volume, without `items` or `subPath`), edit ConfigMap:

   ```bash
   kubectl edit configmap game-config
   # change lives=3 to lives=5 and save
   ```

2. Wait ~1 minute (kubelet periodically synchronizes volume-mounted ConfigMaps) and re-read file inside Pod:

   ```bash
   kubectl exec pod-vol -- cat /etc/config/game.properties
   ```

3. Repeat change and check Pod consuming ConfigMap as environment variables (`pod-envfrom`):

   ```bash
   kubectl exec pod-envfrom -- printenv | grep APP_
   ```

4. Delete and recreate that Pod (or perform `kubectl rollout restart deployment/<name>` if managed by Deployment) and confirm updated value is picked up.

**Comprehension Questions — Block 4**

1. Why did file at `/etc/config/game.properties` update live without restarting Pod, whereas environment variables did not?
2. If volume was mounted using `subPath` (as in end of Block 3), does file update live like in step 2? Justify.
3. What common strategy (even if not native Kubernetes mechanism) do teams employ to force Pod rollouts on Deployments when ConfigMap consumed via env vars changes?

---

## Block 5 — Immutable ConfigMaps

1. Create an immutable ConfigMap:

   ```yaml
   # cm-immutable.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: static-config
   data:
     RELEASE: "1.0.0"
   immutable: true
   ```

   ```bash
   kubectl apply -f cm-immutable.yaml
   ```

2. Attempt modifying an existing value:

   ```bash
   kubectl patch configmap static-config \
     --type merge -p '{"data":{"RELEASE":"1.0.1"}}'
   ```

3. Observe returned error. Create a new versioned ConfigMap instead (`static-config-v2`) and update references in Pod/Deployment manifests.

**Comprehension Questions — Block 5**

1. What general error message does API server return on step 2 attempt?
2. What two concrete benefits does marking ConfigMaps `immutable: true` offer in large clusters?
3. What is recommended pattern for "updating" immutable ConfigMaps without violating immutability?

---

<details>
<summary><strong>View Answers</strong></summary>

**Block 1**

1. `--from-file=game.properties` creates **a single key** named `game.properties` whose value is entire raw file content. `--from-env-file=app.env` **parses** file line by line (`KEY=value`) generating **one key per line** (`LOG_LEVEL`, `MAX_CONNECTIONS`), identically to using multiple `--from-literal` flags.
2. Controls **key name** under which file contents are stored: instead of default filename (`game.properties`), key becomes `game-conf`.
3. `--from-file`, because it preserves whole file as single text blob under one key (typically filename), suitable for volume mounting.

**Block 2**

1. `CreateContainerConfigError`, because kubelet cannot construct container environment due to missing `APP_TIMEOUT` key referenced in `configMapKeyRef`.
2. Avoids declaring individual `env` entries for every key: all ConfigMap keys inject automatically as environment variables using key names.
3. Kubernetes **silently skips** entry (variable is not generated) because `app.mode` is invalid shell environment variable identifier (contains period); kubelet emits warning event while remaining valid variables inject normally.

**Block 3**

1. Pre-existing directory contents became **hidden**: mounting ConfigMap volume over existing path replaces directory view with volume content (standard Linux volume mount behavior).
2. `items` projects selected key as **sole file inside dedicated directory** (directory contains only listed items), whereas `subPath` mounts key as specific file **inside existing directory containing other files**, without masking pre-existing contents.
3. Because `subPath` injects a single file without masking pre-existing image files in target directory (e.g. default Nginx `.conf` files), avoiding breaking base image defaults.

**Block 4**

1. Kubelet periodically synchronizes ConfigMap volume contents (sync loop updates files live without restarting Pod). Environment variables resolve **once** at container creation time and never re-evaluate during container lifecycle.
2. **No**: with `subPath`, kubelet does not automatically update mounted file when ConfigMap changes because projected volume sync mechanism does not apply to `subPath` mounts. Recreating Pod is required.
3. Teams embed a **content hash/checksum annotation** of ConfigMap inside Deployment `template` spec (e.g. via Helm) or execute `kubectl rollout restart deployment/<name>`, triggering rolling update on ConfigMap changes.

**Block 5**

1. Error stating `data` (or `binaryData`) field is immutable (`field is immutable when immutable is set`), causing `kubectl patch` to fail.
2. First, **reduces `kube-apiserver` load** by eliminating kubelet watches on ConfigMaps. Second, **prevents accidental modifications** to critical application settings.
3. Create a **new versioned ConfigMap** (e.g. `static-config-v2`) and update references (`configMapKeyRef`, `configMapRef`, or `volumes.configMap.name`) in consuming manifests, triggering controlled Pod rollouts.

</details>
