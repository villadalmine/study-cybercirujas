# Guided Exercises — Topic 2.5: Security Integration in CI/CD Pipelines

> **Exam:** CNPA (2025-04-01) · **Weight:** 4.0
> **Goal:** Wire security *gates* into a delivery pipeline the way platform teams actually do it — shift-left scanning, supply-chain signing, and admission-time enforcement — and understand *why* each gate sits where it does and what it can and cannot prove.
>
> **Lab prerequisites** (all open-source, no cloud account required):
> `docker` or `podman`, `kind` ≥ 0.23, `kubectl`, `trivy` ≥ 0.53, `syft` ≥ 1.9, `cosign` ≥ 2.4, `gitleaks` ≥ 8.18, `checkov` ≥ 3.2, `kube-linter` ≥ 0.6, `helm` ≥ 3.15. A GitHub account is used only in Exercise 8.

---

## Exercise 1 — Bootstrap a security-instrumented lab

The whole point of "security in CI/CD" is a *feedback loop*: a scanner finds something, the pipeline *stops*, a human decides. Before we can build gates we need a target cluster and a sample app repo.

1. Create a throwaway cluster:

   ```bash
   kind create cluster --name cnpa-sec --wait 120s
   kubectl config use-context kind-cnpa-sec
   ```

   Expected:

   ```text
   Creating cluster "cnpa-sec" ...
    ✓ Ensuring node image (kindest/node:v1.30.0)
    ✓ Preparing nodes
    ✓ Writing configuration
    ✓ Starting control-plane
    ✓ Installing CNI
   Set kubectl context to "kind-cnpa-sec"
   ```

2. Scaffold a deliberately-imperfect repo. We *want* findings, so the gates have something to catch:

   ```bash
   mkdir -p demo-app/k8s && cd demo-app
   git init -q

   cat > Dockerfile <<'EOF'
   FROM python:3.9.18-slim
   WORKDIR /app
   COPY app.py .
   RUN pip install flask==2.0.1
   USER root
   CMD ["python", "app.py"]
   EOF

   cat > app.py <<'EOF'
   from flask import Flask
   app = Flask(__name__)
   AWS_KEY = "AKIAIOSFODNN7EXAMPLE"   # planted secret
   @app.route("/")
   def hi(): return "hello"
   app.run(host="0.0.0.0", port=8080)
   EOF
   ```

3. Add a Deployment manifest with several bad-practice defaults:

   ```yaml
   # k8s/deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: demo
   spec:
     replicas: 1
     selector:
       matchLabels: { app: demo }
     template:
       metadata:
         labels: { app: demo }
       spec:
         containers:
           - name: demo
             image: demo-app:dev            # mutable tag, no digest
             ports:
               - containerPort: 8080
             securityContext:
               privileged: true             # intentionally wrong
   ```

4. Confirm the cluster is empty and healthy:

   ```bash
   kubectl get nodes
   ```

   Expected:

   ```text
   NAME                     STATUS   ROLES           AGE   VERSION
   cnpa-sec-control-plane   Ready    control-plane   40s   v1.30.0
   ```

> **Check your understanding**
> **Q1.1** — "Shift-left" is the guiding principle of this topic. Order these four gates by *how early* they can run and state the cost of a failure caught only at the *last* one: (a) admission controller rejects the Pod, (b) `gitleaks` pre-commit hook, (c) image vuln scan in CI, (d) SAST on the Dockerfile in CI.
> **Q1.2** — The Deployment references `image: demo-app:dev`. Name two distinct supply-chain problems a *mutable tag* creates that a *digest* (`@sha256:…`) does not.

---

## Exercise 2 — Secret scanning as a hard gate

The planted `AKIA…` key must never reach the registry, the logs, or the git history. Secret scanning is the cheapest, earliest gate.

1. Run `gitleaks` over the working tree and produce SARIF (the format most CI systems ingest):

   ```bash
   gitleaks detect --source . --no-git \
     --report-format sarif --report-path gitleaks.sarif --verbose
   ```

   Expected (truncated):

   ```text
   Finding:     AWS_KEY = "AKIAIOSFODNN7EXAMPLE"
   Secret:      AKIAIOSFODNN7EXAMPLE
   RuleID:      aws-access-token
   File:        app.py
   Line:        3
   ...
   8:00PM INF 1 commits scanned.
   8:00PM WRN leaks found: 1
   ```

2. Inspect the exit code — this is what makes it a *gate*, not a report:

   ```bash
   echo $?
   ```

   Expected: `1` (gitleaks returns non-zero when leaks are found).

3. Turn it into a pre-commit hook so the secret is blocked *before* it ever enters history:

   ```bash
   cat > .pre-commit-config.yaml <<'EOF'
   repos:
     - repo: https://github.com/gitleaks/gitleaks
       rev: v8.18.4
       hooks:
         - id: gitleaks
   EOF
   pre-commit install
   ```

4. Remediate properly — a secret that was *committed* is already compromised. Remove it from the code and rotate. For the lab, replace the literal with an env lookup:

   ```bash
   sed -i 's/AWS_KEY = .*/AWS_KEY = os.environ["AWS_KEY"]/' app.py
   sed -i '1i import os' app.py
   gitleaks detect --source . --no-git ; echo "exit=$?"
   ```

   Expected: `... no leaks found` … `exit=0`.

> **Check your understanding**
> **Q2.1** — Your teammate says "we'll just scan on the `main` branch nightly." Why is that strictly weaker than the pre-commit + PR-gate approach, in terms of what an attacker (or a leak) can do in the window?
> **Q2.2** — `gitleaks detect` found the secret in the *working tree*, but the exam distinguishes `detect` (history) from `protect` (staged changes). If a secret was committed six months ago and later deleted from `HEAD`, which mode finds it, and why does deleting the line not fix the problem?
> **Q2.3** — Why is a non-zero exit code the load-bearing detail of every scanner in this topic?

*Source: Gitleaks — https://github.com/gitleaks/gitleaks · Pre-commit — https://pre-commit.com/*

---

## Exercise 3 — Static analysis of IaC and manifests (SAST for config)

Before an image is even built, the *configuration* can be scanned. This is policy-as-code applied at CI time.

1. Scan the Kubernetes manifest with Checkov:

   ```bash
   checkov -d ./k8s --framework kubernetes --compact
   ```

   Expected (truncated):

   ```text
   kubernetes scan results:
   Passed checks: 12, Failed checks: 9, Skipped checks: 0

   Check: CKV_K8S_16: "Container should not be privileged"
     FAILED for resource: Deployment.default.demo
     File: /k8s/deploy.yaml:16-18
   Check: CKV_K8S_43: "Image should use digest"
     FAILED for resource: Deployment.default.demo
   Check: CKV_K8S_37: "Minimize the admission of containers with capabilities"
     FAILED for resource: Deployment.default.demo
   ```

2. Cross-check with `kube-linter`, which targets operational/security anti-patterns rather than CIS-style rules — the tools *overlap but do not subsume each other*:

   ```bash
   kube-linter lint ./k8s
   ```

   Expected (truncated):

   ```text
   k8s/deploy.yaml: (object: default/demo apps/v1, Kind=Deployment)
     container "demo" does not have a read-only root file system (check: no-read-only-root-fs)
     container "demo" has no resource limits (check: unset-cpu-requirements)
     container "demo" is privileged (check: privileged-container)
   Error: found 3 lint errors
   ```

3. Fix the manifest to pass both — least privilege, pinned digest, dropped capabilities, resource bounds:

   ```yaml
   # k8s/deploy.yaml  (hardened container spec)
   securityContext:
     privileged: false
     runAsNonRoot: true
     runAsUser: 10001
     allowPrivilegeEscalation: false
     readOnlyRootFilesystem: true
     capabilities:
       drop: ["ALL"]
   resources:
     requests: { cpu: "50m", memory: "64Mi" }
     limits:   { cpu: "250m", memory: "128Mi" }
   ```

4. Re-run and confirm the failing checks clear:

   ```bash
   checkov -d ./k8s --framework kubernetes --compact | grep -E "Passed|Failed"
   ```

   Expected: `Passed checks: 21, Failed checks: 0, Skipped checks: 0` (image-digest check still fails until Exercise 6 pins one).

> **Check your understanding**
> **Q3.1** — Checkov and kube-linter both flagged `privileged`. Give one class of problem each tool catches that the *other typically does not*, and explain why a mature pipeline runs both rather than picking one.
> **Q3.2** — You need to accept `CKV_K8S_43` (image digest) temporarily because the digest is filled in by a later stage. What is the *auditable* way to suppress exactly that check on exactly that resource, and why is `--skip-check` globally worse?
> **Q3.3** — This gate runs on YAML, before any image exists. What entire category of vulnerability is it structurally *incapable* of finding, motivating the next exercise?

*Source: Checkov — https://www.checkov.io/ · KubeLinter — https://docs.kubelinter.io/*

---

## Exercise 4 — Image vulnerability scanning with severity gates

Now the image exists. Trivy scans the built layers against vulnerability feeds and, crucially, *fails the build* on your chosen threshold.

1. Build the image locally and load it into kind:

   ```bash
   docker build -t demo-app:dev .
   kind load docker-image demo-app:dev --name cnpa-sec
   ```

2. Scan, gating only on actionable (fixable) HIGH/CRITICAL findings:

   ```bash
   trivy image --scanners vuln \
     --severity HIGH,CRITICAL \
     --ignore-unfixed \
     --exit-code 1 \
     demo-app:dev
   ```

   Expected (truncated):

   ```text
   demo-app:dev (debian 12.5)
   Total: 4 (HIGH: 3, CRITICAL: 1)

   ┌────────────┬────────────────┬──────────┬────────┬───────────────┬──────────────┐
   │  Library   │ Vulnerability  │ Severity │ Status │ Installed Ver │  Fixed Ver   │
   ├────────────┼────────────────┼──────────┼────────┼───────────────┼──────────────┤
   │ libexpat1  │ CVE-2024-45491 │ CRITICAL │ fixed  │ 2.5.0-1       │ 2.5.0-1+deb… │
   └────────────┴────────────────┴──────────┴────────┴───────────────┴──────────────┘
   Python (python-pkg)
   │ flask      │ CVE-2023-30861 │ HIGH     │ fixed  │ 2.0.1         │ 2.2.5        │
   $ echo $?
   1
   ```

3. Remediate at the *source*, not with suppressions: bump the base image and the dependency.

   ```bash
   sed -i 's/python:3.9.18-slim/python:3.12.5-slim/' Dockerfile
   sed -i 's/flask==2.0.1/flask==3.0.3/' Dockerfile
   docker build -t demo-app:dev . && kind load docker-image demo-app:dev --name cnpa-sec
   trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 demo-app:dev
   echo "exit=$?"
   ```

   Expected: `Total: 0 (HIGH: 0, CRITICAL: 0)` … `exit=0`.

4. For a CVE you *must* accept (with justification and expiry), record it in a `.trivyignore` — the transparent alternative to silently lowering the threshold:

   ```bash
   cat > .trivyignore <<'EOF'
   # Accepted 2026-08-06, review by 2026-09-06: no fix upstream, not reachable from our entrypoint.
   CVE-2024-XXXXX
   EOF
   ```

> **Check your understanding**
> **Q4.1** — `--ignore-unfixed` is common in gating jobs but controversial. Argue both sides: what does dropping *unfixed* vulns buy the team, and what real risk does it hide?
> **Q4.2** — Two Trivy runs of the *same digest* one week apart give different results with no rebuild. Nothing about your image changed — what did, and what does this imply about scanning images that are already *running* in the cluster (not just at build time)?
> **Q4.3** — Why is fixing via base-image bump generally superior to adding entries to `.trivyignore`, and when is `.trivyignore` nonetheless the correct, responsible move?

*Source: Trivy — https://trivy.dev/latest/docs/*

---

## Exercise 5 — Generate an SBOM (know what you shipped)

You cannot respond to the *next* Log4Shell if you don't know which images contain the library. The SBOM is the inventory.

1. Produce an SBOM in SPDX JSON (an ISO-standard format) from the image:

   ```bash
   syft demo-app:dev -o spdx-json=sbom.spdx.json
   syft demo-app:dev -o cyclonedx-json=sbom.cdx.json   # second standard format
   ```

   Expected:

   ```text
    ✔ Parsed image sha256:9f2c…
    ✔ Cataloged contents
      ├── ✔ Packages          [147 packages]
      └── ✔ Executables       [212 executables]
   ```

2. Query the SBOM the way an incident-responder would — "am I affected?":

   ```bash
   jq -r '.packages[] | select(.name=="flask") | "\(.name) \(.versionInfo)"' sbom.spdx.json
   ```

   Expected: `flask 3.0.3`

