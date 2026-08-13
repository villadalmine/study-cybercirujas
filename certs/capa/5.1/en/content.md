# Topic 5.1 — Argo Events

> **CAPA domain 5 · Exam weight: 20 %**
> Event-driven automation for Kubernetes. This is one of the two heaviest domains on the CAPA blueprint, so the depth here is deliberate: you are expected to reason about the *dependency graph*, the *event bus as a distributed messaging substrate*, and the *failure modes* — not just to recognise a `Sensor` manifest.

---

## 1. Motivation and the production architectural problem

### 1.1 The gap Argo Events fills

Argo Workflows answers "how do I run a DAG of containers to completion". It does **not** answer "*when* should that DAG run, and *because of what*". In a naïve platform you end up with a proliferation of glue: a Lambda that pokes the Argo Server API on an S3 event; a cron sidecar polling a webhook; a bespoke controller watching a `ConfigMap`; a Slack bot shelling out `kubectl create`. Each is a separate deployment, a separate auth boundary, a separate place secrets leak, and a separate thing that fails silently at 03:00.

Argo Events collapses that glue into **three declarative CRDs** and a **durable message bus**, all running inside the cluster, all reconciled by controllers, all observable through the same Prometheus/`kubectl` surface as the rest of the platform.

```
   ┌────────────┐    CloudEvents    ┌───────────┐    subscribe   ┌──────────┐   trigger
   │ EventSource│ ────────────────▶ │ EventBus  │ ─────────────▶ │  Sensor  │ ────────▶  Workflow
   │  (adapter) │   publish (pub)   │ (NATS/JS) │   (sub)        │ (rules)  │            K8s obj
   └────────────┘                   └───────────┘                └──────────┘            HTTP / Lambda
        ▲                            durable, replicated              │  Kafka / Slack …
        │ external stimulus          (StatefulSet)                    │
   webhook · S3 · SQS · Kafka                                   dependency graph +
   calendar · GitHub · resource                                filters + parameters
```

The three responsibilities are cleanly separated:

| CRD | Responsibility | Runtime artifact |
|---|---|---|
| **EventSource** | *Ingest.* Adapts an external stimulus (webhook, S3, Kafka, cron, a K8s resource change…) into a **CloudEvent** and **publishes** it to the EventBus. | a `Deployment` (the "eventsource pod") |
| **EventBus** | *Transport.* A durable, replicated pub/sub backbone that decouples producers from consumers and survives sensor restarts. | a `StatefulSet` (NATS/JetStream) or an external Kafka |
| **Sensor** | *React.* **Subscribes**, evaluates a **dependency graph** with **filters**, parameterises and fires one or more **triggers**. | a `Deployment` (the "sensor pod") |

### 1.2 Why a bus in the middle — the architectural crux

The non-obvious design decision is the **EventBus** sitting between source and sensor. You could imagine the EventSource calling the Sensor directly over HTTP. Argo Events deliberately does not, and understanding *why* is the heart of this topic:

- **Temporal decoupling / durability.** If the Sensor pod is restarting (deploy, OOM, node drain) when the event lands, a direct HTTP push would be lost. With a durable bus the event is persisted and delivered when the subscriber reconnects — this is what makes **`atLeastOnce`** semantics possible.
- **Fan-out.** One event (`github push`) can fan out to N independent Sensors (build, notify, audit) without the EventSource knowing they exist.
- **Multi-dependency joins.** A Sensor can require `A AND B` where A and B arrive minutes apart from *different* sources. That join needs a place to hold A while it waits for B — the bus (plus the sensor's internal state) provides it.
- **Back-pressure & flow control.** JetStream consumers ack messages; a slow Sensor does not drop events, it lags. You can see and alarm on that lag.

The trade-off you are buying: an EventBus is **stateful infrastructure** (a 3-replica quorum StatefulSet with PVCs) that you now have to run, patch, and reason about split-brain for. That is the price of exactly-`atLeastOnce` delivery.

### 1.3 The production failure this prevents

The classic outage: an S3 upload was supposed to kick off an ingestion Workflow, it didn't, and nobody noticed for six hours because the "glue Lambda" swallowed a 5xx from the Argo API and returned 200. In the Argo Events model that same path is: EventSource pod (with metrics on events read/sent), EventBus (with consumer-lag metrics), Sensor pod (with `triggers_total` / `action_failed_total`), and every hop is a Kubernetes object you can `describe` and a Prometheus series you can alert on. The silent gap becomes a visible one.

---

## 2. Technical comparisons and trade-offs

### 2.1 EventBus implementations

The EventBus is pluggable. Choosing wrong here is the single most common production regret, because migrating a bus in place is disruptive.

| Implementation | `spec.` key | Delivery | State | When to use | Watch out for |
|---|---|---|---|---|---|
| **NATS Streaming (STAN)** | `nats.native` | at-least-once | StatefulSet + PVC | *Legacy only.* | **Deprecated & EOL upstream.** Do not choose for new clusters. |
| **JetStream** | `jetstream` | at-least-once, ack'd, replayable | StatefulSet + PVC, RAFT quorum | **Default recommendation** for all new installs. | Needs odd `replicas` (3/5) for quorum; PVC sizing for retention. |
| **Kafka (external)** | `kafka` | at-least-once | *You already run Kafka* | You have an existing, operated Kafka and want one bus. | Argo does not manage it; topic/ACL lifecycle is on you. |

**Rule of thumb:** new cluster → `jetstream`, `replicas: 3`, persistent volumes. Only reach for `kafka` when Kafka already exists as a first-class platform service.

### 2.2 EventSource vs. an ad-hoc adapter

| Concern | EventSource | Home-grown controller / Lambda |
|---|---|---|
| Reconciliation | Controller-managed Deployment, self-heals | You own the Deployment/lifecycle |
| Observability | Built-in Prometheus metrics, `kubectl describe` | Whatever you added |
| Auth to bus | Managed EventBus auth (token/none) | You wire it |
| Event format | CloudEvents 1.0 (portable) | Ad-hoc JSON |
| Failure surface | 1 CRD | N moving parts |

### 2.3 Trigger types (Sensor side)

| Trigger `template.*` | Purpose | Typical `operation` / knobs |
|---|---|---|
| `argoWorkflow` | Submit/operate an Argo Workflow (first-class) | `submit`, `resubmit`, `retry`, `resume`, `suspend`, `terminate` |
| `k8s` | Create/patch/update any K8s object generically | `create`, `update`, `patch`, `delete` |
| `http` | Call an arbitrary HTTP endpoint | method, url, payload, secure headers |
| `awsLambda` | Invoke a Lambda | region, function, creds |
| `kafka` | Produce to a Kafka topic | url, topic, partition |
| `nats` / `pulsar` | Publish to a messaging system | subject/topic |
| `slack` | Post to Slack | channel, message |
| `azureEventHubs`, `openWhisk`, `log`, `custom` | Cloud fns / debug / gRPC plugin | — |

`argoWorkflow` vs `k8s` for launching Workflows: prefer **`argoWorkflow`** — it understands Workflow-specific operations (retry, resubmit, terminate) that a generic `k8s` create cannot express, and it names Workflows with a generated suffix so repeated events don't collide.

### 2.4 Delivery-semantics trade-off (exam-relevant)

| Setting | Guarantee | Cost |
|---|---|---|
| `sensor.spec.triggers[].atLeastOnce: false` (default) | Trigger *at most once* per event; on ambiguous failure it is **not** retried after ack | A genuinely-executed-but-unacked trigger is dropped → possible **missed** run |
| `atLeastOnce: true` | Message re-delivered until the trigger acks success | Possible **duplicate** trigger → the target action must be **idempotent** |

There is no exactly-once. You choose which failure you can tolerate and design the trigger accordingly (e.g. name the Workflow deterministically so a duplicate submit is a harmless conflict).

---

## 3. Complete manifests and infrastructure (uncut)

### 3.1 Install

```bash
# Namespace + CRDs + controller + validating webhook
kubectl create namespace argo-events
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml

# Optional but recommended: the validating admission webhook
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install-validating-webhook.yaml
```

### 3.2 EventBus — JetStream, 3-replica, persistent (production baseline)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default            # the name 'default' is what EventSource/Sensor use implicitly
  namespace: argo-events
spec:
  jetstream:
    version: latest        # pin to a concrete tag in prod, e.g. 2.10.10
    replicas: 3            # odd number → RAFT quorum; survives one pod loss
    persistence:
      storageClassName: standard
      accessMode: ReadWriteOnce
      volumeSize: 10Gi
    # Stream retention: how long unacked/observed events are kept
    streamConfig: |
      maxAge: 72h
      maxBytes: 1GB
      replicas: 3
    metrics:
      enabled: true
    containerTemplate:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: "1"
          memory: 512Mi
```

### 3.3 EventSource — webhook (canonical "hello world" ingress)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
  namespace: argo-events
spec:
  # The controller creates a Service exposing these ports
  service:
    ports:
      - name: default
        port: 12000
        targetPort: 12000
  webhook:
    # 'orders' is the eventName that Sensors will reference
    orders:
      port: "12000"
      endpoint: /orders
      method: POST
```

### 3.4 EventSource — an S3/Minio bucket (real-world ingest)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: minio
  namespace: argo-events
spec:
  minio:
    landing-bucket:
      bucket:
        name: incoming
      endpoint: minio.storage.svc:9000
      events:
        - s3:ObjectCreated:Put
      filter:
        prefix: raw/
        suffix: .csv
      insecure: true
      accessKey:
        name: minio-creds
        key: accesskey
      secretKey:
        name: minio-creds
        key: secretkey
```

### 3.5 Sensor — full production trigger: filters + parameters + policy + retry + rate-limit

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: order-processor
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa   # MUST be able to create Workflows (see RBAC)
  # Boolean dependency graph: this trigger fires only when the expression is true
  dependencies:
    - name: order-dep
      eventSourceName: webhook
      eventName: orders
      # Filters run inside the sensor BEFORE the trigger; a filtered-out event acks and is dropped
      filters:
        dataLogicalOperator: "and"
        data:
          - path: body.action
            type: string
            comparator: "="
            value:
              - "created"
          - path: body.amount
            type: number
            comparator: ">="
            value:
              - "100"
        exprs:
          - expr: 'region in ["us-east-1","us-west-2"]'
            fields:
              - name: region
                path: body.region
  triggers:
    - template:
        name: launch-order-workflow
        # conditions lets you compose multiple dependencies: "order-dep && audit-dep"
        conditions: "order-dep"
        argoWorkflow:
          operation: submit
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: process-order-   # generateName → duplicate-safe naming
              spec:
                serviceAccountName: workflow-runner
                entrypoint: main
                arguments:
                  parameters:
                    - name: order-id
                      value: PLACEHOLDER        # overwritten by parameters below
                    - name: amount
                      value: "0"
                templates:
                  - name: main
                    container:
                      image: ghcr.io/acme/order-processor:1.4.2
                      args: ["--order", "{{workflow.parameters.order-id}}",
                             "--amount", "{{workflow.parameters.amount}}"]
          # Inject event data into the Workflow at trigger time
          parameters:
            - src:
                dependencyName: order-dep
                dataKey: body.orderId
              dest: spec.arguments.parameters.0.value
            - src:
                dependencyName: order-dep
                dataKey: body.amount
              dest: spec.arguments.parameters.1.value
      # Retry the TRIGGER (not the Workflow) on transient failures firing it
      retryStrategy:
        steps: 3
        duration: 3s
        factor: 2.0
        jitter: 0.1
      # Cap how fast this trigger may fire
      rateLimit:
        unit: Second
        requestsPerUnit: 20
      # Consider the trigger successful only if the created Workflow reaches this state
      policy:
        k8s:
          labels:
            workflows.argoproj.io/phase: Succeeded
          backoff:
            duration: "3s"
            steps: 10
            factor: 2.0
          errorOnBackoffTimeout: true
```

### 3.6 RBAC — the single most common "it silently does nothing" cause

A Sensor's pod uses its ServiceAccount to create the triggered object. If it lacks the verb, the trigger fails. Wire it explicitly:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: operate-workflow-sa
  namespace: argo-events
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: operate-workflow-role
  namespace: argo-events
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "cronworkflows", "workflowtaskresults"]
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operate-workflow-binding
  namespace: argo-events
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: operate-workflow-role
subjects:
  - kind: ServiceAccount
    name: operate-workflow-sa
    namespace: argo-events
```

---

## 4. CLI commands and real terminal output

### 4.1 Confirm the control plane is up

```console
$ kubectl -n argo-events get deploy
NAME                             READY   UP-TO-DATE   AVAILABLE   AGE
argo-events-controller-manager   1/1     1            1           4m12s

$ kubectl -n argo-events get eventbus
NAME      TYPE        AGE
default   JetStream   3m2s

$ kubectl -n argo-events get statefulset
NAME                READY   AGE
eventbus-default-js 3/3     3m2s
```

### 4.2 Apply source + sensor and watch the derived Deployments appear

```console
$ kubectl apply -f eventsource-webhook.yaml
eventsource.argoproj.io/webhook created

$ kubectl apply -f sensor-order.yaml
sensor.argoproj.io/order-processor created

$ kubectl -n argo-events get pods -l 'controller in (eventsource-controller,sensor-controller)'
NAME                                        READY   STATUS    RESTARTS   AGE
webhook-eventsource-xxxxx-abcde             1/1     Running   0          25s
order-processor-sensor-yyyyy-fghij          1/1     Running   0          20s

$ kubectl -n argo-events get svc webhook-eventsource-svc
NAME                      TYPE        CLUSTER-IP      PORT(S)     AGE
webhook-eventsource-svc   ClusterIP   10.96.140.22    12000/TCP   30s
```

### 4.3 Fire an event and observe the trigger

```console
$ kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
$ curl -sS -X POST http://localhost:12000/orders \
    -H 'Content-Type: application/json' \
    -d '{"action":"created","orderId":"ORD-9001","amount":150,"region":"us-east-1"}'
success

$ kubectl -n argo-events get workflows
NAME                  STATUS      AGE
process-order-4t7xq   Running     3s

$ kubectl -n argo-events logs -l sensor-name=order-processor --tail=5
... level=info msg="succeeded to publish a message" ...
... level=info msg="Successfully processed trigger 'launch-order-workflow'" triggerType=ArgoWorkflow
```

### 4.4 A filtered-out event: acked, dropped, no trigger

```console
$ curl -sS -X POST http://localhost:12000/orders \
    -d '{"action":"created","orderId":"ORD-9002","amount":5,"region":"us-east-1"}'
success

$ kubectl -n argo-events logs -l sensor-name=order-processor --tail=3
... level=info msg="Applying filters on dependency 'order-dep'"
... level=info msg="event is filtered out" dependency=order-dep reason="data filter: body.amount >= 100 not satisfied"
```

Note `success` was returned to the caller — the EventSource acknowledges receipt; the *filter* decision happens later, inside the Sensor. This asymmetry surprises people during diagnosis.

---

## 5. Verification and failure-diagnosis guide

Work the pipeline **left to right**; each hop has its own evidence.

### 5.1 Is the EventBus healthy?

```console
$ kubectl -n argo-events describe eventbus default | sed -n '/Status/,$p'
Status:
  Config:
    Js:
      Auth:      token
      Url:       nats://eventbus-default-js-svc:4222
  Conditions:
    Type:      Deployed        Status: True
    Type:      ConfigMapReady   Status: True
```

- **All 3 StatefulSet pods Ready?** A JetStream quorum needs a majority. `2/3` still serves; `1/3` loses quorum and everything stalls.
- **PVCs Bound?** `kubectl -n argo-events get pvc`. An unbound PVC → pods stuck `Pending` → whole bus down.

### 5.2 Is the EventSource actually publishing?

```console
$ kubectl -n argo-events logs deploy/webhook-eventsource --tail=20 | grep -i "started\|publish\|error"
... msg="starting webhook event source" eventName=orders port=12000
... msg="dispatching event on the data channel" eventSourceName=webhook eventName=orders
... msg="succeeded to publish an event to eventbus" eventName=orders
```

If you see the request arrive but **no "publish"** line → the source can't reach the bus (auth/network). If you never see the request → ingress/Service/port problem, not Argo.

### 5.3 Is the Sensor subscribed and evaluating?

```console
$ kubectl -n argo-events logs deploy/order-processor-sensor --tail=30
... msg="starting sensor" sensorName=order-processor
... msg="Subscribing to messages on the event bus" dependency=order-dep
... msg="received event"
... msg="Successfully processed trigger 'launch-order-workflow'"
```

Decision table:

| Symptom in Sensor logs | Root cause | Fix |
|---|---|---|
| No `Subscribing…` line | Sensor can't reach EventBus | check EventBus `Deployed=True`, network policy |
| `received event` then **nothing** | event silently filtered | inspect `filters`; check the JSON `path` (it's `body.x`, not `x`) |
| `Failed to execute a trigger` `... is forbidden` | **RBAC** — SA lacks the verb | grant the Role in §3.6 |
| `dependency not found` / never fires | `eventSourceName`/`eventName` mismatch | must match EventSource metadata & the *key* name exactly |
| Trigger fires **twice** per event | `atLeastOnce: true` + non-idempotent target | make target idempotent (`generateName`/deterministic name) |

### 5.4 Prove the RBAC hypothesis directly

```console
$ kubectl -n argo-events auth can-i create workflows \
    --as=system:serviceaccount:argo-events:operate-workflow-sa
yes
```

A `no` here is your answer — the Sensor pod will get a 403 from the API server the moment it tries to submit, and the trigger fails with a `forbidden` message.

### 5.5 Metrics to alert on

- EventSource: `argo_events_event_processing_duration_milliseconds`, `argo_events_events_sent_total` (should climb with load).
- Sensor: `argo_events_action_triggered_total`, `argo_events_action_failed_total` (alert on the failed rate), `argo_events_action_duration_milliseconds`.
- EventBus (JetStream): consumer **pending/lag** — a growing backlog means the Sensor can't keep up or is crash-looping.

### 5.6 The "everything looks green but nothing runs" checklist

1. `kubectl get eventbus` → `Deployed: True`, StatefulSet at full quorum.
2. EventSource logs show `succeeded to publish`.
3. Sensor logs show `Subscribing…` **and** `received event`.
4. If received but no trigger → it's **filters** (99 % a wrong `path`) or **`conditions`** expression.
5. If trigger attempted but failed → it's **RBAC** or the target object being invalid.
6. `atLeastOnce` mismatch → duplicates or drops; align semantics with target idempotency.

---

## 6. References

- Argo Events — official documentation: https://argoproj.github.io/argo-events/
- Argo Events — GitHub repository & install manifests: https://github.com/argoproj/argo-events
- Concepts (EventSource / Sensor / EventBus): https://argoproj.github.io/argo-events/concepts/architecture/
- EventBus (NATS / JetStream / Kafka): https://argoproj.github.io/argo-events/eventbus/eventbus/
- Sensor triggers: https://argoproj.github.io/argo-events/sensors/triggers/argo-workflow/
- Sensor filters: https://argoproj.github.io/argo-events/sensors/filters/intro/
- Trigger retries, rate-limit & policy: https://argoproj.github.io/argo-events/sensors/trigger-conditions/
- CloudEvents specification (event envelope format): https://cloudevents.io/
- CAPA curriculum (exam blueprint): https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Argo Project (CNCF graduated project): https://argoproj.github.io/