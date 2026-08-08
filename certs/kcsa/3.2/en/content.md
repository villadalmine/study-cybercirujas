# KCSA Exam Preparation Guide: Section 3.2 – Pod Security Admission (PSA) & Pod Security Standards (PSS)

---

## 1. Architectural Problem & Production Motivation

### The Multi-Tenant Workload Security Challenge
In multi-tenant Kubernetes clusters, workloads owned by different teams share the underlying worker nodes, Linux kernel, network interface controllers, and storage primitives. Without kernel-level isolation boundaries and admission-time enforcement, a single compromised container operating with elevated privileges can break out of its container rootfs, access the host node's root filesystem, read host network sockets, or compromise adjacent tenant workloads.

Historically, Kubernetes relied on **PodSecurityPolicy (PSP)** to enforce security boundaries at admission time. PSP was deprecated in Kubernetes v1.21 and completely removed in v1.25 due to fundamental architectural flaws:
1. **Unpredictable Authorization Coupling:** PSP bound policies to users and service accounts via RBAC (`use` verb on `podsecuritypolicies`). Evaluating which policy applied to a given Pod creation request depended on complex user/SA impersonation ordering, leading to unintended authorization leakage.
2. **In-Place Mutation Side Effects:** PSP could mutate Pod specifications (e.g., automatically injecting default `runAsUser` or `seccomp` settings). This mutation broke declarative GitOps workflows, as the manifest stored in Git differed from the live object in `etcd`, causing constant drift in tools like ArgoCD and Flux.
3. **Operational Complexity:** Enabling PSP required cluster-wide rollout without granular soft-enforcement mechanisms (such as dry-run warnings), often breaking system components and ingress controllers upon activation.

### The Built-in Solution: Pod Security Admission (PSA)
Starting in Kubernetes v1.22 (GA in v1.23/v1.25+), **Pod Security Admission (PSA)** replaced PSP as the official, native admission controller implementing the **Pod Security Standards (PSS)** framework.

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                 API Server Pipeline                     │
                  └─────────────────────────────────────────────────────────┘
                                               │
   kubectl apply -f pod.yaml                   ▼
 ───────────────► [Authentication] ──► [Authorization]
                                               │
                                               ▼
                                 ┌───────────────────────────┐
                                 │   Mutating Webhook Phase  │
                                 └───────────────────────────┘
                                               │
                                               ▼
                                 ┌───────────────────────────┐
                                 │  Pod Security Admission   │◄── Validating Admission
                                 │       (Built-in PSA)      │    Plugin (In-Tree)
                                 └───────────────────────────┘
                                   /           │           \
                         Enforce  /      Audit │            \ Warn
                                 ▼             ▼             ▼
                           [ Reject /     [ Annotate    [ HTTP Warning
                             Allow ]      Audit Log ]     Header ]
                                 │             │             │
                                 └─────────────┼─────────────┘
                                               │
                                               ▼
                                 ┌───────────────────────────┐
                                 │ etcd Persistence / Engine │
                                 └───────────────────────────┘
```

PSA operates as an in-tree Validating Admission Webhook plugin. It evaluates Pod creation and update requests against predefined security levels defined by PSS without performing mutations.

### The Three Pod Security Standards (PSS) Levels
1. **Privileged:** Unrestricted policy. Allows root containers, host namespaces (`hostPID`, `hostNetwork`, `hostIPC`), host paths, and arbitrary Linux capabilities (`CAP_SYS_ADMIN`). Designed for infrastructure workloads (e.g., CNI plugins, storage drivers, node feature discovery).
2. **Baseline:** Minimally restrictive policy. Prevents known privilege escalation vectors (blocks host access, host ports, dangerous capabilities like `CAP_SYS_ADMIN`, and restricted volume types) while allowing default container configurations.
3. **Restricted:** Heavily hardened policy targeting multi-tenant application workloads. Enforces strict security contexts: enforces non-root execution (`runAsNonRoot: true`), drops all capabilities (`capabilities.drop: ["ALL"]`), enforces read-only root filesystems where appropriate, and requires explicit seccomp profile declaration (`runtime/default` or `localhost`).

### The Three PSA Evaluation Modes
PSA can apply any PSS level independently across three modes per Namespace:
* **Enforce:** Hard validation. Pod creation requests violating the policy are rejected immediately at the API server boundary.
* **Audit:** Soft validation. Violations do not block pod creation; instead, audit annotations (`pod-security.kubernetes.io/audit-violations`) are appended to the event and written to the API server audit log for SIEM processing.
* **Warn:** User feedback mode. Violations return standard HTTP warning response headers (`Warning: 299 KubeAPIWarningResponse`) directly to the client (`kubectl`, CI/CD pipeline) while allowing the pod creation request to proceed.

---

## 2. Technical Comparison & Trade-off Tables

### Table 2.1: Architectural Evolution & Engine Comparison

| Architectural Attribute | PodSecurityPolicy (PSP) [Deprecated/Removed] | Built-in Pod Security Admission (PSA) | Policy Engines (OPA Gatekeeper / Kyverno) |
| :--- | :--- | :--- | :--- |
| **Status / Lifecycle** | Removed in K8s v1.25 | Native / Built-in GA (v1.25+) | Third-Party CNCF Ecosystem Projects |
| **Mutation Capability** | Yes (Mutates Pod specs, breaking GitOps) | **No** (Strictly validating / non-mutating) | Yes (Supports JSON Patch / Strategic Merge mutations) |
| **Configuration Model** | Cluster-wide CRDs + RBAC bindings | Namespace labels + API Server Config | Custom Resources (ConstraintTemplates, ClusterPolicy) |
| **Operational Overhead** | High (Complex RBAC debugging) | **Zero** (In-tree, no external controllers) | Moderate to High (Requires dedicated pods/CRDs/webhooks) |
| **Custom Rule Logic** | No (Fixed rule set) | No (Fixed PSS levels: Privileged, Baseline, Restricted) | **Yes** (Arbitrary Rego queries or YAML match rules) |
| **Resource Footprint** | Shared API Server memory | **Zero additional footprint** | CPU/Memory overhead for webhook controllers |
| **Evaluation Performance**| Fast (In-tree code execution) | **Extremely Fast** (In-process API server validation) | Network roundtrip latency to validating webhook pod |

### Table 2.2: Pod Security Standards (PSS) Control Matrix

| Security Parameter | Privileged Level | Baseline Level | Restricted Level |
| :--- | :--- | :--- | :--- |
| **Host Namespaces (`hostNetwork`, `hostPID`, `hostIPC`)** | Allowed | **Forbidden** | **Forbidden** |
| **Host Ports (`hostPort`)** | Allowed | **Forbidden** (Must be 0) | **Forbidden** (Must be 0) |
| **Privileged Containers (`privileged`)** | Allowed | **Forbidden** | **Forbidden** |
| **Capabilities (`capabilities`)** | All Allowed | Blocks dangerous capabilities (`SYS_ADMIN`, `NET_ADMIN`) | **Must drop ALL** (`capabilities.drop: ["ALL"]`); optionally add back `NET_BIND_SERVICE` |
| **Host Path Volumes (`hostPath`)** | Allowed | **Forbidden** | **Forbidden** |
| **Privilege Escalation (`allowPrivilegeEscalation`)** | Allowed | Allowed | **Must be explicit `false`** |
| **Running as Root (`runAsNonRoot`, `runAsUser`)** | Allowed | Allowed | **`runAsNonRoot: true` required** (or explicitly set UID > 0) |
| **Seccomp Profile (`seccompProfile`)** | Allowed | Allowed | **Must be `RuntimeDefault` or `Localhost`** |
| **Volume Types Allowed** | All | All except `hostPath` | Restricted to `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret` |

---

## 3. Production-Ready YAML Manifests & Infrastructure Configurations

### 3.1 Namespace Definitions with PSA Labels
This manifest configures a multi-stage, multi-tier namespace security topology.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing-prod
  labels:
    # 1. ENFORCE MODE: Enforce Restricted level targeting current K8s version
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    
    # 2. AUDIT MODE: Log violations to API Server Audit log if policy shifts
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    
    # 3. WARN MODE: Provide early warnings to deployment pipelines
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
---
apiVersion: v1
kind: Namespace
metadata:
  name: system-monitoring-infra
  labels:
    # Infrastructure namespaces requiring Host Metrics and Privileged access
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: latest
```

---

### 3.2 Cluster-Wide Admission Configuration File (`admission-config.yaml`)
Pass this file to the `kube-apiserver` via flag `--admission-control-config-file=/etc/kubernetes/admission/pod-security-config.yaml`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1
    kind: PodSecurityConfiguration
    
    # Defaults applied to any Namespace missing explicit pod-security.kubernetes.io labels
    defaults:
      enforce: "baseline"
      enforce-version: "v1.30"
      audit: "restricted"
      audit-version: "v1.30"
      warn: "restricted"
      warn-version: "latest"
      
    # Global Exemptions: Systems that bypass PSA validation rules
    exemptions:
      # Excluded Authenticated Users/ServiceAccounts
      usernames:
        - "system:serviceaccount:kube-system:node-problem-detector"
        - "system:serviceaccount:cert-manager:cert-manager-controller"
        
      # Excluded Authenticated Groups
      authenticatedGroups:
        - "system:masters"
        
      # Excluded Namespaces
      namespaces:
        - "kube-system"
        - "kube-public"
        - "storage-system"
        
      # Excluded RuntimeClasses (e.g., sandboxed containers like Kata or gVisor)
      runtimeClasses:
        - "kata-containers"
        - "gvisor"
```

---

### 3.3 Target Test Pod Manifests

#### Non-Compliant Pod (Rejection Target under `restricted` level)
This Pod intentionally breaks every rule of the `restricted` PSS profile.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: payment-processing-prod
spec:
  hostNetwork: true
  hostPID: true
  containers:
  - name: insecure-app
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["/agnhost", "netexec", "--http-port=8080"]
    securityContext:
      privileged: true
      allowPrivilegeEscalation: true
      runAsUser: 0
      capabilities:
        add:
          - SYS_ADMIN
          - NET_ADMIN
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /
```

#### Fully Compliant Production Pod (`restricted` level compliant)
This Pod adheres strictly to all PSS `restricted` rules.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-production-app
  namespace: payment-processing-prod
  labels:
    app.kubernetes.io/name: secure-payment-api
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: payment-api
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["/agnhost", "netexec", "--http-port=8080"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
    resources:
      limits:
        cpu: "500m"
        memory: "256Mi"
      requests:
        cpu: "100m"
        memory: "128Mi"
    volumeMounts:
    - name: tmp-dir
      mountPath: /tmp
  volumes:
  - name: tmp-dir
    emptyDir: {}
```

---

## 4. Step-by-Step CLI Execution & Real Terminal Outputs

### 4.1 Applying PSA Labels to Namespaces
Label a targeted namespace and verify label configuration.

```bash
$ kubectl create namespace secure-banking-prod
namespace/secure-banking-prod created

$ kubectl label --overwrite namespace secure-banking-prod \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.30 \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=v1.30
namespace/secure-banking-prod labeled

$ kubectl get ns secure-banking-prod --show-labels
NAME                  STATUS   AGE   LABELS
secure-banking-prod   Active   22s   kubernetes.io/metadata.name=secure-banking-prod,pod-security.kubernetes.io/audit-version=v1.30,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.30,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/warn-version=latest,pod-security.kubernetes.io/warn=restricted
```

---

### 4.2 Testing Rejection of Non-Compliant Pod (Enforce Mode)
Attempting to deploy the non-compliant pod manifest into `secure-banking-prod`.

```bash
$ kubectl apply -f non-compliant-pod.yaml
Error from server (Forbidden): error when creating "non-compliant-pod.yaml": pods "non-compliant-workload" is forbidden: violates PodSecurity "restricted:v1.30": hostNetwork (spec.hostNetwork=true), hostPID (spec.hostPID=true), privileged (container "insecure-app" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "insecure-app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "insecure-app" must set securityContext.capabilities.drop=["ALL"]; container "insecure-app" add list includes disallowed capabilities "NET_ADMIN", "SYS_ADMIN"), runAsNonRoot != true (pod or container "insecure-app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "insecure-app" must not set securityContext.runAsUser=0), seccompProfile (pod or container "insecure-app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost"), hostPath volumes (volume "host-root")
```

---

### 4.3 Testing Warning Headers during Pod Creation (Warn Mode)
Temporarily modify the enforce mode to `baseline` while keeping warn mode at `restricted` to observe dry-run HTTP warning outputs.

```bash
$ kubectl label --overwrite ns secure-banking-prod pod-security.kubernetes.io/enforce=baseline
namespace/secure-banking-prod labeled

$ kubectl apply -f semi-compliant-pod.yaml
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/semi-compliant-workload created
```

---

### 4.4 Successful Deployment of Hardened Workload
Deploying the fully compliant pod into the `restricted` namespace.

```bash
$ kubectl label --overwrite ns secure-banking-prod pod-security.kubernetes.io/enforce=restricted
namespace/secure-banking-prod labeled

$ kubectl apply -f hardened-pod.yaml -n secure-banking-prod
pod/hardened-production-app created

$ kubectl get pod hardened-production-app -n secure-banking-prod -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE           NOMINATED NODE   READINESS GATES
hardened-production-app   1/1     Running   0          18s   10.244.1.4   worker-node1   <none>           <none>
```

---

### 4.5 Dry-Run Label Change Across the Entire Cluster
Check what existing workloads would fail if all unlabeled namespaces were updated to `restricted`.

```bash
$ kubectl label --dry-run=server --overwrite ns --all \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.30
Warning: existing pods in namespace "default" violate the new PodSecurity enforce level "restricted:v1.30"
Warning: existing pod "legacy-deployment-64d8586c9b-z8k9l" in namespace "default" violates PodSecurity "restricted:v1.30": allowPrivilegeEscalation != false, runAsNonRoot != true, seccompProfile
Warning: existing pods in namespace "kube-system" violate the new PodSecurity enforce level "restricted:v1.30"
namespace/default labeled (dry run)
namespace/kube-node-lease labeled (dry run)
namespace/kube-public labeled (dry run)
namespace/kube-system labeled (dry run)
namespace/secure-banking-prod labeled (dry run)
```

---

## 5. Failure Diagnosis & Troubleshooting Runbook

### 5.1 Systemic Diagnostic Matrix

```
                      PSA Rejection / Escalation Flowchart
                                        │
                         [ Deployment Attempt Rejected ]
                                        │
                                        ▼
                  Is request originating from a Controller?
                 (Deployment / ReplicaSet / StatefulSet / Job)
                                 /            \
                           YES  /              \ NO (Direct Pod)
                               v                v
            ┌──────────────────────────┐    ┌───────────────────────────┐
            │ Deployment created successfully, │    │ Direct API call denied    │
            │ but ReplicaSet fails to  │    │ with HTTP 403 Forbidden   │
            │ create target Pods!      │    │ output in terminal.       │
            └──────────────────────────┘    └───────────────────────────┘
                         │                                │
                         ▼                                ▼
            Inspect `kubectl describe rs`    Inspect client output &
            or `kubectl get events`          Namespace Labels directly.
```

---

### 5.2 Diagnostic Step 1: Controller Template vs. Direct Pod Creation Failure
When using higher-level abstractions (`Deployments`, `StatefulSets`, `Jobs`), creating the parent object **succeeds** because the API Server only checks the `Deployment` spec. However, the child `ReplicaSet` fails to spawn Pods because the pod template fails PSA validation.

**Diagnostic Commands:**

```bash
# 1. Check Deployment Status
$ kubectl get deployment payment-service -n payment-processing-prod
NAME              READY   UP-TO-DATE   AVAILABLE   AGE
payment-service   0/3     0            0           2m14s

# 2. Inspect ReplicaSet Events (where the PSA rejection is trapped)
$ kubectl describe replicaset -l app.kubernetes.io/name=payment-service -n payment-processing-prod
...
Events:
  Type     Reason        Age                  From                   Message
  ----     ------        ----                 ----                   -------
  Warning  FailedCreate  45s (x8 over 2m12s)  replicaset-controller  Error creating: pods "payment-service-589d877884-9z2lp" is forbidden: violates PodSecurity "restricted:v1.30": allowPrivilegeEscalation != false (container "payment-app" must set securityContext.allowPrivilegeEscalation=false)
```

---

### 5.3 Diagnostic Step 2: Investigating Audit Logs for Audit Violations
If PSA is set to `audit: restricted`, violations do not block creation but write structured logs. Use `jq` to parse `kube-apiserver-audit.log`.

```bash
$ tail -f /var/log/kubernetes/audit/audit.log | grep "pod-security.kubernetes.io/audit-violations" | jq .
```

**Expected JSON Output extract:**

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "9c1b7a2d-4f12-4011-a831-29e2c608f51a",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/payment-processing-prod/pods",
  "verb": "create",
  "user": {
    "username": "system:serviceaccount:argo:argocd-application-controller",
    "groups": ["system:serviceaccounts", "system:serviceaccounts:argo"]
  },
  "objectRef": {
    "resource": "pods",
    "namespace": "payment-processing-prod",
    "name": "payment-batch-processor-x891"
  },
  "responseStatus": {
    "metadata": {},
    "status": "Success",
    "code": 201
  },
  "annotations": {
    "pod-security.kubernetes.io/audit-violations": "would violate PodSecurity \"restricted:v1.30\": allowPrivilegeEscalation != false (container \"worker\" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container \"worker\" must set securityContext.runAsNonRoot=true)"
  }
}
```

---

### 5.4 Diagnostic Step 3: Verifying Active API Server Exemptions
If a Pod runs despite breaking rules in a `restricted` namespace, check if global exemptions apply via `AdmissionConfiguration`.

1. Inspect the `kube-apiserver` pod manifest or systemd unit file for the `--admission-control-config-file` flag:

```bash
$ ps aux | grep kube-apiserver | grep admission-control-config-file
root 12401 ... --admission-control-config-file=/etc/kubernetes/admission/pod-security-config.yaml
```

2. Inspect the active configuration file on the Control Plane node to verify exemption scopes:

```bash
$ cat /etc/kubernetes/admission/pod-security-config.yaml
```

Check if the pod's `ServiceAccount`, `Namespace`, or `RuntimeClass` matches the listed exemptions under `exemptions.usernames`, `exemptions.namespaces`, or `exemptions.runtimeClasses`.

---

## 6. References

* **Kubernetes Official Documentation - Pod Security Standards:**  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/
* **Kubernetes Official Documentation - Pod Security Admission:**  
  https://kubernetes.io/docs/concepts/security/pod-security-admission/
* **Kubernetes Official Documentation - Enforce Pod Security Standards with Namespace Labels:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
* **Kubernetes Official Documentation - Configure Pod Security Admission via AdmissionConfiguration:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
* **CNCF KCSA Curriculum Repository:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf