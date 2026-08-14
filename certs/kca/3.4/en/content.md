# 3.4 — Installing the Kyverno CLI

> **Domain 3 · Kyverno CLI** — Exam weight for this competency: **3.0**
> Target profile: SRE / Platform Engineer operating Kyverno as an admission-control and policy-as-code system across many clusters and CI pipelines.

---

## 1. Motivation: the architectural problem the CLI exists to solve

Kyverno's primary runtime is an **in-cluster admission controller**. Policies (`ClusterPolicy`, `Policy`, `ValidatingPolicy`, `ImageValidatingPolicy`, plus the generate/mutate variants) are reconciled by the Kyverno controllers, wired into the API server through `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` objects, and evaluated **synchronously on every matching admission request**.

That runtime is exactly the wrong place to *develop and test* a policy:

- **The feedback loop runs through the API server.** To find out whether a `require-run-as-nonroot` policy actually rejects a bad Deployment, you must `kubectl apply` it into a live cluster whose webhook is already reconciled — a multi-second round trip that depends on RBAC, webhook TLS, and controller health.
- **The blast radius is production.** A `Enforce`-mode policy that is subtly wrong doesn't fail in a test harness; it fails by blocking real workload admission, or by mutating live objects. There is no dry run that is both *offline* and *identical* to the admission path.
- **CI/CD cannot gate on it.** A pull request that changes a policy needs a verdict *before* merge, on a runner that has no cluster, no `kubeconfig`, and no network egress to the API server.
- **It is not reproducible.** "Does this policy pass?" must have a deterministic, versioned answer that a pipeline can assert in an air-gapped environment, independent of any cluster's live state.

The **Kyverno CLI** (`kyverno`) resolves this by embedding the *same policy engine* used by the in-cluster controllers into a standalone binary. It evaluates policies against static manifests on disk — no API server, no webhook, no cluster — and returns pass/fail/skip/error verdicts. This is what makes **policy-as-code shift-left** possible: authors iterate locally in milliseconds, CI gates every PR, and the exact same engine version can be pinned in the pipeline and in the cluster so that "passes in CI" means "passes at admission."

**Installing the CLI is therefore not a convenience step — it is the entry point to the entire test/apply/jp workflow (`kyverno test`, `kyverno apply`, `kyverno jp`, `kyverno json`, `kyverno oci`, `kyverno fix`).** Every other CLI competency in Domain 3 depends on getting this binary onto the right host, at the right version, from a verified supply chain.

### The version-skew invariant

The single most important production constraint: **the CLI is a specific build of the Kyverno engine, and the engine changes between releases.** A policy that uses a JMESPath function, a `matchExpressions` construct, or a `ValidatingPolicy` field introduced in engine v1.13 will be *misjudged* by a v1.11 CLI. The rule that makes CI meaningful:

> Pin the CLI version to the **same minor line** as the Kyverno controller running in the target cluster. If the cluster runs `v1.13.x`, gate PRs with a `v1.13.x` CLI. Otherwise "green in CI" is a lie the admission webhook will later contradict.

---

## 2. Installation methods — technical trade-offs

There are five supported acquisition paths. They differ in **invocation surface**, **version-pinning precision**, **supply-chain verifiability**, and **air-gap suitability** — the four dimensions that matter to a platform team.

| Method | Invocation | Version pinning | Supply-chain verification | Air-gap / offline | Toolchain required | Best fit |
|---|---|---|---|---|---|---|
| **Krew** (`kubectl krew install kyverno`) | `kubectl kyverno …` | Krew-index manifest; **lags upstream**, coarse | krew-index SHA256 on the archive | Needs krew + a mirrored index | `kubectl` + krew | Engineer laptops already standardized on kubectl plugins |
| **Homebrew** (`brew install kyverno`) | `kyverno …` | Formula version; **lags upstream** | Bottle SHA (managed by Homebrew) | No | Homebrew | macOS / Linux dev laptops, quick start |
| **Direct release binary** (GitHub release tarball) | `kyverno …` | **Exact tag you choose** | **cosign keyless + `checksums.txt`** | **Yes** — mirror the tarball | `curl`, `tar`, (`cosign` recommended) | CI runners, reproducible / regulated pipelines |
| **`go install`** | `kyverno …` | Go module version | Go module sumdb (`go.sum`) | Needs Go + a module proxy | Go toolchain | Contributors building from source; bleeding edge |
| **Container image** (`ghcr.io/kyverno/kyverno-cli`) | `docker run … kyverno …` | **Tag or `@sha256` digest** | **cosign-signed image + SBOM** | **Yes** — mirror the image | Container runtime | CI without host installs; ephemeral, hermetic runners |

### 2.1 Why the CLI beats "just apply it to a cluster"

The reason the CLI is a first-class competency, expressed as a decision table:

| Dimension | In-cluster admission (apply to live cluster) | Kyverno CLI (offline evaluation) |
|---|---|---|
| Feedback latency | Seconds; through API server + webhook TLS | Milliseconds; local process |
| Blast radius | Can block/mutate **real** workloads | **None** — pure static evaluation |
| Prerequisites | Reachable cluster, valid `kubeconfig`, RBAC, healthy webhook | A binary and files on disk |
| CI/CD gating | Needs an ephemeral cluster (kind/k3d) per run | Runs on any runner, no cluster |
| Determinism | Depends on live cluster state | Deterministic for a pinned CLI + inputs |
| Air-gap | Cluster + network required | Binary + manifests only |

### 2.2 Invocation surface — the one that trips people up

Krew installs the **same binary** but exposes it as a `kubectl` plugin, so the command is **`kubectl kyverno …`**. Every other method installs a standalone binary invoked as **`kyverno …`**. Scripts and CI steps written for one form break silently on the other. Standardize on one per environment and document it.

---

## 3. Complete, production-grade installation infrastructure

The examples below pin a **concrete release** (`v1.13.4` is used illustratively). In production, *never* hardcode "latest" — resolve and freeze an explicit tag. The mechanism to discover the current latest tag (so the material stays correct across releases):

```bash
$ curl -sSL https://api.github.com/repos/kyverno/kyverno/releases/latest \
    | grep -oP '"tag_name":\s*"\K[^"]+'
v1.13.4
```

### 3.1 Verified direct-binary install (the reference method for CI)

This is the supply-chain-hardened path: download → **verify checksum** → **verify cosign signature** → install to `PATH`.

```bash
#!/usr/bin/env bash
# install-kyverno-cli.sh — reproducible, verified Kyverno CLI install
set -euo pipefail

VERSION="v1.13.4"
OS="linux"           # linux | darwin | windows
ARCH="x86_64"        # x86_64 | arm64  (NOTE: x86_64, not amd64)
BASE="https://github.com/kyverno/kyverno/releases/download/${VERSION}"
ARCHIVE="kyverno-cli_${VERSION}_${OS}_${ARCH}.tar.gz"

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT; cd "$workdir"

# 1. Fetch the archive and the release checksum + cosign artifacts
curl -fsSLO "${BASE}/${ARCHIVE}"
curl -fsSLO "${BASE}/checksums.txt"
curl -fsSLO "${BASE}/checksums.txt.pem"
curl -fsSLO "${BASE}/checksums.txt.sig"

# 2. Integrity: the archive must match its published SHA-256
sha256sum -c checksums.txt --ignore-missing

# 3. Provenance: keyless cosign signature over the checksum file
#    (proves the checksums were produced by Kyverno's release workflow)
cosign verify-blob \
  --certificate       checksums.txt.pem \
  --signature         checksums.txt.sig \
  --certificate-identity-regexp='^https://github.com/kyverno/kyverno' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
  checksums.txt

# 4. Extract and install
tar -xzf "${ARCHIVE}"                       # yields: LICENSE  README.md  kyverno
sudo install -m 0755 kyverno /usr/local/bin/kyverno

# 5. Prove the engine version
kyverno version
```

Expected terminal session:

```console
$ ./install-kyverno-cli.sh
kyverno-cli_v1.13.4_linux_x86_64.tar.gz: OK
Verified OK
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

The two verification steps are the difference between "we run a random binary from the internet in our release pipeline" and a defensible supply chain. `sha256sum -c` catches corruption/truncation; `cosign verify-blob` catches a *swapped* archive by proving the checksum manifest itself came from Kyverno's GitHub Actions release workflow (keyless Sigstore identity).

### 3.2 Krew

```console
$ kubectl krew install kyverno
Updated the local copy of plugin index.
Installing plugin: kyverno
Installed plugin: kyverno
\
 | Use this plugin:
 | 	kubectl kyverno
 | Documentation:
 | 	https://github.com/kyverno/kyverno
/
WARNING: You installed plugin "kyverno" from the krew-index plugin repository.
   These plugins are not audited for security by the Krew maintainers.
   Run them at your own risk.

$ kubectl kyverno version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

> `kubectl kyverno: command not found`? Krew installs into `~/.krew/bin`, which must be on `PATH`. See §5.

### 3.3 Homebrew (macOS / Linux dev laptops)

```console
$ brew install kyverno
==> Fetching kyverno
==> Downloading https://ghcr.io/v2/homebrew/core/kyverno/manifests/1.13.4
==> Pouring kyverno--1.13.4.arm64_sonoma.bottle.tar.gz
🍺  /opt/homebrew/Cellar/kyverno/1.13.4: 6 files, 46.1MB
$ kyverno version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

Homebrew tracks upstream with a lag; when you need an *exact* engine version to match a cluster, prefer §3.1.

### 3.4 `go install` (contributors / building from source)

```console
$ go install github.com/kyverno/kyverno/cmd/cli/kyverno@v1.13.4
go: downloading github.com/kyverno/kyverno v1.13.4
$ kyverno version
Version:
Time:
Git commit ID:
```

**Diagnostic gotcha — expected and correct:** `go install` does **not** inject the release `ldflags`, so `kyverno version` prints **empty** version metadata. The binary works, but it cannot report its own version. This breaks any CI assertion of the form `kyverno version | grep 1.13`. For pipelines that must *prove* the engine version, use §3.1 or §3.6, not `go install`.

### 3.5 GitHub Actions — the official install action (CI gate)

Kyverno publishes a first-party action, `kyverno/action-install-cli`, so pipelines don't reimplement §3.1:

```yaml
# .github/workflows/policy-gate.yaml
name: kyverno-policy-gate
on:
  pull_request:
    paths: ["policies/**", "manifests/**"]

permissions:
  contents: read

jobs:
  validate-policies:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          # Pin to the SAME minor line as the in-cluster controller.
          release: v1.13.4

      - name: Verify installed version (fail closed on skew)
        run: |
          set -euo pipefail
          kyverno version
          kyverno version | grep -q 'Version: 1.13' \
            || { echo "::error::Kyverno CLI version skew"; exit 1; }

      - name: Run policy test suites
        run: kyverno test ./policies --detailed-results

      - name: Evaluate policies against candidate manifests
        run: |
          kyverno apply ./policies \
            --resource ./manifests \
            --policy-report \
            --warn-exit-code 0 \
            --fail-exit-code 1
```

### 3.6 Container image — hermetic, host-install-free CI

For runners where you cannot (or will not) install host binaries, run the CLI as a pinned, signed image. **Pin by digest**, not just tag, for immutability:

```console
$ docker run --rm \
    ghcr.io/kyverno/kyverno-cli:v1.13.4@sha256:9f2c...e41 \
    version
Version: 1.13.4
Time: 2024-11-12T10:30:42Z
Git commit ID: main/3d3a9c7f1b2e...
```

Mounting the workspace to evaluate local policies/manifests:

```console
$ docker run --rm -v "$PWD:/work" -w /work \
    ghcr.io/kyverno/kyverno-cli:v1.13.4 \
    test ./policies --detailed-results
```

Verify the image the same way you'd verify any Kyverno-signed artifact:

```console
$ cosign verify \
    --certificate-identity-regexp='^https://github.com/kyverno/kyverno' \
    --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
    ghcr.io/kyverno/kyverno-cli:v1.13.4 | jq '.[0].optional.Subject'
"https://github.com/kyverno/kyverno/.github/workflows/release.yaml@refs/tags/v1.13.4"
```

A multi-stage `Dockerfile` that bakes a pinned CLI into a policy-tooling image:

```dockerfile
# syntax=docker/dockerfile:1
FROM ghcr.io/kyverno/kyverno-cli:v1.13.4 AS cli

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=cli /ko-app/kyverno /usr/local/bin/kyverno
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/kyverno"]
```

### 3.7 Air-gapped installation

No internet on the target host. Do the network work once, on a connected staging box, then transport:

```bash
# --- on a connected host: fetch, verify, and stage the artifact ---
VERSION="v1.13.4"
BASE="https://github.com/kyverno/kyverno/releases/download/${VERSION}"
for f in \
    "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" \
    checksums.txt checksums.txt.pem checksums.txt.sig ; do
  curl -fsSLO "${BASE}/${f}"
done
sha256sum -c checksums.txt --ignore-missing
tar -czf kyverno-cli-airgap-${VERSION}.tgz \
    "kyverno-cli_${VERSION}_linux_x86_64.tar.gz" \
    checksums.txt checksums.txt.pem checksums.txt.sig
sha256sum kyverno-cli-airgap-${VERSION}.tgz > transfer.sha256
# --- transport kyverno-cli-airgap-*.tgz + transfer.sha256 across the boundary ---
```

On the isolated host, re-verify `transfer.sha256`, extract, re-run `sha256sum -c checksums.txt --ignore-missing`, then `install -m 0755 kyverno /usr/local/bin/`. For the container path, `docker pull … && docker save` the digest-pinned image, transport the tarball, `docker load` on the far side, and mirror it into the internal registry.

---

## 4. `kyverno version` — reading the output like an operator

```console
$ kyverno version
Version: 1.13.4                      # engine build; MUST align with the cluster controller's minor line
Time: 2024-11-12T10:30:42Z           # build timestamp (empty for `go install` builds)
Git commit ID: main/3d3a9c7f1b2e...  # exact source revision
```

Compare against the in-cluster controller to detect skew before it bites you:

```console
$ kubectl -n kyverno get deploy kyverno-admission-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
ghcr.io/kyverno/kyverno:v1.13.4
```

If the CLI reports `1.13.x` and the controller image is `v1.13.x`, your CI verdicts are trustworthy. If they diverge across a minor line, treat every "pass" as unverified.

---

## 5. Verification & failure diagnosis

| Symptom (terminal) | Root cause | Fix |
|---|---|---|
| `kyverno: command not found` | Binary not on `PATH` | Confirm install dir (`/usr/local/bin`); `echo $PATH`; `command -v kyverno` |
| `kubectl kyverno: command not found` (after krew) | `~/.krew/bin` not on `PATH` | `export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"` in shell profile |
| `bash: .../kyverno: cannot execute binary file: Exec format error` | Wrong CPU arch (e.g. `x86_64` tarball on `arm64`) | Match `ARCH`; verify with `uname -m` |
| `kyverno-cli_..._linux_x86_64.tar.gz: FAILED` from `sha256sum -c` | Corrupt/truncated download or wrong asset | Re-download; confirm `Content-Length`; check proxy/CDN mangling |
| `cosign verify-blob` → `Error: … no matching signatures` | Wrong identity/issuer regexp, or tampered checksum | Use the identity-regexp/issuer from §3.1; ensure `.pem`/`.sig` match the same release |
| `kyverno version` prints empty `Version:` | Built via `go install` (no release ldflags) | Use §3.1 release binary or §3.6 image when version must be assertable |
| CLI verdict disagrees with cluster admission | **Version skew** CLI ↔ controller | Pin CLI to the controller's minor line (§4) |
| `kyverno test` errors on a field the docs describe | CLI older than the policy schema used | Upgrade CLI to the release that introduced the field |
| `kubectl krew: command not found` | Krew itself not installed | Install Krew per krew.sigs.k8s.io, then `kubectl krew install kyverno` |

**Post-install smoke test** — proves the binary not only runs but *evaluates* correctly, end to end:

```console
$ cat > /tmp/pol.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: require-team-label
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "The label 'team' is required."
        pattern:
          metadata:
            labels:
              team: "?*"
EOF

$ cat > /tmp/good.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: ok
  labels: { team: platform }
spec:
  containers: [{ name: app, image: nginx:1.27 }]
EOF

$ cat > /tmp/bad.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: missing-label
spec:
  containers: [{ name: app, image: nginx:1.27 }]
EOF

$ kyverno apply /tmp/pol.yaml --resource /tmp/good.yaml --resource /tmp/bad.yaml

Applying 1 policy rule(s) to 2 resource(s)...

policy require-labels -> resource default/Pod/ok passed
policy require-labels -> resource default/Pod/missing-label failed:
1. require-team-label: validation error: The label 'team' is required.

pass: 1, fail: 1, warn: 0, error: 0, skip: 0

$ echo "exit: $?"
exit: 1
```

A non-zero exit on the failing resource confirms the engine is wired correctly and can be trusted as a CI gate (the process exit code is what a pipeline asserts on).

---

## 6. References

- Kyverno CLI — installation & usage: https://kyverno.io/docs/kyverno-cli/
- Kyverno CLI — install methods: https://kyverno.io/docs/kyverno-cli/install/
- Kyverno releases (binaries, `checksums.txt`, cosign `.pem`/`.sig`): https://github.com/kyverno/kyverno/releases
- Kyverno source — CLI package (`cmd/cli/kyverno`): https://github.com/kyverno/kyverno
- Kyverno container image (CLI): https://github.com/kyverno/kyverno/pkgs/container/kyverno-cli
- Official install-CLI GitHub Action: https://github.com/kyverno/action-install-cli
- Krew — kubectl plugin manager: https://krew.sigs.k8s.io/
- Krew index entry (kyverno): https://krew.sigs.k8s.io/plugins/
- Sigstore cosign — verifying blobs and images: https://docs.sigstore.dev/
- KCA (Kyverno Certified Associate) curriculum: https://github.com/cncf/curriculum
- Kyverno documentation root: https://kyverno.io/docs/