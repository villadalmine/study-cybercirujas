# KCSA Advanced Production Study Guide: Domain 5.7 – Admission Control

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 5.7:** Admission Control  
**Domain Weight:** 2.29%  

---

## 1. Deep Internal Mechanics & Architecture

Admission Control in Kubernetes serves as the definitive gatekeeper enforcing policy, governance, and security posture on API server requests **after** authentication and authorization succeed, but **before** the object state is persisted into `etcd`.

```
                    +---------------------------------------------------------------------------------+
                    |                               Kube-APIServer                                    |
                    |                                                                                 |
Incoming HTTP Request ---> [ Authentication ] ---> [ Authorization ] ---> [ Mutating Admission ]      |
                    |                                                            |                    |
                    |                                                            v                    |
                    |                                                  [ Schema Validation ]          |
                    |                                                            |                    |
                    |                                                            v                    |
Persistence to etcd <--------------------------------------------------- [ Validating Admission ]     |
                    +---------------------------------------------------------------------------------+
```

### The Admission Pipeline Phases

1. **Phase 1: Mutating Admission Phase**
   - **Order of Execution:** Built-in Mutating Admission Controllers -> Extensible Webhooks (`MutatingWebhookConfiguration`).
   - **Behavior:** Requests are evaluated sequentially. Mutating webhooks can modify the request payload (`AdmissionReview` response containing JSON patches).
   - **Re-invocation Policy:** If a mutating webhook modifies an object, earlier mutating webhooks may be re-invoked (up to a fixed iteration limit) if their `reinvocationPolicy` is set to `IfNeeded`.

2. **Phase 2: Object Schema Validation**
   - Validates the structural integrity and OpenAPI schema compliance of the mutated object.

3. **Phase 3: Validating Admission Phase**
   - **Order of Execution:** Built-in Validating Admission Controllers -> Extensible Webhooks (`ValidatingWebhookConfiguration`) -> In-process Common Expression Language (CEL) policies (`ValidatingAdmissionPolicy`).
   - **Behavior:** Executed in parallel. If **any** validating controller or webhook denies the request, the entire API operation is aborted, and an HTTP `402`/`403`/`422` error is returned to the client.

### Key Architectural Configurations & Trade-offs

| Parameter / Feature | Operational Function & Trade-Off |
| :--- | :--- |
| `failurePolicy: Fail` | Blocks the API request if the webhook server is unreachable or times out. **Security impact:** High (Prevents unvalidated workloads). **Availability impact:** High (Risk of cascading cluster downtime if webhooks crash). |
| `failurePolicy: Ignore` | Allows the API request to proceed if the webhook is unreachable. **Security impact:** Compromised (Bypasses security guardrails during webhook outages). **Availability impact:** Zero disruption. |
| `timeoutSeconds` | Max time API server waits for a webhook response (Default: `10s` for webhooks, recommended `1s-3s` in production). Prolonged timeouts can exhaust kube-apiserver worker threads. |
| `matchConditions` | High-performance CEL expressions evaluated *inside* `kube-apiserver` to skip calling external HTTP webhooks unless specific conditions are met. Reduces network latency. |
| `ValidatingAdmissionPolicy` | Native CEL engine executing policies inside `kube-apiserver`. Eliminates HTTP latency, TLS certificate management, and web-server pod infrastructure overhead. |

---

## 2. Official References & Citation Links

