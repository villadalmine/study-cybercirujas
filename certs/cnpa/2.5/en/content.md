# Security Integration in CI/CD Pipelines

**Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
**Domain 2 — Platform Delivery · Topic 2.5** · Exam weight **4.0**

---

## 1. The production problem: the pipeline *is* the attack surface

For a decade the security perimeter was the running workload — the container, the node, the network policy. Platform engineering inverted that. When you build a *golden path* — a paved road where a developer pushes code and a platform turns it into a signed, deployed, running service without manual gates — you have also built a single, highly privileged machine that:

- reads **source** it did not write,
- pulls **hundreds of transitive dependencies** from registries it does not control,
- holds **credentials** to your registry, your cloud account and your production cluster,
- and produces an **artifact that admission control will trust by default**.

That machine is the highest-value target in the organization. Compromise one build step and you sign malware with the organization's own identity and ship it through every downstream gate. This is not theoretical: SolarWinds (2020, malicious build-step injection), Codecov (2021, exfiltration from a tampered CI script), the `event-stream` and `ua-parser-js` npm hijacks, and the 2024 `xz-utils` backdoor were all **supply-chain** compromises, not runtime exploits. None of them would have been stopped by a NetworkPolicy or a Pod Security Standard.

### 1.1 The four trust boundaries (the SLSA threat model)

SLSA (*Supply-chain Levels for Software Artifacts*) formalizes the pipeline as a graph of trust boundaries. Every arrow is an attack you must have a control for:

```
  ┌──────────┐   (A) tampered source      ┌───────────┐
  │  Source  │ ─────────────────────────► │           │
  │  (Git)   │                            │           │
  └──────────┘                            │   Build   │   (D) compromised
        ▲  (B) bad review / unsigned      │  Platform │ ──── build process ───►  ┌──────────┐
        │      commit                     │           │        publishes         │ Artifact │
  ┌──────────┐  (C) poisoned dependency   │           │        false provenance  │ Registry │
  │Dependency│ ─────────────────────────► │           │                          └──────────┘
  │  (deps)  │                            └───────────┘                                │
  └──────────┘                                                        (E) bypass gate  ▼
                                                                                 ┌──────────┐
                                                                                 │ Cluster  │
                                                                                 │ Admission│
                                                                                 └──────────┘
```

| Boundary | Concrete attack | Control that closes it |
|---|---|---|
| (A) Source integrity | Force-push to `main`, tampered tag | Branch protection, **signed commits/tags**, required reviews |
| (B) Author identity | Stolen token, insider unsigned commit | Commit signing (gitsign/GPG), CODEOWNERS |
| (C) Dependency integrity | Typosquat, hijacked upstream, malicious transitive dep | **SCA + SBOM**, pinned digests, lockfile verification, vendoring |
| (D) Build integrity | Malicious build step, poisoned base image, secret exfiltration | Hermetic/isolated builds, ephemeral runners, **provenance attestation (SLSA)** |
| (E) Deploy integrity | Push unsigned/unscanned image straight to prod | **Admission policy verifying signature + attestations** |

### 1.2 Two principles that drive every decision below

- **Shift left, *gate* right.** Detection (SAST, SCA, secret scan) belongs as early as possible so feedback is cheap. Enforcement (the *deny* decision) belongs at the last trust boundary you fully control — cluster admission — because that is the only place an attacker cannot skip by editing the pipeline. A finding that only warns in CI and is not re-checked at admission is a control an attacker deletes in one commit.
- **Nothing runs that cannot be traced to how it was built.** This mirrors the repo rule *"any backend may author; none may author untraceably."* Every artifact must carry a machine-verifiable statement of *what it is, what went into it, and who built it* — an SBOM and a provenance attestation, cryptographically bound to the image digest.

---

## 2. The security control plane of a pipeline — taxonomy and trade-offs

There is no single "security scan." There are ~7 distinct control families, each catching a class the others structurally cannot. A pipeline that runs only image scanning has a false sense of coverage — it never inspects source, IaC, or provenance.

