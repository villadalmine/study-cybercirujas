# Study Guide: Domain 3.4 — Using Policy Engines and Admission Controllers for Governance

**Certification:** CNCF Certified Cloud Native Platform Engineer (CNPE)  
**Domain Weight:** 3%  
**Target Role:** Principal Platform Architect / Senior SRE  

---

## 1. Production Motivation and Architectural Problem

### 1.1 The Multi-Tenant Governance Gap

In cloud-native platform engineering, standard Kubernetes Role-Based Access Control (RBAC) operates strictly on API verbs (`get`, `create`, `update`, `delete`) and resource types (`pods`, `deployments`, `services`). RBAC cannot inspect or restrict the *contents* of API request payloads. 

This creates severe operational and security vulnerabilities in enterprise production clusters:

* **Privilege Escalation & Container Security:** RBAC permits a user to create a `Pod`, but cannot prevent that user from running the container as `root` (`runAsUser: 0`), mounting host paths (`hostPath`), or enabling high-risk Linux capabilities like `CAP_SYS_ADMIN`.
* **Supply Chain Integrity:** Standard API validation cannot restrict image sources. Unvetted images pulled from untrusted public registries can introduce vulnerabilities or malicious binaries into multi-tenant infrastructure.
* **Resource Exhaustion & noisy-neighbor issues:** Users can deploy workloads without CPU/Memory `requests` and `limits`, bypassing Quality of Service (QoS) guarantees (`Guaranteed`, `Burstable`, `BestEffort`) and inducing `Out-Of-Memory (OOM)` node evictions.
* **Network & Ingress Collisions:** Multiple tenants can define overlapping Ingress hostnames or request public `LoadBalancer` services that violate corporate network isolation policies.

### 1.2 Kubernetes API Server Request Lifecycle

Governance in Kubernetes is anchored inside the API server's request handling pipeline. Every write operation (`CREATE`, `UPDATE`, `DELETE`, `CONNECT`) passes through a strict sequential phase gate before reaching `etcd`:

```
                       KUBERNETES API SERVER REQUEST LIFECYCLE
                       
  +---------+     +-------------------+     +---------------------+
  | HTTP    |     |  Authentication   |     |    Authorization    |
  | Request | --> |  (Cert, OIDC,     | --> |    (RBAC, ABAC)     |
  |         |     |   ServiceAccount) |     |                     |
  +---------+     +-------------------+     +---------------------+
                                                       |
                                                       v
  +-------------------------------------------------------------------+
  |                  DYNAMIC ADMISSION CONTROL                        |
  |                                                                   |
  |  +---------------------+      +--------------------------------+  |
  |  | Mutating Admission  | ---> |  OpenAPI Schema & Structural   |  |
  |  | (Webhooks/In-tree)  |      |        Validation              |  |
  |  +---------------------+      +--------------------------------+  |
  |                                                |                  |
  |                                                v                  |
  |                               +--------------------------------+  |
  |                               | Validating Admission           |  |
  |                               | (Webhooks / In-tree VAP - CEL) |  |
  |                               +--------------------------------+  |
  +-------------------------------------------------------------------+
                                                       |
                                                       v
                                            +---------------------+
                                            |   etcd Persistence  |
                                            +---------------------+
```

1. **Authentication & Authorization:** Verifies identity and checks RBAC permissions.
2. **Mutating Admission Phase:** Modifies incoming payloads before schema compilation. Executed sequentially or iteratively until convergence (e.g., injecting sidecars, enforcing default resource limits, prepending private image registries).
3. **Schema Validation:** Verifies structural compliance against OpenAPI specifications.
4. **Validating Admission Phase:** Evaluates the request state against policy engines (e.g., Gatekeeper, Kyverno, ValidatingAdmissionPolicy). If *any* validating webhook or policy rejects the payload with an HTTP 422 / 403, the pipeline aborts immediately and nothing is written to `etcd`.
5. **Persistence:** The object is serialized and written to `etcd`.

### 1.3 Architectural Hazards & Threat Model of Webhooks

Dynamic Admission Controllers rely on HTTP webhooks (`MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`) targeting services running inside or outside the cluster. Introducing out-of-process webhooks into the API server synchronous call path creates significant architectural risks:

* **Control Plane Latency Amplification:** Every API write operation blocks on an HTTP/2 TLS call over the CNI overlay network to the webhook pod. If policy evaluation takes 200ms, API server throughput degrades significantly.
* **Control Plane Lockout (Cascading Failure):** If a validating webhook service crashes, experiences network partition, or runs out of memory, and its `failurePolicy` is set to `Fail`, the API server rejects ALL matching cluster operations. If `kube-system` resources (such as CoreDNS or CNI plugins) are managed by the policy without explicit exclusion selectors, the entire control plane deadlocks and cannot recover without manual intervention.
* **Reentrant Mutation Loops:** A mutating admission webhook that updates a resource can inadvertently trigger secondary admission requests, causing infinite policy loops if idempotency is not strictly enforced.

---

## 2. Technical Comparisons & Architectural Trade-offs

Selecting an admission governance framework requires weighing evaluation performance, operational overhead, policy language complexity, and failure modes.

### 2.1 Governance Architecture Comparison Matrix

| Architectural Axis | ValidatingAdmissionPolicy (In-Tree CEL) | OPA Gatekeeper (Out-of-Process Webhook) | Kyverno (Out-of-Process Webhook) | Custom Webhook (e.g., Go/Python API) |
| :--- | :--- | :--- | :--- | :--- |
| **Execution Context** | In-process within `kube-apiserver` via Common Expression Language (CEL). | Out-of-process Pod (`gatekeeper-controller-manager`). | Out-of-process Pod (`kyverno-admission-controller`). | Out-of-process custom deployment. |
| **Network Hop** | **Zero latency** overhead (In-memory C-Go / CEL evaluation engine). | Network hop via Pod IP / ClusterIP service + TLS overhead. | Network hop via Pod IP / ClusterIP service + TLS overhead. | Network hop via Pod IP / ClusterIP service + TLS overhead. |
| **Policy Language** | CEL (Common Expression Language, sandboxed, declarative). | Rego (Declarative logic programming language). | Declarative YAML / JSONPath (No custom DSL needed). | Imperative (Go, Python, Rust, Node.js). |
| **Mutation Capabilities** | Supported in K8s v1.32+ (`MutatingAdmissionPolicy`). | Limited / Experimental via `Assign` and `AssignMetadata` CRDs. | **Native & Powerful** (`mutate` rules, strategic merge patch, JSONPatch). | Full custom code control. |
| **Generation Capabilities** | None. | None. | **Native** (`generate` rules for namespace bootstrapping, sync secrets). | Full custom code control. |
| **Image Verification** | None (Requires external binary/webhook integration). | External integration via `gator` or custom OPA extensions. | **Native Sigstore / Cosign** public key and Keyless verification. | Custom Cosign SDK logic. |
| **Background Audit Scan** | None (Real-time admission only). | **Native Audit Controller** (scans existing resources in etcd). | **Native Policy Report Controller** (generates PolicyReports). | Requires building custom cron engine. |
| **Control Plane Lockout Risk** | **Zero risk** (Engine is embedded in API server; cannot disconnect network). | **High risk** if `failurePolicy: Fail` and pods/nodes degrade. | **High risk** if `failurePolicy: Fail` and pods/nodes degrade. | **High risk** if custom deployment crashes or fails healthz. |
| **Memory / CPU Overhead** | Marginal increase in `kube-apiserver` memory footprint. | High (Requires caching etcd context for stateful Rego queries). | Moderate (In-memory policy engine + CRD controller). | Variable based on implementation stack. |

---

## 3. Complete Production Manifests

The following manifests provide syntactically valid, production-grade configurations for all major policy enforcement mechanisms.

### 3.1 Kubernetes Native ValidatingAdmissionPolicy (CEL)

