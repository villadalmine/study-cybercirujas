# CNPE Topic 4.2: Building and Configuring CI/CD Pipelines Integrated with Kubernetes

**Exam:** CNCF Certified Cloud Native Platform Engineer (CNPE)  
**Domain:** Platform Building and Integration  
**Topic 4.2 Weight:** 8.33%  

---

### Official References & Specifications
* [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* [Tekton Pipelines v1 API Specification](https://tekton.dev/docs/pipelines/pipelines/)
* [Kubernetes Service Account Token Volume Projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection)
* [Argo CD Declarative Application Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-management/)
* [Sigstore Cosign Container Image Signing & Attestation](https://docs.sigstore.dev/cosign/overview/)
* [SLSA (Supply-chain Levels for Software Artifacts) v1.0 Specification](https://slsa.dev/spec/v1.0/about)

---

## Technical Deep Dive: Production Architecture & Mechanics

Integrating CI/CD natively into Kubernetes requires decoupling **Build/Artifact Generation (CI)** from **State Synchronization/Deployment (CD)**. Relying on privileged daemon-based container builders (such as mounting `/var/run/docker.sock` into CI pods) breaks multi-tenant security boundaries and introduces systemic host-level vulnerability risks.

```
                                  [ CI BOUNDARY (Tekton / Ephemeral Pods) ]
 +------------------+     Git Commit     +------------------------------------------------------+
 | Developer / SCM  | -----------------> | Tekton EventListener / TriggerBinding               |
 +------------------+                    +------------------------------------------------------+
                                                                   |
                                                                   v
                                         +------------------------------------------------------+
                                         | PipelineRun (ServiceAccount: builder-sa)            |
                                         |  ├── Task 1: Kaniko Unprivileged Build & Push        |
                                         |  └── Task 2: Cosign Keyless Image Signing (OIDC)     |
                                         +------------------------------------------------------+
                                                                   |
                                                                   v
                                         +------------------------------------------------------+
                                         | OCI Registry (Harbor / ECR / GHCR)                   |
                                         |  ├── image:v1.2.3                                    |
                                         |  └── image:v1.2.3.sig (Cosign Signature)            |
                                         +------------------------------------------------------+
                                                                   |
                                                                   | Image Digest Update
                                                                   v
                                  [ CD BOUNDARY (Argo CD / GitOps Engine) ]
                                         +------------------------------------------------------+
                                         | GitOps Repository (Helm / Kustomize)                |
                                         +------------------------------------------------------+
                                                                   |
                                                                   v
                                         +------------------------------------------------------+
                                         | Argo CD Application Controller                       |
                                         |  └── Enforces State on Target Kubernetes Cluster     |
                                         +------------------------------------------------------+
```

### Key Production Trade-offs & Architectural Considerations

1. **Unprivileged Rootless Container Builds (Kaniko vs. Buildkit in-pod)**:
   * **Kaniko** executes inside an unprivileged user namespace, unpacking the filesystem root image in memory and taking snapshots after each layer execution without requiring a running Docker daemon or `CAP_SYS_ADMIN` privileges.
   * *Trade-off:* Kaniko cannot leverage local layer caching across pod restarts unless backed by an external OCI registry cache (`--cache=true --cache-dir=...`), increasing build latencies compared to persistent daemon solutions.
2. **Workload Identity & Keyless Attestation (Sigstore / OIDC)**:
   * Pipelines leverage Kubernetes Projected ServiceAccount Tokens (`/var/run/secrets/tokens/vault-token` or custom OIDC audiences) to exchange short-lived Kubernetes JWT tokens for cloud-provider (AWS IAM, GCP Workload Identity, Keyless Sigstore Fulcio) credentials.
   * *Trade-off:* Eliminates static long-lived credentials stored in Kubernetes `Secrets`, but requires tight cryptographic trust configuration between the API Server's OpenID Connect Issuer and target Cloud IDPs.
3. **Workspace Isolation & Concurrency Control**:
   * Pipeline run state must be passed between steps using Kubernetes `PersistentVolumeClaims` (RWO/RWX) or ephemeral emptyDir volumes.
   * *Trade-off:* RWO volumes limit pipeline step execution to a single node. Ephemeral volumes require high pod memory allocation if large build contexts are transferred.

---

## Guided Exercise 1: Zero-Trust In-Cluster Build & Attestation Engine

### Step 1.1: Provision Least-Privilege Pipeline ServiceAccount and RBAC
To execute Tekton pipelines securely, you must create a dedicated `ServiceAccount` bound tightly to a custom `Role`. The `ServiceAccount` will utilize short-lived projected tokens rather than cluster secrets.

Create the namespace and RBAC configuration file `01-pipeline-rbac.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cicd-pipeline-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-builder-sa
  namespace: cicd-pipeline-system
  annotations:
    iam.gke.io/gcp-service-account: "sa-tekton-builder@prod-platform.iam.gserviceaccount.com"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tekton-builder-role
  namespace: cicd-pipeline-system
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["tekton.dev"]
    resources: ["tasks", "pipelines", "taskruns", "pipelineruns"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tekton-builder-binding
  namespace: cicd-pipeline-system
subjects:
  - kind: ServiceAccount
    name: tekton-builder-sa
    namespace: cicd-pipeline-system
roleRef:
  kind: Role
  name: tekton-builder-role
  apiGroup: rbac.authorization.k8s.io
```

Apply the manifest using `kubectl`:

```bash
kubectl apply -f 01-pipeline-rbac.yaml
```

**Expected Output:**
```text
namespace/cicd-pipeline-system created
serviceaccount/tekton-builder-sa created
role.rbac.authorization.k8s.io/tekton-builder-role created
rolebinding.rbac.authorization.k8s.io/tekton-builder-binding created
```

#### Question 1.1
What security vulnerability is mitigated by eliminating long-lived ServiceAccount token secrets (default prior to K8s 1.24) and relying on Projected ServiceAccount Tokens for CI/CD workers?

---

### Step 1.2: Define a Production Tekton Task with Kaniko Unprivileged Build
Create a syntactically valid Tekton `Task` manifest (`02-kaniko-build-task.yaml`) that pulls a repository context from a shared workspace, builds the image using Kaniko, and outputs the precise image digest.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kaniko-build-unsigned
  namespace: cicd-pipeline-system
spec:
  description: "Builds a Dockerfile with Kaniko inside an unprivileged pod environment."
  workspaces:
    - name: source-dir
      description: "Holds the fetched source repository containing the Dockerfile."
  params:
    - name: DOCKERFILE
      type: string
      description: "Path to the Dockerfile relative to the workspace root."
      default: "./Dockerfile"
    - name: IMAGE_DESTINATION
      type: string
      description: "Full target image reference (registry/repository:tag)."
  results:
    - name: IMAGE_DIGEST
      description: "Digest of the image produced by Kaniko."
    - name: IMAGE_URL
      description: "Fully qualified URL of the built image including tag."
  steps:
    - name: build-and-push
      image: gcr.io/kaniko-project/executor:v1.23.0-debug
      workingDir: $(workspaces.source-dir.path)
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        capabilities:
          drop:
            - ALL
      command:
        - /kaniko/executor
      args:
        - --dockerfile=$(params.DOCKERFILE)
        - --context=$(workspaces.source-dir.path)
        - --destination=$(params.IMAGE_DESTINATION)
        - --digest-file=$(results.IMAGE_DIGEST.path)
        - --oci-layout-path=$(workspaces.source-dir.path)/oci-layout
        - --single-snapshot
```

Apply the task manifest:

```bash
kubectl apply -f 02-kaniko-build-task.yaml
```

**Expected Output:**
```text
task.tekton.dev/kaniko-build-unsigned created
```

#### Question 1.2
Kaniko writes the image digest output to `$(results.IMAGE_DIGEST.path)`. How does Tekton handle the storage and underlying transport mechanism for `Task` results between execution steps?

---

### Step 1.3: Configure Cosign Keyless Image Signing Task
Now, create `03-cosign-sign-task.yaml` to enforce supply chain security by signing the image digest generated by the previous build step using Sigstore Cosign with ambient OIDC credentials.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: cosign-sign-image
  namespace: cicd-pipeline-system
spec:
  description: "Signs an OCI image digest using Sigstore Cosign keyless mode."
  params:
    - name: IMAGE_DIGEST
      type: string
      description: "Digest of the image to sign (e.g., repo/image@sha256:abc...)."
    - name: OIDC_PROVIDER
      type: string
      description: "OIDC Issuer URL for identity verification."
      default: "https://container.googleapis.com/v1/projects/prod-platform/locations/us-central1/clusters/prod-cluster"
  steps:
    - name: cosign-sign
      image: gcr.io/projectsigstore/cosign:v2.4.0
      env:
        - name: COSIGN_EXPERIMENTAL
          value: "1"
        - name: TUF_ROOT
          value: "/tmp/tuf"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65532
      command:
        - cosign
      args:
        - sign
        - --yes
        - $(params.IMAGE_DIGEST)
```

Apply the manifest:

```bash
kubectl apply -f 03-cosign-sign-task.yaml
```

**Expected Output:**
```text
task.tekton.dev/cosign-sign-image created
```

#### Question 1.3
Why is it mandatory in zero-trust production supply chains to sign container images by their **immutable digest (`@sha256:...`)** rather than by their mutable tag (`:v1.2.3`)?

---

### Step 1.4: Assemble the Pipeline and Trigger execution via PipelineRun
Create the complete orchestration pipeline manifest `04-build-sign-pipeline.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: secure-build-and-sign-pipeline
  namespace: cicd-pipeline-system
spec:
  workspaces:
    - name: shared-workspace
  params:
    - name: git-repo-url
      type: string
    - name: image-reference
      type: string
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
            value: cicd-pipeline-system
      workspaces:
        - name: output
          workspace: shared-workspace
      params:
        - name: url
          value: $(params.git-repo-url)
        - name: revision
          value: "main"

    - name: build-container-image
      taskRef:
        name: kaniko-build-unsigned
      runAfter:
        - fetch-repository
      workspaces:
        - name: source-dir
          workspace: shared-workspace
      params:
        - name: DOCKERFILE
          value: "./Dockerfile"
        - name: IMAGE_DESTINATION
          value: $(params.image-reference)

    - name: sign-container-image
      taskRef:
        name: cosign-sign-image
      runAfter:
        - build-container-image
      params:
        - name: IMAGE_DIGEST
          value: "$(params.image-reference)@$(tasks.build-container-image.results.IMAGE_DIGEST)"
---
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: secure-build-sign-pipelinerun-001
  namespace: cicd-pipeline-system
spec:
  pipelineRef:
    name: secure-build-and-sign-pipeline
  serviceAccountName: tekton-builder-sa
  params:
    - name: git-repo-url
      value: "https://github.com/cncf-demo/sample-microservice.git"
    - name: image-reference
      value: "quay.io/cncf_platform/sample-microservice:v1.0.0"
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

Execute the pipeline run:

```bash
kubectl apply -f 04-build-sign-pipeline.yaml
```

Monitor execution status via `tkn` CLI:

```bash
tkn pipelinerun describe secure-build-sign-pipelinerun-001 -n cicd-pipeline-system
```

**Expected Terminal Output:**
```text
Name:              secure-build-sign-pipelinerun-001
Namespace:         cicd-pipeline-system
Pipeline Ref:      secure-build-and-sign-pipeline
Service Account:   tekton-builder-sa
Status:            Succeeded
Started:           2 minutes ago
Duration:          1m42s

Taskruns

 NAME                                                     TASK NAME               STATUS      STARTED        DURATION
 secure-build-sign-pipelinerun-001-fetch-repository      fetch-repository        Succeeded   2 minutes ago  18s
 secure-build-sign-pipelinerun-001-build-container-image build-container-image  Succeeded   1 minute ago   54s
 secure-build-sign-pipelinerun-001-sign-container-image  sign-container-image   Succeeded   30 seconds ago 22s
```

---

## Guided Exercise 2: Automated GitOps Promotion and Progressive Delivery

Now that an authenticated, signed image is built, the CI system must notify the CD system (Argo CD) to update declarative deployments without providing the CI pipeline direct write access to the Kubernetes production cluster workload namespaces.

### Step 2.1: Configure Declarative Argo CD Application with Image Updater Strategy
Create `05-argocd-gitops-app.yaml` establishing an isolated Argo CD application configured to listen for new container digests and automatically commit image parameter changes back to the GitOps state repository.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service-prod
  namespace: argocd
  annotations:
    argocd-image-updater.argoproj.io/image-list: main=quay.io/cncf_platform/sample-microservice
    argocd-image-updater.argoproj.io/main.update-strategy: digest
    argocd-image-updater.argoproj.io/main.helm.image-name: image.repository
    argocd-image-updater.argoproj.io/main.helm.image-tag: image.tag
    argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/gitops-repo-creds
spec:
  project: default
  source:
    repoURL: 'https://github.com/cncf-demo/gitops-manifests.git'
    targetRevision: HEAD
    path: environments/production/payment-service
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: production-workloads
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - Validate=true
```

Apply the deployment:

```bash
kubectl apply -f 05-argocd-gitops-app.yaml
```

Verify application status via Argo CD CLI:

```bash
argocd app get payment-service-prod --refresh
```

**Expected Output:**
```text
Name:               argocd/payment-service-prod
Project:            default
Server:             https://kubernetes.default.svc
Namespace:          production-workloads
URL:                https://argocd.internal.domain/applications/payment-service-prod
Repo:               https://github.com/cncf-demo/gitops-manifests.git
Target:             HEAD
Path:               environments/production/payment-service
Sync Window:        Sync Allowed
Sync Status:        Synced to HEAD (a1b2c3d)
Health Status:      Healthy

GROUP  KIND        NAMESPACE             NAME             STATUS  HEALTH   HOOK  MESSAGE
       Namespace   production-workloads  production-work  Synced           
apps   Deployment  production-workloads  payment-service  Synced  Healthy        deployment.apps/payment-service created
v1     Service     production-workloads  payment-service  Synced  Healthy        service/payment-service created
```

#### Question 2.1
What is the structural security advantage of utilizing `write-back-method: git` in Argo CD Image Updater compared to having a CI task execute `kubectl set image deployment/...` directly against the production cluster?

---

### Step 2.2: Enforce In-Cluster Image Provenance and Cosign Verification Policy
Prevent unauthorized or unsigned container images from reaching the cluster runtime environment. Configure Kyverno policy enforcement (`06-verify-image-policy.yaml`) to validate Sigstore Cosign signatures prior to pod creation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-cosign-signature
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-signature-rule
      match:
        any:
        - resources:
            namespaces:
              - production-workloads
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "quay.io/cncf_platform/*"
          keyless:
            issuer: "https://container.googleapis.com/v1/projects/prod-platform/locations/us-central1/clusters/prod-cluster"
            subject: "https://github.com/cncf-demo/sample-microservice/.github/workflows/*"
          reconcileDigest: true
```

Apply the security policy:

```bash
kubectl apply -f 06-verify-image-policy.yaml
```

**Expected Output:**
```text
clusterpolicy.kyverno.io/verify-image-cosign-signature created
```

#### Question 2.2
If an attacker manually uploads a malicious image to `quay.io/cncf_platform/sample-microservice:v1.0.0` by overwriting the tag without signing the digest via Cosign, explain the sequence of events that occurs when Argo CD attempts to reconcile the deployment.

---

## Guided Exercise 3: Advanced Pipeline Diagnostics, Race-Conditions, and Security Auditing

### Step 3.1: Debugging Pipeline Workspace Storage Permission Deadlocks
A common production operational issue occurs when Tekton steps run under distinct user UIDs across multi-step tasks, resulting in volume permission lockouts on persistent workspaces.

Inspect a failing TaskRun:

```bash
kubectl get taskrun -n cicd-pipeline-system --sort-by='.metadata.creationTimestamp' | tail -n 1
```

**Output:**
```text
NAME                                                     SUCCEEDED   REASON       STARTTIME   COMPLETIONTIME
secure-build-sign-pipelinerun-002-build-container-image  False       Failed       3m12s       2m45s
```

Extract step logs to diagnose root failure:

```bash
tkn taskrun logs secure-build-sign-pipelinerun-002-build-container-image -n cicd-pipeline-system --step build-and-push
```

**Expected Log Error Stream:**
```text
Error: open /workspace/shared-workspace/oci-layout/index.json: permission denied
2026/08/07 19:15:22 execution failed at step build-and-push: exit status 1
```

Analyze volume ownership on the underlying storage node:

```bash
kubectl get pod secure-build-sign-pipelinerun-002-build-container-image-pod -n cicd-pipeline-system -o jsonpath='{.spec.securityContext}'
```

**Output:**
```json
{"fsGroup": 65532}
```

#### Question 3.1
Why did the Kaniko build step encounter a `permission denied` error despite `fsGroup` being configured on the Pod security context, and what specific `volumeClaimTemplate` or pod security parameter solves this condition natively in Tekton pipelines?

---

### Step 3.2: Debugging In-Cluster OIDC Identity Federation Failures
When keyless Cosign attestation fails inside a CI pipeline container step, engineers must verify token projection integrity.

Simulate OIDC validation failures by inspecting projected service account tokens mounted inside the builder pod:

```bash
kubectl exec -it secure-build-sign-pipelinerun-001-sign-container-image-pod -c step-cosign-sign -n cicd-pipeline-system -- cat /var/run/secrets/tokens/sigstore-token
```

Inspect JWT token headers and claims without transmitting sensitive keys:

```bash
TOKEN=$(kubectl exec secure-build-sign-pipelinerun-001-sign-container-image-pod -c step-cosign-sign -n cicd-pipeline-system -- cat /var/run/secrets/tokens/sigstore-token)
jq -R 'split(".") | .[1] | @base64d | fromjson' <<< "$TOKEN"
```

**Expected Decoded JWT Output:**
```json
{
  "aud": [
    "sigstore"
  ],
  "exp": 1786043422,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "cicd-pipeline-system",
    "pod": {
      "name": "secure-build-sign-pipelinerun-001-sign-container-image-pod",
      "uid": "a8f341b1-6d99-4c22-9844-33b09210aa99"
    },
    "serviceaccount": {
      "name": "tekton-builder-sa",
      "uid": "c1d9402a-3b10-4e31-8933-4421aa00ff88"
    }
  },
  "sub": "system:serviceaccount:cicd-pipeline-system:tekton-builder-sa"
}
```

#### Question 3.2
If Sigstore Fulcio rejects keyless certificate generation with the error `invalid identity token: audience "sigstore" does not match expected issuer audience`, what manifest field must be modified in the Tekton `TaskRun`/`Pod` spec to supply the correct token projection?

---

<details>
<summary>Click to expand Answer Key & Technical Explanations</summary>

### Answer 1.1
**Explanation:**  
Prior to Kubernetes 1.24, ServiceAccounts automatically generated non-expiring static tokens stored directly as Kubernetes `Secret` API objects. If an attacker exfiltrated a static CI/CD secret token, they maintained indefinite API access. Projected ServiceAccount Tokens introduce short-lived, auto-rotating JWT tokens bound directly to the ephemeral Pod lifecycle and target audience (`aud`). Once the CI Pod finishes execution, the token is invalidated, eliminating persistent exfiltration risks.

---

### Answer 1.2
**Explanation:**  
Tekton stores `Task` results by mounting an in-memory `emptyDir` volume at `/tekton/results/`. The step writes data into files named after the result key (e.g., `/tekton/results/IMAGE_DIGEST`). The Tekton Entrypoint binary intercepts step execution, reads the contents of `/tekton/results/*` upon step completion, and reports these key-value pairs back to the Tekton Controller via `TaskRun` status conditions (`.status.taskRunResults`). Downstream steps access these values using string interpolation (`$(tasks.<task-name>.results.<result-name>)`).

---

### Answer 1.3
**Explanation:**  
Container tags (such as `:v1.0.0` or `:latest`) are mutable references that can be overwritten or overwritten maliciously in an OCI registry without altering the manifest tag name. In contrast, an image digest (`@sha256:...`) is a cryptographic content addressable hash of the image manifest. Signing by digest guarantees that the signature is immutably tied to the exact binary payload layer state. If a tag is pointed to a different digest, an image policy controller enforcing signature verification on the digest will block execution.

---

### Answer 2.1
**Explanation:**  
Directly executing `kubectl set image` from a CI pipeline requires granting the CI system cluster-admin or broad namespace-write permissions on the target Kubernetes cluster API. This violates least-privilege security boundaries and makes the cluster vulnerable if the CI system is compromised. The GitOps write-back method decouples CI from CD: the CI system only writes declarative parameter updates to Git. Argo CD—running natively inside the cluster—pulls from Git and applies changes internally. The production cluster API remains entirely closed to incoming CI network connections.

---

### Answer 2.2
**Explanation:**  
1. Argo CD detects the updated tag `:v1.0.0` in the repository and attempts to reconcile the deployment by creating/updating the target Pods in the `production-workloads` namespace.
2. The Kubernetes API Server routes the pod creation request to the **Kyverno Validating Webhook Controller**.
3. Kyverno extracts the image digest, checks the OCI registry for an attached Sigstore Cosign signature payload, and validates it against the configured keyless issuer (`https://container.googleapis.com/...`).
4. Because the tag was updated without generating a valid Cosign signature matching the exact image digest, signature verification fails.
5. Kyverno rejects the API server admission request with an HTTP 403 Forbidden error (`validation error: match image signature failed`).
6. The Pod fails to spawn, and Argo CD marks the deployment health status as `Degraded` due to admission webhook rejection.

---

### Answer 3.1
**Explanation:**  
Kaniko runs as root inside the container (`runAsUser: 0`), but rootless or specific non-root user steps (like a prior `git-clone` step running as UID 1000) may create directory trees inside shared persistent volumes with restricted `0755` or `0700` permissions. While `fsGroup` changes group ownership of mounted volumes, Linux file permissions might still prevent non-matching UIDs from modifying files created by earlier steps.  
**Resolution:** Configure `podTemplate` security context with `fsGroupChangePolicy: "Always"` or insert a Tekton workspace initialization step (`initContainer` or clean step) executing `chmod -R g+rwX $(workspaces.shared-workspace.path)` to align workspace POSIX permissions prior to executing unprivileged builds.

---

### Answer 3.2
**Explanation:**  
The Tekton `Task`/`Pod` specification must explicitly project a custom ServiceAccount token with the target audience expected by the identity provider using `volumeMounts` and projected `serviceAccountToken` volumes:

```yaml
spec:
  volumes:
    - name: sigstore-token
      projected:
        sources:
          - serviceAccountToken:
              path: sigstore-token
              expirationSeconds: 600
              audience: "sigstore"
```

The step container must mount this volume at `/var/run/secrets/tokens/` and supply the token via the `--identity-token` flag to `cosign` or export the environment variable `SIGSTORE_ID_TOKEN=$(cat /var/run/secrets/tokens/sigstore-token)`.

</details>