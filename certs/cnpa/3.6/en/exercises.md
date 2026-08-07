# Topic 3.6 — GitOps Basics, Controllers, and Workflows

## Guided Exercises

These exercises assume a working single-node cluster (`kind`, `minikube`, or `k3d`) and a `kubectl` context that points at it. Every manifest below is complete and syntactically valid — apply it as-is. Where a command produces output, the expected shape of that output is shown so you can compare.

> Sources used throughout:
> - OpenGitOps Principles v1.0.0 — https://opengitops.dev/ and https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
> - Argo CD docs — https://argo-cd.readthedocs.io/en/stable/
> - Flux docs (GitOps Toolkit) — https://fluxcd.io/flux/
> - Argo Workflows docs — https://argo-workflows.readthedocs.io/en/latest/

---

### Exercise 0 — Prepare the cluster

**Steps**

1. Create a disposable cluster (skip if you already have one):

   ```bash
   kind create cluster --name gitops-lab
   ```

2. Confirm you are pointed at it and the control plane answers:

   ```bash
   kubectl config current-context
   kubectl get nodes
   ```

   Expected:

   ```
   kind-gitops-lab
   NAME                      STATUS   ROLES           AGE   VERSION
   gitops-lab-control-plane  Ready    control-plane   40s   v1.31.0
   ```

**Check your understanding**

- Q0.1 — GitOps is a *pull-based* model. Given that, does the cluster you just created need any inbound network access from your CI system for GitOps to work? Why or why not?

---

### Exercise 1 — The four OpenGitOps principles, made concrete

Before touching a tool, map the four principles to observable facts. You will validate each one in later exercises.

**Steps**

1. Read the four principles and write, for each, *what artifact or behavior would prove it in a running system*:

   1. **Declarative** — the desired state is expressed as data, not scripts.
   2. **Versioned and Immutable** — that state is stored in Git; history is append-only.
   3. **Pulled Automatically** — software agents pull the desired state from the source.
   4. **Continuously Reconciled** — agents continuously observe actual state and converge it toward desired state.

2. Create a tiny Git repo you control (GitHub/GitLab or local) with a directory `apps/hello/` containing a plain Kubernetes manifest — this is your **single source of truth**:

   ```yaml
   # apps/hello/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: hello
     labels:
       app: hello
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: hello
     template:
       metadata:
         labels:
           app: hello
       spec:
         containers:
           - name: hello
             image: nginxdemos/hello:plain-text
             ports:
               - containerPort: 80
   ```

3. Commit and push it. Note the commit SHA — that SHA is the *immutable* handle to this exact desired state.

**Check your understanding**

- Q1.1 — Which principle is violated if an operator runs `kubectl scale deployment/hello --replicas=5` directly against the cluster and it stays at 5?
- Q1.2 — "Versioned and Immutable" — a Git branch is mutable (you can force-push). What is the *immutable* unit the principle actually refers to?
- Q1.3 — GitOps is often contrasted with a `kubectl apply` step inside a CI pipeline. Which of the four principles does the CI-push model typically fail to satisfy, and why is that the security-relevant one?

---

### Exercise 2 — Install a GitOps controller (Argo CD) and observe the reconciliation loop

**Steps**

1. Install Argo CD into its own namespace:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Wait for the core controller to be ready and list what got installed:

   ```bash
   kubectl -n argocd rollout status deploy/argocd-repo-server
   kubectl -n argocd get deploy
   ```

   Expected (names, not exact ages):

   ```
   NAME                                READY   UP-TO-DATE   AVAILABLE
   argocd-applicationset-controller    1/1     1            1
   argocd-dex-server                   1/1     1            1
   argocd-notifications-controller     1/1     1            1
   argocd-redis                        1/1     1            1
   argocd-repo-server                  1/1     1            1
   argocd-server                       1/1     1            1
   ```

   Note: the **application-controller** is a StatefulSet, not a Deployment:

   ```bash
   kubectl -n argocd get statefulset
   ```

   ```
   NAME                        READY
   argocd-application-controller   1/1
   ```

3. Register your Git repo as the desired state by creating an `Application` custom resource. This CR *is* the declarative intent handed to the controller:

   ```yaml
   # hello-app.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: hello
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/<you>/<your-repo>.git
       targetRevision: main
       path: apps/hello
     destination:
       server: https://kubernetes.default.svc
       namespace: hello
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

   ```bash
   kubectl apply -f hello-app.yaml
   ```

4. Watch the controller pull, diff, and converge:

   ```bash
   kubectl -n argocd get application hello -w
   ```

   Expected progression:

   ```
   NAME    SYNC STATUS   HEALTH STATUS
   hello   OutOfSync     Missing
   hello   Synced        Progressing
   hello   Synced        Healthy
   ```

5. Confirm the workload actually landed in the target namespace:

   ```bash
   kubectl -n hello get deploy,pods
   ```

**Check your understanding**

- Q2.1 — You never ran `kubectl apply` for the Deployment yourself. Trace the exact chain: what did *you* create, what did the controller read from it, and what did the controller create as a result?
- Q2.2 — Why does `SYNC STATUS` (`Synced` / `OutOfSync`) exist as a separate axis from `HEALTH STATUS` (`Healthy` / `Progressing` / `Degraded`)? Give a state where an app is `Synced` but not `Healthy`, and one where it is `Healthy` but `OutOfSync`.
- Q2.3 — The Argo CD `Application` is itself a Kubernetes resource. What advantage does that give you that a controller storing app definitions in its own database would not?

---

### Exercise 3 — Continuous reconciliation and self-healing (drift correction)

This is the principle that separates GitOps from a one-shot `apply`. You will introduce **drift** manually and watch the controller erase it.

**Steps**

1. Confirm current desired state is 2 replicas (from Git), and that live state matches:

   ```bash
   kubectl -n hello get deploy hello -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   2
   ```

2. Introduce drift *out of band* — imperatively scale to 5:

   ```bash
   kubectl -n hello scale deploy/hello --replicas=5
   kubectl -n hello get deploy hello -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   5
   ```

3. Watch the reconciliation loop react (with `selfHeal: true`, no human intervention):

   ```bash
   kubectl -n hello get deploy hello -w -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas
   ```

   Expected: it snaps back to `2` within the controller's reconcile interval (default polling is ~3 min, but the app-controller reconciles far sooner on the watch):

   ```
   NAME    REPLICAS
   hello   5
   hello   2
   ```

4. Now do the opposite experiment — delete a managed object entirely:

   ```bash
   kubectl -n hello delete deployment hello
   ```

   Watch it be recreated:

   ```bash
   kubectl -n hello get deploy -w
   ```

5. Contrast with **prune**. Edit `apps/hello/deployment.yaml` in Git to *remove* nothing but instead add a second manifest, then delete it in a later commit, and observe that `prune: true` causes the controller to delete the now-absent object from the cluster. (You can also read the current sync options: `kubectl -n argocd get application hello -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'`.)

**Check your understanding**

- Q3.1 — In step 3, no CI job ran and no human synced. What component detected the drift, and against what reference did it compare live state?
- Q3.2 — `selfHeal: true` fixed the manual `scale`. What does `prune: true` control that `selfHeal` does *not*, and why are they deliberately two separate switches?
- Q3.3 — A colleague says "GitOps means Git is a backup." Correct the statement precisely using the word *reconciliation*.
- Q3.4 — Self-heal reverted a live change made by a human. Describe one legitimate operational scenario where this behavior is dangerous, and what GitOps-native mechanism (not `kubectl`) you would use instead of an out-of-band edit.

---

### Exercise 4 — A second controller family: Flux and the GitOps Toolkit

Argo CD bundles reconciliation into one application-controller. Flux decomposes it into separate, single-responsibility controllers. Installing Flux lets you *see the controllers themselves* as the unit of GitOps.

**Steps**

1. Install the Flux controllers (no bootstrap/Git write needed for this exercise):

   ```bash
   flux install
   ```

   or, without the CLI:

   ```bash
   kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
   ```

2. List the GitOps Toolkit controllers:

   ```bash
   kubectl -n flux-system get deploy
   ```

   Expected:

   ```
   NAME                        READY   UP-TO-DATE   AVAILABLE
   helm-controller             1/1     1            1
   kustomize-controller        1/1     1            1
   notification-controller     1/1     1            1
   source-controller           1/1     1            1
   ```

3. Declare a **source** (what to pull) and a **Kustomization** (how to reconcile it) as two separate resources — this is the toolkit's separation of concerns made explicit:

   ```yaml
   # podinfo-source.yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 1m
     url: https://github.com/stefanprodan/podinfo
     ref:
       branch: master
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 10m
     targetNamespace: default
     sourceRef:
       kind: GitRepository
       name: podinfo
     path: "./kustomize"
     prune: true
     timeout: 2m
   ```

   ```bash
   kubectl apply -f podinfo-source.yaml
   ```

4. Observe each controller doing its one job:

   ```bash
   kubectl -n flux-system get gitrepository podinfo
   kubectl -n flux-system get kustomization podinfo
   ```

   Expected:

   ```
   NAME      URL                                       READY   STATUS
   podinfo   https://github.com/stefanprodan/podinfo   True    stored artifact for revision 'master@sha1:...'

   NAME      READY   STATUS
   podinfo   True    Applied revision: master@sha1:...
   ```

5. Force a reconcile immediately instead of waiting for the interval:

   ```bash
   flux reconcile kustomization podinfo --with-source
   kubectl -n default get deploy podinfo
   ```

**Check your understanding**

- Q4.1 — In Flux, the `source-controller` fetched the repo and the `kustomize-controller` applied it. What is the intermediate artifact the source-controller produces and the kustomize-controller consumes, and why decouple them this way?
- Q4.2 — Both the `GitRepository` and the `Kustomization` have an `interval`. What is each interval controlling, and what happens to reconciliation if the Git server is briefly unreachable?
- Q4.3 — Map the Flux pair (`GitRepository` + `Kustomization`) onto the fields of the single Argo CD `Application` from Exercise 2. Which Argo CD `spec.source.*` fields correspond to which Flux resource?

---

### Exercise 5 — A promotion workflow: environments and drift-free rollout

GitOps changes are made *by changing Git*, not the cluster. Here you drive a change through the loop and, separately, use **Argo Workflows** as the CI half of the story.

**Steps (promotion via Git)**

1. Change the desired state the correct way — edit `apps/hello/deployment.yaml` in Git to bump the image tag and set `replicas: 3`, then commit and push:

   ```yaml
   spec:
     replicas: 3
     template:
       spec:
         containers:
           - name: hello
             image: nginxdemos/hello:0.3-plain-text
   ```

2. Do **not** touch the cluster. Watch the Argo CD app pick up the new commit:

   ```bash
   kubectl -n argocd get application hello -w
   ```

   Expected: `Synced → OutOfSync → Synced` as it converges to the new revision. Confirm:

   ```bash
   kubectl -n hello get deploy hello -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

3. Inspect the recorded revision to prove traceability from live state back to a commit:

   ```bash
   kubectl -n argocd get application hello \
     -o jsonpath='{.status.sync.revision}{"\n"}'
   ```

**Steps (a CI workflow with Argo Workflows)**

4. Install Argo Workflows:

   ```bash
   kubectl create namespace argo
   kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/latest/download/quick-start-minimal.yaml
   ```

5. Submit a minimal multi-step `Workflow` — the kind of pipeline that would build/test/render manifests *before* committing them to the GitOps repo:

   ```yaml
   # ci-pipeline.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Workflow
   metadata:
     generateName: ci-pipeline-
     namespace: argo
   spec:
     entrypoint: main
     templates:
       - name: main
         steps:
           - - name: test
               template: run
               arguments:
                 parameters:
                   - name: cmd
                     value: "echo running unit tests && true"
           - - name: build
               template: run
               arguments:
                 parameters:
                   - name: cmd
                     value: "echo building image"
       - name: run
         inputs:
           parameters:
             - name: cmd
         container:
           image: busybox:1.36
           command: [sh, -c]
           args: ["{{inputs.parameters.cmd}}"]
   ```

   ```bash
   kubectl create -f ci-pipeline.yaml
   kubectl -n argo get workflows
   ```

   Expected:

   ```
   NAME               STATUS      AGE
   ci-pipeline-xxxxx  Succeeded   30s
   ```

6. Inspect the DAG/step results:

   ```bash
   kubectl -n argo get workflow -o name | head -1 | \
     xargs kubectl -n argo get -o jsonpath='{.status.phase}{"\n"}'
   ```

**Check your understanding**

- Q5.1 — In step 1 you changed a file and pushed. Name every actor between your `git push` and the new pods running, in order. Which of them is the *only* one that writes to the cluster?
- Q5.2 — Argo **Workflows** and Argo **CD** are different projects with a similar name. In one sentence each, what is the responsibility of each, and where is the handoff between them in a GitOps pipeline?
- Q5.3 — A team wants "GitOps for CI too" and proposes having the CI Workflow run `kubectl apply` at the end. Explain why that reintroduces the exact problem GitOps was meant to remove, and what the Workflow should write instead.
- Q5.4 — `Workflow` uses `generateName` rather than `name`. Why is that appropriate for a pipeline run but *inappropriate* for the desired-state manifests you keep in Git?

---

### Cleanup

```bash
kubectl delete -f hello-app.yaml
kubectl delete -f podinfo-source.yaml
kubectl delete namespace argocd argo flux-system hello --ignore-not-found
kind delete cluster --name gitops-lab
```

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 0**

- **A0.1** — No. In the pull model the in-cluster agent (Argo CD / Flux) initiates outbound connections to Git and pulls the desired state; the CI system never needs a route *into* the cluster and never needs cluster credentials. This is the core security advantage of GitOps: no external system holds `kubectl`/API write access, shrinking the attack surface and eliminating long-lived cluster credentials in CI.

**Exercise 1**

- **A1.1** — *Continuously Reconciled*. A live state (5) that persists while the source of truth says 2 means no agent is converging actual toward desired. (It also means the source of truth is no longer authoritative, undermining *Declarative* as the operative model.)
- **A1.2** — The **commit** (identified by its content-addressed SHA). A branch is a moving pointer, but any given commit — and the tree it references — is immutable and content-addressed; that SHA is the exact, reproducible desired state. This is why controllers record a *revision SHA*, not just a branch name.
- **A1.3** — *Pulled Automatically* (and, in practice, *Continuously Reconciled*). A CI job that runs `kubectl apply` **pushes** on a trigger: it applies once, then stops watching, so drift between deploys is unobserved, and it requires giving CI standing write credentials to the cluster. GitOps flips this to an in-cluster agent that pulls — removing external cluster credentials, which is why it is the security-relevant difference.

**Exercise 2**

- **A2.1** — You created the `Application` CR in the `argocd` namespace. The application-controller read `spec.source` (repoURL/targetRevision/path) and `spec.destination`, pulled `apps/hello` at revision `main` from Git via the repo-server, rendered the manifests, diffed them against live state (nothing there yet → `OutOfSync`/`Missing`), and then applied them — creating the `hello` namespace (`CreateNamespace=true`) and the `Deployment`, which the built-in Kubernetes controllers turned into a ReplicaSet and Pods.
- **A2.2** — They answer different questions. **Sync** = "does live cluster state match the manifests in Git?" **Health** = "is the workload actually working?" *Synced but not Healthy*: the correct manifest is applied but the Deployment is still `Progressing` (image pulling) or `Degraded` (CrashLoopBackOff) — Git and cluster agree, the app is just unhealthy. *Healthy but OutOfSync*: the running app is perfectly healthy, but someone changed Git (a new commit) and reconciliation hasn't converged yet — the current healthy state no longer matches the desired state.
- **A2.3** — Because the desired-state object lives in the Kubernetes API, it is subject to the same RBAC, admission control, auditing, `kubectl`/GitOps management, and even reconciliation (App-of-Apps) as any other resource. A controller-private database would put app definitions outside that uniform control plane, so you couldn't manage the *manager* declaratively.

**Exercise 3**

- **A3.1** — The Argo CD **application-controller**. It continuously compares live cluster state against the manifests rendered from the tracked Git revision (the source of truth), detected the diff (`spec.replicas` 5 ≠ 2), marked the app `OutOfSync`, and — because `selfHeal: true` — re-applied the desired state.
- **A3.2** — `selfHeal` controls reverting *modifications* to objects that Git still declares (scale back to 2). `prune` controls *deleting* objects that exist in the cluster but no longer exist in Git. They are separate because deletion is destructive and irreversible in a way a spec revert is not; many teams enable `selfHeal` but keep `prune` off (or gated) so a bad commit that drops a manifest doesn't silently delete production workloads.
- **A3.3** — Git is not merely a backup; it is the **authoritative source of truth that is continuously reconciled**. A backup is a passive copy you restore manually after a loss. In GitOps, an agent actively and continuously drives live state toward the Git state, so unrequested drift is *automatically corrected*, not just recoverable.
- **A3.4** — Emergency incident response (e.g. scaling up under sudden load, or applying a hotfix) where waiting on a PR is unacceptable — self-heal would revert your fix mid-incident. The GitOps-native answers: temporarily **disable auto-sync / self-heal** for that app (pause reconciliation) while you act, or better, make the change *through Git* (commit the scale/hotfix, or use a break-glass branch), so the source of truth stays authoritative and the change is auditable. The anti-pattern is a silent out-of-band `kubectl` edit that the controller will fight.

**Exercise 4**

- **A4.1** — The source-controller fetches the repo and produces an **Artifact** (a tarball of the source at a specific revision, exposed over an in-cluster URL with its checksum). The kustomize-controller consumes that artifact, builds the manifests, and applies them. Decoupling means: one fetch can feed many reconcilers, source acquisition and applying have independent intervals and failure modes, and the source type (Git, OCI, Bucket, Helm) is pluggable behind the same artifact contract.
- **A4.2** — The `GitRepository.spec.interval` controls how often the source-controller *checks Git for a new revision*; the `Kustomization.spec.interval` controls how often the kustomize-controller *re-applies and re-checks drift* against the last successfully fetched artifact. If Git is briefly unreachable, the source-controller keeps serving the **last good artifact**, so the kustomize-controller continues reconciling the known-good revision — reconciliation degrades gracefully rather than stopping.
- **A4.3** — The Flux `GitRepository` corresponds to Argo CD `spec.source.repoURL` + `spec.source.targetRevision` (what/where to pull). The Flux `Kustomization` corresponds to `spec.source.path` + the rendering/apply behavior + `spec.destination` + `spec.syncPolicy` (`prune`, self-heal, target namespace). Argo CD fuses "get the source" and "apply the source" into one `Application`; Flux splits them into two resources owned by two controllers.

**Exercise 5**

- **A5.1** — In order: (1) **Git server** stores the new commit; (2) the **Argo CD repo-server** pulls/renders the manifests at that revision; (3) the **application-controller** diffs and, on `OutOfSync`, applies them to the API server; (4) the **kube-apiserver** persists the updated Deployment; (5) the built-in **Deployment/ReplicaSet controllers** roll out new Pods; (6) the **scheduler + kubelets** run them. The only actor that writes to the cluster (calls the API server with the desired manifests) is the **application-controller** — your `git push` never touches the cluster.
- **A5.2** — **Argo Workflows** is a general-purpose, container-native workflow/DAG engine for running pipelines (CI, batch, ML) as Kubernetes CRDs. **Argo CD** is a GitOps continuous-*delivery* controller that reconciles cluster state to Git. The handoff: Workflows does build/test and **commits the resulting manifests/image tag to the GitOps repo**, and Argo CD (or Flux) then pulls that commit and deploys it. CI writes to Git; CD reads from Git.
- **A5.3** — Ending CI with `kubectl apply` turns it back into a **push-based** deploy: CI needs standing cluster write credentials, the change is applied once and drift goes unwatched, and the cluster's live state is no longer guaranteed to match Git. It defeats *Pulled Automatically* and *Continuously Reconciled*. Instead the Workflow should write the change **into the Git repo** (e.g. commit the new image tag / rendered manifests, open a PR), leaving the in-cluster GitOps agent as the sole writer to the cluster.
- **A5.4** — `generateName` yields a fresh unique name per submission (`ci-pipeline-xxxxx`), which is right for pipeline *runs* — each execution is a distinct, disposable object. Desired-state manifests in Git must have a **stable, deterministic `name`** so that re-applying the same file updates the *same* object (idempotent reconciliation). A generated name would create a new object every reconcile, breaking diffing, pruning, and the whole notion of a single source of truth.

</details>