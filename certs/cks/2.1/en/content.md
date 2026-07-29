# 2.1 Use appropriate pod security standards

## Why this matters

A Pod is, at heart, a request to the kubelet to run processes on a node. Left unconstrained, that request can ask for things that dissolve the boundary between container and host: `privileged: true`, `hostPID: true`, a `hostPath` mount of `/`, the `SYS_ADMIN` capability, an unconfined seccomp profile. Any of those turns "compromise a workload" into "own the node", and from there frequently into "own the cluster" (the node's kubelet credentials, the service account tokens of every Pod on that node, the container runtime socket).

The **Pod Security Standards (PSS)** are Kubernetes' answer to this: three named, versioned policy levels that describe *how much* a Pod is allowed to ask for. The **Pod Security Admission (PSA)** controller is the built-in enforcement mechanism that applies those levels at the namespace boundary. PSA is a *validating* admission plugin compiled into `kube-apiserver` and enabled by default since v1.23 (GA since v1.25). It replaced the removed PodSecurityPolicy (PSP) API.

Two properties define how you must think about PSA:

1. **It is namespace-scoped.** You opt a namespace into a level with labels. There is no per-Pod, per-ServiceAccount, or per-user selector like PSP had.
2. **It never mutates.** PSA only says yes or no. It will not add `runAsNonRoot: true` for you, will not drop capabilities for you. Making a workload compliant is the manifest author's job (or a mutating policy engine's).

---

## The three levels

| Level | Intent | Typical use |
|---|---|---|
| `privileged` | Unrestricted. Deliberately open, allows known privilege escalations. | System/infra namespaces: CNI, CSI drivers, node agents, `kube-system`. |
| `baseline` | Blocks known privilege escalations while staying compatible with the majority of ordinary workloads. Requires no changes to a typical manifest. | Common denominator for application namespaces during migration. |
| `restricted` | Heavily restricted, follows current Pod hardening best practice. Costs compatibility. | The target for tenant/application namespaces. |

The levels are **cumulative**: `restricted` includes everything `baseline` forbids, plus more.

### What `baseline` forbids

| Control | Rule |
|---|---|
| HostProcess | `securityContext.windowsOptions.hostProcess` must be unset or `false` (pod and containers). |
| Host namespaces | `hostNetwork`, `hostPID`, `hostIPC` must be unset or `false`. |
| Privileged containers | `securityContext.privileged` must be unset or `false`. |
| Capabilities | May not **add** any capability beyond `NET_BIND_SERVICE`. |
| HostPath volumes | `hostPath` volumes are forbidden. |
| Host ports | `containerPort.hostPort` must be unset or `0`. |
| AppArmor | `appArmorProfile.type` (or the legacy annotation) must be `RuntimeDefault` or `Localhost`; `Unconfined` is forbidden. |
| SELinux | `seLinuxOptions.type` must be unset, `container_t`, `container_init_t`, `container_kvm_t`, or `container_engine_t`. `seLinuxOptions.user` and `.role` must be unset. |
| `/proc` mount type | `procMount` must be unset or `Default` (i.e. not `Unmasked`). |
| Seccomp | `seccompProfile.type` may be unset, but if set must not be `Unconfined`. |
| Sysctls | Only a small allowlist of namespaced sysctls (e.g. `kernel.shm_rmid_forced`, `net.ipv4.ip_local_port_range`, `net.ipv4.ip_unprivileged_port_start`, `net.ipv4.tcp_syncookies`, `net.ipv4.ping_group_range`). The allowlist grows across policy versions. |

Note what `baseline` does **not** require: it does not force you to run as non-root, does not require dropping capabilities, does not require a seccomp profile. A stock `nginx` Deployment passes `baseline` unchanged.

### What `restricted` adds

| Control | Rule |
|---|---|
| Volume types | Only `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`. (The exact allowlist is part of the policy version.) |
| Privilege escalation | `allowPrivilegeEscalation` must be **explicitly** `false` on every container (Linux pods). |
| Running as non-root | `runAsNonRoot` must be `true` at pod level or on every container. |
| Running as non-root *user* | `runAsUser` must not be `0` (may be unset). |
| Seccomp | `seccompProfile.type` must be **explicitly set** to `RuntimeDefault` or `Localhost`. Unset is a violation (a container may omit it if the pod-level field is set). |
| Capabilities | Every container must have `capabilities.drop: ["ALL"]`. Only `NET_BIND_SERVICE` may be added back. |

