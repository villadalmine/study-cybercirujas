# Topic 1.5 — Verify Platform Binaries Before Deploying

## Guided Exercises

> **Scope.** These exercises cover the supply-chain checks you are expected to perform *before* a binary, package, image or chart ever reaches a node: checksum verification, Sigstore/cosign signature verification, package-repository key trust, on-node drift auditing, digest pinning and Helm provenance.

### Lab prerequisites

- A Linux machine (amd64 assumed; substitute `arm64` where relevant) with `curl`, `sha256sum`, `gpg`, `openssl` and `jq`.
- Outbound HTTPS access to `dl.k8s.io`, `registry.k8s.io`, `pkgs.k8s.io`, `rekor.sigstore.dev` and `fulcio.sigstore.dev`.
- A working `kubeadm`-based cluster with `crictl` on at least one node (used from Exercise 7 onward).
- `sudo` on the lab machine. **Do not run the tampering steps against a production node.**

---

## Exercise 1 — Pin the release you are going to verify

Verification is meaningless if you do not first decide *exactly* which artifact you trust.

1. Create a clean working directory:

   ```bash
   mkdir -p ~/verify-lab && cd ~/verify-lab
   ```

2. Ask the release channel what the current stable version is, and what the stable version of the 1.34 minor line is:

   ```bash
   curl -sL https://dl.k8s.io/release/stable.txt
   curl -sL https://dl.k8s.io/release/stable-1.34.txt
   ```

3. Pin the version explicitly in your shell — every later step reuses it:

   ```bash
   export K8S_VERSION=v1.34.0
   export ARCH=amd64
   echo "${K8S_VERSION}/${ARCH}"
   ```

4. Look at what the release directory publishes for a single binary:

   ```bash
   for ext in "" .sha256 .sig .cert; do
     echo -n "kubectl${ext}: "
     curl -sIL -o /dev/null -w '%{http_code}\n' \
       "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl${ext}"
   done
   ```

**Questions**

1. Why is `curl -sL https://dl.k8s.io/release/stable.txt` a *convenience*, not a security control?
2. `dl.k8s.io` is served over HTTPS. Why is TLS alone insufficient to trust the `kubectl` you just located?
3. What is the practical difference, for an auditor, between "we install Kubernetes 1.34" and "we install `v1.34.0` with digest `sha256:…`"?

---

## Exercise 2 — Verify a released binary with its published checksum

1. Download the binary and its checksum file:

   ```bash
   cd ~/verify-lab
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl"
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
   cat kubectl.sha256; echo
   ```

2. Note that the `.sha256` file contains **only the hash**, with no filename. Build a valid checksum line and verify:

   ```bash
   echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
   ```

   Expected output:

   ```
   kubectl: OK
   ```

3. Confirm the exit code, because that is what a script or pipeline must gate on:

   ```bash
   echo "exit code: $?"
   ```

