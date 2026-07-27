# 3.3 Configure workload autoscaling

## Introduction

Workload autoscaling in Kubernetes enables dynamically adjusting Pod replica counts (horizontal scaling) or container `resources.requests`/`limits` (vertical scaling) based on real-time application demand without manual intervention. The CKA exam targets hands-on proficiency with the native **Horizontal Pod Autoscaler (HPA)**, as well as conceptual understanding of the **Vertical Pod Autoscaler (VPA)** project (`kubernetes/autoscaler`), which is maintained as an optional add-on.

Both mechanisms rely on metric pipeline sources — typically **metrics-server**, which exposes the `metrics.k8s.io` API using raw metrics gathered from cAdvisor/kubelet agents.

## Horizontal Pod Autoscaler (HPA)

### How HPA Works

The HPA is a control loop executing inside `kube-controller-manager`. During periodic evaluation cycles (`--horizontal-pod-autoscaler-sync-period`, default 15s), it queries metrics targeting a scalable resource (Deployment, ReplicaSet, or StatefulSet) and adjusts `spec.replicas` using the formula:

```
desiredReplicas = ceil[ currentReplicas * ( currentMetricValue / desiredMetricValue ) ]
```

Prerequisites:
- **metrics-server** (or custom metric adapters for `custom.metrics.k8s.io`/`external.metrics.k8s.io`) must be installed and healthy.
- Target Pod containers must explicitly declare `resources.requests.cpu` (and/or `memory`), as target utilization percentages calculate relative to requested capacity, not limit caps.

### Imperative HPA Creation

```bash
kubectl autoscale deployment web --cpu-percent=50 --min=2 --max=10
```

```
horizontalpodautoscaler.autoscaling/web autoscaled
```

### Declarative Definition (`autoscaling/v2`)

While `autoscaling/v1` supports CPU metrics only, `autoscaling/v2` supports memory metrics, custom/external metrics, and granular scaling `behavior` rules:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
```

### Fine-Tuning Scaling `behavior`

Custom scaling behaviors prevent metric oscillation (*flapping*) by constraining scaling velocities:

```yaml
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Pods
        value: 4
        periodSeconds: 60
      selectPolicy: Max
```

- `stabilizationWindowSeconds`: Time window evaluating historical metrics to select conservative values before executing scale operations (essential on `scaleDown` to smooth temporary traffic dips).
- `policies`: Limits scaling steps per period (`Pods` = absolute count, `Percent` = percentage).
- `selectPolicy`: `Max` (default for scaleUp), `Min`, or `Disabled`.

### Verification

```bash
kubectl get hpa web-hpa
```

```
NAME      REFERENCE      TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
web-hpa   Deployment/web cpu: 23%/50%       2         10        3          5m
```

```bash
kubectl describe hpa web-hpa
```

Displays event history (`SuccessfulRescale`) and common error events:

```
Warning  FailedGetResourceMetric  horizontal-pod-autoscaler  missing request for cpu
```

If metrics-server is unreachable, `TARGETS` reports `<unknown>/50%`.

### Custom and External Metrics

Beyond `Resource` metrics (CPU/memory via metrics-server), `autoscaling/v2` supports:
- `Pods`: Per-pod average metrics exposed via `custom.metrics.k8s.io` (e.g. HTTP requests per second via `prometheus-adapter`).
- `Object`: Metrics describing distinct Kubernetes objects (e.g. `Ingress` queue depth).
- `External`: Metrics describing external systems outside the cluster via `external.metrics.k8s.io` (e.g. cloud message queues).

```yaml
  metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"
```

## Vertical Pod Autoscaler (VPA)

The VPA is **not part of core Kubernetes**; it is an add-on from the [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) repository. Rather than scaling replica counts, VPA adjusts container `requests`/`limits` dynamically based on historical resource consumption.

VPA Components:
- **Recommender**: Analyzes CPU/memory utilization to calculate recommended resource allocations.
- **Updater**: Evicts Pods that deviate from recommendations (when `updateMode` permits) to trigger container re-creation with updated specs.
- **Admission Controller**: Intercepts Pod creation requests and injects recommended `resources` via mutating webhooks.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: web-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  updatePolicy:
    updateMode: "Auto"
```

`updateMode` options:
- `Off`: Generates recommendations (`kubectl describe vpa`) without applying changes.
- `Initial`: Applies recommendations strictly during initial Pod creation.
- `Recreate` / `Auto`: Evicts existing Pods to apply updated resource values (`Auto` can leverage in-place resource resizing when supported).

```bash
kubectl describe vpa web-vpa
```

```
Recommendation:
  Container Recommendations:
    Container Name: web
    Target:
      Cpu:     250m
      Memory:  256Mi
```

**Exam Note**: Avoid configuring HPA and VPA targeting the **same resource metric** (CPU or memory) on identical workloads, as both controllers compete to adjust resource parameters. Using HPA for custom/external metrics alongside VPA for CPU/memory is supported.

## metrics-server

Required for both `kubectl top` and `Resource`-based HPA scaling.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -n default
```

```
NAME     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
node-1   145m         7%     1204Mi          31%
```

Sandbox cluster setups using self-signed kubelet certificates frequently require adding `--kubelet-insecure-tls` to the metrics-server Deployment.

## Cluster Autoscaler Context

Unlike HPA and VPA, the **Cluster Autoscaler** adjusts host node counts rather than Pods, adding or terminating node instances when Pods enter `Pending` state due to node resource deficits. Configuration depends on cloud infrastructure providers rather than standard Kubernetes API objects, so exam coverage focuses on concepts rather than hands-on tasks.

## Troubleshooting Common Issues

| Symptom | Common Cause |
|---|---|
| `kubectl get hpa` reports `<unknown>/50%` | metrics-server uninstalled or lacking kubelet connectivity |
| HPA fails to scale under high CPU loads | Target container omits `resources.requests.cpu` definitions |
| VPA fails to update Pod specs | `updateMode: Off` set or admission controller uninstalled |
| Replica counts oscillate rapidly | `stabilizationWindowSeconds` on `scaleDown` omitted or window too small |

## References

- Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- HorizontalPodAutoscaler Walkthrough: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/
- HPA API Reference (autoscaling/v2): https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#horizontalpodautoscaler-v2-autoscaling
- kubectl autoscale reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#autoscale
- Vertical Pod Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- metrics-server: https://github.com/kubernetes-sigs/metrics-server
- Cluster Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
