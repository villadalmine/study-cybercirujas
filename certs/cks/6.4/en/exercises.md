# CKS 6.4 — Ensure Immutability of Containers at Runtime
## Guided Exercises (exam version 1.34 · domain weight 4%)

> **What "immutability" means in the CKS context.** A container is immutable when its filesystem cannot be modified after it starts, when nothing can be added to it that was not in the image, and when the image itself cannot change under a stable reference. In practice this is four independent controls, and the exam tests all four:
> 1. `securityContext.readOnlyRootFilesystem: true` — the container layer is mounted `ro`.
> 2. Explicit writable surfaces only (`emptyDir`, `tmpfs`) at the paths the process genuinely needs.
> 3. A minimal image (no shell, no package manager, non-root UID baked in).
> 4. Admission-time enforcement so the above cannot be omitted, plus digest pinning so the tag cannot be swapped underneath you.

### Prerequisites

- A cluster on **v1.34** (`kubeadm` or `kind`), `kubectl` as `cluster-admin`.
- Root SSH on at least one worker node, with `crictl` and `jq` available (needed in Exercises 4 and 8).
- Outbound access to `docker.io` and `registry.k8s.io`.

```bash
kubectl version --short
# Client Version: v1.34.0
# Server Version: v1.34.0

kubectl create namespace immutability-lab
kubectl config set-context --current --namespace=immutability-lab
```

---

## Exercise 1 — Establish the baseline: how much damage a mutable container allows

1. Create a deliberately unhardened Pod:

```yaml
# 01-mutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mutable-app
  namespace: immutability-lab
spec:
  containers:
    - name: app
      image: nginx:1.27
      ports:
        - containerPort: 80
```

```bash
kubectl apply -f 01-mutable.yaml
kubectl wait --for=condition=Ready pod/mutable-app --timeout=60s
```

2. Confirm the identity the process runs under:

```bash
kubectl exec mutable-app -- id
# uid=0(root) gid=0(root) groups=0(root)
```

3. Deface the served content — a write into the image's own layer:

```bash
kubectl exec mutable-app -- sh -c \
  'echo "<h1>compromised</h1>" > /usr/share/nginx/html/index.html'
kubectl exec mutable-app -- cat /usr/share/nginx/html/index.html
# <h1>compromised</h1>
```

4. Plant an executable that was never part of the image, and run it:

```bash
kubectl exec mutable-app -- sh -c 'cp /bin/sh /usr/local/bin/backdoor && chmod 4755 /usr/local/bin/backdoor'
kubectl exec mutable-app -- ls -l /usr/local/bin/backdoor
# -rwsr-xr-x 1 root root 125688 Aug  5 10:04 /usr/local/bin/backdoor
kubectl exec mutable-app -- /usr/local/bin/backdoor -c 'id'
# uid=0(root) gid=0(root) groups=0(root)
```

5. Confirm the image ships a package manager, i.e. an attacker can pull arbitrary tooling:

```bash
kubectl exec mutable-app -- sh -c 'command -v apt-get; command -v curl; command -v sh'
# /usr/bin/apt-get
# /usr/bin/curl
# /bin/sh
```

6. Prove that the modification is *not* visible to the API server — the Pod spec is unchanged:

```bash
kubectl get pod mutable-app -o jsonpath='{.spec.containers[0].image}{"\n"}'
# nginx:1.27
```

**Check your understanding**

- **Q1.** The container's filesystem now differs from the image it claims to run. Which Kubernetes object records that drift, and what does that tell you about detecting this class of attack with `kubectl` alone?
- **Q2.** If this Pod is part of a Deployment with 3 replicas and the attacker modifies only one Pod, what makes the compromise both harder to spot and self-healing from the attacker's point of view?
- **Q3.** Step 4 set the setuid bit. Under what circumstance does that actually help the attacker inside a container, and which `securityContext` field neutralises it independently of `readOnlyRootFilesystem`?

---

## Exercise 2 — Turn on `readOnlyRootFilesystem` and diagnose the fallout

Real applications write somewhere. The exam skill is not "set the flag", it is "set the flag, read the crash, and mount exactly the paths needed".

1. Apply the naïve hardened version:

```yaml
# 02-readonly-broken.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      securityContext:
        readOnlyRootFilesystem: true
```

```bash
kubectl apply -f 02-readonly-broken.yaml
kubectl get pod immutable-web -w
# NAME            READY   STATUS             RESTARTS   AGE
# immutable-web   0/1     Error              0          4s
# immutable-web   0/1     CrashLoopBackOff   1          6s
```

2. Read the actual failure — not `describe`, the container log:

```bash
kubectl logs immutable-web
```
```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: /etc/nginx/conf.d/default.conf is not a file or does not exist
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/08/05 10:11:58 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
```

3. Note the *exit reason* recorded by the kubelet, which is what `describe` gives you:

```bash
kubectl describe pod immutable-web | sed -n '/Last State/,/Ready/p'
# Last State:     Terminated
#   Reason:       Error
#   Exit Code:    1
```

4. Enumerate what the process needs. `errno 30` is `EROFS`; the log names one path, but nginx also needs a PID file. Confirm from the image itself before guessing:

```bash
kubectl run nginx-probe --rm -it --restart=Never --image=nginx:1.27 \
  --command -- grep -E '^(pid|user)' /etc/nginx/nginx.conf
# user  nginx;
# pid        /var/run/nginx.pid;
```

5. Mount exactly those two paths as `emptyDir`, and take the opportunity to drop capabilities:

```yaml
# 03-readonly-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - name: nginx-cache
          mountPath: /var/cache/nginx
        - name: nginx-run
          mountPath: /var/run
  volumes:
    - name: nginx-cache
      emptyDir: {}
    - name: nginx-run
      emptyDir: {}
```

```bash
kubectl delete pod immutable-web --now
kubectl apply -f 03-readonly-fixed.yaml
kubectl wait --for=condition=Ready pod/immutable-web --timeout=60s
kubectl logs immutable-web | tail -1
# /docker-entrypoint.sh: Configuration complete; ready for start up
```

6. Re-run the Exercise 1 attacks against it:

```bash
kubectl exec immutable-web -- sh -c 'echo x > /usr/share/nginx/html/index.html'
# sh: 1: cannot create /usr/share/nginx/html/index.html: Read-only file system
# command terminated with exit code 2

kubectl exec immutable-web -- sh -c 'cp /bin/sh /usr/local/bin/backdoor'
# cp: cannot create regular file '/usr/local/bin/backdoor': Read-only file system
# command terminated with exit code 1
```

