# Argo CD — Guided Exercises (CAPA 3.1)

> **Prerequisites:** A running Kubernetes cluster (kind, minikube, or k3d is fine), `kubectl` configured against it, and the `argocd` CLI installed (`brew install argocd` / [download from releases](https://github.com/argoproj/argo-cd/releases)). Every command below is meant to be typed and observed — read the expected output, don't just copy-paste. Technical terms are kept in English on purpose; they are the terms the exam and the API use.
>
> **Sources:** CNCF CAPA curriculum ([cncf/curriculum `capa/README.md`](https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md)) · Argo CD docs ([argo-cd.readthedocs.io/en/stable](https://argo-cd.readthedocs.io/en/stable/)).

---

## Exercise 1 — Install Argo CD and reach the API/UI

**Goal:** Bootstrap Argo CD in-cluster and understand what components you just deployed.

1. Create the namespace Argo CD expects and install the non-HA manifest:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Watch the workloads come up. Do **not** move on until every pod is `Running`/`1/1`:

   ```bash
   kubectl -n argocd get pods
   ```

   Expected (names/hashes vary):

   ```
   NAME                                                READY   STATUS    RESTARTS   AGE
   argocd-application-controller-0                     1/1     Running   0          90s
   argocd-applicationset-controller-6c8b7d9f5-abcde    1/1     Running   0          90s
   argocd-dex-server-7f9c6c8b7d-fghij                  1/1     Running   0          90s
   argocd-notifications-controller-5d6b7c8f9-klmno     1/1     Running   0          90s
   argocd-redis-6b8f7c9d5-pqrst                        1/1     Running   0          90s
   argocd-repo-server-7c9d8f6b5-uvwxy                  1/1     Running   0          90s
   argocd-server-6f8c7d9b5-z1234                       1/1     Running   0          90s
   ```

3. The initial admin password is stored in a secret. Read it (never commit it):

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath="{.data.password}" | base64 -d ; echo
   ```

4. Port-forward the API server and log in with the CLI. The server serves gRPC and HTTP on the same port, so `--insecure` skips the self-signed cert check for this lab:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:443 &
   argocd login localhost:8080 --username admin \
     --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)" \
     --insecure
   ```

   Expected:

   ```
   'admin:login' logged in successfully
   Context 'localhost:8080' updated
   ```

**Comprehension checkpoint**

- **Q1.1** — You installed several deployments plus one StatefulSet. Which component is the StatefulSet, and *why* is it a StatefulSet rather than a Deployment?
- **Q1.2** — Name the job of each of these three: `argocd-repo-server`, `argocd-application-controller`, `argocd-server`.
- **Q1.3** — The password lives in `argocd-initial-admin-secret`. What is the recommended action after first login, and what happens to that secret?

---

## Exercise 2 — Your first Application: imperative vs. declarative

**Goal:** Create the same Application two ways and understand that Argo CD is fundamentally *declarative* — the CLI is a convenience over a CRD.

1. Create an Application imperatively pointing at the canonical example repo:

   ```bash
   argocd app create guestbook \
     --repo https://github.com/argoproj/argocd-example-apps.git \
     --path guestbook \
     --dest-server https://kubernetes.default.svc \
     --dest-namespace default
   ```

2. Inspect what Argo CD now knows. Note the `Sync Status` and `Health Status`:

   ```bash
   argocd app get guestbook
   ```

   Expected (abridged):

   ```
   Name:               argocd/guestbook
   Project:            default
   Server:             https://kubernetes.default.svc
   Namespace:          default
   Repo:               https://github.com/argoproj/argocd-example-apps.git
   Target:
   Path:               guestbook
   SyncWindow:         Sync Allowed
   Sync Policy:        Manual
   Sync Status:        OutOfSync from  (53e28ff)
   Health Status:      Missing

   GROUP  KIND        NAMESPACE  NAME          STATUS     HEALTH   HOOK  MESSAGE
          Service     default    guestbook-ui  OutOfSync  Missing
   apps   Deployment  default    guestbook-ui  OutOfSync  Missing
   ```

3. The Application is registered but nothing is deployed yet — `Manual` sync policy means Argo CD will not act on its own. Trigger a sync:

   ```bash
   argocd app sync guestbook
   ```

4. Now delete the imperative app and re-create it declaratively so you can see the actual object. Save this as `guestbook-app.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: default
     syncPolicy:
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   argocd app delete guestbook --yes
   kubectl apply -f guestbook-app.yaml
   ```

**Comprehension checkpoint**

- **Q2.1** — `argocd app create ...` and applying the `Application` YAML produce the same result. Which representation is the source of truth, and where does the object physically live?
- **Q2.2** — In the manifest, `targetRevision: HEAD` is used. Why is `HEAD` (or a mutable branch like `main`) a risky choice for a production Application, and what would you pin instead?
- **Q2.3** — What is the `resources-finalizer.argocd.argoproj.io` finalizer for? What behavioral difference do you see when you `kubectl delete` the Application *with* it vs. *without* it?

---

## Exercise 3 — Automated sync: `prune`, `selfHeal`, and drift

**Goal:** Turn on GitOps' core promise — continuous reconciliation — and provoke drift to watch it get corrected.

1. Patch the Application to enable automated sync with pruning and self-heal:

   ```bash
   kubectl -n argocd patch application guestbook --type merge -p '
   spec:
     syncPolicy:
       automated:
         prune: true
         selfHeal: true'
   ```

2. Confirm it reconciled to `Synced` / `Healthy`:

   ```bash
   argocd app get guestbook --refresh
   ```

3. **Provoke drift.** Manually scale the live Deployment away from Git's desired state:

   ```bash
   kubectl -n default scale deployment guestbook-ui --replicas=5
   kubectl -n default get deployment guestbook-ui
   ```

4. Wait a few seconds (default reconciliation is ~180s, but `selfHeal` reacts to the cluster event too), then re-check. The controller should have reverted the replica count back to what Git says:

   ```bash
   argocd app get guestbook --refresh
   kubectl -n default get deployment guestbook-ui
   ```

5. **Provoke a prune scenario.** Manually create an orphaned resource *inside* the app's tracked namespace that Git does not declare, then observe that Argo CD does **not** delete resources it does not own:

   ```bash
   kubectl -n default create configmap not-in-git --from-literal=x=1
   argocd app get guestbook --refresh   # still Synced; the ConfigMap is untracked, not pruned
   ```

**Comprehension checkpoint**

- **Q3.1** — Distinguish `prune: true` from `selfHeal: true`. Give one concrete change each one — and only that one — is responsible for reverting.
- **Q3.2** — In step 5, the stray ConfigMap was not deleted despite `prune: true`. Why? What determines whether a resource is a *prune* candidate?
- **Q3.3** — With `selfHeal: false` (the default even when `automated` is set), what happens when someone `kubectl edit`s a live resource? What is the app's Sync Status, and does Argo CD change anything?
- **Q3.4** — Why is enabling automated `prune` without a review gate considered dangerous? Name the sync option that adds a safety net against pruning the *last* replica of a resource type.

---

## Exercise 4 — Ordering with sync waves and resource hooks

**Goal:** Control *ordering* within a sync — the difference between "apply everything at once" and "run the migration Job, wait, then roll the app."

1. Understand the two ordering mechanisms:
   - **Sync phases** (via `argocd.argoproj.io/hook`): `PreSync` → `Sync` → `PostSync`, plus `SyncFail`.
   - **Sync waves** (via `argocd.argoproj.io/sync-wave`, an integer, default `0`): ordering *within* a phase, lowest first, negatives allowed.

2. Create a manifest that runs a database-migration Job as a `PreSync` hook, then deploys the app. Save as `ordered.yaml` and add it to a test path/repo of your own (or apply directly to explore the annotations):

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: db-migrate
     annotations:
       argocd.argoproj.io/hook: PreSync
       argocd.argoproj.io/hook-delete-policy: HookSucceeded
   spec:
     backoffLimit: 2
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: migrate
             image: migrate/migrate:v4.17.1
             args: ["-help"]
   ---
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: app-config
     annotations:
       argocd.argoproj.io/sync-wave: "0"
   data:
     ready: "true"
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     annotations:
       argocd.argoproj.io/sync-wave: "1"
   spec:
     replicas: 1
     selector: { matchLabels: { app: web } }
     template:
       metadata: { labels: { app: web } }
       spec:
         containers:
           - name: web
             image: nginx:1.27-alpine
   ```

3. Sync and watch the ordering play out live:

   ```bash
   argocd app sync <your-app> --prune
   argocd app get <your-app> --refresh
   ```

   Expected ordering in the resource tree: the `db-migrate` **PreSync** hook runs and completes first, then within the Sync phase `app-config` (wave 0) is applied before `web` (wave 1). The hook Job is deleted once it succeeds.

**Comprehension checkpoint**

- **Q4.1** — A `PreSync` hook (wave 5) and a `Sync` resource (wave -10) are in the same sync. Which is applied first, and why? (State the precedence rule between phases and waves.)
- **Q4.2** — What does Argo CD wait for between waves before proceeding to the next one?
- **Q4.3** — Contrast the `hook-delete-policy` values `HookSucceeded`, `HookFailed`, and `BeforeHookCreation`. Which one keeps a failed migration Job around for you to inspect?
- **Q4.4** — When would you use a `SyncFail` hook, and does it run on a *healthy* sync?

---

## Exercise 5 — Managing many apps: App-of-Apps and ApplicationSet

**Goal:** Scale from one Application to fleets without hand-writing an `Application` per environment/cluster.

1. **App-of-Apps.** Create a parent Application whose Git path contains *child* `Application` manifests. Argo CD syncs the parent, which creates the children, which sync their own workloads. Sketch of the parent:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: bootstrap
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/gitops.git
       targetRevision: HEAD
       path: apps            # this directory holds child Application YAMLs
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd     # children are Applications; they live in argocd
     syncPolicy:
       automated: { prune: true, selfHeal: true }
   ```

2. **ApplicationSet.** Replace hand-maintained children with a generator. This `list` generator templates one Application per element:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: guestbook-fleet
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - list:
           elements:
             - cluster: dev
               url: https://kubernetes.default.svc
             - cluster: staging
               url: https://kubernetes.default.svc
     template:
       metadata:
         name: '{{.cluster}}-guestbook'
       spec:
         project: default
         source:
           repoURL: https://github.com/argoproj/argocd-example-apps.git
           targetRevision: HEAD
           path: guestbook
         destination:
           server: '{{.url}}'
           namespace: '{{.cluster}}-guestbook'
         syncPolicy:
           syncOptions: ["CreateNamespace=true"]
           automated: { prune: true, selfHeal: true }
   ```

3. Apply it and confirm the generated Applications appear:

   ```bash
   kubectl apply -f applicationset.yaml
   kubectl -n argocd get applications
   ```

   Expected:

   ```
   NAME               SYNC STATUS   HEALTH STATUS
   dev-guestbook      Synced        Healthy
   staging-guestbook  Synced        Healthy
   ```

**Comprehension checkpoint**

- **Q5.1** — Both patterns manage many apps. What is the fundamental difference in *how* the child Applications come to exist (who authors them)?
- **Q5.2** — Name three ApplicationSet generators besides `list`, and give a one-line use case for each.
- **Q5.3** — You delete one `element` from the ApplicationSet's `list`. What happens to that generated Application and its workloads by default? Which field controls whether the removed Application is actually deleted?
- **Q5.4** — Why is the `git` generator often paired with the "directory" or "files" mode to onboard a new microservice with a single PR?

---

## Exercise 6 — Diffing, health, and troubleshooting `OutOfSync`

**Goal:** Read Argo CD's diff and health model the way you would during an incident.

1. Introduce a *legitimate but external* change and see the diff Argo CD computes between desired (Git) and live (cluster):

   ```bash
   kubectl -n default set image deployment/guestbook-ui guestbook-ui=gcr.io/heptio-images/ks-guestbook-demo:0.1
   argocd app diff guestbook
   ```

   Expected (unified diff, live vs. desired):

   ```
   ===== apps/Deployment default/guestbook-ui ======
   ...
   -         image: gcr.io/heptio-images/ks-guestbook-demo:0.1
   +         image: gcr.io/heptio-images/ks-guestbook-demo:0.2
   ```

2. Inspect health for a resource whose health is non-trivial (a Deployment is `Healthy` only when its rollout completes):

   ```bash
   argocd app get guestbook -o wide
   ```

3. **Suppress benign diffs.** A common production nuisance: a mutating admission controller or the API server injects fields (e.g. `replicas` managed by an HPA). Add `ignoreDifferences` so those do not cause a permanent `OutOfSync`:

   ```yaml
   spec:
     ignoreDifferences:
       - group: apps
         kind: Deployment
         jsonPointers:
           - /spec/replicas
   ```

4. Force a fresh comparison bypassing the repo cache when you suspect stale state:

   ```bash
   argocd app get guestbook --hard-refresh
   ```

**Comprehension checkpoint**

- **Q6.1** — Argo CD reports `Sync Status` and `Health Status` as two independent axes. Give a real combination where an app is `Synced` but `Degraded`, and one where it is `OutOfSync` but `Healthy`.
- **Q6.2** — What is the difference between `--refresh` and `--hard-refresh`? Which cache does each invalidate?
- **Q6.3** — You add `ignoreDifferences` for `/spec/replicas`. What is the trade-off — what drift are you now *blind* to?
- **Q6.4** — For a `CustomResource` Argo CD does not understand, health shows as `Unknown`/`Progressing` forever. What mechanism lets you teach Argo CD how to assess that CR's health?

---

## Exercise 7 — Multi-tenancy: AppProjects, RBAC, and sync windows

**Goal:** Enforce guardrails so a team can self-serve without deploying cluster-admin YAML to `kube-system`.

1. Create an `AppProject` that constrains *where* and *what* a team may deploy:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AppProject
   metadata:
     name: team-a
     namespace: argocd
   spec:
     description: Team A tenant
     sourceRepos:
       - 'https://github.com/your-org/team-a-*'
     destinations:
       - server: https://kubernetes.default.svc
         namespace: 'team-a-*'
     clusterResourceWhitelist:
       - group: ''
         kind: Namespace
     namespaceResourceBlacklist:
       - group: ''
         kind: ResourceQuota
     roles:
       - name: deployer
         description: Sync rights within team-a
         policies:
           - p, proj:team-a:deployer, applications, sync, team-a/*, allow
           - p, proj:team-a:deployer, applications, get, team-a/*, allow
     syncWindows:
       - kind: deny
         schedule: '0 22 * * *'
         duration: 8h
         applications:
           - '*'
         manualSync: false
   ```

2. Apply it, then try to create an Application in this project that violates a constraint (e.g. a repo outside `team-a-*` or a destination namespace outside `team-a-*`):

   ```bash
   kubectl apply -f team-a-project.yaml
   argocd app create rogue \
     --project team-a \
     --repo https://github.com/other-org/app.git \
     --path . --dest-server https://kubernetes.default.svc --dest-namespace kube-system
   ```

   Expected — the request is rejected:

   ```
   FATA[0000] rpc error: code = InvalidArgument desc = application repo https://github.com/other-org/app.git is not permitted in project 'team-a'
   ```

3. Inspect the deny sync window: during the nightly 8-hour window, automated syncs are blocked:

   ```bash
   argocd app get <app-in-team-a>    # look for the SyncWindow line
   ```

**Comprehension checkpoint**

- **Q7.1** — Distinguish `clusterResourceWhitelist` from `namespaceResourceBlacklist`. Why does Argo CD default to an empty cluster-resource whitelist (i.e. no cluster-scoped resources allowed unless listed)?
- **Q7.2** — RBAC policy lines are `p, <subject>, <resource>, <action>, <object>, <effect>`. Decode `p, proj:team-a:deployer, applications, sync, team-a/*, allow`. What does the `team-a/*` object glob match?
- **Q7.3** — A `deny` sync window with `manualSync: false` is active. Can an operator still sync by hand? What changes if `manualSync: true`?
- **Q7.4** — What is the security purpose of the `default` AppProject, and why is tightening or replacing it an early hardening step?

---

## Exercise 8 — Rollback and history

**Goal:** Treat a bad deploy as a first-class, reversible event.

1. List the deployment history Argo CD retains per Application:

   ```bash
   argocd app history guestbook
   ```

   Expected:

   ```
   ID  DATE                           REVISION
   0   2026-08-12 09:14:02 +0000 UTC  (53e28ff)
   1   2026-08-12 10:02:41 +0000 UTC  (a1b2c3d)
   2   2026-08-12 11:30:18 +0000 UTC  (f4e5d6c)
   ```

2. Roll back to a previous known-good revision by its history ID:

   ```bash
   argocd app rollback guestbook 1
   ```

3. Observe: rollback pins the Application to that revision and — importantly — **disables automated sync** to prevent the controller from immediately re-applying `HEAD` on top of your rollback.

**Comprehension checkpoint**

- **Q8.1** — Why must `argocd app rollback` pause automated sync? What would happen if it did not?
- **Q8.2** — Rollback restores the *manifests* from an old Git revision. What state does it **not** restore, and why is "GitOps rollback ≠ database rollback" an important caveat?
- **Q8.3** — Where does the history come from — the Git provider, or Argo CD's own record? What is the implication if you `argocd app delete` and recreate the Application?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**

- **A1.1** — `argocd-application-controller` is the StatefulSet. It is stateful because it owns the reconciliation loop and shards Applications across controller replicas by a stable identity; a stable pod ordinal/identity lets sharding be deterministic. (Redis is a Deployment because it is a disposable cache — Argo CD rebuilds its state from the cluster and Git, so losing Redis is not data loss.)
- **A1.2** — `argocd-repo-server` clones Git repos and *renders* manifests (runs Helm/Kustomize/plugins) into plain YAML. `argocd-application-controller` compares that rendered desired state against live cluster state and performs syncs / reports health. `argocd-server` is the API/gRPC + web UI front end (auth, RBAC enforcement, serving the CLI and UI) — it does **not** do the reconciliation itself.
- **A1.3** — Change the admin password (`argocd account update-password`) and then delete `argocd-initial-admin-secret`. It is a bootstrap convenience only; it is safe to delete once you have logged in and rotated, and best practice is to disable the local `admin` account entirely in favor of SSO/Dex.

**Exercise 2**

- **A2.1** — The `Application` custom resource is the source of truth; the CLI just creates/patches that CR via the API. The object physically lives as a CRD instance in the `argocd` namespace of the cluster (`kubectl -n argocd get applications`).
- **A2.2** — `HEAD`/`main` is *mutable* — any push silently changes the desired state, so what deploys is not reproducible and a bad commit auto-propagates. Pin a specific Git commit SHA (or an immutable tag) for production so the deployed state is deterministic and auditable.
- **A2.3** — The finalizer triggers **cascading deletion**: deleting the Application first prunes all the resources it manages, then removes the Application. Without the finalizer, deleting the Application leaves the deployed workloads orphaned/running in the cluster (a "non-cascading" delete).

**Exercise 3**

- **A3.1** — `selfHeal: true` reverts changes made *directly on live resources* that drift from Git (e.g. someone scaled replicas or edited an image in the cluster). `prune: true` deletes resources that were *removed from Git* but still exist in the cluster. selfHeal fixes edits; prune removes deletions.
- **A3.2** — Pruning only applies to resources Argo CD **tracks** (those it previously applied and labeled/annotated as belonging to the app, e.g. via the tracking label/annotation). The stray ConfigMap was created out-of-band, is not in the app's managed set, so it is treated as untracked, not as a prune candidate.
- **A3.3** — With `selfHeal: false`, a manual `kubectl edit` makes the app go `OutOfSync`, and Argo CD **reports** the drift but does **not** correct it — reconciliation only re-applies from Git on an explicit/auto sync trigger, not on live drift. The workload keeps the edited value until the next sync.
- **A3.4** — Auto-prune can cascade an accidental deletion in Git into deleting live resources across the fleet with no human gate. The `PruneLast=true` sync option defers pruning to the end of the sync; `PrunePropagationPolicy` controls deletion propagation; and the controller refuses to prune to zero when the "prune requires confirmation" behavior / `allowEmpty` guard is not satisfied (an ApplicationSet's `preserveResourcesOnDeletion` / `allowEmpty` protect against wiping everything).

**Exercise 4**

- **A4.1** — The **PreSync** resource is applied first. Phases have absolute precedence over waves: all of PreSync runs (in wave order among PreSync resources) before *any* Sync resource, regardless of the Sync resource having a lower/negative wave number. Waves only order resources *within the same phase*.
- **A4.2** — Argo CD waits for all resources in the current wave to become **Healthy** (and hooks in that wave to complete) before starting the next wave.
- **A4.3** — `HookSucceeded` deletes the hook object after it succeeds; `HookFailed` deletes it after it fails; `BeforeHookCreation` deletes the *previous* instance of the hook right before creating the new one (so exactly one lingers between runs). To keep a failed migration Job for post-mortem, use `HookSucceeded` **only** (or no delete policy) so a failure is *not* auto-deleted.
- **A4.4** — A `SyncFail` hook runs only when the sync operation fails (e.g. to send an alert, roll back a migration, or clean up partial state). It does **not** run on a successful/healthy sync.

**Exercise 5**

- **A5.1** — In App-of-Apps, a human authors and commits each child `Application` manifest to Git; the parent just applies them. In ApplicationSet, the children are *generated* programmatically by the ApplicationSet controller from a generator + template — you maintain the generator inputs, not one file per app.
- **A5.2** — `cluster` (fan an app out across all/selected registered clusters — multi-cluster rollout); `git` (one app per directory or per config file discovered in a repo — self-service onboarding via PR); `matrix`/`merge` (combine two generators, e.g. every app × every cluster); `pullRequest` (spin up a preview/ephemeral env per open PR); `scmProvider` (one app per repo in a GitHub/GitLab org).
- **A5.3** — By default the generated Application is deleted, and because generated Applications carry cascading deletion, its workloads are removed too. `preserveResourcesOnDeletion: true` (and/or the ApplicationSet's finalizer settings) controls whether the underlying resources are actually cleaned up vs. left running.
- **A5.4** — With a `git` (directory/files) generator, adding a new microservice is just committing a new directory or values file to the watched repo; the controller discovers it and generates the Application automatically — no change to Argo CD config, so onboarding is a single PR.

**Exercise 6**

- **A6.1** — `Synced` + `Degraded`: Git and cluster match exactly, but the Deployment's pods are CrashLooping (bad image) — desired state is applied, the workload is just unhealthy. `OutOfSync` + `Healthy`: someone pushed a new image tag to Git (desired changed) but the running old version is perfectly healthy; the app is healthy yet no longer matches Git.
- **A6.2** — `--refresh` re-compares against the *cached* rendered manifests / last Git fetch (a normal reconciliation). `--hard-refresh` additionally invalidates the repo-server's manifest cache and re-renders from Git, used when you suspect a stale Helm/Kustomize render or cached repo state.
- **A6.3** — You are now blind to *any* replica change, including a legitimate accidental change committed to Git or an unexpected external scaling — Argo CD will never flag `/spec/replicas` drift again, so you rely entirely on the HPA/whatever manages it being correct.
- **A6.4** — A **custom health check** written in Lua, configured in the `argocd-cm` ConfigMap (`resource.customizations.health.<group_kind>`), teaches Argo CD how to map that CR's status into `Healthy`/`Progressing`/`Degraded`.

**Exercise 7**

- **A7.1** — `clusterResourceWhitelist` is an allow-list for *cluster-scoped* kinds (e.g. `Namespace`, `ClusterRole`); nothing cluster-scoped may be created unless explicitly listed. `namespaceResourceBlacklist` is a deny-list for *namespaced* kinds. The empty cluster whitelist default is a security posture: cluster-scoped resources are high-blast-radius, so a tenant project must be explicitly granted each one rather than getting them by default.
- **A7.2** — Subject `proj:team-a:deployer` (the project role) is allowed the `sync` action on the `applications` resource for objects matching `team-a/*`. The object glob is `<project>/<application-name>`, so `team-a/*` = any Application in the `team-a` project.
- **A7.3** — With `manualSync: false`, an active `deny` window blocks manual syncs too — nobody can sync until the window closes. With `manualSync: true`, automated syncs are still blocked during the window but an operator may override and sync by hand (useful for emergency fixes during a change freeze).
- **A7.4** — Every Application without an explicit project falls into `default`, which ships wide open (any repo, any destination, any resource). Leaving it permissive means a mistaken or malicious Application can deploy anything anywhere, so hardening or removing `default` and forcing every app into a scoped project is a first hardening step.

**Exercise 8**

- **A8.1** — Because with automated sync still on, the controller would immediately detect that the live state (the rolled-back revision) is `OutOfSync` with Git's `HEAD` and re-apply `HEAD` — undoing your rollback within one reconcile loop. Pausing auto-sync lets the rollback hold until you fix Git.
- **A8.2** — It restores only the *declarative manifests* (the Kubernetes objects). It does **not** restore data mutated by the running app — database schema/rows, PVC contents, external state. A migration that ran under the bad release is not reversed by rolling manifests back, which is why a GitOps rollback must be paired with an explicit data/migration rollback plan.
- **A8.3** — The history is Argo CD's own per-Application deployment record (revisions it actually synced), stored in the Application's status, not the Git log. If you `argocd app delete` and recreate the Application, that history is lost — the new object starts a fresh history even though the Git repo is unchanged.

</details>