# Guided Exercises — Topic 5.1: Argo Events (CAPA, weight 20%)

These exercises take you from an empty cluster to a working event-driven pipeline, then into the diagnostic techniques you need when events silently fail to fire. Work through them in order — each builds state the next one depends on. Run every command against a scratch cluster (kind/minikube/k3d are fine); nothing here is destructive, but triggers do create real objects.

**Reference sources**
- CNCF curriculum: <https://github.com/cncf/curriculum/blob/master/capa/README.md>
- Argo Events docs (concepts & architecture): <https://argoproj.github.io/argo-events/>
- EventBus: <https://argoproj.github.io/argo-events/concepts/eventbus/>
- Webhook EventSource: <https://argoproj.github.io/argo-events/eventsources/setup/webhook/>
- Sensor filters: <https://argoproj.github.io/argo-events/sensors/filters/intro/>
- Trigger parameterization: <https://argoproj.github.io/argo-events/sensors/trigger-conditions/>

**Mental model before you start.** Argo Events has exactly four moving parts and they form a one-way pipe:

```
external system ──▶ EventSource ──(CloudEvent)──▶ EventBus ──▶ Sensor ──▶ Trigger ──▶ K8s / Workflow / HTTP / ...
```

- **EventSource** — a Deployment that *ingests* from the outside world (webhook, calendar, Kafka, SQS, a Kubernetes resource watch, ...), normalizes each event into a **CloudEvent**, and publishes it to the EventBus.
- **EventBus** — the transport. By default a NATS **JetStream** StatefulSet. It decouples sources from sensors and is the only component both sides share.
- **Sensor** — a Deployment that *subscribes* to the EventBus, evaluates **dependencies** and **filters**, and when its trigger condition is met, fires one or more **Triggers**.
- **Trigger** — the action: create a K8s object, submit an Argo Workflow, call an HTTP endpoint, publish to Kafka, etc.

Keep that diagram in your head — most real failures are "which arrow is broken?"

---

## Exercise 1 — Install the controller and provision an EventBus

1. Create the namespace and install the controller + CRDs:

   ```bash
   kubectl create namespace argo-events
   kubectl apply -n argo-events \
     -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml
   ```

2. Confirm the controller is running and the CRDs are registered:

   ```bash
   kubectl -n argo-events get deploy
   kubectl get crd | grep argoproj.io
   ```

   Expected:

   ```
   NAME                 READY   UP-TO-DATE   AVAILABLE   AGE
   controller-manager   1/1     1            1           40s

   eventbus.argoproj.io          2026-08-12T...
   eventsources.argoproj.io      2026-08-12T...
   sensors.argoproj.io           2026-08-12T...
   ```

3. Provision a JetStream EventBus named `default`. The name matters — EventSources and Sensors that omit `eventBusName` bind to `default`.

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: EventBus
   metadata:
     name: default
   spec:
     jetstream:
       version: latest
       replicas: 3
   EOF
   ```

4. Watch the EventBus provision its StatefulSet and reach a Deployed condition:

   ```bash
   kubectl -n argo-events get statefulset
   kubectl -n argo-events get eventbus default \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   ```

   Expected:

   ```
   NAME                  READY   AGE
   eventbus-default-js   3/3     55s

   Deployed=True
   Configured=True
   ```

**Comprehension check**

- Q1.1 — Why does the EventBus render as a **StatefulSet** rather than a Deployment? What would break if it were a Deployment with 3 replicas behind a single Service?
- Q1.2 — You applied an EventBus called `default`. A colleague creates a second EventBus called `ci` in the same namespace. Does the existing `default` traffic move to `ci`? What single field decides which bus an EventSource/Sensor uses?
- Q1.3 — The StatefulSet is named `eventbus-default-js`. If you had instead deployed the legacy `spec.nats.native` bus, what would the StatefulSet suffix be, and why does the suffix matter operationally?

---

## Exercise 2 — Webhook EventSource and the CloudEvents envelope

1. Create a webhook EventSource. The map key under `webhook:` (`example`) is the **event name** — memorize it, the Sensor references it by that exact string.

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: EventSource
   metadata:
     name: webhook
   spec:
     service:
       ports:
         - port: 12000
           targetPort: 12000
     webhook:
       example:
         port: "12000"
         endpoint: /example
         method: POST
   EOF
   ```

2. Observe what the controller materialized from that spec — a Deployment *and* a Service you never wrote by hand:

   ```bash
   kubectl -n argo-events get deploy,svc -l eventsource-name=webhook
   ```

   Expected:

   ```
   NAME                                    READY   UP-TO-DATE   AVAILABLE
   deployment.apps/webhook-eventsource     1/1     1            1

   NAME                              TYPE        CLUSTER-IP     PORT(S)
   service/webhook-eventsource-svc   ClusterIP   10.96.71.5     12000/TCP
   ```

3. Port-forward the generated Service and send a real event:

   ```bash
   kubectl -n argo-events port-forward svc/webhook-eventsource-svc 12000:12000 &
   curl -si -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' \
     -d '{"message":"hello","value":75}'
   ```

   Expected response: `HTTP/1.1 200 OK` with body `success`.

4. Confirm the EventSource published to the bus:

   ```bash
   kubectl -n argo-events logs -l eventsource-name=webhook --tail=5
   ```

   Expected (trimmed):

   ```
   {"level":"info","logger":"argo-events.eventsource","msg":"succeeded to publish an event","eventSourceName":"webhook","eventName":"example"}
   ```

**Comprehension check**

- Q2.1 — You wrote a `service:` block but no `Service` manifest and no `Deployment`. Which component created them, and what label did it stamp on both so they can be selected together?
- Q2.2 — The event you POSTed reaches the bus as a **CloudEvent**, not as your raw JSON. Sketch the two top-level parts of that envelope, and say where inside it your `{"message":"hello","value":75}` body lands. (Hint: the path you'll use later is `body.message`, not `message`.)
- Q2.3 — Step 4 says "succeeded to publish an event" but **no Sensor exists yet**. Did the event get processed? Where is it now, and what property of the EventBus determines whether a Sensor created *later* can still consume it?

---

## Exercise 3 — Sensor, K8s trigger, and the RBAC that makes it fire

A Sensor triggers actions on the API server, so its ServiceAccount — **not yours** — must be authorized. This is the single most common reason a "correct" Sensor does nothing.

1. Create the ServiceAccount and least-privilege RBAC for the trigger:

   ```bash
   cat <<'EOF' | kubectl apply -f -
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
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["create", "get", "list", "watch"]
     - apiGroups: ["argoproj.io"]
       resources: ["workflows"]
       verbs: ["create", "get", "list", "watch"]
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
   EOF
   ```

2. Create a Sensor whose single dependency matches the EventSource/event names *exactly* and whose trigger creates a Pod:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
     triggers:
       - template:
           name: webhook-pod-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: hello-event-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: busybox
                       command: ["echo"]
                       args: ["an event fired me"]
   EOF
   ```

3. Fire an event (reuse the port-forward from Exercise 2, restart it if it died):

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"go"}'
   ```

4. Verify the Sensor processed the trigger and a Pod was born:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=5
   kubectl -n argo-events get pods -l events.argoproj.io/sensor=webhook
   ```

   Expected (trimmed):

   ```
   {"level":"info","logger":"argo-events.sensor","msg":"successfully processed the trigger","triggerName":"webhook-pod-trigger"}

   NAME                READY   STATUS      RESTARTS   AGE
   hello-event-4t9qz   0/1     Completed   0          6s
   ```

**Comprehension check**

- Q3.1 — Comment out `spec.template.serviceAccountName` and re-apply. The Sensor pod stays healthy, the event still publishes, but no Pod appears. Where does the error surface, and what HTTP status will the API server return to the Sensor?
- Q3.2 — Your Sensor's dependency says `eventName: example`. You rename the webhook map key to `demo` in the EventSource but forget to update the Sensor. Nothing fires. Which of the four components logged the "publish" success, and which one is now silently discarding the event — and why doesn't that show up as an error?
- Q3.3 — The trigger uses `generateName: hello-event-` instead of a fixed `name:`. What would happen on the **second** event if you had used a fixed `name:` and `operation: create`? Which `operation` value would you switch to for a "keep this object reconciled to the latest event" semantic?

---

## Exercise 4 — Filters: making a Sensor selective

A raw dependency fires on *every* matching event. Filters let one Sensor accept some events and drop others. Argo Events evaluates filters in a fixed order — **expr → data → context → time → script** — and *all* configured filter types must pass (logical AND across types).

1. Replace the dependency with filtered logic. This one fires only when `value > 50` **and** the message is non-empty:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
         filters:
           dataLogicalOperator: "and"
           data:
             - path: body.value
               type: number
               comparator: ">"
               value:
                 - "50"
           exprs:
             - expr: 'msg != ""'
               fields:
                 - name: msg
                   path: body.message
     triggers:
       - template:
           name: webhook-pod-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: filtered-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: busybox
                       command: ["echo"]
                       args: ["passed the filter"]
   EOF
   ```

2. Send an event that should be **rejected** (`value` below threshold):

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"low","value":10}'
   ```

3. Send an event that should be **accepted**:

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"high","value":99}'
   ```

4. Inspect the Sensor logs and confirm exactly one Pod was created:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=15 | grep -i filter
   kubectl -n argo-events get pods -l events.argoproj.io/sensor=webhook | grep filtered-
   ```

**Comprehension check**

- Q4.1 — Why is the data filter `value` written as the **string** `"50"` and the field typed `type: number`? What does the `type` field actually control during comparison?
- Q4.2 — You configured both a `data` filter and an `exprs` filter on the same dependency. Are they combined with AND or OR *between the two filter types*? Which field would you change to make the two `data` conditions (if you had two) OR each other instead?
- Q4.3 — A teammate wants "fire only Monday–Friday, 09:00–17:00 UTC." Which filter type covers that, and does it look at the event payload or the event's context/time? Name one edge case that makes time filters surprising near midnight.

---

## Exercise 5 — Parameterization and an Argo Workflow trigger

The real power of Argo Events is feeding event data *into* the triggered object. Here the webhook payload's `message` becomes a Workflow parameter.

1. (If Argo Workflows isn't installed, install just the controller/CRDs so `Workflow` objects are honored:)

   ```bash
   kubectl create namespace argo 2>/dev/null || true
   kubectl apply -n argo \
     -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/install.yaml
   ```

2. Point the trigger at an `argoWorkflow` and parameterize it. `parameters[].src` reads a key out of the event; `dest` is a path into the rendered resource:

   ```bash
   cat <<'EOF' | kubectl apply -n argo-events -f -
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: webhook
   spec:
     template:
       serviceAccountName: operate-workflow-sa
     dependencies:
       - name: test-dep
         eventSourceName: webhook
         eventName: example
     triggers:
       - template:
           name: webhook-workflow-trigger
           argoWorkflow:
             operation: submit
             source:
               resource:
                 apiVersion: argoproj.io/v1alpha1
                 kind: Workflow
                 metadata:
                   generateName: from-event-
                 spec:
                   entrypoint: echo
                   arguments:
                     parameters:
                       - name: message
                         value: "default-if-unset"
                   templates:
                     - name: echo
                       inputs:
                         parameters:
                           - name: message
                       container:
                         image: busybox
                         command: ["echo"]
                         args: ["{{inputs.parameters.message}}"]
             parameters:
               - src:
                   dependencyName: test-dep
                   dataKey: body.message
                 dest: spec.arguments.parameters.0.value
   EOF
   ```

3. Fire an event and watch the parameter flow through:

   ```bash
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"provisioned-by-event"}'
   kubectl -n argo-events get workflows
   ```

   Expected:

   ```
   NAME             STATUS      AGE
   from-event-x7k2  Succeeded   12s
   ```

4. Confirm the injected value actually reached the container:

   ```bash
   POD=$(kubectl -n argo-events get pod -l workflows.argoproj.io/completed=true \
         -o jsonpath='{.items[-1:].metadata.name}')
   kubectl -n argo-events logs "$POD" -c main
   ```

   Expected: `provisioned-by-event`

**Comprehension check**

- Q5.1 — `dest: spec.arguments.parameters.0.value` uses a numeric index. What does the `0` refer to, and what happens if the source template's `parameters` list order changes?
- Q5.2 — The Workflow spec ships a hardcoded `value: "default-if-unset"`. Under what condition does that default survive into the running Workflow instead of the event value? (Hint: think about `dataKey` resolving to a missing path.)
- Q5.3 — You used `operation: submit` for a Workflow. If you instead pointed a K8s trigger at an existing Deployment and wanted the event to bump its image tag, which `operation` and which extra field (beyond `parameters`) would you need so the Sensor patches rather than replaces?

---

## Exercise 6 — Diagnostics: the "nothing happened" playbook

Event-driven systems fail *silently* — no error, just no action. This exercise is a deliberate breakage-and-diagnosis drill. Run each check top to bottom; the first one that's abnormal is your culprit.

1. **Break it on purpose.** Introduce a name mismatch:

   ```bash
   kubectl -n argo-events patch sensor webhook --type=json \
     -p='[{"op":"replace","path":"/spec/dependencies/0/eventName","value":"typo"}]'
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"where did I go"}'
   ```

2. **Rung 1 — is the bus healthy?** A degraded EventBus stops everything:

   ```bash
   kubectl -n argo-events get eventbus default \
     -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
   kubectl -n argo-events get pods -l controller=eventbus-controller
   ```

3. **Rung 2 — did the source publish?** Look for the publish confirmation:

   ```bash
   kubectl -n argo-events logs -l eventsource-name=webhook --tail=3 | grep -i publish
   ```

4. **Rung 3 — did the sensor receive and evaluate?** This is where the mismatch shows:

   ```bash
   kubectl -n argo-events logs -l sensor-name=webhook --tail=20
   ```

   You'll see the event arrive but no `successfully processed the trigger` line, because dependency `test-dep` now expects event `typo` that never arrives.

5. **Rung 4 — controller-level problems** (CRD validation, EventBus wiring):

   ```bash
   kubectl -n argo-events logs deploy/controller-manager --tail=30
   ```

6. **Fix it and confirm recovery:**

   ```bash
   kubectl -n argo-events patch sensor webhook --type=json \
     -p='[{"op":"replace","path":"/spec/dependencies/0/eventName","value":"example"}]'
   curl -s -X POST http://localhost:12000/example \
     -H 'Content-Type: application/json' -d '{"message":"back online"}'
   kubectl -n argo-events logs -l sensor-name=webhook --tail=3 | grep processed
   ```

**Comprehension check**

- Q6.1 — Order the four "rungs" (EventBus health, EventSource publish, Sensor receive/evaluate, controller) as a decision tree. If Rung 2 shows a successful publish but Rung 3 shows the event never arrived at the Sensor at all, which component is the prime suspect — and how is that different from Rung 3 showing the event arriving but not triggering?
- Q6.2 — Two Sensors accidentally share the same EventBus *and* the same dependency `name`. Explain why durable-consumer naming on JetStream can make one Sensor "steal" the other's events. What field isolates them?
- Q6.3 — A trigger intermittently fails against a flaky downstream HTTP endpoint. Which Sensor-level construct lets the trigger retry with backoff, and what's the risk of pairing aggressive retries with a non-idempotent `create` trigger?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1 — EventBus & controller**

- **A1.1** — JetStream/NATS nodes are *stateful peers*: each has a stable identity, a persistent volume for the message store, and they form a cluster (RAFT quorum for JetStream) that requires stable network identities (`eventbus-default-js-0/1/2`). A StatefulSet gives ordered, stable pod names and per-pod PVCs. A plain Deployment would give ephemeral, interchangeable pods behind one IP — the nodes couldn't form a stable cluster, quorum/leader election would thrash, and persisted messages would be lost or split-brained on rescheduling.
- **A1.2** — No. Buses are independent; existing traffic stays on `default`. The `spec.eventBusName` field on an EventSource and on a Sensor decides membership; when omitted it defaults to `default`. To move traffic to `ci` you'd set `eventBusName: ci` on both the source and the sensor (both must agree, or they can't meet).
- **A1.3** — The legacy native NATS Streaming bus renders a StatefulSet suffixed `-stan` (`eventbus-default-stan`); JetStream renders `-js`. The suffix tells you at a glance which transport you're on, which matters because NATS Streaming (STAN) is deprecated/EOL, has different persistence and durable-consumer semantics, and different failure modes than JetStream. Diagnosing "messages not replayed" differs between the two.

**Exercise 2 — Webhook EventSource & CloudEvents**

- **A2.1** — The Argo Events **controller** reconciles the EventSource CR into a Deployment (`webhook-eventsource`) and, because you specified a `service:` block, a Service (`webhook-eventsource-svc`). Both carry the label `eventsource-name=webhook`, which is why `-l eventsource-name=webhook` selects them together.
- **A2.2** — A CloudEvent has a **`context`** (metadata: `id`, `source` = the EventSource name, `type`, `subject` = the event name `example`, `specversion`, `time`) and a **`data`** payload. For the webhook source, `data` is `{"header": {...}, "body": {...}}`. Your JSON lands under `data.body`, so `message` is reached as `body.message` (the `data.` prefix is implicit in `dataKey`/`path`).
- **A2.3** — Yes, it was published to the EventBus and then **dropped**, because with no subscriber there was no durable consumer to hold it. Whether a *later* Sensor can replay it depends on the EventBus persistence/retention and whether a durable consumer with a replay policy exists — by default a Sensor created after the event will **not** see historical events; it consumes from the point it subscribes. (This is why you always create the Sensor before firing test events, or expect to re-fire.)

**Exercise 3 — Sensor, trigger, RBAC**

- **A3.1** — The Sensor *pod* is fine; the failure is at trigger execution against the API server. The Sensor logs a trigger error and the API server returns **HTTP 403 Forbidden** (`pods is forbidden: User "system:serviceaccount:argo-events:default" cannot create resource "pods"`). Fix = give the Sensor's `serviceAccountName` a Role/RoleBinding permitting `create` on the target resource.
- **A3.2** — The **EventSource** logged "succeeded to publish an event" — its job (ingest → publish) succeeded regardless of any consumer. The **Sensor** is now discarding the event because its dependency filters on `eventName: example` while the event arrives as `demo`; a non-matching event simply doesn't satisfy any dependency, and "no dependency matched" is a normal, non-error condition — so it's logged at debug/info, not as an error. Nothing is "wrong" from any single component's perspective, which is exactly why name mismatches are so hard to spot.
- **A3.3** — With a fixed `name:` and `operation: create`, the second event's create would return **AlreadyExists (HTTP 409)** and the trigger would error. `generateName` sidesteps this by minting a unique name per event. For "reconcile this object to the latest event," switch to `operation: update` (or `patch`), which upserts/mutates the existing object instead of failing.

**Exercise 4 — Filters**

- **A4.1** — Filter `value` entries are always serialized as strings in YAML; `type: number` tells the filter engine to **parse both the event field and the comparison value as numbers** before applying `comparator`. Without `type: number`, `">"` on `"10"` vs `"50"` would be a *string* comparison (lexicographic), where `"9" > "50"` is true — a classic filter bug. `type` selects the comparison semantics (number/string/bool).
- **A4.2** — Between *different* filter types (`data` and `exprs`), the result is combined with logical **AND** — every configured type must pass. Within the `data` list, the `dataLogicalOperator` field (`"and"`/`"or"`) controls how multiple `data` conditions combine; the analogous `exprLogicalOperator` governs multiple `exprs`. So to OR two data conditions you set `dataLogicalOperator: "or"`.
- **A4.3** — The **time filter** covers business-hours windows; it inspects the **event's context time** (`context.time`), not the payload. The surprising edge case: a time filter with `start` later than `stop` (e.g. `start: "22:00:00"`, `stop: "06:00:00"`) is interpreted as a window that **crosses midnight**, and everything is evaluated in **UTC** — mixing that up with local time is the usual "why did it fire at the wrong hour" bug.

**Exercise 5 — Parameterization & Workflow trigger**

- **A5.1** — `spec.arguments.parameters.0.value` addresses the **first element (index 0)** of the `parameters` array in the rendered Workflow — here the `message` parameter. If the source template's parameter order changes, index `0` now points at a *different* parameter and you'll inject the event value into the wrong field. Prefer keeping the list order stable, or (in newer Argo Events) target by a stable path where supported.
- **A5.2** — The hardcoded default survives when `dataKey: body.message` **fails to resolve** — i.e. the event has no `body.message`. Parameter resolution falls back to the value already present at `dest` (the template default). So a malformed event or a renamed body field silently ships `default-if-unset` into production. You can also set `src.value` as an explicit fallback on the parameter itself.
- **A5.3** — Use `operation: update` (or `patch`) instead of `create`, and set the trigger's `k8s.patchStrategy`/`liveObject` handling appropriately (for a strategic-merge or JSON patch you supply the patch document; for `update` you must fetch-and-merge). Parameters still inject the new image tag via `dest`, but the operation must be one that mutates the live object rather than creating a new one.

**Exercise 6 — Diagnostics**

- **A6.1** — Decision tree, outer to inner: **(1) EventBus healthy?** (if `Deployed`/`Configured` aren't `True`, fix the bus first — nothing else can work). **(2) EventSource published?** (grep for "succeeded to publish"). **(3) Sensor received and evaluated?** **(4) Controller errors?** If Rung 2 shows publish success but Rung 3 shows the event **never arrived at the Sensor**, the prime suspect is the **EventBus wiring** — mismatched `eventBusName` between source and sensor, or a degraded bus consumer — the two ends aren't on the same bus. If instead the event **arrives but doesn't trigger**, the fault is *inside the Sensor*: a dependency name/event mismatch or a filter rejecting it. Same symptom ("no action"), completely different fix.
- **A6.2** — On JetStream, each Sensor dependency maps to a **durable consumer** whose name is derived from the EventBus + dependency identity. Two Sensors on the same bus that reuse the same dependency `name` can resolve to the **same durable consumer**, and JetStream delivers each message to a durable consumer **once** — so the two Sensors compete and one "steals" messages the other expected. Isolate them by giving each Sensor its own dependency names (and, for stronger isolation, a separate `eventBusName`).
- **A6.3** — The trigger template's **`retryStrategy`** (`steps`, `duration`, `factor`, `jitter`) provides retry-with-backoff. The danger with a non-idempotent `create` trigger is **duplicate side effects**: a retry that actually succeeded but whose response was lost will create a *second* object/Workflow. Mitigate with idempotent operations (`generateName` collides less but still duplicates on retry; prefer a deterministic name + `update`/upsert, or dedup keyed on the CloudEvent `context.id`).

</details>