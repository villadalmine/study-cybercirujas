# 701.5 — Software Composition, Licensing and Open Source

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, version 2.0.0
**Topic weight:** 3.34
**Profile:** Principal Platform Architect / Senior SRE
**Authoring language:** English (technical terms untranslated)

---

## 1. The production problem: you cannot patch what you cannot enumerate

### 1.1 The incident that defines this objective

At 17:26 UTC on 9 December 2021, CVE-2021-44228 (Log4Shell) became public. The vulnerable artifact was `org.apache.logging.log4j:log4j-core` in versions `2.0-beta9` through `2.14.1`. Almost no organisation had it as a **direct** dependency. It arrived as a transitive dependency of Elasticsearch clients, Kafka producers, Spring Boot starters, Solr, Logstash appenders, and — worst of all — as classes *shaded* into fat JARs where the coordinate `log4j-core` no longer appears anywhere on disk.

The engineering question was trivial to state and, for most organisations, took **days to weeks** to answer:

> Which of the 1,400 container images currently running in our clusters contain `log4j-core` at a version below 2.17.1, and which of those are reachable from the internet?

Two years later CVE-2024-3094 (the `xz-utils` / `liblzma` backdoor, versions 5.6.0 and 5.6.1) repeated the exercise at the OS-package layer instead of the language layer, and the same organisations discovered they had inventory for one layer but not the other.

The architectural failure is not "we did not patch fast enough". It is that **the inventory was computed at incident time instead of at build time**. Answering the question required re-deriving, for every artifact, a dependency resolution that the build system had already performed and then discarded.

### 1.2 The second failure mode: licensing

The same missing inventory produces a second class of production incident, with a slower fuse and a larger blast radius:

* A platform team vendors an AGPL-3.0 library into a SaaS control plane. GPL-3.0 §13 as incorporated by AGPL-3.0 requires that users **interacting with the program over a network** be offered the Corresponding Source — including your modifications. There is no "we did not distribute a binary" defence.
* A team ships a customer-installable appliance image based on `debian:bookworm-slim`. That image conveys `bash`, `coreutils`, `util-linux`, `libc6` — GPL-2.0/GPL-3.0 and LGPL-2.1 works. GPL-2.0 §3 requires that conveyance be accompanied by source or by a **written offer valid for three years**. Nobody wrote the offer.
* A vendor relicenses under BUSL-1.1 or SSPL-1.0. Neither is an OSI-approved open source licence. The `main` branch you pinned to keeps building; the licence obligations silently changed at a tag boundary.

Legal exposure and vulnerability exposure are answered by **the same artifact**: a resolved, signed, machine-readable inventory of everything inside the thing you shipped. That artifact is the **SBOM** (Software Bill of Materials), and producing, signing, storing and querying it is what 701.5 examines.

### 1.3 The architectural target

```
                 ┌────────────────────────────────────────────────────┐
   source        │  BUILD (the only place resolution is authoritative)│
   + lockfile ──►│  compile ─► SBOM(build) ─► sign ─► attest          │
                 └───────────────┬────────────────────────────────────┘
                                 │  OCI artifact + in-toto/DSSE attestations
                                 ▼
                 ┌────────────────────────────────────────────────────┐
   registry      │  image@sha256:…                                     │
                 │    ├─ .sbom      (SPDX / CycloneDX)                 │
                 │    ├─ .att       (SLSA provenance)                  │
                 │    └─ .vex       (OpenVEX statements)               │
                 └───────────────┬────────────────────────────────────┘
                                 │
              ┌──────────────────┼────────────────────┐
              ▼                  ▼                    ▼
   ┌────────────────┐  ┌──────────────────┐  ┌─────────────────────┐
   │ Dependency-Track│  │ Admission control│  │ Continuous re-scan  │
   │ (queryable      │  │ (Kyverno verify  │  │ (new CVE ⇒ re-match │
   │  inventory DB)  │  │  attestations)   │  │  old SBOMs)         │
   └────────────────┘  └──────────────────┘  └─────────────────────┘
```

The property that matters: at incident time the query is **O(1) against a database**, not O(N) against N build pipelines. The SBOM is generated once, at the moment the facts are known, and is immutable and signed thereafter.

### 1.4 Where to generate the SBOM — the central trade-off

| Generation point | Mechanism | Sees direct deps | Sees transitive deps | Sees OS packages | Sees what actually ships | Sees build-time-only deps | Typical tools |
|---|---|---|---|---|---|---|---|
| **Source / manifest** | parse `package.json`, `pom.xml`, `go.mod` | ✅ | ⚠️ only if lockfile present | ❌ | ❌ (declared ≠ resolved) | ✅ | `osv-scanner`, `cdxgen`, Dependabot |
| **Lockfile** | parse `package-lock.json`, `poetry.lock`, `go.sum`, `Cargo.lock` | ✅ | ✅ exact versions | ❌ | ⚠️ includes dev deps | ✅ | `osv-scanner`, `syft`, `trivy fs` |
| **Build system** | plugin inside Maven/Gradle/Bazel | ✅ | ✅ with scopes & classifiers | ❌ | ✅ for that language | ✅ | `cyclonedx-maven-plugin`, `cyclonedx-gradle-plugin`, `cdxgen` |
| **Binary / image** | filesystem + package-DB cataloguing | ✅ | ✅ | ✅ | ✅ **as-shipped truth** | ❌ | `syft`, `trivy image` |
| **Runtime** | eBPF / process introspection | ✅ | ✅ | ✅ | ✅ + loaded-only | ❌ | Trivy Operator, Falco-adjacent tooling |

**Production recommendation:** generate **two** SBOMs and attach both.

1. A **build-time SBOM** from the build system — it is the only source that knows dependency *scope* (compile vs test vs provided), resolved classifiers, and shaded/relocated coordinates.
2. An **image SBOM** from `syft`/`trivy` against the final artifact — it is the only source that knows what the base image dragged in.

Merging them is a solved problem (`cyclonedx-cli merge`, `syft ... --catalogers`); pretending one substitutes for the other is the most common architectural mistake in this space. A build SBOM misses `libssl3`; an image SBOM misses the shaded `log4j-core` classes.

---

## 2. Open source licensing for platform engineers

### 2.1 The Open Source Definition is not "you can see the code"

The OSI **Open Source Definition** has ten criteria; the ones that generate production decisions are:

1. Free redistribution (no royalty on sale of aggregates)
3. Derived works must be allowed and redistributable under the same terms
5. No discrimination against persons or groups
6. **No discrimination against fields of endeavour** — this is the clause SSPL-1.0, BUSL-1.1 and Elastic-2.0 fail
7. Licence travels with the program, no separate NDA required
9. Licence must not restrict other software distributed alongside it

"Source-available" ≠ "open source". A `LICENSE` file is not evidence of an OSI-approved licence; the SPDX identifier is.

### 2.2 Licence taxonomy with production consequences

| SPDX identifier | Class | Copyleft scope | Trigger | Explicit patent grant | Practical risk in a container image | Practical risk in SaaS |
|---|---|---|---|---|---|---|
| `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC` | Permissive | none | — | ❌ (implied at most) | Notice + copyright must ship | none |
| `Apache-2.0` | Permissive | none | — | ✅ §3, with retaliation termination | Notice + `NOTICE` file + change log (§4) | none |
| `MPL-2.0` | Weak copyleft | **per-file** | distribution of modified files | ✅ §2.1(b) | must publish modified files only | none (no network clause) |
| `EPL-2.0` | Weak copyleft | per-module | distribution | ✅ | source of modified module | none unless secondary GPL notice |
| `LGPL-2.1-only` / `LGPL-3.0-only` | Weak copyleft | library boundary | distribution | 3.0 ✅ / 2.1 ❌ | **dynamic** link OK; **static** link requires shipping relinkable objects | none |
| `GPL-2.0-only` | Strong copyleft | whole derived work | conveying | ❌ | image conveys GPL ⇒ §3 source offer | none |
| `GPL-3.0-only` | Strong copyleft | whole derived work | conveying | ✅ §11 | + §6 installation info for "User Products" | none |
| `AGPL-3.0-only` | Network copyleft | whole derived work | conveying **or network interaction** | ✅ | as GPL-3.0 | 🔴 **§13: source to remote users** |
| `CDDL-1.0` | Weak copyleft | per-file | distribution | ✅ | ⚠️ FSF: incompatible with GPL-2.0 | none |
| `SSPL-1.0` | Not OSI | service-wide | offering as a service | ✅-ish | 🔴 | 🔴 §13: all service-management source |
| `BUSL-1.1` | Not OSI (source-available) | n/a | production use | ❌ | 🔴 field-of-use restriction until Change Date | 🔴 |
| `Elastic-2.0` | Not OSI | n/a | providing as managed service | ❌ | 🔴 | 🔴 |

### 2.3 Compatibility: the direction matters

Licence compatibility is **directional**. "Can I combine A and B and distribute the result under B?" is a different question from "…under A?".

| Incoming component | Combined work distributed under → | `MIT` | `Apache-2.0` | `MPL-2.0` | `GPL-2.0-only` | `GPL-3.0-or-later` | `AGPL-3.0` | Proprietary |
|---|---|---|---|---|---|---|---|---|
| `MIT` | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Apache-2.0` | | ❌ | ✅ | ✅ | ❌ ¹ | ✅ | ✅ | ✅ |
| `MPL-2.0` | | ❌ | ❌ | ✅ | ✅ ² | ✅ ² | ✅ ² | ✅ ³ |
| `LGPL-2.1-only` | | ❌ | ❌ | ❌ | ✅ | ❌ ⁴ | ❌ ⁴ | ✅ ³ |
| `GPL-2.0-only` | | ❌ | ❌ | ❌ | ✅ | ❌ ⁵ | ❌ ⁵ | ❌ |
| `GPL-2.0-or-later` | | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| `GPL-3.0-only` | | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| `CDDL-1.0` | | ❌ | ❌ | ❌ | ❌ ⁶ | ❌ ⁶ | ❌ ⁶ | ✅ ³ |

¹ FSF position: the Apache-2.0 patent-termination and indemnification terms are additional restrictions under GPL-2.0 §6. Compatible with GPL-3.0 because §7 permits those additional terms.
² Via the MPL-2.0 §3.3 "Secondary Licenses" clause — **unless** the file carries the "Incompatible With Secondary Licenses" notice (Exhibit B).
³ Weak copyleft: proprietary combination is fine provided the covered files' source is available and (for LGPL static linking) relinking is possible.
⁴ LGPL-2.1-**only** lacks the "or later" upgrade path; `LGPL-2.1-or-later` upgrades cleanly to LGPL-3.0/GPL-3.0.
⁵ The reason `GPL-2.0-only` vs `GPL-2.0-or-later` is a **different SPDX identifier** and not a formatting detail. Linux is GPL-2.0-only.
⁶ The ZFS-on-Linux situation: per-file copyleft with terms GPL considers additional restrictions.

> **Exam and production note:** the deprecated SPDX ids `GPL-2.0` and `GPL-2.0+` still appear in old metadata. They are ambiguous. The current identifiers are `GPL-2.0-only` and `GPL-2.0-or-later`.

### 2.4 SPDX licence expressions

SBOM policy engines match on **expressions**, not free text. The grammar:

```
expression   := simple | compound
simple       := <SPDX-id> | <SPDX-id>"+" | "LicenseRef-"<idstring>
compound     := simple "WITH" <exception-id>
              | expression "AND" expression
              | expression "OR" expression
              | "(" expression ")"
```

Real-world expressions you will encounter and must handle:

| Expression | Meaning | Policy handling |
|---|---|---|
| `Apache-2.0` | single licence | trivial |
| `MIT OR Apache-2.0` | **licensee chooses** — the Rust/Go ecosystem default | policy may pick the permitted branch |
| `GPL-2.0-only AND MIT` | **both** apply simultaneously | must satisfy the strictest |
| `GPL-2.0-only WITH Classpath-exception-2.0` | OpenJDK: linking exception removes the classpath copyleft reach | ⚠️ a naive `contains("GPL")` rule wrongly blocks the JDK |
| `LGPL-2.1-or-later WITH LLVM-exception` | | ditto |
| `GPL-3.0-or-later WITH GCC-exception-3.1` | libgcc/libstdc++ runtime | ditto |
| `LicenseRef-Proprietary-Acme` | non-SPDX licence, defined in the SBOM's `hasExtractedLicensingInfos` | must be explicitly allow/deny-listed |
| `NOASSERTION` | the tool could not determine it | **not** "permissive"; treat as blocking-unknown |

The single most damaging policy bug in this domain is treating `OR` as `AND` (blocking `MIT OR Apache-2.0` because one branch is disallowed) or substring-matching `GPL` (blocking every JVM image because of the Classpath Exception).

### 2.5 Conveying a container image *is* distribution

A `FROM debian:bookworm-slim` image published to a public or customer-facing registry conveys GPL-licensed binaries. Obligations you must actually engineer:

* **Notices must travel with the artifact.** Debian keeps them at `/usr/share/doc/<pkg>/copyright`; `debian:*-slim` images **retain** them, but many "optimise" Dockerfiles delete `/usr/share/doc`. That deletion is a compliance regression, not a size optimisation.
* **Source offer.** GPL-2.0 §3(b) permits a written offer valid for three years; GPL-3.0 §6(b) similarly, or §6(d) an equivalent-access download server. Relying on "Debian publishes the source" is common but is *your* offer to make, not Debian's.
* **Apache-2.0 §4(d):** if the upstream work has a `NOTICE` file, its contents must be reproduced in your distribution.

Practical implementation — bake the notices into the image at build time:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim AS licenses
RUN set -eu; \
    mkdir -p /out/licenses; \
    for d in /usr/share/doc/*/copyright; do \
        pkg="$(basename "$(dirname "$d")")"; \
        install -Dm0444 "$d" "/out/licenses/os/$pkg.copyright"; \
    done; \
    dpkg-query -W -f='${Package}\t${Version}\t${Source}\n' > /out/licenses/os/packages.tsv

FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=true \
      -ldflags="-s -w -X main.version=${VERSION:-dev}" \
      -o /out/payments-api ./cmd/payments-api
# go-licenses emits the full text of every module's licence
RUN go install github.com/google/go-licenses@latest && \
    go-licenses save ./cmd/payments-api --save_path=/out/licenses/go && \
    go-licenses report ./cmd/payments-api --template=/dev/null > /out/licenses/go/report.csv 2>/dev/null || \
    go-licenses csv ./cmd/payments-api > /out/licenses/go/report.csv

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build  /out/payments-api          /usr/local/bin/payments-api
COPY --from=build  /out/licenses/go           /usr/share/licenses/go
COPY --from=licenses /out/licenses/os         /usr/share/licenses/os
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/payments-api"]
```