| Control | Stage | What it catches | Blind to | FP profile | Fail policy |
|---|---|---|---|---|---|
| **SAST** (static app analysis) | pre-merge | Injection, unsafe deserialization, hard-coded crypto | Runtime/config, dependency CVEs | High (noisy) | Warn → block on new criticals |
| **SCA** (software composition) | pre-merge + build | Known CVEs in dependencies | Zero-days, logic bugs | Low-med | Block on fixable HIGH/CRITICAL |
| **Secret scanning** | pre-commit + CI | Committed keys, tokens, `.env` | Secrets injected at runtime | Low | **Hard block** always |
| **IaC scanning** | pre-merge | Public S3, `:latest`, privileged pods, open SG | App-layer issues | Medium | Block on policy severity |
| **Image/container scan** | post-build | OS + lang CVEs in the final artifact | Source-only issues, business logic | Med-high | Block on fixable HIGH/CRITICAL |
| **DAST** | staging | Runtime auth/injection/exposure | Requires deployed env; slow | Low but shallow | Non-blocking gate / nightly |
| **Signing + provenance** | post-build + admission | *Untrusted/unknown-origin* artifacts | Vulnerabilities (orthogonal!) | ~Zero | **Hard block at admission** |

> **Key mental model for the exam:** *scanning* answers "is this artifact **vulnerable**?"; *signing/provenance* answers "did **we** actually build this, from **this** pipeline?". They are orthogonal. A CVE-free image from an attacker's fork is still a compromise; a signed image with a CVE is still exploitable. Production needs **both**.

### 2.1 SAST vs SCA vs DAST — where each fails

| Dimension | SAST | SCA | DAST |
|---|---|---|---|
| Needs running app | No | No | **Yes** |
| Sees your code | Yes | No (sees deps) | No (black box) |
| Sees dependencies | Partial | **Yes** | Via behavior only |
| Speed | Seconds–minutes | Seconds | Minutes–hours |
| Best placement | PR check | PR + build | Staging / nightly |
| Typical tools | Semgrep, CodeQL, gosec | Trivy, Grype, Snyk, `govulncheck` | ZAP, Burp, StackHawk |

### 2.2 Signing: cosign (Sigstore) vs Notation (Notary v2) vs cosign keyless

| Property | cosign — long-lived key | cosign — **keyless** (Fulcio/Rekor) | Notation (Notary Project) |
|---|---|---|---|
| Key management | You store & rotate a private key (KMS/KMS) | **No long-lived key** — ephemeral, OIDC-derived | X.509 PKI, CA-issued certs |
| Trust root | The public key you distribute | Fulcio root CA + Rekor transparency log | Your CA / trust store |
| Identity bound | Key possession only | **OIDC identity** (workflow, email, SA) | Cert subject |
| Transparency log | Optional | **Rekor** (public tamper-evident log) | Not built-in |
| Best fit | Air-gapped, no OIDC | **Cloud CI with OIDC** (default for GitHub/GitLab) | Enterprises standardized on X.509 |
| Revocation story | Rotate key, re-sign | Short-lived certs (~10 min) → revocation moot | CRL/OCSP |

**Keyless is the modern default** for cloud-hosted pipelines: the CI job authenticates to Fulcio via its OIDC token, Fulcio issues a ~10-minute code-signing cert bound to the workflow identity, the signature is recorded in the Rekor transparency log, and the ephemeral private key is discarded. There is no key to leak, rotate, or exfiltrate — the attack surface of "someone stole the signing key" disappears entirely.

### 2.3 Admission policy engines

| Engine | Language | Image-verification native? | Strength | Weakness |
|---|---|---|---|---|
| **Kyverno** | YAML (declarative) | **Yes** — `verifyImages` rule | Low barrier, K8s-native, mutate+validate+generate | Less expressive than a full language |
| **OPA Gatekeeper** | Rego | Via external data / `cosign` sidecar patterns | Maximally expressive, portable policy | Rego learning curve; image verify is DIY |
| **Sigstore policy-controller** | YAML `ClusterImagePolicy` | **Purpose-built** for cosign/keyless | Best-in-class signature + attestation policy | Narrow scope (image trust only) |

Rule of thumb: **Kyverno** or **policy-controller** for signature/attestation enforcement, **Gatekeeper** when you already run Rego for broad configuration policy. They compose — many platforms run policy-controller for image trust *and* Gatekeeper/Kyverno for posture.

### 2.4 SBOM formats

| | SPDX | CycloneDX |
|---|---|---|
| Steward | Linux Foundation / ISO/IEC 5962 | OWASP |
| Primary focus | License compliance + composition | Security (VEX, vuln, service, ML-BOM) |
| Best when | Legal/compliance-driven | Security-driven, VEX workflows |
| Tools that emit both | **syft**, **Trivy** | syft, Trivy, cdxgen |

