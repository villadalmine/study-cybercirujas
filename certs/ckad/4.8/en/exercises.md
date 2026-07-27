# Topic 4.8 — Application Security: SecurityContext and Capabilities (CKAD v1.35)

> Reference Source: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf) — domain *Application Environment, Configuration and Security*, item "Understand Application security (SecurityContexts, Capabilities, etc.)".

Prerequisites: A working cluster with configured `kubectl` (`kind`, `minikube`, or similar) and permissions to create Pods. All exercises use `ckad-sec` namespace.

```bash
kubectl create namespace ckad-sec
kubectl config set-context --current --namespace=ckad-sec
```

---

## Exercise 1 — Pod-Level `securityContext`: `runAsUser`, `runAsGroup`, `fsGroup`

1. Create `pod-level-sc.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-level-sc
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  volumes:
    - name: data
      emptyDir: {}
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
```

2. Apply manifest and wait for `Running` state:

```bash
kubectl apply -f pod-level-sc.yaml
kubectl wait --for=condition=Ready pod/pod-level-sc --timeout=60s
```

3. Verify process identity inside container:

```bash
kubectl exec pod-level-sc -- id
```

4. Verify volume group ownership:

```bash
kubectl exec pod-level-sc -- ls -ld /data
```

### Comprehension Questions

1. Why does process run as UID 1000 and GID 3000 even though `busybox` image specifies no `USER` in Dockerfile?
2. What is the difference between `runAsGroup` and `fsGroup`, and which determines `/data` group ownership?

---

## Exercise 2 — Container-Level `securityContext`: Overriding Pod Settings

1. Modify previous manifest to add a second container overriding inherited `runAsUser`, saving as `container-level-sc.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: container-level-sc
spec:
  securityContext:
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: default-user
      image: busybox:1.36
      command: ["sleep", "3600"]
    - name: overridden-user
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 4000
```

2. Apply manifest:

```bash
kubectl apply -f container-level-sc.yaml
kubectl wait --for=condition=Ready pod/container-level-sc --timeout=60s
```

3. Compare effective UID per container:

```bash
kubectl exec container-level-sc -c default-user -- id -u
kubectl exec container-level-sc -c overridden-user -- id -u
```

### Comprehension Questions

1. Which Kubernetes precedence rule explains why `overridden-user` runs as UID 4000 instead of inheriting 1000 from Pod?
2. Can Pod-level `fsGroup` be overridden at Container level? Why?

---

## Exercise 3 — `runAsNonRoot`: Blocking Root Container Execution

1. Create `nonroot-fail.yaml` using default root image without setting `runAsUser`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nonroot-fail
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: nginx:1.27
```

2. Apply manifest and observe Pod status:

```bash
kubectl apply -f nonroot-fail.yaml
kubectl get pod nonroot-fail
kubectl describe pod nonroot-fail | tail -n 15
```

3. Fix issue by adding `runAsUser: 101` (unprivileged UID used by official `nginx` image):

```bash
kubectl delete pod nonroot-fail
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nonroot-fail
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
  containers:
    - name: app
      image: nginx:1.27
```

4. Reapply and confirm startup:

```bash
kubectl apply -f nonroot-fail.yaml
kubectl get pod nonroot-fail
```

### Comprehension Questions

1. Which `status.containerStatuses[].state` and `reason` is reported for step 2 Pod, and how does `kubectl get pod` output reflect it?
2. Why is declaring `runAsNonRoot: true` without `runAsUser` insufficient to guarantee a specific non-root UID?

---

## Exercise 4 — Linux Capabilities: Selective `drop: [ALL]` + `add`

1. Create `cap-fail.yaml`: non-root container attempting to listen on privileged port 80 (<1024) without extra capabilities:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cap-fail
spec:
  securityContext:
    runAsUser: 1000
  containers:
    - name: app
      image: busybox:1.36
      command: ["nc", "-l", "-p", "80"]
      securityContext:
        capabilities:
          drop: ["ALL"]
```

2. Apply and inspect logs:

```bash
kubectl apply -f cap-fail.yaml
kubectl logs cap-fail
```

3. Add required capability in `cap-fixed.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cap-fixed
spec:
  securityContext:
    runAsUser: 1000
  containers:
    - name: app
      image: busybox:1.36
      command: ["nc", "-l", "-p", "80"]
      securityContext:
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
```

4. Apply and confirm process listens cleanly:

```bash
kubectl apply -f cap-fixed.yaml
kubectl logs cap-fixed
kubectl get pod cap-fixed
```

### Comprehension Questions

