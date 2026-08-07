# Continuous Integration Pipelines: Overview and Architecture

> **CNPA · Domain 3 · Topic 3.3** — Exam weight 2.3
> Depth calibrated to the weight: this is the *architectural* view of CI as a platform capability, not a per-language build tutorial. The goal is that you can reason about **where CI compute runs, how it scales, how it stays isolated, and where the CI boundary ends and CD/GitOps begins.**

---

## 1. Motivation: the production problem CI architecture actually solves

In a mature platform, the interesting failure is almost never "the build broke." It is **CI sprawl**: every one of *N* application teams stands up its own Jenkins controller, its own runner fleet, its own secret handling, and its own idea of what "tested and safe to ship" means. The consequences are structural, not cosmetic:

- **Configuration drift.** No two pipelines agree on Go version, base image, coverage floor, or scan policy. Security posture is a per-repo accident.
- **Undifferentiated toil.** Fifty teams each maintain plugin upgrades and runner AMIs. The platform team maintains nothing reusable.
- **Supply-chain opacity.** Without a *paved road*, nobody can answer "was this image built from the commit it claims, and was it signed?" — the question SLSA and Sigstore exist to answer.
- **Cost blindness.** Static runner fleets sit 90% idle overnight and saturate at 09:00, and nobody owns the bill.

Platform engineering reframes CI from *a thing each team owns* to **a self-service capability the platform provides**: a golden path where a team supplies a repository and a `Dockerfile`, and the platform supplies build compute, caching, test gating, image signing, provenance, and publication — governed centrally, consumed on demand.

**The architectural boundary CNPA cares about.** CI ends when a **tested, scanned, signed, provenance-carrying artifact** lands in a registry. What happens next — reconciling that artifact into a cluster — is **CD/GitOps** (a separate domain). Keeping this seam clean is the single most important design decision: CI *pushes* facts (an immutable digest + attestations), CD *pulls* desired state. Blur the seam (a CI job that runs `kubectl apply`) and you lose auditability, drift detection, and the ability to roll back by reverting Git.

```
   trigger ─▶ build ─▶ test ─▶ scan ─▶ sign/attest ─▶ publish ──╎──▶  (CD / GitOps takes over)
   commit    OCI      unit/    SBOM,   cosign +       registry  ╎     reconcile digest into cluster
   webhook   image    integ    CVE     provenance     (digest)  ╎
                                                                 ╎
                              ── CI owns everything left of the seam ──
```

| Pipeline stage | What it produces | Platform-level concern it forces |
|---|---|---|
| **Trigger** | An event (push, PR, tag, schedule) | Idempotency, de-duplication, concurrency limits per repo |
| **Build** | OCI image / binary | *Where* build runs; rootless vs privileged; cache locality |
| **Test** | Pass/fail + coverage | Enforced quality floor; hermetic, reproducible test envs |
| **Scan** | SBOM + CVE report | Policy gate (fail on critical); SBOM stored as attestation |
| **Sign / attest** | Signature + provenance | Keyless identity (OIDC), transparency log |
| **Publish** | Immutable digest | Registry as the CI→CD handoff; **never** `:latest` |

---

## 2. Architectural comparison and trade-offs

### 2.1 CI control-plane / execution-substrate topologies

The defining question is: **where does the control plane live, and where does the job execute?**

| Dimension | Jenkins | GitHub Actions (SaaS) | GitLab CI | **Tekton** | **Argo Workflows** |
|---|---|---|---|---|---|
| Control plane | Self-hosted controller (stateful, JVM) | GitHub-hosted | GitLab-hosted or self-managed | **In-cluster CRDs** | **In-cluster CRDs** |
| Execution substrate | Static agents (VM/container) | Hosted runners or self-hosted (ARC) | Runners (shell/docker/k8s executor) | **K8s Pods (one per Task)** | **K8s Pods (one per step)** |
| Pipeline definition | Groovy `Jenkinsfile` (imperative) | YAML workflow | YAML `.gitlab-ci.yml` | YAML CRDs (`Task`/`Pipeline`) | YAML CRD (`Workflow`, DAG/steps) |
| Isolation model | Agent-level (shared workspace risk) | Job = fresh runner | Executor-dependent | **Pod-per-Task, K8s RBAC/NS** | **Pod-per-step, K8s RBAC/NS** |
| Autoscaling | Plugin (e.g. k8s plugin) | ARC / hosted elasticity | GitLab Runner autoscaler | HPA/Karpenter on the node pool | HPA/Karpenter on the node pool |
| CNCF status | — | — | — | **CD Foundation (graduated)** | **CNCF Graduated** |
| Primary weakness | Plugin sprawl, stateful controller = SPOF | Vendor lock-in; egress to SaaS | Tightest when all-GitLab | Verbose YAML; no built-in triggers (needs **Triggers**/Events) | General workflow engine; not CI-opinionated |

**Reading the table for CNPA:** the cloud-native answer is a **Kubernetes-native, CRD-driven** engine (Tekton or Argo Workflows) so that CI inherits the cluster's primitives — RBAC, namespaces, `ResourceQuota`, `NetworkPolicy`, node autoscaling — instead of reinventing them. SaaS runners (GitHub Actions via **Actions Runner Controller**) are the pragmatic middle: keep the SaaS control plane, but run execution *inside your cluster* for network access and cost control.

### 2.2 Runner / agent topology: the cost-vs-isolation axis

| Topology | Cold-start latency | Isolation / blast radius | Cache locality | Cost profile | Use when |
|---|---|---|---|---|---|
| **Static VM agents** | ~0 (always on) | Weak — shared FS between jobs | Excellent (warm local cache) | Worst — idle burn 24/7 | Legacy Jenkins; predictable steady load |
| **Static container runners** | Low | Medium — container boundary | Good | High idle burn | Moderate, steady throughput |
| **Ephemeral Pods (per job)** | Medium (image pull + sched) | **Strong** — Pod dies after job | Poor unless cache is externalized | **Pay-per-use** | Cloud-native default; bursty load |
| **Ephemeral VMs (per job)** | High | **Strongest** — kernel isolation | Poor | High per-job, zero idle | Untrusted/PR builds from forks |

The ephemeral-Pod default trades **cache locality for isolation and cost**. You reclaim cache via an *external* layer — a remote build cache (BuildKit/`--cache-from`), a shared PVC, or a registry-backed cache — rather than a warm local disk.

### 2.3 In-cluster image build tooling (a build stage sub-decision)

Building an OCI image *inside* an ephemeral Pod is the classic "how do I `docker build` without a Docker daemon and without `privileged`?" problem.

| Tool | Requires privileged? | Daemonless | Build cache | Notes |
|---|---|---|---|---|
| **Docker-in-Docker (DinD)** | **Yes** (privileged sidecar) | No | Good | Largest attack surface; avoid on shared clusters |
| **Kaniko** | No | Yes | Layer cache (registry/dir) | Simple, widely used; slower on big layers |
| **BuildKit (rootless)** | No | Yes | **Best** (content-addressed, remote) | Fastest; `buildkitd` rootless or as a service |
| **Buildah** | No (rootless w/ user-ns) | Yes | Good | OCI-native; pairs with Podman ecosystem |

**Rule:** on a multi-tenant platform cluster, `privileged: true` for builds is a policy failure. Default to **Kaniko** for simplicity or **rootless BuildKit** for speed; forbid DinD via admission policy.

---

## 3. Complete, valid manifests

### 3.1 GitHub Actions — build → test-gate → build/push → keyless sign

A SaaS-control-plane pipeline that gates on a coverage floor and signs the resulting digest with **keyless cosign** (OIDC → Fulcio → Rekor), producing SBOM + provenance.

```yaml
# .github/workflows/ci.yaml
name: ci-build-test-sign
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write            # REQUIRED: OIDC token for keyless cosign

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.23"
          cache: true
      - name: Unit tests
        run: go test -race -covermode=atomic -coverprofile=cover.out ./...
      - name: Enforce coverage floor (>= 70%)
        run: |
          pct=$(go tool cover -func=cover.out | awk '/total:/{print substr($3,1,length($3)-1)}')
          echo "total coverage: ${pct}%"
          awk -v p="$pct" 'BEGIN { exit (p < 70.0) }'   # non-zero exit fails the job

  build-sign:
    needs: test                        # hard gate: no build unless tests pass
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Log in to registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Derive tags/labels
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,format=long
      - uses: docker/setup-buildx-action@v3
      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: true               # SLSA provenance attestation
          sbom: true                     # SPDX SBOM attestation
      - uses: sigstore/cosign-installer@v3
      - name: Sign the digest (keyless)
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: cosign sign --yes "${REGISTRY}/${IMAGE_NAME}@${DIGEST}"
```

Two architectural points to internalize: (1) `needs: test` is the **quality gate** — the build never runs on failing tests; (2) we sign the **digest**, never a mutable tag, because the tag can be repointed after signing.

### 3.2 Actions Runner Controller (ARC) — execution *inside* your cluster

Keep GitHub's control plane, run the runners as ephemeral Pods you own. Modern ARC is the `gha-runner-scale-set` Helm chart; the resulting CRD is `AutoscalingRunnerSet` (group `actions.github.com`).

```yaml
# values.yaml — Helm values for the gha-runner-scale-set chart
githubConfigUrl: https://github.com/acme
githubConfigSecret: arc-github-app        # k8s Secret holding the GitHub App creds
minRunners: 1
maxRunners: 50
runnerScaleSetName: k8s-linux-x64         # <- workflows target this via runs-on:
containerMode:
  type: kubernetes                        # each job step runs as its own Pod
  kubernetesModeWorkVolumeClaim:
    accessModes: [ReadWriteOnce]
    storageClassName: fast-ssd
    resources:
      requests:
        storage: 10Gi
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.319.1
        command: ["/home/runner/run.sh"]
        resources:
          requests: { cpu: "1", memory: 2Gi }
          limits:   { cpu: "2", memory: 4Gi }
```

```bash
# Install controller, then the scale set (both from OCI Helm registries):
$ helm install arc \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    -n arc-systems --create-namespace

$ helm install k8s-linux-x64 \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    -n arc-runners --create-namespace -f values.yaml
```

Workflows then request this fleet with `runs-on: k8s-linux-x64`. The listener scales Pods from `minRunners` to `maxRunners` against queue depth — **elastic, pay-per-use, isolated per job**.

### 3.3 Tekton — a Kubernetes-native `Pipeline` (clone → test → kaniko build/push)

```yaml
# pipeline.yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: build-test-push
spec:
  params:
    - name: repo-url
    - name: revision
      default: main
    - name: image-ref
  workspaces:
    - name: shared         # git checkout + build context
    - name: dockerconfig   # registry credentials for the push
  tasks:
    - name: clone
      taskRef:
        resolver: hub
        params:
          - { name: kind, value: task }
          - { name: name, value: git-clone }
          - { name: version, value: "0.9" }
      params:
        - { name: url, value: $(params.repo-url) }
        - { name: revision, value: $(params.revision) }
      workspaces:
        - { name: output, workspace: shared }

    - name: unit-test
      runAfter: [clone]
      workspaces:
        - { name: source, workspace: shared }
      taskSpec:                       # inline Task — no external ref needed
        workspaces:
          - name: source
        steps:
          - name: go-test
            image: golang:1.23
            workingDir: $(workspaces.source.path)
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              go test -race ./...

    - name: build-push
      runAfter: [unit-test]           # gate: build only after tests pass
      taskRef:
        resolver: hub
        params:
          - { name: kind, value: task }
          - { name: name, value: kaniko }
          - { name: version, value: "0.6" }
      params:
        - { name: IMAGE, value: $(params.image-ref) }
      workspaces:
        - { name: source, workspace: shared }
        - { name: dockerconfig, workspace: dockerconfig }
```

```yaml
# pipelinerun.yaml — one execution
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-test-push-
spec:
  pipelineRef:
    name: build-test-push
  taskRunTemplate:
    serviceAccountName: build-bot     # RBAC identity for every TaskRun Pod
  params:
    - { name: repo-url,  value: https://github.com/acme/widget.git }
    - { name: revision,  value: main }
    - { name: image-ref, value: registry.internal.acme.io/widget:ci }
  workspaces:
    - name: shared
      volumeClaimTemplate:            # ephemeral PVC, one per run
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests: { storage: 1Gi }
    - name: dockerconfig
      secret:
        secretName: registry-credentials
```

### 3.4 Argo Workflows — the same pipeline as a DAG

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ci-
spec:
  entrypoint: pipeline
  serviceAccountName: build-bot
  arguments:
    parameters:
      - { name: repo, value: https://github.com/acme/widget }
      - { name: revision, value: main }
      - { name: image, value: registry.internal.acme.io/widget:ci }
  volumeClaimTemplates:               # shared work volume, auto-mounted by name
    - metadata: { name: work }
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 1Gi }
  volumes:
    - name: docker-config
      secret:
        secretName: registry-credentials
        items:
          - { key: .dockerconfigjson, path: config.json }
  templates:
    - name: pipeline
      dag:
        tasks:
          - { name: clone, template: git-clone }
          - { name: test,  template: go-test,  dependencies: [clone] }
          - { name: build, template: kaniko,   dependencies: [test] }

    - name: git-clone
      container:
        image: alpine/git:2.45.2
        command: [sh, -c]
        args: ["git clone --depth 1 -b {{workflow.parameters.revision}} {{workflow.parameters.repo}} /work/src"]
        volumeMounts: [{ name: work, mountPath: /work }]

    - name: go-test
      container:
        image: golang:1.23
        workingDir: /work/src
        command: [sh, -c]
        args: ["go test -race ./..."]
        volumeMounts: [{ name: work, mountPath: /work }]

    - name: kaniko
      container:
        image: gcr.io/kaniko-project/executor:v1.23.2
        args:
          - --context=/work/src
          - --dockerfile=/work/src/Dockerfile
          - --destination={{workflow.parameters.image}}
        volumeMounts:
          - { name: work, mountPath: /work }
          - { name: docker-config, mountPath: /kaniko/.docker }
```

Note both engines encode the **test → build gate** structurally: Tekton with `runAfter`, Argo with `dependencies`. In a DAG engine, a failed dependency short-circuits the branch — the build node never schedules.

---

## 4. CLI and real terminal output

### Tekton

```console
$ tkn pipeline start build-test-push \
    --param repo-url=https://github.com/acme/widget.git \
    --param revision=main \
    --param image-ref=registry.internal.acme.io/widget:ci \
    --workspace name=shared,volumeClaimTemplateFile=./workspace-pvc.yaml \
    --workspace name=dockerconfig,secret=registry-credentials \
    --serviceaccount build-bot \
    --showlog
PipelineRun started: build-test-push-9tq4x
Waiting for logs to be available ...
[clone : clone] {"level":"info","msg":"Successfully cloned https://github.com/acme/widget.git @ main (grafted, HEAD)"}
[unit-test : go-test] ok      github.com/acme/widget/pkg/handler   0.412s
[unit-test : go-test] ok      github.com/acme/widget/pkg/store     0.207s
[build-push : build-and-push] INFO[0002] Retrieving image manifest golang:1.23
[build-push : build-and-push] INFO[0041] Pushing image to registry.internal.acme.io/widget:ci
[build-push : build-and-push] INFO[0047] Pushed registry.internal.acme.io/widget@sha256:1c9f7e...bd21

$ kubectl get pipelinerun
NAME                  SUCCEEDED   REASON      STARTTIME   COMPLETIONTIME
build-test-push-9tq4x True        Succeeded   3m12s       9s

$ tkn pipelinerun describe build-test-push-9tq4x
Status
 STARTED   DURATION   STATUS
 3m ago    3m3s       Succeeded
Taskruns
 NAME                              TASK NAME    STATUS
 build-test-push-9tq4x-build-push  build-push   Succeeded
 build-test-push-9tq4x-unit-test   unit-test    Succeeded
 build-test-push-9tq4x-clone       clone        Succeeded
```

### Argo Workflows

```console
$ argo submit -n ci workflow.yaml --watch
Name:                ci-2f8kd
Namespace:           ci
Status:              Running
  ├─✔ clone   git-clone   ci-2f8kd-1913...   6s
  ├─✔ test    go-test     ci-2f8kd-2277...   11s
  └─◷ build   kaniko      ci-2f8kd-3841...   (running)

$ argo get -n ci ci-2f8kd
STATUS: Succeeded
Duration: 1 minute 4 seconds
```

### GitHub Actions

```console
$ gh run list --workflow=ci.yaml --limit 3
STATUS  TITLE               WORKFLOW            BRANCH  EVENT  ID           ELAPSED
✓       fix: store retries  ci-build-test-sign  main    push   1187234455   1m48s
X       flaky store test    ci-build-test-sign  main    push   1187219902   58s

$ gh run view 1187219902 --log-failed
test  Enforce coverage floor (>= 70%)  total coverage: 61.4%
test  Enforce coverage floor (>= 70%)  ##[error]Process completed with exit code 1.
```

### Verifying the CI output (the CI→CD handoff artifact)

```console
$ cosign verify \
    --certificate-identity-regexp "https://github.com/acme/.+" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/widget@sha256:1c9f7e...bd21
Verification for ghcr.io/acme/widget@sha256:1c9f7e...bd21 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

---

## 5. Verification and failure diagnosis

The value of a Kubernetes-native CI engine is that **every failure is a Kubernetes failure** you already know how to debug: a Pod, an Event, a describe.

| Symptom | Most likely cause | First command |
|---|---|---|
| `PipelineRun`/`Workflow` stuck **Pending** | Unschedulable Pod: no CPU/mem, PVC unbound, or missing ServiceAccount | `kubectl describe taskrun <n>` → read Events |
| TaskRun Pod `ImagePullBackOff` | Bad step image ref or private registry with no pull secret | `kubectl describe pod <p>` |
| Kaniko push `401 UNAUTHORIZED` | `dockerconfig`/registry Secret wrong or not mounted at `/kaniko/.docker` | `kubectl get secret registry-credentials -o yaml` |
| PVC `Pending` (workspace) | No default `StorageClass` / `ReadWriteOnce` conflict | `kubectl get pvc,storageclass` |
| ARC jobs never start (`Queued`) | Listener not connected, GitHub App perms, or `runs-on` ≠ `runnerScaleSetName` | `kubectl logs -n arc-systems deploy/arc-gha-rs-controller` |
| Job passes locally, fails in CI | Non-hermetic test (network, time, ordering) | Re-run with `-race`; inspect step logs |
| Signature verify fails downstream | Signed a tag, not the digest; tag repointed | `cosign verify ...@sha256:<digest>` |

**Canonical diagnosis workflow (Tekton):**

```console
# 1. What failed, and why?
$ tkn pipelinerun describe build-test-push-9tq4x
...
 build-test-push-9tq4x-build-push  build-push  Failed

# 2. The failing TaskRun's Pod and its Events (scheduling / mount / pull problems live here)
$ kubectl describe taskrun build-test-push-9tq4x-build-push
Events:
  Warning  FailedScheduling  0/6 nodes are available: 6 Insufficient cpu.

# 3. Cluster-wide events, newest last (catches quota + PVC binding issues)
$ kubectl get events --sort-by=.lastTimestamp -n ci | tail

# 4. Stream the exact step logs
$ tkn taskrun logs build-test-push-9tq4x-build-push -f
```

**Argo equivalent:** `argo get -n ci <wf>` for the DAG state, then `argo logs -n ci <wf> <node>` for a specific node. **GitHub Actions:** `gh run view <id> --log-failed` jumps straight to the failing step.

**A hard gate that should exist in every pipeline** — reject an image that is not signed *before* CD ever sees it. This is the verifiable contract at the seam:

```console
$ cosign verify --certificate-identity-regexp 'https://github.com/acme/.+' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "$IMAGE_DIGEST" || { echo "unsigned artifact — refusing to publish"; exit 1; }
```

---

## 6. References

- **CNPA curriculum (official):** https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- **CNPA certification page (Linux Foundation):** https://training.linuxfoundation.org/certification/cloud-native-platform-engineering-associate-cnpa/
- **Tekton Pipelines documentation:** https://tekton.dev/docs/pipelines/
- **Tekton Hub (git-clone, kaniko Tasks):** https://hub.tekton.dev/
- **Tekton Triggers (event-driven CI):** https://tekton.dev/docs/triggers/
- **Argo Workflows documentation:** https://argo-workflows.readthedocs.io/en/stable/
- **GitHub Actions documentation:** https://docs.github.com/en/actions
- **Actions Runner Controller (ARC):** https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller
- **Kaniko:** https://github.com/GoogleContainerTools/kaniko
- **BuildKit (moby):** https://github.com/moby/buildkit
- **Buildah:** https://buildah.io/
- **Sigstore / cosign documentation:** https://docs.sigstore.dev/
- **SLSA — Supply-chain Levels for Software Artifacts:** https://slsa.dev/
- **CD Foundation (Tekton, governance):** https://cd.foundation/