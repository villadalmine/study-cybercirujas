# Topic 1.1 — GitOps Fundamentals

**Exam:** CGOA · **Weight:** 25.0 · **Profile:** SRE / Platform Architect

---

## 1. Motivation: the production problem GitOps solves

### 1.1 The failure mode of imperative operations

Before GitOps, the dominant delivery pattern for Kubernetes was **CIOps**: a CI pipeline builds an artifact, then *pushes* changes into the cluster with imperative commands (`kubectl apply`, `helm upgrade`) as its final stage. This model breaks down in production along four independent axes:

1. **Configuration drift.** The cluster's *actual state* diverges from what anyone believes is deployed. A hotfix applied with `kubectl edit` at 03:00 during an incident survives silently until the next pipeline run overwrites it — or worse, doesn't, because the pipeline only applies the files it knows about. There is no process whose job is to notice the divergence.
2. **Credential sprawl.** Push-based CD requires the CI system to hold cluster-admin (or near-admin) credentials for every target cluster. Your CI platform — often a SaaS product outside your security boundary — becomes the highest-value attack target in the estate. Compromise of the pipeline is compromise of production.
3. **Unauditable change.** `kubectl` gives you no durable answer to "who changed this, when, and why?" Kubernetes audit logs record the API call, but not the intent, the review, or the rollback path. Compliance regimes (SOC 2, PCI-DSS change control) end up reconstructing change history from Slack messages.
4. **Slow, lossy disaster recovery.** If the cluster is the only place the full desired state exists, rebuilding a cluster means archaeology: exporting live objects (polluted with `status`, `managedFields`, defaulted values) and hoping nothing was hand-applied.

### 1.2 The architectural answer: closed-loop control

GitOps re-frames delivery as a **closed-loop control system**, the same model as the Kubernetes controllers it runs on:

```
             ┌──────────────────────────────────────────────┐
             │                                              │
  Human ──► PR ──► review ──► merge ──► State Store (Git)   │
             │                              │               │
             │                              ▼               │
             │                    ┌──────────────────┐      │
             │                    │ Reconciler agent │◄─────┼── observes actual state
             │                    │ (in-cluster)     │      │
             │                    └────────┬─────────┘      │
             │                             │ pull + apply   │
             │                             ▼                │
             │                    Kubernetes API server ────┘
             └──────────────────────────────────────────────┘
```

- The **desired state** lives in a versioned, immutable **state store** (in practice, Git).
- Software **agents** (reconcilers) *pull* the desired state and *continuously* compare it against the **actual state** of the system.
- Any divergence — whether caused by a new commit or by out-of-band mutation of the cluster — is **drift**, and the reconciler's job is to converge actual state back to desired state.

The critical mental shift for the exam: **a deployment is not an event triggered by a pipeline; it is the side effect of changing the desired state.** The verb is *merge*, not *push*.

### 1.3 What this buys you in production

| Property | Mechanism that provides it |
|---|---|
| Auditability | Every change is a commit: author, timestamp, diff, review trail |
| Rollback | `git revert` — the reconciler converges to the previous state |
| Disaster recovery | Point a fresh cluster's reconciler at the repo; state rebuilds itself |
| Security posture | Cluster credentials never leave the cluster; CI has zero cluster access |
| Drift elimination | Continuous reconciliation reverts out-of-band changes automatically |
| Multi-cluster consistency | N clusters reconcile from one source of truth |

---

## 2. The four OpenGitOps principles (v1.0.0)

The CNCF **OpenGitOps** project (a working group under the CNCF App Delivery TAG) defines GitOps in four principles. These are the normative definition the CGOA exam tests — memorize them *and* their operational consequences.

> **Principle 1 — Declarative.** *A system managed by GitOps must have its desired state expressed declaratively.*

You describe **what** the end state is (`replicas: 3`), never **how** to get there (`kubectl scale --replicas=3`). Declarative state is idempotent and convergent: applying it twice is safe, and the current state is irrelevant to the correctness of the desired state. Imperative scripts, by contrast, encode assumptions about the starting point and fail unpredictably when those assumptions break.

> **Principle 2 — Versioned and Immutable.** *Desired state is stored in a way that enforces immutability, versioning and retains a complete version history.*

Note carefully: the principle says **versioned and immutable storage**, not "Git." Git is the overwhelmingly common implementation (hence the name), but an OCI registry with immutable tags, or a versioned S3 bucket, satisfies the principle. Immutability means a given revision (a commit SHA, an image digest) always resolves to the same content — which is what makes rollback trivial and audit trustworthy.

> **Principle 3 — Pulled Automatically.** *Software agents automatically pull the desired state declarations from the source.*

The agent runs *inside* (or adjacent to) the managed system and fetches state on its own schedule. Nothing outside the trust boundary needs write access to the system. This inverts the CI/CD credential model: instead of CI holding cluster credentials, the cluster holds a *read-only* deploy key to the repo.

> **Principle 4 — Continuously Reconciled.** *Software agents continuously observe actual system state and attempt to apply the desired state.*

"Continuously" means the loop never terminates — it is not "apply on commit." The reconciler compares desired vs. actual on every interval (and on notification), so drift introduced at *any* time from *any* source gets corrected. This is the principle that distinguishes GitOps from "CD pipeline that happens to read YAML from Git."

### 2.1 Core terminology (exam vocabulary)

| Term | Definition |
|---|---|
| **Desired state** | The aggregate of all configuration data sufficient to recreate the system |
| **State store** | The versioned, immutable system holding desired state (Git, OCI registry) |
| **Actual state** | The observed, live state of the managed system |
| **State drift** | Any divergence between actual and desired state |
| **Reconciliation** | The continuous process of converging actual state toward desired state |
| **State reconciler / agent** | The software component performing reconciliation (Flux controllers, Argo CD application-controller) |
| **Drift detection** | Identifying that actual ≠ desired (a prerequisite of, but distinct from, remediation) |
| **Continuous deployment vs. GitOps** | CD automates *releasing*; GitOps additionally makes the release target a continuously enforced declared state |

---

## 3. Trade-off analysis

### 3.1 Push (CIOps) vs. Pull (GitOps)

| Dimension | Push (CI applies to cluster) | Pull (in-cluster reconciler) |
|---|---|---|
| Cluster credentials | Exported to CI system (attack surface) | Never leave the cluster; repo deploy key is read-only |
| Drift handling | None — drift persists until next pipeline run | Detected and remediated continuously |
| Network topology | CI must reach the API server (VPN/firewall holes into prod) | Cluster makes *outbound* HTTPS to Git — works behind NAT, air-gap-friendly with a mirrored store |
| Deployment trigger | Pipeline event (imperative moment in time) | State change + interval (convergent, retried forever) |
| Failure recovery | Re-run pipeline manually | Reconciler retries with backoff automatically |
| Fleet scaling | Pipeline complexity grows O(clusters) | Each cluster pulls independently; O(1) pipeline |
| Feedback latency | Immediate (pipeline log) | Interval-bound unless webhook/notification configured |
| Emergency "just ship it" | Trivially easy (which is the problem) | Requires a commit — friction is the feature |

### 3.2 Imperative vs. declarative management

| Dimension | Imperative (`kubectl create/edit/scale`) | Declarative (`apply` from manifests) |
|---|---|---|
| Idempotency | No — depends on current state | Yes — converges from any state |
| Reviewability | Command history only | Full diff in a PR |
| Reproducibility | Requires replaying history in order | Requires only the latest revision |
| Merge with other actors | Clobbers | Server-side apply field ownership resolves per-field |
| GitOps compatibility | Incompatible (Principle 1 violation) | Required |

### 3.3 Reconciler placement: in-cluster agent vs. external operator

| Dimension | Agent per cluster (Flux model, Argo CD per-cluster) | Central hub managing spokes (Argo CD hub-and-spoke) |
|---|---|---|
| Blast radius of reconciler compromise | One cluster | Entire fleet |
| Credential model | None crosses boundary | Hub stores kubeconfigs/tokens for every spoke |
| Single pane of glass | Requires aggregation layer | Native |
| Scales to N clusters | Linearly, independently | Hub becomes a throughput/HA bottleneck |
| Network requirement | Cluster → Git (outbound only) | Hub → every spoke API server (inbound to prod) |

Architect's rule of thumb: pull-per-cluster maximizes the security properties GitOps promises; hub-and-spoke trades some of them back for operability. Know that the *purest* reading of Principle 3 favors the in-cluster agent.

### 3.4 State store: Git vs. OCI artifacts

| Dimension | Git repository | OCI registry (e.g. Flux OCIRepository) |
|---|---|---|
| Human review workflow | Native (PRs) | Needs Git upstream anyway; registry holds *published* state |
| Immutability | Enforced by convention (protected branches, no force-push) | Enforced by digest addressing |
| Signing/verification | Commit signing (GPG/SSH), gated by policy | Cosign/Notation signatures, verified by the reconciler |
| Scale of consumers | Git servers throttle heavy polling fleets | Registries are built for massive pull fan-out |
| Air-gapped delivery | Repo mirroring | Artifact promotion between registries — very natural |

---

## 4. Complete manifests: a minimal GitOps-managed application

The desired state lives in a repository with this layout:

```
fleet-repo/
├── apps/
│   └── podinfo/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── kustomization.yaml
└── clusters/
    └── prod/
        ├── podinfo-source.yaml
        └── podinfo-kustomization.yaml
```

### 4.1 The application's desired state

`apps/podinfo/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  namespace: podinfo
  labels:
    app.kubernetes.io/name: podinfo
    app.kubernetes.io/managed-by: flux
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: podinfo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: podinfo
    spec:
      containers:
        - name: podinfo
          image: ghcr.io/stefanprodan/podinfo:6.7.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 9898
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```

`apps/podinfo/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: podinfo
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

`apps/podinfo/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: podinfo
resources:
  - deployment.yaml
  - service.yaml
```

### 4.2 The reconciler configuration — Flux flavor

`clusters/prod/podinfo-source.yaml` — *where* to pull desired state from (Principles 2 and 3):

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: fleet-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/example-org/fleet-repo
  ref:
    branch: main
  secretRef:
    name: fleet-repo-auth
```

`clusters/prod/podinfo-kustomization.yaml` — *what* to reconcile and *how* (Principle 4):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: fleet-repo
  path: ./apps/podinfo
  prune: true
  wait: true
  targetNamespace: podinfo
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: podinfo
      namespace: podinfo
```

Two fields carry the exam-relevant semantics:

- **`prune: true`** — resources removed from Git are *deleted* from the cluster (garbage collection). Without it, deletions in the state store never propagate, and the actual state accumulates orphans.
- **`interval`** — the reconciliation loop period. This is the upper bound on drift lifetime, independent of any commit activity.

### 4.3 The same intent — Argo CD flavor

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/example-org/fleet-repo
    targetRevision: main
    path: apps/podinfo
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Vocabulary mapping worth knowing cold: Argo CD's **`selfHeal: true`** is what makes reconciliation *continuous* against cluster-side drift (without it, Argo CD only syncs on Git changes — drift is detected and reported as `OutOfSync` but not remediated). **`prune: true`** is the same garbage-collection semantic as Flux's field of the same name.

---

## 5. Real CLI workflows and expected output

### 5.1 The change workflow is a Git workflow

```
$ git switch -c bump-podinfo-6.7.1
$ sed -i 's|podinfo:6.7.0|podinfo:6.7.1|' apps/podinfo/deployment.yaml
$ git add -p && git commit -m "apps/podinfo: bump to 6.7.1"
$ git push -u origin bump-podinfo-6.7.1
```

After review and merge, no further human action occurs. The reconciler picks up the new revision on its next interval.

### 5.2 Observing reconciliation (Flux)

```
$ flux get sources git
NAME        REVISION            SUSPENDED  READY  MESSAGE
fleet-repo  main@sha1:8f4e2c1a  False      True   stored artifact for revision 'main@sha1:8f4e2c1a'

$ flux get kustomizations
NAME     REVISION            SUSPENDED  READY  MESSAGE
podinfo  main@sha1:8f4e2c1a  False      True   Applied revision: main@sha1:8f4e2c1a
```

The load-bearing detail: `REVISION` reports the exact commit SHA applied. "What is running in prod?" has a one-command, commit-precise answer.

Force an immediate reconciliation instead of waiting for the interval:

```
$ flux reconcile kustomization podinfo --with-source
► annotating GitRepository fleet-repo in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:8f4e2c1a
► annotating Kustomization podinfo in flux-system namespace
✔ Kustomization annotated
◎ waiting for Kustomization reconciliation
✔ applied revision main@sha1:8f4e2c1a
```

### 5.3 Observing sync state (Argo CD)

```
$ argocd app get podinfo
Name:               argocd/podinfo
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          podinfo
URL:                https://argocd.example.com/applications/podinfo
Source:
- Repo:             https://github.com/example-org/fleet-repo
  Target:           main
  Path:             apps/podinfo
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (8f4e2c1)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME     STATUS  HEALTH   HOOK  MESSAGE
       Service     podinfo    podinfo  Synced  Healthy        service/podinfo unchanged
apps   Deployment  podinfo    podinfo  Synced  Healthy        deployment.apps/podinfo configured
```

Note the two orthogonal statuses — this distinction is examined:

- **Sync Status** (`Synced` / `OutOfSync`): does actual state match desired state?
- **Health Status** (`Healthy` / `Progressing` / `Degraded` / `Missing`): is the workload actually functioning?

An application can be `Synced` and `Degraded` simultaneously: the manifests applied cleanly, but the pods are crash-looping. GitOps guarantees convergence of *configuration*, not correctness of the *software*.

### 5.4 Witnessing drift remediation

Simulate an out-of-band change:

```
$ kubectl -n podinfo scale deployment/podinfo --replicas=10
deployment.apps/podinfo scaled

$ kubectl -n podinfo get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   10/10   10           10          14d
```

Within one reconciliation interval (or immediately with `selfHeal`):

```
$ kubectl -n podinfo get deploy podinfo
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
podinfo   3/3     3            3           14d

$ kubectl -n flux-system get events --field-selector reason=ReconciliationSucceeded | tail -1
2m    Normal   ReconciliationSucceeded   kustomization/podinfo   Reconciliation finished in 341ms, next run in 10m
```

The imperative change was reverted by the control loop. This demonstration — drift injected, drift erased, no human involved — *is* Principle 4.

### 5.5 Rollback is `git revert`

```
$ git revert --no-edit 8f4e2c1
[main 3b9d0aa] Revert "apps/podinfo: bump to 6.7.1"
$ git push origin main
```

No `rollout undo`, no redeploy pipeline. The desired state moved backwards; the reconciler converges to it exactly as it would to any other revision. Because the revert is itself a commit, the audit trail records the rollback as a first-class change.

---

## 6. Verification and failure diagnosis

### 6.1 Systematic diagnosis order

Reconciliation is a chain: **source fetch → build/render → apply → health**. Diagnose in that order; a failure earlier in the chain manifests as staleness later.

```
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.2 >=1.28.0-0
► checking controllers
✔ source-controller: deployment ready
✔ kustomize-controller: deployment ready
✔ helm-controller: deployment ready
✔ notification-controller: deployment ready
✔ all checks passed

$ flux get all -A --status-selector ready=false
NAME  REVISION  SUSPENDED  READY  MESSAGE
```

An empty second listing is the fleet-wide green light: nothing is failing to reconcile.

### 6.2 Failure-mode table

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| Source `READY=False`, `authentication required` | Expired/rotated deploy key or token | `kubectl -n flux-system describe gitrepository fleet-repo` | Rotate the secret in `secretRef`; keys are read-only, so rotation is low-risk |
| Revision advances but cluster unchanged | Kustomization/Application suspended, or wrong `path` | `flux get kustomizations` (`SUSPENDED=True`), `argocd app get` | `flux resume kustomization <name>`; fix `spec.path` |
| `OutOfSync` immediately after every sync | A mutating webhook or another controller rewrites fields the reconciler owns | `kubectl diff`, Argo CD "diff" view showing perpetual delta | Ignore-differences / drift-exclusion config for the contested fields; find the competing owner via `managedFields` |
| Apply fails: `dry-run failed: ... CRD not found` | Ordering — CR applied before its CRD | Kustomization events | Split CRDs into their own earlier Kustomization; use `dependsOn` (Flux) or sync waves (Argo CD) |
| `Synced` but `Degraded` | Config converged; workload broken (bad image, failing probes) | `kubectl -n podinfo describe pod`, container logs | Fix forward or `git revert` — never `kubectl edit`, which the loop will erase |
| Deleted from Git, still in cluster | `prune` disabled | `spec.prune` on the Kustomization/Application | Enable prune; understand blast radius first |
| Reconciler `Progressing` forever | `wait: true` with a health check that can never pass | `kubectl -n flux-system logs deploy/kustomize-controller` | Fix the workload or the health check; raise `timeout` only if genuinely slow |
| Changes land minutes late | Interval-only polling, no push notification | Compare commit time vs. `lastHandledReconcileAt` | Add webhook receiver (Flux notification-controller / Argo CD webhook) — interval becomes the fallback, not the path |

### 6.3 Drift detection without a reconciler (first principles)

`kubectl diff` is the primitive underneath every GitOps tool's drift detection — exit code `1` means drift exists:

```
$ kustomize build apps/podinfo | kubectl diff -f -
diff -u /tmp/LIVE-1932/apps.v1.Deployment.podinfo.podinfo /tmp/MERGED-2811/apps.v1.Deployment.podinfo.podinfo
--- /tmp/LIVE-1932/apps.v1.Deployment.podinfo.podinfo
+++ /tmp/MERGED-2811/apps.v1.Deployment.podinfo.podinfo
@@ -14,7 +14,7 @@
-  replicas: 10
+  replicas: 3
$ echo $?
1
```

### 6.4 The verification ladder for a GitOps claim

To assert "prod runs revision X" with evidence rather than faith:

1. `git log -1 --format=%H` on `main` — what the state store says.
2. `flux get kustomizations` / `argocd app get` — what the reconciler last applied.
3. `kubectl get deploy podinfo -o jsonpath='{.spec.template.spec.containers[0].image}'` — what the API server holds.
4. `kubectl get pods -o jsonpath='{.items[*].status.containerStatuses[*].imageID}'` — the digest actually running on nodes.

All four agree, or you have found either drift (2≠3), a stalled reconciler (1≠2), or a rollout in flight (3≠4). Each inequality localizes the fault to one link of the chain — that decomposition is the practical skill this domain examines.

---

## Referencias

- OpenGitOps — principles v1.0.0 and glossary: https://opengitops.dev/
- OpenGitOps normative documents (CNCF GitOps Working Group): https://github.com/open-gitops/documents
- CNCF CGOA curriculum: https://github.com/cncf/curriculum
- CGOA exam page (CNCF/Linux Foundation): https://www.cncf.io/training/certification/cgoa/
- Kubernetes — Declarative management of objects: https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes — Controllers and the reconciliation model: https://kubernetes.io/docs/concepts/architecture/controller/
- Flux — Core concepts: https://fluxcd.io/flux/concepts/
- Flux — Kustomization API: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Argo CD — Declarative setup: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- Argo CD — Automated sync and self-heal: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/