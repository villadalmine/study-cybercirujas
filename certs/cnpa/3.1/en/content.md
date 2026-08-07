# Continuous Integration Fundamentals and Best Practices

> **CNPA · Domain 3 · Topic 3.1** — *Continuous Integration & Delivery*
> Exam weight: **2.3** · Curriculum version: **2025-04-01**

Continuous Integration (CI) is the discipline of merging every developer's work into a shared mainline many times a day, and proving on every merge — automatically and quickly — that the integrated system still builds, passes its tests, and produces a deployable, tamper-evident artifact. For a **platform engineer** the deliverable is not a single pipeline: it is CI *as a capability* — a golden path that dozens of application teams consume without each reinventing runners, caches, secrets, image builds, and supply-chain controls. This topic covers the mechanics of that capability on Kubernetes-native tooling.

---

## 1. The architectural problem: integration latency and the cost of large batches

Before CI, teams integrated on a branch that lived for weeks. The pain was not writing the code; it was the **merge**. Integration cost grows super-linearly with batch size: two branches that each touch 40 files and diverged for three weeks produce conflicts whose resolution requires re-understanding intent that has already been paged out of everyone's head. The failure is discovered *late*, when it is *expensive* and *ambiguous* (which of the 200 commits broke it?).

CI attacks this with one lever: **reduce the batch size of integration to near zero and make the feedback loop fast enough that developers stay inside it.** The mechanism is trunk-based development plus an automated gate on every push.

```
                     ┌──────────── the feedback loop CI must keep short ───────────┐
                     │                                                             │
  git push ──▶ webhook ──▶ CI controller ──▶ [ lint · build · unit · SAST ·       │
                              (schedules)       container build · scan · sign ]    │
                     │                                          │                  │
                     └── red/green status ◀── artifact + attestations ◀────────────┘
                                │
                                ▼
                        merge to trunk (protected)
```

**Why this is a *platform* concern, not just a dev concern.** In a multi-tenant engineering org, each of the three cost drivers below is a shared-infrastructure decision:

| Cost driver | Symptom when unmanaged | Platform lever |
|---|---|---|
| **Feedback latency** | Developers context-switch; PRs pile up | Warm caches, ephemeral parallel runners, incremental/affected-only builds |
| **Non-determinism** | "Works on my machine", flaky reds | Hermetic builds, pinned toolchains, isolated pods |
| **Trust in the artifact** | Unknown provenance ships to prod | Build-once + SBOM + signature + provenance attestation |

The rest of this topic is the machinery for those three levers.

---

## 2. Core practices (the "best practices" the exam tests)

These are the non-negotiables. Each maps to a concrete failure it prevents.

1. **Trunk-based development, short-lived branches.** Branches live hours, not weeks. Feature flags decouple *deploy* from *release* so incomplete work can merge safely.
2. **Every commit triggers the pipeline.** No nightly-only CI. The gate runs on push and on the merge queue.
3. **Fail fast, cheapest-first ordering.** Order stages by *cost of running* × *probability of catching*: `format → lint → unit → build → integration → e2e`. A 200 ms formatter must never sit behind a 20-minute e2e suite.
4. **Build once, promote the same artifact.** The bytes tested in CI are the bytes that reach prod. Never rebuild per environment — rebuilding re-opens the supply chain and invalidates every test you ran.
5. **Hermetic, reproducible builds.** Pinned base images by digest, pinned dependency lockfiles, no network access during the build step where possible. Same inputs → same output digest.
6. **Immutable, content-addressed artifacts.** Reference images by `@sha256:…`, never by mutable tags like `:latest`.
7. **Keep the build green; a red trunk stops the line.** A broken mainline is a team-wide outage of the ability to integrate. Fixing it preempts feature work.
8. **Secure the supply chain in CI, at build time.** Generate an SBOM, scan it, sign the artifact, and emit provenance — because CI is the *only* place that observed the source→artifact transformation.
9. **Pipeline-as-code, versioned with the app.** The pipeline definition lives in the repo and is reviewed like code.
10. **Measure the loop.** Track the DORA metrics that CI directly moves: build duration (p50/p95), change-failure rate, and pipeline pass rate.

> **Deploy vs release.** CI/CD moves *artifacts*; feature flags move *user-visible behavior*. Merging a half-finished feature behind a flag is not a smell — it is what makes trunk-based development safe. Long-lived feature branches are the anti-pattern the flag replaces.

---

## 3. Technical comparison of CI systems

There is no single correct CI engine; there are trade-offs along *control-plane locality*, *runner model*, and *ecosystem*.

### 3.1 CI orchestrators

| Engine | Control plane | Pipeline model | Runner model | Best fit | Main drawback |
|---|---|---|---|---|---|
| **GitHub Actions** | SaaS (or self-hosted runners) | YAML workflow, marketplace actions | GitHub-hosted or self-hosted (ARC on K8s) | Repos on GitHub; fastest onboarding | Vendor-coupled control plane; YAML sprawl |
| **GitLab CI** | SaaS or self-managed | `.gitlab-ci.yml`, stages/jobs | Shared or self-managed runners | Integrated SCM+CI+registry | Monolith; runner autoscaling is bespoke |
| **Jenkins** | Self-hosted | Groovy/declarative `Jenkinsfile` | Static agents or K8s plugin pods | Legacy, plugin-heavy shops | Snowflake controllers, plugin CVE surface |
| **Tekton** | **In-cluster CRDs (K8s-native)** | `Task`/`Pipeline` CRDs, each step a container | Every step is a pod on your cluster | Platform teams building CI *as a product* | You operate it; no built-in UI/SCM |
| **Argo Workflows** | In-cluster CRDs | DAG/steps of container templates | Pods on your cluster | Batch/ML DAGs, CI on K8s | General-purpose; less CI-specific ergonomics |
| **Dagger** | Engine (BuildKit) + SDK | Code (Go/Python/…) as pipeline | Runs anywhere with the engine | Portable pipelines, local==CI | Newer; another engine to run |

**Why Tekton matters for CNPA.** Tekton is the CNCF-graduated, Kubernetes-native CI primitive. Its unit of work is a `Step` (a container), a `Task` is a sequence of steps in one pod, and a `Pipeline` is a DAG of `Tasks`. Because the control plane *is* Kubernetes CRDs, a platform team gets RBAC, admission control, scheduling, and multi-tenancy for free — the same substrate the workloads run on. That is precisely the "CI as a platform capability" the exam frames.

### 3.2 Runner / execution model — the decision that dominates cost and blast radius

| Model | Isolation | Cold-start | Scaling | Security posture | Notes |
|---|---|---|---|---|---|
| **SaaS shared runners** | Fresh VM per job | Seconds | Elastic, billed/minute | Secrets leave your network | Zero to operate; noisy-neighbor & egress cost |
| **Static self-hosted VMs** | Reused host | None | Manual | Persistent state = supply-chain risk | Cheap steady-state; state bleeds between jobs |
| **Ephemeral pods (ARC / Tekton)** | Fresh pod per job | Sub-second–seconds | HPA/scale-set, scale-to-zero | Per-job identity, no reuse | The cloud-native default; you operate the cluster |

**Ephemeral-per-job on Kubernetes is the platform-engineering answer**: each run gets a clean pod, a scoped ServiceAccount (ideally exchanged for a short-lived OIDC token), and disappears afterward — no reused filesystem to poison a later build.

### 3.3 In-cluster container builds — you cannot assume a Docker daemon

Building images *inside* a Kubernetes pod without a privileged Docker socket is a defining cloud-native constraint (the node runs containerd/CRI-O, not dockerd, and mounting the host socket is a container-escape vector).

| Tool | Root required | Daemon | Cache | Notes |
|---|---|---|---|---|
| **Kaniko** | No (unprivileged) | None — executes build in userspace | Registry-backed layer cache | Simple, popular in Tekton catalog |
| **BuildKit (rootless)** | No (rootless) | `buildkitd` (can run rootless) | Rich local + registry cache, mounts | Fastest; best cache semantics |
| **Buildah** | No (rootless) | None | Layer cache | OCI-native, pairs with Podman |
| **Docker-in-Docker (dind)** | **Privileged** | dockerd sidecar | Local | Avoid: privileged pod = node-escape risk |

---

## 4. Complete, production-grade manifests

### 4.1 Tekton: a full build → test → scan → sign → push pipeline

A `Task` that runs unit tests in a hermetic Go container:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: go-unit-test
  labels:
    app.kubernetes.io/part-of: ci-golden-path
spec:
  description: >-
    Run `go test` with the module cache on a shared workspace so the
    build step downstream reuses the same modules.
  params:
    - name: packages
      description: Package selector passed to go test
      type: string
      default: "./..."
  workspaces:
    - name: source          # the cloned repo
    - name: gocache         # persisted module + build cache
  steps:
    - name: test
      image: golang:1.23.4@sha256:1a5f0c5d7d9d0c2e3b6a1f2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60
      workingDir: $(workspaces.source.path)
      env:
        - name: GOFLAGS
          value: "-mod=readonly"        # fail if go.sum is incomplete → hermeticity
        - name: GOCACHE
          value: $(workspaces.gocache.path)/build
        - name: GOMODCACHE
          value: $(workspaces.gocache.path)/mod
        - name: CGO_ENABLED
          value: "0"
      script: |
        #!/usr/bin/env sh
        set -eu
        echo "→ vet"
        go vet $(params.packages)
        echo "→ test (race + coverage)"
        go test -race -covermode=atomic -coverprofile=coverage.out $(params.packages)
        go tool cover -func=coverage.out | tail -1
```

A `Task` that builds and pushes an image with **Kaniko** (unprivileged, no Docker daemon), emitting the pushed digest as a Tekton *result*:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kaniko-build
spec:
  params:
    - name: image
      description: Fully qualified image ref WITHOUT tag, e.g. registry/app
      type: string
    - name: dockerfile
      type: string
      default: ./Dockerfile
  workspaces:
    - name: source
    - name: dockerconfig      # projected registry credentials at /kaniko/.docker
  results:
    - name: image-digest
      description: The sha256 digest of the image just pushed
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.2@sha256:8b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
      workingDir: $(workspaces.source.path)
      env:
        - name: DOCKER_CONFIG
          value: $(workspaces.dockerconfig.path)
      args:
        - --dockerfile=$(params.dockerfile)
        - --context=dir://$(workspaces.source.path)
        - --destination=$(params.image):$(context.pipelineRun.uid)
        - --cache=true
        - --cache-repo=$(params.image)/cache
        - --reproducible                       # deterministic, timestamp-stripped layers
        - --digest-file=$(results.image-digest.path)
```

The `Pipeline` wiring the DAG together, including a `finally` block that always runs:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ci-build-verify-sign
spec:
  params:
    - name: repo-url
    - name: revision
      default: main
    - name: image
  workspaces:
    - name: shared            # source, mounted by every task
    - name: gocache
    - name: dockerconfig
  tasks:
    - name: fetch
      taskRef:
        name: git-clone       # from the Tekton catalog / Artifact Hub
      params:
        - name: url
          value: $(params.repo-url)
        - name: revision
          value: $(params.revision)
      workspaces:
        - name: output
          workspace: shared
    - name: unit-test
      runAfter: [fetch]
      taskRef:
        name: go-unit-test
      workspaces:
        - name: source
          workspace: shared
        - name: gocache
          workspace: gocache
    - name: build
      runAfter: [unit-test]          # build only if tests pass — cheap-first ordering
      taskRef:
        name: kaniko-build
      params:
        - name: image
          value: $(params.image)
      workspaces:
        - name: source
          workspace: shared
        - name: dockerconfig
          workspace: dockerconfig
    - name: scan
      runAfter: [build]
      taskRef:
        name: trivy-scanner
      params:
        - name: image-ref
          value: $(params.image)@$(tasks.build.results.image-digest)
        - name: args
          value: ["--severity", "HIGH,CRITICAL", "--exit-code", "1"]
      workspaces:
        - name: manifest-dir
          workspace: shared
    - name: sign
      runAfter: [scan]
      taskRef:
        name: cosign-sign            # keyless, uses the PipelineRun SA OIDC identity
      params:
        - name: image
          value: $(params.image)@$(tasks.build.results.image-digest)
  finally:
    - name: report
      taskRef:
        name: emit-ci-metrics
      params:
        - name: pipeline-status
          value: $(tasks.status)     # Succeeded / Failed / Completed
        - name: digest
          value: $(tasks.build.results.image-digest)
```

The `PipelineRun` that instantiates it — note `volumeClaimTemplate`, so each run gets a **fresh, isolated** PVC that is garbage-collected afterward (no state bleed between builds):

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ci-app-
  labels:
    tekton.dev/pipeline: ci-build-verify-sign
spec:
  pipelineRef:
    name: ci-build-verify-sign
  taskRunTemplate:
    serviceAccountName: ci-builder      # scoped RBAC + registry push + OIDC
  timeouts:
    pipeline: "1h0m0s"
  params:
    - name: repo-url
      value: https://github.com/acme/payments.git
    - name: revision
      value: 9f8e7d6c5b4a3928170615243546576869708192
    - name: image
      value: registry.internal.acme.io/payments
  workspaces:
    - name: shared
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
    - name: gocache
      persistentVolumeClaim:
        claimName: shared-go-cache        # long-lived warm cache, RWX
    - name: dockerconfig
      secret:
        secretName: registry-push-creds
```

### 4.2 GitHub Actions: the same shape as pipeline-as-code

For teams on GitHub, the golden path is a reusable workflow. Note pinned `permissions` (least privilege), OIDC (`id-token: write`) instead of long-lived registry passwords, a `concurrency` group that cancels superseded runs, and dependency caching:

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read
  id-token: write          # OIDC for keyless cosign signing + cloud auth
  packages: write          # push to GHCR

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true # a newer push cancels the stale run

jobs:
  build-test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true                      # module + build cache, keyed on go.sum

      - name: Lint, vet, test (fail fast, cheap first)
        run: |
          gofmt -l . | tee /dev/stderr | (! read)   # non-zero if any file unformatted
          go vet ./...
          go test -race -covermode=atomic ./...

      - name: Build & push (build once)
        id: build
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true                 # SLSA provenance attestation
          sbom: true                       # attach SBOM attestation

      - name: Sign the image (keyless)
        env:
          COSIGN_EXPERIMENTAL: "1"
        run: |
          cosign sign --yes \
            ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
```

### 4.3 Self-hosted ephemeral runners on Kubernetes (Actions Runner Controller)

To keep secrets and egress inside your network while retaining GitHub Actions ergonomics, run **ephemeral, scale-to-zero** runners as pods via ARC's `gha-runner-scale-set`. Installed with Helm; the values that matter:

```yaml
# values.yaml for the gha-runner-scale-set Helm chart
githubConfigUrl: https://github.com/acme
githubConfigSecret: arc-github-app       # GitHub App creds, not a PAT

minRunners: 0                            # scale to zero when idle
maxRunners: 50

runnerScaleSetName: k8s-ephemeral

template:
  spec:
    securityContext:
      runAsNonRoot: true
      runAsUser: 1001
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.320.0
        command: ["/home/runner/run.sh"]
        resources:
          requests: { cpu: "1", memory: 2Gi }
          limits:   { cpu: "2", memory: 4Gi }
```

```bash
$ helm install arc-runners \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --namespace arc-runners --create-namespace \
    -f values.yaml
```

A workflow then targets it with `runs-on: k8s-ephemeral`; each job spins up one fresh pod, runs, and is deleted.

---

## 5. CLI walkthrough and expected terminal output

Applying and driving the Tekton pipeline with `tkn` and `kubectl`:

```console
$ kubectl apply -f tasks/ -f pipeline.yaml
task.tekton.dev/go-unit-test created
task.tekton.dev/kaniko-build created
pipeline.tekton.dev/ci-build-verify-sign created

$ tkn pipeline start ci-build-verify-sign \
    --param repo-url=https://github.com/acme/payments.git \
    --param revision=9f8e7d6 \
    --param image=registry.internal.acme.io/payments \
    --workspace name=shared,volumeClaimTemplateFile=pvc.yaml \
    --workspace name=gocache,claimName=shared-go-cache \
    --workspace name=dockerconfig,secret=registry-push-creds \
    --use-param-defaults --showlog