7. Now find the hole you just created yourself:

```bash
kubectl exec immutable-web -- sh -c 'cp /bin/sh /var/cache/nginx/backdoor && /var/cache/nginx/backdoor -c id'
# uid=0(root) gid=0(root) groups=0(root)
```

**Check your understanding**

- **Q4.** `kubectl describe` reported only `Exit Code: 1`. Why did the root cause appear only in `kubectl logs`, and what is the general rule for diagnosing a `readOnlyRootFilesystem` regression?
- **Q5.** In step 5 you dropped `ALL` capabilities and added four back. Why does this specific image still need `SETUID`, `SETGID` and `CHOWN` even though the container starts as root?
- **Q6.** Step 7 executed a shell copied into an `emptyDir`. Does `readOnlyRootFilesystem: true` apply to mounted volumes? What would you have to change to make that path non-executable, and why can't you do it with `emptyDir` alone?
- **Q7.** The `10-listen-on-ipv6-by-default.sh` entrypoint script logged an informational message instead of failing. What does that tell you about how well-built images handle a read-only root, and what would you check in a home-grown image before enabling the flag?

---

## Exercise 3 — Combine immutability with non-root and a full restricted profile

Read-only alone still leaves you running as UID 0. Production hardening is the combination.

1. Try to run the *unprivileged* nginx variant, which listens on 8080 and writes its PID under `/tmp`:

```yaml
# 04-nonroot-immutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web-nonroot
  namespace: immutability-lab
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    fsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: nginxinc/nginx-unprivileged:1.27-alpine
      ports:
        - containerPort: 8080
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
    - name: tmp
      emptyDir: {}
```

```bash
kubectl apply -f 04-nonroot-immutable.yaml
kubectl wait --for=condition=Ready pod/immutable-web-nonroot --timeout=60s
kubectl exec immutable-web-nonroot -- id
# uid=101(nginx) gid=101(nginx) groups=101(nginx)
```

2. Verify the service actually answers on 8080:

```bash
kubectl run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w '%{http_code}\n' http://immutable-web-nonroot.immutability-lab.pod.cluster.local:8080
```
*(simpler alternative if DNS for Pod FQDNs is not configured)*
```bash
kubectl port-forward pod/immutable-web-nonroot 8080:8080 >/dev/null 2>&1 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080
# 200
kill %1
```

3. Prove that privilege escalation is blocked even if a setuid binary existed:

```bash
kubectl exec immutable-web-nonroot -- cat /proc/self/status | grep -E 'NoNewPrivs|CapEff|CapBnd'
# CapBnd: 0000000000000000
# CapEff: 0000000000000000
# NoNewPrivs:     1
```

4. Contrast with the root-based Pod from Exercise 2:

```bash
kubectl exec immutable-web -- cat /proc/self/status | grep -E 'NoNewPrivs|CapEff'
# CapEff: 0000000000000400
# NoNewPrivs:     0
```

**Check your understanding**

- **Q8.** `CapEff: 0000000000000400` — which capability is that, and why is it the only one left effective even though you added four in the manifest?
- **Q9.** In step 3, `NoNewPrivs: 1` appears. Which field sets it, and what would still be possible if you set `readOnlyRootFilesystem: true` but left `allowPrivilegeEscalation` unset?
- **Q10.** Why did switching to `nginxinc/nginx-unprivileged` also let you drop `NET_BIND_SERVICE`? What is the general principle for the exam when a task says "run as non-root and keep the service reachable"?
- **Q11.** `runAsNonRoot: true` and `runAsUser: 101` are both set. What happens at admission and at startup if the image's `USER` is `root` and you set only `runAsNonRoot: true`? What is the exact error?

---

## Exercise 4 — Verify immutability from inside the container and from the node

An exam task may ask you to *prove* a container is immutable, not just to write the YAML.

1. From inside — the root mount's options:

```bash
kubectl exec immutable-web -- head -1 /proc/mounts
# overlay / overlay ro,relatime,lowerdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/... 0 0
```

2. From inside — which paths are still writable:

```bash
kubectl exec immutable-web -- sh -c "grep -E ' (rw|ro),' /proc/mounts | awk '{print \$2, \$4}' | cut -d, -f1"
# / ro
# /dev rw
# /dev/shm rw
# /var/cache/nginx rw
# /var/run rw
# /etc/hosts rw
# /dev/termination-log rw
# /etc/hostname rw
# /etc/resolv.conf rw
# /var/run/secrets/kubernetes.io/serviceaccount ro
```

3. Inspect `/dev/shm` specifically — a writable tmpfs the runtime always adds:

```bash
kubectl exec immutable-web -- sh -c 'grep /dev/shm /proc/mounts'
# shm /dev/shm tmpfs rw,nosuid,nodev,noexec,relatime,size=65536k 0 0
kubectl exec immutable-web -- sh -c 'cp /bin/sh /dev/shm/x && /dev/shm/x -c id'
# sh: 1: /dev/shm/x: Permission denied
```

4. From the node — locate the container and read the CRI security context:

```bash
# on the worker node
CID=$(sudo crictl ps --name nginx --pod $(sudo crictl pods --name immutable-web -q) -q)
sudo crictl inspect "$CID" | jq '.info.config.linux.security_context.readonly_rootfs'
# true
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.root.readonly'
# true
```

5. From the node — list every mount the runtime made read-write, which is the authoritative writable-surface inventory:

```bash
sudo crictl inspect "$CID" \
  | jq -r '.info.runtimeSpec.mounts[] | "\(.destination)\t\(.options | join(","))"' \
  | grep -v ',ro'
# /proc     nosuid,noexec,nodev,rprivate,rw
# /dev      nosuid,strictatime,rprivate,rw,mode=755,size=65536k
# /dev/shm  nosuid,noexec,nodev,rprivate,rw,mode=1777,size=65536k
# /var/cache/nginx  rbind,rprivate,rw
# /var/run          rbind,rprivate,rw
```

6. Confirm the running image by digest, not by tag:

```bash
kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
# docker.io/library/nginx@sha256:6b1daa0462fbd0d33e40d1e6b0b7f68a4b4b1b0f... (yours will differ)
```

**Check your understanding**

- **Q12.** Step 3 showed the copy into `/dev/shm` succeeded but execution failed with `Permission denied`. Which mount option caused that, and why is `/dev/shm` safer by default than your own `emptyDir` at `/tmp`?
- **Q13.** `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf` are mounted `rw` despite `readOnlyRootFilesystem: true`. Why does the kubelet do this, and does it represent a real exposure?
- **Q14.** Why is `.status.containerStatuses[].imageID` a stronger statement about what is running than `.spec.containers[].image`?
- **Q15.** You are given a node and told "one container in `kube-system` has a writable root filesystem — find it" with no `kubectl` access. Write the `crictl` + `jq` one-liner.

---

## Exercise 5 — Immutability at the image layer: no shell, no drift, pinned digest

1. Deploy a container built `FROM scratch` and try to get a shell:

```yaml
# 05-noshell.yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-shell
  namespace: immutability-lab
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 65535
        capabilities:
          drop: ["ALL"]
```

```bash
kubectl apply -f 05-noshell.yaml
kubectl wait --for=condition=Ready pod/no-shell --timeout=60s
kubectl exec -it no-shell -- /bin/sh
```
```
error: Internal error occurred: error executing command in container: failed to exec in container:
failed to start exec "e0b1...": OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

2. Confirm the same for a distroless image, and inspect it without executing anything:

```bash
kubectl run distroless --restart=Never --image=gcr.io/distroless/static-debian12:nonroot \
  --command -- /nonexistent
kubectl describe pod distroless | grep -A2 'Last State'
# Last State:  Terminated
#   Reason:    StartError
```

3. Observe how you *do* debug such a Pod — an ephemeral container with its own image:

```bash
kubectl debug -it no-shell --image=busybox:1.36 --target=pause -- sh
# / # ls /proc/1/root 2>/dev/null || echo "cannot traverse target rootfs"
# / # exit
```

4. Now address tag mutability. Resolve the tag to a digest:

```bash
kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}' \
  | cut -d@ -f2
# sha256:6b1daa0462fbd0d33e40d1e6b0b7f68a4b4b1b0f...   (yours will differ)
```

5. Pin it. Replace the tag reference with a digest reference and note that `imagePullPolicy` becomes irrelevant to correctness:

```bash
DIGEST=$(kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}' | cut -d@ -f2)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pinned-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx@${DIGEST}
      imagePullPolicy: IfNotPresent
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - { name: cache, mountPath: /var/cache/nginx }
        - { name: run,   mountPath: /var/run }
  volumes:
    - { name: cache, emptyDir: {} }
    - { name: run,   emptyDir: {} }
EOF
kubectl wait --for=condition=Ready pod/pinned-web --timeout=90s
```

6. Show that a digest reference is self-verifying by breaking it:

```bash
kubectl run bad-digest --restart=Never \
  --image=nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000
