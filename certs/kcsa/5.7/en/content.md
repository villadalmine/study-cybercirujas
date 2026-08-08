# KCSA Study Guide — Topic 5.7: Admission Control

**Certification Exam:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Cluster Hardening / Admission Control  
**Topic Weight:** 2.29%  

---

## 1. Production Architectural Problem & Motivation

In a production-grade Kubernetes cluster, Role-Based Access Control (RBAC) is necessary but insufficient to enforce cluster security governance. RBAC answers *who* can perform an operation on a resource (e.g., "Can user `alice` `CREATE` a `Pod` in namespace `prod`?"), but it cannot evaluate the **semantic state or configuration payload** of the request itself (e.g., "Is `alice` attempting to run a Pod as `root`, mounting the host `/etc` directory, or omitting CPU/memory requests?").

Admission Controllers act as the final defense-in-depth boundary inside the `kube-apiserver` before objects are validated against the OpenAPI schema and persisted into `etcd`.

```
                    kube-apiserver Request Lifecycle
                    
  +----------------+      +---------------+      +----------------------------+
  |  HTTP Request  | ---> | Authentication| ---> |       Authorization        |
  |  (JSON/YAML)   |      |  (Token/X509) |      | (RBAC / Node / Webhook)    |
  +----------------+      +---------------+      +----------------------------+
                                                                |
                                                                v
  +----------------+      +---------------+      +----------------------------+
  | Schema Check & | <--- |   Mutating    | <--- |   Mutating Webhook Phase   |
  | Serialization  |      | Admission (In)|      | (Dynamic Webhooks)         |
  +----------------+      +---------------+      +----------------------------+
          |
          v
  +----------------+      +---------------+      +----------------------------+
  |  Validating    | ---> |  Validating   | ---> |  ValidatingAdmissionPolicy |
  | Admission (In) |      | Webhook Phase |      |    (In-Tree CEL Engine)    |
  +----------------+      +---------------+      +----------------------------+
                                                                |
                                                                v
                                                 +----------------------------+
                                                 |        etcd Store          |
                                                 |      (Persistence)         |
                                                 +----------------------------+
```

### Production Architectural Hazards

1. **Circular Deadlocks during Bootstrap:** If a dynamic Admission Webhook depends on cluster components (such as CoreDNS or CNI plugins) and its `namespaceSelector` does not explicitly exclude system namespaces (`kube-system`), restarting the cluster nodes will cause `kube-apiserver` to block pod creation for CoreDNS/CNI waiting for the webhook, while the webhook container cannot run because CoreDNS/CNI is down.
2. **Latencies and Cascading API Failures:** Webhooks operate over synchronous HTTPS network calls. If an admission webhook takes 10 seconds to respond or times out, every matching API request blocks. Under high throughput, `kube-apiserver` worker goroutines exhaust max-in-flight limits, bringing down cluster-wide operations.
3. **Bypass via Mutating Re-invocation:** Mutating webhooks can modify object fields. If Webhook A mutates an object, it may bypass security guarantees expected by Webhook B unless `reinvocationPolicy: IF_NEEDED` is set and carefully audited.
4. **Unauthenticated / MitM Admission Webhooks:** If the API server does not validate the webhook's TLS certificate authority (`caBundle`) or if the webhook endpoint is exposed to the pod network without mTLS/authentication, an attacker on the network can hijack admission calls and approve malicious requests.

---

## 2. Technical Architectural Comparisons & Trade-offs

### Matrix 1: Admission Mechanism Architectural Comparison