4. Do the same for the server tarball, which is what `kubeadm`-style installs and air-gapped mirrors usually consume:

   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/kubernetes-server-linux-${ARCH}.tar.gz"
   curl -sL "https://dl.k8s.io/release/${K8S_VERSION}/kubernetes-server-linux-${ARCH}.tar.gz.sha512" \
     | tr -d '\n' > server.sha512
   echo "$(cat server.sha512)  kubernetes-server-linux-${ARCH}.tar.gz" | sha512sum --check
   ```

   > If the `.sha512` file is not published for your release, the same digests are listed in the release changelog: `https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.34.md`.

5. Only now install the binary:

   ```bash
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   kubectl version --client
   ```

**Questions**

1. Why does `sha256sum --check` fail with "no properly formatted checksum lines found" if you pass `kubectl.sha256` directly?
2. The checksum file sits on the same server as the binary. Which attack does the checksum actually protect you against, and which does it *not*?
3. Why does step 5 come after step 2, and not before?
4. What is the security-relevant reason to use `install -o root -g root -m 0755` instead of `cp` + `chmod +x`?

---

## Exercise 3 — Negative test: detect a tampered binary

A control you have never seen fail is a control you have not tested.

1. Make a copy and modify one byte at the end of it:

   ```bash
   cd ~/verify-lab
   cp kubectl kubectl-tampered
   printf '\x00' >> kubectl-tampered
   ```

2. Compare the two hashes visually:

   ```bash
   sha256sum kubectl kubectl-tampered
   ```

3. Run the same verification against the tampered file and capture the exit code:

   ```bash
   echo "$(cat kubectl.sha256)  kubectl-tampered" | sha256sum --check
   echo "exit code: $?"
   ```

   Expected output:

   ```
   kubectl-tampered: FAILED
   sha256sum: WARNING: 1 computed checksum did NOT match
   exit code: 1
   ```

4. Now prove that the tampered binary still *works*:

   ```bash
   chmod +x kubectl-tampered
   ./kubectl-tampered version --client
   ```

5. Compare file sizes and clean up:

   ```bash
   ls -l kubectl kubectl-tampered
   rm -f kubectl-tampered
   ```

**Questions**

1. Step 4 shows the tampered binary running normally. What lesson does that teach about "it works, so it must be fine"?
2. A single appended NUL byte changed the whole SHA-256 output. What property of a cryptographic hash function is that, and why does it matter here?
3. Would comparing file *size* have caught a real trojaned `kubectl`? Why or why not?
4. In a CI pipeline, what is wrong with `sha256sum --check checksums.txt || true`?

---

## Exercise 4 — Verify the Sigstore signature of a release binary

Since v1.24, Kubernetes release artifacts are signed with cosign using keyless (Fulcio/Rekor) signing. Checksums prove *integrity*; signatures prove *provenance*.

1. Install cosign:

   ```bash
   cd ~/verify-lab
   curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
   cosign version
   ```

2. Download the signature and the signing certificate for `kubectl`:

   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.sig"
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.cert"
   ```

3. Inspect the certificate before trusting it — look at the Subject Alternative Name:

   ```bash
   openssl x509 -in kubectl.cert -noout -text | grep -A1 "Subject Alternative Name"
   # If that errors, the file is base64-wrapped:
   # base64 -d kubectl.cert | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
   ```

4. Verify the blob, binding it to the expected identity **and** the expected OIDC issuer:

   ```bash
   cosign verify-blob kubectl \
     --signature kubectl.sig \
     --certificate kubectl.cert \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   ```

   Expected output:

   ```
   Verified OK
   ```

5. Run the negative test — same signature, wrong artifact:

   ```bash
   cp kubectl kubectl-evil && printf '\x00' >> kubectl-evil
   cosign verify-blob kubectl-evil \
     --signature kubectl.sig \
     --certificate kubectl.cert \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   rm -f kubectl-evil
   ```

6. Run a second negative test — right artifact, wrong expected identity:

   ```bash
   cosign verify-blob kubectl \
     --signature kubectl.sig --certificate kubectl.cert \
     --certificate-identity attacker@example.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   ```

**Questions**

1. What extra guarantee does the cosign signature give you that the `.sha256` file does not?
2. Why are `--certificate-identity` and `--certificate-oidc-issuer` **mandatory** in cosign v2? What happens to your security posture if you could omit them?
3. The Fulcio certificate is valid for roughly ten minutes. How can a signature made months ago still verify today?
4. Your build server is air-gapped and cannot reach `rekor.sigstore.dev`. Name one flag that makes verification proceed and state the trade-off you accept by using it.

---

## Exercise 5 — Verify control-plane container image signatures

1. Locate where the signature for an image is stored in the registry:

   ```bash
   cosign triangulate registry.k8s.io/kube-apiserver:${K8S_VERSION}
   ```

2. Verify the image signature against the image-signing identity (note: it is **not** the same identity used for binaries):

   ```bash
   cosign verify registry.k8s.io/kube-apiserver:${K8S_VERSION} \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com | jq '.[0].optional'
   ```

3. Resolve the tag to an immutable digest and verify *the digest*:

   ```bash
   DIGEST=$(crictl images --digests 2>/dev/null | awk '/kube-apiserver/ {print $3; exit}')
   echo "$DIGEST"
   cosign verify "registry.k8s.io/kube-apiserver@${DIGEST}" \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com >/dev/null && echo "signature OK"
   ```

4. Verify the full set of images your cluster version needs:

   ```bash
   for img in $(kubeadm config images list --kubernetes-version ${K8S_VERSION}); do
     echo "== $img"
     cosign verify "$img" \
       --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
       --certificate-oidc-issuer https://accounts.google.com >/dev/null 2>&1 \
       && echo "  OK" || echo "  FAILED / unsigned"
   done
   ```

5. Negative test — verify an image that the Kubernetes release process never signed:

   ```bash
   cosign verify docker.io/library/nginx:latest \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   ```

**Questions**

1. Why is verifying `image:tag` weaker than verifying `image@sha256:…`, even when both succeed right now?
2. Step 4 may report `FAILED / unsigned` for some images (for example a third-party CNI or a mirrored `etcd`). Is that necessarily a compromise? What should you do about it?
3. `cosign verify` succeeded on your workstation. Does that stop a compromised image from running in the cluster? What component would you need for that?
4. What does `cosign triangulate` return, and why is signature storage as a separate tag relevant when you mirror images into an air-gapped registry?

---

## Exercise 6 — Trust the package repository, not just the packages

Most clusters install `kubelet`/`kubeadm`/`kubectl` from `pkgs.k8s.io`. The trust anchor there is a GPG key.

1. Fetch the repository signing key and inspect it *before* installing it:

   ```bash
   cd ~/verify-lab
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key -o k8s-1.34-release.key
   gpg --show-keys --with-fingerprint --with-colons k8s-1.34-release.key | grep -E '^(pub|fpr|uid)'
   ```

2. Install it into a dedicated keyring (never into the global trusted set):

   ```bash
   sudo mkdir -p /etc/apt/keyrings
   sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg < k8s-1.34-release.key
   sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   ```

3. Scope that key to exactly one repository with `signed-by=`:

   ```bash
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
     | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   ```

4. Prove the signature check is live by breaking it:

   ```bash
   sudo cp /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-key.bak
   sudo dd if=/dev/urandom of=/etc/apt/keyrings/kubernetes-apt-keyring.gpg bs=64 count=1 status=none
   sudo apt-get update 2>&1 | grep -iE 'NO_PUBKEY|not signed|GPG error' || echo "no error - investigate!"
   sudo cp /tmp/k8s-key.bak /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   sudo apt-get update >/dev/null && echo "restored"
   ```

5. On an RPM-based node, the equivalent controls live in the repo definition — confirm both flags are enabled:

   ```bash
   grep -E 'gpgcheck|repo_gpgcheck|gpgkey' /etc/yum.repos.d/kubernetes.repo
   ```

6. Verify that installed package files have not drifted from what the package declared:

   ```bash
   sudo dpkg --verify kubelet kubeadm kubectl ; echo "dpkg exit: $?"
   # RPM-based:
   # sudo rpm -V kubelet kubeadm kubectl ; echo "rpm exit: $?"
   ```

**Questions**

1. What concretely goes wrong if you drop the key into `/etc/apt/trusted.gpg.d/` instead of using `signed-by=`?
2. In step 4, `apt-get update` failed. Which file's signature was actually being checked?
3. `gpgcheck=1` versus `repo_gpgcheck=1` — what does each one cover?
4. `dpkg --verify` reported nothing for a file an attacker replaced. Give one reason that can happen, and name the class of tool that closes the gap.

---

## Exercise 7 — Audit the binaries already running on a node

Verification before deployment is half the job; you also need to detect post-installation tampering.

1. Find out exactly which version each on-node binary claims to be:

   ```bash
   for b in kubelet kubeadm kubectl; do
     printf '%-8s %s\n' "$b" "$(command -v $b) -> $($b --version 2>/dev/null | head -1)"
   done
   ```

2. Hash the installed `kubelet` and fetch the official checksum for that exact version:

   ```bash
   KUBELET_VER=$(kubelet --version | awk '{print $2}')
   LOCAL=$(sha256sum "$(command -v kubelet)" | awk '{print $1}')
   OFFICIAL=$(curl -sL "https://dl.k8s.io/release/${KUBELET_VER}/bin/linux/${ARCH}/kubelet.sha256")
   echo "local:    $LOCAL"
   echo "official: $OFFICIAL"
   [ "$LOCAL" = "$OFFICIAL" ] && echo "MATCH" || echo "MISMATCH - investigate"
   ```

3. Record a signed baseline of the security-relevant paths so drift becomes detectable:

   ```bash
   sudo sha256sum /usr/bin/kubelet /usr/bin/kubeadm /usr/bin/kubectl \
        /etc/kubernetes/manifests/*.yaml \
        > ~/verify-lab/node-baseline.sha256
   cat ~/verify-lab/node-baseline.sha256
   ```

4. Re-check the baseline at any later time:

   ```bash
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256
   echo "exit: $?"
   ```

5. Simulate drift in a static Pod manifest and re-run the check:

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak
   sudo sed -i 's/--anonymous-auth=false/--anonymous-auth=true/' /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256 | grep -i failed
   sudo cp /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256
   ```

6. Check ownership and permissions on the binaries and the manifest directory:

   ```bash
   stat -c '%n owner=%U:%G mode=%a' /usr/bin/kubelet /etc/kubernetes/manifests
   ```

**Questions**

1. In step 2 the hash matched. Why might a legitimate, uncompromised node still show `MISMATCH`?
2. Where should `node-baseline.sha256` be stored, and why is keeping it only on the node it describes a weak design?
3. Why are static Pod manifests in `/etc/kubernetes/manifests` an especially high-value tampering target?
4. `/usr/bin/kubelet` is mode `755` and owned by `root:root`. If it were `root:root 775` and an operator account were in the `root` group, what would the attacker gain?

---

## Exercise 8 — Pin images by digest and confirm what actually ran

1. Resolve a tag to a digest without pulling the whole image:

   ```bash
   cosign triangulate registry.k8s.io/pause:3.10 2>/dev/null
   crictl pull registry.k8s.io/pause:3.10
   crictl images --digests | grep pause
   ```

2. Deploy a Pod pinned by digest (replace the digest with the one you just resolved):

   ```bash
   PAUSE_DIGEST=$(crictl images --digests | awk '/pause/ {print $3; exit}')
   cat <<EOF | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pinned-demo
   spec:
     containers:
     - name: app
       image: registry.k8s.io/pause@${PAUSE_DIGEST}
   EOF
   ```

3. Ask the cluster what it *actually* ran, not what you asked for:

   ```bash
   kubectl get pod pinned-demo -o jsonpath='{.spec.containers[*].image}{"\n"}'
   kubectl get pod pinned-demo -o jsonpath='{.status.containerStatuses[*].imageID}{"\n"}'
   ```

4. Audit every running container in the cluster for tag-based (mutable) references:

   ```bash
   kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
     | grep -v '@sha256:' | sort -u
   ```

5. Clean up:

   ```bash
   kubectl delete pod pinned-demo
   ```

**Questions**

1. `.spec.containers[].image` and `.status.containerStatuses[].imageID` can disagree. Which one is evidence, and why?
2. With a digest-pinned image, does `imagePullPolicy: Always` versus `IfNotPresent` change the integrity guarantee? Explain.
3. An attacker with push access re-tags `v1.2.3` to point at a malicious layer set. Which of your Pods are affected, and which are not?
4. What operational cost do you accept by pinning digests everywhere, and how is it normally absorbed?

---

## Exercise 9 — Verify Helm chart provenance

Charts are platform artifacts too: they carry the manifests that define your security posture.

1. Create a signing key and export the keyrings in the legacy format Helm needs:

   ```bash
   cd ~/verify-lab
   gpg --batch --quick-generate-key "Lab Signer <lab@example.com>" default default never
   gpg --export-secret-keys > ~/.gnupg/secring.gpg
   gpg --export > ~/.gnupg/pubring-legacy.gpg
   ```

2. Create and sign a chart:

   ```bash
   helm create demo
   helm package --sign --key 'Lab Signer' --keyring ~/.gnupg/secring.gpg demo
   ls -l demo-0.1.0.tgz demo-0.1.0.tgz.prov
   ```

3. Read the provenance file — it contains the chart metadata plus the package hash, all inside a signed block:

   ```bash
   head -30 demo-0.1.0.tgz.prov
   grep -A2 'files:' demo-0.1.0.tgz.prov
   ```

4. Verify the chart:

   ```bash
   helm verify demo-0.1.0.tgz --keyring ~/.gnupg/pubring-legacy.gpg
   echo "exit: $?"
   ```

5. Tamper with the packaged chart and re-verify:

   ```bash
   cp demo-0.1.0.tgz demo-tampered.tgz
   cp demo-0.1.0.tgz.prov demo-tampered.tgz.prov
   printf '\x00' >> demo-tampered.tgz
   helm verify demo-tampered.tgz --keyring ~/.gnupg/pubring-legacy.gpg
   echo "exit: $?"
   ```

6. Enforce verification at install and pull time:

   ```bash
   helm install --dry-run --verify --keyring ~/.gnupg/pubring-legacy.gpg demo ./demo-0.1.0.tgz
   # For remote charts:
   # helm pull --verify --keyring ~/.gnupg/pubring-legacy.gpg <repo>/<chart> --version <ver>
   ```

**Questions**

1. What does a `.prov` file actually sign — the `.tgz`, the rendered manifests, or the chart metadata?
2. `helm verify` passed. Which two distinct claims have you established?
3. What happens if you run `helm install` **without** `--verify` on a chart that ships a valid `.prov`?
4. Why is chart provenance not a substitute for verifying the container images that the chart references?

---

## Exercise 10 — SBOMs and attestations (optional, for depth)

1. Download the SPDX SBOM published for the release:

   ```bash
   cd ~/verify-lab
   curl -Ls "https://sbom.k8s.io/${K8S_VERSION}/release" -o kubernetes-${K8S_VERSION}.spdx
   head -20 kubernetes-${K8S_VERSION}.spdx
   grep -c '^SPDXID:' kubernetes-${K8S_VERSION}.spdx
   ```

2. Search the SBOM for a specific artifact and its declared checksum:

   ```bash
   grep -B2 -A6 'FileName:.*kubectl' kubernetes-${K8S_VERSION}.spdx | head -40
   ```

3. Cross-check the SBOM-declared checksum against the file you verified in Exercise 2:

   ```bash
   sha256sum kubectl
   ```

4. Try to retrieve an in-toto attestation for a release image (if the release publishes one, cosign prints the payload; otherwise it reports that no matching attestations were found):

   ```bash
   cosign verify-attestation --type slsaprovenance \
     registry.k8s.io/kube-apiserver:${K8S_VERSION} \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com \
     2>&1 | head -20
   ```

**Questions**

1. An SBOM lists components. Does downloading an SBOM tell you anything about integrity on its own?
2. What is the difference between a *signature* and an *attestation* in the Sigstore model?
3. How does an SBOM change your response time when a CVE lands in a library that Kubernetes vendors?

---

## Wrap-up: the pre-deployment checklist

Before any platform binary, package, image or chart reaches a node:

| Artifact | Minimum check | Command |
|---|---|---|
| Release binary | SHA-256 + cosign signature | `sha256sum --check` + `cosign verify-blob` |
| Release tarball | SHA-512 from release page/changelog | `sha512sum --check` |
| Container image | Signature bound to identity, referenced by digest | `cosign verify <img>@sha256:…` |
| Distro package | Repo key scoped with `signed-by=`, `gpgcheck=1` | `apt-get update` / `rpm -V` |
| Helm chart | Provenance file verified | `helm verify` / `helm install --verify` |
| Installed node files | Baseline hash comparison | `sha256sum --check baseline` |

Two rules worth memorising: **verify before install, never after**, and **always bind a signature to an expected identity and issuer** — an unbound "it is signed" proves only that *somebody* signed it.

---

## Answers

<details>
<summary>Click to reveal the answers</summary>

### Exercise 1

1. `stable.txt` tells you what upstream currently considers stable; it is fetched at run time and can change between your test run and your production run. It is an input to a decision, not a verification step. Security requires a version you pinned deliberately and can reproduce.
2. TLS protects the *channel*: it proves you are talking to `dl.k8s.io` and that nobody modified bytes in flight. It says nothing about whether the object stored on that server is the object the Kubernetes release team produced — a compromised bucket, a poisoned mirror or a malicious CDN edge would all serve their content over perfectly valid TLS. Integrity and provenance need checksums and signatures.
3. "Kubernetes 1.34" is a range of dozens of distinct binaries with different fixes and different hashes; it is not verifiable. `v1.34.0` plus a digest is a single, immutable, reproducible object — an auditor can re-download it, re-hash it, and get the same answer next year.

### Exercise 2

1. `sha256sum --check` expects lines of the form `<hash>  <filename>`. The published `.sha256` file contains only the bare hash with no two-space separator and no filename, so the parser finds no valid lines. You must construct the line yourself, which is why the `echo "$(cat kubectl.sha256)  kubectl"` idiom exists.
2. It protects against **accidental or in-transit corruption** and against tampering that affects the binary but not the checksum file (a partial mirror compromise, a broken download, a proxy cache). It does **not** protect against an attacker who controls the server or the connection end-to-end, because they would simply publish a matching checksum for their malicious binary. Closing that gap is exactly what the cosign signature in Exercise 4 does.
3. Because installing first means the untrusted binary is already on `PATH`, already root-owned and executable, and possibly already run by another process or a shell completion hook. Verification must gate installation, not follow it.
4. It sets the final ownership and permission atomically as part of placing the file. A `cp` followed by `chmod` leaves a window in which the file exists at its destination with the copying user's ownership or a permissive umask-derived mode — a local attacker can overwrite or replace it in that window. `install` also avoids inheriting a group or mode from the download directory.

### Exercise 3

1. Functionality and integrity are independent. A real trojaned `kubectl` would behave exactly like the genuine one for every command you test, while additionally exfiltrating your kubeconfig. "It works" is not evidence of authenticity; only a cryptographic check is.
2. The **avalanche effect** — a one-bit change in the input changes roughly half the output bits, unpredictably. Combined with collision and second-preimage resistance, this means an attacker cannot craft a malicious binary that hashes to the published value.
3. No. Size is trivially controllable: an attacker who removes as many bytes as they add produces a byte-identical file size. Padding to a target size is a standard technique. Size comparison is a sanity check, never a security control.
4. `|| true` swallows the non-zero exit code, so the pipeline reports success even when verification failed. The check becomes decorative — it produces log noise that looks like assurance while enforcing nothing. Verification steps must be allowed to fail the build.

### Exercise 4

1. The checksum proves the file matches *a published hash*. The cosign signature proves the file was produced and signed by **the Kubernetes release automation identity**, with the event recorded in the public Rekor transparency log. An attacker who fully controls `dl.k8s.io` can forge a checksum; they cannot forge a Fulcio certificate for `krel-staging@k8s-releng-prod.iam.gserviceaccount.com` without also compromising Google's OIDC issuer and Sigstore's CA — and any such signature would be publicly visible in the transparency log.
2. They tell cosign *whose* signature to accept. Without them, verification degrades to "this artifact carries a syntactically valid signature from someone" — an attacker signs their malicious binary with their own Sigstore identity and it verifies. cosign v2 made them mandatory precisely because omitting them was the most common real-world misuse of v1.
3. Because verification checks that the certificate was **valid at signing time**, and the Rekor transparency log entry provides the trusted timestamp that proves *when* the signature was made. The short certificate lifetime limits the blast radius of a stolen key without invalidating past signatures.
4. `--insecure-ignore-tlog=true` (often together with `--insecure-ignore-sct`). The trade-off: you lose the transparency-log proof of signing time and public auditability, so verification now rests only on the certificate chain — a revoked or maliciously issued certificate is much harder to detect. The correct pattern for air-gapped environments is to verify at the boundary where you *do* have connectivity, then mirror only verified artifacts inward.

### Exercise 5

1. A tag is a mutable pointer. Verification of `image:tag` establishes that *whatever the tag pointed to at verification time* was signed; the tag can be moved to a different (unsigned or malicious) manifest a second later, and the next pull gets the new content. A digest is the content address itself — verifying `image@sha256:…` and then deploying that same digest closes the time-of-check/time-of-use gap.
2. Not necessarily. Images outside the Kubernetes release process (third-party CNIs, mirrored `etcd` builds, vendor images) are signed by different identities or not signed at all. The right response is to determine the correct signing identity for each source and verify against *that*, and to record an explicit, reviewed exception for anything genuinely unsigned — not to silence the check.
3. No. Verification on your workstation is advisory; nothing prevents someone from applying a manifest that references an unverified image. Enforcement requires a **validating admission controller** that verifies signatures at admission time (for example Kyverno's `verifyImages` rule, Sigstore Policy Controller, or Connaisseur), backed by policy that rejects unsigned or unknown-identity images.
4. It returns the registry reference where the signature is stored — the same repository with a tag derived from the image digest, ending in `.sig`. This matters for air-gapped mirroring because a naive `crane copy image:tag` or `skopeo copy` of only the tagged manifest leaves the `.sig` (and `.att`) tags behind, and verification then fails inside the isolated environment. You must copy the signature tags too (`cosign copy` handles this).

### Exercise 6

1. A key in `/etc/apt/trusted.gpg.d/` is trusted for **every** repository configured on the system. If any repo in your sources list is hijacked or a malicious repo is added, that key can be presented to authenticate its packages. `signed-by=` binds the key to one repository entry, so a compromise of one supplier cannot be used to authenticate packages from another.
2. The repository's `InRelease` file (or the `Release`/`Release.gpg` pair). That file is signed by the repo key and contains the hashes of the `Packages` indexes, which in turn contain the hashes of each `.deb`. Breaking the key breaks the chain at its root, so apt refuses the whole repository — this is the `apt-secure` model.
3. `gpgcheck=1` verifies the GPG signature on each **individual RPM package** before installation. `repo_gpgcheck=1` verifies the signature on the **repository metadata** (`repomd.xml`). You want both: metadata signing prevents index/downgrade manipulation, package signing prevents installing an unsigned or altered package.
4. `dpkg --verify` compares against checksums recorded at packaging time and does not cover every file type or every package (`conffiles` handling, packages that ship no md5sums); an attacker with root can also rewrite `/var/lib/dpkg/info/*.md5sums` to match their modified file. The class of tool that closes the gap is a **file integrity monitoring / HIDS** system with an off-host or immutable baseline — AIDE, Tripwire, or runtime detection such as Falco.

### Exercise 7

1. The binary may not have come from `dl.k8s.io` at all: distro or vendor packages are sometimes rebuilt from source with different compiler flags, stripped, or patched, producing a legitimately different hash. Managed distributions (and some cloud providers) ship their own builds. `MISMATCH` means "this did not come from the upstream release" — which requires you to identify and verify the *actual* supply chain, not to assume compromise or to ignore it.
2. Off the node — a signed artifact repository, a configuration-management server, or a WORM/immutable store. Keeping it only on the node it describes means an attacker with root simply regenerates the baseline after tampering, and every subsequent check passes. The baseline must live somewhere the node itself cannot rewrite.
3. Because the kubelet applies whatever it finds there **with no API server involvement, no RBAC, and no admission control**. Editing `kube-apiserver.yaml` lets an attacker enable anonymous auth, remove admission plugins, add an authentication webhook, or mount the host filesystem — a complete control-plane takeover that bypasses every in-cluster policy you have configured.
4. Group-write on a root-owned binary means any member of the `root` group can replace `/usr/bin/kubelet` with a trojan **without being root**, and the kubelet then executes it as root at the next restart. It is a direct, unprivileged-to-root escalation path. Platform binaries must not be group- or world-writable, and neither must their parent directories.

### Exercise 8

1. `.status.containerStatuses[].imageID` is the evidence: it is the digest the container runtime actually resolved and ran. `.spec.containers[].image` is only the request. They diverge whenever the spec used a mutable tag, so audits and incident response must read the status field.
2. With a digest reference, the pull policy does not change the integrity guarantee — the runtime can only ever fetch content whose hash matches the digest, so `IfNotPresent` reuses a byte-identical local copy and `Always` re-fetches the same bytes. (The policy still matters for availability and for cache-poisoning-of-local-store scenarios, but not for the content guarantee.) With a tag, `Always` actively *increases* risk, because every restart re-resolves a pointer an attacker may have moved.
3. Pods referencing `image:v1.2.3` are affected on their next pull — which for `imagePullPolicy: Always` is the next restart, reschedule, or node failure. Pods referencing `image@sha256:…` are not: the digest no longer resolves to the attacker's content, so the pull either succeeds with the original bytes or fails loudly. That "fails loudly" is a feature.
4. Digests are unreadable and must be updated on every legitimate upgrade, so humans stop being able to review manifests by eye and routine patching becomes a code change. It is absorbed with automation: a renovate/dependabot-style bot that resolves tags to digests and opens a reviewable PR, or a GitOps rendering step that pins at build time while developers keep writing tags.

### Exercise 9

1. The `.prov` file is a clear-signed document containing the chart's `Chart.yaml` metadata **plus a `files:` block with the SHA-256 digest of the `.tgz` package**. So it signs the metadata directly and the package contents indirectly, through that hash. It does not sign the rendered manifests, which depend on values supplied at install time.
2. (a) **Integrity** — the `.tgz` you hold hashes to the value recorded in the provenance file, so it has not been altered. (b) **Provenance** — that provenance file was signed by a private key whose public half is in your keyring, so it came from a signer you decided to trust. Both claims are needed; either alone is insufficient.
3. Nothing is verified. Helm does not check provenance implicitly — the `.prov` file is simply ignored, and a tampered chart installs cleanly. Verification is opt-in per command (`--verify`), which is why it belongs in your tooling/CI wrapper rather than in human muscle memory.
4. A chart is a set of templates that *reference* images by name. Signing the chart proves the templates are authentic; it says nothing about the bytes behind `image: vendor/app:1.2.3`, which are fetched from a registry at Pod creation time and are a completely separate supply chain. You need chart provenance **and** image signature verification (ideally enforced at admission) to cover both.

### Exercise 10

1. No. An SBOM is a *claim* about composition — a text file that anyone can write. On its own it provides inventory, not integrity. It becomes trustworthy only when it is itself signed or delivered as a signed attestation bound to the artifact's digest, and when the checksums it declares are actually checked against the artifact (step 3).
2. A **signature** asserts only "this identity vouches for these exact bytes." An **attestation** is a signed *statement about* an artifact — an in-toto payload with a predicate type (SLSA provenance, SPDX SBOM, vulnerability scan result) bound to the artifact's digest. Signatures answer "is this authentic?"; attestations answer "how was this built, what is in it, and what has been checked?"
3. Dramatically. Without SBOMs, responding to a CVE in a vendored library means source-diving each release to determine whether it is affected. With SBOMs you query your inventory for the affected package and version range and get an immediate, evidence-backed list of impacted releases and images — turning a multi-day investigation into a search.

</details>

---

## Sources

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes documentation, *Verify Signed Kubernetes Artifacts* — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
- Kubernetes documentation, *Install and Set Up kubectl on Linux* — https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Kubernetes, *Download Kubernetes / release artifacts* — https://kubernetes.io/releases/download/
- Kubernetes documentation, *Installing kubeadm (pkgs.k8s.io repositories)* — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes blog, *Signing Kubernetes Release Artifacts* — https://kubernetes.io/blog/2022/05/03/kubernetes-1-24-release-signing/
- Sigstore documentation, *Verifying with cosign* — https://docs.sigstore.dev/cosign/verifying/verify/
- Helm documentation, *Helm Provenance and Integrity* — https://helm.sh/docs/topics/provenance/
- Debian, *SecureApt* — https://wiki.debian.org/SecureApt
- SLSA, *Supply-chain Levels for Software Artifacts* — https://slsa.dev/spec/v1.0/levels