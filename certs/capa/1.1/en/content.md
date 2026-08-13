# CAPA 1.1 — Argo Project Fundamentals

> **Domain weight:** 20% · **Level:** Advanced (SRE / Platform Architect) · **Authoring language:** English
>
> This chapter establishes the conceptual and architectural substrate shared by every tool in the Argo ecosystem. Everything you learn in the Workflows, CD, Rollouts, and Events domains rests on the four ideas developed here: **Kubernetes-native CRDs**, the **controller/reconciliation loop**, **declarative desired state**, and **GitOps**. Treat this as the load-bearing chapter — the exam rewards understanding *why* Argo is built the way it is, not just *what* the CLIs do.

---

## 1. Motivation and the production architectural problem

### 1.1 The problem Argo exists to solve

A modern platform team operating Kubernetes at scale faces four recurring, distinct problems. Argo is not a single tool — it is a **family of four CNCF-graduated controllers**, each attacking one of these problems with the *same* architectural pattern:

| Production problem | Symptom in the field | Argo project |
|---|---|---|
| **Configuration drift** — the live cluster no longer matches what is in Git | "It works in staging, nobody knows why prod is different"; manual `kubectl edit` never captured | **Argo CD** (continuous delivery / GitOps) |
| **Complex, DAG-shaped batch orchestration** — CI/CD, ETL, ML pipelines that outgrow a shell script | Jenkins pipelines wrapping `kubectl run`; no retries, no artifact lineage, no parallelism control | **Argo Workflows** (workflow engine) |
| **Risky deployments** — a bad rollout takes 100% of traffic instantly | `Deployment` `RollingUpdate` has no automated metric-driven abort; rollback is manual and slow | **Argo Rollouts** (progressive delivery) |
| **Event-driven glue** — "when X happens in system A, do Y in Kubernetes" | Cron polling, bespoke webhook receivers, no dependency logic between events | **Argo Events** (event-driven automation) |

The architectural insight that unifies them: **do not build a bespoke daemon for each problem. Extend the Kubernetes API with a new resource type (a CRD) and write a controller that continuously drives reality toward the resource's declared spec.** This is the *operator pattern*, and Argo is one of the most complete real-world demonstrations of it.

### 1.2 Why "Kubernetes-native" is an architectural decision, not a slogan

Consider the alternative designs a platform team could have chosen for continuous delivery:

- **Push-based CI (Jenkins/GitLab pushing `kubectl apply`)** — the CI runner needs cluster-admin credentials, which now live *outside* the cluster's trust boundary. Every runner is an attack surface with a golden key. There is no continuous convergence: once `apply` finishes, drift is invisible until the next pipeline runs.
- **A custom in-house sync daemon** — you now own the reconciliation semantics, the caching, the RBAC, the diff engine, and the UI. This is a multi-year investment that every team reinvents.
- **Argo's choice: a controller inside the cluster that pulls from Git.** State lives in the cluster's own API server (as CRs). The reconciliation loop is continuous. Credentials never leave the cluster. Observability is `kubectl get` plus a purpose-built UI.

The rest of this chapter dissects that shared machinery so the tool-specific chapters can move fast.

---

## 2. The Argo Project: scope, governance, and maturity

### 2.1 The four core projects (plus the ecosystem)

```
                         ┌─────────────────────────────────────────┐
                         │              Argo Project                │
                         │        (CNCF Graduated — Dec 2022)       │
                         └─────────────────────────────────────────┘
                                          │
     ┌───────────────┬────────────────────┼────────────────────┬───────────────┐
     ▼               ▼                    ▼                    ▼               ▼
┌──────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐   (ecosystem
│ Argo CD  │   │ Argo         │   │ Argo Rollouts │   │ Argo Events  │    add-ons:
│ GitOps   │   │ Workflows    │   │ Progressive   │   │ Event-driven │    ApplicationSet,
│ CD       │   │ DAG/step     │   │ delivery      │   │ automation   │    Notifications,
│          │   │ orchestration│   │ (canary/BG)   │   │ (bus+sources)│    argo-cd-image-updater)
└──────────┘   └──────────────┘   └───────────────┘   └──────────────┘
```

All four graduated together in the CNCF as a single project on **2022-12-06** — graduation is the CNCF's highest maturity tier and signals production adoption, security audits, and diverse governance.

### 2.2 How the projects compose (this is exam-relevant)

The projects are independent binaries but are designed to **chain**:

```
   Git push / webhook
          │
          ▼
   ┌──────────────┐  event   ┌──────────────┐  submit  ┌──────────────┐
   │ Argo Events  │ ───────▶ │ Argo         │ ───────▶ │  (build/test │
   │ EventSource  │          │ Workflows    │          │   artifacts) │
   │ + Sensor     │          │              │          └──────────────┘
   └──────────────┘          └──────────────┘
                                                              │ commit new image tag to Git
                                                              ▼
                              ┌──────────────┐   syncs   ┌──────────────┐
                              │  Argo CD     │ ────────▶ │ Argo Rollouts│
                              │  (GitOps)    │  Rollout  │  (canary +   │
                              │              │  manifest │   analysis)  │
                              └──────────────┘           └──────────────┘
```

A canonical production pipeline: **Events** detects a Git push → triggers a **Workflow** that builds and tests → the Workflow commits an updated image tag → **Argo CD** detects the Git change and syncs → the synced resource is a **Rollout** that progressively shifts traffic while querying metrics.

### 2.3 The one pattern behind all four

Every Argo project is an instance of the same triad:

| Layer | What it is | Example (Argo CD) | Example (Workflows) |
|---|---|---|---|
| **Custom Resource (CRD)** | The declarative *desired state*, stored in etcd like any native object | `Application`, `ApplicationSet` | `Workflow`, `WorkflowTemplate`, `CronWorkflow` |
| **Controller** | A control loop watching those CRs | `argocd-application-controller` | `workflow-controller` |
| **Reconciliation** | Continuously drives *live state* → *desired state* | Sync git manifests into cluster | Create pods for each workflow node |

If you internalize *CRD + controller + reconciliation*, every Argo tool becomes a variation on a theme.

---

## 3. Core concept 1 — Custom Resource Definitions (CRDs)

### 3.1 Why extend the API instead of building a sidecar service

A CRD registers a new `kind` with the Kubernetes API server. Once registered, `Application`, `Workflow`, and `Rollout` are **first-class API objects**: they get `kubectl get/describe/apply`, RBAC, admission control, audit logging, `resourceVersion` optimistic concurrency, watch streams, and etcd persistence — **for free**. Argo writes zero storage code.

Inspect the CRDs Argo installs:

```bash
$ kubectl get crd | grep argoproj.io
applications.argoproj.io                    2026-08-01T09:14:22Z
applicationsets.argoproj.io                 2026-08-01T09:14:22Z
appprojects.argoproj.io                     2026-08-01T09:14:22Z
clusterworkflowtemplates.argoproj.io        2026-08-01T09:15:03Z
cronworkflows.argoproj.io                   2026-08-01T09:15:03Z
workflows.argoproj.io                       2026-08-01T09:15:03Z
workflowtemplates.argoproj.io               2026-08-01T09:15:03Z
rollouts.argoproj.io                        2026-08-01T09:15:41Z
analysistemplates.argoproj.io               2026-08-01T09:15:41Z
analysisruns.argoproj.io                    2026-08-01T09:15:41Z
experiments.argoproj.io                     2026-08-01T09:15:41Z
eventsources.argoproj.io                    2026-08-01T09:16:12Z
sensors.argoproj.io                         2026-08-01T09:16:12Z
eventbus.argoproj.io                        2026-08-01T09:16:12Z
```

### 3.2 The anatomy every Argo CR shares

Every Argo CR follows the standard Kubernetes object contract: `spec` is what the user declares; `status` is what the controller reports back. **You write `spec`. The controller owns `status`. Never edit `status` by hand.**

