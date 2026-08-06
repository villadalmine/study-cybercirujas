# CNPA 2.1 — Observability Fundamentals: Guided Exercises

> **Exam domain:** Observability (weight 4.0) — *Observability Fundamentals: Traces, Metrics, Logs, and Events*
> **Time:** ~3–4 hours
> **What you build:** a two-service instrumented application, a Prometheus server with Kubernetes service discovery, an OpenTelemetry Collector with three pipelines, and Jaeger — then you break it on purpose and diagnose it with each signal in turn.

The exam expects you to reason about *which signal answers which question*, and what each one costs. Keep this table in view; every exercise below maps back to a row.

| Signal | Shape | Cardinality cost | Answers | Retention model |
|---|---|---|---|---|
| **Metrics** | numeric time series, pre-aggregated | O(product of label values) — the dangerous one | *Is it broken? How badly? Since when?* | cheap, months |
| **Logs** | discrete timestamped records | O(events × bytes) | *What exactly happened in this one execution?* | expensive, days–weeks |
| **Traces** | causally-linked spans across services | O(requests × spans), usually sampled | *Where in the call graph is the time/error?* | expensive, days |
| **Events (k8s)** | control-plane state-change records in etcd | small but **TTL'd** | *What did the control plane decide, and why?* | **default 1 h**, then gone |

---

## Exercise 0 — Lab environment

### Steps

1. Create a cluster (any conformant 1.29+ cluster works; `kind` is used here because you will need node filesystem access later).

```bash
kind create cluster --name obs-lab --image kindest/node:v1.31.0
kubectl config use-context kind-obs-lab
kubectl get nodes -o wide
```

Expected:

```
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP
obs-lab-control-plane   Ready    control-plane   38s   v1.31.0   172.18.0.2
```

2. Create the working namespace and verify your client/server versions.

```bash
kubectl create namespace obs-lab
kubectl version --output=yaml | grep -E 'gitVersion|major|minor'
```

3. Confirm which Event APIs your cluster serves. This is not trivia — the two APIs have different field names.

```bash
kubectl api-resources --api-group='' | grep -i event
kubectl api-resources --api-group=events.k8s.io
```

Expected:

```
events        ev   v1                true    Event
NAME     SHORTNAMES   APIVERSION           NAMESPACED   KIND
events   ev           events.k8s.io/v1     true         Event
```

### Checkpoint

- **Q1.** `kubectl api-resources` lists `Event` twice, under `v1` and under `events.k8s.io/v1`. Are these two distinct storage objects, or one object exposed through two APIs? What happens to a `core/v1` Event you create when you read it back through `events.k8s.io/v1`?
- **Q2.** Name the field that carries the human-readable text in each of the two APIs, and the field that identifies the object the Event is about.

---

## Exercise 1 — Events: the control plane narrating its own decisions

Kubernetes Events are the only signal that tells you what the **scheduler, kubelet and controllers** decided. They are not application telemetry, and they are not durable.

### Steps

1. Create three pods that fail in three structurally different ways.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: bad-image
  namespace: obs-lab
spec:
  containers:
    - name: app
      image: registry.k8s.io/does-not-exist:v9.9.9
  restartPolicy: Never
---
apiVersion: v1
kind: Pod
metadata:
  name: unschedulable
  namespace: obs-lab
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
      resources:
        requests:
          cpu: "400"
          memory: 4000Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: memory-hog
  namespace: obs-lab
spec:
  restartPolicy: Always
  containers:
    - name: app
      image: busybox:1.36
      command: ["/bin/sh", "-c", "yes | tr '\\n' 'x' | head -c 268435456 | grep n"]
      resources:
        limits:
          memory: 32Mi
        requests:
          memory: 32Mi
EOF
```

2. Watch the Events stream live for 60 seconds.

```bash
kubectl events -n obs-lab --watch
# fallback on older clients:
# kubectl get events -n obs-lab --watch
```

Expected (abbreviated):

```
LAST SEEN   TYPE      REASON              OBJECT              MESSAGE
0s          Normal    Scheduled           Pod/bad-image       Successfully assigned obs-lab/bad-image to obs-lab-control-plane
0s          Normal    Pulling             Pod/bad-image       Pulling image "registry.k8s.io/does-not-exist:v9.9.9"
2s          Warning   Failed              Pod/bad-image       Failed to pull image "...": not found
2s          Warning   Failed              Pod/bad-image       Error: ErrImagePull
3s          Normal    BackOff             Pod/bad-image       Back-off pulling image "..."
3s          Warning   Failed              Pod/bad-image       Error: ImagePullBackOff
0s          Warning   FailedScheduling    Pod/unschedulable   0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

3. Query Events like the API objects they are, not by grepping.

```bash
# Only warnings, most recent last
kubectl get events -n obs-lab \
  --field-selector type=Warning \
  --sort-by=.lastTimestamp

# Everything about one object, the way `kubectl describe` does it internally
kubectl get events -n obs-lab \
  --field-selector involvedObject.kind=Pod,involvedObject.name=bad-image

# The same, via the newer API
kubectl events -n obs-lab --for pod/unschedulable
```

4. Inspect the raw object to see the aggregation fields.

```bash
kubectl get events -n obs-lab \
  --field-selector involvedObject.name=bad-image \
  -o jsonpath='{range .items[*]}{.reason}{"\t"}{.count}{"\t"}{.firstTimestamp}{"\t"}{.lastTimestamp}{"\n"}{end}'
```

Expected:

```
Pulling	4	2026-08-06T14:02:11Z	2026-08-06T14:05:44Z
Failed	4	2026-08-06T14:02:13Z	2026-08-06T14:05:46Z
BackOff	9	2026-08-06T14:02:14Z	2026-08-06T14:06:02Z
```

5. Now look at the OOM case. Compare what the Event says with what the Pod status says.

```bash
kubectl get events -n obs-lab --field-selector involvedObject.name=memory-hog
kubectl get pod memory-hog -n obs-lab \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{.status.containerStatuses[0].restartCount}{"\n"}'
```

Expected:

```
BackOff   Back-off restarting failed container app in pod memory-hog_obs-lab(...)
OOMKilled
4
```

6. Find the Event TTL enforced by your API server.

```bash
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -i event-ttl
echo "no --event-ttl flag => API server default applies"
```

### Checkpoint

- **Q3.** The `bad-image` pod produced `Pulling` four times but the Event object has `count: 4` with one `firstTimestamp` and one moving `lastTimestamp`. Which component performed that aggregation — the API server, etcd, or the emitting client? Why does it matter for how you count failures?
- **Q4.** You are on-call and open a ticket about an outage that happened 6 hours ago. `kubectl get events` returns nothing relevant. Is the cluster healthy, or did you lose evidence? What is the default `--event-ttl`, and what are the two production-grade ways to retain Events beyond it?
- **Q5.** `memory-hog` shows the Event reason `BackOff` but the container status reason `OOMKilled`. Which of the two is the authoritative statement that the kernel OOM killer fired, and what does that tell you about building alerts on Event reasons?
- **Q6.** A controller in a hot loop tries to emit the same Event 500 times per minute; you only see a handful. Which mechanism suppressed the rest, and on which side of the API boundary does it run?

---

## Exercise 2 — Logs: from `stdout` to the node, and why that is not a logging system

### Steps

1. Deploy a chatty pod and read its logs through the API.

```bash
kubectl -n obs-lab run chatty --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c 'i=0; while true; do i=$((i+1)); echo "{\"level\":\"info\",\"seq\":$i,\"msg\":\"tick\"}"; echo "stderr line $i" >&2; sleep 1; done'

kubectl -n obs-lab logs chatty --tail=4 --timestamps
```

Expected:

```
2026-08-06T14:12:03.114512331Z {"level":"info","seq":41,"msg":"tick"}
2026-08-06T14:12:03.114690112Z stderr line 41
2026-08-06T14:12:04.116004221Z {"level":"info","seq":42,"msg":"tick"}
2026-08-06T14:12:04.116219004Z stderr line 42
```

2. Prove where those bytes physically live. Enter the node.

```bash
docker exec -it obs-lab-control-plane bash

# inside the node:
ls -l /var/log/containers/ | grep chatty
ls -lR /var/log/pods/obs-lab_chatty_*/
tail -n 3 /var/log/pods/obs-lab_chatty_*/chatty/0.log
```

Expected:

```
/var/log/containers/chatty_obs-lab_chatty-7c1f...e9.log -> /var/log/pods/obs-lab_chatty_2f1a-.../chatty/0.log

2026-08-06T14:12:04.116004221Z stdout F {"level":"info","seq":42,"msg":"tick"}
2026-08-06T14:12:04.116219004Z stderr F stderr line 42
```

3. Read the kubelet's rotation policy, still on the node, then exit.

```bash
grep -E 'containerLogMax' /var/lib/kubelet/config.yaml || \
  echo "keys absent => defaults: containerLogMaxSize=10Mi containerLogMaxFiles=5"
exit
```

4. Demonstrate that `kubectl logs` is bound to the container instance, not to the pod's history.

```bash
kubectl -n obs-lab logs memory-hog --previous --tail=3
kubectl -n obs-lab logs memory-hog --tail=3
```

5. Read logs across a set of pods by label, which is what you will do once the app is running.

```bash
kubectl -n obs-lab logs -l run=chatty --prefix --tail=2 --max-log-requests=10
```

### Checkpoint