3. Scan *the SBOM itself* (offline, no image pull needed) — this is how you re-check a fleet against a fresh CVE feed without rebuilding anything:

   ```bash
   trivy sbom sbom.cdx.json --severity HIGH,CRITICAL
   ```

   Expected: `Total: 0 (HIGH: 0, CRITICAL: 0)`

> **Check your understanding**
> **Q5.1** — An SBOM produced at *build time* and a scanner run *today* together answer a question that a build-time scan alone cannot. State the question precisely.
> **Q5.2** — Why must the SBOM be generated from the *built artifact* (the image) rather than from the source repo or a lockfile, to be trustworthy for incident response?
> **Q5.3** — An SBOM by itself is just a file sitting in CI storage. What must happen to it in the next exercise for a *consumer* of your image to trust that this SBOM actually describes *that* image?

*Source: Syft/SPDX — https://github.com/anchore/syft · SPDX — https://spdx.dev/ · CycloneDX — https://cyclonedx.org/*

---

## Exercise 6 — Keyless signing and attestation with Sigstore/cosign

An unsigned image and an unbound SBOM are just claims. Cosign binds *provenance* to the image digest and records it in a public transparency log (Rekor). "Keyless" means the signing identity is a short-lived OIDC-issued certificate — no long-lived private key to leak.

1. Run a local registry so we can push the image (signatures are stored *alongside* the image in the registry):

   ```bash
   docker run -d -p 5001:5000 --name reg registry:2
   docker tag demo-app:dev localhost:5001/demo-app:1.0.0
   docker push localhost:5001/demo-app:1.0.0
   DIGEST=$(cosign triangulate --type digest localhost:5001/demo-app:1.0.0)
   echo "$DIGEST"
   ```

   Expected: `localhost:5001/demo-app@sha256:4b1e…` — always sign the *digest*, never the tag.

2. Sign keylessly. Cosign opens a browser for OIDC; in CI this is fully automated (Exercise 8):

   ```bash
   COSIGN_EXPERIMENTAL=1 cosign sign --yes "$DIGEST"
   ```

   Expected (truncated):

   ```text
   Generating ephemeral keys...
   Retrieving signed certificate...
   ...
   tlog entry created with index: 128374651
   Pushing signature to: localhost:5001/demo-app
   ```

3. Attach the SBOM as a signed *attestation* (a signed statement *about* the artifact, not just a signature *of* it):

   ```bash
   cosign attest --yes --type spdxjson \
     --predicate sbom.spdx.json "$DIGEST"
   ```

4. Verify — this is exactly what an admission controller will do at deploy time. Verification pins *who* signed and *which issuer* vouched for them:

   ```bash
   cosign verify \
     --certificate-identity-regexp ".*" \
     --certificate-oidc-issuer-regexp ".*" \
     "$DIGEST" | jq '.[0].optional.Subject'
   ```

   Expected (truncated):

   ```text
   Verification for localhost:5001/demo-app@sha256:4b1e… --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - Existence of the claims in the transparency log was verified offline
     - The code-signing certificate was verified using trusted certificate authority certificates
   "villadalmine@gmail.com"
   ```

> **Check your understanding**
> **Q6.1** — Explain the security advantage of *keyless* signing over a long-lived signing key held in a CI secret. What does the ephemeral-certificate + Rekor design eliminate?
> **Q6.2** — `cosign sign` and `cosign attest` produce different things. A signature proves one property; an SBOM *attestation* proves another. State both properties precisely.
> **Q6.3** — Why does cosign refuse to let signing a mutable tag be meaningful, forcing you to sign the digest? Tie this back to Q1.2.
> **Q6.4** — At verify time you must supply `--certificate-identity` and `--certificate-oidc-issuer`. What attack does verifying *without* pinning these (accepting `.*`) leave you open to, even though every signature is cryptographically valid and in Rekor?

*Source: Sigstore/cosign — https://docs.sigstore.dev/cosign/signing/overview/ · Rekor — https://docs.sigstore.dev/rekor/overview/*

---

## Exercise 7 — Admission-time enforcement with Kyverno

CI gates are advisory: a determined engineer can push an image straight to the registry and `kubectl apply` it, bypassing the pipeline entirely. The *cluster* must independently verify signatures. This is the "trust boundary" that makes the whole chain enforceable.