```yaml
apiVersion: argoproj.io/v1alpha1   # group / version — most Argo CRDs are still v1alpha1
kind: Application                  # the CRD kind
metadata:
  name: my-app
  namespace: argocd                # Argo CD Applications live in the control-plane namespace
spec:                              # DESIRED STATE — authored by you / Git
  # ...
status:                            # OBSERVED STATE — written by the controller, read-only to you
  # ...
```

> **Trap:** most Argo CRDs are still `v1alpha1`. The `alpha` in the API version does **not** mean "not production-ready" — the projects are CNCF-graduated. It is an API-stability label that the Argo maintainers have chosen not to bump because doing so requires a conversion-webhook migration burden. Do not conflate API version with project maturity.

---

## 4. Core concept 2 — the controller and its reconciliation loop

### 4.1 The control loop

A controller is a program running an infinite loop:

```
   for-ever:
     desired = read spec of every watched CR         (from the API server cache / informer)
     live    = observe actual cluster state
     diff    = desired − live
     if diff != ∅:
         act to close the diff (create/update/delete child resources)
     write observed result into status
     wait for next event OR resync interval
```

This is **level-triggered** (also called *level-based*) reconciliation, and it is the single most important design property to understand for the exam.

### 4.2 Level-triggered vs edge-triggered — the trade-off that makes GitOps self-healing

| Property | **Edge-triggered** (react to the event) | **Level-triggered** (react to the state) — *Argo's model* |
|---|---|---|
| Trigger | The transition ("a push happened") | The current condition ("live ≠ desired") |
| Missed event | **Permanently lost** — state diverges forever | **Irrelevant** — the next resync re-observes and corrects |
| Controller restart | May miss what happened while down | Recovers fully by re-observing on startup |
| Manual drift (`kubectl edit` on prod) | Undetected | **Detected and (optionally) reverted** on next loop |
| Idempotency | Hard — must dedupe events | Natural — reconciling an already-correct state is a no-op |
| Cost | Cheap per event | Periodic full comparison (mitigated by informer caches + hashing) |

Because Argo controllers reconcile against *state*, not *events*, they are **self-healing**. If an operator runs `kubectl scale deployment/foo --replicas=1` on a resource Argo CD manages, the next reconciliation observes `live.replicas=1 ≠ desired.replicas=3`, reports **OutOfSync**, and (with `selfHeal: true`) restores it. An edge-triggered CI push model would never notice.

### 4.3 Where the state lives

```
   ┌───────────────────────────────────────────────────────────────┐
   │                     Kubernetes API server                      │
   │   (etcd: the single source of truth for LIVE cluster state)    │
   └───────────────────────────────────────────────────────────────┘
        ▲  watch/list (informer)            │ create/update/patch
        │                                    ▼
   ┌────┴───────────────┐            ┌───────────────────────┐
   │   Argo controller   │  compares  │  child resources it   │
   │ (reconcile loop)    │◀──────────▶│  owns (Deployments,   │
   │                     │            │  Pods, Services, ...)  │
   └─────────────────────┘            └───────────────────────┘
        ▲
        │ DESIRED state
   ┌────┴───────────────┐
   │  Git repo (Argo CD) │   ← for GitOps tools, Git is the desired-state source;
   │  or the CR itself   │     for Workflows/Rollouts, the CR `spec` is authoritative.
   └─────────────────────┘
```

---

## 5. Core concept 3 — declarative desired state

### 5.1 Declarative vs imperative

| Axis | **Imperative** (`kubectl create`, `kubectl scale`, shell scripts) | **Declarative** (`kubectl apply -f`, Argo CRs) |
|---|---|---|
| You specify | The *steps* to reach a state | The *end state* itself |
| Reproducibility | Depends on starting point + order | Same manifest → same result, any starting point |
| Drift detection | Impossible (no recorded intent) | Trivial (compare manifest vs live) |
| Auditability | Scattered in shell history / CI logs | One reviewable Git diff |
| Rollback | Re-derive and re-run reverse steps | `git revert` |
| Argo's stance | Escape hatch only | **The default and the whole point** |

Argo tools are declarative to the core: you never tell Argo CD "sync now, then wait, then patch." You declare an `Application` whose `spec.source` points at a Git path, and the controller figures out the steps.

