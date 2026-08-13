# Argo Workflows — CAPA Domain 2.1

**Certification:** Certified Argo Project Associate (CAPA)
**Domain 2.1 — Argo Workflows** · Exam weight: 20%
**Target profile:** SRE / Platform Architect — production internals, trade-offs, complete manifests, real diagnostics.

Version baseline for every example below: **Argo Workflows v3.5.x / v3.6.x** running on Kubernetes ≥ 1.27. Where behavior changed across releases (executor defaults, artifact GC, hooks) it is called out explicitly.

---

## 1. Motivation and the production architectural problem

### 1.1 What Argo Workflows actually is

Argo Workflows is a **container-native workflow engine implemented entirely as a set of Kubernetes Custom Resource Definitions (CRDs) plus a reconciling controller**. There is no external scheduler, no separate metadata database on the hot path, and no DSL to compile. A workflow is a Kubernetes object; each *step* of that workflow is a **Pod**; orchestration is a reconciliation loop over the `Workflow` custom resource.

This is the key architectural fact that everything else derives from: **the desired state (the DAG), the runtime state (node statuses), and the execution units (Pods) all live in the Kubernetes API.** The control plane is `etcd` + the API server; Argo adds a controller.

```
                    ┌────────────────────────────────────────────┐
                    │              Kubernetes API / etcd           │
                    │  Workflow CR  ─┐   Pods   ConfigMaps  RBAC   │
                    └────────┬───────┼──────────────┬─────────────┘
                             │ watch │ create/patch  │ read
              ┌──────────────▼───────┴──┐   ┌────────▼─────────┐
              │   workflow-controller    │   │   argo-server    │
              │  (reconcile loop, DAG    │   │  (REST/gRPC API, │
              │   scheduler, GC, retries)│   │   UI, archive)   │
              └──────────────┬───────────┘   └──────────────────┘
                             │ spawns one Pod per node
                 ┌───────────▼───────────────────────────┐
                 │  Step Pod                               │
                 │  ┌─────────┐  ┌──────────────────────┐ │
                 │  │  init    │  │  main (your image)   │ │
                 │  │ (load    │  │                      │ │
                 │  │  inputs) │  └──────────────────────┘ │
                 │  └─────────┘  ┌──────────────────────┐ │
                 │               │  wait (executor)     │ │
                 │               │  captures outputs,   │ │
                 │               │  artifacts, exit code│ │
                 │               └──────────────────────┘ │
                 └─────────────────────────────────────────┘
```

### 1.2 The production problem it solves

Before Argo, teams running **batch DAGs, ML pipelines, CI/CD, data ETL, and infrastructure automation on Kubernetes** were stuck with three bad options:

1. **Raw `Job`/`CronJob` objects.** No dependency graph. A ten-stage pipeline becomes ten Jobs glued together by brittle shell polling (`kubectl wait --for=condition=complete`), with no shared parameter passing, no artifact handoff, no fan-out, and no single object representing "the pipeline run".
2. **An external orchestrator (Airflow, Luigi, Prefect).** The scheduler and its metadata DB live *outside* the cluster. Tasks are often submitted *as* Kubernetes Pods (KubernetesPodOperator), so you now run two control planes, two RBAC models, and two failure domains. The DAG is Python code that must be packaged and shipped separately from the cluster state.
3. **CI runners (Jenkins, GitLab CI) driving `kubectl`.** The orchestration state lives in the CI system, not the cluster; retries, backoff, and observability are the CI tool's, not Kubernetes-native.

Argo collapses this: **one CRD is the pipeline, the scheduler is a standard Kubernetes controller, and every RBAC/quota/network-policy/PSA control you already run applies unchanged.** For an SRE the operational win is that a workflow is debuggable with the exact tools you use for everything else — `kubectl get`, `kubectl describe`, `kubectl logs`, events, and Prometheus.

### 1.3 The three hard problems Argo has to solve internally

A workflow engine on Kubernetes must answer three questions that raw Jobs cannot:

| Problem | Why it is hard on K8s | Argo's mechanism |
|---|---|---|
| **Capture a step's output** (a return value, a computed parameter, a produced file) | A Pod's container has no return channel beyond its exit code and logs | The **wait/executor container** reads `outputs.parameters` from files/paths in the main container and writes them back into the `Workflow` node status; artifacts are streamed to an object store |
| **Pass data between steps** | Pods are ephemeral and isolated; there is no shared step memory | Output parameters are stored in the Workflow status; **artifacts** are persisted to S3/GCS/Azure/MinIO and re-hydrated by the *init* container of the downstream step |
| **Know when a step is truly done** (including when the runtime kills the container) | The kubelet may reap a container before its status is observed | The **emissary executor** wraps the main process (PID 1 is `argoexec`), so the exact exit code is captured even under eviction, and outputs are flushed before the Pod terminates |

Understanding that **outputs and completion are captured by a sidecar/wrapper, not by Kubernetes itself**, is the single most important internal concept for the exam and for debugging.

---

## 2. Technical comparisons and trade-offs

### 2.1 Argo Workflows vs. the alternatives

| Dimension | Argo Workflows | Apache Airflow | Tekton Pipelines | Raw K8s Job/CronJob |
|---|---|---|---|---|
| **Control plane location** | In-cluster CRDs + controller | External scheduler + metadata DB | In-cluster CRDs + controller | In-cluster |
| **Unit of execution** | 1 Pod per step | 1 task (often a Pod via operator) | 1 Pod per `TaskRun` step-container | 1 Pod per Job |
| **DAG definition** | YAML (`dag`/`steps`) | Python code | YAML (`Pipeline`) | None (imperative glue) |
| **Parameter/artifact passing** | First-class (params + object-store artifacts) | XCom (small) + external storage | `results` (≤4 KB) + `workspaces` (PVC) | Manual |
| **Fan-out (`withItems`/`withParam`)** | Native, dynamic | Dynamic task mapping | Matrix (limited) | None |
| **Primary use case** | Batch/ML/ETL/CI, data pipelines | Scheduled data engineering | CI/CD pipelines | One-off/scheduled jobs |
| **GitOps fit** | Excellent (pure K8s objects) | Poor (code + DB) | Excellent | Good |
| **Scale ceiling** | 10k+ nodes/workflow with tuning | High (but DB-bound) | Moderate | N/A |
| **Statefulness** | Stateless controller; state in etcd + optional archive DB | Stateful (DB is source of truth) | Stateless | Stateless |

**Architect's read:** choose Argo when the pipeline *is* Kubernetes-native work and you want one control plane and GitOps. Choose Airflow when you need rich scheduling semantics, backfills, and a data-engineering ecosystem, and are willing to run a second stateful system. Tekton overlaps with Argo for CI/CD specifically but is weaker at dynamic fan-out and data-science DAGs.

### 2.2 `steps` vs `dag` template types

| | `steps` | `dag` |
|---|---|---|
| **Model** | Ordered list of stages; each stage is a list that runs in parallel | Explicit dependency graph via `dependencies`/`depends` |
| **Concurrency** | Everything in one `[ ... ]` group runs concurrently; groups are sequential | Any task runs as soon as its dependencies satisfy |
| **Best for** | Linear-ish pipelines with occasional parallel stages | Complex graphs where max parallelism matters |
| **Failure semantics** | A failed stage blocks the next stage | Only downstream tasks of the failed node are blocked; independent branches continue |
| **Advanced gating** | `when` expressions | `depends` boolean logic (`A.Succeeded && B.Failed`) |

Rule of thumb: **`dag` extracts more parallelism** because it is not stage-gated. Use `steps` when readability of a mostly-sequential flow matters more than squeezing out concurrency.

### 2.3 Executors — the most important operational trade-off

The executor is the code in the **wait container** that captures outputs and the exit code. Historically Argo shipped four (`docker`, `kubelet`, `k8sapi`, `pns`); **since v3.3 the default and recommended executor is `emissary`**, and the legacy ones were removed in v3.4.

| Executor | Mechanism | Needs privileged access? | Captures exact exit code? | Status |
|---|---|---|---|---|
| **emissary** (current default) | `argoexec` is PID 1, `exec`s and reaps the user command via a shared `emissary` volume | No | Yes | **Recommended / only one in ≥ v3.4** |
| `docker` (legacy) | Talks to the Docker socket | Yes (mounts `docker.sock`) | Yes | Removed |
| `kubelet` (legacy) | Kubelet API | Partial | No (log-scraped) | Removed |
| `k8sapi` (legacy) | K8s API `exec`/`logs` | No | No (relies on logs) | Removed |
| `pns` (legacy) | Shared process namespace + `/proc` polling | `SYS_PTRACE` | Yes | Removed |

**Why emissary matters in production:** it needs **no Docker socket, no privileged securityContext, and no CRI coupling**, so it works on containerd, CRI-O, GKE Autopilot, and restrictive Pod Security Admission (`restricted`) namespaces. It does require that your container images have a shell-free-compatible command resolvable on `PATH`, and it reserves `/var/run/argo`. If your image has an unusual entrypoint, set `command:` explicitly — the classic emissary failure is `Error: failed to find name in PATH`.

### 2.4 `retryStrategy.retryPolicy` semantics

| `retryPolicy` | Retries on failure (exit ≠ 0)? | Retries on error (infra: pod deleted, node lost, image pull)? |
|---|---|---|
| `Always` | Yes | Yes |
| `OnFailure` | Yes | No |
| `OnError` | No | Yes |
| `OnTransientError` | No | Only if the error message matches the transient-error allowlist (`TRANSIENT_ERROR_PATTERN`) |

**Default is `OnFailure`.** For flaky infrastructure (spot/preemptible nodes) you usually want `Always` with a bounded `backoff`. For deterministic user bugs, retrying is pointless — cap `limit` low.

### 2.5 Artifact repository backends

| Backend | Key type | Notes |
|---|---|---|
| S3 (AWS or MinIO) | `s3` | IRSA / IAM role or accessKey/secretKey secret; most common |
| Google Cloud Storage | `gcs` | Workload Identity or service-account JSON key |
| Azure Blob | `azure` | Managed identity or connection-string secret |
| Alibaba OSS | `oss` | |
| HDFS | `hdfs` | Kerberos supported |
| Git | `git` | Input-only (clone a repo as an artifact) |
| HTTP / raw | `http`/`raw` | Input-only; `raw` inlines literal content |

Configure a default repo in the controller ConfigMap, or per-namespace with an `artifact-repositories` ConfigMap and the `workflows.argoproj.io/default-artifact-repository` annotation. **Artifact GC** (v3.4+) lets you delete artifacts `OnWorkflowCompletion` / `OnWorkflowDeletion` so object stores don't grow unbounded.

---

## 3. Complete, uncut manifests and infrastructure

### 3.1 Installation (namespace-scoped install)

Argo ships two install profiles: **cluster install** (`ClusterRole`, watches all namespaces) and **namespace install** (`Role`, watches one namespace — the multi-tenant-safe choice). Reference manifests, pinned by tag:

```bash
$ kubectl create namespace argo
$ kubectl apply -n argo \
  -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.11/namespace-install.yaml
```

### 3.2 `workflow-controller-configmap` — the operational control surface

This ConfigMap is where an SRE tunes the controller: default artifact repository, parallelism, executor resources, node status offloading, and metrics. Complete, production-shaped example:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: workflow-controller-configmap
  namespace: argo
data:
  # --- Global concurrency guardrails ---
  parallelism: "50"                 # max concurrently-running workflows (whole controller)
  namespaceParallelism: "20"        # max concurrently-running workflows per namespace

  # --- Node status offloading: keep large workflows out of the 1.5 MB etcd object limit ---
  # When a Workflow's node status grows past the etcd object size, offload it to Postgres.
  persistence: |
    connectionPool:
      maxIdleConns: 100
      maxOpenConns: 0
    nodeStatusOffLoad: true
    archive: true
    archiveTTL: 7d
    postgresql:
      host: postgres.argo.svc.cluster.local
      port: 5432
      database: argo
      tableName: argo_workflows
      userNameSecret:
        name: argo-postgres-config
        key: username
      passwordSecret:
        name: argo-postgres-config
        key: password

  # --- Default artifact repository (S3 / MinIO) ---
  artifactRepository: |
    archiveLogs: true
    s3:
      endpoint: minio.argo.svc.cluster.local:9000
      bucket: argo-artifacts
      insecure: true                # true only for in-cluster MinIO over HTTP
      keyFormat: "wf/{{workflow.namespace}}/{{workflow.name}}/{{pod.name}}"
      accessKeySecret:
        name: argo-artifacts-s3
        key: accesskey
      secretKeySecret:
        name: argo-artifacts-s3
        key: secretkey

  # --- Executor (emissary) resource footprint applied to the wait/init containers ---
  executor: |
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 512Mi

  # --- Pod GC & workflow TTL defaults ---
  podGC: |
    strategy: OnWorkflowSuccess       # delete step Pods once the wf succeeds (keep on failure to debug)

  # --- Prometheus metrics ---
  metricsConfig: |
    enabled: true
    path: /metrics
    port: 9090

  # --- Default workflow spec merged into every submitted workflow ---
  workflowDefaults: |
    spec:
      ttlStrategy:
        secondsAfterCompletion: 86400   # GC the Workflow object 24h after it finishes
        secondsAfterSuccess: 3600
        secondsAfterFailure: 172800     # keep failures longer for post-mortem
      podGC:
        strategy: OnWorkflowSuccess
      activeDeadlineSeconds: 21600       # hard 6h wall-clock ceiling per workflow
```

Every key here is a real operational lever. The two most consequential for scale are **`nodeStatusOffLoad: true`** (workflows with thousands of nodes will otherwise hit the etcd 1.5 MB object limit and the controller logs `offload node status is not supported`) and **`parallelism`/`namespaceParallelism`** (the blast-radius guardrail against a single tenant saturating the cluster).

### 3.3 A complete production DAG workflow

DAG with parameters, artifacts, per-task retries, resource limits, a `when` gate, fan-out over `withParam`, and an exit handler:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: etl-pipeline-
  namespace: data-eng
spec:
  entrypoint: main
  serviceAccountName: argo-workflow          # SA with the RBAC from §3.6
  arguments:
    parameters:
      - name: source-date
        value: "2026-08-12"
  onExit: notify                             # runs whether the wf succeeds or fails

  # Controller-level retry defaults for every template unless overridden
  templateDefaults:
    retryStrategy:
      limit: "3"
      retryPolicy: OnFailure
      backoff:
        duration: "30s"
        factor: "2"
        maxDuration: "5m"

  templates:
    # ---- The DAG that wires the pipeline together ----
    - name: main
      dag:
        tasks:
          - name: extract
            template: extract
            arguments:
              parameters: [{name: date, value: "{{workflow.parameters.source-date}}"}]

          - name: validate
            template: validate
            dependencies: [extract]
            arguments:
              artifacts:
                - name: raw
                  from: "{{tasks.extract.outputs.artifacts.raw}}"

          # Fan-out: one transform task per shard emitted by validate
          - name: transform
            template: transform
            dependencies: [validate]
            withParam: "{{tasks.validate.outputs.parameters.shards}}"
            arguments:
              parameters: [{name: shard, value: "{{item}}"}]

          - name: load
            template: load
            # boolean depends: run only if all transforms succeeded AND validate passed
            depends: "transform.Succeeded && validate.Succeeded"

          - name: publish-report
            template: publish-report
            depends: "load.Succeeded"
            when: "{{workflow.parameters.source-date}} != ''"

    # ---- extract: container template producing an artifact ----
    - name: extract
      inputs:
        parameters: [{name: date}]
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/extract.py]
        args: ["--date", "{{inputs.parameters.date}}", "--out", "/out/raw.parquet"]
        resources:
          requests: {cpu: "500m", memory: 512Mi}
          limits:   {cpu: "1",    memory: 1Gi}
      outputs:
        artifacts:
          - name: raw
            path: /out/raw.parquet

    # ---- validate: script template emitting a JSON list output parameter ----
    - name: validate
      inputs:
        artifacts: [{name: raw, path: /in/raw.parquet}]
      script:
        image: ghcr.io/acme/etl:1.9.2
        command: [python]
        source: |
          import json, pyarrow.parquet as pq
          n = pq.read_table("/in/raw.parquet").num_rows
          assert n > 0, "empty extract"
          shards = [f"shard-{i}" for i in range(4)]
          with open("/tmp/shards.json", "w") as f:
              json.dump(shards, f)
      outputs:
        parameters:
          - name: shards
            valueFrom: {path: /tmp/shards.json}

    # ---- transform: one pod per shard ----
    - name: transform
      inputs:
        parameters: [{name: shard}]
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/transform.py]
        args: ["--shard", "{{inputs.parameters.shard}}"]
      retryStrategy:                          # override: spot-friendly, retry on infra loss too
        limit: "5"
        retryPolicy: Always
        backoff: {duration: "15s", factor: "2", maxDuration: "3m"}

    - name: load
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/load.py]

    - name: publish-report
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/report.py]

    # ---- exit handler: fires on success or failure ----
    - name: notify
      container:
        image: curlimages/curl:8.10.1
        command: [sh, -c]
        args:
          - >
            curl -s -XPOST "$SLACK_URL" -d
            '{"text":"wf {{workflow.name}} finished: {{workflow.status}} in {{workflow.duration}}"}'
        env:
          - name: SLACK_URL
            valueFrom: {secretKeyRef: {name: slack-webhook, key: url}}
```

### 3.4 `WorkflowTemplate` + `CronWorkflow` (reusable + scheduled)

Reusable templates are the production pattern: author once, invoke by reference, schedule with a `CronWorkflow`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: nightly-etl
  namespace: data-eng
spec:
  entrypoint: main
  arguments:
    parameters: [{name: source-date, value: "auto"}]
  templates:
    - name: main
      container:
        image: ghcr.io/acme/etl:1.9.2
        command: [python, /app/run.py]
        args: ["--date", "{{workflow.parameters.source-date}}"]
---
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: nightly-etl-cron
  namespace: data-eng
spec:
  schedule: "0 2 * * *"                 # 02:00 daily
  timezone: "America/Argentina/Buenos_Aires"
  concurrencyPolicy: "Forbid"          # never overlap runs
  startingDeadlineSeconds: 300         # miss the window? skip, don't backfill forever
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 10
  workflowSpec:
    serviceAccountName: argo-workflow
    workflowTemplateRef:
      name: nightly-etl                # invoke the template by reference
    arguments:
      parameters: [{name: source-date, value: "{{workflow.creationTimestamp.Y}}-{{workflow.creationTimestamp.m}}-{{workflow.creationTimestamp.d}}"}]
```

### 3.5 Synchronization — semaphores and mutexes (deadlock prevention)

To cap how many workflows/steps hit a shared external system (a database, a licensed API, a staging environment), Argo reads limits from a ConfigMap.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-semaphores
  namespace: data-eng
data:
  db-writers: "2"        # at most 2 concurrent holders
---
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: gated-
spec:
  entrypoint: main
  synchronization:                    # workflow-level gate
    semaphore:
      configMapKeyRef: {name: argo-semaphores, key: db-writers}
  templates:
    - name: main
      steps:
        - - name: write
            template: writer
    - name: writer
      synchronization:                # step-level mutex: strictly one at a time
        mutex: {name: staging-env}
      container: {image: busybox, command: [sh, -c, "echo writing; sleep 10"]}
```

### 3.6 RBAC for the workflow ServiceAccount

Every step Pod runs under a ServiceAccount whose token the executor uses to patch its own Pod and Workflow node status, and (for `resource` templates) to create/get Kubernetes objects. The minimum for a normal container/DAG workflow:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: argo-workflow, namespace: data-eng}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: argo-workflow, namespace: data-eng}
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, watch, patch]                 # executor patches its own pod
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get, watch]
  - apiGroups: [argoproj.io]
    resources: [workflowtaskresults]
    verbs: [create, patch]                      # emissary writes results here (v3.4+)
  - apiGroups: [argoproj.io]
    resources: [workflowtasksets, workflowtasksets/status]
    verbs: [list, watch, patch]                 # only for agent/HTTP templates
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: argo-workflow, namespace: data-eng}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: argo-workflow}
subjects: [{kind: ServiceAccount, name: argo-workflow, namespace: data-eng}]
```

> **Common production failure:** forgetting `workflowtaskresults: [create, patch]`. On v3.4+, emissary reports outputs via a `WorkflowTaskResult` object; without this rule steps run but the controller logs `Failed to patch WorkflowTaskResult ... is forbidden` and outputs/exit codes never propagate, leaving nodes stuck in `Running`.

---

## 4. CLI commands and real terminal output

### 4.1 Submit and watch

```bash
$ argo submit -n data-eng etl.yaml --watch
Name:                etl-pipeline-8k2vq
Namespace:           data-eng
ServiceAccount:      argo-workflow
Status:              Running
Created:             Wed Aug 12 02:00:01 -0300 (10 seconds ago)
Started:             Wed Aug 12 02:00:01 -0300 (10 seconds ago)
Duration:            10 seconds
Progress:            2/6
Parameters:
  source-date:       2026-08-12

STEP                        TEMPLATE         PODNAME                        DURATION  MESSAGE
 ● etl-pipeline-8k2vq       main
 ├───✔ extract              extract          etl-pipeline-8k2vq-1837471290  6s
 ├───● validate             validate         etl-pipeline-8k2vq-2948562301  3s
 ├───○ transform            transform
 ├───○ load                 load
 └───○ publish-report       publish-report
```

Node glyphs: `✔` succeeded, `●` running, `○` pending, `✖`/`✘` failed, `◷` retrying.

### 4.2 List, get, logs

```bash
$ argo list -n data-eng
NAME                 STATUS      AGE   DURATION   PRIORITY   MESSAGE
etl-pipeline-8k2vq   Succeeded   4m    1m         0
gated-abc12          Running     30s   30s        0

$ argo get -n data-eng etl-pipeline-8k2vq -o wide
Name:                etl-pipeline-8k2vq
Status:              Succeeded
Conditions:
 PodRunning          False
 Completed           True
Duration:            1 minute 12 seconds
ResourcesDuration:   4m3s*(1 cpu),9m12s*(100Mi memory)

$ argo logs -n data-eng etl-pipeline-8k2vq --follow
etl-pipeline-8k2vq-1837471290: 2026-08-12T05:00:07Z INFO  extracted 1.2M rows -> /out/raw.parquet
etl-pipeline-8k2vq-2948562301: 2026-08-12T05:00:11Z INFO  validation ok, 4 shards
etl-pipeline-8k2vq-3051673412: 2026-08-12T05:00:20Z INFO  transform shard-0 done
```

### 4.3 Retry, resubmit, stop, terminate — know the difference

```bash
# retry: re-run a FAILED workflow, reusing successful nodes (memoized), only from failure points
$ argo retry -n data-eng etl-pipeline-8k2vq
Name:   etl-pipeline-8k2vq   Status: Running (retried)

# resubmit: brand-new run from the same spec (new name, nothing reused)
$ argo resubmit -n data-eng etl-pipeline-8k2vq
Name:   etl-pipeline-9m4xp

# stop: graceful — runs the onExit handler, then stops
$ argo stop -n data-eng gated-abc12

# terminate: hard — kills everything immediately, NO exit handler
$ argo terminate -n data-eng gated-abc12
```

| Command | Runs exit handler? | Reuses prior nodes? | Result |
|---|---|---|---|
| `argo retry` | yes | yes (successful nodes) | same Workflow object resumes |
| `argo resubmit` | n/a | no | new Workflow object |
| `argo stop` | **yes** | — | graceful shutdown |
| `argo terminate` | **no** | — | immediate kill |

### 4.4 Lint before you ship, and suspend/resume gates

```bash
$ argo lint -n data-eng etl.yaml
✔ etl.yaml is valid

$ argo submit -n data-eng approval-wf.yaml            # contains a `suspend` template
$ argo resume -n data-eng approval-wf-xyz --node-field-selector displayName=wait-for-approval
```

### 4.5 The Kubernetes-native view (no argo CLI needed)

Everything is visible through `kubectl` because it is all CRDs:

```bash
$ kubectl get wf -n data-eng
NAME                 STATUS      AGE
etl-pipeline-8k2vq   Succeeded   5m

$ kubectl get pods -n data-eng -l workflows.argoproj.io/workflow=etl-pipeline-8k2vq
NAME                            READY   STATUS      RESTARTS   AGE
etl-pipeline-8k2vq-1837471290   0/2     Completed   0          5m
etl-pipeline-8k2vq-2948562301   0/2     Completed   0          5m
```

---

## 5. Verification and failure diagnosis guide

### 5.1 The diagnostic ladder

Always debug top-down: **Workflow status → node message → Pod events → container logs → controller logs.**

```bash
# 1. Why did the workflow fail? Read the node-level message
$ argo get -n data-eng etl-pipeline-8k2vq
   └─✖ transform(0:shard-0)  transform  ...  Error (exit code 137)   # 137 = OOMKilled

# 2. Confirm at the Pod level
$ kubectl describe pod -n data-eng etl-pipeline-8k2vq-3051673412
  State:      Terminated
  Reason:     OOMKilled
  Exit Code:  137
  Events:
    Warning  Failed   kubelet  Memory cgroup out of memory: killed process

# 3. Read the failing container's logs
$ kubectl logs -n data-eng etl-pipeline-8k2vq-3051673412 -c main

# 4. If nodes are stuck (not failing), read the CONTROLLER
$ kubectl logs -n argo deploy/workflow-controller --tail=100 | grep -i error
```

### 5.2 Failure catalogue — symptom → cause → fix

| Symptom / message | Root cause | Fix |
|---|---|---|
| Pod stuck `Pending`, node never starts | Unschedulable: no CPU/mem, taints, or PVC unbound | `kubectl describe pod` → read Events; adjust `resources`/tolerations/nodeSelector |
| `Error: failed to find name in PATH` | emissary can't resolve the command | Set `command:` explicitly; ensure the binary is on `PATH` |
| Node stuck `Running` forever; controller logs `Failed to patch WorkflowTaskResult ... forbidden` | Missing `workflowtaskresults` RBAC | Add the RBAC rule in §3.6 |
| `failed to save outputs: ... no such file or directory` | `outputs.artifacts.path` / `outputs.parameters.valueFrom.path` doesn't exist in the container | Verify the step actually writes to that exact path |
| `failed to put file: ... 403 AccessDenied` | Artifact repo credentials/IAM wrong | Check the S3 secret / IRSA role; test with `argo submit` of a raw-artifact wf |
| exit code `137` | OOMKilled | Raise memory `limits`, or shard the work |
| exit code `143` | SIGTERM (terminated/deadline) | Check `activeDeadlineSeconds` and `terminate` events |
| Workflow `Error`: `offload node status is not supported` | Node status exceeded etcd 1.5 MB with offload disabled | Enable `nodeStatusOffLoad: true` + Postgres/MySQL |
| Workflows queue and never start | `parallelism`/`namespaceParallelism` cap reached, or semaphore/mutex held | Inspect `synchronization.status`; raise limits or release the lock |
| `ImagePullBackOff` on the wait/init container | executor image not pullable (airgap/registry) | Mirror `quay.io/argoproj/argoexec`; set `executor.image`/`imagePullSecrets` |
| CronWorkflow never fires | Bad `schedule`/`timezone`, or `concurrencyPolicy: Forbid` with a stuck prior run | `kubectl get cronwf -o yaml` → read `.status`; check `startingDeadlineSeconds` |

### 5.3 Verify the control plane is healthy

```bash
$ kubectl get deploy -n argo
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
argo-server           1/1     1            1           12d
workflow-controller   1/1     1            1           12d

# Controller leader-election & reconcile health via metrics
$ kubectl -n argo port-forward deploy/workflow-controller 9090:9090 &
$ curl -s localhost:9090/metrics | grep -E 'argo_workflows_(count|error_count|queue_depth)'
argo_workflows_count{status="Running"} 3
argo_workflows_count{status="Failed"} 1
argo_workflows_error_count 0
argo_workflows_workers_busy_count{worker_type="workflow_queue"} 2
```

Key SLO metrics to alert on: `argo_workflows_error_count` (controller-internal errors), `argo_workflows_queue_depth_count` (reconcile backlog — rising means the controller is falling behind), and `argo_workflows_k8s_request_total{status_code!="200"}` (API throttling). A rising `workflow_ttl_queue` depth with growing Workflow object counts means GC is not keeping up — check `ttlStrategy`.

### 5.4 Fast reproduction harness for artifact/RBAC issues

Before blaming a 6-stage pipeline, prove the plumbing with a one-line workflow:

```bash
$ argo submit -n data-eng --watch - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {generateName: smoke-}
spec:
  entrypoint: main
  serviceAccountName: argo-workflow
  templates:
    - name: main
      container: {image: busybox, command: [sh, -c, "echo hi > /tmp/o.txt"]}
      outputs:
        artifacts: [{name: o, path: /tmp/o.txt}]     # exercises the artifact repo end-to-end
EOF
```

If this smoke test uploads its artifact and reaches `Succeeded`, the executor, RBAC, and artifact repository are all correct — the fault is in your pipeline, not the platform.

---

## 6. References

- Argo Workflows — Official documentation: https://argo-workflows.readthedocs.io/en/stable/
- Argo Workflows — GitHub repository & releases: https://github.com/argoproj/argo-workflows
- Workflow / template field reference: https://argo-workflows.readthedocs.io/en/stable/fields/
- Core concepts (Workflow, Template, node): https://argo-workflows.readthedocs.io/en/stable/core-concepts/
- Workflow templates: https://argo-workflows.readthedocs.io/en/stable/workflow-templates/
- Cron workflows: https://argo-workflows.readthedocs.io/en/stable/cron-workflows/
- Executors (emissary): https://argo-workflows.readthedocs.io/en/stable/workflow-executors/
- Configuring artifact repositories: https://argo-workflows.readthedocs.io/en/stable/configure-artifact-repository/
- Retries: https://argo-workflows.readthedocs.io/en/stable/retries/
- Synchronization (semaphores & mutexes): https://argo-workflows.readthedocs.io/en/stable/synchronization/
- Workflow controller ConfigMap: https://argo-workflows.readthedocs.io/en/stable/workflow-controller-configmap/
- Node status offloading & archive: https://argo-workflows.readthedocs.io/en/stable/offloading-large-workflows/
- Argo CLI reference: https://argo-workflows.readthedocs.io/en/stable/cli/argo/
- Prometheus metrics: https://argo-workflows.readthedocs.io/en/stable/metrics/
- CAPA curriculum (CNCF): https://github.com/cncf/curriculum/blob/master/capa/README.md
- Argo Project (CNCF Graduated): https://www.cncf.io/projects/argo/