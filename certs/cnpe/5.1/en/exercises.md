# CNCF Cloud Native Platform Engineer (CNPE) Exam Study Guide
## Topic 5.1: Designing and Creating Custom Resource Definitions (CRDs) for Platform Services
**Exam Weight**: 6.25%  
**Official Reference**: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)  
**Official Documentation Reference**: [Kubernetes Custom Resource Definitions](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/), [CRD Versioning & Conversion](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/), [Common Expression Language (CEL) in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)

---

### Architectural Overview & Mechanics

Custom Resource Definitions (CRDs) extend the Kubernetes API by registering new RESTful resource endpoints under `apiextensions.k8s.io/v1`. When a CRD is created, the `apiextensions-apiserver` (an aggregated sub-component inside `kube-apiserver`) dynamically registers new HTTP endpoints (`/apis/<group>/<version>/namespaces/<ns>/<plural>`) and generates internal HTTP handlers for CRUD operations.

```
                  ┌─────────────────────────────────────────────────────────────┐
                  │                        kube-apiserver                       │
                  │                                                             │
                  │  ┌───────────────────────┐       ┌───────────────────────┐  │
HTTP Request ────►│  │  Core API Server      │       │ apiextensions-server  │  │
                 │  └───────────────────────┘       └───────────┬───────────┘  │
                  └─────────────────────────────────────────────│───────────────┘
                                                                │
                                                1. Validate Structural Schema (OpenAPI v3)
                                                2. Evaluate CEL Validations
                                                3. Prune Unknown Fields
                                                4. Execute Conversion Webhooks (if multi-version)
                                                                │
                                                                ▼
                                                ┌───────────────────────────────┐
                                                │         etcd Storage          │
                                                │  /registry/<group>/<plural>/  │
                                                └───────────────────────────────┘
```

#### Key Production Mechanics:
1. **Structural Schemas**: Every version in `spec.versions[*]` must define a complete OpenAPI v3 schema. `kube-apiserver` enforces structural schemas to prune undeclared fields (`x-kubernetes-preserve-unknown-fields: false` by default) and prevent schema poisoning.
2. **CEL Validations (`x-kubernetes-validations`)**: Declarative inline validation evaluated directly inside `kube-apiserver` using Common Expression Language. Replaces mutating/validating webhooks for field immutability, range checks, and cross-field validation without incurring latency or Webhook availability risks.
3. **Subresources**:
   - `/status`: Isolates the `status` block. Modifications to spec via status endpoint are rejected, preventing state synchronization race conditions between platform controllers and end-users.
   - `/scale`: Enables horizontal pod autoscaling (HPA) and `kubectl scale` by mapping JSONPaths (`specReplicasPath`, `statusReplicasPath`, `labelSelectorPath`).
4. **Storage & Versioning**: A CRD can serve multiple API versions (`served: true`), but exactly ONE version can be designated as the storage version (`storage: true`). When schema changes occur across versions, conversion webhooks convert objects dynamically before etcd persistence or REST responses.

---

### Hands-on Guided Exercises

---

#### Module 1: Production Schema Design & CEL Validation Rules

In this exercise, you will create a production-grade CRD representing a platform service (`PostgreSQLCluster`) under group `platform.example.com`. You will implement structural schemas, mandatory status subresources, and declarative CEL validation rules.

##### Exercise Steps

1. Create a directory for your manifests and navigate to it:
```bash
mkdir -p ~/crd-lab && cd ~/crd-lab
```