1. Install Kyverno:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
   kubectl -n kyverno get pods
   ```

   Expected: admission-controller / background-controller / cleanup / reports controllers all `Running`.

2. Apply a `verifyImages` policy that blocks any Pod whose image is not signed by the expected identity. Start in `Audit`, then flip to `Enforce`:

   ```yaml
   # verify-images.yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-image-signatures
   spec:
     validationFailureAction: Enforce
     webhookTimeoutSeconds: 30
     rules:
       - name: require-signature
         match:
           any:
             - resources:
                 kinds: ["Pod"]
         verifyImages:
           - imageReferences:
               - "localhost:5001/demo-app*"
             failureAction: Enforce
             mutateDigest: true          # rewrites tag → digest on admission
             verifyDigest: true
             required: true
             attestors:
               - count: 1
                 entries:
                   - keyless:
                       subject: "villadalmine@gmail.com"
                       issuer: "https://github.com/login/oauth"
                       rekor:
                         url: https://rekor.sigstore.dev
   ```

   ```bash
   kubectl apply -f verify-images.yaml
   ```

3. Prove the negative — deploy an *unsigned* image and watch admission reject it:

   ```bash
   docker tag nginx:1.27 localhost:5001/demo-app:unsigned
   docker push localhost:5001/demo-app:unsigned
   kubectl run bad --image=localhost:5001/demo-app:unsigned
   ```

   Expected:

   ```text
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   resource Pod/default/bad was blocked due to the following policies:
     verify-image-signatures:
       require-signature: 'failed to verify image localhost:5001/demo-app:unsigned:
       .. no matching signatures'
   ```

4. Prove the positive — the *signed* image is admitted, and note the tag was rewritten to a digest:

   ```bash
   kubectl run good --image=localhost:5001/demo-app:1.0.0
   kubectl get pod good -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

   Expected: `localhost:5001/demo-app:1.0.0@sha256:4b1e…`

> **Check your understanding**
> **Q7.1** — Every CI gate in Exercises 2–6 can be bypassed by someone with registry write + `kubectl apply`. Explain precisely why the Kyverno gate *cannot* be bypassed the same way, and what makes it the true enforcement point.
> **Q7.2** — The policy sets `mutateDigest: true`. What concrete attack (a TOCTOU / time-of-check-to-time-of-use race on a mutable tag) does rewriting tag→digest at admission prevent?
> **Q7.3** — Why is rolling out such a policy in `validationFailureAction: Audit` first a hard operational requirement, not a nicety? What breaks cluster-wide if you ship `Enforce` immediately with a too-broad `imageReferences`?
> **Q7.4** — Kyverno needs to reach `rekor.sigstore.dev` at admission time. What availability/latency risk does this introduce into the *critical path of every Pod creation*, and name one mitigation.

*Source: Kyverno verifyImages — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/ · Policy Reporter — https://kyverno.io/docs/*

---

## Exercise 8 — Assemble the pipeline with least privilege (GitHub Actions + OIDC)

Now put the gates in the correct order in one workflow, and make the *runner itself* least-privileged. Keyless signing in CI works because the runner exchanges a GitHub OIDC token for a Sigstore certificate — no key is stored anywhere.

1. Create the workflow. Note the `permissions` block — this is the platform-engineering discipline: grant `id-token: write` (needed for OIDC/keyless) and `packages: write`, and *nothing else*.

   ```yaml
   # .github/workflows/secure-build.yaml
   name: secure-build
   on: { push: { branches: [main] } }

   permissions:
     contents: read        # least privilege by default
     id-token: write       # OIDC token for keyless cosign
     packages: write       # push to GHCR

   jobs:
     build:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4

         # Gate 1 — secrets (fail fast, cheapest)
         - uses: gitleaks/gitleaks-action@v2

         # Gate 2 — IaC / manifest SAST
         - uses: bridgecrewio/checkov-action@v12
           with: { directory: k8s, framework: kubernetes }

         # Build (only reached if gates 1–2 pass)
         - uses: docker/build-push-action@v6
           id: build
           with:
             push: true
             tags: ghcr.io/${{ github.repository }}:${{ github.sha }}

         # Gate 3 — image vulnerabilities
         - uses: aquasecurity/trivy-action@0.24.0
           with:
             image-ref: ghcr.io/${{ github.repository }}:${{ github.sha }}
             severity: HIGH,CRITICAL
             ignore-unfixed: true
             exit-code: '1'

         # Provenance — SBOM + keyless sign + attest
         - uses: anchore/sbom-action@v0
           with: { image: 'ghcr.io/${{ github.repository }}:${{ github.sha }}', format: spdx-json, output-file: sbom.spdx.json }
         - uses: sigstore/cosign-installer@v3
         - run: |
             DIGEST=$(cosign triangulate --type digest ghcr.io/${{ github.repository }}:${{ github.sha }})
             cosign sign --yes "$DIGEST"
             cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$DIGEST"
   ```

