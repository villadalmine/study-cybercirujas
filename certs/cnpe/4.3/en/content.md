# CNPE Exam Study Guide
## Module 4: Application Deployment & Lifecycle Management
### Topic 4.3: Deploying Applications Using Progressive Delivery Strategies (Blue/Green & Canary)
**Exam Weight:** 8.34%  
**Target Role:** Principal Platform Architect / Senior SRE  

---

### 1. Production Motivation & Architectural Problem Statement

#### 1.1 The Failure Modes of Native Kubernetes Deployments
The native Kubernetes `Deployment` workload resource manages application upgrades using two primitive strategies: `Recreate` and `RollingUpdate`.

```
1. Recreate Strategy:
   [v1 Pods] ---> Terminate All ---> [Downtime Window] ---> Provision [v2 Pods]

2. Native RollingUpdate Strategy:
   [v1 Pods: 100%] ──> Surge v2 Pods ──> [v1: 75% | v2: 25%] ──> [v1: 50% | v2: 50%] ──> [v2: 100%]
                                             │
                                             └──> 25% of Live Traffic Immediately Exposed to Unverified v2
```

* **`Recreate` Failure Mode:** Completely terminates all existing replicas (`v1`) before spinning up new replicas (`v2`). This incurs a guaranteed service outage window proportional to pod boot time and readiness initialization.
* **`RollingUpdate` Uncontrolled Blast Radius:** The `RollingUpdate` controller scales down `v1` ReplicaSets while scaling up `v2` ReplicaSets according to `maxSurge` and `maxUnavailable`. If an application binary contains a latent bug (e.g., thread pool exhaustion under concurrency, memory leaks, or corrupted database query logic), **10% to 25% of live customer traffic is instantly exposed to `v2` on the first replica swap**.
* **The Blindness of Readiness Probes:** Kubernetes `readinessProbes` evaluate static, synthetic conditions (e.g., HTTP `200 OK` on `/healthz` or TCP socket connection). They **cannot** observe runtime performance regressions such as elevated P99 latency, downstream HTTP 5xx error spikes, database connection pool saturation, or degraded business metrics (e.g., drop in checkout conversions).
* **High MTTR on Manual Aborts:** If `v2` passes readiness checks but fails under production traffic load, rolling back a standard `Deployment` requires human detection (alert triage), manual CLI intervention (`kubectl rollout undo`), and waiting for a reverse `RollingUpdate` cycle. This leads to an unacceptable Mean Time to Recovery (MTTR).

#### 1.2 The Architecture of Progressive Delivery
Progressive Delivery extends Continuous Delivery by combining **fine-grained L4/L7 traffic management** with **automated telemetry analysis** to orchestrate metric-guided rollouts and instant automated rollbacks.

```
                    ┌──────────────────────────────────────────────┐
                    │               Ingress / Mesh                 │
                    │        (Istio / Envoy / NGINX)               │
                    └───────┬──────────────────────────────┬───────┘
                            │                              │
                    90% Traffic                        10% Traffic
                            │                              │
                            ▼                              ▼
                 ┌──────────────────────┐      ┌──────────────────────┐
                 │    Stable Service    │      │    Canary Service    │
                 └──────────┬───────────┘      └──────────┬───────────┘
                            │                             │
                            ▼                             ▼
                 ┌──────────────────────┐      ┌──────────────────────┐
                 │  v1 ReplicaSet Pods  │      │  v2 ReplicaSet Pods  │
                 └──────────────────────┘      └──────────────────────┘
                                                          ▲
                                                          │
                                         Prometheus Metrics Continuous Query
                                         (P99 Latency < 100ms, Error Rate < 0.5%)
                                                          │
                                             ┌────────────┴───────────┐
                                             │ Argo Rollouts Controller│
                                             └────────────────────────┘
```

The system operates on three architectural primitives:
1. **Blast Radius Minimization:** New revisions receive a tightly controlled traffic weight (e.g., 1%, 5%, 10%) regardless of pod replica count.
2. **Automated Telemetry Analysis:** Continuous monitoring of Service Level Indicators (SLIs) comparing baseline (`v1`) versus canary (`v2`) metrics using statistical thresholds.
3. **Automated Zero-Touch Rollback:** Immediate restoration of 100% traffic weight to `v1` within seconds if canary telemetry violates defined SLO guardrails during any evaluation step.

---

### 2. Deep Technical Trade-Off & Strategy Comparison

#### 2.1 Strategy Comparison Matrix

| Evaluation Dimension | Recreate | RollingUpdate | Blue/Green (Active/Preview) | Canary (Step-based) | Metric-Driven Canary (Automated) | Shadow / Traffic Mirroring |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Blast Radius** | 100% (Total Outage) | High (20-50% of Users) | High at Cutover (100% Instant Shift) | Low (Tolerable % Shift) | **Minimal (1-5% Incremental)** | **Zero (Read-Only Copy)** |
| **Instant Rollback Speed** | Slow (Re-provision `v1`) | Slow (Reverse `RollingUpdate`) | **Instant (< 1s via L7/Service Switch)** | Fast (Shift Weight back to `v1`) | **Instant Automated (< 1s)** | N/A (No Live User Traffic) |
| **Infrastructure Compute Cost** | Baseline (100%) | Temporary Overhead (100% + `maxSurge`) | **100% Duplicate (200% Capacity)** | Dynamic Overhead (100% + Canary Replica Count) | Dynamic Overhead (100% + Canary Replica Count) | **100% Duplicate (200% Capacity)** |
| **Traffic Control Layer** | K8s Pod Lifecycle | K8s Pod Lifecycle | Service Selector / L7 Ingress | L7 Ingress / Service Mesh | **L7 Ingress / Service Mesh** | L7 Service Mesh (Envoy `shadow`) |
| **Database Schema Constraint** | Non-breaking / Breaking | Must be Backward Compatible | **Strictly Backward/Forward Compatible** | **Strictly Backward Compatible** | **Strictly Backward Compatible** | Must Handle Duplicate Writes / Dual Schema |
| **Observability Overhead** | None | Low (Manual Metric Checks) | Low (Manual Validation on Preview) | Medium (Manual Dashboard Review) | **High (PromQL Analysis Templates)** | High (Async Response Drops / Tracing) |

#### 2.2 Traffic Routing Mechanics: L4 (Pod Replica Ratio) vs. L7 (Proxy Weighting)

##### Layer 4 Traffic Shifting (Standard Kubernetes Service)
When using standard Kubernetes `Services`, traffic distribution relies on `kube-proxy` iptables/IPVS rules across endpoints. 
$$\text{Traffic Weight}_{\text{Canary}} = \left( \frac{\text{Replicas}_{\text{Canary}}}{\text{Replicas}_{\text{Stable}} + \text{Replicas}_{\text{Canary}}} \right) \times 100$$
* **Drawbacks:** To send 1% of traffic to a canary, you must run at least 99 stable pods and 1 canary pod (or 100 total pods). L4 routing cannot inspect HTTP request headers, query parameters, or JWT claims.

##### Layer 7 Traffic Shifting (Service Mesh / Ingress Controllers)
L7 routing (via Istio, Envoy, or NGINX Ingress) decouples the **traffic splitting weight** from the **pod replica count**.

```
Client Request ──> Envoy Proxy (Istio Ingress Gateway)
                        │
                        ├─── Header: "X-Canary: Tester" ───> 100% to v2 Pods
                        │
                        └─── Weighted Route Rules:
                                ├─── Weight: 95% ──────────> v1 Pods (Stable)
                                └─── Weight: 5%  ──────────> v2 Pods (Canary)
```

L7 proxying enables:
* Exact percentage splits (e.g., 1% weight sent to 1 canary pod, while 10 stable pods process 99% weight).
* Synthetic traffic routing based on HTTP headers (e.g., `X-Canary: true`), request cookies, or client IP ranges for internal pre-canary validation.

---

### 3. Production-Grade Kubernetes Manifests

The following manifests construct a production-ready Progressive Delivery architecture using **Argo Rollouts**, **Istio Service Mesh**, and **Prometheus Analysis**.

#### 3.1 Namespace & Service Infrastructure setup (`infrastructure.yaml`)
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service-stable
  namespace: production
  labels:
    app: payment-service
    tier: api
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    app: payment-service
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service-canary
  namespace: production
  labels:
    app: payment-service
    tier: api
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    app: payment-service
```

#### 3.2 Istio Traffic Routing Manifests (`istio-networking.yaml`)
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: payment-gateway
  namespace: production
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "payment.api.internal"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: payment-service-virtualservice
  namespace: production
spec:
  hosts:
    - "payment.api.internal"
  gateways:
    - payment-gateway
  http:
    - name: primary-route
      route:
        - destination:
            host: payment-service-stable
            port:
              number: 8080
          weight: 100
        - destination:
            host: payment-service-canary
            port:
              number: 8080
          weight: 0
```

#### 3.3 Prometheus Analysis Template (`analysis-template.yaml`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: payment-success-rate-and-latency
  namespace: production
spec:
  metrics:
    - name: success-rate
      interval: 30s
      successCondition: result[0] >= 0.995
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(istio_requests_total{reporter="destination",destination_service_name="payment-service-canary",response_code!~"5.*"}[2m]))
            /
            sum(rate(istio_requests_total{reporter="destination",destination_service_name="payment-service-canary"}[2m]))
    - name: p99-latency
      interval: 30s
      successCondition: result[0] <= 0.150
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service_name="payment-service-canary"}[2m])) by (le)) / 1000
```

#### 3.4 Complete Argo Rollout Workload (`rollout.yaml`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service
  namespace: production
  labels:
    app: payment-service
    tier: api
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: payment-service
  strategy:
    canary:
      canaryService: payment-service-canary
      stableService: payment-service-stable
      trafficRouting:
        istio:
          virtualService:
            name: payment-service-virtualservice
            routes:
              - primary-route
      analysis:
        templates:
          - templateName: payment-success-rate-and-latency
        args:
          - name: service-name
            value: payment-service-canary
      steps:
        - setWeight: 5
        - pause: { duration: 10m }
        - setWeight: 20
        - pause: { duration: 30m }
        - setWeight: 50
        - pause: { duration: 1h }
  template:
    metadata:
      labels:
        app: payment-service
        tier: api
    spec:
      containers:
        - name: payment-api
          image: registry.internal.net/finance/payment-api:v2.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2000m"
              memory: "2Gi"
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
```

---

### 4. CLI Commands & Realistic Terminal Logs

#### 4.1 Applying Manifests & Deploying Revision `v2.4.0`
```bash
$ kubectl apply -f infrastructure.yaml -f istio-networking.yaml -f analysis-template.yaml -f rollout.yaml
namespace/production unchanged
service/payment-service-stable created
service/payment-service-canary created
gateway.networking.istio.io/payment-gateway created
virtualservice.networking.istio.io/payment-service-virtualservice created
analysistemplate.argoproj.io/payment-success-rate-and-latency created
rollout.argoproj.io/payment-service created
```

#### 4.2 Watching the Live Progressive Delivery Rollout
```bash
$ kubectl argo rollouts get rollout payment-service -n production --watch
```
```text
Name:            payment-service
Namespace:       production
Status:          ── Progressing
Message:         CanaryMeasuredReason: Step '0/6' set weight 5, step '1/6' paused 10m
Strategy:        Canary
  Step:          1/6 (pause: 10m)
  SetWeight:     5
  ActualWeight:  5
Images:          registry.internal.net/finance/payment-api:v2.4.0 (stable, canary)
Replicas:
  Desired:       10
  Current:       11
  Updated:       1
  Ready:         11
  Available:     11

NAME                                                  STATUS      COLOR  COST  AGE
├─┬ Revision 2                                        progressing        2m    12s
│ ├── payment-service-75b486984d-c4x9z                ready              2m    12s
│ └─┬ Metric: success-rate                            Successful               30s
│   └── 100% Successful metrics (1/1)
│ └─┬ Metric: p99-latency                             Successful               30s
│   └── 100% Successful metrics (1/1)
└─┬ Revision 1                                        stable             15d   8m
  ├── payment-service-68686d498b-2k4l9                ready              15d   8m
  ├── payment-service-68686d498b-59d48                ready              15d   8m
  ├── payment-service-68686d498b-8x92p                ready              15d   8m
  ├── payment-service-68686d498b-b7qtw                ready              15d   8m
  ├── payment-service-68686d498b-df8x1                ready              15d   8m
  ├── payment-service-68686d498b-f2s99                ready              15d   8m
  ├── payment-service-68686d498b-g9p21                ready              15d   8m
  ├── payment-service-68686d498b-m4k88                ready              15d   8m
  ├── payment-service-68686d498b-p3n71                ready              15d   8m
  └── payment-service-68686d498b-v8l12                ready              15d   8m
```

#### 4.3 Verifying VirtualService L7 Weight Distribution via Istio
```bash
$ kubectl get virtualservice payment-service-virtualservice -n production -o yaml
```
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-service-virtualservice
  namespace: production
spec:
  gateways:
  - payment-gateway
  hosts:
  - payment.api.internal
  http:
  - name: primary-route
    route:
    - destination:
        host: payment-service-stable
        port:
          number: 8080
      weight: 95
    - destination:
        host: payment-service-canary
        port:
          number: 8080
      weight: 5
```

#### 4.4 Triggering an Automated Rollback via Metric Violation
Simulate latency degradation on the canary revision (`v2.4.0`). The Prometheus `AnalysisRun` catches the breach:

```bash
$ kubectl argo rollouts get rollout payment-service -n production
```
```text
Name:            payment-service
Namespace:       production
Status:          deg Degraded
Message:         Rollout aborted update to revision 2: Metric 'p99-latency' failed 2 times
Strategy:        Canary
Images:          registry.internal.net/finance/payment-api:v2.3.9 (stable)
                 registry.internal.net/finance/payment-api:v2.4.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       0
  Ready:         10
  Available:     10

NAME                                                  STATUS      COLOR  COST  AGE
├─┬ Revision 2                                        aborted            4m    3m52s
│ ├── payment-service-75b486984d-c4x9z                terminating        2m    3m52s
│ └─┬ AnalysisRun: payment-service-75b486984d-2       Failed             3m10s
│   ├─┬ Metric: success-rate                          Successful               3m
│   │ └── 6/6 Successful metrics
│   └─┬ Metric: p99-latency                           Failed                   3m
│     └── 2/2 Failed metrics (Recent values: [0.245, 0.312])
└─┬ Revision 1                                        stable             15d   12m
  ├── payment-service-68686d498b-2k4l9                ready              15d   12m
  └── ... (10 pods ready)
```

#### 4.5 Manual Abort and Emergency Instant Rollback CLI Commands
```bash
# Force an immediate manual abort of an ongoing rollout
$ kubectl argo rollouts abort payment-service -n production
rollout 'payment-service' aborted

# Manually promote a rollout step (override pause)
$ kubectl argo rollouts promote payment-service -n production
rollout 'payment-service' promoted

# Completely retry a failed/aborted rollout revision
$ kubectl argo rollouts retry rollout payment-service -n production
rollout 'payment-service' retried
```

---

### 5. Verification & Diagnostic Runbook for SREs

#### 5.1 Failure Diagnostic Tree

```
Rollout Stuck / Failing
 ├── 1. Check Rollout Controller Logs
 │      └── kubectl logs -n argo-rollouts deployment/argo-rollouts -f
 ├── 2. Inspect AnalysisRun Resource
 │      ├── kubectl get analysisrun -n production
 │      └── kubectl describe analysisrun <analysis-run-name> -n production
 ├── 3. Verify L7 Route Synchronization
 │      ├── kubectl get virtualservice payment-service-virtualservice -o jsonpath='{.spec.http[0].route}'
 │      └── istioctl analyze -n production
 └── 4. Check Pod Level Errors
        ├── kubectl get pods -n production -l app=payment-service
        └── kubectl logs -n production -l app=payment-service -c payment-api --tail=100
```

#### 5.2 Scenario Diagnostics & Resolution Strategies

##### Scenario A: Intermittent HTTP 503 Errors During Traffic Shifting
* **Root Cause:** The `DestinationRule` or `VirtualService` configuration references a target service port that is not properly exposed by the `canaryService` or `stableService`, or Envoy proxy fails to update endpoints prior to scaling down old pods.
* **Diagnostic Step:**
  ```bash
  $ istioctl proxy-config endpoints payment-gateway.production --cluster "outbound|8080||payment-service-canary.production.svc.cluster.local"
  ```
* **Remediation:** Ensure `spec.strategy.canary.trafficRouting.istio.virtualService.routes` matches the exact route name inside the Istio `VirtualService`. Verify `prePromotionAnalysis` or `gracePeriodSeconds` is set to allow endpoint propagation across Envoy proxies.

##### Scenario B: AnalysisRun Fails Due to "No Data" or Prometheus Latency Spikes
* **Root Cause:** Metric label mismatch. The PromQL query uses static pod selectors that fail to isolate canary pods from stable pods, or query execution times out.
* **Diagnostic Step:** Describe the target `AnalysisRun` to extract raw PromQL execution responses.
  ```bash
  $ kubectl get analysisrun -n production -o wide
  $ kubectl describe analysisrun payment-service-75b486984d-2 -n production
  ```
  Look for `Status.MetricResults.Message`: `Error: query result is empty`.
* **Remediation:** Ensure the `AnalysisTemplate` queries metrics tagged with the specific destination service host (`payment-service-canary`) or dynamically injected pod template hash:
  ```promql
  sum(rate(http_requests_total{pod_template_hash="{{user.pod-template-hash}}", status=~"5.*"}[1m]))
  ```

##### Scenario C: Sticky Session Leakage Overriding L7 Traffic Splits
* **Root Cause:** High-layer HTTP load balancers or Ingress controllers configured with session affinity (e.g., `Cookie` or `IP` hashing) force users to stick to old or new pods, bypassing proxy percentage weight rules.
* **Diagnostic Step:** Inspect curl headers across consecutive requests:
  ```bash
  $ for i in {1..20}; do curl -I -s http://payment.api.internal/health | grep "Set-Cookie"; done
  ```
* **Remediation:** Strip session affinity cookies on the VirtualService canary route match block or utilize explicit cookie matching rules inside the `Rollout` strategy step list:
  ```yaml
  steps:
    - match:
        - headerName: X-Canary-Group
          headerValue:
            exact: QA-Testers
  ```

##### Scenario D: Database Schema Desynchronization (Breaking Schema Changes)
* **Root Cause:** Releasing `v2` canary pods that apply destructive database schema changes (e.g., dropping a column or renaming a field) instantly breaks active `v1` stable pods running concurrently.
* **Architectural Rule:** **Always decouple Schema Migrations from Application Deployment using the Expand-Contract (Parallel Change) Pattern.**

```
Phase 1 (Expand): 
Database supports both old and new schema. Add new column NULLABLE.
v1 Application writes to Column A.
v2 Canary Application writes to Column A AND Column B.

Phase 2 (Migrate Data): 
Backfill historical data from Column A to Column B via async background job.

Phase 3 (Contract): 
After v2 is 100% stable, deploy v3 which reads ONLY from Column B.
Drop Column A in a future, isolated migration script.
```

---

### 6. References

* **CNCF Curriculum:** [CNCF Certified Cloud Native Platform Engineer (CNPE) Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* **Argo Rollouts Documentation:** [Argo Rollouts - Progressive Delivery for Kubernetes](https://argoproj.github.io/argo-rollouts/)
* **Flagger Documentation:** [Flagger - Progressive Delivery Operator for Kubernetes](https://flagger.app/)
* **Istio Traffic Management:** [Istio Traffic Management Concepts](https://istio.io/latest/docs/concepts/traffic-management/)
* **Kubernetes Deployment Strategies:** [Kubernetes Deployments Specification](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
* **Prometheus Query Language Reference:** [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)