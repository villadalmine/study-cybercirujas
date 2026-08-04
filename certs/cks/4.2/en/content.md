# CKS 4.2 — Understand your supply chain (SBOM, CI/CD, artifact repositories)

> **Domain:** Supply Chain Security · **Exam weight of this objective:** 5 · **Curriculum:** CKS v1.34

---

## 1. The production problem

### 1.1 Why this objective exists

A Kubernetes cluster is, from the perspective of an attacker, an **automated execution engine for arbitrary third-party binaries**. The kubelet's job is to fetch a blob from a network endpoint, unpack it onto a node, and run it as PID 1 of a namespace with whatever privileges the PodSpec requested. Every control you learn in the other CKS domains — RBAC, NetworkPolicy, seccomp, AppArmor, Pod Security Standards — assumes that *the thing you are confining is the thing you intended to run*. Supply chain security is the discipline that makes that assumption true.

The failure mode is not theoretical:

| Incident | Year | Compromise point (SLSA threat) | Kubernetes-relevant lesson |
|---|---|---|---|
| SolarWinds / SUNBURST | 2020 | (D) Build process compromised | Signed artifacts from a trusted vendor were malicious. Signature ≠ safety; you need *provenance* about **how** it was built. |
| Codecov Bash Uploader | 2021 | (F) Upload of modified package | A single mutable script URL, unpinned, exfiltrated CI env vars. Every `curl \| bash` in a pipeline is an unauthenticated remote code execution primitive. |
| `event-stream` / `ua-parser-js` | 2018/2021 | (E) Compromised dependency | Transitive dependency you never chose. Only an SBOM lets you answer "am I affected?" in minutes rather than weeks. |
| Dependency confusion | 2021 | (E)/(G) Registry resolution order | Internal package names resolvable from a public index. Applies verbatim to container registries and Helm repos. |
| `xz-utils` backdoor (CVE-2024-3094) | 2024 | (B)/(C) Source repo + build script | Malicious payload only present in the **release tarball**, not in git. Build-from-source-of-truth (SLSA L3) is what detects this class. |
| Log4Shell (CVE-2021-44228) | 2021 | (H) Consumption | Not a compromise at all — an ordinary CVE. But organizations without SBOMs took **weeks** to enumerate exposure; organizations with SBOMs took **minutes**. |

### 1.2 The four questions

"Understanding your supply chain" is operationally reducible to four questions that a platform team must be able to answer **about any container currently running in production, within minutes, without asking a developer**:

1. **What is inside it?** → SBOM (Software Bill of Materials)
2. **Where did it come from?** → Artifact repository + immutable digest reference
3. **How was it built?** → Provenance attestation (in-toto / SLSA)
4. **Who vouches for it, and is that vouching still valid?** → Signature + transparency log + admission-time verification

If any of the four is missing, the chain has a hole. The remaining sections build the answer to each, and then close the loop with cluster-side enforcement.

### 1.3 The architectural map

```
   ┌─────────────┐   (A)(B)      ┌──────────────┐   (C)(D)      ┌───────────────┐
   │  Developer  │──────────────▶│  Source repo │──────────────▶│  Build system │
   │  workstation│  push/PR      │  (git)       │  checkout     │  (CI/CD)      │
   └─────────────┘               └──────────────┘               └───────┬───────┘
                                        ▲                               │
                                        │ (E) deps                      │ produces:
                                 ┌──────┴───────┐                       │  • image
                                 │ Package idx  │                       │  • SBOM
                                 │ npm/PyPI/Go  │                       │  • provenance
                                 └──────────────┘                       │  • signature
                                                                        ▼
   ┌─────────────┐   (H) pull    ┌──────────────┐   (F)(G)      ┌───────────────┐
   │   kubelet   │◀──────────────│   Admission  │◀──────────────│   Artifact    │
   │ + containerd│   scheduled   │  controller  │   verify      │  repository   │
   └─────────────┘               └──────────────┘               └───────────────┘
         │                               ▲
         │ runs                          │ ENFORCEMENT BOUNDARY
         ▼                               │ (the only place the cluster
   ┌─────────────┐                       │  can still say "no")
   │  Container  │───────────────────────┘
   └─────────────┘
```

Threat letters follow the SLSA threat model. Note that the **only** point where a Kubernetes cluster can unilaterally intervene is admission. Everything to the left of that boundary is a matter of trust that must be *established by evidence you can verify at admission time*.

### 1.4 Kubernetes-specific amplifiers

Four properties of Kubernetes make supply chain weaknesses worse than in classic VM fleets:

| Amplifier | Mechanism | Mitigation covered here |
|---|---|---|
| **Mutable tags** | `image: app:latest` resolves differently on each node and each restart. Two replicas of the same Deployment can run different code. | Digest pinning enforced at admission (§5.2) |
| **Node-local image cache** | A pod in namespace `A` can run an image previously pulled by a pod in namespace `B` **without possessing the pull credentials**. | `AlwaysPullImages` admission plugin (§5.6) |
| **Controller-driven re-pull** | A node failure or scale-out re-resolves the tag at an arbitrary future time, outside any CI/CD gate. | Digest pinning + admission-time verification on every CREATE |
| **Ubiquitous cluster-wide agents** | CNI, CSI, ingress, monitoring and service mesh all run privileged DaemonSets from third-party registries. | Registry allowlisting applied to `kube-system` too (§5.2), not just app namespaces |

---

## 2. SBOM: format, generation, distribution

### 2.1 What an SBOM actually is

An SBOM is a machine-readable inventory of components and their relationships. The minimum-viable field set (NTIA minimum elements) is: supplier, component name, version, unique identifiers (PURL / CPE), dependency relationship, SBOM author, timestamp.

For containers there are effectively **three layers** of content, and most tooling only covers the first two by default:

| Layer | Example content | Detected by |
|---|---|---|
| **OS packages** | `apk`/`dpkg`/`rpm` databases | Syft, Trivy, Grype — reliably |
| **Language packages** | `go.mod` embedded in the binary, `package-lock.json`, `*.dist-info`, `Cargo.lock`, `pom.xml` | Syft, Trivy — reliably for lockfiles and Go buildinfo |
| **Vendored / statically linked / copied binaries** | A `curl` binary copied in a `COPY` step, a statically linked C library, a JAR shaded into an uber-JAR | **Poorly.** Requires file-digest cataloging + binary classifiers (`syft --select-catalogers`) or golden-hash matching |

> **Architect's note:** the third layer is where the `xz` class of attack lives. Treat "the SBOM is clean" as evidence of *absence of known-vulnerable declared components*, never as evidence of *absence of malicious code*. This is the single most common overclaim made about SBOMs in production programs.

### 2.2 Format comparison

| | **SPDX 2.3 / 3.0** | **CycloneDX 1.6** | **Syft JSON** | **SWID** |
|---|---|---|---|---|
| Governance | Linux Foundation / ISO/IEC 5962:2021 | OWASP / ECMA-424 | Anchore (vendor) | ISO/IEC 19770-2 |
| Primary design goal | License compliance & provenance | Security & risk analysis | Lossless tool-native | Software asset management |
| Serializations | JSON, YAML, RDF, tag-value, spreadsheet | JSON, XML, Protobuf | JSON | XML |
| Vulnerability data in-band | No (external, or SPDX 3.0 security profile) | **Yes** (`vulnerabilities[]`) | No | No |
| VEX support | Separate document | **Native** (CycloneDX VEX) | No | No |
| Service / ML-BOM / HW-BOM | SPDX 3.0 profiles | **Yes** (SaaSBOM, ML-BOM, CBOM) | No | No |
| Dependency graph fidelity | Relationship-based, very expressive, verbose | `dependencies[]` tree, compact | Full | Weak |
| Signature envelope | External (in-toto/DSSE) | **Native** JSON Signature Format + external | External | XML DSig |
| Typical size (Alpine + Go app, ~150 pkgs) | ~420 KB JSON | ~180 KB JSON | ~600 KB | n/a |
| Kubernetes ecosystem default | **Yes** — k8s releases publish SPDX at `sbom.k8s.io` | Widely used by Trivy/Dependency-Track | Internal | Rare |

**Practical recommendation:** emit **both**. It costs one extra `-o` flag and removes an entire class of "our scanner/our customer/our regulator needs the other one" toil.

```
-o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json
```

### 2.3 Build-time vs analysis-time SBOM

This is the most consequential design decision in the whole objective, and it is routinely gotten wrong.

| | **Analysis-time (post-hoc scan)** | **Build-time (generated by the builder)** |
|---|---|---|
| How | `syft scan registry:img:tag` after the fact | `docker buildx build --sbom=true`, Bazel, Tekton Chains, `ko` |
| Sees vendored/static content | No | Partially — knows the build graph |
| Sees build-only deps (compilers, test deps) | No | Yes (`mode=max`) |
| Sees the *source* of each component | Inferred | **Authoritative** — knows the exact resolver output |
| Trust anchor | The scanner, run by whoever runs it | The build platform (can be SLSA L3) |
| Reproducible | Depends on scanner DB version | Yes, tied to build |
| Retrofit cost onto existing images | Zero | High — requires builder changes |
| Correct answer for | Third-party / base images you did not build | **Everything you build yourself** |

Use build-time SBOMs for first-party images and analysis-time SBOMs for everything else. Never rely exclusively on analysis-time SBOMs for code your organization authored.

### 2.4 Generating SBOMs — real commands

**Syft (analysis-time, multi-format):**

```
$ syft scan registry:registry.acme.io/payments-api:1.8.3 \
    -o spdx-json=sbom.spdx.json \
    -o cyclonedx-json=sbom.cdx.json \
    -o table
 ✔ Pulled image
 ✔ Loaded image                        registry.acme.io/payments-api:1.8.3
 ✔ Parsed image             sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
 ✔ Cataloged contents                  6c1e0b0a4f2d8e7b9c3a5f1d0e8b2c4a6f9d3e7b1c5a8f0d2e4b6c9a3f7d1e5b
   ├── ✔ Packages                        [148 packages]
   ├── ✔ File digests                    [2417 files]
   ├── ✔ File metadata                   [2417 locations]
   └── ✔ Executables                     [41 executables]

NAME                     VERSION                TYPE
busybox                  1.36.1-r29             apk
ca-certificates-bundle   20241121-r1            apk
github.com/gin-gonic/gin v1.10.0                go-module
github.com/jackc/pgx/v5  v5.7.1                 go-module
golang.org/x/crypto      v0.28.0                go-module
libcrypto3               3.3.2-r0               apk
libssl3                  3.3.2-r0               apk
musl                     1.2.5-r8               apk
payments-api             (devel)                go-module
...
```

Verify the two artifacts describe the same digest — a surprisingly common CI bug is scanning `:latest` while shipping a different digest:

```
$ jq -r '.packages[0].externalRefs[]? | select(.referenceType=="purl") | .referenceLocator' sbom.spdx.json | head -1
pkg:oci/payments-api@sha256%3A9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c?arch=amd64&repository_url=registry.acme.io

$ crane digest registry.acme.io/payments-api:1.8.3
sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
```

**Trivy (analysis-time, integrated with its own vuln DB):**

```
$ trivy image --format cyclonedx --output trivy-sbom.cdx.json \
    registry.acme.io/payments-api:1.8.3
2026-08-03T14:22:07Z INFO  [vulndb] Need to update DB
2026-08-03T14:22:11Z INFO  [vulndb] Downloading vulnerability DB...
2026-08-03T14:22:19Z INFO  "--format cyclonedx" disables security scanning. Specify "--scanners vuln" explicitly if you want to include vulnerabilities.
2026-08-03T14:22:21Z INFO  Detected OS  family="alpine" version="3.20.3"
2026-08-03T14:22:21Z INFO  Number of language-specific files  num=1
```

Note the warning: by default `--format cyclonedx` gives you an inventory **without** vulnerabilities. To get a combined SBOM+VDR document:

```
$ trivy image --scanners vuln --format cyclonedx --output vdr.cdx.json \
    registry.acme.io/payments-api:1.8.3
```

**Build-time with BuildKit (the preferred path for first-party images):**

```
$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --sbom=true \
    --provenance=mode=max \
    --tag registry.acme.io/payments-api:1.8.3 \
    --push .
[+] Building 42.7s (23/23) FINISHED
 => [internal] load build definition from Dockerfile                       0.0s
 ...
 => exporting to image                                                     6.1s
 => => exporting layers                                                    2.3s
 => => exporting manifest sha256:9f2b3c7d...                               0.0s
 => => exporting config sha256:1b7e4a2d...                                 0.0s
 => => exporting attestation manifest sha256:c4a91e0f...                   0.1s
 => => exporting manifest list sha256:3d8f0b6c...                          0.0s
 => => pushing layers                                                      3.2s
 => => pushing manifest for registry.acme.io/payments-api:1.8.3@sha256:3d8f0b6c...
```

The attestations become entries in the OCI image index, discoverable without extra tooling:

```
$ docker buildx imagetools inspect registry.acme.io/payments-api:1.8.3 --raw | jq -r \
    '.manifests[] | "\(.platform.os)/\(.platform.architecture)\t\(.annotations["vnd.docker.reference.type"] // "image")\t\(.digest)"'
linux/amd64	image	sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
linux/arm64	image	sha256:5e1a8c3f7b2d9e0a4c6f8b1d3e5a7c9f0b2d4e6a8c1f3b5d7e9a0c2f4b6d8e1a
unknown/unknown	attestation-manifest	sha256:c4a91e0f2b6d8a3c5e7f9b1d0a2c4e6f8b0d2a4c6e8f0b2d4a6c8e0f2b4d6a8c
unknown/unknown	attestation-manifest	sha256:7b3e5a9c1f0d2b4e6a8c0f2d4b6e8a0c2f4d6b8e0a2c4f6d8b0e2a4c6f8d0b2e

$ docker buildx imagetools inspect registry.acme.io/payments-api:1.8.3 \
    --format '{{ json .Provenance.SLSA.buildDefinition.externalParameters }}' | jq .
{
  "configSource": {
    "digest": { "sha1": "4c8e2b1f7a9d0c3e5b6f8a1d2c4e6b8f0a3d5c7e" },
    "entryPoint": "Dockerfile",
    "uri": "https://github.com/acme/payments-api.git#refs/tags/v1.8.3"
  },
  "request": {
    "frontend": "dockerfile.v0",
    "args": { "build-arg:GOFLAGS": "-trimpath -buildvcs=true" }
  }
}
```

### 2.5 Distributing SBOMs: attestations, not sidecar files

An SBOM stored in a CI artifact bucket is operationally dead — nobody can find it six months later when the CVE lands at 02:00. The SBOM must travel **with the image, addressed by digest**.

Three mechanisms, in increasing order of correctness:

| Mechanism | How it is stored | Discoverable via | Verdict |
|---|---|---|---|
| `cosign attach sbom` (**deprecated**) | Tag `sha256-<digest>.sbom` | `cosign download sbom` | **Do not use.** Unsigned, deprecated since cosign v2. |
| `cosign attest` (tag-based) | Tag `sha256-<digest>.att`, DSSE-wrapped in-toto | `cosign verify-attestation` | Good. Works on every registry. |
| OCI 1.1 Referrers (`subject` field) | Manifest with `subject`, queried via `/v2/<n>/referrers/<digest>` | `oras discover`, `cosign --registry-referrers-mode oci-1-1` | **Best.** Native GC semantics, no tag pollution. Requires a registry that implements the Referrers API (Harbor ≥ 2.9, GHCR, ECR, GAR, Zot, distribution ≥ 2.8.2 with fallback). |

**Signing the SBOM as an attestation:**

```
$ cosign attest --yes \
    --type cyclonedx \
    --predicate sbom.cdx.json \
    registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
Generating ephemeral keys...
Retrieving signed certificate...
        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.
Successfully verified SCT...
tlog entry created with index: 187443902
Using payload from: sbom.cdx.json
```

**Discovering everything attached to an image:**

```
$ cosign tree registry.acme.io/payments-api:1.8.3
📦 Supply Chain Security Related artifacts for an image: registry.acme.io/payments-api:1.8.3
└── 💾 Attestations for an image tag: registry.acme.io/payments-api:sha256-9f2b3c7d....att
   ├── 🍒 sha256:a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90
   └── 🍒 sha256:b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1
└── 🔐 Signatures for an image tag: registry.acme.io/payments-api:sha256-9f2b3c7d....sig
   └── 🍒 sha256:c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2

$ oras discover -o tree registry.acme.io/payments-api:1.8.3
registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
├── application/vnd.in-toto+json
│   ├── sha256:a1b2c3d4... [https://cyclonedx.org/bom]
│   └── sha256:b2c3d4e5... [https://slsa.dev/provenance/v1]
└── application/vnd.dev.cosign.artifact.sig.v1+json
    └── sha256:c3d4e5f6...
```

### 2.6 VEX: the control that makes SBOMs survivable at scale

A 148-package image will typically match 30–80 CVEs. Blocking on all of them is impossible; ignoring them is negligent. **VEX (Vulnerability Exploitability eXchange)** is the assertion layer: for a given product and vulnerability, one of four statuses — `not_affected`, `affected`, `fixed`, `under_investigation` — plus a machine-readable justification.

```
$ cat vex/payments-api.openvex.json
```
```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://acme.io/vex/payments-api/2026-08-03-001",
  "author": "ACME Product Security <psirt@acme.io>",
  "timestamp": "2026-08-03T09:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2024-45337" },
      "products": [
        {
          "@id": "pkg:oci/payments-api@sha256%3A9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c?repository_url=registry.acme.io",
          "subcomponents": [
            { "@id": "pkg:golang/golang.org/x/crypto@v0.28.0" }
          ]
        }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path",
      "impact_statement": "payments-api imports golang.org/x/crypto only for bcrypt password hashing. The vulnerable ssh.ServerConfig callback path is not reachable; verified with `go tool callgraph` on build 1.8.3."
    }
  ]
}
```

Consumed at scan time so the gate stays meaningful:

```
$ trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
    --vex vex/payments-api.openvex.json \
    registry.acme.io/payments-api:1.8.3
2026-08-03T14:31:02Z INFO  [vex] VEX filtering  vex_id="https://acme.io/vex/payments-api/2026-08-03-001"
2026-08-03T14:31:02Z INFO  [vex] Filtered out the detected vulnerability  vulnerability-id="CVE-2024-45337" status="not_affected" justification="vulnerable_code_not_in_execute_path"

registry.acme.io/payments-api:1.8.3 (alpine 3.20.3)
Total: 0 (HIGH: 0, CRITICAL: 0)
```

VEX documents should themselves be signed and attached as attestations (`cosign attest --type openvex`), so the exception is auditable and expires with the image digest rather than living in a scanner's mutable ignore-list.

---

## 3. Artifact repositories

### 3.1 Comparison

| | **Harbor** | **Artifactory** | **GHCR** | **ECR / GAR** | **Quay** | **Zot** | **distribution** |
|---|---|---|---|---|---|---|---|
| License | Apache 2.0 (CNCF graduated) | Commercial | SaaS | SaaS | Apache 2.0 / SaaS | Apache 2.0 (CNCF sandbox) | Apache 2.0 |
| OCI 1.1 Referrers | ✅ ≥ 2.9 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ ≥ 2.8.2 (tag fallback) |
| Built-in vuln scan | ✅ Trivy | ✅ Xray (paid) | ❌ | ✅ (basic/enhanced) | ✅ Clair | ✅ Trivy | ❌ |
| Signature enforcement on pull-policy | ✅ Cosign + Notation | ✅ | ❌ | ⚠️ via policy engines | ✅ | ⚠️ | ❌ |
| Immutable tag rules | ✅ | ✅ | ⚠️ manual | ✅ | ✅ | ⚠️ | ❌ |
| Replication / pull-through proxy | ✅ | ✅ | ❌ | ✅ (pull-through) | ✅ | ✅ | ✅ (proxy mode) |
| Quotas & retention (GC) | ✅ | ✅ | ⚠️ | ✅ lifecycle policies | ✅ | ⚠️ | manual GC |
| Robot / workload identity | ✅ robot accounts | ✅ | ✅ OIDC | ✅ IRSA / WI | ✅ | ✅ | ❌ |
| Air-gap friendly | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ **(best — tiny, single binary)** | ✅ |
| Runs in-cluster | ✅ Helm/operator | ✅ | n/a | n/a | ✅ | ✅ | ✅ |

**Selection heuristic:** Harbor for self-hosted enterprise (policy features are the differentiator); Zot for edge/air-gapped/embedded (a ~30 MB static binary with full OCI 1.1 conformance); cloud-native registry for cloud-native clusters, because workload identity beats any secret you would otherwise have to rotate.

### 3.2 Harbor project hardening reference

The registry is a policy enforcement point in its own right — a second line of defense behind admission. Configure per project:

```
$ curl -sS -u "admin:${HARBOR_PW}" -X PUT \
    -H 'Content-Type: application/json' \
    https://registry.acme.io/api/v2.0/projects/payments \
    -d '{
      "metadata": {
        "public": "false",
        "enable_content_trust_cosign": "true",
        "prevent_vul": "true",
        "severity": "high",
        "auto_scan": "true",
        "reuse_sys_cve_allowlist": "false"
      }
    }'
```

| Setting | Effect | Failure mode if unset |
|---|---|---|
| `public: false` | Requires auth for pull | Anonymous enumeration of your internal service names and versions |
| `enable_content_trust_cosign: true` | Harbor refuses to serve unsigned images | Unsigned image reaches a cluster whose admission controller happens to be degraded |
| `prevent_vul: true` + `severity: high` | Blocks pull of images with ≥ High findings | Known-vulnerable image redeployed months later during an unrelated node drain |
| `auto_scan: true` | Scan on push | Findings discovered only when someone remembers to look |
| Immutable tag rule | Tag→digest binding frozen | `1.8.3` silently becomes a different image; your audit trail is fiction |

Immutable tag rule (`v*` and `[0-9]*` in every repository of the project):

```
$ curl -sS -u "admin:${HARBOR_PW}" -X POST \
    -H 'Content-Type: application/json' \
    https://registry.acme.io/api/v2.0/projects/payments/immutabletagrules \
    -d '{
      "disabled": false,
      "scope_selectors": {
        "repository": [ { "kind": "doublestar", "decoration": "repoMatches", "pattern": "**" } ]
      },
      "tag_selectors": [
        { "kind": "doublestar", "decoration": "matches", "pattern": "{v*,[0-9]*}" }
      ]
    }'
```

Verification that immutability actually took:

```
$ docker tag alpine:3.20 registry.acme.io/payments/payments-api:1.8.3
$ docker push registry.acme.io/payments/payments-api:1.8.3
The push refers to repository [registry.acme.io/payments/payments-api]
denied: The tag 1.8.3 in repository payments/payments-api is immutable, please delete it or make it mutable first
```

### 3.3 Registry mirroring and pull-through — the containerd layer

Even with a perfect registry policy, nodes must be configured to actually use it. Egress-restricted clusters should resolve *all* image references through the internal registry.

`containerd` 2.x (`/etc/containerd/config.toml`):

```toml
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

`containerd` 1.7.x:

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

Per-host mirror definitions:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://registry.acme.io/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = false
  ca = "/etc/containerd/certs.d/acme-root-ca.pem"
```

```toml
# /etc/containerd/certs.d/registry.acme.io/hosts.toml
server = "https://registry.acme.io"

[host."https://registry.acme.io"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/acme-root-ca.pem"
```

Verify from the node — the mirror is being used only if the resolve happens against the mirror host:

```
$ sudo ctr --namespace k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/library/alpine:3.20
docker.io/library/alpine:3.20:                                     resolved
index-sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a: exists
...
elapsed: 1.4 s    total:   0.0 B (0.0 B/s)
unpacking linux/amd64 sha256:1e42bbe2...
done: 61.2ms

$ sudo journalctl -u containerd --since '1 min ago' | grep -i 'registry.acme.io'
Aug 03 14:40:11 node-01 containerd[1183]: time="..." level=debug msg="resolving" host=registry.acme.io
```

### 3.4 CRI-O: runtime-level signature verification

CRI-O (via `containers/image`) can verify signatures **at pull time on the node**, which is a genuinely different control point from admission — it survives a compromised or bypassed API server admission chain.

```
# /etc/crio/crio.conf.d/10-signature-policy.conf
[crio.image]
signature_policy = "/etc/containers/policy.json"
signature_policy_dir = "/etc/crio/policies"
```

```json
{
  "default": [ { "type": "reject" } ],
  "transports": {
    "docker": {
      "registry.acme.io": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/containers/keys/acme-release.pub",
          "signedIdentity": { "type": "matchRepoDigestOrExact" }
        }
      ],
      "registry.k8s.io": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/containers/keys/k8s-release.pub",
          "signedIdentity": { "type": "matchRepoDigestOrExact" }
        }
      ]
    },
    "": [ { "type": "reject" } ]
  }
}
```

```
$ sudo crictl pull registry.acme.io/payments-api:1.8.3
FATA[0002] pulling image: rpc error: code = Unknown desc = SignatureValidationFailed:
  Source image rejected: A signature was required, but no signature exists
```

> `containerd` has **no equivalent native mechanism**. On containerd-based clusters, admission is your only enforcement point — which is why §5 matters so much.

### 3.5 Node pull credentials without long-lived secrets

`imagePullSecrets` are static, long-lived registry credentials stored in etcd and readable by anyone with `get secrets` in the namespace. Prefer the **kubelet credential provider** (GA since v1.26), which fetches short-lived tokens from the cloud IAM plane at pull time.

```yaml
# /etc/kubernetes/kubelet/credential-provider-config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - get-credentials
    env:
      - name: AWS_REGION
        value: sa-east-1
  - name: acme-oidc-credential-provider
    matchImages:
      - "registry.acme.io"
      - "registry.acme.io/*"
    defaultCacheDuration: "10m"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - --oidc-issuer=https://oidc.acme.io
      - --audience=registry.acme.io
```

Kubelet flags:

```
--image-credential-provider-config=/etc/kubernetes/kubelet/credential-provider-config.yaml
--image-credential-provider-bin-dir=/usr/local/bin/credential-providers
```

Verification:

```
$ sudo journalctl -u kubelet --since '5 min ago' | grep -i 'credential provider'
Aug 03 14:44:02 node-01 kubelet[2214]: I0803 14:44:02.118442  2214 plugin.go:158] "Successfully registered credential provider plugin" name="acme-oidc-credential-provider"
Aug 03 14:44:09 node-01 kubelet[2214]: I0803 14:44:09.774310  2214 plugin.go:245] "Got credentials from external credential provider" image="registry.acme.io/payments-api:1.8.3" cacheDuration="10m0s"
```

---

## 4. CI/CD: the build platform is part of your Trusted Computing Base

### 4.1 SLSA v1.0 Build levels

| Level | Requirement | What it defeats | Typical implementation |
|---|---|---|---|
| **L0** | Nothing | — | Local `docker build && docker push` |
| **L1** | Provenance exists and is distributed | Accidental mislabeling; "which commit is prod running?" | `buildx --provenance=mode=max` |
| **L2** | Build runs on a hosted platform; provenance is **signed** by that platform | A developer forging provenance from a laptop | GitHub Actions + `actions/attest-build-provenance`; Tekton Chains |
| **L3** | Build platform is hardened; provenance is **non-falsifiable** (signing key unreachable from user-controlled build steps); ephemeral, isolated runners | A malicious build step stealing the signing key and self-attesting | GitHub-hosted runners + Fulcio ephemeral certs; Tekton Chains with a controller-held key; SLSA GitHub Generator |

> **The L2→L3 distinction is the one architects get wrong.** If your pipeline does `cosign sign --key $COSIGN_KEY` where `COSIGN_KEY` is an environment variable available to the same job that runs `make build`, then arbitrary code in your repository (including from any dependency executed during the build) can read that key. That is L2 at best. Keyless signing with an OIDC-federated ephemeral certificate, or a separate signing job that only receives the digest, is the structural fix.

### 4.2 Reference pipeline (GitHub Actions, SLSA L3-shaped)

```yaml
# .github/workflows/release.yaml
name: release

on:
  push:
    tags: ['v*.*.*']

# Default to nothing; each job opts in explicitly.
permissions: {}

env:
  REGISTRY: registry.acme.io
  IMAGE_NAME: payments/payments-api

jobs:
  # ── Stage 1: static analysis of source + IaC ──────────────────────────────
  static-analysis:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write
    steps:
      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Scan source, secrets and misconfigurations
        uses: aquasecurity/trivy-action@6c175e9c4083a92bbca2f9724c8a5e33bc2d97a5 # 0.30.0
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          severity: HIGH,CRITICAL
          exit-code: '1'
          ignore-unfixed: true

      - name: Lint Kubernetes manifests
        run: |
          curl -sSfL -o kube-linter.tar.gz \
            https://github.com/stackrox/kube-linter/releases/download/v0.7.2/kube-linter-linux.tar.gz
          echo "b3a5b6bbf4c0cbb0eb8bbf9d4a2d5ee7c2f4a5b0f1e3d7c9a1b5e0f2d4c6a8b0  kube-linter.tar.gz" | sha256sum -c -
          tar -xzf kube-linter.tar.gz && sudo install kube-linter /usr/local/bin/
          kube-linter lint deploy/ --config .kube-linter.yaml

      - name: Kubesec scan
        run: |
          docker run --rm -i kubesec/kubesec:v2.14.2 scan /dev/stdin \
            < deploy/deployment.yaml | tee kubesec.json
          score=$(jq -r '.[0].score' kubesec.json)
          echo "kubesec score: ${score}"
          [ "${score}" -ge 5 ] || { echo "::error::kubesec score ${score} below threshold 5"; exit 1; }

  # ── Stage 2: build, SBOM, push. NO signing key is present in this job. ────
  build:
    needs: [static-analysis]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write        # OIDC token for registry auth — no static password
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      image:  ${{ steps.meta.outputs.image }}
    steps:
      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Set up QEMU
        uses: docker/setup-qemu-action@49b3bc8e6bdd4a60e6116a5414239cba5943d3cf # v3.2.0

      - name: Set up Buildx
        uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349 # v3.7.1

      - name: Registry login (OIDC-federated, short-lived)
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ vars.HARBOR_ROBOT_NAME }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}

      - name: Compute metadata
        id: meta
        run: |
          echo "image=${REGISTRY}/${IMAGE_NAME}" >> "$GITHUB_OUTPUT"
          echo "version=${GITHUB_REF_NAME#v}"    >> "$GITHUB_OUTPUT"

      - name: Build and push (multi-arch, with SBOM + max provenance)
        id: build
        uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75 # v6.9.0
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          sbom: true
          provenance: mode=max
          tags: |
            ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.version }}
          build-args: |
            GOFLAGS=-trimpath -buildvcs=true
          # Reproducibility: freeze timestamps to the commit time.
          outputs: type=image,rewrite-timestamp=true
        env:
          SOURCE_DATE_EPOCH: ${{ github.event.repository.pushed_at }}

      - name: Generate and upload standalone SBOMs
        run: |
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
            | sh -s -- -b /usr/local/bin v1.18.1
          syft scan "${{ steps.meta.outputs.image }}@${{ steps.build.outputs.digest }}" \
            -o spdx-json=sbom.spdx.json \
            -o cyclonedx-json=sbom.cdx.json

      - name: Gate on vulnerabilities (VEX-filtered)
        run: |
          curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin v0.58.0
          trivy sbom sbom.cdx.json \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            --vex vex/ \
            --exit-code 1

      - uses: actions/upload-artifact@b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882 # v4.4.3
        with:
          name: sboms
          path: sbom.*.json
          retention-days: 90

  # ── Stage 3: sign + attest. Isolated job; sees only the digest. ───────────
  sign:
    needs: [build]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write        # required for keyless (Fulcio) signing
    steps:
      - name: Install cosign
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0
        with:
          cosign-release: v2.4.1

      - uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v4.1.8
        with:
          name: sboms

      - name: Registry login
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ vars.HARBOR_ROBOT_NAME }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}

      - name: Sign the image (keyless — ephemeral Fulcio cert, Rekor logged)
        run: |
          cosign sign --yes \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

      - name: Attest the SBOM
        run: |
          cosign attest --yes \
            --type cyclonedx \
            --predicate sbom.cdx.json \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

      - name: Attest the SPDX SBOM as well
        run: |
          cosign attest --yes \
            --type spdxjson \
            --predicate sbom.spdx.json \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

  # ── Stage 4: prove the artifact passes the same gate the cluster applies ──
  verify:
    needs: [build, sign]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - name: Install cosign
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0

      - name: Verify signature exactly as the admission controller will
        run: |
          cosign verify \
            --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
            --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}" | jq -e '.[0].optional.Bundle' > /dev/null

      - name: Verify the SBOM attestation
        run: |
          cosign verify-attestation \
            --type cyclonedx \
            --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
            --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}" > /dev/null
```

**Non-obvious properties of that pipeline, and why each matters:**

| Property | Rationale |
|---|---|
| `permissions: {}` at workflow level, opt-in per job | The default `GITHUB_TOKEN` scope is a lateral-movement primitive. Least privilege per job. |
| Every `uses:` pinned to a **commit SHA** | Tags on third-party actions are mutable. `actions/checkout@v4` is an unauthenticated remote dependency you re-resolve on every run. |
| `persist-credentials: false` | Otherwise the git credential remains in `.git/config` on disk for every subsequent step, including third-party ones. |
| Build job holds **no signing material** | Structural SLSA L3 property. A malicious `go generate` in a dependency cannot sign. |
| Sign job receives only `digest`, never re-builds | Removes TOCTOU between what was scanned and what is signed. |
| `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` | Makes builds byte-reproducible so a second independent builder can corroborate the digest. |
| `verify` job re-runs the *production* verification predicate | The pipeline fails in CI rather than at 03:00 during a rollout, which is the only time anyone would otherwise notice a broken identity regexp. |
| Vulnerability gate runs on the **SBOM**, not the image | Deterministic, offline-capable, and identical to what downstream consumers will run. |

### 4.3 In-cluster builds: Tekton Chains

For organizations that build inside Kubernetes, Tekton Chains observes completed `TaskRun`/`PipelineRun` objects and emits signed in-toto provenance — the signing key lives in the Chains controller's namespace, unreachable from the build pod. That is the in-cluster equivalent of SLSA L3.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chains-config
  namespace: tekton-chains
data:
  # Provenance format and where it goes
  artifacts.taskrun.format: "in-toto"
  artifacts.taskrun.storage: "oci"
  artifacts.taskrun.signer: "x509"

  artifacts.pipelinerun.format: "in-toto"
  artifacts.pipelinerun.storage: "oci"
  artifacts.pipelinerun.signer: "x509"

  # Image signatures alongside provenance
  artifacts.oci.format: "simplesigning"
  artifacts.oci.storage: "oci"
  artifacts.oci.signer: "x509"

  # SLSA v1.0 predicate
  builder.id: "https://tekton.dev/chains/v2"
  slsa.builder.id: "https://tekton.dev/chains/v2"

  # Keyless signing via Fulcio, transparency via Rekor
  signers.x509.fulcio.enabled: "true"
  signers.x509.fulcio.address: "https://fulcio.sigstore.dev"
  signers.x509.fulcio.issuer: "https://oauth2.sigstore.dev/auth"
  signers.x509.fulcio.provider: "spiffe"
  signers.x509.identity.token.file: "/var/run/sigstore/cosign/oidc-token"

  transparency.enabled: "true"
  transparency.url: "https://rekor.sigstore.dev"
