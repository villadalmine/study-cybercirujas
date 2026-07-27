# 4.8 – Understand Application Security (SecurityContexts, Capabilities, etc.)

## What is a SecurityContext?

A **SecurityContext** defines OS-level privileges and access control settings for a Pod or an individual container (user, group, Linux capabilities, privilege escalation, etc.). It serves as the primary mechanism to enforce the principle of **least privilege** across Kubernetes workloads.

It can be declared at two levels:

- **`spec.securityContext`** (Pod-level): Applies to all containers in the Pod (and volumes, in the case of `fsGroup`).
- **`spec.containers[].securityContext`** (Container-level): Applies strictly to that container and **overrides** equivalent values defined at Pod level.

```
Pod securityContext
 └── Container securityContext (takes precedence if defining identical fields)
```

## Pod-Level SecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secctx
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    runAsNonRoot: true
    fsGroup: 2000
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    emptyDir: {}
```

- **`runAsUser` / `runAsGroup`**: Enforces UID/GID for container execution, regardless of image `USER` instruction.
- **`runAsNonRoot: true`**: Instructs kubelet to **reject** container startup if it would execute as UID 0 (root). Acts as a validation check rather than setting UID by itself.
- **`fsGroup`**: Modifies group ownership of mounted supported volumes so the specified GID has write access.

Verification:

```bash
kubectl apply -f pod-secctx.yaml
kubectl exec pod-secctx -- id
```

```
uid=1000 gid=3000 groups=3000,2000
```

## Container-Level SecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-container-secctx
spec:
  containers:
  - name: app
    image: nginx:1.25
    securityContext:
      runAsUser: 101
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      privileged: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
```

Key container-level fields:

| Field | Effect |
|---|---|
| `privileged` | If `true`, container gains host root equivalent access (all devices, no security namespace isolation). Avoid unless explicitly required (CNI plugins, node drivers). |
| `allowPrivilegeEscalation` | If `false`, prevents child processes from gaining higher privileges than parent (blocks setuid/setgid binaries and enables `no_new_privs`). Forced `false` automatically if `privileged: false` and `capabilities.add` omits `SYS_ADMIN`. |
| `readOnlyRootFilesystem` | Mounts container root filesystem as read-only; processes write only to explicitly mounted volumes (combine with `emptyDir` for writable paths like `/tmp`). |
| `capabilities` | List of Linux capabilities to add (`add`) or remove (`drop`) relative to container runtime defaults. |

## Linux Capabilities

**Capabilities** decompose traditional root user privileges into fine-grained units. Container runtimes (`containerd`/`runc`) start containers with a reduced default set of capabilities, which can be **added** or **dropped**.

Relevant capabilities for the exam:

| Capability | Permits |
|---|---|
| `NET_ADMIN` | Configure network interfaces, routing tables, firewall rules (iptables). |
| `NET_RAW` | Use raw sockets (e.g. `ping`). |
| `NET_BIND_SERVICE` | Bind to ports < 1024 without root privileges. |
| `CHOWN` | Change file ownership. |
| `SYS_TIME` | Modify system clock. |
| `SYS_ADMIN` | Broad administrative operations (mount filesystems, etc.) — avoid unless strictly necessary. |

Example: drop all and add only necessary capability (hardening best practice):

```yaml
securityContext:
  capabilities:
    drop:
    - ALL
    add:
    - NET_BIND_SERVICE
```

Practical example: container requiring `NET_ADMIN` to manipulate network rules:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: netadmin-pod
spec:
  containers:
  - name: net-tool
    image: nicolaka/netshoot
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
```

```bash
kubectl exec netadmin-pod -- sh -c "iptables -L"
```

Without `NET_ADMIN`, this command fails with `Permission denied` (Operation not permitted).

## seccompProfile

Restricts system calls available to the container.

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

`type` options:

- **`RuntimeDefault`**: Uses container runtime's default seccomp profile (recommended baseline).
- **`Localhost`**: Uses custom JSON profile located on node (requires `localhostProfile: <relative path>`).
- **`Unconfined`**: Disables seccomp filtering (avoid in production).

## seLinuxOptions (Brief Reference)

For clusters with SELinux enabled, process labels can be specified:

```yaml
securityContext:
  seLinuxOptions:
    level: "s0:c123,c456"
```

Less common on the exam than `capabilities`/`runAsUser`, but may appear as a distractor option.

## Combined Example (Pod + Container)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
  - name: web
    image: nginx:1.25
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
```

Note: `nginx` writes to `/var/cache/nginx` and `/var/run` by default; with `readOnlyRootFilesystem: true`, mounting `emptyDir` at those locations prevents startup failures.

## Verification and Troubleshooting

```bash
kubectl get pod hardened-pod -o jsonpath='{.spec.securityContext}'
kubectl get pod hardened-pod -o jsonpath='{.spec.containers[0].securityContext}'
```

If a Pod specifying `runAsNonRoot: true` attempts to run an image executing as root (or omitting `USER`) without specifying `runAsUser`, Pod enters `CreateContainerConfigError`:

```bash
kubectl describe pod hardened-pod
```

```
Warning  Failed  2s  kubelet  Error: container has runAsNonRoot and image will run as root
```

Resolution: explicitly declare non-root `runAsUser` UID, or use image declaring non-root `USER`.

## Exam Tips

- Remember **precedence rules**: container-level overrides pod-level on a field-by-field basis (does not replace whole block).
- `drop: ["ALL"]` + `add: [...]` is the most tested hardening pattern: drop all and enable strictly necessary capabilities.
- `allowPrivilegeEscalation: false` cannot be set to `true` if container specifies `privileged: true` or `CAP_SYS_ADMIN`.
- Editing `securityContext` on live Pods via `kubectl edit` is disallowed (immutable field); replace Pod using `kubectl replace --force` or edit manifest and reapply.
- Leverage `kubectl explain pod.spec.securityContext` and `kubectl explain pod.spec.containers.securityContext` during exam.

## References

- Configure a Security Context for a Pod or Container: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- SecurityContext API reference: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#securitycontext-v1-core
- Linux capabilities (man7): https://man7.org/linux/man-pages/man7/capabilities.7.html
- Seccomp security in Kubernetes: https://kubernetes.io/docs/tutorials/security/seccomp/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