| Dimension | Built-in PodSecurity (PSA) | Dynamic Admission Webhooks (OPA/Kyverno) | ValidatingAdmissionPolicy (In-Tree CEL) |
| :--- | :--- | :--- | :--- |
| **Execution Context** | Compiled inside `kube-apiserver` | External HTTPS Service (Out-of-Process) | Embedded CEL Interpreter inside `kube-apiserver` |
| **Network Overhead** | 0 ms | 5 ms – 500+ ms (Network RTT + TLS Handshake) | 0 ms (In-memory execution) |
| **Availability Risk** | Zero (tied to API Server availability) | High (Network partitions, pod crash, DNS failure) | Zero (Evaluated in apiserver runtime) |
| **Custom Rules** | None (Predefined Pod Security Standards: Privileged, Baseline, Restricted) | Unlimited (Turing-complete, custom HTTP logic, Rego/YAML) | High (Declarative Common Expression Language) |
| **Mutation Capability**| No | Yes (`MutatingAdmissionWebhook`) | No (Validation and Audit only as of v1.30) |
| **External State Lookup**| No | Yes (Can query external APIs, databases, etcd) | No (Strictly pure functions over request object/params) |

### Matrix 2: `failurePolicy` Security vs. Availability Trade-offs

| Mode | Security Posture | Cluster Resilience / Availability | Production Use-Case |
| :--- | :--- | :--- | :--- |
| `failurePolicy: Fail` | **Fail-Closed (Secure)**. Blocks request if webhook is unreachable, times out, or returns a 5xx error. | **Risk of Outage**. A failure in the webhook service halts deployment pipelines and resource modifications across matching scopes. | Mandatory for production security/compliance webhooks (e.g., Image signature verification, root-execution blocking). |
| `failurePolicy: Ignore` | **Fail-Open (Insecure)**. Allows request to proceed if webhook errors or times out. | **High Availability**. API Server continues functioning even if webhook pods are completely down. | Non-critical webhooks (e.g., telemetry labeling, non-enforcing audit logging). |

---

## 3. Complete Production-Grade Manifests

### 3.1 Production `ValidatingWebhookConfiguration` with mTLS and System Exclusion

This manifest configures a dynamic validation webhook enforcing strict labels. It excludes system namespaces to prevent bootstrap deadlocks and enforces a tight 3-second timeout with `failurePolicy: Fail`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: enterprise-security-guardrail
  labels:
    app.kubernetes.io/name: security-guardrail
    app.kubernetes.io/part-of: platform-governance
spec:
  webhooks:
  - name: validate-security-controls.enterprise.io
    rules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods", "services"]
      scope:       "Namespaced"
    clientConfig:
      service:
        name: security-webhook-svc
        namespace: security-system
        path: "/validate-pod-spec"
        port: 443
      # Base64 encoded PEM certificate authority that signed the webhook server certificate
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVTnZXd1l0SmZ1Znd6TEpYVDRNZEh2Zk5ZUWpFd0RRWUpLb1pJaHZjTkFRRUwKQlFBd1NURUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd0hoY05Nak13TnpBMU1qQXdNQjRYRFRNNE16QXhNVEl3Ck1qQXdNQjB3U1RFTE1Ba0dBMTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd2dnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3CmdnRUZBQUtDQVFFQXJ6M0JBNzFsZzBVS1E1U0MvYWRaMVYxM0R5cVVqNWJrbk5xTHQ3Yzc0TGp5N3dNQmt4eDEKNm45VXZ3dHFBTHI3c0s0YjNmNGc3QU8yWUpvL09vOWM3a2FldDhpT21RUlZ2Smt2eW0ybUtvdTdpSUtSRnFkQQp3N2Zic1dEelQ0SmlCQUFBPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    admissionReviewVersions:
    - "v1"
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
    matchPolicy: Equivalent
    namespaceSelector:
      matchExpressions:
      - key: security.enterprise.io/enforce
        operator: In
        values: ["true"]
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values:
        - kube-system
        - kube-public
        - kube-node-lease
        - security-system
    objectSelector:
      matchExpressions:
      - key: app.kubernetes.io/managed-by
        operator: NotIn
        values: ["helm"]
