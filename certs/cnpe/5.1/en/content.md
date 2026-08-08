# CNCF CNPE Exam Study Guide: Topic 5.1 — Designing and Creating Custom Resource Definitions (CRDs) for Platform Services

**Certification:** Certified Cloud Native Platform Engineer (CNPE)  
**Domain 5:** Platform Extension & API Engineering  
**Topic 5.1:** Designing and Creating Custom Resource Definitions (CRDs) for Platform Services  
**Weight:** 6.25%  

---

## 1. Architectural Motivation and Production Context

In modern cloud-native platform engineering, standard Kubernetes primitives (`Deployment`, `StatefulSet`, `Service`, `ConfigMap`) are insufficient for managing complex, domain-specific stateful infrastructure (e.g., managed database clusters, message queues, internal Developer Platforms (IDPs), or service mesh abstractions).

Custom Resource Definitions (CRDs) extend the API server capabilities by dynamically introducing new declarative RESTful resources (`Group/Version/Kind` or GVK) into the `kube-apiserver` without requiring source code modifications or recompilation of the control plane binaries.

```
                      +------------------------------------------------------------------+
                      |                      kube-apiserver                              |
                      |                                                                  |
  Client Request ---> |  [Authentication & Authorization (RBAC)]                         |
(kubectl/API Call)    |                           |                                      |
                      |  [Mutating Webhooks]      v                                      |
                      |                           |                                      |
                      |  [OpenAPI v3 Schema & CEL Validation Engine]                     |
                      |                           |                                      |
                      |  [Validating Webhooks]    v                                      |
                      |                           |                                      |
                      |  [CRD Storage Layer] ----> (REST storage mapper to etcd)         |
                      +------------------------------------------------------------------+
                                                                 |
                                                                 v
                                                      +---------------------+
                                                      |        etcd         |
                                                      | /registry/group/... |
                                                      +---------------------+
```

### The API Request Lifecycle & Internal Mechanics

When a client submits a Custom Resource (CR) instance to the `kube-apiserver`:

1. **Authentication & Authorization:** The request passes through standard authentication plugins and RBAC authorization policies evaluated against the custom API group, resource verb, and namespace.
2. **Mutating Admission:** Registered mutating webhooks modify incoming payloads.
3. **OpenAPI v3 Structural Schema & CEL Validation:** The API server enforces schema conformance. Structural validation ensures that all fields match the OpenAPI v3 spec defined inside the CRD manifest. If Common Expression Language (CEL) validation rules (`x-kubernetes-validations`) are specified, the API server evaluates inline expression logic without requiring external webhook network hops.
4. **Validating Admission:** Registered validating webhooks execute custom business logic rules.
5. **REST Storage & etcd Persistence:** The object is serialized to JSON/Protobuf and written to etcd under the key path `/registry/<group>/<plural-resource>/<namespace>/<name>`.

### Production Trade-offs and Architectural Imperatives

* **Structural Schema Enforcement:** Non-structural schemas (schemas omitting explicit field types or using top-level arbitrary JSON maps without `x-kubernetes-preserve-unknown-fields`) degrade API server performance and are rejected in `apiextensions.k8s.io/v1`.
* **Subresource Isolation:** Enforcing separate `/status` and `/scale` subresources prevents race conditions between control plane actors. Platform human operators update `spec` via main REST endpoints, while custom controllers mutate `status` via `/status` endpoints without risking spec corruption.
* ** etcd Serialization Overhead:** Large CRDs storing expansive operational metadata in `status` directly increase etcd memory footprints (`--quota-backend-bytes`) and write latency. Large status fields must be pruned or offloaded to external storage.

---

## 2. Technical Comparison & Trade-off Analysis

Platform Architects must choose the correct API extension pattern based on performance, state footprint, schema complexity, and operational overhead.

| Metric / Feature | Custom Resource Definition (CRD) | Aggregated API Server (AAKS) | ConfigMap + Custom Controller | External Database + Out-of-Cluster API |
| :--- | :--- | :--- | :--- | :--- |
| **API Integration** | Native (`kube-apiserver` sub-router) | Delegated extension server via API Service | Native (`core/v1`) | Non-native / Custom Endpoint |
| **etcd Impact** | Direct (shares core etcd cluster) | None (uses separate dedicated storage) | Direct (shares core etcd cluster) | None |
| **Schema Validation** | Declarative (OpenAPI v3 + CEL) | Programmatic (Golang code compilation) | None (client-side parsing) | Custom API / DB Constraints |
| **Development Complexity** | Low to Medium (YAML + Controller) | High (Requires complete REST implementation) | Very Low | High (Dual-system integration) |
| **RBAC Granularity** | Native per-GVK fine-grained rules | Custom per-endpoint or delegated RBAC | Coarse (ConfigMap level per namespace) | Custom authentication layer |
| **Latency / Request Path** | In-process `kube-apiserver` handling | Network hop to Extension API Server | In-process `kube-apiserver` handling | Dependent on external gateway |
| **Conversion Webhooks** | Supported (version migration via webhook) | Native (Internal multi-version structs) | N/A | Custom DB migrations |
| **Custom Verbs (`exec/logs`)** | Unsupported | Supported (e.g., `metrics.k8s.io`) | Unsupported | Supported |

---

## 3. Complete Production-Grade YAML Manifests

The following manifest defines a production-grade CRD (`PostgresCluster`) under the API group `platform.example.com` utilizing `apiextensions.k8s.io/v1`. It includes:

* Multiple API versions (`v1alpha1` pruned/deprecated, `v1` served & stored).
* OpenAPI v3 validation schema with strict constraint patterns.
* Inline CEL (`x-kubernetes-validations`) rules.
* `/status` and `/scale` subresources.
* Custom printer columns for `kubectl get`.
* Webhook conversion configuration block.

### Manifest 1: `crd-postgrescluster.yaml`

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresclusters.platform.example.com
  annotations:
    controller-gen.kubebuilder.io/version: v0.14.0
    api-approved.kubernetes.io: "https://github.com/kubernetes/enhancements/pull/0000"
spec:
  group: platform.example.com
  scope: Namespaced
  names:
    plural: postgresclusters
    singular: postgrescluster
    kind: PostgresCluster
    shortNames:
      - pgc
      - pgcluster
    categories:
      - all
      - platform
      - datastores
  conversion:
    strategy: Webhook
    webhook:
      conversionReviewVersions:
        - v1
        - v1alpha1
      clientConfig:
        service:
          name: postgres-operator-webhook
          namespace: platform-system
          path: /convert
          port: 443
        caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg== # Truncated base64 PEM for validation syntax
  versions:
    - name: v1alpha1
      served: true
      storage: false
      deprecated: true
      deprecationWarning: "platform.example.com/v1alpha1 PostgresCluster is deprecated; migrate to platform.example.com/v1"
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            apiVersion:
              type: string
            kind:
              type: string
            metadata:
              type: object
            spec:
              type: object
              properties:
                replicas:
                  type: integer
                  minimum: 1
                storageSizeGb:
                  type: integer
            status:
              type: object
              properties:
                phase:
                  type: string
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
        scale:
          specReplicasPath: .spec.replicas
          statusReplicasPath: .status.replicas
          labelSelectorPath: .status.labelSelector
      additionalPrinterColumns:
        - name: Phase
          type: string
          jsonPath: .status.phase
          description: Current operational phase of the Postgres cluster
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
          description: Desired replica count
        - name: Ready-Replicas
          type: integer
          jsonPath: .status.readyReplicas
          description: Current ready replica count
        - name: Storage
          type: string
          jsonPath: .spec.storage.size
          description: Allocated storage capacity
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            apiVersion:
              type: string
            kind:
              type: string
            metadata:
              type: object
            spec:
              type: object
              required:
                - engineVersion
                - replicas
                - storage
                - resources
              properties:
                engineVersion:
                  type: string
                  enum:
                    - "14"
                    - "15"
                    - "16"
                  description: "Supported PostgreSQL major engine version."
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 32
                  default: 3
                  description: "Number of nodes in the database cluster."
                storage:
                  type: object
                  required:
                    - size
                    - storageClassName
                  properties:
                    size:
                      type: string
                      pattern: "^[0-9]+(Gi|Ti)$"
                      description: "Capacity request matching Kubernetes resource quantity (e.g. 100Gi)."
                    storageClassName:
                      type: string
                      minLength: 1
                resources:
                  type: object
                  required:
                    - cpu
                    - memory
                  properties:
                    cpu:
                      type: string
                      pattern: "^[0-9]+(m)?$"
                    memory:
                      type: string
                      pattern: "^[0-9]+(Mi|Gi)$"
                backup:
                  type: object
                  properties:
                    enabled:
                      type: boolean
                      default: true
                    schedule:
                      type: string
                      pattern: "^((\\*(/[0-9]+)?|[0-9]+(-[0-9]+)?(,[0-9]+)*)\\s+){4}(\\*(/[0-9]+)?|[0-9]+(-[0-9]+)?(,[0-9]+)*)$"
                      description: "Valid standard cron schedule expression."
              x-kubernetes-validations:
                - rule: "self.replicas % 2 != 0 || self.replicas == 2"
                  message: "Production database cluster replicas must be an odd number to maintain quorum, or exactly 2 for primary-standby."
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum:
                    - Pending
                    - Provisioning
                    - Running
                    - Degraded
                    - Failed
                replicas:
                  type: integer
                readyReplicas:
                  type: integer
                labelSelector:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    required:
                      - type
                      - status
                      - lastTransitionTime
                    properties:
                      type:
                        type: string
                      status:
                        type: string
                        enum:
                          - "True"
                          - "False"
                          - Unknown
                      lastTransitionTime:
                        type: string
                        format: date-time
                      reason:
                        type: string
                      message:
                        type: string
```

---

### Manifest 2: `cr-postgrescluster-instance.yaml`

```yaml
apiVersion: platform.example.com/v1
kind: PostgresCluster
metadata:
  name: pg-orders-prod
  namespace: production
  labels:
    app.kubernetes.io/name: postgrescluster
    app.kubernetes.io/managed-by: platform-operator
    tier: database
spec:
  engineVersion: "16"
  replicas: 3
  storage:
    size: 250Gi
    storageClassName: gp3-encrypted
  resources:
    cpu: "4000m"
    memory: "16Gi"
  backup:
    enabled: true
    schedule: "0 2 * * *"
```

---

## 4. Real-World CLI Execution & Terminal Outputs

### Applying the Custom Resource Definition

```bash
$ kubectl apply -f crd-postgrescluster.yaml
customresourcedefinition.apiextensions.k8s.io/postgresclusters.platform.example.com created
```

### Verifying CRD Registration State in the API Server

```bash
$ kubectl get crd postgresclusters.platform.example.com -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
Established	True	InitialNamesAccepted
NamesAccepted	True	NoConflicts
```

### Creating the Custom Resource Instance

```bash
$ kubectl apply -f cr-postgrescluster-instance.yaml
postgrescluster.platform.example.com/pg-orders-prod created
```

### Fetching Instances with Custom Printer Columns

```bash
$ kubectl get pgc -n production
NAME             PHASE     REPLICAS   READY-REPLICAS   STORAGE   AGE
pg-orders-prod   Running   3          3                250Gi     42s
```

### Triggering Structural and CEL Schema Validation Error

Attempting to submit an invalid manifest with an even replica count of 4 (violating the CEL rule) and invalid storage formatting:

```bash
$ cat <<EOF | kubectl apply -f -
apiVersion: platform.example.com/v1
kind: PostgresCluster
metadata:
  name: pg-invalid
  namespace: production
spec:
  engineVersion: "16"
  replicas: 4
  storage:
    size: "250GB"
    storageClassName: standard
  resources:
    cpu: "2"
    memory: "4Gi"
EOF
```

**Expected Terminal Output:**

```text
The PostgresCluster "pg-invalid" is invalid: 
* spec.storage.size: Invalid value: "250GB": spec.storage.size in body should match ^[0-9]+(Gi|Ti)$
* spec: Invalid value: map[string]interface{}{"backup":map[string]interface{}{"enabled":true}, "engineVersion":"16", "replicas":4, "resources":map[string]interface{}{"cpu":"2", "memory":"4Gi"}, "storage":map[string]interface{}{"size":"250GB", "storageClassName":"standard"}}: Production database cluster replicas must be an odd number to maintain quorum, or exactly 2 for primary-standby.
```

### Interacting with the `/scale` Subresource

```bash
$ kubectl scale postgrescluster pg-orders-prod -n production --replicas=5
postgrescluster.platform.example.com/pg-orders-prod scaled

$ kubectl get pgc pg-orders-prod -n production -o jsonpath='{.spec.replicas}'
5
```

### Direct Endpoint Inspection via Raw API Requests

```bash
$ kubectl get --raw /apis/platform.example.com/v1/namespaces/production/postgresclusters/pg-orders-prod | jq .spec
{
  "backup": {
    "enabled": true,
    "schedule": "0 2 * * *"
  },
  "engineVersion": "16",
  "replicas": 5,
  "resources": {
    "cpu": "4000m",
    "memory": "16Gi"
  },
  "storage": {
    "size": "250Gi",
    "storageClassName": "gp3-encrypted"
  }
}
```

Updating the `/status` subresource independently using raw HTTP mutation (simulating Controller reconciler execution):

```bash
$ kubectl raw --request PUT /apis/platform.example.com/v1/namespaces/production/postgresclusters/pg-orders-prod/status \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "platform.example.com/v1",
    "kind": "PostgresCluster",
    "metadata": {
      "name": "pg-orders-prod",
      "namespace": "production",
      "resourceVersion": "'$(kubectl get pgc pg-orders-prod -n production -o jsonpath='{.metadata.resourceVersion}')'"
    },
    "status": {
      "phase": "Running",
      "replicas": 5,
      "readyReplicas": 5,
      "conditions": [
        {
          "type": "Ready",
          "status": "True",
          "lastTransitionTime": "2026-08-07T19:12:44Z",
          "reason": "ClusterQuorumReached",
          "message": "All 5 replicas are synchronized."
        }
      ]
    }
  }' | jq .status
{
  "conditions": [
    {
      "lastTransitionTime": "2026-08-07T19:12:44Z",
      "message": "All 5 replicas are synchronized.",
      "reason": "ClusterQuorumReached",
      "status": "True",
      "type": "Ready"
    }
  ],
  "phase": "Running",
  "readyReplicas": 5,
  "replicas": 5
}
```

---

## 5. Production Verification, Diagnostics & Troubleshooting

```
+-----------------------------------------------------------------------------------------------+
|                                CRD DIAGNOSTIC DECISION TREE                                   |
+-----------------------------------------------------------------------------------------------+
                                               |
                               [CRD Manifest Submitted]
                                               |
                                               v
                             /-----------------------------------\
                            / Does CRD Status show "Established"? \
                            \              = True?                /
                             \-----------------------------------/
                                       /               \
                                 (Yes)/                 \(No)
                                     /                   \
                                    v                     v
            /-------------------------------+   +---------------------------------------+
           / Can clients create CR instances \  | Check CRD Conditions:                 |
           \          successfully?          /  | # kubectl get crd <name> -o yaml      |
            \-------------------------------/   | Common Issues:                        |
                      /           \             | - NameConflict (Plural/Group collision|
                (Yes)/             \(No)        | - InvalidSchema (OpenAPI v3 syntax)   |
                    /               \           +---------------------------------------+
                   v                 v
   +-----------------------+   +--------------------------------------------------------+
   | System Healthy        |   | Determine Failure Point:                               |
   | Control loop ready to |   | 1. API Server Schema Error -> Enforce structural schema|
   | reconcile state.      |   | 2. Conversion Webhook Fail -> Check CA bundle / endpoint|
   +-----------------------+   | 3. Status Lockout         -> Verify /status endpoint   |
                               +--------------------------------------------------------+
```

### Pitfall 1: Non-Structural OpenAPI Schemas & Rejection

* **Symptom:** `kube-apiserver` rejects CRD creation or drops fields silently upon CR ingestion.
* **Root Cause:** Fields lack explicit primitive types, or unknown fields are accepted without explicitly setting `x-kubernetes-preserve-unknown-fields: true`.
* **Diagnosis:**

```bash
$ kubectl get crd postgresclusters.platform.example.com -o jsonpath='{.status.conditions[?(@.type=="NonStructuralSchema")]}'
```

* **Resolution:** Ensure every level of the JSON schema defines `type: object`, `type: string`, `type: integer`, etc. Never use raw unstructured `type: object` maps unless `x-kubernetes-preserve-unknown-fields: true` is explicitly placed under that attribute.

---

### Pitfall 2: Status Subresource Mutation Lockout

* **Symptom:** A Custom Controller attempts to update `.status` via a standard `PUT /apis/platform.example.com/v1/namespaces/default/postgresclusters/pg-main` call, but the payload is rejected or `.status` changes are ignored.
* **Root Cause:** When `status: {}` subresource is declared in the CRD spec, updates to the main resource endpoint ignore changes to the `.status` stanza. Conversely, updates to the `/status` endpoint ignore changes to `.spec`.
* **Diagnosis:** Inspect controller logs for HTTP 200 responses that resulted in no state modification, or HTTP 422 Unprocessable Entity errors.
* **Resolution:** Ensure the operator SDK / client-go implementation explicitly uses the status writer client interface (`kubeClient.Status().Update(ctx, instance)`).

---

### Pitfall 3: Conversion Webhook Latency and Timeouts

* **Symptom:** Operations on older API versions (`v1alpha1`) time out during `kubectl get` or reconciliation cycles. `kube-apiserver` logs report: `conversion webhook failed: context deadline exceeded`.
* **Root Cause:** The conversion webhook service (`postgres-operator-webhook`) is unreachable, misconfigured, lacks valid TLS certificates, or exceeds the default API server 10-second timeout.
* **Diagnosis Commands:**

```bash
# Check API Server logs for conversion failures
$ kubectl logs -n kube-system kube-apiserver-control-plane-1 --grep="conversion webhook"

# Verify API Server latency metrics for conversion webhooks
$ kubectl get --raw /metrics | grep apiserver_crd_conversion_webhook_duration_seconds
```

* **Resolution:** 
  1. Validate the webhook deployment endpoints and service routing.
  2. Verify the `caBundle` injected into `spec.conversion.webhook.clientConfig` matches the serving cert of the mutating/converting pod.
  3. Ensure network policies allow `kube-apiserver` to communicate with the webhook pod on port 443.

---

### Pitfall 4: Stale Storage Versions & etcd Migration Bloat

* **Symptom:** Deprecated API versions are removed from the CRD spec, causing API server startup errors or inability to decode legacy objects stored in etcd under the old version.
* **Root Cause:** Changing `storage: true` from `v1alpha1` to `v1` in the CRD does NOT automatically rewrite existing etcd objects into the new storage version. Objects remain persisted as `v1alpha1` until written to.
* **Diagnosis:**

```bash
# Inspect the storage version status reported by the API server
$ kubectl get crd postgresclusters.platform.example.com -o jsonpath='{.status.storedVersions}'
["v1alpha1", "v1"]
```

* **Resolution:** Use the official `storage-version-migrator` tool to trigger dummy updates across all resources, re-encoding etcd records to `v1`. Once `v1alpha1` is fully purged from etcd state, remove `v1alpha1` from `status.storedVersions` and `spec.versions`.

```bash
# Force rewrite objects to current storage version using kubectl
$ kubectl get postgresclusters --all-namespaces -o json | kubectl replace -f -
```

---

## 6. References

* **CNCF CNPE Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* **Kubernetes Documentation — Custom Resources Overview:**  
  [https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
* **Kubernetes Documentation — CustomResourceDefinitions Specification:**  
  [https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
* **Kubernetes Documentation — OpenAPI v3 Validation Rules & Structural Schemas:**  
  [https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation)
* **Kubernetes Documentation — Common Expression Language (CEL) Validation:**  
  [https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules)
* **Kubernetes Documentation — Webhook Conversion for Multi-Version CRDs:**  
  [https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/#webhook-conversion](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/#webhook-conversion)
* **Kubernetes SIGs — Storage Version Migrator:**  
  [https://github.com/kubernetes-sigs/storage-version-migrator](https://github.com/kubernetes-sigs/storage-version-migrator)