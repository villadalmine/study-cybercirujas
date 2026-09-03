# 704.1 Cloud Native Security

**Exam:** LPI DevOps Tools Engineer 701-100, version 2.0.0
**Weight:** 6.67

---

## 1. The architectural problem

Classical infrastructure security is a *perimeter* discipline: a firewall separates trusted from untrusted, hosts are long-lived, and a machine's security posture is the accumulated result of years of patching. Every one of those assumptions breaks in a cloud native platform.

Consider a concrete production incident shape that this objective exists to prevent:

> A team ships `api:latest` to a shared cluster. The image was built four months ago on a developer laptop; nobody can reproduce it. It runs as UID 0 because the base image's entrypoint writes to `/etc`. The pod mounts a service account token by default, and that service account was bound to `cluster-admin` during a Helm-chart debugging session that was never reverted. There is no NetworkPolicy, so every pod in the cluster can reach every other pod, including the etcd-backed internal admin API. A dependency in the image carries a known local privilege escalation. An attacker who achieves RCE in the application obtains root in the container, escalates to root on the node through the unpatched glibc, reads every other container's secrets off the kubelet's filesystem, and pivots laterally with an unlimited API token.

Every link in that chain is a distinct control failure, and each one belongs to a different layer of the stack. That is why cloud native security is organised as **defence in depth across layers**, not as a single boundary:

| Layer | Trust boundary | You control it via | Failure mode if absent |
|---|---|---|---|
| **Cloud / infrastructure** | Tenant ↔ provider | IAM, instance metadata policy, VPC/subnet design, disk encryption, node OS hardening | Metadata service (`169.254.169.254`) credential theft from any pod |
| **Cluster** | API server ↔ client; namespace ↔ namespace | RBAC, admission control, encryption at rest, audit policy, kubelet authn/authz | One compromised workload becomes cluster-admin |
| **Container / workload** | Container ↔ host kernel | `securityContext`, seccomp, LSM (AppArmor/SELinux), capabilities, user namespaces, RuntimeClass | Container escape via a kernel bug or a permissive `CAP_SYS_ADMIN` |
| **Code / supply chain** | Build system ↔ artifact ↔ runtime | Signing, attestation, SBOM, scanning, digest pinning, reproducible builds | You deploy something nobody can attribute or reproduce |

The layering is not decorative. It determines *where a control can be enforced at all*. You cannot fix a vulnerable dependency at admission time; you cannot fix a wildcard RoleBinding in the Dockerfile. A platform architect's job in this objective is to place each control at the cheapest layer that can actually enforce it, and to make the enforcement *non-optional* — a policy that developers can bypass by adding a flag is documentation, not a control.

Two properties distinguish cloud native security from traditional hardening:

1. **Immutability replaces patching.** You do not `apt upgrade` a running container; you rebuild the image and roll the Deployment. This converts a *runtime* problem into a *pipeline* problem, which is good — pipelines are testable — but it means the pipeline itself is now a production system with production availability requirements.
2. **Identity replaces network location.** In a flat pod network, "the IP came from inside the cluster" proves nothing. Authorization must be based on cryptographic workload identity (a service account token, an SVID, an mTLS peer certificate), not on source address.

**Threat-model reference:** NIST SP 800-190 enumerates container-specific risks (image, registry, orchestrator, container, host OS) and remains the most citable baseline for a formal risk register. The CNCF TAG Security cloud native security guidance covers the same ground with the lifecycle framing (develop → distribute → deploy → runtime) used below.

---

## 2. Layer: supply chain — provenance before permissions

### 2.1 What "provenance" means operationally

A production image must answer four questions, mechanically, without asking a human:

| Question | Artifact that answers it | Verification tool |
|---|---|---|
| What is *in* this image? | SBOM (SPDX or CycloneDX) | `syft`, `trivy sbom` |
| Are the things in it known-vulnerable? | Vulnerability report against the SBOM | `trivy`, `grype` |
| Who built it, from which source, on what builder? | SLSA provenance attestation (in-toto predicate) | `cosign verify-attestation`, `slsa-verifier` |
| Is this exact bag of bytes the one that was signed? | Signature over the manifest digest | `cosign verify` |

Note the ordering dependency: a signature over a *tag* is worthless, because tags are mutable. Signatures and policy must always bind to `@sha256:...`.

### 2.2 Base image and Dockerfile hardening

```dockerfile
# syntax=docker/dockerfile:1.7

########################################
# Stage 1 — build
########################################
FROM golang:1.22.6-bookworm AS build

WORKDIR /src

# Dependency layer: cached independently of source changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

# Reproducibility: static binary, no cgo, stripped, trimmed paths,
# version stamped from the build argument (never from `git` inside the image).
ARG VERSION=dev
ARG COMMIT=unknown
ARG SOURCE_DATE_EPOCH=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
      -trimpath \
      -buildvcs=false \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/api ./cmd/api

########################################
# Stage 2 — runtime
########################################
FROM gcr.io/distroless/static-debian12:nonroot

# Distroless "static" contains: ca-certificates, /etc/passwd with a `nonroot`
# user (65532), tzdata, and nothing else. No shell, no package manager,
# no libc for a dynamically linked payload to abuse.
COPY --from=build --chown=65532:65532 /out/api /usr/local/bin/api

USER 65532:65532
WORKDIR /
EXPOSE 8080

# Exec form: PID 1 is the application, so SIGTERM reaches it directly and
# graceful shutdown works. Shell form would insert /bin/sh, which does not
# exist here anyway.
ENTRYPOINT ["/usr/local/bin/api"]
```

Design decisions worth defending in a review:

* **Multi-stage** keeps the compiler, module cache and source tree out of the shipped artifact. The runtime image contains one binary; the attack surface is the binary plus the kernel.
* **`USER 65532`** in the image is a defence-in-depth duplicate of `runAsUser` in the Pod spec. Kubernetes' `runAsNonRoot: true` fails the container at *start* if the image's declared user resolves to UID 0 — which is exactly the early, loud failure you want.
* **No shell** breaks the majority of published container-escape and cryptominer payloads, which are shell scripts. It also breaks `kubectl exec -it -- sh`, which is a deliberate trade-off: use ephemeral debug containers instead (§7.4).
* **`SOURCE_DATE_EPOCH`** and `-trimpath` move you toward byte-reproducible builds, which is what makes an independent rebuild a meaningful check on the build system.

### 2.3 Scanning: choosing a tool and, more importantly, a policy

| | Trivy | Grype | Clair |
|---|---|---|---|
| Scope | OS packages, language deps, IaC, K8s manifests, secrets, licenses | OS packages, language deps | OS packages (container-centric) |
| SBOM | Generates and consumes SPDX + CycloneDX | Consumes Syft SBOM natively | Consumes, indexer-based |
| Deployment model | Single static binary, or K8s operator | Single binary, pairs with `syft` | Server + indexer + matcher, API-driven |
| DB distribution | OCI artifact pulled from registry | OCI artifact (Grype DB) | Server-side updaters |
| Best fit | One tool for CI + IaC + cluster | Pipeline pairing with Syft-first SBOM flow | Registry-integrated continuous rescanning |

The tool matters less than these three policy decisions:

1. **`--ignore-unfixed`.** A CRITICAL with no upstream fix is not actionable by the build; failing the pipeline on it trains people to add blanket ignores. Track it, don't block on it.
2. **Rescan continuously, not once.** An image scanned clean on Monday is not clean on Friday; the CVE was published, not introduced. This is why registry-side or in-cluster rescanning (Trivy Operator, Clair) matters more than the CI gate.
3. **Exceptions must expire.** Use `.trivyignore` entries with an expiry date, reviewed, not a permanent allowlist.

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    registry.example.com/platform/api:1.24.3

2026-09-03T14:02:11Z    INFO    Vulnerability scanning is enabled
2026-09-03T14:02:11Z    INFO    Detected OS: debian
2026-09-03T14:02:11Z    INFO    Detecting Debian vulnerabilities...
2026-09-03T14:02:12Z    INFO    Number of language-specific files: 1

registry.example.com/platform/api:1.24.3 (debian 12.6)
======================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌────────────────┬────────────────┬──────────┬────────┬───────────────────┬────────────────────┬─────────────────────────────────────────┐
│    Library     │ Vulnerability  │ Severity │ Status │ Installed Version │   Fixed Version    │                  Title                  │
├────────────────┼────────────────┼──────────┼────────┼───────────────────┼────────────────────┼─────────────────────────────────────────┤
│ libc6          │ CVE-2023-4911  │ HIGH     │ fixed  │ 2.36-9+deb12u4    │ 2.36-9+deb12u7     │ glibc: buffer overflow in ld.so via     │
│                │                │          │        │                   │                    │ GLIBC_TUNABLES (local privesc)          │
├────────────────┼────────────────┼──────────┼────────┼───────────────────┼────────────────────┼─────────────────────────────────────────┤
│ openssh-server │ CVE-2024-6387  │ CRITICAL │ fixed  │ 1:9.2p1-2+deb12u2 │ 1:9.2p1-2+deb12u3  │ openssh: signal handler race leading    │
│                │                │          │        │                   │                    │ to pre-auth RCE as root (regreSSHion)   │
└────────────────┴────────────────┴──────────┴────────┴───────────────────┴────────────────────┴─────────────────────────────────────────┘

