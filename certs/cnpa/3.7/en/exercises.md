# Guided Exercises — Topic 3.7: GitOps for Multi-Environment Application Management

> **Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
> **Exam weight:** 2.25
> **Estimated time:** 90–120 min · **Level:** Advanced / production-oriented

These exercises take you from an empty cluster to a fully reconciled, multi-environment (`dev` → `staging` → `prod`) GitOps topology, first with **Argo CD** and then with **Flux**. You will build the repository layout that platform teams actually ship, observe the reconciliation loop, force drift and watch it self-heal, scale environments with generators, and promote a release across environments *through Git only* — never with `kubectl apply`.

---

## Prerequisites and lab bootstrap

You need a throwaway Kubernetes cluster and the two GitOps CLIs. Everything below is idempotent — re-running is safe.

**Steps**

1. Create a local cluster and the tooling:

   ```bash
   kind create cluster --name gitops-lab --image kindest/node:v1.31.0
   kubectl config use-context kind-gitops-lab

   # Argo CD CLI + Flux CLI
   curl -sSL -o /usr/local/bin/argocd \
     https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   chmod +x /usr/local/bin/argocd
   curl -s https://fluxcd.io/install.sh | sudo bash
   ```

2. Fork the sample application repository into your own Git account (you need push access later for promotion). We refer to it throughout as `https://github.com/<you>/platform-apps`. It contains a single stateless app, `podinfo`, that exposes `/version` so you can see which image is running per environment.

   ```bash
   export GITOPS_REPO="https://github.com/<you>/platform-apps"
   git clone "$GITOPS_REPO" && cd platform-apps
   ```

3. Confirm the cluster is empty of workloads:

   ```bash
   kubectl get ns | grep -E 'web-(dev|staging|prod)' || echo "no env namespaces yet"
   ```
   Expected:
   ```
   no env namespaces yet
   ```

**Comprehension check**

- **Q0.1** The four OpenGitOps principles (opengitops.dev) are *Declarative*, *Versioned and Immutable*, *Pulled Automatically*, and *Continuously Reconciled*. For each of the last two, name the concrete component in Argo CD (or Flux) that implements it.
- **Q0.2** Why is `kubectl apply -f deployment.yaml` against this cluster considered an *anti-pattern* once GitOps is in place, even though it produces the same live object?

---

## Exercise 1 — Bootstrap Argo CD and read the reconciliation loop

**Goal:** install the control plane and understand *desired state → live state* convergence.

**Steps**

1. Install Argo CD into its own namespace:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f \
     https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-repo-server
   ```

2. Log in via the CLI (port-forward the API server in a second terminal first: `kubectl -n argocd port-forward svc/argocd-server 8080:443`):

   ```bash
   ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d)
   argocd login localhost:8080 --username admin --password "$ARGO_PWD" --insecure
   ```

3. Inspect the reconciliation components:

   ```bash
   kubectl -n argocd get deploy \
     -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
   ```
   Expected (abridged):
   ```
   NAME                        IMAGE
   argocd-application-controller  quay.io/argoproj/argocd:v2.x
   argocd-repo-server             quay.io/argoproj/argocd:v2.x
   argocd-server                  quay.io/argoproj/argocd:v2.x
   argocd-applicationset-controller quay.io/argoproj/argocd:v2.x
   ```
   *(The `application-controller` is a StatefulSet in current versions — adjust the command with `get statefulset` if it does not appear.)*

**Comprehension check**

- **Q1.1** Trace the path a commit takes to become a running Pod. Which controller polls Git, which one renders the manifests (e.g., runs `kustomize build`), and which one diffs against and writes to the cluster?
- **Q1.2** The default reconciliation interval is 3 minutes (`timeout.reconciliation`). A developer merges a fix and wants it live *now*. Name two GitOps-preserving ways to trigger reconciliation immediately, and one way that would *violate* GitOps.

---

## Exercise 2 — Structure the repo for multiple environments with Kustomize overlays

**Goal:** encode the *same* app for three environments as one immutable `base` plus three thin overlays. This is the layout the promotion exercise later depends on.

**Steps**

1. Create the base (environment-agnostic) manifests:

   ```bash
   mkdir -p apps/web/base apps/web/overlays/{dev,staging,prod}
   ```

   `apps/web/base/deployment.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 1
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: podinfo
             image: ghcr.io/stefanprodan/podinfo:6.6.0
             ports:
               - containerPort: 9898
             readinessProbe:
               httpGet: { path: /readyz, port: 9898 }
             resources:
               requests: { cpu: 50m, memory: 32Mi }
               limits:   { cpu: 200m, memory: 64Mi }
   ```

   `apps/web/base/service.yaml`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
       - port: 80
         targetPort: 9898
   ```

   `apps/web/base/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   ```

2. Create the `dev` overlay (1 replica, pinned image, isolating namespace and name prefix):

   `apps/web/overlays/dev/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-dev
   namePrefix: dev-
   resources:
     - ../../base
   images:
     - name: ghcr.io/stefanprodan/podinfo
       newTag: 6.6.0
   replicas:
     - name: web
       count: 1
   ```

3. Create the `staging` overlay (2 replicas, a resource bump patch):

   `apps/web/overlays/staging/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-staging
   namePrefix: staging-
   resources:
     - ../../base
   images:
     - name: ghcr.io/stefanprodan/podinfo
       newTag: 6.6.0
   replicas:
     - name: web
       count: 2
   patches:
     - target: { kind: Deployment, name: web }
       patch: |-
         - op: replace
           path: /spec/template/spec/containers/0/resources/limits/cpu
           value: 500m
   ```

4. Create the `prod` overlay (3 replicas, still on `6.6.0` — prod trails dev on purpose):

   `apps/web/overlays/prod/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: web-prod
   namePrefix: prod-
   resources:
     - ../../base
   images:
     - name: ghcr.io/stefanprodan/podinfo
       newTag: 6.6.0
   replicas:
     - name: web
       count: 3
   ```

5. Validate every overlay renders before committing (fail-fast, offline):

   ```bash
   for env in dev staging prod; do
     echo "== $env =="
     kubectl kustomize apps/web/overlays/$env | grep -E '^(kind|  name|      replicas)' | head
   done
   git add apps/ && git commit -m "web: base + dev/staging/prod overlays" && git push
   ```

**Comprehension check**

- **Q2.1** The `image:` tag lives in *three* overlay files, not in `base`. What breaks about promotion (dev→staging→prod) if you instead set the tag once in `base` and let all environments inherit it?
- **Q2.2** Overlays use `namePrefix` and a distinct `namespace`. Which one gives you *hard* isolation between environments on a shared cluster, and which is only cosmetic? What would you add to make the isolation enforceable?
- **Q2.3** Why run `kubectl kustomize` in CI *before* the commit rather than letting Argo CD surface the error after merge?

---

## Exercise 3 — Deploy the environments and force drift to observe self-heal

**Goal:** create one Argo CD `Application` per environment and prove *Continuously Reconciled* by breaking live state manually.

**Steps**

1. Create the three `Application` resources. Save as `bootstrap/web-dev.yaml` (repeat for `staging`, `prod`, changing `name`, `path`, and `namespace`):

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: web-dev
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<you>/platform-apps
       targetRevision: main
       path: apps/web/overlays/dev
     destination:
       server: https://kubernetes.default.svc
       namespace: web-dev
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

2. Register them and watch convergence:

   ```bash
   kubectl apply -f bootstrap/web-dev.yaml -f bootstrap/web-staging.yaml -f bootstrap/web-prod.yaml
   argocd app list -o wide
   ```
   Expected once synced:
   ```
   NAME          SYNC STATUS   HEALTH STATUS   REVISION
   web-dev       Synced        Healthy         main
   web-staging   Synced        Healthy         main
   web-prod      Synced        Healthy         main
   ```

3. Confirm replica counts materialized per overlay:

   ```bash
   kubectl get deploy -A -l app=web \
     -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas
   ```
   Expected:
   ```
   NS            NAME            REPLICAS
   web-dev       dev-web         1
   web-staging   staging-web     2
   web-prod      prod-web        3
   ```

4. **Force drift.** Imperatively scale prod, simulating a paniced 2 a.m. `kubectl`:

   ```bash
   kubectl -n web-prod scale deployment/prod-web --replicas=8
   kubectl -n web-prod get deploy prod-web -o jsonpath='{.spec.replicas}{"\n"}'   # 8
   ```

5. Watch Argo CD react (with `selfHeal: true`, no human action is needed):

   ```bash
   argocd app get web-prod --refresh
   kubectl -n web-prod get deploy prod-web -o jsonpath='{.spec.replicas}{"\n"}'
   ```
   Expected: the live spec returns to `3`; the app transitions `OutOfSync → Synced` on its own.

6. Now delete a whole resource and confirm `prune` semantics work the other direction:

   ```bash
   kubectl -n web-dev delete svc dev-web
   argocd app get web-dev --refresh   # controller recreates the Service
   ```

**Comprehension check**

- **Q3.1** With `selfHeal: true`, what exactly did Argo CD do to your `--replicas=8` change — did it run `kubectl scale` back, or something else? What is the difference between `selfHeal` and `prune`?
- **Q3.2** You set `prune: true`. Describe a realistic scenario where `prune: true` combined with an accidental bad merge (someone deletes a file) causes a **production outage**, and one guardrail that prevents it.
- **Q3.3** If you had wanted Argo CD to *detect* the drift but **not** auto-correct it (require a human to click Sync), which field would you change and to what?

---

## Exercise 4 — Scale environments with an ApplicationSet (git directory generator)

**Goal:** replace three hand-written `Application` files with one `ApplicationSet` that fans out over `overlays/*`. This is how platform teams onboard the 4th, 5th, Nth environment without editing YAML per environment.

**Steps**

1. Delete the manual Applications (the ApplicationSet will re-own the same environments — no workload restart, because the rendered spec is identical):

   ```bash
   kubectl -n argocd delete application web-dev web-staging web-prod
   ```

2. Create `bootstrap/web-appset.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: ApplicationSet
   metadata:
     name: web-envs
     namespace: argocd
   spec:
     goTemplate: true
     goTemplateOptions: ["missingkey=error"]
     generators:
       - git:
           repoURL: https://github.com/<you>/platform-apps
           revision: main
           directories:
             - path: apps/web/overlays/*
     template:
       metadata:
         name: 'web-{{.path.basename}}'
       spec:
         project: default
         source:
           repoURL: https://github.com/<you>/platform-apps
           targetRevision: main
           path: '{{.path.path}}'
         destination:
           server: https://kubernetes.default.svc
           namespace: 'web-{{.path.basename}}'
         syncPolicy:
           automated:
             prune: true
             selfHeal: true
           syncOptions:
             - CreateNamespace=true
   ```

3. Apply and confirm three Applications were generated automatically:

   ```bash
   kubectl apply -f bootstrap/web-appset.yaml
   argocd appset get web-envs
   argocd app list -l argocd.argoproj.io/application-set-name=web-envs
   ```
   Expected: `web-dev`, `web-staging`, `web-prod` all present and `Synced`.

4. **Prove the fan-out.** Add a fourth environment purely by creating a directory in Git:

   ```bash
   cp -r apps/web/overlays/staging apps/web/overlays/qa
   sed -i 's/web-staging/web-qa/; s/staging-/qa-/' apps/web/overlays/qa/kustomization.yaml
   git add apps/web/overlays/qa && git commit -m "web: add qa environment" && git push
   argocd appset get web-envs   # after the next git generator poll, web-qa appears
   ```

**Comprehension check**

- **Q4.1** You never wrote a `web-qa` Application, yet it exists. Which controller created it, and what would `kubectl delete application web-qa` do (and why is that the wrong way to remove the environment)?
- **Q4.2** The `git` *directory* generator discovers environments from folders. Name two other ApplicationSet generators and give a concrete case where a **cluster generator** is the right choice for multi-environment fan-out instead of directories.
- **Q4.3** What does `goTemplateOptions: ["missingkey=error"]` protect you from at render time?

---

## Exercise 5 — Promote a release dev → staging → prod through Git

**Goal:** perform a real promotion. The image `6.7.0` flows environment by environment, each promotion is a Git commit (auditable, revertable), and nothing is applied by hand.

**Steps**

1. **Promote to dev.** Bump only the dev overlay:

   ```bash
   sed -i 's/newTag: 6.6.0/newTag: 6.7.0/' apps/web/overlays/dev/kustomization.yaml
   git commit -am "promote: web 6.7.0 -> dev" && git push
   argocd app wait web-dev --sync --health --timeout 120
   ```

2. Verify the running version end-to-end (not just the manifest — the actual served version):

   ```bash
   kubectl -n web-dev port-forward svc/dev-web 8081:80 >/dev/null 2>&1 &
   curl -s localhost:8081/version   # {"version":"6.7.0",...}
   ```

3. **Promote to staging** only after dev is healthy — this is the human gate:

   ```bash
   sed -i 's/newTag: 6.6.0/newTag: 6.7.0/' apps/web/overlays/staging/kustomization.yaml
   git commit -am "promote: web 6.7.0 -> staging" && git push
   argocd app wait web-staging --sync --health --timeout 120
   ```

4. **Promote to prod** as a reviewed change. In a real repo this is a Pull Request that a second engineer approves; here, simulate the review boundary:

   ```bash
   git switch -c promote/web-6.7.0-prod
   sed -i 's/newTag: 6.6.0/newTag: 6.7.0/' apps/web/overlays/prod/kustomization.yaml
   git commit -am "promote: web 6.7.0 -> prod"
   git push -u origin promote/web-6.7.0-prod
   # open a PR, get approval, merge to main
   ```
   After the merge, Argo CD reconciles prod to `6.7.0`.

5. **Practice rollback.** Prod is a bad release — revert *in Git*, never with `kubectl rollout undo`:

   ```bash
   git revert --no-edit HEAD          # the merge/promotion commit
   git push
   argocd app wait web-prod --sync --health --timeout 120
   kubectl -n web-prod get deploy prod-web \
     -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # back to :6.6.0
   ```

**Comprehension check**

- **Q5.1** Why is `git revert` (which adds a new commit) the correct rollback rather than `git reset --hard` to the previous SHA, in a GitOps world where the whole team follows `main`?
- **Q5.2** This exercise promotes by editing tags in **directory-per-environment** overlays. Contrast that with a **branch-per-environment** model (`env/dev`, `env/staging`, `env/prod`). Give one advantage and one drawback of each for auditing and diffing a promotion.
- **Q5.3** `kubectl rollout undo` would also revert prod. State precisely why doing so leaves the system in a broken state until the *next* reconciliation, and what that broken state is.

---

## Exercise 6 — The Flux alternative: same repo, pull-based reconciliation

**Goal:** reconcile the *same* overlays with Flux to internalize that GitOps is a pattern, not one tool. You will map Flux's controllers to Argo CD's concepts.

**Steps** *(run against a second cluster, or after removing the Argo CD Applications to avoid two controllers fighting over the same namespaces)*

1. Install Flux and check the controller set:

   ```bash
   flux install
   kubectl -n flux-system get deploy
   ```
   Expected controllers: `source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller` (and, once enabled, `image-reflector-controller`, `image-automation-controller`).

2. Register the repository as a `GitRepository` source:

   ```bash
   flux create source git platform-apps \
     --url=https://github.com/<you>/platform-apps \
     --branch=main --interval=1m
   ```

3. Create one `Kustomization` per environment. Example for staging:

   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: web-staging
     namespace: flux-system
   spec:
     interval: 10m0s
     path: ./apps/web/overlays/staging
     prune: true
     wait: true
     sourceRef:
       kind: GitRepository
       name: platform-apps
     targetNamespace: web-staging
   ```
   ```bash
   kubectl apply -f web-staging-ks.yaml
   flux get kustomizations
   ```
   Expected:
   ```
   NAME          REVISION        SUSPENDED  READY  MESSAGE
   web-staging   main@sha1:...   False      True   Applied revision: main@sha1:...
   ```

4. Force a re-sync on demand (the Flux equivalent of `argocd app sync`):

   ```bash
   flux reconcile kustomization web-staging --with-source
   ```

**Comprehension check**

- **Q6.1** Map each Flux controller to its Argo CD counterpart: `source-controller`, `kustomize-controller`, and the pair `image-reflector-controller` + `image-automation-controller`.
- **Q6.2** Flux's `Kustomization.spec.prune` and Argo CD's `syncPolicy.automated.prune` sound identical. Both delete resources removed from Git — but what is the key difference in *how Flux tracks which objects it owns* (hint: inventory), and why does that matter for safe pruning?
- **Q6.3** `interval: 10m0s` on the Kustomization *and* `interval: 1m` on the GitRepository — what is each interval actually controlling? If a commit lands, what is the worst-case delay before staging reconciles, and how does `flux reconcile --with-source` collapse it?

---

## Final challenge (no walkthrough)

Design, in ~10 lines of prose plus one manifest sketch, a promotion pipeline where the **image tag is bumped in dev automatically** by a controller watching the registry, but **staging and prod are promoted only by human-reviewed PRs**. Name the Flux (or Argo CD) components involved, state where the automated write happens (which environment's overlay, which branch), and explain the one guardrail that stops the automation from ever touching prod.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 0

**A0.1** *Pulled Automatically* is implemented by an in-cluster agent that reaches out to Git and applies changes — Argo CD's `application-controller` (via the `repo-server`) or Flux's `source-controller`; nothing outside the cluster pushes with credentials. *Continuously Reconciled* is implemented by the same controller's reconciliation loop that periodically re-diffs desired vs. live state and corrects drift (Argo CD `application-controller` with `selfHeal`; Flux `kustomize-controller`/`helm-controller`).

**A0.2** The imperative `apply` produces the same object *once*, but Git is no longer the single source of truth: the change is unversioned, unreviewed, and unauditable, and the reconciler will treat it as drift (reverting it, or fighting it). GitOps requires desired state to live in Git so it is declarative, versioned/immutable, and continuously reconciled — an out-of-band apply violates all three.

### Exercise 1

**A1.1** `repo-server` clones/polls Git and *renders* manifests (runs `kustomize build` / `helm template`) into plain Kubernetes objects. The `application-controller` diffs that rendered desired state against live cluster state and, when out of sync (and automated), writes the difference back via the Kubernetes API. `argocd-server` is only the API/UI front end — it does not reconcile.

**A1.2** GitOps-preserving triggers: `argocd app sync web-dev` (or the UI "Sync" button), and `argocd app get --refresh` / a Git webhook that pokes the controller to poll immediately. Both still apply *what is in Git*. The violating way: `kubectl apply`/`edit` the live object directly — that bypasses Git and will be reverted or flagged as drift.

### Exercise 2

**A2.1** If the tag lives in `base`, every environment shares one value, so you cannot have dev on `6.7.0` while prod stays on `6.6.0`. Promotion *is* the act of moving a version through environments independently; a single shared tag makes all environments jump at once, eliminating the staged, testable rollout that promotion exists to provide.

**A2.2** The distinct **namespace** gives real isolation (RBAC, NetworkPolicy, ResourceQuota, and object-name collisions are all namespace-scoped); `namePrefix` is cosmetic within a namespace. To make isolation *enforceable* add per-namespace `ResourceQuota`/`LimitRange`, `NetworkPolicy`, and RBAC — and, for hard multi-tenancy, separate clusters or an Argo CD `AppProject` restricting each app's allowed destinations/namespaces.

**A2.3** A `kustomize build` failure (missing patch target, invalid field) discovered post-merge means `main` is already broken and the reconciler surfaces a red app in the cluster for every consumer of that path. Validating in CI keeps the failure at the PR, before it reaches the source of truth — fail-fast and free (no completion, no cluster round-trip).

### Exercise 3

**A3.1** Argo CD did not run `kubectl scale`; the `application-controller` computed a diff between the rendered desired manifest (`replicas: 3`) and live state (`replicas: 8`) and *patched the object's spec back* to the desired value through the API. `selfHeal` = correct drift where live differs from Git for a resource still declared in Git. `prune` = delete live resources that are **no longer declared** in Git at all. One fixes fields; the other removes whole objects.

**A3.2** With `prune: true`, if a bad merge deletes `service.yaml` from the overlay, the controller sees the Service as "no longer declared" and prunes it in prod, dropping the app's stable endpoint — an outage. Guardrails: `syncOptions: [Prune=false]` for critical resources or the `Prune=confirm`/manual-sync gate, per-resource `argocd.argoproj.io/sync-options: Prune=false` annotations, PR review + `kustomize build` in CI, and Argo CD's prune-protection / `PruneLast`.

**A3.3** Keep drift *detection* but disable auto-correction by removing `selfHeal` (set `selfHeal: false`) while leaving `automated` — or drop `automated` entirely so sync is manual. The app then shows `OutOfSync` and waits for a human `argocd app sync`.

### Exercise 4

**A4.1** The `applicationset-controller` generated `web-qa` from the git directory generator. `kubectl delete application web-qa` is wrong because the ApplicationSet controller *owns* that Application and will immediately re-create it (the folder still exists in Git). The GitOps-correct removal is to delete the `overlays/qa` directory in Git; the generator then stops producing the app and it is pruned.

**A4.2** Other generators include **list**, **cluster**, **git file**, **matrix**, **merge**, and pull-request generators. The **cluster generator** is right when the same app must be deployed to *many clusters* (e.g., one prod cluster per region): it fans out over registered clusters/labels rather than over folders, so onboarding a new region is registering a cluster, not adding a directory.

**A4.3** `missingkey=error` makes Go templating *fail loudly* if the template references a key the generator did not provide (e.g., a typo like `{{.path.basenam}}`), instead of silently rendering an empty string and creating a malformed Application (blank name/namespace) in the cluster.

### Exercise 5

**A5.1** `git revert` adds a new commit that is a normal fast-forward for everyone on `main` — history is preserved, the rollback is itself auditable, and no collaborator's clone is invalidated. `git reset --hard` rewrites shared history: it requires a force-push, breaks every other clone and any branch based on the reverted commits, and destroys the audit trail of what was rolled back and why.

**A5.2** *Directory-per-environment:* a promotion is a diff *within one branch* (`main`), so history and diffs of "what changed in prod" are linear and easy to review, but the same manifest content is duplicated across overlays. *Branch-per-environment:* each environment is a branch and promotion is a merge/cherry-pick between branches, giving a clean per-environment HEAD, but cross-branch drift is easy to introduce and "diff dev vs prod" means comparing branches. Directories favor a single auditable timeline; branches favor strong per-environment isolation at the cost of merge discipline.

**A5.3** `kubectl rollout undo` mutates live state to the old ReplicaSet, but **Git still says `6.7.0`**. Until the next reconciliation the live/desired states disagree — a self-healing controller will detect the "drift" and *re-apply `6.7.0`*, undoing your rollback (the outage returns). The broken state is precisely this desired≠live divergence, and the only durable fix is to change Git.

### Exercise 6

**A6.1** `source-controller` ↔ Argo CD `repo-server` (fetches and caches Git/Helm/OCI artifacts). `kustomize-controller` ↔ Argo CD `application-controller` (renders + applies + prunes). `image-reflector-controller` + `image-automation-controller` ↔ **Argo CD Image Updater** (scan the registry for new tags and write the bump back into Git).

**A6.2** Flux records an explicit **inventory** in the `Kustomization` status — the exact set of object references it applied last time — and prunes by computing (previous inventory − current inventory). Argo CD derives ownership by tracking annotations/labels and the app's rendered set. The inventory makes Flux's pruning precise: it only garbage-collects objects it *provably* created, reducing the risk of deleting something it never owned.

**A6.3** The `GitRepository.interval` (`1m`) controls how often the source is *fetched* from Git; the `Kustomization.interval` (`10m`) controls how often it is *reconciled/applied* even without a source change (drift correction). Worst case, a commit waits up to ~1 min to be fetched *and then* up to the Kustomization's next reconcile — bounded by the source poll plus apply cadence. `flux reconcile kustomization web-staging --with-source` forces an immediate source fetch **and** an immediate apply, collapsing the delay to seconds.

### Final challenge (model answer)

Enable Flux's **image-reflector-controller** (scans the registry) and **image-automation-controller** (writes commits). Add an `ImageRepository` + `ImagePolicy` (e.g., semver `>=6.6.0 <7.0.0`) for podinfo, and an `ImageUpdateAutomation` whose `spec.git.checkout.ref.branch`/`push.branch` and `update.path: ./apps/web/overlays/dev` scope every automated write to **the dev overlay only**, pushing to `main` (or a `dev-auto` branch). Staging and prod overlays carry `# {"$imagepolicy": ...}` markers *only in dev*, so the automation has nothing to edit elsewhere. The single guardrail: the automation's `update.path` is dev-scoped and prod's tag is changed exclusively by human-approved PRs — the controller has neither a marker nor a path into prod, so it can never write there. Argo CD equivalent: Argo CD Image Updater with `write-back-method: git` and an application-level annotation restricting it to the dev `Application`.

</details>