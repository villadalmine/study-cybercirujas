# KCSA Topic 3.2: Pod Security Admission (PSA) & Pod Security Standards (PSS)

## 1. Deep Technical Foundations & Architecture

### 1.1 Architecture & Internal Mechanics
Kubernetes Pod Security Admission (PSA) is a built-in admission plugin implemented directly within the `kube-apiserver`. It evaluates incoming Pod creation and modification requests against defined **Pod Security Standards (PSS)** levels.

```
                   +-------------------------------------------------------+
                   |                   kube-apiserver                      |
                   |                                                       |
  kubectl / API ---> Mutating Admission ---> PodSecurity Admission ---> Validating Admission ---> Etcd
  Client Request   |    Plugins                Plugin (PSA)               Plugins          |
                   +-------------------------------------------------------+
                                                       |
                                           +-----------+-----------+
                                           | Evaluates PSS Levels  |
                                           +-----------------------+
                                           | 1. Privileged         |
                                           | 2. Baseline           |
                                           | 3. Restricted         |
                                           +-----------------------+
                                                       |
                                    +------------------+------------------+
                                    |                                     |
                             Enforce Mode                             Warn / Audit
                            (Blocks Request)                      (Allows & Records)
```

### 1.2 Evaluation Modes
PSA applies policies across three operational modes:

| Mode | Behavior on Violation | HTTP / Audit Response | Production Use Case |
| :--- | :--- | :--- | :--- |
| `enforce` | Rejects the Pod creation request. | HTTP 403 Forbidden | Hard enforcement for compliance in production namespaces. |
| `warn` | Allows request execution. | Returns `Warning:` headers to client CLI. | Soft notification during developer deployment pipelines. |
| `audit` | Allows request execution. | Appends `pod-security.kubernetes.io/audit-violations` annotation to API Audit logs. | Passive compliance monitoring and security posture analysis. |

### 1.3 Pod Security Standard (PSS) Levels

1. **Privileged**: Unrestricted execution. Provides absolute access to host network, PID/IPC namespaces, capabilities, and file paths.
2. **Baseline**: Prevents known privilege escalation vectors while retaining default application compatibility. Restricts host path mounts, host networking, host ports, and privileged container flags.
3. **Restricted**: Applies current hardening best practices. Requires:
   - Explicit execution as non-root (`runAsNonRoot: true`, non-zero `runAsUser`).
   - Disabling privilege escalation (`allowPrivilegeEscalation: false`).
   - Dropping `ALL` linux capabilities (adding back specific required ones like `NET_BIND_SERVICE`).
   - Configuring explicit Seccomp profiles (`RuntimeDefault` or `Localhost`).
   - Optional read-only root filesystems (`readOnlyRootFilesystem: true`).

### 1.4 Namespace-Level vs. Cluster-Wide Configuration
- **Namespace-Level**: Driven by labels applied directly to the `Namespace` API object (`pod-security.kubernetes.io/<mode>: <level>`).
- **Cluster-Wide**: Configured via the API Server flag `--admission-control-config-file` pointing to a `PodSecurityConfiguration` file (`pod-security.admission.config.k8s.io/v1`).

---

## 2. Official Reference Sources
- **CNCF KCSA Curriculum**: [KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Pod Security Standards**: [Kubernetes PSS Documentation](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- **Kubernetes Pod Security Admission**: [Kubernetes PSA Documentation](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- **PodSecurityConfiguration Reference**: [PSA Configuration Guide](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/)

---

## 3. Hands-On Guided Exercises

### Lab 1: Namespace-Level Pod Security Admission Policy Management

#### Objective
Configure a multi-stage namespace policy that enforces `baseline` security while warning developers and auditing against `restricted` standard violations.

#### Step 1.1: Create target namespace and inspect initial label state
Run the following command to create namespace `sec-production`:

```bash
kubectl create namespace sec-production
```

**Expected Output:**
```text
namespace/sec-production created
```

#### Step 1.2: Apply PSA configuration labels to the namespace
Apply the labels for `enforce=baseline`, `warn=restricted`, and `audit=restricted` pinned to Kubernetes version `v1.30`.

```bash
kubectl label --overwrite namespace sec-production \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.30 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.30 \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=v1.30
```

**Expected Output:**
```text
namespace/sec-production labeled
```

#### Step 1.3: Verify label application
Verify that the namespace labels are active:

```bash
kubectl get ns sec-production -o jsonpath='{.metadata.labels}' | jq .
```

**Expected Output:**
```json
{
  "kubernetes.io/metadata.name": "sec-production",
  "pod-security.kubernetes.io/audit": "restricted",
  "pod-security.kubernetes.io/audit-version": "v1.30",
  "pod-security.kubernetes.io/enforce": "baseline",
  "pod-security.kubernetes.io/enforce-version": "v1.30",
  "pod-security.kubernetes.io/warn": "restricted",
  "pod-security.kubernetes.io/warn-version": "v1.30"
}
```

#### Step 1.4: Deploy a baseline-compliant, non-restricted workload
Apply the following manifest for a standard non-privileged NGINX pod:

```yaml
cat <<EOF | kubectl apply -n sec-production -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-baseline
spec:
  containers:
  - name: nginx
    image: nginx:1.25-alpine
EOF
```

**Expected Output:**
```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "nginx" must not set runAsUser=0), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/nginx-baseline created
```

#### Step 1.5: Attempt to deploy a workload violating `enforce=baseline`
Attempt to create a pod configured with `hostNetwork: true` and `privileged: true`.

```yaml
cat <<EOF | kubectl apply -n sec-production -f -
apiVersion: v1
kind: Pod
metadata:
  name: privileged-violator
spec:
  hostNetwork: true
  containers:
  - name: exploit
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
EOF
```

**Expected Output:**
```text
Error from server (Forbidden): error when creating "STDIN": pods "privileged-violator" is forbidden: violates PodSecurity "baseline:v1.30": hostNetwork (spec.hostNetwork=true), privileged (container "exploit" must not set securityContext.privileged=true)
```

---

#### Verification Questions — Lab 1
1. **Q1.1**: Why was `nginx-baseline` allowed to be created despite triggering a `Warning:` message?
2. **Q1.2**: If `pod-security.kubernetes.io/enforce-version` is omitted, which version does PSA use to evaluate incoming requests?

---

### Lab 2: Fully Hardened Workload Compliant with PSS `restricted`

#### Objective
Construct a syntactically valid Kubernetes Deployment manifest that satisfies all constraints of `pod-security.kubernetes.io/enforce=restricted` without emitting warnings or audit triggers.

#### Step 2.1: Enforce `restricted` standard on namespace
Update the namespace `sec-production` to enforce `restricted`:

```bash
kubectl label --overwrite namespace sec-production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

**Expected Output:**
```text
namespace/sec-production labeled
```

#### Step 2.2: Apply complete, hardened deployment manifest
Create the hardened workload manifest:

```yaml
cat <<EOF | kubectl apply -n sec-production -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: sec-production
  labels:
    app.kubernetes.io/name: secure-app
    app.kubernetes.io/part-of: financial-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: busybox:1.36
        command: ["sh", "-c", "echo App is running safely && sleep 3600"]
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
EOF
```

**Expected Output:**
```text
deployment.apps/secure-app created
```

#### Step 2.3: Verify Deployment rollout status
Check that the replica set successfully created the Pods without admission controller rejection.

```bash
kubectl rollout status deployment/secure-app -n sec-production --timeout=30s
```

**Expected Output:**
```text
deployment "secure-app" successfully rolled out
```

---

#### Verification Questions — Lab 2
1. **Q2.1**: If `runAsNonRoot: true` is set in the Pod's `securityContext`, but the container image metadata specifies `USER root` (or UID 0) without explicit `runAsUser` in the manifest, what will occur at admission time vs runtime?
2. **Q2.2**: Which linux capability must be added back if a non-root application within `restricted` profile needs to bind to port 80?

---

### Lab 3: Cluster-Wide `PodSecurityConfiguration` and Exemption Management

#### Objective
Configure global cluster-wide Pod Security Admission policies using the `PodSecurityConfiguration` API file, setting default restrictions while defining granular user and namespace exemptions.

#### Step 3.1: Construct `PodSecurityConfiguration` manifest
Create a valid configuration file `/etc/kubernetes/admission/pod-security-config.yaml`:

```yaml
cat <<EOF > /tmp/pod-security-config.yaml
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
  runtimeClasses:
    - "gvisor"
    - "kata-containers"
  namespaces:
    - "kube-system"
    - "security-monitoring"
EOF
```

#### Step 3.2: Verify configuration file syntax
Validate the YAML schema structure using `kubectl`:

```bash
kubectl alpha dry-run --filename=/tmp/pod-security-config.yaml 2>&1 || true
```

#### Step 3.3: Dry-run check for namespace security check using `kubectl label`
Test how existing workloads in an unlabelled namespace `legacy-apps` are evaluated against a proposed policy before enforcing it:

```bash
kubectl create namespace legacy-apps
cat <<EOF | kubectl apply -n legacy-apps -f -
apiVersion: v1
kind: Pod
metadata:
  name: legacy-pod
spec:
  containers:
  - name: legacy
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF
```

Apply dry-run evaluation on the namespace:

```bash
kubectl label --dry-run=server namespace legacy-apps \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

**Expected Output:**
```text
Warning: existing pods in namespace "legacy-apps" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-pod: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, runAsUser=0, seccompProfile
namespace/legacy-apps labeled (server dry run)
```

---

#### Verification Questions — Lab 3
1. **Q3.1**: What is the key evaluation difference between `usernames` exemptions in `PodSecurityConfiguration` vs namespace label exemptions?
2. **Q3.2**: How does PSA handle Pod updates (e.g., modifying `metadata.labels` on an existing Pod) compared to Pod creation?

---

## 4. Troubleshooting & Diagnostic Commands

### 4.1 Audit Log Analysis for Security Violations
When PSA operates in `audit` mode, violations do not block pod creation. Inspect audit log entries to identify violations:

```bash
# Querying API server audit logs for PSA violation annotations
grep "pod-security.kubernetes.io/audit-violations" /var/log/kubernetes/kube-apiserver-audit.log | jq '{
  timestamp: .stageTimestamp,
  user: .user.username,
  verb: .verb,
  namespace: .objectRef.namespace,
  pod: .objectRef.name,
  annotations: .annotations
}'
```

### 4.2 Querying Namespace Security Configurations
Inspect all namespaces lacking explicit `enforce` labels:

```bash
kubectl get namespaces -o json | jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] == null) | .metadata.name'
```

---

## Solutions & Answer Key

<details>
<summary>Click to expand Answer Key & Verification Explanations</summary>

### Lab 1 Solutions

- **A1.1**: `nginx-baseline` violated the `restricted` standard. However, the namespace configuration set `enforce=baseline` (which allows standard non-privileged pods) and `warn=restricted`. Therefore, the request was allowed, but a warnings header detailing the `restricted` violations was returned to the client.
- **A1.2**: If `pod-security.kubernetes.io/enforce-version` is not explicitly set, PSA defaults to `latest`. This means the policy rules tracked by the version of the running `kube-apiserver` binary are used. In production, pinning the version (e.g., `v1.30`) is recommended to avoid breaking workloads during Kubernetes control plane minor upgrades.

---

### Lab 2 Solutions

- **A2.1**: 
  - **Admission Time**: PSA checks the `PodSpec` security context. If `runAsNonRoot: true` is defined in the manifest, PSA considers the Pod compliant with the `restricted` policy at admission time and allows creation.
  - **Runtime**: When Kubelet attempts to start the container image, it inspects the image metadata. If the image runs as UID 0 and `runAsUser` was not specified in the spec, Kubelet will fail to start the container, emitting a runtime `ContainerCannotRun` error: *"container has runAsNonRoot and image will run as root"*.
- **A2.2**: The capability `CAP_NET_BIND_SERVICE` must be added back under `securityContext.capabilities.add: ["NET_BIND_SERVICE"]` after dropping `ALL`.

---

### Lab 3 Solutions

- **A3.1**: `usernames` exemptions can **only** be configured at the cluster-wide level inside the `PodSecurityConfiguration` file loaded by the API server. They **cannot** be defined via Namespace labels. This prevents namespace admins from bypassing security restrictions by setting labels.
- **A3.2**: PSA applies a special evaluation policy for existing Pod updates. If a field governed by PSS (such as `spec.containers[*].securityContext`) is **not** modified during an update operation, PSA skips re-evaluating the Pod spec. This prevents existing workloads from breaking if the namespace PSS enforcement level is updated while the Pod is running.

</details>