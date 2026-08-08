# CNPE Exam Study Guide: Topic 5.4 — Using Automation Frameworks for Self-Service Provisioning

**Exam Domain:** Platform Engineering & Infrastructure Automation  
**Topic Weight:** 6.25%  
**Target Certification:** CNCF Certified Cloud Native Platform Engineer (CNPE)  
**Official Reference:** [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

---

## 1. Architectural Blueprint & Deep Technical Mechanics

Self-service provisioning in modern Cloud Native Platforms decouples infrastructure implementation details from application developer intent. Rather than granting application teams direct access to cloud APIs (AWS, GCP, Azure) or low-level Kubernetes primitives, platform engineers construct **Control Plane API Abstractions** using automation frameworks such as **Crossplane**, **Argo CD**, and **Backstage Scaffolder**.

```
 +-----------------------------------------------------------------------------------+
 |                             Developer Portal / Service Catalog                     |
 |                             (e.g., Backstage Software Catalog)                    |
 +-----------------------------------------------------------------------------------+
                                           |  Trigger Scaffolder / Git Commit
                                           v
 +-----------------------------------------------------------------------------------+
 |                             GitOps Repository (Declarative Intent)                |
 |                             Manifest: PostgreSQLInstance Claim                    |
 +-----------------------------------------------------------------------------------+
                                           |  Reconcile Intent
                                           v
 +-----------------------------------------------------------------------------------+
 |                       Kubernetes Control Plane (Platform Cluster)                 |
 |                                                                                   |
 |  +-----------------------------------------------------------------------------+  |
 |  | CompositeResourceDefinition (XRD): xpostgresqlinstances.platform.cncf.io    |  |
 |  +-----------------------------------------------------------------------------+  |
 |                                         | Bind / Match                            |
 |  +-----------------------------------------------------------------------------+  |
 |  | Composition: postgresql-aws-aurora / postgresql-incluster-operator          |  |
 |  +-----------------------------------------------------------------------------+  |
 |                                         | Render Managed Resources                |
 |  +-----------------------------------------------------------------------------+  |
 |  | Managed Resources (MRs): DBSubnetGroup, RDSInstance, SecurityGroup, Secret    |  |
 |  +-----------------------------------------------------------------------------+  |
 +-----------------------------------------------------------------------------------+
                                           |  External API Calls
                                           v
 +-----------------------------------------------------------------------------------+
 |                               Cloud Provider / Target Environment                  |
 |                               (e.g., AWS RDS / GCP Cloud SQL / In-Cluster Stateful)|
 +-----------------------------------------------------------------------------------+
```

### Key Architectural Concepts

1. **Composite Resource Definitions (XRDs):**  
   An XRD defines the custom OpenAPI schema for a platform API (e.g., `PostgreSQLInstance`). It creates both an **Unclaimed Composite Resource (XR)** for cluster-scoped platform administration and an optional **Claim (XRC)** for namespace-scoped developer consumption.

2. **Compositions & Resource Binding:**  
   A `Composition` encapsulates the implementation blueprint. It maps the high-level parameters defined in an XRD to low-level Managed Resources (MRs) or nested K8s resources using **Patch and Transform** pipelines, **Function Pipelines** (`kusionstack/kusion` or `crossplane-contrib/function-patch-and-transform`), and connection secret publishing rules.

3. **Reconciliation Loop & State Convergence:**  
   The Crossplane controller runs a continuous control loop:
   $$\text{Observed State} \xrightarrow{\text{Diff against Desired State}} \text{Reconcile (Create/Update/Delete via Provider SDK)} \xrightarrow{\text{Update Ready/Synced Conditions}}$$
   - **`Synced=True`**: Declarative state successfully rendered and accepted by target API.
   - **`Ready=True`**: Target resource actively operational and passing health checks.

4. **Multi-Tenancy & Security Boundaries:**  
   Developers interact *only* with Namespaced Claims via restricted RBAC role bindings. Platform credentials (e.g., AWS IAM access keys or Cloud KMS keys) remain isolated inside the Provider Config in systemic namespaces (`crossplane-system`), preventing privilege escalation.

---

## 2. Guided Hands-On Exercises

### Prerequisites Setup Checklist

Ensure your local or lab environment contains the following tools before beginning:
- `kubectl` v1.28+
- `helm` v3.12+
- A running Kubernetes cluster (v1.28+) with Crossplane v1.14+ installed in `crossplane-system`.
- Argo CD v2.9+ installed in `argocd`.

---

### Exercise 1: Defining Control-Plane Abstractions with Crossplane XRDs and Compositions

#### Scenario
You are tasked with exposing a self-service database API named `PostgreSQLInstance` to developer namespaces. Application teams should only specify the database engine version, storage capacity (in GB), and tier (`small`, `medium`, `large`). The platform framework must automatically calculate CPU/memory constraints, instantiate an in-cluster database operator resource, and securely project connection credentials into the developer's namespace.

#### Step 1: Define the CompositeResourceDefinition (XRD)
Create a file named `xpostgresqlinstances-xrd.yaml`:

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.platform.cncf.io
spec:
  group: platform.cncf.io
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
    claimNames:
      kind: PostgreSQLInstance
      plural: postgresqlinstances
  claimNamespaced: true
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required:
                - storageGB
                - tier
              properties:
                storageGB:
                  type: integer
                  minimum: 5
                  maximum: 500
                  description: "Storage allocation in Gigabytes."
                tier:
                  type: string
                  enum: ["small", "medium", "large"]
                  description: "Compute tier mapping to CPU/Memory requests."
                postgresVersion:
                  type: string
                  default: "15"
                  enum: ["13", "14", "15"]
                  description: "Major PostgreSQL engine version."
            status:
              type: object
              properties:
                endpoint:
                  type: string
                phase:
                  type: string
```

Apply the XRD manifest to the cluster:

```bash
kubectl apply -f xpostgresqlinstances-xrd.yaml
```

**Expected Output:**
```
compositeresourcedefinition.apiextensions.crossplane.io/xpostgresqlinstances.platform.cncf.io created
```

Verify that the Custom Resource Definition was generated by Crossplane:

```bash
kubectl get crd xpostgresqlinstances.platform.cncf.io postgresqlinstances.platform.cncf.io
```

**Expected Output:**
```
NAME                                       CREATED AT
xpostgresqlinstances.platform.cncf.io      2026-08-07T19:22:35Z
postgresqlinstances.platform.cncf.io       2026-08-07T19:22:35Z
```

---

#### Step 2: Define the Composition Implementation Blueprint
Create a file named `composition-postgres-incluster.yaml`. This Composition maps the abstract `XPostgreSQLInstance` parameters to an operational target resource (in this case, a composite set including a `Secret` and a `ConfigMap` representing the target state, illustrating Crossplane's patch & transform engine).

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-incluster-production
  labels:
    provider: incluster
    environment: production
spec:
  compositeTypeRef:
    apiVersion: platform.cncf.io/v1alpha1
    kind: XPostgreSQLInstance
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: postgres-configmap
            base:
              apiVersion: v1
              kind: ConfigMap
              metadata:
                name: postgres-configuration
              data:
                max_connections: "100"
                shared_buffers: "128MB"
                storage_size: ""
                engine_version: ""
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: spec.storageGB
                toFieldPath: data.storage_size
                transforms:
                  - type: string
                    string:
                      fmt: "%dGi"
              - type: FromCompositeFieldPath
                fromFieldPath: spec.postgresVersion
                toFieldPath: data.engine_version
              - type: FromCompositeFieldPath
                fromFieldPath: spec.tier
                toFieldPath: metadata.labels['platform.cncf.io/tier']
          - name: postgres-secret
            base:
              apiVersion: v1
              kind: Secret
              metadata:
                name: postgres-conn-credential
              type: Opaque
              stringData:
                username: "postgres_admin"
                password: "SuperSecretProductionPassword123!"
            connectionDetails:
              - name: username
                type: FromFieldPath
                fromFieldPath: data.username
              - name: password
                type: FromFieldPath
                fromFieldPath: data.password
  writeConnectionSecretsToNamespace: crossplane-system
```

Apply the Composition to the cluster:

```bash
kubectl apply -f composition-postgres-incluster.yaml
```

**Expected Output:**
```
composition.apiextensions.crossplane.io/postgresql-incluster-production created
```

---

#### Step 3: Instantiate a Developer Self-Service Claim
Simulate an application developer requesting a database in their team namespace (`dev-team-alpha`).

Create the namespace and developer claim file `dev-db-claim.yaml`:

```bash
kubectl create namespace dev-team-alpha
```

```yaml
apiVersion: platform.cncf.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: order-db
  namespace: dev-team-alpha
spec:
  storageGB: 50
  tier: "medium"
  postgresVersion: "15"
  writeConnectionSecretToRef:
    name: order-db-conn-secret
```

Apply the claim:

```bash
kubectl apply -f dev-db-claim.yaml
```

**Expected Output:**
```
postgresqlinstance.platform.cncf.io/order-db created
```

---

#### Step 4: Verify Resource Reconciliation & Connection Secret Binding
Inspect the status of the namespaced claim and the underlying composite resource:

```bash
kubectl get postgresqlinstance -n dev-team-alpha order-db
```

**Expected Output:**
```
NAME       SYNCED   READY   CONNECTION-SECRET     AGE
order-db   True     True    order-db-conn-secret   14s
```

Check the generated connection secret in the developer namespace:

```bash
kubectl get secret -n dev-team-alpha order-db-conn-secret -o jsonpath='{.data.username}' | base64 --decode
```

**Expected Output:**
```
postgres_admin
```

Inspect the managed resource generated by the composition reconciliation pipeline:

```bash
kubectl get configmap -n dev-team-alpha -l platform.cncf.io/tier=medium
```

---

#### Comprehension Check: Exercise 1

> **Question 1.1:** What is the technical distinction between an `XR` (Composite Resource) and an `XRC` (Composite Resource Claim) in Crossplane architecture, and how does this enforce multi-tenancy security boundaries?
>
> **Question 1.2:** If a developer updates `spec.storageGB` from `50` to `100` in their `PostgreSQLInstance` claim manifest, explain the sequential steps the Kubernetes API server and Crossplane controllers execute to reconcile the underlying infrastructure.
>
> **Question 1.3:** What happens if two distinct `Composition` objects match the same `compositeTypeRef`? How does Crossplane decide which Composition to select when reconciling a Claim?

---

### Exercise 2: Building Multi-Tenant GitOps Provisioning with Argo CD ApplicationSets

#### Scenario
Self-service provisioning requires dynamic, automated deployment of tenant applications and infrastructure across heterogeneous target clusters. You must configure an **Argo CD ApplicationSet** using a **Matrix Generator** that combines a **Git Generator** (scanning tenant configuration files) with a **Cluster Generator** (targeting specific cloud environments based on label selectors).

```
   +-----------------------+      +-----------------------+
   |     Git Generator     |      |   Cluster Generator   |
   | (Scans tenant configs) |      | (Matches prod/staging)|
   +-----------------------+      +-----------------------+
               \                              /
                \                            /
                 v                          v
   +------------------------------------------------------+
   |               Matrix Generator                       |
   |   (Combines Tenant Config x Target Cluster Matrix)   |
   +------------------------------------------------------+
                             |
                             v
   +------------------------------------------------------+
   |        Generates Argo CD Applications dynamically    |
   |  - app-tenant-alpha-us-east-1                        |
   |  - app-tenant-beta-eu-west-1                         |
   +------------------------------------------------------+
```

#### Step 1: Prepare Git Directory Structure & Tenant Configs
Assume your infrastructure Git repository (`https://github.com/cncf-demo/platform-tenants.git`) contains the following tree:

```
tenants/
├── tenant-alpha/
│   └── config.json
└── tenant-beta/
    └── config.json
```

Where `tenants/tenant-alpha/config.json` contains:
```json
{
  "tenant": {
    "name": "tenant-alpha",
    "tier": "gold",
    "environment": "production"
  }
}
```

---

#### Step 2: Construct the ApplicationSet with Matrix Generator
Create `applicationset-tenant-matrix.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-selfservice-matrix
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          - git:
              repoURL: 'https://github.com/cncf-demo/platform-tenants.git'
              revision: HEAD
              files:
                - path: 'tenants/*/config.json'
          - clusters:
              selector:
                matchLabels:
                  environment: '{{ .tenant.environment }}'
  template:
    metadata:
      name: '{{ .tenant.name }}-{{ .serverNormalized }}'
      labels:
        platform.cncf.io/tenant: '{{ .tenant.name }}'
        platform.cncf.io/tier: '{{ .tenant.tier }}'
    spec:
      project: default
      source:
        repoURL: 'https://github.com/cncf-demo/platform-tenants.git'
        targetRevision: HEAD
        path: 'helm/tenant-base-chart'
        helm:
          valuesObject:
            tenantName: '{{ .tenant.name }}'
            tenantTier: '{{ .tenant.tier }}'
      destination:
        server: '{{ .server }}'
        namespace: 'tenant-{{ .tenant.name }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Apply the ApplicationSet:

```bash
kubectl apply -f applicationset-tenant-matrix.yaml -n argocd
```

**Expected Output:**
```
applicationset.argoproj.io/tenant-selfservice-matrix created
```

---

#### Step 3: Inspect Argo CD Application Generation
List the dynamically generated Applications created by the matrix controller:

```bash
kubectl get applications -n argocd -l platform.cncf.io/tenant=tenant-alpha
```

**Expected Output:**
```
NAME                                   SYNC STATUS   HEALTH STATUS
tenant-alpha-https-10-0-100-5-k8s     Synced        Healthy
```

Describe the Application resource to verify matrix variable interpolation:

```bash
kubectl get application tenant-alpha-https-10-0-100-5-k8s -n argocd -o jsonpath='{.spec.source.helm.valuesObject}'
```

**Expected Output:**
```json
{"tenantName":"tenant-alpha","tenantTier":"gold"}
```

---

#### Comprehension Check: Exercise 2

> **Question 2.1:** What problem does the `goTemplate: true` directive solve in Argo CD ApplicationSets compared to standard legacy fasttemplate rendering when manipulating complex JSON payloads from Git generators?
>
> **Question 2.2:** In a scenario where a target cluster label `environment` changes from `staging` to `production` in Argo CD secrets, explain how the Matrix Generator reconciles existing running `Applications`. Will resources in the staging cluster be automatically deleted? Why or why not?
>
> **Question 2.3:** Compare the security implications of using an ApplicationSet with `CreateNamespace=true` vs. pre-provisioning tenant namespaces via Crossplane claims with strict `ResourceQuota` and `LimitRange` objects embedded.

---

### Exercise 3: Advanced Diagnostics and Failure Troubleshooting on Self-Service Pipelines

#### Scenario
A developer submits a `PostgreSQLInstance` claim, but the resource remains stuck indefinitely in `SYNCED=False` and `READY=False`. You must trace the error through the Kubernetes event bus, Crossplane Composition engine, status conditions, and controller logs to isolate and rectify the root cause.

#### Step 1: Simulate a Provisioning Pipeline Failure
Apply an invalid claim `dev-db-claim-broken.yaml` that requests an unmapped tier (`ultra-large`) and invalid storage parameter:

```yaml
apiVersion: platform.cncf.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: billing-db-broken
  namespace: dev-team-alpha
spec:
  storageGB: 10000 # Exceeds XRD maximum limit of 500
  tier: "ultra-large" # Invalid enum value
  postgresVersion: "15"
```

Apply the broken claim:

```bash
kubectl apply -f dev-db-claim-broken.yaml
```

**Expected Output (API Validation Level):**
```
Error from server (Invalid): error validating "dev-db-claim-broken.yaml": error validating data: [ValidationError(PostgreSQLInstance.spec.storageGB): invalid signedValue; ValidationError(PostgreSQLInstance.spec.tier): unsupported value "ultra-large"]
```

> **Diagnostic Note:** OpenAPI v3 validation at the API Server layer rejected the request immediately because the XRD defined strict schema validation constraints (`minimum`, `maximum`, and `enum`).

---

#### Step 2: Diagnosing Composition Selection & Patching Failures
Now, modify the XRD to remove OpenAPI validation restrictions temporarily to allow the request to pass to the controller, simulating a runtime composition failure.

Apply a claim referencing a non-existent Composition selector:

```yaml
apiVersion: platform.cncf.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: analytics-db-unbound
  namespace: dev-team-alpha
  annotations:
    crossplane.io/composition-name: non-existent-composition
spec:
  storageGB: 100
  tier: "medium"
  postgresVersion: "15"
```

Apply the manifest:

```bash
kubectl apply -f dev-db-claim-unbound.yaml
```

Check the status conditions of the resource:

```bash
kubectl describe postgresqlinstance analytics-db-unbound -n dev-team-alpha
```

**Expected Output (Truncated Events & Status):**
```
Status:
  Conditions:
    Last Transition Time:  2026-08-07T19:22:35Z
    Message:               cannot resolve composition reference: Composition.apiextensions.crossplane.io "non-existent-composition" not found
    Reason:                CannotSelectComposition
    Status:                False
    Type:                  Synced
Events:
  Type     Reason                     Age   From                                   Message
  ----     ------                     ----  ----                                   -------
  Warning  CannotSelectComposition    42s   defined/composite/postgresqlinstances  Composition.apiextensions.crossplane.io "non-existent-composition" not found
```

---

#### Step 3: Inspecting Controller Reconciliation Loop Logs
When status conditions do not provide sufficient depth, query the Crossplane core controller container logs directly filtering by the target resource UID.

Retrieve the target resource UID:

```bash
RESOURCE_UID=$(kubectl get postgresqlinstance analytics-db-unbound -n dev-team-alpha -o jsonpath='{.metadata.uid}')
echo "Target Resource UID: ${RESOURCE_UID}"
```

Stream controller logs filtered by the UID:

```bash
kubectl logs -n crossplane-system -l app=crossplane --tail=500 | grep "${RESOURCE_UID}"
```

**Expected Output:**
```json
{"level":"error","ts":"2026-08-07T19:22:35.412Z","logger":"crossplane","msg":"Reconcile failed","controller":"defined/composite/postgresqlinstances","uid":"b7e28a1a-4c91-4912-9c12-88229a27d1ef","error":"cannot fetch referenced Composition: composition.apiextensions.crossplane.io \"non-existent-composition\" not found"}
```

---

#### Step 4: Resolving Stuck Finalizers on Failed Provisioned Resources
When a self-service resource fails during deletion (e.g., cloud API credentials deleted before target infrastructure was destroyed), Crossplane finalizers will block resource garbage collection indefinitely.

Inspect resource finalizers:

```bash
kubectl get postgresqlinstance analytics-db-unbound -n dev-team-alpha -o jsonpath='{.metadata.finalizers}'
```

**Expected Output:**
```json
["finalizer.composite.apiextensions.crossplane.io"]
```

To resolve a stuck finalizer safely during emergency recovery (after verifying cloud resources are manually remediated or orphan deletion is acceptable):

```bash
kubectl patch postgresqlinstance analytics-db-unbound -n dev-team-alpha \
  --type='json' \
  -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

**Expected Output:**
```
postgresqlinstance.platform.cncf.io/analytics-db-unbound patched
```

---

#### Comprehension Check: Exercise 3

> **Question 3.1:** Explain the difference in failure domains between an error thrown at step 1 (API Validation) vs step 2 (Composition Selection) vs step 3 (Managed Resource Reconciliation).
>
> **Question 3.2:** What is the risk of forcefully removing `finalizer.composite.apiextensions.crossplane.io` from an XR without first checking the status of underlying Managed Resources (MRs)?
>
> **Question 3.3:** How do `Orphan` vs `Delete` retain policies configured in a Crossplane `Composition` affect infrastructure lifecycle management when a developer deletes their namespaced Claim?

---

## 3. Comprehensive Solutions & Explanations

<details>
<summary><strong>Click to expand Answers & Technical Solutions</strong></summary>

### Solutions for Exercise 1

* **Answer 1.1:**
  * **XR (Composite Resource):** A cluster-scoped custom resource generated by an XRD that represents the actual composition of infrastructure resources. Only platform administrators with cluster-level permissions can directly create or manage XRs.
  * **XRC (Composite Resource Claim):** A namespace-scoped custom resource created by developers inside their isolated tenant namespaces. 
  * **Security Boundary:** Developers interact *only* with the XRC within their namespace. The Crossplane controller detects the XRC and creates/binds an underlying XR in the cluster scope. The developer never sees or touches cloud credentials, ProviderConfigs, or underlying low-level Managed Resources, achieving strict privilege separation.

* **Answer 1.2:**
  1. The **Kubernetes API Server** validates the update request against the OpenAPI schema defined in the `XPostgreSQLInstance` XRD (checking `minimum: 5`, `maximum: 500`).
  2. Upon mutation acceptance, the API Server emits an `UPDATE` event on the `PostgreSQLInstance` Claim object.
  3. The **Crossplane Claim Controller** observes the event and propagates the `spec.storageGB` mutation down to the corresponding cluster-scoped `XPostgreSQLInstance` (XR).
  4. The **Composition Engine** evaluates the pipeline patches. The patch rule (`FromCompositeFieldPath` `spec.storageGB`) executes the `fmt: "%dGi"` transform, updating the target Managed Resource desired spec to `100Gi`.
  5. The **Provider Controller** executes a reconciliation cycle against the target API (or in-cluster operator) to mutate the underlying storage volume size.
  6. Upon completion, the Provider Controller updates the `Ready=True` status condition on the Managed Resource, which bubbles up to the XR and XRC.

* **Answer 1.3:**
  If multiple Compositions match the same `compositeTypeRef`:
  * If a Claim/XR specifies `spec.compositionRef.name`, Crossplane strictly uses that designated Composition.
  * If `spec.compositionSelector` (labels) is used, Crossplane selects the Composition whose `metadata.labels` match the selector.
  * If no reference or selector is provided, Crossplane checks if exactly one Composition is marked with the annotation `composition.apiextensions.crossplane.io/default: "true"`.
  * If multiple Compositions exist without explicit references/selectors and none or multiple are marked as default, the reconciliation fails with a `CannotSelectComposition` error.

---

### Solutions for Exercise 2

* **Answer 2.1:**
  Setting `goTemplate: true` replaces Argo CD's legacy string-replacement parser with the full Go Template engine (`text/template`). This enables advanced control flow, including conditionals (`if/else`), iteration (`range`), string manipulation functions (Sprig library), nested JSON navigation, and strict type safety checking using `goTemplateOptions: ["missingkey=error"]`. Without this, complex nested data from Git generators cannot be dynamically manipulated into Helm `valuesObject` representations.

* **Answer 2.2:**
  The Matrix Generator re-evaluates the Cartesian product between the Git generator and the Cluster generator on every poll/reconciliation loop.
  * When the target cluster label changes, the old matrix tuple `(tenant-alpha, staging-cluster)` evaluates to empty/false, while a new tuple `(tenant-alpha, prod-cluster)` evaluates to true.
  * An Application for `prod-cluster` is generated.
  * For the old `staging-cluster` Application: if the ApplicationSet has `preserved: false` (default behavior), the old `Application` CR is deleted from the `argocd` namespace.
  * Whether resources inside the staging cluster are deleted depends on the `syncPolicy` and finalizers on the generated Application. If `prune: true` and Argo CD finalizers (`resources-finalizer.argocd.argoproj.io`) were set on the Application, Argo CD will delete the deployed tenant resources from the staging cluster. If finalizers were omitted, the `Application` CR is deleted while leaving orphaned resources running in the cluster.

* **Answer 2.3:**
  * **ApplicationSet `CreateNamespace=true`:** Convenient, but creates unconstrained namespaces. Tenant workloads run without CPU/memory limits, storage quotas, or default `NetworkPolicies`, risking noisy-neighbor issues or cluster-wide Resource Exhaustion Denial of Service (DoS).
  * **Crossplane Claim-Based Provisioning:** Allows platform teams to enforce a complete tenant landing zone bundle. When a tenant is provisioned, the Composition creates the namespace *along with* `ResourceQuota`, `LimitRange`, `NetworkPolicy`, and default RBAC `RoleBindings` alongside application workloads, ensuring secure, hard multi-tenancy boundaries.

---

### Solutions for Exercise 3

* **Answer 3.1:**
  * **API Validation Error (Step 1):** Synchronous HTTP 422 failure at the `kube-apiserver` boundary. The object is never written to etcd. No controller reconciliation is attempted. Zero impact on etcd or platform controllers.
  * **Composition Selection Error (Step 2):** Asynchronous controller error. The object exists in etcd, but Crossplane's control loop cannot bind the XR to an implementation blueprint (`Composition`). The Claim enters `Synced=False`. No Managed Resources are rendered or requested.
  * **Managed Resource Reconciliation Error (Step 3):** Asynchronous external integration failure. The XRD and Composition rendered correctly, but the underlying Provider Controller failed to create/configure the external infrastructure (e.g., invalid cloud API credentials, cloud quota exceeded, subnet CIDR exhaustion). The Claim remains `Synced=True`, `Ready=False`.

* **Answer 3.2:**
  Forcefully removing the finalizer on an XR bypasses Crossplane's deletion ordering. The control plane immediately removes the metadata record from etcd without executing the provider SDK's `Delete()` method. This leaves orphan cloud infrastructure running in the target provider (e.g., unmanaged AWS RDS instances or GCP VPCs), leading to untracked financial costs and security leaks.

* **Answer 3.3:**
  The deletion policy configured in a `Composition` (or Managed Resource `spec.deletionPolicy`) dictates teardown behavior:
  * **`Delete` (Default):** When the developer deletes their Claim, the deletion cascades to the XR, MRs, and external infrastructure. The cloud provider resources are permanently destroyed.
  * **`Orphan`:** When the Claim/XR is deleted, Crossplane deletes the K8s custom resource representations in the control plane but explicitly skips invoking the external cloud API deletion methods. The physical cloud infrastructure remains intact and operational in the cloud provider account.

</details>

---

## 4. Official References & Further Reading

- [CNCF Certified Cloud Native Platform Engineer (CNPE) Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
- [Crossplane Architecture & Composition Documentation](https://docs.crossplane.io/latest/concepts/compositions/)
- [Crossplane Composite Resource Definitions (XRDs)](https://docs.crossplane.io/latest/concepts/composite-resource-definitions/)
- [Argo CD ApplicationSet Matrix Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/)
- [Argo CD Go Template Rendering Engine](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/GoTemplate/)