api (gobinary)
==============
Total: 1 (HIGH: 1, CRITICAL: 0)

┌───────────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┬──────────────────────────────────────┐
│      Library      │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │                Title                 │
├───────────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┼──────────────────────────────────────┤
│ golang.org/x/net  │ CVE-2023-39325 │ HIGH     │ fixed  │ v0.14.0           │ v0.17.0       │ net/http: HTTP/2 rapid reset DoS     │
└───────────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┴──────────────────────────────────────┘

$ echo $?
1
```

Read that output as an architect, not as a ticket queue. `openssh-server` in an application image is not a CVE, it is a *design defect*: there is no reason for an API container to ship an SSH daemon. The fix is not `apt upgrade`, it is the distroless base of §2.2, which removes the finding permanently instead of resetting the clock on it.

### 2.4 SBOM generation

```console
$ syft registry.example.com/platform/api:1.24.3 -o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json
 ✔ Loaded image                    registry.example.com/platform/api:1.24.3
 ✔ Parsed image                    sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
 ✔ Cataloged contents
   ├── ✔ Packages                        [148 packages]
   ├── ✔ File digests                    [412 files]
   └── ✔ Executables                     [1 executables]

$ jq '.packages | length' sbom.spdx.json
148

$ jq -r '.packages[] | select(.name=="golang.org/x/net") | "\(.name) \(.versionInfo)"' sbom.spdx.json
golang.org/x/net v0.14.0
```

The SBOM is what makes the next CVE cheap. When the next `golang.org/x/net` advisory drops, the question "which of our 300 images are affected?" becomes a `jq` query over stored SBOMs instead of 300 rebuilds.

### 2.5 Signing and attestation with Sigstore

Keyless signing removes the worst part of code signing — long-lived private keys. `cosign` requests an ephemeral certificate from Fulcio bound to an OIDC identity (the CI workflow's identity), signs, discards the key, and records the signing event in the Rekor transparency log. Verification checks the certificate chain, the identity, and the log inclusion proof.

```console
$ cosign sign --yes registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
Generating ephemeral keys...
Retrieving signed certificate...
Successfully verified SCT...
tlog entry created with index: 148392017
Pushing signature to: registry.example.com/platform/api

$ cosign attest --yes --predicate sbom.spdx.json --type spdxjson \
    registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
Using payload from: sbom.spdx.json
tlog entry created with index: 148392018
```

Verification, with the identity constraint that actually carries the security value:

```console
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/example-org/platform-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840

Verification for registry.example.com/platform/api@sha256:9b2f1c7a... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[{"critical":{"identity":{"docker-reference":"registry.example.com/platform/api"},"image":{"docker-manifest-digest":"sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840"},"type":"cosign container image signature"},"optional":{"1.3.6.1.4.1.57264.1.9":"https://github.com/example-org/platform-api/.github/workflows/release.yaml@refs/tags/v1.24.3","Bundle":{"SignedEntryTimestamp":"MEUCIQD...","Payload":{"logIndex":148392017,"logID":"c0d23d6a...","integratedTime":1788442931}}}}]
```

And the failure you *want* to see when someone signs from the wrong workflow:

```console
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/example-org/platform-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/platform/api@sha256:11aa22bb33cc44dd55ee66ff7788990011223344556677889900aabbccddeeff

Error: no matching signatures:
none of the expected identities matched what was in the certificate, got subjects
[https://github.com/example-org/platform-api/.github/workflows/nightly.yaml@refs/heads/main]
with issuer https://token.actions.githubusercontent.com
main.go:74: error during command execution: no matching signatures
```

> **Anti-pattern:** `cosign verify <image>` without `--certificate-identity*` and `--certificate-oidc-issuer` is not verification. It proves *someone* signed the image. Anyone with a GitHub account can do that. The identity constraint is the policy.

### 2.6 SLSA levels as a maturity target

| Level | Requirement | Practical implementation |
|---|---|---|
| **Build L1** | Provenance exists and is distributed | CI emits an in-toto provenance attestation with the source repo, commit and builder |
| **Build L2** | Provenance is signed by a hosted build platform | Attestation signed by the CI platform's identity (OIDC → Fulcio), not by a developer key |
| **Build L3** | Builds run in isolated, ephemeral environments; provenance is non-forgeable by the build's own steps | Signing key material inaccessible to user-controlled build steps; reusable, pinned workflow; no self-hosted runner reuse |

L2 is achievable in a day with keyless signing on hosted runners. L3 is an organisational programme: it requires that a compromised build *step* cannot forge provenance, which means removing signing from the job the developer controls.

### 2.7 The pipeline, end to end

```yaml
# .github/workflows/release.yaml
name: release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  build-sign-attest:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write
      id-token: write        # REQUIRED: mints the OIDC token cosign exchanges at Fulcio
      attestations: write
    env:
      REGISTRY: registry.example.com
      IMAGE: platform/api
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3

      - name: Registry login
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          provenance: mode=max
          sbom: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE }}:${{ github.ref_name }}
          build-args: |
            VERSION=${{ github.ref_name }}
            COMMIT=${{ github.sha }}
            SOURCE_DATE_EPOCH=0
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Install cosign
        uses: sigstore/cosign-installer@v3

      - name: Install trivy
        uses: aquasecurity/setup-trivy@v0.2.0

      - name: Generate SBOM (SPDX)
        run: |
          set -euo pipefail
          trivy image \
            --format spdx-json \
            --output sbom.spdx.json \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Vulnerability gate
        run: |
          set -euo pipefail
          trivy image \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            --exit-code 1 \
            --format table \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Sign image by digest
        run: |
          set -euo pipefail
          cosign sign --yes "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Attach SBOM attestation
        run: |
          set -euo pipefail
          cosign attest --yes \
            --predicate sbom.spdx.json \
            --type spdxjson \
            "${REGISTRY}/${IMAGE}@${{ steps.build.outputs.digest }}"

      - name: Emit digest for GitOps
        run: |
          echo "digest=${{ steps.build.outputs.digest }}" >> "$GITHUB_STEP_SUMMARY"
```

Three details are load-bearing:

* **`id-token: write`** is what makes keyless signing possible. Without it `cosign sign` fails with `error getting signer: getting key from Fulcio: retrieving cert: no identity token provided`.
* **Everything after the build references `${{ steps.build.outputs.digest }}`, never the tag.** Scanning tag `v1.24.3` and signing tag `v1.24.3` can, in a race or with a mutable tag, operate on two different images.
* **The gate runs before the signature.** A signature asserts "we vouch for this"; signing an image you have not yet scanned inverts the meaning.

The GitLab CI equivalent uses `id_tokens:` with `aud: sigstore` and is otherwise identical.

---

## 3. Layer: cluster configuration

### 3.1 RBAC — least privilege that survives contact with a Helm chart

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api
  namespace: production
# Deny the legacy auto-mounted token at the identity level. Any pod that
# genuinely needs API access opts in explicitly with a projected volume.
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-config-reader
  namespace: production
rules:
  # Named resources only. `resourceNames` is the difference between
  # "read one ConfigMap" and "read every ConfigMap in the namespace",
  # and the latter is how config-borne credentials leak.
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-runtime-config", "api-feature-flags"]
    verbs: ["get", "watch"]
  # `list` is deliberately absent: `list` cannot be constrained by
  # resourceNames, so granting it grants read access to the whole collection.
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    resourceNames: ["api-leader"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-config-reader
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: api-config-reader
subjects:
  - kind: ServiceAccount
    name: api
    namespace: production
```

The three RBAC facts that decide most real-world outcomes:

| Fact | Consequence |
|---|---|
| RBAC is purely additive; there is no `deny` rule | You cannot "subtract" a permission granted by another binding. Audit *all* bindings for a subject, not the one you wrote. |
| `resourceNames` does not constrain `list`, `watch` on collections, `deletecollection` or `create` | A Role with `list` on `secrets` is a Role with read access to every secret in the namespace. |
| `escalate`, `bind`, and `impersonate` are privilege-escalation verbs | `bind` on ClusterRoles lets a subject grant itself anything. Treat them as cluster-admin equivalents. |

Hunting for existing over-grants:

```console
$ kubectl get clusterrolebindings -o json | \
    jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
           .metadata.name as $n | (.subjects // [])[] |
           "\($n)\t\(.kind)/\(.namespace // "-")/\(.name)"'
cluster-admin	Group/-/system:masters
gitlab-runner-admin	ServiceAccount/ci/gitlab-runner
monitoring-debug	ServiceAccount/monitoring/prom-debug

$ kubectl auth can-i --list --as=system:serviceaccount:ci:gitlab-runner
Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             []                  []               [*]
                                                [*]                 []               [*]
```

