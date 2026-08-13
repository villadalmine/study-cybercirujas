# Tema 1.4 — OCI Images: Guided Exercises

> **Peso en el examen: 4.5** · Certificación KCA
> Estos labs asumen un host Linux con `crane`, `skopeo`, `buildah`, `jq`, `dive`, `cosign` y `syft` instalados, y salida de red hacia Docker Hub / GHCR. Todos los comandos corren **rootless** salvo que se indique lo contrario. Ninguno necesita un Docker daemon: trabajamos contra el registry por HTTP y contra el OCI layout en disco, que es lo que el examen KCA evalúa.
>
> Fuentes de referencia usadas a lo largo del tema:
> - OCI Image Format Specification — https://github.com/opencontainers/image-spec/blob/main/spec.md
> - OCI Image Manifest — https://github.com/opencontainers/image-spec/blob/main/manifest.md
> - OCI Image Index — https://github.com/opencontainers/image-spec/blob/main/image-index.md
> - OCI Image Configuration — https://github.com/opencontainers/image-spec/blob/main/config.md
> - OCI Image Layout — https://github.com/opencontainers/image-spec/blob/main/image-layout.md
> - OCI Distribution Specification — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
> - Sigstore / cosign — https://docs.sigstore.dev/cosign/signing/overview/

---

## Exercise 1 — Anatomy of an OCI image: manifest, config and layers

**Goal:** stop treating an image as an opaque blob. An OCI image is a small JSON *manifest* that points, by content digest, to one config blob and N layer blobs. You will read each of those objects directly from the registry.

1. Fetch the raw manifest of a small image and pretty-print it. `crane` speaks the OCI Distribution API directly — no local daemon, no `docker pull`:

   ```bash
   crane manifest alpine:3.19 | jq .
   ```

   Expected (digests truncated for readability):

   ```json
   {
     "schemaVersion": 2,
     "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
     "config": {
       "mediaType": "application/vnd.docker.container.image.v1+json",
       "size": 1471,
       "digest": "sha256:05455a08881e...c9d3f7"
     },
     "layers": [
       {
         "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
         "size": 3401967,
         "digest": "sha256:4abcf2066143...b1e9a2"
       }
     ]
   }
   ```

2. Note the `mediaType`. Docker Hub still serves many images in the **Docker schema 2** media types, not the OCI ones. Ask the registry for the OCI-native equivalent of the same content by inspecting a known OCI image and comparing:

   ```bash
   crane manifest gcr.io/distroless/static:nonroot | jq -r '.mediaType, .config.mediaType, .layers[].mediaType'
   ```

   Expected:

   ```
   application/vnd.oci.image.manifest.v1+json
   application/vnd.oci.image.config.v1+json
   application/vnd.oci.image.layer.v1.tar+gzip
   ```

3. Resolve the manifest's own **content digest** (the immutable identity of the image) and compare it to the mutable tag:

   ```bash
   crane digest alpine:3.19
   ```

   ```
   sha256:c5b1261d6d3e43071626931fc004f70149baeba2c8ec672bd4f27761f8e1ad6b
   ```

4. Now pull the **config blob** the manifest points to and read it. This is the `application/vnd.oci.image.config.v1+json` object — the runtime contract:

   ```bash
   crane config alpine:3.19 | jq '{architecture, os, config: .config, rootfs: .rootfs, history: (.history | length)}'
   ```

   Expected (abbreviated):

   ```json
   {
     "architecture": "amd64",
     "os": "linux",
     "config": {
       "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
       "Cmd": ["/bin/sh"]
     },
     "rootfs": {
       "type": "layers",
       "diff_ids": ["sha256:63ca1fbb43ae...5f2c1a"]
     },
     "history": 2
   }
   ```

5. Compare the digest in `.layers[0].digest` (from step 1) with the digest in `.rootfs.diff_ids[0]` (from step 4). Write both down. They are **not** equal.

**Verification questions (block 1):**

