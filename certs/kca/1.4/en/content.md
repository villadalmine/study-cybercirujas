# OCI Images

> **KCA · Domain 1 · Topic 1.4** — Exam weight **4.5**
> Profile: Platform Architect / SRE. Assumes you already run containers; this topic is about the *artifact* itself — how it is specified, addressed, distributed, verified, and how it breaks.

---

## 1. The production problem: why "OCI" exists at all

Before 2015 a "container image" meant "whatever the Docker daemon produced and consumed." The format was a de-facto standard owned by one vendor, coupled to one runtime, described by no written specification you could implement against. Three concrete production failures followed from that coupling:

1. **Runtime lock-in.** An image built by `docker build` could only be reliably run by the Docker daemon. If you wanted `containerd`, `CRI-O`, `podman`, `runc`, `crun`, `gVisor`, or `Kata` to consume the *same* bytes, you were relying on reverse-engineered compatibility, not a contract.
2. **Registry lock-in.** The wire protocol for `docker push`/`docker pull` was similarly de-facto. Every registry vendor (Quay, Harbor, ECR, GCR, ACR, GitHub Packages) had to chase Docker's behavior instead of implementing a spec.
3. **Supply-chain opacity.** An image was an opaque blob keyed by a mutable tag (`myapp:latest`). There was no content-addressable identity, no standard place to attach a signature, an SBOM, or a provenance attestation. You could not answer "is *this exact artifact* the one my CI built and signed?" with cryptographic certainty.

The **Open Container Initiative (OCI)**, founded June 2015 under the Linux Foundation, exists to remove that coupling by publishing three vendor-neutral specifications. Understanding which spec governs which boundary is the single most useful mental model for this topic:

| Spec | Governs | Question it answers | Key consumers |
|---|---|---|---|
| **OCI Image Specification** | The on-disk / in-registry artifact | "What *is* an image? How is it laid out and addressed?" | build tools, registries, `containerd` image store |
| **OCI Distribution Specification** | The registry HTTP API | "How do I push/pull/discover this artifact over the wire?" | registries, `crane`, `skopeo`, `oras`, CI |
| **OCI Runtime Specification** | The *unpacked* filesystem bundle + `config.json` | "How does a runtime turn an image into a running process?" | `runc`, `crun`, `containerd`, `CRI-O` |

The image spec is the "at rest" format. The distribution spec is the "in flight" protocol. The runtime spec is the "converted to run" format. **An OCI image is never handed directly to `runc`** — a higher-level runtime (`containerd`/`CRI-O`) unpacks the image layers into a root filesystem and generates a runtime `config.json`, and *that bundle* is what the low-level runtime executes. This decoupling is exactly what lets Kubernetes swap runtimes without rebuilding a single image.

```
                        ┌──────────────────────────────────────────┐
   docker build /       │            OCI IMAGE (at rest)            │
   buildah / kaniko ──▶ │  index.json → manifest → config + layers  │
   / ko / buildpacks    └───────────────────┬──────────────────────┘
                                             │  push (Distribution spec)
                                             ▼
                        ┌──────────────────────────────────────────┐
                        │              OCI REGISTRY                  │
                        │   content-addressable blob + manifest DB   │
                        └───────────────────┬──────────────────────┘
                                             │  pull (Distribution spec)
                                             ▼
              containerd / CRI-O  ── unpack layers, snapshot ──▶
                        ┌──────────────────────────────────────────┐
                        │       OCI RUNTIME BUNDLE (to run)          │
                        │   rootfs/  +  config.json (Runtime spec)   │
                        └───────────────────┬──────────────────────┘
                                             │  runc / crun / gVisor / Kata
                                             ▼
                                     running container process
```

---

## 2. Anatomy of an OCI image

An OCI image is **not a single file**. It is a small directed acyclic graph of JSON documents and tar blobs, every node identified by the SHA-256 digest of its own bytes (content-addressable storage). Four object types:

1. **Image Index** (`application/vnd.oci.image.index.v1+json`) — optional top node. A list of manifests, one per platform (`linux/amd64`, `linux/arm64`, …). This is what makes an image "multi-arch." Docker's equivalent is the *manifest list*.
2. **Image Manifest** (`application/vnd.oci.image.manifest.v1+json`) — the per-platform node. Points at exactly **one config** and an **ordered list of layer** blobs.
3. **Image Config** (`application/vnd.oci.image.config.v1+json`) — a JSON document describing how to run the image: `Entrypoint`, `Cmd`, `Env`, `User`, `WorkingDir`, `ExposedPorts`, plus `rootfs.diff_ids` and `history`. **The digest of this config JSON is the "image ID"** you see in `docker images` / `crane digest --platform`.
4. **Layers** — tar archives (optionally gzip- or zstd-compressed) that stack to form the root filesystem.

### 2.1 The descriptor — the universal pointer

Every reference between these objects is a **descriptor**: a small JSON object that is the atom of the whole format. Internalize its fields — nearly every diagnostic you will run inspects a descriptor.

```json
{
  "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
  "digest": "sha256:2d429b9e73a6fd15 e46f88ecf6 b6d90a5d... ",
  "size": 3408729,
  "urls": ["https://..."],
  "annotations": { "org.opencontainers.image.title": "app-binary" },
  "platform": { "architecture": "amd64", "os": "linux" },
  "artifactType": "application/vnd.example.sbom.v1+json"
}
```

| Field | Required | Meaning / production relevance |
|---|---|---|
| `mediaType` | yes | Tells the puller how to interpret the blob **before** downloading it. Wrong media type → `unsupported media type` on pull. |
| `digest` | yes | `sha256:<hex>`. The content address. Immutable identity. This is what you pin in prod, not the tag. |
| `size` | yes | Bytes. Registries and clients enforce it; a size mismatch aborts the transfer (integrity check). |
| `urls` | no | Foreign/optional out-of-registry sources (e.g. Windows base layers legally hosted by Microsoft). |
| `annotations` | no | Arbitrary `key=value`. Standard keys live under `org.opencontainers.image.*`. |
| `platform` | in index only | `os` / `architecture` / `variant` (e.g. `arm/v7`). Drives multi-arch selection. |
| `artifactType` | no (OCI 1.1) | Marks non-image artifacts (SBOMs, signatures, Helm charts) so registries and tooling can filter them. |

### 2.2 Content addressability — the property everything rests on

The digest of a blob is `sha256(bytes_of_the_blob)`. Three production consequences fall directly out of this:

- **Immutability & integrity.** If a single byte of a layer changes, its digest changes, so it is a *different* object. You cannot silently mutate what a digest points to. Pinning `image@sha256:...` in a Deployment is the only way to guarantee the running bytes equal the reviewed/scanned bytes. A `:tag` is a mutable pointer and can be re-pushed under you.
- **Deduplication & caching.** Two images that share a base layer share the *same digest* for that layer, so the registry stores it once and the node pulls it once. This is why choosing a common base image across your fleet directly reduces registry storage and node pull time.
- **Distributed, trustless assembly.** A puller can fetch blobs from anywhere (mirror, CDN, cache) and still verify each one locally against its digest. The registry does not have to be trusted for integrity, only for availability.

### 2.3 `digest` vs `diff_id` — the single most confused pair in this topic

There are **two different SHA-256 values per layer**, and mixing them up is the root cause of most "why doesn't this match?" confusion:

| Value | Hash of | Lives in | Used for |
|---|---|---|---|
| **`digest`** (a.k.a. blob digest) | the **compressed** layer blob (the gzip/zstd bytes as stored) | the **manifest**'s `layers[]` descriptors | fetching/verifying the blob over the wire |
| **`diff_id`** | the **uncompressed** tar of that layer | the **config**'s `rootfs.diff_ids[]` | computing the filesystem identity / chain ID |

The runtime stacks layers by their uncompressed content, so `diff_id` is the "what the filesystem looks like" identity, independent of compression algorithm. The manifest addresses the blob-as-transferred, so `digest` depends on the compressor. **Recompressing a layer (gzip → zstd) changes the `digest` but not the `diff_id`.** This is why the image ID (config digest) can stay stable across a re-push that changed transport compression, and why you diff `diff_ids` — not blob digests — to prove two images have the same filesystem.

### 2.4 Layers, tar, and whiteouts

Each layer is a tar of the filesystem *changes* relative to the layer below (an "additive diff"). Files are added or replaced by including them. **Deletions** are encoded with whiteout markers, because tar cannot represent "this file is gone":

- **Opaque whiteout:** a `.wh..wh..opq` entry inside a directory means "hide everything from lower layers in this directory."
- **Regular whiteout:** a `.wh.<filename>` entry means "hide `<filename>` from lower layers."

**The load-bearing SRE consequence:** deleting a secret in a later layer does **not** remove it from the image. The secret still ships in the earlier layer's blob; the whiteout only hides it from the *assembled* view. `crane blob`/`skopeo` can extract the earlier layer and read it. This is why "we `rm`'d the credentials in a later `RUN`" is not remediation — you must not introduce the secret into any layer (use build secrets / multi-stage builds).

### 2.5 A real, complete image graph

**Image index** (multi-arch top node):

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:7d3a...amd64",
      "size": 1024,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9f21...arm64",
      "size": 1024,
      "platform": { "architecture": "arm64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:c0ff...attest",
      "size": 840,
      "annotations": {
        "vnd.docker.reference.type": "attestation-manifest",
        "vnd.docker.reference.digest": "sha256:7d3a...amd64"
      },
      "platform": { "architecture": "unknown", "os": "unknown" }
    }
  ]
}
```

**Image manifest** for `linux/amd64` — note the ordered `layers[]`:

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "artifactType": "",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:b1e9...config",
    "size": 2931
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:2d42...base",
      "size": 30457821
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:8a17...deps",
      "size": 8123094
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:f6bd...app",
      "size": 3408729
    }
  ],
  "annotations": {
    "org.opencontainers.image.source": "https://github.com/acme/app",
    "org.opencontainers.image.revision": "9c1f0a2",
    "org.opencontainers.image.created": "2026-08-13T09:14:22Z"
  }
}
```

**Image config** — the runtime knobs plus `diff_ids` and `history`:

```json
{
  "created": "2026-08-13T09:14:22Z",
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "User": "10001:10001",
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "APP_ENV=production"
    ],
    "Entrypoint": ["/app/server"],
    "Cmd": ["--config", "/etc/app/config.yaml"],
    "WorkingDir": "/app",
    "ExposedPorts": { "8080/tcp": {} },
    "Labels": {
      "org.opencontainers.image.title": "acme-api",
      "org.opencontainers.image.version": "1.7.3"
    }
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:aa01...base-uncompressed",
      "sha256:bb02...deps-uncompressed",
      "sha256:cc03...app-uncompressed"
    ]
  },
  "history": [
    { "created": "2026-08-01T00:00:00Z", "created_by": "/bin/sh -c #(nop) ADD file:... in /" },
    { "created": "2026-08-13T09:14:20Z", "created_by": "RUN /bin/sh -c apk add --no-cache ca-certificates", "empty_layer": false },
    { "created": "2026-08-13T09:14:22Z", "created_by": "COPY /out/server /app/server", "comment": "buildkit.dockerfile.v0" }
  ]
}
```

Read the graph top-down: **index** selects a **manifest** by platform → the manifest names one **config** (the image ID) and an ordered list of **layer** blobs → the config's `diff_ids` are the *uncompressed* identities of those same layers, in the same order.

---

## 3. Media types: OCI vs Docker (the interop table you will actually need)

Most registry incompatibilities in production trace back to a media-type mismatch. Docker Schema 2 and OCI are structurally almost identical but use different `mediaType` strings; older registries and clients reject the type they don't recognize with `manifest unknown` or `unsupported media type`.

| Purpose | OCI media type | Docker (schema 2) media type |
|---|---|---|
| Multi-arch top node | `application/vnd.oci.image.index.v1+json` | `application/vnd.docker.distribution.manifest.list.v2+json` |
| Per-platform manifest | `application/vnd.oci.image.manifest.v1+json` | `application/vnd.docker.distribution.manifest.v2+json` |
| Config | `application/vnd.oci.image.config.v1+json` | `application/vnd.docker.container.image.v1+json` |
| Layer (gzip) | `application/vnd.oci.image.layer.v1.tar+gzip` | `application/vnd.docker.image.rootfs.diff.tar.gzip` |
| Layer (uncompressed) | `application/vnd.oci.image.layer.v1.tar` | — |
| Layer (zstd) | `application/vnd.oci.image.layer.v1.tar+zstd` | — |
| Non-distributable (foreign) | (deprecated) `...layer.nondistributable.v1.tar+gzip` | `...foreign.diff.tar.gzip` |
| Empty/scratch config payload | `application/vnd.oci.empty.v1+json` (`{}`) | — |

**Trade-off note — gzip vs zstd layers:** zstd decompresses several times faster and compresses smaller at comparable levels, cutting node pull-and-unpack latency. The cost is compatibility: a registry or an old `containerd`/Docker that doesn't understand `+zstd` will fail the pull. Keep gzip when you cannot guarantee every consumer is modern; move to zstd for internal fleets where you control the runtime version. `estargz`/`zstd:chunked` go further by making layers *seekable* so the runtime can start a container before the layer finishes downloading (lazy pulling) — valuable for large images and cold-start-sensitive workloads, at the cost of specialized snapshotter support (`stargz-snapshotter`).

---

## 4. The OCI image layout on disk

The **image-layout** is how an image is serialized to a directory or a `.tar` (what `docker save`, `skopeo copy oci:...`, and `--output type=oci` produce). Three things at the root:

```
$ tree bundle/
bundle/
├── oci-layout
├── index.json
└── blobs/
    └── sha256/
        ├── 7d3a...          # a manifest
        ├── b1e9...          # the config
        ├── 2d42...          # a layer
        ├── 8a17...          # a layer
        └── f6bd...          # a layer
```

- `oci-layout` — a one-line JSON marker: `{"imageLayoutVersion": "1.0.0"}`.
- `index.json` — the entry point (same schema as an image index); its `manifests[]` descriptors, resolved by digest, point into `blobs/`.
- `blobs/sha256/<hex>` — **every** object (manifests, configs, layers) stored flat, filename = its digest hex. Fully content-addressable, self-verifying.

```
$ cat bundle/oci-layout
{"imageLayoutVersion":"1.0.0"}

$ cat bundle/index.json | jq '.manifests[0]'
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "digest": "sha256:7d3a...",
  "size": 1024,
  "annotations": { "org.opencontainers.image.ref.name": "1.7.3" }
}

# The file's own name equals its digest — verify integrity locally, no registry needed:
$ sha256sum bundle/blobs/sha256/7d3a... | cut -d' ' -f1
7d3a...
```

This layout is what CI systems hand between build and push steps, and what air-gapped promotion pipelines carry across trust boundaries as a single tarball.

---

## 5. Building OCI images: tool trade-offs

There is no single "correct" builder; the choice is driven by *where the build runs* (privileged host vs unprivileged CI vs in-cluster) and *what you are packaging*.

| Tool | Daemon? | Root/privileged needed? | Dockerfile? | Native multi-arch | Best-fit production scenario |
|---|---|---|---|---|---|
| **Docker + BuildKit (`buildx`)** | daemon (rootless mode exists) | traditionally yes; rootless removes it | yes | yes (`--platform`, QEMU or remote nodes) | dev laptops, general CI with a Docker host |
| **Buildah** | daemonless | rootless-capable | yes (or scriptable, no Dockerfile) | yes | RHEL/OpenShift build pipelines, fine-grained scripted builds |
| **Kaniko** | none | **no privileged daemon** — runs as a normal pod | yes | one arch per run (matrix for multi) | building **inside** a Kubernetes cluster with no Docker socket |
| **ko** | none | no | **no** (Go toolchain) | yes | Go microservices; fast, reproducible, distroless base, no Dockerfile drift |
| **Jib (Maven/Gradle)** | none | no | no | yes | Java apps; reproducible layered images from the build tool |
| **Cloud Native Buildpacks (`pack`)** | uses a builder image | no | **no** (auto-detect) | yes | polyglot platforms wanting no per-team Dockerfiles; rebase for fast base-image CVE patching |
| **BuildKit standalone (`buildctl`)** | `buildkitd` | rootless-capable | yes (LLB frontends) | yes | the engine under buildx; direct use in advanced CI |

**Key architectural point — the daemon and privilege problem.** In a Kubernetes CI cluster you generally do **not** want to mount the host's Docker socket into a build pod (that is root on the node). Kaniko and Buildah-rootless and BuildKit-rootless solve exactly this: they execute the build steps in userspace without a privileged daemon. This is the dominant reason teams move off `docker build` for in-cluster CI.

**Reproducibility.** Two builds of the same source should produce byte-identical layers (same digests) so you can prove provenance and get cache hits. The enemies are embedded timestamps and non-deterministic file ordering. Controls: `SOURCE_DATE_EPOCH` to pin timestamps, deterministic layer ordering (ko/Jib/Buildpacks do this by construction), and BuildKit's `--output ...,rewrite-timestamp=true`. Reproducibility is what makes `diff_ids` comparable across independent builders.

### 5.1 Multi-stage build → minimal, non-root, pinned base

```dockerfile
# syntax=docker/dockerfile:1.7

# ---- build stage: full toolchain, thrown away ----
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
# Reproducible, static binary; secrets mounted, never layered:
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=secret,id=npmrc,target=/root/.npmrc \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

# ---- runtime stage: distroless, non-root, pinned by digest ----
FROM gcr.io/distroless/static-debian12:nonroot@sha256:3f2b...   AS runtime
COPY --from=build /out/server /app/server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/server"]
CMD ["--config", "/etc/app/config.yaml"]
```

Why this shape matters for the artifact: the toolchain layers exist only in the `build` stage and never enter the final manifest's `layers[]`, so they never ship and never inflate your attack surface or pull time. The base is **pinned by digest**, so the final image ID is stable and auditable. `USER` is baked into the config (`config.User`), so the container cannot run as root even if the Pod spec forgets `securityContext`.

Build it multi-arch and push directly, using build secrets so `.npmrc` never lands in a layer:

```
$ docker buildx create --name multi --driver docker-container --use
$ echo "//registry.npmjs.org/:_authToken=..." > /tmp/npmrc
$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --secret id=npmrc,src=/tmp/npmrc \
    --provenance=true --sbom=true \
    -t registry.example.com/acme/api:1.7.3 \
    --push .
[+] Building 41.7s (23/23) FINISHED
 => [linux/amd64 build 6/6] RUN ... go build ...                   12.3s
 => [linux/arm64 build 6/6] RUN ... go build ...                   18.9s
 => exporting to image                                              6.1s
 => => exporting manifest list sha256:44ab...                      0.0s
 => => pushing layers                                              4.2s
 => => pushing manifest for registry.example.com/acme/api:1.7.3@sha256:44ab...
```

`--provenance=true --sbom=true` attach an in-toto provenance attestation and an SBOM as **extra manifests in the index** (the `attestation-manifest` entry you saw in §2.5) — supply-chain metadata travels with the image, addressed by the same digest graph.

---

## 6. Distribution: pushing and pulling over the wire

The **Distribution Specification** is a small, purely HTTP, content-addressable API rooted at `/v2/`. Every real registry (Harbor, Quay, ECR, GCR, GHCR, Zot, `distribution/distribution`) implements it. The endpoints you must recognize:

| Method + path | Purpose |
|---|---|
| `GET /v2/` | API version check / auth challenge (returns `200` or `401` with `WWW-Authenticate`). |
| `HEAD/GET /v2/<name>/blobs/<digest>` | Fetch or existence-check a blob (layer/config). |
| `POST /v2/<name>/blobs/uploads/` | Begin a blob upload (returns a session `Location`). |
| `PUT /v2/<name>/blobs/uploads/<uuid>?digest=<d>` | Finalize a blob upload, verified against `<d>`. |
| `POST .../blobs/uploads/?mount=<digest>&from=<repo>` | **Cross-repo mount** — reuse an existing blob without re-uploading. |
| `PUT /v2/<name>/manifests/<ref>` | Push a manifest by tag or digest. |
| `GET /v2/<name>/manifests/<ref>` | Pull a manifest (respect the `Accept` header for media-type negotiation). |
| `GET /v2/<name>/tags/list` | List tags. |
| `GET /v2/<name>/referrers/<digest>` | **OCI 1.1** — list artifacts (signatures, SBOMs) that reference a subject. |

**Critical ordering rule:** you **push blobs first, manifest last**. A manifest references blobs by digest; a well-behaved registry rejects a manifest whose referenced blobs are not already present with `MANIFEST_BLOB_UNKNOWN`. Pulling is the mirror: fetch the manifest, then fetch each referenced blob (skipping any already cached by digest — this is why re-pulling a shared base layer is free).

### 6.1 The auth challenge (the flow behind `docker login`)

```
$ curl -s -i https://registry.example.com/v2/
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer realm="https://registry.example.com/token",service="registry.example.com"
Docker-Distribution-Api-Version: registry/2.0

# The client then fetches a scoped token and retries with a Bearer header:
$ TOKEN=$(curl -s "https://registry.example.com/token?service=registry.example.com&scope=repository:acme/api:pull" \
          -u "$USER:$PASS" | jq -r .token)
$ curl -s -H "Authorization: Bearer $TOKEN" \
       -H "Accept: application/vnd.oci.image.index.v1+json" \
       https://registry.example.com/v2/acme/api/manifests/1.7.3 | jq .mediaType
"application/vnd.oci.image.index.v1+json"
```

Note the `Accept` header — **content negotiation** is how the same tag can hand back an OCI index to a modern client and a Docker manifest list to an old one, if the registry stores both.

### 6.2 Referrers API — attaching signatures/SBOMs without mutating the image

OCI 1.1 lets an artifact declare a `subject` (a descriptor pointing at the image it describes). The registry indexes these so `GET /referrers/<image-digest>` returns everything attached to that image — cosign signatures, SBOMs, VEX docs — **without changing the image's own digest**. This is the modern, tag-free replacement for the old `sha256-<digest>.sig` tag convention and is what `cosign` and `oras` use.

---

## 7. Inspecting images without pulling them: `skopeo` and `crane`

These two tools operate directly against the distribution API, so you can inspect, copy, and diff images **without a container runtime and often without downloading layers** — essential on a locked-down bastion or in CI.

### 7.1 `crane` — surgical inspection

```
$ crane digest registry.example.com/acme/api:1.7.3
sha256:44ab...                       # digest of the INDEX (what to pin for multi-arch)

$ crane digest --platform linux/amd64 registry.example.com/acme/api:1.7.3
sha256:7d3a...                       # digest of the amd64 MANIFEST

$ crane manifest registry.example.com/acme/api:1.7.3 | jq '.mediaType, (.manifests|length)'
"application/vnd.oci.image.index.v1+json"
3

$ crane config registry.example.com/acme/api:1.7.3 | jq '.config.User, .config.Entrypoint'
"65532:65532"
[ "/app/server" ]

$ crane ls registry.example.com/acme/api
1.7.1
1.7.2
1.7.3
latest

# Enumerate layers of the amd64 variant, smallest-first:
$ crane manifest --platform linux/amd64 registry.example.com/acme/api:1.7.3 \
    | jq -r '.layers[] | "\(.size)\t\(.digest)"' | sort -n
3408729    sha256:f6bd...
8123094    sha256:8a17...
30457821   sha256:2d42...
```

### 7.2 `skopeo` — inspect, copy across registries, transport-to-transport

```
$ skopeo inspect docker://registry.example.com/acme/api:1.7.3 | jq '{Digest, Architecture, Os, Layers: (.Layers|length)}'
{
  "Digest": "sha256:7d3a...",
  "Architecture": "amd64",
  "Os": "linux",
  "Layers": 3
}

# See the RAW index (multi-arch) rather than a resolved single manifest:
$ skopeo inspect --raw docker://registry.example.com/acme/api:1.7.3 | jq '.manifests[].platform'
{ "architecture": "amd64", "os": "linux" }
{ "architecture": "arm64", "os": "linux" }
{ "architecture": "unknown", "os": "unknown" }

# Copy registry → registry with NO local Docker, preserving the multi-arch index:
$ skopeo copy --all \
    docker://registry.example.com/acme/api:1.7.3 \
    docker://mirror.internal.net/acme/api:1.7.3
Getting image list signatures
Copying 2 of 2 images in list
Copying image sha256:7d3a... (1/2)
Copying image sha256:9f21... (2/2)
Writing manifest list to image destination

# Export to an OCI layout directory (the format from §4) for air-gapped transport:
$ skopeo copy docker://registry.example.com/acme/api:1.7.3 oci:/tmp/api-oci:1.7.3
$ ls /tmp/api-oci
blobs  index.json  oci-layout
```

`--all` is the flag people forget: without it, `skopeo copy` resolves to *your host's* platform and silently drops the other architectures from a multi-arch image — a classic "works on my amd64 laptop, `exec format error` on the arm64 node" production incident.

---

## 8. Verification & failure diagnosis

This is where the exam weight and the on-call pager overlap. Map the symptom to the layer of the stack that owns it.

### 8.1 `exec format error` — architecture mismatch

**Symptom:** container crash-loops; kubelet events show `exec /app/server: exec format error`.
**Cause:** the pulled manifest is for a different CPU architecture than the node (amd64 image on arm64 node, or vice versa), usually from a single-arch push or a `skopeo copy` without `--all`.

```
$ kubectl get pod api-7c9 -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
exec /app/server: exec format error

# What arch is the NODE?
$ kubectl get node ip-10-0-3-11 -o jsonpath='{.status.nodeInfo.architecture}'
arm64

# What arches does the IMAGE actually offer?
$ crane manifest registry.example.com/acme/api:1.7.3 \
    | jq -r 'if .manifests then .manifests[].platform.architecture else .architecture end'
amd64          # ← only amd64 shipped; arm64 node cannot run it
```

**Fix:** rebuild multi-arch (`buildx --platform linux/amd64,linux/arm64`), or constrain scheduling with `nodeSelector: kubernetes.io/arch: amd64` until the image is fixed.

### 8.2 `manifest unknown` / `unsupported media type`

**Symptom:** `docker pull` / kubelet fails with `manifest unknown` or `unsupported MediaType`.
**Cause (usual):** the registry or the runtime does not understand the manifest's media type — an OCI index pushed to an old registry that only speaks Docker manifest lists, or `+zstd` layers hitting a runtime that only handles gzip.

```
$ crane manifest registry.example.com/acme/api:1.7.3 | jq -r '.mediaType, (.layers[].mediaType // empty)'
application/vnd.oci.image.index.v1+json
application/vnd.oci.image.layer.v1.tar+zstd     # ← old containerd chokes here

# Re-export with gzip layers and Docker-compatible types for the lagging consumer:
$ skopeo copy --format v2s2 --dest-compress-format gzip \
    docker://registry.example.com/acme/api:1.7.3 \
    docker://legacy-registry.internal/acme/api:1.7.3
```

### 8.3 Blob / digest integrity failure

**Symptom:** pull aborts mid-transfer: `failed to verify blob sha256:…: expected sha256:AAAA got sha256:BBBB`.
**Cause:** corruption in transit, a broken CDN/mirror serving stale bytes, or a registry storage fault. The digest check is doing its job — it refused to hand the runtime the wrong bytes.

```
$ crane blob registry.example.com/acme/api@sha256:f6bd... > /tmp/layer.tgz
$ sha256sum /tmp/layer.tgz
f6bd...  /tmp/layer.tgz          # matches → the blob in THIS registry is intact

# If it did NOT match, the registry/mirror is serving corruption. Verify a manifest end-to-end:
$ curl -s -H "Authorization: Bearer $TOKEN" \
     https://registry.example.com/v2/acme/api/manifests/sha256:7d3a... \
   | sha256sum
7d3a...          # must equal the digest you requested, or the manifest is corrupt/tampered
```

### 8.4 `MANIFEST_BLOB_UNKNOWN` on push

**Symptom:** push fails at the manifest step even though layers "uploaded."
**Cause:** you attempted to `PUT` a manifest whose referenced blobs aren't fully present (interrupted layer upload, or wrong push order). Re-push; the blobs already present are skipped, only the missing one re-uploads.

### 8.5 `ImagePullBackOff` — is it the image or the credentials?

**Symptom:** Pod stuck in `ImagePullBackOff`.
**Triage:** read the *event*, don't guess.

```
$ kubectl describe pod api-7c9 | sed -n '/Events/,$p'
Events:
  Warning  Failed   kubelet  Failed to pull image "registry.example.com/acme/api:1.7.3":
           failed to resolve reference: pull access denied, insufficient scope, authorization failed
```

`pull access denied / unauthorized` → registry auth (`imagePullSecrets` missing/expired). `not found / manifest unknown` → wrong tag or image never pushed. `context deadline exceeded` → network/registry availability, not the image. Confirm the image is actually reachable with the pull path, independent of the cluster:

```
$ crane manifest registry.example.com/acme/api:1.7.3 >/dev/null && echo "image OK" || echo "image problem"
image OK
```

### 8.6 Proving two images share a filesystem (or don't)

To prove `:1.7.3` and `:latest` are the *same build*, compare the **config digest** (image ID). To prove they share a base independent of compression, compare `diff_ids`:

```
$ crane digest --platform linux/amd64 registry.example.com/acme/api:1.7.3
sha256:7d3a...
$ crane digest --platform linux/amd64 registry.example.com/acme/api:latest
sha256:7d3a...                       # identical → same manifest, same bytes, same build

$ diff \
   <(crane config --platform linux/amd64 registry.example.com/acme/api:1.7.3 | jq -r '.rootfs.diff_ids[]') \
   <(crane config --platform linux/amd64 registry.example.com/base/distroless:latest | jq -r '.rootfs.diff_ids[]')
# no output → the base's diff_ids are a prefix of the app's → they share the base filesystem exactly
```

### 8.7 Signature / provenance verification (supply chain)

Pinning by digest guarantees *immutability*, not *authenticity* — you still need to know the digest was produced and signed by your pipeline. `cosign` verifies the signature attached via the referrers graph:

```
$ cosign verify \
    --certificate-identity-regexp 'https://github.com/acme/.+/.github/workflows/.+' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/acme/api@sha256:7d3a... | jq '.[].optional.Issuer'

Verification for registry.example.com/acme/api@sha256:7d3a... --
The following checks were performed on the signature:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The signing certificate was verified against the Fulcio root
"https://token.actions.githubusercontent.com"
```

Enforce this at admission (Sigstore Policy Controller / Kyverno `verifyImages`) so **unsigned or wrong-identity images cannot schedule** — the artifact's digest, signature, and policy close the loop from build to runtime.

---

## 9. Production checklist for OCI images

- **Pin by digest** (`image@sha256:...`) in Deployments; treat tags as human labels only.
- **Build multi-arch** if any node arch differs from the build host; verify with `crane manifest | jq '.manifests[].platform'`.
- **Never introduce secrets into a layer** — use `--mount=type=secret` and multi-stage; remember whiteouts *hide*, they do not *delete*.
- **Prefer minimal, digest-pinned bases** (distroless/scratch) and a non-root `config.User` baked in.
- **Attach and enforce** an SBOM + provenance + signature via the referrers graph; verify at admission.
- **Register every cert/lang combo you build in the audit `TARGETS`** so "0 corrupt" actually means something.
- **Diagnose from the descriptor down:** media type → platform → digest → blob integrity. Each failure class lives at exactly one of those rungs.

---

## Referencias

- OCI Image Specification — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Image Manifest — https://github.com/opencontainers/image-spec/blob/main/manifest.md
- OCI Image Index — https://github.com/opencontainers/image-spec/blob/main/image-index.md
- OCI Image Configuration — https://github.com/opencontainers/image-spec/blob/main/config.md
- OCI Image Layout — https://github.com/opencontainers/image-spec/blob/main/image-layout.md
- OCI Layer / changeset (whiteouts) — https://github.com/opencontainers/image-spec/blob/main/layer.md
- OCI Descriptor — https://github.com/opencontainers/image-spec/blob/main/descriptor.md
- OCI Distribution Specification — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI Runtime Specification — https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- Open Container Initiative — https://opencontainers.org/
- CNCF KCA Curriculum — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf
- `crane` (go-containerregistry) — https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md
- `skopeo` — https://github.com/containers/skopeo/blob/main/docs/skopeo.1.md
- BuildKit / `buildx` — https://docs.docker.com/build/buildkit/
- Kaniko — https://github.com/GoogleContainerTools/kaniko
- Buildah — https://buildah.io/
- `ko` — https://ko.build/
- Cloud Native Buildpacks — https://buildpacks.io/
- Sigstore `cosign` — https://docs.sigstore.dev/cosign/signing/signing_with_containers/
- ORAS (OCI artifacts) — https://oras.land/
- Distroless base images — https://github.com/GoogleContainerTools/distroless