Generate one canonical format, but note both are first-class in syft/Trivy; CycloneDX is usually preferred when you also want **VEX** (Vulnerability Exploitability eXchange) to suppress non-exploitable CVEs.

---

## 3. Reference architecture: a hardened pipeline, end to end

The pipeline below implements every boundary from §1.1. It uses **GitHub Actions with OIDC** (no stored registry password, no stored signing key), builds the image, generates an **SBOM (syft)**, scans it (**Trivy**), **signs keyless (cosign)**, attaches the SBOM and a **provenance attestation**, and pushes to GHCR. Admission control (§3.3–3.4) then refuses anything not produced exactly this way.

### 3.1 The build workflow (`.github/workflows/release.yml`)

```yaml
name: build-sign-attest

on:
  push:
    tags: ["v*"]

permissions:
  contents: read          # checkout only
  packages: write         # push to GHCR
  id-token: write         # OIDC → Fulcio (keyless) AND registry auth
  attestations: write     # GitHub-native provenance (optional, belt & suspenders)

env:
  REGISTRY: ghcr.io
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      # --- Boundary C: dependency integrity (SCA on source) ---
      - name: SCA — scan repo/deps and fail on fixable HIGH/CRITICAL
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig   # SCA + secret + IaC in one pass
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      # --- Reproducible auth: no password stored, OIDC-backed ---
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/setup-buildx-action@v3

      # --- Boundary D: build. Push by DIGEST, capture it ---
      - name: Build & push
        id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ github.ref_name }}
          provenance: true            # SLSA build provenance in the image
          sbom: true

      # --- Install the trust tooling ---
      - uses: sigstore/cosign-installer@v3.7.0
      - uses: anchore/sbom-action/download-syft@v0.17.0

      # --- SBOM as an in-toto attestation, bound to the DIGEST ---
      - name: Generate SBOM (CycloneDX)
        run: syft "${IMAGE}@${DIGEST}" -o cyclonedx-json=sbom.cdx.json
        env:
          IMAGE: ${{ env.IMAGE }}
          DIGEST: ${{ steps.push.outputs.digest }}

      # --- Image scan on the FINAL artifact (defense in depth) ---
      - name: Trivy image scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ env.IMAGE }}@${{ steps.push.outputs.digest }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      # --- Sign KEYLESS: no private key exists to leak ---
      - name: cosign sign (keyless)
        run: cosign sign --yes "${IMAGE}@${DIGEST}"
        env:
          IMAGE: ${{ env.IMAGE }}
          DIGEST: ${{ steps.push.outputs.digest }}

      # --- Attach SBOM as a signed attestation ---
      - name: cosign attest SBOM
        run: |
          cosign attest --yes \
            --type cyclonedx \
            --predicate sbom.cdx.json \
            "${IMAGE}@${DIGEST}"
        env:
          IMAGE: ${{ env.IMAGE }}
          DIGEST: ${{ steps.push.outputs.digest }}

  # --- Boundary D: SLSA provenance via the trusted reusable workflow ---
  provenance:
    needs: build
    permissions:
      actions: read
      id-token: write
      packages: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
    with:
      image: ghcr.io/${{ github.repository }}
      digest: ${{ needs.build.outputs.digest }}
    secrets:
      registry-username: ${{ github.actor }}
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

Why each choice matters:

- **`id-token: write` + keyless** — the job never sees a signing key or a registry password beyond the ephemeral `GITHUB_TOKEN`. There is nothing durable to steal.
- **Push and sign by `@sha256:...` digest, never by tag** — tags are mutable; an attacker who can re-tag can substitute an image after signing. The digest is the artifact's cryptographic identity. Sign the digest, deploy the digest.
- **`ignore-unfixed: true`** — blocking on CVEs with no upstream fix produces unactionable red builds and trains teams to bypass the gate. Block on what a dependency bump can fix; track the rest via VEX.
- **SLSA generator as a *reusable* workflow** — provenance generated inside your own job can be forged by a malicious step in that job. The trusted reusable workflow runs the generation in an isolated context, so the provenance attests to a builder identity a step in your job cannot impersonate → SLSA Build **L3**.

### 3.2 Secrets: OIDC federation over stored credentials

The single biggest reduction in pipeline blast radius is **eliminating long-lived secrets**. Prefer, in order:

1. **OIDC federation to the cloud** — the runner exchanges its OIDC token for short-lived cloud credentials (AWS `AssumeRoleWithWebIdentity`, GCP Workload Identity Federation, Azure federated credentials). No static cloud keys in CI.
2. **Keyless signing** — as above, no signing key.
3. When a real secret is unavoidable, source it from an external store at runtime with **External Secrets Operator**, never from a committed file:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: registry-pull
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: registry-pull        # the k8s Secret this materializes
    creationPolicy: Owner
  data:
    - secretKey: .dockerconfigjson
      remoteRef:
        key: kv/data/ci/registry
        property: dockerconfigjson
```

### 3.3 Enforcement at admission — Kyverno `verifyImages` (keyless)

This is the *gate right* half. It runs in the cluster, so it holds even if the entire pipeline definition is tampered with. It refuses any image not signed by **this specific workflow identity** and lacking a valid SBOM attestation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-and-attested
spec:
  validationFailureAction: Enforce     # Audit first in a new cluster, then Enforce
  webhookTimeoutSeconds: 30
  failurePolicy: Fail                  # fail closed: if Kyverno is down, deny
  background: false
  rules:
    - name: verify-keyless-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "ghcr.io/my-org/*"
          mutateDigest: true           # pin tag→digest on admission
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/my-org/*/.github/workflows/release.yml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/my-org/*/.github/workflows/release.yml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
```

`subject` + `issuer` are the crux: it is not enough that *an* image is signed — it must be signed by the **expected workflow, from the expected repo, on a tag ref**. This is what makes an attacker's fork-built image fail even if they signed it correctly with their own identity.

### 3.4 Alternative: Sigstore `policy-controller` `ClusterImagePolicy`

Purpose-built for exactly this and often paired with Kyverno for broader posture:

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: my-org-keyless
spec:
  images:
    - glob: "ghcr.io/my-org/**"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: "^https://github.com/my-org/.+/.github/workflows/release.yml@refs/tags/.+$"
      ctlog:
        url: https://rekor.sigstore.dev
      attestations:
        - name: must-have-sbom
          predicateType: https://cyclonedx.org/bom
  mode: enforce   # 'warn' during rollout
```

### 3.5 Gatekeeper — the posture layer (block `:latest`, require digests)

Signature policy is orthogonal to configuration hygiene. A Gatekeeper `ConstraintTemplate` closes the "someone deployed by mutable tag" gap:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredigest
spec:
  crd:
    spec:
      names:
        kind: K8sRequireDigest
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredigest
        violation[{"msg": msg}] {
          c := input.review.object.spec.containers[_]
          not contains(c.image, "@sha256:")
          msg := sprintf("image %q must be pinned by digest, not a tag", [c.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequireDigest
metadata:
  name: images-must-be-digest-pinned
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
```

---

## 4. CLI and terminal output — the operator's view

### 4.1 Sign keyless and inspect the Rekor entry

```console
$ COSIGN_YES=1 cosign sign ghcr.io/my-org/api@sha256:9f2b...c41a
Generating ephemeral keys...
Retrieving signed certificate...
The sigstore service, hosted by sigstore a Series of LF Projects, LLC...
Successfully verified SCT...
tlog entry created with index: 148820371
Pushing signature to: ghcr.io/my-org/api
```

```console
$ cosign verify \
    --certificate-identity-regexp \
      "https://github.com/my-org/.+/.github/workflows/release.yml@refs/tags/.+" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/my-org/api@sha256:9f2b...c41a | jq -r '.[0].optional.Subject'

Verification for ghcr.io/my-org/api@sha256:9f2b...c41a --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
https://github.com/my-org/api/.github/workflows/release.yml@refs/tags/v1.4.2
```

### 4.2 SBOM and vulnerability triage

```console
$ syft ghcr.io/my-org/api@sha256:9f2b...c41a -o cyclonedx-json=sbom.cdx.json
 ✔ Parsed image        sha256:9f2b...c41a
 ✔ Cataloged contents
   ├── ✔ Packages                  [214 packages]
   ├── ✔ File digests              [1,908 files]
   └── ✔ Executables               [143 executables]

$ grype sbom:sbom.cdx.json --fail-on high
NAME        INSTALLED   FIXED-IN   TYPE  VULNERABILITY   SEVERITY
libcrypto3  3.3.0-r2    3.3.2-r0   apk   CVE-2024-6119   High
stdlib      1.22.3      1.22.5     go    CVE-2024-24790  Critical

1 error occurred:
  * discovered vulnerabilities at or above the severity threshold
$ echo $?
1
```

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    ghcr.io/my-org/api@sha256:9f2b...c41a
ghcr.io/my-org/api (alpine 3.20.1)
Total: 1 (HIGH: 1, CRITICAL: 0)
┌────────────┬───────────────┬──────────┬────────┬───────────────┬───────────────┐
│  Library   │ Vulnerability │ Severity │ Status │ Installed Ver │  Fixed Ver    │
├────────────┼───────────────┼──────────┼────────┼───────────────┼───────────────┤
│ libcrypto3 │ CVE-2024-6119 │ HIGH     │ fixed  │ 3.3.0-r2      │ 3.3.2-r0      │
└────────────┴───────────────┴──────────┴────────┴───────────────┴───────────────┘
```

### 4.3 Verify SLSA provenance

```console
$ slsa-verifier verify-image ghcr.io/my-org/api@sha256:9f2b...c41a \
    --source-uri github.com/my-org/api \
    --source-tag v1.4.2
Verifying image ghcr.io/my-org/api@sha256:9f2b...c41a ...
Verifying artifact digest: 9f2b...c41a
Verifying builder id: https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.0.0
Verifying source: github.com/my-org/api at tag v1.4.2
PASSED: SLSA verification passed
```

### 4.4 The gate doing its job at admission

```console
$ kubectl run rogue --image=ghcr.io/my-org/api:latest -n apps
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/apps/rogue was blocked due to the following policies

require-signed-and-attested:
  verify-keyless-signature: |
    failed to verify image ghcr.io/my-org/api:latest:
    .attestors[0].entries[0].keyless: no matching signatures:
    none of the expected identities matched what was in the certificate
```

```console
# an attacker's fork-built (but validly self-signed) image also fails:
$ kubectl apply -f attacker-fork.yaml
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
  subject mismatch: got "https://github.com/attacker/api/.github/workflows/release.yml@refs/tags/v9",
  want "https://github.com/my-org/*/.github/workflows/release.yml@refs/tags/*"
```

---

## 5. Verification and failure diagnostics

A runbook keyed to the failures you will actually hit in production.

### 5.1 `cosign verify` fails — decision tree

```console
$ cosign verify --certificate-identity-regexp "..." \
    --certificate-oidc-issuer "..." ghcr.io/my-org/api@sha256:...
Error: no matching signatures
```

| Symptom in output | Root cause | Fix |
|---|---|---|
| `no signatures found` | Never signed, or signed a **different digest** (tag moved) | Re-check the digest; confirm the sign step ran on `@sha256`, not the tag |
| `no matching signatures: none of the expected identities matched` | `--certificate-identity` regex doesn't match the signer | `cosign verify --insecure-ignore-tlog` then inspect `.optional.Subject`; align the regex to the real workflow ref |
| `certificate expired` on **offline** verify | Fulcio certs are short-lived; you're verifying the cert validity window not the sign time | Verify against Rekor (online) so the tlog timestamp is used, not wall-clock |
| `error verifying SCT` | Clock skew or wrong trust root | `sudo chronyc makestep`; refresh the TUF root: `cosign initialize` |

Inspect what was actually signed, straight from the transparency log:

```console
$ rekor-cli search --sha sha256:9f2b...c41a
Found matching entries (listed by UUID):
24296fb2...e1
$ rekor-cli get --uuid 24296fb2...e1 --format json | jq '.Body.HashedRekordObj.signature.publicKey' 
# → decode to see the exact certificate Subject/Issuer that signed
```

### 5.2 Admission denies a *legitimate* deployment

Order of investigation:

1. **Is the policy in `Enforce`/`enforce` before you were ready?** Roll to `Audit`/`warn`, confirm the artifact, then re-enforce.
2. **Digest vs tag.** Kyverno with `mutateDigest: true` resolves the tag at admission; if the tag now points at an *unsigned* rebuild, it fails correctly. Deploy by digest.
3. **Kyverno can't reach Rekor/Fulcio.** In a restricted-egress cluster, verification fails closed. Check:
   ```console
   $ kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -i verifyImages
   ... "failed to verify image" err="Get \"https://rekor.sigstore.dev/...\": context deadline exceeded"
   ```
   Fix: allow egress to Fulcio/Rekor, or run an internal Sigstore stack and set `rekor.url`/pin the TUF root via a `ConfigMap`.
4. **`failurePolicy: Fail` + webhook down = whole namespace blocked.** Confirm the admission controller is healthy:
   ```console
   $ kubectl get --raw /readyz?verbose | grep -i webhook
   $ kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep kyverno
   ```

### 5.3 Test policies *before* they reach a live cluster

Never discover a policy bug in production admission. Dry-run and unit-test:

```console
$ kyverno apply require-signed-and-attested.yaml --resource test-pod.yaml
Applying 1 policy rule(s) to 1 resource(s)...
policy require-signed-and-attested -> resource apps/Pod/api-7d... : fail
  verify-keyless-signature: image is not signed by the expected identity

$ conftest test deploy.yaml --policy policy/           # OPA/Rego unit tests
FAIL - deploy.yaml - main - image must be pinned by digest, not a tag
1 test, 0 passed, 1 failure
```

Roll enforcement out in three stages, never straight to Enforce:
**`Audit`/`warn`** (observe violations) → fix findings → **`Enforce`** on a canary namespace → **`Enforce`** cluster-wide.

### 5.4 Scanner triage — separate "blocking" from "noise"

- **Unfixable CVE blocking the build:** `--ignore-unfixed` at the gate; record the CVE in a **VEX** document so it is *acknowledged*, not silently dropped.
  ```console
  $ trivy image --vex vex.openvex.json --severity CRITICAL <image>
  # CVE-2024-24790 suppressed: VEX status "not_affected" (component not in call path)
  ```
- **`govulncheck` over Trivy for Go** when you need call-graph reachability — it reports only CVEs your code actually reaches:
  ```console
  $ govulncheck ./...
  Vulnerability #1: GO-2024-2937 (reachable)
    Your code calls net/http... via handler.ServeHTTP
  ```
- **Secret finding = stop the line.** A committed credential is *already leaked*; rotate first, scrub history second. Rewriting history does not un-leak the secret.
  ```console
  $ gitleaks detect --source . --redact
  Finding:     AWS Access Key
  Secret:      AKIA****REDACTED
  File:        config/dev.env      Commit: a1b2c3d
  ```

### 5.5 Golden signal: `verify what you deploy`, continuously

The last defense is a periodic re-verification job, because trust roots rotate and images get re-tagged. Reconcile *what admission trusts* against *what is running*:

```console
$ for img in $(kubectl get pods -A -o jsonpath='{..image}' | tr ' ' '\n' | sort -u); do
    cosign verify --certificate-identity-regexp "$ID" \
      --certificate-oidc-issuer "$ISS" "$img" >/dev/null 2>&1 \
      && echo "OK   $img" || echo "FAIL $img"
  done
OK   ghcr.io/my-org/api@sha256:9f2b...c41a
FAIL docker.io/library/redis:7        # ← unsigned base infra image: expected exception or gap
```

---

## References

- CNCF — *CNPA (Cloud Native Platform Engineering Associate) Curriculum*: https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- SLSA — *Supply-chain Levels for Software Artifacts* (v1.0, build levels & provenance): https://slsa.dev/spec/v1.0/
- Sigstore — cosign (signing, keyless, attestations): https://docs.sigstore.dev/cosign/signing/overview/
- Sigstore — Fulcio (certificate authority): https://docs.sigstore.dev/certificate_authority/overview/
- Sigstore — Rekor (transparency log): https://docs.sigstore.dev/logging/overview/
- Sigstore — `policy-controller` / `ClusterImagePolicy`: https://docs.sigstore.dev/policy-controller/overview/
- SLSA GitHub Generator (container provenance, SLSA L3): https://github.com/slsa-framework/slsa-github-generator
- slsa-verifier: https://github.com/slsa-framework/slsa-verifier
- Kyverno — image verification (`verifyImages`): https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- in-toto attestation framework: https://github.com/in-toto/attestation
- Anchore syft (SBOM): https://github.com/anchore/syft
- Anchore grype (vulnerability scanning): https://github.com/anchore/grype
- Aqua Trivy (SCA, image, IaC, secret, SBOM): https://trivy.dev/latest/docs/
- CycloneDX SBOM specification: https://cyclonedx.org/specification/overview/
- SPDX specification (ISO/IEC 5962): https://spdx.dev/use/specifications/
- OpenVEX (Vulnerability Exploitability eXchange): https://github.com/openvex/spec
- Go `govulncheck`: https://go.dev/doc/tutorial/govulncheck
- GitHub Actions — OIDC hardening & `id-token`: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- External Secrets Operator: https://external-secrets.io/latest/
- CNCF Software Supply Chain Security Best Practices (TAG Security): https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper