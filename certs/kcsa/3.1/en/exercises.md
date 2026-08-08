# KCSA Study Guide: Topic 3.1 - Pod Security Standards

**Exam Target:** Kubernetes and Cloud Security Associate (KCSA)  
**Domain:** Cluster Security Readiness  
**Topic:** 3.1 Pod Security Standards (PSS) & Pod Security Admission (PSA)  
**Weight:** 3.14%  

---

## 1. Deep Dive Mechanics & Internal Architecture

### 1.1 Pod Security Standards (PSS) Overview
Kubernetes Pod Security Standards define three distinct security profiles to restrict the execution context of Pods. Following the deprecation and removal of `PodSecurityPolicy` (PSP) in Kubernetes v1.25, the standard built-in mechanism for enforcing PSS is **Pod Security Admission (PSA)**.

1. **Privileged**: Unrestricted profile. Provides the widest possible permissions. Allows known privilege escalations, root execution, host namespace access (`hostNetwork`, `hostPID`, `hostIPC`), and arbitrary host path volume mounts. Intended for system-level daemons, infrastructure agents, and CNI plugins.
2. **Baseline**: Minimal restrictive profile. Prevents known privilege escalations while maintaining high compatibility with standard workloads. Blocks `privileged: true`, host namespaces, host ports, host path volumes, dangerous capabilities (e.g., `CAP_SYS_ADMIN`), and dangerous `sysctls`.
3. **Restricted**: Heavily hardened profile following current Pod hardening best practices. Requires workloads to run as non-root, block privilege escalation (`allowPrivilegeEscalation: false`), restrict allowed volume types, enforce a valid `seccompProfile` (`RuntimeDefault` or `Localhost`), and explicitly drop all capabilities (`capabilities.drop: ["ALL"]`).

```
 +-------------------------------------------------------------------------------+
 |                              KUBE-APISERVER                                   |
 |                                                                               |
 |   Incoming Pod / Workload Request                                             |
 |              |                                                                |
 |              v                                                                |
 |   +--------------------+                                                      |
 |   | Mutating Webhooks  |                                                      |
 |   +---------+----------+                                                      |
 |             |                                                                 |
 |             v                                                                 |
 |   +-----------------------------------------------------------------------+   |
 |   | Validating Admission Phase                                            |   |
 |   |                                                                       |   |
 |   |   +---------------------------------------------------------------+   |   |
 |   |   | PodSecurity Admission Plugin (In-Tree)                        |   |   |
 |   |   |                                                               |   |   |
 |   |   | 1. Check Namespace Labels & Cluster Exemptions                |   |   |
 |   |   | 2. Evaluate Pod Spec against Target Level (v1.x)              |   |   |
 |   |   |                                                               |   |   |
 |   |   |   +----------------+------------------+-------------------+   |   |   |
 |   |   |   |  Enforce Mode  |   Audit Mode     |     Warn Mode     |   |   |   |
 |   |   |   +-------+--------+--------+---------+---------+---------+   |   |   |
 |   |   +-----------|-----------------|-------------------|-------------+   |   |
 |   +---------------+-----------------|-------------------|-----------------+   |
 |                   |                 |                   |                     |
 +-------------------|-----------------|-------------------|---------------------+
                     |                 |                   |
            Reject Request     Write Audit Annotation  Return Warning Header
            (HTTP 403 Forbidden) (Audit Log Engine)    to Client / User CLI
```

### 1.2 Pod Security Admission (PSA) Execution Mechanics
PSA is implemented directly inside `kube-apiserver` as an in-tree validating admission plugin (`PodSecurity`).

* **Evaluation Controls (Modes)**:
  * **`enforce`**: Rejects the Pod creation HTTP request if it violates the target PSS profile.
  * **`audit`**: Accepts the Pod creation request, but records an audit annotation (`pod-security.kubernetes.io/audit-violations`) in the API Server audit log if the Pod violates the profile.
  * **`warn`**: Accepts the Pod creation request, but returns a warning header in the HTTP response (`Warning: 299 - ...`) to the requesting user or client CLI.

* **Version Pinning**:
  * Profile rules evolve across Kubernetes releases. PSA requires/allows version pinning per mode (e.g., `pod-security.kubernetes.io/enforce-version: v1.30` or `latest`). If a version is omitted, it defaults to the Kubernetes API server's current minor version.

* **Standalone Pods vs. Workload Controllers**:
  * When applying `enforce` mode to a Namespace, direct `Pod` manifests violating the profile are immediately rejected by the API Server.
  * However, creating a `Deployment`, `StatefulSet`, `ReplicaSet`, or `Job` whose Pod template violates `enforce` mode will **succeed** at the Controller object level. The failure occurs asynchronously when the Controller Manager attempts to spawn individual `Pod` instances.
  * To provide immediate feedback during `Deployment` creation, `audit` and `warn` modes evaluate Pod templates inside workload controllers, whereas `enforce` mode only evaluates actual `Pod` creation events.

### 1.3 Cluster-Wide `PodSecurityConfiguration`
Global default levels and exemptions are defined using the `PodSecurityConfiguration` API schema, passed to `kube-apiserver` via the `--admission-control-config-file` flag.

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "baseline"
  enforce-version: "latest"
  audit: "restricted"
  audit-version: "latest"
  warn: "restricted"
  warn-version: "latest"
exemptions:
  usernames:
    - "system:serviceaccount:kube-system:daemon-set-controller"
  runtimeClasses: []
  namespaces:
    - "kube-system"
    - "cert-manager"
```

---

## 2. Official References
* [Kubernetes Documentation: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Kubernetes Documentation: Enforce Pod Security Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
* [Kubernetes Documentation: Enforce Pod Security Standards with an Admission Controller](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/)
* [CNCF KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Guided Exercises

### Exercise 1: Configuring Namespace-Level PSA with Multi-Mode Labels

In this exercise, you will create a target namespace, apply multi-mode PSA labels (`enforce`, `audit`, and `warn`), deploy compliant and non-compliant workloads, and observe the exact behavior of `kube-apiserver`.

#### Step 1.1: Create Namespace and Apply Security Labels
Create a new namespace `production-secure` and apply labels:
* `enforce`: `baseline` (v1.30)
* `warn`: `restricted` (latest)
* `audit`: `restricted` (latest)

Execute the following commands:

```bash
kubectl create namespace production-secure

kubectl label --overwrite namespace production-secure \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.30 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

**Expected Output:**
```text
namespace/production-secure created
namespace/production-secure labeled
```

Inspect the applied labels:

```bash
kubectl get namespace production-secure --show-labels
```

**Expected Output:**
```text
NAME                STATUS   AGE   LABELS
production-secure   Active   12s   kubernetes.io/metadata.name=production-secure,pod-security.kubernetes.io/audit-version=latest,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.30,pod-security.kubernetes.io/enforce=baseline,pod-security.kubernetes.io/warn-version=latest,pod-security.kubernetes.io/warn=restricted
```

#### Step 1.2: Attempt to Deploy a Privileged Pod violating `enforce=baseline`
Save the following manifest as `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-workload
  namespace: production-secure
spec:
  containers:
  - name: exploit-container
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      privileged: true
```

Attempt to apply the manifest:

```bash
kubectl apply -f privileged-pod.yaml
```

**Expected Output:**
```text
Error from server (Forbidden): error when creating "privileged-pod.yaml": pods "privileged-workload" is forbidden: violates PodSecurity "baseline:v1.30": privileged (container "exploit-container" must not set securityContext.privileged=true)
```

#### Step 1.3: Deploy a Pod Compliant with `baseline` but Violating `restricted`
Save the following manifest as `baseline-pod.yaml`. Notice that it does not use `privileged: true`, but it runs as root, does not drop capabilities, and allows privilege escalation.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: baseline-workload
  namespace: production-secure
spec:
  containers:
  - name: standard-container
    image: nginx:1.25-alpine
    ports:
    - containerPort: 80
```

Apply the manifest:

```bash
kubectl apply -f baseline-pod.yaml
```

**Expected Output:**
```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "standard-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "standard-container" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "standard-container" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "standard-container" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/baseline-workload created
```

#### Verification Questions (Exercise 1)

1. Why was `privileged-workload` immediately rejected with an `HTTP 403 Forbidden` error, whereas `baseline-workload` was successfully created despite throwing warnings?
2. What happened under the hood to the warning message emitted during the creation of `baseline-workload`, and where can a Security Engineer trace the `audit: restricted` violation?

---

### Exercise 2: Building Production-Grade `Restricted` Workloads & Managing Controller Rejections

In this exercise, you will harden a workload manifest until it fully complies with the `restricted` Pod Security Standard. You will also analyze the architectural behavior when applying Pod Security Enforcement to high-level controllers (`Deployments`).

#### Step 2.1: Enforce `restricted` Profile on Namespace
Update the `production-secure` namespace to strictly enforce the `restricted` profile:

```bash
kubectl label --overwrite namespace production-secure \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

**Expected Output:**
```text
namespace/production-secure labeled
```

#### Step 2.2: Analyze Deployment Creation vs. ReplicaSet Pod Spawning
Save the following non-compliant Deployment manifest as `unhardened-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: production-secure
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: web-container
        image: nginx:1.25-alpine
```

Apply the deployment manifest:

```bash
kubectl apply -f unhardened-deployment.yaml
```

**Expected Output:**
```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "web-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "web-container" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web-container" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web-container" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/web-app created
```

Now check the status of the Deployment and ReplicaSet:

```bash
kubectl get deployment web-app -n production-secure
kubectl get replicaset -n production-secure
```

**Expected Output:**
```text
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
web-app   0/2     0            0           25s

NAME                 DESIRED   CURRENT   READY   AGE
web-app-767976964    2         0         0       28s
```

Inspect the ReplicaSet events to diagnose why pods are missing:

```bash
kubectl describe replicaset -n production-secure -l app=web-app
```

**Expected Output (Snippet):**
```text
Events:
  Type     Reason        Age                  From                   Message
  ----     ------        ----                 ----                   -------
  Warning  FailedCreate  40s (x4 over 80s)    replicaset-controller  (combined from similar events): Failed create pod: pods "web-app-767976964-xxxxx" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "web-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "web-container" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web-container" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web-container" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Step 2.3: Construct a Syntactically Valid `Restricted` Compliant Deployment
Delete the failing deployment:

```bash
kubectl delete deployment web-app -n production-secure
```

Save the following fully compliant manifest as `hardened-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app-hardened
  namespace: production-secure
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-app-hardened
  template:
    metadata:
      labels:
        app: web-app-hardened
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web-container
        image: nginxinc/nginx-unprivileged:1.25-alpine
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        - name: cache-volume
          mountPath: /var/cache/nginx
        - name: pid-volume
          mountPath: /var/run
      volumes:
      - name: tmp-volume
        emptyDir: {}
      - name: cache-volume
        emptyDir: {}
      - name: pid-volume
        emptyDir: {}
```

Apply the hardened manifest:

```bash
kubectl apply -f hardened-deployment.yaml
```

**Expected Output:**
```text
deployment.apps/web-app-hardened created
```

Verify Pod execution and readiness:

```bash
kubectl get pods -n production-secure -o wide
```

**Expected Output:**
```text
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE
web-app-hardened-65b8979c5c-8xgh2   1/1     Running   0          18s   10.244.0.5   node-01
web-app-hardened-65b8979c5c-n9p4w   1/1     Running   0          18s   10.244.0.6   node-01
```

#### Verification Questions (Exercise 2)

1. Why did `kubectl apply -f unhardened-deployment.yaml` return `deployment.apps/web-app created` without returning an API HTTP 403 error, even though `enforce=restricted` was set on the namespace?
2. What specific security context settings were added to `hardened-deployment.yaml` to meet the minimum threshold of the `restricted` Pod Security Standard?
3. Why was it necessary to mount `emptyDir` volumes to `/tmp`, `/var/cache/nginx`, and `/var/run` when specifying `readOnlyRootFilesystem: true`?

---

### Exercise 3: Advanced Diagnostic Techniques & Cluster-Wide Exemption Auditing

In this exercise, you will inspect API server audit logs for PSA security events and verify how cluster-wide exemptions alter admission behavior.

#### Step 3.1: Querying Kube-APIServer Audit Logs for PSA Violations
If audit logging is enabled on your API Server (logging to `/var/log/kubernetes/audit/audit.log`), execute `grep` commands to isolate PSA audit events:

```bash
sudo grep "pod-security.kubernetes.io/audit-violations" /var/log/kubernetes/audit/audit.log | jq .
```

**Expected JSON Output (Abbreviated):**
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "d1c3a649-7e23-4e89-a212-07b140bf1d02",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/production-secure/pods",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["system:masters"]
  },
  "responseStatus": {
    "metadata": {},
    "status": "Success",
    "code": 201
  },
  "annotations": {
    "pod-security.kubernetes.io/audit": "restricted",
    "pod-security.kubernetes.io/audit-violations": "allowPrivilegeEscalation != false (container \"standard-container\" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container \"standard-container\" must set securityContext.capabilities.drop=[\"ALL\"]), runAsNonRoot != true (pod or container \"standard-container\" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container \"standard-container\" must set securityContext.seccompProfile.type to \"RuntimeDefault\" or \"Localhost\")"
  }
}
```

#### Step 3.2: Inspecting PSA Exemption Evaluation via Kube-APIServer Configuration
Examine a production-ready `PodSecurityConfiguration` file configured with exemptions (`/etc/kubernetes/admission/pod-security-config.yaml`):

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "restricted"
  enforce-version: "latest"
  audit: "restricted"
  audit-version: "latest"
  warn: "restricted"
  warn-version: "latest"
exemptions:
  usernames:
    - "system:serviceaccount:kube-system:storage-provisioner"
  runtimeClasses:
    - "kata-containers"
  namespaces:
    - "kube-system"
    - "monitoring"
