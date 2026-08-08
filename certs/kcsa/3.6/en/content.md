# KCSA Topic 3.6: Audit Logging – Advanced Production Study Guide

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Compliance and Standards / Auditing & Forensics  
**Topic:** Audit Logging  
**Weight:** 3.14%  

---

## 1. Motivation and Production Architectural Problem

### 1.1 The Compliance and Forensics Imperative
In production Kubernetes environments, control plane visibility is essential for regulatory compliance (PCI-DSS 4.0 Req 10, SOC 2 Type II, HIPAA § 164.312, NIST SP 800-190) and incident response. RBAC policies define authorized access boundaries, but **Kubernetes Audit Logging** provides the immutable, chronological record of every sequence of activities driven by users, service accounts, or control plane components interacting with the `kube-apiserver`.

Without audit logging, security operations centers (SOC) face critical blind spots:
- Inability to determine who accessed or exported sensitive `Secret` objects.
- Lack of attribution for privilege escalation attacks (e.g., unauthorized updates to `ClusterRoleBinding` resources).
- Zero visibility into interactive execution commands (`kubectl exec`, `kubectl attach`, `kubectl port-forward`).
- Inability to trace automated supply chain or CI/CD compromises acting via ServiceAccount tokens.

### 1.2 The Production Architectural Problem
Kubernetes audit logging is not a simple "turn-on-and-forget" feature. The `kube-apiserver` processes hundreds or thousands of HTTP requests per second (RPS). Every single API request passes through the auditing pipeline at four distinct stages:

```
                          [ Incoming HTTP Request ]
                                      │
                                      ▼
                           ┌─────────────────────┐
                           │   RequestReceived   │
                           └──────────┬──────────┘
                                      │
                                      ▼
                           ┌─────────────────────┐
                           │   ResponseStarted   │  (Streaming responses like watch/exec)
                           └──────────┬──────────┘
                                      │
                                      ▼
                           ┌─────────────────────┐
                           │  ResponseComplete   │  (Standard REST call finished)
                           └──────────┬──────────┘
                                      │
                                      ▼
                           ┌─────────────────────┐
                           │        Panic        │  (Internal API server crash/panic)
                           └─────────────────────┘
```

The architectural challenge revolves around balancing **three conflicting vectors**:

1. **Performance & Memory Footprint:** Capturing full request and response payloads (`RequestResponse` level) for every API call consumes massive CPU cycles for JSON serialization and generates gigabytes of log data per minute, degrading `kube-apiserver` throughput and inducing memory pressure.
2. **Security & Data Exposure:** Logging full request/response bodies blindly exposes raw sensitive data (e.g., passwords, TLS private keys, database credentials inside `Secret` or `ConfigMap` resources) in plaintext within audit log storage, creating a secondary compliance violation.
3. **Log Integrity vs. Backpressure:** Log shipping backends can fail or experience network congestion. If configured in synchronous/blocking mode, audit logging can block the `kube-apiserver` handler pipeline, causing control plane outages. If configured asynchronously with bounded queues, overflow conditions lead to audit event drops.

---

## 2. Technical Comparisons & Trade-off Matrix

### 2.1 Audit Level Comparison

Kubernetes defines four distinct audit levels in `audit.k8s.io/v1`:

| Audit Level | Data Captured | API Server Overhead | Storage Overhead | Primary Production Use Case | Security / Compliance Risk |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `None` | Nothing logged for matching requests. | Zero | Zero | Suppressing noisy read-only events (e.g., `/healthz`, `/metrics`, `endpoints`, `leases`). | Security Blind Spot if applied to operational resources. |
| `Metadata` | Request metadata (user, timestamp, verb, resource, namespace, subresource, HTTP status code). Excludes bodies. | Low | Low (~1 KB/event) | **Default production baseline** for standard resource reads and list operations across all namespaces. | High-level visibility only; payload modifications are hidden. |
| `Request` | Metadata + full HTTP Request Body. Excludes Response Body. | Medium | Medium (~2–10 KB/event) | Auditing resource creation (`create`, `update`, `patch`) and execution commands (`pods/exec`). | Potential leakage of request payloads containing credentials if not scoped properly. |
| `RequestResponse` | Metadata + full HTTP Request Body + full HTTP Response Body. | High | High (10–100+ KB/event) | Targeted auditing of critical administrative actions (e.g., modifications to `clusterroles`, `clusterrolebindings`). | **Extreme Risk:** Raw secret exposure if applied to `secrets` or `configmaps`. |

---

### 2.2 Audit Backend Architectural Models

Kubernetes supports two primary audit backend mechanisms: **Log Backend** (local disk) and **Webhook Backend** (remote HTTP endpoint).