1. Why can a non-root process (UID 1000) bind port 80 after adding `NET_BIND_SERVICE` without being root?
2. What security benefit does `drop: ["ALL"]` provide before adding specific capabilities over accepting container runtime defaults?

---

## Exercise 5 — `privileged: true` Scope

1. Create `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

2. Apply and wait for readiness:

```bash
kubectl apply -f privileged-pod.yaml
kubectl wait --for=condition=Ready pod/privileged-pod --timeout=60s
```

3. List host block devices from container (visible under privileged mode):

```bash
kubectl exec privileged-pod -- ls /dev
```

4. Compare with `cap-fail` Pod (non-privileged) trying same command:

```bash
kubectl exec cap-fail -- ls /dev 2>&1 || true
```

### Comprehension Questions

1. What does `privileged: true` grant that adding individual capabilities (e.g. `SYS_ADMIN`) does not?
2. In a cluster enforcing `restricted` Pod Security Admission mode, what happens when applying `privileged-pod.yaml`?

---

## Exercise 6 — `readOnlyRootFilesystem` and `allowPrivilegeEscalation`

1. Create `readonly-fail.yaml`: container with read-only root filesystem attempting write to `/tmp`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-fail
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hello > /tmp/test.txt && sleep 3600"]
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
```

2. Apply and observe failure:

```bash
kubectl apply -f readonly-fail.yaml
kubectl get pod readonly-fail
kubectl logs readonly-fail
```

3. Fix by mounting `emptyDir` at `/tmp` to provide a writable directory, in `readonly-fixed.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-fixed
spec:
  volumes:
    - name: tmp
      emptyDir: {}
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hello > /tmp/test.txt && sleep 3600"]
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: tmp
          mountPath: /tmp
```

4. Apply and confirm successful write:

```bash
kubectl apply -f readonly-fixed.yaml
kubectl wait --for=condition=Ready pod/readonly-fixed --timeout=60s
kubectl exec readonly-fixed -- cat /tmp/test.txt
```

### Comprehension Questions

1. Why does `readonly-fail.yaml` container fail, and how does mounting volume at `/tmp` resolve it without disabling `readOnlyRootFilesystem`?
2. What kernel behavior does `allowPrivilegeEscalation: false` block (`setuid`/`setgid` binaries, `no_new_privs` flag)?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
1. `securityContext.runAsUser`/`runAsGroup` at Pod level forces runtime process UID/GID regardless of image `USER` settings.
2. `runAsGroup` sets process primary GID. `fsGroup` is a supplementary GID applied by Kubernetes to mounted volumes (changing volume file group ownership via recursive ownership updates), enabling process read/write access. `/data` group ownership is governed by `fsGroup` (2000), not `runAsGroup`.

**Exercise 2**
1. Container-level `securityContext` settings override Pod-level settings per container; non-repeated fields inherit from Pod. `overridden-user` takes `runAsUser: 4000`.
2. No, `fsGroup` is exclusively a `PodSecurityContext` field governing shared volumes across all Pod containers.

**Exercise 3**
1. Container enters `waiting` state with `reason: CreateContainerConfigError` (process never starts), displayed as `Status: CreateContainerConfigError` in `kubectl get pod`.
2. `runAsNonRoot: true` validates that effective UID is non-zero, but without `runAsUser` specified, kubelet checks image `USER`. If image `USER` is root, validation fails.

**Exercise 4**
1. Binding ports <1024 requires Linux capability `CAP_NET_BIND_SERVICE` rather than root UID 0. Adding `NET_BIND_SERVICE` permits binding unprivileged non-root processes.
2. Follows least privilege principles: drops default runtime capabilities (`CHOWN`, `SETUID`, `SETGID`, `NET_RAW`), enabling only explicitly required capabilities and reducing attack surface.

**Exercise 5**
1. `privileged: true` disables container security isolation: grants all Linux capabilities, disables default seccomp/AppArmor profiles, and permits access to host devices (`/dev`). Individual capabilities broaden specific operations while preserving remaining isolation barriers.
2. Pod Security Admission in `restricted` mode rejects Pod creation (`privileged: true` is explicitly forbidden).

**Exercise 6**
1. `readOnlyRootFilesystem: true` mounts container root filesystem as read-only. Writing to `/tmp` fails with "Read-only file system". Mounting `emptyDir` at `/tmp` provides a writable mount point isolated from root filesystem.
2. `allowPrivilegeEscalation: false` sets kernel flag `no_new_privs`, preventing processes (and children) from gaining elevated privileges via `setuid`/`setgid` binaries (e.g., `sudo`, `su`).

</details>