### 2.6 Inbound contribution policy: DCO vs CLA

| | **DCO** (Developer Certificate of Origin 1.1) | **CLA** (Contributor Licence Agreement) |
|---|---|---|
| Instrument | A ~200-word certification, signed per commit | A contract signed once per contributor/employer |
| Mechanism | `git commit -s` → `Signed-off-by:` trailer | Web form / CLA-bot, out-of-band |
| Grants | Nothing beyond the project licence — it *asserts provenance* | Copyright licence (often broad) ± patent grant; ICLA/CCLA variants |
| Enables relicensing | ❌ | ✅ (this is usually the point) |
| Contributor friction | Very low | High — legal review, corporate CCLA |
| Enforcement | `git interpret-trailers`, DCO GitHub App, `gitlint` | CLA-assistant bot blocking the PR |
| Used by | Linux kernel, Kubernetes/CNCF, Docker, GitLab | Apache Software Foundation (ICLA/CCLA), many vendor-led projects |

Enforce DCO in CI without a third-party app:

```bash
$ git log --format='%H %s%n%b' origin/main..HEAD | grep -c '^Signed-off-by: '
0
$ git rebase --signoff origin/main
Successfully rebased and updated refs/heads/feature/sbom-attest.
$ git log -1 --format='%B'
feat(ci): attach CycloneDX SBOM as a cosign attestation

Signed-off-by: Ada Lovelace <ada@example.org>
```

### 2.7 REUSE: making licensing machine-readable at file level

The FSFE REUSE Specification requires every file to declare `SPDX-FileCopyrightText` and `SPDX-License-Identifier`, either inline, in a `.license` sidecar, or in `REUSE.toml`.

```toml
# REUSE.toml
version = 1
SPDX-PackageName = "payments-api"
SPDX-PackageSupplier = "Acme Platform Team <platform@acme.example>"
SPDX-PackageDownloadLocation = "https://github.com/acme/payments-api"

[[annotations]]
path = "vendor/**"
precedence = "aggregate"
SPDX-FileCopyrightText = "NONE"
SPDX-License-Identifier = "NOASSERTION"

[[annotations]]
path = ["docs/**", "**.md"]
precedence = "aggregate"
SPDX-FileCopyrightText = "2026 Acme Corp"
SPDX-License-Identifier = "CC-BY-SA-4.0"

[[annotations]]
path = ["deploy/**.yaml", "**.go", "Makefile"]
precedence = "aggregate"
SPDX-FileCopyrightText = "2026 Acme Corp"
SPDX-License-Identifier = "Apache-2.0"
```

```bash
$ reuse lint
# MISSING COPYRIGHT AND LICENSING INFORMATION

The following files have no copyright and licensing information:
* scripts/rotate-keys.sh
* internal/telemetry/otel.go

# SUMMARY

* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: Apache-2.0, CC-BY-SA-4.0
* Read errors: 0
* Files with copyright information: 214 / 216
* Files with license information: 214 / 216

Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(

$ reuse annotate --copyright="2026 Acme Corp" --license="Apache-2.0" \
      scripts/rotate-keys.sh internal/telemetry/otel.go
Successfully changed header of scripts/rotate-keys.sh
Successfully changed header of internal/telemetry/otel.go

$ reuse lint && echo "REUSE OK"
...
Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)
REUSE OK
```

---

## 3. SBOM formats

### 3.1 Format comparison

| | **SPDX** | **CycloneDX** | **SWID** |
|---|---|---|---|
| Steward | Linux Foundation / SPDX project | OWASP Foundation | ISO/IEC 19770-2:2015 |
| Standard | **ISO/IEC 5962:2021** (SPDX 2.2.1) | **ECMA-424** (CycloneDX 1.6) | ISO/IEC |
| Current versions | 2.3 (JSON/tag-value/RDF/YAML/xlsx), 3.0 (JSON-LD) | 1.5 / 1.6 (JSON, XML, Protobuf) | XML tags |
| Origin bias | Licence compliance first | Security / supply chain first | Asset management |
| Licence expression model | Rich: `licenseConcluded` vs `licenseDeclared`, `hasExtractedLicensingInfos` | `licenses[]` with `expression` or `id`/`name` | limited |
| Dependency graph | `relationships[]` — 40+ typed relationships | `dependencies[]` — `dependsOn` / `provides` | ❌ |
| Vulnerabilities inside the BOM | ❌ (separate SPDX security profile in 3.0) | ✅ `vulnerabilities[]` since 1.4 | ❌ |
| VEX | external (OpenVEX / CSAF) | ✅ native VEX profile | ❌ |
| Service inventory | ❌ | ✅ `services[]` | ❌ |
| Formulation / build provenance | partial | ✅ `formulation` (1.5+) | ❌ |
| Crypto assets (CBOM) | ❌ | ✅ 1.6 | ❌ |
| ML models (MLBOM) | partial | ✅ 1.5 `modelCard` | ❌ |
| Attestations / claims | ❌ | ✅ 1.6 `declarations` | ❌ |
| Typical size (500-pkg image) | ~1.4 MB JSON | ~600 KB JSON | n/a |
| Best fit | legal/OSPO, government (NTIA minimum elements) | security tooling, Dependency-Track | endpoint asset inventory |

**Decision:** emit **both**. `syft` produces both from one catalog pass at essentially zero marginal cost, and the consumers differ — Dependency-Track and Trivy prefer CycloneDX; procurement, US federal (EO 14028) and EU CRA workflows prefer SPDX.

### 3.2 The NTIA minimum elements (what a compliant SBOM must contain)

| Element | SPDX 2.3 field | CycloneDX 1.6 field |
|---|---|---|
| Supplier name | `packages[].supplier` | `components[].supplier.name` |
| Component name | `packages[].name` | `components[].name` |
| Version of the component | `packages[].versionInfo` | `components[].version` |
| Other unique identifiers | `packages[].externalRefs` (purl, cpe23Type) | `components[].purl`, `.cpe`, `.bom-ref` |
| Dependency relationship | `relationships[]` | `dependencies[]` |
| Author of SBOM data | `creationInfo.creators` | `metadata.tools`, `metadata.authors` |
| Timestamp | `creationInfo.created` | `metadata.timestamp` |

### 3.3 Package URL (purl) — the join key of the entire ecosystem

```
pkg:type/namespace/name@version?qualifiers#subpath
```

| purl | Layer |
|---|---|
| `pkg:golang/github.com/gorilla/mux@v1.8.1` | Go module |
| `pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1` | Maven |
| `pkg:npm/%40acme/telemetry@3.2.0` | npm scoped (`@` is percent-encoded) |
| `pkg:pypi/urllib3@2.2.1` | PyPI |
| `pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12` | Debian package |
| `pkg:apk/alpine/busybox@1.36.1-r29?arch=x86_64&distro=alpine-3.20` | Alpine package |
| `pkg:oci/payments-api@sha256:9f2b…?repository_url=ghcr.io/acme/payments-api&tag=1.24.3` | the image itself |
| `pkg:generic/openssl@3.0.15?download_url=https://…&checksum=sha256:…` | vendored tarball |

**CPE** (`cpe:2.3:a:apache:log4j:2.14.1:*:*:*:*:*:*:*`) is the NVD's identifier. It is lossy, ambiguously assigned, and frequently absent — but NVD-sourced matching requires it. This is the root cause of a whole class of false negatives (§8.6).

### 3.4 A real SPDX 2.3 document (abridged to two packages, structurally complete)

```json
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "ghcr.io/acme/payments-api:1.24.3",
  "documentNamespace": "https://acme.example/spdx/payments-api-1.24.3-4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10",
  "creationInfo": {
    "created": "2026-09-03T09:14:22Z",
    "creators": [
      "Tool: syft-1.29.0",
      "Organization: Acme Corp",
      "Person: Acme Platform Team (platform@acme.example)"
    ],
    "licenseListVersion": "3.25"
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-golang-github.com-gorilla-mux-1b3f0c9d2a44e517",
      "name": "github.com/gorilla/mux",
      "versionInfo": "v1.8.1",
      "supplier": "NOASSERTION",
      "downloadLocation": "https://proxy.golang.org/github.com/gorilla/mux/@v/v1.8.1.zip",
      "filesAnalyzed": false,
      "licenseConcluded": "BSD-3-Clause",
      "licenseDeclared": "BSD-3-Clause",
      "copyrightText": "NOASSERTION",
      "checksums": [
        { "algorithm": "SHA256",
          "checksumValue": "9dc7f6d21e4d1b9ce8e1a1e4a4a0f9a0a3c5f9e2b7c1d0a8f3e6b4c2d1a0f9e8" }
      ],
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:golang/github.com/gorilla/mux@v1.8.1" }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-deb-libssl3-7ad2e91c4b60fa38",
      "name": "libssl3",
      "versionInfo": "3.0.15-1~deb12u1",
      "supplier": "Organization: Debian OpenSSL Team <pkg-openssl-devel@lists.alioth.debian.org>",
      "originator": "Organization: Debian",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "NOASSERTION",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "NOASSERTION",
      "sourceInfo": "acquired package info from DPKG DB: /var/lib/dpkg/status.d/libssl3",
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12" },
        { "referenceCategory": "SECURITY",
          "referenceType": "cpe23Type",
          "referenceLocator": "cpe:2.3:a:openssl:openssl:3.0.15-1~deb12u1:*:*:*:*:*:*:*" }
      ]
    }
  ],
  "relationships": [
    { "spdxElementId": "SPDXRef-DOCUMENT",
      "relationshipType": "DESCRIBES",
      "relatedSpdxElement": "SPDXRef-Package-oci-payments-api" },
    { "spdxElementId": "SPDXRef-Package-oci-payments-api",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": "SPDXRef-Package-golang-github.com-gorilla-mux-1b3f0c9d2a44e517" },
    { "spdxElementId": "SPDXRef-Package-oci-payments-api",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": "SPDXRef-Package-deb-libssl3-7ad2e91c4b60fa38" }
  ],
  "hasExtractedLicensingInfos": [
    { "licenseId": "LicenseRef-Acme-Internal",
      "extractedText": "Copyright 2026 Acme Corp. Internal use only. Redistribution prohibited.",
      "name": "Acme Internal Licence" }
  ]
}
```