| Architectural Dimension | Local File Sink + Log Shipper (e.g., Vector/Fluentbit) | Webhook Sink (Batching Mode) | Webhook Sink (Blocking/Blocking-Strict Mode) |
| :--- | :--- | :--- | :--- |
| **Delivery Guarantee** | At-least-once (via disk tailing). | Best-effort / At-least-once (drop on buffer overflow). | Guaranteed synchronous delivery before response return. |
| **Control Plane Impact** | Minimal (async local file I/O). | Low to Moderate (in-memory buffer + background worker pool). | **High**: API Server latency equals endpoint latency. Endpoint outage halts API server. |
| **Tamper Resistance** | Vulnerable if control plane node root access is compromised before log shipping. | High (direct network stream to isolated SIEM/S3/Log Analytics). | High (direct network stream). |
| **Buffer Exhaustion Behavior** | Handled by OS filesystem limits; requires log rotation (`--audit-log-maxsize`). | Events are dropped once `buffer-size` is exceeded (`batch-throttle-enable`). | API Server blocks incoming calls until webhook responds or times out. |
| **Recommended Context** | **Standard Production Baseline** for physical/VM control planes. | Large-scale multi-tenant enterprise clusters with external SIEM integration. | Ultra-high security enclaves where non-audited actions are forbidden by policy. |

---

## 3. Production Manifests & Infrastructure Configurations

### 3.1 Hardened Production Audit Policy (`audit-policy.yaml`)

This policy implements strict security best practices:
- Suppresses noise (system components, leases, endpoints, status checks).
- Logs security-critical RBAC and authentication changes at `RequestResponse`.
- Logs Secret and ConfigMap modifications at `Metadata` (preventing payload credential leakage).
- Logs pod execution/attach subresources at `Request`.
- Catches all remaining cluster-wide modifications at `Request`.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Do not generate audit events for unrecorded stages (reduces duplicate event noise)
omitStages:
  - "RequestReceived"
rules:
  # Rule 1: Ignore read-only health and metric endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/metrics"
      - "/version"
      - "/swagger*"

  # Rule 2: Ignore high-frequency internal controller leases and endpoints
  - level: None
    resources:
      - group: ""
        resources: ["endpoints", "services", "configmaps"]
      - group: "coordination.k8s.io"
        resources: ["leases"]
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:node:*"
      - "system:serviceaccount:kube-system:endpointslice-controller"

  # Rule 3: Ignore noisy status check read requests by system nodes
  - level: None
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # Rule 4: Audit sensitive authentication and privilege escalation at RequestResponse level
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews", "selfsubjectrulesreviews"]

  # Rule 5: Audit Secrets and ConfigMaps at Metadata ONLY (Prevents credential leakage in log files)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Rule 6: Audit workload execution, port-forwarding, and interactive access at Request level
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # Rule 7: Audit all other pod and workload mutations at Request level
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]

  # Rule 8: Default metadata audit for all other resources and non-system users
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

---

### 3.2 `kube-apiserver` Static Pod Manifest Excerpt

The static pod manifest located at `/etc/kubernetes/manifests/kube-apiserver.yaml` must be configured with explicit audit parameters and host path volume mounts.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.10.10
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --enable-bootstrap-token-auth=true
    - --etcd-servers=https://127.0.0.1:2379
    # --- AUDIT LOGGING CONFIGURATION FLAGS ---
    - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/kube-apiserver-audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --audit-log-compress=true
    # --- AUDIT WEBHOOK CONFIGURATION FLAGS (OPTIONAL DUAL SINK) ---
    - --audit-webhook-config-file=/etc/kubernetes/audit/webhook-config.yaml
    - --audit-webhook-mode=batch
    - --audit-webhook-batch-max-size=100
    - --audit-webhook-batch-max-wait=5s
    - --audit-webhook-batch-buffer-wait=5s
    image: registry.k8s.io/kube-apiserver:v1.30.0
    name: kube-apiserver
    volumeMounts:
    - mountPath: /etc/kubernetes/audit
      name: audit-config
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
      readOnly: false
  volumes:
  - name: audit-config
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

---

### 3.3 Audit Webhook Configuration (`webhook-config.yaml`)

When sending audit events asynchronously to an external SIEM endpoint via HTTP webhook, the `kube-apiserver` expects a standard `Kubeconfig` formatted file specifying TLS client authentication and remote cluster targets.

```yaml
apiVersion: v1
kind: Config
preferences: {}
clusters:
- name: external-siem-audit-sink
  cluster:
    server: https://audit-sink.secOps.internal.net:8443/api/v1/audit
    certificate-authority: /etc/kubernetes/audit/siem-ca.crt
users:
- name: kube-apiserver-audit-client
  user:
    client-certificate: /etc/kubernetes/audit/audit-client.crt
    client-key: /etc/kubernetes/audit/audit-client.key
contexts:
- context:
    cluster: external-siem-audit-sink
    user: kube-apiserver-audit-client
  name: default-context
current-context: default-context
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### 4.1 Verifying Active `kube-apiserver` Audit Parameters

Inspect the running API server process parameters directly via container runtime commands (`crictl`) or `kubectl`.

```bash
$ kubectl get pod -n kube-system -l component=kube-apiserver -o jsonpath='{range .items[0].spec.containers[0].command[*]}{.}{"\n"}{end}' | grep audit
```
```text
--audit-log-compress=true
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
--audit-log-path=/var/log/kubernetes/audit/kube-apiserver-audit.log
--audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
```

---

### 4.2 Generating an Audited Security Event (Privilege Escalation)

Trigger an audited action by creating a suspicious `ClusterRoleBinding` granting `cluster-admin` privileges to a default service account.

```bash
$ kubectl create clusterrolebinding mal-binding --clusterrole=cluster-admin --serviceaccount=default:attacker-sa
```
```text
clusterrolebinding.rbac.authorization.k8s.io/mal-binding created
```

---

### 4.3 Querying Audit Logs for Security Investigation

Extract and parse the raw JSON audit event generated by the command above using `jq`.

```bash
$ sudo tail -n 50 /var/log/kubernetes/audit/kube-apiserver-audit.log | jq -c 'select(.objectRef.resource=="clusterrolebindings" and .objectRef.name=="mal-binding")'
```
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "auditID": "9c148e1a-5b4d-491b-87cf-6e87f34c22a1",
  "stage": "ResponseComplete",
  "requestURI": "/apis/rbac.authorization.k8s.io/v1/clusterrolebindings?fieldManager=kubectl-create",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": [
      "system:masters",
      "system:authenticated"
    ]
  },
  "sourceIPs": [
    "192.168.10.50"
  ],
  "userAgent": "kubectl/v1.30.0 (linux/amd64) kubernetes/7c40c29",
  "objectRef": {
    "resource": "clusterrolebindings",
    "name": "mal-binding",
    "apiGroup": "rbac.authorization.k8s.io",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 201
  },
  "requestObject": {
    "kind": "ClusterRoleBinding",
    "apiVersion": "rbac.authorization.k8s.io/v1",
    "metadata": {
      "name": "mal-binding",
      "creationTimestamp": null
    },
    "subjects": [
      {
        "kind": "ServiceAccount",
        "name": "attacker-sa",
        "namespace": "default"
      }
    ],
    "roleRef": {
      "apiGroup": "rbac.authorization.k8s.io",
      "kind": "ClusterRole",
      "name": "cluster-admin"
    }
  },
  "responseObject": {
    "kind": "ClusterRoleBinding",
    "apiVersion": "rbac.authorization.k8s.io/v1",
    "metadata": {
      "name": "mal-binding",
      "uid": "e81d77b8-3f8c-4f9e-a89b-8260a9ef83b7",
      "resourceVersion": "124852",
      "creationTimestamp": "2026-08-07T23:45:12Z"
    },
    "subjects": [
      {
        "kind": "ServiceAccount",
        "name": "attacker-sa",
        "namespace": "default"
      }
    ],
    "roleRef": {
      "apiGroup": "rbac.authorization.k8s.io",
      "kind": "ClusterRole",
      "name": "cluster-admin"
    }
  },
  "requestReceivedTimestamp": "2026-08-07T23:45:12.102941Z",
  "stageTimestamp": "2026-08-07T23:45:12.115482Z",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"cluster-admin\" of ClusterRole \"cluster-admin\" to User \"kubernetes-admin\""
  }
}
```

---

### 4.4 Auditing Unauthorized Access Attempts (`HTTP 403 Forbidden`)

Query the audit log for unauthorized access attempts across the cluster to identify potential privilege escalation or reconnaissance activity.

```bash
$ sudo grep -E '"code":403' /var/log/kubernetes/audit/kube-apiserver-audit.log | jq -r '[.stageTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name // "N/A", .sourceIPs[0]] | @tsv'
```
```text
2026-08-07T23:48:01Z	system:serviceaccount:default:app-sa	list	secrets	N/A	10.244.1.15
2026-08-07T23:49:22Z	untrusted-developer	delete	nodes	worker-node-02	192.168.10.75
```

---

### 4.5 Auditing Interactive Container Execution (`kubectl exec`)

Detect interactive shell executions within running pods, extracting user identity, pod name, and namespace.

```bash
$ sudo grep 'pods/exec' /var/log/kubernetes/audit/kube-apiserver-audit.log | jq -r '[.stageTimestamp, .user.username, .objectRef.namespace, .objectRef.name, .requestURI] | @tsv'
```
```text
2026-08-07T23:52:10Z	admin-user	prod-banking	db-pod-0	/api/v1/namespaces/prod-banking/pods/db-pod-0/exec?command=sh&container=mysql&stdin=true&tty=true
```

---

## 5. Verification & Failure Diagnostic Guide

### 5.1 Common Production Failure Modes

```
                                  Audit System Failure Modes
                                              │
         ┌────────────────────────────────────┼────────────────────────────────────┐
         ▼                                    ▼                                    ▼
┌─────────────────┐                  ┌─────────────────┐                  ┌─────────────────┐
│ Control Plane   │                  │ Webhook Buffer  │                  │ Secret Payload  │
│ CrashLoop       │                  │ Overflow        │                  │ Leakage         │
└────────┬────────┘                  └────────┬────────┘                  └────────┬────────┘
         │                                    │                                    │
         ├─ Path Mount Missing                ├─ High API Latency                  └─ Audit Level set
         ├─ Policy Syntax Error               ├─ Remote SIEM Down                     to Request/Response
         └─ Invalid Flag Spec                 └─ Queue Drops Events                   on `secrets`
```

---

### 5.2 Diagnostic Decision Tree & Troubleshooting Workflow

#### Issue 1: `kube-apiserver` fails to start after enabling Audit Logging
**Symptoms:** `kubectl` commands return `The connection to the server localhost:8080 was refused`, and `crictl ps` shows `kube-apiserver` repeatedly exiting.

**Step 1:** Inspect the static pod container logs directly using `crictl`.
```bash
$ sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -n 1)
```
*Expected Error Output (Syntax Failure):*
```text
Error: loading audit policy file failed: failed to decode audit policy file: unknown field "rule" in k8s.io/apiserver/pkg/apis/audit.v1.Policy
```
*Resolution:* Correct typos in `/etc/kubernetes/audit/audit-policy.yaml` (e.g., change `rule:` to `rules:`).

*Expected Error Output (Mount Failure):*
```text
Error: open /etc/kubernetes/audit/audit-policy.yaml: no such file or directory
```
*Resolution:* Ensure both `hostPath` and `volumeMounts` paths match identically in `/etc/kubernetes/manifests/kube-apiserver.yaml`.

---

#### Issue 2: Audit Logs are growing uncontrollably, filling the Control Plane disk
**Symptoms:** Root disk utilization alert triggers (`/var/log` full).

**Step 1:** Inspect log directory space.
```bash
$ du -sh /var/log/kubernetes/audit/*
```

**Step 2:** Verify retention and rotation parameters in the static pod specification:
- `--audit-log-maxsize=100`: Triggers rotation at 100 MB per file.
- `--audit-log-maxbackup=10`: Retains a maximum of 10 rotated log files.
- `--audit-log-maxage=30`: Deletes rotated log files older than 30 days.
- `--audit-log-compress=true`: Enables gzip compression on rotated files.

**Step 3:** Check for unthrottled `RequestResponse` logging rules matching high-volume API endpoints like `leases`, `endpoints`, or `pods`.

---

#### Issue 3: Audit Webhook dropping events due to backend latency
**Symptoms:** API server metrics report dropped audit events: `apiserver_audit_error_total` or `apiserver_audit_requests_rejected_total` increasing.

**Step 1:** Inspect API Server audit metrics via Prometheus endpoint.
```bash
$ kubectl get --raw /metrics | grep apiserver_audit_
```
```text
apiserver_audit_event_total{plugin="webhook"} 145023
apiserver_audit_error_total{plugin="webhook"} 342
apiserver_audit_requests_rejected_total{plugin="webhook"} 12
```

**Step 2:** Tune batching performance flags in `/etc/kubernetes/manifests/kube-apiserver.yaml`:
```text
--audit-webhook-batch-max-size=500
--audit-webhook-batch-max-wait=1s
--audit-webhook-batch-buffer-wait=2s
--audit-webhook-batch-throttle-qps=10
--audit-webhook-batch-throttle-burst=15
```

---

## 6. References

- **Kubernetes Documentation – Auditing Architecture & Configuration:**  
  https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/

- **Kubernetes API Reference – Audit Policy (`audit.k8s.io/v1`):**  
  https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/

- **CNCF KCSA Official Exam Curriculum PDF:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf

- **NIST SP 800-190 – Application Container Security Guide (Section 3.4 Control Plane Security):**  
  https://csrc.nist.gov/publications/detail/sp/800-190/final