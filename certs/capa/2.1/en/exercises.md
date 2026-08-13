# Argo Workflows — Guided Exercises (CAPA, Domain 2.1)

> **Format.** Each exercise is a numbered sequence of commands and manifests you run against a real cluster. After every block there are **comprehension checks**. All answers are gathered in the collapsible section at the end.
>
> **Reference sources**
> - CNCF CAPA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
> - Argo Workflows docs — https://argo-workflows.readthedocs.io/en/latest/
> - Workflow CRD field reference — https://argo-workflows.readthedocs.io/en/latest/fields/

---

## Prerequisites — install the controller and the CLI

You need a running Kubernetes cluster (kind, minikube, k3d, or a real one) and `kubectl` pointed at it.

### Steps

1. Create the `argo` namespace and install the *quick-start* manifests (bundles the workflow-controller, the argo-server API/UI, and a MinIO artifact repository):

   ```bash
   kubectl create namespace argo
   kubectl apply -n argo -f \
     https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/quick-start-minimal.yaml
   ```

2. Wait for the control plane to become ready:

   ```bash
   kubectl -n argo rollout status deploy/workflow-controller
   kubectl -n argo get pods
   ```

   Expected (illustrative):

   ```
   NAME                                   READY   STATUS    RESTARTS   AGE
   argo-server-6b8c9c8f7d-2xk4p           1/1     Running   0          40s
   minio-7d7c8f9c5b-nq7wm                 1/1     Running   0          40s
   workflow-controller-5f9c7b8d6c-lm2vq   1/1     Running   0          40s
   ```

3. Install the `argo` CLI (Linux amd64 shown; match your platform):

   ```bash
   curl -sLO https://github.com/argoproj/argo-workflows/releases/download/v3.5.8/argo-linux-amd64.gz
   gunzip argo-linux-amd64.gz
   chmod +x argo-linux-amd64
   sudo mv argo-linux-amd64 /usr/local/bin/argo
   argo version --short
   ```

   ```
   argo: v3.5.8
   ```

4. Set the default namespace so you can drop `-n argo` from later commands:

   ```bash
   kubectl config set-context --current --namespace=argo
   ```

### Comprehension checks

- **Q1.** The install created three long-running components. Which of them actually *reconciles* `Workflow` objects into Pods, and which one is optional for running workflows from the CLI?
- **Q2.** Argo defines its objects (`Workflow`, `WorkflowTemplate`, `CronWorkflow`, …) as CRDs under the `argoproj.io/v1alpha1` API group. What does that tell you about how `argo submit` and `kubectl create -f workflow.yaml` relate?

---

## Exercise 1 — Your first `Workflow`: entrypoint and the `container` template

### Steps

1. Create `hello.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: hello-world-      # server appends a random suffix
   spec:
     entrypoint: main                 # which template to run first
     templates:
       - name: main
         container:
           image: busybox
           command: [echo]
           args: ["hello world"]
   ```

2. Submit it and stream the node tree until completion:

   ```bash
   argo submit --watch hello.yaml
   ```

   Expected (final frame, illustrative):

   ```
   Name:                hello-world-9d4qk
   Namespace:           argo
   ServiceAccount:      unset (will run with the default ServiceAccount)
   Status:              Succeeded
   Conditions:
    PodRunning          False
    Completed           True
   Created:             Wed Aug 12 10:03:11 +0000 (30 seconds ago)
   Started:             Wed Aug 12 10:03:11 +0000 (30 seconds ago)
   Finished:            Wed Aug 12 10:03:21 +0000 (20 seconds ago)
   Duration:            10 seconds
   Progress:            1/1

   STEP                    TEMPLATE  PODNAME            DURATION  MESSAGE
    ✔ hello-world-9d4qk    main      hello-world-9d4qk  8s
   ```

3. List and inspect it, then read the container logs:

   ```bash
   argo list
   argo get @latest          # @latest is the most recently submitted workflow
   argo logs @latest
   ```

   ```
   hello-world-9d4qk: hello world
   ```

4. Look at how the workflow maps to Kubernetes underneath:

   ```bash
   kubectl get wf                          # 'wf' is the short name for workflows
   kubectl get pods -l workflows.argoproj.io/workflow=hello-world-9d4qk
   ```

### Comprehension checks

- **Q3.** You used `generateName` instead of `name`. What breaks if you submit the same file twice with `name: hello-world` instead, and why does `generateName` avoid it?
- **Q4.** A `Workflow` has many `templates` but ran only one. What is the exact role of `spec.entrypoint`, and how many Pods did this workflow create?
- **Q5.** The output showed `ServiceAccount: unset (will run with the default ServiceAccount)`. Why does the *executor* need permissions at all — what does it do that plain `echo` does not?

---

## Exercise 2 — `steps`: sequential groups and parallel fan-out

The `steps` template is a **list of lists**. The outer list runs **sequentially**; items inside the same inner list run **in parallel**.

### Steps

1. Create `steps.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: steps-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: one            # group 1
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step one"}]
           - - name: two-a          # group 2 — two-a and two-b run together
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step two-a"}]
             - name: two-b
               template: echo
               arguments:
                 parameters: [{name: msg, value: "step two-b"}]

       - name: echo
         inputs:
           parameters:
             - name: msg
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Submit and observe ordering in the tree:

   ```bash
   argo submit --watch steps.yaml
   ```

   Expected shape (illustrative):

   ```
   STEP            TEMPLATE  PODNAME             DURATION  MESSAGE
    ● steps-abc12  main
    ├─✔ one        echo      steps-abc12-1  6s
    ├─✔ two-a      echo      steps-abc12-2  5s
    └─✔ two-b      echo      steps-abc12-3  5s
   ```

3. Confirm the two second-group Pods overlapped in time:

   ```bash
   kubectl get pods -l workflows.argoproj.io/workflow=$(argo get @latest -o json | \
     jq -r .metadata.name) -o wide --sort-by=.status.startTime
   ```

### Comprehension checks

- **Q6.** Rewrite the YAML mentally so that `two-a` and `two-b` run **one after another** instead of together. Which characters do you change, and nothing else?
- **Q7.** The `echo` template is declared once but invoked three times with different `arguments.parameters`. Distinguish `inputs.parameters` (on the callee) from `arguments.parameters` (on the caller). Which one is the "function signature" and which is the "call site"?

---

## Exercise 3 — `dag`: dependency graphs (the diamond)

A `dag` template declares `tasks` with `dependencies`. The controller runs a task as soon as **all** its dependencies have succeeded, maximizing parallelism.

### Steps

1. Create `dag-diamond.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: dag-diamond-
   spec:
     entrypoint: diamond
     templates:
       - name: diamond
         dag:
           tasks:
             - name: A
               template: echo
               arguments: {parameters: [{name: msg, value: A}]}
             - name: B
               dependencies: [A]
               template: echo
               arguments: {parameters: [{name: msg, value: B}]}
             - name: C
               dependencies: [A]
               template: echo
               arguments: {parameters: [{name: msg, value: C}]}
             - name: D
               dependencies: [B, C]
               template: echo
               arguments: {parameters: [{name: msg, value: D}]}

       - name: echo
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Submit and watch:

   ```bash
   argo submit --watch dag-diamond.yaml
   ```

   Expected (illustrative):

   ```
   STEP                 TEMPLATE  PODNAME               DURATION
    ● dag-diamond-x7q2  diamond
    ├─✔ A               echo      dag-diamond-x7q2-1  6s
    ├─✔ B               echo      dag-diamond-x7q2-2  5s
    ├─✔ C               echo      dag-diamond-x7q2-3  5s
    └─✔ D               echo      dag-diamond-x7q2-4  6s
   ```

### Comprehension checks

- **Q8.** In wall-clock terms, in what order did `B` and `C` execute relative to each other, and why is `D` guaranteed to be last?
- **Q9.** You can express this same diamond with a `steps` template. What is the practical advantage of `dag` when the graph is wide and irregular (say 30 tasks with sparse dependencies)?
- **Q10.** If task `C` **fails**, what happens to `D` and to `B` by default? (Consider `depends` failure semantics.)

---

## Exercise 4 — Parameters: `script` results and output parameters

`script` templates run inline source and capture **stdout** as `outputs.result`. You can also emit an **output parameter** from a file via `valueFrom.path`.

### Steps

1. Create `params.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: params-
   spec:
     entrypoint: main
     arguments:
       parameters:
         - name: seed
           value: "42"
     templates:
       - name: main
         steps:
           - - name: generate
               template: gen
           - - name: consume
               template: print
               arguments:
                 parameters:
                   - name: value
                     value: "{{steps.generate.outputs.result}}"

       - name: gen
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import random
             random.seed({{workflow.parameters.seed}})
             print(random.randint(1, 100))

       - name: print
         inputs:
           parameters: [{name: value}]
         container:
           image: busybox
           command: [sh, -c]
           args: ["echo got value {{inputs.parameters.value}}"]
   ```

2. Submit and read the propagated value:

   ```bash
   argo submit --watch params.yaml
   argo logs @latest
   ```

   ```
   params-k2m9x-2: got value 82
   ```

3. Override the top-level parameter at submit time:

   ```bash
   argo submit --watch params.yaml -p seed=7
   argo logs @latest
   ```

### Comprehension checks

- **Q11.** Trace the three parameter scopes used here: `{{workflow.parameters.seed}}`, `{{steps.generate.outputs.result}}`, `{{inputs.parameters.value}}`. In which order are each of these substituted, and by whom?
- **Q12.** `outputs.result` captured the number because the script printed it to stdout. If instead you wrote the number to `/tmp/out` inside a `container` template, what `outputs.parameters` block would expose it, and why is the `result` shortcut only available on `script` (and `container`) templates?
- **Q13.** `-p seed=7` overrode `spec.arguments.parameters`. Where would you set a *default* that applies when neither `-p` nor `arguments` provides a value?

---

## Exercise 5 — Artifacts: passing files between steps

Parameters carry small strings; **artifacts** carry files/directories, stored in an artifact repository (here, the MinIO the quick-start installed).

### Steps

1. Create `artifacts.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: artifact-passing-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: generate
               template: whalesay
           - - name: consume
               template: print-message
               arguments:
                 artifacts:
                   - name: message
                     from: "{{steps.generate.outputs.artifacts.hello-art}}"

       - name: whalesay
         container:
           image: docker/whalesay:latest
           command: [sh, -c]
           args: ["cowsay hello world | tee /tmp/hello_world.txt"]
         outputs:
           artifacts:
             - name: hello-art
               path: /tmp/hello_world.txt

       - name: print-message
         inputs:
           artifacts:
             - name: message
               path: /tmp/message      # controller mounts the artifact here
         container:
           image: busybox
           command: [sh, -c]
           args: ["cat /tmp/message"]
   ```

2. Submit and confirm the file crossed the Pod boundary:

   ```bash
   argo submit --watch artifacts.yaml
   argo logs @latest | grep -A6 hello
   ```

3. Inspect where Argo stored the artifact:

   ```bash
   argo get @latest -o json | jq '.status.nodes[] | select(.outputs.artifacts) |
     {node: .displayName, artifacts: .outputs.artifacts}'
   ```

### Comprehension checks

- **Q14.** The `generate` step ran in one Pod and `consume` in another. Explain, step by step, how the bytes got from `/tmp/hello_world.txt` in the first Pod to `/tmp/message` in the second — what compresses/uploads and what downloads?
- **Q15.** If no artifact repository were configured, this workflow would fail at the *output* stage. Where is the default artifact repository configured cluster-wide, and what field on an artifact lets you override the destination per-artifact?

---

## Exercise 6 — Loops (`withItems`, `withParam`) and conditionals (`when`)

### Steps

1. Static loop with `withItems`, then a dynamic loop with `withParam` fed by a step's JSON output. Create `loops.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: loops-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: static-loop
               template: echo
               arguments: {parameters: [{name: msg, value: "{{item}}"}]}
               withItems: [cat, dog, fox]

           - - name: gen-list
               template: make-list
           - - name: dynamic-loop
               template: echo
               arguments: {parameters: [{name: msg, value: "{{item}}"}]}
               withParam: "{{steps.gen-list.outputs.result}}"

       - name: make-list
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import json
             print(json.dumps(["alpha", "beta"]))

       - name: echo
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Submit and count the fan-out:

   ```bash
   argo submit --watch loops.yaml
   argo get @latest    # note the (0), (1), (2)… iteration nodes
   ```

3. Now a conditional. Create `coinflip.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: coinflip-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: flip
               template: flip-coin
           - - name: heads
               template: say
               when: "{{steps.flip.outputs.result}} == heads"
               arguments: {parameters: [{name: msg, value: "it was heads"}]}
             - name: tails
               template: say
               when: "{{steps.flip.outputs.result}} == tails"
               arguments: {parameters: [{name: msg, value: "it was tails"}]}

       - name: flip-coin
         script:
           image: python:alpine3.6
           command: [python]
           source: |
             import random
             print("heads" if random.random() > 0.5 else "tails")

       - name: say
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

4. Submit a few times and note that one branch is skipped each run:

   ```bash
   argo submit --watch coinflip.yaml
   argo get @latest    # one of heads/tails shows as Skipped
   ```

### Comprehension checks

- **Q16.** `withItems` and `withParam` both fan out the same template. What is the essential difference in *when* the loop cardinality is known — authoring time vs. run time — and what constraint does that put on the string `withParam` receives?
- **Q17.** In `coinflip.yaml`, the skipped branch shows as `Skipped`, not `Failed`. Why does a `when` that evaluates false **not** fail the workflow, and what does a downstream step see as that node's phase?
- **Q18.** `{{item}}` referenced the current loop element. If the items were **objects** like `{"name": "a", "port": 80}`, what expression would pull out just the port inside the template arguments?

---

## Exercise 7 — Resilience: `retryStrategy` and `onExit` handlers

### Steps

1. Create `retry-exit.yaml` — a container that fails ~70% of the time, retried with exponential backoff, plus an exit handler that always runs:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: retry-exit-
   spec:
     entrypoint: main
     onExit: notify              # runs on success OR failure
     templates:
       - name: main
         retryStrategy:
           limit: "5"
           retryPolicy: "OnFailure"     # Always | OnFailure | OnError | OnTransientError
           backoff:
             duration: "2"              # seconds
             factor: "2"                # 2s, 4s, 8s, …
             maxDuration: "1m"
         container:
           image: python:alpine3.6
           command: [python, -c]
           args:
             - |
               import random, sys
               sys.exit(1) if random.random() < 0.7 else print("succeeded")

       - name: notify
         container:
           image: busybox
           command: [sh, -c]
           args:
             - "echo workflow {{workflow.name}} finished with status {{workflow.status}}"
   ```

2. Submit and watch the retry nodes accumulate:

   ```bash
   argo submit --watch retry-exit.yaml
   argo get @latest      # note (1), (2), (3)… retry attempts under the main node
   ```

3. Read the exit handler's log:

   ```bash
   argo logs @latest | grep finished
   ```

   ```
   retry-exit-p8w2q-onExit: workflow retry-exit-p8w2q finished with status Succeeded
   ```

### Comprehension checks

- **Q19.** Distinguish `retryPolicy: OnFailure` from `OnError`. A Pod that the exit code marks as failed vs. a Pod the *executor* could not start (e.g. image pull error) — which policy catches which, and why does `Always` catch both?
- **Q20.** The exit handler printed `{{workflow.status}}`. Name two other global variables available specifically inside an `onExit` handler that let it branch on how the workflow ended.
- **Q21.** Retries and backoff interact with `activeDeadlineSeconds`. If the workflow hits its deadline mid-backoff, does the pending retry still fire? Reason about which limit is authoritative.

---

## Exercise 8 — Reuse and scheduling: `WorkflowTemplate` and `CronWorkflow`

### Steps

1. Create a reusable `WorkflowTemplate` in `wt.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: WorkflowTemplate
   metadata:
     name: print-message-wt
   spec:
     entrypoint: main
     arguments:
       parameters: [{name: msg, value: "default hello"}]
     templates:
       - name: main
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Register it and run it two ways:

   ```bash
   argo template create wt.yaml
   argo template list

   # (a) submit a one-off Workflow from the template
   argo submit --from workflowtemplate/print-message-wt -p msg="from --from" --watch
   ```

   Or reference it from inside another `Workflow` with `templateRef`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: caller-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: call
               templateRef:
                 name: print-message-wt
                 template: main
               arguments:
                 parameters: [{name: msg, value: "called via templateRef"}]
   ```

3. Now schedule it. Create `cron.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: CronWorkflow
   metadata:
     name: hello-cron
   spec:
     schedule: "*/1 * * * *"           # every minute
     concurrencyPolicy: "Replace"      # Allow | Forbid | Replace
     startingDeadlineSeconds: 30
     successfulJobsHistoryLimit: 3
     failedJobsHistoryLimit: 1
     workflowSpec:
       entrypoint: main
       templates:
         - name: main
           container:
             image: busybox
             command: [sh, -c]
             args: ["echo scheduled run at $(date)"]
   ```

4. Apply and observe scheduling:

   ```bash
   argo cron create cron.yaml
   argo cron list
   argo cron get hello-cron
   # after a minute or two:
   argo list --prefix hello-cron
   ```

5. Clean up when done:

   ```bash
   argo cron delete hello-cron
   argo template delete print-message-wt
   ```

### Comprehension checks

- **Q22.** Compare the two ways of using a `WorkflowTemplate`: `argo submit --from workflowtemplate/...` versus `templateRef` inside a `Workflow`. One creates a standalone `Workflow`; the other embeds a call. When would you reach for each?
- **Q23.** `concurrencyPolicy: Replace` — a run is still going when the next tick arrives. What does the controller do, and how would `Forbid` and `Allow` differ on that same tick?
- **Q24.** What is the difference between a `WorkflowTemplate` and a `ClusterWorkflowTemplate`, and how does that change how a `templateRef` addresses it?

---

## Exercise 9 — Human-in-the-loop and throttling: `suspend` and `synchronization`

### Steps

1. A `suspend` template pauses until you resume it (approval gate). Create `approval.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: approval-
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: build
               template: say
               arguments: {parameters: [{name: msg, value: "building"}]}
           - - name: wait-approval
               template: approve
           - - name: deploy
               template: say
               arguments: {parameters: [{name: msg, value: "deploying"}]}

       - name: approve
         suspend: {}                  # add {duration: "20s"} for a timed pause

       - name: say
         inputs:
           parameters: [{name: msg}]
         container:
           image: busybox
           command: [echo]
           args: ["{{inputs.parameters.msg}}"]
   ```

2. Submit; it will halt at `wait-approval`:

   ```bash
   argo submit approval.yaml
   argo get @latest        # status shows the suspend node Running/Suspended
   ```

3. Resume it (this is where an approver clicks in the UI, or calls the API):

   ```bash
   argo resume @latest
   argo get @latest --watch
   ```

4. Now bound concurrency with a semaphore. First a ConfigMap holding the limit:

   ```bash
   kubectl create configmap workflow-controller-configmap-sema \
     --from-literal=deploy=1 -n argo --dry-run=client -o yaml | kubectl apply -f -
   ```

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: limited-
   spec:
     entrypoint: main
     synchronization:
       semaphore:
         configMapKeyRef:
           name: workflow-controller-configmap-sema
           key: deploy               # value "1" ⇒ at most one holder at a time
     templates:
       - name: main
         container:
           image: busybox
           command: [sh, -c]
           args: ["echo holding the semaphore; sleep 20"]
   ```

5. Submit this workflow **twice quickly** and watch the second one wait:

   ```bash
   argo submit --generate-name limited- limited.yaml
   argo submit --generate-name limited- limited.yaml
   argo list      # one Running, one Pending with a "Waiting for ... lock" message
   ```

### Comprehension checks

- **Q25.** A `suspend: {}` node holds no Pod while it waits. Why is that operationally cheaper than a container that runs `sleep` in a loop polling for approval?
- **Q26.** Distinguish `synchronization.semaphore` from `synchronization.mutex`. If you set the semaphore value to `1`, is it equivalent to a mutex? What can a semaphore express that a mutex cannot?
- **Q27.** Semaphore/mutex can be declared at **workflow** scope or on an individual **template**. What changes about *what* is being throttled when you move the `synchronization` block from `spec` down into a single template?

---

## Answers

<details>
<summary>Show all answers (Q1–Q27)</summary>

**Q1.** The **workflow-controller** is the reconciler: it watches `Workflow` objects and creates/updates the Pods that run each node. The **argo-server** (API + web UI) is optional for CLI use — `argo submit`/`kubectl apply` talk to the Kubernetes API directly, so the controller alone is enough to run workflows. (MinIO is only the artifact backend.)

**Q2.** Because Argo's types are CRDs, a `Workflow` is a first-class Kubernetes object. `argo submit file.yaml` and `kubectl create -f file.yaml` both just create the same `Workflow` resource via the API server; `argo` adds conveniences (`--watch`, log streaming, `@latest`, parameter overrides) but the object it creates is identical. Reference: https://argo-workflows.readthedocs.io/en/latest/workflow-concepts/

**Q3.** With `name: hello-world`, the second submit collides with the existing object and the API returns `AlreadyExists`. `generateName` tells the API server to append a random suffix (`hello-world-9d4qk`), so every submission is a unique object — the idiomatic pattern for repeatedly-submitted workflows.

**Q4.** `spec.entrypoint` names the template the controller invokes first; the others are only run if reached by an invocator (`steps`/`dag`) or a handler. This workflow created **one Pod** — a single leaf `container` template equals one Pod.

**Q5.** Argo injects an **executor** into each workflow Pod (the default is the *emissary* executor). The executor captures outputs (parameters/artifacts/logs), reports node status back, and manages the main container's lifecycle. That is why the Pod's ServiceAccount needs RBAC (e.g. to patch pods/get pod logs), whereas a bare `echo` would need nothing.

**Q6.** Change the two second-group entries from sharing one inner list to being their own outer list items — i.e. turn `- - name: two-a` … `  - name: two-b` (same inner list) into `- - name: two-a` … `- - name: two-b` (two separate outer groups). Same-inner-list ⇒ parallel; separate-outer-list ⇒ sequential.

**Q7.** `inputs.parameters` on the `echo` template is the **signature** — it declares the parameters the template requires and their defaults. `arguments.parameters` at each call site is the **call**, binding actual values to those inputs. A template with `inputs` but no matching `arguments` at the call site fails unless the input has a default `value`.

**Q8.** `B` and `C` both depend only on `A`, so they start together and run **concurrently**; their relative finish order is non-deterministic. `D` depends on `[B, C]`, so the controller cannot schedule it until both have succeeded — making it last.

**Q9.** `dag` lets you declare each task's dependencies **locally** (`dependencies: [B, C]`) and the controller derives maximum parallelism automatically. With `steps` you must manually flatten the graph into sequential groups, which forces artificial barriers (a whole group must finish before the next starts) — wasteful for wide, sparse graphs.

**Q10.** By default a task runs only when its dependencies **succeed**, so if `C` fails, `D` is not run (it shows as failed/omitted because a dependency failed), while `B` — which does not depend on `C` — still runs to completion. You can change this with the richer `depends` field (e.g. `A.Succeeded || A.Failed`, `C.Failed`) to build error-handling branches.

**Q11.** Order of substitution:
1. `{{workflow.parameters.seed}}` — a **global**, substituted by the controller before the `gen` Pod is created (it is baked into the script source).
2. `{{steps.generate.outputs.result}}` — resolved **after** `generate` completes and its result is known, then passed as the `consume` step's argument.
3. `{{inputs.parameters.value}}` — resolved when the `print` template is instantiated, binding the caller's argument to the template input.
So substitution is staged: globals first, then step outputs as they become available, then inputs at each invocation.

**Q12.** For a `container` writing to a file:
```yaml
outputs:
  parameters:
    - name: value
      valueFrom:
        path: /tmp/out
```
`outputs.result` is the convenience capture of **stdout**, available on `script` and `container` templates precisely because they run a process whose stdout Argo can capture; templates like `resource`/`suspend` have no such stdout stream, so they expose outputs only via explicit `valueFrom`.

**Q13.** Put the default on the **template input** itself: `inputs.parameters: [{name: value, value: "fallback"}]`. Resolution precedence is: CLI `-p` / API override → `spec.arguments.parameters` (or the call-site `arguments`) → the input's default `value`.

**Q14.** (1) When `whalesay` finishes, its Pod's executor sees `outputs.artifacts.hello-art` with `path: /tmp/hello_world.txt`, tars/compresses that path and **uploads** it to the artifact repository (MinIO) under a key tied to the workflow/node. (2) `argo` records the artifact's location in the node status. (3) When `print-message` starts, its executor reads the input artifact reference (`from: {{steps.generate.outputs.artifacts.hello-art}}`), **downloads** the object from MinIO, and unpacks it to `/tmp/message` before the main container runs `cat`.

**Q15.** The cluster-wide default lives in the **`artifact-repository`** entry of the `workflow-controller-configmap` (or a repository referenced by `artifactRepositoryRef`). Per-artifact, you override the destination by specifying the backend inline on the artifact (`s3:`, `gcs:`, `azure:`, `http:`, `git:`, etc.) with its bucket/key and credentials `secretKeyRef`. Reference: https://argo-workflows.readthedocs.io/en/latest/configure-artifact-repository/

**Q16.** `withItems` is known at **authoring time** — the list is literal in the manifest, so the controller knows the cardinality before anything runs. `withParam` is known at **run time** — it consumes the output of a prior step. The constraint: the string handed to `withParam` must be a **valid JSON array** (e.g. `["a","b"]`); the controller parses it and fans out one child per element.

**Q17.** A `when` that evaluates false marks the node **Skipped**, which is a *successful* terminal phase for control-flow purposes — it is a deliberate branch, not an error, so it does not fail the workflow. Downstream steps that depend on a skipped node treat it as satisfied-but-produced-no-output (referencing its outputs would be an error, which is why conditional branches usually converge on a separate join step).

**Q18.** Use the object-field accessor on `item`: `"{{item.port}}"` (and `"{{item.name}}"` for the name). Argo exposes each object element's fields as `{{item.<field>}}`.

**Q19.** `OnFailure` retries when the **main container exits non-zero** (application-level failure). `OnError` retries when Argo hits an **infrastructure/executor error** — the Pod could not be created/started, was deleted, image pull failed, node lost, etc. `Always` = `OnFailure ∪ OnError`, so it catches both. (`OnTransientError` retries only errors matched as transient, e.g. via the transient-error env allow-list.)

**Q20.** Inside `onExit` you additionally have `{{workflow.failures}}` (a JSON list of failed nodes with messages), plus `{{workflow.duration}}`, `{{workflow.name}}`, `{{workflow.uid}}`, and `{{workflow.status}}` — commonly you branch the handler with a `when: "{{workflow.status}} == Failed"`.

**Q21.** `activeDeadlineSeconds` (workflow-level) is authoritative: when the deadline passes, the controller stops the workflow and **does not** fire a pending retry — the workflow is failed/terminated regardless of remaining `retryStrategy.limit`. Backoff waiting counts against the deadline, so a long `maxDuration` can be cut short by a shorter workflow deadline.

**Q22.** `argo submit --from workflowtemplate/X` creates a **new standalone `Workflow`** from the template — ideal for running the template as a job (manually, from CI, or scheduled). `templateRef` **embeds a call** to the template from within another `Workflow`, so you compose reusable building blocks into a larger graph. Reach for `--from` to *run* a template; use `templateRef` to *reuse* it as a component.

**Q23.** With `Replace`, when a new tick arrives while the previous run is still active, the controller **cancels the old run and starts the new one**. `Forbid` **skips** the new tick (keeps the running one). `Allow` (the default) lets them **overlap**, running concurrently.

**Q24.** A `WorkflowTemplate` is **namespaced**; a `ClusterWorkflowTemplate` is **cluster-scoped** and usable from any namespace. In a `templateRef`, addressing a `ClusterWorkflowTemplate` adds `clusterScope: true` (and drops namespace assumptions), e.g. `templateRef: {name: X, template: main, clusterScope: true}`.

**Q25.** A `suspend` node is pure controller state — no Pod, no CPU/memory reserved, no image pulled — so a workflow can wait hours or days for approval essentially for free and without occupying a node. A `sleep`-poll container consumes a Pod slot and resources the entire time and still needs external signalling logic.

**Q26.** A `mutex` is a named lock with capacity **exactly 1** (mutual exclusion). A `semaphore` is a counting lock whose capacity comes from a ConfigMap value. Setting the semaphore to `1` is behaviourally equivalent to a mutex, but a semaphore can express **N > 1** — "at most N holders at once" — which a mutex cannot. Reference: https://argo-workflows.readthedocs.io/en/latest/synchronization/

**Q27.** At **workflow scope** (`spec.synchronization`), the lock gates the *entire workflow* — only N whole workflows hold it at once. Moved into a **template**, it gates *each invocation of that template* — so a single workflow's many parallel instances of that template (e.g. a fan-out step) contend for the same N slots, throttling that one stage without limiting the rest of the graph.

</details>