2. Create the complete CRD manifest named `postgresqlcluster-crd.yaml`:
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresqlclusters.platform.example.com
spec:
  group: platform.example.com
  names:
    kind: PostgreSQLCluster
    listKind: PostgreSQLClusterList
    plural: postgresqlclusters
    singular: postgresqlcluster
    shortNames:
      - pg
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.readyReplicas
          labelSelectorPath: .status.selector
      additionalPrinterColumns:
        - name: Engine
          type: string
          jsonPath: .spec.engineVersion
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Ready
          type: integer
          jsonPath: .status.readyReplicas
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - engineVersion
                - replicas
                - storage
              properties:
                engineVersion:
                  type: string
                  enum: ["14", "15", "16"]
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 9
                storage:
                  type: object
                  required:
                    - size
                  properties:
                    size:
                      type: string
                      pattern: '^[0-9]+(Gi|Ti)$'
                    storageClass:
                      type: string
                tls:
                  type: object
                  required:
                    - enabled
                  properties:
                    enabled:
                      type: boolean
                    secretRef:
                      type: string
              x-kubernetes-validations:
                - rule: "self.tls.enabled == false || has(self.tls.secretRef)"
                  message: "secretRef is required when TLS is enabled."
                - rule: "oldSelf.engineVersion == self.engineVersion || (int(oldSelf.engineVersion) < int(self.engineVersion))"
                  message: "Engine version downgrades are prohibited."
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
                  default: 0
                phase:
                  type: string
                selector:
                  type: string
```

3. Apply the CustomResourceDefinition to the cluster:
```bash
kubectl apply -f postgresqlcluster-crd.yaml
```

*Expected Output:*
```text
customresourcedefinition.apiextensions.k8s.io/postgresqlclusters.platform.example.com created
```

4. Verify the CRD registration status and endpoint exposure via `kubectl`:
```bash
kubectl get crd postgresqlclusters.platform.example.com
kubectl api-resources | grep postgresqlcluster
```

*Expected Output:*
```text
NAME                                       CREATED AT
postgresqlclusters.platform.example.com   2026-08-07T19:15:00Z

postgresqlclusters   pg   platform.example.com/v1alpha1   true   PostgreSQLCluster
```

5. Attempt to create a custom resource `pg-invalid.yaml` that violates the CEL validation rule (`tls.enabled = true` without `secretRef`):
```yaml
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: pg-test-invalid
spec:
  engineVersion: "15"
  replicas: 3
  storage:
    size: "100Gi"
  tls:
    enabled: true
```

6. Apply the invalid resource to verify API Server validation interception:
```bash
kubectl apply -f - <<EOF
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: pg-test-invalid
spec:
  engineVersion: "15"
  replicas: 3
  storage:
    size: "100Gi"
  tls:
    enabled: true
EOF
```

*Expected Output:*
```text
Error from server (Invalid): error when creating "STDIN": PostgreSQLCluster.platform.example.com "pg-test-invalid" is invalid: spec: Invalid value: map[string]interface {}{"engineVersion":"15", "replicas":3, "storage":map[string]interface {}{"size":"100Gi"}, "tls":map[string]interface {}{"enabled":true}}: secretRef is required when TLS is enabled.
```

7. Apply a valid Custom Resource `pg-valid.yaml`:
```yaml
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: pg-primary
spec:
  engineVersion: "15"
  replicas: 3
  storage:
    size: "100Gi"
  tls:
    enabled: true
    secretRef: "pg-tls-certs"
```

```bash
kubectl apply -f - <<EOF
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: pg-primary
spec:
  engineVersion: "15"
  replicas: 3
  storage:
    size: "100Gi"
  tls:
    enabled: true
    secretRef: "pg-tls-certs"
EOF
```

*Expected Output:*
```text
postgresqlcluster.platform.example.com/pg-primary created
```

8. Test the CEL version downgrade prohibition rule by attempting to update `engineVersion` from `"15"` to `"14"`:
```bash
kubectl patch pg pg-primary --type='json' -p='[{"op": "replace", "path": "/spec/engineVersion", "value": "14"}]'
```

*Expected Output:*
```text
Error from server (Invalid): postgresqlclusters.platform.example.com "pg-primary" is invalid: spec: Invalid value: map[string]interface {}{...}: Engine version downgrades are prohibited.
```

---

##### Verification Questions - Module 1

1. **Why does CEL validation (`x-kubernetes-validations`) offer performance and availability advantages over external Validating Webhooks?**
2. **If an API request attempts to modify `/spec` by sending an HTTP PUT directly to `/apis/platform.example.com/v1alpha1/namespaces/default/postgresqlclusters/pg-primary/status`, what action will `kube-apiserver` take and why?**

---

#### Module 2: Subresource Manipulation, Status Isolation & Scale Controls

In this exercise, you will interact directly with the `/status` and `/scale` subresources using raw HTTP operations and `kubectl` subcommands to observe isolation semantics.

##### Exercise Steps

1. Attempt to update `.status.readyReplicas` directly using standard `kubectl patch` (modifying the main resource endpoint):
```bash
kubectl patch pg pg-primary --type='merge' -p '{"status": {"readyReplicas": 3, "phase": "Running"}}'
```

*Expected Output:*
```text
postgresqlcluster.platform.example.com/pg-primary patched (no change)
```

2. Inspect the resource to verify that `.status` was NOT modified:
```bash
kubectl get pg pg-primary -o jsonpath='{.status}'
```

*Expected Output:*
```text
(empty output or current unmodified status object)
```

3. Update the status subresource using the dedicated `/status` endpoint via `kubectl replace --raw`:
```bash
# Fetch current object JSON, inject status, and send to /status endpoint
CR_JSON=$(kubectl get pg pg-primary -o json)
UPDATED_JSON=$(echo "$CR_JSON" | jq '.status = {"readyReplicas": 3, "phase": "Running", "selector": "app=pg-primary"}')

