# KCSA Advanced Study Guide: Topic 3.1 – Pod Security Standards (PSS) & Pod Security Admission (PSA)

---

## 1. Motivation and Production Architectural Problem

In cloud-native multi-tenant Kubernetes clusters, containers share the underlying host Linux kernel. Without strict runtime boundary controls, a compromised container can trivialise host compromise, node takeover, or cluster-wide lateral movement. 

### The Security Vulnerability Vectors
Standard Kubernetes workloads run by default without security context restrictions. This permissive default state presents several high-risk attack vectors:
1. **Container Escape via Linux Capabilities**: A process executing with root inside a container and retaining Linux capabilities such as `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, or `CAP_NET_ADMIN` can modify host kernel parameters, load unverified kernel modules, or inspect processes across namespaces.
2. **Host Namespace Sharing**: Disabling isolation boundaries using `hostPID: true`, `hostIPC: true`, or `hostNetwork: true` allows containers to interact directly with host processes, shared memory segments, and network interfaces—bypassing container network interfaces (CNI) and NetworkPolicies.
3. **Arbitrary Storage Access**: Unrestricted `hostPath` volume mounts enable workloads to write to critical host locations such as `/var/run/docker.sock`, `/run/containerd/containerd.sock`, `/etc/kubernetes/manifests`, or `/var/lib/kubelet`, leading directly to node compromise.
4. **Privilege Escalation**: Processes inside containers can execute setuid binaries to elevate privileges if `allowPrivilegeEscalation` is set to `true` (the default when running as UID 0).

### The Evolution from PSP to PSS/PSA
Historically, Kubernetes relied on **PodSecurityPolicy (PSP)**. However, PSP presented severe architectural flaws:
* **Complex Binding Logic**: Enforcement relied on a combination of RBAC `ClusterRoles`, `Roles`, `ClusterRoleBindings`, and ServiceAccount permissions, making policy evaluation non-deterministic and difficult to audit at scale.
* **Mutation Side-Effects**: PSP automatically mutated Pod specifications (e.g., assigning default user IDs or security contexts), leading to drift between the applied manifest and the running object state.
* **Lack of Dry-Run / Warning Capabilities**: Applying a PSP immediately blocked non-compliant workloads, introducing massive operational risk during security rollouts in production.

PSP was deprecated in Kubernetes v1.21 and completely removed in v1.25. 

To replace PSP, Kubernetes introduced **Pod Security Standards (PSS)**—a declarative framework defining three distinct security profiles (`Privileged`, `Baseline`, `Restricted`)—and **Pod Security Admission (PSA)**—a built-in Admission Controller implementing KEP-2579 that evaluates incoming Pod specifications against PSS profiles without requiring third-party webhooks or mutating objects.

---

## 2. Technical Comparisons & Architectural Trade-offs

Pod Security Standards define three levels of security assurance:

```
+-----------------------------------------------------------------------+
|                              PRIVILEGED                               |
|   Unrestricted access. Designed for system components, CNI, CSI.       |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                               BASELINE                                |
|   Minimal friction. Prevents known privilege escalation vectors.      |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                               RESTRICTED                              |
|   Hardened best practices. Mandatory non-root, read-only root FS,     |
|   dropped capabilities, explicit seccomp profile enforcement.         |
+-----------------------------------------------------------------------+
```

### 2.1 Pod Security Standards Level Comparison

| Feature / Security Control | Privileged Level | Baseline Level | Restricted Level |
| :--- | :--- | :--- | :--- |
| **Target Workload Profile** | CNI, CSI plugins, system daemons, `kube-system` | Standard commercial off-the-shelf (COTS) apps, legacy services | Hardened production microservices, financial/regulated workloads |
| **Privileged Containers** | Allowed (`privileged: true`) | Blocked (`privileged: false`) | Blocked (`privileged: false`) |
| **Host Namespaces (`PID/IPC/Net`)** | Allowed | Blocked | Blocked |
| **Host Ports** | Unrestricted (`0-65535`) | Blocked | Blocked |
| **Allowed Host Volumes** | All types (including `hostPath`) | Blocks `hostPath` | Blocks `hostPath` |
| **Linux Capabilities** | All capabilities allowed | Blocked: `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_SYS_MODULE`, etc. | Must drop `ALL`. May conditionally re-add `NET_BIND_SERVICE`. |
| **Root Execution** | Allowed (UID 0 permitted) | Allowed (UID 0 permitted) | Blocked (`runAsNonRoot: true`, `runAsUser` > 0) |
| **Privilege Escalation** | Allowed | Allowed | Blocked (`allowPrivilegeEscalation: false`) |
| **Seccomp Profile** | Unrestricted | Unrestricted (`Unconfined` allowed) | Mandatory (`RuntimeDefault` or `Localhost`) |
| **Root Filesystem** | Read/Write allowed | Read/Write allowed | Encouraged / Standardized (`readOnlyRootFilesystem: true`) |
| **AppArmor Profiles** | Unrestricted | Unrestricted / Default | Restricted (`runtime/default` or `localhost/*`) |

---

### 2.2 Pod Security Admission (PSA) Operation Modes

PSA enforces policies across three distinct operational modes at the namespace level. Modes can be set concurrently for different levels or target Kubernetes API versions.

| Admission Mode | Evaluation Hook | API Response Behavior | Audit Log Impact | Production Use Case |
| :--- | :--- | :--- | :--- | :--- |
| `enforce` | Validating Admission Webhook phase | Blocks non-compliant Pod creation with a `403 Forbidden` status. | Creates an audit event recording the rejection. | Active enforcement in production namespaces after verification. |
| `warn` | Validating Admission Webhook phase | Allows Pod creation. Returns a human-readable warning header (`Warning: 299`) to the client (`kubectl` / CI/CD). | No audit logging by default unless combined with `audit`. | Testing policy impact on developer workflows without breaking deployments. |
| `audit` | Validating Admission Webhook phase | Allows Pod creation transparently. | Appends `pod-security.kubernetes.io/audit-violations` annotation to the K8s API audit log. | Gathering metrics and identifying non-compliant workloads in production prior to enforcement. |

---

### 2.3 Architectural Migration Matrix: PSP vs. PSA

| Dimension | PodSecurityPolicy (PSP) | Pod Security Admission (PSA) |
| :--- | :--- | :--- |
| **Architecture** | Built-in admission plugin relying on RBAC bindings | Built-in admission plugin driven by Namespace labels and API server config |
| **Mutation Support** | Yes (mutates Pod specs dynamically, causing config drift) | **No** (purely validating; zero mutation) |
| **Evaluation Scope** | Per-ServiceAccount or Per-User via RBAC | Per-Namespace via Labels (or cluster-wide defaults) |
| **Policy Definition** | Custom resource `PodSecurityPolicy` (cluster-scoped) | Standardized Kubernetes PSS levels (`Privileged`, `Baseline`, `Restricted`) |
| **Phased Rollout** | Extremely difficult (binary block/allow per binding) | Native multi-mode rollout (`warn` $\rightarrow$ `audit` $\rightarrow$ `enforce`) |
| **Performance Overhead** | High (RBAC authorization lookup per Pod creation) | Negligible (in-memory label and field evaluation) |

---

## 3. Complete Syntactically Valid YAML Manifests

### 3.1 Cluster-Wide Pod Security Admission Configuration
This configuration file must be passed to the `kube-apiserver` via the command-line flag `--admission-control-config-file=/etc/kubernetes/admission/pod-security-config.yaml`.

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
    - "system:serviceaccount:monitoring:prometheus-operator"
  runtimeClasses:
    - "kata-containers"
    - "gvisor"
  namespaces:
    - "kube-system"
    - "kube-public"
    - "cert-manager"
    - "ingress-nginx"
```

---

### 3.2 Production Namespace Labeling for PSA Enforcement

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing-prod
  labels:
    # Environment taxonomy
    environment: production
    tier: payment
    # Pod Security Admission Controls
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

---

### 3.3 Fully Compliant Restricted Pod Specification
This manifest adheres 100% to the **PSS Restricted Profile** requirements.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: compliant-payment-api
  namespace: payment-processing-prod
  labels:
    app.kubernetes.io/name: payment-api
    app.kubernetes.io/part-of: payment-system
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: api-server
      image: registry.internal.net/payments/api:v2.4.1
      imagePullPolicy: IfNotPresent
      command: ["/app/server"]
      ports:
        - containerPort: 8443
          name: https
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          cpu: "500m"
          memory: "512Mi"
        requests:
          cpu: "100m"
          memory: "128Mi"
      volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        - name: cache-volume
          mountPath: /app/cache
  volumes:
    - name: tmp-volume
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
    - name: cache-volume
      emptyDir:
        sizeLimit: 128Mi
```

---

### 3.4 Non-Compliant Pod Specification (Demonstrating PSA Rejection Violations)
Applying this manifest into a namespace with `pod-security.kubernetes.io/enforce: restricted` will trigger multiple policy evaluation failures.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: payment-processing-prod
spec:
  # VIOLATION 1: Host PID namespace sharing enabled
  hostPID: true
  # VIOLATION 2: Host Network enabled
  hostNetwork: true
  containers:
    - name: vulnerable-app
      image: nginx:latest
      # VIOLATION 3: Container running as root without explicit runAsNonRoot: true
      securityContext:
        # VIOLATION 4: Privileged container requested
        privileged: true
        # VIOLATION 5: Privilege escalation permitted
        allowPrivilegeEscalation: true
        # VIOLATION 6: Retaining capabilities and adding CAP_SYS_ADMIN
        capabilities:
          add:
            - SYS_ADMIN
            - NET_ADMIN
      volumeMounts:
        - name: host-root
          mountPath: /host
  volumes:
    # VIOLATION 7: Unrestricted hostPath mount
    - name: host-root
      hostPath:
        path: /
        type: Directory
```

---

## 4. Real CLI Commands and Terminal Outputs ($)

### 4.1 Dry-Run Labeling Evaluation of Existing Namespaces
Before enforcing policies on an active namespace, perform a dry-run to identify potential violations across running workloads.

```bash
$ kubectl label --overwrite ns production \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.30 \
    --dry-run=server
```

**Expected Terminal Output:**
```text
namespace/production labeled (server dry run)
Warning: existing pods in namespace "production" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-deployment-6799446d6b-x92zk (and 3 more): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

---

### 4.2 Applying Label Configuration to Live Namespace

```bash
$ kubectl label --overwrite namespace payment-processing-prod \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.30 \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=v1.30 \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=v1.30
```

**Expected Terminal Output:**
```text
namespace/payment-processing-prod labeled
```

---

### 4.3 Direct Blocked Deployment Execution (Privileged Pod Rejection)

```bash
$ kubectl apply -f non-compliant-pod.yaml
```

**Expected Terminal Output:**
```text
Error from server (Forbidden): error when creating "non-compliant-pod.yaml": pods "non-compliant-workload" is forbidden: violates PodSecurity "restricted:v1.30": host namespaces (hostPID=true, hostNetwork=true), privileged (container "vulnerable-app" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "vulnerable-app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "vulnerable-app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "vulnerable-app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "vulnerable-app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### 4.4 Indirect Deployment Block Execution (ReplicaSet Controller Lifecycle)
When applying a `Deployment` object that violates PSS, the Deployment resource creation succeeds because the API server validates the Deployment schema, not the nested Pod template inside spec.template. However, the `ReplicaSet` controller fails when attempting to create child Pods.

```bash
$ kubectl apply -f non-compliant-deployment.yaml
deployment.apps/bad-deployment created

$ kubectl get deployment bad-deployment
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
bad-deployment   0/1     0            0           12s

$ kubectl get rs
NAME                        DESIRED   CURRENT   READY   AGE
bad-deployment-7888796856   1         0         0       20s

$ kubectl describe rs bad-deployment-7888796856
```

**Expected Terminal Output:**
```text
Name:           bad-deployment-7888796856
Namespace:      payment-processing-prod
Selector:       app=bad-deployment,pod-template-hash=7888796856
Labels:         app=bad-deployment
                pod-template-hash=7888796856
Annotations:    deployment.kubernetes.io/revision: 1
Replicas:       0 current / 1 desired
Pods Status:    0 Running / 0 Waiting / 0 Succeeded / 0 Failed
Events:
  Type     Reason        Age                   From                   Message
  ----     ------        ----                  ----                   -------
  Warning  FailedCreate  4s (x8 over 24s)      replicaset-controller  (combined from similar events): Failed create pod pod-template-hash=7888796856-XXXXX: pods "bad-deployment-7888796856-XXXXX" is forbidden: violates PodSecurity "restricted:v1.30": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### 4.5 Applying Compliant Pod Manifest

```bash
$ kubectl apply -f compliant-pod.yaml
```

**Expected Terminal Output:**
```text
pod/compliant-payment-api created
```

```bash
$ kubectl get pod compliant-payment-api -o wide
```

**Expected Terminal Output:**
```text
NAME                    READY   STATUS    RESTARTS   AGE   IP           NODE         NOMINATED NODE   READINESS GATES
compliant-payment-api   1/1     Running   0          18s   10.244.3.4   worker-node4 <none>           <none>
```

---

## 5. Verification and Failure Diagnostic Guide

### 5.1 PSA Failure Decision Tree

```
                           [ Incoming Pod Request ]
                                      |
                                      v
                        Is Namespace Exempted in Config?
                                   /     \
                             YES  /       \ NO
                                 /         \
                         [ ALLOW ]          v
                                    Does Pod match Label 
                                    Enforce Level & Version?
                                       /          \
                                 YES  /            \ NO
                                     /              \
                             [ ALLOW ]               v
                                             Is 'enforce' Mode Set?
                                                /          \
                                          YES  /            \ NO
                                              /              \
                                     [ REJECT 403 ]          v
                                                     Is 'warn' Mode Set?
                                                        /          \
                                                  YES  /            \ NO
                                                      /              \
                                          [ RETURN WARNING ]     [ LOG AUDIT ]
```

---

### 5.2 Common PSA Violation Diagnostics & Remediation Matrix

| Diagnostic Error Message Snippet | Root Cause | Required SecurityContext Remediation |
| :--- | :--- | :--- |
| `allowPrivilegeEscalation != false` | `allowPrivilegeEscalation` omitted or set to `true`. | Set `container.securityContext.allowPrivilegeEscalation: false`. |
| `runAsNonRoot != true` | Pod or Container permits root execution (UID 0). | Set `securityContext.runAsNonRoot: true` and specify explicit `runAsUser: <non-zero>`. |
| `unrestricted capabilities` | Container capabilities have not dropped all defaults under `Restricted`. | Set `container.securityContext.capabilities.drop: ["ALL"]`. |
| `seccompProfile` | Seccomp profile missing or set to `Unconfined`. | Set `securityContext.seccompProfile.type: "RuntimeDefault"` or `"Localhost"`. |
| `hostPath volumes` | Spec contains `hostPath` volume mounts under `Baseline` or `Restricted`. | Replace `hostPath` with `emptyDir`, `persistentVolumeClaim`, or CSI ephemeral volumes. |
| `host namespaces (hostPID=true)` | Spec sets `hostPID`, `hostIPC`, or `hostNetwork` to `true`. | Remove host namespace attributes or set them explicitly to `false`. |

---

### 5.3 Extracting PSA Audit Log Events
When PSA operates in `audit` mode, violations do not block Pod creation. To inspect audit events emitted by the API server:

```bash
$ jq '. | select(.annotations["pod-security.kubernetes.io/audit-violations"] != null) | {time: .requestReceivedTimestamp, user: .user.username, namespace: .objectRef.namespace, pod: .objectRef.name, violations: .annotations["pod-security.kubernetes.io/audit-violations"]}' /var/log/kubernetes/audit/audit.log
```

**Example JSON Log Output:**
```json
{
  "time": "2026-08-07T19:44:02.104523Z",
  "user": "system:serviceaccount:jenkins:jenkins-runner",
  "namespace": "payment-processing-prod",
  "pod": "payment-batch-processor-98b7d",
  "violations": "allowPrivilegeEscalation != false (container \"processor\" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container \"processor\" must set securityContext.runAsNonRoot=true)"
}
```

---

### 5.4 Querying Prometheus Metrics for PSA Enforcement Activity
The Kubernetes API server exposes native Prometheus metrics tracking Pod Security Admission evaluations.

```bash
$ curl -s --cacert /etc/kubernetes/pki/ca.crt \
    --header "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    https://localhost:6443/metrics | grep apiserver_pod_security_submission_evaluations_total
```

**Sample Metric Output:**
```text
# HELP apiserver_pod_security_submission_evaluations_total [ALPHA] Total number of pod security evaluations.
# TYPE apiserver_pod_security_submission_evaluations_total counter
apiserver_pod_security_submission_evaluations_total{decision="deny",policy_level="restricted",policy_mode="enforce",request_kind="pod"} 42
apiserver_pod_security_submission_evaluations_total{decision="allow",policy_level="restricted",policy_mode="warn",request_kind="pod"} 128
```

---

## 6. References

* **Kubernetes Documentation: Pod Security Standards**  
  `https://kubernetes.io/docs/concepts/security/pod-security-standards/`

* **Kubernetes Documentation: Pod Security Admission**  
  `https://kubernetes.io/docs/concepts/security/pod-security-admission/`

* **CNCF KCSA Exam Curriculum Specifications**  
  `https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf`

* **Kubernetes Enhancement Proposal KEP-2579: Pod Security Admission**  
  `https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/2579-pod-security-admission`