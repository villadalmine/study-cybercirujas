# CNPA — Topic 3.1: Continuous Integration Fundamentals and Best Practices

## Guided Hands-On Exercises

> **Scope.** These labs build a complete, cloud-native Continuous Integration pipeline the way a platform team would ship it as a *paved road*: pipeline-as-code, ephemeral and reproducible build environments, build-once/promote-everywhere artifacts, shift-left testing, and supply-chain attestations. The engine is **Tekton** (the CNCF-graduated, Kubernetes-native CI/CD primitive set), because CNPA tests your ability to reason about CI *on a platform*, not the syntax of one SaaS runner.
>
> **Estimated time:** 90–120 min. **Cost:** \$0 — everything runs on a local `kind` cluster and the anonymous `ttl.sh` ephemeral registry.

---

### Exercise 0 — Provision the CI control plane

**Goal:** stand up a disposable cluster and install Tekton Pipelines + the `tkn` CLI. This *is* a CI lesson: your build infrastructure should itself be declarative and reproducible.

1. Create a throwaway cluster:

   ```bash
   kind create cluster --name cnpa-ci
   ```
   ```
   Creating cluster "cnpa-ci" ...
    ✓ Ensuring node image (kindest/node:v1.31.0)
    ✓ Preparing nodes
    ✓ Writing configuration
    ✓ Starting control-plane
   Set kubectl context to "kind-cnpa-ci"
   ```

2. Install Tekton Pipelines (pinned, not `latest` — reproducibility applies to your tooling too):

   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.65.0/release.yaml
   ```

3. Wait for the control plane to be ready:

   ```bash
   kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=180s
   kubectl get pods -n tekton-pipelines
   ```
   ```
   NAME                                                 READY   STATUS    RESTARTS   AGE
   tekton-pipelines-controller-6d9c9b8f9c-4wq2t         1/1     Running   0          72s
   tekton-pipelines-webhook-7c8b6d5f7d-mrl8x            1/1     Running   0          72s
   ```

4. Install the `tkn` CLI and confirm it talks to the cluster:

   ```bash
   tkn version
   ```
   ```
   Client version: 0.38.1
   Pipeline version: v0.65.0
   ```

5. Import the reusable `git-clone` Task from the Tekton catalog. Reusing a vetted, versioned Task instead of hand-rolling a clone step is the first best practice — *don't reinvent shared steps*:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.9/git-clone.yaml
   tkn task list
   ```
   ```
   NAME         DESCRIPTION              AGE
   git-clone    These Tasks are Git...   6s
   ```

**Comprehension checks (0):**

- **0a.** Why did we pin Tekton to `v0.65.0` instead of applying the `latest` release manifest, even for a throwaway cluster?
- **0b.** A Tekton `Task` runs each `step` as a container in a single pod, and each `TaskRun`/`PipelineRun` gets its own pod that is deleted afterward. Which two CI best practices does this pod-per-run model enforce *by construction*?

---

### Exercise 1 — A first CI Task: fast, fail-fast feedback

**Goal:** author a pipeline-as-code Task that clones, lints, and unit-tests a repo, and observe fail-fast behavior. The whole point of CI is *short feedback loops on every commit*.

1. Create a Task file `lint-test.yaml`:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: lint-and-test
   spec:
     description: Vet, lint and unit-test a Go module. Fails fast on the first failing gate.
     workspaces:
       - name: source
         description: Checked-out source tree
     results:
       - name: test-summary
         description: Human-readable pass/fail summary
     steps:
       - name: vet
         image: golang:1.23-alpine
         workingDir: $(workspaces.source.path)
         script: |
           #!/usr/bin/env sh
           set -euo pipefail
           go vet ./...
       - name: unit-test
         image: golang:1.23-alpine
         workingDir: $(workspaces.source.path)
         script: |
           #!/usr/bin/env sh
           set -euo pipefail
           go test -race -covermode=atomic -coverprofile=cover.out ./...
           pct=$(go tool cover -func=cover.out | awk '/^total:/ {print $3}')
           printf 'coverage=%s' "$pct" | tee $(results.test-summary.path)
   ```

2. Apply it and create a `Pipeline` that chains a clone into the test Task:

   ```yaml
   # ci-pipeline.yaml
   apiVersion: tekton.dev/v1
   kind: Pipeline
   metadata:
     name: ci
   spec:
     params:
       - name: repo-url
         type: string
       - name: revision
         type: string
         default: main
     workspaces:
       - name: shared
     tasks:
       - name: fetch
         taskRef:
           name: git-clone
         params:
           - name: url
             value: $(params.repo-url)
           - name: revision
             value: $(params.revision)
         workspaces:
           - name: output
             workspace: shared
       - name: verify
         runAfter: [fetch]
         taskRef:
           name: lint-and-test
         workspaces:
           - name: source
             workspace: shared
   ```

   ```bash
   kubectl apply -f lint-test.yaml -f ci-pipeline.yaml
   ```

3. Trigger a `PipelineRun`. A `volumeClaimTemplate` gives this run its own ephemeral PVC — an isolated, disposable workspace:

   ```bash
   tkn pipeline start ci \
     --param repo-url=https://github.com/GoogleCloudPlatform/microservices-demo \
     --param revision=main \
     --workspace name=shared,volumeClaimTemplateFile=<(cat <<'EOF'
   spec:
     accessModes: [ReadWriteOnce]
     resources:
       requests:
         storage: 1Gi
   EOF
   ) \
     --showlog
   ```

4. Read the results and the run status:

   ```bash
   tkn pipelinerun describe --last | sed -n '1,20p'
   ```
   ```
   Name:              ci-run-abc12
   Status:            Succeeded
   ⚓ Params
    NAME       VALUE
    repo-url   https://github.com/.../microservices-demo
   📝 Results
    NAME           VALUE
    test-summary   coverage=71.4%
   ```

5. Now *break* the build on purpose to watch fail-fast: edit `lint-and-test` so the `vet` step runs `go vet ./... && exit 3`, re-apply, and re-run. Observe:

   ```bash
   tkn pipelinerun describe --last | grep -A4 'Taskruns'
   ```
   ```
   NAME                    TASK RUN            STATUS
   ci-run-def34-verify     ...-verify-pod      Failed(Exit code 3)
   ```

   The `unit-test` step never executes — steps in a Task are sequential and the first non-zero exit aborts the rest.

**Comprehension checks (1):**

- **1a.** `git-clone` and `lint-and-test` share data through the `shared` workspace, yet they run in *separate pods*. What mechanism makes the checked-out code visible to the second Task, and what does that imply for `accessModes: ReadWriteOnce` on a multi-node cluster?
- **1b.** We ordered `verify` with `runAfter: [fetch]` and put `vet` before `unit-test`. A colleague proposes running `vet` and `unit-test` as two separate *parallel* Tasks to save time. What is the trade-off between fail-fast cost-savings and total-signal for that change?
- **1c.** Why publish coverage as a Tekton `result` rather than just printing it to the log?

---

### Exercise 2 — Build once, promote everywhere: immutable, reproducible images

**Goal:** build a container image *in-cluster* without a Docker daemon (no privileged socket) using **Kaniko**, and pin the artifact by **digest**, not tag. "Build once, promote the same binary through environments" is the cornerstone artifact discipline of CI.

1. Add a build Task `build.yaml` that emits the image **digest** as a result:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: kaniko-build
   spec:
     params:
       - name: image
         type: string
       - name: dockerfile
         type: string
         default: ./Dockerfile
     workspaces:
       - name: source
     results:
       - name: image-digest
         description: The sha256 digest of the image that was pushed
     steps:
       - name: build-and-push
         image: gcr.io/kaniko-project/executor:v1.23.2
         workingDir: $(workspaces.source.path)
         args:
           - --dockerfile=$(params.dockerfile)
           - --context=$(workspaces.source.path)
           - --destination=$(params.image)
           - --digest-file=$(results.image-digest.path)
           - --reproducible
           - --cache=true
   ```

2. Add the build to the Pipeline `spec.tasks`, ordered after the tests, and expose the digest as a Pipeline result:

   ```yaml
       - name: build
         runAfter: [verify]
         taskRef:
           name: kaniko-build
         params:
           - name: image
             value: $(params.image)
         workspaces:
           - name: source
             workspace: shared
   # ...
     results:
       - name: image
         value: $(params.image)@$(tasks.build.results.image-digest)
   ```
   Add `- name: image` to `spec.params`.

3. Re-apply and run, pushing to the anonymous ephemeral registry `ttl.sh` (public, auth-free, images expire after the TTL in the tag):

   ```bash
   IMG=ttl.sh/cnpa-$(uuidgen | tr 'A-Z' 'a-z'):1h
   tkn pipeline start ci \
     --param repo-url=https://github.com/GoogleCloudPlatform/microservices-demo \
     --param image="$IMG/cartservice/src" \
     --workspace name=shared,volumeClaimTemplateFile=... \
     --showlog
   ```

4. Read the immutable, digest-pinned reference back out:

   ```bash
   tkn pipelinerun describe --last -o jsonpath='{.status.results[?(@.name=="image")].value}'
   ```
   ```
   ttl.sh/cnpa-9f3a...:1h/cartservice/src@sha256:1b2c3d4e5f6a...
   ```

5. Prove reproducibility: run the same build twice and compare digests. With `--reproducible` (which zeroes file timestamps in layers), identical source yields an identical digest:

   ```bash
   crane digest "$IMG/cartservice/src"   # run 1
   crane digest "$IMG/cartservice/src"   # run 2  -> same sha256
   ```

**Comprehension checks (2):**

- **2a.** Kaniko builds an OCI image *inside an unprivileged container* with no Docker daemon and no `--privileged` socket mount. Why is eliminating the Docker socket from CI runners a security best practice, and what class of attack does it remove?
- **2b.** The Pipeline result is `image@sha256:...`, not `image:1h`. Give two concrete failures that "promote by tag" causes downstream that "promote by digest" prevents.
- **2c.** What does `--reproducible` actually change in the output layers, and why does non-reproducible build metadata (timestamps, file ordering) defeat layer caching and artifact deduplication?

---

### Exercise 3 — Best practices: parallelism, caching, and `finally`

**Goal:** shape the pipeline for speed and reliability — run independent gates in parallel, cache dependencies across runs, and guarantee cleanup/notification with `finally`.

1. Split verification into two independent Tasks that both `runAfter: [fetch]` (no `runAfter` between them ⇒ they run **in parallel**):

   ```yaml
       - name: lint
         runAfter: [fetch]
         taskRef: { name: golangci-lint }
         workspaces: [{ name: source, workspace: shared }]
       - name: test
         runAfter: [fetch]
         taskRef: { name: lint-and-test }
         workspaces: [{ name: source, workspace: shared }]
       - name: build
         runAfter: [lint, test]        # fan-in barrier
         taskRef: { name: kaniko-build }
         # ...
   ```

2. Add a **second, long-lived** workspace for a module cache so dependencies are not re-downloaded every run. Declare it in the Pipeline and mount it into the test/build Tasks, backed by a pre-created PVC instead of a per-run `volumeClaimTemplate`:

   ```yaml
     workspaces:
       - name: shared           # per-run, ephemeral
       - name: gocache          # persistent across runs
   ```
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: { name: go-mod-cache }
   spec:
     accessModes: [ReadWriteOnce]
     resources: { requests: { storage: 2Gi } }
   EOF
   ```
   In the test step, set `GOMODCACHE=$(workspaces.gocache.path)`.

3. Add a `finally` block that always runs — even when a task failed — to emit a status. `finally` Tasks can read `$(tasks.<name>.status)` and the overall `$(tasks.status)` (`Succeeded` / `Failed` / `None`):

   ```yaml
     finally:
       - name: report
         taskRef: { name: notify }
         params:
           - name: state
             value: "$(tasks.status)"
           - name: image
             value: "$(tasks.build.results.image-digest)"
   ```

4. Run it and measure the wall-clock win from parallelism:

   ```bash
   tkn pipelinerun start ci --use-param-defaults --showlog
   tkn pipelinerun describe --last | grep -E 'Started|Completed|Duration'
   ```
   ```
   Duration:   2m14s     # vs ~3m40s when lint and test were serial
   ```

5. Confirm the second run is faster because the module cache is warm:

   ```bash
   tkn taskrun logs --last | grep -c 'downloading'   # ~0 on a warm cache
   ```

**Comprehension checks (3):**

- **3a.** `lint` and `test` both mount the `shared` workspace `ReadWriteOnce`. On a single-node `kind` cluster they schedule fine; on a multi-node cluster this can deadlock. Explain why, and name the workspace attribute or volume access mode that fixes it.
- **3b.** Why must a persistent cache workspace (`gocache`) *never* be trusted the way ephemeral, per-run state is? What integrity risk does a shared, writable, cross-run cache introduce, and what is the standard mitigation (hint: cache *key*)?
- **3c.** The `finally` `report` Task references `$(tasks.build.results.image-digest)`, but `build` may not have run (a lint failure short-circuits it). What value does that variable resolve to, and why must the `notify` Task tolerate an empty/missing result?

---

### Exercise 4 — Shift left: supply-chain security in the pipeline

**Goal:** make security a *build gate*, not an afterthought: scan for vulnerabilities, generate an SBOM, and cryptographically sign the artifact. This is the CI half of software supply-chain security (SLSA / Sigstore).

1. Add a **scan** Task using Trivy that fails the build on HIGH/CRITICAL findings — a hard quality gate:

   ```yaml
   apiVersion: tekton.dev/v1
   kind: Task
   metadata:
     name: trivy-scan
   spec:
     params:
       - name: image
     steps:
       - name: scan
         image: aquasec/trivy:0.56.2
         script: |
           #!/usr/bin/env sh
           set -e
           trivy image --scanners vuln \
             --severity HIGH,CRITICAL \
             --exit-code 1 \
             --ignore-unfixed \
             "$(params.image)"
   ```

2. Add an **SBOM** Task with Syft, publishing the SBOM to the same registry as an OCI artifact attached to the image:

   ```yaml
       - name: sbom
         image: anchore/syft:v1.14.0
         script: |
           #!/usr/bin/env sh
           set -e
           syft "$(params.image)" -o spdx-json > sbom.spdx.json
           wc -l sbom.spdx.json
   ```

3. Add a **sign** Task with Sigstore `cosign` (key-based here for an offline lab; production uses keyless OIDC/Fulcio):

   ```bash
   cosign generate-key-pair                # produces cosign.key / cosign.pub
   kubectl create secret generic cosign-key \
     --from-file=cosign.key --from-literal=COSIGN_PASSWORD=""
   ```
   ```yaml
       - name: sign
         image: gcr.io/projectsigstore/cosign:v2.4.1
         env:
           - name: COSIGN_PASSWORD
             valueFrom: { secretKeyRef: { name: cosign-key, key: COSIGN_PASSWORD } }
         script: |
           #!/usr/bin/env sh
           set -e
           cosign sign --key /keys/cosign.key --yes \
             "$(params.image)@$(params.digest)"
           cosign attest --key /keys/cosign.key --yes \
             --predicate sbom.spdx.json --type spdxjson \
             "$(params.image)@$(params.digest)"
   ```
   Wire these three between `build` and `report`, all keyed off the digest from Exercise 2 (`sign`/`sbom`/`scan` consume `$(tasks.build.results.image-digest)`, never the tag).

4. Run the full pipeline and verify the signature from outside the cluster:

   ```bash
   cosign verify --key cosign.pub "$IMG/cartservice/src@sha256:1b2c..."
   ```
   ```
   Verification for ttl.sh/...@sha256:1b2c... --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - The signatures were verified against the specified public key
   ```

5. Verify the SBOM attestation is attached and readable:

   ```bash
   cosign verify-attestation --key cosign.pub --type spdxjson \
     "$IMG/cartservice/src@sha256:1b2c..." | jq -r '.payload' | base64 -d | jq '.predicateType'
   ```
   ```
   "https://spdx.dev/Document"
   ```

**Comprehension checks (4):**

- **4a.** `trivy` runs with `--exit-code 1 --severity HIGH,CRITICAL`. What is the platform-engineering argument for making this a *blocking* gate in CI rather than a report you review later — and what is the counter-argument that `--ignore-unfixed` addresses?
- **4b.** We sign `image@sha256:...`, never `image:tag`. Explain precisely why signing a mutable tag provides *no* real integrity guarantee.
- **4c.** The SBOM is produced in CI and attached as a signed attestation. Two months later a new CVE is disclosed for a library. How does having a stored, signed SBOM change your incident response versus having to rebuild and re-scan every image to find out if you're affected?
- **4d.** In production you'd replace `--key` with keyless signing (`cosign sign` with an OIDC token from the CI system, Fulcio-issued short-lived cert, Rekor transparency log). What operational problem of long-lived signing keys does keyless signing eliminate?

---

### Exercise 5 — CI as a product: the paved road

**Goal:** turn the one-off pipeline into a *self-service platform capability* a stream-aligned team consumes without copying YAML. This is the CNPA-defining perspective: CI is a **product** the platform team offers, governed by golden defaults.

1. Parameterize the Pipeline so a consumer supplies only intent, not implementation. Give every operational knob a sane default so the common path is zero-config:

   ```yaml
     params:
       - name: repo-url
         type: string
       - name: revision
         type: string
         default: main
       - name: image
         type: string
       - name: coverage-floor
         type: string
         default: "70"
       - name: severity-gate
         type: string
         default: "HIGH,CRITICAL"
   ```

2. Encode the golden defaults as *policy in the pipeline*, not documentation. For example, enforce the coverage floor as a real gate the consumer cannot silently bypass:

   ```yaml
       - name: coverage-gate
         runAfter: [test]
         params:
           - name: got
             value: "$(tasks.test.results.coverage)"
           - name: floor
             value: "$(params.coverage-floor)"
         taskSpec:
           params: [{ name: got }, { name: floor }]
           steps:
             - name: check
               image: alpine:3.20
               script: |
                 #!/usr/bin/env sh
                 got=$(printf '%s' "$(params.got)" | tr -dc '0-9.')
                 awk "BEGIN{exit !($got >= $(params.floor))}" \
                   || { echo "coverage $got% < floor $(params.floor)%"; exit 1; }
   ```

3. Offer the pipeline through a `PipelineRun` **template** that a team's repo triggers on push (the interface is a few params, the 200 lines of Task YAML stay in the platform). A minimal GitHub Actions caller that delegates to the platform pipeline:

   ```yaml
   # .github/workflows/ci.yaml  (in the consumer's repo)
   name: ci
   on:
     push:
       branches: [main]        # trunk-based: CI on every push to trunk
     pull_request:             # and on every PR before merge
   jobs:
     platform-ci:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - name: Invoke platform pipeline
           run: |
             tkn pipeline start ci \
               --param repo-url=${{ github.server_url }}/${{ github.repository }} \
               --param revision=${{ github.sha }} \
               --param image=registry.internal/${{ github.repository }} \
               --use-param-defaults --showlog
   ```

4. Confirm a consumer can run the whole paved road with defaults only:

   ```bash
   tkn pipeline start ci \
     --param repo-url=https://github.com/acme/widget \
     --param image=ttl.sh/widget:1h \
     --use-param-defaults --showlog
   ```

**Comprehension checks (5):**

- **5a.** The consumer's GitHub Actions file is ~10 lines; the 200 lines of Tasks, gates, and signing live in the platform. State the platform-engineering principle this split embodies, and one thing that gets *easier* to change for the whole org because of it.
- **5b.** Triggering CI on `push` to `main` *and* on `pull_request` reflects **trunk-based development**. Why does trunk-based development depend on a fast, trustworthy CI pipeline more than long-lived feature branches do?
- **5c.** The `coverage-floor` is a param with a default of `70`, but the gate is a real pipeline Task. Contrast this with putting "please keep coverage above 70%" in a README. Which one is a *paved road* and why?
- **5d.** A team asks to disable image signing "just for their repo, to go faster." As the platform owner, why is a per-consumer opt-out of a supply-chain control an anti-pattern, and what is the healthier way to handle a genuine exception?

---

<details>
<summary><strong>Answers</strong></summary>

**0a.** `latest` is a moving target: two `kubectl apply` runs a week apart install different controller versions, so a pipeline that passed becomes unreproducible and failures can't be attributed to your change vs. an upstream change. Pinning `v0.65.0` makes the build infrastructure itself deterministic — the same discipline you apply to application artifacts applies to the tools that produce them.

**0b.** (1) **Ephemeral, clean-room build environments** — each run starts from an immutable image with no state leaked from a previous run, so builds can't depend on hand-mutated runner state ("works because someone `apt install`ed it last Tuesday"). (2) **Reproducibility / isolation** — no shared mutable runner means parallel runs can't interfere, and a build's inputs are fully declared, not inherited from a long-lived machine.

**1a.** The workspace is backed by a `PersistentVolumeClaim`; both Tasks mount the *same* PVC, so `git-clone` writes the tree to the volume and `lint-and-test` reads it back. With `ReadWriteOnce`, that PVC can only be mounted by pods on a **single node**, so Tekton must schedule both Task pods to the same node (via the affinity-assistant) — and two Tasks needing the volume *simultaneously* (Exercise 3 parallelism) can't run on different nodes. The fix is `ReadWriteMany` storage or per-Task copies.

**1b.** Running `vet` and `unit-test` in parallel gives you the *complete* signal every run (you see lint AND test failures at once, fewer edit-run cycles) but you pay to run the tests even when `vet` already proves the commit is broken — you lose the fail-fast cost saving. The right call depends on which is scarcer: cheap fast gates first (fail-fast) when compute is the constraint; parallel-all when *engineer wait time* is the constraint. Cheap gates (lint) serial-first, expensive gates parallel is the common compromise.

**1c.** A `result` is a first-class, machine-readable output that downstream Tasks (`coverage-gate`), the `PipelineRun` status, and external systems can consume without scraping logs. Logs are unstructured, get truncated/rotated, and parsing them is brittle; a result is the stable contract.

**2a.** Mounting `/var/run/docker.sock` gives the build container control of the host Docker daemon, which is effectively **root on the node** — a malicious dependency or `Dockerfile` `RUN` can start privileged containers, mount the host filesystem, and escape to other tenants' workloads. Kaniko builds in userspace inside an unprivileged pod, removing the daemon and the socket entirely, closing that container-escape / privilege-escalation class.

**2b.** (1) **Non-determinism / drift:** a tag like `:1h` can be repointed to different bytes; the thing you tested is not guaranteed to be the thing you deploy. (2) **Broken rollbacks & caching:** a rollback to `:1h` may pull a *different* image than before, and orchestrators/caches keyed on the tag won't detect the change. A digest is content-addressed and immutable — the same reference always resolves to the same bytes.

**2c.** `--reproducible` strips per-build nondeterminism from layers — principally file timestamps (normalized) and consistent file/whiteout ordering — so identical inputs produce byte-identical layers and therefore an identical digest. Without it, every build differs even with unchanged source, which busts layer caches (nothing is a cache hit), defeats registry deduplication (every push stores "new" layers), and makes it impossible to prove two builds produced the same artifact.

**3a.** `ReadWriteOnce` binds the PVC to one node. When `lint` and `test` run in parallel, the scheduler may want them on different nodes, but only one node can mount the RWO volume — the second pod stays `Pending` and the pipeline stalls. Fix: back the shared workspace with `ReadWriteMany` storage, or keep the affinity-assistant to co-locate all Tasks of a run on one node (at the cost of parallel scheduling flexibility).

**3b.** Ephemeral per-run state is discarded, so a compromise dies with the run; a persistent cross-run cache is *shared, writable, and long-lived*, so a single poisoned entry (a tampered dependency, a planted `.go` object) can silently propagate into every subsequent build — a cache-poisoning supply-chain vector. Mitigation: key the cache on a content hash of the lockfile (`go.sum`/`package-lock.json`), treat it as read-only at build time where possible, and verify checksums so a mismatched entry is a cache miss, not blind trust.

**3c.** Because `build` never ran, `$(tasks.build.results.image-digest)` resolves to an **empty string** (Tekton substitutes empty for results of skipped/failed Tasks). The `notify` Task must handle that gracefully — report "build skipped due to earlier failure" rather than crashing or emitting a bogus `image@sha256:` (empty digest). `finally` Tasks always run, so they must be written defensively.

**4a.** Blocking on HIGH/CRITICAL means a known-exploitable image *cannot* reach a registry others promote from — the control is enforced at the one chokepoint every artifact passes through, instead of relying on humans to read a report. The counter-argument is false-positive fatigue: blocking on vulns with *no available fix* just stops all builds with no action a developer can take, so `--ignore-unfixed` scopes the gate to findings that are actually *actionable* (a patched version exists).

**4b.** A tag is a mutable pointer. Signing `image:tag` binds a signature to the *name*, but the name can later resolve to different bytes; an attacker who can push can repoint the tag to a malicious image and the old signature verification story is meaningless. Signing `image@sha256:...` binds the signature to the exact content — verification proves *these bytes* were signed, and the bytes cannot change without changing the digest.

**4c.** With a stored, signed SBOM you answer "am I affected?" as a **query** — search your attestations for the vulnerable package/version across all deployed images — in minutes, with cryptographic assurance the SBOM matches the running artifact. Without it you must rebuild and re-scan every image (often impossible for older builds whose inputs have drifted), which is slow, incomplete, and can't even reconstruct what an old image actually contained.

**4d.** Long-lived signing keys must be stored, rotated, access-controlled, and are catastrophic if leaked (an attacker can forge trusted signatures until you notice and rotate). Keyless signing issues a *short-lived* certificate (Fulcio) bound to the CI workload's OIDC identity and records the signing event in a public transparency log (Rekor), so there is no durable secret to steal or rotate — trust is anchored in the identity and the tamper-evident log, not a file on disk.

**5a.** It embodies **abstraction / separation of "what" from "how"** — the consumer declares intent (repo, image), the platform owns implementation (gates, signing, scanning). What gets easier: the platform team can change *the whole org's* CI behavior (bump the severity gate, add SBOM signing, swap Kaniko for Buildah) in one place, and every consumer inherits it on the next run — no fleet-wide YAML copy-paste migration.

**5b.** Trunk-based development integrates small changes into a shared main line constantly, so main is only kept releasable if *every* push is verified quickly and reliably; a slow or flaky pipeline makes developers batch changes (defeating the model) or merge on red. Long-lived feature branches defer integration, so the pain (and the CI dependency) is deferred too — until a giant, painful merge. Fast trustworthy CI is the enabling condition for trunk-based, not an optional nicety.

**5c.** The README is advisory — nothing stops a merge below 70%, and enforcement depends on human vigilance in review. The pipeline gate is **executable policy**: the build fails, deterministically, for everyone, with no bypass. A paved road is the easy path that is *also* the compliant path by construction; a README is a hope. The gate is the paved road.

**5d.** A per-consumer opt-out turns a supply-chain guarantee into an honor system: the moment one repo can ship unsigned images, "all our production images are signed" is false, and consumers of *that* image downstream inherit unverifiable provenance — the exception's blast radius isn't local. The healthier pattern is to fix the *reason* for the exception (make signing fast enough that it's not a bottleneck) and, for a genuine one-off, grant a **time-boxed, logged, policy-tracked exception** approved centrally — an exception the platform records and expires, not a switch the consumer flips.

</details>

---

### Sources

- CNPA Curriculum — https://github.com/cncf/curriculum (`CNPA_Curriculum.pdf`)
- Tekton Pipelines documentation — https://tekton.dev/docs/pipelines/
- Tekton Catalog (`git-clone`) — https://github.com/tektoncd/catalog
- Kaniko — https://github.com/GoogleContainerTools/kaniko
- Sigstore / cosign — https://docs.sigstore.dev/
- SLSA supply-chain framework — https://slsa.dev/
- Syft (SBOM) — https://github.com/anchore/syft
- Trivy — https://trivy.dev/
- CD Foundation (CI/CD best practices) — https://cd.foundation/