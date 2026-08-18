# 2.1 GitOps Principles & Practices

## 1. Production Motivation: The Architectural Problem

Before GitOps, the dominant operational model for Kubernetes fleets was **CIOps** (CI-driven push deployment): a pipeline runs `kubectl apply` or `helm upgrade` against the cluster at the end of a build, and whatever happens after that moment is invisible to the delivery system. At production scale this model fails along four independent axes:

**Configuration drift.** The cluster's live state is mutated by actors the pipeline knows nothing about: an SRE running `kubectl edit` during an incident, an admission webhook injecting sidecars, an operator scaling a workload, a colleague applying a hotfix from their laptop. Within weeks, no artifact anywhere describes what is actually running. The pipeline's last-applied manifests are a historical claim, not a fact. This is the *snowflake cluster* problem transplanted from the VM era into Kubernetes.

**Credential blast radius.** Push models require the CI system — typically a multi-tenant, internet-adjacent service executing third-party code — to hold cluster-admin (or near-admin) credentials for every target cluster. A single compromised pipeline plugin becomes a fleet-wide compromise. The 2020–2021 wave of CI supply-chain incidents made this the primary security argument for inverting the deployment direction.

**No convergence guarantee.** `kubectl apply` is a one-shot, fire-and-forget operation. If the API server is briefly unavailable, if a CRD is not yet registered, if a node admission race drops a resource — the pipeline either fails the whole run or, worse, half-applies and reports green. Nothing retries after the pipeline exits. Deployment is an *event*, not a *process*.

**Unauditable operations and slow disaster recovery.** When the record of change is a scroll of CI logs plus operator shell history, answering "who changed the `PodDisruptionBudget` and why" requires forensics. Rebuilding a lost cluster requires replaying an unknown sequence of imperative actions in an unknown order.

GitOps resolves all four by restructuring delivery as a **closed-loop control system**, the same architectural pattern Kubernetes itself uses internally (controllers reconciling `spec` toward `status`):

```
             ┌────────────────────────────────────────────────┐
             │              Desired State Store               │
             │        (Git repository / OCI registry)         │
             └───────────────────────┬────────────────────────┘
                                     │  pulled (poll/webhook)
                                     ▼
             ┌────────────────────────────────────────────────┐
             │            Reconciler (software agent)         │
             │   observe live state ──► diff ──► converge     │
             │        Flux / Argo CD, running IN cluster      │
             └───────────────────────┬────────────────────────┘
                                     │  apply / prune / wait
                                     ▼
             ┌────────────────────────────────────────────────┐
             │                 Managed System                 │
             │            (Kubernetes API server)             │
             └────────────────────────────────────────────────┘
```

Humans and CI systems lose write access to the cluster; they gain write access to the state store, gated by the same review machinery as application code (pull requests, branch protection, signed commits, CODEOWNERS). The agent inside the cluster pulls the desired state and drives the system toward it, continuously, forever. Deployment stops being something you *do* and becomes something the system *maintains*.

---

## 2. The Four OpenGitOps Principles (v1.0.0)

The CNCF **OpenGitOps** project (a working group under the CNCF App Delivery TAG) codified GitOps into four normative principles. The CGOA exam tests these definitions precisely — including what they deliberately do *not* say (note: nothing below requires Git specifically, and nothing mentions Kubernetes).

> A GitOps-managed system is one where the **desired state** is (1) expressed declaratively, (2) stored in a versioned, immutable store, (3) pulled automatically by software agents, and (4) continuously reconciled against the live state.

### Principle 1 — Declarative

*"A system managed by GitOps must have its desired state expressed declaratively."*

Declarative means the state store contains **facts about the destination, not instructions for the journey**. `replicas: 6` is declarative; `kubectl scale deployment web --replicas=6` is imperative. The distinction is architectural, not stylistic:

- Declarations are **idempotent and order-tolerant**: applying the same state twice converges to the same result; the reconciler can retry, reorder, and re-apply safely. Imperative sequences are neither — replaying `scale +2` twice gives a different system.
- Declarations are **diffable**: the reconciler can compute `desired − observed` and act only on the delta. There is no meaningful diff between two shell scripts.
- Declarations **compose**: overlays (Kustomize), values (Helm), and policy engines can transform them mechanically.

The desired state is the *source of truth*; the live system is a *derived artifact* — the same relationship a compiled binary has to source code.

### Principle 2 — Versioned and Immutable

*"Desired state is stored in a way that enforces immutability, versioning and retains a complete version history."*

The principle names properties, not products. Git satisfies them (content-addressed commits, append-only history under branch protection), which is why it is the canonical choice — but an **OCI registry with immutable tags** or an S3 bucket with object versioning and object lock are equally conformant state stores. Flux, for instance, can reconcile directly from OCI artifacts with no Git repository in the runtime path at all.

What the properties buy in production:

- **Rollback is a revert.** Every previous system state is addressable by revision; recovery from a bad release is `git revert` + reconciliation — no snowflake "roll-forward-only" pressure.
- **Audit is intrinsic.** Author, reviewer, timestamp, and full content of every change exist by construction. Combined with commit signing and branch protection, the history is tamper-evident.
- **Correlation.** The revision (commit SHA / OCI digest) becomes a fleet-wide correlation ID: the reconciler reports which revision each cluster is running, and incident timelines pin to revisions rather than to wall-clock guesses.

### Principle 3 — Pulled Automatically

*"Software agents automatically pull the desired state declarations from the source."*

The agent runs **inside the trust boundary of the managed system** and reaches *out* to the state store — the inverse of push deployment. Consequences:

- **Credential inversion.** The cluster holds a read-only token for the state store. The state store holds nothing. CI holds nothing that can touch the cluster. The most exposed component in the chain (CI) is stripped of its most dangerous secret.
- **Network inversion.** No inbound path to the Kubernetes API is required — clusters behind NAT, in air-gapped sites, or on edge hardware pull whenever connectivity exists. This is why GitOps is the standard pattern for edge fleets.
- **Automatic** means changes are applied when *available*, not when a human runs a command. Webhooks are an optimization that shortens the poll interval; the poll loop remains the correctness mechanism (webhooks may be lost; polling guarantees eventual pickup).

### Principle 4 — Continuously Reconciled

*"Software agents continuously observe actual system state and attempt to apply the desired state."*

This is the principle that separates GitOps from "CD that happens to use Git." The agent runs an endless control loop — *observe → diff → act* — with **two triggers, not one**:

1. **Desired state changed** (new commit) → converge live state up to it.
2. **Live state changed** (drift: manual edit, deleted resource, failed node) → converge live state *back* to the declaration.

Trigger 2 is what a pipeline can never provide. Drift is detected and either reported or auto-reverted within one reconciliation interval, which means an emergency `kubectl edit` is *undone by design* — the correct emergency procedure in a GitOps system is to suspend reconciliation explicitly (`flux suspend kustomization <name>`, or Argo CD's `spec.syncPolicy` / sync windows), fix, then commit the fix to the state store and resume. "Continuously" promises *perpetual attempts at convergence*, not instantaneous success — the system is eventually consistent.

---

## 3. Trade-off Analysis

### 3.1 Imperative vs. Declarative operations

| Dimension | Imperative (`kubectl create/edit/scale`) | Declarative (manifests + apply/reconcile) |
|---|---|---|
| Idempotency | No — replay changes outcome | Yes — replay converges to same state |
| Auditability | Shell history, if anything | Full versioned history by construction |
| Drift handling | Invisible; drift *is* the workflow | Detectable and revertible (diff exists) |
| Recovery (DR) | Replay unknown command sequence | Point agent at the state store; done |
| Ordering sensitivity | High — sequences must run in order | Low — reconciler retries until converged |
| Incident-time speed | Fast for a one-off hotfix | Requires commit + reconcile (or explicit suspend) |
| Review/approval gates | None inherent | PR review, CODEOWNERS, policy checks |

### 3.2 Push (CIOps) vs. Pull (GitOps)

| Dimension | Push: CI runs `kubectl`/`helm` | Pull: in-cluster agent reconciles |
|---|---|---|
| Cluster credentials | Held by CI, outside the cluster | Never leave the cluster; store token is read-only |
| Network topology | Inbound access to API server required | Outbound-only; NAT/edge/air-gap friendly |
| Post-deploy drift | Undetected until next pipeline run | Corrected/reported every interval |
| Convergence | One-shot; fails if timing is wrong | Retried forever; eventual consistency |
| Fleet scale (100+ clusters) | N pipelines × N credential sets | Same repo, N agents pulling; O(1) config surface |
| Deployment visibility | CI log line "applied" | Live health + sync status per resource |
| Failure mode | Half-applied, pipeline green | Reported `Not Ready` until actually healthy |
| Emergency stop | Cancel pipeline | Suspend reconciliation explicitly |

### 3.3 GitOps vs. traditional CD — where CI still lives

GitOps does **not** replace CI. The boundary is:

| Stage | Owner | Output |
|---|---|---|
| Build, test, scan | CI (push model, unchanged) | Immutable image `registry/app@sha256:…` |
| Release definition | Human or automation opening a PR | Commit updating the image digest / values in the state store |
| Deployment | Reconciler (pull model) | Converged cluster reporting revision + health |

CI's write access ends at the Git repository. The only coupling is a commit.

### 3.4 State store options

| Store | Immutability | Versioning | Latency to agent | Typical use |
|---|---|---|---|---|
| Git repository | Branch protection + SHA addressing | Native | Poll or webhook | Default; human review workflow |
| OCI registry (Flux `OCIRepository`) | Immutable tags / digest pinning | Tag + digest | Fast, CDN-backed | Scale-out fleets; Git stays for authoring, OCI for distribution |
| S3/object storage (`Bucket`) | Object versioning + lock | Native | Poll | Air-gapped mirrors, ML/config artifacts |

---

## 4. Reference Implementation: Complete Manifests

The repository layout below is the standard mono-repo pattern for environments-as-directories (branches-per-environment is an anti-pattern: it forces merge-based promotion and diverging history):

```
fleet-repo/
├── apps/
│   └── podinfo/
│       ├── base/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── staging/
│           │   └── kustomization.yaml
│           └── production/
│               ├── kustomization.yaml
│               └── replicas-patch.yaml
└── clusters/
    └── production/
        ├── flux-system/            # generated by flux bootstrap
        └── apps.yaml               # Flux Kustomization (below)
```

### 4.1 Declarative application base

`apps/podinfo/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  labels:
    app.kubernetes.io/name: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: podinfo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodana/podinfo:6.7.0   # pinned tag, never :latest
          ports:
            - name: http
              containerPort: 9898
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
```

`apps/podinfo/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  labels:
    app.kubernetes.io/name: podinfo
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: podinfo
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

`apps/podinfo/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

`apps/podinfo/overlays/production/replicas-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
spec:
  replicas: 6
```

`apps/podinfo/overlays/production/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: podinfo-prod
resources:
  - ../../base
patches:
  - path: replicas-patch.yaml
```

### 4.2 Flux: source + reconciliation

`clusters/production/apps.yaml` — the `GitRepository` declares *where the desired state lives*; the `Kustomization` declares *what to reconcile from it and how*:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet-repo
  namespace: flux-system
spec:
  interval: 1m                      # poll cadence; webhook receiver can shorten it
  url: https://github.com/example-org/fleet-repo
  ref:
    branch: main
  secretRef:
    name: fleet-repo-auth           # read-only deploy token
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo-production
  namespace: flux-system
spec:
  interval: 10m                     # full re-reconcile even without new commits (drift correction)
  sourceRef:
    kind: GitRepository
    name: fleet-repo
  path: ./apps/podinfo/overlays/production
  prune: true                       # delete cluster objects removed from Git
  wait: true                        # reconcile is not Ready until workloads are healthy
  timeout: 3m
  targetNamespace: podinfo-prod
```

### 4.3 Argo CD equivalent

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo-production
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # cascade-delete managed resources with the app
spec:
  project: default
  source:
    repoURL: https://github.com/example-org/fleet-repo
    targetRevision: main
    path: apps/podinfo/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo-prod
  syncPolicy:
    automated:
      prune: true                   # remove resources deleted from Git
      selfHeal: true                # revert manual drift automatically
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

`prune` and `selfHeal` are the two switches that turn Argo CD from "sync on demand" into a fully Principle-4-conformant reconciler; without `selfHeal`, drift is only *reported* (`OutOfSync`), not corrected.

---

## 5. Operating the Loop: Real CLI Sessions

### 5.1 Bootstrap and first reconciliation (Flux)

```
$ flux check --pre
► checking prerequisites
✔ Kubernetes 1.30.2 >=1.28.0-0
✔ prerequisites checks passed

$ flux bootstrap github \
    --owner=example-org --repository=fleet-repo \
    --branch=main --path=clusters/production
► connecting to github.com
✔ repository "https://github.com/example-org/fleet-repo" created
► installing components in "flux-system" namespace
✔ install completed
► configuring deploy key
✔ deploy key configured with read-only access
✔ sync configured
✔ all components are healthy
```

Note the bootstrap output itself demonstrates Principle 3: the credential provisioned is a **read-only deploy key**, held by the cluster.

### 5.2 Observing desired vs. live state

```
$ flux get kustomizations
NAME                  REVISION            SUSPENDED  READY  MESSAGE
flux-system           main@sha1:8f4e21ab  False      True   Applied revision: main@sha1:8f4e21ab
podinfo-production    main@sha1:8f4e21ab  False      True   Applied revision: main@sha1:8f4e21ab

$ kubectl -n podinfo-prod get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   6/6     6            6           12m
```

The `REVISION` column is the correlation ID from Principle 2: every cluster in the fleet reports exactly which commit it embodies.

### 5.3 A change flows through the loop

```
$ git switch -c bump-podinfo-6.7.1
$ sed -i 's/6.7.0/6.7.1/' apps/podinfo/base/deployment.yaml
$ git commit -am "podinfo: bump image to 6.7.1"
$ git push origin bump-podinfo-6.7.1
# ... PR reviewed, approved, merged to main ...

$ flux reconcile kustomization podinfo-production --with-source
► annotating GitRepository fleet-repo in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:c91d3e07
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:c91d3e07
```

`flux reconcile` only *shortens the wait* — omitting it, the same convergence happens within `spec.interval`. The command is a trigger, never a deployment mechanism.

### 5.4 Drift injection and automatic reversion

```
$ kubectl -n podinfo-prod scale deploy podinfo --replicas=1
deployment.apps/podinfo scaled

$ sleep 600 && kubectl -n podinfo-prod get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   6/6     6            6           43m
```

The manual scale survived less than one reconciliation interval. Argo CD shows the same event explicitly:

```
$ argocd app get podinfo-production
Name:               argocd/podinfo-production
Sync Status:        Synced to main (c91d3e0)
Health Status:      Healthy

GROUP  KIND        NAMESPACE     NAME     STATUS  HEALTH   MESSAGE
       Service     podinfo-prod  podinfo  Synced  Healthy  service/podinfo unchanged
apps   Deployment  podinfo-prod  podinfo  Synced  Healthy  deployment.apps/podinfo configured
```

### 5.5 Rollback as a revert

```
$ git revert --no-edit c91d3e07
[main 4b7a9f12] Revert "podinfo: bump image to 6.7.1"
$ git push origin main
$ flux reconcile kustomization podinfo-production --with-source
✔ applied revision main@sha1:4b7a9f12
```

No special rollback machinery exists or is needed: rollback is a forward motion of the state store to a content-identical previous state.

---

## 6. Verification & Failure Diagnosis Guide

### 6.1 Structured triage order

Diagnose along the pipeline direction — **source → build → apply → health** — because each stage's failure poisons the next:

```
$ flux get sources git          # 1. can the agent fetch the state store?
$ flux get kustomizations       # 2. did build+apply succeed, at which revision?
$ flux events --for Kustomization/podinfo-production   # 3. what exactly failed?
$ kubectl -n podinfo-prod get events --sort-by=.lastTimestamp   # 4. workload-level causes
```

### 6.2 Failure catalog

| Symptom (agent status) | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| `failed to checkout and determine revision` / `authentication required` | Deploy key rotated, token expired, repo made private | `flux get sources git` shows source not Ready | Recreate `secretRef` secret; never widen to write scope |
| `kustomization path not found` | `spec.path` typo or directory renamed in a commit | `flux events` names the missing path | Fix path in the Flux `Kustomization`; treat repo layout as API |
| `dry-run failed: ... field is immutable` | Change to an immutable field (e.g. Deployment `spec.selector`, Service `clusterIP`) | Error names the field | Delete/recreate the object intentionally, or use `spec.force: true` on the Flux Kustomization knowing it recreates resources |
| `OutOfSync` immediately after every sync (Argo CD) | Mutating webhook or controller rewrites fields; diff never settles | `argocd app diff` shows fields you never set | Add `ignoreDifferences` for the mutated paths, or normalize with server-side apply |
| Resources deleted from Git still running | `prune` disabled (Flux `prune: false` / Argo without `prune: true`) | Compare `kubectl get -n ns all` vs repo | Enable pruning; verify with a dry-run first |
| Reconcile hangs then `timeout waiting for ... to be ready` | `wait: true` + workload never healthy (bad image, failing probe, unschedulable) | `kubectl describe pod` → `ImagePullBackOff` / probe failures | Fix the workload in Git; the agent is correctly refusing to report success |
| CRD + CR in same apply fails once, then succeeds | Ordering: CR applied before CRD established | Transient `no matches for kind` in events | Acceptable (retry converges), or split CRDs into an earlier Kustomization with `dependsOn` |
| Drift keeps reappearing every interval | Two reconcilers (or an HPA) fighting over one field | `kubectl get deploy -o yaml \| grep -A2 managedFields` shows two managers | Remove the field from Git if the HPA owns it (`replicas`), or delete the duplicate Application/Kustomization |
| Everything Ready but old revision | Reconciliation suspended | `flux get kustomizations` → `SUSPENDED: True` | `flux resume kustomization <name>`; audit why it was suspended |

### 6.3 Verifying convergence independently

Never trust a single green status — verify desired-vs-live with the API server itself:

```
$ kubectl diff -k apps/podinfo/overlays/production
$ echo $?
0        # exit 0 = zero drift; exit 1 = diff printed; >1 = error
```

`kubectl diff` performs a server-side dry-run against live objects — it is the ground-truth drift check independent of any GitOps tool, and belongs in CI as a nightly fleet-drift report.

### 6.4 Emergency procedure (the exam-relevant runbook)

1. `flux suspend kustomization podinfo-production` — make the pause explicit and visible, instead of racing the reconciler.
2. Apply the imperative mitigation.
3. Commit the equivalent declarative change to the state store, via expedited review.
4. `flux resume kustomization podinfo-production` — the loop converges onto the now-correct declaration; the manual change is either confirmed or cleanly overwritten.

Skipping step 3 is the classic failure: the incident fix silently evaporates at the next reconciliation after resume.

---

## Referencias

- OpenGitOps — GitOps Principles v1.0.0 (CNCF): https://opengitops.dev/
- OpenGitOps principles source (GitHub): https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
- OpenGitOps glossary (desired state, state store, reconciliation): https://github.com/open-gitops/documents/blob/main/GLOSSARY.md
- CNCF CGOA curriculum: https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
- CGOA exam page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-gitops-associate-cgoa/
- Kubernetes — Declarative management of objects: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Server-Side Apply and field management: https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Flux documentation — Core concepts: https://fluxcd.io/flux/concepts/
- Flux — Kustomization API (prune, wait, force, dependsOn): https://fluxcd.io/flux/components/kustomize/kustomizations/
- Argo CD documentation — Automated sync, self-heal and pruning: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Argo CD — Diffing customization (`ignoreDifferences`): https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/