kubectl replace --raw "/apis/platform.example.com/v1alpha1/namespaces/default/postgresqlclusters/pg-primary/status" -f - <<< "$UPDATED_JSON"
```

*Expected Output:*
```json
{"apiVersion":"platform.example.com/v1alpha1","kind":"PostgreSQLCluster","metadata":{...},"spec":{...},"status":{"phase":"Running","readyReplicas":3,"selector":"app=pg-primary"}}
```

4. Verify the updated columns in standard `kubectl get` output:
```bash
kubectl get pg
```

*Expected Output:*
```text
NAME         ENGINE   REPLICAS   READY   AGE
pg-primary   15       3          3       5m
```

5. Test the `/scale` subresource using `kubectl scale`:
```bash
kubectl scale postgresqlcluster pg-primary --replicas=5
```

*Expected Output:*
```text
postgresqlcluster.platform.example.com/pg-primary scaled
```

6. Inspect `.spec.replicas` to confirm the scale operation succeeded:
```bash
kubectl get pg pg-primary -o jsonpath='{.spec.replicas}'
```

*Expected Output:*
```text
5
```

---

##### Verification Questions - Module 2

1. **Which fields inside `spec.versions[*].subresources.scale` are strictly required to enable Horizontal Pod Autoscaler (`HPA`) support for a Custom Resource?**
2. **Explain the security and concurrency reason why `kube-apiserver` ignores updates to `.status` when targeted at the root REST resource endpoint when `subresources.status: {}` is defined.**

---

#### Module 3: Multi-Version Schema Evolution & Conversion Webhook Architecture

When evolving platform APIs, schema changes across versions (e.g., `v1alpha1` to `v1beta1`) require field conversions. In this exercise, you will add a `v1beta1` version, analyze the etcd storage mechanics, and understand the conversion pipeline architecture.

```
       Client Request (v1beta1)
                  │
                  ▼
         ┌─────────────────┐
         │  kube-apiserver │
         └────────┬────────┘
                  │
     Is v1beta1 Storage Version?
                 │
        ┌────────┴────────┐
     NO │                 │ YES
        ▼                 ▼
┌───────────────┐  ┌───────────────┐
│ Invoke        │  │ Store Directly│
│ Conversion    │  │ to etcd       │
│ Webhook       │  └───────────────┘
└───────┬───────┘
        │ Converted to Storage Version (v1alpha1)
        ▼
┌───────────────┐
│ Write etcd    │
└───────────────┘
```

##### Exercise Steps

1. Update `postgresqlcluster-crd.yaml` to serve both `v1alpha1` and `v1beta1`. In `v1beta1`, `storage.size` is renamed to `spec.capacity` to refactor the platform API:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresqlclusters.platform.example.com
spec:
  group: platform.example.com
  names:
    kind: PostgreSQLCluster
    listKind: PostgreSQLClusterList
    plural: postgresqlclusters
    singular: postgresqlcluster
    shortNames:
      - pg
  scope: Namespaced
  conversion:
    strategy: None
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                engineVersion:
                  type: string
                replicas:
                  type: integer
                storage:
                  type: object
                  properties:
                    size:
                      type: string
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
    - name: v1beta1
      served: true
      storage: false
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                engineVersion:
                  type: string
                replicas:
                  type: integer
                capacity:
                  type: string
            status:
              type: object
              properties:
                readyReplicas:
                  type: integer
```

2. Apply the multi-version CRD:
```bash
kubectl apply -f postgresqlcluster-crd.yaml
```

*Expected Output:*
```text
customresourcedefinition.apiextensions.k8s.io/postgresqlclusters.platform.example.com configured
```

3. Query the `pg-primary` instance specifically asking for the non-storage version (`v1beta1`):
```bash
kubectl get postgresqlclusters.v1beta1.platform.example.com pg-primary -o yaml
```

*Expected Output snippet:*
```yaml
apiVersion: platform.example.com/v1beta1
kind: PostgreSQLCluster
metadata:
  name: pg-primary
spec:
  engineVersion: "15"
  replicas: 5
  storage:
    size: 100Gi
```

*Notice:* Without a `Webhook` conversion strategy configured, `kube-apiserver` performs naive field copying. Unmapped fields (`capacity` vs `storage.size`) are dropped or retained depending on preserve unknown fields configuration, leading to schema corruption!

4. Inspect the CRD status to observe stored versions recorded by `kube-apiserver`:
```bash
kubectl get crd postgresqlclusters.platform.example.com -o jsonpath='{.status.storedVersions}'
```

*Expected Output:*
```text
["v1alpha1"]
```

---

##### Verification Questions - Module 3

1. **When `spec.conversion.strategy: Webhook` is configured, describe the payload structure exchanged between `kube-apiserver` and the conversion webhook container.**
2. **If `v1beta1` is changed to `storage: true` while existing CRD objects were written under `v1alpha1`, what happens to the existing records inside etcd before they are re-written?**

---

#### Module 4: Advanced Diagnostics, Garbage Collection & Stuck CRD Resolution

In production SRE operations, CRDs or instances often become stuck during deletion due to active finalizers or API group unregistration ordering.

##### Exercise Steps

1. Create a Custom Resource containing a blocking finalizer:
```bash
kubectl apply -f - <<EOF
apiVersion: platform.example.com/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: pg-stuck
  finalizers:
    - platform.example.com/deprovision-storage
spec:
  engineVersion: "16"
  replicas: 1
  storage:
    size: "10Gi"
EOF
```

2. Initiate deletion of the Custom Resource in the background:
```bash
kubectl delete pg pg-stuck --wait=false
```

*Expected Output:*
```text
postgresqlcluster.platform.example.com "pg-stuck" deleted
```

3. Inspect the deletion status to observe why the resource persists:
```bash
kubectl get pg pg-stuck -o jsonpath='{.metadata.deletionTimestamp}'
echo ""
kubectl get pg pg-stuck -o jsonpath='{.metadata.finalizers}'
```

*Expected Output:*
```text
2026-08-07T19:20:00Z
["platform.example.com/deprovision-storage"]
```

