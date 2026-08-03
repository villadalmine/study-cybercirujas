# Guided Exercises: Observability

These exercises require access to a Kubernetes cluster via `kubectl` (for example, one created with `minikube start` or `kind create cluster`) and, for exercises 4 and 5, `helm` installed.

## Exercise 1: Liveness and readiness probes

Health checks are the most basic observability mechanism at the Pod level: they tell the kubelet whether a container is alive and whether it is ready to receive traffic.

**Steps:**

1. Create a `liveness-demo.yaml` file with the following content:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: liveness-demo
spec:
  containers:
  - name: demo
    image: busybox
    args:
    - /bin/sh
    - -c
    - touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 5
      periodSeconds: 5
```

2. Apply the manifest:

```bash
kubectl apply -f liveness-demo.yaml
```

3. Watch the Pod status during the first minute:

```bash
kubectl get pod liveness-demo -w
```

4. After the container deletes `/tmp/healthy` (after 30 seconds), inspect the events:

```bash
kubectl describe pod liveness-demo
```

You will see an `Unhealthy` event followed by a `Killing` event and a container restart.

5. Confirm the restart count:

```bash
kubectl get pod liveness-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'
```

**Comprehension questions:**

- What action does the kubelet take when a liveness probe fails repeatedly, and how does it differ from the action taken when a readiness probe fails?
- Why is `initialDelaySeconds` important for applications with a long startup time?

---

## Exercise 2: Logs in multi-container Pods

A common pattern (sidecar) has more than one container per Pod, each with its own log stream.

**Steps:**

1. Create a file `multi-container.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi-log
spec:
  containers:
  - name: app
    image: busybox
    args: ["/bin/sh", "-c", "while true; do echo app-$(date +%s); sleep 5; done"]
  - name: sidecar
    image: busybox
    args: ["/bin/sh", "-c", "while true; do echo sidecar-$(date +%s); sleep 5; done"]
```

2. Apply the manifest and wait for the Pod to be `Running`:

```bash
kubectl apply -f multi-container.yaml
kubectl get pod multi-log
```

3. Try to view the logs without specifying a container:

```bash
kubectl logs multi-log
```

4. Now specify each container:

```bash
kubectl logs multi-log -c app
kubectl logs multi-log -c sidecar
```

5. Follow the logs in real time from one of the two containers:

```bash
kubectl logs multi-log -c app -f
```

Stop with `Ctrl+C` when you want to finish.

**Comprehension questions:**

- What happens when you run `kubectl logs` on a Pod with more than one container without using `-c`?
- Which command would you use to see the logs of a container that has restarted, corresponding to its previous execution?

---

## Exercise 3: Resource metrics with `kubectl top`

`kubectl top` depends on metrics-server, a component that aggregates CPU/memory metrics from cAdvisor (via kubelet) and exposes them through the Metrics API.

**Steps:**

1. If using minikube, enable the addon:

```bash
minikube addons enable metrics-server
```

2. Verify that the metrics-server Pod is running in `kube-system`:

```bash
kubectl get pods -n kube-system | grep metrics-server
```

3. Wait about a minute (metrics-server needs time to collect the first sample) and query node-level usage:

```bash
kubectl top nodes
```

4. Query Pod-level usage in the `default` namespace:

```bash
kubectl top pods
```

5. If the command fails with a "metrics not available yet" error, wait a few more seconds and retry.

**Comprehension questions:**

- Which component needs to be running in the cluster for `kubectl top` to work?
- Why is `kubectl top` not suitable for viewing historical CPU usage over the last 24 hours?

---

## Exercise 4: Prometheus and PromQL

Prometheus is the reference monitoring system in the cloud native ecosystem, with a pull-based collection model (scraping `/metrics` endpoints).

**Steps:**

1. Add the Helm repository from the Prometheus community:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

2. Install the stack (includes Prometheus, Alertmanager, and exporters):

```bash
helm install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

3. Wait for the Pods to be ready:

```bash
kubectl get pods -n monitoring -w
```

4. Port-forward to the Prometheus server:

```bash
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-stack-prometheus 9090:9090
```

5. Open `http://localhost:9090` in a browser and run this query in the "Graph" tab:

```
up
```

This returns `1` for each target that Prometheus scraped successfully, `0` otherwise.

6. Try a second query that aggregates CPU usage by Pod:

```
sum(rate(container_cpu_usage_seconds_total[5m])) by (pod)
```

**Comprehension questions:**

- What does it mean that Prometheus uses a pull model instead of push, and what does that imply for how applications expose their metrics?
- In the query `rate(container_cpu_usage_seconds_total[5m])`, what does `[5m]` represent?

---

## Exercise 5: Grafana as a visualization layer

Grafana does not collect data by itself: it queries datasources (like Prometheus) and renders the results as dashboards.

**Steps:**

1. If you installed `kube-prometheus-stack` in the previous exercise, Grafana is already included. Retrieve the generated admin password:

```bash
kubectl get secret -n monitoring kube-prom-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

2. Port-forward to the Grafana service:

```bash
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80
```

3. Open `http://localhost:3000` and log in with user `admin` and the password obtained in step 1.

4. Go to Connections → Data sources and confirm that Prometheus is already configured as a datasource (the chart adds it automatically).

5. Import a public cluster monitoring dashboard: In Dashboards → New → Import, enter ID `315` (Kubernetes cluster monitoring) and select the Prometheus datasource.

6. Explore the imported dashboard and locate the CPU usage by node panel.

**Comprehension questions:**

- What responsibility does Prometheus have and what does Grafana have in this stack? Why separate them instead of having a single component that does both?
- If a Grafana panel shows "No data", which component would you check first: the Prometheus datasource or the dashboard configuration?

---

**Reference source:** [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

<details>
<summary>Answers</summary>

**Exercise 1**
- When a liveness probe fails repeatedly, the kubelet kills the container and restarts it according to the Pod's `restartPolicy`. When a readiness probe fails, the Pod is not restarted: it is simply removed from the Service Endpoints, so it stops receiving traffic until it passes the probe again.
- `initialDelaySeconds` prevents Kubernetes from starting to evaluate the probe before the application has finished starting up. Without that delay, a slow-starting app could be marked as failed (and restarted in a loop) before it has a chance to come up.

**Exercise 2**
- If the Pod has more than one container and you don't use `-c`, `kubectl logs` returns an error asking you to specify the container name (unless the Pod has a single container, in which case it is not needed).
- `kubectl logs <pod> -c <container> --previous` shows the logs of the previous instance of the container, useful for diagnosing why it restarted (crash, OOMKilled, etc.).

**Exercise 3**
- It needs the metrics-server component running in the cluster (usually in `kube-system`), which aggregates usage data from cAdvisor/kubelet and exposes it via the Metrics API.
- Because metrics-server only keeps data in memory, in a very short window (the last seconds/minutes), without historical persistence. For that you need a system with time series storage, like Prometheus.

**Exercise 4**
- In the pull model, Prometheus initiates the connections, periodically scraping the `/metrics` endpoints exposed by applications. This implies that each app (or an exporter acting on its behalf) must expose an HTTP endpoint with metrics in Prometheus format, instead of actively sending them to a central server.
- The `[5m]` defines a range vector: it tells `rate()` to calculate the rate of change of the counter using values from the last 5 minutes, rather than comparing just two consecutive points.

**Exercise 5**
- Prometheus is responsible for scraping, storing, and querying (via PromQL) the time series of metrics. Grafana does not store metrics: it queries datasources like Prometheus and renders them as panels and dashboards. Separating both responsibilities allows, for example, changing the visualization tool without touching collection, or having multiple datasources (Prometheus, Loki, etc.) feeding the same dashboards.
- You would first check the Prometheus datasource (whether it is correctly configured and whether Prometheus has data for that query), since a misconfigured panel usually shows a different error than "No data", while "No data" typically indicates that the query returned no results from the datasource.

</details>