PipelineRun started: ci-build-verify-sign-run-7t2kq
Waiting for logs to be available...

[fetch : clone] + git clone --depth 1 https://github.com/acme/payments.git
[fetch : clone] Cloned revision 9f8e7d6 into /workspace/output

[unit-test : test] → vet
[unit-test : test] → test (race + coverage)
[unit-test : test] ok   github.com/acme/payments/ledger  3.114s  coverage: 91.2%
[unit-test : test] total:  (statements)  88.7%

[build : build-and-push] INFO[0002] Using dockerfile ./Dockerfile
[build : build-and-push] INFO[0021] Pushed registry.internal.acme.io/payments:7t2kq...
[build : build-and-push] INFO[0021] Digest: sha256:4d5e6f70...c3d4e5f6

[scan : trivy] payments (alpine 3.20)  Total: 0 (HIGH: 0, CRITICAL: 0)

[sign : cosign] Generating ephemeral keys...
[sign : cosign] tlog entry created with index: 148203991
```

Inspecting status and results afterward:

```console
$ tkn pipelinerun describe ci-build-verify-sign-run-7t2kq
Name:              ci-build-verify-sign-run-7t2kq
Status
STARTED          DURATION     STATUS
2 minutes ago    1m48s        Succeeded

🗂  Taskruns
 NAME               TASK NAME    STATUS
 ...-fetch          fetch        ✔ Succeeded
 ...-unit-test      unit-test    ✔ Succeeded
 ...-build          build        ✔ Succeeded
 ...-scan           scan         ✔ Succeeded
 ...-sign           sign         ✔ Succeeded
 ...-report         report       ✔ Succeeded   (finally)

$ tkn pipelinerun describe ci-...-7t2kq -o jsonpath='{.status.results}'
[{"name":"image-digest","value":"sha256:4d5e6f70...c3d4e5f6"}]
```

Verifying the supply-chain artifacts the pipeline produced:

```console
$ cosign verify \
    --certificate-identity-regexp '^https://github.com/acme/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.internal.acme.io/payments@sha256:4d5e6f70...c3d4e5f6
Verification for registry.internal.acme.io/payments@sha256:4d5e... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted CA

$ syft registry.internal.acme.io/payments@sha256:4d5e6f70... -o spdx-json > sbom.json
 ✔ Parsed image        sha256:4d5e6f70...
 ✔ Cataloged contents  213 packages
```

---

## 6. Verification, diagnosis, and common failure modes

CI failures split into two classes: **true reds** (the code is wrong — the system working as designed) and **infrastructure reds** (the pipeline is wrong). Only the second class is the platform team's bug, and it is the more corrosive one, because it teaches developers to distrust and re-run the gate.

| Symptom | Likely root cause | Diagnosis | Fix |
|---|---|---|---|
| **Flaky tests** (pass on re-run) | Shared state, time/order dependence, real network in "unit" tests | Run with `-race`, `-count=10`, `-shuffle=on`; quarantine and track | Isolate state; ban network in unit tier; fix or delete |
| **"Works locally, red in CI"** | Non-hermetic build: unpinned base image or deps | Diff toolchain versions; check for `:latest` / floating deps | Pin base by `@sha256`, `-mod=readonly`, lockfiles |
| **Cache poisoning / stale cache** | Cache key too coarse; reused across incompatible inputs | Key on `hashFiles('**/go.sum')`, not branch name | Content-addressed cache keys; scope per toolchain version |
| **Kaniko/BuildKit push denied** | Missing/expired registry creds or SA token | `kubectl logs` the build step; check `DOCKER_CONFIG` mount | Rotate creds; prefer short-lived OIDC token exchange |
| **Runner starvation, queue backup** | `maxRunners` too low; no scale-to-zero warmup | `kubectl get pods -n arc-runners`; inspect HPA/scale-set | Raise `maxRunners`; pre-warm caches; shard the suite |
| **`PipelineRun` stuck `Pending`** | PVC unbound (no RWX/RWO provisioner) or quota | `kubectl describe pipelinerun`; `kubectl get pvc` | Fix StorageClass; raise `ResourceQuota` |
| **Pipeline "passes" but ships bad artifact** | Scan/sign step non-blocking (`exit-code 0`) | Read the *gate* config, not just the green check | Make scan `--exit-code 1`; require signature at admission |

Concrete diagnostic session for a wedged run:

```console
$ tkn pipelinerun list --limit 5
NAME                              STARTED       DURATION   STATUS
ci-...-9x4mz                      3 min ago     ---        Running
ci-...-7t2kq                      1 hour ago    1m48s      Succeeded

$ tkn pipelinerun describe ci-...-9x4mz
...
 NAME              TASK NAME   STATUS
 ...-build         build      ✗ Failed

$ tkn taskrun logs ci-...-9x4mz-build -f
[build-and-push] error checking push permissions -- make sure you
[build-and-push] entered the correct tag name, and that you are
[build-and-push] authenticated correctly: UNAUTHORIZED

$ kubectl get pods -l tekton.dev/pipelineRun=ci-...-9x4mz \
    -o jsonpath='{.items[0].spec.volumes}' | jq '.[] | select(.secret)'
{ "name": "ws-dockerconfig", "secret": { "secretName": "registry-push-creds" } }

$ kubectl get secret registry-push-creds -o jsonpath='{.data.\.dockerconfigjson}' \
    | base64 -d | jq '.auths | keys'
[ "registry.internal.acme.io" ]        # ← key matches, so creds present but expired
```

**Verification checklist for the golden path itself** (what a platform team runs to prove CI is trustworthy):

- **Reproducibility:** build the same commit twice → identical image digest (`--reproducible`).
- **Hermeticity:** run the build step with network egress denied; it should still succeed.
- **Isolation:** a failing build leaves no residue that changes the next run (fresh PVC per `PipelineRun`).
- **Gate integrity:** deliberately introduce a HIGH CVE and confirm the pipeline goes red, not green.
- **Provenance:** `cosign verify-attestation` resolves for every image before it is admitted to a cluster.

---

## 7. Metrics that close the loop

CI is only "working" if it is fast and trusted. Instrument the four signals the exam associates with delivery performance:

| Signal | Target direction | Where measured |
|---|---|---|
| **Build/pipeline duration (p50, p95)** | ↓ (keep p95 < ~10 min) | CI system; Tekton `finally` emit |
| **Pipeline pass rate on trunk** | ↑ (green trunk) | CI history |
| **Change-failure rate** | ↓ | CI red-after-merge + prod incidents |
| **Mean time to green** (red trunk → fixed) | ↓ | CI history |

A p95 build that creeps past ~10 minutes is the leading indicator that developers will start batching work again — the exact failure CI exists to prevent. Treat build latency as a first-class SLO of the platform.

---

## References

- CNCF — *Kubernetes and Cloud Native Platform Engineering Associate (CNPA) Curriculum*: https://github.com/cncf/curriculum
- Tekton — *Pipelines documentation* (Tasks, Pipelines, PipelineRuns, Workspaces): https://tekton.dev/docs/pipelines/
- Tekton — *Catalog / Artifact Hub tasks* (`git-clone`, `kaniko`, `trivy`, `cosign`): https://hub.tekton.dev/
- Argo Workflows — *Documentation*: https://argo-workflows.readthedocs.io/
- GitHub — *GitHub Actions documentation*: https://docs.github.com/en/actions
- GitHub — *Actions Runner Controller (ARC) / autoscaling runner scale sets*: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller
- Kaniko — *Building images in Kubernetes without a Docker daemon*: https://github.com/GoogleContainerTools/kaniko
- Docker BuildKit — *Documentation*: https://docs.docker.com/build/buildkit/
- Sigstore Cosign — *Signing and verifying containers*: https://docs.sigstore.dev/cosign/signing/overview/
- SLSA — *Supply-chain Levels for Software Artifacts (provenance)*: https://slsa.dev/spec/
- Anchore Syft — *SBOM generation*: https://github.com/anchore/syft
- GitLab — *CI/CD documentation*: https://docs.gitlab.com/ee/ci/
- Google — *DORA / Accelerate metrics for delivery performance*: https://dora.dev/
- Martin Fowler — *Continuous Integration* (canonical practice definition): https://martinfowler.com/articles/continuousIntegration.html