- [Kubernetes Official Documentation: Using Admission Controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Kubernetes Official Documentation: Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [Kubernetes Official Documentation: Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Kubernetes Official Documentation: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [CNCF KCSA Curriculum Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Guided Exercises

---

### Exercise 1: Built-in Admission Control & Pod Security Admission (PSA)

#### Task Overview
Enforce the `restricted` Pod Security Standard on a target namespace using built-in Pod Security Admission labels, verify policy enforcement, and audit admission violations.

#### Step 1: Create isolate test namespaces
Create two namespaces: one configured for Pod Security enforcement (`sec-restricted`) and one unconstrained (`sec-legacy`).

```bash
kubectl create namespace sec-restricted
kubectl create namespace sec-legacy
```

**Expected Output:**
```text
namespace/sec-restricted created
namespace/sec-legacy created
```

#### Step 2: Configure Namespace Pod Security Labels
Apply Pod Security Standards labels to `sec-restricted` to enforce the `restricted` profile at version `latest`, while emitting audit logs and warnings for violations.

```bash
kubectl label --overwrite namespace sec-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

**Expected Output:**
```text
namespace/sec-restricted labeled
```

#### Step 3: Attempt to Deploy a Non-Compliant Workload
Deploy a pod manifest that violates the `restricted` profile by running as `root` (UID 0), allowing privilege escalation, and omitting `seccompProfile`. Save this manifest as `privileged-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload
  namespace: sec-restricted
spec:
  containers:
  - name: nginx
    image: nginx:1.25.3
    securityContext:
      allowPrivilegeEscalation: true
      runAsUser: 0
```

Execute creation:

```bash
kubectl apply -f privileged-pod.yaml
```

**Expected Output:**
```text
Error from server (Forbidden): error when creating "privileged-pod.yaml": pods "insecure-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Step 4: Deploy a Fully Compliant Workload
Create a fully compliant manifest adhering strictly to the `restricted` Pod Security Standard. Save as `compliant-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: sec-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: pause-container
    image: registry.k8s.io/pause:3.9
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
```

Execute creation:

```bash
kubectl apply -f compliant-pod.yaml
```

**Expected Output:**
```text
pod/secure-workload created
```

#### Step 5: Verify Deployment Status
Verify that the pod reaches the `Running` state.

```bash
kubectl get pod secure-workload -n sec-restricted -o wide
```

**Expected Output:**
```text
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE
secure-workload   1/1     Running   0          12s   10.244.0.5   node-01
```

---

#### Verification Questions (Exercise 1)

1. **Question 1.1:** Which component inside the Kubernetes control plane is responsible for evaluating the `pod-security.kubernetes.io/enforce` namespace label, and during which exact admission control phase does this check occur?
2. **Question 1.2:** If a deployment resource (`apps/v1`) containing a non-compliant pod template is applied to the `sec-restricted` namespace, will the `kubectl apply -f deployment.yaml` command be rejected at the API server level? Explain the technical behavior.

---

### Exercise 2: Native In-Process Policy Enforcement via `ValidatingAdmissionPolicy` (CEL)

#### Task Overview
Create and bind a zero-dependency, high-performance `ValidatingAdmissionPolicy` using Common Expression Language (CEL) to reject Pods attempting to use the `:latest` image tag or pods missing resource CPU/Memory requests.

#### Step 1: Define the `ValidatingAdmissionPolicy`
Create a complete manifest `policy-cel-guardrails.yaml` specifying structural rules via CEL expressions.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "enforce-resource-limits-and-tags"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest'))"
      message: "Production Risk: Container images using the ':latest' tag are strictly prohibited."
    - expression: "object.spec.containers.all(c, has(c.resources) && has(c.resources.requests) && has(c.resources.requests.cpu))"
      message: "Resource Governance: Container must explicitly specify CPU requests."
```

Apply policy:

```bash
kubectl apply -f policy-cel-guardrails.yaml
```

**Expected Output:**
```text
validatingadmissionpolicy.admissionregistration.k8s.io/enforce-resource-limits-and-tags created
```

#### Step 2: Bind the Policy to Target Namespaces using `ValidatingAdmissionPolicyBinding`
Create `policy-binding.yaml` to enforce the policy on any namespace labeled `environment: production`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "enforce-resource-limits-and-tags-binding"
spec:
  policyName: "enforce-resource-limits-and-tags"
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

Apply binding and label namespace:

```bash
kubectl apply -f policy-binding.yaml
kubectl label namespace sec-legacy environment=production --overwrite
```

**Expected Output:**
```text
validatingadmissionpolicybinding.admissionregistration.k8s.io/enforce-resource-limits-and-tags-binding created
namespace/sec-legacy labeled
```

#### Step 3: Test CEL Policy Violations
Create a test manifest `violating-cel-pod.yaml` violating both CEL expressions.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-cel-pod
  namespace: sec-legacy
spec:
  containers:
  - name: web
    image: nginx:latest
```

Execute creation:

```bash
kubectl apply -f violating-cel-pod.yaml
```

**Expected Output:**
```text
Error from server (Invalid): error when creating "violating-cel-pod.yaml": Pod "bad-cel-pod" is invalid: : ValidatingAdmissionPolicy 'enforce-resource-limits-and-tags' with binding 'enforce-resource-limits-and-tags-binding' denied request: Production Risk: Container images using the ':latest' tag are strictly prohibited.
```

#### Step 4: Validate CEL Expressions using dry-run diagnostics
Fix the image tag but keep CPU requests missing to observe the secondary CEL condition triggering. Save as `partial-fix-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-cel-pod-2
  namespace: sec-legacy
spec:
  containers:
  - name: web
    image: nginx:1.25.3
```

Execute creation:

```bash
kubectl apply -f partial-fix-pod.yaml
```

**Expected Output:**
```text
Error from server (Invalid): error when creating "partial-fix-pod.yaml": Pod "bad-cel-pod-2" is invalid: : ValidatingAdmissionPolicy 'enforce-resource-limits-and-tags' with binding 'enforce-resource-limits-and-tags-binding' denied request: Resource Governance: Container must explicitly specify CPU requests.
```

---

#### Verification Questions (Exercise 2)

1. **Question 2.1:** What are the key architectural performance advantages of `ValidatingAdmissionPolicy` (CEL) over standard dynamic HTTP webhooks (`ValidatingWebhookConfiguration`)?
2. **Question 2.2:** What occurs if a `ValidatingAdmissionPolicyBinding` specifies `validationActions: [Audit, Warn]` instead of `Deny` when a policy violation occurs?

---

### Exercise 3: Dynamic Dynamic Admission Webhooks, Failure Policies & Latency Troubleshooting

#### Task Overview
Configure a `ValidatingWebhookConfiguration` with explicit `matchConditions`, investigate webhook failure modes, analyze API server timeouts, and evaluate the impact of `failurePolicy: Fail` versus `failurePolicy: Ignore`.

#### Step 1: Deploy Mock Webhook Infrastructure
Deploy a mock HTTP validation webhook endpoint and service in namespace `webhook-system`.

```bash
kubectl create namespace webhook-system
```

Create `webhook-backend.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dummy-webhook
  namespace: webhook-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dummy-webhook
  template:
    metadata:
      labels:
        app: dummy-webhook
  spec:
    containers:
    - name: server
      image: registry.k8s.io/pause:3.9
      ports:
      - containerPort: 8443
---
apiVersion: v1
kind: Service
metadata:
  name: dummy-webhook-svc
  namespace: webhook-system
spec:
  ports:
  - port: 443
    targetPort: 8443
  selector:
    app: dummy-webhook
```

Apply backend resources:

```bash
kubectl apply -f webhook-backend.yaml
```

**Expected Output:**
```text
deployment.apps/dummy-webhook created
service/dummy-webhook-svc created
```

#### Step 2: Register a `ValidatingWebhookConfiguration` with Strict Failure Policy
Save the following manifest as `validating-webhook-strict.yaml`. Notice `failurePolicy: Fail` points to the mock service (which does not actually handle HTTPS `AdmissionReview` requests, causing connection errors).

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: strict-security-webhook
webhooks:
  - name: "check.security.domain.internal"
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE"]
        resources:   ["pods"]
        scope:       "Namespaced"
    clientConfig:
      service:
        name: "dummy-webhook-svc"
        namespace: "webhook-system"
        path: "/validate"
        port: 443
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        webhook-enforce: "true"
```

Apply webhook configuration:

```bash
kubectl apply -f validating-webhook-strict.yaml
```

**Expected Output:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io/strict-security-webhook created
```

#### Step 3: Label Namespace and Trigger Webhook Invocation
Label namespace `sec-legacy` to match the webhook selector.

```bash
kubectl label namespace sec-legacy webhook-enforce=true --overwrite
```

Attempt to deploy a simple pod manifest `test-webhook-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-webhook-pod
  namespace: sec-legacy
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```

Apply manifest:

```bash
kubectl apply -f test-webhook-pod.yaml
```

**Expected Output:**
```text
Error from server (InternalError): error when creating "test-webhook-pod.yaml": Internal error occurred: failed calling webhook "check.security.domain.internal": failed to call webhook: Post "https://dummy-webhook-svc.webhook-system.svc:443/validate?timeout=3s": dial tcp 10.96.142.88:443: connect: connection refused
```

#### Step 4: Advanced Diagnostics of Webhook Failures
Query API server metrics and events to diagnose admission webhook call failures.

```bash
kubectl get events -n sec-legacy --field-selector reason=FailedAdmission
```

Inspect API server logs for HTTP 500 error traces:

```bash
kubectl logs -n kube-system -l component=kube-apiserver --tail=100 | grep "failed calling webhook"
```

**Expected Diagnostic Output:**
```text
E0807 20:35:12.441102 1 dispatcher.go:205] failed calling webhook "check.security.domain.internal": Post "https://dummy-webhook-svc.webhook-system.svc:443/validate?timeout=3s": dial tcp 10.96.142.88:443: connect: connection refused
W0807 20:35:12.441145 1 handler.go:232] admission webhook "check.security.domain.internal" failed to complete request in 3s, failing open=false
```

#### Step 5: Remediate Outage via Dynamic Policy Patching
Mitigate cluster operational disruption by dynamically switching `failurePolicy` from `Fail` to `Ignore`.

```bash
kubectl patch validatingwebhookconfiguration strict-security-webhook \
  --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
```

**Expected Output:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io/strict-security-webhook patched
```

Retry pod creation:

```bash
kubectl apply -f test-webhook-pod.yaml
```

**Expected Output:**
```text
pod/test-webhook-pod created
```

#### Step 6: Clean Up Lab Resources
Clean up all objects created during the exercises.

```bash
kubectl delete namespace sec-restricted sec-legacy webhook-system
kubectl delete validatingadmissionpolicy enforce-resource-limits-and-tags
kubectl delete validatingadmissionpolicybinding enforce-resource-limits-and-tags-binding
kubectl delete validatingwebhookconfiguration strict-security-webhook
```

---

#### Verification Questions (Exercise 3)

1. **Question 3.1:** Explain the danger of setting `namespaceSelector` to match all namespaces (including `kube-system` or `webhook-system` itself) when combined with `failurePolicy: Fail` on a `MutatingWebhookConfiguration` or `ValidatingWebhookConfiguration`.
2. **Question 3.2:** What is the purpose of the `reinvocationPolicy` field in a `MutatingWebhookConfiguration`, and what specific value prevents infinite loops during mutation phases?

---

## 4. Solutions & Technical Explanations

<details>
<summary><strong>Click to Expand Answers & Deep Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:**
  * **Component:** The built-in **`PodSecurity` Admission Controller** plugin compiled directly inside the `kube-apiserver` binary.
  * **Phase:** It executes during **Phase 3 (Validating Admission Phase)**. It evaluates the pod's `securityContext` parameters against the defined standard level (`privileged`, `baseline`, or `restricted`) designated by the `pod-security.kubernetes.io/enforce` namespace label.

* **Answer 1.2:**
  * **No**, the `kubectl apply -f deployment.yaml` command will **NOT** be rejected at the API server level upon initial submission.
  * **Technical Reason:** The Pod Security Admission controller checks `Pod` objects (`kind: Pod`), not higher-level controllers like `Deployments`, `ReplicaSets`, or `Jobs`. The `Deployment` object will be successfully persisted to `etcd`.
  * **Consequence:** Afterwards, the `ReplicaSet` controller will attempt to create child `Pod` objects. When the `ReplicaSet` submits individual `Pod` creation requests, the `PodSecurity` admission controller will reject those `Pod` requests. The `Deployment` will show `0/1` available replicas, and error events will accumulate on the `ReplicaSet` (visible via `kubectl describe replicaset`).
  * *Note:* To catch violations at the Deployment level before pod creation, Pod Security Admission generates warnings during Deployment creation if configured with `pod-security.kubernetes.io/warn=restricted`, but enforcement occurs strictly on Pod creation requests.

---

### Exercise 2 Solutions

* **Answer 2.1:**
  * **In-Process Execution (Zero Latency):** `ValidatingAdmissionPolicy` evaluates CEL expressions within the `kube-apiserver` process loop. It avoids out-of-process HTTP/HTTPS roundtrips over the pod network, removing serialized network latency.
  * **High Availability & Zero Dependency:** External dynamic webhooks depend on external web-server pods, Service DNS resolution, and TLS certificates. If those pods crash, the webhook fails. CEL policies have zero runtime pod dependencies and cannot crash independently of `kube-apiserver`.
  * **Operational Simplicity:** Eliminates TLS certificate lifecycle management (CA bundles, cert rotations) and web server deployment maintenance.

* **Answer 2.2:**
  * **Behavior:** The API server will **allow and persist** the resource request into `etcd` (the operation succeeds with HTTP 200/201 status).
  * **Audit:** It writes an audit log entry tagged with the policy failure details to the API Server audit log stream (`kube-apiserver-audit.log`).
  * **Warn:** It sends an HTTP response header (`Warning: 299 - ...`) back to the client (`kubectl`), printing the warning message directly to the terminal stdout/stderr for the engineer executing the command.

---

### Exercise 3 Solutions

* **Answer 3.1:**
  * **Deadlock / Circular Dependency (Control Plane Lockout):** If a webhook intercepts all namespaces including `kube-system` and its own deployment namespace (`webhook-system`) with `failurePolicy: Fail`, a catastrophic deadlock can occur:
    1. If the webhook pod crashes or the node hosting it restarts, the webhook service becomes unreachable.
    2. The API server blocks all subsequent pod creation requests because the webhook cannot be called.
    3. The Kubernetes scheduler or deployment controllers cannot spawn a replacement webhook pod (or any CNI/CoreDNS pod) because the API server rejects pod creation requests due to the broken webhook.
  * **Prevention:** Always configure `namespaceSelector` or `objectSelector` to explicitly exclude system namespaces (`kube-system`, `kube-public`, control plane namespaces, and the webhook's own namespace).

* **Answer 3.2:**
  * **Purpose:** `reinvocationPolicy` controls whether a mutating webhook should be called a second time if a *subsequent* mutating webhook in the pipeline modifies the object payload.
  * **Allowed Values:** `Never` (default) and `IfNeeded`.
  * **Loop Prevention:** Setting `reinvocationPolicy: Never` guarantees that the webhook is called at most once per admission request. Additionally, `kube-apiserver` caps the maximum number of re-invocation iterations (hard limit of 5 cycles) to prevent infinite loops caused by mutually conflicting mutating webhooks.

</details>