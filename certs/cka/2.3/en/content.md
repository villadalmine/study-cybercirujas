# 2.3 Monitor Cluster and Application Resource Usage

## Introduction

Monitoring resource utilization forms the foundation for capacity planning, bottleneck detection, and diagnosing performance degradation across a Kubernetes cluster. Unlike full monitoring solutions like Prometheus/Grafana (which fall outside the direct scope of the CKA exam), the exam focuses on **native** tools exposed directly by Kubernetes: **Metrics Server**, the **Metrics API** (`metrics.k8s.io`), the `kubectl top` command line utility, and resource inspection via `kubectl describe`.

Understanding the distinction between metric pipelines is essential:

- **Resource Metrics Pipeline**: Real-time CPU/memory metrics, aggregated with short retention windows (seconds/minutes). Provided by **Metrics Server**. Consumed by `kubectl top` and the **Horizontal Pod Autoscaler (HPA)**.
- **Full Metrics Pipeline**: Historical time-series metrics supporting multi-dimensional custom/external metrics. Supplied by third-party solutions (e.g. Prometheus). Optional for basic cluster operations, but required for long-term historical analysis.

The CKA exam targets the Resource Metrics Pipeline.

## Resource Metrics Pipeline Architecture

```
kubelet (embedded cAdvisor)
   │  exposes /stats/summary per node
   ▼
Metrics Server (scrapes each kubelet every ~15s)
   │  aggregates and exposes via Metrics API
   ▼
metrics.k8s.io (API aggregation layer)
   │
   ├── kubectl top nodes / kubectl top pods
   └── Horizontal Pod Autoscaler (HPA)
```

Key points:

- **kubelet** embeds **cAdvisor**, which collects container-level CPU, memory, network, and filesystem utilization stats.
- **Metrics Server** does not store historical trends: it retains only the latest sample in memory.
- Metrics Server registers as an API extension via an `APIService` bound to `metrics.k8s.io/v1beta1`.

## Installing and Verifying Metrics Server

In standard clusters (kubeadm, minikube without addons, kind), Metrics Server **is not installed by default**. Without it, `kubectl top` fails.

Standard installation (official manifest):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verify pod execution:

```bash
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-6764bf875c-9j4kv   1/1     Running   0          2m
```

Verify API service registration:

```bash
kubectl get apiservices | grep metrics
```

```
v1beta1.metrics.k8s.io   kube-system/metrics-server   True   3m
```

If `AVAILABLE` reports `False`, sandbox clusters (kubeadm/kind with self-signed node certificates) frequently fail TLS validation. The common workaround for sandbox/lab environments (**not for production**) patches `--kubelet-insecure-tls` onto the Deployment:

```bash
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Diagnostic troubleshooting:

```bash
kubectl logs -n kube-system deploy/metrics-server
kubectl describe apiservice v1beta1.metrics.k8s.io
```

## Real-Time Monitoring with `kubectl top`

### Node Level

```bash
kubectl top nodes
```

```
NAME           CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
node-worker1   312m         15%    1204Mi           31%
node-worker2   890m         44%    2867Mi           73%
control-plane  210m         10%    980Mi            25%
```

Identifies **node pressure** prior to kubelet pod evictions (`MemoryPressure`, `DiskPressure`, `PIDPressure`).

### Pod Level

```bash
kubectl top pods
```

```
NAME                       CPU(cores)   MEMORY(bytes)
frontend-7d4b6c9f7-k2xqp   5m           18Mi
backend-6f8c5d9b7-mzt2r    120m         256Mi
```

Inspect specific namespaces or all namespaces:

```bash
kubectl top pods -n production
kubectl top pods --all-namespaces
```

Break down utilization per container within multi-container Pods:

```bash
kubectl top pods --containers
```

```
POD                        NAME       CPU(cores)   MEMORY(bytes)
backend-6f8c5d9b7-mzt2r    app        110m         240Mi
backend-6f8c5d9b7-mzt2r    envoy      10m          16Mi
```

Sort by resource utilization:

```bash
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
kubectl top nodes --sort-by=memory
```

> Note: Newly created pods may return `error: metrics not available yet` until kubelet reports initial scrape intervals (~1 minute).

## Resource Requests and Limits Comparison

`kubectl top` output becomes actionable when compared against declared `PodSpec` parameters:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"
```

- **requests**: Used by `kube-scheduler` for node placement (bin-packing). Defines minimum guaranteed capacity.
- **limits**: Enforced by kubelet/runtime via cgroups. Exceeding memory limits triggers container **OOMKilled** terminations (Exit Code 137). Exceeding CPU limits triggers container **throttling** (CPU execution cycles throttled without container termination).

Inspect declared requests/limits:

```bash
kubectl describe pod backend-6f8c5d9b7-mzt2r
```

```
Limits:
  cpu:     250m
  memory:  256Mi
Requests:
  cpu:     100m
  memory:  128Mi
```

Comparing declarations against `kubectl top pods --containers` highlights:

- **Over-provisioning**: Excessive resource requests vs real usage (wasted cluster capacity).
- **Under-provisioning / OOMKill risks**: Usage nearing or exceeding memory limits.
- **Silent CPU throttling**: Pod remains operational but suffers latency because CPU limits are constrained.

## Quality of Service (QoS) Classes and Eviction Priority

Kubernetes assigns a **QoS Class** to each Pod based on container resource definitions, establishing eviction priority under `MemoryPressure`:

| QoS Class    | Condition                                                   | Eviction Priority |
|--------------|--------------------------------------------------------------|-------------------|
| `Guaranteed` | requests == limits for CPU and memory across all containers  | Last to be evicted |
| `Burstable`  | At least one container specifies requests without meeting Guaranteed criteria | Medium priority |
| `BestEffort` | No requests or limits specified across containers            | First to be evicted |

```bash
kubectl get pod backend-6f8c5d9b7-mzt2r -o jsonpath='{.status.qosClass}'
```

```
Burstable
```

Under node `MemoryPressure`, `BestEffort` Pods suffer eviction first.

## Detecting OOMKilled Conditions and CPU Throttling

Diagnose containers terminated due to memory exhaustion:

```bash
kubectl describe pod backend-6f8c5d9b7-mzt2r
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Retrieve termination reason via JSONPath:

```bash
kubectl get pod backend-6f8c5d9b7-mzt2r -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

Inspect logs from the previous container instance:

```bash
kubectl logs backend-6f8c5d9b7-mzt2r --previous
```

## Cluster Events Inspection

Cluster events reveal underlying operational state (scheduling, image pulls, evictions, probe failures):

```bash
kubectl get events --sort-by='.lastTimestamp'
```

```
LAST SEEN   TYPE      REASON              OBJECT                          MESSAGE
2m          Warning   FailedScheduling    pod/backend-6f8c5d9b7-mzt2r     0/3 nodes are available: 3 Insufficient memory.
1m          Normal    Pulled              pod/backend-6f8c5d9b7-mzt2r     Container image already present on machine
30s         Warning   Evicted             pod/cache-7f9d8c6b5-abc12       The node was low on resource: memory.
```

Filter warning events or target specific workload objects:

```bash
kubectl get events --field-selector type=Warning
kubectl get events -n production --field-selector involvedObject.name=backend-6f8c5d9b7-mzt2r
```

## Node Conditions and Allocated Resources

```bash
kubectl describe node node-worker2
```

```
Conditions:
  Type             Status  Reason
  MemoryPressure   False   KubeletHasSufficientMemory
  DiskPressure     False   KubeletHasNoDiskPressure
  PIDPressure      False   KubeletHasSufficientPID
  Ready            True    KubeletReady

Allocatable:
  cpu:                3800m
  memory:              7205864Ki
```

The `Allocated resources` summary reports total committed requests and limits on the node, revealing whether a node is fully allocated for scheduling even if live utilization (`kubectl top`) appears low:

```
Allocated resources:
  Resource           Requests      Limits
  cpu                2100m (55%)   3400m (89%)
  memory             4096Mi (58%)  6144Mi (87%)
```

## Horizontal Pod Autoscaler (HPA) Integration

HPA queries the Resource Metrics Pipeline (`metrics.k8s.io`) to calculate scaling thresholds. Without an active Metrics Server, HPA cannot evaluate `cpu` or `memory` target metrics.

```bash
kubectl autoscale deployment backend --cpu-percent=70 --min=2 --max=6
kubectl get hpa
```

```
NAME      REFERENCE            TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
backend   Deployment/backend   45%/70%   2         6         2          5m
```

If `TARGETS` displays `<unknown>/70%`, Metrics Server is either unreachable or target container pods omit `requests.cpu` definitions (HPA computes target utilization relative to requested capacity, not limit caps).

## References

- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Resource Metrics Pipeline: https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- kubectl top reference: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#top
- Managing Resources for Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Node-pressure Eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- kubernetes-sigs/metrics-server: https://github.com/kubernetes-sigs/metrics-server
- Troubleshoot Clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