This policy enforces three security constraints natively in the API server:
1. Disallows root containers (`runAsNonRoot: true`).
2. Requires explicit CPU and Memory resource limits.
3. Restricts container images to approved enterprise registries (`registry.enterprise.io`).

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: production-security-governance
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c, 
          has(c.securityContext) && 
          has(c.securityContext.runAsNonRoot) && 
          c.securityContext.runAsNonRoot == true
        )
      message: "SECURITY VIOLATION: All containers must explicitly set securityContext.runAsNonRoot to true."
      reason: Forbidden
    - expression: >-
        object.spec.containers.all(c, 
          has(c.resources) && 
          has(c.resources.limits) && 
          has(c.resources.limits.cpu) && 
          has(c.resources.limits.memory)
        )
      message: "QOS VIOLATION: All containers must specify CPU and Memory limits."
      reason: Invalid
    - expression: >-
        object.spec.containers.all(c, 
          c.image.startsWith("registry.enterprise.io/")
        )
      message: "SUPPLY CHAIN VIOLATION: Container images must originate from registry.enterprise.io."
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionBinding
metadata:
  name: production-security-governance-binding
spec:
  policyName: production-security-governance
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "gatekeeper-system", "kyverno"]
```

---

### 3.2 OPA Gatekeeper Manifests (ConstraintTemplate & Constraint)

Gatekeeper enforces policies using Open Policy Agent's Rego engine via custom CRDs.

#### ConstraintTemplate (`k8sallowedregistries.yaml`)
Defines the schema parameters and the Rego evaluation logic.

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
  annotations:
    metadata.gatekeeper.sh/title: "Allowed Registries"
    description: "Requires container images to originate from an approved list of domain prefixes."
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | reg := input.parameters.registries; good := startswith(container.image, reg)]
          not any(satisfied)
          msg := sprintf("Container image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | reg := input.parameters.registries; good := startswith(container.image, reg)]
          not any(satisfied)
          msg := sprintf("InitContainer image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }
```

#### Constraint (`enforce-enterprise-registry.yaml`)
Instantiates the ConstraintTemplate with concrete parameters and targeting rules.

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: enforce-enterprise-registry
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces:
      - kube-system
      - kube-public
      - gatekeeper-system
  parameters:
    registries:
      - "registry.enterprise.io/"
      - "quay.io/enterprise/"
```

---

### 3.3 Kyverno ClusterPolicy (Mutating, Validating, Generating)

Kyverno allows policy management entirely within declarative Kubernetes YAML.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-governance-policy
  annotations:
    policies.kyverno.io/title: "Comprehensive Platform Security & Governance"
    policies.kyverno.io/subject: "Pod, Namespace"
    policies.kyverno.io/description: >-
      Enforces read-only root filesystems, mutates default security contexts,
      and automatically generates default NetworkPolicies for new namespaces.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    # 1. VALIDATION RULE: Require Read-Only Root Filesystem
    - name: validate-readonly-root-fs
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      validate:
        message: "SECURITY VIOLATION: Root filesystem must be mounted as read-only (securityContext.readOnlyRootFilesystem=true)."
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true

    # 2. MUTATION RULE: Inject Security Context Defaults if Missing
    - name: mutate-inject-non-root-user
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - kyverno
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              runAsNonRoot: true
              runAsUser: 10001

    # 3. GENERATION RULE: Auto-provision Default Deny NetworkPolicy on Namespace Creation
    - name: generate-default-deny-networkpolicy
      match:
        any:
          - resources:
              kinds:
                - Namespace
      exclude:
        any:
          - resources:
              name: "kube-*"
              namespaces:
                - kyverno
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-all
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
              - Ingress
              - Egress
```

---

### 3.4 Low-Level MutatingWebhookConfiguration

For custom-built admission services, this manifest defines the explicit control-plane interface to an out-of-process webhook backend.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: enterprise-mutating-governance-webhook
  labels:
    app.kubernetes.io/name: admission-governance
    app.kubernetes.io/part-of: platform-security
spec:
  webhooks:
    - name: mutate.governance.enterprise.io
      admissionReviewVersions:
        - "v1"
      clientConfig:
        service:
          name: governance-webhook-svc
          namespace: platform-system
          path: "/mutate-v1-pod"
          port: 443
        # LS0tLS1CRUdJTi... represents base64-encoded PEM CA certificate string
        caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==" 
      rules:
        - apiGroups: [""]
          apiVersions: ["v1"]
          operations: ["CREATE"]
          resources: ["pods"]
          scope: "Namespaced"
      failurePolicy: Fail
      sideEffects: None
      timeoutSeconds: 3
      reinvocationPolicy: NeededOnModificationLater
      matchPolicy: Exact
      namespaceSelector:
        matchExpressions:
          - key: control-plane
            operator: NotIn
            values: ["true"]
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: ["kube-system", "kube-public", "platform-system"]
      objectSelector:
        matchExpressions:
          - key: governance.enterprise.io/bypass
            operator: DoesNotExist
```

---

## 4. Real CLI Commands & Expected Outputs

### 4.1 Applying ValidatingAdmissionPolicy and Testing Enforcement

```bash
$ kubectl apply -f validating-admission-policy.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/production-security-governance created
validatingadmissionbinding.admissionregistration.k8s.io/production-security-governance-binding created
```

#### Attempting to deploy a non-compliant pod (Root container & unapproved registry)

```bash
$ kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: insecure-test-pod
  namespace: default
spec:
  containers:
    - name: nginx
      image: docker.io/library/nginx:latest
EOF
```

#### Expected Terminal Output (HTTP 402/403 API Rejection)

```text
Error from server (Forbidden): error when creating "STDIN": pods "insecure-test-pod" is forbidden: 
validatingadmissionpolicy 'production-security-governance' with binding 'production-security-governance-binding' denied request: 
[1] SECURITY VIOLATION: All containers must explicitly set securityContext.runAsNonRoot to true.
[2] QOS VIOLATION: All containers must specify CPU and Memory limits.
[3] SUPPLY CHAIN VIOLATION: Container images must originate from registry.enterprise.io.
```

---

### 4.2 Inspecting Gatekeeper Constraints and Audit Violations

```bash
$ kubectl get constrainttemplates
NAME                   AGE
k8sallowedregistries   12m

$ kubectl get constraints
NAME                          ENFORCEMENT-ACTION   TOTAL-VIOLATIONS   AGE
enforce-enterprise-registry   deny                 3                  10m
```

#### Inspecting Detailed Audit Findings from etcd via Gatekeeper Status

```bash
$ kubectl get constraint enforce-enterprise-registry -o jsonpath='{range .status.violations[*]}{"Pod: "}{.name}{"\t Namespace: "}{.namespace}{"\nReason: "}{.message}{"\n---\n"}{end}'
```

#### Expected Terminal Output

```text
Pod: legacy-billing-app-7b94b545d-x492p	 Namespace: finance
Reason: Container image 'docker.io/mysql:5.7' comes from an unauthorized registry. Allowed registries: ["registry.enterprise.io/", "quay.io/enterprise/"]
---
Pod: rogue-dev-workload	 Namespace: default
Reason: Container image 'ubuntu:22.04' comes from an unauthorized registry. Allowed registries: ["registry.enterprise.io/", "quay.io/enterprise/"]
---
```

---

### 4.3 Querying Kyverno Policy Engine Execution Reports

```bash
$ kubectl get clusterpolicies
NAME                         ADMISSION   BACKGROUND   READY   AGE
platform-governance-policy   true        true         true    15m

$ kubectl get polr -A
```

#### Expected Terminal Output

```text
NAMESPACE   NAME                                   PASS   FAIL   WARN   ERROR   AGE
default     cpol-platform-governance-policy        1      2      0      0       8m
finance     cpol-platform-governance-policy        4      0      0      0       8m
prod        cpol-platform-governance-policy        12     0      0      0       8m
```

---

## 5. Verification & Diagnostic Troubleshooting Guide

When admission webhooks or policy engines fail, control planes can lock up, pods can hang in `ContainerCreating`, or deployments can fail silently. SREs must follow a systematic troubleshooting workflow.

### 5.1 Emergency Control Plane Lockout Recovery

#### Symptom
All `kubectl apply` commands hang and fail with `Error from server (InternalError): Internal error occurred: failed calling webhook... connection refused` or `context deadline exceeded`.

#### Step 1: Identify the Failing Webhook Configuration

```bash
$ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o custom-columns=KIND:.kind,NAME:.metadata.name,FAIL_POLICY:.webhooks[*].failurePolicy,TIMEOUT:.webhooks[*].timeoutSeconds
```

#### Step 2: Emergency Bypass / Delete Broken Webhook

If the API server is completely frozen for normal operations, use the administrative cluster-admin context or bypass flags to remove the locking webhook configuration:

```bash
$ kubectl delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration --timeout=5s
```

If `kubectl` hangs due to an API server connection pool exhaustion caused by webhooks:
1. SSH into a Control Plane node.
2. Edit `/etc/kubernetes/manifests/kube-apiserver.yaml`.
3. Temporarily add the flag `--disable-admission-plugins=MutatingAdmissionWebhook,ValidatingAdmissionWebhook`.
4. Wait for static pod restarting of `kube-apiserver`, perform cleanup of the invalid Webhook CRDs, and revert the static pod manifest.

---

### 5.2 Latency and Performance Debugging

Admission webhooks add synchronous overhead. If `kube-apiserver` latency metrics spike, investigate using Prometheus metrics exposed by the API server.

#### Query: Admission Webhook Latency (99th Percentile by Webhook Name)

```promql
histogram_quantile(0.99, sum(rate(apiserver_admission_webhook_admission_duration_seconds_bucket[5m])) by (le, name))
```

#### Command Line Inspection of API Server Metrics

```bash
$ kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_sum
apiserver_admission_webhook_admission_duration_seconds_sum{name="mutate.kyverno.svc-fail",operation="CREATE",type="admit"} 142.521045
apiserver_admission_webhook_admission_duration_seconds_sum{name="validation.gatekeeper.sh",operation="CREATE",type="admit"} 12.102341
```

> **Diagnosis:** If any webhook shows an average admission latency > 100ms, examine its `timeoutSeconds` (reduce to `<=3s`) and verify that its pod infrastructure has sufficient CPU/Memory limits assigned.

---

### 5.3 Diagnostic Decision Tree for Policy Engine Failures

```
                    ADMISSION CONTROL FAILURE DIAGNOSTIC TREE
                    
                         [ Admission Request Failed ]
                                      |
                                      v
                      Is API Server reachable via HTTP?
                                   /     \
                             NO   /       \ YES
                                 /         \
                                v           v
            Check Control Plane Nodes    Check Return Error Code
            - API server static pods     - Is it HTTP 403 / 422? (Policy Denied)
            - Disk/etcd exhaustion       - Is it HTTP 500? (Webhook Engine Error)
                                                    |
                                                    v
                                    +-------------------------------+
                                    | Check Webhook Health & Logs   |
                                    +-------------------------------+
                                                    |
             +--------------------------------------+--------------------------------------+
             |                                      |                                      |
             v                                      v                                      v
    [ TLS / Cert Failure ]                 [ Timeout / Network ]                [ Engine Panic / OOM ]
  - Check caBundle in Webhook            - Check CNI overlay health            - Check 'kubectl top pods'
  - Verify cert-manager secret           - Check Service endpoint IPs          - Search logs for Rego/CEL
  - Check cert expiration date           - Check Pod CPU throttling              syntax evaluation panics
```

---

### 5.4 CA Bundle and TLS Verification Failures

Out-of-process webhooks **must** communicate over TLS v1.2/v1.3. A common error is:

```text
Error from server (InternalError): Internal error occurred: failed calling webhook "mutate.governance.enterprise.io": 
x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate)
```

#### Diagnostic Commands

Verify that the `caBundle` in the webhook match the actual serving certificate of the target service pod:

```bash
# Extract caBundle configured in Webhook
$ kubectl get mutatingwebhookconfiguration enterprise-mutating-governance-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | openssl x509 -noout -text -dates

# Extract actual serving cert from Webhook Service Pod
$ kubectl exec -n platform-system deployment/governance-webhook-svc -- cat /etc/webhook/certs/tls.crt | openssl x509 -noout -text -dates
```

Compare serial numbers and expiry dates. Ensure `cert-manager` or custom auto-rotators correctly update both the Secret **and** the `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` object specs simultaneously.

---

## 6. References

* **CNCF CNPE Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* **Kubernetes Dynamic Admission Control Documentation:**  
  [https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
* **Kubernetes Validating Admission Policy (CEL Reference):**  
  [https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
* **OPA Gatekeeper Documentation:**  
  [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)
* **Kyverno Architecture & Policy Documentation:**  
  [https://kyverno.io/docs/](https://kyverno.io/docs/)
* **Common Expression Language (CEL) Specification:**  
  [https://github.com/google/cel-spec](https://github.com/google/cel-spec)