### 5.2 Idempotency (a CNCF-native and repo-mandated requirement)

Declarative + level-triggered gives **idempotency**: applying the same manifest N times converges to the same state and is a no-op after the first successful reconcile. This is why Argo operations are safe to retry — an interrupted sync, a re-submitted workflow, a re-applied `Application` all resume cleanly instead of duplicating work.

---

## 6. Core concept 4 — GitOps

### 6.1 The four OpenGitOps principles

GitOps is formalized by the CNCF **OpenGitOps** working group. A system is GitOps if it satisfies **all four** principles. Argo CD is a reference implementation.

| # | Principle | Meaning | How Argo CD implements it |
|---|---|---|---|
| 1 | **Declarative** | The entire desired state is expressed declaratively | Kubernetes manifests / Helm / Kustomize in Git |
| 2 | **Versioned & Immutable** | Desired state is stored so it is versioned and enforces immutability, with a full history | Git — commits, tags, signed commits, revert |
| 3 | **Pulled Automatically** | Software agents automatically pull the desired state from the source | `argocd-repo-server` clones the repo; the controller pulls |
| 4 | **Continuously Reconciled** | Agents continuously observe actual state and attempt to apply the desired state | The application-controller's level-triggered loop |

### 6.2 Pull-based vs push-based delivery — the security argument

| Dimension | **Push CD** (CI runs `kubectl apply`) | **Pull CD** (Argo CD reconciles from inside) |
|---|---|---|
| Credential location | Cluster-admin kubeconfig lives in the CI system (outside the cluster) | Credentials never leave the cluster; the agent has in-cluster RBAC |
| Attack surface | Every CI runner is a golden key to prod | No external system holds cluster creds |
| Multi-cluster scale | CI must reach every cluster's API (network + creds fan-out) | Each cluster pulls itself; hub can be firewalled |
| Drift correction | Only at pipeline run time | Continuous, self-healing |
| Source of truth | Ambiguous (CI state + cluster state) | Git, unambiguously |
| Trade-off | Simpler mental model, familiar to CI teams | Requires an in-cluster agent + reconciliation semantics |

This is the single strongest production argument for Argo CD, and a frequent exam theme: **pull-based GitOps keeps deployment credentials inside the trust boundary and makes drift a continuously-corrected condition rather than a point-in-time event.**

---

## 7. Architecture of each Argo control plane (fundamentals depth)

You are not expected to memorize every pod, but you must recognize the component decomposition and the *reason* for it.

### 7.1 Argo CD components

```
                                   ┌────────────────────────────┐
   git repo ◀───── clone/render ───│  argocd-repo-server        │  renders Helm/Kustomize/
                                   │  (manifest generation)     │  Jsonnet/plain YAML → manifests
                                   └────────────┬───────────────┘
                                                │ gRPC
   ┌──────────────┐   watch/apply   ┌───────────┴───────────────┐
   │ K8s API      │◀───────────────▶│ argocd-application-        │  the reconcile loop:
   │ (managed     │                 │ controller                 │  desired(git) vs live(cluster)
   │  clusters)   │                 └───────────┬───────────────┘
   └──────────────┘                             │
                                    ┌───────────┴───────────────┐
   UI / CLI / SSO ◀───────────────▶│ argocd-server (API server) │  REST/gRPC, RBAC, UI
                                    └───────────┬───────────────┘
                                                │
                          ┌─────────────────────┼─────────────────────┐
                          ▼                     ▼                     ▼
                   ┌─────────────┐      ┌─────────────┐       ┌──────────────┐
                   │ redis       │      │ dex (opt.)  │       │ applicationset│
                   │ (cache)     │      │ SSO broker  │       │ + notifications│
                   └─────────────┘      └─────────────┘       └──────────────┘
```

| Component | Responsibility | Why it is separate |
|---|---|---|
| `argocd-application-controller` | The reconciliation engine: diff + sync | The stateful, cluster-mutating core; scaled by sharding across managed clusters |
| `argocd-repo-server` | Clones Git, renders templating tools into raw manifests | CPU/memory-heavy and untrusted-input-facing; isolated so a bad Helm chart can't crash the controller |
| `argocd-server` | API/gRPC + web UI + RBAC enforcement | Read-mostly, horizontally scalable, network-exposed |
| `redis` | Ephemeral cache of rendered manifests + live state | Avoids re-rendering/re-listing on every request; **loss = cache miss, not data loss** |
| `dex` (optional) | Federates external SSO (OIDC/SAML/LDAP) | Optional; can use native OIDC instead |
| `applicationset-controller` | Generates many `Application`s from generators | Templating fan-out (multi-cluster, monorepo) |
| `notifications-controller` | Sends events to Slack/email/webhooks | Cross-cutting; decoupled from the sync core |

### 7.2 Argo Workflows components

- **`workflow-controller`** — watches `Workflow` CRs, walks the DAG/steps, and creates one **Pod per node**. Each pod runs the user's container plus the **emissary executor** (the default and only executor since v3.4), which captures logs, outputs, and artifacts without needing the Docker socket.
- **`argo-server`** — the API/UI, artifact serving, and auth. Optional for pure `kubectl`-driven use.

### 7.3 Argo Rollouts components

- **`argo-rollouts` controller** — a single controller that manages the `Rollout` CRD (a drop-in replacement for `Deployment`), plus `AnalysisTemplate`/`AnalysisRun`/`Experiment`. It manipulates `ReplicaSet`s and (via traffic-router plugins: Istio, SMI, NGINX, ALB, Gateway API, and others) shifts traffic in weighted steps, optionally gating on metric analysis.

### 7.4 Argo Events components

- **`EventBus`** — the transport backbone (JetStream/NATS by default).
- **`EventSource`** — adapts an external source (webhook, S3, Kafka, calendar, SQS…) into events on the bus.
- **`Sensor`** — subscribes to events, applies dependency/trigger logic, and fires **triggers** (create a Workflow, a K8s object, an HTTP call…).

---

## 8. Complete, unabridged manifests (one per project)

These are minimal-but-valid, production-shaped manifests illustrating the shared CRD anatomy. They are syntactically complete and will apply against a cluster with the respective Argo controller installed.

### 8.1 Argo CD — an `Application` (GitOps unit of deployment)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
  # Ensures the app itself and all its children are removed on `kubectl delete application`.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  # The AppProject scoping the RBAC and allowed sources/destinations for this app.
  project: default

  # DESIRED STATE lives in Git — principle #1 (declarative) and #2 (versioned).
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD          # a branch, tag, or commit SHA (SHA = immutable, recommended for prod)
    path: guestbook               # directory within the repo to render

  # Where the rendered manifests are applied.
  destination:
    server: https://kubernetes.default.svc   # in-cluster; or a registered remote cluster URL
    namespace: guestbook

  # Reconciliation behavior — principle #3 (pull) and #4 (continuous reconcile).
  syncPolicy:
    automated:
      prune: true        # delete cluster objects removed from Git
      selfHeal: true     # revert manual drift back to Git's declared state
      allowEmpty: false  # refuse to prune everything if Git renders to zero manifests (safety rail)
    syncOptions:
      - CreateNamespace=true       # create the destination namespace if missing
      - PruneLast=true             # prune only after other resources are healthy
      - ApplyOutOfSyncOnly=true    # apply only drifted resources, not the whole set
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 8.2 Argo Workflows — a two-step DAG `Workflow`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-dag-        # server assigns a unique suffix — idempotent-safe naming
  namespace: argo
spec:
  entrypoint: main                # which template to run first
  serviceAccountName: argo-workflow   # SA the executor pods run as
  templates:
    - name: main
      dag:
        tasks:
          - name: build
            template: echo
            arguments:
              parameters: [{ name: msg, value: "building" }]
          - name: test
            template: echo
            dependencies: [build]     # test runs only after build succeeds — DAG edge
            arguments:
              parameters: [{ name: msg, value: "testing" }]

    - name: echo
      inputs:
        parameters:
          - name: msg
      container:
        image: alpine:3.20
        command: [sh, -c]
        args: ["echo '{{inputs.parameters.msg}}'; sleep 2"]
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { cpu: 200m, memory: 128Mi }
```

### 8.3 Argo Rollouts — a canary `Rollout` (drop-in `Deployment` replacement)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web
  namespace: demo
spec:
  replicas: 5
  revisionHistoryLimit: 3
  selector:
    matchLabels: { app: web }
  template:                        # identical schema to a Deployment's pod template
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: web
          image: argoproj/rollouts-demo:blue
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 50m, memory: 64Mi }
  strategy:
    canary:
      steps:
        - setWeight: 20            # send 20% of traffic to the new version
        - pause: { duration: 60s } # bake, watch metrics
        - setWeight: 50
        - pause: {}                # pause indefinitely — requires manual `promote`
        - setWeight: 100
```

### 8.4 Argo Events — `EventBus` + `EventSource` + `Sensor`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:                       # JetStream is the recommended bus backend
    version: latest
    replicas: 3
---
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    push:                          # named event dependency key referenced by the Sensor
      port: "12000"
      endpoint: /push
      method: POST
---
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: webhook
  namespace: argo-events
spec:
  dependencies:
    - name: push-dep
      eventSourceName: webhook
      eventName: push
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
                generateName: reacted-
              spec:
                containers:
                  - name: hello
                    image: alpine:3.20
                    command: [echo, "event received"]
                restartPolicy: Never
```

---

## 9. Installation and first-contact CLI (real terminal output)

### 9.1 Install Argo CD

```bash
$ kubectl create namespace argocd
namespace/argocd created

$ kubectl apply -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/applicationsets.argoproj.io created
customresourcedefinition.apiextensions.k8s.io/appprojects.argoproj.io created
serviceaccount/argocd-application-controller created
...
deployment.apps/argocd-repo-server created
deployment.apps/argocd-server created
statefulset.apps/argocd-application-controller created

$ kubectl -n argocd get pods
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          73s
argocd-applicationset-controller-6b8c9f7d5b-x2n4k   1/1     Running   0          73s
argocd-dex-server-7c4f9d9f8c-mn2pq                  1/1     Running   0          73s
argocd-notifications-controller-5d9b7c8f9-qk4rt     1/1     Running   0          73s
argocd-redis-6f9c7d5b4c-8sw2l                       1/1     Running   0          73s
argocd-repo-server-84b7f9c6d8-lk9vn                 1/1     Running   0          73s
argocd-server-6d8c9f7b5d-w7xq2                      1/1     Running   0          73s
```

### 9.2 Log in and deploy the first Application via CLI

```bash
$ argocd admin initial-password -n argocd
kR7pT2xQ9mZ4bWnL
 This password must be only used for first time login. We strongly recommend
 you update the password using `argocd account update-password`.

$ argocd login localhost:8080 --username admin --password kR7pT2xQ9mZ4bWnL --insecure
'admin:login' logged in successfully
Context 'localhost:8080' updated

$ argocd app create guestbook \
    --repo https://github.com/argoproj/argocd-example-apps.git \
    --path guestbook \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace guestbook
application 'guestbook' created

$ argocd app get guestbook
Name:               argocd/guestbook
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          guestbook
Repo:               https://github.com/argoproj/argocd-example-apps.git
Target:             HEAD
Path:               guestbook
Sync Policy:        Manual
Sync Status:        OutOfSync from HEAD (53e28ff)
Health Status:      Missing

GROUP  KIND        NAMESPACE  NAME          STATUS     HEALTH   HOOK  MESSAGE
       Service     guestbook  guestbook-ui  OutOfSync  Missing
apps   Deployment  guestbook  guestbook-ui  OutOfSync  Missing

$ argocd app sync guestbook
TIMESTAMP                  GROUP        KIND    NAMESPACE   NAME          STATUS    HEALTH        HOOK  MESSAGE
2026-08-12T14:07:03+00:00  apps  Deployment  guestbook  guestbook-ui  OutOfSync  Missing
2026-08-12T14:07:05+00:00  apps  Deployment  guestbook  guestbook-ui    Synced  Progressing
Operation:          Sync
Phase:              Succeeded
Message:            successfully synced (all tasks run)
```

Note the transition **OutOfSync/Missing → Synced/Progressing → Synced/Healthy**: two orthogonal axes reported by the controller — *sync status* (does live match Git?) and *health status* (is the live resource actually working?).

### 9.3 Submit a Workflow

```bash
$ argo submit -n argo hello-dag.yaml --watch
Name:                hello-dag-4kf9x
Namespace:           argo
Status:              Running
Created:             Wed Aug 12 14:12:01 +0000 (now)

STEP                    TEMPLATE  PODNAME                    DURATION  MESSAGE
 ● hello-dag-4kf9x      main
 ├─✔ build              echo      hello-dag-4kf9x-build-...  4s
 └─● test               echo      hello-dag-4kf9x-test-...   2s

$ argo list -n argo
NAME              STATUS      AGE   DURATION   PRIORITY   MESSAGE
hello-dag-4kf9x   Succeeded   30s   9s         0
```

---

## 10. Verification and failure-diagnosis guide

This is the section that separates an operator from a user. Every Argo problem reduces to one question: **is the controller reconciling, and what does it report in `status`?**

### 10.1 The universal first three commands

```bash
# 1. Is the controller alive and reconciling?
$ kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller
NAME                              READY   STATUS    RESTARTS   AGE
argocd-application-controller-0   1/1     Running   0          2h

# 2. What does the CR's status say? (status is the controller's report of reality)
$ kubectl -n argocd get application guestbook -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
OutOfSync / Degraded

# 3. What is the controller actually logging as it reconciles?
$ kubectl -n argocd logs argocd-application-controller-0 --tail=50 | grep guestbook
```

### 10.2 Argo CD failure taxonomy

| Symptom (`status`) | Likely root cause | Diagnostic | Fix |
|---|---|---|---|
| `OutOfSync` and won't converge | `syncPolicy.automated` not set, or a resource ignored/pruned | `argocd app diff guestbook` | Add `automated: {selfHeal, prune}` or `argocd app sync` |
| `ComparisonError` | `repo-server` can't clone/render (bad creds, bad path, Helm error) | `kubectl -n argocd logs deploy/argocd-repo-server` | Fix repo creds / `path` / chart values |
| `Health: Degraded` | Child resource genuinely broken (CrashLoop, failed probe) | `kubectl describe` the child; `argocd app resources` | Fix the app, not Argo |
| `Health: Progressing` forever | Deployment never reaches ready replicas | `kubectl get deploy -n <ns>` | Image pull? Resource limits? Readiness probe? |
| Sync succeeds but drift returns instantly | Another controller (HPA, mutating webhook) fights Argo | `argocd app diff`; check `ignoreDifferences` | Add `spec.ignoreDifferences` for HPA-managed fields |
| `repo-server` OOMKilled | Large monorepo / Helm chart exceeds memory | `kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-repo-server` shows restarts | Raise repo-server memory; enable manifest caching |

Concrete drift example — HPA vs Argo fighting over `replicas`:

```yaml
# Add to the Application spec so Argo stops reverting the field the HPA owns:
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

### 10.3 Argo Workflows diagnosis

```bash
$ argo get -n argo hello-dag-4kf9x            # per-node status + messages
$ argo logs -n argo hello-dag-4kf9x           # aggregated logs across all pods
$ kubectl -n argo logs deploy/workflow-controller --tail=100   # controller-level errors

# Common failure: workflow stuck Pending → the executor SA lacks RBAC to create pods,
# or no artifact repository is configured. Check:
$ kubectl -n argo describe wf hello-dag-4kf9x | grep -A3 Events
```

| Symptom | Cause | Fix |
|---|---|---|
| Workflow `Pending`, no pods | RBAC: SA can't create pods | Grant the workflow role to the SA |
| Node `Error: could not save outputs` | No artifact repository configured | Configure `artifactRepository` (S3/GCS/MinIO) |
| Pods stuck `Init:0/1` | Emissary executor init issue / image pull | `kubectl describe pod` the node pod |

### 10.4 Argo Rollouts diagnosis

```bash
$ kubectl argo rollouts get rollout web -n demo --watch
Name:            web
Namespace:       demo
Status:          ॥ Paused
Strategy:        Canary
  Step:          1/5
  SetWeight:     20
  ActualWeight:  20
...
$ kubectl argo rollouts promote web -n demo     # advance past a manual pause
$ kubectl argo rollouts abort web -n demo       # roll back to the stable ReplicaSet immediately
```

### 10.5 Argo Events diagnosis

```bash
# The bus must be Running before sources/sensors work:
$ kubectl -n argo-events get eventbus,eventsource,sensor
NAME                             AGE
eventbus.argoproj.io/default     10m

NAME                              AGE
eventsource.argoproj.io/webhook   9m

NAME                          AGE
sensor.argoproj.io/webhook    9m

$ kubectl -n argo-events logs deploy/webhook-eventsource   # did the source receive the event?
$ kubectl -n argo-events logs deploy/webhook-sensor        # did the sensor's dependency fire?
```

| Symptom | Cause | Fix |
|---|---|---|
| Sensor never triggers | EventBus not Ready, or dependency `eventName` mismatch | Verify bus pods; match `eventSourceName`/`eventName` exactly |
| Trigger fires but object not created | Sensor SA lacks RBAC for the target `kind` | Grant the sensor SA `create` on that resource |

### 10.6 Provenance / reproducibility check (platform hygiene)

Because every Argo object is a declarative CR in Git or etcd, you can always answer "who/what created this and can I rebuild it?":

```bash
$ kubectl get application guestbook -n argocd -o yaml \
    | grep -E 'targetRevision|repoURL|path'
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
```

The desired state is fully traceable to a Git commit — the operational equivalent of the repo's own provenance requirement: *nothing exists untraceably*.

---

## 11. Consolidated trade-off summary (exam cram table)

| Concept | Left option | Right option (Argo's choice) | Why it matters |
|---|---|---|---|
| Extension model | Bespoke daemon | **CRD + controller** | Free storage, RBAC, watch, audit |
| Reconciliation | Edge-triggered | **Level-triggered** | Self-healing, restart-safe, idempotent |
| Config style | Imperative | **Declarative** | Reproducible, auditable, revertible |
| Delivery direction | Push (CI → cluster) | **Pull (agent in cluster)** | Credentials stay inside the trust boundary |
| Source of truth | Cluster / CI state | **Git** | Versioned, immutable, reviewable |
| Deployment strategy | `Deployment` RollingUpdate | **Rollout** canary/blue-green + analysis | Metric-gated, abortable, safe |
| Orchestration | Shell/Jenkins scripts | **Workflow** DAG CRs | Retries, parallelism, artifact lineage |
| Automation trigger | Cron polling | **Events** bus + sensors | Dependency logic, many sources |

---

## 12. References

- CNCF CAPA curriculum (authoritative exam scope): https://github.com/cncf/curriculum — specifically `capa/README.md`: https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
- Certified Argo Project Associate (CAPA) — Linux Foundation certification page: https://training.linuxfoundation.org/certification/certified-argo-project-associate-capa/
- Argo Project umbrella site: https://argoproj.github.io/
- CNCF project profile (graduated maturity): https://www.cncf.io/projects/argo/
- Argo CD documentation: https://argo-cd.readthedocs.io/
- Argo CD core concepts & architecture: https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
- Argo Workflows documentation: https://argo-workflows.readthedocs.io/
- Argo Rollouts documentation: https://argo-rollouts.readthedocs.io/
- Argo Events documentation: https://argo-events.readthedocs.io/
- OpenGitOps principles (CNCF GitOps WG): https://opengitops.dev/
- Kubernetes controllers & the reconciliation model: https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes Custom Resource Definitions: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Argo CD source repository: https://github.com/argoproj/argo-cd
- Argo Workflows source repository: https://github.com/argoproj/argo-workflows
- Argo Rollouts source repository: https://github.com/argoproj/argo-rollouts
- Argo Events source repository: https://github.com/argoproj/argo-events