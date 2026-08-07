# Topic 3.3 — Continuous Integration Pipelines: Overview and Architecture

Guided, hands-on exercises. You run each numbered step, then answer the checkpoint questions before moving on. Solutions are in the collapsible section at the end.

The lab builds a **container-native CI pipeline** on Kubernetes with **Tekton** (a CNCF project), because it exposes every architectural primitive of a CI system as an inspectable API object — Steps, Tasks, a DAG of Tasks, event triggers, and workspaces — instead of hiding them inside a managed runner. Everything you learn maps directly onto GitHub Actions, GitLab CI, or Argo Workflows.

## Prerequisites

- A Linux/macOS host with `docker`, `kubectl`, `git`, and `curl`.
- `kind` v0.20+ (a throwaway Kubernetes cluster).
- `tkn`, the Tekton CLI (`brew install tektoncd-cli` or download from the [releases page](https://github.com/tektoncd/cli/releases)).
- `cosign` (`brew install cosign` or from [Sigstore releases](https://github.com/sigstore/cosign/releases)).

Sources you should keep open:
- Tekton Pipelines — https://tekton.dev/docs/pipelines/
- Tekton Triggers — https://tekton.dev/docs/triggers/
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- SLSA (supply-chain levels) — https://slsa.dev/spec/v1.0/levels
- CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf

---

## Exercise 0 — Stand up the CI control plane

A CI system is itself a distributed application: a **controller** that watches for pipeline objects and schedules **workloads** (each pipeline step runs as a container). You will install that control plane and a local registry that acts as the **artifact store**.

1. Create the cluster with a node port mapped so an in-cluster registry is reachable from your host:

   ```bash
   cat <<'EOF' | kind create cluster --name cnpa-ci --config=-
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   containerdConfigPatches:
     - |-
       [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5001"]
         endpoint = ["http://kind-registry:5000"]
   EOF
   ```

2. Run a local registry container and join it to the cluster network:

   ```bash
   docker run -d --restart=always -p 127.0.0.1:5001:5000 --name kind-registry registry:2
   docker network connect kind cnpa-ci-control-plane 2>/dev/null || true
   docker network connect kind kind-registry 2>/dev/null || true
   ```

3. Install the Tekton Pipelines controller and wait for it:

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
   kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=180s
   ```

4. Confirm the control plane is running:

   ```bash
   kubectl get pods -n tekton-pipelines
   ```

   Expected output (names will differ by hash):

   ```
   NAME                                           READY   STATUS    RESTARTS   AGE
   tekton-pipelines-controller-6d9c9f7b4b-2xr7n   1/1     Running   0          52s
   tekton-pipelines-webhook-7f6c8d5c9c-h9v8k      1/1     Running   0          52s
   ```

**Checkpoint 0**
- **Q0.1** — The `tekton-pipelines-controller` and `tekton-pipelines-webhook` are long-lived Deployments, but the containers that run your build steps are not. What is that execution model called, and why is it the default for cloud-native CI rather than a pool of persistent build servers?
- **Q0.2** — You mapped a registry at `localhost:5001`. In CI-pipeline architecture terms, what role does this component play, and why is it drawn *outside* the pipeline's execution stages in most reference diagrams?

---

## Exercise 1 — Pipeline-as-code: the Step and the Task

The smallest unit of work is a **Step** (one container). A **Task** is an ordered list of Steps that share a pod and a filesystem. This is where "a build stage" actually lives.

1. Create a Task that clones a repository into a shared workspace. Save as `task-git-clone.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: git-clone
   spec:
     params:
       - name: url
         type: string
       - name: revision
         type: string
         default: "main"
     workspaces:
       - name: source
         description: Where the cloned tree is written
     results:
       - name: commit
         description: The resolved commit SHA
     steps:
       - name: clone
         image: alpine/git:2.45.2
         script: |
           #!/bin/sh
           set -eu
           cd "$(workspaces.source.path)"
           git clone --depth 1 --branch "$(params.revision)" "$(params.url)" .
           git rev-parse HEAD | tr -d '\n' > "$(results.commit.path)"
   ```

2. Create a second Task that runs the project's tests. Save as `task-unit-test.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: unit-test
   spec:
     workspaces:
       - name: source
     steps:
       - name: test
         image: golang:1.22-alpine
         workingDir: $(workspaces.source.path)
         script: |
           #!/bin/sh
           set -eu
           go vet ./... && echo "vet OK"
           go test ./... || echo "no test targets"
   ```

3. Apply both and list them:

   ```bash
   kubectl apply -f task-git-clone.yaml -f task-unit-test.yaml
   tkn task list
   ```

   Expected output:

   ```
   NAME         DESCRIPTION   AGE
   git-clone                  6 seconds ago
   unit-test                  6 seconds ago
   ```

4. Run the clone Task alone, giving it an ephemeral workspace backed by an `emptyDir`:

   ```bash
   tkn task start git-clone \
     --param url=https://github.com/vfarcic/silly-demo \
     --param revision=master \
     --workspace name=source,emptyDir="" \
     --showlog
   ```

   Expected tail of output:

   ```
   [clone] Cloning into '.'...
   TaskRun started: git-clone-run-abc12
   Waiting for logs to be available...
   ...
   TaskRun git-clone-run-abc12 completed successfully
   ```

5. Inspect the object the CLI actually created and where the result was captured:

   ```bash
   tkn taskrun describe --last | grep -A2 "Results"
   ```

**Checkpoint 1**
- **Q1.1** — All Steps in a Task share one pod and one filesystem, but each Step is a separate container image (`alpine/git`, then `golang`). What does that tell you about how a Task moves data *between* Steps versus how a Pipeline must move data *between* Tasks?
- **Q1.2** — The clone Task writes the commit SHA to `$(results.commit.path)`. Why does a CI system need first-class, typed **results** rather than having you `echo` the SHA into a log line and grep it later?
- **Q1.3** — You backed the workspace with `emptyDir`. That data vanishes when the pod ends. Which class of CI workloads breaks under `emptyDir`, and what workspace backing would you choose for them?

---

## Exercise 2 — Composing the stages into a DAG

A **Pipeline** wires Tasks into a directed acyclic graph. Order comes from data dependencies (`runAfter`, or a Task consuming another's result), not from top-to-bottom text order — this is what lets a CI engine parallelize independent stages.

1. Add a build Task using Kaniko (daemonless in-cluster image build). Save as `task-build.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: build-image
   spec:
     params:
       - name: image
         type: string
     workspaces:
       - name: source
     results:
       - name: digest
         description: The pushed image digest
     steps:
       - name: build-and-push
         image: gcr.io/kaniko-project/executor:v1.23.2
         args:
           - --dockerfile=Dockerfile
           - --context=dir://$(workspaces.source.path)
           - --destination=$(params.image)
           - --digest-file=$(results.digest.path)
           - --insecure          # local registry over HTTP
           - --insecure-pull
   ```

2. Define the Pipeline. Note that `unit-test` and `build-image` both only depend on `clone`, so they may run **in parallel**. Save as `pipeline-ci.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Pipeline
   metadata:
     name: ci
   spec:
     params:
       - name: repo-url
       - name: image
     workspaces:
       - name: shared
     tasks:
       - name: clone
         taskRef:
           name: git-clone
         params:
           - name: url
             value: $(params.repo-url)
           - name: revision
             value: master
         workspaces:
           - name: source
             workspace: shared
       - name: test
         runAfter: ["clone"]
         taskRef:
           name: unit-test
         workspaces:
           - name: source
             workspace: shared
       - name: build
         runAfter: ["clone"]
         taskRef:
           name: build-image
         params:
           - name: image
             value: $(params.image)
         workspaces:
           - name: source
             workspace: shared
   ```

3. Apply and start the Pipeline, backing the shared workspace with a real PersistentVolumeClaim so both parallel Tasks see the same clone:

   ```bash
   kubectl apply -f task-build.yaml -f pipeline-ci.yaml

   tkn pipeline start ci \
     --param repo-url=https://github.com/vfarcic/silly-demo \
     --param image=localhost:5001/silly-demo:0.0.1 \
     --workspace name=shared,volumeClaimTemplateFile=<(cat <<'EOF'
   spec:
     accessModes: ["ReadWriteOnce"]
     resources:
       requests:
         storage: 1Gi
   EOF
   ) \
     --showlog
   ```

4. In a second terminal, watch the DAG resolve:

   ```bash
   tkn pipelinerun describe --last
   ```

   Expected (abridged) output:

   ```
   Status
   STARTED   DURATION   STATUS
   40s ago   ---        Running

   Taskruns
   NAME             TASK NAME   STARTED   DURATION   STATUS
   ci-run-.-build   build       25s ago   ---        Running
   ci-run-.-test    test        25s ago   ---        Running
   ci-run-.-clone   clone       40s ago   15s        Succeeded
   ```

5. When it finishes, confirm the artifact landed in the store:

   ```bash
   curl -s http://localhost:5001/v2/silly-demo/tags/list
   ```

   Expected output:

   ```json
   {"name":"silly-demo","tags":["0.0.1"]}
   ```

**Checkpoint 2**
- **Q2.1** — `test` and `build` both declare `runAfter: ["clone"]` and nothing else. What does the engine do with them, and what single word describes why `clone` had to finish first?
- **Q2.2** — Both parallel Tasks mount the same `ReadWriteOnce` PVC. On a multi-node cluster this can wedge one Task in `Pending`. Explain the failure and name two architectural fixes a platform team would offer as a golden path.
- **Q2.3** — Suppose `test` fails. With this Pipeline as written, does `build` still run, and does the artifact still get pushed? What does that imply about where you should place a **quality gate** so a broken commit never produces a published artifact?

---

## Exercise 3 — The event-driven front door (Triggers)

So far you started runs by hand. Real CI is **event-driven**: a git push hits a webhook, which is authenticated, parsed, and turned into a PipelineRun. Tekton Triggers splits this into three objects — a `TriggerBinding` (extract fields from the payload), a `TriggerTemplate` (the run to create), and an `EventListener` (the HTTP endpoint + interceptors).

1. Install Triggers and its interceptors:

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
   kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=180s
   ```

2. Create a ServiceAccount + RBAC so the listener may create PipelineRuns. Save as `trigger-rbac.yaml`:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: ci-triggers
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: ci-triggers-binding
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: tekton-triggers-eventlistener-roles
   subjects:
     - kind: ServiceAccount
       name: ci-triggers
   ```

3. Define the binding, template, and listener. Save as `trigger.yaml`:

   ```yaml
   apiVersion: triggers.tekton.dev/v1beta1
   kind: TriggerBinding
   metadata:
     name: github-push
   spec:
     params:
       - name: repo-url
         value: $(body.repository.clone_url)
       - name: revision
         value: $(body.after)
   ---
   apiVersion: triggers.tekton.dev/v1beta1
   kind: TriggerTemplate
   metadata:
     name: ci-template
   spec:
     params:
       - name: repo-url
       - name: revision
     resourcetemplates:
       - apiVersion: tekton.dev/v1
         kind: PipelineRun
         metadata:
           generateName: ci-run-
         spec:
           pipelineRef:
             name: ci
           params:
             - name: repo-url
               value: $(tt.params.repo-url)
             - name: image
               value: localhost:5001/silly-demo:$(tt.params.revision)
           workspaces:
             - name: shared
               volumeClaimTemplate:
                 spec:
                   accessModes: ["ReadWriteOnce"]
                   resources:
                     requests:
                       storage: 1Gi
   ---
   apiVersion: triggers.tekton.dev/v1beta1
   kind: EventListener
   metadata:
     name: github-listener
   spec:
     serviceAccountName: ci-triggers
     triggers:
       - name: on-push
         interceptors:
           - ref:
               name: "github"
             params:
               - name: "secretRef"
                 value:
                   secretName: github-webhook-secret
                   secretKey: token
               - name: "eventTypes"
                 value: ["push"]
         bindings:
           - ref: github-push
         template:
           ref: ci-template
   ```

4. Create the shared-secret the interceptor validates, then apply everything:

   ```bash
   kubectl create secret generic github-webhook-secret --from-literal=token=s3cr3t
   kubectl apply -f trigger-rbac.yaml -f trigger.yaml
   kubectl get eventlistener github-listener
   ```

   Expected output:

   ```
   NAME              ADDRESS                                                    AVAILABLE   READY
   github-listener   http://el-github-listener.default.svc.cluster.local:8080   True        True
   ```

5. Simulate a signed GitHub push. Port-forward the listener, compute the HMAC the way GitHub does, and POST a minimal payload:

   ```bash
   kubectl port-forward svc/el-github-listener 8080:8080 >/dev/null 2>&1 &

   BODY='{"after":"deadbeefcafe","repository":{"clone_url":"https://github.com/vfarcic/silly-demo"}}'
   SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac 's3cr3t' | awk '{print $2}')"

   curl -s -X POST http://localhost:8080 \
     -H 'Content-Type: application/json' \
     -H 'X-GitHub-Event: push' \
     -H "X-Hub-Signature-256: $SIG" \
     -d "$BODY"
   ```

   Expected output:

   ```json
   {"eventListener":"github-listener","namespace":"default","eventListenerUID":"...","eventID":"a1b2c3"}
   ```

6. Confirm the event created a run automatically:

   ```bash
   tkn pipelinerun list
   ```

   Expected output:

   ```
   NAME           STARTED        DURATION   STATUS
   ci-run-x9k2f   4 seconds ago  ---        Running
   ```

7. Now prove the security boundary works — resend with a wrong signature:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080 \
     -H 'Content-Type: application/json' \
     -H 'X-GitHub-Event: push' \
     -H 'X-Hub-Signature-256: sha256=deadbeef' \
     -d "$BODY"
   ```

   Expected output:

   ```
   401
   ```

**Checkpoint 3**
- **Q3.1** — Trace one push event through the four object types (EventListener → interceptor → TriggerBinding → TriggerTemplate). State the single job of each, in order.
- **Q3.2** — The `github` interceptor rejected the tampered request with `401` *before* any Task ran. Why is validating the HMAC at the front door — rather than inside the pipeline — an architectural requirement and not just an optimization?
- **Q3.3** — The EventListener runs under the `ci-triggers` ServiceAccount, whose RoleBinding only grants the `eventlistener-roles` ClusterRole. Why is it deliberately *not* granted `cluster-admin`, given that this endpoint is reachable from the internet?
- **Q3.4** — The `TriggerTemplate` uses `generateName: ci-run-` rather than a fixed `name`. What would break on the second push if it used a fixed name, and what property of CI runs does `generateName` preserve?

---

## Exercise 4 — Hardening the pipeline: sign the artifact in CI

A modern CI pipeline does not just produce a binary — it produces **verifiable provenance**. You will sign the image you built and attach a signature to the registry, so a downstream CD/GitOps controller can *refuse* unsigned images. This is the CI half of software-supply-chain security (SLSA).

1. Generate a signing key pair (in real CI this is keyless — see the checkpoint):

   ```bash
   COSIGN_PASSWORD="" cosign generate-key-pair
   ```

   Expected output:

   ```
   Private key written to cosign.key
   Public key written to cosign.pub
   ```

2. Sign the image you pushed in Exercise 2, addressing it **by digest** (never by tag):

   ```bash
   DIGEST=$(curl -s http://localhost:5001/v2/silly-demo/manifests/0.0.1 \
     -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' -I \
     | awk -F': ' '/docker-content-digest/{print $2}' | tr -d '\r')

   COSIGN_PASSWORD="" cosign sign --key cosign.key --tlog-upload=false \
     --allow-insecure-registry localhost:5001/silly-demo@$DIGEST
   ```

   Expected tail:

   ```
   Pushing signature to: localhost:5001/silly-demo
   ```

3. Verify the signature the way an admission controller would:

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog=true \
     --allow-insecure-registry localhost:5001/silly-demo@$DIGEST
   ```

   Expected output (abridged JSON):

   ```
   Verification for localhost:5001/silly-demo@sha256:... --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - The signatures were verified against the specified public key
   [{"critical":{"identity":{"docker-reference":"localhost:5001/silly-demo"},...}}]
   ```

4. Prove the negative case — tamper detection — by verifying a digest you never signed:

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog=true \
     --allow-insecure-registry \
     localhost:5001/silly-demo@sha256:0000000000000000000000000000000000000000000000000000000000000000
   ```

   Expected output:

   ```
   Error: no signatures found for image
   ```

**Checkpoint 4**
- **Q4.1** — You signed `silly-demo@sha256:...`, not `silly-demo:0.0.1`. Why does signing (and later admission) address the image **by digest** rather than by tag, and what attack does the tag form leave open?
- **Q4.2** — In production CI (e.g. GitHub Actions), `cosign` is used in *keyless* mode: no `cosign.key` file exists. Where does the signing identity come from instead, and why is that model strictly better than a long-lived private key sitting in a CI secret?
- **Q4.3** — The signature and its transparency-log entry (Rekor) are produced during **CI**, but they are consumed during **CD/admission**. Explain why signing belongs in the CI stage that built the artifact and cannot be safely deferred to the deployment stage.
- **Q4.4** — Map the four exercises to a SLSA build level intuition: which single step above moves you from "an artifact exists" to "an artifact whose origin can be independently verified"?

---

## Cleanup

```bash
kind delete cluster --name cnpa-ci
docker rm -f kind-registry
rm -f cosign.key cosign.pub
```

---

<details>
<summary><strong>Solutions</strong></summary>

### Exercise 0

**A0.1** — The build containers are **ephemeral executors**: each Step runs in a fresh container that is created for one run and destroyed after. It is the default because (a) **isolation/reproducibility** — no state leaks between builds, so "works because the last build left a file behind" is impossible; (b) **elasticity** — the scheduler packs runs onto whatever nodes exist and scales to zero when idle, versus paying for an always-on server farm; (c) **security** — a compromised build cannot persist, since the sandbox is torn down. Persistent build servers ("snowflake" runners) accumulate drift and are a supply-chain liability.

**A0.2** — The local registry is the **artifact store / artifact repository**. It is drawn outside the execution stages because it is a *stateful, shared* service with its own lifecycle: pipelines are ephemeral and stateless, but the artifacts they produce must outlive any single run so later stages (scan, sign, deploy) and later pipelines can retrieve them by digest. Coupling artifact storage to a runner's disk would lose the artifact when the runner dies.

### Exercise 1

**A1.1** — Inside a Task, Steps share one pod and one filesystem, so data passes between Steps **implicitly** — Step 2 just reads the files Step 1 wrote. Across Tasks there is no shared pod, so a Pipeline must move data **explicitly**: through a shared **workspace** (a mounted volume) for bulk data, or through typed **results** for small values. This is the core reason a Pipeline needs first-class workspace/result plumbing while a Task does not.

**A1.2** — Typed results are part of the object's status, addressable as `$(tasks.clone.results.commit)`, so downstream Tasks can *consume* them declaratively and the engine treats that consumption as a data dependency (which also orders the DAG). Grepping a log is brittle (format changes break it), unstructured (no schema/validation), and invisible to the scheduler (it cannot infer ordering from a log line). Results make inter-stage data a contract, not a side effect.

**A1.3** — Any workload that must **persist or share state across pods** breaks under `emptyDir`: a multi-Task Pipeline where a later Task on a different pod needs the cloned tree, or build **caches** (Go module cache, npm cache, Docker layer cache) you want reused across runs. Choose a **PersistentVolumeClaim** (`volumeClaimTemplate` for per-run, or a named PVC for a cache shared across runs). `emptyDir` is fine only for scratch space inside a single Task.

### Exercise 2

**A2.1** — The engine runs `test` and `build` **concurrently**, because neither depends on the other — only on `clone`. The single word is **dependency** (a data/ordering dependency): `clone` produces the source tree both consume, so it is their common predecessor in the DAG. Parallelizing independent branches is the whole point of expressing CI as a DAG rather than a script.

**A2.2** — A `ReadWriteOnce` PVC can be mounted read-write by **one node** at a time. If the scheduler places `test` and `build` pods on different nodes, the second pod's volume attach cannot complete and it sits in `Pending` (or `ContainerCreating`) forever. Fixes a platform team offers: (1) a **`ReadWriteMany`** storage class (e.g. NFS/CephFS) so multiple nodes can mount it; (2) constrain the parallel Tasks to **co-locate on one node** (affinity / the Tekton "Affinity Assistant"); (3) avoid the shared mount entirely — have `clone` push the source as a workspace result the others pull independently. Any of these becomes a golden-path template so app teams never hit the raw failure.

**A2.3** — As written, `build` only declares `runAfter: ["clone"]`, so **it runs regardless of whether `test` passes** — and pushes the artifact even on a failing test. That is the anti-pattern. The quality gate must sit **upstream of the artifact-producing step**: make `build` depend on `test` (`runAfter: ["clone","test"]`), so a failed `test` fails the DAG before `build` ever executes. A gate placed after the push cannot un-publish a bad artifact.

### Exercise 3

**A3.1** — In order: (1) **EventListener** — the HTTP endpoint (a Deployment + Service) that receives the webhook POST. (2) **Interceptor** — validates/authenticates the request (HMAC check) and filters by event type, rejecting anything that fails *before* work is created. (3) **TriggerBinding** — extracts fields from the JSON body (`repo-url`, `revision`) into named params. (4) **TriggerTemplate** — the parameterized blueprint that is instantiated into a concrete PipelineRun using those params.

**A3.2** — The endpoint is internet-reachable, so anyone can POST to it. If validation happened *inside* the pipeline, an attacker's forged payload would already have caused the engine to schedule pods, mount volumes, and pull images — i.e. arbitrary, attacker-triggered compute (a DoS and a code-execution surface). Rejecting at the interceptor means an unauthenticated request consumes essentially nothing. Authentication must gate **admission of the event**, not the outcome of the work.

**A3.3** — This is **least privilege** applied to an internet-facing component. The listener only ever needs to create the specific resources in the TriggerTemplate (PipelineRuns and their dependencies) in its own namespace — exactly what `tekton-triggers-eventlistener-roles` grants. If it held `cluster-admin`, a single request-forgery or interceptor bypass would escalate from "trigger a build" to "own the cluster." The blast radius of the most-exposed endpoint must be the smallest.

**A3.4** — With a fixed `name`, the second push would try to create a PipelineRun with a name that already exists and fail with `AlreadyExists`, so only the first event would ever run. `generateName` gives every event a **unique, immutable run** — preserving the property that each CI run is a distinct, independently traceable, non-overwriting record of one commit.

### Exercise 4

**A4.1** — A **tag is mutable**: `:0.0.1` can be re-pushed to point at a different image, so a signature bound to the tag could later apply to content the signer never saw (a tag-swap / TOCTOU attack). A **digest** is the content hash — it names exactly the bytes that were signed and cannot be repointed. Signing and admitting by digest closes the window where the thing you verified differs from the thing you run.

**A4.2** — Keyless signing derives identity from a short-lived **OIDC token** that the CI platform issues to the running job (e.g. GitHub Actions' workload identity). `cosign` exchanges it with **Fulcio** for a short-lived certificate, signs, and records the signature in the **Rekor** transparency log. It is strictly better because there is no long-lived private key to steal, rotate, or leak from a CI secret; the signer's identity is the *pipeline itself* (repo + workflow + trigger), which is verifiable and non-transferable, and every signature is publicly logged and tamper-evident.

**A4.3** — The signature must attest to *what was built and by which build*. Only the CI stage that produced the artifact holds the trustworthy build context (source commit, builder identity, materials) at the moment of creation. Deferring signing to CD would sign an artifact the deployment stage merely *received* — it can no longer prove origin, and it opens a gap between build and sign where an artifact could be swapped. Signing at build time makes provenance a property of creation, not of transport.

**A4.4** — **Exercise 4's signing step.** Exercises 1–3 produce and publish an artifact (it *exists* and is reproducible), but nothing binds it to a verifiable origin. Attaching a signature (and, in production, keyless provenance + Rekor entry) is what lets a *different* party — a CD/admission controller — independently verify who built it and that it was not altered, which is the leap SLSA is about (from "an artifact" to "an artifact with attested provenance").

</details>