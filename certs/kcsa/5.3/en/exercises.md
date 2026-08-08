# CNCF KCSA Certification: Topic 5.3 – Observability (Exam Weight: 2.29%)

## Technical Deep-Dive & Architecture Overview

Security observability in Kubernetes goes beyond standard application performance monitoring (APM). While telemetry traditionally focuses on metrics, logs, and traces for reliability and performance, **Security Observability** focuses on identifying security boundaries, detecting policy violations, uncovering unauthorized access attempts, and auditing system state changes in real time.

In a production Kubernetes cluster, security observability operates across three primary layers of the stack:

```
+-------------------------------------------------------------------------+
|                         API Server & Control Plane                       |
|  - Audit Logging Engine (Stages: RequestReceived, ResponseComplete, etc.)|
|  - Audit Levels: None, Metadata, Request, RequestResponse               |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                        Kernel & Runtime Layer                           |
|  - eBPF / Kernel Tracepoints / Syscall Hooking                          |
|  - Runtime Threat Detection Engines (e.g., Falco, Tetragon)            |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                      Network & Workload Layer                           |
|  - L4/L7 Flow Logs (Cilium/Hubble, Service Mesh / Envoy Access Logs)     |
|  - Security Telemetry Metrics (RBAC 401/403 rate, anomaly detection)    |
+-------------------------------------------------------------------------+
```

### 1. Kubernetes API Server Audit Logging Architecture

The API Server Audit Engine records every request processed by `kube-apiserver`. Each event passes through four audit stages:

1. `RequestReceived`: Logged immediately when the request handler receives the request, before delegation down the handler chain.
2. `ResponseStarted`: Logged once response headers are sent, but before the response body is streamed (used for long-running requests like `watch` or `exec`).
3. `ResponseComplete`: Logged after the response body is completed or closed.
4. `Panic`: Logged when a panic is generated during request processing.

#### Audit Levels & Performance Trade-offs

| Audit Level | Data Logged | Performance Impact | Primary Security Use Case |
| :--- | :--- | :--- | :--- |
| `None` | Nothing | Zero | Excluding high-frequency noise (e.g., `kubelet` status updates, endpoints sweeps). |
| `Metadata` | Request timestamp, URI, user info, verb, resource, namespace, response status code. | Low | General audit compliance, monitoring authorization failures (`401`/`403`). |
| `Request` | `Metadata` + Request payload (`Object` spec). | Medium | Auditing configuration changes (e.g., modifying `RoleBinding` or `PodDisruptionBudget`). |
| `RequestResponse` | `Metadata` + Request payload + Response body (`Object` status & payload). | High (Memory/I/O intensive) | High-security resources (e.g., tracking `Secret` read payloads, `ServiceAccount` token requests). |

> [!WARNING]
> Setting audit level to `RequestResponse` globally on resources like `ConfigMap` or `Secret` can lead to severe disk I/O bottlenecks and memory saturation on control plane nodes, as well as exposing plaintext sensitive data in log archives.

---

## Exercise 1: Advanced Kubernetes Audit Policy Configuration & Diagnostics

### Objectives
1. Design and deploy a production-grade syntactically valid `AuditPolicy` manifest.
2. Configure rules to audit sensitive operations (`exec`, `port-forward`, `secrets`, `rbac`) while omitting high-volume system noise.
3. Parse generated JSON audit logs using CLI diagnostics.

### Step 1: Create the Production Audit Policy Manifest
Create a file named `audit-policy.yaml` with the following configuration:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Never log authentication/authorization checks from node lease or health endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/livez*"
      - "/readyz*"
    
  - level: None
    users:
      - "system:kube-proxy"
      - "system:nodes"
    verbs:
      - "get"
      - "list"
      - "watch"
    resources:
      - group: ""
        resources: ["endpoints", "services", "configmaps"]

  # 2. Audit Pod Exec, Attach, and Port-Forward at ResponseStatus / Metadata level
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Audit Secret and ConfigMap modifications at Request level; read actions at Metadata level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]
    verbs:
      - "get"
      - "list"
      - "watch"

  - level: Request
    resources:
      - group: ""
        resources: ["secrets"]
    verbs:
      - "create"
      - "update"
      - "patch"
      - "delete"

  # 4. Audit RBAC changes at RequestResponse level to capture exactly what privileges were granted
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 5. Default rule for all other namespace-scoped resources
  - level: Metadata
    resources:
      - group: ""
      - group: "apps"
      - group: "batch"
```

### Step 2: Validate API Server Audit Flag Integration
Verify how `kube-apiserver` is configured to ingest this policy on control plane nodes. Inspect the Static Pod manifest `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```bash
sudo grep -E "audit-policy-file|audit-log-path|audit-log-maxbackup|audit-log-maxage|audit-log-maxsize" /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Expected Output:**
```text
    - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxbackup=10
    - --audit-log-maxage=30
    - --audit-log-maxsize=100
```

### Step 3: Trigger Security Events & Analyze JSON Logs
Simulate an unauthorized or sensitive action by attempting to execute a shell inside a pod and reading a Secret.

```bash
# Generate a Pod exec audit event
kubectl run security-test-pod --image=nginx:alpine --restart=Never
kubectl exec -it security-test-pod -- id

# Query the audit log for exec operations
sudo jq -r 'select(.verb=="create" and .objectRef.subresource=="exec") | {timestamp: .stageTimestamp, user: .user.username, pod: .objectRef.name, namespace: .objectRef.namespace}' /var/log/kubernetes/audit/audit.log
```

**Expected Output:**
```json
{
  "timestamp": "2026-08-07T20:25:12Z",
  "user": "kubernetes-admin",
  "pod": "security-test-pod",
  "namespace": "default"
}
```

### Step 4: Audit RBAC Privilege Escalation Events
Create a cluster role binding and audit the resulting event in real-time.

```bash
kubectl create clusterrolebinding suspicious-admin-binding --clusterrole=cluster-admin --user=dev-user

# Parse audit logs for RBAC clusterrolebinding creation
sudo jq -r 'select(.objectRef.resources=="clusterrolebindings" and .verb=="create") | {user: .user.username, binding: .objectRef.name, stage: .stage, level: .level}' /var/log/kubernetes/audit/audit.log
```

**Expected Output:**
```json
{
  "user": "kubernetes-admin",
  "binding": "suspicious-admin-binding",
  "stage": "ResponseComplete",
  "level": "RequestResponse"
}
```

---

### Verification Questions (Exercise 1)

1. **Question 1.1**: An engineer configures an `AuditPolicy` with a rule matching `verbs: ["get"]`, `resources: ["secrets"]` at the `RequestResponse` audit level. What critical operational risk does this introduce to control plane performance during high-throughput application operation?
2. **Question 1.2**: Why is the `RequestReceived` stage frequently added to `omitStages` in production audit policies?
3. **Question 1.3**: In an environment where log tampering by an attacker with node access is a threat, what architecture modification must be made to the API server audit logging backend?

---

## Exercise 2: Runtime Security Observability with Falco & eBPF

### Objectives
1. Configure custom Falco rules to observe host-level and container-level system execution anomalies.
2. Synthesize eBPF and kernel syscall events into structured security alerts.
3. Validate detection of container breakouts and execution of interactive shells in production workloads.

### Step 1: Write Custom Falco Security Rules
Create `/etc/falco/rules.d/custom-security-rules.yaml`:

```yaml
- rule: Unauthorized Shell Spawned in Container
  desc: Detects interactive shell execution inside a running container context
  condition: >
    spawned_process and 
    container and 
    proc.name in (bash, sh, zsh, ksh, ash) and 
    not user_known_shell_execution_activities
  output: >
    Security Alert: Shell spawned in container 
    (user=%user.name user_loginuid=%user.loginuid pod=%k8s.pod.name ns=%k8s.ns.name 
    container_id=%container.id image=%container.image.repository process=%proc.name cmdline=%proc.cmdline)
  priority: WARNING
  tags: [container, security, process, mitre_execution]