2. The Kyverno policy from Exercise 7 is updated to trust the *workflow identity*, not a person — this is the link that closes the loop from CI to cluster:

   ```yaml
   keyless:
     subject: "https://github.com/OWNER/REPO/.github/workflows/secure-build.yaml@refs/heads/main"
     issuer: "https://token.actions.githubusercontent.com"
   ```

3. Trace the full chain of custody on paper before you trust it:

   ```text
   commit → [gitleaks] → [checkov] → build → [trivy] → SBOM → cosign sign+attest (keyless, OIDC)
                                                                     │
                                                          Rekor transparency log
                                                                     │
   kubectl apply ──────────────► Kyverno verifyImages ──── verifies subject == workflow identity
                                          │
                                    admit (digest-pinned) / deny
   ```

> **Check your understanding**
> **Q8.1** — Why is `permissions:` scoped to the minimum the single most important line in this workflow from a supply-chain-attack standpoint? What does a compromised third-party Action gain if you instead left the default broad token?
> **Q8.2** — In step 2 the Kyverno `subject` pins a *workflow ref*, not a person's email. Explain why binding cluster trust to `…/secure-build.yaml@refs/heads/main` is stronger than trusting a human identity — what does it prevent even for a legitimate maintainer?
> **Q8.3** — The gates are ordered gitleaks → checkov → build → trivy → sign. Justify this ordering on two axes: *cost of running the gate* and *what must be true for the next stage to be meaningful*.
> **Q8.4** — A reviewer says "we sign in CI *and* verify in Kyverno — that's redundant, drop one." Which one, if either, is safe to drop, and why does dropping the *other* collapse the entire security model?

*Source: GitHub OIDC hardening — https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect · SLSA — https://slsa.dev/spec/v1.0/*

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
**A1.1** — Earliest → latest: **(b) gitleaks pre-commit** (runs on the developer's machine, before any commit) → **(d) SAST on Dockerfile** and **(c) image vuln scan** (both in CI, `d` needs no build so it's slightly earlier than `c`) → **(a) admission rejection** (at deploy, last). Cost of catching it only at (a): the bad artifact was fully built, pushed, versioned, and possibly consumed by other teams; the feedback reaches the developer minutes-to-hours later with full context lost; and cluster capacity/pipeline time was spent producing something that gets thrown away. Shift-left is about *shrinking the blast radius and the feedback latency* — the earlier the gate, the cheaper and more localized the fix.

**A1.2** — A mutable tag lets (1) the *content* behind `demo-app:dev` change after it was scanned/approved — a **time-of-check-to-time-of-use** gap where what you verified is not what runs; and (2) it destroys **reproducibility/rollback** — "deploy `:dev`" doesn't identify a specific artifact, so you cannot prove which bytes ran during an incident, nor recreate them. A digest is content-addressed: `@sha256:…` *is* the content, immutable and verifiable.

### Exercise 2
**A2.1** — Nightly-on-`main` leaves a window (up to ~24h + however long review took) in which the secret is *live in the remote repository's history*. Anyone with read access — or anyone who scrapes a brief public exposure, fork, CI log, or cache — can grab it. Pre-commit blocks it before it ever leaves the laptop; the PR gate blocks it before it merges to a shared branch. Detection-after-the-fact still means the secret **must be rotated**, whereas prevention means it never existed anywhere shared.

**A2.2** — `gitleaks detect` (scanning git *history*) finds it; `protect` only looks at staged/uncommitted changes. Deleting the line in `HEAD` does not remove it from earlier commits — git history is append-only, so the secret is still fetchable via `git log`/`git show` of the old commit. The only real fix is **rotate the credential** (and optionally rewrite history), because the moment it was pushed it must be treated as compromised.

**A2.3** — CI/CD systems decide pass/fail from the process exit status. A scanner that prints findings but exits `0` is a *report*, not a *gate* — the pipeline proceeds and the bad artifact ships. Non-zero exit is the mechanism that converts "we noticed" into "we stopped."

### Exercise 3
**A3.1** — Checkov is rule/compliance-oriented (CIS-style, IaC across many frameworks: Terraform, CloudFormation, K8s, Helm) and excels at *policy/benchmark* coverage and cross-IaC breadth. kube-linter targets *operational* production readiness and K8s-specific anti-patterns (missing readiness probes, no resource limits, dangling selectors, latest tags) that aren't strictly "security compliance." Running both catches both the compliance gaps and the reliability/operational footguns; neither is a superset of the other.

**A3.2** — Use an inline, resource-scoped suppression with a justification comment — Checkov honors `# checkov:skip=CKV_K8S_43: digest is injected by the release stage` placed on the resource. It suppresses exactly one check on exactly one object and is visible in the manifest/diff/audit. `--skip-check CKV_K8S_43` disables it *everywhere*, silently, for resources that genuinely should fail — a blanket hole with no per-resource justification and no review trail.

**A3.3** — It scans declared configuration, so it cannot find **vulnerabilities inside the built image** — CVEs in OS packages and application dependencies baked into the layers. The YAML can be perfectly hardened while the image ships a critical libexpat CVE. That is Exercise 4's job.

### Exercise 4
**A4.1** — *For* `--ignore-unfixed`: it removes noise you cannot act on (no patch exists), so the gate only fails on things a developer can actually fix by bumping a version — keeping the gate credible and unblocked. *Against*: an unfixed CRITICAL is still exploitable; hiding it can mean shipping a knowingly-vulnerable image with no tracking, and the day a fix lands you won't be alerted because you filtered it out. Mature setups gate on fixable findings *but still record* unfixed ones (report/attestation) with compensating controls.

**A4.2** — The **vulnerability database changed** — new CVEs were published (or existing ones re-scored) against the exact same packages. Implication: an image that was "clean" at build time can become vulnerable *without any change to its bytes*. Therefore scanning must be **continuous** — you must re-scan already-running images/SBOMs against fresh feeds, not just gate once at build. (This is exactly why Exercise 5's SBOM-scanning matters.)

**A4.3** — A base-image bump *removes* the vulnerable code, eliminating the risk. `.trivyignore` only *hides* the finding — the vulnerable code still runs. Bumping is superior whenever a fix exists. `.trivyignore` is the responsible choice only when there is **no upstream fix** and you've assessed the vuln as not-reachable/not-exploitable in your context — and even then it must carry a justification and a review/expiry date so it doesn't become permanent.

### Exercise 5
**A5.1** — "Given today's vulnerability feed, is this *specific, already-built and possibly-deployed* artifact affected by any newly-disclosed CVE — **without rebuilding or re-pulling it**?" The build-time SBOM freezes the exact component inventory; scanning it later re-evaluates that fixed inventory against new knowledge.

**A5.2** — Source repos and lockfiles describe *intent*, not the *result*: the final image also contains base-OS packages, transitively-installed system libraries, files copied in, and whatever the build actually resolved (which can differ from the lockfile). Only an SBOM taken from the built artifact reflects what genuinely shipped — which is what an incident responder must reason about.

**A5.3** — It must be **cryptographically bound to the image digest as a signed attestation** (Exercise 6's `cosign attest`). Otherwise a consumer has no way to know the SBOM wasn't swapped, edited, or generated from a different image — an unsigned SBOM is an unverifiable claim.

### Exercise 6
**A6.1** — Keyless signing uses a **short-lived (minutes) certificate** issued against your OIDC identity, so there is *no long-lived private key* stored in a CI secret to be stolen, misused, or rotated. The signing act is recorded in **Rekor**, a public append-only transparency log, so any signature is publicly auditable and tamper-evident. It eliminates the "leaked signing key → forge arbitrary signatures forever" failure mode entirely.

**A6.2** — `cosign sign` proves **integrity + authenticated origin**: "identity X vouched for the exact bytes at this digest, and this hasn't been tampered with." An SBOM *attestation* (`cosign attest`) proves a **verifiable claim about the artifact**: "identity X asserts *this specific SBOM* (this component list) describes the artifact at this digest" — binding metadata to the image so the SBOM itself can be trusted.

**A6.3** — A signature is only meaningful if it commits to immutable content. Signing a tag would let the underlying image change afterward while the signature still "verifies" the tag — verifying nothing. Signing the digest ties the signature to exact content (the same TOCTOU/reproducibility reasoning as A1.2).

**A6.4** — Accepting any identity/issuer (`.*`) means you verify that *someone* signed it and it's in Rekor — but **not that the *right* party signed it**. An attacker can keylessly sign a malicious image with *their own* perfectly valid identity; the signature and Rekor entry are legitimate. Without pinning `--certificate-identity` (the expected signer) and `--certificate-oidc-issuer` (the expected IdP), you accept attacker-signed images. Trust is in *who*, not merely *that*.

### Exercise 7
**A7.1** — CI gates run *before* the registry/cluster and are opt-in to the pipeline path; anyone with registry-write and `kubectl apply` skips the pipeline entirely. Kyverno's `verifyImages` runs as a **validating/mutating admission webhook inside the API server's request path** — *every* Pod creation, from any source (kubectl, CI, operator, controller), passes through it. There is no way to create a Pod that bypasses admission, so it is the one gate that is enforced regardless of how the request arrives.

**A7.2** — Without digest-pinning, an attacker can pass the check with a signed image behind a tag, then repoint that *mutable tag* to a malicious image before the kubelet pulls it — a TOCTOU race between admission's verification and the node's pull. `mutateDigest: true` rewrites the admitted spec to the exact `@sha256:…` that was verified, so the kubelet pulls *precisely* the bytes Kyverno checked; the tag can't be swapped underneath.

**A7.3** — In `Enforce`, a policy whose `imageReferences` is too broad (or whose attestor is misconfigured) will **deny Pod creation cluster-wide** — including system components, restarts, and scale-ups — potentially causing an outage as existing workloads can't reschedule. `Audit` lets you observe what *would* be blocked via policy reports, tune `imageReferences`/attestors, and confirm zero false-positives before enforcing. It's a rollout safety requirement, like any change that sits in a critical request path.

**A7.4** — Rekor/Fulcio lookups add a network dependency to *every Pod admission*; if the endpoint is slow or down, admission can time out (`webhookTimeoutSeconds`) and, depending on failure policy, either block Pods (availability hit) or fail-open (security hit). Mitigations: cache verification results / use a TUF-mirror or in-cluster Rekor mirror, scope the policy narrowly so most Pods skip the check, tune the webhook timeout, and choose the failurePolicy deliberately.

### Exercise 8
**A8.1** — Every step runs with the job's `GITHUB_TOKEN`; a compromised third-party Action inherits whatever that token can do. With a broad token (e.g. `contents: write`, `packages: write`, plus others) the attacker can push malicious commits, tamper with releases, or exfiltrate — a classic supply-chain pivot. Scoping to `contents: read` + only the two write scopes actually needed (`id-token`, `packages`) means even a fully-compromised Action can't rewrite your repo or escalate. Minimizing `permissions:` is the single highest-leverage line against Action-supply-chain attacks.

**A8.2** — Pinning to `…/secure-build.yaml@refs/heads/main` means the cluster only trusts artifacts produced by **that exact workflow file on that exact branch** — i.e. code that went through review/branch protection. A human identity would let a legitimate maintainer sign an image from their *laptop*, an ad-hoc script, or a feature branch, bypassing all the in-pipeline gates. Binding to the workflow ref makes "was this built by our audited pipeline?" the trust question, which no single person's credentials can satisfy out-of-band.

**A8.3** — *Cost axis:* cheapest/fastest first — gitleaks and checkov are static, sub-second, no build required, so they fail fast before you spend minutes building. *Precondition axis:* each stage needs the prior to be meaningful — trivy needs a *built image* to scan; signing/attesting needs an image that *passed* the vuln gate (you don't want to sign a known-vulnerable artifact and vouch for it). Ordering minimizes wasted work and ensures you only ever sign something that cleared all earlier gates.

**A8.4** — Neither is safe to drop. `cosign sign` in CI *produces* the trustable provenance; Kyverno *enforces* it at the trust boundary. Drop the Kyverno verify and signing becomes decorative — nothing *checks* it, so unsigned/attacker-signed images still run (Exercise 7's bypass returns). Drop the CI signing and Kyverno has nothing valid to verify — every legitimate deploy is denied (or you're forced to disable the policy). They're two halves of one control: *produce* the assertion and *enforce* it. Removing either collapses the model.

</details>