- **Q7.** Decode the on-disk line `2026-08-06T14:12:04.116004221Z stdout F {"level":"info",...}`. Name all four positional fields of the CRI log format and state what the value `P` in the fourth field would mean.
- **Q8.** With the kubelet defaults left untouched, what is the maximum amount of log data retained on the node for a single container, and what happens to `kubectl logs --since=24h` once the container has exceeded it?
- **Q9.** A node is cordoned, drained and deleted after an incident. Which of the four signals still contains evidence of what the application on that node was doing, assuming no agent was installed? Why does this argue for a node-level collector rather than relying on `kubectl logs`?
- **Q10.** The pod emits both a JSON line and a plain-text line. Why is the JSON one strictly more valuable to a collector, and which single field would you add to it to make correlation with traces possible?

---

## Exercise 3 — Metrics: instrument, expose, discover, scrape

You now deploy the real application. It is deliberately written with the OpenTelemetry SDK for traces and `prometheus_client` for metrics, which is the most common production combination.

### Steps

1. Create the application source as a ConfigMap.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-src
  namespace: obs-lab
data:
  app.py: |
    import json, os, random, time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.request import Request, urlopen

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.propagate import extract, inject
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.trace import SpanKind, Status, StatusCode
    from prometheus_client import Counter, Histogram, start_http_server

    ROLE = os.environ["ROLE"]
    DOWNSTREAM = os.environ.get("DOWNSTREAM_URL", "")
    FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))
    EXTRA_LATENCY_MS = int(os.environ.get("EXTRA_LATENCY_MS", "0"))
    HIGH_CARDINALITY = os.environ.get("HIGH_CARDINALITY", "false") == "true"

    # Resource.create() reads OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES.
    # OTLPSpanExporter() reads OTEL_EXPORTER_OTLP_ENDPOINT.
    provider = TracerProvider(resource=Resource.create())
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("shop.http")

    REQUESTS = Counter(
        "http_server_requests_total",
        "Total HTTP requests handled by this service.",
        ["method", "route", "status_code"],
    )
    DURATION = Histogram(
        "http_server_request_duration_seconds",
        "End-to-end handler latency in seconds.",
        ["route"],
        buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
    )
    # Deliberately unbounded label set. Only used when HIGH_CARDINALITY=true.
    ORDERS = Counter(
        "checkout_orders_total",
        "Orders processed, labelled per user and session (ANTI-PATTERN).",
        ["route", "user_id", "session_id"],
    )

    def log(level, message, **fields):
        record = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": level,
            "service.name": os.environ.get("OTEL_SERVICE_NAME", ROLE),
            "message": message,
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            record["trace_id"] = format(ctx.trace_id, "032x")
            record["span_id"] = format(ctx.span_id, "016x")
        record.update(fields)
        print(json.dumps(record), flush=True)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass  # suppress the stdlib access log; we emit structured logs instead

        def do_GET(self):
            route = self.path.split("?")[0]
            started = time.perf_counter()
            # W3C propagators look up lower-case keys; normalise the carrier.
            carrier = {k.lower(): v for k, v in self.headers.items()}
            parent = extract(carrier)
            with tracer.start_as_current_span(
                "GET " + route,
                context=parent,
                kind=SpanKind.SERVER,
                attributes={
                    "http.request.method": "GET",
                    "url.path": route,
                    "server.address": os.environ.get("HOSTNAME", ""),
                },
            ) as span:
                status, body = 200, b'{"ok":true}'
                try:
                    if route == "/healthz":
                        pass
                    elif route == "/checkout":
                        body, status = self.checkout()
                    elif route == "/charge":
                        body, status = self.charge()
                    else:
                        status, body = 404, b'{"error":"not found"}'
                except Exception as exc:                      # noqa: BLE001
                    status, body = 500, b'{"error":"internal"}'
                    span.record_exception(exc)

                span.set_attribute("http.response.status_code", status)
                if status >= 500:
                    span.set_status(Status(StatusCode.ERROR))

                elapsed = time.perf_counter() - started
                tid = format(span.get_span_context().trace_id, "032x")
                DURATION.labels(route=route).observe(elapsed, exemplar={"trace_id": tid})
                REQUESTS.labels(
                    method="GET", route=route, status_code=str(status)
                ).inc(exemplar={"trace_id": tid})
                if HIGH_CARDINALITY:
                    ORDERS.labels(
                        route=route,
                        user_id="u-%d" % random.randint(1, 5000),
                        session_id="s-%d" % random.randint(1, 5000),
                    ).inc()

                log(
                    "info" if status < 500 else "error",
                    "request completed",
                    **{
                        "http.route": route,
                        "http.response.status_code": status,
                        "duration_ms": round(elapsed * 1000, 2),
                    }
                )
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        def checkout(self):
            with tracer.start_as_current_span(
                "GET payments /charge",
                kind=SpanKind.CLIENT,
                attributes={"url.full": DOWNSTREAM, "peer.service": "payments"},
            ):
                headers = {}
                inject(headers)          # must happen INSIDE the client span
                try:
                    with urlopen(Request(DOWNSTREAM, headers=headers), timeout=2) as r:
                        r.read()
                        downstream = r.status
                except Exception as exc:  # noqa: BLE001
                    log("error", "downstream call failed", error=str(exc))
                    return b'{"error":"payments unavailable"}', 502
            if downstream >= 500:
                return b'{"error":"payment declined"}', 502
            return b'{"ok":true,"order":"o-%d"}' % random.randint(1000, 9999), 200

        def charge(self):
            with tracer.start_as_current_span(
                "ledger.write",
                kind=SpanKind.INTERNAL,
                attributes={"db.system": "postgresql", "db.operation": "INSERT"},
            ) as span:
                time.sleep(random.uniform(0.005, 0.05) + EXTRA_LATENCY_MS / 1000.0)
                if random.random() < FAIL_RATE:
                    span.set_status(Status(StatusCode.ERROR, "ledger timeout"))
                    span.add_event("ledger.timeout", {"retry.attempted": False})
                    log("error", "ledger write timed out")
                    return b'{"error":"ledger timeout"}', 500
            return b'{"ok":true}', 200

    if __name__ == "__main__":
        start_http_server(9090)   # /metrics
        log("info", "server starting", role=ROLE, http_port=8080, metrics_port=9090)
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
EOF
```

2. Deploy the two services. Note the scrape annotations and the OTel environment variables — these are the two contracts that make the pod observable.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: obs-lab
  labels: {app: payments}
spec:
  replicas: 2
  selector: {matchLabels: {app: payments}}
  template:
    metadata:
      labels: {app: payments}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: app
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - >-
              pip install --quiet --no-cache-dir
              prometheus-client==0.20.0
              opentelemetry-sdk==1.27.0
              opentelemetry-exporter-otlp-proto-http==1.27.0 &&
              exec python /src/app.py
          env:
            - name: ROLE
              value: payments
            - name: OTEL_SERVICE_NAME
              value: payments
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector.obs-lab.svc.cluster.local:4318
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: deployment.environment=lab,service.version=1.4.2
            - name: FAIL_RATE
              value: "0"
            - name: EXTRA_LATENCY_MS
              value: "0"
          ports:
            - {name: http, containerPort: 8080}
            - {name: metrics, containerPort: 9090}
          volumeMounts:
            - {name: src, mountPath: /src}
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
            initialDelaySeconds: 20
            periodSeconds: 5
      volumes:
        - name: src
          configMap: {name: shop-src}
---
apiVersion: v1
kind: Service
metadata: {name: payments, namespace: obs-lab}
spec:
  selector: {app: payments}
  ports:
    - {name: http, port: 8080, targetPort: 8080}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: obs-lab
  labels: {app: checkout}
spec:
  replicas: 1
  selector: {matchLabels: {app: checkout}}
  template:
    metadata:
      labels: {app: checkout}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: app
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - >-
              pip install --quiet --no-cache-dir
              prometheus-client==0.20.0
              opentelemetry-sdk==1.27.0
              opentelemetry-exporter-otlp-proto-http==1.27.0 &&
              exec python /src/app.py
          env:
            - name: ROLE
              value: checkout
            - name: OTEL_SERVICE_NAME
              value: checkout
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector.obs-lab.svc.cluster.local:4318
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: deployment.environment=lab,service.version=2.0.0
            - name: DOWNSTREAM_URL
              value: http://payments.obs-lab.svc.cluster.local:8080/charge
          ports:
            - {name: http, containerPort: 8080}
            - {name: metrics, containerPort: 9090}
          volumeMounts:
            - {name: src, mountPath: /src}
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
            initialDelaySeconds: 20
            periodSeconds: 5
      volumes:
        - name: src
          configMap: {name: shop-src}
---
apiVersion: v1
kind: Service
metadata: {name: checkout, namespace: obs-lab}
spec:
  selector: {app: checkout}
  ports:
    - {name: http, port: 8080, targetPort: 8080}
EOF

kubectl -n obs-lab rollout status deploy/payments deploy/checkout --timeout=5m
```

3. Look at raw exposition format before any scraper touches it.

```bash
kubectl -n obs-lab port-forward deploy/checkout 9090:9090 >/dev/null 2>&1 &
sleep 2
curl -s localhost:9090/metrics | grep -E '^# (HELP|TYPE) http_server' -A0
curl -s localhost:9090/metrics | grep 'http_server_request_duration_seconds' | head -20
```

Expected:

```
# HELP http_server_requests_total Total HTTP requests handled by this service.
# TYPE http_server_requests_total counter
# HELP http_server_request_duration_seconds End-to-end handler latency in seconds.
# TYPE http_server_request_duration_seconds histogram
http_server_request_duration_seconds_bucket{le="0.005",route="/healthz"} 12.0
http_server_request_duration_seconds_bucket{le="0.01",route="/healthz"} 12.0
...
http_server_request_duration_seconds_bucket{le="+Inf",route="/healthz"} 12.0
http_server_request_duration_seconds_count{route="/healthz"} 12.0
http_server_request_duration_seconds_sum{route="/healthz"} 0.00281...
```

4. Deploy Prometheus with Kubernetes service discovery and exemplar storage enabled.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: {name: prometheus, namespace: obs-lab}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: obs-lab-prometheus}
rules:
  - apiGroups: [""]
    resources: [nodes, nodes/proxy, nodes/metrics, services, endpoints, pods]
    verbs: [get, list, watch]
  - nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: obs-lab-prometheus}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: obs-lab-prometheus}
subjects:
  - {kind: ServiceAccount, name: prometheus, namespace: obs-lab}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: prometheus-config, namespace: obs-lab}
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: obs-lab

    scrape_configs:
      # 1. Annotation-driven pod discovery
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        # Guardrails: refuse pathological targets instead of falling over.
        sample_limit: 5000
        label_limit: 30
        label_value_length_limit: 256
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: "true"
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app

      # 2. Kubelet-embedded cAdvisor: container resource metrics (the USE method)
      - job_name: kubelet-cadvisor
        scheme: https
        tls_config:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          insecure_skip_verify: true
        authorization:
          credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        kubernetes_sd_configs:
          - role: node
        relabel_configs:
          - action: labelmap
            regex: __meta_kubernetes_node_label_(.+)
          - target_label: __address__
            replacement: kubernetes.default.svc:443
          - source_labels: [__meta_kubernetes_node_name]
            regex: (.+)
            target_label: __metrics_path__
            replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: prometheus, namespace: obs-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: prometheus}}
  template:
    metadata:
      labels: {app: prometheus}
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v2.54.1
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.path=/prometheus
            - --storage.tsdb.retention.time=6h
            - --enable-feature=exemplar-storage
            - --web.enable-lifecycle
          ports: [{name: web, containerPort: 9090}]
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
            - {name: data, mountPath: /prometheus}
      volumes:
        - {name: config, configMap: {name: prometheus-config}}
        - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata: {name: prometheus, namespace: obs-lab}
spec:
  selector: {app: prometheus}
  ports: [{name: web, port: 9090, targetPort: 9090}]
EOF

kubectl -n obs-lab rollout status deploy/prometheus --timeout=3m
```

5. Start continuous load, then open Prometheus.

```bash
kubectl -n obs-lab create deployment loadgen --image=busybox:1.36 -- \
  /bin/sh -c 'while true; do wget -q -O- http://checkout.obs-lab.svc.cluster.local:8080/checkout >/dev/null 2>&1; sleep 0.2; done'

kill %1 2>/dev/null
kubectl -n obs-lab port-forward svc/prometheus 9091:9090 >/dev/null 2>&1 &
sleep 2
curl -s 'localhost:9091/api/v1/targets?state=active' \
  | python3 -c 'import json,sys; [print(t["labels"].get("job"), t["labels"].get("pod",""), t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"]]'
```

Expected:

```
kubernetes-pods checkout-6d9f8c74b5-2ktrn up
kubernetes-pods payments-7f5c9d8f4-h9v2p  up
kubernetes-pods payments-7f5c9d8f4-x4nqz  up
kubelet-cadvisor                          up
```

6. Run the RED queries (Rate, Errors, Duration) — the service-level method.

```bash
q() { curl -sG --data-urlencode "query=$1" localhost:9091/api/v1/query \
      | python3 -m json.tool | grep -E '"(value|__name__|route|status_code|app|le)"' ; }

# Rate
q 'sum by (app, route) (rate(http_server_requests_total[5m]))'

# Errors, as a ratio
q 'sum(rate(http_server_requests_total{status_code=~"5.."}[5m])) / sum(rate(http_server_requests_total[5m]))'

# Duration: p99 per route, computed from the histogram buckets
q 'histogram_quantile(0.99, sum by (le, route) (rate(http_server_request_duration_seconds_bucket[5m])))'
```

7. Run the USE queries (Utilization, Saturation, Errors) — the resource-level method.

```bash
# Utilization: CPU seconds burned per pod
q 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="obs-lab",container!=""}[5m]))'

# Saturation: fraction of CFS periods in which the container was throttled
q 'rate(container_cpu_cfs_throttled_periods_total{namespace="obs-lab"}[5m])
   / rate(container_cpu_cfs_periods_total{namespace="obs-lab"}[5m])'

# Memory working set vs limit
q 'container_memory_working_set_bytes{namespace="obs-lab",container!=""}
   / on(pod,container) kube_pod_container_resource_limits'
```

### Checkpoint

- **Q11.** In the exposition output, `http_server_requests_total` is a counter and `http_server_request_duration_seconds` is a histogram. How many distinct time series does a single histogram with 10 explicit buckets and one label with 3 values produce? Show the arithmetic.
- **Q12.** Why is `rate(http_server_requests_total[5m])` correct and `http_server_requests_total` almost always wrong for dashboards? What specific event does `rate()` handle that a naive `delta` would report as a huge negative number?
- **Q13.** `histogram_quantile(0.99, ...)` returned `0.25` for `/checkout`, and your bucket boundaries are `..., 0.1, 0.25, 0.5, ...`. Is the true p99 exactly 250 ms? Explain the interpolation Prometheus performs and what it means for SLO reporting.
- **Q14.** The third `relabel_config` rewrites `__address__` using a regex over two source labels joined by `;`. What exactly is the input string it matches against for the `checkout` pod, and what would break if you omitted this rule?
- **Q15.** RED was applied to `checkout` and `payments`; USE was applied to the containers. Which method would have detected "the node's disk is 100 % full" and which would have detected "the checkout API returns 502 for 30 % of requests"? Why do you need both?
- **Q16.** `sample_limit: 5000` is set on the pod job. Describe precisely what Prometheus does when a target exceeds it, and why failing the scrape is safer than ingesting the samples.

---

## Exercise 4 — Cardinality: the failure mode that kills metric backends

### Steps

1. Record the current series count as a baseline.

```bash
curl -sG --data-urlencode 'query=prometheus_tsdb_head_series' \
  localhost:9091/api/v1/query | python3 -c 'import json,sys; print("head series:", json.load(sys.stdin)["data"]["result"][0]["value"][1])'

curl -s localhost:9091/api/v1/status/tsdb \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"];
[print(f"{x[\"value\"]:>8}  {x[\"name\"]}") for x in d["seriesCountByMetricName"][:8]]'
```

Expected:

```
head series: 4127
     240  container_cpu_usage_seconds_total
     198  container_memory_working_set_bytes
      33  http_server_request_duration_seconds_bucket
       9  http_server_requests_total
```

2. Turn on the anti-pattern and wait ~3 minutes.

```bash
kubectl -n obs-lab set env deploy/checkout HIGH_CARDINALITY=true
kubectl -n obs-lab rollout status deploy/checkout
sleep 180
```

3. Measure the damage.

```bash
curl -sG --data-urlencode 'query=prometheus_tsdb_head_series' \
  localhost:9091/api/v1/query | python3 -c 'import json,sys; print("head series:", json.load(sys.stdin)["data"]["result"][0]["value"][1])'

# Which metric names dominate now?
curl -sG --data-urlencode 'query=topk(5, count by (__name__) ({__name__!=""}))' \
  localhost:9091/api/v1/query | python3 -m json.tool | grep -E '"(__name__|value)"' 

# Distinct values behind each offending label
curl -sG --data-urlencode 'query=count(count by (user_id) (checkout_orders_total))' \
  localhost:9091/api/v1/query | python3 -c 'import json,sys; print("distinct user_id:", json.load(sys.stdin)["data"]["result"][0]["value"][1])'
```

Expected (illustrative):

```
head series: 11893
"checkout_orders_total"  7421
distinct user_id: 2183
```

4. Roll it back and confirm the series do **not** disappear immediately.

```bash
kubectl -n obs-lab set env deploy/checkout HIGH_CARDINALITY-
kubectl -n obs-lab rollout status deploy/checkout
sleep 60
curl -sG --data-urlencode 'query=prometheus_tsdb_head_series' \
  localhost:9091/api/v1/query | python3 -c 'import json,sys; print("head series:", json.load(sys.stdin)["data"]["result"][0]["value"][1])'
```

5. Apply the correct mitigation at the collection boundary — drop the metric before it is ingested.

```bash
kubectl -n obs-lab patch configmap prometheus-config --type merge -p "$(cat <<'EOF'
{"data":{"prometheus.yml":"global:\n  scrape_interval: 15s\nscrape_configs:\n  - job_name: kubernetes-pods\n    kubernetes_sd_configs:\n      - role: pod\n    metric_relabel_configs:\n      - source_labels: [__name__]\n        regex: 'checkout_orders_total'\n        action: drop\n"}}
EOF
)"
echo "note: this patch is illustrative and truncates the config — re-apply the full ConfigMap from Exercise 3 before continuing."
```

### Checkpoint

- **Q17.** `checkout_orders_total` has labels `route`, `user_id`, `session_id`. If the service sees 50 000 users and 200 000 sessions over a week across 3 routes, what is the theoretical upper bound on time series for this single metric? Why is the *observed* count lower, and why does that not save you?
- **Q18.** After removing the label, `prometheus_tsdb_head_series` stayed high for a while. Explain what a *stale* series is in the TSDB head block, and roughly when the memory is actually reclaimed.
- **Q19.** There are three places you could have stopped this: in the application, in `metric_relabel_configs`, and in `relabel_configs`. Which one runs *before* the scrape and which run *after*? Which of the three is the only one that also saves the application's own memory?
- **Q20.** A colleague proposes keeping `user_id` "because we need per-user debugging." Which signal should carry `user_id`, and why is it structurally the right home for high-cardinality identifiers?

---

## Exercise 5 — Traces: context propagation across a service boundary

### Steps

1. Deploy Jaeger and the OpenTelemetry Collector. The Collector is the fan-in point for all three OTLP signals plus Kubernetes Events.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: jaeger, namespace: obs-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: jaeger}}
  template:
    metadata: {labels: {app: jaeger}}
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.60
          env:
            - {name: COLLECTOR_OTLP_ENABLED, value: "true"}
          ports:
            - {name: ui, containerPort: 16686}
            - {name: otlp-grpc, containerPort: 4317}
---
apiVersion: v1
kind: Service
metadata: {name: jaeger, namespace: obs-lab}
spec:
  selector: {app: jaeger}
  ports:
    - {name: ui, port: 16686, targetPort: 16686}
    - {name: otlp-grpc, port: 4317, targetPort: 4317}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: otel-collector, namespace: obs-lab}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: obs-lab-otel-collector}
rules:
  - apiGroups: [""]
    resources: [pods, namespaces, nodes, events]
    verbs: [get, list, watch]
  - apiGroups: ["apps"]
    resources: [replicasets, deployments]
    verbs: [get, list, watch]
  - apiGroups: ["events.k8s.io"]
    resources: [events]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: obs-lab-otel-collector}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: obs-lab-otel-collector}
subjects:
  - {kind: ServiceAccount, name: otel-collector, namespace: obs-lab}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: otel-collector-config, namespace: obs-lab}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      k8sobjects:
        auth_type: serviceAccount
        objects:
          - name: events
            mode: watch
            group: events.k8s.io

    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.node.name
            - k8s.deployment.name
      batch:
        timeout: 5s
        send_batch_size: 1024

    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
        dimensions:
          - name: http.request.method
          - name: http.response.status_code

    exporters:
      otlp/jaeger:
        endpoint: jaeger.obs-lab.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true
      debug:
        verbosity: detailed
        sampling_initial: 2
        sampling_thereafter: 500

    service:
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp/jaeger, spanmetrics]
        metrics:
          receivers: [otlp, spanmetrics]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
        logs:
          receivers: [otlp, k8sobjects]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [debug]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: otel-collector, namespace: obs-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: otel-collector}}
  template:
    metadata:
      labels: {app: otel-collector}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8889"
    spec:
      serviceAccountName: otel-collector
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.109.0
          args: ["--config=/conf/config.yaml"]
          ports:
            - {name: otlp-grpc, containerPort: 4317}
            - {name: otlp-http, containerPort: 4318}
            - {name: promexport, containerPort: 8889}
            - {name: selfmetrics, containerPort: 8888}
          volumeMounts:
            - {name: conf, mountPath: /conf}
      volumes:
        - {name: conf, configMap: {name: otel-collector-config}}
---
apiVersion: v1
kind: Service
metadata: {name: otel-collector, namespace: obs-lab}
spec:
  selector: {app: otel-collector}
  ports:
    - {name: otlp-grpc, port: 4317, targetPort: 4317}
    - {name: otlp-http, port: 4318, targetPort: 4318}
    - {name: promexport, port: 8889, targetPort: 8889}
EOF

kubectl -n obs-lab rollout status deploy/jaeger deploy/otel-collector --timeout=3m
kubectl -n obs-lab rollout restart deploy/checkout deploy/payments
kubectl -n obs-lab rollout status deploy/checkout deploy/payments --timeout=5m
```

2. Fire one request **with a trace context you control**, so you can find it deterministically.

```bash
TRACE_ID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SPAN_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01"

kubectl -n obs-lab run curl-probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
  http://checkout.obs-lab.svc.cluster.local:8080/checkout
```

Expected:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
{"ok":true,"order":"o-4471"}
```

3. Confirm both services joined the *same* trace, using their own logs.

```bash
kubectl -n obs-lab logs -l app=checkout --tail=200 | grep "$TRACE_ID"
kubectl -n obs-lab logs -l app=payments --tail=200 | grep "$TRACE_ID"
```

Expected:

```
{"ts":"...","level":"info","service.name":"checkout","message":"request completed","trace_id":"4bf92f...4736","span_id":"9a1c...","http.route":"/checkout","http.response.status_code":200,"duration_ms":41.7}
{"ts":"...","level":"info","service.name":"payments","message":"request completed","trace_id":"4bf92f...4736","span_id":"c3e8...","http.route":"/charge","http.response.status_code":200,"duration_ms":31.2}
```

4. Open Jaeger and inspect the trace structure.

```bash
kubectl -n obs-lab port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
sleep 2
curl -s "localhost:16686/api/traces/${TRACE_ID}" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"][0]
procs={k:v["serviceName"] for k,v in d["processes"].items()}
for s in sorted(d["spans"], key=lambda s: s["startTime"]):
    kind=[t["value"] for t in s["tags"] if t["key"]=="span.kind"]
    print(f"{procs[s[\"processID\"]]:>9} | {s[\"operationName\"]:<24} | kind={kind} | {s[\"duration\"]/1000:.1f}ms | span={s[\"spanID\"]}")
'
```

Expected:

```
 checkout | GET /checkout            | kind=['server'] | 41.7ms | span=9a1c4f...
 checkout | GET payments /charge     | kind=['client'] | 38.9ms | span=1b2d7e...
 payments | GET /charge              | kind=['server'] | 31.2ms | span=c3e88a...
 payments | ledger.write             | kind=['internal'] | 29.4ms | span=77aa10...
```

Then browse `http://localhost:16686` and open the same trace visually.

5. Enable head sampling on `checkout` at 10 % and observe the effect on both services.

```bash
kubectl -n obs-lab set env deploy/checkout \
  OTEL_TRACES_SAMPLER=parentbased_traceidratio \
  OTEL_TRACES_SAMPLER_ARG=0.1
kubectl -n obs-lab set env deploy/payments \
  OTEL_TRACES_SAMPLER=parentbased_traceidratio \
  OTEL_TRACES_SAMPLER_ARG=0.1
kubectl -n obs-lab rollout status deploy/checkout deploy/payments --timeout=5m

sleep 120
curl -s "localhost:16686/api/traces?service=checkout&limit=200&lookback=2m" \
  | python3 -c 'import json,sys; print("traces stored:", len(json.load(sys.stdin)["data"]))'
```

6. Verify that sampling is *consistent* — you never get a checkout span whose payments child is missing.

```bash
curl -s "localhost:16686/api/traces?service=checkout&limit=50&lookback=5m" \
  | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]:
    svcs={t["processes"][s["processID"]]["serviceName"] for s in t["spans"]}
    print(t["traceID"][:16], sorted(svcs))
' | head
```

Expected — every stored trace has both services, never a half trace:

```
7d3a91c0e2f45b18 ['checkout', 'payments']
a1c8ff2093be7740 ['checkout', 'payments']
```

### Checkpoint

- **Q21.** Decompose `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`. Name each of the four dash-separated parts, its length in hex characters, and what the final byte means when its low bit is `1` versus `0`.
- **Q22.** In the span list, `checkout` produced two spans for one HTTP call: one `SERVER` and one `CLIENT`. Why is that not redundant? What does the difference between their durations measure that neither service's own metrics can tell you?
- **Q23.** `inject(headers)` is called inside the `CLIENT` span, not inside the `SERVER` span. What would go wrong in the resulting trace tree if it were called outside, before the client span was started?
- **Q24.** With `parentbased_traceidratio` at 0.1 on both services, exactly which service makes the sampling decision for a given trace, and what does `payments` do with that decision? Contrast this with setting `traceidratio` (non-parent-based) at 0.1 on both — how many complete traces would survive?
- **Q25.** Head sampling at 10 % throws away 90 % of traces *before knowing whether they errored*. Describe the tail-sampling alternative and the architectural constraint it imposes on a horizontally scaled Collector fleet. Which Collector component solves that constraint?
- **Q26.** The application code lower-cases header keys before calling `extract()`. What real-world class of bug does this guard against, given that HTTP header names are case-insensitive on the wire but Python's `dict` lookups are not?

---

## Exercise 6 — The Collector: one pipeline per signal, and Events as logs

### Steps

1. Watch Kubernetes Events arriving through the `k8sobjects` receiver into the *logs* pipeline.

```bash
kubectl -n obs-lab logs deploy/otel-collector --tail=200 | grep -A20 'LogRecord'
```

Expected (abbreviated):

```
LogRecord #0
ObservedTimestamp: 2026-08-06 15:02:44.11 +0000 UTC
Body: Map({"kind":"Event","reason":"Scheduled","note":"Successfully assigned obs-lab/curl-probe to obs-lab-control-plane", ...})
Attributes:
     -> k8s.resource.name: Str(events)
     -> event.domain: Str(k8s)
```

2. Generate a fresh Event and confirm it flows through within seconds.

```bash
kubectl -n obs-lab delete pod bad-image --ignore-not-found
kubectl -n obs-lab run bad-image-2 --image=registry.k8s.io/nope:v0 --restart=Never
sleep 20
kubectl -n obs-lab logs deploy/otel-collector --tail=400 | grep -c 'ErrImagePull'
```

3. Inspect the Collector's own telemetry — an observability pipeline must itself be observable.

```bash
kubectl -n obs-lab port-forward deploy/otel-collector 8888:8888 >/dev/null 2>&1 &
sleep 2
curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent|exporter_send_failed|processor_dropped)' | grep -v '^#'
```

Expected:

```
otelcol_receiver_accepted_spans{receiver="otlp",transport="http"} 4820
otelcol_exporter_sent_spans{exporter="otlp/jaeger"} 4820
otelcol_exporter_send_failed_spans{exporter="otlp/jaeger"} 0
otelcol_receiver_accepted_log_records{receiver="k8sobjects"} 137
```

4. Look at the metrics the `spanmetrics` connector derived from traces, now scraped by Prometheus.

```bash
curl -sG --data-urlencode 'query=topk(5, sum by (service_name, span_name, status_code) (rate(traces_span_metrics_calls_total[5m])))' \
  localhost:9091/api/v1/query | python3 -m json.tool | grep -E '"(service_name|span_name|status_code|value)"'
```

5. Confirm `k8sattributes` enriched the spans with pod identity that the SDK never knew.

```bash
curl -s "localhost:16686/api/traces?service=payments&limit=1&lookback=5m" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"][0]
for p in d["processes"].values():
    print(p["serviceName"], {t["key"]: t["value"] for t in p["tags"]})
'
```

Expected:

```
payments {'deployment.environment': 'lab', 'service.version': '1.4.2', 'k8s.pod.name': 'payments-7f5c9d8f4-h9v2p', 'k8s.namespace.name': 'obs-lab', 'k8s.node.name': 'obs-lab-control-plane', 'k8s.deployment.name': 'payments'}
```

### Checkpoint

- **Q27.** The Collector config has `receivers`, `processors`, `exporters`, `connectors` and `service.pipelines`. Which of these sections actually *activates* a component, and what happens to a receiver that is defined but never referenced?
- **Q28.** `spanmetrics` appears as an exporter in the `traces` pipeline and as a receiver in the `metrics` pipeline. Explain what a connector is in one sentence, and give the operational reason you would derive RED metrics from spans rather than instrumenting them separately.
- **Q29.** `k8sattributes` sits before `batch` in every pipeline, and `memory_limiter` sits first everywhere. Justify both orderings. What specifically breaks if `batch` runs before `memory_limiter`?
- **Q30.** The `k8sobjects` receiver turns Kubernetes Events into OTLP **log records**, not into metrics or traces. Argue why "log" is the correct signal type for an Event, referring to the shape of the data.
- **Q31.** `otelcol_exporter_send_failed_spans` is non-zero and climbing while `otelcol_receiver_accepted_spans` keeps rising. What is the failure mode, what does the `memory_limiter` do when this persists, and which application-side setting determines whether the app blocks or drops?

---

## Exercise 7 — Correlation: exemplars and the resource model

The point of the four signals is not to have four dashboards. It is to move between them in one click.

### Steps

1. Look at an exemplar in the raw exposition. It only appears under OpenMetrics content negotiation.

```bash
kubectl -n obs-lab port-forward deploy/checkout 9092:9090 >/dev/null 2>&1 &
sleep 2

# Prometheus text format: no exemplars
curl -s localhost:9092/metrics | grep 'duration_seconds_bucket{le="0.25",route="/checkout"}'

# OpenMetrics: exemplars appear
curl -s -H 'Accept: application/openmetrics-text; version=1.0.0; charset=utf-8' \
  localhost:9092/metrics | grep 'duration_seconds_bucket{le="0.25",route="/checkout"}'
```

Expected:

```
http_server_request_duration_seconds_bucket{le="0.25",route="/checkout"} 3841.0
http_server_request_duration_seconds_bucket{le="0.25",route="/checkout"} 3841.0 # {trace_id="9f2c1b7a44de0331aa87b6f2c0d91e45"} 0.0417 1754491362.114
```

2. Query the exemplars Prometheus stored.

```bash
curl -sG --data-urlencode 'query=http_server_request_duration_seconds_bucket{route="/checkout"}' \
  --data-urlencode "start=$(( $(date +%s) - 300 ))" \
  --data-urlencode "end=$(date +%s)" \
  localhost:9091/api/v1/query_exemplars \
  | python3 -c '
import json,sys
for s in json.load(sys.stdin)["data"]:
    for e in s["exemplars"][:3]:
        print(e["labels"]["trace_id"], e["value"])
'
```

Expected:

```
9f2c1b7a44de0331aa87b6f2c0d91e45 0.0417
c1d3086ba7f24519bb00ee7714c9a83f 0.2210
```

3. Perform the full three-hop correlation by hand: metric → trace → logs.

```bash
TID=$(curl -sG --data-urlencode 'query=http_server_request_duration_seconds_bucket{route="/checkout",le="+Inf"}' \
  --data-urlencode "start=$(( $(date +%s) - 300 ))" --data-urlencode "end=$(date +%s)" \
  localhost:9091/api/v1/query_exemplars \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["exemplars"][-1]["labels"]["trace_id"])')

echo "trace: $TID"
curl -s "localhost:16686/api/traces/${TID}" | python3 -c '
import json,sys; d=json.load(sys.stdin)["data"][0]
print("spans:", len(d["spans"]), "services:", {p["serviceName"] for p in d["processes"].values()})'

kubectl -n obs-lab logs -l app=payments --tail=500 | grep "$TID"
kubectl -n obs-lab logs -l app=checkout --tail=500 | grep "$TID"
```

4. Inspect the resource attributes that make the join key stable across all three signals.

```bash
kubectl -n obs-lab exec deploy/checkout -- env | grep -E '^OTEL_'
```

Expected:

```
OTEL_SERVICE_NAME=checkout
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.obs-lab.svc.cluster.local:4318
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=lab,service.version=2.0.0
```

### Checkpoint

- **Q32.** In the OpenMetrics line, the exemplar has three parts after the `#`. Name them. Why is the exemplar attached to a specific bucket rather than to the metric as a whole, and why is that exactly what you want when chasing tail latency?
- **Q33.** A metric time series carries perhaps thousands of observations per scrape interval, but Prometheus stores a small number of exemplars per series. What does this imply about using exemplars as a complete record versus as an *entry point*?
- **Q34.** Name the single OpenTelemetry resource attribute that is **required** by the specification for every service, and explain what fails in the Collector and in Jaeger when it is missing.
- **Q35.** `service.version=2.0.0` is set as a resource attribute rather than as a metric label. Trace what happens to your metric cardinality on every deploy under each of the two choices, and state which is correct for a Prometheus-backed pipeline.
- **Q36.** You have `k8s.pod.name` on spans (from `k8sattributes`) and `pod` on metrics (from `relabel_configs`). These are different key names for the same thing. Why does that matter for a correlation UI, and what is the standards-based fix?

---

## Exercise 8 — Diagnostic drill: break it, then walk the four signals in order

### Steps

1. Inject a latency regression and an error rate into `payments`. Note the time.

```bash
date -u +%H:%M:%SZ
kubectl -n obs-lab set env deploy/payments FAIL_RATE=0.3 EXTRA_LATENCY_MS=400
kubectl -n obs-lab rollout status deploy/payments --timeout=5m
sleep 240
```

2. **Metrics first** — establish *that* something is wrong and its blast radius. Do not open logs yet.

```bash
q() { curl -sG --data-urlencode "query=$1" localhost:9091/api/v1/query | python3 -m json.tool | grep -E '"(app|route|status_code|value)"'; }

q 'sum by (app) (rate(http_server_requests_total{status_code=~"5.."}[2m]))
   / sum by (app) (rate(http_server_requests_total[2m]))'

q 'histogram_quantile(0.95, sum by (le, app, route) (rate(http_server_request_duration_seconds_bucket[2m])))'
```

Expected:

```
"app": "checkout"   "value": [..., "0.0"]      # checkout returns 502, not 5xx, on its own counter
"app": "payments"   "value": [..., "0.298"]
"app": "checkout", "route": "/checkout"  "value": [..., "0.5"]
"app": "payments", "route": "/charge"    "value": [..., "0.5"]
```

3. **Traces second** — locate *where* in the call graph the time and the errors are.

```bash
curl -s "localhost:16686/api/traces?service=checkout&limit=20&lookback=5m&minDuration=300ms" \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
print("slow traces:", len(d))
t=d[0]; procs={k:v["serviceName"] for k,v in t["processes"].items()}
for s in sorted(t["spans"], key=lambda s: s["startTime"]):
    err=[tg["value"] for tg in s["tags"] if tg["key"]=="otel.status_code"]
    print(f"{procs[s[\"processID\"]]:>9} | {s[\"operationName\"]:<22} | {s[\"duration\"]/1000:7.1f}ms | {err}")
'
```

Expected:

```
slow traces: 18
 checkout | GET /checkout          |   446.2ms | []
 checkout | GET payments /charge   |   443.8ms | []
 payments | GET /charge            |   441.0ms | ['ERROR']
 payments | ledger.write           |   438.5ms | ['ERROR']
```

4. **Logs third** — read the exact message from the one span that failed.

```bash
kubectl -n obs-lab logs -l app=payments --tail=1000 \
  | grep '"level":"error"' | tail -3
```

Expected:

```
{"ts":"2026-08-06T15:41:02Z","level":"error","service.name":"payments","message":"ledger write timed out","trace_id":"b81f...","span_id":"5c2a..."}
```

5. **Events fourth** — rule the control plane in or out.

```bash
kubectl get events -n obs-lab --field-selector type=Warning --sort-by=.lastTimestamp | tail -10
kubectl -n obs-lab get deploy payments -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}'
kubectl -n obs-lab rollout history deploy/payments
```

6. Roll back and confirm recovery through the same metric you used to detect it.

```bash
kubectl -n obs-lab set env deploy/payments FAIL_RATE=0 EXTRA_LATENCY_MS=0
kubectl -n obs-lab rollout status deploy/payments --timeout=5m
sleep 150
q 'sum(rate(http_server_requests_total{app="payments",status_code=~"5.."}[2m]))
   / sum(rate(http_server_requests_total{app="payments"}[2m]))'
```

### Checkpoint

- **Q37.** In step 2, `checkout`'s 5xx ratio was `0.0` while it was clearly serving broken responses to users. Read the application code and explain the discrepancy. What does this teach about trusting a single service's own error metric?
- **Q38.** For each of the four questions below, state which signal answered it and why the other three could not have, or could only have done so at unacceptable cost:
  (a) *When did the regression start?*
  (b) *Which of the two services is the source?*
  (c) *What is the literal failure inside that service?*
  (d) *Was this caused by a control-plane action such as a rollout or an eviction?*
- **Q39.** The Events in step 5 showed a `ScalingReplicaSet` roughly when the regression started. Does that prove the rollout caused it? What additional signal or field would let you attribute the change to a specific revision?
- **Q40.** Suppose head sampling had been at 1 % and the error rate at 0.5 %. Would step 3 have found a failing trace within a reasonable time? Which sampling strategy would you have deployed instead, and what would it have cost you?
- **Q41.** Write the PromQL for a burn-rate alert on a 99.5 % availability SLO for `/checkout`, measured over a 5-minute window, that fires when the error budget is being consumed 14.4× faster than sustainable.

---

## Cleanup

```bash
kill %1 %2 %3 %4 2>/dev/null
kubectl delete namespace obs-lab
kubectl delete clusterrole obs-lab-prometheus obs-lab-otel-collector
kubectl delete clusterrolebinding obs-lab-prometheus obs-lab-otel-collector
kind delete cluster --name obs-lab
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A1.** One object, two APIs. `events.k8s.io/v1` is a rewritten surface over the *same* etcd storage as `core/v1` Events — there is no separate resource and no dual write. Reading a `core/v1` Event through `events.k8s.io/v1` returns it with the newer field names, and fields that have no counterpart may come back empty. The practical consequence: `--field-selector` expressions written for one API do not transfer to the other, which is the most common cause of "my selector returns nothing."

**A2.** Message text: `message` in `core/v1`, `note` in `events.k8s.io/v1`. Subject object: `involvedObject` (an `ObjectReference`) in `core/v1`, `regarding` in `events.k8s.io/v1`. Similarly `source.component` → `reportingController`, and `firstTimestamp`/`lastTimestamp`/`count` → `eventTime` plus `series.lastObservedTime`/`series.count`.

### Exercise 1

**A3.** The **emitting client** aggregates, not the API server and not etcd. Each component (kubelet, scheduler, controller-manager) uses `client-go`'s `EventRecorder`/`EventCorrelator`, which hashes an "aggregation key" from source + involved object + reason + message. On a repeat it does a `PATCH` that bumps `count` and moves `lastTimestamp` instead of creating a new object. Consequence: `count` is a *client-side* tally that resets when the emitting component restarts, and it is not a reliable metric. Counting failures by `count` across a kubelet restart undercounts.

**A4.** You most likely lost the evidence. The kube-apiserver flag `--event-ttl` defaults to **1 hour**; the API server garbage-collects Events older than that regardless of namespace or importance. Two production-grade retentions:
1. Export Events into a log/telemetry backend continuously — e.g. the OTel Collector's `k8sobjects` receiver (Exercise 6), `kube-events-exporter`, or an agent watching the Events API.
2. Convert the ones you care about into metrics with `kube-state-metrics` / `event-exporter`, which gives you a durable time series (`kube_pod_container_status_last_terminated_reason`, etc.).
Raising `--event-ttl` is a distant third: it enlarges the etcd working set and every API server pays the cost.

**A5.** The **container status** is authoritative. `status.containerStatuses[*].lastState.terminated.reason: OOMKilled` (with `exitCode: 137`) is reported by the CRI runtime from the kernel cgroup OOM record. The `BackOff` Event only says the kubelet is throttling restarts; the `OOMKilling` Event that older kubelets emitted from the cAdvisor OOM watcher is not reliably present in current versions. Lesson: **do not alert on Event reasons for conditions that have a status field.** Alert on `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` from kube-state-metrics, which reads the status, not the Event stream.

**A6.** `client-go`'s `EventSourceObjectSpamFilter`, a per-(source, involvedObject) token bucket with a refill rate of 1 event per 5 minutes and a burst of 25. It runs **client-side**, inside the emitting component, before the API call. So the suppressed Events never reach the API server at all — there is no server-side record you can recover. This is deliberate: an Event storm from a hot-looping controller would otherwise take etcd down.

### Exercise 2

**A7.** CRI log format is four space-separated fields:
1. **RFC 3339Nano timestamp** in UTC (`2026-08-06T14:12:04.116004221Z`) — written by the runtime, not the app.
2. **Stream** — `stdout` or `stderr`.
3. **Tag** — `F` (full: this line is complete) or `P` (partial: the line exceeded the runtime's read buffer, typically 16 KiB, and continues in the next record). A collector must concatenate consecutive `P` records up to the terminating `F`, or you get shredded JSON.
4. **The log line itself**, verbatim.

**A8.** `containerLogMaxSize` defaults to `10Mi` and `containerLogMaxFiles` to `5`, so at most **~50 MiB** per container (the active file plus 4 rotated ones). `kubectl logs --since=24h` does not fail — it silently returns only what survives on disk. For a chatty container that may be the last 20 minutes. This silent truncation is exactly why `kubectl logs` is a debugging convenience, never an audit trail.

**A9.** **None of them, locally.** Container logs live only in `/var/log/pods` on that node and die with it. Metrics survive because they were *pushed or scraped off the node* into Prometheus. Traces survive because the SDK exported them off-node. Events survive only until the TTL. The argument for a node-level collector (DaemonSet tailing `/var/log/containers/*.log`, or an OTLP log exporter in the app) is precisely this: the signal must leave the failure domain before the failure domain disappears.

**A10.** The JSON line already carries typed, named fields, so the collector performs zero parsing and the backend can index `level`, `http.response.status_code`, `duration_ms` as real fields. The plain-text line requires a fragile regex/grok pattern that breaks the next time someone edits the format string. The single field to add is **`trace_id`** (and ideally `span_id`) — it is the join key that turns an isolated log line into "the logs for *this* request across *all* services."

### Exercise 3

**A11.** A Prometheus histogram with N explicit buckets produces **N + 3** series per label combination: N `_bucket` series, plus the implicit `le="+Inf"` bucket, plus `_sum` and `_count`. So 10 explicit buckets → 13 series per combination. With one label of 3 values: **13 × 3 = 39 series**. This is why an innocuous-looking histogram is roughly an order of magnitude more expensive than a counter, and why adding a label to a histogram is 13× worse than adding it to a counter.

**A12.** A counter is monotonically increasing and its absolute value is meaningless — it depends on how long ago the process started. `rate()` converts it to a per-second average over the window, which is comparable across pods and restarts. The specific event it handles is a **counter reset**: when a pod restarts, the counter goes back to 0. `rate()` and `increase()` detect the drop and treat it as a reset, adding the pre-reset value rather than reporting a large negative delta. `delta()` (intended for gauges) does not, and would report nonsense.

**A13.** No. `histogram_quantile` performs **linear interpolation within the matched bucket**, and it can never return a value outside the bucket boundaries that contain the quantile. With boundaries at 0.1 and 0.25, any p99 falling in that bucket is reported somewhere in [0.1, 0.25]; the result is bounded by your bucket layout, not by the real distribution. Two consequences for SLOs: (1) place a bucket boundary **exactly at your SLO threshold** (if the SLO is "99 % under 300 ms", you need an `le="0.3"` bucket) and then measure the *ratio* `..._bucket{le="0.3"} / ..._count` rather than a quantile; (2) never average quantiles across pods — always `sum by (le) (rate(..._bucket[...]))` first, then `histogram_quantile`, as in step 6.

**A14.** The input is `__address__` and the port annotation joined by `;`, i.e. `10.244.0.17:8080;9090` for the checkout pod (service discovery sets `__address__` to the pod IP and the first declared container port). The regex `([^:]+)(?::\d+)?;(\d+)` captures `10.244.0.17` and `9090`, and the replacement rewrites `__address__` to `10.244.0.17:9090`. Without this rule Prometheus would scrape `10.244.0.17:8080/metrics` — the application port — and get a 404, so the target would show `up=0` with `server returned HTTP status 404 Not Found`.

**A15.** USE detects "the node's disk is full": it is a *resource*-oriented method (Utilization, Saturation, Errors, applied to every resource — CPU, memory, disk, network, and their queues). RED detects "checkout returns 502 for 30 % of requests": it is a *request*-oriented method (Rate, Errors, Duration, applied to every service). You need both because they answer different questions and each is blind where the other sees: a saturated disk shows up in USE long before any request fails, while a logic bug that returns 502 on a perfectly healthy node is invisible to USE. Google's Four Golden Signals (latency, traffic, errors, saturation) is essentially RED plus USE's saturation term.

**A16.** When a scrape yields more than `sample_limit` samples, Prometheus **discards the entire scrape** and marks the target `up=0` with the error `sample limit exceeded`. Nothing from that scrape is ingested. Failing the scrape is safer than partial ingestion because (a) partial ingestion would produce silently incomplete data that looks valid, and (b) `up=0` is itself an alertable signal that points at the offending target by name. It converts a slow, cluster-wide degradation into a loud, locally attributable failure.

### Exercise 4

**A17.** Theoretical bound: `3 routes × 50 000 users × 200 000 sessions = 3 × 10^10` series. Observed is far lower because only combinations that actually occur create a series — a user only touches a handful of sessions. But that does not save you: the real growth is **unbounded and monotonic in time**. Every new session is a new series forever; the metric's series count grows linearly with traffic and never plateaus, which is the defining property of a cardinality bomb. Prometheus's cost is roughly linear in *active* series for memory and in *total* series for index size.

**A18.** A series becomes **stale** when it stops being present in scrapes; Prometheus writes a staleness marker so queries stop returning it after ~5 minutes. But the series' index entries and its samples remain in the **head block** until the head is compacted into a persistent block — by default every 2 hours — and the memory backing the index is only reclaimed then. So `prometheus_tsdb_head_series` stays elevated for up to a couple of hours after you fix the emitter, and the on-disk index keeps the labels for the full retention period. Practical implication: you cannot "undo" a cardinality incident quickly; if the server is OOM-looping you must drop the metric at scrape time *and* often delete the series via the admin API.

**A19.** `relabel_configs` runs **before** the scrape — it operates on discovered targets and can drop the whole target, so Prometheus never even makes the HTTP request. `metric_relabel_configs` runs **after** the scrape, on each sample, before ingestion — the bytes are transferred and parsed but not stored. Fixing it **in the application** is the only option that also saves the application's own memory, because `prometheus_client` keeps every label combination in an in-process map for the lifetime of the process; a cardinality bomb OOM-kills the app itself, not just Prometheus.

**A20.** `user_id` belongs on **traces** (as a span attribute) and on **logs** (as a structured field). Both are per-event stores indexed for high-cardinality lookup — that is what they are built for; adding one more attribute to a span costs bytes on that span and nothing else. Metrics are pre-aggregated time series where every distinct label value creates a permanent, independently stored series, so cost is multiplicative rather than additive. The rule of thumb: **metrics answer questions about populations, traces and logs answer questions about individuals.** If the label identifies an individual, it does not go in a metric.

### Exercise 5

**A21.** `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`:
- `00` — **version**, 1 byte / 2 hex chars. `ff` is invalid.
- `4bf9…4736` — **trace-id**, 16 bytes / **32 hex chars**, globally unique per trace; all-zeroes is invalid.
- `00f0…02b7` — **parent-id** (the caller's span id), 8 bytes / **16 hex chars**; all-zeroes is invalid.
- `01` — **trace-flags**, 1 byte / 2 hex chars. Only the low bit is defined: **`sampled`**. `01` means the caller decided to record this trace and downstream services should too; `00` means it was not sampled. Note the flag is a *decision*, not a guarantee — a receiver may still choose otherwise, but a well-behaved parent-based sampler honours it.

**A22.** They measure different things. The `SERVER` span is "how long checkout took to answer its caller." The `CLIENT` span is "how long checkout waited for payments, measured from checkout's side." The `payments` `SERVER` span is "how long payments took, measured from payments' side." The **difference between the CLIENT span and the downstream SERVER span** is the network + serialization + connection-pool-wait + queueing time between the two services. No service-local metric can produce that number, because neither service can see both clocks; it is the single most common place where "both services report they are fast" and the user still waits.

**A23.** `inject()` writes the *currently active* span context into the carrier. Called outside the `CLIENT` span, it would inject the `SERVER` span as the parent. The trace would still be connected — payments' span would attach to checkout's `SERVER` span — but the `CLIENT` span would become a **sibling** of the remote work instead of its parent. You would lose the parent-child edge that makes the client/server duration comparison meaningful, and waterfall views would show the remote call as unrelated to the outbound call.

**A24.** With `parentbased_traceidratio`, the sampler consults the incoming `traceparent` first: **if there is a valid parent, its `sampled` flag is obeyed verbatim and the ratio is ignored.** The ratio is applied only when there is no parent — i.e. at the **root**, which here is `checkout` (or `curl` if you supply your own `traceparent`). So `payments` never makes a decision; it inherits. With plain `traceidratio` at 0.1 on both, each service would roll the dice independently and only ~1 % of traces would be complete in both services; the other 9 % + 9 % would be useless fragments. This is why parent-based is the default and why the ratio must be configured at the entry point.

**A25.** **Tail sampling** buffers all spans of a trace until it is complete (or a timeout expires), then applies policies to the *whole* trace — keep it if any span errored, if total duration exceeded a threshold, if it touched a particular route, plus a probabilistic floor for the boring ones. The constraint: **every span of a given trace must reach the same Collector instance**, otherwise no instance ever sees a complete trace and the policies evaluate against fragments. The component that solves this is a two-tier Collector topology where the first tier runs the **`loadbalancing` exporter with `routing_key: traceID`**, consistently hashing each trace to one instance of the second tier, which runs the `tail_sampling` processor. Costs: memory for the buffer, added latency equal to the decision wait, and a stateful tier you must scale carefully.

**A26.** HTTP header names are case-insensitive on the wire, so a peer may legitimately send `TraceParent`, `TRACEPARENT` or `traceparent` — proxies, service meshes and some HTTP clients normalize differently. OpenTelemetry's default `TextMapGetter` for a plain `dict` performs an **exact, case-sensitive key lookup** for `"traceparent"`. Without normalization, a request whose header arrived as `Traceparent` would silently yield no parent context: the receiving service would start a **new root trace**, and the trace would appear broken into two disconnected halves with no error anywhere. This class of bug is invisible in logs and metrics and only shows up as "traces mysteriously stop at one hop."

### Exercise 6

**A27.** Only `service.pipelines` activates anything. The top-level `receivers`/`processors`/`exporters`/`connectors` blocks are *definitions*; a component defined there but not referenced by any pipeline is validated at startup and then **never instantiated** — it does not listen, does not consume memory, and does not appear in the Collector's self-metrics. This is a frequent source of "I configured the receiver and nothing arrives."

**A28.** A **connector** is a component that terminates one pipeline as an exporter and begins another as a receiver, optionally changing the signal type. Operationally you derive RED metrics from spans (`spanmetrics`) because it gives you consistent latency/error/rate series for **every** instrumented service with zero additional application code and zero risk of the metric and the trace disagreeing — they are literally computed from the same data. The trade-off: the metrics inherit the trace sampling rate unless the connector sits before the sampler, so `spanmetrics` must be fed from the **unsampled** span stream.

**A29.** `memory_limiter` **first** because its job is to refuse data when the process is near its memory ceiling; anything placed before it can allocate unboundedly and OOM the Collector before the limiter is ever consulted. If `batch` ran first, the batcher would accumulate up to `send_batch_size` records in memory precisely while the process is under memory pressure — the limiter would then be protecting nothing, since the memory is already committed. `k8sattributes` before `batch` because it enriches per-record using the record's source IP / pod association; batching does not change correctness here, but running enrichment on already-formed batches costs the same and, more importantly, `batch` should always be **last** so it groups the final, fully-processed records for efficient export.

**A30.** A Kubernetes Event has exactly the shape of a log record: it is a **discrete, timestamped, immutable occurrence with a text body and structured attributes**, emitted at unpredictable intervals, with no numeric value to aggregate and no causal parent/child relationship to other Events. It is not a metric (no measurement to sample over time), and it is not a span (no duration, no trace context, no parent). Modelling it as a log record means it lands in the same store as application logs, is searchable with the same query language, and can be placed on the same timeline during an incident — which is exactly what you want when correlating "the pod started failing" with "the scheduler evicted it."

**A31.** The exporter cannot deliver — the backend (Jaeger here) is down, unreachable, or rejecting/rate-limiting. Data accumulates in the exporter's sending queue; once the queue is full the exporter drops and increments `otelcol_exporter_send_failed_spans`. As memory rises, `memory_limiter` begins **refusing data at the receivers**, returning a retryable error (gRPC `RESOURCE_EXHAUSTED` / HTTP 429) to the senders — backpressure, deliberately pushed upstream rather than absorbed. On the application side, the **span processor** decides the outcome: `BatchSpanProcessor` (used here) has a bounded queue and **drops** spans once it is full, so the app never blocks and user requests are unaffected; `SimpleSpanProcessor` exports synchronously and would block the request path. In production, always `BatchSpanProcessor` — telemetry must degrade, never take the service down.

### Exercise 7

**A32.** After the `#`: (1) the **exemplar labels** in braces, `{trace_id="…"}`; (2) the **exemplar value** — the observed measurement, `0.0417` seconds; (3) an optional **timestamp** in Unix seconds, `1754491362.114`. The exemplar is attached to a specific **bucket** because that is where the observation was counted, and that is exactly the property you exploit: to chase tail latency you query exemplars on the *high* buckets (`le="2.5"`, `le="+Inf"`) and you get trace IDs of genuinely slow requests, not of the median ones that dominate any random sample.

**A33.** Prometheus stores a small, bounded number of exemplars per series in a circular buffer (`--storage.tsdb.max-exemplars`, default 100 000 across the whole TSDB), and the exposition itself carries at most one exemplar per bucket per scrape. So exemplars are **statistically unrepresentative by construction** — you cannot count them, average them, or reason about their distribution. They are an **entry point**: "here is one concrete request that landed in this bucket; go read its trace." Anyone building a dashboard panel that aggregates exemplars has misunderstood the mechanism.

**A34.** **`service.name`**. It is the only resource attribute the OpenTelemetry specification marks as required; SDKs that do not receive it fall back to the literal `unknown_service` (often `unknown_service:python`). Downstream, Jaeger's entire index is keyed on service name, so every uninstrumented-looking service collapses into a single `unknown_service` entry, the service map becomes meaningless, and `spanmetrics` emits `service_name="unknown_service"` for all of them, merging unrelated services into one RED series. Nothing errors — it just silently produces garbage, which is worse.

**A35.** As a **resource attribute** on spans/logs it costs one extra key-value per exported record and nothing structurally: old spans keep the old version, new spans carry the new one, and no index grows without bound. As a **metric label** it would double the series count on every deploy: `http_server_requests_total{version="2.0.0"}` becomes stale (and stays in the index for the retention period) while `{version="2.0.1"}` is created fresh — and `rate()` across the deploy boundary breaks, because the old series ends and a new one begins at zero, so a naive `sum(rate(...))` shows a dip. For a Prometheus-backed pipeline the correct choice is: **version goes on traces/logs, and on a separate low-cardinality "build info" gauge** (`app_build_info{version="2.0.0"} 1`) that you join against by `on(pod) group_left(version)` when you need it. Never on the request counters themselves.

**A36.** A correlation UI (Grafana's trace-to-metrics / logs-to-trace, or an equivalent) joins signals by matching label/attribute *names*. `k8s.pod.name` on spans and `pod` on metrics do not match, so the "view metrics for this pod" link produces an empty panel. The standards-based fix is to adopt **OpenTelemetry semantic conventions on both sides**: keep `k8s.pod.name`/`k8s.namespace.name` as the canonical names, and make Prometheus produce the same keys — either by naming the target labels accordingly in `relabel_configs`, or by routing metrics through the Collector's `k8sattributes` processor so all three signals are enriched by the *same* component with the *same* keys. (Note the Prometheus data model forbids `.` in label names, so the conventional mapping is `k8s.pod.name` → `k8s_pod_name`; the Collector's Prometheus exporter applies this normalization consistently, which is another argument for routing metrics through it.)

### Exercise 8

**A37.** Read `checkout()`: when the downstream returns ≥ 500, checkout returns **502** to its caller. `502` does not match the selector `status_code=~"5.."`… except it does — `502` matches `5..`. The real discrepancy is that the query grouped `by (app)` over `http_server_requests_total`, and checkout's traffic is dominated by `/healthz` probes returning 200, which dilutes the ratio; restrict to `route="/checkout"` and the ratio appears. The broader lesson stands and is the exam-relevant one: **a service's own error metric reflects that service's opinion of the outcome, aggregated over whatever traffic mix it happens to serve.** Probe traffic, retries that eventually succeed, and errors translated into different status codes all distort it. Always scope error ratios to the route that matters, and corroborate a single service's self-report against the caller's view.

**A38.**
- **(a) When did it start?** — **Metrics.** They are the only signal continuously sampled at a fixed interval and retained long enough to draw a line and see where it moves. Traces are sampled, logs are retained for days at high cost, and Events are TTL'd at 1 hour.
- **(b) Which service is the source?** — **Traces.** Only traces carry the causal edges between services. Metrics can *suggest* it (both services degraded simultaneously) but cannot distinguish "payments is slow" from "checkout is slow and payments is merely waiting"; you would have to reason from correlated dashboards and you would frequently be wrong.
- **(c) What is the literal failure?** — **Logs.** `"ledger write timed out"` is a specific string produced by a specific line of code. A span can carry it as an event or a status message (and here it does), but the exhaustive record of what one execution did is the log.
- **(d) Was it a control-plane action?** — **Events** (plus `rollout history`). Nothing in the application's own telemetry knows that a Deployment was updated or a pod was evicted; that information exists only in the control plane's record of its own decisions.

**A39.** No — a `ScalingReplicaSet` Event at the right time is **correlation, not causation**. The rollout might have been a coincidental scale-up, and the regression might have started slightly before. To attribute it you need the change to be visible *in the telemetry itself*: emit `service.version` (or the ReplicaSet's pod-template-hash) as a resource attribute on spans and as a label on an `app_build_info` gauge, then compare the error rate **split by version** — `sum by (version) (rate(...))` joined against build info. If the old-version pods are healthy while the new-version pods error at 30 % during the overlap window of a rolling update, that is attribution. This is exactly what canary analysis automates.

**A40.** Almost certainly not. With independent head sampling at 1 % and an error rate of 0.5 %, only ~0.005 % of requests produce a *stored, errored* trace — at 5 req/s you would wait hours for a handful, and you would have no guarantee the stored ones are representative. The correct strategy is **tail sampling** with an error-based policy: keep 100 % of traces containing a span with `status=ERROR` or exceeding a latency threshold, and keep 1 % of the rest as a baseline. Costs: a stateful second Collector tier fronted by the `loadbalancing` exporter, memory proportional to (span rate × decision wait), added export latency equal to the decision wait, and the operational burden of a tier that cannot be scaled by simply adding replicas behind a round-robin service.

**A41.** 14.4× is the standard multi-window burn rate that consumes a 30-day error budget in ~2 days (it corresponds to alerting on 2 % of the budget in 1 hour). For a 99.5 % SLO the sustainable error ratio is `1 - 0.995 = 0.005`, so the threshold is `14.4 × 0.005 = 0.072`:

```promql
(
  sum(rate(http_server_requests_total{app="checkout",route="/checkout",status_code=~"5.."}[5m]))
  /
  sum(rate(http_server_requests_total{app="checkout",route="/checkout"}[5m]))
) > (14.4 * 0.005)
```

In production you would pair this fast window with a slower one to avoid flapping, requiring **both** to breach before paging:

```promql
(
  sum(rate(http_server_requests_total{app="checkout",route="/checkout",status_code=~"5.."}[5m]))
  / sum(rate(http_server_requests_total{app="checkout",route="/checkout"}[5m])) > 0.072
)
and
(
  sum(rate(http_server_requests_total{app="checkout",route="/checkout",status_code=~"5.."}[1h]))
  / sum(rate(http_server_requests_total{app="checkout",route="/checkout"}[1h])) > 0.072
)
```

Note this measures *availability*. A latency SLO ("99 % of requests under 300 ms") is measured against a bucket, not a quantile: `1 - (sum(rate(..._bucket{le="0.3"}[5m])) / sum(rate(..._count[5m])))`, which is why the bucket boundary must be placed at the SLO threshold (see A13).

</details>

---

## Sources

- CNCF, *Cloud Native Platform Engineering Associate (CNPA) Curriculum* — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes, *Events* (API reference, `events.k8s.io/v1`) — https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- Kubernetes, *kube-apiserver options* (`--event-ttl`) — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes, *Logging Architecture* (node-level logging, rotation) — https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes, *Kubelet Configuration* (`containerLogMaxSize`, `containerLogMaxFiles`) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes, *Metrics For Kubernetes System Components* — https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
- Prometheus, *Metric types* and *Exposition formats* — https://prometheus.io/docs/concepts/metric_types/ · https://prometheus.io/docs/instrumenting/exposition_formats/
- Prometheus, *Configuration: `kubernetes_sd_config`, `relabel_config`, `metric_relabel_configs`* — https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus, *Querying: `histogram_quantile`, `rate`* — https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus, *Exemplars* — https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- OpenMetrics specification (exemplars) — https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- W3C, *Trace Context* (Recommendation) — https://www.w3.org/TR/trace-context/
- OpenTelemetry, *Traces / Spans* — https://opentelemetry.io/docs/concepts/signals/traces/
- OpenTelemetry, *Sampling* (head vs tail, `parentbased_traceidratio`) — https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry, *Resource semantic conventions* (`service.name`) — https://opentelemetry.io/docs/specs/semconv/resource/
- OpenTelemetry, *SDK environment variables* — https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- OpenTelemetry Collector, *Configuration* and *Connectors* — https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Collector Contrib, *`k8sattributes`, `k8sobjects`, `tailsampling`, `loadbalancing`, `spanmetrics`* — https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main
- Beyer, Jones, Petoff, Murphy (eds.), *Site Reliability Engineering*, ch. 6 "Monitoring Distributed Systems" (Four Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Brendan Gregg, *The USE Method* — https://www.brendangregg.com/usemethod.html
- Tom Wilkie, *The RED Method* — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- Google, *SRE Workbook*, ch. 5 "Alerting on SLOs" (multi-window burn rates) — https://sre.google/workbook/alerting-on-slos/