- rule: Sensitive File Access Below /etc in Container
  desc: Detects attempt to read or modify sensitive authentication files inside a container
  condition: >
    open_write or open_read and
    container and
    fd.name startswith /etc/shadow or fd.name startswith /etc/sudoers
  output: >
    Critical Violation: Sensitive file accessed in container
    (user=%user.name command=%proc.cmdline file=%fd.name pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: CRITICAL
  tags: [container, security, filesystem, mitre_credential_access]
```

### Step 2: Validate Falco DaemonSet / Systemd Service Status
Check that Falco is operating with the eBPF probe probe engine instead of kernel module hooks for high-performance non-intrusive monitoring.

```bash
# Verify falco engine status via falco-driver-loader or systemctl
systemctl status falco --no-pager
```

**Expected Output:**
```text
● falco.service - Falco: Container Native Runtime Security
     Loaded: loaded (/lib/systemd/system/falco.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-08-07 19:00:00 UTC; 1h ago
       Docs: https://falco.org/docs/
   Main PID: 41200 (falco)
      Tasks: 11 (limit: 4915)
     Memory: 84.2M
        CPU: 1.254s
     CGroup: /system.slice/falco.service
             └─41200 /usr/bin/falco -U -o json_output=true
```

### Step 3: Trigger Threat Signals and Capture Observability Output
Simulate a malicious actor executing an unauthorized shell and attempting to read `/etc/shadow` inside a target application pod.

```bash
# Run test pod
kubectl run web-app --image=nginx --restart=Never

# Trigger violation 1: Spawn shell
kubectl exec -it web-app -- /bin/sh -c "cat /etc/shadow"

# Inspect Falco JSON alerts from system log or stdout
journalctl -u falco -n 20 --no-pager | grep "Unauthorized Shell Spawned in Container"
```

**Expected Output:**
```json
{"severity":"Warning","time":"2026-08-07T20:28:44.102938472Z","rule":"Unauthorized Shell Spawned in Container","output":"Security Alert: Shell spawned in container (user=root user_loginuid=-1 pod=web-app ns=default container_id=a8f9c1e2b3d4 image=nginx process=sh cmdline=/bin/sh -c cat /etc/shadow)","output_fields":{"container.id":"a8f9c1e2b3d4","container.image.repository":"nginx","fd.name":null,"k8s.ns.name":"default","k8s.pod.name":"web-app","proc.cmdline":"/bin/sh -c cat /etc/shadow","proc.name":"sh","user.loginuid":-1,"user.name":"root"}}
```

---

### Verification Questions (Exercise 2)

1. **Question 2.1**: How does using an eBPF driver in Falco differ from the legacy kernel module approach in terms of kernel safety, performance overhead, and cluster node upgrade operations?
2. **Question 2.2**: If an attacker executes a statically compiled binary injected via `kubectl cp` that is named `/usr/bin/custom-tool` (which internally invokes `execve` on `/bin/sh`), will the `Unauthorized Shell Spawned in Container` rule above capture the event? Explain the syscall mechanism (`proc.name` vs `proc.cmdline`).

---

## Exercise 3: Network Flow Observability & Microsegmentation Auditing

### Objectives
1. Utilize eBPF-based flow logging (e.g., Cilium/Hubble) or Service Mesh proxy access logs to audit network egress and ingress flows.
2. Detect unauthorized cross-namespace communication and dropped connection attempts.
3. Construct network observability filters to verify NetworkPolicy compliance.

### Step 1: Deploy a Deny-All NetworkPolicy with Logging/Auditing
Deploy a restrictive baseline `NetworkPolicy` manifest:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: secure-space
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

Create the target namespace and deploy a probe workload:

```bash
kubectl create namespace secure-space
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: isolated-workload
  namespace: secure-space
  labels:
    app: secure-api
spec:
  containers:
  - name: alpine
    image: alpine
    command: ["sleep", "3600"]
EOF
```

### Step 2: Observe Network Traffic Flows via Hubble eBPF CLI
Use the Hubble CLI tool to inspect kernel-level eBPF network trace events in real time.

```bash
# Query network flows for dropped packets due to NetworkPolicy enforcement
hubble observe --namespace secure-space --verdict DROP --output json
```

Now trigger a violation from inside the isolated container:

```bash
# Attempt unauthorized external egress connection
kubectl exec -n secure-space isolated-workload -- nc -zw2 8.8.8.8 53
```

**Expected Hubble CLI Output:**
```json
{
  "flow": {
    "time": "2026-08-07T20:31:05.819231920Z",
    "verdict": "DROP",
    "drop_reason": 133,
    "auth_type": "DISABLED",
    "ethernet": {
      "source": "aa:bb:cc:dd:ee:ff",
      "destination": "00:11:22:33:44:55"
    },
    "IP": {
      "source": "10.244.1.45",
      "destination": "8.8.8.8",
      "ipVersion": "IPv4"
    },
    "l4": {
      "TCP": {
        "source_port": 49202,
        "destination_port": 53
      }
    },
    "source": {
      "id": 1204,
      "namespace": "secure-space",
      "labels": ["k8s:app=secure-api", "k8s:io.kubernetes.pod.namespace=secure-space"],
      "pod_name": "isolated-workload"
    },
    "destination": {
      "id": 2,
      "identity": 2,
      "labels": ["reserved:world"]
    },
    "Type": "TO_STACK",
    "node_name": "worker-node-1",
    "summary": "TCP Flags: SYN"
  }
}
```

### Step 3: Analyze Envoy Proxy L7 Access Logs for mTLS & HTTP Policy Auditing
In a Service Mesh architecture (e.g., Istio/Envoy), verify mTLS state and authorization failures (`403 RBAC access denied`) via proxy sidecar logs:

```bash
kubectl logs -n secure-space isolated-workload -c istio-proxy --tail=100 | grep "rbac_access_denied"
```

**Expected Output:**
```text
[2026-08-07T20:33:12.112Z] "GET /api/v1/admin HTTP/1.1" 403 rbac_access_denied - "-" 0 19 1 - "-" "curl/7.88.1" "a1b2c3d4-e5f6-7890" "api.secure-space.svc.cluster.local" "10.244.1.50:8080" inbound|8080|| 10.244.1.45:51234 10.244.1.50:8080 10.244.1.45:49812 outbound_.8080_._.api.secure-space.svc.cluster.local TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
```

---

### Verification Questions (Exercise 3)

1. **Question 3.1**: What key security observability limitation exists when inspecting standard Kubernetes `NetworkPolicy` drops versus using eBPF flow collectors like Cilium/Hubble?
2. **Question 3.2**: In the Envoy proxy log line from Step 3, which exact field confirms that the inter-pod session was encrypted via mutual TLS (mTLS), and why is this critical for zero-trust posture validation?

---

## Exercise 4: Security Telemetry Metrics & Prometheus Alerting

### Objectives
1. Extract security metrics directly from the Kubernetes API server and runtime controllers.
2. Build PromQL queries to detect anomalous authentication/authorization failures.
3. Configure Prometheus `AlertingRule` manifests for automated security event escalation.

### Step 1: Query API Server Security Metrics directly via raw API endpoint
Execute a raw query against the control plane metrics endpoint to inspect authorization denial counts.

```bash
kubectl get --raw /metrics | grep "apiserver_audit_requests_total" | head -n 10
```

**Expected Output:**
```text
# HELP apiserver_audit_requests_total [ALPHA] Counter of apiserver requests audited.
# TYPE apiserver_audit_requests_total counter
apiserver_audit_requests_total{level="Metadata"} 481023
apiserver_audit_requests_total{level="Request"} 12044
apiserver_audit_requests_total{level="RequestResponse"} 3102
```

Query the API Server HTTP response metrics for 401 (Unauthorized) and 403 (Forbidden) error rates:

```bash
kubectl get --raw /metrics | grep -E 'apiserver_request_total\{.*code="(401|403)"'
```

**Expected Output:**
```text
apiserver_request_total{code="401",component="apiserver",contentType="application/json",dry_run="",group="",resource="pods",subresource="",verb="list",version="v1"} 14
apiserver_request_total{code="403",component="apiserver",contentType="application/json",dry_run="",group="rbac.authorization.k8s.io",resource="clusterrolebindings",subresource="",verb="create",version="v1"} 3
```

### Step 2: Deploy Production Security Alerting Rules
Create a manifest named `security-prometheus-rules.yaml` defining PromQL alerts for threat detection:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: security-observability-alerts
  namespace: monitoring
  labels:
    role: alert-rules
spec:
  groups:
    - name: KubernetesSecurityOperations
      rules:
        # Alert 1: Spike in Unauthorized (401/403) API Server Requests (Potential Brute-force / Probe)
        - alert: HighAPIServerAuthorizationFailures
          expr: >
            sum(rate(apiserver_request_total{code=~"401|403"}[5m])) 
            / 
            sum(rate(apiserver_request_total[5m])) * 100 > 5
          for: 2m
          labels:
            severity: critical
            category: security
          annotations:
            summary: "High rate of API server authorization denials detected"
            description: "API server requests resulting in 401 or 403 status code exceeded 5% of overall traffic over the last 5 minutes. Current value: {{ $value }}%"

        # Alert 2: Container Exec Activity Spike
        - alert: ExcessivePodExecOperations
          expr: >
            sum(rate(apiserver_audit_requests_total{level=~"Request|RequestResponse"}[5m])) > 10
          for: 1m
          labels:
            severity: warning
            category: security-audit
          annotations:
            summary: "Abnormal volume of kubectl exec operations"
            description: "More than 10 pod exec requests per second recorded over 5 minutes."
```

### Step 3: Verify Prometheus Rule Deployment & Evaluation
Apply the rule manifest and check its status:

```bash
kubectl apply -f security-prometheus-rules.yaml
kubectl get prometheusrule -n monitoring security-observability-alerts -o jsonpath='{.status}'
```

---

### Verification Questions (Exercise 4)

1. **Question 4.1**: Why is measuring raw counts of `apiserver_request_total{code="403"}` less reliable for security alerting than calculating the ratio of 403s against total request rate (`rate(apiserver_request_total{code="403"}[5m]) / rate(apiserver_request_total[5m])`)?
2. **Question 4.2**: Name two specific metric vectors that can indicate a potential container breakout or privilege escalation attempt at the host level when analyzed alongside Falco logs.

---

## References & Official Sources

- **CNCF KCSA Curriculum Blueprint**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Audit Logging Documentation**: [https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- **Falco Security Rules Architecture Reference**: [https://falco.org/docs/rules/](https://falco.org/docs/rules/)
- **Cilium & Hubble eBPF Network Observability Documentation**: [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/)
- **Prometheus Monitoring Security Best Practices**: [https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

---

<details>
<summary><strong>Solutions & Comprehensive Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **1.1 Answer**:
  Configuring `RequestResponse` for `get` operations on `secrets` forces the API server audit engine to capture, serialize, and write the full payload (spec and data fields) of every single Secret retrieved. 
  
  **Mechanics & Risks**:
  1. **Memory & I/O Saturation**: Every controller loop, pod boot cycle (mounting secrets), or application lookup causes large JSON payloads to be serialized into memory and flushed to disk/webhook backends. This leads to high API server latency, disk throttling, and potential control plane OOM (Out-Of-Memory) kills.
  2. **Credential Exposure**: Plaintext secret values (encoded in base64 within the Secret payload) are written directly to unencrypted audit log files or log aggregators, violating the principle of least privilege and creating a massive credential leakage risk.

* **1.2 Answer**:
  The `RequestReceived` stage occurs before the API Server authenticates, authorizes, or processes the request. If logged alongside `ResponseComplete`, every single request generates at least two distinct audit log entries. Omitting `RequestReceived` cuts audit log volume roughly in half without sacrificing security compliance, as `ResponseComplete` records the final state, user identity, resource target, and response code.

* **1.3 Answer**:
  The audit configuration must switch from (or supplement) the `log` backend to the **Webhook Audit Backend** (`--audit-webhook-config-file`). The webhook backend streams audit events out-of-band over mTLS to an external, immutably configured remote SIEM or log collector (e.g., Elasticsearch, AWS CloudWatch, Splunk). This prevents an attacker who gains root access on a control plane node from modifying or deleting local `/var/log/kubernetes/audit/audit.log` files to cover their tracks.

---

### Exercise 2 Solutions

* **2.1 Answer**:
  - **Kernel Safety**: Legacy kernel modules execute directly in kernel space; a bug or null pointer dereference in the driver can crash the host kernel (Kernel Panic). eBPF bytecode is validated before loading by the kernel's in-kernel verifier, guaranteeing it cannot crash the host system, access unauthorized memory, or enter infinite loops.
  - **Performance Overhead**: eBPF runs highly optimized programs directly inside kernel tracepoints using efficient ring buffers, avoiding costly context switches between kernel and user space.
  - **Node Upgrades & Portability**: Kernel modules must be recompiled for every specific host kernel version update (`dkms`). eBPF uses CO-RE (Compile Once – Run Everywhere) via BTF (BPF Type Format), enabling seamless host kernel upgrades without breaking runtime security instrumentation.

* **2.2 Answer**:
  Yes, the rule will capture the event. 
  - `proc.name` evaluates the basename of the executed binary (`sh`). 
  - `proc.cmdline` records the full command-line invocation including arguments. 
  When `/usr/bin/custom-tool` executes `execve("/bin/sh", ...)`, the kernel emits a `sys_enter_execve` system call tracepoint event. Falco intercepts this system call via eBPF. Since `execve` updates the process's executable image to `/bin/sh`, `proc.name` becomes `sh`, satisfying the `proc.name in (bash, sh, zsh, ksh, ash)` condition regardless of what parent process initiated the binary.

---

### Exercise 3 Solutions

* **3.1 Answer**:
  Standard Kubernetes `NetworkPolicy` implementations enforce packet drops silently at the kernel interface (via iptables, IPVS, or basic eBPF) without natively writing structured drop events to standard container logs or system files. Without an eBPF network observability layer like Cilium/Hubble or specialized CNI logging plugins, network drops appear to application operators merely as generic "Connection Timed Out" errors. Hubble hooks into eBPF drop tracepoints (`kfree_skb`, `cilium_drop_tp`) to extract packet headers, metadata, and matched NetworkPolicy IDs in real time.

* **3.2 Answer**:
  The field `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` (or modern `TLS_AES_128_GCM_SHA256` cipher suite string) present at the end of the log line explicitly verifies that the Envoy sidecar successfully negotiated mTLS for the incoming HTTP session. In a Zero-Trust architecture, validating this metric/log field confirms that traffic in transit cannot be intercepted via packet sniffing (man-in-the-middle) and that cryptographic workload identity (SPIFFE/SPIRE ID or SAN URI) was enforced prior to evaluation of L7 RBAC authorization rules.

---

### Exercise 4 Solutions

* **4.1 Answer**:
  Raw counter metrics (e.g., `apiserver_request_total{code="403"} = 500`) are misleading because an increase in 403s might simply be a byproduct of cluster expansion or high overall traffic volume (e.g., 500 failed requests out of 10,000,000 total requests is 0.005%, which is normal operational background noise). Calculating the **ratio** (`rate(403) / rate(total)`) provides a normalized percentage metric. An abrupt increase in the denial ratio (e.g., exceeding 5% of total cluster requests) accurately isolates security anomalies (such as an compromised token attempting privilege escalation or an automated scanner probing endpoints) while minimizing false-positive alerts.

* **4.2 Answer**:
  1. `container_cpu_usage_seconds_total` (or kernel context-switch metrics): Anomalous spikes in CPU utilization or thread creation without corresponding application traffic spikes can indicate unauthorized cryptomining or brute-force tool execution inside a container.
  2. `node_namespace_processes` / `container_processes` (Process Count Metrics): A sudden spike in process count inside a container whose baseline process count is fixed (e.g., a single Nginx worker process jumping to 50 active processes) indicates shell execution, privilege escalation, or fork-bomb activity.

</details>