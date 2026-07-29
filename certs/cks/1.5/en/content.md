# 1.5 Verify platform binaries before deploying

## Why this matters

Every control plane component, the kubelet, `kubectl`, `kubeadm`, the CNI plugins and the container images that back them are *executable code running with very high privilege*. A tampered `kubelet` binary owns every node it runs on. A tampered `kube-apiserver` image owns the whole cluster.

The realistic threat is not someone breaking TLS on `dl.k8s.io` — it is the long tail of the delivery chain:

- an internal mirror or artifact proxy (Nexus, Artifactory, an S3 bucket) that someone can write to,
- a "convenience" install script curl-piped into `bash` from a blog post,
- a base image or Helm chart pulled from a public registry that got typosquatted or account-compromised,
- a build pipeline that injects code between source and artifact (the SolarWinds / `xz-utils` pattern).

Verification is the cheap control that breaks all of these: **you never run a byte you have not tied back to a publisher you trust.**

There are three escalating levels of assurance, and you should know all three for the exam:

| Level | Mechanism | Answers the question |
|---|---|---|
| 1 | Checksum (`sha256sum` / `sha512sum`) | "Did the bytes arrive intact / are they the bytes the publisher listed?" |
| 2 | Digital signature (cosign/sigstore, GPG) | "Who produced these bytes, and can they deny it?" |
| 3 | Provenance + SBOM | "How were these bytes built, and what is inside them?" |

A checksum published on the *same* server as the artifact proves almost nothing against an attacker who controls that server. Only a signature (level 2) binds the artifact to an identity.

---

## Trust anchors for Kubernetes artifacts

| Artifact | Canonical source |
|---|---|
| Binaries (`kubectl`, `kubelet`, `kubeadm`, `kube-apiserver`, …) | `https://dl.k8s.io/release/<version>/bin/<os>/<arch>/<binary>` |
| Per-binary checksum | same URL + `.sha256` |
| Per-binary signature / certificate | same URL + `.sig` and `.cert` |
| Tarballs + sha512 list | `CHANGELOG/CHANGELOG-1.34.md` in `kubernetes/kubernetes` |
| Container images | `registry.k8s.io/<component>:<version>` (signed with cosign) |
| SBOM | `https://sbom.k8s.io/<version>/release` |
| Distro packages | `https://pkgs.k8s.io/core:/stable:/v1.34/{deb,rpm}/` |

Note the `registry.k8s.io` / `dl.k8s.io` hostnames: the old `k8s.gcr.io` registry is frozen. Anything still pulling from it is a finding in itself.

---

## Level 1 — Checksum verification

The everyday workflow, and the one most likely to appear as an exam task:

```bash
KUBE_VERSION=v1.34.0
ARCH=linux/amd64

curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/${ARCH}/kubectl"
curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/${ARCH}/kubectl.sha256"

echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

```
kubectl: OK
```

If the file was modified in transit or on disk:

```
kubectl: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```

`sha256sum --check` returns a **non-zero exit code** on failure, which is what you want inside an installer script:

```bash
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check || { rm -f kubectl; exit 1; }
```

Doing it by eye (useful when you only have the hash, not a `.sha256` file):

```bash
sha256sum kubectl
```
```
3a1b7f0c9e5d8a2f4b6c1d0e9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b  kubectl
```

Same idea for the release tarballs, which use SHA-512:

```bash
curl -LO "https://dl.k8s.io/${KUBE_VERSION}/kubernetes-server-linux-amd64.tar.gz"
sha512sum kubernetes-server-linux-amd64.tar.gz
# compare against the value listed in CHANGELOG-1.34.md
```

### Verifying a binary that is already installed

This is the "an intruder may have swapped a binary on this node" scenario. Hash what is on disk and compare with upstream:

```bash
sha256sum /usr/local/bin/kubelet
curl -sL "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubelet.sha256"
```

Two frequent gotchas:

1. **Version drift.** Hash the version that is actually installed, not the newest one: `kubelet --version`, `kubectl version --client`, `kubeadm version -o short`.
2. **Repackaged binaries.** If the node was installed from the community `deb`/`rpm` repos, the shipped binaries are the upstream release builds and normally match — but a vendor distribution (EKS, GKE, OpenShift, Rancher) rebuilds them, so upstream hashes will *not* match by design. Verify those against the vendor's published hashes, or against the package manager (below).

---

## Level 2 — Signature verification with cosign

Since v1.26 **all** Kubernetes release artifacts — binaries, tarballs and images — are signed with [Sigstore](https://sigstore.dev/) cosign in *keyless* mode: the signing identity is a short-lived certificate issued to the release automation's OIDC identity and logged in the public Rekor transparency log. There is no long-lived private key to steal.

### A release binary

```bash
BINARY=kubectl
VERSION=v1.34.0
URL="https://dl.k8s.io/release/${VERSION}/bin/linux/amd64"

curl -sSLO "${URL}/${BINARY}"
curl -sSLO "${URL}/${BINARY}.sig"
curl -sSLO "${URL}/${BINARY}.cert"

cosign verify-blob "${BINARY}" \
  --signature "${BINARY}.sig" \
  --certificate "${BINARY}.cert" \
  --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com
```

```
Verified OK
```

### A release image

```bash
cosign verify registry.k8s.io/kube-apiserver:v1.34.0 \
  --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com
```

```
Verification for registry.k8s.io/kube-apiserver:v1.34.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

Key points to internalise:

- `--certificate-identity` and `--certificate-oidc-issuer` are **mandatory** in cosign v2. Omitting them means "accept a signature from anybody", which is worse than not verifying at all. The exact identity string differs between binaries and images and can change across releases — take it from the official *Verify Signed Kubernetes Artifacts* page for the release you are on.
- Verification contacts the Rekor transparency log by default. In an air-gapped environment use `--insecure-ignore-tlog` plus a locally mirrored TUF root, and understand you are giving up the "was this signature ever public?" property.
- For your own images the equivalent with a key pair is:

```bash
cosign generate-key-pair                       # cosign.key + cosign.pub
cosign sign --key cosign.key myregistry.io/app@sha256:<digest>
cosign verify --key cosign.pub myregistry.io/app@sha256:<digest>
```

---

## Level 3 — Package managers, SBOMs and provenance

### Distro packages

The community repos are GPG-signed; `apt`/`dnf` verify the repository metadata automatically, provided you installed the keyring:

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Verify an individual RPM before installing, and verify installed files afterwards:

```bash
rpm --checksig kubeadm-1.34.0-150500.1.1.x86_64.rpm
# kubeadm-1.34.0-...x86_64.rpm: digests signatures OK

rpm --verify kubelet        # empty output = no file has been modified
```

The Debian equivalent for drift detection:

```bash
debsums -c kubelet          # lists only files whose checksum changed
```

`rpm --verify` / `debsums -c` are excellent quick wins during an incident: they tell you which on-disk files no longer match what the package installed.

### SBOM

Every release ships an SPDX SBOM, so you can answer "does this component embed the vulnerable library?" without unpacking anything:

```bash
curl -sL https://sbom.k8s.io/v1.34.0/release -o k8s-v1.34.0.spdx
grep -i 'name: golang.org/x/net' k8s-v1.34.0.spdx
```

Or pull the SBOM attached to an image:

```bash
cosign download sbom registry.k8s.io/kube-apiserver:v1.34.0
```

---

## Pin by digest, not by tag

A checksum you verified at install time is worthless if the workload later pulls a mutable tag. Tags are pointers; **digests are content-addressed and immutable**.

```yaml
# Bad: :latest, and even :v1.34.0 can be re-pushed
image: registry.k8s.io/kube-apiserver:v1.34.0

# Good
image: registry.k8s.io/kube-apiserver@sha256:0f6a3b0e3d7c9b1a5e2d4c8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b
```

Inspect what is actually running on a node:

```bash
kubectl get pod kube-apiserver-controlplane -n kube-system \
  -o jsonpath='{.status.containerStatuses[*].imageID}{"\n"}'
```
```
registry.k8s.io/kube-apiserver@sha256:0f6a3b0e3d7c9b1a5e2d4c8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b
```

```bash
crictl images --digests
crictl inspecti registry.k8s.io/kube-apiserver:v1.34.0
```

If the running `imageID` digest does not match the digest you signed and approved, something changed the image behind the tag.

## Enforce it, don't just check it

Manual verification does not scale. Push it into admission control so unverified images are rejected at the API server:

```yaml
# Kyverno: only admit images signed by our key
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "myregistry.io/*"
          mutateDigest: true      # rewrites the tag to the resolved digest
          required: true
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

`mutateDigest: true` is the underrated part: it resolves the tag to a digest at admission time, so the pod is permanently pinned to the exact image that was verified. The equivalents are Gatekeeper/OPA with an external data provider, the Sigstore `policy-controller`, or the built-in `ImagePolicyWebhook` admission plugin.

## Helm charts and third-party tooling

Charts are code too. Helm supports provenance files (`.prov`) signed with GPG:

```bash
helm package --sign --key 'release@example.com' --keyring ~/.gnupg/secring.gpg ./mychart
helm verify mychart-1.2.3.tgz
helm install myrel mychart-1.2.3.tgz --verify
```

```
Signed by: Release Bot <release@example.com>
Using Key With Fingerprint: 8F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A
Chart Hash Verified: sha256:9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d
```

The same discipline applies to `kubectl` plugins from Krew, CNI plugin tarballs, `etcd` releases (signed with cosign as well), `crictl`, and any `curl … | bash` installer — replace the pipe with download → verify → execute.

## Common pitfalls

- **Trusting a checksum served from the same compromised host as the artifact.** Use signatures for anything that matters.
- **`cosign verify` without identity flags** (or with a wildcard regexp) — accepts any valid Sigstore signature from anyone.
- **Verifying the download but installing from cache**, or verifying `v1.34.0` while the node runs `v1.33.4`.
- **Pinning a tag and calling it immutable.** Only digests are immutable.
- **Ignoring the exit code** in automation — always `set -euo pipefail` and let `sha256sum --check` fail the build.
- **Verifying at install time only.** Re-check with `rpm --verify` / `debsums` and compare running `imageID` digests as part of routine node auditing.

## Quick exam checklist

```bash
# 1. Hash a suspect binary and compare with upstream
sha256sum /usr/bin/kubectl
curl -sL https://dl.k8s.io/release/$(kubectl version --client -o json \
  | jq -r .clientVersion.gitVersion)/bin/linux/amd64/kubectl.sha256

# 2. One-shot verify of a fresh download
echo "$(curl -sL .../kubectl.sha256)  kubectl" | sha256sum --check

# 3. Signature check
cosign verify-blob kubectl --signature kubectl.sig --certificate kubectl.cert \
  --certificate-identity <identity> --certificate-oidc-issuer <issuer>

# 4. What is really running
kubectl get pods -n kube-system -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' | sort -u

# 5. Which installed files drifted from their package
rpm -Va | grep -E 'kube|etcd'      # or: debsums -c
```

---

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Verify Signed Kubernetes Artifacts — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
- Install and Set Up kubectl on Linux (checksum validation) — https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Installing kubeadm (community package repositories) — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes Downloads and release artifacts — https://kubernetes.io/releases/download/
- Kubernetes SBOM — https://kubernetes.io/docs/reference/issues-security/official-cve-feed/ and https://sbom.k8s.io/
- Kubernetes Images and image pull policy — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes Software Supply Chain Best Practices (CNCF TAG Security) — https://github.com/cncf/tag-security/blob/main/community/working-groups/supply-chain-security/supply-chain-security-paper/CNCF_SSCP_v1.pdf
- Sigstore cosign documentation — https://docs.sigstore.dev/cosign/signing/overview/
- cosign `verify` / `verify-blob` reference — https://github.com/sigstore/cosign/blob/main/doc/cosign_verify.md
- Kyverno — Verify Image Signatures — https://kyverno.io/docs/writing-policies/verify-images/
- Helm — Provenance and Integrity — https://helm.sh/docs/topics/provenance/
- Kubernetes Admission Controllers Reference (`ImagePolicyWebhook`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook