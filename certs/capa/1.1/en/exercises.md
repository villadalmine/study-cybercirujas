# Topic 1.1 — Argo Project Fundamentals · Guided Exercises

> **Exam domain weight: 20%** · Certification: **CAPA** (Certified Argo Project Associate)
>
> These labs assume a working Kubernetes cluster (`kind`, `minikube`, or k3s are fine) and a `kubectl` that already targets it. Each exercise is a sequence of numbered steps you run in a terminal, followed by comprehension checks. Consolidated answers are in the collapsible section at the very end — try to answer before expanding.
>
> **Sanity check before you start:**
> ```bash
> kubectl version --output=json | grep -i gitVersion
> kubectl get nodes
> ```
> You should see at least one node in `Ready` state.

---

## Exercise 1 — Mapping the Argo Project: four tools, one design

**Goal:** Learn *what* the Argo Project is and *which* problem each of its four components solves, so you never confuse Argo CD (continuous delivery) with Argo Workflows (job orchestration) on the exam.

The Argo Project is a **CNCF Graduated** project (graduated 2022-12) made of four independently-installable but composable tools:

| Component | Category | Core question it answers |
|---|---|---|
| **Argo Workflows** | Workflow / job orchestration | "Run this multi-step DAG of containers to completion." |
| **Argo CD** | Continuous Delivery (GitOps) | "Keep the cluster matching what Git says." |
| **Argo Rollouts** | Progressive Delivery | "Roll out this new version gradually and safely." |
| **Argo Events** | Event-driven automation | "When *X* happens, trigger *Y*." |

1. Confirm you understand the target versions by reading the release each project publishes. (No install yet — just observe the naming pattern.)
   ```bash
   curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest        | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-workflows/releases/latest | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-rollouts/releases/latest  | grep '"tag_name"'
   curl -s https://api.github.com/repos/argoproj/argo-events/releases/latest    | grep '"tag_name"'
   ```
   Expected shape of each line:
   ```
     "tag_name": "v2.13.2",
   ```

2. Create the four conventional namespaces now so the rest of the labs land in predictable places:
   ```bash
   kubectl create namespace argo          # Argo Workflows
   kubectl create namespace argocd        # Argo CD
   kubectl create namespace argo-rollouts # Argo Rollouts
   kubectl create namespace argo-events   # Argo Events
   ```
   Expected:
   ```
   namespace/argo created
   namespace/argocd created
   namespace/argo-rollouts created
   namespace/argo-events created
   ```

**Comprehension checks — 1**

- **1a.** A team asks you to "gradually shift 10% of production traffic to `v2` and automatically roll back if error rate rises." Which Argo component is that, and which is it *not*?
- **1b.** What does "CNCF Graduated" tell you about the project's maturity relative to "Incubating" or "Sandbox"?
- **1c.** Argo CD and Argo Rollouts are frequently deployed together. What is the division of labor between them?

---

## Exercise 2 — The shared architecture: CRDs + controllers + reconciliation

**Goal:** See that *all four* Argo tools are built on the same Kubernetes-native pattern — a **Custom Resource Definition (CRD)** describing desired state, plus a **controller** that continuously **reconciles** actual state toward it. This is the single most important architectural idea in Topic 1.1.

1. Install just the Argo Workflows control plane so we have real CRDs to inspect (pin a version rather than `latest` for reproducibility):
   ```bash
   ARGO_WF_VERSION=v3.6.2
   kubectl apply -n argo \
     -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WF_VERSION}/quick-start-minimal.yaml"
   ```

2. Wait for the controller and API server to become ready:
   ```bash
   kubectl -n argo rollout status deployment/workflow-controller
   kubectl -n argo rollout status deployment/argo-server
   ```
   Expected:
   ```
   deployment "workflow-controller" successfully rolled out
   deployment "argo-server" successfully rolled out
   ```

3. List the CRDs the install registered. This is the "vocabulary" Argo added to the Kubernetes API:
   ```bash
   kubectl get crd | grep argoproj.io
   ```
   Expected (abbreviated):
   ```
   clusterworkflowtemplates.argoproj.io   2026-08-12T...
   cronworkflows.argoproj.io              2026-08-12T...
   workflows.argoproj.io                  2026-08-12T...
   workflowtemplates.argoproj.io          2026-08-12T...
   ...
   ```

4. Inspect the schema of the `Workflow` kind straight from the API server — no docs needed:
   ```bash
   kubectl explain workflow.spec.entrypoint
   kubectl api-resources --api-group=argoproj.io
   ```
   Expected tail of the second command:
   ```
   NAME                       SHORTNAMES   APIVERSION            NAMESPACED   KIND
   cronworkflows              cwf,cronwf   argoproj.io/v1alpha1  true         CronWorkflow
   workflows                  wf           argoproj.io/v1alpha1  true         Workflow
   workflowtemplates          wftmpl       argoproj.io/v1alpha1  true         WorkflowTemplate
   ...
   ```

5. Watch the controller do its job. In one terminal, stream its logs:
   ```bash
   kubectl -n argo logs deployment/workflow-controller -f
   ```
   Leave it running; you'll see it react in Exercise 3.

**Comprehension checks — 2**

- **2a.** What are the two halves of the Kubernetes "operator/controller" pattern, and which half is the *desired state* vs the *acting agent*?
- **2b.** All four Argo CRDs share the API group `argoproj.io` and version `v1alpha1`. From the exam's perspective, why does every Argo object you write start with `apiVersion: argoproj.io/v1alpha1`?
- **2c.** You ran `kubectl explain workflow.spec.entrypoint` and it returned a schema. Where does that schema physically live in the cluster, and why does that matter for validation *before* a Pod is ever created?
- **2d.** Define "reconciliation" in one sentence, as a control loop.

---

## Exercise 3 — Your first Argo Workflow (job orchestration fundamentals)

**Goal:** Submit a real multi-step DAG, watch the controller create Pods for each node, and read the result. This grounds the "Workflows = run containers to completion" idea.

1. Install the `argo` CLI (Linux amd64 shown; adjust for your platform):
   ```bash
   ARGO_WF_VERSION=v3.6.2
   curl -sSL -o argo.gz \
     "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WF_VERSION}/argo-linux-amd64.gz"
   gunzip argo.gz && chmod +x argo && sudo mv argo /usr/local/bin/
   argo version --short
   ```
   Expected:
   ```
   argo: v3.6.2
   ```

2. Write a DAG workflow. Save as `hello-dag.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: hello-dag-        # server appends a random suffix
     namespace: argo
   spec:
     entrypoint: main                # which template starts the run
     templates:
       - name: main
         dag:
           tasks:
             - name: a
               template: echo
               arguments:
                 parameters: [{ name: msg, value: "I am task A" }]
             - name: b
               template: echo
               dependencies: [a]     # b runs only after a succeeds
               arguments:
                 parameters: [{ name: msg, value: "I am task B, after A" }]
             - name: c
               template: echo
               dependencies: [a]     # c also waits on a, runs in PARALLEL with b
               arguments:
                 parameters: [{ name: msg, value: "I am task C, after A" }]
       - name: echo
         inputs:
           parameters: [{ name: msg }]
         container:
           image: alpine:3.20
           command: [sh, -c]
           args: ["echo {{inputs.parameters.msg}}"]
   ```

3. Submit it and watch it run to completion:
   ```bash
   argo submit -n argo --watch hello-dag.yaml
   ```
   Expected (final state):
   ```
   Name:                hello-dag-abcde
   Namespace:           argo
   Status:              Succeeded
   Duration:            18 seconds
   
   STEP              TEMPLATE  PODNAME                   DURATION
    ✔ hello-dag-abcde  main
    ├─✔ a             echo      hello-dag-abcde-echo-...  6s
    ├─✔ b             echo      hello-dag-abcde-echo-...  5s
    └─✔ c             echo      hello-dag-abcde-echo-...  5s
   ```

4. Prove the orchestration mapped each DAG node to a Pod, then read one node's output:
   ```bash
   argo list -n argo
   kubectl -n argo get pods -l workflows.argoproj.io/workflow
   argo logs -n argo @latest
   ```
   Expected (logs, order may interleave):
   ```
   a:  I am task A
   b:  I am task B, after A
   c:  I am task C, after A
   ```

**Comprehension checks — 3**

- **3a.** In the manifest, why did we use `generateName` instead of `name`?
- **3b.** Tasks `b` and `c` both declare `dependencies: [a]`. Given the DAG semantics, what is the execution relationship between `b` and `c`, and why?
- **3c.** How many Pods did this single `Workflow` object cause the controller to create, and what is the mapping between DAG tasks and Pods here?
- **3d.** What does `entrypoint: main` select, and what would break if you set it to `echo` instead?
- **3e.** After the run, its status was `Succeeded`. Where is that status stored — in the CLI, or in the cluster — and how would you re-read it a day later?

---

## Exercise 4 — Your first Argo CD Application (GitOps fundamentals)

**Goal:** Install Argo CD, register a Git repo as the source of truth, and watch it drive the cluster into the declared state. This anchors the four GitOps principles: **declarative, versioned in Git, pulled automatically, continuously reconciled.**

1. Install Argo CD into the `argocd` namespace:
   ```bash
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deployment/argocd-server
   ```

2. Look at the components a stock install brings up — note there are *several* controllers, not one:
   ```bash
   kubectl -n argocd get deploy,statefulset
   ```
   Expected (abbreviated):
   ```
   deployment.apps/argocd-applicationset-controller
   deployment.apps/argocd-dex-server
   deployment.apps/argocd-notifications-controller
   deployment.apps/argocd-redis
   deployment.apps/argocd-repo-server
   deployment.apps/argocd-server
   statefulset.apps/argocd-application-controller
   ```

3. Retrieve the auto-generated admin password (Argo CD stores it in a Secret on first boot):
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   ```

4. Declare an `Application` — the CRD that tells Argo CD *what repo* to sync *where*. Save as `guestbook-app.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd                     # Applications live in the Argo CD namespace
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook                      # sub-directory holding the manifests
     destination:
       server: https://kubernetes.default.svc  # the in-cluster API
       namespace: guestbook
     syncPolicy:
       automated:                           # GitOps principle: pulled automatically
         prune: true                        # delete resources removed from Git
         selfHeal: true                     # revert manual drift back to Git
       syncOptions:
         - CreateNamespace=true
   ```

5. Apply it and watch Argo CD reconcile:
   ```bash
   kubectl apply -f guestbook-app.yaml
   kubectl -n argocd get application guestbook -w
   ```
   Expected progression:
   ```
   NAME        SYNC STATUS   HEALTH STATUS
   guestbook   OutOfSync     Missing
   guestbook   Syncing       Progressing
   guestbook   Synced        Healthy
   ```

6. Confirm the workloads Git described now exist in the cluster, and then test **self-heal** by deliberately introducing drift:
   ```bash
   kubectl -n guestbook get deploy,svc
   kubectl -n guestbook scale deployment/guestbook-ui --replicas=5   # manual drift
   kubectl -n guestbook get deploy guestbook-ui -w                    # watch it revert
   ```
   Expected: replicas briefly show `5`, then Argo CD scales it back to the value declared in Git.

**Comprehension checks — 4**

- **4a.** Name the four GitOps principles and point to the exact field(s) in the `Application` manifest that implement "pulled automatically" and "continuously reconciled."
- **4b.** You scaled the Deployment to 5 replicas by hand and it snapped back. Which `syncPolicy` sub-field caused that, and what would happen instead if it were `false`?
- **4c.** `prune: true` — what does it delete, and what would be silently left behind if it were `false`?
- **4d.** The `Application` object lives in the `argocd` namespace but the guestbook workloads live in the `guestbook` namespace. Explain how one `Application` in one namespace ends up managing resources in another.
- **4e.** Argo CD is a **pull-based** delivery tool. Contrast that with a **push-based** CI job that runs `kubectl apply` — give one security advantage of pull.

---

## Exercise 5 — Your first Argo Rollout (progressive delivery fundamentals)

**Goal:** Replace a standard `Deployment` with a `Rollout` and drive a **canary** release step by step. This grounds "Rollouts = deploy gradually and safely."

1. Install the Argo Rollouts controller and the kubectl plugin:
   ```bash
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   kubectl -n argo-rollouts rollout status deployment/argo-rollouts

   curl -sSL -o kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   chmod +x kubectl-argo-rollouts && sudo mv kubectl-argo-rollouts /usr/local/bin/
   kubectl argo rollouts version
   ```

2. Declare a canary `Rollout`. Save as `canary-rollout.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-demo
     namespace: default
   spec:
     replicas: 5
     revisionHistoryLimit: 2
     selector:
       matchLabels: { app: rollouts-demo }
     template:
       metadata:
         labels: { app: rollouts-demo }
       spec:
         containers:
           - name: rollouts-demo
             image: argoproj/rollouts-demo:blue
             ports: [{ containerPort: 8080 }]
             resources:
               requests: { cpu: 5m, memory: 32Mi }
     strategy:
       canary:                     # gradual, not all-at-once
         steps:
           - setWeight: 20         # send 20% to the new version
           - pause: {}             # pause INDEFINITELY until a human promotes
           - setWeight: 40
           - pause: { duration: 20s }
           - setWeight: 60
           - pause: { duration: 20s }
           - setWeight: 80
           - pause: { duration: 20s }
   ```

3. Create it and open the live dashboard for this rollout:
   ```bash
   kubectl apply -f canary-rollout.yaml
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```
   Expected initial state (all 5 pods on the stable `blue` version, no canary yet):
   ```
   Name:            rollouts-demo
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          8/8
     SetWeight:     100
     ActualWeight:  100
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas: Desired: 5 / Current: 5 / Updated: 5 / Available: 5
   ```

4. Trigger an update by changing only the image tag, then watch the canary pause at 20%:
   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```
   Expected (paused at step 2 of 8):
   ```
   Status:        ॥ Paused
     Step:        1/8
     SetWeight:   20
     ActualWeight: 20
   Images:        argoproj/rollouts-demo:blue (stable)
                  argoproj/rollouts-demo:yellow (canary)
   Replicas: Desired: 5 / Current: 6 / Updated: 1 / Available: 5
   ```

5. Manually promote through the remaining steps, then verify the new version is now stable:
   ```bash
   kubectl argo rollouts promote rollouts-demo
   kubectl argo rollouts get rollout rollouts-demo --watch   # completes the timed steps
   ```
   Expected end state: `Images: argoproj/rollouts-demo:yellow (stable)`.

6. (Optional) Practice a safety abort instead of a promotion:
   ```bash
   kubectl argo rollouts set image rollouts-demo rollouts-demo=argoproj/rollouts-demo:red
   kubectl argo rollouts abort rollouts-demo     # roll back to stable immediately
   ```

**Comprehension checks — 5**

- **5a.** A `Rollout` is a drop-in replacement for which native Kubernetes object? What does it add that the native object cannot do on its own?
- **5b.** In step 4, `Current: 6` while `Desired: 5`. Why are there temporarily 6 Pods during a 20% canary of 5 replicas?
- **5c.** The first `pause: {}` has no `duration`, but later pauses have `duration: 20s`. What is the behavioral difference, and which one required your `promote` command?
- **5d.** You changed *only* the image tag to trigger the rollout. Which field in `spec.template` does the controller hash to decide "this is a new revision"?
- **5e.** `abort` vs `promote` — describe the end state of each on a paused canary.

---

## Exercise 6 — Argo Events primitives (event-driven fundamentals)

**Goal:** Understand the three core Argo Events objects and how a signal becomes an action: **EventSource → EventBus → Sensor → trigger.**

1. Install Argo Events and its default EventBus dependency (NATS JetStream):
   ```bash
   kubectl apply -n argo-events \
     -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml
   kubectl -n argo-events rollout status deployment/controller-manager
   ```

2. Create the `EventBus` — the transport backbone every EventSource and Sensor talks through. Save as `eventbus.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: EventBus
   metadata:
     name: default            # Sensors/EventSources default to the bus named "default"
     namespace: argo-events
   spec:
     jetstream:
       version: latest
       replicas: 3
   ```
   ```bash
   kubectl apply -f eventbus.yaml
   kubectl -n argo-events get eventbus
   ```

3. Create an `EventSource` that emits an event on a fixed schedule (a "calendar" source is the simplest to test with, needs no external system). Save as `eventsource.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: EventSource
   metadata:
     name: calendar
     namespace: argo-events
   spec:
     calendar:
       example-every-10s:
         interval: 10s        # emit an event named "example-every-10s" every 10 seconds
   ```

4. Create a `Sensor` that listens for that event and triggers an action (here, creating a short-lived Pod). Save as `sensor.yaml`:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Sensor
   metadata:
     name: calendar-sensor
     namespace: argo-events
   spec:
     dependencies:
       - name: cal-dep
         eventSourceName: calendar          # must match the EventSource metadata.name
         eventName: example-every-10s        # must match the key under spec.calendar
     triggers:
       - template:
           name: log-trigger
           k8s:
             operation: create
             source:
               resource:
                 apiVersion: v1
                 kind: Pod
                 metadata:
                   generateName: cal-triggered-
                 spec:
                   restartPolicy: Never
                   containers:
                     - name: hello
                       image: alpine:3.20
                       command: [echo, "an event fired and I was triggered"]
   ```

5. Apply the source and sensor, then watch a Pod get created every ~10 seconds:
   ```bash
   kubectl apply -f eventsource.yaml
   kubectl apply -f sensor.yaml
   kubectl -n argo-events get pods -w
   ```
   Expected: new `cal-triggered-xxxxx` Pods appearing on the interval, each running to `Completed`.

**Comprehension checks — 6**

- **6a.** Name the three Argo Events CRDs from this lab and state the single responsibility of each.
- **6b.** In the `Sensor`, `eventSourceName` and `eventName` must match specific fields in the `EventSource`. Which fields, exactly, and what happens if `eventName` is misspelled?
- **6c.** What is the role of the `EventBus`, and why does Argo Events insert a message bus between sources and sensors instead of wiring them directly?
- **6d.** A common production pattern is "a webhook EventSource triggers an Argo Workflow." Which two Argo components does that pattern combine, and what replaces the `k8s` trigger to launch a Workflow?

---

## Exercise 7 — Seeing the one pattern behind all four

**Goal:** Consolidate. Prove to yourself that Workflows, CD, Rollouts, and Events are the *same* architectural idea — declarative CRD + reconciling controller — installed four times.

1. Enumerate every CRD each Argo tool registered:
   ```bash
   kubectl get crd -o name | grep argoproj.io | sort
   ```
   Expected (abbreviated, spanning all four tools):
   ```
   customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/eventbus.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/eventsources.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/experiments.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/rollouts.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/sensors.argoproj.io
   customresourcedefinition.apiextensions.k8s.io/workflows.argoproj.io
   ...
   ```

2. Identify the controller Pod behind each tool:
   ```bash
   kubectl -n argo            get deploy workflow-controller
   kubectl -n argocd          get statefulset argocd-application-controller
   kubectl -n argo-rollouts   get deploy argo-rollouts
   kubectl -n argo-events     get deploy controller-manager
   ```

3. Fill in this mental model (write it down, don't just read it):

   | Tool | Primary CRD | Reconciling controller | "Actual state" it drives |
   |---|---|---|---|
   | Workflows | `Workflow` | `workflow-controller` | Pods run to completion |
   | Argo CD | `Application` | `argocd-application-controller` | Cluster == Git |
   | Rollouts | `Rollout` | `argo-rollouts` controller | Traffic shifts gradually |
   | Argo Events | `Sensor` (+ `EventSource`) | `controller-manager` | Triggers fire on events |

**Comprehension checks — 7**

- **7a.** State the universal Argo pattern in one sentence, using the words *declarative*, *controller*, and *reconcile*.
- **7b.** Argo CD's controller is a `StatefulSet` while the other three are `Deployments`. Without memorizing it, what does "the desired state is stored in the API server, not the controller" imply about whether losing a controller Pod loses your `Application`/`Workflow`/`Rollout` objects?
- **7c.** "Argo CD deploys the *manifests*; Argo Rollouts controls *how those manifests progress*; Argo Workflows can *run the CI/CD steps that produced them*; Argo Events *triggers the whole thing*." Map each clause to one of the four tools and explain why the project ships them as one family.

---

## Clean-up (optional)

```bash
kubectl delete -f canary-rollout.yaml -f eventsource.yaml -f sensor.yaml -f eventbus.yaml --ignore-not-found
kubectl delete application guestbook -n argocd --ignore-not-found
kubectl delete namespace argo argocd argo-rollouts argo-events guestbook --ignore-not-found
```

---

<details>
<summary><strong>✅ Answers &amp; explanations (expand after attempting)</strong></summary>

### Exercise 1

- **1a.** That is **Argo Rollouts** (progressive delivery: canary weighting + automated rollback on metric analysis). It is *not* **Argo CD** — Argo CD decides *what* version should be deployed from Git, but it applies changes as a standard rollout; the *gradual traffic-shifting with automated analysis* is Rollouts' job.
- **1b.** CNCF maturity levels are **Sandbox → Incubating → Graduated**. "Graduated" is the highest tier: it signals broad production adoption, a healthy multi-vendor community, documented security/governance processes, and a stable API — safe to standardize on. Argo graduated in December 2022.
- **1c.** **Argo CD** is the GitOps engine: it observes Git and keeps the cluster's declared objects (including a `Rollout` manifest) in sync. **Argo Rollouts** is the deployment strategy engine: once a `Rollout` object exists/changes, its controller executes the canary or blue-green steps and traffic shifting. Argo CD says *"this version should exist"*; Rollouts says *"here is how to get there safely."*

### Exercise 2

- **2a.** The two halves are the **Custom Resource (backed by a CRD)** = the *desired state / declarative spec*, and the **controller** = the *acting agent* that runs a control loop. The CRD/CR is data; the controller is behavior.
- **2b.** All Argo objects belong to the same API group and version because each tool **extends the Kubernetes API** via CRDs registered under `argoproj.io/v1alpha1`. On the exam, any Argo manifest — `Workflow`, `Application`, `Rollout`, `Sensor`, `EventSource`, `EventBus` — begins with `apiVersion: argoproj.io/v1alpha1`; a wrong `apiVersion` is a classic distractor.
- **2c.** The schema lives in the **CRD object stored in the cluster's API server (etcd)**. Because the API server holds an OpenAPI schema for the CRD, it can **validate and reject a malformed manifest at `kubectl apply` time** — before any controller acts and before any Pod is scheduled. Validation is server-side and independent of the controller.
- **2d.** **Reconciliation** is a continuous control loop that observes the actual state of the world, compares it to the declared desired state, and takes corrective action to close the gap — repeatedly, not once.

### Exercise 3

- **3a.** `generateName` tells the API server to **append a random suffix** and mint a unique name (`hello-dag-abcde`). Because you submit many runs of the same workflow, a fixed `name` would collide with the previous run; `generateName` lets each submission create a distinct object.
- **3b.** `b` and `c` **run in parallel**. Each depends only on `a`, and there is no dependency edge between `b` and `c`, so once `a` succeeds the controller schedules both simultaneously. The DAG models dependencies, and independent siblings are concurrent by default.
- **3c.** The controller created **three Pods** — one per DAG *task* that has a `container` (`a`, `b`, `c`). The top-level `main` template is a DAG orchestrator and does **not** get its own worker Pod; only the leaf `echo` invocations become Pods. Mapping here: 1 task ⇒ 1 Pod.
- **3d.** `entrypoint: main` selects **which template the run starts from**. Setting it to `echo` would try to start at a template that *requires an input parameter* (`msg`) with no arguments supplied, so the workflow would fail to run correctly (missing required input) instead of executing the DAG.
- **3e.** The status is stored **in the cluster**, on the `Workflow` object itself (`.status`), in etcd — not in the CLI. A day later you re-read it with `kubectl -n argo get wf <name> -o yaml` or `argo get -n argo <name>`; the `argo --watch` output was just a live view of that server-side status.

### Exercise 4

- **4a.** The four GitOps principles: **(1) Declarative** — the whole system is described as data (the manifests in `path: guestbook`); **(2) Versioned & immutable** — that desired state lives in Git (`repoURL` + `targetRevision`); **(3) Pulled automatically** — an agent pulls and applies it (`syncPolicy.automated`); **(4) Continuously reconciled** — the agent keeps observing and correcting drift (`selfHeal: true`, plus Argo CD's ongoing sync loop). "Pulled automatically" ⇒ `syncPolicy.automated`; "continuously reconciled" ⇒ `selfHeal: true`.
- **4b.** `syncPolicy.automated.selfHeal: true` caused the revert — Argo CD detected live state diverging from Git and re-applied Git's declared `replicas`. With `selfHeal: false`, the Application would show **`OutOfSync`** and leave your manual 5 replicas in place until someone synced manually.
- **4c.** `prune: true` **deletes cluster resources that were once managed by this Application but have since been removed from Git**. With `prune: false`, those orphaned objects are left running silently — a common cause of "I deleted it from Git but it's still in the cluster."
- **4d.** The `Application` is a control object read by the `argocd-application-controller`. Its `spec.destination` (`server` + `namespace`) tells the controller **which cluster and namespace to apply the sourced manifests into**. So the Application *definition* lives in `argocd`, but its *effect* is in whatever destination it names — here, `guestbook`.
- **4e.** In **pull** mode, the delivery agent runs *inside* the target cluster and reaches *out* to Git; no external CI system needs cluster-admin credentials or inbound API access. That shrinks the attack surface: you don't hand kube-apiserver write credentials to an outside CI runner, and the cluster's API server need not be exposed to the CI network.

### Exercise 5

- **5a.** A `Rollout` is a drop-in replacement for a **`Deployment`** (same `replicas`/`selector`/`template` shape). It adds **advanced deployment strategies** — canary and blue-green with weighted traffic steps, pauses, automated metric analysis (`AnalysisTemplate`), and manual promote/abort — which a native `Deployment` (only `RollingUpdate`/`Recreate`) cannot do.
- **5b.** During a 20% canary of 5 replicas, the controller keeps the **5 stable Pods** available *and* adds **1 canary Pod** (20% of 5 = 1) so live capacity isn't reduced while the new version is validated — hence `Current: 6`. Old Pods are only scaled down as the canary weight increases.
- **5c.** `pause: {}` with no duration pauses **indefinitely** — it waits for a human `kubectl argo rollouts promote`. `pause: { duration: 20s }` **auto-resumes** after 20 seconds. The indefinite one (step 2) is what required your `promote` command; the timed ones advanced on their own.
- **5d.** The controller hashes **`spec.template`** (the Pod template). Any change there — including just the container image tag — produces a new pod-template hash, which the controller treats as a new revision and starts the canary strategy. Changing something outside `spec.template` (e.g. `replicas`) does *not* trigger a new rollout.
- **5e.** `promote` **advances** the rollout to the next step (or, with `--full`, straight to 100%), eventually making the canary the new stable. `abort` **immediately rolls back** to the last stable version, scaling the canary to zero and leaving the previous stable serving 100% of traffic.

### Exercise 6

- **6a.** **`EventSource`** — connects to an external system (calendar, webhook, S3, Kafka, …) and *produces* events onto the bus. **`EventBus`** — the transport (NATS JetStream by default) that carries events from sources to sensors. **`Sensor`** — *subscribes* to named event dependencies and, when they're satisfied, fires **triggers** (create a Pod, launch a Workflow, call an HTTP endpoint, …).
- **6b.** In the `Sensor`, `dependencies[].eventSourceName` must equal the `EventSource`'s `metadata.name` (`calendar`), and `dependencies[].eventName` must equal the **key under `spec.calendar`** (`example-every-10s`), not the CRD name. If `eventName` is misspelled, the dependency **never matches an incoming event**, so the Sensor sits idle and no trigger ever fires — with no error, which makes it a subtle bug.
- **6c.** The `EventBus` is the **durable message-transport layer** between EventSources and Sensors. Decoupling them through a bus gives **durability/replay (JetStream persistence), fan-out (many sensors consuming one source), back-pressure, and independent scaling/restart** of sources and sensors — none of which a direct source-to-sensor wire could provide.
- **6d.** It combines **Argo Events** (the webhook `EventSource` + `Sensor`) with **Argo Workflows**. Instead of the `k8s` trigger, the Sensor uses an **`argoWorkflow` trigger** (`triggers[].template.argoWorkflow`) whose `operation: submit` creates a `Workflow` object — a canonical event-driven pipeline.

### Exercise 7

- **7a.** Every Argo tool lets you **declaratively** describe desired state as a custom resource, and runs a dedicated **controller** that continuously **reconciles** the cluster's actual state toward that declaration.
- **7b.** Because desired state (`Application`, `Workflow`, `Rollout`, `Sensor`, …) is persisted in the **API server / etcd**, not inside the controller process, **losing a controller Pod does not lose your objects**. A new controller Pod reconnects, reads the same CRs from the API server, and resumes reconciling. `StatefulSet` vs `Deployment` is an implementation choice about the controller, not about where state lives.
- **7c.** **Argo CD** deploys the manifests (GitOps sync of *what* runs); **Argo Rollouts** governs *how* a new version of those manifests progresses (canary/blue-green safety); **Argo Workflows** runs the pipeline steps (build/test/scan jobs) that *produce and validate* releases; **Argo Events** *triggers* pipelines and syncs in response to signals (git push webhook, schedule, message). They ship as one family because they compose into a full event-driven, GitOps continuous-delivery loop — each covering a distinct phase (trigger → build → deliver → progress) while sharing the same CRD-plus-controller foundation.

</details>

---

### Sources (official)

- CNCF CAPA curriculum — <https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md>
- Argo Project (umbrella) — <https://argoproj.github.io/>
- Argo Workflows docs — <https://argo-workflows.readthedocs.io/en/latest/>
- Argo CD docs — <https://argo-cd.readthedocs.io/en/stable/>
- Argo Rollouts docs — <https://argo-rollouts.readthedocs.io/en/stable/>
- Argo Events docs — <https://argoproj.github.io/argo-events/>
- OpenGitOps principles (CNCF) — <https://opengitops.dev/>
- CNCF graduated projects — <https://www.cncf.io/projects/argo/>