4. Debug CRD/CR removal blockages by patching the finalizers via raw HTTP to bypass stuck controller logic in emergency recovery:
```bash
kubectl patch pg pg-stuck --type='json' -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

*Expected Output:*
```text
postgresqlcluster.platform.example.com/pg-stuck patched
```

5. Confirm the object is purged from etcd:
```bash
kubectl get pg pg-stuck
```

*Expected Output:*
```text
Error from server (NotFound): postgresqlclusters.platform.example.com "pg-stuck" not found
```

6. Clean up lab environment resources:
```bash
kubectl delete crd postgresqlclusters.platform.example.com
rm -rf ~/crd-lab
```

---

##### Verification Questions - Module 4

1. **What happens to Custom Resource instances if a cluster administrator executes `kubectl delete crd postgresqlclusters.platform.example.com` while Custom Resources are still present in namespaces?**
2. **Which diagnostic CLI command allows an SRE to dump the OpenAPI schema validation errors directly from `kube-apiserver` for a specific CRD?**

---

<details>
<summary><strong>Answers and Deep Dive Explanations</strong></summary>

### Module 1 Answers

1. **CEL Validation Advantages over Validating Webhooks:**
   - **Zero Latency / Out-of-Process Overhead:** CEL rules are evaluated directly in-process within `kube-apiserver` binary runtime. Webhooks introduce network round-trips (typically 5-50ms latency per mutation/validation) and risk timeout failures (`500 Internal Server Error` / `429 Too Many Requests`).
   - **High Availability & Fault Isolation:** If a Validating Webhook Deployment crashes or its Service network policy blocks port 9443, API object creation completely halts (or defaults to fail-open if `failurePolicy: Ignore`). CEL validations run as long as `kube-apiserver` is running, eliminating external infrastructure dependencies.

2. **Rejection of `/spec` updates via `/status` endpoint:**
   - `kube-apiserver` will strip or ignore modifications to `.spec` (or return an error depending on request composition). 
   - **Reason:** When `subresources.status: {}` is defined in the CRD schema, `kube-apiserver` splits the REST handlers into two separate HTTP paths. The `/status` REST handler only accepts mutations to the `.status` sub-tree and ignores changes to `.spec`. This enforces optimistic concurrency control and prevents status-reconciling controllers from accidentally overwriting user-driven `.spec` intentions.

---

### Module 2 Answers

1. **Required JSONPaths for `/scale` Subresource:**
   - `specReplicasPath`: Defines the JSONPath within the Custom Resource where desired replicas are defined (e.g., `.spec.replicas`).
   - `statusReplicasPath`: Defines the JSONPath where current actual replicas are reported (e.g., `.status.readyReplicas`).
   - `labelSelectorPath` (Optional for basic scaling, but **Mandatory for HPA**): Defines the JSONPath pointing to the string formatted or serialized label selector (e.g., `.status.selector`) so HPA can match pods to metrics.

2. **Security & Race Condition Prevention in Root vs Status Endpoints:**
   - RBAC policies can be fine-grained per subresource. Platform engineers can grant `update` permissions on `postgresqlclusters/status` to operator ServiceAccounts, while denying them write access to `postgresqlclusters` (root resource). This prevents an operator from mutating spec parameters, and prevents end-users from forging status metrics (e.g., marking a broken cluster as `Ready`).

---

### Module 3 Answers

1. **`ConversionReview` Webhook Payload Structure:**
   - `kube-apiserver` sends an `apiextensions.k8s.io/v1` `ConversionReview` request object containing:
     - `request.desiredAPIVersion`: The target version requested by the client (e.g., `platform.example.com/v1beta1`).
     - `request.objects`: Array of `runtime.RawExtension` JSON objects to be converted from their current version.
   - The Webhook container must process the array and return a `ConversionReview` response with `response.uid` matching `request.uid`, `response.result.status = "Success"`, and `response.convertedObjects` containing the mutated JSON array in the target API schema.

2. **Storage Version Migration Mechanics in etcd:**
   - Changing `storage: true` from `v1alpha1` to `v1beta1` in the CRD does NOT retroactively update existing etcd byte entries. Existing objects remain written in etcd as `v1alpha1` until they are updated by a write operation.
   - To migrate all persisted etcd objects to the new storage version, platform teams must execute the Kubernetes [Storage Version Migrator](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/#upgrade-existing-objects-to-a-new-stored-version) controller or run `kubectl get postgresqlclusters -A -o json | kubectl replace -f -`.

---

### Module 4 Answers

1. **Impact of Deleting a CRD containing Active Custom Resources:**
   - When a CRD is deleted, the `apiextensions-apiserver` garbage collector automatically deletes all custom resource instances across all namespaces.
   - **Danger:** If finalizers are attached to those custom resources, the instances will enter a `Terminating` state, blocking CRD deletion. The CRD itself will remain in `Terminating` status until every single underlying Custom Resource instance finalizer is processed or forcefully removed.

2. **Diagnostic CLI Commands for CRD Schema Debugging:**
   - `kubectl explain postgresqlclusters.platform.example.com --api-version=platform.example.com/v1alpha1` dynamically fetches and parses the OpenAPI v3 schema from `kube-apiserver`, allowing SREs to inspect required fields, types, and descriptions.
   - `kubectl get crd postgresqlclusters.platform.example.com -o jsonpath='{.status.conditions}'` outputs detailed structural validation failures, conversion webhook failures, or name conflict errors generated by `apiextensions-apiserver`.

</details>