```

### 3.2 Production `MutatingWebhookConfiguration` with `reinvocationPolicy`

This webhook injects security sidecars or default security contexts into incoming workloads. It specifies `reinvocationPolicy: IF_NEEDED` to ensure changes made by other mutating webhooks downstream are re-evaluated.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: enterprise-security-mutator
spec:
  webhooks:
  - name: mutate-security-context.enterprise.io
    rules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE"]
      resources:   ["pods"]
      scope:       "Namespaced"
    clientConfig:
      service:
        name: security-mutator-svc
        namespace: security-system
        path: "/mutate-pods"
        port: 443
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWdDZ0F3SUJBZ0lVTnZXd1l0SmZ1Znd6TEpYVDRNZEh2Zk5ZUWpFd0RRWUpLb1pJaHZjTkFRRUwKQlFBd1NURUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd0hoY05Nak13TnpBMU1qQXdNQjRYRFRNNE16QXhNVEl3Ck1qQXdNQjB3U1RFTE1Ba0dBMTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ2xOaGJHVm1iM0p1YVNCRGJIQjFjM0F4RnpBVgpCZ05WQkFNTUNsTmhiR1ZtYjNKdWFTQkRiSEIxYzNBd2dnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3CmdnRUZBQUtDQVFFQXJ6M0JBNzFsZzBVS1E1U0MvYWRaMVYxM0R5cVVqNWJrbk5xTHQ3Yzc0TGp5N3dNQmt4eDEKNm45VXZ3dHFBTHI3c0s0YjNmNGc3QU8yWUpvL09vOWM3a2FldDhpT21RUlZ2Smt2eW0ybUtvdTdpSUtSRnFkQQp3N2Zic1dEelQ0SmlCQUFBPQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCg==
    admissionReviewVersions: ["v1"]
    sideEffects: NoneOnDryRun
    timeoutSeconds: 5
    failurePolicy: Fail
    reinvocationPolicy: IF_NEEDED
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "security-system"]
```

### 3.3 Zero-Trust In-Tree Policy: `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` (CEL)

Kubernetes native admission control using Common Expression Language (CEL) runs directly inside `kube-apiserver`. The policy below enforces two rules on Pods:
1. `readOnlyRootFilesystem` must be set to `true`.
2. Image tags must not use `latest`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: enforce-pod-hardening
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem == true)"
      message: "Security Hardening Breach: Every container must set securityContext.readOnlyRootFilesystem to true."
      reason: Invalid
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest') && c.image.contains(':'))"
      message: "Supply Chain Risk: Containers are forbidden from using floating ':latest' tags or untagged images."
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: enforce-pod-hardening-binding
spec:
  policyName: enforce-pod-hardening
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-public"]
```

### 3.4 Cluster-Wide `AdmissionConfiguration` for PodSecurity Admission (PSA)

This static control-plane file configures `PodSecurity` admission defaults across the entire cluster. It enforces `baseline` rules by default, audits `restricted` rules, and exempts system infrastructure.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
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
      usernames: []
      runtimeClassNames: []
      namespaces:
      - kube-system
      - kube-public
      - kube-node-lease
```

---

## 4. Operational CLI Commands & Expected Terminal Outputs

### Step 4.1: Generating TLS Server Certificates for an Admission Webhook

Admission webhooks **must** be served over HTTPS with valid TLS certificates trusted by `kube-apiserver`.

```bash
$ openssl req -new -newkey rsa:4096 -nodes \
    -keyout webhook-server.key \
    -out webhook-server.csr \
    -subj "/CN=security-webhook-svc.security-system.svc"

$ cat <<EOF > san.ext
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = security-webhook-svc
DNS.2 = security-webhook-svc.security-system
DNS.3 = security-webhook-svc.security-system.svc
DNS.4 = security-webhook-svc.security-system.svc.cluster.local
EOF

$ openssl x509 -req -in webhook-server.csr \
    -CA /etc/kubernetes/pki/ca.crt \
    -CAkey /etc/kubernetes/pki/ca.key \
    -CAcreateserial \
    -out webhook-server.crt \
    -days 365 \
    -extfile san.ext
```

**Expected Terminal Output:**
```text
Signature ok
subject=CN = security-webhook-svc.security-system.svc
Getting CA Private Key
```

### Step 4.2: Inspecting Active Admission Webhooks & Configurations

```bash
$ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o wide
```

**Expected Terminal Output:**
```text
NAME                                                                 WEBHOOKS   AGE
validatingwebhookconfiguration.admissionregistration.k8s.io/enterprise-security-guardrail   1          4d2h

NAME                                                                 WEBHOOKS   AGE
mutatingwebhookconfiguration.admissionregistration.k8s.io/enterprise-security-mutator     1          4d2h
```

### Step 4.3: Testing Policy Enforcement via Server Dry-Run

Validate if a non-compliant workload triggers denial in admission without persisting changes:

```bash
$ kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload-test
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Expected Terminal Output:**
```text
Error from server (Forbidden): error when creating "STDIN": pods "insecure-workload-test" is forbidden: validaterule deny request: 
[ValidatingAdmissionPolicy: enforce-pod-hardening] Supply Chain Risk: Containers are forbidden from using floating ':latest' tags or untagged images.
[ValidatingAdmissionPolicy: enforce-pod-hardening] Security Hardening Breach: Every container must set securityContext.readOnlyRootFilesystem to true.
```

### Step 4.4: Auditing API Server Webhook Latency Metrics

To determine if webhooks are degrading `kube-apiserver` performance, query the API server's Prometheus metrics endpoint:

```bash
$ kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_bucket
```

**Expected Terminal Output:**
```text
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.05"} 1420
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.1"} 1485
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="0.5"} 1501
apiserver_admission_webhook_admission_duration_seconds_bucket{name="validate-security-controls.enterprise.io",operation="CREATE",rejected="false",type="validating",le="+Inf"} 1501
```

---

## 5. Verification, Hardening & Troubleshooting Guide

### 5.1 Common Failure Modes & Diagnostic Workflows

#### Scenario A: Webhook Timeout causing `InternalError` (HTTP 500)
**Symptom:** `kubectl apply` returns `Internal error occurred: failed calling webhook... context deadline exceeded`.

```
           Admission Timeout Troubleshooting Flow
           
  +-------------------------------------------------------+
  | Symptom: context deadline exceeded (Webhook Timeout)  |
  +-------------------------------------------------------+
                              |
                              v
       +---------------------------------------------+
       | Check Webhook Pod & Endpoint Status         |
       | $ kubectl get pods,ep -n <webhook-ns>       |
       +---------------------------------------------+
                              |
              +---------------+---------------+
              |                               |
       [Endpoints Ready]             [No Endpoints / Pending]
              |                               |
              v                               v
  +-----------------------+       +-----------------------+
  | Check NetworkPolicy / |       | Inspect Pod Logs &    |
  | Firewall / Egress     |       | Deployment Events     |
  | Rules (Port 443/8443) |       | $ kubectl logs -n ... |
  +-----------------------+       +-----------------------+
```

1. **Verify Webhook Endpoint Availability:**
   ```bash
   $ kubectl get endpoints security-webhook-svc -n security-system
   ```
2. **Inspect API Server Error Logs:**
   ```bash
   $ journalctl -u kube-apiserver -g "failed calling webhook" --no-pager | tail -n 20
   ```
   *Look for `x509: certificate signed by unknown authority` (mismatch in `caBundle`) or `i/o timeout` (NetworkPolicy blocking master-to-worker port 443/8443 traffic).*

#### Scenario B: Control Plane Deadlock During Node Restart
**Symptom:** Cluster nodes reboot, `kube-apiserver` is up, but no pods in the cluster can start. CoreDNS is stuck in `Pending`.  
**Root Cause:** Admission Webhook has `failurePolicy: Fail` and does not exclude `kube-system`. When API server calls the webhook, CoreDNS is down, DNS resolution fails, webhook call fails, blocking CoreDNS pod startup (circular lock).  
**Emergency Remediation:**
Temporarily delete or patch the blocking `ValidatingWebhookConfiguration` directly:

```bash
$ kubectl delete validatingwebhookconfiguration enterprise-security-guardrail
```

---

## 6. References

* **Kubernetes Documentation — Dynamic Admission Control:**  
  [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
* **Kubernetes Documentation — Validating Admission Policy (CEL):**  
  [https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
* **Kubernetes Documentation — Pod Security Admission (PSA):**  
  [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **CNCF KCSA Exam Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)