```

#### Verification Questions (Exercise 3)

1. If a Pod violating the `restricted` standard is created inside the `monitoring` namespace configured under the `exemptions.namespaces` section above, what will be the result of the API server validation check?
2. What risk does using `exemptions.usernames` introduce into a multi-tenant cluster, and how can an attacker abuse a poorly configured service account exemption?

---

## 4. Comprehension Solutions

<details>
<summary>Click here to view detailed solutions and technical explanations</summary>

### Solutions for Exercise 1 Verification Questions

1. **Why was `privileged-workload` rejected while `baseline-workload` was accepted with warnings?**
   * **Mechanics**: The namespace was labeled with `pod-security.kubernetes.io/enforce=baseline` and `pod-security.kubernetes.io/warn=restricted`.
   * `privileged-workload` set `securityContext.privileged=true`. This explicitly violates the `baseline` profile. Because `baseline` was assigned to the `enforce` mode, the `PodSecurity` admission plugin halted processing during the validating admission phase and instructed `kube-apiserver` to return an `HTTP 403 Forbidden` error.
   * `baseline-workload` complied with the `baseline` profile (it did not request host access or privileged mode), so it passed the `enforce` check. However, it violated the `restricted` profile (which requires non-root execution, dropped capabilities, etc.). Because `restricted` was assigned to `warn` and `audit` modes (and not `enforce`), the API Server accepted the resource creation but attached an `HTTP Warning` header (Warning code 299) back to the `kubectl` client response.

2. **What happened under the hood to the warning message, and where is the audit log recorded?**
   * The warning message was generated dynamically during validation by the `PodSecurity` admission plugin.
   * For the `warn` mode: The API server injects an `HTTP 299 Warning` response header into the API response returned to the client request. `kubectl` intercepts HTTP 299 headers and prints them to `stderr`.
   * For the `audit` mode: The admission plugin adds an annotation entry (`pod-security.kubernetes.io/audit-violations`) directly to the API request evaluation context. When the API Server's Audit Logging module processes the request at the `ResponseComplete` stage, it logs the entire event payload—including the violation annotations—into the configured API Server audit sink (e.g., `/var/log/kubernetes/audit/audit.log` or a webhook sink).

---

### Solutions for Exercise 2 Verification Questions

1. **Why did `kubectl apply -f unhardened-deployment.yaml` succeed at object creation despite namespace enforcement?**
   * **Mechanics**: The Kubernetes API Server processes object creation schemas independently. A `Deployment` object is a high-level workload abstraction; its manifest contains a `PodTemplateSpec` under `.spec.template`, not a direct `Pod` object.
   * The `PodSecurity` admission plugin in `enforce` mode **only enforces constraints on direct `Pod` creation requests**. It does **not** reject high-level controller objects (`Deployments`, `StatefulSets`, `DaemonSets`, `Jobs`) during `enforce` evaluation, because doing so could block administrative changes or deployment updates.
   * However, `warn` and `audit` modes **do** inspect `PodTemplates` on controller objects to alert engineers immediately upon `kubectl apply`.
   * Once the `Deployment` object was accepted and persisted to `etcd`, the `kube-controller-manager`'s `replicaset-controller` attempted to spawn underlying `Pod` resources. Those pod creation API calls were evaluated individually by the `PodSecurity` admission controller, failed validation against `enforce=restricted`, and were blocked, resulting in `FailedCreate` events on the `ReplicaSet`.

2. **What specific security context settings were required for `restricted` compliance?**
   * **Pod-Level Security Context (`spec.securityContext`)**:
     * `runAsNonRoot: true`: Ensures the container runtime enforces non-root execution (UID != 0).
     * `runAsUser: 10001` & `runAsGroup: 10001`: Explicitly sets non-root UID/GID values.
     * `seccompProfile.type: RuntimeDefault`: Enforces the container runtime's default secure system call filter profile (blocking dangerous syscalls like `unshare`, `kexec_load`).
   * **Container-Level Security Context (`spec.containers[*].securityContext`)**:
     * `allowPrivilegeEscalation: false`: Prevents child processes from gaining more privileges than their parent process (disables `setuid` binaries via `PR_SET_NO_NEW_PRIVS`).
     * `capabilities.drop: ["ALL"]`: Removes all Linux capabilities (e.g., `CAP_NET_RAW`, `CAP_SYS_CHROOT`, `CAP_DAC_OVERRIDE`) assigned by default to rootless/root container processes.

3. **Why mount `emptyDir` volumes when using `readOnlyRootFilesystem: true`?**
   * Setting `readOnlyRootFilesystem: true` mounts the container's root (`/`) storage layer as read-only.
   * Standard applications (like Nginx) frequently write transient runtime data, PID files, or cache files to directories such as `/tmp`, `/var/cache/nginx`, and `/var/run`.
   * Without mounting ephemeral writable volumes (such as `emptyDir` memory or disk backed volumes) at these specific target paths, the application process crashes with `IOError: Read-only file system` upon startup.

---

### Solutions for Exercise 3 Verification Questions

1. **What is the outcome for a violating Pod created in an exempted namespace?**
   * **Result**: The API server **bypasses all PSS checks** (`enforce`, `audit`, `warn`) for that Pod creation request.
   * **Mechanics**: During admission evaluation, the `PodSecurity` plugin first checks the global `exemptions` rules defined in `PodSecurityConfiguration`. Because the namespace `monitoring` is matched by `exemptions.namespaces`, evaluation terminates early with an immediate `ALLOW` decision, skipping profile checks regardless of labels attached to the `monitoring` namespace.

2. **What risk does `exemptions.usernames` introduce?**
   * **Security Risk**: If a service account or user identity (e.g., `system:serviceaccount:kube-system:storage-provisioner`) is granted a global exemption, any actor or compromised workload capable of impersonating or stealing the Service Account Token (JWT) of that service account can bypass Pod Security Admission cluster-wide.
   * An attacker with access to an exempted service account can spawn fully privileged pods (`privileged: true`, mounting host `/etc` via `hostPath`), breaking out of container isolation to compromise the underlying Node and API Server. Exemptions should strictly be minimized and audited continuously.

</details>