### 3.5 The same inventory as CycloneDX 1.6

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10",
  "version": 1,
  "metadata": {
    "timestamp": "2026-09-03T09:14:22Z",
    "lifecycles": [ { "phase": "build" } ],
    "tools": {
      "components": [
        { "type": "application", "author": "anchore", "name": "syft", "version": "1.29.0" }
      ]
    },
    "authors": [ { "name": "Acme Platform Team", "email": "platform@acme.example" } ],
    "supplier": { "name": "Acme Corp", "url": [ "https://acme.example" ] },
    "component": {
      "bom-ref": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e",
      "type": "container",
      "name": "ghcr.io/acme/payments-api",
      "version": "1.24.3",
      "purl": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
      "hashes": [
        { "alg": "SHA-256",
          "content": "9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e" }
      ],
      "licenses": [ { "license": { "id": "Apache-2.0" } } ]
    }
  },
  "components": [
    {
      "bom-ref": "pkg:golang/github.com/gorilla/mux@v1.8.1",
      "type": "library",
      "name": "github.com/gorilla/mux",
      "version": "v1.8.1",
      "scope": "required",
      "purl": "pkg:golang/github.com/gorilla/mux@v1.8.1",
      "licenses": [ { "license": { "id": "BSD-3-Clause" } } ],
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/gorilla/mux" }
      ]
    },
    {
      "bom-ref": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
      "type": "library",
      "group": "org.apache.logging.log4j",
      "name": "log4j-core",
      "version": "2.14.1",
      "scope": "required",
      "purl": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
      "licenses": [ { "expression": "Apache-2.0" } ]
    },
    {
      "bom-ref": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12",
      "type": "library",
      "name": "libssl3",
      "version": "3.0.15-1~deb12u1",
      "purl": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12",
      "cpe": "cpe:2.3:a:openssl:openssl:3.0.15:*:*:*:*:*:*:*",
      "licenses": [ { "license": { "id": "Apache-2.0" } } ]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e",
      "dependsOn": [
        "pkg:golang/github.com/gorilla/mux@v1.8.1",
        "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
        "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12"
      ]
    },
    { "ref": "pkg:golang/github.com/gorilla/mux@v1.8.1", "dependsOn": [] }
  ],
  "compositions": [
    {
      "aggregate": "complete",
      "bom-ref": "composition-os-layer",
      "assemblies": [
        "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
      ]
    }
  ]
}
```

> `compositions[].aggregate` is the honesty field: `complete`, `incomplete`, `incomplete_first_party_only`, `incomplete_third_party_only`, `unknown`, `not_specified`. An SBOM that omits it silently claims completeness it cannot prove.

---

## 4. The tooling landscape

### 4.1 Comparison

| Tool | Primary job | Input | Output | Licence detection | Vuln DB | Offline mode | Where it belongs |
|---|---|---|---|---|---|---|---|
| **syft** | SBOM generation | image, dir, archive, OCI layout | SPDX 2.3/3.0, CycloneDX 1.x, syft-json, table | declared only, package-metadata level | ❌ | ✅ | build stage |
| **grype** | vuln matching | SBOM, image, dir | table, JSON, SARIF, CycloneDX | ❌ | GitHub/NVD/distro feeds, local DB | ✅ `grype db import` | gate stage |
| **trivy** | all-in-one scanner | image, fs, repo, SBOM, K8s, IaC | table, JSON, SARIF, SPDX, CycloneDX, GitHub | ✅ classified (forbidden…unknown) | own DB via OCI | ✅ `--skip-db-update` + mirror | gate + cluster |
| **osv-scanner** | lockfile/source vuln matching | lockfiles, dirs, SBOM, image, Debian/Alpine | table, JSON, SARIF, markdown | ✅ (v2, licence summary) | OSV.dev | ✅ `--offline-vulnerabilities` | pre-commit, PR check |
| **cdxgen** | build-aware SBOM | 30+ ecosystems, build-system aware | CycloneDX | declared | via depscan | ⚠️ | build stage (JVM/Node) |
| **scancode-toolkit** | file-level licence/copyright forensics | source tree | JSON, SPDX, CSV | ✅ **text matching**, ~2000 detections | ❌ | ✅ | OSPO deep review |
| **ORT** | full compliance pipeline | source + package managers | evaluated results, SPDX, notices | ✅ + curations + policy rules | via advisors | ⚠️ | OSPO / release gate |
| **FOSSology** | licence review workflow | uploads | reports, SPDX | ✅ + human curation | ❌ | ✅ | legal review |
| **Dependency-Track** | continuous SBOM analysis platform | CycloneDX (SPDX via convert) | UI, REST, policy violations | ✅ policy | OSV, NVD, GitHub, VulnDB | ✅ mirrored feeds | central platform |
| **Renovate / Dependabot** | dependency updating | lockfiles | PRs | ⚠️ | advisories | ❌ | repository automation |
| **cosign** | signing & attestation | artifacts, predicates | DSSE / Sigstore bundles | ❌ | ❌ | ✅ with keys | release stage |
| **OpenSSF Scorecard** | upstream project health | repo URL | JSON, table | ❌ | ❌ | ❌ | dependency intake review |

### 4.2 Generating SBOMs with syft

```bash
$ syft version
Application:        syft
Version:            1.29.0
BuildDate:          2026-08-14T11:02:41Z
GitCommit:          8f3a1c4d7b09e2a6f5c8d1b4e7a0c3f6d9b2e5a8
Platform:           linux/amd64
GoVersion:          go1.23.6

$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 \
        -o spdx-json=sbom.spdx.json \
        -o cyclonedx-json=sbom.cdx.json \
        -o table
 ✔ Pulled image
 ✔ Loaded image                                       ghcr.io/acme/payments-api:1.24.3
 ✔ Parsed image                sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
 ✔ Cataloged contents          sha256:1a4dcbf29e0d7c6b5a83f210e4d97c6b8a5f3e1d0c9b7a6f4e2d1c0b9a8f7e6d
   ├── ✔ Packages                        [312 packages]
   ├── ✔ Executables                     [41 executables]
   ├── ✔ File metadata                   [2184 locations]
   └── ✔ File digests                    [2184 files]
NAME                        VERSION                TYPE
base-files                  12.4+deb12u7           deb
ca-certificates             20230311               deb
github.com/gorilla/mux      v1.8.1                 go-module
libc6                       2.36-9+deb12u8         deb
libssl3                     3.0.15-1~deb12u1       deb
log4j-core                  2.14.1                 java-archive
payments-api                1.24.3                 go-module
...

$ jq '.packages | length' sbom.spdx.json
312
$ jq -r '.creationInfo.created, .documentNamespace' sbom.spdx.json
2026-09-03T09:14:22Z
https://anchore.com/syft/image/ghcr.io/acme/payments-api-1.24.3-4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10
```

Pin the catalogue behaviour so SBOMs are reproducible across runs:

```yaml
# .syft.yaml
output:
  - "spdx-json=sbom.spdx.json"
  - "cyclonedx-json=sbom.cdx.json"
quiet: false
check-for-app-update: false

# Deterministic output: no timestamps that change between identical builds.
format:
  pretty: true
  spdx-json:
    deterministic-uuid: true
  cyclonedx-json:
    deterministic-uuid: true

# Explicitly select catalogers. Relying on the default set means a syft
# upgrade can silently change the component count of "the same" image.
select-catalogers:
  - "image"          # default image set: OS package DBs + binaries
  - "+sbom-cataloger" # ingest SBOMs already embedded in the image

package:
  search-unindexed-archives: true   # look inside nested JAR/WAR/EAR
  search-indexed-archives: true
  exclude-binary-overlap-by-ownership: true

file:
  metadata:
    selection: owned-by-package
    digests: ["sha256"]
  executable:
    cataloger:
      enabled: true

exclude:
  - "./proc/**"
  - "./sys/**"
  - "**/test/fixtures/**"

source:
  name: "payments-api"
  version: "1.24.3"
```

### 4.3 Vulnerability matching with grype (SBOM in, decision out)

```bash
$ grype db status
Location:  /home/build/.cache/grype/db/6
Built:     2026-09-03T02:11:07Z
Schema:    6
Checksum:  sha256:c2e8a1f9d0b73c46a5f28e9d1b0c7a63f5e4d2c1b0a9f8e7d6c5b4a3928170f6
Status:    valid

$ grype sbom:./sbom.cdx.json --fail-on high --by-cve -o table
 ✔ Scanned for vulnerabilities     [37 vulnerability matches]
   ├── by severity: 2 critical, 6 high, 18 medium, 9 low, 2 negligible
   └── by status:   21 fixed, 16 not-fixed
NAME        INSTALLED         FIXED-IN    TYPE           VULNERABILITY   SEVERITY
libssl3     3.0.15-1~deb12u1  (won't fix) deb            CVE-2024-13176  Medium
log4j-core  2.14.1            2.15.0      java-archive   CVE-2021-44228  Critical
log4j-core  2.14.1            2.16.0      java-archive   CVE-2021-45046  Critical
log4j-core  2.14.1            2.17.0      java-archive   CVE-2021-45105  High
zlib1g      1:1.2.13.dfsg-1   (won't fix) deb            CVE-2023-45853  High
...
1 error occurred:
	* discovered vulnerabilities at or above the severity threshold: high

$ echo $?
1
```

The gate is `--fail-on high` plus a **triage file** rather than a blanket ignore:

```yaml
# .grype.yaml
check-for-app-update: false
fail-on-severity: high
only-fixed: false          # NEVER true on a gate: hides unfixed criticals
add-cpes-if-none: true     # generate CPEs for language packages lacking them
by-cve: true               # normalise GHSA/ELSA/DSA to CVE for dedup

db:
  auto-update: true
  validate-age: true
  max-allowed-built-age: 120h   # fail if the DB is older than 5 days

# Every ignore MUST carry an expiry and a reason. Unbounded ignores are
# how a "temporary" exception becomes permanent technical debt.
ignore:
  - vulnerability: CVE-2023-45853
    package:
      name: zlib1g
      type: deb
    # zlib MiniZip only; we never call minizip. Debian marks it won't-fix.
    # Re-review: 2026-12-01
  - vulnerability: GHSA-jfh8-c2jp-5v3q
    reason: "superseded by CVE mapping, deduplicated via by-cve"

exclude:
  - "/usr/share/doc/**"

registry:
  auth:
    - authority: ghcr.io
      username: ${GHCR_USER}
      password: ${GHCR_TOKEN}
```

### 4.4 Trivy: vulnerabilities, licences, secrets and misconfigurations in one pass

```bash
$ trivy image --scanners vuln,license,secret \
        --license-full \
        --severity HIGH,CRITICAL \
        --exit-code 1 \
        --format table \
        ghcr.io/acme/payments-api:1.24.3
2026-09-03T09:20:11Z    INFO    Vulnerability scanning is enabled
2026-09-03T09:20:11Z    INFO    Secret scanning is enabled
2026-09-03T09:20:11Z    INFO    License scanning is enabled
2026-09-03T09:20:14Z    INFO    Detected OS  family="debian" version="12.8"
2026-09-03T09:20:14Z    INFO    [debian] Detecting vulnerabilities...  os_version="12" pkg_num=118
2026-09-03T09:20:15Z    INFO    Number of language-specific files  num=2
2026-09-03T09:20:15Z    INFO    [gobinary] Detecting vulnerabilities...
2026-09-03T09:20:15Z    INFO    [jar] Detecting vulnerabilities...

ghcr.io/acme/payments-api:1.24.3 (debian 12.8)
==============================================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌──────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│ Library  │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ zlib1g   │ CVE-2023-45853 │ CRITICAL │ will_  │ 1:1.2.13.dfsg-1   │               │
│          │                │          │ not_fix│                   │               │
└──────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

Java (jar)
==========
Total: 3 (HIGH: 1, CRITICAL: 2)

┌────────────────────────────────┬────────────────┬──────────┬───────────────────┬───────────────┐
│            Library             │ Vulnerability  │ Severity │ Installed Version │ Fixed Version │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│ org.apache.logging.log4j:      │ CVE-2021-44228 │ CRITICAL │ 2.14.1            │ 2.15.0        │
│ log4j-core                     │                │          │                   │               │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│                                │ CVE-2021-45046 │ CRITICAL │                   │ 2.16.0        │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│                                │ CVE-2021-45105 │ HIGH     │                   │ 2.17.0        │
└────────────────────────────────┴────────────────┴──────────┴───────────────────┴───────────────┘

ghcr.io/acme/payments-api:1.24.3 (debian 12.8)
==============================================
Total: 4 (HIGH: 1, CRITICAL: 0)

┌──────────────┬─────────────────┬──────────┬──────────────────────────────────────────┐
│ Classification│    Severity    │ Licence  │                   Path                   │
├──────────────┼─────────────────┼──────────┼──────────────────────────────────────────┤
│ Restricted   │ HIGH            │ GPL-3.0  │ /usr/share/licenses/os/coreutils.copyright│
├──────────────┼─────────────────┼──────────┼──────────────────────────────────────────┤
│ Reciprocal   │ MEDIUM          │ MPL-2.0  │ /usr/share/licenses/go/…/mozilla-cert.txt │
└──────────────┴─────────────────┴──────────┴──────────────────────────────────────────┘

$ echo $?
1
```

Trivy classifies licences using Google's category model. Encode the policy in `trivy.yaml` rather than in shell:

```yaml
# trivy.yaml
scan:
  scanners:
    - vuln
    - license
    - secret
  skip-dirs:
    - /usr/share/doc
    - /var/lib/apt

severity:
  - HIGH
  - CRITICAL

vulnerability:
  ignore-unfixed: false      # do NOT hide won't-fix; triage them via VEX

license:
  full: true
  # Categories: forbidden > restricted > reciprocal > notice > permissive
  #             > unencumbered > unknown
  forbidden:
    - AGPL-1.0
    - AGPL-3.0
    - SSPL-1.0
    - BUSL-1.1
    - Elastic-2.0
    - CC-BY-NC-4.0
  restricted:
    - GPL-2.0-only
    - GPL-3.0-only
    - LGPL-3.0-only
  reciprocal:
    - MPL-2.0
    - EPL-2.0
    - CDDL-1.0
  notice:
    - Apache-2.0
    - MIT
    - BSD-3-Clause
    - ISC
  ignored:
    # Classpath Exception removes the copyleft reach across the linking
    # boundary; a substring match on "GPL" would wrongly block every JRE.
    - GPL-2.0-only WITH Classpath-exception-2.0
    - GPL-3.0-or-later WITH GCC-exception-3.1

db:
  # Mirror the DB internally: ghcr.io anonymous pulls are rate-limited and
  # will break your pipeline at the worst possible moment.
  repository: registry.internal.acme.example/mirror/trivy-db:2
  java-repository: registry.internal.acme.example/mirror/trivy-java-db:1
  skip-update: false

cache:
  dir: /var/cache/trivy

exit-code: 1
```

### 4.5 osv-scanner: the cheap pre-commit / PR gate

```bash
$ osv-scanner scan source --recursive --licenses="MIT,Apache-2.0,BSD-3-Clause,ISC,BSD-2-Clause" .
Scanned /src/go.mod file and found 84 packages
Scanned /src/web/package-lock.json file and found 1204 packages
Scanned /src/requirements.txt file and found 31 packages

╭─────────────────────────────────────┬──────┬───────────┬─────────────────────┬─────────┬──────────────────╮
│ OSV URL                             │ CVSS │ ECOSYSTEM │ PACKAGE             │ VERSION │ SOURCE           │
├─────────────────────────────────────┼──────┼───────────┼─────────────────────┼─────────┼──────────────────┤
│ https://osv.dev/GHSA-m425-mq94-257g │ 7.5  │ Go        │ google.golang.org/  │ 1.58.2  │ go.mod           │
│                                     │      │           │ grpc                │         │                  │
│ https://osv.dev/GHSA-w596-4wvx-j9j6 │ 9.8  │ PyPI      │ pyyaml              │ 5.3.1   │ requirements.txt │
╰─────────────────────────────────────┴──────┴───────────┴─────────────────────┴─────────┴──────────────────╯

License violations found:
╭───────────┬──────────────────────────┬─────────┬──────────────────╮
│ ECOSYSTEM │ PACKAGE                  │ LICENSE │ SOURCE           │
├───────────┼──────────────────────────┼─────────┼──────────────────┤
│ npm       │ @acme/legacy-charting    │ GPL-3.0 │ package-lock.json│
╰───────────┴──────────────────────────┴─────────┴──────────────────╯

$ echo $?
1
```

### 4.6 Deep licence forensics with ScanCode

`syft` and `trivy` read *declared* metadata. Only a text-matching scanner tells you that `vendor/thirdparty/base64.c` carries a GPL header inside an otherwise-MIT repository.

```bash
$ scancode --license --copyright --package --info --license-text \
           --processes 8 --timeout 120 \
           --json-pp scancode.json \
           --spdx-rdf scancode.spdx.rdf \
           ./src
Setup plugins...
Collect file inventory...
Scan files for: info, licenses, copyrights, packages with 8 process(es)...
[####################] 2184
Scanning done.
Summary:        info, licenses, copyrights, packages with 8 process(es)
Errors count:   0
Scan Speed:     41.32 files/sec
Initial counts: 2184 resource(s): 1976 file(s) and 208 directorie(s)
Final counts:   2184 resource(s): 1976 file(s) and 208 directorie(s)
Timings:
  scan_start: 2026-09-03T09:31:02.114
  scan_end:   2026-09-03T09:31:50.882

$ jq -r '
    [ .files[]
      | select(.detected_license_expression != null)
      | .detected_license_expression ]
    | group_by(.) | map({licence: .[0], files: length})
    | sort_by(-.files) | .[] | "\(.files)\t\(.licence)"
  ' scancode.json
1421	apache-2.0
318	mit
92	bsd-new
14	mpl-2.0
3	gpl-2.0            <-- not declared anywhere in go.mod / package.json
1	unknown-license-reference

$ jq -r '.files[] | select(.detected_license_expression=="gpl-2.0") | .path' scancode.json
src/vendor/thirdparty/base64.c
src/vendor/thirdparty/crc32.c
src/vendor/thirdparty/README
```

That is the finding a metadata-only SBOM will never produce.

---

## 5. VEX: why "1,437 vulnerabilities" is not an answer

A raw scan of a realistic image returns hundreds of matches. Most are irrelevant: the vulnerable code path is not compiled in, not reachable, or already mitigated. Handing that list to a delivery team teaches them to ignore scanners — the worst possible outcome.

**VEX (Vulnerability Exploitability eXchange)** is the machine-readable assertion, made by the supplier, of whether a *known* vulnerability actually affects a *specific* product.

### 5.1 VEX formats

| | **OpenVEX** | **CSAF 2.0 VEX profile** | **CycloneDX VEX** |
|---|---|---|---|
| Steward | OpenVEX / OpenSSF community | OASIS | OWASP |
| Encoding | small standalone JSON-LD | large JSON, full advisory model | inside/alongside a CycloneDX BOM |
| Product identity | purl / any IRI in `products[].@id` | CSAF product tree + `product_identification_helper` | `bom-ref` / purl |
| Statuses | `not_affected`, `affected`, `fixed`, `under_investigation` | `known_not_affected`, `known_affected`, `fixed`, `first_fixed`, `under_investigation`, `recommended` | `not_affected`, `exploitable`, `in_triage`, `resolved`, `false_positive` … |
| Justifications | 5 machine-readable values | 5 flag labels (same semantics) | `analysis.justification` |
| Best fit | attach per-artifact in CI | vendor PSIRT publishing at scale | teams already all-in on CycloneDX |

### 5.2 The five `not_affected` justifications (identical across OpenVEX and CSAF)

| Justification | Meaning | Typical evidence |
|---|---|---|
| `component_not_present` | the component was never in the artifact | SBOM diff, false-positive match |
| `vulnerable_code_not_present` | component present, vulnerable function/file removed or never built | build flags, `nm`/`objdump` |
| `vulnerable_code_not_in_execute_path` | present and built, but unreachable from any entrypoint | call-graph / reachability analysis |
| `vulnerable_code_cannot_be_controlled_by_adversary` | reachable, but the attacker cannot influence the input | threat model, input validation |
| `inline_mitigations_already_exist` | reachable and controllable, but a compensating control blocks it | WAF rule, seccomp profile, NetworkPolicy |

### 5.3 A real OpenVEX document

```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://acme.example/vex/payments-api/2026-09-03-001",
  "author": "Acme Product Security <psirt@acme.example>",
  "role": "Document Creator",
  "timestamp": "2026-09-03T10:02:00Z",
  "last_updated": "2026-09-03T10:02:00Z",
  "version": 1,
  "tooling": "vexctl/0.4.0",
  "statements": [
    {
      "vulnerability": {
        "@id": "https://nvd.nist.gov/vuln/detail/CVE-2023-45853",
        "name": "CVE-2023-45853",
        "description": "zlib MiniZip integer overflow in zipOpenNewFileInZip4_64"
      },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        {
          "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
          "identifiers": {
            "purl": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api"
          },
          "subcomponents": [
            { "@id": "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12" }
          ]
        }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_present",
      "impact_statement": "The overflow is in MiniZip (contrib/minizip), which Debian does not build into libz.so.1. Verified with `nm -D /lib/x86_64-linux-gnu/libz.so.1 | grep -c zipOpenNewFileInZip4_64` => 0."
    },
    {
      "vulnerability": { "name": "CVE-2021-44228" },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        { "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
          "subcomponents": [
            { "@id": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1" }
          ]
        }
      ],
      "status": "affected",
      "action_statement": "Upgrade log4j-core to >= 2.17.1. Interim mitigation: JVM flag -Dlog4j2.formatMsgNoLookups=true is set in the container ENTRYPOINT.",
      "action_statement_timestamp": "2026-09-03T10:02:00Z"
    },
    {
      "vulnerability": { "name": "CVE-2024-13176" },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        { "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api" }
      ],
      "status": "under_investigation"
    }
  ]
}
```

### 5.4 Producing and consuming VEX

```bash
$ vexctl create \
    --author "Acme Product Security <psirt@acme.example>" \
    --product "pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io%2Facme%2Fpayments-api" \
    --subcomponents "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12" \
    --vuln "CVE-2023-45853" \
    --status "not_affected" \
    --justification "vulnerable_code_not_present" \
    --file payments-api.openvex.json
{ … }

# Attach VEX to the image as an in-toto attestation
$ vexctl attest --attach --sign payments-api.openvex.json \
    ghcr.io/acme/payments-api@sha256:9f2b3c…

# Consume it: grype re-scans and the suppressed finding disappears
$ grype sbom:./sbom.cdx.json --vex payments-api.openvex.json --show-suppressed -o table
 ✔ Scanned for vulnerabilities     [37 vulnerability matches]
   ├── by severity: 2 critical, 5 high, 18 medium, 9 low, 2 negligible (1 suppressed)
   └── by status:   21 fixed, 16 not-fixed
NAME        INSTALLED         FIXED-IN  TYPE          VULNERABILITY   SEVERITY
log4j-core  2.14.1            2.15.0    java-archive  CVE-2021-44228  Critical
zlib1g      1:1.2.13.dfsg-1             deb           CVE-2023-45853  High (suppressed by VEX)
…

# Trivy consumes the same document
$ trivy image --vex payments-api.openvex.json --show-suppressed \
        --severity HIGH,CRITICAL ghcr.io/acme/payments-api:1.24.3
2026-09-03T10:05:44Z    INFO    VEX filtering  file="payments-api.openvex.json"
2026-09-03T10:05:47Z    INFO    Suppressed vulnerability  vuln_id="CVE-2023-45853" status="not_affected" justification="vulnerable_code_not_present"
```

> **The invariant:** VEX suppresses at *report* time, never at *SBOM* time. The SBOM stays complete and truthful; VEX is a separate, separately-signed, separately-revisable assertion layered on top. Deleting a component from the SBOM to silence a scanner is falsifying the inventory.

---

## 6. Provenance and attestation: proving where the artifact came from

An SBOM asserts *what is inside*. It asserts nothing about *who produced it* or *whether it was tampered with*. That is the provenance layer.

### 6.1 SLSA v1.0 Build levels

| Level | Requirement | What it defeats | Cost |
|---|---|---|---|
| **L0** | nothing | — | — |
| **L1** | provenance exists and is distributed; build process documented & automated | accidental mystery-meat artifacts, "built on Jenkins' laptop" | low |
| **L2** | build runs on a **hosted** platform; provenance is **signed** by that platform, authenticated | forged provenance by an outsider; post-build tampering | medium |
| **L3** | build platform is **hardened**: builds are isolated, secret material is unforgeable by the build's own user-defined steps | a malicious build script exfiltrating the signing key and forging provenance | high |

SLSA v1.0 explicitly reorganised the earlier v0.1 four-level model into **tracks**; "Build L3" is not the same claim as "SLSA 3" from 2021 documentation.

### 6.2 in-toto attestation structure

Everything — SBOM, SLSA provenance, VEX, test results — is wrapped identically:

```
DSSE envelope
├── payloadType: "application/vnd.in-toto+json"
├── payload: base64( in-toto Statement )
│   └── Statement
│       ├── _type: "https://in-toto.io/Statement/v1"
│       ├── subject: [ { name, digest: { sha256: "…" } } ]   ← binds to the artifact
│       ├── predicateType: "https://slsa.dev/provenance/v1"  ← what kind of claim
│       └── predicate: { … }                                  ← the claim itself
└── signatures: [ { keyid, sig } ]
```

A SLSA v1.0 provenance predicate:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "ghcr.io/acme/payments-api",
      "digest": {
        "sha256": "9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      "externalParameters": {
        "workflow": {
          "ref": "refs/tags/v1.24.3",
          "repository": "https://github.com/acme/payments-api",
          "path": ".github/workflows/release.yml"
        },
        "inputs": { "push_image": true }
      },
      "internalParameters": {
        "github": {
          "event_name": "push",
          "repository_id": "487213904",
          "repository_owner_id": "10294851"
        }
      },
      "resolvedDependencies": [
        {
          "uri": "git+https://github.com/acme/payments-api@refs/tags/v1.24.3",
          "digest": { "gitCommit": "7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21" }
        },
        {
          "uri": "https://github.com/actions/checkout@v4",
          "digest": { "gitCommit": "11bd71901bbe5b1630ceea73d27597364c9af683" }
        }
      ]
    },
    "runDetails": {
      "builder": {
        "id": "https://github.com/actions/runner/github-hosted"
      },
      "metadata": {
        "invocationId": "https://github.com/acme/payments-api/actions/runs/9182736450/attempts/1",
        "startedOn": "2026-09-03T09:10:04Z",
        "finishedOn": "2026-09-03T09:16:52Z"
      }
    }
  }
}
```

### 6.3 Signing and attaching with cosign (keyless / Sigstore)

```bash
$ export IMAGE=ghcr.io/acme/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e

$ cosign sign --yes "$IMAGE"
Generating ephemeral keys...
Retrieving signed certificate...
        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.
Successfully verified SCT...
tlog entry created with index: 187436291
Pushing signature to: ghcr.io/acme/payments-api

$ cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$IMAGE"
Using payload from: sbom.spdx.json
Generating ephemeral keys...
Retrieving signed certificate...
Successfully verified SCT...
tlog entry created with index: 187436294
Pushing attestation to: ghcr.io/acme/payments-api

$ cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$IMAGE"
tlog entry created with index: 187436297

$ cosign attest --yes --type openvex --predicate payments-api.openvex.json "$IMAGE"
tlog entry created with index: 187436301
```

Verification — the step that actually matters:

```bash
$ cosign verify-attestation \
    --type spdxjson \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yml@refs/tags/v.+$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    "$IMAGE" > attestation.json

Verification for ghcr.io/acme/payments-api@sha256:9f2b3c… --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
Certificate subject: https://github.com/acme/payments-api/.github/workflows/release.yml@refs/tags/v1.24.3
Certificate issuer URL: https://token.actions.githubusercontent.com
GitHub Workflow Trigger: push
GitHub Workflow SHA: 7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
GitHub Workflow Name: release
GitHub Workflow Repository: acme/payments-api
GitHub Workflow Ref: refs/tags/v1.24.3

# Recover the SBOM from the verified attestation
$ jq -r '.payload' attestation.json | base64 -d \
  | jq -r '.predicate.packages | length'
312

# And confirm the attestation is bound to THIS digest, not another
$ jq -r '.payload' attestation.json | base64 -d | jq -r '.subject[].digest.sha256'
9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
```

> **Verification anti-pattern.** `cosign verify --certificate-identity-regexp '.*'` verifies that *somebody* signed the image — including an attacker with any valid OIDC identity on the public Sigstore instance. The identity regexp and the OIDC issuer are the entire security boundary. Anchor both ends of the regex (`^…$`).

### 6.4 Verifying SLSA provenance independently

```bash
$ slsa-verifier verify-image "$IMAGE" \
    --source-uri github.com/acme/payments-api \
    --source-tag v1.24.3
Verified build using builder "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.0.0" at commit 7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
PASSED: SLSA verification passed

# GitHub-native equivalent
$ gh attestation verify oci://ghcr.io/acme/payments-api:1.24.3 --owner acme
Loaded digest sha256:9f2b3c… for oci://ghcr.io/acme/payments-api:1.24.3
Loaded 1 attestation from GitHub API

The following policy criteria will be enforced:
- Predicate type must match:................ https://slsa.dev/provenance/v1
- Source Repository Owner URI must match:... https://github.com/acme
- Subject Alternative Name must match regex: (?i)^https://github.com/acme/
- OIDC Issuer must match:................... https://token.actions.githubusercontent.com

✓ Verification succeeded!
```

---

## 7. Complete production implementation

### 7.1 GitHub Actions: build → SBOM → gate → sign → attest → publish

```yaml
# .github/workflows/release.yml
name: release

on:
  push:
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      push_image:
        description: "Push the image to the registry"
        type: boolean
        default: true

permissions:
  contents: read

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  COSIGN_VERSION: v2.4.1
  SYFT_VERSION: v1.29.0
  GRYPE_VERSION: v0.87.0

jobs:
  license-compliance:
    name: Licence compliance (REUSE + source scan)
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: REUSE compliance
        uses: fsfe/reuse-action@v5

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install osv-scanner
        run: |
          set -euo pipefail
          curl -sSfL -o /usr/local/bin/osv-scanner \
            https://github.com/google/osv-scanner/releases/download/v2.0.2/osv-scanner_linux_amd64
          chmod +x /usr/local/bin/osv-scanner
          osv-scanner --version

      - name: Licence allow-list over resolved dependencies
        run: |
          set -euo pipefail
          osv-scanner scan source --recursive \
            --licenses="MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0,Unlicense,CC0-1.0,Zlib,PostgreSQL,Python-2.0,BSL-1.0" \
            --format=json --output=osv-licences.json . || RC=$?
          echo "osv-scanner exit code: ${RC:-0}"
          jq -r '
            .results[]?.packages[]?
            | select(.licenses != null)
            | [ .package.name, .package.version, (.licenses | join(" OR ")) ]
            | @tsv
          ' osv-licences.json | sort -u | head -50
          exit "${RC:-0}"

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: licence-report
          path: osv-licences.json
          retention-days: 90

  build:
    name: Build, scan, sign and attest
    needs: license-compliance
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write        # push to GHCR
      id-token: write        # OIDC token for keyless signing
      attestations: write    # GitHub attestation store
      security-events: write # SARIF upload
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      image: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3
        with:
          driver-opts: image=moby/buildkit:v0.19.0

      - name: Log in to registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Derive image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,format=long
          labels: |
            org.opencontainers.image.licenses=Apache-2.0
            org.opencontainers.image.vendor=Acme Corp
            org.opencontainers.image.source=https://github.com/${{ github.repository }}

      - name: Build and push (digest-pinned)
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' || inputs.push_image }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: mode=max      # BuildKit-native SLSA provenance
          sbom: true                # BuildKit-native SBOM attestation
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: |
            VERSION=${{ github.ref_name }}

      - name: Install syft
        uses: anchore/sbom-action/download-syft@v0
        with:
          syft-version: ${{ env.SYFT_VERSION }}

      - name: Generate SBOMs (SPDX + CycloneDX) from the pushed digest
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          syft scan "registry:${IMAGE_REF}" \
            -o "spdx-json=sbom.spdx.json" \
            -o "cyclonedx-json=sbom.cdx.json"
          echo "SPDX packages:       $(jq '.packages | length' sbom.spdx.json)"
          echo "CycloneDX components:$(jq '.components | length' sbom.cdx.json)"
          # Non-empty SBOM is a hard requirement: an empty one silently
          # turns every downstream scan into a green build.
          test "$(jq '.packages | length' sbom.spdx.json)" -gt 10

      - name: Install grype
        uses: anchore/scan-action/download-grype@v6
        with:
          grype-version: ${{ env.GRYPE_VERSION }}

      - name: Vulnerability gate (SBOM in, no re-pull)
        run: |
          set -euo pipefail
          grype "sbom:./sbom.cdx.json" \
            --config .grype.yaml \
            --vex ./vex/payments-api.openvex.json \
            --output "sarif=grype.sarif" \
            --output "json=grype.json" \
            --output "table" \
            --fail-on high

      - name: Upload SARIF to code scanning
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: grype.sarif
          category: grype-container

      - name: Install cosign
        uses: sigstore/cosign-installer@v3
        with:
          cosign-release: ${{ env.COSIGN_VERSION }}

      - name: Sign image and attach attestations (keyless)
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          cosign sign   --yes "${IMAGE_REF}"
          cosign attest --yes --type spdxjson  --predicate sbom.spdx.json "${IMAGE_REF}"
          cosign attest --yes --type cyclonedx --predicate sbom.cdx.json  "${IMAGE_REF}"
          cosign attest --yes --type openvex   --predicate ./vex/payments-api.openvex.json "${IMAGE_REF}"

      - name: GitHub-native build provenance
        uses: actions/attest-build-provenance@v2
        with:
          subject-name: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          subject-digest: ${{ steps.build.outputs.digest }}
          push-to-registry: true

      - name: Verify what we just published (fail closed)
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          cosign verify \
            --certificate-identity-regexp "^https://github\.com/${{ github.repository }}/\.github/workflows/release\.yml@refs/tags/v.+$" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            "${IMAGE_REF}"
          cosign verify-attestation --type spdxjson \
            --certificate-identity-regexp "^https://github\.com/${{ github.repository }}/\.github/workflows/release\.yml@refs/tags/v.+$" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            "${IMAGE_REF}" > /dev/null
          echo "publish-time verification OK"

      - name: Publish SBOM to Dependency-Track
        env:
          DT_URL:     ${{ secrets.DEPENDENCY_TRACK_URL }}
          DT_API_KEY: ${{ secrets.DEPENDENCY_TRACK_API_KEY }}
        run: |
          set -euo pipefail
          HTTP=$(curl -sS -o dt-response.json -w '%{http_code}' \
            -X POST "${DT_URL}/api/v1/bom" \
            -H "X-Api-Key: ${DT_API_KEY}" \
            -F "autoCreate=true" \
            -F "projectName=${{ github.event.repository.name }}" \
            -F "projectVersion=${{ github.ref_name }}" \
            -F "bom=@sbom.cdx.json")
          echo "HTTP ${HTTP}"; cat dt-response.json
          test "${HTTP}" = "200"

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: sbom-and-scan
          path: |
            sbom.spdx.json
            sbom.cdx.json
            grype.json
            grype.sarif
          retention-days: 365   # SBOM retention must outlive the release
```

### 7.2 GitLab CI equivalent

```yaml
# .gitlab-ci.yml
stages: [compliance, build, sbom, scan, sign, publish]

variables:
  IMAGE: "$CI_REGISTRY_IMAGE"
  SYFT_VERSION: "v1.29.0"
  GRYPE_VERSION: "v0.87.0"
  COSIGN_VERSION: "v2.4.1"
  DOCKER_BUILDKIT: "1"

.oidc: &oidc
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore

reuse-lint:
  stage: compliance
  image: fsfe/reuse:latest
  script:
    - reuse lint

licence-allowlist:
  stage: compliance
  image: ghcr.io/google/osv-scanner:v2.0.2
  script:
    - |
      osv-scanner scan source --recursive \
        --licenses="MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0,Zlib,Unlicense,CC0-1.0" \
        --format=json --output=osv-licences.json .
  artifacts:
    when: always
    paths: [osv-licences.json]
    expire_in: 90 days

build-image:
  stage: build
  image: gcr.io/kaniko-project/executor:v1.23.2-debug
  script:
    - /kaniko/executor
        --context "${CI_PROJECT_DIR}"
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
        --destination "${IMAGE}:${CI_COMMIT_REF_SLUG}"
        --destination "${IMAGE}:${CI_COMMIT_SHA}"
        --digest-file /tmp/digest
        --reproducible
    - cp /tmp/digest digest.txt
  artifacts:
    paths: [digest.txt]

generate-sbom:
  stage: sbom
  image: anchore/syft:${SYFT_VERSION}
  script:
    - export DIGEST="$(cat digest.txt)"
    - syft scan "registry:${IMAGE}@${DIGEST}"
        -o spdx-json=sbom.spdx.json
        -o cyclonedx-json=sbom.cdx.json
    - test "$(grep -c '"SPDXID"' sbom.spdx.json)" -gt 10
  artifacts:
    paths: [sbom.spdx.json, sbom.cdx.json]
    reports:
      cyclonedx: sbom.cdx.json
    expire_in: 1 year

vuln-gate:
  stage: scan
  image: anchore/grype:${GRYPE_VERSION}
  script:
    - grype sbom:./sbom.cdx.json
        --config .grype.yaml
        --vex ./vex/payments-api.openvex.json
        -o table -o "json=grype.json"
        --fail-on high
  artifacts:
    when: always
    paths: [grype.json]

sign-and-attest:
  stage: sign
  <<: *oidc
  image:
    name: gcr.io/projectsigstore/cosign:${COSIGN_VERSION}
    entrypoint: [""]
  script:
    - export DIGEST="$(cat digest.txt)"
    - echo "$CI_REGISTRY_PASSWORD" | cosign login "$CI_REGISTRY" -u "$CI_REGISTRY_USER" --password-stdin
    - cosign sign   --yes "${IMAGE}@${DIGEST}"
    - cosign attest --yes --type spdxjson  --predicate sbom.spdx.json "${IMAGE}@${DIGEST}"
    - cosign attest --yes --type cyclonedx --predicate sbom.cdx.json  "${IMAGE}@${DIGEST}"
    - cosign verify
        --certificate-identity-regexp "^${CI_SERVER_URL}/${CI_PROJECT_PATH}//.gitlab-ci.yml@refs/tags/v.+$"
        --certificate-oidc-issuer "${CI_SERVER_URL}"
        "${IMAGE}@${DIGEST}"

publish-sbom:
  stage: publish
  image: curlimages/curl:8.11.0
  script:
    - |
      curl -sSf -X POST "${DT_URL}/api/v1/bom" \
        -H "X-Api-Key: ${DT_API_KEY}" \
        -F "autoCreate=true" \
        -F "projectName=${CI_PROJECT_NAME}" \
        -F "projectVersion=${CI_COMMIT_REF_NAME}" \
        -F "bom=@sbom.cdx.json"
```

### 7.3 Dependency-Track on Kubernetes (complete manifests)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: supply-chain
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Secret
metadata:
  name: dtrack-db
  namespace: supply-chain
type: Opaque
stringData:
  # In production this is sourced from ExternalSecrets / Vault, never from git.
  POSTGRES_DB: dtrack
  POSTGRES_USER: dtrack
  POSTGRES_PASSWORD: "CHANGE-ME-VIA-EXTERNAL-SECRET"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dtrack-postgres-data
  namespace: supply-chain
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: dtrack-postgres
  namespace: supply-chain
spec:
  serviceName: dtrack-postgres
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-postgres }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-postgres }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: postgres
          image: postgres:16.6-alpine
          ports:
            - { name: postgres, containerPort: 5432 }
          envFrom:
            - secretRef: { name: dtrack-db }
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "dtrack", "-d", "dtrack"] }
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            exec: { command: ["pg_isready", "-U", "dtrack", "-d", "dtrack"] }
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 2Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: dtrack-postgres-data }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-postgres
  namespace: supply-chain
spec:
  clusterIP: None
  selector: { app.kubernetes.io/name: dtrack-postgres }
  ports:
    - { name: postgres, port: 5432, targetPort: 5432 }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dtrack-apiserver-data
  namespace: supply-chain
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi     # mirrored NVD/OSV/GitHub feeds live here
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
  labels: { app.kubernetes.io/name: dtrack-apiserver }
spec:
  replicas: 1                 # the API server is stateful (embedded index)
  strategy: { type: Recreate }
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-apiserver }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-apiserver }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: apiserver
          image: dependencytrack/apiserver:4.12.7
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: ALPINE_DATABASE_MODE
              value: external
            - name: ALPINE_DATABASE_URL
              value: jdbc:postgresql://dtrack-postgres.supply-chain.svc.cluster.local:5432/dtrack
            - name: ALPINE_DATABASE_DRIVER
              value: org.postgresql.Driver
            - name: ALPINE_DATABASE_USERNAME
              valueFrom: { secretKeyRef: { name: dtrack-db, key: POSTGRES_USER } }
            - name: ALPINE_DATABASE_PASSWORD
              valueFrom: { secretKeyRef: { name: dtrack-db, key: POSTGRES_PASSWORD } }
            - name: ALPINE_DATA_DIRECTORY
              value: /data
            - name: ALPINE_METRICS_ENABLED
              value: "true"
            - name: EXTRA_JAVA_OPTIONS
              value: "-Xms2g -Xmx6g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: tmp,  mountPath: /tmp }
          startupProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 15
            failureThreshold: 40    # first boot mirrors NVD: this is slow
          readinessProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 15
            timeoutSeconds: 5
          livenessProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          resources:
            requests: { cpu: "1",   memory: 4Gi }
            limits:   { cpu: "4",   memory: 8Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: dtrack-apiserver-data }
        - name: tmp
          emptyDir: { sizeLimit: 2Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
spec:
  selector: { app.kubernetes.io/name: dtrack-apiserver }
  ports:
    - { name: http, port: 8080, targetPort: http }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dtrack-frontend
  namespace: supply-chain
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-frontend }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-frontend }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: frontend
          image: dependencytrack/frontend:4.12.7
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: API_BASE_URL
              value: https://dtrack.acme.example
          volumeMounts:
            - { name: nginx-cache, mountPath: /var/cache/nginx }
            - { name: nginx-run,   mountPath: /var/run }
          readinessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m,  memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      volumes:
        - { name: nginx-cache, emptyDir: {} }
        - { name: nginx-run,   emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-frontend
  namespace: supply-chain
spec:
  selector: { app.kubernetes.io/name: dtrack-frontend }
  ports:
    - { name: http, port: 8080, targetPort: http }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dtrack
  namespace: supply-chain
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "64m"   # SBOMs are large
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [dtrack.acme.example]
      secretName: dtrack-tls
  rules:
    - host: dtrack.acme.example
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend: { service: { name: dtrack-apiserver, port: { number: 8080 } } }
          - path: /
            pathType: Prefix
            backend: { service: { name: dtrack-frontend, port: { number: 8080 } } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: dtrack-apiserver }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
        - podSelector:
            matchLabels: { app.kubernetes.io/name: dtrack-frontend }
      ports: [{ protocol: TCP, port: 8080 }]
  egress:
    - to:
        - podSelector:
            matchLabels: { app.kubernetes.io/name: dtrack-postgres }
      ports: [{ protocol: TCP, port: 5432 }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    # Egress to the internet is required to mirror NVD/OSV/GitHub advisories.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.169.254/32]
      ports: [{ protocol: TCP, port: 443 }]
```

### 7.4 Admission control: refuse images without a verified SBOM

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-sbom-and-provenance
  annotations:
    policies.kyverno.io/title: Require signed SBOM and SLSA provenance
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Every first-party image admitted to prod or staging must carry a
      Sigstore-signed SPDX attestation produced by a release workflow on a
      protected tag, and SLSA build provenance naming an approved builder.
spec:
  validationFailureAction: Enforce   # Kyverno >=1.11; on newer releases confirm
                                     # whether your CRD expects a per-rule field
  background: false                  # image verification needs registry access
  failurePolicy: Fail                # fail closed
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-first-party-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [prod, staging]
      # Exempt the supply-chain tooling itself to avoid a bootstrap deadlock.
      exclude:
        any:
          - resources:
              namespaces: [kube-system, supply-chain]
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          required: true
          mutateDigest: true      # rewrite tag -> digest; TOCTOU protection
          verifyDigest: true
          imageRegistryCredentials:
            secrets: [ghcr-pull]

          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false

          attestations:
            # ---- 1. A signed SPDX SBOM must exist and be well-formed -------
            - type: https://spdx.dev/Document
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor: { url: https://rekor.sigstore.dev }
              conditions:
                - all:
                    - key: "{{ spdxVersion }}"
                      operator: AnyIn
                      value: ["SPDX-2.2", "SPDX-2.3"]
                    # An "SBOM" with three packages is an empty SBOM.
                    - key: "{{ packages | length(@) }}"
                      operator: GreaterThan
                      value: 10
                    - key: "{{ creationInfo.creators }}"
                      operator: AnyIn
                      value: ["Organization: Acme Corp"]

            # ---- 2. SLSA provenance from an approved builder ---------------
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor: { url: https://rekor.sigstore.dev }
              conditions:
                - all:
                    - key: "{{ buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://actions.github.io/buildtypes/workflow/v1"
                    - key: "{{ runDetails.builder.id }}"
                      operator: AnyIn
                      value:
                        - "https://github.com/actions/runner/github-hosted"
                    - key: "{{ buildDefinition.externalParameters.workflow.repository }}"
                      operator: AnyIn
                      value:
                        - "https://github.com/acme/payments-api"
                        - "https://github.com/acme/ledger-api"
                        - "https://github.com/acme/notify-worker"
---
# Third-party images: no attestations available, so pin by digest instead.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: third-party-images-must-be-digest-pinned
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-digest
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [prod, staging]
      validate:
        message: >-
          Third-party images must be referenced by immutable digest
          (name@sha256:...), never by a mutable tag.
        pattern:
          spec:
            =(initContainers):
              - image: "*@sha256:*"
            =(ephemeralContainers):
              - image: "*@sha256:*"
            containers:
              - image: "*@sha256:*"
```

Behaviour at admission:

```bash
$ kubectl -n prod run rogue --image=ghcr.io/acme/payments-api:latest --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/rogue was blocked due to the following policies

require-signed-sbom-and-provenance:
  verify-first-party-images: |
    failed to verify image ghcr.io/acme/payments-api:latest:
    .attestors[0].entries[0].keyless: no matching attestations:
    none of the expected identities matched what was in the certificate

$ kubectl -n prod apply -f deploy/payments-api.yaml
deployment.apps/payments-api created

$ kubectl -n prod get deploy payments-api \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
ghcr.io/acme/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
# ^ mutateDigest rewrote the tag to the digest that was actually verified
```

### 7.5 Continuous re-evaluation: the CVE published *after* you shipped

An SBOM's value is that a *new* CVE can be matched against an *old* artifact without rebuilding it.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sbom-rescan
  namespace: supply-chain
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sbom-rescan-read-pods
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [list, get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sbom-rescan-read-pods
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sbom-rescan-read-pods
subjects:
  - kind: ServiceAccount
    name: sbom-rescan
    namespace: supply-chain
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: sbom-rescan
  namespace: supply-chain
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 5400
      template:
        spec:
          serviceAccountName: sbom-rescan
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: rescan
              image: ghcr.io/acme/supply-chain-toolbox:2026.09.1   # kubectl+cosign+grype+jq+curl
              command: [/bin/sh, -euo, pipefail, -c]
              args:
                - |
                  echo "== refreshing vulnerability DB =="
                  grype db update
                  grype db status

                  echo "== enumerating running first-party images =="
                  kubectl get pods -A \
                    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}' \
                    | grep -E '^ghcr\.io/acme/' \
                    | sed 's#^docker-pullable://##' \
                    | sort -u > /tmp/images.txt
                  wc -l < /tmp/images.txt

                  FAILED=0
                  while read -r IMG; do
                    [ -n "$IMG" ] || continue
                    echo "----- $IMG -----"

                    # Pull the SBOM we signed at build time; never re-derive it.
                    if ! cosign verify-attestation --type cyclonedx \
                         --certificate-identity-regexp "$IDENTITY_RE" \
                         --certificate-oidc-issuer "$OIDC_ISSUER" \
                         "$IMG" > /tmp/att.json 2>/tmp/att.err; then
                      echo "NO VERIFIED SBOM: $IMG"; cat /tmp/att.err
                      FAILED=1; continue
                    fi
                    jq -r '.payload' /tmp/att.json | base64 -d \
                      | jq '.predicate' > /tmp/sbom.cdx.json

                    grype "sbom:/tmp/sbom.cdx.json" -o json > /tmp/result.json || true
                    CRIT=$(jq '[.matches[] | select(.vulnerability.severity=="Critical")] | length' /tmp/result.json)
                    HIGH=$(jq '[.matches[] | select(.vulnerability.severity=="High")]     | length' /tmp/result.json)
                    echo "critical=$CRIT high=$HIGH"

                    if [ "$CRIT" -gt 0 ]; then
                      jq -n --arg img "$IMG" --argjson crit "$CRIT" --argjson high "$HIGH" \
                        '{text: "🔴 New CRITICAL findings in a RUNNING image\n\($img)\ncritical=\($crit) high=\($high)"}' \
                        | curl -sS -X POST -H 'Content-Type: application/json' -d @- "$ALERT_WEBHOOK" >/dev/null
                      FAILED=1
                    fi
                  done < /tmp/images.txt
                  exit "$FAILED"
              env:
                - name: IDENTITY_RE
                  value: '^https://github\.com/acme/[^/]+/\.github/workflows/release\.yml@refs/tags/v.+$'
                - name: OIDC_ISSUER
                  value: https://token.actions.githubusercontent.com
                - name: ALERT_WEBHOOK
                  valueFrom: { secretKeyRef: { name: alerting, key: webhook } }
                - name: GRYPE_DB_CACHE_DIR
                  value: /tmp/grype-db
              volumeMounts:
                - { name: tmp, mountPath: /tmp }
              resources:
                requests: { cpu: 500m, memory: 1Gi }
                limits:   { cpu: "2",  memory: 4Gi }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: ["ALL"] }
          volumes:
            - name: tmp
              emptyDir: { sizeLimit: 8Gi }
```

### 7.6 Renovate: closing the loop on dependency currency

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":dependencyDashboard",
    ":semanticCommits",
    "helpers:pinGitHubActionDigests"
  ],
  "timezone": "Etc/UTC",
  "schedule": ["after 2am and before 6am every weekday"],
  "prConcurrentLimit": 8,
  "prHourlyLimit": 4,
  "rangeStrategy": "pin",
  "postUpdateOptions": ["gomodTidy", "npmDedupe"],
  "osvVulnerabilityAlerts": true,
  "vulnerabilityAlerts": {
    "enabled": true,
    "schedule": ["at any time"],
    "labels": ["security", "priority/critical"],
    "prPriority": 10,
    "minimumReleaseAge": null
  },
  "packageRules": [
    {
      "description": "Cooling-off period defeats compromised-release attacks (event-stream, xz)",
      "matchUpdateTypes": ["minor", "patch"],
      "minimumReleaseAge": "5 days"
    },
    {
      "description": "Group all patch-level Go module bumps into one reviewable PR",
      "matchManagers": ["gomod"],
      "matchUpdateTypes": ["patch"],
      "groupName": "go modules (patch)"
    },
    {
      "description": "Major bumps require an explicit human decision",
      "matchUpdateTypes": ["major"],
      "dependencyDashboardApproval": true,
      "labels": ["needs-architecture-review"]
    },
    {
      "description": "Never auto-follow a project that relicensed away from OSI",
      "matchPackageNames": [
        "github.com/hashicorp/terraform",
        "github.com/hashicorp/vault",
        "github.com/hashicorp/consul"
      ],
      "enabled": false
    },
    {
      "description": "Base images: track digests, not tags",
      "matchDatasources": ["docker"],
      "pinDigests": true
    }
  ],
  "customManagers": [
    {
      "customType": "regex",
      "description": "Keep tool versions in workflow env blocks up to date",
      "managerFilePatterns": ["/^\\.github/workflows/.+\\.ya?ml$/"],
      "matchStrings": [
        "#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)\\s*\\n\\s*\\w+:\\s*[\"']?(?<currentValue>v?[\\d.]+)[\"']?"
      ]
    }
  ]
}
```

---

## 8. Verification and failure diagnosis

### 8.1 The triage table

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| SBOM has 0–3 packages | scanned a scratch/distroless image with no package DB; wrong scan target | `syft scan <img> -o table \| wc -l` | scan the build stage too, or use build-system SBOM and merge |
| Grype reports 0 vulns on a known-vulnerable image | stale or missing DB; components lack both purl and CPE | `grype db status`; `jq '.artifacts[] \| select(.cpes==[])' sbom.syft.json` | `grype db update`; `add-cpes-if-none: true` |
| Go binary shows version `(devel)` | built without VCS stamping or from a dirty tree | `go version -m ./bin/app` | build with `-buildvcs=true` and inject `-X main.version=` |
| `log4j-core` invisible in a fat JAR | classes shaded/relocated; no POM inside | `unzip -l app.jar \| grep -i log4j`; `jar tf app.jar \| grep JndiLookup` | build-time SBOM via `cyclonedx-maven-plugin`; `--search-unindexed-archives` |
| Thousands of npm findings | `node_modules` still contains devDependencies | `npm ls --omit=dev --all \| wc -l` | `npm ci --omit=dev` before the scan; multi-stage build |
| All licences `NOASSERTION` | metadata-only detection; no `LICENSE` text present | `scancode --license …` on the source | run ScanCode/ORT; add curations |
| Policy blocks the JDK for "GPL" | substring match ignoring `WITH Classpath-exception-2.0` | `jq '.components[].licenses' sbom.cdx.json` | parse the SPDX expression, allow-list the exception |
| `cosign verify` → `no matching signatures` | wrong identity regexp / issuer, or unsigned image | see §8.4 | fix the regexp; check the tlog |
| `cosign verify-attestation` → `no matching attestations` | attested a different digest, or wrong `--type` | `crane digest`; `cosign tree` | attest the digest, not the tag |
| Trivy `TOOMANYREQUESTS` on DB pull | anonymous ghcr.io rate limit | `trivy image --debug` | mirror the DB (`db.repository`) |
| Dependency-Track upload → HTTP 400 | CycloneDX spec version newer than the DT release | `curl -v … ; jq '.specVersion'` | downgrade output (`-o cyclonedx-json@1.5`) or upgrade DT |
| VEX ignored, finding still shown | product `@id` does not match the artifact purl exactly | see §8.7 | make the purls byte-identical |
| Kyverno admits an unsigned image | rule `background: true` + `failurePolicy: Ignore`; webhook timeout | `kubectl logs -n kyverno deploy/kyverno-admission-controller` | `background: false`, `failurePolicy: Fail` |

### 8.2 Prove the SBOM is not empty *before* trusting a green scan

The most dangerous outcome in this pipeline is a **structurally valid, semantically empty SBOM** — every downstream gate passes.

```bash
$ jq -r '
    {
      spdx_version: .spdxVersion,
      packages: (.packages | length),
      with_purl: ([ .packages[] | select(
                      (.externalRefs // []) | map(.referenceType=="purl") | any) ] | length),
      with_version: ([ .packages[]
                       | select(.versionInfo != null and .versionInfo != "NOASSERTION") ] | length),
      relationships: (.relationships | length),
      noassertion_licence: ([ .packages[]
                       | select(.licenseConcluded=="NOASSERTION"
                                and .licenseDeclared=="NOASSERTION") ] | length)
    }' sbom.spdx.json
{
  "spdx_version": "SPDX-2.3",
  "packages": 312,
  "with_purl": 312,
  "with_version": 311,
  "relationships": 313,
  "noassertion_licence": 6
}
```

Turn that into a hard gate:

```bash
#!/usr/bin/env bash
# scripts/assert-sbom-quality.sh
set -euo pipefail
SBOM="${1:?usage: assert-sbom-quality.sh <sbom.spdx.json>}"
MIN_PACKAGES="${MIN_PACKAGES:-25}"
MAX_UNKNOWN_LICENCE_PCT="${MAX_UNKNOWN_LICENCE_PCT:-10}"

total=$(jq '.packages | length' "$SBOM")
purl=$(jq '[ .packages[] | select((.externalRefs // []) | map(.referenceType=="purl") | any) ] | length' "$SBOM")
unknown=$(jq '[ .packages[] | select(.licenseConcluded=="NOASSERTION" and .licenseDeclared=="NOASSERTION") ] | length' "$SBOM")

echo "packages=${total} with_purl=${purl} unknown_licence=${unknown}"

(( total >= MIN_PACKAGES )) || { echo "FAIL: only ${total} packages (< ${MIN_PACKAGES})"; exit 1; }
(( purl == total ))         || { echo "FAIL: $((total - purl)) packages have no purl"; exit 1; }
pct=$(( unknown * 100 / total ))
(( pct <= MAX_UNKNOWN_LICENCE_PCT )) || { echo "FAIL: ${pct}% unknown licences (> ${MAX_UNKNOWN_LICENCE_PCT}%)"; exit 1; }
echo "SBOM quality gate: PASS"
```

```bash
$ MIN_PACKAGES=25 ./scripts/assert-sbom-quality.sh sbom.spdx.json
packages=312 with_purl=312 unknown_licence=6
SBOM quality gate: PASS

$ ./scripts/assert-sbom-quality.sh /tmp/scratch-image.spdx.json
packages=1 with_purl=1 unknown_licence=1
FAIL: only 1 packages (< 25)
$ echo $?
1
```

### 8.3 Diagnosing missing components in a distroless / scratch image

```bash
# Symptom: 312 packages in the builder stage, 1 in the final image
$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 -o table
NAME          VERSION   TYPE
payments-api  1.24.3    go-module

# Why: no OS package DB exists in the final layer
$ crane export ghcr.io/acme/payments-api:1.24.3 - | tar -tf - | grep -E 'var/lib/dpkg|lib/apk/db|var/lib/rpm' | head
(no output)

# But the Go module graph IS embedded in the binary
$ crane export ghcr.io/acme/payments-api:1.24.3 - \
    | tar -xO usr/local/bin/payments-api > /tmp/payments-api
$ go version -m /tmp/payments-api | head -20
/tmp/payments-api: go1.23.6
	path	github.com/acme/payments-api/cmd/payments-api
	mod	github.com/acme/payments-api	v1.24.3	h1:6C3g…=
	dep	github.com/gorilla/mux	v1.8.1	h1:TuBL49tXwgrFYWhqrNgrUNEY92u81SPhu7sTdzQEiWY=
	dep	google.golang.org/grpc	v1.68.1	h1:oI5oTa11+ng8r8XvFCLQVs1TR1S…=
	build	-buildmode=exe
	build	-compiler=gc
	build	-trimpath=true
	build	CGO_ENABLED=0
	build	vcs=git
	build	vcs.revision=7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
	build	vcs.time=2026-09-03T09:08:11Z
	build	vcs.modified=false

# If `mod` shows "(devel)" instead of v1.24.3, VCS stamping is missing:
$ go build -buildvcs=true -ldflags "-X main.version=$(git describe --tags)" ./cmd/payments-api
```

**Fix:** emit the SBOM from the *builder* stage as well and merge:

```bash
$ docker build --target build -t payments-api:builder .
$ syft scan docker:payments-api:builder     -o cyclonedx-json=sbom.build.json
$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 -o cyclonedx-json=sbom.image.json
$ cyclonedx-cli merge --input-files sbom.build.json sbom.image.json \
                      --output-file sbom.merged.json --hierarchical \
                      --name payments-api --version 1.24.3
$ jq '.components | length' sbom.build.json sbom.image.json sbom.merged.json
298
1
299
```

### 8.4 Diagnosing signature and attestation failures

```bash
$ cosign verify \
    --certificate-identity-regexp 'github.com/acme/payments-api' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/payments-api:1.24.3

Error: no matching signatures:
main.go:74: error during command execution: no matching signatures
```

Work down the ladder:

```bash
# 1. Does ANY signature exist for this digest?
$ cosign tree ghcr.io/acme/payments-api:1.24.3
📦 Supply Chain Security Related artifacts for an image: ghcr.io/acme/payments-api:1.24.3
└── 💾 Attestations for an image tag: ghcr.io/acme/payments-api:sha256-9f2b3c….att
   ├── 🍒 sha256:c8b1e4d7a2f905638e1c0b7a4d3f296e8c5b0a1d7f3e6c9b2a4d8f1e0c7b3a56
   └── 🍒 sha256:e1f0a9d8c7b6a5948372615f4e3d2c1b0a9f8e7d6c5b4a39281706f5e4d3c2b1
└── 🔐 Signatures for an image tag: ghcr.io/acme/payments-api:sha256-9f2b3c….sig
   └── 🍒 sha256:a4f7d2c9e0b18365d4c7a0f3e6b9d2c5a8f1e4d7c0b3a6f9e2d5c8b1a4f7e0d3

# 2. Signature exists → the identity is wrong. Read the certificate directly.
$ cosign verify --insecure-ignore-tlog=true --certificate-identity-regexp '.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/payments-api:1.24.3 2>/dev/null \
  | jq -r '.[0].optional.Subject, .[0].optional.Issuer'
https://github.com/acme/payments-api/.github/workflows/build-nightly.yml@refs/heads/main
https://token.actions.githubusercontent.com
# ^ signed by the NIGHTLY workflow, not release.yml. The policy is correct;
#   the artifact is not the one the policy is meant to admit.

# 3. Confirm independently in the transparency log
$ rekor-cli search --sha sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
Found matching entries (listed by UUID):
24296fb24b8ad77a1f9c0e4b7d2a5638e0c1b4a7f3d6e9c2b5a8f1d4e7c0b3a6f92d8e1c4b7a0f3e6

$ rekor-cli get --uuid 24296fb24b8ad77a…0f3e6 --format json \
  | jq -r '.Body.HashedRekordObj.signature.publicKey.content' \
  | base64 -d | openssl x509 -noout -text \
  | grep -A3 'X509v3 Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:https://github.com/acme/payments-api/.github/workflows/build-nightly.yml@refs/heads/main
```

Attestation-specific failures:

```bash
# Wrong predicate type
$ cosign verify-attestation --type slsaprovenance ghcr.io/acme/payments-api@sha256:9f2b3c… \
    --certificate-identity-regexp '…' --certificate-oidc-issuer '…'
Error: none of the attestations matched the predicate type: slsaprovenance
# SLSA v1.0 uses https://slsa.dev/provenance/v1 ; "slsaprovenance" is the v0.2 alias.
$ cosign verify-attestation --type "https://slsa.dev/provenance/v1" …

# Attested the tag, deployed the digest (or vice versa)
$ crane digest ghcr.io/acme/payments-api:1.24.3
sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
$ jq -r '.payload' attestation.json | base64 -d | jq -r '.subject[].digest.sha256'
b7e1a4c9d2f0836e5a1c4b7d0f3e6a9c2b5d8f1e4a7c0b3d6f9e2a5c8b1d4f7e0
# ^ mismatch: the tag was moved after attestation. Always attest and deploy
#   the same @sha256: reference; never a tag.
```

### 8.5 Registry-side problems

```bash
# OCI 1.1 referrers API unsupported by an older registry
$ cosign attest --yes --type spdxjson --predicate sbom.spdx.json \
    registry.internal.acme.example/payments-api@sha256:9f2b3c…
Error: recursively copying attestation: PUT https://registry.internal.acme.example/v2/…/referrers/sha256:9f2b3c…:
  UNSUPPORTED: The operation is unsupported

# Fall back to the tag-based fallback scheme
$ COSIGN_EXPERIMENTAL=0 cosign attest --yes --registry-referrers-mode=legacy \
    --type spdxjson --predicate sbom.spdx.json registry.internal.acme.example/payments-api@sha256:9f2b3c…

# The fallback stores attestations at a derived tag:
$ crane ls registry.internal.acme.example/payments-api | grep sha256-
sha256-9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e.att
sha256-9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e.sig
# ⚠️ A registry garbage-collection or "delete untagged manifests" policy will
#    silently destroy these. Exclude *.att / *.sig / *.sbom from GC rules.
```

### 8.6 purl vs CPE: the false-negative machine

```bash
# A Go module with no CPE: NVD-only matchers will never see it
$ jq -r '
    .artifacts[]
    | select(.type=="go-module" and (.cpes | length)==0)
    | "\(.name)\t\(.version)\tpurl=\(.purl)\tcpes=\(.cpes|length)"
  ' sbom.syft.json | head -5
github.com/gorilla/mux	v1.8.1	purl=pkg:golang/github.com/gorilla/mux@v1.8.1	cpes=0
google.golang.org/grpc	v1.68.1	purl=pkg:golang/google.golang.org/grpc@v1.68.1	cpes=0

# Compare matcher coverage
$ grype sbom:./sbom.cdx.json -o json | jq '[.matches[].vulnerability.id] | length'
37
$ grype sbom:./sbom.cdx.json --add-cpes-if-none -o json | jq '[.matches[].vulnerability.id] | length'
44

# Cross-check the same lockfile against OSV, whose native key is the purl
$ osv-scanner scan source --lockfile=go.mod --format=json . \
  | jq -r '[.results[].packages[].vulnerabilities[]?.id] | unique | length'
9
```

> **Operational rule:** run at least two matchers with different data sources (grype ⇒ GitHub Security Advisories + distro feeds + NVD; osv-scanner ⇒ OSV.dev). Their union is the finding set; their intersection is the high-confidence set. A single matcher is a single point of failure for *detection*, and detection failures are silent.

### 8.7 VEX not applied

```bash
$ grype sbom:./sbom.cdx.json --vex vex.json --show-suppressed -o json \
  | jq '[.matches[] | select(.vulnerability.id=="CVE-2023-45853")] | length'
1          # still present — VEX did not match

# Compare the identifiers byte for byte
$ jq -r '.statements[].products[]."@id"' vex.json
pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io/acme/payments-api

$ jq -r '.metadata.component.purl' sbom.cdx.json
pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io%2Facme%2Fpayments-api
#                                                             ^^^ percent-encoded

# purl qualifier values must be percent-encoded per the purl spec.
$ jq '(.statements[].products[]."@id") |=
        sub("repository_url=ghcr\\.io/acme/payments-api";
            "repository_url=ghcr.io%2Facme%2Fpayments-api")' vex.json > vex.fixed.json

$ grype sbom:./sbom.cdx.json --vex vex.fixed.json --show-suppressed -o table \
  | grep CVE-2023-45853
zlib1g  1:1.2.13.dfsg-1  deb  CVE-2023-45853  High (suppressed by VEX)
```

### 8.8 Air-gapped and rate-limited environments

```bash
# Symptom
$ trivy image ghcr.io/acme/payments-api:1.24.3
2026-09-03T11:02:19Z    FATAL   Fatal error   init error: DB error: failed to download vulnerability DB:
  OCI repository error: 1 error occurred:
	* GET https://ghcr.io/v2/aquasecurity/trivy-db/manifests/2: TOOMANYREQUESTS: retry-after=…

# Fix: mirror the DB into the internal registry once per day, then point at it
$ oras copy ghcr.io/aquasecurity/trivy-db:2 \
            registry.internal.acme.example/mirror/trivy-db:2
Copying  ba1c4e7d9f02 db.tar.gz
Copied  [================================================] 58.4/58.4 MB
Digest: sha256:d3c9b0a7f1e4628d5c0b3a6f9e2d5c8b1a4f7e0d3c6b9a2f5e8d1c4b7a0f3e69

$ export TRIVY_DB_REPOSITORY=registry.internal.acme.example/mirror/trivy-db:2
$ export TRIVY_JAVA_DB_REPOSITORY=registry.internal.acme.example/mirror/trivy-java-db:1
$ trivy image --skip-db-update=false ghcr.io/acme/payments-api:1.24.3
2026-09-03T11:05:02Z    INFO    Downloading DB   repository="registry.internal.acme.example/mirror/trivy-db:2"

# Grype, air-gapped
$ grype db update -o json > /dev/null            # on a connected host
$ tar -czf grype-db-$(date +%F).tar.gz -C ~/.cache/grype/db .
# transfer, then on the air-gapped host:
$ grype db import ./grype-db-2026-09-03.tar.gz
$ GRYPE_DB_AUTO_UPDATE=false grype sbom:./sbom.cdx.json

# osv-scanner, offline
$ osv-scanner --download-offline-databases scan source --offline .
```

### 8.9 The full end-to-end verification script

```bash
#!/usr/bin/env bash
# scripts/verify-release.sh — run this against a candidate before promotion.
set -euo pipefail

IMAGE_REPO="${1:?usage: verify-release.sh <repo> <tag>}"
TAG="${2:?}"
IDENTITY_RE='^https://github\.com/acme/[^/]+/\.github/workflows/release\.yml@refs/tags/v.+$'
OIDC_ISSUER='https://token.actions.githubusercontent.com'

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "1. Resolve tag -> immutable digest"
DIGEST="$(crane digest "${IMAGE_REPO}:${TAG}")"
REF="${IMAGE_REPO}@${DIGEST}"
echo "$REF"

step "2. Verify the image signature"
cosign verify --certificate-identity-regexp "$IDENTITY_RE" \
              --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" > /dev/null
echo "signature OK"

step "3. Verify and extract the SPDX attestation"
cosign verify-attestation --type spdxjson \
  --certificate-identity-regexp "$IDENTITY_RE" \
  --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" \
  | jq -r '.payload' | base64 -d > /tmp/spdx-statement.json
jq -r '.predicate' /tmp/spdx-statement.json > /tmp/sbom.spdx.json

step "4. Confirm the attestation is bound to THIS digest"
SUBJ="$(jq -r '.subject[0].digest.sha256' /tmp/spdx-statement.json)"
[ "sha256:${SUBJ}" = "$DIGEST" ] || { echo "FAIL: subject/digest mismatch"; exit 1; }
echo "subject binding OK"

step "5. SBOM quality gate"
MIN_PACKAGES=25 ./scripts/assert-sbom-quality.sh /tmp/sbom.spdx.json

step "6. Verify SLSA provenance"
cosign verify-attestation --type "https://slsa.dev/provenance/v1" \
  --certificate-identity-regexp "$IDENTITY_RE" \
  --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" \
  | jq -r '.payload' | base64 -d \
  | jq -e '.predicate.runDetails.builder.id
           | test("^https://github.com/actions/runner/")' > /dev/null
echo "provenance builder OK"

step "7. Vulnerability gate against the fresh DB"
grype db update >/dev/null
grype "sbom:/tmp/sbom.spdx.json" --config .grype.yaml \
      --vex ./vex/payments-api.openvex.json --fail-on high -o table

step "8. Licence gate"
jq -r '
  [ .packages[].licenseDeclared ] | unique | .[]
  | select(test("AGPL|SSPL|BUSL|Elastic-2\\.0|CC-BY-NC"))
' /tmp/sbom.spdx.json > /tmp/forbidden.txt || true
if [ -s /tmp/forbidden.txt ]; then
  echo "FAIL: forbidden licences present:"; cat /tmp/forbidden.txt; exit 1
fi
echo "licence gate OK"

printf '\n\033[1;32mRELEASE VERIFICATION PASSED: %s\033[0m\n' "$REF"
```

```bash
$ ./scripts/verify-release.sh ghcr.io/acme/payments-api 1.24.3

== 1. Resolve tag -> immutable digest ==
sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
ghcr.io/acme/payments-api@sha256:9f2b3c…

== 2. Verify the image signature ==
signature OK

== 3. Verify and extract the SPDX attestation ==

== 4. Confirm the attestation is bound to THIS digest ==
subject binding OK

== 5. SBOM quality gate ==
packages=312 with_purl=312 unknown_licence=6
SBOM quality gate: PASS

== 6. Verify SLSA provenance ==
provenance builder OK

== 7. Vulnerability gate against the fresh DB ==
 ✔ Scanned for vulnerabilities     [36 vulnerability matches]
   ├── by severity: 0 critical, 0 high, 18 medium, 16 low, 2 negligible (1 suppressed)
   └── by status:   20 fixed, 16 not-fixed

== 8. Licence gate ==
licence gate OK

RELEASE VERIFICATION PASSED: ghcr.io/acme/payments-api@sha256:9f2b3c…
$ echo $?
0
```

---

## 9. Architectural decision summary

| Decision | Choose this | Because |
|---|---|---|
| SBOM format | emit **both** SPDX 2.3 and CycloneDX 1.6 | consumers are split; marginal cost is one extra `-o` flag |
| SBOM generation point | build-stage **and** image-stage, merged | neither alone sees both language deps and OS deps |
| Attach mechanism | in-toto attestation in a DSSE envelope via cosign | binds the SBOM to a digest and to a signing identity |
| Signing | Sigstore keyless with OIDC workload identity | no long-lived key to leak or rotate; identity is the workflow |
| Noise control | **VEX**, never scanner ignore-lists | VEX is signed, dated, justified, and shared with customers |
| Storage | Dependency-Track (or equivalent) as the queryable inventory | incident response must be a database query, not N pipeline runs |
| Enforcement | admission control that verifies attestations + `mutateDigest` | closes the tag-mutation TOCTOU window |
| Licence detection | metadata scan in CI, ScanCode/ORT at release | declared metadata misses vendored source |
| Licence policy | SPDX **expression** parsing, never substring matching | `WITH Classpath-exception-2.0` and `OR` are both mishandled otherwise |
| Contribution model | DCO unless relicensing is a real requirement | CLA friction is a measurable contributor-acquisition cost |
| Dependency currency | Renovate with a `minimumReleaseAge` cooling-off period | defeats compromised-release attacks; still keeps you current |
| Retention | SBOMs outlive the artifact (≥ the support window) | you will be asked about a 2-year-old release |

### Terms and utilities

`SPDX` · `CycloneDX` · `SWID` · `purl` · `CPE` · `CVE` · `CVSS` · `EPSS` · `OSV` · `VEX` · `OpenVEX` · `CSAF` · `SLSA` · `in-toto` · `DSSE` · `Sigstore` · `Fulcio` · `Rekor` · `SCA` · `OSPO` · `DCO` · `CLA` · `REUSE` · copyleft (strong/weak/network) · licence compatibility · SBOM lifecycle phases
`syft` · `grype` · `trivy` · `osv-scanner` · `cdxgen` · `scancode` · `ort` · `reuse` · `cosign` · `rekor-cli` · `slsa-verifier` · `vexctl` · `crane` · `oras` · `go-licenses` · `licensee` · `cyclonedx-cli` · `dependency-track` · `renovate`

---

## 10. References

**Exam objectives**
- LPI DevOps Tools Engineer — Exam 701 Objectives: https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI DevOps Tools Engineer overview: https://www.lpi.org/our-certifications/devops-overview/

**Open source definition and licences**
- Open Source Definition (OSI): https://opensource.org/osd
- OSI approved licences: https://opensource.org/licenses
- SPDX Licence List: https://spdx.org/licenses/
- SPDX Licence Expressions (Annex D, SPDX 2.3): https://spdx.github.io/spdx-spec/v2.3/SPDX-license-expressions/
- GNU licence list and commentary: https://www.gnu.org/licenses/license-list.html
- GNU GPL FAQ (linking, conveying, network use): https://www.gnu.org/licenses/gpl-faq.html
- GNU GPL v3: https://www.gnu.org/licenses/gpl-3.0.en.html
- GNU AGPL v3: https://www.gnu.org/licenses/agpl-3.0.en.html
- GNU LGPL v3: https://www.gnu.org/licenses/lgpl-3.0.en.html
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- ASF third-party licensing policy: https://www.apache.org/legal/resolved.html
- Mozilla Public License 2.0 FAQ: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
- Business Source License 1.1: https://mariadb.com/bsl11/
- Server Side Public License: https://www.mongodb.com/legal/licensing/server-side-public-license

**Contribution and file-level compliance**
- Developer Certificate of Origin 1.1: https://developercertificate.org/
- Apache ICLA/CCLA: https://www.apache.org/licenses/contributor-agreements.html
- REUSE Specification: https://reuse.software/spec/
- REUSE tooling: https://reuse.software/dev/

**SBOM specifications**
- SPDX project: https://spdx.dev/
- SPDX 2.3 specification: https://spdx.github.io/spdx-spec/v2.3/
- SPDX 3.0 specification: https://spdx.github.io/spdx-spec/v3.0.1/
- CycloneDX specification overview: https://cyclonedx.org/specification/overview/
- CycloneDX 1.6 JSON reference: https://cyclonedx.org/docs/1.6/json/
- CycloneDX use cases: https://cyclonedx.org/use-cases/
- Package URL (purl) specification: https://github.com/package-url/purl-spec
- CISA SBOM resources: https://www.cisa.gov/sbom
- NTIA "The Minimum Elements For a Software Bill of Materials": https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom

**Vulnerability and exploitability data**
- OSV database: https://osv.dev/
- OSV schema: https://ossf.github.io/osv-schema/
- National Vulnerability Database: https://nvd.nist.gov/
- CVE Program: https://www.cve.org/
- CVSS v4.0 specification: https://www.first.org/cvss/v4-0/specification-document
- EPSS: https://www.first.org/epss/
- OpenVEX specification: https://github.com/openvex/spec
- CSAF 2.0 (OASIS standard, includes the VEX profile): https://docs.oasis-open.org/csaf/csaf/v2.0/csaf-v2.0.html
- CISA "Minimum Requirements for Vulnerability Exploitability eXchange (VEX)": https://www.cisa.gov/resources-tools/resources/minimum-requirements-vulnerability-exploitability-exchange-vex

**Supply chain integrity**
- SLSA v1.0 specification: https://slsa.dev/spec/v1.0/
- SLSA provenance predicate: https://slsa.dev/spec/v1.0/provenance
- in-toto Attestation Framework: https://github.com/in-toto/attestation
- DSSE (Dead Simple Signing Envelope): https://github.com/secure-systems-lab/dsse
- Sigstore documentation: https://docs.sigstore.dev/
- cosign: https://github.com/sigstore/cosign
- slsa-verifier: https://github.com/slsa-framework/slsa-verifier
- OpenSSF Scorecard: https://scorecard.dev/
- NIST SP 800-218 (Secure Software Development Framework): https://csrc.nist.gov/pubs/sp/800/218/final
- Executive Order 14028: https://www.federalregister.gov/d/2021-10460
- EU Cyber Resilience Act (Regulation 2024/2847): https://eur-lex.europa.eu/eli/reg/2024/2847/oj

**Tooling**
- syft: https://github.com/anchore/syft
- grype: https://github.com/anchore/grype
- Trivy documentation: https://trivy.dev/latest/docs/
- osv-scanner: https://google.github.io/osv-scanner/
- cdxgen: https://github.com/CycloneDX/cdxgen
- CycloneDX CLI: https://github.com/CycloneDX/cyclonedx-cli
- ScanCode Toolkit: https://scancode-toolkit.readthedocs.io/
- OSS Review Toolkit (ORT): https://oss-review-toolkit.org/ort/
- FOSSology: https://www.fossology.org/
- Dependency-Track: https://docs.dependencytrack.org/
- Kyverno image verification: https://kyverno.io/docs/writing-policies/verify-images/
- Renovate: https://docs.renovatebot.com/
- go-licenses: https://github.com/google/go-licenses
- crane / go-containerregistry: https://github.com/google/go-containerregistry
- ORAS: https://oras.land/docs/
- OCI Image Specification: https://github.com/opencontainers/image-spec
- OCI Distribution Specification (referrers API): https://github.com/opencontainers/distribution-spec