kubectl describe pod bad-digest | grep -E 'Failed|Error' | head -2
# Warning  Failed  ...  Failed to pull image "nginx@sha256:0000...": failed to resolve reference: not found
# Warning  Failed  ...  Error: ErrImagePull
```

**Check your understanding**

- **Q16.** `kubectl exec` failed on the `pause` Pod. Does removing the shell prevent an attacker who already achieved RCE inside the process from doing damage? What class of attacker does it actually stop?
- **Q17.** In step 3 you attached a `busybox` ephemeral container. Explain precisely why this is a hole in your immutability story, and which two Kubernetes controls close it.
- **Q18.** With `image: nginx:1.27` and `imagePullPolicy: IfNotPresent`, describe the concrete attack in which two Pods of the same Deployment run different code. Why does a digest reference make `IfNotPresent` safe again?
- **Q19.** `imagePullPolicy: Always` is often proposed as the fix for tag mutability. Name one security property it *does* provide that `IfNotPresent` does not, and one reason it is still not a substitute for digest pinning.

---

## Exercise 6 — Enforce it: PSA is not enough, so write a ValidatingAdmissionPolicy

1. Create a namespace enforcing the `restricted` Pod Security Standard:

```bash
kubectl create namespace psa-restricted
kubectl label namespace psa-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34
```

2. Verify that `restricted` rejects an unhardened Pod:

```bash
kubectl -n psa-restricted run rejected --image=nginx:1.27
```
```
Error from server (Forbidden): pods "rejected" is forbidden: violates PodSecurity "restricted:v1.34":
allowPrivilegeEscalation != false (container "rejected" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "rejected" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "rejected" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "rejected" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

3. Now submit a Pod that is fully `restricted`-compliant but has a **writable** root filesystem:

```yaml
# 06-psa-gap.yaml
apiVersion: v1
kind: Pod
metadata:
  name: psa-passes-but-mutable
  namespace: psa-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

```bash
kubectl apply -f 06-psa-gap.yaml
# pod/psa-passes-but-mutable created            <-- ADMITTED

kubectl -n psa-restricted exec psa-passes-but-mutable -- \
  sh -c 'cp /bin/busybox /tmp/payload && chmod +x /tmp/payload && /tmp/payload id'
# uid=1000 gid=0(root)
```

**This is the single most important fact in this topic: no Pod Security Standard level — not even `restricted` — requires `readOnlyRootFilesystem`.** You must add it yourself.

4. Close the gap with a `ValidatingAdmissionPolicy` (GA `admissionregistration.k8s.io/v1`):

```yaml
# 07-vap.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-immutable-rootfs
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "every container must set securityContext.readOnlyRootFilesystem: true"
      reason: Invalid
    - expression: >-
        !has(object.spec.initContainers) ||
        object.spec.initContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "every initContainer must set securityContext.readOnlyRootFilesystem: true"
      reason: Invalid
    - expression: >-
        object.spec.containers.all(c, c.image.contains('@sha256:'))
      message: "images must be pinned by digest (repo@sha256:...), not by tag"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-immutable-rootfs-binding
spec:
  policyName: require-immutable-rootfs
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        immutability: enforced
```

```bash
kubectl apply -f 07-vap.yaml
kubectl label namespace psa-restricted immutability=enforced
```

5. Re-test:

```bash
kubectl delete pod psa-passes-but-mutable -n psa-restricted --now
kubectl apply -f 06-psa-gap.yaml
```
```
Error from server (Forbidden): error when creating "06-psa-gap.yaml": pods "psa-passes-but-mutable"
is forbidden: ValidatingAdmissionPolicy 'require-immutable-rootfs' with binding
'require-immutable-rootfs-binding' denied request: every container must set
securityContext.readOnlyRootFilesystem: true
```

6. Now observe the trap: apply the same spec through a **Deployment**.

```bash
kubectl -n psa-restricted create deployment gap --image=busybox:1.36 -- sleep 3600
# deployment.apps/gap created                   <-- ACCEPTED

kubectl -n psa-restricted get deploy gap
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# gap    0/1     0            0           15s

kubectl -n psa-restricted describe rs -l app=gap | tail -4
# Events:
#   Type     Reason        Age   From                   Message
#   Warning  FailedCreate  12s   replicaset-controller  Error creating: pods "gap-7d9f5c8b6-" is forbidden:
#     ValidatingAdmissionPolicy 'require-immutable-rootfs' ... denied request: every container must set
#     securityContext.readOnlyRootFilesystem: true
```

7. Optional — check whether your cluster exposes the mutating counterpart, which could *inject* the field instead of rejecting:

```bash
kubectl api-resources | grep -i admissionpolicy
# validatingadmissionpolicies          admissionregistration.k8s.io/v1     false   ValidatingAdmissionPolicy
# validatingadmissionpolicybindings    admissionregistration.k8s.io/v1     false   ValidatingAdmissionPolicyBinding
# mutatingadmissionpolicies            admissionregistration.k8s.io/v1beta1 false  MutatingAdmissionPolicy
```

**Check your understanding**

- **Q20.** Name the four things `restricted` *does* enforce that relate to container integrity, and state explicitly what it does not enforce.
- **Q21.** In step 6 the Deployment was accepted but no Pod ran. Explain the mechanism, and say where an operator would actually see the error in a real incident.
- **Q22.** The binding uses `failurePolicy: Fail` on the policy. What breaks if a CEL expression in the policy is invalid at runtime, and how does that differ from `failurePolicy: Ignore`?
- **Q23.** Rewrite the first `expression` using CEL optional syntax so it is shorter, and explain why `has(c.securityContext)` is required before dereferencing the field.
- **Q24.** Your policy checks `c.image.contains('@sha256:')`. Give one image reference that passes this check but is still not what you intended, and tighten the expression.

---

## Exercise 7 — The ephemeral-container bypass and how to close it

1. With the policy from Exercise 6 active, try to attach a debug container to an existing compliant Pod:

```bash
kubectl label namespace immutability-lab immutability=enforced
kubectl debug -it pinned-web --image=busybox:1.36 --target=nginx -- sh
```

2. Observe whether it is admitted. The default `matchConstraints` above covers `pods` on `UPDATE`, but `kubectl debug` writes to the **`pods/ephemeralcontainers` subresource**:

```bash
kubectl get pod pinned-web -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
# debugger-8xk2j
kubectl exec pinned-web -c debugger-8xk2j -- sh -c 'cp /bin/busybox /payload && ls -l /payload'
# -rwxr-xr-x 1 root root 1153680 Aug  5 10:31 /payload
```

3. Extend the policy to cover the subresource and to validate ephemeral containers:

```yaml
# 08-vap-ephemeral.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-immutable-ephemeral
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["UPDATE"]
        resources:   ["pods/ephemeralcontainers"]
  validations:
    - expression: >-
        !has(object.spec.ephemeralContainers) ||
        object.spec.ephemeralContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "ephemeral containers must also set readOnlyRootFilesystem: true"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-immutable-ephemeral-binding
spec:
  policyName: require-immutable-ephemeral
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        immutability: enforced
```

```bash
kubectl apply -f 08-vap-ephemeral.yaml
kubectl delete pod pinned-web --now && kubectl apply -f - <<'EOF'
# (re-apply the pinned-web manifest from Exercise 5, step 5)
EOF
kubectl debug -it pinned-web --image=busybox:1.36 --target=nginx -- sh
```
```
error: ephemeralcontainers "pinned-web" is forbidden: ValidatingAdmissionPolicy
'require-immutable-ephemeral' with binding 'require-immutable-ephemeral-binding' denied request:
ephemeral containers must also set readOnlyRootFilesystem: true
```

4. Close the RBAC path as well — the durable control:

```bash
kubectl create clusterrole no-debug --verb=create,patch \
  --resource=pods/ephemeralcontainers --dry-run=client -o yaml
```
Then confirm which subjects currently hold it:
```bash
kubectl auth can-i update pods/ephemeralcontainers --as=system:serviceaccount:default:default
# no
kubectl auth can-i update pods/ephemeralcontainers
# yes
```

**Check your understanding**

- **Q25.** Why did the original policy in Exercise 6 not fire on `kubectl debug`, even though it matched `UPDATE` on `pods`?
- **Q26.** An ephemeral container cannot be removed once added. What operational consequence does that have for a cluster that enforces immutability, and how do you actually get rid of it?
- **Q27.** Between the VAP and the RBAC restriction on `pods/ephemeralcontainers`, which one would you deploy first in production, and why?

---

## Exercise 8 — Defence in depth: AppArmor as a second, kernel-level lock (node access required)

`readOnlyRootFilesystem` is enforced by the container runtime's mount. AppArmor is enforced by the LSM, independently.

1. On the worker node, verify AppArmor is active:

```bash
sudo aa-status | head -3
# apparmor module is loaded.
# 45 profiles are loaded.
# 42 profiles are in enforce mode.
```

2. Write a profile that denies writes to the image's own directories:

```bash
sudo tee /etc/apparmor.d/k8s-immutable >/dev/null <<'EOF'
#include <tunables/global>

profile k8s-immutable flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,

  # Nothing in the image may be modified.
  deny /bin/**        w,
  deny /sbin/**       w,
  deny /usr/**        w,
  deny /etc/**        w,
  deny /lib/**        w,

  # Nothing may be executed from the writable scratch volumes.
  deny /var/cache/nginx/** x,
  deny /tmp/**             x,
}
EOF

sudo apparmor_parser -q -r /etc/apparmor.d/k8s-immutable
sudo aa-status | grep k8s-immutable
#    k8s-immutable
```

3. Reference it from the Pod using the GA API field (v1.30+; the old `container.apparmor.security.beta.kubernetes.io/<name>` annotation is deprecated):

```yaml
# 09-apparmor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-immutable
  namespace: immutability-lab
spec:
  nodeName: <your-worker-node>
  containers:
    - name: nginx
      image: nginx:1.27
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-immutable
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - { name: cache, mountPath: /var/cache/nginx }
        - { name: run,   mountPath: /var/run }
  volumes:
    - { name: cache, emptyDir: {} }
    - { name: run,   emptyDir: {} }
```

```bash
kubectl apply -f 09-apparmor.yaml
kubectl wait --for=condition=Ready pod/apparmor-immutable --timeout=60s
kubectl exec apparmor-immutable -- cat /proc/self/attr/current
# k8s-immutable (enforce)
```

4. Verify that the hole from Exercise 2 step 7 is now closed:

```bash
kubectl exec apparmor-immutable -- sh -c 'cp /bin/sh /var/cache/nginx/backdoor && /var/cache/nginx/backdoor -c id'
# sh: 1: /var/cache/nginx/backdoor: Permission denied
# command terminated with exit code 126
```

5. Read the kernel's own record of the denial on the node:

```bash
sudo dmesg | grep -i 'apparmor="DENIED"' | tail -1
# audit: type=1400 ... apparmor="DENIED" operation="exec" profile="k8s-immutable"
#   name="/var/cache/nginx/backdoor" pid=41827 comm="sh" requested_mask="x" denied_mask="x"
```

6. Confirm the failure mode when the profile is missing on a node:

```bash
kubectl apply -f 09-apparmor.yaml   # against a node without the profile loaded
kubectl describe pod apparmor-immutable | grep -A1 'Reason:'
# Reason:  AppArmor
# Message: Cannot enforce AppArmor: profile "k8s-immutable" is not loaded
```

**Check your understanding**

- **Q28.** Give two things AppArmor enforces here that `readOnlyRootFilesystem` structurally cannot.
- **Q29.** Step 6 shows the Pod fails when the profile is absent. Why is this failure mode the *desired* one, and what does it imply about how you must roll out profiles across a node pool?
- **Q30.** The profile denies `x` on `/tmp/**`. What is the equivalent seccomp-based control, and why is seccomp the wrong tool for this particular requirement?

---

## Exercise 9 — Cluster-wide audit and cleanup

1. Find every container in the cluster without an immutable root filesystem:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | .metadata as $m
  | (.spec.containers + (.spec.initContainers // []) + (.spec.ephemeralContainers // []))[]
  | select((.securityContext.readOnlyRootFilesystem // false) != true)
  | "\($m.namespace)\t\($m.name)\t\(.name)"' \
  | column -t
# kube-system  coredns-668d6bf9bc-7lz9x  coredns
# kube-system  kube-proxy-2xq4p          kube-proxy
# default      legacy-api-7f6c4b8d9-mq2sv  api
```

2. The `jq`-free equivalent, useful when the exam terminal is bare:

```bash
kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,C:.spec.containers[*].name,ROFS:.spec.containers[*].securityContext.readOnlyRootFilesystem' \
  | grep -E '<none>|false'
```

3. Find every container running from a mutable tag rather than a digest:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -v '@sha256:'
```

4. Run the policy in audit-only mode against the whole cluster before enforcing it anywhere — change the binding and read the annotations from the audit log:

```bash
kubectl patch validatingadmissionpolicybinding require-immutable-rootfs-binding \
  --type=merge -p '{"spec":{"validationActions":["Audit","Warn"],"matchResources":{"namespaceSelector":{}}}}'
kubectl -n default run probe --image=nginx:1.27
# Warning: ValidatingAdmissionPolicy 'require-immutable-rootfs' ... every container must set
#   securityContext.readOnlyRootFilesystem: true
# pod/probe created
```

5. Tear down:

```bash
kubectl delete validatingadmissionpolicybinding require-immutable-rootfs-binding require-immutable-ephemeral-binding
kubectl delete validatingadmissionpolicy require-immutable-rootfs require-immutable-ephemeral
kubectl delete namespace immutability-lab psa-restricted --wait=false
kubectl config set-context --current --namespace=default
# on the node, if Exercise 8 was done:
sudo apparmor_parser -R /etc/apparmor.d/k8s-immutable && sudo rm /etc/apparmor.d/k8s-immutable
```

**Check your understanding**

- **Q31.** Step 1's `jq` filter uses `// false`. What real-world case does that handle, and what would the query miss without it?
- **Q32.** Step 4 used `["Audit","Warn"]`. Describe the rollout sequence you would use to introduce a `readOnlyRootFilesystem` requirement into a live cluster with 400 workloads, and name the signal you would watch at each stage.

---

## Reference sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Restrict a Container's Access to Resources with AppArmor* — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes, *Images* (pull policy, digests) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Volumes — emptyDir* — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Kubernetes, *Debug Running Pods — Ephemeral Containers* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Kubernetes, *Security Checklist* — https://kubernetes.io/docs/concepts/security/security-checklist/
- GoogleContainerTools, *distroless* — https://github.com/GoogleContainerTools/distroless

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** None. The container's writable layer lives entirely on the node, in the runtime's overlayfs `upperdir`; the API server stores only the desired spec. `kubectl get/describe` will report a healthy, `Running`, unmodified Pod forever. Detecting this class of attack requires either a runtime agent watching filesystem syscalls (Falco `write_below_binary_dir` / `Write below etc` rules), node-side comparison of the overlay upper layer against the image, or — far cheaper — removing the possibility entirely with `readOnlyRootFilesystem`. This asymmetry is the whole argument for immutability: prevention is nearly free, detection is not.

**Q2.** Load balancing means only ~1 in 3 requests hits the compromised replica, so intermittent symptoms get dismissed as flakiness. And it is "self-healing" in the wrong direction for the defender: the drift disappears the moment that Pod restarts or is rescheduled, taking the forensic evidence with it, while the attacker's actual persistence lives elsewhere (a mutated image, a compromised CI pipeline, a `CronJob`). A Pod-level compromise that vanishes on restart is a *symptom*; treat the ephemeral artefact as evidence, not as the root cause.

**Q3.** Setuid only helps if the process is running as a **non-root** user and the binary is owned by root — then executing it elevates to UID 0. Here the container was already root, so it changes nothing; it matters for the non-root hardened Pods. `allowPrivilegeEscalation: false` neutralises it by setting the `no_new_privs` process flag, which makes the kernel ignore setuid/setgid bits and file capabilities on `execve()` for that process and all its descendants — independently of whether the root filesystem is writable.

**Q4.** `describe` shows the kubelet's view: the container exited with status 1. The kubelet has no insight into *why* a process exited — that reasoning lives in the process's own stderr, which is the container log. The rule: for `readOnlyRootFilesystem` regressions, always `kubectl logs <pod> --previous` (needed once the Pod is in `CrashLoopBackOff`, since the current container may not have started yet) and grep for `EROFS` / `Read-only file system` / `errno 30`. `describe` is only useful for the *scheduling and image* class of failure; log output is the only source for the *startup* class.

**Q5.** The nginx master process starts as root to bind port 80, then forks workers that it drops to the `nginx` user — that fork-and-drop requires `SETUID` and `SETGID`. `CHOWN` is needed because the master adjusts ownership of the log and temp paths for those workers. Being UID 0 is not sufficient: the capability *bounding set* is what the kernel actually consults, and `drop: ["ALL"]` empties it, so a root process loses `setuid(2)` just as a non-root one would. This is exactly why `runAsUser: 0` and "has capabilities" are orthogonal concepts.

**Q6.** No — `readOnlyRootFilesystem` applies **only to the container's own root layer**. Every `volumeMount` has its own mount and its own read-write semantics; `emptyDir` is read-write by definition. You can make an individual mount read-only with `volumeMounts[].readOnly: true`, but that defeats the purpose here (nginx must write to its cache). To make it *writable but not executable* you need a `noexec` mount option, and `emptyDir` does not expose mount options — that requires a CSI driver supporting `mountOptions`, or a kernel-level control such as the AppArmor `deny /var/cache/nginx/** x` rule used in Exercise 8. **Design implication:** every writable path you add is a candidate drop zone; add as few as possible and keep them out of `$PATH`.

**Q7.** Well-built images probe writability (`[ ! -w "$file" ]`) and degrade gracefully rather than aborting. The nginx entrypoint does exactly this for the IPv6 script — hence the informational message instead of a crash. For a home-grown image, before enabling the flag: run it locally with `docker run --read-only` (or `podman run --read-only`), exercise a full request cycle, and inventory every `EROFS`; alternatively `strace -f -e trace=open,openat,mkdir -P ...` and look for write-mode opens outside your intended volumes. Do this in staging, not by iterating on CrashLoopBackOff in the cluster.

**Q8.** `0x400` = bit 10 = **`CAP_NET_BIND_SERVICE`**. It is the only one *effective* because the effective set is computed after the process has already started and dropped what it no longer needs — nginx's master retains only what it still uses at steady state. `CAP_SETUID`/`CAP_SETGID`/`CAP_CHOWN` were needed during startup (fork workers, fix ownership) and have been released by the time you read `/proc/self/status`. Note also that the `kubectl exec` shell inherits the container's *bounding* set, so comparing `CapBnd` between the two Pods is the more reliable check of what the manifest actually granted.

**Q9.** `allowPrivilegeEscalation: false` sets `no_new_privs`. Without it, a read-only root filesystem still lets an attacker execute a setuid-root binary that was **baked into the image** — and Debian/Alpine base images ship several (`/usr/bin/passwd`, `/bin/su`, `/usr/bin/mount`, `/usr/bin/newgrp`). Immutability prevents *planting* a new escalation vector; it does nothing about the ones already in the image. The two controls are complementary, which is why `restricted` mandates the second and every serious baseline mandates both.

**Q10.** `nginxinc/nginx-unprivileged` is built to listen on **8080** (>1024), and only ports below 1024 require `CAP_NET_BIND_SERVICE` on Linux. The general exam principle: do not try to bend a root-designed image into a non-root one by adding capabilities and rewriting file ownership — **pick or build an image designed for the constraint**, then expose the real port via the Service's `targetPort` so nothing downstream changes. `Service.port: 80 → targetPort: 8080` keeps the contract stable while the Pod stays unprivileged.

**Q11.** With only `runAsNonRoot: true` and an image whose `USER` is root, the Pod is **admitted** — the API server cannot inspect image metadata — and then fails at container start. The kubelet resolves the image's configured UID, sees 0, and refuses:
```
Error: container has runAsNonRoot and image will run as root
```
with the Pod entering `CreateContainerConfigError`. This is a favourite exam scenario: the fix is to add an explicit `runAsUser: <non-zero>` (which overrides the image), or to use an image with a non-root `USER`. Setting `runAsUser` alone without `runAsNonRoot` is weaker, because a later manifest edit or an admission mutation could set it back to 0 unchallenged.

**Q12.** `noexec`, which the container runtime applies to `/dev/shm` unconditionally (along with `nosuid,nodev`). Your own `emptyDir` at `/tmp` gets none of those options — Kubernetes mounts it as an ordinary bind mount, read-write and executable. So an `emptyDir` at `/tmp` is strictly more dangerous than the runtime-provided `/dev/shm`, and "I set `readOnlyRootFilesystem` and mounted an `emptyDir` at `/tmp`" restores an executable, writable, world-known path. If the workload only needs scratch *data*, that is fine; if `$PATH` or any interpreter can reach it, it is a drop zone.

**Q13.** The kubelet manages those three files itself: it injects the Pod's DNS configuration, hostname, and `hostAliases` entries at container creation, and must be able to update `/etc/hosts` for the Pod's lifetime. They are individual file bind mounts, so they are not covered by the read-only root layer. The exposure is real but narrow: an attacker with write access inside the container can poison the container's own name resolution (`/etc/resolv.conf`, `/etc/hosts`) to redirect its outbound traffic. It does not give code execution and does not affect other Pods; mitigate with AppArmor (`deny /etc/** w`) or by not granting `exec` in the first place.

**Q14.** `.spec.containers[].image` is the *request* — a mutable, human-supplied string like `nginx:1.27` that says what the author asked for. `.status.containerStatuses[].imageID` is the *fact* — the content-addressable digest of the image the runtime actually unpacked and started, as reported by CRI. If someone repushed the `1.27` tag, or a node had a stale cached layer under `IfNotPresent`, only the `imageID` reveals it. During an incident, comparing `imageID` across all replicas of a Deployment is the fastest way to spot node-level image drift.

**Q15.**
```bash
for c in $(sudo crictl ps -q); do
  sudo crictl inspect "$c" | jq -r \
    'select(.info.config.linux.security_context.readonly_rootfs != true)
     | "\(.status.labels["io.kubernetes.pod.namespace"])/\(.status.labels["io.kubernetes.pod.name"]) \(.status.metadata.name)"'
done | grep '^kube-system/'
```
The pod namespace and name are carried as CRI labels (`io.kubernetes.pod.namespace`, `io.kubernetes.pod.name`), which is how you correlate node-side containers back to Kubernetes objects without the API server. `.info.runtimeSpec.root.readonly` is the equivalent field if you prefer to read the OCI spec directly.

**Q16.** It does not stop an attacker who already has code execution inside the process — they can call `execve` on anything present, allocate memory, open sockets, and read mounted Secrets, all without a shell. What it stops is the enormous class of attacks that *shell out*: command-injection payloads that assume `/bin/sh -c`, reverse shells from web-app RCEs, and — critically — an attacker with only `kubectl exec` permission, for whom no shell means no interactive foothold. It also collapses the post-exploitation tooling available (`curl`, `wget`, `apt`, `nc` all absent), which raises effort and forces noisier techniques. Treat it as a strong cost-imposition control, not a boundary.

**Q17.** An ephemeral container runs in the target Pod's namespaces (PID, network, and optionally the process namespace) but brings **its own image and its own fully writable root filesystem**. So `kubectl debug --image=busybox` hands the user a writable, tool-rich environment inside an otherwise immutable Pod, and with `--target` it can read `/proc/<pid>/root` and `/proc/<pid>/environ` of the hardened container. The two controls that close it: (1) RBAC — deny `create`/`update`/`patch` on the `pods/ephemeralcontainers` subresource to everyone but break-glass identities; (2) admission — a `ValidatingAdmissionPolicy` (or PSA, which does evaluate ephemeral containers for its own fields) matching `pods/ephemeralcontainers` and imposing the same security context requirements, as in Exercise 7.

**Q18.** Node A pulled `nginx:1.27` in March. In June the tag is repushed — legitimately by upstream, or maliciously after a registry credential compromise. Node B, scheduling a new replica today, has no cached copy and pulls the *new* content. With `imagePullPolicy: IfNotPresent`, node A never re-pulls, so the Deployment now runs two different code bases under one identical spec, with no field anywhere in the API that reveals it. A digest reference is content-addressed: `nginx@sha256:<d>` can only ever resolve to the bytes hashing to `<d>`, and the runtime verifies the hash after download. There is nothing to re-check, so `IfNotPresent` becomes not just safe but optimal — a cached layer matching the digest *is* the right image, by definition.

**Q19.** What `Always` provides: the kubelet contacts the registry on every container start, which means **`imagePullSecrets` are re-validated** — a Pod cannot keep running an image whose pull credentials have been revoked, and a user without registry access cannot start a Pod from a cached private image they were never entitled to. That authorization property is genuinely valuable and is why `Always` is recommended for multi-tenant clusters. Why it is not a substitute: `Always` still resolves a *mutable tag*, so it guarantees you get "whatever that tag points to right now" — which is precisely the attacker-controlled value in the repushed-tag scenario. It converts a stale-image risk into a fresh-malicious-image risk. Digest pinning plus `Always` gives you both properties.

**Q20.** `restricted` enforces, among others: `runAsNonRoot: true`; `allowPrivilegeEscalation: false`; `capabilities.drop: ["ALL"]` (with only `NET_BIND_SERVICE` addable); `seccompProfile.type` of `RuntimeDefault` or `Localhost`; plus the `baseline` inheritance — no privileged containers, no host namespaces, no `hostPath`, no `hostPort`, restricted volume types, no unsafe sysctls. It does **not** enforce `readOnlyRootFilesystem`, and it does not constrain image provenance (tag vs digest, registry allowlist) at all. Those three gaps are exactly what topic 6.4 asks you to close with a separate admission mechanism. Memorise this: "PSA restricted ≠ immutable."

**Q21.** `ValidatingAdmissionPolicy` matched on `pods`, so it evaluates the Pod object at creation. A Deployment does not create Pods directly — it creates a ReplicaSet, and the **ReplicaSet controller** creates Pods, using the controller-manager's own identity. The Deployment and ReplicaSet objects themselves are never validated, so they are accepted; the rejection happens later, asynchronously, when the controller tries to create the Pod. The operator sees it in the ReplicaSet's events (`kubectl describe rs`) and in the Deployment's `status.conditions` (`ReplicaFailure=True`, reason `FailedCreate`) — never in the output of `kubectl apply`. This is the standard failure signature of *any* Pod-level admission control (PSA behaves identically) and is why `validationActions: ["Warn"]` matters: `Warn` responses do surface on the Deployment create, giving the author immediate feedback.

**Q22.** With `failurePolicy: Fail`, a CEL expression that errors at runtime — a type mismatch, an unset field dereference, or exceeding the cost budget — causes the **request to be rejected**. Combined with a binding that matches broadly, a bad expression can block all Pod creation cluster-wide, including in `kube-system`, which is a self-inflicted outage that survives a control-plane restart. `failurePolicy: Ignore` lets the request through instead, trading availability risk for a silent security gap. Note that CEL *compile-time* errors are caught when the policy object is created (`spec.validations[0].expression: Invalid value: ... undefined field`), so `Fail` is mainly about runtime evaluation errors — which is precisely why you must exercise the policy in `Audit`/`Warn` mode against real traffic before switching to `Deny`.

**Q23.**
```cel
object.spec.containers.all(c, c.?securityContext.?readOnlyRootFilesystem.orValue(false) == true)
```
Kubernetes CEL enables optional types, so `?field` yields an `optional<T>` that short-circuits instead of erroring, and `orValue()` supplies the default. The `has()` guard in the long form is required because `securityContext` is an *optional* field in the Pod schema: dereferencing an absent field in CEL raises `no such key`, which under `failurePolicy: Fail` rejects the request with an opaque evaluation error rather than your intended message. The rule for policy authoring: never dereference an optional field without `has()` or the `?` operator.

**Q24.** `myregistry.io/evil@sha256:abc...` passes — the check validates the *form* of the reference, not its origin, so an attacker who can set the image field simply pins a digest from a registry they control. It also accepts a reference like `nginx:latest@sha256:...`, where the tag is decorative. Tighten by anchoring the registry as well:
```cel
object.spec.containers.all(c,
  c.image.startsWith('registry.internal.example.com/') &&
  c.image.contains('@sha256:'))
```
In production this belongs with a signature-verification admission controller (Sigstore policy-controller, Kyverno `verifyImages`) that checks the digest against a signature, since a registry allowlist only proves *where* the bytes came from, not *who* built them.

**Q25.** Because subresources are matched explicitly. A `resourceRules` entry listing `resources: ["pods"]` matches the Pod resource itself; the ephemeral-containers write targets `pods/ephemeralcontainers`, a distinct subresource that must be named separately (`resources: ["pods", "pods/ephemeralcontainers"]`). This is identical to how `ValidatingWebhookConfiguration` and RBAC treat subresources, and it is a routine source of policy bypasses — the same applies to `pods/exec`, `pods/attach`, `pods/portforward` and `pods/eviction`. When writing any Pod-scoped policy, enumerate the subresources deliberately.

**Q26.** `spec.ephemeralContainers` is append-only: the API server rejects removal, and `kubectl` offers no delete verb for it. Once a debug container has been attached, the only way to return the Pod to a known-good state is to **delete the Pod** and let its controller recreate it — for a bare Pod, that means losing it entirely. Operationally this is a feature for immutability: an ephemeral container is a permanent, auditable mark on the Pod's spec, so "was this Pod ever debugged?" is answerable from the API long after the debug container terminated. Include `spec.ephemeralContainers` in your drift audits.

**Q27.** RBAC first. It is a single, well-understood control that applies to every path into the subresource, it has no runtime evaluation cost, it cannot be broken by a CEL error taking out Pod creation, and it fails closed by default (absence of a grant is a denial). The VAP is the second layer, and it is worth having because RBAC is coarse — a break-glass SRE role that legitimately needs `pods/ephemeralcontainers` still benefits from being forced to attach a hardened debug container. Ordering rule: prefer the mechanism whose failure mode is "nobody can debug" over the one whose failure mode is "nobody can deploy".

**Q28.** (1) **Execution control on writable paths.** `readOnlyRootFilesystem` cannot express "this path is writable but not executable" — every `emptyDir` you add is fully executable. AppArmor's `deny /var/cache/nginx/** x` closes exactly the hole demonstrated in Exercise 2 step 7. (2) **Independent enforcement locus.** The read-only root is a property of a mount, applied by the runtime at container creation; a container that gains `CAP_SYS_ADMIN` (via a misconfiguration, a runtime CVE, or a privileged sidecar sharing namespaces) can remount it read-write. AppArmor is enforced by the LSM on every syscall and is not undone by remounting. Additionally, AppArmor can express *finer-than-mount* rules — deny writes to `/etc/**` while permitting them elsewhere in the same layer — and it produces kernel audit records of every denial, giving you detection alongside prevention.

**Q29.** Failing closed is correct because the alternative — silently starting the container *without* the profile — would mean a Pod believed to be confined runs unconfined, and nothing in `kubectl get pod` would say so. A security control that degrades invisibly is worse than no control, because it produces false confidence. The rollout implication: the profile must be present on **every node the Pod could be scheduled to**, before the workload references it. In practice: distribute profiles with a privileged DaemonSet (or node image / config management), gate the workload rollout on that DaemonSet being `Ready` cluster-wide, and use `nodeSelector`/node labels during a phased rollout so Pods can only land on nodes already carrying the profile. `kubectl exec <pod> -- cat /proc/self/attr/current` is the per-Pod verification, and `aa-status` the per-node one.

**Q30.** The seccomp equivalent would be blocking the `execve`/`execveat` syscalls — but seccomp filters on **syscall numbers and register values only**. It cannot dereference the pathname pointer argument, so it has no way to express "deny exec *of files under /tmp*"; it can only deny `execve` entirely, which breaks any process that spawns children (including nginx's master forking workers, and every shell script in an entrypoint). Path-aware mandatory access control is precisely the job an LSM exists to do, which is why AppArmor (path-based) or SELinux (label-based) is the right tool here and seccomp is the wrong one. Use seccomp for *attack-surface reduction* — `RuntimeDefault` blocks ~44 dangerous syscalls such as `mount`, `pivot_root`, `bpf`, `kexec_load`, `ptrace` — and an LSM for *resource-scoped* policy. They are complementary layers, not alternatives.

**Q31.** `// false` is jq's alternative operator: it supplies `false` when the left side is `null` **or** `false`. The real case it handles is the field being entirely **absent** — a container with no `securityContext` at all, or one that sets other fields but omits `readOnlyRootFilesystem`. Without it, `.securityContext.readOnlyRootFilesystem` evaluates to `null` for those containers and `null != true` still holds, so the `select` happens to work — but `.securityContext` itself being `null` makes the whole path expression yield `null` rather than erroring only by jq's leniency, and the moment you extend the filter with a chained comparison or a `| .[]` it breaks. Writing the default explicitly makes the "unset means insecure" assumption visible, which is the point: **absence is a finding, not a gap in the data.**

**Q32.** Four stages, each with an explicit signal:
1. **Measure (`Audit` only, no `namespaceSelector`).** Bind the policy cluster-wide with `validationActions: ["Audit"]` and read `validation.policy.admission.k8s.io/validation_failure` annotations out of the API server audit log. Signal: the count and the *owner distribution* of failing workloads. Expect the majority to fail; that is the baseline, and you need the owner list to plan the work.
2. **Warn (`["Audit","Warn"]`).** Developers now see the message in `kubectl apply` output and in CI. Signal: the failure count trending down week over week without you filing tickets. This stage also flushes out the Deployment-vs-Pod asymmetry from Q21 — `Warn` is the only action that reaches the person running `kubectl apply` on a Deployment.
3. **Enforce by exception (`["Deny"]` + `namespaceSelector: {matchLabels: {immutability: enforced}}`).** Teams opt in by labelling their namespace as they finish remediation. Signal: number of labelled namespaces, and zero `FailedCreate` events on `ReplicaSet`s in those namespaces. New namespaces should be labelled at creation so the ratchet only tightens.
4. **Flip the default.** Once the remaining set is small and known, invert the selector — enforce everywhere except namespaces carrying an explicit, time-boxed `immutability: exempt` label. Signal: the exemption list shrinking, and an alert on any exemption older than its agreed expiry. Never enforce in `kube-system` without first confirming the control-plane and CNI DaemonSets comply; several (`kube-proxy`, some CNI agents) legitimately need a writable root and require a namespace-level exemption or per-workload remediation upstream.

</details>