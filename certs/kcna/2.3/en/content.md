# 2.3 Observability

## Introduction

**Observability** is the ability to understand the internal state of a system from its external outputs. In cloud native systems, where applications are composed of dozens or hundreds of microservices distributed across ephemeral containers, observability is no longer a "nice to have" but becomes an operational necessity: without it, it is impossible to debug failures, understand latencies, or plan capacity.

It is often distinguished from **monitoring**: monitoring tells you *that something is wrong* (based on predefined dashboards and alerts), while observability gives you the tools to *investigate why* something is wrong, even for failures you never anticipated.

Observability traditionally relies on three pillars:

| Pillar | What it captures | Question it answers |
|---|---|---|
| **Metrics** | Numerical series over time (CPU, requests/sec, latency) | "How often does this happen?" |
| **Logs** | Discrete events with context (timestamp, message) | "What exactly happened?" |
| **Traces** | The path of a request across multiple services | "Where did the latency/error originate?" |

## Metrics and Prometheus

**Prometheus** is the CNCF reference project (second graduated, after Kubernetes) for metrics in cloud native environments.

Key characteristics:

- **Multi-dimensional** data model: each metric is a time series identified by a name and a set of key-value pairs called **labels**.
- **Pull-based**: Prometheus scrapes (polls) HTTP endpoints in `/metrics` format instead of apps pushing data to it.
- Native **service discovery** for Kubernetes: discovers Pods, Services and Endpoints automatically via the Kubernetes API.
- Own query language: **PromQL**.
- **AlertManager** as a separate component to deduplicate, group and route alerts.

Example of a metric exposed by an app (Prometheus format):

```
# HELP http_requests_total Total HTTP requests received
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 1547
http_requests_total{method="POST",status="500"} 12
```

Example of a PromQL query to calculate the request rate per second over the last 5 minutes:

```promql
rate(http_requests_total[5m])
```

Metric types in Prometheus:

- **Counter**: value that only increases (e.g., total requests).
- **Gauge**: value that goes up and down (e.g., current memory usage).
- **Histogram**: distribution of values into buckets (e.g., request latency).
- **Summary**: similar to histogram, but calculates quantiles on the client side.

To expose metrics from components that do not natively generate them (nodes, databases, hardware), **exporters** are used, such as `node_exporter` (operating system metrics) or `kube-state-metrics` (state of Kubernetes objects: Deployments, Pods, etc.).

## Visualization: Grafana

**Grafana** is the standard tool for building dashboards from data sources such as Prometheus, Loki or Elasticsearch. It does not store data: it queries external sources and renders them. It allows defining visual alerts and is data-source agnostic, making it the natural complement to Prometheus within the CNCF stack.

## Health checks in Kubernetes (probes)

Kubernetes uses **probes** to determine the health status of a container and act accordingly. They are a fundamental part of observability because they allow the system to self-remediate without human intervention:

- **Liveness probe**: if it fails, Kubernetes **restarts** the container. Detects "hung" processes (deadlocks).
- **Readiness probe**: if it fails, the Pod is **removed from the Service** (stops receiving traffic) but is not restarted. Indicates whether the container is ready to handle requests.
- **Startup probe**: used in apps with slow startup; disables liveness/readiness until the app finishes starting, preventing premature restarts.

Example manifest with all three probes:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-app
spec:
  containers:
  - name: app
    image: myapp:1.0
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 15
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      periodSeconds: 5
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10
```

Useful commands to inspect health status:

```bash
kubectl get pods
# NAME      READY   STATUS    RESTARTS   AGE
# web-app   0/1     Running   3          5m   <- readiness fails, restarts due to liveness

kubectl describe pod web-app
# ... Events:
#   Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500
```

## Logging

Logs in Kubernetes are ephemeral by nature: when a Pod dies, its local logs are lost. The standard pattern is to centralize them with an **EFK/ELK** stack (Elasticsearch/Fluentd/Fluent Bit + Kibana) or the native Prometheus stack, **Grafana Loki** (indexes only metadata/labels, not full text, making it lighter).

- **Fluentd** / **Fluent Bit**: agents that run as a **DaemonSet** on each node, collect logs from `/var/log` (or via the container runtime) and forward them to a centralized backend.
- **Loki**: designed to integrate with Grafana and use the same label model as Prometheus.

Basic command to view logs of a Pod (debugging level, does not replace centralization):

```bash
kubectl logs web-app -c app --previous   # logs from the previous container after a crash
```

## Distributed Tracing

In a microservices architecture, a single user request can traverse dozens of services. **Distributed tracing** allows reconstructing that end-to-end path using a **trace**, composed of multiple **spans** (each span represents a unit of work, e.g., a call to a service or database).

Reference tools in the CNCF ecosystem:

- **Jaeger**: a CNCF graduated project, originated at Uber, for distributed tracing.
- **OpenTelemetry (OTel)**: a CNCF project that unifies **instrumentation** (generation of metrics, logs, and traces) under a single vendor-neutral standard, with SDKs per language and a central component, the **OTel Collector**, which receives, processes and exports telemetry to different backends (Prometheus, Jaeger, Loki, etc.). OpenTelemetry is the result of merging OpenTracing and OpenCensus and is today the recommended standard over instrumenting each pillar separately.

## Other considerations

- **Cost monitoring**: observability also covers cost visibility in cloud native environments (e.g., **Kubecost**), allowing infrastructure spend to be attributed to namespaces, Deployments, or teams.
- The KCNA exam expects you to recognize which tool corresponds to which pillar (Prometheus → metrics, Fluentd/Loki → logs, Jaeger/OTel → traces) and the role of probes as a Kubernetes self-healing mechanism.

## References

- KCNA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes – Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes – Logging Architecture: https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Prometheus – Documentation: https://prometheus.io/docs/introduction/overview/
- Prometheus – Metric Types: https://prometheus.io/docs/concepts/metric_types/
- Grafana – Documentation: https://grafana.com/docs/grafana/latest/
- Grafana Loki – Documentation: https://grafana.com/docs/loki/latest/
- OpenTelemetry – Documentation: https://opentelemetry.io/docs/
- Jaeger – Documentation: https://www.jaegertracing.io/docs/latest/
- CNCF – Cloud Native Interactive Landscape (Observability & Analysis): https://landscape.cncf.io/