```

```
$ kubectl -n tekton-chains logs deploy/tekton-chains-controller --tail=8
{"level":"info","ts":"2026-08-03T14:52:10.331Z","logger":"watcher","caller":"taskrun/taskrun.go:60",
 "msg":"Received TaskRun payments-api-build-7fk2x in namespace builds"}
{"level":"info","ts":"2026-08-03T14:52:10.902Z","logger":"watcher","caller":"chains/signing.go:181",
 "msg":"Signing object with identity spiffe://acme.io/ns/builds/sa/build-runner"}
{"level":"info","ts":"2026-08-03T14:52:11.744Z","logger":"watcher","caller":"chains/rekor.go:74",
 "msg":"Uploaded entry to rekor with UUID 24296fb24b8ad77a9c4f1e0b3d5a7c9e1f0b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8"}
{"level":"info","ts":"2026-08-03T14:52:11.981Z","logger":"watcher","caller":"chains/signing.go:271",
 "msg":"Successfully signed and stored 1 artifact(s) for TaskRun builds/payments-api-build-7fk2x"}

$ tkn tr describe payments-api-build-7fk2x -n builds -o jsonpath='{.metadata.annotations}' | jq .
{
  "chains.tekton.dev/signed": "true",
  "chains.tekton.dev/payload-taskrun-abc123": "eyJfdHlwZSI6Imh0dHBzOi8vaW4tdG90by5pby9TdGF0ZW1lbnQvdjEi...",
  "chains.tekton.dev/transparency": "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=187449118"
}
```

### 4.4 Pipeline hardening checklist

| Control | Anti-pattern it removes |
|---|---|
| Ephemeral, single-use runners | Cross-job credential and cache poisoning |
| No long-lived registry password; OIDC federation or short-TTL robot tokens | Leaked token in logs remains valid for months |
| All third-party actions/plugins pinned by digest or SHA | Silent supply chain compromise via mutable tag |
| Dependency resolution from an internal proxy with an explicit allowlist | Dependency confusion / typosquatting |
| Lockfiles committed and enforced (`npm ci`, `go mod verify`, `pip install --require-hashes`) | Non-reproducible resolution at build time |
| Signing isolated from building | Key theft by malicious build step |
| Branch protection + required reviews + signed commits on the release branch | (A)(B) unauthorized source change |
| Build logs retained and provenance archived independently of the registry | Post-incident forensics with a deleted registry |
| Egress-restricted build network | Exfiltration and unpinned `curl \| bash` |

Verify the dependency layer explicitly — this is cheap and catches real problems:

```
$ go mod verify
all modules verified

$ GOFLAGS=-mod=readonly go build ./... && go version -m ./payments-api | head -20
./payments-api: go1.23.4
	path	github.com/acme/payments-api/cmd/api
	mod	github.com/acme/payments-api	(devel)
	dep	github.com/gin-gonic/gin	v1.10.0	h1:nTuyha1TYqgedzytsKYqna+DfLos46nTv2ygFy86HFU=
	dep	github.com/jackc/pgx/v5	v5.7.1	h1:x7SYsPBYDkHDksogeSmZZ5xzThcTgRz++hOSZ6NAJ68=
	dep	golang.org/x/crypto	v0.28.0	h1:GBDwsMXVQi34v5CCYUm2jkJvu4cbtru2U4TN2PSyQnw=
	build	-buildmode=exe
	build	-trimpath=true
	build	vcs=git
	build	vcs.revision=4c8e2b1f7a9d0c3e5b6f8a1d2c4e6b8f0a3d5c7e
	build	vcs.time=2026-08-03T13:58:41Z
	build	vcs.modified=false
```

`vcs.modified=false` is the assertion that the working tree was clean. A `true` there means the binary does not correspond to any commit — the provenance is worthless.

---

## 5. Enforcement at the cluster edge

### 5.1 Option comparison

| | **ValidatingAdmissionPolicy** | **Kyverno** | **Gatekeeper (+Ratify)** | **ImagePolicyWebhook** | **Connaisseur** |
|---|---|---|---|---|---|
| Language | CEL (in-process) | YAML DSL | Rego | Your own HTTP service | YAML config |
| Runs in-process in kube-apiserver | ✅ | ❌ webhook | ❌ webhook | ❌ webhook | ❌ webhook |
| Availability risk if component is down | **None** | `failurePolicy` decides | `failurePolicy` decides | `defaultAllow` decides | `failurePolicy` decides |
| Registry allowlist | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Digest pinning enforcement | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Signature verification** | ❌ (no network egress from CEL) | ✅ native `verifyImages` | ✅ via Ratify external data | ✅ if you implement it | ✅ |
| Attestation policy (SLSA/SBOM content) | ❌ | ✅ `attestations` + conditions | ✅ Ratify verifiers | custom | ⚠️ limited |
| Mutate tag → digest | ❌ | ✅ `mutateDigest: true` | ❌ | ❌ | ✅ |
| Kubernetes API version | `admissionregistration.k8s.io/v1` (GA 1.30) | CRD | CRD | `v1alpha1` (unchanged since 1.9) | CRD |
| Operational cost | Lowest | Medium | Medium-high (Rego) | High (you own the service) | Low |
| CKS exam presence | Increasingly | ✅ frequently | ✅ frequently | ✅ **classic exam item** | Rare |

**Recommended production topology — defense in depth, three layers:**
1. **VAP** for the cheap, absolute invariants (registry allowlist, digest-only). In-process, cannot be taken down, evaluated even if every webhook is unavailable.
2. **Kyverno `verifyImages`** for cryptographic verification and attestation policy. `failurePolicy: Fail` so a Kyverno outage blocks new workloads rather than silently admitting unsigned ones.
3. **Registry-side** `prevent_vul` / `enable_content_trust_cosign` as the backstop for anything that bypasses admission (static pods, a compromised webhook config).

### 5.2 ValidatingAdmissionPolicy — registry allowlist + digest pinning

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: supply-chain-image-provenance.acme.io
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - apiGroups:   ["batch"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["jobs", "cronjobs"]
  variables:
    # Normalise: pods carry .spec, workload controllers carry .spec.template.spec,
    # cronjobs carry .spec.jobTemplate.spec.template.spec.
    - name: podSpec
      expression: >-
        has(object.spec.template)
          ? object.spec.template.spec
          : (has(object.spec.jobTemplate)
              ? object.spec.jobTemplate.spec.template.spec
              : object.spec)
    - name: allImages
      expression: >-
        (variables.podSpec.containers.map(c, c.image)) +
        (has(variables.podSpec.initContainers)
           ? variables.podSpec.initContainers.map(c, c.image) : []) +
        (has(variables.podSpec.ephemeralContainers)
           ? variables.podSpec.ephemeralContainers.map(c, c.image) : [])
    - name: allowedPrefixes
      expression: >-
        ['registry.acme.io/', 'registry.k8s.io/']
  validations:
    - expression: >-
        variables.allImages.all(img,
          variables.allowedPrefixes.exists(p, img.startsWith(p)))
      messageExpression: >-
        'image(s) ' +
        variables.allImages.filter(img,
          !variables.allowedPrefixes.exists(p, img.startsWith(p))).join(', ') +
        ' are not from an approved registry. Approved: ' +
        variables.allowedPrefixes.join(', ')
      reason: Forbidden
    - expression: >-
        variables.allImages.all(img, img.contains('@sha256:'))
      messageExpression: >-
        'image(s) ' +
        variables.allImages.filter(img, !img.contains('@sha256:')).join(', ') +
        ' must be referenced by immutable digest (repo@sha256:...), not by tag'
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: supply-chain-image-provenance-binding.acme.io
spec:
  policyName: supply-chain-image-provenance.acme.io
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        # Exempt only the namespaces that bootstrap the cluster itself.
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

**Rolling this out safely** — always start in audit-only mode and read the audit log before flipping to `Deny`:

```yaml
  validationActions: ["Audit", "Warn"]
```

```
$ sudo grep -o '"validation.policy.admission.k8s.io/validation_failure":"[^"]*"' \
    /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn | head
     41 "validation.policy.admission.k8s.io/validation_failure":"[{\"message\":\"image(s) docker.io/bitnami/redis:7.4.1 are not from an approved registry...
     12 "validation.policy.admission.k8s.io/validation_failure":"[{\"message\":\"image(s) registry.acme.io/payments-api:1.8.3 must be referenced by immutable digest...
```

Then enforce:

```
$ kubectl run rogue --image=docker.io/library/nginx:latest
error: failed to create pod: admission webhook denied the request:
ValidatingAdmissionPolicy 'supply-chain-image-provenance.acme.io' with binding
'supply-chain-image-provenance-binding.acme.io' denied request:
image(s) docker.io/library/nginx:latest are not from an approved registry.
Approved: registry.acme.io/, registry.k8s.io/

$ kubectl run good --image=registry.acme.io/payments-api:1.8.3
error: failed to create pod: ... denied request: image(s) registry.acme.io/payments-api:1.8.3
must be referenced by immutable digest (repo@sha256:...), not by tag

$ kubectl run good --image=registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
pod/good created
```

### 5.3 Kyverno — signature and attestation verification

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-supply-chain
  annotations:
    policies.kyverno.io/title: Verify signatures, SLSA provenance and SBOM
    policies.kyverno.io/severity: critical
spec:
  # NOTE: on Kyverno >= 1.12 `spec.validationFailureAction` is deprecated for
  # validate rules in favour of `spec.rules[].validate.failureAction`, but it
  # remains the correct field for verifyImages rules.
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    # ── Rule 1: the image must carry a valid keyless signature ────────────
    - name: verify-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          # Rewrite tag -> digest in the admitted object so that the thing
          # verified is provably the thing that runs (closes the TOCTOU gap).
          mutateDigest: true
          verifyDigest: true
          required: true
          imageRegistryCredentials:
            allowInsecureRegistry: false
            secrets:
              - regcred-kyverno
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false

    # ── Rule 2: SLSA provenance must exist and name the right repo/builder ─
    - name: verify-slsa-provenance
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          required: true
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor:
                          url: https://rekor.sigstore.dev
              conditions:
                - all:
                    - key: "{{ buildDefinition.externalParameters.workflow.repository }}"
                      operator: Equals
                      value: "https://github.com/acme/payments-api"
                    - key: "{{ buildDefinition.externalParameters.workflow.ref }}"
                      operator: AnyIn
                      value: ["refs/heads/main", "refs/tags/*"]
                    - key: "{{ runDetails.builder.id }}"
                      operator: Equals
                      value: "https://github.com/actions/runner/github-hosted"

    # ── Rule 3: a CycloneDX SBOM attestation must exist and be recent ──────
    - name: verify-sbom-attestation
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          required: true
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ time_since('', '{{ metadata.timestamp }}', '') }}"
                      operator: LessThanOrEquals
                      value: "2160h"   # SBOM older than 90 days -> rebuild required
```

Observed behaviour:

```
$ kubectl -n payments run unsigned --image=registry.acme.io/payments/scratch-build:dev
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/payments/unsigned was blocked due to the following policies

verify-acme-supply-chain:
  verify-image-signature: 'failed to verify image registry.acme.io/payments/scratch-build:dev:
    .attestors[0].entries[0].keyless: no signatures found'

$ kubectl -n payments apply -f deploy/payments-api.yaml
deployment.apps/payments-api created

$ kubectl -n payments get pod -l app=payments-api \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
```

Note the last output: the manifest declared `:1.8.3`, and `mutateDigest: true` rewrote it to the digest that was actually verified. That rewrite is what makes the guarantee hold across a later node restart.

### 5.4 ImagePolicyWebhook — the classic exam configuration

Still shipped in v1.34 as `imagepolicy.k8s.io/v1alpha1`. Architecturally superseded, but it appears on the exam and it is the only admission mechanism whose *entire configuration* lives on the control plane filesystem — worth understanding for that reason alone.

**Step 1 — the admission configuration file:**

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50          # seconds to cache an "allow" decision
        denyTTL: 50           # seconds to cache a "deny" decision
        retryBackoff: 500     # milliseconds between retries
        defaultAllow: false   # FAIL CLOSED. The single most important field.
```

> `defaultAllow: true` means "if my webhook is unreachable, admit everything." That converts your image policy into a suggestion. On the exam, the expected answer is almost always `false`; in production it is *always* `false`, paired with an HA webhook deployment.

**Step 2 — kubeconfig the API server uses to reach the webhook (mTLS):**

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-policy-webhook
    cluster:
      certificate-authority: /etc/kubernetes/admission/pki/ca.crt
      server: https://image-policy.image-policy.svc:443/policy
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/admission/pki/apiserver-client.crt
      client-key: /etc/kubernetes/admission/pki/apiserver-client.key
current-context: webhook
contexts:
  - name: webhook
    context:
      cluster: image-policy-webhook
      user: kube-apiserver
```

**Step 3 — wire it into the static pod manifest.** Both the flags and the volume mounts are required; forgetting the mount is the classic failure.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml   (excerpt)
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.1.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook,AlwaysPullImages
        - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        # ... remaining flags unchanged ...
      volumeMounts:
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
  hostNetwork: true
  priorityClassName: system-node-critical
```

**Step 4 — what the API server sends and expects back.**

Request:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [
      { "image": "registry.acme.io/payments/payments-api@sha256:9f2b3c7d..." }
    ],
    "annotations": {
      "policy.image-policy.k8s.io/break-glass": "INC-4471"
    },
    "namespace": "payments"
  }
}
```

Response the webhook must return (HTTP 200 in both cases):

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": {
    "allowed": false,
    "reason": "image registry.acme.io/payments/payments-api@sha256:9f2b... has no valid cosign signature from the release workflow"
  }
}
```

Only pod annotations under `*.image-policy.k8s.io/*` are forwarded, and only if the plugin is configured to accept them — they are the intended break-glass channel, and every use should be alerted on.

**Verifying the plugin is actually loaded:**

```
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT  POD ID
7a3f1c0e9b2d   9e1d0f3a7b5c   2 minutes ago   Running   kube-apiserver   3        4b8e2f1a0c7d

$ sudo crictl logs 7a3f1c0e9b2d 2>&1 | grep -i 'admission\|imagepolicy' | head
I0803 15:02:11.442901       1 plugins.go:157] Loaded 14 mutating admission controller(s) successfully in the following order: NamespaceLifecycle,LimitRanger,ServiceAccount,...,DefaultIngressClass,MutatingAdmissionWebhook
I0803 15:02:11.443118       1 plugins.go:160] Loaded 15 validating admission controller(s) successfully in the following order: LimitRanger,ServiceAccount,PodSecurity,...,ImagePolicyWebhook,ValidatingAdmissionPolicy,ValidatingAdmissionWebhook

$ kubectl run test --image=docker.io/library/nginx:1.27
Error from server (Forbidden): pods "test" is forbidden: image policy webhook backend denied one or more images: image docker.io/library/nginx:1.27 is not from an approved registry
```

### 5.5 Gatekeeper equivalent (for Rego shops)

```yaml
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
            requireDigest:
              type: boolean
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input_containers[_]
          not any_prefix_matches(container.image)
          msg := sprintf(
            "container <%v> uses disallowed image <%v>; allowed repositories: %v",
            [container.name, container.image, input.parameters.repos])
        }

        violation[{"msg": msg}] {
          input.parameters.requireDigest
          container := input_containers[_]
          not contains(container.image, "@sha256:")
          msg := sprintf(
            "container <%v> image <%v> must be pinned by digest",
            [container.name, container.image])
        }

        any_prefix_matches(image) {
          startswith(image, input.parameters.repos[_])
        }

        input_containers[c] { c := input.review.object.spec.containers[_] }
        input_containers[c] { c := input.review.object.spec.initContainers[_] }
        input_containers[c] { c := input.review.object.spec.ephemeralContainers[_] }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: acme-approved-registries
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    repos:
      - "registry.acme.io/"
      - "registry.k8s.io/"
    requireDigest: true
```

```
$ kubectl get k8sallowedrepos acme-approved-registries -o jsonpath='{.status.totalViolations}{"\n"}'
0

$ kubectl -n staging run bad --image=quay.io/prometheus/node-exporter:v1.8.2
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[acme-approved-registries] container <bad> uses disallowed image <quay.io/prometheus/node-exporter:v1.8.2>;
allowed repositories: ["registry.acme.io/", "registry.k8s.io/"]
```

### 5.6 `AlwaysPullImages` — the control everyone forgets

Without it, node-local image caching is a namespace-isolation bypass: if any pod on node N has ever pulled `registry.acme.io/private/secrets-manager:1.0`, any other pod scheduled onto N can run that image with `imagePullPolicy: IfNotPresent` **without ever presenting a pull credential**.

```
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ImagePolicyWebhook
```

Verification:

```
$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cache-probe
  namespace: default
spec:
  containers:
    - name: c
      image: registry.acme.io/payments/payments-api:1.8.3
      imagePullPolicy: IfNotPresent
EOF
pod/cache-probe created

$ kubectl get pod cache-probe -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
Always

$ kubectl describe pod cache-probe | sed -n '/Events/,$p'
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  8s    default-scheduler  Successfully assigned default/cache-probe to node-02
  Normal   Pulling    7s    kubelet            Pulling image "registry.acme.io/payments/payments-api:1.8.3"
  Warning  Failed     6s    kubelet            Failed to pull image "registry.acme.io/payments/payments-api:1.8.3": failed to pull and unpack image: failed to resolve reference: unexpected status from HEAD request to https://registry.acme.io/v2/payments/payments-api/manifests/1.8.3: 401 Unauthorized
  Warning  Failed     6s    kubelet            Error: ErrImagePull
```

The pull policy was rewritten to `Always`, and the credential-less pull correctly failed. **Trade-off:** every pod start now performs a registry round trip. Budget for registry availability and latency (a pull-through cache on-node or an in-cluster mirror is the usual mitigation), and understand that an unreachable registry now blocks pod restarts cluster-wide.

---

## 6. Verification and failure diagnosis

### 6.1 End-to-end verification walkthrough

The exact sequence to run when someone asks "can we prove what is running in production?":

```
# 1. What digest is actually running, per container, cluster-wide?
$ kubectl get pods -A -o json | jq -r '
    .items[] as $p |
    (($p.status.containerStatuses // []) + ($p.status.initContainerStatuses // []))[] |
    [$p.metadata.namespace, $p.metadata.name, .name, .imageID] | @tsv' \
  | sort -u | column -t | head
kube-system  coredns-7c8f9b4d5-2xk7p   coredns  registry.k8s.io/coredns/coredns@sha256:1eeb4c7316bacb1d4c8ead65571cd92dd21e27359f0d4750fbe85edc1f1e5f6f
payments     payments-api-6f4c8d9b7-h2m9q  api  registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
payments     payments-api-6f4c8d9b7-tk3rl  api  registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

# 2. Detect digest drift — replicas of the same workload running different code.
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(.metadata.ownerReferences != null) |
    "\(.metadata.namespace)/\(.metadata.labels["app.kubernetes.io/name"] // .metadata.labels.app)\t\(.status.containerStatuses[0].imageID)"' \
  | sort -u | awk -F'\t' '{c[$1]++} END {for (k in c) if (c[k]>1) print "DRIFT:", k, c[k]" distinct digests"}'
DRIFT: default/legacy-worker 2 distinct digests

# 3. Verify the signature of a running digest.
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

Verification for registry.acme.io/payments/payments-api@sha256:9f2b3c7d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[{"critical":{"identity":{"docker-reference":"registry.acme.io/payments/payments-api"},
"image":{"docker-manifest-digest":"sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c"},
"type":"cosign container image signature"},"optional":{
"1.3.6.1.4.1.57264.1.1":"https://token.actions.githubusercontent.com",
"Bundle":{"SignedEntryTimestamp":"MEUCIQ...","Payload":{"logIndex":187443901,
"logID":"c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d",
"integratedTime":1785...,"index":187443901}},
"Issuer":"https://token.actions.githubusercontent.com",
"Subject":"https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/v1.8.3"}}]

# 4. Pull the SBOM attestation back out and interrogate it.
$ cosign verify-attestation --type cyclonedx \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d... 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq -r '.predicate.components[] | "\(.name)\t\(.version)"' \
  | grep -i 'crypto\|ssl\|xz\|log4j'
golang.org/x/crypto	v0.28.0
libcrypto3	3.3.2-r0
libssl3	3.3.2-r0

# 5. Verify provenance points at the source you think it does.
$ cosign verify-attestation --type slsaprovenance1 \
    --certificate-identity-regexp '^https://github\.com/acme/.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d... 2>/dev/null \
  | jq -r '.payload' | base64 -d \
  | jq '.predicate.buildDefinition.externalParameters, .predicate.runDetails.builder'
{
  "workflow": {
    "path": ".github/workflows/release.yaml",
    "ref": "refs/tags/v1.8.3",
    "repository": "https://github.com/acme/payments-api"
  }
}
{
  "id": "https://github.com/actions/runner/github-hosted"
}

# 6. Corroborate independently against the transparency log.
$ rekor-cli search --sha sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
Found matching entries (listed by UUID):
24296fb24b8ad77a3f8e2c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d
24296fb24b8ad77abc9e0f1d2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80912

$ rekor-cli get --uuid 24296fb24b8ad77a3f8e2c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d \
    --format json | jq -r '.IntegratedTime, .LogIndex'
1785294731
187443901
```

**The auditor's question this answers:** "prove that the binary running in `payments/payments-api` was built from commit X of repository Y by workflow Z on date D, and that nothing has altered it since." Steps 1, 3 and 5 together are that proof, and step 6 makes it independently verifiable by a third party who does not trust your registry.

### 6.2 Failure catalogue

| Symptom | Most likely root cause | Diagnostic command | Fix |
|---|---|---|---|
| `ErrImagePull` / `401 Unauthorized` | Missing/expired `imagePullSecret`, wrong SA, robot token rotated | `kubectl describe pod`, then `kubectl get sa <sa> -o yaml \| grep -A3 imagePullSecrets` | Attach secret to SA or move to kubelet credential provider |
| `ErrImagePull` / `manifest unknown` | Tag deleted, wrong arch, digest GC'd by registry retention | `crane manifest <ref>`, `crane ls <repo>` | Restore artifact; disable GC of referenced digests |
| `ImagePullBackOff` only on **some** nodes | Per-node `hosts.toml` / CA trust drift | `sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d <ref>` on the failing node | Reconcile node config with DaemonSet/Ignition |
| Kyverno: `no signatures found` | Image signed under a different digest (multi-arch index vs. platform manifest), or referrers mode mismatch | `cosign tree <ref>`; `oras discover -o tree <ref>` | Sign the **index** digest; align `--registry-referrers-mode` |
| Kyverno: `no matching signatures: certificate identity ... does not match` | Workflow file renamed, tag pattern changed, or a fork built it | `cosign verify ... 2>&1 \| grep Subject`; inspect cert | Update `subject` glob, or reject — this is the control working |
| Kyverno: `failed to fetch attestations: ... 403` | Kyverno lacks registry credentials for the private repo | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i registry` | Configure `imageRegistryCredentials.secrets` or `--imagePullSecrets` |
| **API server will not start** after enabling `ImagePolicyWebhook` | Missing hostPath mount, unparseable config, bad path | `sudo crictl ps -a --name kube-apiserver`; `sudo crictl logs <id>`; `sudo journalctl -u kubelet \| grep apiserver` | Add the `volumes`+`volumeMounts` pair; validate YAML |
| Everything admitted despite policy | `defaultAllow: true`, or `failurePolicy: Ignore`, or binding `validationActions: ["Audit"]` | `grep defaultAllow /etc/kubernetes/admission/admission-config.yaml`; `kubectl get vapb -o yaml` | Fail closed |
| `cosign verify` → `error validating certificate: no matching CT log found` | Air-gapped or stale TUF root | `cosign initialize` output | `cosign initialize --mirror <internal> --root <root.json>` |
| `cosign verify` → `no matching signatures` but signature visibly exists | Verifying the tag while the signature is on the platform-specific digest | `crane digest --platform linux/amd64 <ref>` vs `crane digest <ref>` | Always verify by index digest |
| Scanner reports 0 findings on a real app | Distroless/static binary with no package DB; scanner found nothing to parse | `syft scan <ref> -o table \| wc -l` | Use build-time SBOM; add binary classifiers |
| Trivy: `DB error: failed to download` in CI | Rate limit on the vuln DB registry | — | Mirror the DB: `trivy image --db-repository registry.acme.io/trivy-db` |

### 6.3 Two failures worth walking through in detail

**Failure A — `cosign verify` fails on a multi-arch image.**

```
$ cosign verify --certificate-identity-regexp '...' --certificate-oidc-issuer '...' \
    registry.acme.io/payments/payments-api:1.8.3
Error: no matching signatures:
main.go:74: error during command execution: no matching signatures:

$ crane digest registry.acme.io/payments/payments-api:1.8.3
sha256:3d8f0b6c2e4a1f7d9b0c3e5a7f1d4b6e8a0c2f4d6b8e0a2c4f6d8b0e2a4c6f8d

$ crane digest --platform linux/amd64 registry.acme.io/payments/payments-api:1.8.3
sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

$ cosign verify ... registry.acme.io/payments/payments-api@sha256:9f2b3c7d...
Verification for registry.acme.io/payments/payments-api@sha256:9f2b3c7d... --
  ...checks passed
```

**Diagnosis:** the pipeline signed the **platform manifest** digest (what `build-push-action` returns as `digest` for a single-platform build) rather than the **index** digest that the tag points to. Kubernetes resolves the tag to the index, so admission verifies the index and finds nothing.
**Fix:** sign the index digest. In `docker/build-push-action` with multiple `platforms`, `steps.build.outputs.digest` *is* the index digest — the bug appears when someone later adds a second platform without re-checking the signing step. Add the §4.2 `verify` job so CI catches it.

**Failure B — the API server crash-loops after enabling ImagePolicyWebhook.**

```
$ kubectl get nodes
The connection to the server 10.0.1.10:6443 was refused - did you specify the right host or port?

$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT  POD ID
2f1a9c0e3b7d   9e1d0f3a7b5c   9 seconds ago   Exited   kube-apiserver   7        8c3e1b0a5f2d

$ sudo crictl logs 2f1a9c0e3b7d 2>&1 | tail -4
W0803 15:14:02.117338       1 admission.go:78] Admission plugin "ImagePolicyWebhook" configuration error
E0803 15:14:02.117512       1 run.go:74] "command failed" err="failed to initialize admission: couldn't init admission plugin \"ImagePolicyWebhook\": open /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml: no such file or directory"

$ sudo ls -l /etc/kubernetes/admission/
total 8
-rw------- 1 root root  312 Aug  3 15:12 admission-config.yaml
-rw------- 1 root root  641 Aug  3 15:12 imagepolicy-kubeconfig.yaml

$ sudo grep -A6 'volumeMounts' /etc/kubernetes/manifests/kube-apiserver.yaml | head -8
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
```

**Diagnosis:** the files exist on the host, but the API server runs as a container and `/etc/kubernetes/admission` was never mounted into it. The path resolution failure is inside the container's mount namespace.
**Fix:** add the `volumes`/`volumeMounts` pair from §5.4. The kubelet re-reads the static pod manifest within seconds; no restart needed.

```
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml    # add the mount + volume
$ sleep 25 && kubectl get --raw='/readyz?verbose' | tail -3
[+]shutdown ok
[+]poststarthook/start-legacy-token-tracking-controller ok
readyz check passed
```

> **Operational rule:** before editing `kube-apiserver.yaml`, always `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak`. Moving the manifest *out* of `/etc/kubernetes/manifests/` stops the API server; moving it back starts it. That is your only recovery path when the file is malformed, and it is a routine exam scenario.

### 6.4 Air-gapped verification

Sigstore's public good instance is unreachable in an air-gapped cluster. Two supported approaches:

**(a) Mirror the TUF root and run internal Fulcio/Rekor:**

```
$ cosign initialize \
    --mirror https://tuf.acme.internal \
    --root /etc/sigstore/acme-tuf-root.json
Root status:
 {
  "local": "/home/sre/.sigstore/root",
  "remote": "https://tuf.acme.internal",
  "metadata": {
    "root.json": { "version": 3, "len": 4271, "expiration": "27 Jan 27 12:00 UTC", "error": "" },
    "targets.json": { "version": 9, "len": 1782, "expiration": "12 Nov 26 09:00 UTC", "error": "" }
  },
  "targets": [ "fulcio_v1.crt.pem", "ctfe.pub", "rekor.pub" ]
 }
```

**(b) Long-lived keys plus offline bundles** — simpler, and correct when you control both ends:

```
$ cosign generate-key-pair k8s://cosign-system/cosign-signing-key
Private key written to kubernetes://cosign-system/cosign-signing-key
Public key written to cosign.pub

$ cosign sign --key k8s://cosign-system/cosign-signing-key --tlog-upload=false --yes \
    registry.acme.internal/payments/payments-api@sha256:9f2b3c7d...

$ cosign verify --key cosign.pub --insecure-ignore-tlog=true \
    registry.acme.internal/payments/payments-api@sha256:9f2b3c7d...
WARNING: Skipping tlog verification is an insecure practice that lacks transparency/timestamping.
Verification for registry.acme.internal/payments/payments-api@sha256:9f2b3c7d... --
  ...checks passed
```

Corresponding Kyverno attestor:

```yaml
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqR8b3F1a5c7d9e0f2a4b6c8d0e2f4a
                      6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c==
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true
                    ctlog:
                      ignoreSCT: true
```

The trade-off is explicit: without a transparency log you lose the ability to detect that a key was misused before you knew it was compromised, and you take on key rotation as an operational burden. Mirror Rekor if the environment can support it.

---

## 7. Consolidated checklist

| # | Control | Verify with |
|---|---|---|
| 1 | Every first-party image has a build-time SBOM (SPDX + CycloneDX) attached as a signed attestation | `cosign verify-attestation --type cyclonedx` |
| 2 | Every image has SLSA v1 provenance naming the correct repo, ref and builder | `cosign verify-attestation --type slsaprovenance1` |
| 3 | Signing key material is unreachable from build steps (keyless, or a separate job/controller) | Read the pipeline: does the build job see `COSIGN_*`? |
| 4 | Registry enforces immutable tags, auto-scan, and blocks vulnerable/unsigned pulls | Try to overwrite a released tag; expect `denied` |
| 5 | Admission enforces registry allowlist **and** digest pinning, in-process (VAP), fail-closed | `kubectl run` with a `docker.io` tag; expect deny |
| 6 | Admission verifies signatures + attestations (Kyverno/Ratify), `failurePolicy: Fail`, `mutateDigest: true` | Deploy an unsigned image; expect deny. Check admitted pod's image is a digest. |
| 7 | `AlwaysPullImages` enabled | `kubectl get pod X -o jsonpath='{.spec.containers[0].imagePullPolicy}'` → `Always` |
| 8 | No long-lived `imagePullSecrets` where a credential provider is available | `kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson` |
| 9 | Nodes resolve all images through the internal registry/mirror | `sudo ctr -n k8s.io images pull --hosts-dir ...` on a node |
| 10 | A cluster-wide digest inventory is produced on a schedule and diffed against the SBOM store | The `jq` pipeline in §6.1, run as a CronJob |
| 11 | VEX documents are signed, attached, and consumed by the scanner gate | `trivy sbom --vex ...` shows `Filtered out` lines |
| 12 | Break-glass paths (policy exclusions, `image-policy.k8s.io` annotations) are alerted on | Audit-log query for the annotation prefix |

Items 5–7 are pure `kubectl`/control-plane work and are the highest-probability exam surface. Items 1–3 are what separates a program that can answer "are we affected by CVE-YYYY-NNNNN?" in ten minutes from one that cannot answer it at all.

---

## Referencias

**Curriculum and exam**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Linux Foundation CKS program page — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Kubernetes official documentation**
- Admission Controllers Reference (ImagePolicyWebhook, AlwaysPullImages) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Images (pull policy, private registries, digests) — https://kubernetes.io/docs/concepts/containers/images/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Kubelet Credential Provider — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/
- Image Volumes — https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/
- Kubernetes Release SBOMs — https://sbom.k8s.io/
- Kubernetes Supply Chain Security (SIG Release) — https://github.com/kubernetes/sig-release/blob/master/security/README.md
- Verify Kubernetes release artifact signatures — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/

**SBOM standards**
- SPDX specification — https://spdx.dev/use/specifications/
- SPDX 3.0 — https://spdx.github.io/spdx-spec/v3.0.1/
- CycloneDX specification — https://cyclonedx.org/specification/overview/
- CycloneDX / ECMA-424 — https://ecma-international.org/publications-and-standards/standards/ecma-424/
- NTIA Minimum Elements for an SBOM — https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom
- CISA SBOM resources — https://www.cisa.gov/sbom
- Package URL (PURL) specification — https://github.com/package-url/purl-spec

**VEX**
- OpenVEX specification — https://github.com/openvex/spec
- CISA VEX documentation — https://www.cisa.gov/resources-tools/resources/minimum-requirements-vulnerability-exploitability-exchange-vex

**Provenance, attestation and signing**
- SLSA v1.0 specification — https://slsa.dev/spec/v1.0/
- SLSA threat model — https://slsa.dev/spec/v1.0/threats
- SLSA provenance predicate — https://slsa.dev/provenance/v1
- in-toto Attestation Framework — https://github.com/in-toto/attestation
- Sigstore documentation — https://docs.sigstore.dev/
- cosign — https://github.com/sigstore/cosign
- Rekor transparency log — https://docs.sigstore.dev/logging/overview/
- Fulcio certificate authority — https://docs.sigstore.dev/certificate_authority/overview/
- Notary Project (Notation) — https://notaryproject.dev/docs/
- Notation trust policy reference — https://github.com/notaryproject/specifications/blob/main/specs/trust-store-trust-policy.md

**Registries and OCI**
- OCI Image Specification v1.1 (referrers, subject) — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Distribution Specification (Referrers API) — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- Harbor documentation — https://goharbor.io/docs/
- Harbor content trust & vulnerability policy — https://goharbor.io/docs/latest/administration/vulnerability-scanning/
- Zot registry — https://zotregistry.dev/
- ORAS — https://oras.land/docs/
- containerd registry host configuration — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- CRI-O signature verification (containers-policy.json) — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md

**Tooling**
- Syft — https://github.com/anchore/syft
- Grype — https://github.com/anchore/grype
- Trivy — https://trivy.dev/latest/docs/
- Trivy VEX support — https://trivy.dev/latest/docs/supply-chain/vex/
- BuildKit attestations — https://docs.docker.com/build/metadata/attestations/
- Docker build provenance — https://docs.docker.com/build/metadata/attestations/slsa-provenance/
- Kubesec — https://kubesec.io/
- KubeLinter — https://docs.kubelinter.io/

**Policy engines**
- Kyverno image verification — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Kyverno verifying attestations — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/#verifying-image-attestations
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Gatekeeper policy library (allowed repos) — https://open-policy-agent.github.io/gatekeeper-library/website/validation/allowedrepos
- Ratify — https://ratify.dev/docs/what-is-ratify
- Connaisseur — https://sse-secure-systems.github.io/connaisseur/

**CI/CD**
- Tekton Chains — https://tekton.dev/docs/chains/
- GitHub Actions OIDC hardening — https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- GitHub artifact attestations — https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds
- SLSA GitHub Generator — https://github.com/slsa-framework/slsa-github-generator
- CNCF Software Supply Chain Best Practices White Paper — https://github.com/cncf/tag-security/blob/main/community/resources/software-supply-chain-security/secure-software-factory/secure-software-factory.md