- **Q1.1** — The tag `alpine:3.19` and the digest `sha256:c5b1261d…` both name "the same image" right now. What is the operational difference between pinning a deployment to the tag versus to the digest, and which does a `kubernetes` `Pod` spec resolve to at admission?
- **Q1.2** — The manifest's `.layers[0].digest` and the config's `.rootfs.diff_ids[0]` describe the *same* layer yet differ. What exactly is each digest computed over, and why must they differ?
- **Q1.3** — You changed only the image's `CMD` (nothing in the filesystem). Which of these change: the config blob digest, the layer digests, the manifest digest? Explain the propagation.
- **Q1.4** — A registry client requests `GET /v2/library/alpine/blobs/sha256:4abcf2…` and the returned bytes hash to a *different* digest. Per the OCI Distribution Spec, what must the client do, and what property of the system makes this check possible without trusting the registry?

---

## Exercise 2 — Layers are filesystem changesets: whiteouts and `diff_id`

**Goal:** see, byte for byte, that a layer is a tar of *changes* over the layer below it — additions, modifications, and deletions encoded as whiteout files.

1. Export a tiny multi-layer image to a local OCI layout so you can open the blobs by hand:

   ```bash
   skopeo copy docker://busybox:1.36 oci:busybox-oci:1.36
   ls busybox-oci
   ```

   ```
   blobs  index.json  oci-layout
   ```

2. Read the top-level `index.json` and the `oci-layout` marker that make this a valid **OCI Image Layout**:

   ```bash
   cat busybox-oci/oci-layout; echo
   jq -r '.manifests[0].mediaType, .manifests[0].digest' busybox-oci/index.json
   ```

   ```
   {"imageLayoutVersion":"1.0.0"}
   application/vnd.oci.image.manifest.v1+json
   sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7
   ```

3. Build an image whose layers *delete* and *replace* files so the changeset is interesting. Use `buildah` with a heredoc Dockerfile (rootless, no daemon):

   ```bash
   cat > Containerfile <<'EOF'
   FROM busybox:1.36
   RUN mkdir -p /data && echo "v1" > /data/keep.txt && echo "secret" > /data/remove.txt
   RUN rm /data/remove.txt && echo "v2" > /data/keep.txt
   EOF
   buildah build --layers -t layers-demo:local -f Containerfile .
   ```

   Expected tail:

   ```
   COMMIT layers-demo:local
   Successfully tagged localhost/layers-demo:local
   3f2a...e91
   ```

4. Dump the manifest of the image you just built and extract the **last** layer blob (the one created by the `rm` + rewrite step):

   ```bash
   buildah push layers-demo:local oci:demo-oci:local
   LAST=$(jq -r '.layers[-1].digest' \
     "demo-oci/blobs/sha256/$(jq -r '.manifests[0].digest' demo-oci/index.json | cut -d: -f2)")
   echo "$LAST"
   tar -tvf "demo-oci/blobs/sha256/${LAST#sha256:}" | grep data
   ```

   Expected (the deletion appears as a `.wh.` whiteout entry, the rewrite as a normal file):

   ```
   sha256:71b0c9...aa
   -rw-r--r-- 0/0   3 2026-08-13 00:00 data/keep.txt
   -rw-r--r-- 0/0   0 2026-08-13 00:00 data/.wh.remove.txt
   ```

5. Confirm that deleting a file does **not** shrink the image. Compare the total image size to the sum of all layers — the earlier layer that *added* `remove.txt` is still present and still downloaded:

   ```bash
   dive layers-demo:local --ci 2>/dev/null | grep -E 'efficiency|wasted' || \
     crane manifest layers-demo:local 2>/dev/null | jq '[.layers[].size] | add'
   ```

**Verification questions (block 2):**

- **Q2.1** — In the last layer's tar you saw `data/.wh.remove.txt` with size 0. What does that entry instruct the layer-stacking engine (e.g. overlayfs) to do, and where does the *real* `remove.txt` still live?
- **Q2.2** — A `RUN rm -rf /var/cache/...` in the final line of a Dockerfile is a classic mistake for shrinking an image. Given what you saw, why does it fail to reduce the pulled bytes, and what technique (single-`RUN` chaining, multi-stage, `--squash`) actually removes the data?
- **Q2.3** — What is the difference between a `.wh.<name>` whiteout and a `.wh..wh..opq` **opaque** whiteout? Give a filesystem operation that produces each.
- **Q2.4** — The `diff_id` in the config is the digest of the *uncompressed* tar, while the manifest layer digest is over the *gzipped* tar. Which of the two is used to compute the overlay **chainID**, and why can two different registries serving the same logical layer legitimately have different manifest layer digests but identical `diff_id`s?

---

## Exercise 3 — Multi-arch images: the image index (manifest list)

**Goal:** understand that `nginx:latest` is usually not one image but an **image index** — a list of per-platform manifests. A `kubernetes` node pulls the entry matching its own `architecture`/`os`.

1. Inspect the index of a well-known multi-arch image and list every platform it advertises:

   ```bash
   crane manifest --platform all nginx:1.27 | jq -r '.mediaType'
   crane manifest nginx:1.27 | jq -r '.manifests[] | "\(.platform.os)/\(.platform.architecture)\(.platform.variant // "") \(.digest)"'
   ```

   Expected:

   ```
   application/vnd.oci.image.index.v1+json
   linux/amd64 sha256:e8b9f6...11
   linux/arm/v5 sha256:2c1d44...02
   linux/arm/v7 sha256:9f0a7b...c3
   linux/arm64/v8 sha256:44ad12...9e
   linux/386 sha256:71cc90...aa
   linux/mips64le sha256:0b3e5f...7d
   linux/ppc64le sha256:5a2b81...4f
   linux/s390x sha256:c9d0e2...6b
   ```

2. Notice there are also entries with `platform.os == "unknown"`. List them — these are **attestation manifests** (SBOM / provenance) attached via the referrers mechanism, not runnable images:

   ```bash
   crane manifest nginx:1.27 | jq -r '.manifests[] | select(.platform.os=="unknown") | .annotations'
   ```

   ```
   { "vnd.docker.reference.digest": "sha256:44ad12...9e", "vnd.docker.reference.type": "attestation-manifest" }
   ```

3. Resolve the *concrete* single-arch manifest a linux/arm64 node would actually run, by digest, and confirm its config reports the right architecture:

   ```bash
   ARM64=$(crane manifest nginx:1.27 | jq -r '.manifests[] | select(.platform.architecture=="arm64") | .digest')
   crane config "nginx@${ARM64}" | jq '{architecture, os, variant}'
   ```

   ```json
   { "architecture": "arm64", "os": "linux", "variant": "v8" }
   ```

4. Build your own two-platform index locally and push it, to prove the index is just a small JSON object you assemble:

   ```bash
   buildah build --platform linux/amd64,linux/arm64 --manifest myapp:multi -f Containerfile .
   buildah manifest inspect myapp:multi | jq -r '.manifests[] | "\(.platform.architecture) \(.mediaType)"'
   ```

   ```
   amd64 application/vnd.oci.image.manifest.v1+json
   arm64 application/vnd.oci.image.manifest.v1+json
   ```

**Verification questions (block 3):**

- **Q3.1** — A `Pod` on an `arm64` node references `nginx:1.27` by tag. Trace what the kubelet's container runtime does: how many round-trips to the registry, and which digest ends up recorded in the Pod status `imageID`?
- **Q3.2** — You pin your Deployment to `nginx@sha256:<index-digest>` (the index digest, not a per-arch digest). Is this still portable across amd64 and arm64 nodes? What breaks if instead you pin to the amd64 *child* manifest digest?
- **Q3.3** — What distinguishes a `manifests[]` entry that is a runnable platform image from one that is an attestation? Name the fields you'd filter on.
- **Q3.4** — An `arm64` node fails to schedule an image that only advertises `linux/amd64`. At what layer does the failure surface (scheduler, kubelet, runtime), and what is the exact error class?

---

## Exercise 4 — Reproducibility, caching and provenance of a build

**Goal:** reason about *why* an image has the digest it has, and make a build deterministic enough that the same inputs yield the same bytes.

1. Build the same trivial image twice and observe that the digests differ even though nothing "changed":

   ```bash
   cat > Containerfile <<'EOF'
   FROM gcr.io/distroless/static:nonroot
   COPY hello /hello
   ENTRYPOINT ["/hello"]
   EOF
   echo hi > hello
   buildah build -t repro:a -f Containerfile . && crane digest --tarball <(buildah push repro:a docker-archive:- 2>/dev/null) 2>/dev/null || buildah images --format '{{.Digest}}' repro:a
   sleep 1
   buildah build --no-cache -t repro:b -f Containerfile .
   buildah images --format '{{.Name}} {{.Digest}}' | grep repro
   ```

   The two digests differ, primarily because the config's `created` timestamp and layer mtimes are non-deterministic.

2. Force determinism. Rebuild pinning the source epoch and the base image **by digest**, and normalizing timestamps:

   ```bash
   BASE=$(crane digest gcr.io/distroless/static:nonroot)
   cat > Containerfile <<EOF
   FROM gcr.io/distroless/static@${BASE}
   COPY hello /hello
   ENTRYPOINT ["/hello"]
   EOF
   export SOURCE_DATE_EPOCH=1700000000
   buildah build --timestamp "$SOURCE_DATE_EPOCH" --no-cache -t repro:c -f Containerfile .
   buildah build --timestamp "$SOURCE_DATE_EPOCH" --no-cache -t repro:d -f Containerfile .
   buildah images --format '{{.Name}} {{.Digest}}' | grep -E 'repro:(c|d)'
   ```

   Expected: `repro:c` and `repro:d` now share the **same** digest.

3. Inspect where the timestamp lives so you understand *what* you normalized:

   ```bash
   buildah inspect --format '{{.OCIv1.Created}}' repro:c
   ```

   ```
   2023-11-14T22:13:20Z
   ```

4. Read the **history** of the config — the provenance trail of how each layer was produced — and spot the empty (metadata-only) entries:

   ```bash
   crane config gcr.io/distroless/static:nonroot 2>/dev/null | jq -r '.history[] | "\(.created_by)  empty=\(.empty_layer // false)"' | tail -5
   ```

**Verification questions (block 4):**

- **Q4.1** — Two builds from identical source produced different manifest digests in step 1. List every non-deterministic input that typically causes this and how each is neutralized.
- **Q4.2** — Why is pinning `FROM ...@sha256:<digest>` a *correctness* requirement for reproducibility, not just a security nicety? What happens to your build if the base tag is re-pushed upstream?
- **Q4.3** — `.history[]` has entries with `empty_layer: true`. What kind of Dockerfile instructions create these, and why do they still change the image digest despite adding no layer blob?
- **Q4.4** — A colleague argues "the digest is a hash of the tarball, so byte-identical filesystems must give identical digests." Where is this wrong? Name the two JSON objects (besides layer blobs) that feed the final manifest digest.

---

## Exercise 5 — Content trust: signing and SBOM with cosign

**Goal:** an image digest proves *integrity* (the bytes are what the manifest says) but not *authenticity* (who produced them). Close that gap with a signature and attach a bill of materials.

1. Push your test image to a registry you control (here a local `zot`/`registry:2` on `localhost:5000`) so it has a real, addressable digest to sign:

   ```bash
   skopeo copy --dest-tls-verify=false oci:demo-oci:local docker://localhost:5000/demo:1.0
   DIGEST=$(crane digest --insecure localhost:5000/demo:1.0)
   echo "$DIGEST"
   ```

2. Sign it with a **key pair** (the classic model). Always sign the digest, never the tag:

   ```bash
   cosign generate-key-pair
   cosign sign --key cosign.key --tlog-upload=false "localhost:5000/demo@${DIGEST}"
   ```

   ```
   Pushing signature to: localhost:5000/demo
   ```

3. Verify. A tampered or unsigned image fails loudly, non-zero:

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog=true "localhost:5000/demo@${DIGEST}" | jq '.[0].optional'
   ```

   ```json
   { "Bundle": { "SignedEntryTimestamp": "..." } }
   ```

4. Generate an SBOM from the image and attach it as an **attestation** bound to the same digest:

   ```bash
   syft "localhost:5000/demo@${DIGEST}" -o spdx-json > sbom.spdx.json
   cosign attest --key cosign.key --predicate sbom.spdx.json \
     --type spdxjson --tlog-upload=false "localhost:5000/demo@${DIGEST}"
   ```

5. Discover what is attached to the image using the **referrers** API (OCI Distribution v1.1) — signatures and attestations are themselves images that *refer* to the subject digest:

   ```bash
   cosign tree "localhost:5000/demo@${DIGEST}"
   ```

   ```
   📦 Supply Chain Security Related artifacts for an image: localhost:5000/demo@sha256:...
   └── 🔐 Signatures for an image tag: localhost:5000/demo:sha256-...sig
   └── 💾 Attestations for an image tag: localhost:5000/demo:sha256-...att
   ```

**Verification questions (block 5):**

- **Q5.1** — Why does cosign refuse-by-convention to sign a *tag* and insist on a digest? Construct the attack that signing a tag would enable.
- **Q5.2** — In **keyless** (Fulcio/OIDC) signing there is no long-lived private key. What replaces it as the root of trust, and which two `cosign verify` flags become mandatory (`--certificate-identity`, `--certificate-oidc-issuer`) and why?
- **Q5.3** — A signature and an SBOM attestation are stored *in the registry* alongside the image. How are they associated with the subject image — by tag naming convention, by the referrers API, or both — and what does that imply for a `kubernetes` admission controller (e.g. `policy-controller` / `kyverno`) verifying at deploy time?
- **Q5.4** — Signature verification passes but the SBOM lists a vulnerable `openssl`. Does a green `cosign verify` tell you the image is safe? Precisely state what a valid signature does and does not attest.

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — Manifest, config and layers

**A1.1** — A **tag** is a mutable pointer in the registry; the maintainer can re-push `alpine:3.19` tomorrow and it will resolve to different bytes. A **digest** (`sha256:c5b1261d…`) is the content-address of the manifest and is immutable — the same digest always names the same bytes or the registry rejects it. In a Pod spec you may *write* either form (`image: alpine:3.19` or `image: alpine@sha256:…`). The kubelet resolves a tag to a concrete digest at pull time and records the resolved digest in `status.containerStatuses[].imageID`. Pinning by digest gives reproducible, tamper-evident deployments; pinning by tag is convenient but non-deterministic across pulls (and interacts with `imagePullPolicy`). *(image-spec: descriptors; distribution-spec: content-addressable pulls.)*

**A1.2** — The **manifest layer digest** is the SHA-256 of the *compressed* layer blob (the gzipped tar as it travels over the wire and sits in the registry). The config's **`diff_id`** is the SHA-256 of the *uncompressed* tar (the applied filesystem changeset). They describe the same layer at two stages of processing, so they cannot be equal. The compressed digest identifies the transport/storage artifact; the `diff_id` identifies the filesystem content and is what the runtime uses to build the rootfs. *(config.md: `rootfs.diff_ids`; manifest.md: layer descriptors.)*

**A1.3** — Changing `CMD` mutates the **config blob** → its digest changes. The manifest's `.config.digest` points at that config, so the **manifest digest** also changes. The **layer digests do not change** — no filesystem bytes moved. This is the whole point of content-addressing: metadata-only edits produce a new image identity while *reusing every existing layer blob* (the registry deduplicates them and clients skip re-downloading), which is why a `CMD`/`ENV` change is nearly free to push and pull.

**A1.4** — The client must **reject the blob and error out** (treat the pull as failed / corrupt). The OCI Distribution Spec requires the returned content to hash to the requested digest; because the identifier *is* the hash, the client verifies integrity end-to-end without trusting the registry, the CDN, or the transport. This is what lets you safely pull from an untrusted mirror: tampering changes the digest, and the change is detected locally.

### Block 2 — Layers as changesets

**A2.1** — `data/.wh.remove.txt` is a **whiteout**: it tells the union/overlay engine "in the merged view, `remove.txt` does not exist," masking the file that a lower layer added. The real `remove.txt` bytes are **still present in the earlier layer** that created it; the whiteout only hides it at runtime. Nothing is physically deleted from the image. *(image-spec layer.md: whiteouts.)*

**A2.2** — Because the file still lives in the earlier layer blob, which is still part of the manifest and still pulled, the image size is unchanged and a `rm` only adds a tiny whiteout on top. To actually remove the bytes you must never let them land in a persisted layer: chain the create-and-delete in a **single `RUN`** (so the layer's committed state never contains the file), use a **multi-stage build** copying only the wanted artifacts into a clean final stage, or **squash** the layers. *(This is why `curl … && make && rm -rf src` must be one `RUN`.)*

**A2.3** — `.wh.<name>` removes a **single** entry `<name>` from the layers below. `.wh..wh..opq` is an **opaque whiteout** placed *inside a directory*; it hides **all** entries from lower layers within that directory, so only the current layer's contents of that directory are visible. A single `rm file` yields `.wh.file`; replacing a directory wholesale (e.g. `rm -rf dir && mkdir dir && …`) commonly yields an opaque whiteout on `dir`.

**A2.4** — The **`diff_id` (uncompressed digest)** feeds the **chainID**, computed iteratively: `chainID(0)=diff_id(0)`, `chainID(n)=SHA256(chainID(n-1) + " " + diff_id(n))`. The chainID identifies a *stack* of applied layers for the local overlay cache, independent of compression. Two registries can gzip the same tar with different compression levels/implementations, producing **different compressed (manifest) digests** for byte-identical filesystem content, while the **`diff_id`s stay identical** — so the runtime still recognizes the layers as the same and reuses the cache.

### Block 3 — Image index / multi-arch

**A3.1** — Two logical resolutions: (1) the runtime GETs the **image index** for `nginx:1.27`, reads `manifests[]`, and selects the entry whose `platform.architecture/os/variant` matches the node (`arm64/v8`); (2) it then GETs that **child manifest** by its digest, then the config and any missing layer blobs. The **child** (per-arch) manifest digest is what is recorded in the Pod's `imageID`, not the index digest. *(distribution-spec + image-index.md.)*

**A3.2** — Pinning to the **index digest** stays portable: every node re-selects its own child manifest from that fixed index, so both amd64 and arm64 nodes work. Pinning to the **amd64 child digest** hard-codes a single-platform image; scheduling that Pod onto an arm64 node fails because the image cannot run there (and there is no index to select from).

**A3.3** — A runnable platform image has a real `platform.architecture`/`os` (e.g. `linux/amd64`) and its `mediaType` is an image manifest. An **attestation** entry typically has `platform.os == "unknown"`, `platform.architecture == "unknown"`, and carries `annotations` like `vnd.docker.reference.type: attestation-manifest` pointing at the subject via `vnd.docker.reference.digest`. Filter on `platform.os != "unknown"` (and/or the annotations) to keep only runnable images.

**A3.4** — The kubelet's container runtime cannot find a matching platform in the index and the **pull fails**; the failure surfaces on the kubelet as an image-pull error (`ErrImagePull`/`ImagePullBackOff`) with a "no matching manifest for linux/arm64" style message. The scheduler is unaware — it placed the Pod fine; the mismatch is only discovered at pull time on the node. (You prevent it up front with `nodeAffinity`/`nodeSelector` on `kubernetes.io/arch`.)

### Block 4 — Reproducibility & provenance

**A4.1** — Non-deterministic inputs: the config `created` timestamp; file **mtimes** inside layer tars; tar entry **ordering**; **uid/gid/permission** normalization; a **base image tag** that moved between builds; and build-tool version differences in compression. Neutralize with `SOURCE_DATE_EPOCH` / `--timestamp` (normalizes `created` and mtimes), deterministic tar ordering (modern BuildKit/buildah do this), pinning `FROM …@digest`, and fixing the builder version.

**A4.2** — A **tag is mutable**: if upstream re-pushes `distroless/static:nonroot`, your "same" Dockerfile now builds `FROM` different bytes, so the output legitimately differs — reproducibility is broken through no change of yours. Pinning `FROM …@sha256:<digest>` freezes the base to exact content, making the base an invariant input; it is a *correctness* condition for byte-reproducible builds (and, separately, blocks a supply-chain swap of the base).

**A4.3** — `empty_layer: true` entries come from **metadata-only instructions** — `ENV`, `CMD`, `ENTRYPOINT`, `LABEL`, `EXPOSE`, `WORKDIR`, `USER`, etc. — that change the **config** but add no filesystem layer. They still change the image digest because the config blob changes, and the manifest points at the config; so the manifest digest changes even though no new layer blob exists.

**A4.4** — The manifest digest is a hash of the **manifest JSON**, which references the **config blob digest** and the ordered **layer descriptors**. The config includes the non-deterministic `created` timestamp and `history`, and the manifest may carry annotations. So identical filesystems can still yield different manifest digests via the **config object** and the **manifest object** metadata — not just the layer tars. The two extra JSON objects are the **image config** and the **manifest** itself.

### Block 5 — Content trust

**A5.1** — Because a tag is a mutable pointer, signing "the tag" would bind a signature to a name whose bytes can later change. Attack: you sign `demo:1.0` today; the attacker re-pushes `demo:1.0` to malicious bytes; the old signature still "verifies for the tag," so consumers accept poisoned content. Signing the **digest** binds the signature to immutable bytes, so any swap changes the digest and invalidates the association.

**A5.2** — In keyless signing the root of trust is **Sigstore**: an ephemeral key is issued by **Fulcio** against an **OIDC** identity, the signature is logged in **Rekor** (transparency log), and the ephemeral cert is discarded. Verification therefore cannot trust "a public key"; it must pin **who** signed and **via which issuer** — hence `--certificate-identity` (the OIDC subject, e.g. a CI email/SPIFFE ID) and `--certificate-oidc-issuer` (e.g. `https://token.actions.githubusercontent.com`) are mandatory to prevent accepting a validly-signed-but-untrusted identity.

**A5.3** — **Both** historically: cosign uses a tag naming convention (`sha256-<hex>.sig` / `.att`) *and*, on OCI 1.1 registries, the **referrers API** to list artifacts whose `subject` is the image digest. For a `kubernetes` admission controller (Sigstore `policy-controller`, Kyverno, Connaisseur), this means at deploy time it resolves the image to a digest, fetches the associated signatures/attestations from the registry, and admits or denies the Pod **before** it runs — enforcing "no unsigned images" as policy.

**A5.4** — No. A valid `cosign verify` attests only that **a trusted identity signed this exact digest** — provenance/authenticity and integrity. It says **nothing** about the image being free of vulnerabilities, correctly configured, or non-malicious. The SBOM/vuln findings are orthogonal: you can have a perfectly-signed image full of CVEs. Authenticity and safety are separate controls; you need signing *plus* vulnerability policy (e.g. Trivy/Grype gating on the SBOM) to make a security decision.

</details>