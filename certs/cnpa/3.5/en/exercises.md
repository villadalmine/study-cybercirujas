# Guided Exercises — Topic 3.5: CI/CD Relationship Fundamentals and Integration

> **Certification:** CNPA (Cloud Native Platform Engineering Associate) — exam version 2025-04-01
> **Domain weight:** 2.3
>
> These exercises build a complete CI → CD integration on your workstation and make the *boundary* between the two systems observable. You will see, concretely, where CI ends, where CD begins, what artifact crosses that boundary, and why the handoff is designed the way it is. Every command is real and produces the output shown (versions and digests will differ on your machine).
>
> **What you need**
>
> | Tool | Minimum version | Check |
> |---|---|---|
> | `docker` (with buildx) | 24.x | `docker buildx version` |
> | `kind` | 0.23+ | `kind version` |
> | `kubectl` | 1.29+ | `kubectl version --client` |
> | `kustomize` | 5.x | `kustomize version` |
> | `git` | 2.40+ | `git --version` |
> | `argocd` CLI | 2.11+ | `argocd version --client` |
>
> No paid registry or cloud account is required — we publish images to the anonymous, ephemeral registry **ttl.sh** and host the config repo locally.

---

## Block 0 — Bootstrap the platform substrate

You need a cluster (the *runtime*) and a place to run CI (*your shell*, standing in for a build runner).

1. Create a local Kubernetes cluster:

   ```bash
   kind create cluster --name cnpa-cicd
   ```

   ```text
   Creating cluster "cnpa-cicd" ...
    ✓ Ensuring node image (kindest/node:v1.30.0) 🖼
    ✓ Preparing nodes 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
   Set kubectl context to "kind-cnpa-cicd"
   ```

2. Confirm the context and node:

   ```bash
   kubectl config current-context
   kubectl get nodes
   ```

   ```text
   kind-cnpa-cicd
   NAME                      STATUS   ROLES           AGE   VERSION
   cnpa-cicd-control-plane   Ready    control-plane   40s   v1.30.0
   ```

3. Create a working directory that will hold **two logically separate repositories** — the *application source* and the *deployment configuration*:

   ```bash
   mkdir -p ~/cnpa-lab/app-src ~/cnpa-lab/platform-config
   ```

**Comprehension check — Block 0**

- **Q0.1** — You just created two directories, `app-src` and `platform-config`. Before writing any pipeline, why does CI/CD integration practice keep application *source* and deployment *configuration* in separate repositories? What single concern does this separation protect?

---

## Block 1 — The unit of handoff: an immutable, content-addressed artifact

CI's job is to turn *source* into a *versioned artifact*. That artifact — not the source — is what CD consumes. Here you produce it and prove it is immutable.

1. Create a trivial application in `app-src`:

   ```bash
   cd ~/cnpa-lab/app-src
   cat > index.html <<'EOF'
   <!doctype html><html><body><h1>CNPA demo — build 1</h1></body></html>
   EOF
   cat > Dockerfile <<'EOF'
   FROM nginx:1.27-alpine
   COPY index.html /usr/share/nginx/html/index.html
   EOF
   ```

2. Pick a unique image name (ttl.sh keys images by name; the *tag* is the time-to-live):

   ```bash
   export IMG=ttl.sh/cnpa-$(uuidgen | tr 'A-Z' 'a-z')
   echo "$IMG"
   ```

   ```text
   ttl.sh/cnpa-7f3c9e21-4a5b-4c8d-9e11-2b6a0d5f8c34
   ```

3. Build **and publish** the artifact, capturing the build metadata so you can read the digest:

   ```bash
   docker buildx build --push \
     -t "$IMG:1h" \
     --metadata-file build.json .
   ```

   ```text
   [+] Building 3.1s (8/8) FINISHED
    => exporting to image
    => => pushing layers
    => => pushing manifest for ttl.sh/cnpa-7f3c…:1h@sha256:a1b2c3…
   ```

4. Extract the **digest** — the content address of the artifact:

   ```bash
   export DIGEST=$(jq -r '."containerimage.digest"' build.json)
   echo "$DIGEST"
   ```

   ```text
   sha256:a1b2c3d4e5f60718293a4b5c6d7e8f9012a3b4c5d6e7f80912a3b4c5d6e7f809
   ```

5. Now change the source, rebuild to the **same tag**, and observe that the digest changes:

   ```bash
   sed -i 's/build 1/build 2/' index.html
   docker buildx build --push -t "$IMG:1h" --metadata-file build2.json .
   jq -r '."containerimage.digest"' build2.json
   ```

   ```text
   sha256:99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa
   ```

**Comprehension check — Block 1**

- **Q1.1** — The tag `:1h` stayed identical across steps 3 and 5, but the digest changed. Explain why a **tag** is an unreliable input for CD and why the **digest** is the correct thing to hand across the CI→CD boundary.
- **Q1.2** — Name the CI responsibilities you exercised in this block (there are three distinct ones). Which of them, if any, touched the Kubernetes cluster?
- **Q1.3** — "Build once, promote everywhere" is a CI/CD integration principle. Given what you saw about digests, what would go wrong if instead you rebuilt the image separately for `dev`, `staging`, and `prod`?

---

## Block 2 — CD's input contract: the desired-state config

CD does not build; it *reconciles a declared desired state*. That desired state lives in `platform-config` and names the artifact by digest.

1. Scaffold a Kustomize base plus a `dev` overlay:

   ```bash
   cd ~/cnpa-lab/platform-config
   mkdir -p base envs/dev
   ```

2. Write the base manifests:

   ```bash
   cat > base/deployment.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 2
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: app            # placeholder, overridden by kustomize
             ports:
               - containerPort: 80
   EOF

   cat > base/service.yaml <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector: { app: web }
     ports:
       - port: 80
         targetPort: 80
   EOF

   cat > base/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
   EOF
   ```

3. Create the `dev` overlay and pin the artifact **by digest** (this is the CI→CD contract materialised as text):

   ```bash
   cat > envs/dev/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: demo-dev
   resources:
     - ../../base
   images:
     - name: app
       newName: PLACEHOLDER_NAME
       digest: PLACEHOLDER_DIGEST
   EOF

   cd envs/dev
   kustomize edit set image "app=${IMG}@${DIGEST}"
   cd ~/cnpa-lab/platform-config
   ```

4. Render the desired state locally to confirm the digest is baked in:

   ```bash
   kustomize build envs/dev | grep -A1 'image:'
   ```

   ```text
         image: ttl.sh/cnpa-7f3c…@sha256:a1b2c3d4e5f6…
   ```

5. Turn `platform-config` into a **local git repository** — CD reads from git, so this is mandatory, not cosmetic:

   ```bash
   git init -q && git add -A && git commit -qm "config: pin web to first build"
   git log --oneline
   ```

   ```text
   3a9f1c2 config: pin web to first build
   ```

**Comprehension check — Block 2**

- **Q2.1** — The `image:` field in `base/deployment.yaml` literally says `app`, yet the rendered output shows a full registry path and digest. Which system resolved that, and at what point in the CI/CD flow does this resolution belong — build time or deploy time?
- **Q2.2** — Nothing in this block contacted the cluster either. Summarise, in one sentence each, what CI *produces* and what CD *consumes*.
- **Q2.3** — Why is it significant that the desired state is committed to **git** specifically, rather than, say, pushed to an object store or a database?

---

## Block 3 — Two integration styles: push vs pull

The CI→CD handoff can be wired *push-based* (CI applies to the cluster) or *pull-based* (an in-cluster agent syncs from git). You will feel the difference by doing the push style first, then dismantling it.

1. **Push style (imperative from CI):** simulate a CI runner deploying directly.

   ```bash
   kubectl create namespace demo-dev
   kustomize build envs/dev | kubectl apply -f -
   ```

   ```text
   namespace/demo-dev created
   deployment.apps/web created
   service/web created
   ```

2. Confirm it runs, then note *who* just did the deploying:

   ```bash
   kubectl -n demo-dev get deploy web -o wide
   ```

   ```text
   NAME   READY   UP-TO-DATE   AVAILABLE   IMAGE
   web    2/2     2            2           ttl.sh/cnpa-7f3c…@sha256:a1b2c3…
   ```

3. Now **introduce drift** the way a hurried operator would, bypassing git entirely:

   ```bash
   kubectl -n demo-dev scale deploy/web --replicas=5
   kubectl -n demo-dev get deploy web
   ```

   ```text
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    5/5     5            5           90s
   ```

4. Observe the problem: git still says `replicas: 2`, the cluster says `5`, and **nothing reconciles them**. The desired state and actual state have silently diverged.

5. Tear the push-deployed workload down so Block 4 can redeploy it the pull way:

   ```bash
   kubectl delete namespace demo-dev
   ```

**Comprehension check — Block 3**

- **Q3.1** — In the push model of steps 1–2, which system held **write credentials to the cluster**? In an organisation with dozens of pipelines, what is the security consequence of that answer?
- **Q3.2** — After step 3, the cluster ran 5 replicas but git declared 2, and no alarm fired. What capability is the push model *structurally missing* that would have caught this?
- **Q3.3** — Define **push-based** and **pull-based** continuous delivery in one line each, and state which one keeps the cluster's credentials *inside* the cluster.

---

## Block 4 — Wire the pull-based CD controller (the real integration)

Now install Argo CD as the in-cluster reconciler and let it — not your shell — deploy from `platform-config`.

1. Install Argo CD:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   kubectl -n argocd rollout status deploy/argocd-repo-server
   ```

   ```text
   deployment "argocd-repo-server" successfully rolled out
   ```

2. Serve `platform-config` over a URL Argo CD can reach from inside the cluster. The simplest self-contained option is the local git HTTP daemon exposed to kind:

   ```bash
   cd ~/cnpa-lab/platform-config
   git daemon --reuseaddr --base-path=/home/$USER/cnpa-lab \
     --export-all --enable=receive-pack \
     --listen=0.0.0.0 --port=9418 &
   # reachable from kind nodes at the host gateway address:
   export REPO_URL="git://host.docker.internal:9418/platform-config"
   echo "$REPO_URL"
   ```

   > On Linux kind, `host.docker.internal` resolves via the default `extraHosts`; if unset, substitute the output of `docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}'`.

3. Declare the CD **Application** — this object *is* the integration point: it binds a git path (desired state) to a cluster namespace (runtime), and turns on continuous reconciliation:

   ```bash
   cat > /tmp/app-dev.yaml <<EOF
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: web-dev
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: ${REPO_URL}
       targetRevision: HEAD
       path: envs/dev
     destination:
       server: https://kubernetes.default.svc
       namespace: demo-dev
     syncPolicy:
       automated:
         prune: true        # delete resources removed from git
         selfHeal: true     # revert manual drift back to git
       syncOptions:
         - CreateNamespace=true
   EOF
   kubectl apply -f /tmp/app-dev.yaml
   ```

   ```text
   application.argoproj.io/web-dev created
   ```

4. Watch the controller pull, render, and apply — with no `kubectl apply` from you:

   ```bash
   kubectl -n argocd get applications
   ```

   ```text
   NAME      SYNC STATUS   HEALTH STATUS
   web-dev   Synced        Healthy
   ```

5. Prove `selfHeal` closes the gap that Block 3 left open. Reintroduce the same drift:

   ```bash
   kubectl -n demo-dev scale deploy/web --replicas=5
   sleep 15
   kubectl -n demo-dev get deploy web
   ```

   ```text
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    2/2     2            2           1m
   ```

   The controller detected divergence from git and reverted it.

**Comprehension check — Block 4**

- **Q4.1** — The `Application` object contains a `source` (git) and a `destination` (cluster). Explain how this single object *is* the CI/CD integration seam — what does each side represent?
- **Q4.2** — In step 5 the replica count snapped back to 2 on its own. Which two `syncPolicy.automated` settings produced that behaviour, and what does each one do?
- **Q4.3** — Compare with Block 3: in this pull model, does your CI pipeline need cluster credentials at all? Where does the "apply to the cluster" action now physically execute?

---

## Block 5 — Close the loop: CI promotes by writing config, CD deploys

Here is the whole relationship in motion. A source change triggers CI, CI publishes a new artifact **and updates the config repo**, and CD picks it up. Crucially, CI *never* touches the cluster — it only writes git.

1. Simulate a source change and a fresh CI build (reuse the "build 2" image from Block 1):

   ```bash
   export DIGEST2=$(jq -r '."containerimage.digest"' ~/cnpa-lab/app-src/build2.json)
   echo "CI produced: ${IMG}@${DIGEST2}"
   ```

2. **CI's config-update step** — the *only* thing CI does to CD is commit a new desired state:

   ```bash
   cd ~/cnpa-lab/platform-config/envs/dev
   kustomize edit set image "app=${IMG}@${DIGEST2}"
   cd ~/cnpa-lab/platform-config
   git commit -qam "ci: promote web to ${DIGEST2:0:19}…"
   git log --oneline
   ```

   ```text
   b4c7e90 ci: promote web to sha256:998877665…
   3a9f1c2 config: pin web to first build
   ```

3. Nudge/observe reconciliation (Argo CD polls ~3 min by default; force it to be immediate):

   ```bash
   kubectl -n argocd annotate app web-dev argocd.argoproj.io/refresh=hard --overwrite
   sleep 20
   kubectl -n argocd get app web-dev -o jsonpath='{.status.sync.revision}{"\n"}'
   kubectl -n demo-dev get deploy web -o jsonpath='{..image}{"\n"}'
   ```

   ```text
   b4c7e90…
   ttl.sh/cnpa-7f3c…@sha256:998877665…
   ```

   The cluster is now running build 2 — deployed by CD, triggered by a git commit, without CI ever authenticating to the cluster.

4. Review the full example CI definition this block simulated (GitHub Actions form) and note the two clean stages and the missing cluster credentials:

   ```yaml
   # .github/workflows/ci.yaml  (in the app-src repo)
   name: ci
   on:
     push:
       branches: [main]
   jobs:
     build-and-publish:
       runs-on: ubuntu-latest
       outputs:
         digest: ${{ steps.build.outputs.digest }}
       steps:
         - uses: actions/checkout@v4
         - id: build
           name: Build, test, and publish the immutable artifact
           run: |
             IMAGE=ttl.sh/cnpa-web
             docker buildx build --push -t "$IMAGE:1h" --metadata-file m.json .
             echo "digest=$(jq -r '."containerimage.digest"' m.json)" >> "$GITHUB_OUTPUT"

     promote-dev:
       needs: build-and-publish
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
           with:
             repository: acme/platform-config      # the *other* repo
             token: ${{ secrets.CONFIG_REPO_PAT }} # write to git, NOT to the cluster
         - run: |
             cd envs/dev
             kustomize edit set image "app=ttl.sh/cnpa-web@${{ needs.build-and-publish.outputs.digest }}"
             git config user.name  ci-bot
             git config user.email ci-bot@acme.io
             git commit -am "ci: promote web to ${{ needs.build-and-publish.outputs.digest }}"
             git push
   ```

**Comprehension check — Block 5**

- **Q5.1** — Trace the trigger chain from a developer's `git push` in `app-src` to a new Pod running in the cluster. List every hop and name the system responsible for each.
- **Q5.2** — In the workflow YAML, `promote-dev` holds a `CONFIG_REPO_PAT` secret but *no* kubeconfig or cluster token. Why is this scoping the entire point of pull-based integration? What is the blast radius if that PAT leaks, versus a leaked cluster admin credential?
- **Q5.3** — The `promote-dev` job runs `kustomize edit set image` and commits. Is this action **CI** or **CD**? Justify your answer using the definition of each — and explain why this boundary case is exactly what "CI/CD relationship" means.

---

## Block 6 — Promotion across environments: same artifact, different config

Environments should differ in *configuration*, never in *artifact*. You promote by copying a **digest** from one overlay to the next — not by rebuilding.

1. Create a `staging` overlay that reuses the identical base but scales differently:

   ```bash
   cd ~/cnpa-lab/platform-config
   mkdir -p envs/staging
   cat > envs/staging/kustomization.yaml <<'EOF'
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: demo-staging
   resources:
     - ../../base
   replicas:
     - name: web
       count: 4
   images:
     - name: app
       newName: PLACEHOLDER
       digest: PLACEHOLDER
   EOF
   ```

2. **Promote the exact artifact currently in dev** into staging (read dev's pin; write it to staging):

   ```bash
   DEV_IMG=$(kustomize build envs/dev | awk '/image:/{print $2; exit}')
   NAME=${DEV_IMG%@*}; DG=${DEV_IMG#*@}
   cd envs/staging && kustomize edit set image "app=${NAME}@${DG}" && cd ..
   git commit -qam "promote: dev→staging ${DG:0:19}…"
   ```

3. Register a second CD Application for staging (same source repo, different path and namespace):

   ```bash
   sed -e 's/web-dev/web-staging/' \
       -e 's#path: envs/dev#path: envs/staging#' \
       -e 's/namespace: demo-dev/namespace: demo-staging/' \
       /tmp/app-dev.yaml | kubectl apply -f -
   sleep 20
   kubectl -n argocd get applications
   ```

   ```text
   NAME          SYNC STATUS   HEALTH STATUS
   web-dev       Synced        Healthy
   web-staging   Synced        Healthy
   ```

4. Confirm both environments run the **same digest** at **different scale**:

   ```bash
   for ns in demo-dev demo-staging; do
     printf '%-14s ' "$ns"
     kubectl -n $ns get deploy web -o jsonpath='{.spec.replicas} replicas, {..image}{"\n"}'
   done
   ```

   ```text
   demo-dev       2 replicas, ttl.sh/cnpa-7f3c…@sha256:998877665…
   demo-staging   4 replicas, ttl.sh/cnpa-7f3c…@sha256:998877665…
   ```

**Comprehension check — Block 6**

- **Q6.1** — Promotion here copied a *digest string* between two files. Why is this safer and more auditable than a pipeline that runs `docker build` again with a `--target=staging` flag?
- **Q6.2** — The staging overlay differs from dev only in `replicas` and `namespace`. State the general rule this illustrates about what may vary per environment and what must not.
- **Q6.3** — In a real org, step 2's commit would go through a **pull request** instead of a direct commit. What does routing promotion through git's review flow give you that an imperative `kubectl set image --context=staging` cannot?

---

## Block 7 — Failure and rollback: the handoff under fault

A robust CI/CD relationship must fail *visibly* and roll back *cheaply*. You will break the deploy from the CD side, then roll back with a git operation.

1. Push a **bad desired state** — a digest that does not exist:

   ```bash
   cd ~/cnpa-lab/platform-config/envs/dev
   kustomize edit set image "app=${IMG}@sha256:$(printf '0%.0s' {1..64})"
   cd ~/cnpa-lab/platform-config
   git commit -qam "ci: (accidentally) promote a non-existent digest"
   kubectl -n argocd annotate app web-dev argocd.argoproj.io/refresh=hard --overwrite
   sleep 25
   ```

2. Observe how the failure surfaces — CD applied the manifest (it's valid YAML) but the runtime can't honour it:

   ```bash
   kubectl -n argocd get app web-dev -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
   kubectl -n demo-dev get pods -l app=web
   ```

   ```text
   Synced / Degraded
   NAME                   READY   STATUS             RESTARTS   AGE
   web-6f9c7bd5d8-2xk4t   0/1     ImagePullBackOff   0          30s
   ```

3. Note the crucial detail: because the *old* ReplicaSet's Pods are still healthy during a rolling update, your running service was not fully taken down — but the new rollout is stuck and **flagged**, not silent.

4. **Roll back the way GitOps intends** — revert the git commit; CD reconciles the cluster back:

   ```bash
   git revert --no-edit HEAD
   kubectl -n argocd annotate app web-dev argocd.argoproj.io/refresh=hard --overwrite
   sleep 25
   kubectl -n argocd get app web-dev -o jsonpath='{.status.sync.status} / {.status.health.status}{"\n"}'
   ```

   ```text
   Synced / Healthy
   ```

5. Confirm the good digest is restored and audit the trail:

   ```bash
   git log --oneline -3
   ```

   ```text
   c1d2e3f Revert "ci: (accidentally) promote a non-existent digest"
   9a8b7c6 ci: (accidentally) promote a non-existent digest
   b4c7e90 ci: promote web to sha256:998877665…
   ```

**Comprehension check — Block 7**

- **Q7.1** — The Application showed `Synced / Degraded`. Distinguish the two axes: what does **Sync status** measure, and what does **Health status** measure? Why does the CI/CD handoff need *both* signals?
- **Q7.2** — Rollback was a `git revert`, not a console click or a `kubectl rollout undo`. What property of the pull-based model makes "revert the commit" a complete and sufficient rollback?
- **Q7.3** — Suppose CI had *tested nothing* and simply published+promoted whatever compiled. Which of the failures in this block would that have caught, and which one is inherently a **CD-side** concern that no amount of CI testing can prevent? Use this to articulate the precise division of responsibility between CI and CD.

---

## Cleanup

```bash
kill %1 2>/dev/null            # stop the git daemon
kind delete cluster --name cnpa-cicd
rm -rf ~/cnpa-lab
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 0

- **A0.1** — Separating *source* from *config* decouples the two lifecycles that CI and CD own. A source change (new feature) and a deployment change (scale up, rollout to a new environment, rollback) are different events with different reviewers, blast radii, and audit needs. If they share a repo, every config edit re-triggers builds and every code push risks accidental deploys, and the git history stops being a clean deployment ledger. The single concern protected is a **clean, independent trigger boundary** between "what the software *is*" (CI) and "what is *running where*" (CD). This is also what makes the config repo a trustworthy source of truth for CD.

### Block 1

- **A1.1** — A tag is a *mutable pointer*: `:1h` pointed at digest `a1b2c3…` and then at `998877…` after a rebuild, with no visible change to the reference. If CD consumed the tag, "what is deployed" would silently change whenever someone re-pushed the tag, and two environments pinned to the same tag could run different bits. A **digest** (`sha256:…`) is the content address of the exact bytes; it is immutable by construction — a different image *is* a different digest. Handing the digest across the boundary makes the deployed artifact deterministic and verifiable.
- **A1.2** — The three CI responsibilities: (1) **build** the image from source, (2) **test/validate** (implicitly, the build succeeding; in a real pipeline, unit/integration tests), and (3) **publish** the versioned artifact to a registry. **None** of them touched the cluster — CI's output is an artifact in a registry, not a running workload.
- **A1.3** — Rebuilding per environment produces a *different digest* for each, so `prod` would run bytes that were never validated in `dev`/`staging`. You would have tested one artifact and shipped three, defeating the purpose of a promotion pipeline. "Build once, promote everywhere" means a single immutable digest flows unchanged through the environments; only configuration differs.

### Block 2

- **A2.1** — **Kustomize** (a config/deploy-time tool) resolved the `app` placeholder to the real `newName@digest` when rendering the overlay. This resolution belongs at **deploy time / config time**, not build time: the base manifest stays artifact-agnostic, and each environment overlay decides *which* published artifact it runs. The image was already built; config only *selects* it.
- **A2.2** — CI **produces** an immutable, content-addressed artifact (the image at a digest) in a registry. CD **consumes** a declared desired state (git config that references that digest) and makes the cluster match it.
- **A2.3** — Git gives the desired state **version history, atomic commits, review (PRs), attribution, and trivial revert** — it is an auditable ledger of every change to "what should be running." A database/object store can hold the same YAML but lacks the native diff/review/revert semantics that make the deployment history trustworthy and rollbacks a one-command operation. This is the "declarative + versioned" pillar of GitOps (see opengitops.dev).

### Block 3

- **A3.1** — In the push model, **the CI runner / your shell** held cluster write credentials (a kubeconfig with apply rights). At org scale this means every pipeline is a standing credential holding write access to the cluster — a large, distributed attack surface. Compromising any runner compromises the cluster, and credentials must be copied out to every CI system.
- **A3.2** — The push model is missing **continuous reconciliation / drift detection**. Nothing continuously compares declared state (git) to actual state (cluster), so the 5-vs-2 divergence persisted invisibly. Push is a one-shot `apply`; it has no ongoing controller watching for drift.
- **A3.3** — **Push-based**: an external actor (CI) authenticates *into* the cluster and applies changes. **Pull-based**: an agent *inside* the cluster watches a git source and applies changes to its own cluster. Pull-based keeps the cluster's credentials **inside the cluster** — the agent uses in-cluster service-account permissions and nothing outside needs cluster write access.

### Block 4

- **A4.1** — The `Application`'s `source` represents CI's deliverable made declarative — the desired state in git (repo, revision, path). The `destination` represents the runtime — a cluster and namespace. The object *binds source to runtime and turns on reconciliation*, so it literally is the seam where the CI-produced desired state meets the CD-managed cluster; the controller's job is to make destination equal source, continuously.
- **A4.2** — `selfHeal: true` reverts any manual/live divergence back to git's declared state (this is what snapped replicas from 5 to 2). `prune: true` deletes cluster resources that were removed from git, so the cluster never accumulates orphans. Together they enforce *git is the only source of truth*.
- **A4.3** — No — CI needs **no cluster credentials** in this model. The "apply to the cluster" action executes **inside the cluster**, performed by the Argo CD controller using its in-cluster service account. CI's reach stops at the registry and the git repo.

### Block 5

- **A5.1** — (1) Developer `git push` to `app-src` → git hosting fires a webhook. (2) **CI** (`build-and-publish`) builds, tests, and publishes the image, emitting a digest. (3) **CI** (`promote-dev`) writes that digest into `platform-config` and commits/pushes to git. (4) **CD** (Argo CD controller, in-cluster) detects the new git revision, renders the overlay, and applies it. (5) **Kubernetes** creates a new ReplicaSet/Pods running the digest. Trigger flows source→CI→git→CD→cluster; only CD writes to the cluster.
- **A5.2** — The pull model deliberately scopes CI's authority to *writing git*, nothing more. A leaked `CONFIG_REPO_PAT` lets an attacker propose bad desired state — but it still passes through git review, CD policy, and reconciliation, and is revertible; the blast radius is "can open a bad commit." A leaked **cluster admin credential** is immediate, total control of the runtime (exfiltrate secrets, run workloads, delete namespaces) with no git checkpoint. Minimising what CI can touch is the security payoff of the whole design.
- **A5.3** — It is the **CI side of the boundary**: `promote-dev` is still the *build/publish* system acting — its final act is to *hand off* by recording the artifact selection in git. It is emphatically **not** CD, because CD is the reconciler that reads git and changes the cluster. This is precisely the "CI/CD relationship": CI's terminal responsibility is to *publish desired state*; CD's opening responsibility is to *consume it*. The commit is the handshake — the exact point where one system's output becomes the other's input.

### Block 6

- **A6.1** — Copying a digest promotes the *identical, already-tested bytes*; there is zero chance staging runs something dev never saw, and the git diff is a one-line, human-auditable record of exactly which artifact moved. Re-running `docker build` for staging produces a *new, unvalidated digest*, reintroduces build-environment nondeterminism, and leaves no guarantee that staging == dev. Promotion should move a reference, never rebuild the artifact.
- **A6.2** — **Only configuration may vary per environment** (replicas, resource limits, namespaces, hostnames, feature flags, config/secrets). **The artifact (image digest) must not vary.** Environments are differentiated by config layered over one immutable build.
- **A6.3** — Routing promotion through a PR gives **review, approval gates, an audit trail, and CI-on-the-config (policy checks, manifest validation) before it merges** — plus a natural revert point. An imperative `kubectl set image` against staging is unreviewed, unrecorded in git, and creates drift the moment it runs; the cluster no longer matches the source of truth.

### Block 7

- **A7.1** — **Sync status** measures whether the cluster's live objects match git's declared desired state (did CD successfully apply what git says?). **Health status** measures whether those objects are actually working at runtime (are Pods Ready, is the rollout progressing?). Here it was `Synced` (the manifest *was* applied — the YAML was valid) but `Degraded` (Pods can't pull the fake digest). Both signals are needed because the handoff can succeed *declaratively* while failing *operationally*; watching only sync would report a green deploy over a broken app.
- **A7.2** — Because git is the single source of truth and the in-cluster controller continuously reconciles the cluster *to* git, restoring a previous git state is a *complete* rollback — the controller drives the cluster back automatically. State is not held in an imperative history on the cluster; it is held in git, so `git revert` is both the record *and* the mechanism of rollback.
- **A7.3** — Stronger CI testing (unit/integration/security scans on the artifact) would have caught application-level defects *inside* the image. It could **not** have caught the `ImagePullBackOff`, because that stems from a **desired-state / deploy-time** error — a config pointing at a non-existent digest — which is inherently a **CD-side** concern surfaced by reconciliation and health checks. Division of responsibility: **CI validates the artifact is good**; **CD validates the desired state is applyable and the runtime is healthy**. Neither substitutes for the other, which is exactly why CI and CD are distinct but tightly integrated stages.

</details>

---

**Sources**

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenGitOps Principles (declarative, versioned/immutable, pulled, continuously reconciled) — https://opengitops.dev/
- Argo CD — Application spec, sync policy, self-heal/prune — https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- Argo CD — Application health & sync status — https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
- Kustomize — `images` transformer and `kustomize edit set image` — https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/
- Kubernetes — image pull policy and identifying images by digest — https://kubernetes.io/docs/concepts/containers/images/
- GitHub Actions — workflow syntax and job outputs — https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions
- ttl.sh — anonymous & ephemeral container image registry — https://ttl.sh/