# CNPE Exam Study Guide: Topic 4.3 – Deploying Applications Using Progressive Delivery Strategies (Blue/Green & Canary)

**Weight**: 8.34%  
**Target Level**: Principal Platform Architect / Senior SRE  
**Reference Source**: [CNCF Curriculum Repository](https://github.com/cncf/curriculum)  

---

## Technical Deep Dive: Architecture & Internal Mechanics

Progressive delivery extends traditional Continuous Delivery (CD) by decoupling *code deployment* (copying binaries/running pods in Kubernetes) from *feature release* (exposing incoming user traffic to the new code). Standard Kubernetes `Deployment` resources manage pod lifecycles via rolling updates using `maxSurge` and `maxUnavailable`. However, `Deployment` objects lack fine-grained, weight-based traffic control and automated metrics-driven gating. Traffic distribution in standard deployments is determined purely by the ratio of new-to-old pods in the endpoint slice (`EndpointSlice` / `Service`), which makes low-percentage canary testing (e.g., 1% of HTTP requests) impossible without deploying an impractically large total pod count.

```
                              +---------------------------------------+
                              |        Custom Controller              |
                              |  (e.g., Argo Rollouts / Flagger)      |
                              +------------------+--------------------+
                                                 |
                   +-----------------------------+-----------------------------+
                   | Reconciles ReplicaSets                                    | Configures Traffic Provider
                   v                                                           v
  +---------------------------------+                         +---------------------------------+
  +   Stable RS    +   Canary RS    +                         |   Ingress / Service Mesh        |
  |  (Version v1)  |  (Version v2)  |                         | (Istio / NGINX / Gateway API)   |
  +-------+--------+-------+--------+                         +----------------+----------------+
          |                |                                                   |
          |                |                                                   |
          v                v                                                   v
  +---------------+ +---------------+                         +---------------------------------+
  | Stable Pods   | | Canary Pods   |                         |  Weight Shifting & Mirroring    |
  | (App Version 1| | (App Version 2|                         |  (e.g., 90% -> v1, 10% -> v2)   |
  +---------------+ +---------------+                         +---------------------------------+
```

### Controller Mechanics & Reconciliation Loop
Custom Resource Controllers (such as Argo Rollouts or Flagger) replace or augment the standard Kubernetes `Deployment` controller by watching a custom resource (e.g., `Rollout`). The reconciliation loop executes the following sequence:

1. **Pod Template Hash Calculation**: When `spec.template` changes, the controller generates a unique hash and creates a new `ReplicaSet` (Canary/Preview RS).
2. **Traffic Provider Manipulation**: Rather than relying on Kubernetes `Service` pod ratios, the controller calls APIs for Service Meshes (Istio `VirtualService`, Envoy `RouteConfiguration`) or Ingress Controllers (NGINX ingress annotations, Gateway API `HTTPRoute`) to mutate routing tables dynamically.
3. **Step Execution State Machine**: The controller steps through a user-defined pause-and-weight sequence. It holds the progression at defined steps (`pause: {}` or `pause: {duration: 1m}`).
4. **Metric Analysis Engine**: Background workers query metric providers (Prometheus, Datadog, CloudWatch). If queries return values outside acceptable thresholds (defined in an `AnalysisTemplate`), the controller changes the Rollout status to `Degraded`, halts progression, and initiates an immediate traffic rollback to the Stable `ReplicaSet`.
5. **Connection Draining & Graceful Shutdown**: Upon rollback or completion, old pods receive a `SIGTERM` signal. The traffic provider immediately removes the pod IP from the active routing table to prevent in-flight request truncation.

### Key Architectural Trade-Offs

| Metric / Dimension | Traditional Rolling Update | Blue/Green Deployment | Canary Deployment |
| :--- | :--- | :--- | :--- |
| **Resource Overhead** | Low (`maxSurge` default: 25%) | High (100% capacity duplicate footprint required) | Low (Proportional to canary step percentage + surge) |
| **Rollback Speed** | Slow (requires spinning down new pods & spinning up old pods) | Instant (Single pointer update on Router/Service) | Fast (Immediate weight update back to stable subset) |
| **Blast Radius** | Medium (Affects subset of users determined by replica ratio) | High (100% of users switched simultaneously if unvalidated) | Very Low (Restricted to precise HTTP request percentage) |
| **Database Schema Compatibility** | Forward-compatible schemas required | Requires dual-schema support or strict non-breaking migrations | Forward/Backward compatible schemas strictly required |
| **Testing Real Traffic** | In-flight live traffic | Pre-cutover smoke test via Preview Endpoint | Live production traffic with metric gating & optional shadowing |

---

## Module 1: Infrastructure Setup & CRD Architecture Verification

In this module, you will inspect the cluster components responsible for progressive delivery and verify the CRDs powering custom rollout reconciliation loops.

### Guided Steps

1. Verify that the Argo Rollouts controller and Istio service mesh components are installed and healthy in the cluster:
   ```bash
   kubectl get pods -n argo-rollouts
   kubectl get pods -n istio-system
   ```
   *Expected Output:*
   ```text
   NAME                                     READY   STATUS    RESTARTS   AGE
   argo-rollouts-7f48896d84-x2p9k          1/1     Running   0          5d2h
   
   NAME                                     READY   STATUS    RESTARTS   AGE
   istiod-55b6965b6f-w8m22                  1/1     Running   0          5d2h
   ```

2. Inspect the custom resource definitions (CRDs) registered by Argo Rollouts to observe the custom schema API endpoints:
   ```bash
   kubectl get crd | grep argoproj.io
   ```
   *Expected Output:*
   ```text
   analysisruns.argoproj.io                 2026-08-01T10:00:00Z
   analysistemplates.argoproj.io             2026-08-01T10:00:00Z
   clusteranalysistemplates.argoproj.io      2026-08-01T10:00:00Z
   experiments.argoproj.io                  2026-08-01T10:00:00Z
   rollouts.argoproj.io                     2026-08-01T10:00:00Z
   ```

3. View the Rollout CRD API group, version, and scope:
   ```bash
   kubectl explain rollout --api-version=argoproj.io/v1alpha1
   ```
   *Expected Output:*
   ```text
   KIND:       Rollout
   VERSION:    argoproj.io/v1alpha1
   DESCRIPTION:
       Rollout defines a Kubernetes Deployment replacement powered by progressive
       delivery capabilities including Blue/Green and Canary deployments.
   ```

---

### Module 1 Comprehension Check

**Question 1.1**: Why is a native Kubernetes `Deployment` object incapable of executing a true 1% canary deployment when running 3 application replicas? Explain using endpoint controller mechanics.

**Question 1.2**: In an Istio-backed progressive delivery setup, what component modifies traffic weights when a rollout transitions between steps, and how does this differ from modifying a standard Kubernetes `Service` selector?

---

## Module 2: Blue/Green Strategy with Active/Preview Routing & Automated Pre-Promotion Analysis

Blue/Green deployment maintains two independent replica sets: `Active` (serving live production traffic) and `Preview` (serving staging/internal traffic). Before promoting `Preview` to `Active`, an `AnalysisRun` executes automated HTTP smoke tests against the `Preview` endpoint.

```
                  +--------------------------------+
                  |         Istio Gateway          |
                  +---------------+----------------+
                                  |
            +---------------------+---------------------+
            | Host: app.example.com                     | Host: preview.example.com
            v                                           v
  +--------------------+                     +--------------------+
  | Active K8s Service |                     | Preview K8s Service|
  +---------+----------+                     +---------+----------+
            |                                           |
            v                                           v
  +--------------------+                     +--------------------+
  | Active ReplicaSet  |                     | Preview ReplicaSet |
  |   (v1.0.0 - 100%)  |                     |   (v1.1.0 - 0%)    |
  +--------------------+                     +--------------------+
```

### Guided Steps

1. Create a workspace namespace named `progressive-delivery-lab`:
   ```bash
   kubectl create namespace progressive-delivery-lab
   kubectl label namespace progressive-delivery-lab istio-injection=enabled
   ```
   *Expected Output:*
   ```text
   namespace/progressive-delivery-lab created
   namespace/progressive-delivery-lab labeled
   ```

2. Save the following manifest as `bluegreen-rollout.yaml`. This file includes the `AnalysisTemplate`, Kubernetes Services, Istio Routing objects, and the `Rollout` definition:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: bluegreen-smoke-test
     namespace: progressive-delivery-lab
   spec:
     metrics:
     - name: preview-http-smoke-test
       provider:
         web:
           url: "http://payments-preview.progressive-delivery-lab.svc.cluster.local:8080/healthz"
           timeoutSeconds: 5
           jsonPath: "{$.status}"
       successCondition: result == 'OK'
       interval: 5s
       count: 3
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: payments-active
     namespace: progressive-delivery-lab
   spec:
     ports:
     - name: http
       port: 8080
       targetPort: 8080
     selector:
       app: payments
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: payments-preview
     namespace: progressive-delivery-lab
   spec:
     ports:
     - name: http
       port: 8080
       targetPort: 8080
     selector:
       app: payments
   ---
   apiVersion: networking.istio.io/v1alpha3
   kind: VirtualService
   metadata:
     name: payments-virtualservice
     namespace: progressive-delivery-lab
   spec:
     hosts:
     - "payments.example.com"
     gateways:
     - mesh
     http:
     - name: primary-route
       route:
       - destination:
           host: payments-active.progressive-delivery-lab.svc.cluster.local
           port:
             number: 8080
         weight: 100
       - destination:
           host: payments-preview.progressive-delivery-lab.svc.cluster.local
           port:
             number: 8080
         weight: 0
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: payments-service
     namespace: progressive-delivery-lab
   spec:
     replicas: 4
     revisionHistoryLimit: 3
     selector:
       matchLabels:
         app: payments
     template:
       metadata:
         labels:
           app: payments
       spec:
         containers:
         - name: payments-api
           image: argoproj/rollouts-demo:blue
           ports:
           - name: http
             containerPort: 8080
           readinessProbe:
             httpGet:
               path: /healthz
               port: 8080
             initialDelaySeconds: 3
             periodSeconds: 3
     strategy:
       blueGreen:
         activeService: payments-active
         previewService: payments-preview
         autoPromotionEnabled: false
         prePromotionAnalysis:
           templates:
           - templateName: bluegreen-smoke-test
         trafficRouting:
           istio:
             virtualService:
               name: payments-virtualservice
               routes:
               - primary-route
   ```

3. Apply the complete Blue/Green architecture:
   ```bash
   kubectl apply -f bluegreen-rollout.yaml
   ```
   *Expected Output:*
   ```text
   analysistemplate.argoproj.io/bluegreen-smoke-test created
   service/payments-active created
   service/payments-preview created
   virtualservice.networking.istio.io/payments-virtualservice created
   rollout.argoproj.io/payments-service created
   ```

4. Monitor the rollout until all 4 replicas are healthy and active:
   ```bash
   kubectl argo rollouts get rollout payments-service -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   Name:            payments-service
   Namespace:       progressive-delivery-lab
   Status:          HEALTHY
   Strategy:        BlueGreen
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas:
     Desired:       4
     Current:       4
     Updated:       4
     Ready:         4
     Available:     4

   NAME                                                 STATUS     MEMORY  STARTED               AGE
   e-payments-service-67566587c6                        Healthy    0B      2026-08-07T19:00:00Z  1m
   └── pd-payments-service-67566587c6-2w4x8             Ready      0B      2026-08-07T19:00:00Z  1m
   └── pd-payments-service-67566587c6-5q9lm             Ready      0B      2026-08-07T19:00:00Z  1m
   └── pd-payments-service-67566587c6-8j2nk             Ready      0B      2026-08-07T19:00:00Z  1m
   └── pd-payments-service-67566587c6-9l7zz             Ready      0B      2026-08-07T19:00:00Z  1m
   ```

5. Trigger an update by changing the container image to `argoproj/rollouts-demo:green`:
   ```bash
   kubectl argo rollouts set image payments-service payments-api=argoproj/rollouts-demo:green -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   rollout "payments-service" image updated
   ```

6. Inspect the rollout state immediately during the pre-promotion pause phase:
   ```bash
   kubectl argo rollouts get rollout payments-service -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   Name:            payments-service
   Namespace:       progressive-delivery-lab
   Status:          PAUSED
   Message:         BlueGreenPause
   Strategy:        BlueGreen
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:green (preview)
   Replicas:
     Desired:       4
     Current:       8
     Updated:       4
     Ready:         8
     Available:     8

   NAME                                                 STATUS     MEMORY  STARTED               AGE
   e-payments-service-589647b5b7                        Healthy    0B      2026-08-07T19:01:00Z  30s
   ├── pd-payments-service-589647b5b7-x49kl             Ready      0B      2026-08-07T19:01:00Z  30s
   ├── pd-payments-service-589647b5b7-p91mn             Ready      0B      2026-08-07T19:01:00Z  30s
   ├── pd-payments-service-589647b5b7-k81vv             Ready      0B      2026-08-07T19:01:00Z  30s
   └── pd-payments-service-589647b5b7-l30pp             Ready      0B      2026-08-07T19:01:00Z  30s
   e-payments-service-67566587c6                        Healthy    0B      2026-08-07T19:00:00Z  2m
   ├── pd-payments-service-67566587c6-2w4x8             Ready      0B      2026-08-07T19:00:00Z  2m
   ├── pd-payments-service-67566587c6-5q9lm             Ready      0B      2026-08-07T19:00:00Z  2m
   ├── pd-payments-service-67566587c6-8j2nk             Ready      0B      2026-08-07T19:00:00Z  2m
   └── pd-payments-service-67566587c6-9l7zz             Ready      0B      2026-08-07T19:00:00Z  2m

   Analysis Runs:
   └── payments-service-589647b5b7-pre  Successful
   ```

7. Manually promote the rollout to execute traffic cutover to the green ReplicaSet:
   ```bash
   kubectl argo rollouts promote payments-service -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   rollout 'payments-service' promoted
   ```

---

### Module 2 Comprehension Check

**Question 2.1**: What specific change occurs to the pod selectors of `payments-active` and `payments-preview` Kubernetes services during the promotion step in a Blue/Green rollout when traffic routing is **not** managed by a service mesh?

**Question 2.2**: If the `prePromotionAnalysis` run fails (e.g., return code 500 or timeout), describe the exact sequence of events executed by the Rollout controller regarding traffic routing and pod lifecycles.

---

## Module 3: Canary Strategy with Dynamic Weight Shifting, Traffic Mirroring & Prometheus Metric Analysis

Canary deployments gradually shift live traffic from the stable revision to the canary revision (e.g., 10% -> 30% -> 50% -> 100%). During this progression, continuous background analysis queries Prometheus to monitor real-time HTTP error rates and latency.

```
                           +------------------------+
                           |  Istio VirtualService  |
                           +-----------+------------+
                                       |
                 +---------------------+---------------------+
                 | HTTP Traffic Shifting                     | Traffic Shadow / Mirror
                 v                                           v
    +-------------------------+                 +-------------------------+
    |   DestinationRule: v1   |                 |   DestinationRule: v2   |
    |      (Weight: 90%)      |                 |   (Mirrored Copy: 100%) |
    +------------+------------+                 +------------+------------+
                 |                                           |
                 v                                           v
    +-------------------------+                 +-------------------------+
    |   Stable Pod Subset     |                 |   Canary Pod Subset     |
    +-------------------------+                 +-------------------------+
```

### Guided Steps

1. Create a Prometheus-backed `AnalysisTemplate` saved as `canary-analysis.yaml`. This template calculates HTTP 5xx error percentage over a rolling 2-minute window:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: prometheus-error-rate-check
     namespace: progressive-delivery-lab
   spec:
     args:
     - name: service-name
     metrics:
     - name: success-rate
       interval: 10s
       successCondition: result[0] <= 0.01
       failureLimit: 3
       provider:
         prometheus:
           address: "http://prometheus-k8s.monitoring.svc.cluster.local:9090"
           query: |
             sum(rate(istio_requests_total{reporter="destination",destination_service_name=~"{{args.service-name}}",response_code=~"5.*"}[2m]))
             /
             sum(rate(istio_requests_total{reporter="destination",destination_service_name=~"{{args.service-name}}"}[2m]))
   ```

2. Apply the analysis template:
   ```bash
   kubectl apply -f canary-analysis.yaml
   ```
   *Expected Output:*
   ```text
   analysistemplate.argoproj.io/prometheus-error-rate-check created
   ```

3. Save the following manifest as `canary-rollout.yaml`. It configures Istio routing, Destination Rules (subsets `stable` and `canary`), traffic mirroring, step weights, and continuous background metric analysis:

   ```yaml
   apiVersion: networking.istio.io/v1alpha3
   kind: DestinationRule
   metadata:
     name: catalog-destinationrule
     namespace: progressive-delivery-lab
   spec:
     host: catalog-service.progressive-delivery-lab.svc.cluster.local
     subsets:
     - name: stable
       labels:
         rollouts-pod-template-hash: stable
     - name: canary
       labels:
         rollouts-pod-template-hash: canary
   ---
   apiVersion: networking.istio.io/v1alpha3
   kind: VirtualService
   metadata:
     name: catalog-virtualservice
     namespace: progressive-delivery-lab
   spec:
     hosts:
     - catalog.example.com
     gateways:
     - mesh
     http:
     - name: primary-canary-route
       route:
       - destination:
           host: catalog-service.progressive-delivery-lab.svc.cluster.local
           subset: stable
         weight: 100
       - destination:
           host: catalog-service.progressive-delivery-lab.svc.cluster.local
           subset: canary
         weight: 0
       mirror:
         host: catalog-service.progressive-delivery-lab.svc.cluster.local
         subset: canary
       percentage:
         value: 100.0
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: catalog-service
     namespace: progressive-delivery-lab
   spec:
     ports:
     - name: http
       port: 8080
       targetPort: 8080
     selector:
       app: catalog
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: catalog-service
     namespace: progressive-delivery-lab
   spec:
     replicas: 5
     revisionHistoryLimit: 5
     selector:
       matchLabels:
         app: catalog
     template:
       metadata:
         labels:
           app: catalog
       spec:
         containers:
         - name: catalog-api
           image: argoproj/rollouts-demo:blue
           ports:
           - name: http
             containerPort: 8080
     strategy:
       canary:
         canaryService: catalog-service
         trafficRouting:
           istio:
             virtualService:
               name: catalog-virtualservice
               routes:
               - primary-canary-route
             destinationRule:
               name: catalog-destinationrule
               canarySubsetName: canary
               stableSubsetName: stable
         analysis:
           templates:
           - templateName: prometheus-error-rate-check
           args:
           - name: service-name
             value: catalog-service
         steps:
         - setWeight: 10
         - pause: { duration: 30s }
         - setWeight: 30
         - pause: { duration: 1m }
         - setWeight: 50
         - pause: { duration: 2m }
   ```

4. Deploy the complete Canary setup:
   ```bash
   kubectl apply -f canary-rollout.yaml
   ```
   *Expected Output:*
   ```text
   destinationrule.networking.istio.io/catalog-destinationrule created
   virtualservice.networking.istio.io/catalog-virtualservice created
   service/catalog-service created
   rollout.argoproj.io/catalog-service created
   ```

5. Trigger a canary deployment by updating the image to `argoproj/rollouts-demo:yellow`:
   ```bash
   kubectl argo rollouts set image catalog-service catalog-api=argoproj/rollouts-demo:yellow -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   rollout "catalog-service" image updated
   ```

6. Monitor step progression and live metric analysis execution:
   ```bash
   kubectl argo rollouts get rollout catalog-service -n progressive-delivery-lab --watch
   ```
   *Expected Output:*
   ```text
   Name:            catalog-service
   Namespace:       progressive-delivery-lab
   Status:          PROGRESSING
   Message:         SetWeight:30%
   Strategy:        Canary
     Step:          3/6 (Pause 1m)
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:yellow (canary)
   Replicas:
     Desired:       5
     Current:       6
     Updated:       2
     Ready:         6
     Available:     6

   NAME                                                 STATUS     MEMORY  STARTED               AGE
   e-catalog-service-86b4594589                         Healthy    0B      2026-08-07T19:05:00Z  45s
   ├── pd-catalog-service-86b4594589-m82pp              Ready      0B      2026-08-07T19:05:00Z  45s
   └── pd-catalog-service-86b4594589-v91zz              Ready      0B      2026-08-07T19:05:00Z  45s
   e-catalog-service-67566587c6                         Healthy    0B      2026-08-07T19:02:00Z  3m
   ├── pd-catalog-service-67566587c6-1a2b3              Ready      0B      2026-08-07T19:02:00Z  3m
   ├── pd-catalog-service-67566587c6-4c5d6              Ready      0B      2026-08-07T19:02:00Z  3m
   ├── pd-catalog-service-67566587c6-7e8f9              Ready      0B      2026-08-07T19:02:00Z  3m
   └── pd-catalog-service-67566587c6-0g1h2              Ready      0B      2026-08-07T19:02:00Z  3m

   Analysis Runs:
   └── catalog-service-86b4594589-3  Running  Successful: 4
   ```

7. Inspect the auto-generated Istio `VirtualService` configuration applied dynamically by the Rollouts controller during the step:
   ```bash
   kubectl get virtualservice catalog-virtualservice -n progressive-delivery-lab -o yaml
   ```
   *Expected Output snippet:*
   ```yaml
   spec:
     http:
     - name: primary-canary-route
       route:
       - destination:
           host: catalog-service.progressive-delivery-lab.svc.cluster.local
           subset: stable
         weight: 70
       - destination:
           host: catalog-service.progressive-delivery-lab.svc.cluster.local
           subset: canary
         weight: 30
   ```

---

### Module 3 Comprehension Check

**Question 3.1**: When combining Istio Traffic Mirroring (`mirror`) with progressive canary delivery, what happens to responses generated by the mirrored destination, and what key operational risk must be managed regarding backend state mutations (e.g., database writes, payment processing)?

**Question 3.2**: Explain how the `failureLimit` field in an `AnalysisTemplate` protects against transient metric noise during a rollout step.

---

## Module 4: Advanced Diagnostics, Database Schema Evolution & Edge Case Troubleshooting

Progressive delivery requires careful management of stateful dependencies. Additionally, engineers must be capable of diagnosing stuck rollouts, metric query failures, and pod crash loops during canary evaluation.

### Database Schema Evolution: Expand-Contract Pattern
Because both old (stable) and new (canary/preview) pod revisions run concurrently during progressive delivery, database schema changes **must never** be destructive in a single deployment step.

```
Phase 1: Expand
┌─────────────────────────┐
│ DB Table: users         │
│ - id                    │
│ - name (legacy)         │
│ - first_name (NEW)      │
│ - last_name (NEW)       │
└─────────────────────────┘
  v1 Pods read/write `name`
  v2 Pods write BOTH, read `first_name`

Phase 2: Migrate Data
  Background backfill populates `first_name` and `last_name` from `name`

Phase 3: Contract
  v3 Pods read/write ONLY `first_name` / `last_name`
  Schema migration drops legacy column `name`
```

### Guided Steps: Troubleshooting & Remediation

1. Simulate a failed rollout step caused by an image pull error or crashlooping container:
   ```bash
   kubectl argo rollouts set image catalog-service catalog-api=argoproj/rollouts-demo:bad-tag -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   rollout "catalog-service" image updated
   ```

2. Check the rollout status to identify the degraded state:
   ```bash
   kubectl argo rollouts get rollout catalog-service -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   Name:            catalog-service
   Namespace:       progressive-delivery-lab
   Status:          DEGRADED
   Message:         ProgressDeadlineExceeded: ReplicaSet "catalog-service-7bb957476f" has timed out progressing.
   Strategy:        Canary
   ```

3. Deep-dive into the underlying Kubernetes events and AnalysisRun logs to isolate the root cause:
   ```bash
   kubectl get analysisruns -n progressive-delivery-lab
   kubectl describe analysisrun -l rollout-type=canary -n progressive-delivery-lab
   ```
   *Expected Output snippet:*
   ```text
   Status:
     Phase:  Failed
     Metric Results:
       Name:    success-rate
       Phase:   Failed
       Message: Metric "success-rate" failed 3 times. Latest measurement: 0.150000 (threshold <= 0.010000)
   ```

4. Abort the failed rollout immediately to restore 100% traffic to the stable ReplicaSet:
   ```bash
   kubectl argo rollouts abort catalog-service -n progressive-delivery-lab
   ```
   *Expected Output:*
   ```text
   rollout 'catalog-service' aborted
   ```

5. Confirm that traffic weight has immediately reverted to 100% stable:
   ```bash
   kubectl get virtualservice catalog-virtualservice -n progressive-delivery-lab -o jsonpath='{.spec.http[0].route}'
   ```
   *Expected Output:*
   ```json
   [{"destination":{"host":"catalog-service.progressive-delivery-lab.svc.cluster.local","subset":"stable"},"weight":100},{"destination":{"host":"catalog-service.progressive-delivery-lab.svc.cluster.local","subset":"canary"},"weight":0}]
   ```

6. Clear the aborted state and reset the rollout back to a fully healthy revision:
   ```bash
   kubectl argo rollouts undo catalog-service -n progressive-delivery-lab --to-revision=1
   ```
   *Expected Output:*
   ```text
   rollout 'catalog-service' rolled back to revision 1
   ```

---

### Module 4 Comprehension Check

**Question 4.1**: If a database column `user_address` is renamed to `shipping_address` during a deployment, explain why running an `ALTER TABLE users RENAME COLUMN user_address TO shipping_address;` script before initiating a Canary rollout will cause outage for the stable pods. Describe the correct multi-phase pattern.

**Question 4.2**: What is the difference in behavior between `kubectl argo rollouts abort` and `kubectl argo rollouts undo`?

---

## Official Documentation & References

- **Argo Rollouts Documentation**: [https://argoproj.github.io/argo-rollouts/](https://argoproj.github.io/argo-rollouts/)
- **Argo Rollouts Architecture & Concepts**: [https://argoproj.github.io/argo-rollouts/architecture/](https://argoproj.github.io/argo-rollouts/architecture/)
- **Istio Traffic Management Rules**: [https://istio.io/latest/docs/concepts/traffic-management/](https://istio.io/latest/docs/concepts/traffic-management/)
- **CNCF Curriculum Repository**: [https://github.com/cncf/curriculum](https://github.com/cncf/curriculum)
- **Flagger Progressive Delivery Operator**: [https://flagger.app/](https://flagger.app/)

---

<details>
<summary><strong>Click here to display the Answer Key & Detailed Explanations</strong></summary>

### Answer Key

#### Module 1 Solutions

**Answer 1.1**:  
Standard Kubernetes `Deployment` resources rely on endpoints provided by the `EndpointSlice` controller. Traffic balancing across pods behind a standard Kubernetes `Service` is done via round-robin or IPVS/iptables equal probability rules across all active pod IPs. If an application runs 3 replicas of Version 1 (v1) and introduces 1 canary pod of Version 2 (v2), the resulting traffic distribution is strictly `1 / (3 + 1) = 25%`. Achieving a 1% canary allocation using native deployment pod ratios would require spinning up 99 v1 pods and 1 v2 pod, creating massive resource waste. Custom progressive delivery controllers solve this by configuring weighted routing rules at the network layer (Ingress / Service Mesh) independent of pod counts.

**Answer 1.2**:  
In an Istio-backed progressive delivery setup, the Argo Rollouts (or Flagger) controller directly intercepts and mutates the Istio `VirtualService` resource spec (updating the `weight` values for the respective `DestinationRule` subsets). This leaves the underlying Kubernetes `Service` selectors unchanged (pointing to the shared app label), shifting traffic at the Envoy proxy level in the sidecar/gateway before requests ever reach pod network interfaces.

---

#### Module 2 Solutions

**Answer 2.1**:  
When service mesh integration is **not** used, Argo Rollouts performs traffic switching by modifying the `spec.selector` field of the active and preview Kubernetes `Service` resources. Before promotion, `payments-active` service selector points to `rollouts-pod-template-hash: <stable-hash>` while `payments-preview` points to `rollouts-pod-template-hash: <preview-hash>`. During promotion, the controller updates `payments-active` selector to point to `<preview-hash>`, instantly redirecting standard Kubernetes service traffic to the new ReplicaSet.

**Answer 2.2**:  
If `prePromotionAnalysis` fails:
1. The `AnalysisRun` transitions to state `Failed`.
2. The Rollout controller marks the rollout status as `Degraded`.
3. Traffic routing remains 100% directed to `payments-active` (the stable ReplicaSet). Zero production traffic is exposed to the preview pods.
4. Depending on configuration (`scaleDownDelaySeconds`), the preview ReplicaSet is scaled down to 0 replicas.
5. The rollout enters a paused/aborted state, requiring developer intervention or a git rollback.

---

#### Module 3 Solutions

**Answer 3.1**:  
In Istio Traffic Mirroring (`mirror`), requests are duplicated asynchronously. The client receives the response generated by the primary (stable) route, while the response generated by the mirrored (canary) destination is **completely discarded**.  
*Operational Risk*: Mirrored requests execute real business logic on the canary pods. If the application performs non-idempotent side effects (e.g., executing SQL `INSERT` commands, publishing Kafka events, sending emails, processing payments), the mirrored request will execute those operations a second time. To prevent corruption, mirrored targets must be executed against mocked endpoints, shadowed databases, or idempotent transaction layers.

**Answer 3.2**:  
The `failureLimit` parameter defines how many consecutive or cumulative failed metric evaluation intervals are permitted before the entire `AnalysisRun` is marked as `Failed`. For instance, if Prometheus suffers a temporary network timeout or a single transient 5xx spike occurs within a 10-second polling window, setting `failureLimit: 3` prevents a single bad metric data point from triggering a false-positive automated rollback.

---

#### Module 4 Solutions

**Answer 4.1**:  
Executing an immediate `ALTER TABLE users RENAME COLUMN user_address TO shipping_address;` breaks backward compatibility. Because stable pods (v1) and canary pods (v2) run simultaneously during progressive delivery, v1 pods will instantly crash when attempting to query the non-existent `user_address` column.  
*Correct Expand-Contract Pattern*:
1. **Expand**: Add `shipping_address` as a new nullable column alongside `user_address`. Deploy v2 code (canary) which writes to both columns but falls back to reading `user_address`.
2. **Backfill**: Run a background data migration job copying data from `user_address` to `shipping_address`.
3. **Contract Phase A**: Deploy v3 code which exclusively reads and writes `shipping_address`.
4. **Contract Phase B**: After all old revisions are fully retired, run a final schema migration dropping the legacy `user_address` column.

**Answer 4.2**:  
- `kubectl argo rollouts abort`: Immediately halts an in-progress canary or blue/green rollout and shifts 100% of network traffic back to the stable ReplicaSet revision. However, it leaves the Rollout resource in an `Aborted`/`Degraded` state and does **not** modify the underlying `spec.template` container image in the git/manifest specification.
- `kubectl argo rollouts undo`: Performs an explicit rollback to a previous revision (similar to `kubectl rollout undo`). It rewrites the Rollout's `spec.template` to match the target revision hash, triggering a clean, new reconciliation cycle that moves the system back to a known-good state.

</details>