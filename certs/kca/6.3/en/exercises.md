# 6.3 — Kyverno Metrics · Guided Exercises

> **Exam weight:** 3.33 % (domain 6, *Monitoring, Reporting and Troubleshooting*).
> **Reference syllabus:** [KCA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf)
> **Primary documentation:** [kyverno.io/docs/monitoring/](https://kyverno.io/docs/monitoring/)

**What you will be able to do when you finish**

1. Locate every metrics endpoint Kyverno exposes and explain why there is more than one.
2. Read the raw OpenTelemetry/Prometheus exposition and decode the label set of each metric family.
3. Correlate `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds`, `kyverno_policy_execution_duration_seconds` and `kyverno_policy_results_total` to attribute latency.
4. Control metric cardinality through the `kyverno-metrics` ConfigMap before it takes your Prometheus down.
5. Wire Kyverno into Prometheus Operator with a `ServiceMonitor`, write meaningful PromQL, and alert on the failure modes that actually happen.
6. Switch the pipeline from pull (Prometheus) to push (OTLP/gRPC collector).

**Lab prerequisites**

| Component | Version used in the outputs below | Notes |
|---|---|---|
| Kubernetes | 1.31 (kind) | any 1.27+ works |
| Kyverno | 1.13.x (Helm chart `3.3.x`) | multi-controller architecture — mandatory for this topic |
| `kubectl` | matching minor | |
| Helm | 3.14+ | |
| `kube-prometheus-stack` | 65.x | only needed from Exercise 7 onward |
| `curl`, `jq`, `grep` | any | |

---

## Exercise 0 — Build the lab

### Steps

1. Create the cluster and the tenant namespaces you will use as metric label values:

```bash
kind create cluster --name kca-metrics
kubectl create namespace team-a
kubectl create namespace team-b
```

2. Install Kyverno with all four controllers and their metrics Services:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.3.7 \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set reportsController.replicas=1 \
  --set cleanupController.replicas=1
```

3. Confirm the four Deployments are ready:

```bash
kubectl -n kyverno get deploy
```

Expected output:

```
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           93s
kyverno-background-controller   1/1     1            1           93s
kyverno-cleanup-controller      1/1     1            1           93s
kyverno-reports-controller      1/1     1            1           93s
```

> **Production note.** `admissionController.replicas=1` is a *lab* setting. In production you run 3 replicas, and that decision has a direct consequence on metrics that you will exercise in Exercise 9: every counter is **per-pod**.

---

## Exercise 1 — Map the metrics surface

### Steps

1. List the Services in the `kyverno` namespace and separate the webhook Services from the metrics Services:

```bash
kubectl -n kyverno get svc
```

Expected output:

```
NAME                                    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
kyverno-background-controller-metrics   ClusterIP   10.96.146.211   <none>        8000/TCP   4m12s
kyverno-cleanup-controller              ClusterIP   10.96.63.84     <none>        443/TCP    4m12s
kyverno-cleanup-controller-metrics      ClusterIP   10.96.15.7      <none>        8000/TCP   4m12s
kyverno-reports-controller-metrics      ClusterIP   10.96.209.32    <none>        8000/TCP   4m12s
kyverno-svc                             ClusterIP   10.96.111.20    <none>        443/TCP    4m12s
kyverno-svc-metrics                     ClusterIP   10.96.24.155    <none>        8000/TCP   4m12s
```

2. Inspect the selector and target port of the admission controller's metrics Service:

```bash
kubectl -n kyverno get svc kyverno-svc-metrics -o yaml | grep -A8 -E '^spec:'
```

Expected (abridged):

```yaml
spec:
  ports:
  - name: metrics-port
    port: 8000
    protocol: TCP
    targetPort: metrics-port
  selector:
    app.kubernetes.io/component: admission-controller
    app.kubernetes.io/instance: kyverno
    app.kubernetes.io/part-of: kyverno
  type: ClusterIP
```

3. Read the effective flags of the admission controller — this is the authoritative source for how metrics are configured, not the chart values you *think* you set:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

Expected (abridged):

```
["--caSecretName=kyverno-svc.kyverno.svc.kyverno-tls-ca"
 "--tlsSecretName=kyverno-svc.kyverno.svc.kyverno-tls-pair"
 "--servicePort=443"
 "--webhookServerPort=9443"
 "--resyncPeriod=15m"
 "--disableMetrics=false"
 "--otelConfig=prometheus"
 "--metricsPort=8000"
 "--admissionReports=true"
 "--autoUpdateWebhooks=true"
 "--enableConfigMapCaching=true"
 "--v=2"]
```

4. Confirm the container port is named and exposed:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{range .spec.template.spec.containers[0].ports[*]}{.name}{"\t"}{.containerPort}{"\n"}{end}'
```

Expected output:

```
https	9443
metrics-port	8000
```

### Comprehension questions — block 1

- **Q1.1** — Why does Kyverno 1.11+ expose four separate `/metrics` endpoints instead of one, and what breaks operationally if your scrape configuration only targets `kyverno-svc-metrics`?
- **Q1.2** — `kyverno-svc` listens on 443 and `kyverno-svc-metrics` on 8000. What is served on each, and why must the metrics port **never** be merged into the webhook port?
- **Q1.3** — From the flag list, which two flags together determine whether Prometheus can scrape Kyverno at all, and what is the default value of each?
- **Q1.4** — The Service `selector` includes `app.kubernetes.io/component: admission-controller`. What would you observe in Prometheus if that label were removed from the selector while the other two labels stayed?

---

## Exercise 2 — Read the raw exposition

### Steps

1. Open a port-forward to the admission controller metrics endpoint (leave it running in a second terminal):

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000
```

2. Count how many distinct Kyverno metric families exist on a freshly installed cluster:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^# TYPE kyverno_' | sort
```

Expected output (abridged, order and set vary by version):

```
# TYPE kyverno_admission_requests_total counter
# TYPE kyverno_admission_review_duration_seconds histogram
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_http_requests_duration_seconds histogram
# TYPE kyverno_http_requests_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge
```

3. Look at what else is on the endpoint besides `kyverno_*`:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^# TYPE ' | grep -v kyverno_ | head -12
```

Expected output (abridged):

```
# TYPE go_gc_duration_seconds summary
# TYPE go_goroutines gauge
# TYPE go_memstats_alloc_bytes gauge
# TYPE go_threads gauge
# TYPE process_cpu_seconds_total counter
# TYPE process_resident_memory_bytes gauge
# TYPE promhttp_metric_handler_errors_total counter
# TYPE target_info gauge
```

4. Print one full sample line and decode it by hand:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_client_queries_total' | head -1
```

Expected output:

```
kyverno_client_queries_total{client_type="dynamic",operation="List",otel_scope_name="kyverno",otel_scope_version="",resource_kind="ClusterPolicy",resource_namespace=""} 6
```

5. Extract the label *keys* of a family programmatically — the technique you should use instead of memorising label lists that drift between minor versions:

```bash
curl -s http://127.0.0.1:8000/metrics \
  | grep -m1 '^kyverno_policy_rule_info_total{' \
  | sed 's/.*{//; s/}.*//' | tr ',' '\n' | cut -d= -f1
```

Expected output:

```
otel_scope_name
otel_scope_version
policy_background_mode
policy_名... 
```

Corrected expected output:

```
otel_scope_name
otel_scope_version
policy_background_mode
policy_name
policy_namespace
policy_type
policy_validation_mode
rule_name
rule_type
status_ready
```

6. Inspect `target_info`, the OpenTelemetry resource descriptor:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^target_info'
```

Expected output:

```
target_info{service_name="kyverno",service_version="v1.13.4",telemetry_sdk_language="go",telemetry_sdk_name="opentelemetry",telemetry_sdk_version="1.32.0"} 1
```

### Comprehension questions — block 2

- **Q2.1** — Where do the `otel_scope_name` and `otel_scope_version` labels come from? They are not documented in the Kyverno metrics reference — what does their presence tell you about how Kyverno produces metrics internally?
- **Q2.2** — A colleague writes `sum(kyverno_policy_results_total) by (rule_result)` and gets a number that occasionally *drops*. The metric is a counter. Explain the drop and give the correct query.
- **Q2.3** — `kyverno_policy_rule_info_total` is typed `gauge` but its name ends in `_total`. Why is that a naming smell, and what does the gauge's *value* actually represent (as opposed to what the name suggests)?
- **Q2.4** — You need the p95 of `kyverno_admission_review_duration_seconds`. Which three time series suffixes does a Prometheus histogram expose, and which one does `histogram_quantile()` consume?

---

## Exercise 3 — Drive admission traffic and attribute latency

### Steps

1. Apply an **Enforce** validate policy scoped to `team-a`. Note the Kyverno 1.13+ per-rule `failureAction` field (the spec-level `spec.validationFailureAction` is deprecated but still honoured):

```yaml
# require-team-label.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-team-label
  annotations:
    policies.kyverno.io/title: Require team label
    policies.kyverno.io/severity: medium
spec:
  background: true
  rules:
    - name: check-team-label
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - team-a
      validate:
        failureAction: Enforce
        message: "The label `team` is required on every Pod in team-a."
        pattern:
          metadata:
            labels:
              team: "?*"
```

2. Apply an **Audit** policy and a **mutate** policy, so the metrics carry more than one `rule_type` and `policy_validation_mode`:

```yaml
# audit-and-mutate.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        failureAction: Audit
        message: "An explicit image tag is required."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-resources
spec:
  background: false
  rules:
    - name: add-requests
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - team-b
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - (name): "*"
                resources:
                  requests:
                    +(cpu): "50m"
                    +(memory): "64Mi"
```

```bash
kubectl apply -f require-team-label.yaml -f audit-and-mutate.yaml
kubectl get clusterpolicy
```

Expected output:

```
NAME                    ADMISSION   BACKGROUND   READY   AGE   MESSAGE
add-default-resources   true        false        True    8s    Ready
disallow-latest-tag     true        true         True    8s    Ready
require-team-label      true        true         True    8s    Ready
```

3. Produce one **denied** request:

```bash
kubectl -n team-a run web --image=nginx:1.27
```

Expected output:

```
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/team-a/web was blocked due to the following policies

require-team-label:
  check-team-label: 'validation error: The label `team` is required on every Pod
    in team-a. rule check-team-label failed at path /metadata/labels/team/'
```

4. Produce one **passed** request and one **mutated** request:

```bash
kubectl -n team-a run web --image=nginx:1.27 --labels=team=payments
kubectl -n team-b run cache --image=redis:7.4
kubectl -n team-b get pod cache -o jsonpath='{.spec.containers[0].resources}'; echo
```

Expected output:

```
pod/web created
pod/cache created
{"requests":{"cpu":"50m","memory":"64Mi"}}
```

5. Read the results counter:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_results_total' | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Expected output (abridged, labels reordered for readability):

```
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="fail",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="require-image-tag",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{policy_background_mode="false",policy_name="add-default-resources",policy_namespace="-",policy_type="cluster",policy_validation_mode="-",resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="add-requests",rule_result="pass",rule_type="mutate"} 1
```

6. Read the request counter and the two latency histograms:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_admission_requests_total'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_admission_review_duration_seconds_sum'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_execution_duration_seconds_sum'
```

Expected output (abridged):

```
kyverno_admission_requests_total{...,resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create"} 2
kyverno_admission_requests_total{...,resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create"} 1

kyverno_admission_review_duration_seconds_sum{...,resource_kind="Pod",resource_namespace="team-a",resource_request_operation="create"} 0.041672
kyverno_admission_review_duration_seconds_sum{...,resource_kind="Pod",resource_namespace="team-b",resource_request_operation="create"} 0.019344

kyverno_policy_execution_duration_seconds_sum{...,policy_name="require-team-label",rule_name="check-team-label",rule_result="fail",rule_type="validate",...} 0.000186
kyverno_policy_execution_duration_seconds_sum{...,policy_name="disallow-latest-tag",rule_name="require-image-tag",rule_result="pass",rule_type="validate",...} 0.000094
```

### Comprehension questions — block 3

- **Q3.1** — `kyverno_admission_requests_total` for `team-a` is `2` but `kyverno_policy_results_total` has more than 2 samples for `team-a`. What is the cardinality relationship between an admission request and a policy result, and which of the two is the correct denominator for a "% of requests blocked" SLI?
- **Q3.2** — The sum of `kyverno_policy_execution_duration_seconds_sum` across all rules for the `team-a` create is ~0.3 ms, while `kyverno_admission_review_duration_seconds_sum` for the same label set is ~42 ms. Where did the other ~41.7 ms go? Name three concrete contributors.
- **Q3.3** — In the mutate rule's result sample, `policy_validation_mode="-"`. Why is it a dash and not `Audit` or `Enforce`?
- **Q3.4** — `rule_execution_cause="admission_request"`. What is the other value this label can take, and which controller emits it?
- **Q3.5** — Your Kyverno webhook has `timeoutSeconds: 10` and `failurePolicy: Fail`. Write the PromQL that tells you how close you are to that cliff, and explain why the `_count` series alone is not enough.

---

## Exercise 4 — Rule inventory and policy lifecycle

### Steps

1. Read the rule inventory gauge:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_rule_info_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Expected output (abridged):

```
kyverno_policy_rule_info_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",rule_name="check-team-label",rule_type="validate",status_ready="true"} 1
kyverno_policy_rule_info_total{policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",rule_name="require-image-tag",rule_type="validate",status_ready="true"} 1
kyverno_policy_rule_info_total{policy_background_mode="false",policy_name="add-default-resources",policy_namespace="-",policy_type="cluster",policy_validation_mode="-",rule_name="add-requests",rule_type="mutate",status_ready="true"} 1
```

2. Watch the lifecycle counter. Record the baseline, then create, update and delete a namespaced `Policy`:

```bash
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_changes_total'
```

```yaml
# throwaway-policy.yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: throwaway
  namespace: team-b
spec:
  background: false
  rules:
    - name: noop-check
      match:
        any:
          - resources:
              kinds:
                - ConfigMap
      validate:
        failureAction: Audit
        message: "placeholder"
        pattern:
          metadata:
            name: "?*"
```

```bash
kubectl apply -f throwaway-policy.yaml
kubectl -n team-b annotate policy throwaway note=v2 --overwrite
kubectl -n team-b delete policy throwaway
sleep 5
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_changes_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Expected output:

```
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="created",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="updated",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
kyverno_policy_changes_total{policy_background_mode="false",policy_change_type="deleted",policy_name="throwaway",policy_namespace="team-b",policy_type="namespaced",policy_validation_mode="-"} 1
```

3. Break a policy on purpose and observe `status_ready`. Reference a non-existent API in a context call:

```yaml
# broken-policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: broken-context
spec:
  background: true
  rules:
    - name: lookup-missing
      match:
        any:
          - resources:
              kinds:
                - Pod
      context:
        - name: missing
          apiCall:
            urlPath: "/apis/does.not.exist/v1/widgets"
            jmesPath: "items | length(@)"
      validate:
        failureAction: Audit
        message: "context lookup demo"
        deny:
          conditions:
            all:
              - key: "{{ missing }}"
                operator: GreaterThan
                value: 0
```

```bash
kubectl apply -f broken-policy.yaml
kubectl get clusterpolicy broken-context
```

### Comprehension questions — block 4

- **Q4.1** — `kyverno_policy_rule_info_total` still shows `1` for a rule after you delete the policy, until the next refresh interval. Which configuration key governs that, and what problem is it solving?
- **Q4.2** — `policy_namespace="-"` for ClusterPolicies and a real namespace for Policies. Why does Kyverno emit a literal dash instead of an empty string, and what practical PromQL problem does that avoid?
- **Q4.3** — Write the alert expression that fires when *any* Kyverno rule is loaded but not ready, and explain why `kyverno_policy_rule_info_total{status_ready="false"} == 1` is safer than `== 0`.

---

## Exercise 5 — Background scans, cleanup controller, and API-server pressure

### Steps

1. Scrape the **background** controller — a different endpoint, a different metric mix:

```bash
kubectl -n kyverno port-forward svc/kyverno-background-controller-metrics 8001:8000 &
curl -s http://127.0.0.1:8001/metrics | grep '^# TYPE kyverno_' | sort
```

Expected output:

```
# TYPE kyverno_client_queries_total counter
# TYPE kyverno_controller_drop_total counter
# TYPE kyverno_controller_reconcile_total counter
# TYPE kyverno_controller_requeue_total counter
# TYPE kyverno_policy_changes_total counter
# TYPE kyverno_policy_execution_duration_seconds histogram
# TYPE kyverno_policy_results_total counter
# TYPE kyverno_policy_rule_info_total gauge
```

2. Trigger a background scan by touching a policy, then look for results whose cause is *not* an admission request:

```bash
kubectl annotate clusterpolicy require-team-label rescan="$(date +%s)" --overwrite
sleep 20
curl -s http://127.0.0.1:8001/metrics \
  | grep '^kyverno_policy_results_total' \
  | grep 'rule_execution_cause="background_scan"' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Expected output (abridged):

```
kyverno_policy_results_total{policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_namespace="team-a",resource_request_operation="",rule_execution_cause="background_scan",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
```

3. Look at the controller work-queue metrics — the health signal for the background and reports controllers:

```bash
curl -s http://127.0.0.1:8001/metrics | grep -E '^kyverno_controller_(reconcile|requeue|drop)_total' | head -8
```

Expected output (abridged):

```
kyverno_controller_reconcile_total{controller_name="background-scan-controller",otel_scope_name="kyverno",otel_scope_version=""} 14
kyverno_controller_reconcile_total{controller_name="update-request-controller",otel_scope_name="kyverno",otel_scope_version=""} 3
kyverno_controller_requeue_total{controller_name="background-scan-controller",num_requeues="1",otel_scope_name="kyverno",otel_scope_version=""} 2
kyverno_controller_drop_total{controller_name="background-scan-controller",otel_scope_name="kyverno",otel_scope_version=""} 0
```

4. Measure the load Kyverno places on the API server:

```bash
curl -s http://127.0.0.1:8001/metrics | grep '^kyverno_client_queries_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g' | head -6
```

Expected output (abridged):

```
kyverno_client_queries_total{client_type="dynamic",operation="List",resource_kind="Pod",resource_namespace=""} 11
kyverno_client_queries_total{client_type="kubeclient",operation="Get",resource_kind="ConfigMap",resource_namespace="kyverno"} 4
kyverno_client_queries_total{client_type="kyverno",operation="Watch",resource_kind="ClusterPolicy",resource_namespace=""} 1
kyverno_client_queries_total{client_type="metadata",operation="List",resource_kind="Deployment",resource_namespace=""} 2
```

5. Exercise the **cleanup** controller. First grant it delete rights via RBAC aggregation, then create a cleanup policy:

```yaml
# cleanup-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-pods
  labels:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "delete"]
---
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-marked-pods
spec:
  match:
    any:
      - resources:
          kinds:
            - Pod
          namespaces:
            - team-b
          selector:
            matchLabels:
              ephemeral: "true"
  schedule: "*/1 * * * *"
```

```bash
kubectl apply -f cleanup-rbac.yaml
kubectl -n team-b run scratch --image=busybox:1.36 --labels=ephemeral=true --command -- sleep 3600
sleep 90

kubectl -n kyverno port-forward svc/kyverno-cleanup-controller-metrics 8002:8000 &
curl -s http://127.0.0.1:8002/metrics | grep '^kyverno_cleanup_controller_deletedobjects_total' \
  | sed 's/otel_scope_[a-z]*="[^"]*",//g'
```

Expected output:

```
kyverno_cleanup_controller_deletedobjects_total{policy_name="cleanup-marked-pods",policy_namespace="",policy_type="ClusterCleanupPolicy",resource_group="",resource_kind="Pod",resource_namespace="team-b",resource_version="v1"} 1
```

### Comprehension questions — block 5

- **Q5.1** — In the background-scan result, `resource_request_operation` is the empty string. Why, and what does that imply for a PromQL query that filters on `resource_request_operation="create"`?
- **Q5.2** — `kyverno_admission_requests_total` and `kyverno_admission_review_duration_seconds` do not appear on the background controller endpoint. Give the architectural reason, and name the metric that *does* appear on all four controllers.
- **Q5.3** — You see `rate(kyverno_controller_drop_total{controller_name="reports-controller"}[5m]) > 0`. What does a "drop" mean in a controller-runtime work queue, and what is the downstream user-visible symptom?
- **Q5.4** — `kyverno_client_queries_total{client_type="metadata"}` grows far faster than the other client types on a large cluster. What is the metadata client used for in Kyverno, and why is that *good* news for API-server load rather than bad?

---

## Exercise 6 — Cardinality control with the `kyverno-metrics` ConfigMap

> This is the exercise that matters most in production. A 5 000-namespace cluster with default settings will add millions of active series to Prometheus.

### Steps

1. Estimate your current cardinality before changing anything:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_' \
  | sed 's/{.*//' | sort | uniq -c | sort -rn | head
```

Expected output:

```
187
     84 kyverno_policy_execution_duration_seconds_bucket
     28 kyverno_admission_review_duration_seconds_bucket
     14 kyverno_client_queries_total
      8 kyverno_policy_results_total
      6 kyverno_policy_execution_duration_seconds_sum
      6 kyverno_policy_execution_duration_seconds_count
      ...
```

2. Inspect the shipped configuration:

```bash
kubectl -n kyverno get cm kyverno-metrics -o yaml
```

Expected output (abridged):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
data:
  bucketBoundaries: 0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10,15,20,25,30
  metricsExposure: ""
  metricsRefreshInterval: 0
  namespaces: |
    {"exclude":[],"include":[]}
```

3. Confirm the Helm keys that render this ConfigMap in *your* chart version — never trust a remembered key path:

```bash
helm show values kyverno/kyverno --version 3.3.7 | grep -n -A 30 '^metricsConfig:'
```

4. Apply a production-shaped configuration: drop the noisiest namespaces, drop `resource_namespace` from the highest-cardinality families, tighten the histogram buckets, and disable a metric you do not use:

```yaml
# kyverno-metrics-tuned.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kyverno-metrics
  namespace: kyverno
data:
  namespaces: |
    {
      "include": [],
      "exclude": ["kube-system", "kube-public", "kube-node-lease", "kyverno"]
    }
  metricsRefreshInterval: 6h
  bucketBoundaries: "0.005,0.01,0.025,0.05,0.1,0.25,0.5,1,2.5,5,10"
  metricsExposure: |
    {
      "kyverno_admission_requests_total": {
        "disabledLabelDimensions": ["resource_namespace"]
      },
      "kyverno_policy_results_total": {
        "disabledLabelDimensions": ["resource_namespace", "resource_kind"]
      },
      "kyverno_policy_execution_duration_seconds": {
        "disabledLabelDimensions": ["resource_namespace", "resource_request_operation"],
        "bucketBoundaries": [0.005, 0.01, 0.05, 0.1, 0.5, 1]
      },
      "kyverno_client_queries_total": {
        "enabled": false
      }
    }
```

```bash
kubectl apply -f kyverno-metrics-tuned.yaml
kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

5. Re-open the port-forward (the pod was replaced), regenerate traffic, and diff the cardinality:

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
kubectl -n team-a run web2 --image=nginx:1.27 --labels=team=payments
kubectl -n kube-system run probe --image=busybox:1.36 --command -- sleep 60

curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_'
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_client_queries_total'
curl -s http://127.0.0.1:8000/metrics | grep '^kyverno_policy_results_total' | head -2
```

Expected output:

```
64
0
kyverno_policy_results_total{otel_scope_name="kyverno",otel_scope_version="",policy_background_mode="true",policy_name="disallow-latest-tag",policy_namespace="-",policy_type="cluster",policy_validation_mode="Audit",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="require-image-tag",rule_result="pass",rule_type="validate"} 1
kyverno_policy_results_total{otel_scope_name="kyverno",otel_scope_version="",policy_background_mode="true",policy_name="require-team-label",policy_namespace="-",policy_type="cluster",policy_validation_mode="Enforce",resource_kind="Pod",resource_request_operation="create",rule_execution_cause="admission_request",rule_name="check-team-label",rule_result="pass",rule_type="validate"} 1
```

6. Verify the namespace exclusion took effect — the `kube-system` Pod was admitted but produced no series:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c 'kube-system'
```

Expected output:

```
0
```

7. Confirm `kyverno_policy_rule_info_total` was **not** affected by the namespace exclusion:

```bash
curl -s http://127.0.0.1:8000/metrics | grep -c '^kyverno_policy_rule_info_total'
```

Expected output:

```
4
```

### Comprehension questions — block 6

- **Q6.1** — `metricsRefreshInterval: 0` is the shipped default. What does `0` mean here, and what is the exact behaviour you buy by setting it to `6h`? What do you *lose*?
- **Q6.2** — After the exclusion, the `kube-system` Pod was still admitted and still evaluated by `disallow-latest-tag`. Explain precisely what the `namespaces.exclude` list filters and what it does **not** filter. Why is this a monitoring blind spot you must document?
- **Q6.3** — In step 5, two `kyverno_policy_results_total` samples have *different* label sets: one has `resource_kind`, one does not. Given the ConfigMap you applied, is that consistent? What does it tell you about how `disabledLabelDimensions` is applied?
- **Q6.4** — You cut `bucketBoundaries` from 15 boundaries to 11. For a single histogram family with 40 distinct label combinations, how many time series did you remove, and what is the formula? (Remember the implicit `+Inf` bucket plus `_sum` and `_count`.)
- **Q6.5** — Setting `"enabled": false` on `kyverno_client_queries_total` saves series but costs you something during an incident. Name the specific class of incident you can no longer diagnose, and the alternative signal you would use instead.

---

## Exercise 7 — Prometheus Operator, PromQL and alerts

### Steps

1. Install `kube-prometheus-stack`, disabling the default selector so it picks up ServiceMonitors it did not create:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait
```

2. Enable Kyverno's ServiceMonitors and the shipped Grafana dashboards:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values \
  --set admissionController.serviceMonitor.enabled=true \
  --set backgroundController.serviceMonitor.enabled=true \
  --set cleanupController.serviceMonitor.enabled=true \
  --set reportsController.serviceMonitor.enabled=true \
  --set grafana.enabled=true \
  --set grafana.namespace=monitoring

kubectl -n kyverno get servicemonitor
```

Expected output:

```
NAME                            AGE
kyverno-background-controller   12s
kyverno-cleanup-controller      12s
kyverno-reports-controller      12s
kyverno-admission-controller    12s
```

3. Inspect one ServiceMonitor to see how it binds to the metrics Service:

```bash
kubectl -n kyverno get servicemonitor kyverno-admission-controller -o yaml | grep -A 14 '^spec:'
```

Expected output (abridged):

```yaml
spec:
  endpoints:
  - interval: 30s
    path: /metrics
    port: metrics-port
    scrapeTimeout: 25s
  namespaceSelector:
    matchNames:
    - kyverno
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/instance: kyverno
      app.kubernetes.io/part-of: kyverno
```

4. Confirm the targets are UP:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("kyverno")) | "\(.labels.job)\t\(.health)\t\(.scrapeUrl)"'
```

Expected output:

```
kyverno-admission-controller	up	http://10.244.0.14:8000/metrics
kyverno-background-controller	up	http://10.244.0.15:8000/metrics
kyverno-cleanup-controller	up	http://10.244.0.16:8000/metrics
kyverno-reports-controller	up	http://10.244.0.17:8000/metrics
```

5. Run the production query set. Execute each through the HTTP API so you can script it:

```bash
q() { curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[] | "\(.metric)\t\(.value[1])"'; }

# a) Enforce-mode block rate per policy/rule
q 'sum by (policy_name, rule_name) (rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[5m]))'

# b) p99 admission review latency per resource kind
q 'histogram_quantile(0.99, sum by (le, resource_kind) (rate(kyverno_admission_review_duration_seconds_bucket[5m])))'

# c) Fraction of admission time NOT spent in the policy engine
q '1 - ( sum(rate(kyverno_policy_execution_duration_seconds_sum[5m])) / sum(rate(kyverno_admission_review_duration_seconds_sum[5m])) )'

# d) Slowest rules by mean execution time
q 'topk(5, sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_sum[5m])) / sum by (policy_name, rule_name) (rate(kyverno_policy_execution_duration_seconds_count[5m])))'

# e) Rules loaded but not ready
q 'max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"})'

# f) Kyverno's own series count — watch your cardinality budget
q 'count({__name__=~"kyverno_.+"})'
```

6. Ship the alert rules:

```yaml
# kyverno-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kyverno-slo
  namespace: monitoring
  labels:
    release: monitoring
spec:
  groups:
    - name: kyverno.availability
      rules:
        - alert: KyvernoMetricsAbsent
          expr: absent(kyverno_policy_rule_info_total)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "Kyverno is exporting no metrics — the admission path is unobserved"

        - alert: KyvernoRuleNotReady
          expr: max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"}) == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Rule {{ $labels.rule_name }} of policy {{ $labels.policy_name }} is not ready"

    - name: kyverno.latency
      rules:
        - alert: KyvernoAdmissionLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, resource_kind) (
                rate(kyverno_admission_review_duration_seconds_bucket[5m])
              )
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 Kyverno admission latency for {{ $labels.resource_kind }} is above 1s"
            description: "Webhook timeoutSeconds is 10s with failurePolicy=Fail; at this rate a latency spike becomes a cluster-wide write outage."

    - name: kyverno.saturation
      rules:
        - alert: KyvernoControllerDroppingWork
          expr: sum by (controller_name) (rate(kyverno_controller_drop_total[10m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Controller {{ $labels.controller_name }} is dropping queue items — reports will be stale"

        - alert: KyvernoBlockRateSpike
          expr: |
            sum(rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[10m]))
              > 5 * sum(rate(kyverno_policy_results_total{policy_validation_mode="Enforce",rule_result="fail"}[1h] offset 1h))
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Enforce-mode denials are 5x the previous hour — a policy rollout may be breaking deployments"
```

```bash
kubectl apply -f kyverno-alerts.yaml
curl -s http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[] | select(.name|startswith("kyverno.")) | .name'
```

Expected output:

```
kyverno.availability
kyverno.latency
kyverno.saturation
```

### Comprehension questions — block 7

- **Q7.1** — `serviceMonitorSelectorNilUsesHelmValues=false` was set at install time. What exactly goes wrong if you forget it, and how would you diagnose it — what would `kubectl get servicemonitor` show, and what would the Prometheus targets page show?
- **Q7.2** — The `PrometheusRule` carries `labels: {release: monitoring}`. Why? What is the equivalent knob you set on the Prometheus CR to make that unnecessary?
- **Q7.3** — Query (c) computes `1 - (policy_execution_sum / admission_review_sum)`. State two reasons this ratio can exceed 1.0 or go negative, and how you would guard the expression.
- **Q7.4** — The `KyvernoAdmissionLatencyHigh` alert uses `sum by (le, ...)` inside `histogram_quantile`. What happens if you omit `le` from the `by` clause, and what if you apply `histogram_quantile` before the `rate`?
- **Q7.5** — The scrape `interval` is 30 s and `scrapeTimeout` is 25 s. You then set `metricsRefreshInterval: 20s` in the metrics ConfigMap "to get fresher data". Describe the failure this produces in `increase()` and `rate()` results.

---

## Exercise 8 — Push mode: exporting to an OpenTelemetry Collector

### Steps

1. Deploy a minimal collector that accepts OTLP/gRPC and re-exposes a Prometheus endpoint:

```yaml
# otel-collector.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      batch:
        timeout: 10s
    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
      debug:
        verbosity: basic
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [prometheus, debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
        - name: collector
          image: otel/opentelemetry-collector-contrib:0.115.1
          args: ["--config=/conf/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
            - name: prom
              containerPort: 8889
          volumeMounts:
            - name: conf
              mountPath: /conf
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app: otel-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: prom
      port: 8889
      targetPort: prom
```

```bash
kubectl apply -f otel-collector.yaml
kubectl -n observability rollout status deploy/otel-collector
```

2. Switch the admission controller from pull to push. Read the current flags first, then patch:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'otel|metricsPort'
```

```bash
kubectl -n kyverno patch deploy kyverno-admission-controller --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--otelConfig=grpc"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--otelCollector=otel-collector.observability.svc.cluster.local"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--transportCreds="}
]'
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

> Later flags win on the Kyverno command line, so appending `--otelConfig=grpc` overrides the chart-rendered `--otelConfig=prometheus`. For a durable change, set the equivalent chart value instead of patching.

3. Generate traffic and confirm the metrics arrive at the collector, not at Kyverno:

```bash
kubectl -n team-a run web3 --image=nginx:1.27 --labels=team=payments
sleep 20

kubectl -n observability port-forward svc/otel-collector 8889:8889 &
curl -s http://127.0.0.1:8889/metrics | grep '^kyverno_admission_requests_total'
```

Expected output:

```
kyverno_admission_requests_total{exported_job="kyverno",instance="",job="kyverno",resource_kind="Pod",resource_request_operation="create"} 1
```

4. Confirm the Kyverno endpoint is now silent:

```bash
kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
curl -s -m 5 http://127.0.0.1:8000/metrics | grep -c '^kyverno_' || echo "no kyverno metrics served"
```

Expected output:

```
no kyverno metrics served
```

5. Revert to pull mode for the rest of the lab:

```bash
helm upgrade kyverno kyverno/kyverno -n kyverno --reuse-values
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

### Comprehension questions — block 8

- **Q8.1** — `--otelConfig` accepts `prometheus` or `grpc`. Beyond "pull vs push", give two operational properties that change when you move to `grpc` — one that improves and one that gets worse.
- **Q8.2** — `--transportCreds=` is set to the empty string. What does that configure, what is the production-correct value, and what is the risk of leaving it empty on a shared cluster?
- **Q8.3** — In the collector output the label `exported_job="kyverno"` appeared alongside `job="kyverno"`. What produced the `exported_` prefix, and why does it matter for dashboards written against pull-mode scrapes?

---

## Exercise 9 — Troubleshooting drill

Work through each symptom. Do not look at the answers until you have written down your own hypothesis ladder.

### Steps

1. **Symptom A.** Prometheus shows zero `kyverno_*` series. Run the diagnosis ladder in order and record what each rung proves:

```bash
# 1. Is metrics generation on at all?
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E 'disableMetrics|otelConfig|metricsPort'

# 2. Does the pod serve the endpoint?
kubectl -n kyverno exec deploy/kyverno-reports-controller -- true 2>/dev/null || \
kubectl -n kyverno run curl-probe --rm -it --restart=Never --image=curlimages/curl:8.11.0 -- \
  -s -o /dev/null -w '%{http_code}\n' http://kyverno-svc-metrics.kyverno.svc:8000/metrics

# 3. Does the Service select any endpoints?
kubectl -n kyverno get endpointslice -l kubernetes.io/service-name=kyverno-svc-metrics

# 4. Does a ServiceMonitor exist and does Prometheus own it?
kubectl -n kyverno get servicemonitor kyverno-admission-controller -o yaml | grep -A6 selector

# 5. Is the target registered?
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=dropped' \
  | jq -r '.data.droppedTargets[]?.discoveredLabels["__meta_kubernetes_service_name"]' | sort -u
```

2. **Symptom B.** Reproduce the multi-replica counter trap:

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=3
kubectl -n kyverno rollout status deploy/kyverno-admission-controller

for i in $(seq 1 20); do kubectl -n team-a run t$i --image=nginx:1.27 --labels=team=payments >/dev/null; done

q 'sum(increase(kyverno_admission_requests_total{resource_kind="Pod"}[10m]))'
q 'sum without (instance, pod) (increase(kyverno_admission_requests_total{resource_kind="Pod"}[10m]))'
```

3. **Symptom C.** Reproduce a cardinality incident and measure it:

```bash
for n in $(seq 1 40); do kubectl create namespace tenant-$n >/dev/null; done
for n in $(seq 1 40); do kubectl -n tenant-$n run p --image=nginx:1.27 >/dev/null; done
sleep 30

q 'count({__name__=~"kyverno_.+"})'
q 'topk(5, count by (__name__) ({__name__=~"kyverno_.+"}))'
```

4. **Symptom D.** A dashboard panel titled "Policies blocking deployments" uses:

```promql
sum by (policy_name) (kyverno_policy_results_total{rule_result="fail"})
```

The panel shows 4 policies. The platform team insists only 1 policy is in Enforce mode. Reconcile the two statements without changing the policies.

### Comprehension questions — block 9

- **Q9.1** — In Symptom A, rung 3 (`endpointslice`) returns an EndpointSlice with `addresses: []`. Which two rungs above it are now proven *irrelevant*, and what is the single most likely root cause?
- **Q9.2** — In Symptom B, both queries return the same number in this lab. Construct the scenario in which they differ, and state which of the two is always correct.
- **Q9.3** — In Symptom C, adding 40 namespaces multiplied the series count. Which metric families grew, which did not, and what single ConfigMap change would have capped the growth without losing per-policy visibility?
- **Q9.4** — In Symptom D, explain the discrepancy in one sentence, then write the corrected PromQL for the panel — including the fix for the counter-reset problem the original query also has.

---

## Answers

<details>
<summary><strong>Click to reveal the answers to all comprehension questions</strong></summary>

### Block 1 — Mapping the metrics surface

**A1.1** — Since 1.11 Kyverno is split into four independently scalable Deployments: the admission controller (webhook request path), the background controller (background scans and `UpdateRequest` processing for generate/mutate-existing), the reports controller (PolicyReport aggregation) and the cleanup controller (`CleanupPolicy` cron deletions). Each is a separate process with its own OpenTelemetry meter provider, so each has its own `/metrics`. If you only scrape `kyverno-svc-metrics` you get the admission path and nothing else: you lose all `rule_execution_cause="background_scan"` results, all `kyverno_cleanup_controller_deletedobjects_total`, and the work-queue health (`kyverno_controller_drop_total`, `_requeue_total`) of the three non-admission controllers — exactly the metrics you need when reports go stale or generate rules stop firing. The admission path stays green while the rest of Kyverno silently degrades.

**A1.2** — `kyverno-svc:443` is the `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` target: mutual-TLS, called by the kube-apiserver, backed by container port 9443. `kyverno-svc-metrics:8000` is the plaintext Prometheus exposition, backed by container port 8000 (`metrics-port`). They must stay separate because the webhook port is reachable by the API server and terminates a TLS session whose CA bundle is managed by Kyverno; exposing an unauthenticated `/metrics` handler on that same listener would leak policy names, namespace names and resource kinds — a cluster-topology disclosure — to anything that can reach the webhook, and it would put non-critical handler work on the latency-critical admission listener. Separate ports also let you apply a NetworkPolicy that admits the API server on 9443 and only Prometheus on 8000.

**A1.3** — `--disableMetrics` (default `false`, i.e. metrics *on*) and `--otelConfig` (default `prometheus`, i.e. serve a pull endpoint). Both must hold their defaults for a scrape to succeed: `--disableMetrics=true` stops metric recording entirely, and `--otelConfig=grpc` keeps recording but pushes to a collector and stops serving `/metrics`. `--metricsPort` (default `8000`) determines *where*, but it cannot rescue either of the other two.

**A1.4** — The Service selector would then match every Kyverno pod that carries `app.kubernetes.io/instance: kyverno` and `app.kubernetes.io/part-of: kyverno` — all four controllers. The Service's EndpointSlice would list four pod IPs on port 8000, and Prometheus (scraping via the Service in a plain `static`/`kubernetes_sd` endpoints setup) would attribute *all four controllers'* metrics to the job `kyverno-admission-controller`. Symptoms: `kyverno_cleanup_controller_deletedobjects_total` appearing under the admission job, and counters that look like they jump erratically because different pods with different `instance` labels export different values for the same family. Note that a Prometheus Operator `ServiceMonitor` scrapes each endpoint separately with its own `pod`/`instance` label, so the series are still distinguishable — but every dashboard filtering on `job` is now wrong.

---

### Block 2 — Reading the raw exposition

**A2.1** — Kyverno does not use the Prometheus client library directly; it instruments with the **OpenTelemetry Go SDK** and renders Prometheus text through the OTel `prometheus` exporter. That exporter stamps every series with the instrumentation *scope* that created the instrument — `otel_scope_name` (here `kyverno`) and `otel_scope_version` — plus a `target_info` gauge carrying the OTel resource attributes. The practical consequences: (a) these labels are not in the Kyverno docs because they are not Kyverno's, (b) they add a constant label pair to every series, so `sum without (...)` and `group_left` joins must account for them, and (c) the same instruments can be exported over OTLP/gRPC with no code change — which is what Exercise 8 exploits.

**A2.2** — Two causes, both real. First, **counter resets**: the value is per-process, and when the admission controller pod restarts (rollout, OOM, node drain) its counters go back to zero. Second, **series churn**: when a policy or namespace stops producing traffic, its series eventually stop being exported (aided by `metricsRefreshInterval`), and a bare `sum()` of a vanishing series drops it from the total. The correct query never reads a counter's raw value:

```promql
sum by (rule_result) (increase(kyverno_policy_results_total[1h]))
```

`rate()`/`increase()` are reset-aware — they detect the drop to a lower value and treat it as a restart rather than a negative delta.

**A2.3** — Prometheus naming conventions reserve the `_total` suffix for counters ([prometheus.io/docs/practices/naming/](https://prometheus.io/docs/practices/naming/)); a `_total`-suffixed gauge violates that and will confuse anyone (and any linter or auto-generated dashboard) that infers type from the name. The value is **not** a cumulative count — it is `1` while the rule described by the label set is currently loaded in the engine, i.e. an *info-style* gauge whose entire payload is its label set. You therefore query it with `== 1`, `count()`, or as a `group_left` join target — never with `rate()` or `increase()`.

**A2.4** — A Prometheus histogram exposes `<name>_bucket{le="..."}` (cumulative counts per upper bound, including `le="+Inf"`), `<name>_sum` (total of all observed values) and `<name>_count` (number of observations, equal to the `+Inf` bucket). `histogram_quantile()` consumes the **`_bucket`** series, and it requires the `le` label to be preserved through any aggregation:

```promql
histogram_quantile(0.95, sum by (le) (rate(kyverno_admission_review_duration_seconds_bucket[5m])))
```

---

### Block 3 — Attributing latency

**A3.1** — One admission request fans out to *N* rule evaluations, where *N* is the number of rules across all policies whose `match`/`exclude` selects that resource. `kyverno_admission_requests_total` counts **AdmissionReview requests** (one per API write that reaches the webhook); `kyverno_policy_results_total` counts **rule results** (one per rule evaluated). For team-a, 2 requests × (1 team-label rule + 1 latest-tag rule) = 4 results, so the two numbers legitimately differ.

For a "% of requests blocked" SLI the correct denominator is `kyverno_admission_requests_total`, because that is the unit the user experiences (one `kubectl apply` that failed). Using `kyverno_policy_results_total` as the denominator gives you "% of rule evaluations that failed", which is a policy-quality metric, not an availability metric — and it moves whenever you add an unrelated policy, because the denominator grows while user-visible failures stay constant.

**A3.2** — The engine's rule evaluation is sub-millisecond; the review duration is end-to-end inside Kyverno. The gap is everything around the evaluation:

1. **Deserialisation and policy selection** — unmarshalling the AdmissionReview, building the `PolicyContext`, resolving which policies match, and applying the resource cache / deferred loading.
2. **External data resolution** — `context` entries: `configMap` lookups, `apiCall` requests back to the API server, `globalReference`, and for `verifyImages` rules a network round trip to the OCI registry and to Rekor/Fulcio. These are the dominant contributor in real clusters and are *not* counted in the per-rule execution histogram in the same way.
3. **Report generation and response marshalling** — building the AdmissionReport object, generating the JSON patch for mutate rules, computing the response, plus Go GC and scheduler latency inside a resource-constrained pod.

Also, on a cold pod the first request pays informer sync and JMESPath/CEL compilation costs. Operationally: when the ratio in query (c) of Exercise 7 is high, look at `kyverno_client_queries_total` and at `verifyImages` rules before you blame the engine.

**A3.3** — `policy_validation_mode` describes the **validate** failure action (`Audit` or `Enforce`). A mutate rule has no failure action — it either patches or it does not; it cannot "audit" a mutation. Kyverno emits `-` as the explicit *not applicable* sentinel. The same applies to generate and cleanup rules.

**A3.4** — The other value is `background_scan`, emitted by the **background controller** when it re-evaluates existing resources on a schedule or after a policy change (only for policies with `background: true`). Distinguishing the two is essential: admission-cause results measure your webhook's live blocking behaviour, while background-scan results measure your *existing fleet's* compliance and will show violations for resources that were admitted before the policy existed. Mixing them in one panel makes a policy rollout look like a flood of new denials when nothing was actually blocked.

**A3.5** —

```promql
histogram_quantile(0.99,
  sum by (le, resource_kind) (rate(kyverno_admission_review_duration_seconds_bucket[5m]))
) / 10
```

…alerting when this exceeds ~0.3 (30 % of the timeout budget). The `_count` series alone tells you only *how many* reviews happened, not how long any of them took; and the mean derived from `_sum / _count` hides the tail — the p99 is what trips a 10-second timeout. The stakes with `failurePolicy: Fail` are that a timeout is not "policy skipped", it is **the API write is rejected**: a Kyverno latency regression becomes a cluster-wide inability to create resources. Complement the quantile with a direct budget query on the bucket boundaries:

```promql
1 - (
  sum(rate(kyverno_admission_review_duration_seconds_bucket{le="5"}[5m]))
  / sum(rate(kyverno_admission_review_duration_seconds_count[5m]))
)
```

— the fraction of reviews slower than 5 s, i.e. halfway to the cliff.

---

### Block 4 — Rule inventory and lifecycle

**A4.1** — `metricsRefreshInterval` in the `kyverno-metrics` ConfigMap. Gauge and counter series are held in the exporter's registry for the life of the process; without a reset, every policy and every resource namespace that ever produced a sample stays exported forever, so the endpoint grows monotonically and Prometheus keeps ingesting series for objects that no longer exist. `metricsRefreshInterval` periodically tears down and re-registers the meter provider, dropping series that are no longer being written. It is a cardinality-bleed control, not a freshness control.

**A4.2** — An empty label value in Prometheus is indistinguishable from *the label being absent*: `{policy_namespace=""}` matches series that never had the label at all, and `sum by (policy_namespace)` collapses "cluster-scoped" together with any series where the label was dropped by `disabledLabelDimensions`. Using the literal `-` makes cluster scope an explicit, matchable value: `kyverno_policy_rule_info_total{policy_namespace="-"}` selects exactly the ClusterPolicies, and `!="-"` selects exactly the namespaced Policies. Without it you cannot write either query reliably.

**A4.3** —

```promql
max by (policy_name, rule_name) (kyverno_policy_rule_info_total{status_ready="false"}) == 1
```

`status_ready` is a **label**, not the value. The gauge's value is `1` for "this rule is currently loaded"; a not-ready rule is therefore `kyverno_policy_rule_info_total{status_ready="false"} = 1`. Writing `== 0` would match nothing in the normal case and would only ever fire on a transient value you should not depend on. The `max by (...)` collapses multiple admission-controller replicas reporting the same rule, so a 3-replica deployment produces one alert instance instead of three. Practically, a not-ready rule means Kyverno parsed the policy but could not activate it (bad `context` API call, missing CRD, RBAC gap for a generate/mutate-existing target) — the policy exists, appears in `kubectl get cpol`, and is enforcing nothing.

---

### Block 5 — Background, cleanup, and API pressure

**A5.1** — Background scans are not driven by an AdmissionReview, so there is no `CREATE`/`UPDATE`/`DELETE` operation to report; Kyverno emits the empty string. Consequently a query filtered on `resource_request_operation="create"` **silently excludes every background result**, which is the opposite of what most people intend when they build a compliance dashboard. Either filter on the cause explicitly (`rule_execution_cause="admission_request"`) — clearer and self-documenting — or drop the operation filter and aggregate with `sum without (resource_request_operation)`.

**A5.2** — Only the admission controller runs the webhook server, so only it ever receives an AdmissionReview; the background, reports and cleanup controllers reconcile through informers and the API, never through the webhook path. Those two metric families therefore cannot exist elsewhere. The families present on **all four** are the controller-runtime work-queue set — `kyverno_controller_reconcile_total`, `kyverno_controller_requeue_total`, `kyverno_controller_drop_total` — plus `kyverno_client_queries_total`; every controller has queues and every controller talks to the API server. (Note `kyverno_client_queries_total` disappears if you disabled it in Exercise 6.)

**A5.3** — In a controller-runtime rate-limiting work queue, an item that fails is requeued with backoff up to a maximum number of attempts (`num_requeues` on the requeue metric); when that ceiling is reached the item is **dropped** — forgotten, never retried, no error surfaced to the user. For the reports controller the user-visible symptom is **stale or missing PolicyReports**: `kubectl get polr` shows results that do not reflect the current cluster state, compliance dashboards under-report violations, and nothing in the Kyverno logs looks like an outage. This is the single most under-monitored Kyverno failure mode; `rate(kyverno_controller_drop_total[10m]) > 0` sustained is always a real incident.

**A5.4** — The **metadata client** (`k8s.io/client-go/metadata`) requests objects with `Accept: application/json;as=PartialObjectMetadata`, so the API server returns only `TypeMeta` + `ObjectMeta` — name, namespace, labels, annotations, ownerRefs — and never the spec or status. Kyverno uses it wherever it only needs identity and labels: report ownership, garbage collection of reports, and matching resources by selector. High `client_type="metadata"` counts are good news because each of those queries transfers a fraction of the bytes a full object would, and it keeps large objects out of Kyverno's informer caches — the difference between a few hundred MB and several GB of RSS on a cluster with many Secrets or ConfigMaps. The signal to worry about is high `client_type="dynamic"` with `operation="List"`, which means full-object list calls against the API server.

---

### Block 6 — Cardinality control

**A6.1** — `0` disables the periodic refresh: the meter provider is never torn down, so every series ever emitted is exported for the lifetime of the process. Setting `6h` makes Kyverno reset and re-register its instruments every six hours, dropping series for policies, namespaces and resource kinds that are no longer producing data — that is the cardinality bleed control.

What you lose: **all counters restart from zero at each refresh**. `increase()` and `rate()` handle this correctly because they are reset-aware, but any dashboard or query reading a raw counter value ("total denials since install") becomes meaningless, and an `increase()` over a window *longer than* the refresh interval loses accuracy at the boundary. Rule: set `metricsRefreshInterval` comfortably longer than your longest query range, and never read raw counter values.

**A6.2** — `namespaces.exclude` filters **metric emission**, keyed on the *resource's* namespace (`resource_namespace`). It does not filter policy evaluation, admission, or reporting: the `kube-system` Pod was still sent to the webhook, still evaluated by every matching rule, and still produced a PolicyReport. What changed is only that no time series was recorded for it.

This is a blind spot you must document explicitly, because the invariant "we can see everything Kyverno does" is now false for those namespaces. Concretely: an Enforce-mode policy that starts blocking `kube-system` workloads — breaking CNI, CSI or DNS pods — will produce **zero** signal in Prometheus and **zero** alert firing, while the cluster degrades. The correct pattern is to exclude namespaces from *metrics* only where you also exclude them from *policy* (via the Kyverno `resourceFilters` in the main `kyverno` ConfigMap), so the two exclusions stay in lockstep. If a namespace is policed, it must be measured.

**A6.3** — Yes, it is consistent. `disabledLabelDimensions` is configured **per metric family**, not globally. The applied config removes `resource_namespace` *and* `resource_kind` from `kyverno_policy_results_total`… but the second sample still shows `resource_kind="Pod"`.

That inconsistency is the point of the question: if you observe it in your own lab, it means the pod serving that sample had **not** picked up the new ConfigMap — you are looking at a series recorded by the pre-restart process (or by a second replica that was not restarted), and the exporter is still holding it. It resolves on the next `metricsRefreshInterval` or on a full rollout of every replica. The lesson: after changing `metricsExposure`, verify on **every** pod (`kubectl get pods -l app.kubernetes.io/component=admission-controller`) and confirm the old label is absent from *all* samples, not just the first one `grep` returns. Do not assume hot reload; roll the Deployment.

**A6.4** — A histogram with *B* configured boundaries exports `B + 1` bucket series (the boundaries plus `+Inf`), plus `_sum` and `_count` — so `B + 3` series per label combination.

- Before: `(15 + 3) × 40 = 720` series
- After: `(11 + 3) × 40 = 560` series
- Removed: **160 series**

The general formula is `Δseries = (B_before − B_after) × L`, where *L* is the number of distinct label combinations. Note how the multiplier works against you: cutting four boundaries saved 160 series here, but on a cluster where `L` is 5 000 (many namespaces × many kinds) the same four boundaries cost 20 000 series. Reducing *L* via `disabledLabelDimensions` is almost always the higher-leverage change.

**A6.5** — You lose the ability to diagnose **Kyverno-induced API-server pressure**: the incident where the API server's latency and priority-and-fairness queues degrade and you need to prove whether Kyverno is a cause or a victim. `kyverno_client_queries_total` broken down by `client_type` and `operation` is the direct evidence — e.g. a `context.apiCall` in a hot policy issuing a `List` per admission request, or an informer resync storm after a rollout.

Alternatives, in descending order of usefulness: the API server's own `apiserver_request_total{user_agent=~"kyverno.*"}` and `apiserver_flowcontrol_*` metrics (authoritative, and outside Kyverno's control so they survive Kyverno being down); audit logs filtered by the Kyverno service accounts; and, as a weak proxy, the gap between `kyverno_admission_review_duration_seconds` and `kyverno_policy_execution_duration_seconds` from question A3.2, which grows when context lookups are the bottleneck. Given that the API server metric exists, disabling `kyverno_client_queries_total` is a defensible trade on a very large cluster — but only if you have confirmed the API server side is scraped.

---

### Block 7 — Prometheus, PromQL, alerts

**A7.1** — `kube-prometheus-stack` defaults the Prometheus CR's `serviceMonitorSelector` to `{matchLabels: {release: <helm-release-name>}}`, so it only adopts ServiceMonitors carrying that label. Kyverno's chart does not add it. Forgetting the flag means Kyverno's four ServiceMonitors are created and healthy but **never adopted**.

Diagnosis: `kubectl -n kyverno get servicemonitor` shows all four objects (so the resource exists — this rung proves nothing), while the Prometheus **Targets** page shows no `kyverno-*` job at all — not "down", *absent*. Confirm by reading what Prometheus actually selects:

```bash
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.serviceMonitorNamespaceSelector}'
```

and by checking the generated scrape config (`kubectl -n monitoring get secret prometheus-<name> -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep kyverno`). Two fixes: set `serviceMonitorSelectorNilUsesHelmValues=false` (adopt everything), or label Kyverno's ServiceMonitors with `release: monitoring` via `--set admissionController.serviceMonitor.additionalLabels.release=monitoring`. The second is the better production choice — it keeps the selector meaningful.

**A7.2** — Same mechanism, different field: the Prometheus CR's `ruleSelector` also defaults to `{matchLabels: {release: <release>}}`, so a `PrometheusRule` without that label is ignored — silently, with no error on `kubectl apply`. Adding `labels: {release: monitoring}` makes it adoptable. The equivalent CR-side knob is `prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false` (used at install time in step 1), which nils the selector so all `PrometheusRule` objects in watched namespaces are adopted. Also verify `ruleNamespaceSelector` covers the namespace you deployed into.

**A7.3** — Two reasons it can go out of range:

1. **Different denominators.** `kyverno_policy_execution_duration_seconds` is emitted for background-scan executions too, while `kyverno_admission_review_duration_seconds` only exists for admission requests. During a background scan the numerator includes work the denominator never saw, so the ratio can exceed 1 and the expression goes negative. Constrain the numerator: `{rule_execution_cause="admission_request"}`.
2. **Divide-by-zero / no traffic.** With no admission requests in the window, the denominator's `rate()` is 0 or the series is absent, giving `+Inf` or an empty result.

Guarded version:

```promql
clamp_min(
  clamp_max(
    1 - (
      sum(rate(kyverno_policy_execution_duration_seconds_sum{rule_execution_cause="admission_request"}[5m]))
      /
      clamp_min(sum(rate(kyverno_admission_review_duration_seconds_sum[5m])), 0.0001)
    ), 1),
  0)
```

A third, subtler reason: with multiple replicas the two families are summed across the same pod set, so a pod that restarted mid-window contributes a reset to one family and not the other. Keep the window short relative to restart frequency.

**A7.4** — Omitting `le` from the `by` clause sums the bucket series *across* upper bounds, destroying the cumulative structure the histogram encodes. `histogram_quantile()` then either returns `NaN` or a nonsense value — and, critically, it does not error, so the panel shows a plausible-looking number that is simply wrong. `le` must always survive the aggregation.

Applying `histogram_quantile()` before `rate()` is wrong in a different way: the raw `_bucket` series are monotonically increasing counters over the process's whole lifetime, so the quantile you compute is the all-time quantile since pod start, heavily weighted by history and unable to show a current regression — and it breaks entirely at a counter reset. The invariant is: **`rate()` first (per-`le`), aggregate second (keeping `le`), `histogram_quantile()` last.**

**A7.5** — A `metricsRefreshInterval` shorter than — or close to — the scrape interval means the counters reset *between* scrapes, sometimes more than once. Prometheus detects a counter reset by seeing a value lower than the previous sample and compensates by adding the pre-reset value; that logic is only correct when it observes at least one sample on each side of the reset. With a 20 s reset and a 30 s scrape, Prometheus frequently sees a reset it cannot bound, and increments that occurred entirely inside a reset window are lost forever.

Symptoms: `rate()` and `increase()` systematically **under-report**, with a jagged, spiky graph; totals do not reconcile with reality; and alerts on denial rate never fire because the rate is always near zero. The rule is `metricsRefreshInterval >> scrape_interval` — hours, not seconds. The default of `0` (never) and the recommended `6h`–`24h` values exist for exactly this reason; the setting is a cardinality control, and treating it as a freshness control corrupts every counter-derived query you have.

---

### Block 8 — OTLP push mode

**A8.1** — Improves: **no inbound network path required.** In push mode Kyverno initiates an outbound gRPC connection to the collector, so you no longer need Prometheus to reach port 8000 on every Kyverno pod. That removes NetworkPolicy and firewall exceptions, works across cluster and VPC boundaries, and makes short-lived pods safe — metrics recorded just before a pod exits are exported rather than lost between scrapes. It also unlocks the collector's processor pipeline (batching, filtering, attribute rewriting, tail sampling, fan-out to multiple backends) without touching Kyverno.

Gets worse: **you lose scrape-based liveness and delivery guarantees.** With pull, a Prometheus target going `down` is itself a signal that Kyverno is unreachable, and `up == 0` alerts for free. With push, a Kyverno pod that stops exporting is indistinguishable from a Kyverno pod that has nothing to report — `absent()` is your only detector and it is slow and coarse. You also add a hard dependency on the collector: if it is down, saturated, or misconfigured, metrics are dropped in-flight (OTLP export failures appear only in Kyverno's logs), and you now have a second component to capacity-plan, upgrade and monitor.

**A8.2** — `--transportCreds` is the path to a CA certificate file used to establish **TLS on the OTLP/gRPC connection to the collector**. The empty string selects an **insecure** (plaintext) gRPC connection. Production-correct is to mount a CA bundle into the Kyverno pod and pass its path, with the collector configured for TLS on its OTLP receiver.

The risk of leaving it empty on a shared cluster: the OTLP stream carries policy names, rule names, namespace names and resource kinds in cleartext across the pod network — a map of your security posture and cluster topology, useful to an attacker for finding which namespaces are unpoliced. There is also no server authentication, so any workload that can win the Service name (or intercept the traffic) can silently absorb Kyverno's telemetry, and nothing in Kyverno will report an anomaly.

**A8.3** — Prometheus renames a label on an ingested sample when it would collide with a label Prometheus itself attaches during scraping. Here the collector's `prometheus` exporter re-exposed a series that already carried `job="kyverno"` (from the OTel resource attributes / `target_info`), and when Prometheus scraped the collector it applied its own `job` label for the collector's target — so the original was preserved as `exported_job`. The same happens to `instance`.

Why it matters: **every dashboard and alert written against pull-mode scrapes breaks on the label set, not on the metric name.** Queries grouping by `job` now group by the collector, not by Kyverno; queries filtering `job="kyverno-admission-controller"` return nothing; and the `instance` label — which in pull mode identified the Kyverno pod — now identifies the collector, collapsing per-replica visibility. Fixes, in order of preference: set `honor_labels: true` on the Prometheus scrape of the collector (keeps the exported values under their original names), or normalise in the collector pipeline with a `transform`/`attributes` processor before the exporter. Verify the label set after any pull→push migration; the metric names surviving is not evidence the queries survived.

---

### Block 9 — Troubleshooting

**A9.1** — An EndpointSlice that exists but has no addresses proves the Service object and its selector are fine and that Prometheus-side configuration is not yet in play, so **rung 4 (ServiceMonitor selector) and rung 5 (target discovery) are irrelevant** — Prometheus cannot scrape an endpoint that does not exist, no matter how the ServiceMonitor is labelled. Rung 1 (flags) is also downstream of this: the process configuration cannot matter if no pod is backing the Service.

Most likely root cause: **no ready pod matches the Service selector.** Either the pods are not `Ready` (readiness probe failing, `CrashLoopBackOff`, image pull, pending scheduling), or the pod labels no longer match the selector — which happens after a chart upgrade that renames a component label, or when someone edits the Service. Check in that order:

```bash
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o wide
kubectl -n kyverno describe svc kyverno-svc-metrics | grep -i endpoints
```

An empty EndpointSlice with healthy `Running` pods means a **label mismatch**; an empty one with no pods listed means a **scheduling or crash** problem.

**A9.2** — They differ as soon as an individual pod's counter **resets** — a rollout, an OOM kill, an eviction, or the `metricsRefreshInterval` firing.

- `sum(increase(...))` applies `increase()` **per series first** (each pod's counter is reset-corrected in isolation), then adds the corrected increments. Correct.
- `sum without (instance, pod) (increase(...))` also computes `increase()` per series before summing — `sum without` here only controls which labels survive, so in this form it is equivalent.

The genuinely wrong form — the one this trap is about — is aggregating **before** the rate function:

```promql
increase(sum(kyverno_admission_requests_total{resource_kind="Pod"})[10m:])   # WRONG
```

Summing across pods first produces a composite series that dips whenever *any* single pod restarts, while the others keep climbing. `increase()` sees a dip smaller than a full reset and either misattributes it or discards the interval, so you under-count by roughly the restarting pod's accumulated total. **Always `rate()`/`increase()` per series, then `sum()`.** This is the same ordering invariant as A7.4.

**A9.3** — Grew: every family carrying `resource_namespace` — `kyverno_admission_requests_total`, `kyverno_admission_review_duration_seconds` (×(B+3) per namespace, the worst offender because it is a histogram), `kyverno_policy_results_total`, `kyverno_policy_execution_duration_seconds`, and `kyverno_client_queries_total`. The histograms dominate: 40 namespaces × 18 series each is 720 new series from one family.

Did not grow: `kyverno_policy_rule_info_total` and `kyverno_policy_changes_total` — both are keyed on `policy_namespace` (the namespace of the *policy*, `-` for ClusterPolicies), not on the resource's namespace. Neither did the controller queue metrics, which are keyed only on `controller_name`.

The single capping change is `disabledLabelDimensions: ["resource_namespace"]` on the offending families in `metricsExposure`. It removes the unbounded dimension — namespace count grows with tenants, forever — while keeping `policy_name`, `rule_name`, `rule_result` and `rule_type`, so per-policy visibility is fully intact. `namespaces.exclude` would *not* have worked here: you cannot enumerate tenant namespaces in advance, and excluding them would create the blind spot from A6.2 in exactly the namespaces you most need to watch.

**A9.4** — In one sentence: the panel counts **all** failing rule results including `Audit`-mode policies, which detect and report violations without blocking anything, so three of the four "blocking" policies are merely observing.

Corrected PromQL, fixing both the mode filter and the counter-reset problem in the original:

```promql
sum by (policy_name) (
  increase(
    kyverno_policy_results_total{
      policy_validation_mode="Enforce",
      rule_result="fail",
      rule_execution_cause="admission_request"
    }[1h]
  )
)
```

Three fixes, all necessary: `policy_validation_mode="Enforce"` restricts to policies that actually reject the request; `increase(...[1h])` replaces the raw counter value so pod restarts and `metricsRefreshInterval` resets do not corrupt the number (A2.2); and `rule_execution_cause="admission_request"` excludes background-scan violations, which are findings about pre-existing resources, not deployments that were blocked (A3.4). Without the third filter the panel spikes every time someone edits a policy and triggers a rescan — the classic false alarm that trains teams to ignore the dashboard.

Caveat worth stating on the panel itself: a rule in Enforce mode that fails does not *always* block, because `failureActionOverrides` can downgrade specific namespaces to Audit. If you use overrides, the label reflects the rule's declared mode and you must reconcile against `kyverno_admission_requests_total` to confirm the request was actually rejected.

</details>

---

## Sources

- Kyverno — Monitoring and metrics reference: <https://kyverno.io/docs/monitoring/>
- Kyverno — Installation and configuration (controller flags, metrics configuration): <https://kyverno.io/docs/installation/customization/>
- Kyverno Helm chart values (`metricsConfig`, `serviceMonitor`, `grafana`): <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml>
- Kyverno — Cleanup policies: <https://kyverno.io/docs/policy-types/cleanup-policy/>
- Prometheus — Metric and label naming conventions: <https://prometheus.io/docs/practices/naming/>
- Prometheus — Histograms, quantiles and `histogram_quantile`: <https://prometheus.io/docs/practices/histograms/>
- Prometheus Operator — `ServiceMonitor` and `PrometheusRule` API: <https://prometheus-operator.dev/docs/api-reference/api/>
- OpenTelemetry Collector — configuration and receivers: <https://opentelemetry.io/docs/collector/configuration/>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum>