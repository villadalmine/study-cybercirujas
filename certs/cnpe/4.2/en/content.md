# CNPE Study Guide — Topic 4.2: Building and Configuring CI/CD Pipelines Integrated with Kubernetes

**Certification Exam:** Certified Cloud Native Platform Engineer (CNPE)  
**Domain:** GitOps and Continuous Delivery  
**Topic 4.2:** Building and Configuring CI/CD Pipelines Integrated with Kubernetes  
**Exam Weight:** 8.33%  

---

## 1. Production Architectural Motivation & Problem Statement

### Legacy Push-Based CI/CD Vulnerabilities in Enterprise Kubernetes

Traditional enterprise CI/CD architectures rely on **push-based deployment models**, where an external CI runner (e.g., Jenkins, GitHub-hosted runners, GitLab CI) builds application artifacts and executes `kubectl apply` or `helm upgrade` directly against remote target Kubernetes API servers. In production multi-tenant environments, this pattern introduces severe architectural flaws and security risks:

```
[ External CI Engine ] --( Static High-Privilege Token )--> [ Kubernetes API Server ]
        │                                                            │
        ├── Builds Container Image (Requires Docker Socket / Root)    ├── Mutates Cluster State directly
        └── Pushes to Registry & Modifies Live Workloads             └── Bypasses Internal RBAC Boundaries
```

1. **Credential Exposure and Static Secret Sprawl**: Push pipelines require long-lived cluster credentials (e.g., `kubeconfig` files, static service account tokens) stored in external CI platforms. If a CI runner or third-party CI plugin is compromised, an attacker gains unrestricted admin or cluster-wide write access to production clusters.
2. **Elevated Privileges for Image Construction**: Traditional in-cluster or CI image builds often rely on mounting the host system's Docker socket (`/var/run/docker.sock`) or running container build jobs with `privileged: true`. This grants containers effective host root access, exposing the cluster to container breakout attacks (e.g., CVE-2019-5736, CVE-2022-0492).
3. **Configuration Drift and Absence of Single Source of Truth**: When CI directly mutates cluster state via `kubectl apply`, cluster state diverges from Git over time due to manual operator overrides, emergency hotfixes, or untracked state changes.
4. **Lack of Cryptographic Software Supply Chain Integrity**: Without automated, in-pipeline image signing (Sigstore/Cosign) and Software Bill of Materials (SBOM) generation (SLSA compliance), malicious or untrusted images can bypass deployment checks.

### Secure Zero-Trust Cloud-Native Pipeline Architecture

To address these vulnerabilities, modern Kubernetes platform engineering establishes a strict **De-coupled Hybrid Architecture**:

```
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │                                           CI BUILD PHASE                                                │
 │                                                                                                         │
 │  [ Git Commit ] ──> [ OIDC Federation ] ──> [ Tekton / Kaniko Job ] ──> [ Container Registry ]         │
 │                            │                           │                            │                   │
 │                            ▼                           ▼                            ▼                   │
 │                     Short-Lived JWT             Rootless Build               Signed Image + SBOM    │
 └────────────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                          │ Updates Manifest Tag
                                                          ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
 │                                          CD GITOPS PHASE                                                │
 │                                                                                                         │
 │  [ Deployment Repository ] ──( Pull Reconciliation )──> [ Argo CD Operator ] ──> [ Argo Rollouts ]      │
 │                                                                 │                         │             │
 │                                                                 ▼                         ▼             │
 │                                                         Kyverno Policy Check      Canary / Analysis     │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

* **Zero Static Credentials via OIDC**: External CI runners exchange short-lived OIDC JSON Web Tokens (JWT) for ephemeral Kubernetes ServiceAccount tokens or cloud IAM roles, eliminating static API keys.
* **Zero-Trust Rootless In-Cluster Building**: Image builds execute inside ephemeral, unprivileged Kubernetes Pods using tools like **Kaniko** or **BuildKit** that operate within restricted Security Contexts without requiring Docker socket access or elevated Linux capabilities.
* **Separation of CI and CD via GitOps**: The CI engine is restricted strictly to linting, testing, image building, signing, and updating target deployment manifests in Git. **Argo CD** or **Flux** running inside the target cluster pulls and reconciles those declarative changes natively, eliminating inbound API access from CI systems.
* **Progressive Delivery with Automated Guardrails**: Deployment updates utilize **Argo Rollouts** with automated metrics analysis (Prometheus/Datadog) to perform automated Canary rollouts and zero-downtime rollbacks without human intervention.

---

## 2. Technical Comparisons & Trade-off Tables

### Matrix 1: Deployment Paradigms — Push-Based CI/CD vs. Pull-Based GitOps Integration

| Metric / Dimension | Push-Based CI/CD (`kubectl` / Helm from CI) | Pull-Based GitOps (Argo CD / Flux) | Enterprise Recommendation |
| :--- | :--- | :--- | :--- |
| **Security Boundary** | High Risk: External CI engine requires network connectivity and admin credentials to Kubernetes API. | Low Risk: No inbound open ports required. Cluster pulls declaratively from Git repository. | **Pull-Based GitOps** for production cluster boundaries. |
| **Credential Lifetime** | Long-lived static service account tokens, cloud provider secret keys, or certificates. | Ephemeral internal service accounts; Git authentication via SSH keys / fine-grained PATs. | **Pull-Based GitOps** using ephemeral OIDC tokens. |
| **Drift Detection & Remediation** | None. Manual changes (`kubectl edit`) persist until overwritten by the next CI run. | Continuous background reconciliation. Auto-detects and heals unauthorized drift back to Git state. | **Pull-Based GitOps**. Enforces Git as single source of truth. |
| **Auditability & Traceability** | Disjointed logs split across CI system web interfaces and Kubernetes audit logs. | Complete audit trail backed by immutable `git log` commits and GPG signatures. | **Pull-Based GitOps**. |
| **Rollback Complexity** | Imperative re-execution of historical CI pipeline jobs; susceptible to script failures. | Declarative revert via `git revert` or instant rollback via Argo CD state pointer sync. | **Pull-Based GitOps**. |

### Matrix 2: In-Cluster Container Image Construction Engines

| Architecture / Feature | Docker-in-Docker (DinD) | Kaniko | BuildKit (Daemonless mode) | Cloud Native Buildpacks (Pack) |
| :--- | :--- | :--- | :--- | :--- |
| **Security Context** | Requires `privileged: true` & `CAP_SYS_ADMIN`. Host compromise risk. | Fully rootless execution. Runs under `securityContext.runAsNonRoot: true`. | Supports unprivileged user namespaces and rootless mode. | Runs rootless without privilege escalation. |
| **Host Dependencies** | Requires Host `/var/run/docker.sock` or host dockerd daemon. | Zero host system dependencies. Operates in userspace. | Zero host system dependencies (daemonless pod). | Depends on unprivileged OCI container runtimes. |
| **Layer Caching** | High efficiency (uses local host Docker layer store). | Remote registry layer caching (`--cache=true --cache-dir`). | Advanced caching (inline, registry, S3, gcs backends). | Reusable persistent volume cache for buildpack layers. |
| **Multi-Stage Build Support**| Full native support. | Full native support. | Native support with concurrent stage execution. | Abstracted away via buildpack build phases. |
| **Dockerfile Dependency** | Mandates `Dockerfile`. | Mandates `Dockerfile`. | Mandates `Dockerfile`. | Auto-detects language runtime without `Dockerfile`. |

### Matrix 3: Native Kubernetes Orchestration Engines for Pipelines

| Dimension | Tekton Pipelines | Argo Workflows | GitHub Actions with ARC (Actions Runner Controller) |
| :--- | :--- | :--- | :--- |
| **Architecture Base** | Kubernetes-native CRDs (`Task`, `Pipeline`, `PipelineRun`). | Kubernetes-native CRDs (`Workflow`, `WorkflowTemplate`, `CronWorkflow`). | Kubernetes operator managing dynamic Pod instances of GitHub self-hosted runners. |
| **Workload Scope** | Purpose-built for CI/CD container lifecycle management. | General-purpose DAG execution, data processing, and CI/CD pipelines. | General-purpose GitHub CI work executing natively on Kubernetes compute. |
| **Event Trigger Engine** | Tekton Triggers (`EventListener`, `TriggerBinding`, `TriggerTemplate`). | Argo Events (`EventSource`, `Sensor`, `EventDelivery`). | GitHub Webhooks driving native runner allocation via ARC. |
| **Multi-Tenancy Isolation**| Native namespace isolation via Kubernetes RBAC and ServiceAccount binding. | Namespace-scoped and Cluster-wide workflow controller paradigms. | Runner scale sets bounded by target namespaces and node pools. |
| **Footprint & Overhead** | Extremely lightweight controller overhead (~50MB RAM). | Medium controller overhead (~200MB RAM). | Requires ARC controller + ephemeral Pod overhead per job. |

---

## 3. Complete, Production-Grade YAML Manifests & Infrastructure Specs

### 3.1 OIDC Authentication & Minimal RBAC for External CI Runners

This manifest creates a Kubernetes ServiceAccount bound to an OpenID Connect (OIDC) identity provider (e.g., GitHub Actions), granting only the minimum permissions required to write Tekton `PipelineRun` resources into the `ci-pipelines` namespace.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ci-pipelines
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-actions-pipeline-runner
  namespace: ci-pipelines
  annotations:
    iam.gke.io/gcp-service-account: "ci-runner@prod-platform-project.iam.gserviceaccount.com"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tekton-pipeline-executor
  namespace: ci-pipelines
rules:
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns", "taskruns"]
    verbs: ["create", "get", "list", "watch", "update", "patch"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelines", "tasks"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-github-actions-tekton
  namespace: ci-pipelines
subjects:
  - kind: ServiceAccount
    name: github-actions-pipeline-runner
    namespace: ci-pipelines
roleRef:
  kind: Role
  name: tekton-pipeline-executor
  apiGroup: rbac.authorization.k8s.io
```

---

### 3.2 Secure Tekton CI Pipeline Manifest (Kaniko Build, Cosign Sign, Git Bump)

This complete Tekton configuration includes:
1. A **Rootless Kaniko Task** that builds a container image and generates an OCI layout artifact.
2. A **Cosign Task** that signs the built container image using keyless OIDC ambient tokens.
3. A **Pipeline** wiring these tasks securely under restricted pod security standards.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: build-kaniko-unprivileged
  namespace: ci-pipelines
spec:
  description: "Builds a Dockerfile with Kaniko without requiring root privileges or Docker socket."
  params:
    - name: IMAGE
      type: string
      description: "Target container image reference (registry/repo:tag)."
    - name: DOCKERFILE
      type: string
      default: "./Dockerfile"
      description: "Path to Dockerfile relative to context."
    - name: CONTEXT
      type: string
      default: "."
      description: "Path to build context directory."
  workspaces:
    - name: source
      description: "Workspace containing application code."
    - name: dockerconfig
      description: "Workspace containing registry secret json."
      optional: true
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command:
        - /kaniko/executor
      args:
        - --dockerfile=$(params.DOCKERFILE)
        - --context=$(workspaces.source.path)/$(params.CONTEXT)
        - --destination=$(params.IMAGE)
        - --digest-file=$(workspaces.source.path)/image-digest
        - --cache=true
        - --cache-dir=$(workspaces.source.path)/.cache
        - --reproducible=true
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        capabilities:
          drop:
            - ALL
          add:
            - SETUID
            - SETGID
      volumeMounts:
        - name: kaniko-secret
          mountPath: /kaniko/.docker
  volumes:
    - name: kaniko-secret
      secret:
        secretName: regcred
        items:
          - key: .dockerconfigjson
            path: config.json
---
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: sign-cosign
  namespace: ci-pipelines
spec:
  description: "Signs a container image using Cosign and Sigstore."
  params:
    - name: IMAGE_DIGEST_FILE
      type: string
      description: "Path to file containing image digest."
    - name: IMAGE_REPO
      type: string
      description: "Repository path of the image."
  workspaces:
    - name: source
  steps:
    - name: cosign-sign
      image: gcr.io/projectsigstore/cosign:v2.4.1
      script: |
        #!/usr/bin/sh
        set -e
        DIGEST=$(cat $(workspaces.source.path)/$(params.IMAGE_DIGEST_FILE))
        FULL_IMAGE="$(params.IMAGE_REPO)@${DIGEST}"
        echo "Signing image: ${FULL_IMAGE}"
        cosign sign --yes --key k8s://ci-pipelines/cosign-keys ${FULL_IMAGE}
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
---
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: app-ci-pipeline
  namespace: ci-pipelines
spec:
  params:
    - name: git-url
      type: string
    - name: image-repo
      type: string
    - name: image-tag
      type: string
  workspaces:
    - name: shared-workspace
  tasks:
    - name: fetch-repository
      taskRef:
        resolver: cluster
        params:
          - name: kind
            value: task
          - name: name
            value: git-clone
          - name: namespace
            value: tekton-tasks
      params:
        - name: url
          value: $(params.git-url)
        - name: revision
          value: "main"
      workspaces:
        - name: output
          workspace: shared-workspace
    - name: build-image
      runAfter:
        - fetch-repository
      taskRef:
        name: build-kaniko-unprivileged
      params:
        - name: IMAGE
          value: "$(params.image-repo):$(params.image-tag)"
      workspaces:
        - name: source
          workspace: shared-workspace
    - name: sign-image
      runAfter:
        - build-image
      taskRef:
        name: sign-cosign
      params:
        - name: IMAGE_DIGEST_FILE
          value: "image-digest"
        - name: IMAGE_REPO
          value: "$(params.image-repo)"
      workspaces:
        - name: source
          workspace: shared-workspace
---
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: app-ci-pipeline-run-001
  namespace: ci-pipelines
spec:
  pipelineRef:
    name: app-ci-pipeline
  params:
    - name: git-url
      value: "https://github.com/enterprise/payment-service.git"
    - name: image-repo
      value: "quay.io/enterprise/payment-service"
    - name: image-tag
      value: "v2.4.0"
  taskRunTemplate:
    serviceAccountName: github-actions-pipeline-runner
    podTemplate:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi
```

---

### 3.3 Production GitOps & Canary Deployment Manifests (Argo CD & Argo Rollouts)

#### Argo CD Application Manifest Enforcing Strict Synchronization Security

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: production-apps
  source:
    repoURL: 'https://github.com/enterprise/gitops-manifests.git'
    targetRevision: HEAD
    path: apps/payment-service/overlays/production
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: payment-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - Validate=true
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

#### Argo Rollout Manifest with Automated Prometheus Metric Analysis

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service
  namespace: payment-production
  labels:
    app.kubernetes.io/name: payment-service
spec:
  replicas: 10
  strategy:
    canary:
      canaryService: payment-service-canary
      stableService: payment-service-stable
      trafficRouting:
        nginx:
          stableIngress: payment-service-ingress
      steps:
        - setWeight: 10
        - pause: { duration: 5m }
        - setWeight: 25
        - analysis:
            templates:
              - templateName: success-rate-and-latency-check
            args:
              - name: service-name
                value: payment-service-canary
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 75
        - pause: { duration: 5m }
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-service
    spec:
      containers:
        - name: payment-api
          image: quay.io/enterprise/payment-service:v2.4.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1024Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-and-latency-check
  namespace: payment-production
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 30s
      successCondition: result[0] >= 0.995
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(http_requests_total{job="{{args.service-name}}", status!~"5.*"}[2m]))
            /
            sum(rate(http_requests_total{job="{{args.service-name}}"}[2m]))
    - name: latency-p99
      interval: 30s
      successCondition: result[0] <= 0.200
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="{{args.service-name}}"}[2m])) by (le))
```

---

## 4. Real CLI Commands and Expected Terminal Outputs

### Step 1: Validate Kubernetes OIDC Token Exchange for CI Runner

Execute an authenticated request using an ephemeral OIDC ServiceAccount token to verify API permission scopes.

```bash
$ kubectl auth can-i create pipelineruns.tekton.dev \
  --as=system:serviceaccount:ci-pipelines:github-actions-pipeline-runner \
  -n ci-pipelines
```

```
yes
```

Check prohibited operations to confirm minimal RBAC scope enforcement:

```bash
$ kubectl auth can-i delete deployments \
  --as=system:serviceaccount:ci-pipelines:github-actions-pipeline-runner \
  -n payment-production
```

```
no - RBAC permissions deny system:serviceaccount:ci-pipelines:github-actions-pipeline-runner from performing "delete" on "deployments" in namespace "payment-production"
```

---

### Step 2: Trigger and Monitor Tekton In-Cluster Pipeline Execution

Trigger the Tekton `PipelineRun` using the Tekton CLI (`tkn`):

```bash
$ tkn pipeline start app-ci-pipeline \
  --namespace ci-pipelines \
  --param git-url="https://github.com/enterprise/payment-service.git" \
  --param image-repo="quay.io/enterprise/payment-service" \
  --param image-tag="v2.4.0" \
  --workspace name=shared-workspace,claimName=pipeline-pvc \
  --showlog
```

```
PipelineRun started: app-ci-pipeline-run-manual-8x4kz
Waiting for logs to be available...
[fetch-repository : clone] OK. Cloned revision main at commit b4a71d9e2f.
[build-image : build-and-push] INFO[0000] Resolving base image golang:1.23-alpine
[build-image : build-and-push] INFO[0004] Taking snapshot of full filesystem...
[build-image : build-and-push] INFO[0012] Step 1/8 : FROM golang:1.23-alpine AS builder
[build-image : build-and-push] INFO[0018] Pushing image quay.io/enterprise/payment-service:v2.4.0
[build-image : build-and-push] INFO[0022] Pushed quay.io/enterprise/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
[sign-image : cosign-sign] Signing image: quay.io/enterprise/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
[sign-image : cosign-sign] Verification key generated. Public key written to cosign.pub.
[sign-image : cosign-sign] Signing payload with certificate identity: https://kubernetes.io/namespaces/ci-pipelines/serviceaccounts/github-actions-pipeline-runner
[sign-image : cosign-sign] Signature published to registry.

PipelineRun completed successfully.
```

---

### Step 3: Verify Cryptographic Supply Chain Image Signature with Cosign

Inspect the published container image signature using `cosign`:

```bash
$ cosign verify \
  --key k8s://ci-pipelines/cosign-keys \
  quay.io/enterprise/payment-service:v2.4.0
```

```
Verification for quay.io/enterprise/payment-service:v2.4.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims below were verified against verification key:
[{"critical":{"identity":{"docker-reference":"quay.io/enterprise/payment-service"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":null}]
```

---

### Step 4: Inspect Argo CD Synchronized GitOps State

Query Argo CD via CLI to confirm reconciliation status of target application:

```bash
$ argocd app get payment-service-prod --refresh
```

```
Name:               argocd/payment-service-prod
Project:            production-apps
Server:             https://kubernetes.default.svc
Namespace:          payment-production
URL:                https://argocd.platform.internal/applications/payment-service-prod
Repo:               https://github.com/enterprise/gitops-manifests.git
Target:             HEAD
Path:               apps/payment-service/overlays/production
Sync Window:        Sync Allowed
Sync Status:        Synced to HEAD (b4a71d9)
Health Status:      Healthy

GROUP        KIND              NAMESPACE           NAME                    STATUS  HEALTH   HOOK  MESSAGE
             Service           payment-production  payment-service-stable  Synced  Healthy        service/payment-service-stable created
             Service           payment-production  payment-service-canary  Synced  Healthy        service/payment-service-canary created
argoproj.io  Rollout           payment-production  payment-service         Synced  Healthy        rollout.argoproj.io/payment-service configured
networking   Ingress           payment-production  payment-service-ingress Synced  Healthy        ingress.networking.k8s.io/payment-service-ingress configured
```

---

### Step 5: Monitor Canary Promotion via Argo Rollouts CLI

Track real-time Canary rollout metrics analysis and traffic weight transitions:

```bash
$ kubectl argo rollouts get rollout payment-service -n payment-production
```

```
Name:            payment-service
Namespace:       payment-production
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          2/5 (setWeight: 25)
  SetWeight:     25
  ActualWeight:  25
Images:          quay.io/enterprise/payment-service:v2.3.9 (stable)
                 quay.io/enterprise/payment-service:v2.4.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       3
  Stable:        7
  Available:     10
  Unavailable:   0

NAME                                                   KIND        STATUS     AGE    INFO
├── revision:12                                        ReplicaSet  stable     5d     quay.io/enterprise/payment-service:v2.3.9
│   └── payment-service-7d4b9b9449                     pod         Running    5d     ready:1/1
└── revision:13                                        ReplicaSet  canary     3m20s  quay.io/enterprise/payment-service:v2.4.0
    ├── payment-service-58997c6d66-ab12                pod         Running    3m18s  ready:1/1
    ├── payment-service-58997c6d66-cd34                pod         Running    3m18s  ready:1/1
    └── payment-service-58997c6d66-ef56                pod         Running    3m18s  ready:1/1

NAME                                                   TYPE        STATUS     SUCCESS AGE
└── success-rate-and-latency-check-13-2                AnalysisRun Successful 3/3     1m45s
    ├── success-rate                                   Metric      Successful 3/3     1m45s
    └── latency-p99                                    Metric      Successful 3/3     1m45s
```

---

## 5. Verification, Failure Diagnostics & Troubleshooting Guide

### Enterprise Troubleshooting Matrix for Kubernetes CI/CD Integrations

```
                                  DIAGNOSTIC WORKFLOW
                                           │
          ┌────────────────────────────────┼────────────────────────────────┐
          ▼                                ▼                                ▼
  [ Kaniko Pod Failed ]          [ OIDC Auth Error ]             [ Argo Rollout Aborted ]
          │                                │                                │
  Check SecurityContext           Check JWT Audience &            Check Prometheus Metrics &
  & Namespace PSS Level           ServiceAccount Annotation       AnalysisRun Logs
```

#### Diagnostic 1: Kaniko In-Cluster Build Fails under `restricted` Pod Security Standards
* **Symptom**: Pod fails immediately upon startup with `CreateContainerConfigError` or `PodSecurityViolation: privileged container forbidden`.
* **Root Cause**: The cluster namespace enforces `pod-security.kubernetes.io/enforce: restricted`. Standard Kaniko images require root privileges (`runAsUser: 0`) and specific Linux capabilities (`SETUID`, `SETGID`) to extract layer archives into root filesystems.
* **Resolution**:
  1. Set namespace PSS policy to `baseline` OR run Kaniko in unprivileged mode using user namespaces.
  2. Configure `securityContext` explicitly on the task step:
     ```yaml
     securityContext:
       runAsUser: 0
       capabilities:
         drop: ["ALL"]
         add: ["SETUID", "SETGID"]
     ```
  3. Ensure workspace volume is backed by `emptyDir` or standard `PersistentVolumeClaim` with `readOnly: false`.

#### Diagnostic 2: External CI OIDC Exchange Returns `401 Unauthorized`
* **Symptom**: External CI runner log shows `Error: Could not retrieve WebIdentityToken / OpenIDConnect exchange failed: Unauthorized`.
* **Root Cause**: Mismatch between the JWT payload issuer (`iss`), audience (`aud`), or subject claim (`sub`) sent by the CI provider and the identity provider configuration in Kubernetes / Cloud IAM.
* **Resolution**:
  1. Inspect the raw JWT token issued by the CI system using `jq`:
     ```bash
     $ echo $CI_OIDC_TOKEN | jq -R 'split(".") | .[1] | @base64d | fromjson'
     ```
  2. Verify that the `aud` field matches expected target (e.g., `sts.amazonaws.com` or `https://container.googleapis.com/v1/projects/...`).
  3. Confirm the Kubernetes ServiceAccount metadata contains correct annotations matching the federated identity subject:
     ```yaml
     annotations:
       iam.gke.io/gcp-service-account: "ci-runner@project.iam.gserviceaccount.com"
     ```

#### Diagnostic 3: Argo CD Application Stuck in `OutOfSync` with CRD Schema Errors
* **Symptom**: Argo CD dashboard displays `SyncFailed` with message `Unknown field "analysis" in io.argoproj.v1alpha1.Rollout`.
* **Root Cause**: The target cluster lacks the Custom Resource Definitions (CRDs) for Argo Rollouts or the CRD version installed on the cluster is older than the API version declared in Git manifests.
* **Resolution**:
  1. Verify installed CRD versions on cluster:
     ```bash
     $ kubectl get crd rollouts.argoproj.io -o jsonpath='{.spec.versions[*].name}'
     ```
  2. Apply missing CRDs directly via cluster admin credentials before sync:
     ```bash
     $ kubectl apply -k https://github.com/argoproj/argo-rollouts/manifests/crds?ref=v1.7.2
     ```
  3. Force Argo CD hard refresh to clear cached discovery schemas:
     ```bash
     $ argocd app get payment-service-prod --hard-refresh
     ```

#### Diagnostic 4: Argo Rollouts Automated Canary Rollback Triggered by Failed Analysis
* **Symptom**: Rollout automatically degrades to previous stable version; status indicates `Degraded: RolloutAborted`.
* **Root Cause**: The Prometheus metric query defined in `AnalysisTemplate` failed to meet the `successCondition` threshold during the Canary observation window.
* **Resolution**:
  1. Inspect `AnalysisRun` instances to determine specific metric failure:
     ```bash
     $ kubectl get analysisrun -n payment-production -o wide
     ```
  2. View detailed metrics evaluated during failure:
     ```bash
     $ kubectl describe analysisrun success-rate-and-latency-check-13-2 -n payment-production
     ```
  3. Check raw Prometheus query result directly using `curl`:
     ```bash
     $ curl -g -s 'http://prometheus-k8s.monitoring.svc.cluster.local:9090/api/v1/query?query=sum(rate(http_requests_total{job="payment-service-canary",status=~"5.*"}[2m]))' | jq .
     ```

---

### Production SRE One-Liner Diagnostic Toolset

```bash
# 1. Tail logs of all failed pods in the ci-pipelines namespace
$ kubectl logs -n ci-pipelines -l tekton.dev/pipelineRun=app-ci-pipeline-run-001 --all-containers --tail=100 -f

# 2. Inspect active Rollout state and traffic routing rules
$ kubectl argo rollouts status payment-service -n payment-production

# 3. Force manual emergency sync override in Argo CD (Bypass health checks in break-glass scenarios)
$ argocd app sync payment-service-prod --strategy apply --force

# 4. Extract failed events across CI/CD namespaces sorted by timestamp
$ kubectl get events -n ci-pipelines --field-selector type=Warning --sort-by='.metadata.creationTimestamp'
```

---

## 6. References

* **CNCF Curriculum Repository**: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* **Tekton Pipelines Documentation**: [Tekton Pipeline Fundamentals & CRDs](https://tekton.dev/docs/pipelines/)
* **Argo CD Official Guide**: [Declarative Application Management & Sync Policies](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
* **Argo Rollouts Documentation**: [Canary Architecture & Prometheus Metric Analysis](https://argoproj.github.io/argo-rollouts/features/canary/)
* **Kaniko GitHub Repository**: [Unprivileged Container Builds in Kubernetes](https://github.com/GoogleContainerTools/kaniko)
* **Sigstore / Cosign Documentation**: [Container Image Signing and Keyless Verification](https://docs.sigstore.dev/cosign/overview/)
* **Kubernetes ServiceAccount OIDC Federation**: [Authenticating Workloads with OIDC Tokens](https://kubernetes.io/docs/concepts/security/service-accounts-oidc/)