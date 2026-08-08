# Topic 5.3: Using Kubernetes Operators for Platform Automation and Integration

**Exam Domain:** Platform Automation and Integration  
**Exam Weight:** 6.25%  
**Target Level:** Senior SRE / Principal Platform Architect  

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Core Architectural Problem in Production
Kubernetes natively manages stateless workloads using primitive abstractions such as `Deployments`, `ReplicaSets`, and `Pods`. For stateful systems (e.g., PostgreSQL clusters, Kafka brokers, Redis Sentinel clusters, ETCD instances), native controllers are fundamentally insufficient. Standard primitives like `StatefulSets` handle stable network identifiers and ordered ordinal pod provisioning, but they lack domain-specific operational intelligence.

In enterprise production environments, Day-2 operations for complex stateful platforms require human operator intervention for tasks such as:
- Initializing topology topologies (e.g., primary-replica replication setup, raft consensus bootstrapping).
- Executing dynamic, zero-downtime schema migrations and version upgrades.
- Handling automated failovers, quorum renegotiations, and split-brain resolution.
- Performing consistent Point-In-Time Recovery (PITR) and binary log stream archiving.
- Dynamic horizontal scaling while executing graceful rebalancing of data partitions.

Relying on external runbooks, manual human intervention, or out-of-band automation scripts (e.g., Jenkins pipelines, cron jobs) introduces significant operational risks: high Mean Time to Detect/Repair (MTTD/MTTR), human error during high-severity incidents, state drift between configuration repositories and live clusters, and broken declarative contracts.

```
                    +-------------------------------------------------------+
                    |                   KUBERNETES CONTROL PLANE             |
                    +-------------------------------------------------------+
                                                |
                                      Watch / Informer Stream
                                                v
+-----------------------------------------------------------------------------------+
|                            KUBERNETES OPERATOR CONTROL LOOP                        |
|                                                                                   |
|  +--------------------+     +---------------------+     +----------------------+  |
|  |     OBSERVE        | --> |       ANALYZE       | --> |         ACT          |  |
|  | (SharedInformer    |     | (Diff Desired vs    |     | (Issue API Mutating  |  |
|  |  & Cache Lookup)   |     |  Observed State)    |     |  Calls / Reconcile)  |  |
|  +--------------------+     +---------------------+     +----------------------+  |
|            ^                                                       |              |
+------------|-------------------------------------------------------|--------------+
             |                                                       |
             +---------------- Update Status / CRD Subresource <------+
```

### 1.2 The Operator Pattern Mechanics
The **Operator Pattern** extends the Kubernetes control plane by combining **Custom Resource Definitions (CRDs)**—which define the desired state schema—with a domain-specific **Custom Controller** that runs an asynchronous reconciliation loop.

#### 1.2.1 Deep Dive: Internal Mechanics of the Control Loop (`client-go` / `controller-runtime`)
The underlying mechanism of a production-grade Operator relies on the `client-go` framework and `controller-runtime` abstractions. The operational sequence executes through five distinct sub-components:

1. **Reflector**: Establishes an HTTP/2 chunked `ListWatch` stream against the Kubernetes API Server for target resources (both CRDs and child resources like `Pods` or `PersistentVolumeClaims`). It fetches initial state via `List` and maintains a real-time delta stream via `Watch`.
2. **DeltaFIFO Queue**: The Reflector writes incoming state change events (`Added`, `Updated`, `Deleted`) into a FIFO queue.
3. **Informer / SharedIndexInformer**: Consumes events from `DeltaFIFO`, updates an in-memory thread-safe cache (`Indexer`), and dispatches event handlers (`OnAdd`, `OnUpdate`, `OnDelete`). The local cache eliminates redundant GET requests to the Kubernetes API Server during reconciliation.
4. **WorkQueue (Rate-Limiting Queue)**: Event handlers extract the resource's key (`<namespace>/<name>`) and push it to a rate-limiting work queue. The queue handles deduplication (coalescing multiple rapid events for the same key into a single reconciliation task) and manages backoff retries via exponential delays (`utilrate-limiting`).
5. **Reconciler**: Worker goroutines poll the WorkQueue, invoke `Reconcile(ctx, req)`, compare the desired state (declared in the Spec of the Custom Resource) against the observed state (fetched from the Informer's local Indexer), and issue imperative mutating API calls (`Create`, `Update`, `Patch`, `Delete`) to synchronize state.

---

## 2. Technical Comparisons & Architecture Trade-off Analysis

### 2.1 Comparison: Kubernetes Automation Paradigms

| Technical Metric / Feature | Kubernetes Operator (CRD + Controller) | Helm Charts | Terraform / Crossplane Controller | Raw client-go Custom Controller |
| :--- | :--- | :--- | :--- | :--- |
| **State Reconciliation Type** | Continuous, active level-triggered control loop. | Continuous templating engine; static deployment time. | Continuous declarative sync against external/cloud APIs. | Continuous low-level control loop. |
| **Day-2 Operation Capabilities** | **Native**: Auto-failover, backup, restore, schema updates. | **None**: Requires external orchestration. | **Limited**: Managed cloud resource lifecycle management. | **Native**: Full control, high coding implementation overhead. |
| **Loop Execution Frequency** | Real-time (event-driven via Watch API) + fallback reconcile. | Manual trigger (`helm upgrade`) or CI/CD pipeline step. | Periodic sync interval (e.g., 10m poll loops). | Real-time via custom `SharedIndexInformer`. |
| **Schema Validation** | OpenAPI v3 validation, CEL validation, Mutating/Validating Webhooks. | Client-side YAML templating; optional JSONSchema validation. | Provider-specific schema validation. | Manual Go struct validation or OpenAPI CRD schema. |
| **Development & Maintenance Effort** | High (Requires Go/SDK expertise, controller-runtime lifecycle handling). | Low (YAML templates, Go templating functions). | Medium (HCL/Declarative Providers). | Extreme (Manual workqueue management, thread safety, refactor risk). |

### 2.2 Comparison: Custom Resource Definitions (CRDs) vs. Aggregated API Server (AA)

| Metric / Dimension | Custom Resource Definitions (CRDs) | Aggregated API Server (AA) |
| :--- | :--- | :--- |
| **Storage Backend** | Managed automatically by core Kubernetes `etcd`. | Custom storage backend (e.g., external etcd, PostgreSQL, dynamic memory). |
| **API Latency & Throughput** | Standard etcd latency; constrained by shared etcd cluster limits. | Custom optimized performance tuning per storage driver. |
| **Schema Evolution & Versioning** | Built-in via CRD conversion webhooks and `storedVersions`. | Manual API version translation implementation required. |
| **Operational Complexity** | Very Low (Native object managed by k8s control plane). | High (Requires deploying, monitoring, scaling custom API server binary + TLS certs). |
| **Subresource Support** | `/status`, `/scale` built-in; custom subresources restricted. | Full customization of any arbitrary HTTP REST endpoint/subresource. |

### 2.3 Comparison: Reconcile Loop Trigger Strategies

| Strategy | Mechanism | Latency / Responsiveness | API Server Load | Operational Risk |
| :--- | :--- | :--- | :--- | :--- |
| **Event-Driven Watch (Informer)** | ListWatch via HTTP/2 stream on owned child resources. | Real-time (< 100ms). | Very Low (Uses persistent push stream). | Cache staleness if Informer resync fails. |
| **Periodic Requeue (`RequeueAfter`)** | Returns `reconcile.Result{RequeueAfter: d}` in controller. | Delayed by fixed interval `d`. | Moderate (Triggers full reconciliation on interval). | High resource usage if resync interval is too aggressive. |
| **Polling Out-of-Band State** | Worker thread explicitly queries external endpoint (e.g., DB API). | Polling interval dependent (e.g., 30s). | Zero on k8s API; high on target system. | Network timeouts, rate limiting on target APIs. |

---

## 3. Complete, Production-Ready Manifests

The following manifests construct a production-ready PostgreSQL Operator ecosystem, complete with an OpenAPI v3 CRD schema, a Custom Resource instance, RBAC configuration, Leader Election, and Deployment spec.

### 3.1 Custom Resource Definition Manifest (`crd-postgresqlcluster.yaml`)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresqlclusters.database.platform.cncf.io
  annotations:
    controller-gen.kubebuilder.io/version: v0.14.0
    api-approved.kubernetes.io: "https://github.com/kubernetes/enhancements/pull/1111"
spec:
  group: database.platform.cncf.io
  names:
    kind: PostgreSQLCluster
    listKind: PostgreSQLClusterList
    plural: postgresqlclusters
    singular: postgresqlcluster
    shortNames:
      - pgcluster
      - pgc
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
          labelSelectorPath: .status.labelSelector
      additionalPrinterColumns:
        - name: Status
          type: string
          jsonPath: .status.phase
        - name: Replicas
          type: integer
          jsonPath: .status.readyReplicas
        - name: Primary
          type: string
          jsonPath: .status.primaryPod
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          description: PostgreSQLCluster defines the enterprise deployment spec for managed DB clusters.
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
                - replicas
                - version
                - storage
                - backupSchedule
              properties:
                replicas:
                  type: integer
                  format: int32
                  minimum: 1
                  maximum: 9
                  description: Total desired instances in cluster (1 Primary + N Replicas).
                version:
                  type: string
                  enum:
                    - "14"
                    - "15"
                    - "16"
                  description: Major PostgreSQL engine version.
                storage:
                  type: object
                  required:
                    - size
                    - storageClassName
                  properties:
                    size:
                      type: string
                      pattern: '^([0-9]+)(Gi|Ti)$'
                      description: Storage volume request (e.g. 50Gi, 1Ti).
                    storageClassName:
                      type: string
                      description: Name of target StorageClass supporting volume binding.
                backupSchedule:
                  type: string
                  pattern: '^(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)$'
                  description: Standard Cron expression for automated base backups.
                resources:
                  type: object
                  properties:
                    limits:
                      type: object
                      additionalProperties:
                        type: string
                    requests:
                      type: object
                      additionalProperties:
                        type: string
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum:
                    - Pending
                    - Initializing
                    - Running
                    - Degrading
                    - Failed
                readyReplicas:
                  type: integer
                  format: int32
                primaryPod:
                  type: string
                labelSelector:
                  type: string
                observedGeneration:
                  type: integer
                  format: int64
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
                        enum: ["True", "False", "Unknown"]
                      lastTransitionTime:
                        type: string
                        format: date-time
                      reason:
                        type: string
                      message:
                        type: string
```

### 3.2 Custom Resource Instance Manifest (`cr-postgres-production.yaml`)

```yaml
apiVersion: database.platform.cncf.io/v1alpha1
kind: PostgreSQLCluster
metadata:
  name: prod-db-cluster
  namespace: database-workloads
  labels:
    environment: production
    tier: database
spec:
  replicas: 3
  version: "16"
  storage:
    size: 100Gi
    storageClassName: gp3-csi-immediate
  backupSchedule: "0 2 * * *"
  resources:
    requests:
      cpu: "2000m"
      memory: "4Gi"
    limits:
      cpu: "4000m"
      memory: "8Gi"
```

### 3.3 Operator RBAC, ServiceAccount, and Deployment Manifest (`operator-infrastructure.yaml`)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: postgres-operator-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-operator-controller-manager
  namespace: postgres-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: postgres-operator-role
rules:
  # Operator Custom Resources permissions
  - apiGroups:
      - database.platform.cncf.io
    resources:
      - postgresqlclusters
      - postgresqlclusters/status
      - postgresqlclusters/finalizers
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  # Core Kubernetes workload resources permissions
  - apiGroups:
      - ""
    resources:
      - pods
      - services
      - endpoints
      - persistentvolumeclaims
      - configmaps
      - secrets
      - events
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - apps
    resources:
      - statefulsets
      - deployments
    verbs:
      - create
      - delete
      - get
      - list
      - patch
      - update
      - watch
  # Coordination API for Leader Election
  - apiGroups:
      - coordination.k8s.io
    resources:
      - leases
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: postgres-operator-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: postgres-operator-role
subjects:
  - kind: ServiceAccount
    name: postgres-operator-controller-manager
    namespace: postgres-operator-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-operator-controller-manager
  namespace: postgres-operator-system
  labels:
    app.kubernetes.io/name: postgres-operator
    control-plane: controller-manager
spec:
  replicas: 2
  selector:
    matchLabels:
      control-plane: controller-manager
  template:
    metadata:
      labels:
        control-plane: controller-manager
    spec:
      serviceAccountName: postgres-operator-controller-manager
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: manager
          image: ghcr.io/cncf/example-postgres-operator:v1.2.0
          imagePullPolicy: IfNotPresent
          command:
            - /manager
          args:
            - --leader-elect=true
            - --leader-election-namespace=postgres-operator-system
            - --health-probe-bind-address=:8081
            - --metrics-bind-address=127.0.0.1:8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8081
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8081
            initialDelaySeconds: 5
            periodSeconds: 10
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Applying the Custom Resource Definition & Verifying Schema Registration

```bash
$ kubectl apply -f crd-postgresqlcluster.yaml
customresourcedefinition.apiextensions.k8s.io/postgresqlclusters.database.platform.cncf.io created

$ kubectl get crd postgresqlclusters.database.platform.cncf.io -o wide
NAME                                           CREATED AT             APIVERSION
postgresqlclusters.database.platform.cncf.io   2026-08-07T19:20:00Z   apiextensions.k8s.io/v1

$ kubectl api-resources --api-group=database.platform.cncf.io
NAME                 SHORTNAMES   APIVERSION                             NAMESPACED   KIND
postgresqlclusters   pgcluster    database.platform.cncf.io/v1alpha1     true         PostgreSQLCluster
```

### 4.2 Deploying the Operator Infrastructure & Checking Leader Election Status

```bash
$ kubectl apply -f operator-infrastructure.yaml
namespace/postgres-operator-system created
serviceaccount/postgres-operator-controller-manager created
clusterrole.rbac.authorization.k8s.io/postgres-operator-role created
clusterrolebinding.rbac.authorization.k8s.io/postgres-operator-rolebinding created
deployment.apps/postgres-operator-controller-manager created

$ kubectl get pods -n postgres-operator-system
NAME                                                    READY   STATUS    RESTARTS   AGE
postgres-operator-controller-manager-7894567b8-x29zk   1/1     Running   0          22s
postgres-operator-controller-manager-7894567b8-z8qlm   1/1     Running   0          22s

$ kubectl get lease -n postgres-operator-system
NAME                                    HOLDER                                                  AGE
postgres-operator-leader-election-lock  postgres-operator-controller-manager-7894567b8-x29zk   30s
```

### 4.3 Creating the Custom Resource and Monitoring Real-Time Reconciliation

```bash
$ kubectl apply -f cr-postgres-production.yaml -n database-workloads
postgresqlcluster.database.platform.cncf.io/prod-db-cluster created

$ kubectl get postgresqlcluster -n database-workloads
NAME              STATUS        REPLICAS   PRIMARY                 AGE
prod-db-cluster   Initializing  0/3        prod-db-cluster-0       5s

$ kubectl get pods -n database-workloads -l app.kubernetes.io/instance=prod-db-cluster
NAME                READY   STATUS    RESTARTS   AGE
prod-db-cluster-0   1/1     Running   0          45s
prod-db-cluster-1   1/1     Running   0          30s
prod-db-cluster-2   1/1     Running   0          15s

$ kubectl get postgresqlcluster -n database-workloads
NAME              STATUS    REPLICAS   PRIMARY                 AGE
prod-db-cluster   Running   3          prod-db-cluster-0       60s
```

### 4.4 Tailing Operator Logs During Reconciliation Loop Execution

```bash
$ kubectl logs -n postgres-operator-system deployment/postgres-operator-controller-manager -f --tail=20
2026-08-07T19:21:10.123Z INFO  controller.postgresqlcluster Starting Reconcile Loop {"reconcilerGroup": "database.platform.cncf.io", "reconcilerKind": "PostgreSQLCluster", "name": "prod-db-cluster", "namespace": "database-workloads"}
2026-08-07T19:21:10.125Z INFO  controller.postgresqlcluster Observed generation matches target generation {"generation": 1}
2026-08-07T19:21:10.180Z INFO  controller.postgresqlcluster StatefulSet validation check complete {"statefulset": "prod-db-cluster", "status": "replicas-matched"}
2026-08-07T19:21:10.210Z INFO  controller.postgresqlcluster Primary node healthcheck succeeded {"node": "prod-db-cluster-0", "role": "primary"}
2026-08-07T19:21:10.250Z INFO  controller.postgresqlcluster Status subresource updated successfully {"phase": "Running", "readyReplicas": 3}
```

---

## 5. Verification & Failure Troubleshooting Guide

### 5.1 Failure Scenario 1: Stale Finalizers Blocking Resource Deletion
#### Symptom
A Custom Resource remains indefinitely stuck in the `Terminating` state after running `kubectl delete pgcluster prod-db-cluster`.

```bash
$ kubectl get pgcluster prod-db-cluster -n database-workloads
NAME              STATUS    REPLICAS   PRIMARY             AGE
prod-db-cluster   Running   3          prod-db-cluster-0   10m (deleting...)
```

#### Root Cause Analysis
The controller injected a custom finalizer (`database.platform.cncf.io/finalizer`) into `.metadata.finalizers`. When a deletion request is issued, Kubernetes sets `.metadata.deletionTimestamp`. The controller is responsible for executing pre-delete cleanup routines (e.g., backing up database logs, releasing cloud load balancers) and removing the finalizer string. If the operator deployment is uninstalled, crashed, or missing permissions, the object cannot be garbage collected.

#### Diagnostic & Remediation Steps
1. Inspect `.metadata.finalizers` and `.metadata.deletionTimestamp`:
```bash
$ kubectl get pgcluster prod-db-cluster -n database-workloads -o jsonpath='{.metadata.finalizers}'
["database.platform.cncf.io/finalizer"]
```

2. If the operator binary is unrecoverable and out-of-band cleanup has been manually verified, forcefully strip the finalizer using a JSON merge patch:
```bash
$ kubectl patch pgcluster prod-db-cluster -n database-workloads --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
postgresqlcluster.database.platform.cncf.io/prod-db-cluster patched
```

---

### 5.2 Failure Scenario 2: WorkQueue Saturation & Rate-Limiting Backoff
#### Symptom
Changes made to the Spec of a Custom Resource take minutes or hours to reconcile, or do not reconcile at all. The operator log shows recurring requeue notices.

```bash
2026-08-07T19:25:01.450Z ERROR reconciler.postgresqlcluster Reconcile error encountered; requeuing {"error": "Conflict: Operation cannot be fulfilled on statefulsets.apps \"prod-db-cluster\": the object has been modified; please apply your changes to the latest version and try again", "requeueAfter": "16s"}
```

#### Root Cause Analysis
- **Resource Lock Contention / Optimistic Concurrency Failure**: The controller attempts to update an object using an outdated `resourceVersion`, triggering a 409 Conflict.
- **Non-Idempotent Reconciliation Loop**: The reconciler modifies child resources unconditionally on every loop without checking if the target state is already met. This causes child updates to continuously trigger new Watch events back to the Informer, filling the `WorkQueue`.

#### Diagnostic & Remediation Steps
1. Check Prometheus metrics exposed by `controller-runtime` on port 8080:
   - `workqueue_depth{name="postgresqlcluster"}`: Spikes above 0 continuously.
   - `workqueue_adds_total{name="postgresqlcluster"}`: Extremely high growth rate.
   - `controller_runtime_reconcile_errors_total{controller="postgresqlcluster"}`: Incrementing continuously.
2. Debug in code/manifests: Ensure the reconciler fetches the latest object version using `client.Get()` before mutating, or uses atomic `client.Patch()` with strict Server-Side Apply (SSA) field management.

---

### 5.3 Failure Scenario 3: Leader Election Lockout (Split-Brain Prevention)
#### Symptom
Operator logs report leadership loss, and secondary pods refuse to execute reconciliation loops.

```bash
2026-08-07T19:28:12.001Z INFO  leader-election leaderelection.go:248 failed to renew lease postgres-operator-system/postgres-operator-leader-election-lock: failed to update lease: failed to calling webhook: Post "https://...": context deadline exceeded
2026-08-07T19:28:12.002Z ERROR controller-runtime.manager stopped leading
```

#### Root Cause Analysis
The active leader pod missed its Lease renewal deadline (defined in `coordination.k8s.io/v1 Lease` object) due to network throttling, high CPU starvation on the control plane node, or excessive etcd latency. Controller-runtime immediately stops all workers when leadership drops to ensure two instances never make conflicting mutations against cluster state.

#### Diagnostic & Remediation Steps
1. Inspect the Lease object status:
```bash
$ kubectl describe lease postgres-operator-leader-election-lock -n postgres-operator-system
Name:         postgres-operator-leader-election-lock
Namespace:    postgres-operator-system
Holder:       postgres-operator-controller-manager-7894567b8-x29zk
Lease Duration: 15s
Renew Time:     Fri, 07 Aug 2026 19:28:00 GMT
Acquire Time:   Fri, 07 Aug 2026 19:20:00 GMT
Transitions:    3
```
2. Verify system CPU limits on the operator container (`spec.containers[*].resources.limits.cpu`). If CPU throttling occurs (check `/sys/fs/cgroup/cpu.stat`), increase limits or remove aggressive CPU quotas.

---

## 6. References

- **CNCF Curriculum**: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Kubernetes Documentation - Operator Pattern**: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- **Kubernetes Documentation - Custom Resources**: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- **Kubernetes Controller Runtime**: https://pkg.go.dev/sigs.k8s.io/controller-runtime
- **Kubebuilder Book & Operator Architecture**: https://book.kubebuilder.io/architecture.html
- **Kubernetes API Conventions (Status & Subresources)**: https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md