`*.*` with `[*]` is the signature of a cluster takeover primitive sitting in your CI namespace. Anyone who can submit a pipeline job owns the cluster.

```console
$ kubectl auth can-i --list --as=system:serviceaccount:production:api -n production
Resources                                       Non-Resource URLs   Resource Names                        Verbs
selfsubjectreviews.authentication.k8s.io        []                  []                                    [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []                                    [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []                                    [create]
leases.coordination.k8s.io                      []                  []                                    [create]
leases.coordination.k8s.io                      []                  [api-leader]                          [get update patch]
configmaps                                      []                  [api-runtime-config api-feature-flags] [get watch]

$ kubectl auth can-i get secrets --as=system:serviceaccount:production:api -n production
no
```

### 3.2 Service account tokens: bound, audience-scoped, short-lived

Legacy `Secret`-backed service account tokens never expire, have no audience, and are readable by anything that can read Secrets. Modern clusters issue **projected, bound tokens**: signed JWTs with an expiry, an audience, and a binding to the Pod object, so the token is invalidated when the Pod is deleted.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-token-demo
  namespace: production
spec:
  serviceAccountName: api
  automountServiceAccountToken: false
  containers:
    - name: api
      image: registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
      volumeMounts:
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: vault-token
      projected:
        defaultMode: 0444
        sources:
          - serviceAccountToken:
              # `audience` is the anti-replay control: a token minted for
              # "vault" is rejected by the Kubernetes API server, and vice versa.
              audience: vault
              expirationSeconds: 3600
              path: vault-token
```

```console
$ kubectl create token api -n production --audience=vault --duration=10m \
  | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq
{
  "aud": [
    "vault"
  ],
  "exp": 1788446531,
  "iat": 1788445931,
  "iss": "https://oidc.example.com/clusters/leloir",
  "jti": "d9a1f0c2-7b44-4f18-9a03-1c6e5b28d7aa",
  "kubernetes.io": {
    "namespace": "production",
    "serviceaccount": {
      "name": "api",
      "uid": "5c3f2a91-0e84-4d77-b6a2-9f1c0d38e4b5"
    }
  },
  "nbf": 1788445931,
  "sub": "system:serviceaccount:production:api"
}
```

That `iss` is the cluster's OIDC issuer. Publishing it (`kubectl get --raw /.well-known/openid-configuration`) is what allows a cloud IAM provider or Vault to federate directly against Kubernetes workload identity — no static cloud credentials in the cluster at all. This is the correct answer to "how does my pod get an S3 credential".

### 3.3 Pod Security Admission

PSA is the built-in, namespace-labelled enforcement of the three Pod Security Standards. It is stable since Kubernetes 1.25 and costs nothing to run — it is in-process in the API server.

| Profile | Blocks | Typical use |
|---|---|---|
| `privileged` | nothing | Node-level system components only (CNI, CSI, monitoring agents) |
| `baseline` | privileged containers, host namespaces, hostPath, hostPort, adding non-default capabilities, `/proc` masking changes | Migration target for legacy workloads |
| `restricted` | everything in `baseline`, plus: must `runAsNonRoot`, must drop `ALL` capabilities, must set `allowPrivilegeEscalation: false`, must set a `seccompProfile`, volume types limited to a safe set | Every application namespace |

Three independent modes per namespace — this is the migration mechanism:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    # Hard rejection at admission.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    # Returns a warning to the client (kubectl prints it) but admits.
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    # Emits an audit annotation on the API server audit event.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
```

Pin `*-version` explicitly. `latest` means the profile silently tightens when you upgrade the control plane, and workloads that admitted last week start failing during a cluster upgrade — a genuinely painful way to discover a policy change.

The safe rollout order is `warn` → `audit` → `enforce`, and server-side dry-run tells you the blast radius *before* you commit:

```console
$ kubectl label --dry-run=server --overwrite ns production \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "production" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-batch-9f7c4d8b6-t4kzn (and 3 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/production labeled (server dry run)
```

And the enforcement message when a violating Pod is submitted:

```console
$ kubectl apply -f bad-pod.yaml
Error from server (Forbidden): error when creating "bad-pod.yaml": pods "legacy" is forbidden:
violates PodSecurity "restricted:v1.30":
allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**Critical limitation:** PSA validates the **Pod** object. A Deployment with a violating template is *accepted*; the failure surfaces later, in the ReplicaSet's events, as pods that never get created. This is why the `warn` label matters — it is what makes `kubectl apply -f deployment.yaml` print the warning at the moment the human is looking.

```console
$ kubectl -n production describe rs legacy-batch-9f7c4d8b6 | tail -6
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  12s (x4 over 31s)  replicaset-controller  Error creating: pods "legacy-batch-9f7c4d8b6-" is forbidden: violates PodSecurity "restricted:v1.30": runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 3.4 Admission control beyond PSA

PSA covers a fixed set of Pod-level checks. Everything else — required labels, allowed registries, signature verification, resource limits, ingress hostname ownership — needs general-purpose admission.

| | Pod Security Admission | ValidatingAdmissionPolicy (CEL) | Kyverno | OPA Gatekeeper |
|---|---|---|---|---|
| Where it runs | In-process in `kube-apiserver` | In-process in `kube-apiserver` | External webhook (deployment) | External webhook (deployment) |
| Language | none (fixed profiles) | CEL | YAML (K8s-native DSL) | Rego |
| Scope | Pods only | Any resource, validation only¹ | Any resource: validate, mutate, generate, cleanup, verify images | Any resource: validate, mutate |
| Image signature verification | ✗ | ✗ (no network egress from CEL) | ✓ native `verifyImages` | via external data / `gator` + provider |
| Availability risk | none | none | Webhook down + `failurePolicy: Fail` ⇒ API writes blocked | same |
| Learning curve | none | low | low–medium | medium–high (Rego) |
| Best for | Baseline every cluster must have | Cheap, dependency-free structural rules | Full policy platform, supply-chain enforcement | Organisations already standardised on Rego/OPA |

¹ Mutating admission policies in CEL are a newer, still-maturing addition; validation is the GA path.

**Recommended composition, not selection:** PSA for the workload baseline (free, cannot fail open), `ValidatingAdmissionPolicy` for structural invariants that must survive a webhook outage, and one policy engine (Kyverno *or* Gatekeeper) for supply-chain and cross-resource policy.

**In-tree CEL policy — digest pinning, no external dependency:**

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-digest-pinned-images
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allImages
      expression: >-
        (object.spec.containers.map(c, c.image)) +
        (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
  validations:
    - expression: "variables.allImages.all(i, i.contains('@sha256:'))"
      message: "every container image must be pinned by digest, e.g. registry.example.com/app@sha256:<64-hex>"
      reason: Forbidden
    - expression: "variables.allImages.all(i, i.startsWith('registry.example.com/'))"
      message: "images must come from registry.example.com"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-digest-pinned-images-binding
spec:
  policyName: require-digest-pinned-images
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

```console
$ kubectl -n production run probe --image=nginx:1.27 --restart=Never
Error from server (Forbidden): admission webhook denied the request:
ValidatingAdmissionPolicy 'require-digest-pinned-images' with binding 'require-digest-pinned-images-binding' denied request:
every container image must be pinned by digest, e.g. registry.example.com/app@sha256:<64-hex>
```

**Kyverno — signature verification at admission.** This is the control that closes the supply-chain loop: an image that was never signed by the release workflow cannot run, no matter who has RBAC to create Pods.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-platform-image-signatures
  annotations:
    policies.kyverno.io/title: Verify image signatures (keyless)
    policies.kyverno.io/severity: critical
spec:
  # NOTE: schema drift — `spec.validationFailureAction` is the Kyverno 1.11/1.12
  # field. From 1.13 it is deprecated in favour of per-rule `failureAction`.
  # Pin your Kyverno version and match the schema to it.
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-signed-by-release-workflow
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
                - staging
      verifyImages:
        - imageReferences:
            - "registry.example.com/platform/*"
          # Resolve the tag to a digest and rewrite the Pod spec, so what is
          # verified is exactly what is run. Closes the TOCTOU gap between
          # admission and image pull.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example-org/*/.github/workflows/release.yaml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

```console
$ kubectl -n production apply -f deploy-unsigned.yaml
Error from server: error when creating "deploy-unsigned.yaml": admission webhook
"mutate.kyverno.svc-fail" denied the request:
resource Pod/production/scratch-7f6b was blocked due to the following policies

verify-platform-image-signatures:
  verify-signed-by-release-workflow: 'failed to verify image registry.example.com/platform/scratch:dev:
    .attestors[0].entries[0].keyless: no signatures found'
```

**Gatekeeper equivalent** for the allowed-registry rule, for teams standardised on Rego:

```yaml
---
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("container <%v> has disallowed image <%v>", [container.name, container.image])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("initContainer <%v> has disallowed image <%v>", [container.name, container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: only-corporate-registry
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    repos:
      - "registry.example.com/"
```

> **Availability trade-off you must decide deliberately.** `failurePolicy: Fail` on a webhook that covers `pods` means: if the policy engine is unavailable, **no pods can be created cluster-wide** — including the policy engine's own pods after a node failure. Mitigations: exclude the engine's own namespace and `kube-system` via `namespaceSelector`, run ≥3 replicas with a PodDisruptionBudget and anti-affinity, and set `timeoutSeconds` low. `failurePolicy: Ignore` converts a hard outage into a silent security bypass. For signature verification, `Fail` is correct; for a "must have an owner label" rule, `Ignore` is correct.

### 3.5 Secrets: encryption at rest, and where secrets should actually live

Kubernetes `Secret` objects are **base64-encoded, not encrypted**, by default. Anyone with etcd disk access, an etcd backup, or `get secrets` RBAC reads them in plaintext.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml  (kube-apiserver: --encryption-provider-config=...)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
      - events.events.k8s.io
    providers:
      # First provider encrypts; all providers are tried, in order, to decrypt.
      # KMS v2 (GA in 1.29) uses a hierarchical DEK/KEK scheme: the API server
      # caches a local KEK, so it does not call the external KMS per object.
      - kms:
          apiVersion: v2
          name: vault-kms
          endpoint: unix:///opt/kms/vault-kms.sock
          timeout: 3s
      # `identity` last = plaintext fallback for objects written before
      # encryption was enabled. Remove it only AFTER a full rewrite (below).
      - identity: {}
```

Enabling encryption does **not** encrypt existing objects. They are rewritten on next write:

```console
$ kubectl get secrets --all-namespaces -o json \
  | kubectl replace -f - >/dev/null
$ echo "rewrite complete"
rewrite complete
```

Prove it at the storage layer — this is the only verification that actually counts:

```console
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/production/db-credentials | hexdump -C | head -5
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 72 6f 64 75 63  74 69 6f 6e 2f 64 62 2d  |s/production/db-|
00000020  63 72 65 64 65 6e 74 69  61 6c 73 0a 6b 38 73 3a  |credentials.k8s:|
00000030  65 6e 63 3a 6b 6d 73 3a  76 32 3a 76 61 75 6c 74  |enc:kms:v2:vault|
00000040  2d 6b 6d 73 3a 0a ac 02  1f 9d 44 7b 61 e0 3c 55  |-kms:.....D{a.<U|
```

The `k8s:enc:kms:v2:vault-kms:` prefix is the proof. If you instead see readable `postgres://user:hunter2@...`, encryption is not active for that object.

**Where secrets should live — trade-offs:**

| Approach | Secret material at rest in Git | Rotation | Cluster dependency | Notes |
|---|---|---|---|---|
| Plain `Secret` in Git | **plaintext** | manual | none | Never. |
| Sealed Secrets | encrypted to a cluster-specific key | re-seal + commit | controller in cluster | Simple GitOps; private key is cluster-bound, so DR requires backing it up |
| SOPS + age/KMS | encrypted, per-value | re-encrypt + commit | none at runtime (decrypt in CD) or `ksops`/Flux | Diff-friendly (only changed values change); key management is yours |
| External Secrets Operator + Vault/cloud SM | **absent** — only a reference | central, automatic | ESO + external store availability | Secrets never enter Git; the `ExternalSecret` is a pointer |
| Secrets Store CSI Driver | **absent** | central; supports rotation-reconcile | CSI driver + provider | Mounts as a tmpfs volume; can avoid creating a K8s `Secret` at all |

For a platform team, ESO or the CSI driver is the target state: the strongest property is not "the secret is encrypted" but "the secret is not in the repository at all, so a repo leak is not a credential leak."

```yaml
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault
  namespace: production
spec:
  provider:
    vault:
      server: https://vault.example.com:8200
      path: kv
      version: v2
      auth:
        # Vault validates the projected token against the cluster's OIDC
        # issuer. No static Vault token is stored anywhere in the cluster.
        kubernetes:
          mountPath: kubernetes
          role: production-api
          serviceAccountRef:
            name: api
            audiences:
              - vault
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: production
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      engineVersion: v2
      data:
        DATABASE_URL: "postgres://{{ .username }}:{{ .password }}@db.production.svc.cluster.local:5432/api?sslmode=verify-full"
  data:
    - secretKey: username
      remoteRef:
        key: production/api/db
        property: username
    - secretKey: password
      remoteRef:
        key: production/api/db
        property: password
```

```console
$ kubectl -n production get externalsecret db-credentials
NAME             STORE   REFRESH INTERVAL   STATUS         READY
db-credentials   vault   15m                SecretSynced   True

$ kubectl -n production describe externalsecret db-credentials | tail -5
Events:
  Type    Reason   Age   From              Message
  ----    ------   ----  ----              -------
  Normal  Updated  22s   external-secrets  Updated Secret
```

**Consume secrets as files, not environment variables.** Environment variables leak into `/proc/<pid>/environ`, crash dumps, `kubectl describe pod` for anything using `envFrom` with a ConfigMap fallback, and child-process inheritance. A file on a `tmpfs` mount with mode `0400` does not.

### 3.6 Audit logging

Admission tells you what was blocked; audit tells you what was allowed. Without it, incident response has no primary source.

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Do not record the request/response body for these resources at all.
omitStages:
  - RequestReceived
rules:
  # 1. Never log Secret/ConfigMap bodies — that would write plaintext
  #    credentials into the audit log, which is usually shipped off-cluster.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 2. Drop high-volume, low-value read noise from system components.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"
      - "/metrics"

  # 3. Full request bodies for RBAC changes — the most security-relevant
  #    writes in the cluster.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 4. Exec/attach/portforward: who got a shell into which pod.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]

  # 5. All other writes at Request level.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]

  # 6. Everything else: metadata only.
  - level: Metadata
```

```console
$ sudo jq -c 'select(.objectRef.subresource=="exec")
              | {t:.requestReceivedTimestamp, u:.user.username,
                 ns:.objectRef.namespace, pod:.objectRef.name}' \
    /var/log/kubernetes/audit.log | tail -3
{"t":"2026-09-03T13:41:02.118Z","u":"alice@example.com","ns":"production","pod":"api-7d9f8c5b64-x2wqp"}
{"t":"2026-09-03T13:52:47.903Z","u":"system:serviceaccount:ci:gitlab-runner","ns":"production","pod":"api-7d9f8c5b64-x2wqp"}
{"t":"2026-09-03T14:06:12.550Z","u":"bob@example.com","ns":"staging","pod":"worker-6b5c9f7d84-mnq2t"}
```

A CI service account executing a shell into a production pod is an alert, not a log line.

### 3.7 CIS benchmark verification

```console
$ kubectl run kube-bench-node --rm -it --restart=Never \
    --image=docker.io/aquasec/kube-bench:v0.8.0 \
    --overrides='{"spec":{"hostPID":true,"nodeName":"worker-03","containers":[{"name":"kube-bench","image":"docker.io/aquasec/kube-bench:v0.8.0","command":["kube-bench","run","--targets","node"],"volumeMounts":[{"name":"var-lib-kubelet","mountPath":"/var/lib/kubelet","readOnly":true},{"name":"etc-kubernetes","mountPath":"/etc/kubernetes","readOnly":true}]}],"volumes":[{"name":"var-lib-kubelet","hostPath":{"path":"/var/lib/kubelet"}},{"name":"etc-kubernetes","hostPath":{"path":"/etc/kubernetes"}}]}}'

[INFO] 4 Worker Node Security Configuration
[INFO] 4.1 Worker Node Configuration Files
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive (Automated)
[PASS] 4.1.2 Ensure that the kubelet service file ownership is set to root:root (Automated)
[PASS] 4.1.9 Ensure that the kubelet --config configuration file has permissions set to 600 (Automated)
[INFO] 4.2 Kubelet
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[PASS] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate (Automated)
[FAIL] 4.2.6 Ensure that the --protect-kernel-defaults argument is set to true (Automated)
[WARN] 4.2.10 Ensure that the --rotate-server-certificates argument is set to true (Manual)

== Remediations node ==
4.2.6 If using a Kubelet config file, edit /var/lib/kubelet/config.yaml to set protectKernelDefaults: true.
Then restart the kubelet: systemctl daemon-reload && systemctl restart kubelet

== Summary node ==
21 checks PASS
1 checks FAIL
1 checks WARN
0 checks INFO
```

Treat `kube-bench` output as a *conversation starter*, not a compliance verdict: several checks are informational, and managed control planes legitimately fail control-plane checks you cannot reach. What matters is that the FAIL list is reviewed and each entry is either fixed or has a documented, dated exception.

---

## 4. Layer: workload isolation and runtime

### 4.1 The Linux primitives underneath

A container is not a security boundary in the way a VM is. It is a process with a restricted view, assembled from:

| Primitive | What it isolates / restricts | Kubernetes surface |
|---|---|---|
| Namespaces (`pid`, `net`, `mnt`, `uts`, `ipc`, `cgroup`, `user`) | What the process can *see* | `hostPID`, `hostNetwork`, `hostIPC`, `hostUsers` |
| cgroups v2 | What it can *consume* | `resources.requests` / `resources.limits` |
| Capabilities | Which root-only operations it may perform | `securityContext.capabilities` |
| seccomp | Which **syscalls** it may issue | `securityContext.seccompProfile` |
| LSM: AppArmor / SELinux | Which **files, sockets and operations** it may touch | `securityContext.appArmorProfile`, `seLinuxOptions` |
| `no_new_privs` | Whether setuid binaries can raise privilege | `allowPrivilegeEscalation: false` |
| User namespaces | Maps container UID 0 to an unprivileged host UID | `spec.hostUsers: false` |

The single most important line: **`privileged: true` disables essentially all of it.** A privileged container has all capabilities, an unconfined seccomp and AppArmor profile, and full `/dev` access. It is host root with extra steps. Treat every `privileged: true` in your manifests as a node-level trust grant, and enumerate them:

```console
$ kubectl get pods -A -o json | jq -r '
    .items[] |
    .metadata.namespace as $ns | .metadata.name as $n |
    (.spec.containers[] | select(.securityContext.privileged == true) | .name) as $c |
    "\($ns)/\($n)\tcontainer=\($c)"'
kube-system/cilium-8xk4d	container=cilium-agent
kube-system/csi-node-9m2pq	container=node-driver-registrar
legacy/build-agent-6f7d8c9b4-vt3kw	container=dind
```

The first two are expected. The third — a Docker-in-Docker build agent — is a full cluster compromise waiting to be found, and the fix is a rootless builder (BuildKit rootless, Kaniko, Buildah) instead of a privileged daemon.

### 4.2 A fully hardened Deployment

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: production
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/component: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/component: backend
      annotations:
        # Roll pods when the config changes; unrelated to security but
        # prevents "the fix is deployed" while old pods hold old config.
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543"
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false
      # No host namespaces. hostPID would expose every process on the node
      # (and their command lines, which often contain credentials).
      hostNetwork: false
      hostPID: false
      hostIPC: false
      # User namespaces (beta): container UID 0 maps to an unprivileged
      # host UID, so a container escape lands as nobody, not as root.
      # Requires a runtime with idmap-mount support (containerd >= 1.7,
      # runc >= 1.2) and the UserNamespacesSupport feature gate.
      hostUsers: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        supplementalGroups: []
      terminationGracePeriodSeconds: 30
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: api
      containers:
        - name: api
          # Digest-pinned. The tag is kept only as a human-readable comment
          # in the GitOps repo; the API server resolves nothing at runtime.
          image: registry.example.com/platform/api@sha256:9b2f1c7a4e0d5c8b3a6f2e91d47c0b58e3fa1d629c4b8071ee5a3d92f6c1b840
          imagePullPolicy: IfNotPresent
          args:
            - "--listen=:8080"
            - "--metrics-listen=:9090"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            capabilities:
              drop:
                - ALL
              # Nothing is added back. If the app needed to bind :443 the
              # correct fix is a Service on 443 -> containerPort 8443,
              # NOT capabilities.add: ["NET_BIND_SERVICE"].
            seccompProfile:
              type: RuntimeDefault
            appArmorProfile:
              type: RuntimeDefault
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            # Credentials arrive as a file, never as an env var.
            - name: DATABASE_URL_FILE
              value: /var/run/secrets/db/DATABASE_URL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/api
            - name: db-credentials
              mountPath: /var/run/secrets/db
              readOnly: true
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              # No CPU limit on latency-sensitive services (CFS throttling);
              # a memory limit is mandatory — it is the only defence against
              # one workload OOM-killing its neighbours on the node.
              memory: "512Mi"
              ephemeral-storage: "1Gi"
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
      volumes:
        # readOnlyRootFilesystem: true means every writable path must be an
        # explicit, size-bounded volume. Unbounded emptyDir is a node-filling
        # DoS primitive.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 512Mi
        - name: db-credentials
          secret:
            secretName: db-credentials
            defaultMode: 0400
            optional: false
      nodeSelector:
        kubernetes.io/os: linux
```

Verification that the security context is actually in force — read the *running* container, not the manifest:

```console
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- id
uid=65532(nonroot) gid=65532(nonroot) groups=65532(nonroot)

$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- grep -E 'Cap(Prm|Eff|Bnd)|Seccomp|NoNewPrivs' /proc/1/status
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1

$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- touch /etc/probe
touch: /etc/probe: Read-only file system
command terminated with exit code 1
```

Decode: `CapBnd: 0` means the *bounding set* is empty — the process cannot acquire any capability, ever, even via a setuid binary. `NoNewPrivs: 1` is `allowPrivilegeEscalation: false`. `Seccomp: 2` is `SECCOMP_MODE_FILTER` (mode 1 is strict, 0 is disabled). If you see `Seccomp: 0`, the profile did not apply and you should find out why before shipping.

### 4.3 Custom seccomp profiles

`RuntimeDefault` blocks roughly 40–60 syscalls that no ordinary application needs (`kexec_load`, `mount`, `pivot_root`, `bpf`, `perf_event_open`, `userfaultfd`, …). A custom profile goes further, but only build one if you can measure the syscall set.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clock_gettime", "clone",
        "close", "connect", "epoll_create1", "epoll_ctl", "epoll_pwait",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "getsockname", "getsockopt",
        "gettid", "listen", "lseek", "madvise", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "prctl", "pread64", "read",
        "readlinkat", "recvfrom", "rt_sigaction", "rt_sigprocmask",
        "rt_sigreturn", "sched_getaffinity", "sched_yield", "sendto",
        "set_robust_list", "set_tid_address", "setsockopt", "shutdown",
        "sigaltstack", "socket", "tgkill", "uname", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Deploy it to `/var/lib/kubelet/seccomp/profiles/api.json` on every node (a DaemonSet, or the Security Profiles Operator), then reference it:

```yaml
        securityContext:
          seccompProfile:
            type: Localhost
            localhostProfile: profiles/api.json
```

**Never author one by hand from a syscall list.** Build it empirically: run with `"defaultAction": "SCMP_ACT_LOG"` under representative load, harvest the kernel audit records, then tighten.

```console
$ sudo journalctl -k --since "10 min ago" | grep -m3 'type=1326'
kernel: audit: type=1326 audit(1788445102.417:882): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=284119 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=318 compat=0 ip=0x4a1b2c code=0x7ffc0000
kernel: audit: type=1326 audit(1788445103.902:883): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=284119 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=302 compat=0 ip=0x4a3f10 code=0x7ffc0000

$ ausyscall --dump | awk '$1==318 || $1==302'
302	prlimit64
318	getrandom
```

`code=0x7ffc0000` is `SECCOMP_RET_LOG` — logged and allowed. Under `SCMP_ACT_ERRNO` the same syscall would return `EPERM`, and you would instead be debugging an application that mysteriously fails to seed its RNG. That is exactly the diagnostic path in §7.3.

### 4.4 Stronger isolation: RuntimeClass

When a shared kernel is not an acceptable boundary — untrusted tenant code, CI running arbitrary build scripts, customer-supplied plugins — change the runtime rather than adding more syscall filters.

| Runtime | Boundary | Syscall compatibility | Startup | Overhead | Use when |
|---|---|---|---|---|---|
| `runc` | Shared host kernel + namespaces/cgroups | full | ~50–100 ms | ~0 | Trusted first-party workloads |
| `gVisor` (runsc) | User-space kernel intercepts syscalls | high, but not complete (some `ioctl`, niche syscalls, direct `/proc` behaviours differ) | ~150–300 ms | noticeable on syscall-heavy and I/O-heavy paths | Multi-tenant workloads that are mostly network/CPU bound |
| `Kata Containers` | Hardware virtualisation — a real per-pod kernel | full (it *is* Linux) | ~300–800 ms | memory per VM; near-native CPU | Hostile or untrusted code; hard compliance boundary |

```yaml
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    example.com/runtime: gvisor
  tolerations:
    - key: example.com/runtime
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed:
    cpu: "50m"
    memory: "64Mi"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata-qemu
scheduling:
  nodeSelector:
    example.com/runtime: kata
overhead:
  podFixed:
    cpu: "250m"
    memory: "160Mi"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: untrusted-build
  namespace: tenant-builds
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      runtimeClassName: gvisor
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: build
          image: registry.example.com/platform/builder@sha256:4c81a3e0f2d97b6a5e18c04d3b7f92ae61c0d85fb437291ea6cf0d3b8e24571c
          command: ["/usr/local/bin/build.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              memory: "4Gi"
          volumeMounts:
            - name: workspace
              mountPath: /workspace
      volumes:
        - name: workspace
          emptyDir:
            sizeLimit: 8Gi
```

The `overhead` field is not cosmetic: it tells the scheduler that a Kata pod really costs 160 MiB more than its containers request, which prevents systematic node overcommit.

Confirming the sandbox is real, from inside:

```console
$ kubectl -n tenant-builds exec untrusted-build-7v9kx -- cat /proc/version
Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016

$ kubectl -n tenant-builds exec untrusted-build-7v9kx -- dmesg | head -2
[    0.000000] Starting gVisor...
[    0.325841] Feeding the init monster...
```

That synthetic kernel version string is gVisor's user-space kernel answering, not the host. On a `runc` pod the same command returns the node's actual kernel.

### 4.5 Runtime threat detection

Prevention fails eventually; detection is what bounds the dwell time. Falco (syscall-level rules, kernel module or modern eBPF probe) is the CNCF reference implementation.

```yaml
# /etc/falco/rules.d/platform.yaml
- macro: platform_images
  condition: (container.image.repository startswith "registry.example.com/platform/")

- macro: known_build_tools
  condition: (proc.name in (git, go, make, buildkitd, buildctl))

- rule: Shell spawned in production container
  desc: >
    An interactive shell was executed inside a production application
    container. Distroless images have no shell, so this indicates either an
    ephemeral debug container or an intrusion.
  condition: >
    spawned_process
    and container
    and shell_procs
    and platform_images
    and k8s.ns.name in (production)
    and not known_build_tools
  output: >
    Shell in production container
    (user=%user.name uid=%user.uid proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname image=%container.image.repository:%container.image.tag
     ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name)
  priority: WARNING
  tags: [container, shell, mitre_execution, T1059]

- rule: Service account token read by unexpected process
  desc: Reading the projected service account token outside the app binary.
  condition: >
    open_read
    and container
    and fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount
    and not proc.name in (api, kubelet)
  output: >
    SA token read (proc=%proc.name file=%fd.name ns=%k8s.ns.name pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, credentials, mitre_credential_access, T1552]

- rule: Outbound connection to cloud metadata endpoint
  desc: A container attempted to reach the instance metadata service.
  condition: >
    outbound
    and container
    and fd.sip = "169.254.169.254"
    and not k8s.ns.name in (kube-system)
  output: >
    Metadata service contacted from container
    (proc=%proc.name cmdline=%proc.cmdline ns=%k8s.ns.name pod=%k8s.pod.name
     dest=%fd.sip:%fd.sport)
  priority: CRITICAL
  tags: [network, cloud, mitre_credential_access, T1552.005]
```

```console
$ kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20 | grep -E 'Warning|Critical'
14:07:22.481233591: Warning Shell in production container (user=root uid=0 proc=bash cmdline=bash -i parent=runc image=registry.example.com/platform/api:1.24.3 ns=production pod=api-7d9f8c5b64-x2wqp container=api)
14:07:41.902117034: Critical SA token read (proc=curl file=/var/run/secrets/kubernetes.io/serviceaccount/token ns=production pod=api-7d9f8c5b64-x2wqp)
14:07:44.115880226: Critical Metadata service contacted from container (proc=curl cmdline=curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ ns=production pod=api-7d9f8c5b64-x2wqp dest=169.254.169.254:80)
```

Three lines, forty seconds, and you can read the whole intrusion: shell, token theft, cloud credential pivot. That sequence is the entire reason this objective exists.

---

## 5. Layer: network

### 5.1 NetworkPolicy — default deny is the only correct starting point

The Kubernetes network model is flat: every pod reaches every pod. NetworkPolicy is *allowlist* semantics, and it only applies once at least one policy selects a pod. A namespace with zero policies has zero enforcement, regardless of what your CNI supports.

```yaml
---
# 1. Deny all ingress and egress in the namespace.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}          # empty selector = every pod in the namespace
  policyTypes:
    - Ingress
    - Egress
---
# 2. DNS is not optional. Without this, every name resolution fails and the
#    symptom is a generic connection timeout, which sends people hunting the
#    wrong layer for an hour. This is the single most common NetworkPolicy bug.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# 3. Ingress: only the ingress controller may reach the API on 8080,
#    and only Prometheus may scrape 9090.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
---
# 4. Egress: the database, and nothing else on the pod network.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-egress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgres
      ports:
        - protocol: TCP
          port: 5432
---
# 5. Explicitly deny the cloud metadata endpoint for every pod.
#    `except` carves a hole out of an allowed CIDR — this is how you permit
#    general internet egress while still blocking 169.254.169.254.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-except-metadata
  namespace: production
spec:
  podSelector:
    matchLabels:
      egress.example.com/internet: "true"
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16     # link-local, incl. cloud metadata
              - 10.0.0.0/8         # internal RFC1918
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

**Semantics that trip people up:**

| Behaviour | Detail |
|---|---|
| Policies are **additive OR** | Two policies selecting the same pod produce the union of their allows. There is no ordering and no deny rule. |
| `podSelector` inside a `from`/`to` block is **namespace-local** unless combined with `namespaceSelector` | `{namespaceSelector: X, podSelector: Y}` in **one list item** = "pods matching Y in namespaces matching X". As **two list items** it means "any pod in X" **OR** "pod Y in this namespace" — a much wider allow. Indentation is the security control. |
| `ipBlock` matches the packet source as seen by the CNI | For traffic that has been SNAT'd (some ingress paths, some cloud LBs), `ipBlock` will not match the original client. |
| Selecting the destination is not enough | Egress on the client **and** ingress on the server must both allow the flow. Denials are silent on the wire. |

### 5.2 CNI capability matrix

NetworkPolicy is an API; enforcement is the CNI's job. Verify what yours does.

| Feature | Calico | Cilium | Weave / kindnet | AWS VPC CNI (alone) |
|---|---|---|---|---|
| `networking.k8s.io/v1` NetworkPolicy | ✓ | ✓ | ✓ / ✗ | ✗ (needs an add-on) |
| Cluster-wide policy CRD | ✓ (`GlobalNetworkPolicy`) | ✓ (`CiliumClusterwideNetworkPolicy`) | ✗ | ✗ |
| L7 (HTTP method/path, gRPC, Kafka) | ✓ (with Envoy/Istio integration) | ✓ (native Envoy) | ✗ | ✗ |
| DNS/FQDN-based egress | ✓ | ✓ (`toFQDNs`) | ✗ | ✗ |
| Policy denial observability | `calicoctl`, flow logs | `hubble observe` | ✗ | ✗ |
| Transparent encryption | WireGuard | WireGuard / IPsec | ✓ (Weave) | ✗ |

Standard NetworkPolicy cannot express "this pod may call `api.stripe.com` over HTTPS but nothing else" because it works on CIDRs and the destination's IPs are dynamic. The CNI CRD can:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-egress-l7
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: api
  egress:
    # Cilium must proxy DNS to learn which IPs a name resolves to.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # L7 HTTP: only these methods and paths against the internal billing API.
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: billing
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/v1/invoices(/[0-9]+)?$"
              - method: "POST"
                path: "/v1/invoices$"
```

### 5.3 Workload identity and mTLS

NetworkPolicy answers "may this IP talk to that IP". It does not answer "is the caller who it claims to be". For that you need cryptographic identity: **SPIFFE** defines the identity document (an SVID — an X.509 cert or JWT whose subject is a `spiffe://` URI), **SPIRE** is the reference issuer, and service meshes bundle both behind mTLS.

```
spiffe://example.com/ns/production/sa/api
```

That identity is attested from the workload's actual properties (its Kubernetes namespace, service account, and the node it runs on), not asserted by the workload. Registering one:

```console
$ kubectl -n spire exec -it spire-server-0 -c spire-server -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID spiffe://example.com/ns/production/sa/api \
      -parentID spiffe://example.com/spire/agent/k8s_psat/leloir/9f2c1a0e-7b34-4d18-8a03-1c6e5b28d7aa \
      -selector k8s:ns:production \
      -selector k8s:sa:api \
      -ttl 3600
Entry ID         : 4b1f0a92-3c77-4e56-91d2-8a0e7c4b61f3
SPIFFE ID        : spiffe://example.com/ns/production/sa/api
Parent ID        : spiffe://example.com/spire/agent/k8s_psat/leloir/9f2c1a0e-7b34-4d18-8a03-1c6e5b28d7aa
Revision         : 0
TTL              : 3600
Selector         : k8s:ns:production
Selector         : k8s:sa:api
```

The two selectors are the authorization policy: only a pod in `production` running as service account `api` can obtain that SVID. A pod in `staging` presenting the same manifest gets nothing. Combine with mTLS-enforced peer authorization and lateral movement requires stealing a key that rotates hourly and is never written to disk.

---

## 6. Putting the layers together: a complete namespace

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    kubernetes.io/metadata.name: production
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.memory: 120Gi
    persistentvolumeclaims: "20"
    services.loadbalancers: "2"
    services.nodeports: "0"          # NodePort bypasses the ingress security path
    count/secrets: "40"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: production-defaults
  namespace: production
spec:
  limits:
    - type: Container
      default:
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        memory: 8Gi
      min:
        memory: 32Mi
```

Layer summary for this namespace, and what each control actually stops:

| Control | Stops |
|---|---|
| PSA `restricted` | Root containers, privilege escalation, host namespaces, hostPath mounts, unconfined seccomp |
| `ValidatingAdmissionPolicy` digest pinning | Mutable tags; a compromised registry silently swapping the image behind `:1.24.3` |
| Kyverno `verifyImages` | Any image not produced by the release workflow |
| `default-deny-all` NetworkPolicy | Lateral movement from a compromised pod |
| `except: 169.254.0.0/16` | Cloud IAM credential theft via the metadata endpoint |
| `automountServiceAccountToken: false` | RCE turning into API-server access by default |
| `readOnlyRootFilesystem` + no shell | Persistence: the attacker cannot write a payload anywhere the runtime will execute |
| ESO + KMS encryption at rest | Credentials in Git; credentials in an etcd backup |
| `services.nodeports: "0"` | An accidental route around the ingress WAF/TLS termination |
| Falco rules | Turning a silent breach into a 40-second detection |

---

## 7. Verification and failure diagnosis

### 7.1 A verification pass you can run on any cluster

```console
# --- Supply chain -----------------------------------------------------------
$ kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u | grep -v '@sha256:'
registry.example.com/platform/legacy-cron:latest
docker.io/busybox:1.36
# ^ unpinned images: mutable, unverifiable, and `:latest` is unrollbackable

# --- Identity ---------------------------------------------------------------
$ kubectl get sa -A -o json \
  | jq -r '.items[] | select(.automountServiceAccountToken != false)
           | "\(.metadata.namespace)/\(.metadata.name)"' | head
default/default
production/legacy-worker

$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select([.subjects[]?.name] | index("system:anonymous") or index("system:unauthenticated"))
           | .metadata.name'
# (empty is the correct answer)

# --- Workload hardening -----------------------------------------------------
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(
      (.spec.containers[]?.securityContext.privileged == true) or
      (.spec.hostNetwork == true) or (.spec.hostPID == true) or
      ((.spec.volumes // [])[]? | has("hostPath"))
    ) | "\(.metadata.namespace)/\(.metadata.name)"' | sort -u
kube-system/cilium-8xk4d
legacy/build-agent-6f7d8c9b4-vt3kw

# --- Network ----------------------------------------------------------------
$ for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    n=$(kubectl -n "$ns" get netpol --no-headers 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && echo "NO NETWORKPOLICY: $ns"
  done
NO NETWORKPOLICY: default
NO NETWORKPOLICY: legacy

# --- Secrets ----------------------------------------------------------------
$ kubectl get pods -A -o json | jq -r '
    .items[] | .metadata.namespace as $ns | .metadata.name as $n |
    .spec.containers[] | select((.env // [])[]? | .name | test("PASS|SECRET|TOKEN|KEY"; "i"))
    | select((.env[] | select(.valueFrom == null)) != null)
    | "\($ns)/\($n) container=\(.name)"' | sort -u
legacy/build-agent-6f7d8c9b4-vt3kw container=dind
# ^ a literal credential in the pod spec: readable by anyone with `get pods`
```

### 7.2 Failure signature table

| Symptom | Most likely cause | Confirm with |
|---|---|---|
| `Error from server (Forbidden): ... violates PodSecurity "restricted:..."` | PSA rejecting the Pod | Read the message — it lists every missing field verbatim |
| Deployment shows `0/3 READY`, **no pods at all** | PSA/admission rejecting at ReplicaSet level | `kubectl describe rs <rs>` → `FailedCreate` events |
| `CreateContainerConfigError` | Missing Secret/ConfigMap key, or `runAsNonRoot` with a root image | `kubectl describe pod` → Events |
| `container has runAsNonRoot and image will run as root` | Image `USER` is 0 and no `runAsUser` override | `docker inspect --format '{{.Config.User}}' <image>` |
| `CreateContainerError: ... unable to find user` | `runAsUser` UID has no `/etc/passwd` entry and the app requires one | `runAsUser` + set `HOME`, or add the user to the image |
| `ErrImagePull` / `unauthorized` after enabling policy | Kyverno `mutateDigest` rewrote the reference; imagePullSecret scoped to the tag path | `kubectl get pod -o jsonpath='{.spec.containers[*].image}'` |
| `admission webhook ... denied the request` | Policy engine denial | `kubectl -n kyverno logs -l app.kubernetes.io/component=admission-controller` |
| Every API write hangs, then `context deadline exceeded` | Policy webhook down with `failurePolicy: Fail` | `kubectl get validatingwebhookconfigurations` and check the backing pods |
| Application: "connection timed out" to a Service | NetworkPolicy denial (silent drop, no RST) | §7.5 |
| Application: "no such host" / DNS `SERVFAIL` | Default-deny egress with no DNS allow rule | Check for the `allow-dns-egress` policy |
| App works, then fails with `EPERM` on an uncommon operation | seccomp or capability drop | §7.3 |
| `permission denied` reading a mounted Secret | `fsGroup` mismatch vs `defaultMode` | `kubectl exec -- ls -ln <mountpath>` |
| Pod runs but `readOnlyRootFilesystem` breaks it | App writes outside the declared volumes | `kubectl logs` for the exact path, add an `emptyDir` |
| `cosign verify`: `no matching signatures` | Wrong identity/issuer, or genuinely unsigned | Re-run with `--certificate-identity-regexp '.*'` to see the actual subject |

### 7.3 Diagnosing a seccomp / capability denial

The symptom is an application-level error with no Kubernetes event. Work down the layers:

```console
# 1. Is a filter even loaded?
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- grep -E 'Seccomp|CapEff' /proc/1/status
CapEff:	0000000000000000
Seccomp:	2
Seccomp_filters:	1

# 2. Which profile did the runtime apply? (run on the node)
$ sudo crictl ps --name api -q
3f2b1c8a9d44e7160b5a2f0c81d93e64af720b1c5d83e9f04a6b2c71d8e05f39

$ sudo crictl inspect 3f2b1c8a9d44 \
  | jq '.info.runtimeSpec.linux.seccomp | {defaultAction, syscallGroups: (.syscalls | length)}'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscallGroups": 1
}

# 3. Watch the kernel refuse it, live.
$ sudo journalctl -kf | grep --line-buffered 'type=1326'
kernel: audit: type=1326 audit(1788446012.771:1204): auid=4294967295 uid=65532 gid=65532 ses=4294967295 pid=291447 comm="api" exe="/usr/local/bin/api" sig=0 arch=c000003e syscall=41 compat=0 ip=0x4a08f1 code=0x50001

# 4. Translate the syscall number.
$ ausyscall --dump | awk '$1==41'
41	socket
```

`code=0x50001` is `SECCOMP_RET_ERRNO` returning errno 1 (`EPERM`); the profile is denying `socket(2)`. Because the profile in §4.3 was harvested under a workload that never opened a new socket family, the application fails only on a code path exercised in production. **The lesson is procedural:** a hand-narrowed seccomp profile must be validated under the *full* production traffic mix in `SCMP_ACT_LOG` mode for at least one complete business cycle before it is switched to `SCMP_ACT_ERRNO`.

Capability denials look similar but with a different cause. `CapEff: 0000000000000000` means every privileged operation returns `EPERM`. The reflex to `capabilities.add` is almost always wrong; the classic case is binding port 80:

```console
$ kubectl -n production logs api-7d9f8c5b64-x2wqp
listen tcp :80: bind: permission denied
```

The correct fix is `containerPort: 8080` with `Service.port: 80`. The second-best fix is `net.ipv4.ip_unprivileged_port_start=0` as an unsafe sysctl. Adding `NET_BIND_SERVICE` is the worst of the three and is prohibited by `restricted` anyway.

### 7.4 Debugging a distroless pod

You removed the shell on purpose. Ephemeral containers restore debuggability without weakening the image:

```console
$ kubectl -n production debug -it api-7d9f8c5b64-x2wqp \
    --image=busybox:1.36 \
    --target=api \
    --profile=general \
    -- sh
Defaulting debug container name to debugger-t9k2c.
If you don't see a command prompt, try pressing enter.
/ # ls /proc/1/root/usr/local/bin
api
/ # cat /proc/1/environ | tr '\0' '\n' | grep -c PASSWORD
0
```

`--target=api` joins the target container's process and network namespaces, so `/proc/1` is the application. `--profile=general` is important: without a profile, older `kubectl` versions copied nothing and the debug container could be *more* privileged than the target — in a `restricted` namespace it would simply be rejected by PSA. Note that every `kubectl debug` on a Pod creates an `ephemeralcontainers` subresource write, which your audit policy (§3.6) records.

### 7.5 Diagnosing a NetworkPolicy drop

NetworkPolicy denials drop packets silently: no ICMP unreachable, no TCP RST. Every failure looks like a timeout, which is why people blame DNS, the Service, or the app before they blame the policy.

```console
# Symptom
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- \
    wget -qO- --timeout=3 http://payments.production.svc.cluster.local:8080/healthz
wget: download timed out
command terminated with exit code 1

# Is it DNS or is it the connection?
$ kubectl -n production exec api-7d9f8c5b64-x2wqp -- nslookup payments.production.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10:53

Name:	payments.production.svc.cluster.local
Address: 10.104.22.187
# DNS resolves -> not the DNS egress rule. Now check policy.

# Which policies select each side?
$ kubectl -n production get netpol -o custom-columns=\
NAME:.metadata.name,PODSELECTOR:.spec.podSelector.matchLabels,TYPES:.spec.policyTypes
NAME                 PODSELECTOR                                 TYPES
default-deny-all     map[]                                       [Ingress Egress]
allow-dns-egress     map[]                                       [Egress]
api-ingress          map[app.kubernetes.io/name:api]             [Ingress]
api-egress           map[app.kubernetes.io/name:api]             [Egress]
payments-ingress     map[app.kubernetes.io/name:payments]        [Ingress]

$ kubectl -n production get netpol api-egress -o jsonpath='{.spec.egress}' | jq
[
  {
    "ports": [{"port": 5432, "protocol": "TCP"}],
    "to": [{"podSelector": {"matchLabels": {"app.kubernetes.io/name": "postgres"}}}]
  }
]
# api may egress to postgres:5432 only. payments:8080 is not allowed.
```

With Cilium, skip the reasoning and read the verdict directly:

```console
$ hubble observe --namespace production --verdict DROPPED --last 10
Sep  3 14:22:31.117: production/api-7d9f8c5b64-x2wqp:44120 (ID:23814)
  -> production/payments-6b4c8d9f75-h2ln8:8080 (ID:41093)
  policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  3 14:22:32.141: production/api-7d9f8c5b64-x2wqp:44120 (ID:23814)
  -> production/payments-6b4c8d9f75-h2ln8:8080 (ID:41093)
  policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
```

`policy-verdict:none EGRESS DENIED` names the direction and the side. Without flow-level observability this same diagnosis takes an order of magnitude longer, which is the strongest operational argument for choosing a CNI that provides it.

### 7.6 Diagnosing a webhook-induced outage

The worst failure mode in this objective is self-inflicted: a policy webhook takes the cluster's write path down.

```console
$ kubectl -n production scale deploy/api --replicas=4
Error from server (InternalError): Internal error occurred: failed calling webhook
"mutate.kyverno.svc-fail": failed to call webhook: Post
"https://kyverno-svc.kyverno.svc:443/mutate/fail?timeout=30s": context deadline exceeded

$ kubectl -n kyverno get pods
NAME                                             READY   STATUS             RESTARTS   AGE
kyverno-admission-controller-6d9c7f8b54-4nq2x    0/1     CrashLoopBackOff   7          14m
kyverno-admission-controller-6d9c7f8b54-8ktdw    0/1     CrashLoopBackOff   7          14m

$ kubectl get validatingwebhookconfigurations \
    -o custom-columns=NAME:.metadata.name,FAILUREPOLICY:.webhooks[*].failurePolicy
NAME                              FAILUREPOLICY
kyverno-policy-validating-webhook-cfg   Fail,Fail
kyverno-resource-validating-webhook-cfg Fail
```

Break-glass (deliberate, logged, reversible) — the webhook configuration itself is not gated by the webhook:

```console
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o yaml > /tmp/break-glass-backup.yaml
$ kubectl delete validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg
validatingwebhookconfiguration.admissionregistration.k8s.io "kyverno-resource-validating-webhook-cfg" deleted
```

Preventing the recurrence is a design change, not a runbook entry: exclude the policy engine's own namespace and `kube-system` with a `namespaceSelector`, run ≥3 replicas across failure domains with a PodDisruptionBudget, keep `timeoutSeconds` at 5–10 rather than 30, and move the rules that must survive an engine outage into in-tree `ValidatingAdmissionPolicy`, which cannot go down independently of the API server.

---

## 8. Key facts to retain

* Kubernetes `Secret` objects are **base64-encoded, not encrypted**, unless `EncryptionConfiguration` is enabled on the API server — and enabling it does not touch already-stored objects until they are rewritten.
* **RBAC is additive only.** There is no deny rule; audit every binding for a subject.
* `resourceNames` does not restrict `list`, `watch` on collections, or `create`.
* **PSA validates Pods, not Deployments.** Use the `warn` label so `kubectl apply` surfaces violations at authoring time.
* Pin `pod-security.kubernetes.io/*-version` — `latest` tightens silently across cluster upgrades.
* **NetworkPolicy is allowlist-only and additive**; a namespace with no policy has no enforcement, and default-deny without a DNS egress rule breaks everything with a timeout, not a DNS error.
* Signatures and admission policy must bind to **`@sha256:` digests**, never tags.
* `cosign verify` without `--certificate-identity*` and `--certificate-oidc-issuer` proves only that *someone* signed it.
* `privileged: true` neutralises capabilities, seccomp and AppArmor simultaneously — it is host root.
* `allowPrivilegeEscalation: false` sets `no_new_privs`; verify with `NoNewPrivs: 1` in `/proc/1/status`. `Seccomp: 2` confirms a filter is loaded.
* `failurePolicy: Fail` on an admission webhook is a **cluster availability dependency**; `Ignore` is a silent security bypass. Choose per rule.
* SLSA Build L2 (signed provenance from a hosted builder) is cheap; L3 requires that the build's own steps cannot forge provenance.

---

## 9. References

**Exam objectives**
* LPI Exam 701 objectives (authoritative objective list and weights) — https://www.lpi.org/our-certifications/exam-701-objectives/

**Kubernetes — security concepts and API reference**
* Kubernetes security documentation — https://kubernetes.io/docs/concepts/security/
* Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
* Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
* Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
* Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
* Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
* User Namespaces — https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
* Runtime Class — https://kubernetes.io/docs/concepts/containers/runtime-class/
* Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
* Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
* Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
* Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
* Encrypting Confidential Data at Rest — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
* Using KMS provider for data encryption — https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
* Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
* Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
* Projected Volumes — https://kubernetes.io/docs/concepts/storage/projected-volumes/
* Debug Running Pods (ephemeral containers) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
* Secrets — https://kubernetes.io/docs/concepts/configuration/secret/

**Supply chain**
* Sigstore documentation — https://docs.sigstore.dev/
* Cosign — https://github.com/sigstore/cosign
* Rekor transparency log — https://docs.sigstore.dev/logging/overview/
* SLSA specification, v1.0 levels — https://slsa.dev/spec/v1.0/levels
* in-toto attestation framework — https://github.com/in-toto/attestation
* SPDX specification — https://spdx.dev/
* CycloneDX specification — https://cyclonedx.org/specification/overview/
* Syft — https://github.com/anchore/syft
* Grype — https://github.com/anchore/grype
* Trivy — https://trivy.dev/
* Distroless base images — https://github.com/GoogleContainerTools/distroless
* BuildKit — https://github.com/moby/buildkit

**Policy engines**
* Kyverno documentation — https://kyverno.io/docs/
* Kyverno image verification — https://kyverno.io/docs/writing-policies/verify-images/
* OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
* Open Policy Agent / Rego — https://www.openpolicyagent.org/docs/latest/

**Runtime, isolation and detection**
* OCI Runtime Specification — https://github.com/opencontainers/runtime-spec
* OCI Image Specification — https://github.com/opencontainers/image-spec
* gVisor — https://gvisor.dev/docs/
* Kata Containers — https://katacontainers.io/docs/
* Falco — https://falco.org/docs/
* Cilium Tetragon — https://tetragon.io/docs/
* Linux capabilities manual page — https://man7.org/linux/man-pages/man7/capabilities.7.html
* seccomp manual page — https://man7.org/linux/man-pages/man2/seccomp.2.html

**Networking and identity**
* Cilium documentation — https://docs.cilium.io/
* Calico network policy — https://docs.tigera.io/calico/latest/network-policy/
* Hubble observability — https://docs.cilium.io/en/stable/observability/hubble/
* SPIFFE — https://spiffe.io/docs/latest/spiffe-about/overview/
* SPIRE — https://spiffe.io/docs/latest/spire-about/

**Secrets management**
* External Secrets Operator — https://external-secrets.io/latest/
* Secrets Store CSI Driver — https://secrets-store-csi-driver.sigs.k8s.io/
* HashiCorp Vault Kubernetes auth method — https://developer.hashicorp.com/vault/docs/auth/kubernetes
* SOPS — https://github.com/getsops/sops
* Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets

**Benchmarks and threat models**
* NIST SP 800-190, Application Container Security Guide — https://csrc.nist.gov/pubs/sp/800/190/final
* CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
* kube-bench — https://github.com/aquasecurity/kube-bench
* CNCF TAG Security — https://tag-security.cncf.io/
* OWASP Kubernetes Top Ten — https://owasp.org/www-project-kubernetes-top-ten/
* MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/