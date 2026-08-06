# Study Guide: LPI 050-100 — Topic 5.2: Product Management & Release Management

**Exam:** LPI Open Source Essentials (050-100)  
**Topic 5.2:** Product Management / Release Management  
**Weight:** 5  
**Official Reference:** [LPI Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## 1. Technical & Architectural Foundations

In open source and cloud-native platform engineering, **Product Management** and **Release Management** govern how software transitions from code modifications into predictable, resilient production artifacts.

```
                   +-------------------------------------------------------------+
                   |                 DEVELOPMENT & COMMIT STAGE                  |
                   |  Conventional Commits (feat, fix, refactor, BREAKING)       |
                   +------------------------------+------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |                 AUTOMATED RELEASE PIPELINE                  |
                   |  1. SemVer Engine determines Next Version (e.g. v1.4.0)     |
                   |  2. Build Binary / OCI Container Image                      |
                   |  3. Generate SBOM (CycloneDX / SPDX via Syft)               |
                   |  4. Cryptographic Artifact Signing (Cosign / Keyless OIDC)   |
                   +------------------------------+------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |                 PROGRESSIVE DELIVERY STAGE                  |
                   |  Canary / Blue-Green Deployment (Argo Rollouts / Flagger)   |
                   |  Real-time Prometheus Metrics Verification & Auto-Rollback     |
                   +-------------------------------------------------------------+
```

### Key Architectural Concepts & Mechanics

1. **Open Source Product Management vs. Traditional Commercial Product Management**
   - **Upstream / Downstream Dynamics:** Open source products maintain an upstream community repository (e.g., Kubernetes core) while downstream commercial distributions (e.g., Red Hat OpenShift, Google GKE) package, harden, support, and extend the core software.
   - **Community-Driven Governance:** Prioritization occurs via open Enhancement Proposals (e.g., KEPs in Kubernetes, PEPs in Python) rather than closed executive roadmaps.

2. **Release Cadence & Lifecycle Models**
   - **Semantic Versioning ([SemVer 2.0.0](https://semver.org/)):** `MAJOR.MINOR.PATCH` format.
     - `MAJOR`: Incompatible API changes.
     - `MINOR`: Backward-compatible functionality added.
     - `PATCH`: Backward-compatible bug fixes.
   - **Release Stages:** Alpha (feature-incomplete, highly volatile) $\rightarrow$ Beta (feature-complete, operational bugs) $\rightarrow$ Release Candidate / RC (production testing, stability phase) $\rightarrow$ General Availability / GA (stable production release) $\rightarrow$ End-of-Life / EOL (deprecation and support termination).
   - **Long-Term Support (LTS) vs. Rolling Releases:**
     - *LTS:* Fixed release cadence with backported security fixes guaranteed for extended periods (e.g., 2–5 years). Target: Conservative enterprise workloads.
     - *Rolling Release:* Continuous integration and deployment model without distinct major versions (e.g., Arch Linux, continuous edge delivery). Target: Rapid iteration environments.

3. **Supply Chain Security & Software Bill of Materials (SBOM)**
   - Modern release pipelines must produce cryptographic evidence of artifact provenance. An **SBOM** lists all transitive dependencies, licenses, and module digests to enable vulnerability tracing (CVE matching).
   - Cryptographic signing tools like **Cosign** (part of the [Sigstore project](https://sigstore.dev/)) sign OCI container images in registries using OIDC keyless identity signatures or public/private key pairs.

4. **Progressive Delivery & Feature Management**
   - **Canary Deployments:** Routing a tiny fraction of live user traffic (e.g., 5%) to a new release while monitoring error rates, latency (p99), and system metrics via Prometheus before scaling to 100%.
   - **Blue-Green Deployments:** Maintaining two identical physical/virtual environments (Blue = active traffic, Green = idle new release). Traffic is switched instantly at the load balancer level upon health verification.
   - **Feature Flags:** Decoupling code deployment from feature exposure by evaluating runtime conditional flags (e.g., via OpenFeature / LaunchDarkly) without requiring application restarts or re-deployments.

---

## 2. Guided Production Exercises

### Exercise 1: Semantic Versioning, Conventional Commits, and Automated Versioning

In this exercise, you will initialize a git repository, apply [Conventional Commits](https://www.conventionalcommits.org/), and execute automated SemVer calculation using CLI tools.

#### Step 1.1: Initialize the repository and set up initial state
Execute the following commands in your shell to simulate a project lifecycle:

```bash
mkdir -p /tmp/release-management-demo && cd /tmp/release-management-demo
git init -b main
git config user.name "SRE Engineer"
git config user.email "sre@example.com"

# Create base application structure
echo 'console.log("App v1.0.0 initialized");' > app.js
git add app.js
git commit -m "feat: initial core application setup"

# Tag initial release
git tag -a v1.0.0 -m "Release v1.0.0"
```

**Expected Shell Output:**
```text
Initialized empty Git repository in /tmp/release-management-demo/.git/
[main (root-commit) 8a1b2c3] feat: initial core application setup
 1 file changed, 1 insertion(+)
 create mode 100644 app.js
```

#### Step 1.2: Commit features, bug fixes, and breaking changes
Simulate subsequent development iterations adhering strictly to Conventional Commit specifications:

```bash
# Iteration 1: Bug fix (Triggers PATCH update)
echo 'console.log("Fixed null pointer issue");' >> app.js
git add app.js
git commit -m "fix(auth): resolve null pointer exception during OAuth handshake"

# Iteration 2: Backward-compatible feature (Triggers MINOR update)
echo 'function metricsExporter() { return true; }' >> app.js
git add app.js
git commit -m "feat(telemetry): add Prometheus metrics exporter endpoint"

# Iteration 3: Breaking API change (Triggers MAJOR update)
echo 'function v2AuthHandler() { throw new Error("v1 API deprecated"); }' >> app.js
git add app.js
git commit -m "feat(api)!: remove v1 authentication endpoints

BREAKING CHANGE: The /v1/auth endpoint has been permanently removed. Migrate to /v2/auth."
```

**Expected Shell Output:**
```text
[main d4e5f6a] fix(auth): resolve null pointer exception during OAuth handshake
 1 file changed, 1 insertion(+)
[main 7b8c9d0] feat(telemetry): add Prometheus metrics exporter endpoint
 1 file changed, 1 insertion(+)
[main 1a2b3c4] feat(api)!: remove v1 authentication endpoints
 1 file changed, 1 insertion(+)
```

#### Step 1.3: Inspect commit history and evaluate next version
Examine the log structure using `git log`:

```bash
git log --oneline --decorate v1.0.0..HEAD
```

**Expected Shell Output:**
```text
1a2b3c4 (HEAD -> main) feat(api)!: remove v1 authentication endpoints
7b8c9d0 feat(telemetry): add Prometheus metrics exporter endpoint
d4e5f6a fix(auth): resolve null pointer exception during OAuth handshake
```

---

#### Comprehension Questions — Exercise 1

**Question 1.1:** Given the initial git tag `v1.0.0` and the subsequent three commits (`fix(auth)...`, `feat(telemetry)...`, `feat(api)!...`), what is the exact new version number that an automated SemVer tool must calculate, and why?

**Question 1.2:** If the commit history contained *only* `fix(auth)...` and `feat(telemetry)...` following `v1.0.0`, what would the resulting version number be?

---

### Exercise 2: Software Bill of Materials (SBOM) Generation and Cryptographic Artifact Signing

In this exercise, you will package a containerized artifact, build an SBOM using [Syft](https://github.com/anchore/syft), and generate/verify a cryptographic signature using [Cosign](https://github.com/sigstore/cosign).

#### Step 2.1: Create a minimal Dockerfile and build an OCI image
Write a syntactically valid Dockerfile and build the image locally using Docker/Podman:

```bash
cat << 'EOF' > Dockerfile
FROM alpine:3.19.1
RUN apk add --no-舆-cache curl bash jq
COPY app.js /app/app.js
ENTRYPOINT ["/bin/bash", "-c", "echo Application Running && sleep 3600"]
EOF

# Build local OCI image artifact
docker build -t local/release-app:1.0.0 .
```

**Expected Shell Output:**
```text
[+] Building 1.2s (7/7) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 168B
 => [internal] load .dockerignore
 => => transferring context: 2B
 => [internal] load metadata for docker.io/library/alpine:3.19.1
 => [1/3] FROM docker.io/library/alpine:3.19.1
 => [2/3] RUN apk add --no-cache curl bash jq
 => [3/3] COPY app.js /app/app.js
 => exporting to image
 => => naming to docker.io/local/release-app:1.0.0
```

#### Step 2.2: Generate a CycloneDX JSON Software Bill of Materials (SBOM)
Utilize `syft` to scan the OCI image layer hierarchy and extract package metadata into a standard format:

```bash
syft local/release-app:1.0.0 -o cyclonedx-json=sbom.cyclonedx.json
```

Inspect the generated SBOM file to verify schema structure:

```bash
head -n 25 sbom.cyclonedx.json
```

**Expected Shell Output:**
```json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-06T19:21:08Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.0.0"
      }
    ],
    "component": {
      "bom-ref": "pkg:oci/release-app@sha256:d3b4c5...",
      "type": "container",
      "name": "local/release-app",
      "version": "1.0.0"
    }
  }
}
```

#### Step 2.3: Generate Cosign Keypair and Sign Artifact Metadata
Generate a Cosign keypair to cryptographically attest to the release artifact:

```bash
# Generate Cosign keypair without passphrase for non-interactive test
COSIGN_PASSWORD="" cosign generate-key-pair

# Inspect generated key files
ls -l cosign.key cosign.pub
```

**Expected Shell Output:**
```text
Private key written to cosign.key
Public key written to cosign.pub
-rw------- 1 root root  649 Aug  6 19:21 cosign.key
-rw-r--r-- 1 root root  178 Aug  6 19:21 cosign.pub
```

---

#### Comprehension Questions — Exercise 2

**Question 2.1:** What distinct problem in the software supply chain does generating a standardized SBOM (e.g., CycloneDX or SPDX) solve during security incident responses (such as Log4Shell)?

**Question 2.2:** Why is signing the digest (`sha256:hash`) of a container image with Cosign preferable to signing a mutable tag like `:latest` or `:1.0.0`?

---

### Exercise 3: Progressive Delivery Mechanics — Automated Canary Rollout Manifest

In this exercise, you will analyze a complete, production-grade Kubernetes custom manifest for **Argo Rollouts** (or Flagger) to manage progressive releases via real-time metric analysis.

#### Step 3.1: Analyze the complete Argo Rollout custom resource manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service-rollout
  namespace: production
  labels:
    app: payment-service
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
      - name: payment-service
        image: registry.enterprise.io/finance/payment-service:v2.1.0
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
  strategy:
    canary:
      canaryService: payment-service-canary
      stableService: payment-service-stable
      trafficRouting:
        nginx:
          stableIngress: payment-service-ingress
      steps:
      - setWeight: 10
      - pause: { duration: 10m }
      - setWeight: 30
      - pause: { duration: 30m }
      - setWeight: 50
      - pause: { duration: 1h }
      analysis:
        templates:
        - templateName: success-rate-prometheus-check
        args:
        - name: service-name
          value: payment-service-canary
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-prometheus-check
  namespace: production
spec:
  metrics:
  - name: success-rate
    interval: 1m
    successCondition: result[0] >= 0.995
    failureLimit: 3
    provider:
      prometheus:
        address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_requests_total{app="payment-service-canary", status=~"2.*|3.*"}[2m]))
          /
          sum(rate(http_requests_total{app="payment-service-canary"}[2m]))
```

#### Step 3.2: Simulate monitoring and promotion CLI execution
Run the following CLI command to monitor an active rollout progression:

```bash
kubectl argo rollouts get rollout payment-service-rollout -n production --watch
```

**Expected Output:**
```text
Name:            payment-service-rollout
Namespace:       production
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/6 (setWeight: 10)
  SetWeight:     10
  ActualWeight:  10
Images:          registry.enterprise.io/finance/payment-service:v1.9.0 (stable)
                 registry.enterprise.io/finance/payment-service:v2.1.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       1
  Ready:         10
  Available:     10

NAME                                                                 STATUS        GI  AGE  HOLD
├── revision:1                                                       stable        d8  14d
│   └── payment-service-rollout-687496d8b-4x2lz                      Running       d8  14d
└── revision:2                                                       canary        e9  3m
    ├── payment-service-rollout-79bf877ec-9q1zw                      Running       e9  3m
    └── inline-analysis:success-rate-prometheus-check-revision-2-1  Successful    e9  2m
```

---

#### Comprehension Questions — Exercise 3

**Question 3.1:** According to the manifest in Step 3.1, what threshold must the Prometheus query metric satisfy for the deployment to proceed without triggering a rollback?

**Question 3.2:** What is the fundamental operational difference between a **Blue/Green** deployment strategy and a **Canary** deployment strategy regarding resource consumption and risk mitigation?

---

<details>
<summary><strong>Click to expand Solutions and Detailed Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:**  
  The new version number is **`v2.0.0`**.  
  *Technical Reason:* Although `fix(auth)` requests a `PATCH` increment (1.0.0 $\rightarrow$ 1.0.1) and `feat(telemetry)` requests a `MINOR` increment (1.0.0 $\rightarrow$ 1.1.0), the third commit (`feat(api)!: ...`) contains an exclamation mark (`!`) after the scope and a explicitly designated `BREAKING CHANGE:` footer. Under SemVer 2.0.0 rules, any breaking API change forces an immediate increment of the `MAJOR` version digit, resetting `MINOR` and `PATCH` to zero.

* **Answer 1.2:**  
  The version number would be **`v1.1.0`**.  
  *Technical Reason:* `fix` increments `PATCH`, but `feat` increments `MINOR`. When multiple commits accumulate within a single release window, the highest precedence bump applies. `MINOR` outranks `PATCH`.

---

### Exercise 2 Solutions

* **Answer 2.1:**  
  When a zero-day vulnerability (e.g., Log4Shell in Java, or a vulnerable C library inside Alpine base images) is disclosed, security teams must quickly identify which running artifacts contain the vulnerable package version. Searching raw source code repos is insufficient because third-party dependencies are pulled during container builds. Standardized SBOM formats (CycloneDX/SPDX) provide a machine-readable index of exact software components, transitive dependencies, and hashes. Security engines (e.g., Dependency-Track, Grype) query this SBOM instantly without re-scanning image layers.

* **Answer 2.2:**  
  Docker image tags like `:latest` or `:1.0.0` are **mutable pointers**. A malicious actor or broken pipeline can overwrite the tag `:1.0.0` in a registry to point to a completely different binary without updating the signature. The **sha256 digest** (e.g., `sha256:d3b4c5...`) is an immutable, cryptographically derived hash of the image manifest and layers. Signing the digest guarantees that the exact byte stream verified by Cosign is identical to what the Kubernetes container runtime (`containerd` or `CRIO`) executes on node hosts.

---

### Exercise 3 Solutions

* **Answer 3.1:**  
  The Prometheus metric condition `successCondition: result[0] >= 0.995` requires that **at least 99.5%** of all HTTP traffic routed to the canary pod (`payment-service-canary`) yields HTTP 2xx or 3xx status codes over a 2-minute sliding window. If the error rate exceeds 0.5% for 3 consecutive checks (`failureLimit: 3`), Argo Rollouts automatically aborts the deployment, scales the canary deployment to 0 replicas, and routes 100% of traffic back to `payment-service-stable`.

* **Answer 3.2:**  
  * **Resource Consumption:** Blue/Green requires reserving 200% capacity (provisioning a complete, duplicate copy of production infrastructure alongside active workloads) during rollout. Canary requires minimal extra capacity (e.g., 10% additional pods for step 1).
  * **Risk Mitigation:** Blue/Green switches 100% of live users instantly from Blue to Green. If an uncaught edge-case bug occurs, all users experience the failure simultaneously until traffic is swapped back. Canary limits exposure to a controlled subset of users (e.g., 10%), isolating failure radius during evaluation windows.

</details>