The `restricted` fields must be satisfied by **all** `containers`, `initContainers`, and `ephemeralContainers`.

---

## Pod Security Admission: modes and labels

You opt a namespace in with labels of the form:

```
pod-security.kubernetes.io/<MODE>: <LEVEL>
pod-security.kubernetes.io/<MODE>-version: <POLICY_VERSION>   # optional
```

`<MODE>` is one of:

| Mode | Effect | Applies to |
|---|---|---|
| `enforce` | Violating **Pods** are rejected at admission. | Pods only. |
| `audit` | Violation is recorded as an annotation in the API server audit log. Object is admitted. | Pods **and** workload controllers (Deployment, Job, CronJob, …). |
| `warn` | Violation is returned to the client as a `Warning:` header. Object is admitted. | Pods **and** workload controllers. |

`<LEVEL>` is `privileged`, `baseline`, or `restricted`. `<POLICY_VERSION>` is a minor version like `v1.34`, or `latest` (the default).

### The `enforce`-only-applies-to-Pods trap

This is the single most common source of confusion, and it shows up in exam-style scenarios constantly.

`enforce` is evaluated against the **Pod** object. When you create a Deployment, the Deployment is admitted; the ReplicaSet is admitted; then the ReplicaSet controller tries to create Pods and *those* are rejected. Your `kubectl apply` succeeds and nothing runs.

```console
$ kubectl -n prod create deployment web --image=nginx
deployment.apps/web created

$ kubectl -n prod get deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/1     0            0           14s

$ kubectl -n prod get pods
No resources found in prod namespace.

$ kubectl -n prod describe rs -l app=web | tail -6
Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  12s   replicaset-controller  Error creating: pods "web-6c9b7f4b8d-" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The diagnosis path is: Deployment has 0 replicas → `describe rs` (or `kubectl get events -n <ns>`) → read the `FailedCreate` message.

This is exactly why you should set `warn` alongside `enforce`: with `warn` enabled the feedback arrives immediately, at `kubectl apply` time, on the Deployment itself.

```console
$ kubectl -n prod create deployment web --image=nginx
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/web created
```

---

## Applying the labels

### Declaratively

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    # Hard requirement
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.34
    # Tell me now, at apply time, if I'm not ready for restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    # And record it for the security team
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
```

This "enforce baseline / warn+audit restricted" combination is the canonical migration pattern: you get a hard floor today and a measurable path to `restricted`.

### Imperatively

```console
$ kubectl label namespace prod \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.34 --overwrite
namespace/prod labeled
```

Removing a mode is done by deleting the label:

```console
$ kubectl label namespace prod pod-security.kubernetes.io/enforce-
namespace/prod unlabeled
```

Values are validated by the API server, so typos fail loudly:

```console
$ kubectl label ns prod pod-security.kubernetes.io/enforce=restrict --overwrite
The Namespace "prod" is invalid: metadata.labels[pod-security.kubernetes.io/enforce]: Invalid value: "restrict": must be one of ["privileged" "baseline" "restricted"]
```

### Auditing which namespaces are covered

```console
$ kubectl get ns -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/warn
NAME              STATUS   AGE   ENFORCE      WARN
default           Active   21d
dev               Active   4h    baseline     restricted
kube-node-lease   Active   21d
kube-public       Active   21d
kube-system       Active   21d   privileged
prod              Active   4h    restricted   restricted
```

Empty `ENFORCE` means **no enforcement at all** for that namespace unless a cluster-wide default is configured (see below). An unlabelled namespace is effectively `privileged`. Do not assume "no label = safe".

---

## Dry-running a level against existing workloads

Before you turn on `enforce`, find out what would break. PSA evaluates existing Pods in the namespace when the label changes, and a **server-side dry run** gives you that evaluation without persisting anything:

```console
$ kubectl label --dry-run=server --overwrite ns dev \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "dev" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-app-7f9d4c85b-2xk9p (and 2 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: node-exporter-nq7lb: host namespaces, hostPath volumes, allowPrivilegeEscalation != false, unrestricted capabilities, restricted volume types, runAsNonRoot != true, seccompProfile
namespace/dev labeled
```

Nothing was actually labeled — `--dry-run=server` means the API server evaluated the request and discarded it. This is the fastest safe way to answer "can this namespace go restricted?" and is worth memorising for the exam.

To sweep the whole cluster:

```console
$ kubectl label --dry-run=server --overwrite ns --all \
    pod-security.kubernetes.io/enforce=baseline 2>&1 | grep -A100 Warning
```

---

## Cluster-wide defaults and exemptions

Namespace labels are opt-in, which means a newly created namespace is unprotected. To set a floor for the whole cluster, configure the `PodSecurity` admission plugin via an `AdmissionConfiguration` file.

`/etc/kubernetes/admission/pod-security.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      # Applied to any namespace that does not carry the corresponding label.
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        # Requests by these users bypass PSA entirely.
        usernames: []
        # Pods using these RuntimeClasses are exempt (e.g. sandboxed runtimes).
        runtimeClasses: []
        # Pods in these namespaces are exempt.
        namespaces: ["kube-system"]
```

Wire it into the API server. On a kubeadm cluster, edit the static Pod manifest `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --admission-control-config-file=/etc/kubernetes/admission/pod-security.yaml
        # ...
      volumeMounts:
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

The kubelet restarts the API server automatically when the manifest changes:

```console
$ sudo crictl ps | grep kube-apiserver
b3f1c2a9e77d5  ...  Running  kube-apiserver  1  9f2a1c...

$ kubectl -n kube-system logs kube-apiserver-controlplane | grep -i podsecurity
```

If the API server does not come back, the manifest or the config file is malformed — check `sudo crictl ps -a`, then `sudo crictl logs <container-id>`, or `/var/log/pods/`.

### Notes on exemptions

- Exemptions are evaluated **before** the policy, so an exempt request is not even checked (it is not audited either).
- Exempting by `username` is a real escape hatch: any principal in that list can create a privileged Pod anywhere. Treat that list like cluster-admin.
- There is **no** exemption by ServiceAccount or by Pod name. If you need per-workload granularity, that is a job for a policy engine, not for PSA.
- The label always wins over the configured default for that mode.

---

## Making a workload `restricted`-compliant

The failing baseline manifest:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
    - name: web
      image: nginx:1.27
```

```console
$ kubectl -n prod apply -f web.yaml
Error from server (Forbidden): error when creating "web.yaml": pods "web" is forbidden: violates PodSecurity "restricted:v1.34": allowPrivilegeEscalation != false (container "web" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "web" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The compliant version — this is the shape worth being able to type from memory:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  securityContext:                    # pod level: inherited by all containers
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:1.27
      ports:
        - containerPort: 8080
      securityContext:                # container level: cannot be set at pod level
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true  # not required by PSS, but good practice
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```console
$ kubectl -n prod apply -f web.yaml
pod/web created

$ kubectl -n prod get pod web
NAME   READY   STATUS    RESTARTS   AGE
web    1/1     Running   0          6s
```

Two placement rules to internalise:

- `runAsNonRoot`, `runAsUser`, `seccompProfile`, `seLinuxOptions`, `fsGroup` can be set at **pod** level (`spec.securityContext`) and are inherited.
- `allowPrivilegeEscalation`, `capabilities`, `privileged`, `readOnlyRootFilesystem`, `procMount` exist **only** at container level (`spec.containers[].securityContext`). A container-level value always overrides the pod-level one.

### The `runAsNonRoot` runtime failure

`runAsNonRoot: true` without `runAsUser` is admitted by PSA, but the kubelet enforces it at container start by inspecting the image's `USER`. An image that runs as root then fails *after* admission:

```console
$ kubectl -n prod get pod web
NAME   READY   STATUS                       RESTARTS   AGE
web    0/1     CreateContainerConfigError   0          8s

$ kubectl -n prod describe pod web | grep -A3 Warning
  Warning  Failed  3s (x3 over 18s)  kubelet  Error: container has runAsNonRoot and image will run as root (pod: "web_prod(...)", container: web)
