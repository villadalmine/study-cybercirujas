# CNCF Certified Cloud Native Platform Engineer (CNPE)
## Module 3: Security, Compliance, and Governance
### Topic 3.4: Using Policy Engines and Admission Controllers for Governance

---

## 1. Architectural Deep Dive: Kubernetes Admission Control & Policy Engines

### 1.1 Kubernetes API Server Admission Control Pipeline
When an API request reaches the Kubernetes API server (`kube-apiserver`), it undergoes a strict multi-stage evaluation pipeline before being persisted to `etcd`:

```
   +---------------------------------------------------------------------------------+
   |                                 kube-apiserver                                  |
   |                                                                                 |
   |  +----------------+    +-------------------+    +----------------------------+  |
   |  | Authentication | -> |   Authorization   | -> | Mutating Admission Phase   |  |
   |  |  (TLS, OIDC)   |    | (RBAC, Webhooks)  |    | (Built-in + Webhook Webhooks) |
   |  +----------------+    +-------------------+    +----------------------------+  |
   +---------------------------------------------------------------+-----------------+
                                                                   |
                                                                   v
   +---------------------------------------------------------------+-----------------+
   |  +------------------+    +---------------------+    +-------------------------+ |
   |  | Schema Validation| -> | Validating Admission| -> |      etcd Storage       | |
   |  | (OpenAPI v2/v3)  |    | (Built-in + Webhooks) |  |   (Object Persistence)  | |
   |  +------------------+    +---------------------+    +-------------------------+ |
   +---------------------------------------------------------------------------------+
```

1. **Authentication & Authorization**: The client request is authenticated (e.g., via X.509 client certificates or ServiceAccount tokens) and authorized via RBAC.
2. **Mutating Admission Phase**: 
   - Built-in mutating controllers and external `MutatingWebhookConfiguration` resources execute in sequence.
   - If multiple mutating webhooks exist, they are executed alphabetically by webhook configuration name or according to specified ordering.
   - **Re-invocation Phase**: If a mutating webhook alters an object, the mutating pipeline re-invokes earlier mutating webhooks (up to 5 times) if their `reinvocationPolicy` is set to `IfNeeded`.
3. **Object Schema Validation**: The modified request payload is checked against the API server's structural OpenAPI schema.
4. **Validating Admission Phase**:
   - Built-in validating controllers and external `ValidatingWebhookConfiguration` resources execute in parallel.
   - If any validating webhook rejects the request, the entire operation fails immediately with an HTTP 422 (Unprocessable Entity) or 403 (Forbidden) response.
5. **Persistence**: Validated requests are serialized and committed to `etcd`.

---

### 1.2 Policy Engine Architecture Comparison: OPA/Gatekeeper vs. Kyverno

| Architectural Dimension | OPA / Gatekeeper | Kyverno |
| :--- | :--- | :--- |
| **Language Paradigm** | Declarative logic via **Rego** (Datalog derivative). | Native Kubernetes **Custom Resources (YAML)**. |
| **Primary Webhooks** | `ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration` (Gator/v3+). | `ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`. |
| **Audit Mechanism** | Cron-based controller audits cluster state against `Constraints`. | Background controller scans resources against `ClusterPolicy` rules. |
| **Data Architecture** | Replicates cluster state into in-memory OPA cache via OPA Sync (`sync.yaml`). | Queries API server on-demand or uses cached informers. |
| **Mutation Engine** | Requires `Assign`, `AssignMetadata`, or `ModifySet` CRDs. | Native inline `mutate` blocks (JSON Patch, Strategic Merge, overlay). |
| **Generation Engine** | Not natively supported (requires custom controllers or Flux/ArgoCD). | Built-in `generate` block (creates resources like NetworkPolicies, ResourceQuotas). |
| **Extensibility** | High. Capable of handling arbitrary complex set theory and nested JSON array logic. | High for standard K8s objects; limited for abstract cross-resource data operations. |

---

### 1.3 Key Trade-offs & Production Considerations

- **Failure Policy (`failurePolicy: Fail` vs. `Ignore`)**:
  - `Fail`: Rejects API requests if the policy engine webhook is unreachable or times out (`timeoutSeconds`). Essential for high-security environments, but introduces an API server availability dependency. If the policy engine pod crashes, cluster operations stall.
  - `Ignore`: Bypasses policy evaluation during webhook failure. Preserves API availability but introduces compliance bypass vulnerabilities.
- **Webhook Timeouts**: Kubernetes defaults to a 10-second webhook timeout (configurable down to 1s). High latency in custom webhooks causes API server request queues to saturate.
- **Namespace Exemptions**: Policy engine deployments (`gatekeeper-system`, `kyverno`) must be exempted from their own webhooks to prevent circular deadlock during bootstrap or recovery scenarios.

---

## 2. Guided Production Exercises

### Prerequisites
Ensure you have access to a Kubernetes cluster (v1.28+) with `kubectl` configured with `cluster-admin` privileges. Helm 3 must be installed.

---

### Exercise 1: Deploying Kyverno and Enforcing Root User & Registry Governance

#### Scenario
Your security team requires that no Pods run as the `root` user (`runAsNonRoot: true`), and all container images must originate from an approved enterprise container registry (`registry.enterprise.io/`).

#### Step 1: Install Kyverno via Helm with Strict Failure Policy
Execute the following commands to deploy Kyverno into its dedicated namespace:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=2 \
  --set admissionController.webhook.failurePolicy=Fail
```

##### Expected Output:
```text
NAME: kyverno
LAST DEPLOYED: Fri Aug  7 18:20:00 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
Thank you for installing kyverno!
```

Verify that the admission controller pods are ready:

```bash
kubectl get pods -n kyverno -l app.kubernetes.io/component=admission-controller
```

##### Expected Output:
```text
NAME                                                  READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d8487b99c-2x89b         1/1     Running   0          42s
kyverno-admission-controller-7d8487b99c-9n7zw         1/1     Running   0          42s
```

#### Step 2: Apply a Syntax-Valid Kyverno ClusterPolicy
Create a file named `disallow-root-and-untrusted-registry.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-root-and-untrusted-registry
  annotations:
    policies.kyverno.io/title: Enforce Non-Root and Approved Registries
    policies.kyverno.io/category: Pod Security & Supply Chain
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Enforces that runAsNonRoot is set to true and all images are pulled
      exclusively from registry.enterprise.io.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-run-as-non-root
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "Running as root is forbidden. securityContext.runAsNonRoot must be set to true."
        pattern:
          spec:
            =(securityContext):
              runAsNonRoot: true
            containers:
              - name: "*"
                =(securityContext):
                  =(runAsNonRoot): true
    - name: check-approved-registry
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "Image registry is not allowed. Images must come from registry.enterprise.io."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotIn
                    value: ["registry.enterprise.io/*"]
```

Apply the manifest to the cluster:

```bash
kubectl apply -f disallow-root-and-untrusted-registry.yaml
```

##### Expected Output:
```text
clusterpolicy.kyverno.io/disallow-root-and-untrusted-registry created
```

#### Step 3: Test Non-Compliant Pod Rejection
Attempt to run a non-compliant workload using a public Docker Hub image without non-root configuration:

```bash
kubectl run unauthorized-pod --image=nginx:alpine --restart=Never
```

##### Expected Output:
```text
Error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/unauthorized-pod was blocked due to the following policies:

disallow-root-and-untrusted-registry:
  check-approved-registry: 'Image registry is not allowed. Images must come from registry.enterprise.io.'
  check-run-as-non-root: 'Running as root is forbidden. securityContext.runAsNonRoot must be set to true.'
```

#### Step 4: Deploy a Fully Compliant Workload
Create a manifest named `compliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: compliant-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
  containers:
    - name: app
      image: registry.enterprise.io/web/nginx:alpine
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
```

Apply the compliant manifest:

```bash
kubectl apply -f compliant-pod.yaml
```

##### Expected Output:
```text
pod/compliant-pod created
```

---

#### Verification Questions (Exercise 1)

1. Explain what happens during the admission pipeline if `validationFailureAction` is set to `Audit` instead of `Enforce`.
2. Why is `background: true` significant in a Kyverno `ClusterPolicy` definition, and how does it interact with pre-existing cluster resources?

---

### Exercise 2: Implementing Mutating Admission Policies for Security Sidecar Injection

#### Scenario
Platform Operations requires that all application Pods deployed in namespaces labeled `injection=enabled` automatically receive a security logging sidecar container and a default environment label (`env=production`) if not explicitly specified.

#### Step 1: Create the Target Namespace
Label a dedicated namespace for mutation testing:

```bash
kubectl create namespace app-space
kubectl label namespace app-space injection=enabled
```

##### Expected Output:
```text
namespace/app-space created
namespace/app-space labeled
```

#### Step 2: Define a Mutating Kyverno ClusterPolicy
Create a file named `mutate-inject-sidecar.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-security-sidecar
spec:
  rules:
    - name: add-env-label
      match:
        any:
        - resources:
            namespaces:
              - app-space
            kinds:
              - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(env): production
    - name: inject-sidecar-container
      match:
        any:
        - resources:
            namespaces:
              - app-space
            kinds:
              - Pod
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - name: security-logger
                image: registry.enterprise.io/sec/logger:v1.0
                resources:
                  limits:
                    cpu: 100m
                    memory: 128Mi
                  requests:
                    cpu: 50m
                    memory: 64Mi
```

Apply the mutating policy:

```bash
kubectl apply -f mutate-inject-sidecar.yaml
```

##### Expected Output:
```text
clusterpolicy.kyverno.io/inject-security-sidecar created
```

#### Step 3: Test Mutation Engine Execution
Create a simple workload manifest without labels or sidecars in `test-app.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: business-app
  namespace: app-space
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 2000
  containers:
    - name: main-app
      image: registry.enterprise.io/apps/biz:v2.1
```

Apply the manifest:

```bash
kubectl apply -f test-app.yaml
```

##### Expected Output:
```text
pod/business-app created
```

#### Step 4: Validate Mutated State via API Server
Inspect the mutated live object:

```bash
kubectl get pod business-app -n app-space -o jsonpath='{.metadata.labels}'
```

##### Expected Output:
```json
{"env":"production"}
```

Inspect the container array to verify sidecar injection:

```bash
kubectl get pod business-app -n app-space -o jsonpath='{.spec.containers[*].name}'
```

##### Expected Output:
```text
main-app security-logger
```

---

#### Verification Questions (Exercise 2)

1. If a `ValidatingWebhookConfiguration` and a `MutatingWebhookConfiguration` both match the same incoming API request, which webhook executes first, and why?
2. What risk is introduced if a mutating webhook modifies fields evaluated by an earlier mutating webhook, and how does Kubernetes mitigate infinite mutation loops?

---

### Exercise 3: OPA Gatekeeper Governance: ConstraintTemplates, Constraints, and Rego

#### Scenario
Deploy OPA Gatekeeper and construct a custom `ConstraintTemplate` that enforces resource request declarations (`cpu` and `memory`) on all workload containers.

#### Step 1: Deploy OPA Gatekeeper via Official Manifests

```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
```

##### Expected Output:
```text
namespace/gatekeeper-system created
customresourcedefinition.apiextensions.k8s.io/constrainttemplates.templates.gatekeeper.sh created
...
deployment.apps/gatekeeper-controller-manager created
deployment.apps/gatekeeper-audit created
```

Verify deployment readiness:

```bash
kubectl get pods -n gatekeeper-system
```

##### Expected Output:
```text
NAME                                             READY   STATUS    RESTARTS   AGE
gatekeeper-audit-57d6b49f4b-7p2xk                1/1     Running   0          35s
gatekeeper-controller-manager-666874f67c-9b8lw   1/1     Running   0          35s
gatekeeper-controller-manager-666874f67c-d6x2v   1/1     Running   0          35s
```

#### Step 2: Define a Custom ConstraintTemplate in Rego
Create `k8srequiredresources_template.yaml`:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredresources
  annotations:
    metadata.gatekeeper.sh/title: Required Resources
    description: >-
      Requires containers to have CPU and memory resource requests defined.
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredResources
      validation:
        openAPIV3Schema:
          type: object
          properties:
            resources:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredresources

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          provided := {res | container.resources.requests[res]}
          required := {res | res := input.parameters.resources[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("Container <%v> in Pod <%v> is missing required resource requests: %v", [container.name, input.review.object.metadata.name, missing])
        }
```

Apply the ConstraintTemplate:

```bash
kubectl apply -f k8srequiredresources_template.yaml
```

##### Expected Output:
```text
constrainttemplate.templates.gatekeeper.sh/k8srequiredresources created
```

#### Step 3: Instantiate a Constraint Resource
Create `require-cpu-memory-requests.yaml`:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredResources
metadata:
  name: pod-must-have-requests
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "default"
  parameters:
    resources: ["cpu", "memory"]
```

Apply the Constraint:

```bash
kubectl apply -f require-cpu-memory-requests.yaml
```

##### Expected Output:
```text
k8srequiredresources.constraints.gatekeeper.sh/pod-must-have-requests created
```

#### Step 4: Validate Admission Denials via OPA Engine
Attempt to deploy a container missing resource specifications:

```bash
kubectl run no-resource-pod --image=nginx:alpine -n default
```

##### Expected Output:
```text
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [pod-must-have-requests] Container <no-resource-pod> in Pod <no-resource-pod> is missing required resource requests: {"cpu", "memory"}
```

---

#### Verification Questions (Exercise 3)

1. Describe the structural relationship between a OPA Gatekeeper `ConstraintTemplate` and a `Constraint`.
2. How does OPA Gatekeeper evaluate compliance for pre-existing resources that were created prior to applying a `Constraint`?

---

### Exercise 4: Advanced Webhook Diagnostics and Failure Mode Troubleshooting

#### Scenario
An administrator misconfigures a `ValidatingWebhookConfiguration` pointing to a dead endpoint with `failurePolicy: Fail`, blocking all Pod creations in the cluster. You must diagnose the API failure and resolve the lock-out.

#### Step 1: Inject a Failing Webhook Configuration
Create `broken-webhook.yaml`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: broken-governance-webhook
webhooks:
  - name: broken.unreachable.domain
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      url: "https://192.0.2.254:9443/validate" # RFC 5737 Non-routable IP
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
```

Apply the broken configuration:

```bash
kubectl apply -f broken-webhook.yaml
```

##### Expected Output:
```text
validatingwebhookconfiguration.admissionregistration.k8s.io/broken-governance-webhook created
```

#### Step 2: Reproduce the Failure State
Attempt to create a pod in the cluster:

```bash
kubectl run test-fail-pod --image=nginx:alpine --request-timeout='5s'
```

##### Expected Output:
```text
Error from server (InternalError): Internal error occurred: failed calling webhook "broken.unreachable.domain": failed to call webhook: Post "https://192.0.2.254:9443/validate?timeout=3s": context deadline exceeded
```

#### Step 3: Perform Root Cause Analysis (RCA) via API Server Events & Webhook Inspection
Filter cluster `ValidatingWebhookConfigurations` to identify endpoints with `failurePolicy: Fail`:

```bash
kubectl get validatingwebhookconfigurations -o custom-columns=\
NAME:.metadata.name,\
FAIL_POLICY:.webhooks[*].failurePolicy,\
TIMEOUT:.webhooks[*].timeoutSeconds,\
URL:.webhooks[*].clientConfig.url
```

##### Expected Output:
```text
NAME                        FAIL_POLICY   TIMEOUT   URL
broken-governance-webhook   Fail          3         https://192.0.2.254:9443/validate
kyverno-resource-validation Fail          10        <none>
```

Inspect API Server Logs (or control plane event stream) for webhook handshake timeouts:

```bash
kubectl get events --all-namespaces --field-selector reason=FailedCallingWebhook
```

#### Step 4: Emergency Remediation
Delete the blocking webhook configuration:

```bash
kubectl delete validatingwebhookconfiguration broken-governance-webhook
```

##### Expected Output:
```text
validatingwebhookconfiguration.admissionregistration.k8s.io "broken-governance-webhook" deleted
```

Verify cluster functionality restoration:

```bash
kubectl run recovery-pod --image=nginx:alpine
```

##### Expected Output:
```text
pod/recovery-pod created
```

---

#### Verification Questions (Exercise 4)

1. If a system-critical control plane namespace (such as `kube-system`) is blocked by an unreachable `ValidatingWebhookConfiguration` with `failurePolicy: Fail`, how can you configure the webhook's `namespaceSelector` to prevent control plane deadlock?
2. What is the role of `caBundle` in a `WebhookClientConfig`, and what error is returned by `kube-apiserver` if `caBundle` is invalid or missing?

---

<details>
<summary><strong>Answers & Explanations</strong></summary>

### Exercise 1 Answers

1. **`validationFailureAction: Audit` Execution Mechanics**:
   When `validationFailureAction` is set to `Audit`, non-compliant API requests are **not rejected**. The `kube-apiserver` permits object persistence in `etcd`. However, Kyverno generates a `PolicyReport` or `ClusterPolicyReport` custom resource detailing the violation and logs an audit event. This mode is used for testing new policies in production without risking application outage.

2. **Significance of `background: true`**:
   `background: true` instructs the policy engine background controller to continuously scan existing resources already residing in `etcd`. If a policy is created *after* non-compliant workloads are running, the background scanner detects these pre-existing violations and generates corresponding policy reports, ensuring governance visibility over legacy state.

---

### Exercise 2 Answers

1. **Webhook Execution Ordering**:
   **Mutating webhooks execute FIRST**, followed by OpenAPI Schema Validation, and finally **Validating webhooks execute LAST**. This sequence ensures that any alterations or sidecars injected during the mutating phase are subjected to full structural schema validation and security rule checks during the validating phase before etcd persistence.

2. **Re-invocation and Infinite Mutation Loops**:
   If a mutating webhook alters an object, other mutating webhooks with `reinvocationPolicy: IfNeeded` are re-evaluated. If two mutating webhooks make conflicting, cyclic changes (e.g., Webhook A appends Label X, Webhook B removes Label X), an infinite loop could occur. Kubernetes mitigates this by capping the re-invocation count to a maximum of **5 iterations**. If stability is not reached, the API request fails with an error.

---

### Exercise 3 Answers

1. **ConstraintTemplate vs. Constraint Relationship**:
   A `ConstraintTemplate` acts as the **class definition/schema** containing the core Rego policy logic and defining parameter requirements. A `Constraint` is an **instance** of that template, binding specific parameters (e.g., `resources: ["cpu", "memory"]`) to target Kubernetes match criteria (e.g., specific namespaces or resource kinds).

2. **Audit of Pre-existing Resources in OPA Gatekeeper**:
   Gatekeeper runs a dedicated `gatekeeper-audit` pod. This controller periodically queries the API server for resources matching active `Constraints`, evaluates their state against the Rego rules, and writes compliance violations directly into the `.status.violations` field of the respective `Constraint` CRD.

---

### Exercise 4 Answers

1. **Preventing Control Plane Deadlocks with `namespaceSelector`**:
   You can configure a `namespaceSelector` using `matchExpressions` with `NotIn` to explicitly exclude critical operational namespaces:
   ```yaml
   namespaceSelector:
     matchExpressions:
       - key: kubernetes.io/metadata.name
         operator: NotIn
         values: ["kube-system", "kyverno", "gatekeeper-system"]
   ```

2. **Role of `caBundle`**:
   The `caBundle` is a PEM-encoded X.509 CA certificate payload used by `kube-apiserver` to verify the TLS identity of the external admission webhook server. If `caBundle` is missing, invalid, or signed by an untrusted authority, TLS handshake verification fails, resulting in an API error: `x509: certificate signed by unknown authority` or `failed calling webhook: tls verification failed`.

</details>

---

## Official Documentation References
- [Kubernetes Documentation: Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [CNCF Curriculum repository (CNPE Exam)](https://github.cncf.io/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
- [Kyverno Official Documentation: Policy Architecture](https://kyverno.io/docs/architecture/)
- [OPA Gatekeeper Documentation: How to use Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/docs/howto/)