```

Fix by using an image built with a non-root `USER`, or by setting an explicit non-zero `runAsUser` **and** ensuring the filesystem permissions in the image allow that UID to run.

---

## Reading the audit trail

With `audit` enabled, violations land in the API server audit log as annotations rather than blocking anything:

```json
{
  "kind": "Event",
  "verb": "create",
  "objectRef": { "resource": "pods", "namespace": "dev", "name": "legacy-app" },
  "annotations": {
    "pod-security.kubernetes.io/audit-violations": "would violate PodSecurity \"restricted:latest\": allowPrivilegeEscalation != false (container \"app\" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container \"app\" must set securityContext.capabilities.drop=[\"ALL\"])"
  }
}
```

This requires the API server audit log to be configured (`--audit-policy-file`, `--audit-log-path`) — it is the measurement instrument that tells you when a namespace is finally ready to be moved from `baseline` to `restricted`.

---

## Policy versioning

Pinning `*-version` to a concrete minor version (`v1.34`) freezes the policy definition. If a later Kubernetes release adds a new check to `restricted`, a pinned namespace keeps evaluating the older ruleset and your running workloads are not suddenly rejected on cluster upgrade.

- Use a **pinned version for `enforce`** in production, so an upgrade cannot break admission for existing workloads.
- Use **`latest` for `warn` and `audit`**, so you learn about new checks before they bite.
- Bump the pinned `enforce` version deliberately, after the audit data says you are clean.

If a namespace's pinned version is older than the oldest version the API server still knows, PSA falls back to the oldest supported policy and emits a warning.

---

## Where PSA stops, and what to reach for next

PSA is intentionally narrow. It cannot express:

- "images must come from `registry.internal.example.com`"
- "every Pod must set resource limits"
- "this ServiceAccount may use `hostNetwork`, others may not"
- any **mutation** (adding a default `securityContext`)

For those, layer a policy engine or CEL-based policy on top:

- **ValidatingAdmissionPolicy** (built-in, CEL, GA since v1.30) and **MutatingAdmissionPolicy** — no external webhook to run or keep available.
- **Kyverno** / **OPA Gatekeeper** — both ship pre-built PSS policy sets and can additionally mutate manifests into compliance.

The recommended composition is: PSA for the coarse namespace-level floor, a policy engine for anything finer.

A minimal `ValidatingAdmissionPolicy` illustrating the complement:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-approved-registry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.startsWith('registry.internal.example.com/'))
      message: "images must come from the internal registry"
```

---

## Common pitfalls

- **Unlabelled namespaces are wide open.** Enumerate them (`kubectl get ns -L pod-security.kubernetes.io/enforce`) or set a cluster-wide default.
- **`enforce` alone gives silent failures** through controllers. Always pair it with `warn`.
- **PSA does not retroactively evict.** Labeling a namespace only affects Pods created *after* the change; existing violating Pods keep running (you just get a warning). Recreate them to converge.
- **`restricted` requires `seccompProfile` to be explicitly set.** Unset is a violation, unlike in `baseline`.
- **`capabilities.drop: ["ALL"]` is required even if you add nothing back.** "No capabilities added" is not the same as "all dropped".
- **`privileged` is not "no policy configured".** It is an explicit statement, and labeling infra namespaces `privileged` documents intent — and makes them visible in an audit.
- **Exempting `kube-system` is normal; exempting your app namespaces is not.**
- Any manifest that needs `hostPath`, `hostNetwork`, or `privileged` (node agents, CNI, monitoring exporters) belongs in a dedicated `privileged` namespace with tightly-scoped RBAC — not in a namespace shared with applications.

---

## Practice lab

```console
# 1. Create a namespace that enforces baseline but warns on restricted
kubectl create ns lab
kubectl label ns lab \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.34 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

# 2. A plain pod is admitted (baseline), but warns about restricted
kubectl -n lab run web --image=nginx

# 3. A privileged pod is rejected
kubectl -n lab run bad --image=nginx --privileged
# Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
# "baseline:v1.34": privileged (container "bad" must not set securityContext.privileged=true)

# 4. A hostPath pod is rejected
kubectl -n lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: mounter }
spec:
  containers:
    - name: c
      image: busybox
      command: ["sleep","3600"]
      volumeMounts: [{ name: host, mountPath: /host }]
  volumes:
    - name: host
      hostPath: { path: / }
EOF
# Error from server (Forbidden): ... violates PodSecurity "baseline:v1.34":
# hostPath volumes (volume "host")

# 5. Dry-run the upgrade to restricted and read what would break
kubectl label --dry-run=server --overwrite ns lab \
  pod-security.kubernetes.io/enforce=restricted

# 6. Fix the workload, then commit the upgrade
kubectl -n lab delete pod web
kubectl label --overwrite ns lab pod-security.kubernetes.io/enforce=restricted
kubectl -n lab apply -f web-restricted.yaml   # the compliant manifest above

# 7. Clean up
kubectl delete ns lab
```

---

## Referencias

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Enforce Pod Security Standards with Namespace Labels — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Enforce Pod Security Standards by Configuring the Built-in Admission Controller — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller — https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- CKS Curriculum v1.34 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf