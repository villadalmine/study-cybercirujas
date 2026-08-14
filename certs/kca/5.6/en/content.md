# 5.6 VerifyImage Rules

> **Domain 5 — Kyverno policy authoring · Exam weight: 2.91**
> Rule type: `spec.rules[].verifyImages[]` (`kyverno.io/v1`, `ClusterPolicy` / `Policy`)
> Next-generation equivalent: `ImageValidatingPolicy` (`policies.kyverno.io/v1alpha1`, Kyverno ≥ 1.14)

---

## 1. The production problem: a tag is not an identity

Every other Kyverno rule type reasons about **text inside the AdmissionReview**. `validate` reads `securityContext.runAsNonRoot`. `mutate` writes a label. `generate` creates a downstream object. All of them are pure functions of the request body — deterministic, offline, sub-millisecond.

`verifyImages` is the only rule type that leaves the cluster to answer its question.

The reason is that an OCI image reference is not an identity claim. Consider what a pod spec actually asserts:

```yaml
containers:
  - name: api
    image: ghcr.io/acme/api:1.4.2
```

This says "pull whatever the registry currently returns for the mutable pointer `1.4.2` in the repository `ghcr.io/acme/api`." It does not say who built it, from what source, on what runner, or whether the bytes changed since your CI pipeline last pushed them. Four concrete production failures follow directly from that gap:

| Failure | Mechanism | What a `validate` rule can catch |
|---|---|---|
| **Tag re-push** | An attacker (or a careless engineer) with `push` on the repo re-points `1.4.2` at different bytes. Every node that pulls after that runs new code with an unchanged manifest, unchanged GitOps commit, unchanged audit trail. | Nothing. The YAML is byte-identical. |
| **Registry compromise / MITM** | The registry itself, or a caching pull-through mirror, serves substituted layers. | Nothing. |
| **Typosquat / dependency confusion** | `ghcr.io/acme/api` vs `ghcr.io/acme-inc/api`. A reviewer's eye slips; the manifest is syntactically perfect. | Only via an allowlist of registries — which is a *string* check, not a *provenance* check. It cannot distinguish "our image" from "an image someone pushed into our registry." |
| **Unattributable build** | The image is genuinely in your registry, but nobody can say which commit, which workflow, which builder produced it. | Nothing. |

The SLSA framework names the first three as threats **(D) Compromise package repo**, **(E) Use compromised package**, and **(F) Upload modified package** in the supply-chain threat model. The mitigation SLSA prescribes is the same in all cases: bind the artifact's *digest* to a cryptographic statement produced by a trusted identity, and verify that binding at the moment of consumption.

For Kubernetes, "the moment of consumption" is admission control. That is what `verifyImages` implements.

### 1.1 Why admission control is the correct enforcement point (and where it is weak)

| Enforcement point | Covers | Does not cover | Operational cost |
|---|---|---|---|
| CI gate (verify before `kubectl apply`) | Images that flow through your pipeline | Anything applied out-of-band, operator-generated pods, `kubectl run`, sidecar injection by other webhooks | Free — but trivially bypassed |
| **Kyverno `verifyImages` (admission)** | Every `CREATE`/`UPDATE` of a pod-bearing resource in the cluster, including operator-created and webhook-injected containers | Pods already running before the policy existed; images pulled by nodes outside the API server (static pods, `crictl pull`) | One or more registry round-trips per admission; a hard dependency on registry availability |
| Container runtime / node-level (e.g. containerd image verification plugins) | Actual pull, including static pods | No policy context, no namespace scoping, per-node configuration drift | Node lifecycle management |
| Runtime detection (Falco, Tetragon) | Detects, does not prevent | — | Alert fatigue |

`verifyImages` sits at the highest-leverage point that is still centrally managed and policy-driven. Its two structural weaknesses — **pre-existing pods** and **the registry as a hard dependency** — drive most of the design decisions in the rest of this topic.

---

## 2. Architecture: where a verifyImages rule actually executes

This is the single most misunderstood mechanic in this domain, and it is examinable.

**A `verifyImages` rule is not a validating rule. It executes in the mutating admission phase.**

The reason is structural: the primary hardening action of image verification is *rewriting the mutable tag to the immutable digest that was actually verified*. That is a JSONPatch, and JSONPatches are only legal from a `MutatingWebhookConfiguration`. Kyverno therefore registers image-verification paths on the resource **mutating** webhook, not the validating one.

```
$ kubectl get mutatingwebhookconfigurations
NAME                                   WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg    1          31d
kyverno-resource-mutating-webhook-cfg  2          31d
kyverno-verify-mutating-webhook-cfg    1          31d

$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.clientConfig.service.path}{"\t"}{.failurePolicy}{"\t"}{.timeoutSeconds}{"\n"}{end}'
mutate.kyverno.svc-fail      /mutate/fail          Fail     10
mutate.kyverno.svc-ignore    /mutate/ignore        Ignore   10
```

> `kyverno-verify-mutating-webhook-cfg` is unrelated to image verification — it is Kyverno's self-liveness probe, targeting its own Deployment to confirm the API server can reach the webhook service. Do not confuse the two names; this is a classic distractor.

The end-to-end request flow for a `CREATE pods` request against a cluster with one `verifyImages` policy:

```
kubectl apply
      │
      ▼
API server ── AdmissionReview(CREATE, v1/Pod) ──► kyverno-resource-mutating-webhook-cfg
                                                        │
                                                        ▼
                                            Kyverno admission controller
                                                        │
                                          ┌─────────────┴──────────────┐
                                          │ 1. match/exclude evaluation │
                                          │ 2. extract image list       │
                                          │    (initContainers,         │
                                          │     containers,             │
                                          │     ephemeralContainers)    │
                                          │ 3. normalize references     │
                                          │    nginx:1.27 →             │
                                          │    docker.io/library/...    │
                                          │ 4. imageReferences glob     │
                                          │ 5. cache lookup             │
                                          └─────────────┬──────────────┘
                                                        │ MISS
                                                        ▼
                                        ┌───────────────────────────────┐
                                        │  OUTBOUND NETWORK             │
                                        │  • registry: HEAD manifest    │
                                        │    → resolve tag to digest    │
                                        │  • registry: GET signature    │
                                        │    tag  sha256-<hex>.sig      │
                                        │    (or OCI referrers API)     │
                                        │  • Fulcio/Rekor (keyless)     │
                                        └───────────────┬───────────────┘
                                                        │
                          ┌─────────────────────────────┴──────────────┐
                          │ verified                       not verified │
                          ▼                                             ▼
        JSONPatch response:                            AdmissionResponse
        • image → @sha256:<digest>  (mutateDigest)     allowed=false  (Enforce)
        • + annotation                                 allowed=true + warning (Audit)
          kyverno.io/verify-images                     + PolicyViolation event
                          │                            + PolicyReport entry
                          ▼
          API server persists mutated object
                          │
                          ▼
        kyverno-resource-validating-webhook-cfg  (validate rules run here, on the
                                                  already-digest-pinned spec)
```

Three consequences worth internalising:

1. **Ordering.** Because verification runs in the mutating phase, `validate` rules see the *post-mutation* spec. A rule like "images must be referenced by digest" will pass on a tag-referenced pod if a `verifyImages` rule with `mutateDigest: true` fired first. That is usually what you want, but it means the two rules are not independent.
2. **Registry latency is inside the API server's critical path.** A slow or unreachable registry turns into admission latency, and — with `failurePolicy: Fail` — into a cluster-wide inability to create pods.
3. **Background scans do not re-verify signatures.** Kyverno's reports controller has no AdmissionReview and, by design, does not perform registry I/O for image verification during periodic scans. A clean `PolicyReport` therefore proves "no admission was rejected," not "every running image is still signed." Verify this on your own cluster rather than trusting the claim:

```
$ kubectl get clusterpolicyreport -o json \
  | jq -r '.items[].results[] | select(.rule|test("verify")) | "\(.policy)/\(.rule)\t\(.result)"' \
  | sort -u
```

If you need continuous assurance for already-running workloads, that is a separate control (a `CronJob` that re-runs `cosign verify` over `kubectl get pods -o jsonpath='{..image}'`, or a runtime attestation agent), not something `verifyImages` gives you.

---

## 3. The rule API, field by field

Here is a complete, syntactically valid policy exercising the majority of the surface. Every field below is explained afterwards.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-images
  annotations:
    policies.kyverno.io/title: Verify ACME container image signatures
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    # Restrict autogen so we do not silently create rules for controllers we
    # have not tested. Remove the annotation to get the full default set.
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  # Enforce is what makes this a control rather than a dashboard.
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit
      namespaces:
        - kube-system
        - sandbox-*
  # Image verification requires registry I/O and cannot run in background scans.
  background: false
  webhookConfiguration:
    timeoutSeconds: 30
  # Fail closed. See §7 for the availability trade-off this creates.
  failurePolicy: Fail
  rules:
    - name: verify-cosign-keyless
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kyverno
      verifyImages:
        - type: Cosign
          imageReferences:
            - "ghcr.io/acme/*"
          skipImageReferences:
            - "ghcr.io/acme/legacy-*"
          # Rewrite the verified tag to its digest in the admitted object.
          mutateDigest: true
          # Do NOT require the submitter to already use a digest; mutateDigest
          # will supply it. Set true only once every producer emits digests.
          verifyDigest: false
          # If no attestor set matches, fail. false would allow unmatched images.
          required: true
          useCache: true
          attestors:
            # Attestor SETS are ANDed. Both of the sets below must pass.
            - count: 1                      # within this set: 1-of-2 (OR)
              entries:
                - keyless:
                    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false
                - keyless:
                    subject: "https://github.com/acme/worker/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false
            - entries:                       # no count → ALL entries required
                - keys:
                    secret:
                      name: acme-release-pubkey
                      namespace: kyverno
                    signatureAlgorithm: sha256
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
                    - key: "{{ regex_match('^https://github.com/acme/', buildDefinition.externalParameters.workflow.repository) }}"
                      operator: Equals
                      value: true
          imageRegistryCredentials:
            allowInsecureRegistry: false
            providers:
              - github
            secrets:
              - acme-ghcr-pull
```

### 3.1 Field reference

| Field | Type | Default | Behaviour and failure mode if wrong |
|---|---|---|---|
| `type` | `Cosign` \| `Notary` | `Cosign` | Selects the verification implementation. `Notary` uses the OCI **referrers API** and X.509 trust chains rather than Sigstore. Mixing a Notary-signed image with a Cosign rule yields `no signatures found`. |
| `imageReferences` | `[]string` (glob) | — (required) | Matched against the **normalized** reference. `*` matches any run of characters *including* `/`. Anchor deliberately: `"ghcr.io/acme/*"` matches `ghcr.io/acme/team/api`. |
| `skipImageReferences` | `[]string` (glob) | `[]` | Evaluated after `imageReferences`; a match short-circuits the rule for that image. The clean way to carve out a migration exception without a second policy. |
| `mutateDigest` | bool | `true` | Rewrites `repo:tag` → `repo:tag@sha256:…` in the admitted object. **This is the field that makes verification meaningful** — without it you verify one set of bytes and the kubelet may pull another. |
| `verifyDigest` | bool | `true` | Rejects references that are not already digest-pinned. Combined with `mutateDigest: true` it is largely redundant; use it alone to *force producers* to emit digests. |
| `required` | bool | `true` | If `true`, an image matching `imageReferences` that no attestor set satisfies is a violation. If `false`, unmatched images pass — a "verify if signed" mode that provides almost no guarantee. |
| `useCache` | bool | `true` | Opt this rule out of the image-verification cache. Set `false` for rules whose result must reflect revocation immediately. |
| `attestors` | `[]AttestorSet` | — | Sets are **ANDed**. See §4. |
| `attestations` | `[]Attestation` | `[]` | In-toto attestation verification plus JMESPath conditions on the predicate. See §5. |
| `imageRegistryCredentials` | object | inherits controller flags | Per-rule registry auth. Overrides the controller-wide `--imagePullSecrets` / credential helpers. |
| `repository` | string (inside attestor entry) | — | Equivalent of `COSIGN_REPOSITORY`: signatures live in a different repository than the image. Common in read-only mirror topologies. |

### 3.2 The attestor algebra — the highest-yield exam detail

```
attestors:                       ── list of AttestorSet ── ALL must pass  (AND)
  - count: <n>                   ── within one set: n of len(entries) must pass
    entries:                     ── if count omitted → ALL entries          (AND)
      - keys:    {...}
      - keyless: {...}
      - certificates: {...}
      - attestor: {...}          ── nested set, enables arbitrary boolean trees
```

| Intent | Encoding |
|---|---|
| Signed by key A **or** key B | one set, `count: 1`, two entries |
| Signed by key A **and** key B (dual control) | one set, no `count`, two entries |
| Signed by the build system **and** by (QA **or** Security) | two sets: set 1 = builder key; set 2 = `count: 1` with QA and Security entries |
| Any 2 of 3 release engineers | one set, `count: 2`, three entries |

The dual-control shape is what "two-person integrity" looks like in Kyverno, and it is the reason attestor *sets* exist as a separate nesting level from *entries*.

---

## 4. Attestor types compared

| | Cosign — keys | Cosign — keyless | Cosign — certificates | Notary (`type: Notary`) |
|---|---|---|---|---|
| Trust anchor | Long-lived public key you distribute | Fulcio root CA + OIDC identity (`subject` + `issuer`) | Your own X.509 cert / chain | Your own X.509 trust store |
| Where the signature lives | OCI tag `sha256-<hex>.sig` | same | same | OCI **referrers** (artifact manifest) |
| Key management burden | High — rotation, custody, revocation are yours | None — certificates are 10-minute ephemeral | High | High |
| Transparency log | Optional (`rekor`) | Effectively mandatory (Rekor + CT log) | Optional | No |
| Internet egress required at admission | Registry only | Registry **+ Rekor + Fulcio root refresh (TUF)** | Registry only | Registry only |
| Air-gap friendliness | Good | Poor unless you run private Fulcio/Rekor | Good | **Best** |
| Revocation story | Rotate the key, re-sign everything | Short-lived certs; identity can be de-authorised in policy instantly | CRL/OCSP (not consulted by Kyverno) | CRL/OCSP (not consulted by Kyverno) |
| Binds signer to a *source repo* | No — a key says nothing about provenance | **Yes** — `subject` is the workflow ref | No | No |
| Kyverno field | `keys.publicKeys` / `keys.secret` / `keys.kms` | `keyless.{subject,issuer,roots,rekor,ctlog}` | `certificates.{cert,certChain}` | `certificates.{cert,certChain}` |

**Architectural recommendation.** For CI-built images in a connected cluster, keyless is strictly better: it eliminates the key-custody problem entirely and, uniquely, the verification statement becomes *"built by workflow X in repository Y at tag Z"* rather than *"someone who holds a key approved this."* For air-gapped or regulated environments where egress to `rekor.sigstore.dev` is not permitted, either run a private Sigstore stack (§8) or use Notary, whose entire trust model is offline X.509.

### 4.1 Keyless: the `subject` field is the whole control

```yaml
- keyless:
    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
    issuer: "https://token.actions.githubusercontent.com"
```

The two most common misconfigurations, both of which produce a policy that *passes its tests* and *provides no security*:

| Anti-pattern | Why it is fatal |
|---|---|
| `subject: "*"` | Any identity in the world that can obtain a Fulcio certificate — i.e. anyone with a GitHub account — satisfies the policy. |
| `subject: "https://github.com/acme/*"` with `issuer: token.actions.githubusercontent.com` | Any workflow in *any* branch of *any* ACME repo can sign. A contributor who can push a workflow to a feature branch of an unrelated repo can now sign production images. Always pin the workflow **path** and constrain the ref (`@refs/tags/*` or `@refs/heads/main`). |

### 4.2 Keys from a Secret (dual use with `cosign generate-key-pair k8s://`)

```yaml
- keys:
    secret:
      name: acme-release-pubkey
      namespace: kyverno
    signatureAlgorithm: sha256
```

The Secret must contain a `cosign.pub` key. `cosign generate-key-pair k8s://<ns>/<name>` creates exactly this shape (`cosign.key`, `cosign.password`, `cosign.pub`) — but note that this puts the **private** key in the cluster Kyverno reads from. In production, generate the pair in your KMS or CI secret store and create a Secret in the Kyverno namespace containing only `cosign.pub`.

Or reference the KMS directly and avoid the Secret entirely:

```yaml
- keys:
    kms: "awskms:///arn:aws:kms:eu-west-1:111122223333:key/1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
```

---

## 5. Attestations: verifying *what the build said*, not just *who signed*

A signature proves an identity approved a digest. An **attestation** is a signed in-toto Statement carrying a structured *predicate* — SLSA provenance, an SBOM, a scan result, a manual approval. `verifyImages.attestations` lets you verify the attestation's signature **and** assert JMESPath conditions over the predicate's contents.

```yaml
attestations:
  - type: https://slsa.dev/provenance/v1        # the in-toto predicateType
    attestors:
      - count: 1
        entries:
          - keyless:
              subject: "https://github.com/acme/*/.github/workflows/release.yaml@refs/tags/*"
              issuer: "https://token.actions.githubusercontent.com"
    conditions:
      - all:
          - key: "{{ buildDefinition.buildType }}"
            operator: Equals
            value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
          - key: "{{ runDetails.builder.id }}"
            operator: Equals
            value: "https://github.com/actions/runner/github-hosted"

  - type: https://cyclonedx.org/bom
    attestors:
      - entries:
          - keys:
              secret:
                name: acme-sbom-pubkey
                namespace: kyverno
    conditions:
      - all:
          # No component may carry a known-banned licence.
          - key: "{{ components[?licenses[?license.id=='AGPL-3.0'] ] | length(@) }}"
            operator: Equals
            value: 0

  - type: https://acme.io/attestations/vulnscan/v1
    attestors:
      - entries:
          - keys:
              secret:
                name: acme-scanner-pubkey
                namespace: kyverno
    conditions:
      - all:
          - key: "{{ scanner.result.critical }}"
            operator: LessThanOrEquals
            value: 0
          - key: "{{ time_since('', '{{ scanner.timestamp }}', '') }}"
            operator: LessThanOrEquals
            value: "168h"                       # scan must be < 7 days old
```

**The JMESPath root is the predicate, not the Statement.** Inside `conditions[].key`, `{{ buildDefinition.buildType }}` resolves against `.predicate.buildDefinition.buildType` of the in-toto Statement. Writing `{{ predicate.buildDefinition.buildType }}` is the single most common authoring error here and produces a silent `null`, which then fails an `Equals` comparison with a confusing message.

The vulnerability-scan example above is the pattern worth remembering architecturally: it converts a *point-in-time CI check* into a *continuously enforced admission invariant with a freshness bound*. A stale scan attestation stops admitting the image after seven days, which forces the pipeline to keep re-attesting — exactly the property you want and exactly the property a CI-only gate cannot give you.

`type` vs `predicateType`: Kyverno ≥ 1.10 uses `attestations[].type`. Older material and older policies use `predicateType`. Confirm against your cluster:

```
$ kubectl explain clusterpolicy.spec.rules.verifyImages.attestations --recursive | head -40
```

---

## 6. End-to-end worked example

### 6.1 Build and sign in GitHub Actions (keyless)

```yaml
# .github/workflows/release.yaml
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  packages: write
  id-token: write          # REQUIRED: mints the OIDC token Fulcio exchanges for a cert

jobs:
  build:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: 'v2.4.1'

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/acme/api:${{ github.ref_name }}
          provenance: false          # we attach SLSA ourselves, below

      # Sign the DIGEST, never the tag. Signing a tag signs whatever the tag
      # points at right now and creates a race with any concurrent push.
      - name: Sign image
        run: |
          cosign sign --yes \
            ghcr.io/acme/api@${{ steps.push.outputs.digest }}

      - name: Attach SBOM attestation
        run: |
          syft ghcr.io/acme/api@${{ steps.push.outputs.digest }} \
            -o cyclonedx-json > sbom.cdx.json
          cosign attest --yes \
            --predicate sbom.cdx.json \
            --type https://cyclonedx.org/bom \
            ghcr.io/acme/api@${{ steps.push.outputs.digest }}

  provenance:
    needs: [build]
    permissions:
      actions: read
      id-token: write
      packages: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
    with:
      image: ghcr.io/acme/api
      digest: ${{ needs.build.outputs.digest }}
```

Local verification before you ever write the policy — always prove the signature exists with `cosign` first, because a Kyverno failure cannot distinguish "policy is wrong" from "image is unsigned":

```
$ export IMG=ghcr.io/acme/api@sha256:9f2b1e0a7c4d5e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f

$ cosign verify \
    --certificate-identity-regexp 'https://github.com/acme/api/\.github/workflows/release\.yaml@refs/tags/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    $IMG | jq -r '.[0].optional.Subject'

Verification for ghcr.io/acme/api@sha256:9f2b1e0a... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/v1.4.2
```

```
$ cosign tree $IMG
📦 Supply Chain Security Related artifacts for an image: ghcr.io/acme/api@sha256:9f2b1e0a...
└── 💾 Attestations for an image tag: ghcr.io/acme/api:sha256-9f2b1e0a....att
   ├── 🍒 sha256:1c4a...
   └── 🍒 sha256:8e11...
└── 🔐 Signatures for an image tag: ghcr.io/acme/api:sha256-9f2b1e0a....sig
   └── 🍒 sha256:44db...
```

### 6.2 The policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-api
spec:
  validationFailureAction: Enforce
  background: false
  failurePolicy: Fail
  webhookConfiguration:
    timeoutSeconds: 30
  rules:
    - name: verify-signature-and-sbom
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: ["prod", "staging"]
      verifyImages:
        - type: Cosign
          imageReferences:
            - "ghcr.io/acme/api*"
          mutateDigest: true
          verifyDigest: false
          required: true
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - entries:
                    - keyless:
                        subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ components[?licenses[?license.id=='AGPL-3.0'] ] | length(@) }}"
                      operator: Equals
                      value: 0
```

### 6.3 Admission, observed

**Signed image — admitted and mutated:**

```
$ kubectl -n prod run api --image=ghcr.io/acme/api:v1.4.2 --restart=Never
pod/api created

$ kubectl -n prod get pod api -o jsonpath='{.spec.containers[0].image}{"\n"}'
ghcr.io/acme/api:v1.4.2@sha256:9f2b1e0a7c4d5e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f

$ kubectl -n prod get pod api -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}{"\n"}'
{"ghcr.io/acme/api:v1.4.2":true}
```

Note both effects. The image is now digest-pinned — the kubelet will pull exactly the bytes Kyverno verified, and a subsequent re-push of `v1.4.2` cannot change what this pod runs. The `kyverno.io/verify-images` annotation records the verification decision on the object itself.

**Unsigned image — rejected:**

```
$ kubectl -n prod run rogue --image=ghcr.io/acme/api:dev-local --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/rogue was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'failed to verify image ghcr.io/acme/api:dev-local:
    .attestors[0].entries[0].keyless: no signatures found'
```

**Signed but wrong signer — rejected with a different message:**

```
$ kubectl -n prod run wrong --image=ghcr.io/acme/api:v1.4.2-hotfix --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/wrong was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'failed to verify image ghcr.io/acme/api:v1.4.2-hotfix:
    .attestors[0].entries[0].keyless: no matching signatures: none of the expected
    identities matched what was in the certificate, got subjects
    [https://github.com/acme/api/.github/workflows/nightly.yaml@refs/heads/main]'
```

`no signatures found` (nothing there) versus `no matching signatures` (something there, wrong identity) is the fastest triage split you have. Memorise it.

**Failing predicate condition:**

```
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/api was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'attestation checks failed for
    ghcr.io/acme/api:v1.4.2 and predicate https://cyclonedx.org/bom'
```

### 6.4 Testing offline with the Kyverno CLI

The CLI performs *real* registry calls, but only when explicitly permitted with `--registry`. Without that flag image verification is skipped and your test passes vacuously.

```
$ kyverno apply verify-acme-api.yaml --resource pod-signed.yaml --registry --policy-report

Applying 1 policy rule(s) to 1 resource(s)...

apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: image verified
  policy: verify-acme-api
  resources:
  - apiVersion: v1
    kind: Pod
    name: api
    namespace: prod
  result: pass
  rule: verify-signature-and-sbom
  scored: true
summary:
  error: 0
  fail: 0
  pass: 1
  skip: 0
  warn: 0
```

```
$ kyverno apply verify-acme-api.yaml --resource pod-unsigned.yaml --registry
pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

---

## 7. Operating it: latency, caching, and the availability trade-off

Every cache miss costs at minimum a registry manifest `HEAD`, a signature-layer `GET`, and — for keyless — Rekor and Fulcio traffic. Measured against a public registry across a WAN this is routinely 300–900 ms, and it lands squarely inside the API server's admission timeout.

### 7.1 The image-verification cache

```yaml
# Helm values.yaml
features:
  imageVerifyCache:
    enabled: true
    maxSize: 1000          # entries
    ttl: 60m
  registryClient:
    allowInsecure: false
    credentialHelpers:
      - default
      - google
      - amazon
      - azure
      - github
```

Equivalent controller flags, if you are not using the chart:

```
--imageVerifyCacheEnabled=true
--imageVerifyCacheMaxSize=1000
--imageVerifyCacheTTLDuration=60m
--registryCredentialHelpers=default,google,amazon,azure,github
--allowInsecureRegistry=false
--imagePullSecrets=acme-ghcr-pull
```

The cache key includes the resolved digest and the policy/rule identity, so a policy edit invalidates its own entries. The trade-off:

| `ttl` | Admission latency (steady state) | Revocation lag | Registry load |
|---|---|---|---|
| `0` (disabled) | Full round-trip on every pod create — catastrophic during a large rollout or node drain | None | 1 round-trip × every container × every pod | 
| `15m` | Near-zero for repeated images | Up to 15 min | Low |
| `60m` (recommended) | Near-zero | Up to 60 min | Very low |
| `24h` | Near-zero | A full day of admitting a revoked image | Negligible |

Because cosign/keyless has no online revocation check anyway, the "revocation lag" column mostly measures *how long a policy edit takes to bite*, which is why 60 minutes is a defensible default. Set `useCache: false` on individual rules where that is unacceptable.

### 7.2 `failurePolicy` — the decision that will wake you up

| | `failurePolicy: Fail` | `failurePolicy: Ignore` |
|---|---|---|
| Registry unreachable | **All matching pod creates are rejected cluster-wide.** Rollouts stall; a concurrent node failure cannot reschedule pods. | Pods admit unverified. Silent loss of the control. |
| Kyverno pods down | Same — total pod-creation outage in matched namespaces | Same — silent bypass |
| Security posture | Sound: unverified never runs | Unsound: an attacker who can DoS your registry or Kyverno defeats the control |
| Suitable for | Production, with the mitigations below | Initial rollout, `Audit` phase |

If you run `Fail` — and for a supply-chain control you should — the mitigations are non-negotiable:

1. **Exclude Kyverno's own namespace and `kube-system`** from `match`, or Kyverno cannot restart itself and you have built a deadlock.
2. **Scope `match` narrowly.** Match `namespaces: [prod, staging]`, not the whole cluster.
3. **Run ≥ 3 admission-controller replicas** with a `PodDisruptionBudget` and anti-affinity.
4. **Use a registry that is in your failure domain** — a pull-through cache or a mirror inside the cluster's region — so registry availability is not a third-party dependency of your control plane.
5. **Set `webhookConfiguration.timeoutSeconds` above your p99 verification latency**, not at the 10 s default. A timeout with `Fail` is indistinguishable from a policy violation to the person doing the deploy.

### 7.3 Metrics to alert on

```
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep -E 'rule_type="ImageVerify"' | head

kyverno_policy_results_total{policy_name="verify-acme-api",policy_type="cluster",rule_execution_cause="admission_request",rule_name="verify-signature-and-sbom",rule_result="pass",rule_type="ImageVerify"} 1842
kyverno_policy_results_total{policy_name="verify-acme-api",policy_type="cluster",rule_execution_cause="admission_request",rule_name="verify-signature-and-sbom",rule_result="fail",rule_type="ImageVerify"} 6
kyverno_policy_execution_duration_seconds_sum{policy_name="verify-acme-api",rule_type="ImageVerify"} 741.22
kyverno_policy_execution_duration_seconds_count{policy_name="verify-acme-api",rule_type="ImageVerify"} 1848
```

Three alerts worth having:

```yaml
groups:
  - name: kyverno-image-verification
    rules:
      - alert: KyvernoImageVerifyFailures
        expr: increase(kyverno_policy_results_total{rule_type="ImageVerify",rule_result="fail"}[15m]) > 0
        labels: {severity: warning}
        annotations:
          summary: "Unsigned or mis-signed image rejected by {{ $labels.policy_name }}"

      - alert: KyvernoImageVerifyErrors
        # 'error' means Kyverno could not reach the registry/Rekor — an
        # availability problem, not a policy violation. Page on this.
        expr: increase(kyverno_policy_results_total{rule_type="ImageVerify",rule_result="error"}[10m]) > 3
        labels: {severity: critical}

      - alert: KyvernoImageVerifySlow
        expr: |
          rate(kyverno_policy_execution_duration_seconds_sum{rule_type="ImageVerify"}[10m])
          / rate(kyverno_policy_execution_duration_seconds_count{rule_type="ImageVerify"}[10m]) > 2
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Image verification averaging >2s; approaching webhook timeout"
```

Distinguishing `rule_result="fail"` (policy working as designed) from `rule_result="error"` (Kyverno could not do its job) is the difference between a ticket and a page.

---

## 8. Private registries, air-gap, and private Sigstore

### 8.1 Registry credentials

Kyverno's admission controller pulls signature layers **itself**; it does not use the node's credentials or the pod's `imagePullSecrets`. This is the number-one cause of "it works with `docker pull`, it fails in Kyverno."

Three layers, most specific wins:

```yaml
# 1. Cluster-wide, via controller flag / Helm
#    Secrets must exist in the Kyverno namespace.
admissionController:
  container:
    extraArgs:
      imagePullSecrets: "acme-ghcr-pull,acme-ecr-pull"

# 2. Cloud credential helpers — uses the controller's workload identity /
#    IRSA / managed identity. No secrets to rotate.
features:
  registryClient:
    credentialHelpers: [default, amazon, azure, google, github]
```

```yaml
# 3. Per-rule, inside verifyImages
        imageRegistryCredentials:
          allowInsecureRegistry: false
          providers: [amazon]
          secrets:
            - acme-ecr-pull            # must live in the Kyverno namespace
```

Creating the secret, and the check that proves Kyverno can actually use it:

```
$ kubectl -n kyverno create secret docker-registry acme-ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=acme-bot \
    --docker-password="$GH_PAT"
secret/acme-ghcr-pull created

$ kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
deployment.apps/kyverno-admission-controller restarted

# Prove reachability from inside the controller's network namespace
$ kubectl -n kyverno debug -it deploy/kyverno-admission-controller \
    --image=cgr.dev/chainguard/crane:latest --target=kyverno -- \
    crane manifest ghcr.io/acme/api:v1.4.2 | jq -r '.config.digest'
sha256:3d4b8c9e...
```

### 8.2 Private Sigstore (air-gapped keyless)

Keyless in an air-gapped cluster requires your own Fulcio, Rekor and TUF root. Kyverno consumes them via chart-level TUF configuration plus per-attestor overrides:

```yaml
features:
  tuf:
    enabled: true
    mirror: https://tuf.acme.internal
    root: /etc/kyverno/tuf/root.json     # mounted via extraVolumes
```

```yaml
          attestors:
            - entries:
                - keyless:
                    subject: "https://gitlab.acme.internal/platform/api//.gitlab-ci.yml@refs/tags/*"
                    issuer: "https://gitlab.acme.internal"
                    roots: |-
                      -----BEGIN CERTIFICATE-----
                      MIIB9zCCAX2gAwIBAgIUALxxxxxxxxxxxxxxxxxxxxxxxxxxwCgYIKoZIzj0EAwMw
                      ... your private Fulcio root ...
                      -----END CERTIFICATE-----
                    rekor:
                      url: https://rekor.acme.internal
                      pubkey: |-
                        -----BEGIN PUBLIC KEY-----
                        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                        -----END PUBLIC KEY-----
                    ctlog:
                      ignoreSCT: true      # no CT log in this deployment
```

If running private Sigstore is out of scope, the honest alternatives are **keyed Cosign** (`keys.kms`, backed by your HSM) or **Notary**, both of which are fully offline.

### 8.3 Notary

```yaml
      verifyImages:
        - type: Notary
          imageReferences:
            - "registry.acme.internal/*"
          mutateDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - certificates:
                    cert: |-
                      -----BEGIN CERTIFICATE-----
                      MIIDTTCCAjWgAwIBAgIJALXXXXXXXXXXXXXXMA0GCSqGSIb3DQEBCwUAMEwxCzAJ
                      ... ACME internal signing CA ...
                      -----END CERTIFICATE-----
                    certChain: |-
                      -----BEGIN CERTIFICATE-----
                      ... intermediate ...
                      -----END CERTIFICATE-----
                      -----BEGIN CERTIFICATE-----
                      ... root ...
                      -----END CERTIFICATE-----
```

```
$ notation cert generate-test --default "acme.internal"
$ notation sign registry.acme.internal/api@sha256:9f2b1e0a...
Successfully signed registry.acme.internal/api@sha256:9f2b1e0a...

$ notation verify registry.acme.internal/api@sha256:9f2b1e0a...
Successfully verified signature for registry.acme.internal/api@sha256:9f2b1e0a...
```

Notary requires a registry that implements the **OCI referrers API** (`/v2/<name>/referrers/<digest>`) or the referrers tag-schema fallback. Verify before you commit to it:

```
$ curl -sI -H "Authorization: Bearer $TOKEN" \
    https://registry.acme.internal/v2/api/referrers/sha256:9f2b1e0a... | head -3
HTTP/2 200
content-type: application/vnd.oci.image.index.v1+json
oci-subject: sha256:9f2b1e0a...
```

A `404` here means the registry lacks referrers support and Notary verification will fail with `failed to resolve referrers`.

---

## 9. Diagnostics: a failure-driven runbook

### 9.1 The triage ladder

Always work outside-in. Kyverno's error is the *last* place to look, because it aggregates four distinct subsystems.

```
$ # 1. Does the signature exist at all, from your laptop?
$ cosign verify --certificate-identity-regexp '...' --certificate-oidc-issuer '...' $IMG

$ # 2. Can KYVERNO's pod reach the registry? (its creds, its DNS, its egress)
$ kubectl -n kyverno debug -it deploy/kyverno-admission-controller \
    --image=cgr.dev/chainguard/crane --target=kyverno -- crane manifest $IMG

$ # 3. Is the policy even matching the image?
$ kubectl get clusterpolicy verify-acme-api -o jsonpath='{.spec.rules[*].verifyImages[*].imageReferences}'

$ # 4. What did the engine actually say?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --since=10m \
    | grep -iE 'verifyimage|imageverif|cosign|notary'
```

Representative controller output during a failure:

```
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --since=5m | grep -i verify
I0813 14:22:07.881204  1 imageVerifyValidate.go:118] EngineVerifyImages "msg"="verifying image" "image"="ghcr.io/acme/api:v1.4.2" "policy"="verify-acme-api" "rule"="verify-signature-and-sbom"
E0813 14:22:09.114881  1 imageVerifyValidate.go:246] EngineVerifyImages "msg"="failed to verify image" "error"="no matching signatures:\nnone of the expected identities matched what was in the certificate" "image"="ghcr.io/acme/api:v1.4.2"
I0813 14:22:09.115402  1 event.go:377] Event(v1.ObjectReference{Kind:"ClusterPolicy", Name:"verify-acme-api"}): type: 'Warning' reason: 'PolicyViolation' Pod prod/api: [verify-signature-and-sbom] fail
```

Events, which survive after the `kubectl` output has scrolled away:

```
$ kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail -5
prod   3m   Warning  PolicyViolation  clusterpolicy/verify-acme-api   Pod prod/api: [verify-signature-and-sbom] fail (no matching signatures)
```

### 9.2 Error-to-cause table

| Message fragment | Root cause | Fix |
|---|---|---|
| `no signatures found` | The `.sig` tag / referrer does not exist. Image was never signed, or was signed by digest while you pushed a *different* digest (multi-arch index vs manifest). | `cosign tree $IMG`. For multi-arch, sign the **index** digest that the pod references. |
| `no matching signatures: none of the expected identities matched` | Signature exists; `subject`/`issuer` or public key does not match. | Compare `cosign verify … \| jq '.[0].optional.Subject'` against the policy's `subject` glob. Watch for `refs/heads/main` vs `refs/tags/*`. |
| `signature not found in transparency log` / `rekor` timeout | No egress from the Kyverno pod to `rekor.sigstore.dev:443`. | Open egress, or `rekor.ignoreTlog: true` (weakens the guarantee), or run private Rekor. |
| `GET https://ghcr.io/token?scope=…: UNAUTHORIZED` | Kyverno has no credentials for the registry. It does **not** inherit node or pod pull secrets. | Create the secret in the Kyverno namespace and reference it via `imageRegistryCredentials.secrets` or `--imagePullSecrets`; restart the controller. |
| `x509: certificate signed by unknown authority` | Private registry / private Fulcio with a CA that Kyverno's trust store lacks. | Mount the CA bundle into the controller and set `SSL_CERT_FILE`, or add it to `keyless.roots`. |
| `failed to fetch attestations` / `attestation checks failed … and predicate <type>` | No attestation of that `type`, or the JMESPath condition evaluated false. | `cosign verify-attestation --type <type> $IMG \| jq -r '.payload\|@base64d' \| jq '.predicate'` — then test your JMESPath against that exact object. |
| `context deadline exceeded` | `webhookConfiguration.timeoutSeconds` shorter than real verification latency. | Raise to 30 s; enable `imageVerifyCache`; move to a regional registry mirror. |
| Rule silently does nothing; report shows `skip` | `imageReferences` glob does not match the **normalized** reference. `nginx:1.27` normalizes to `docker.io/library/nginx:1.27`. | Use fully-qualified globs, or check the `kyverno` ConfigMap: `defaultRegistry` and `enableDefaultRegistryMutation`. |
| Deployments pass but bare Pods are blocked (or vice versa) | Autogen produced (or was prevented from producing) controller rules. | `kubectl get clusterpolicy X -o yaml \| grep autogen` and review `pod-policies.kyverno.io/autogen-controllers`. |
| `error unmarshalling PEM` / `unable to load certificate` | YAML block-scalar indentation mangled the PEM. | Use `\|-`, keep `-----BEGIN`/`-----END` lines intact, no trailing spaces. `yq '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys' policy.yaml` to see what actually parsed. |
| Works on first apply, fails after a re-push | Cache holding a stale verdict for a re-tagged digest, or the opposite — the tag now points at unsigned bytes. | This is the control working. Check `useCache` and TTL only after confirming with `cosign`. |
| Everything fails after weeks of stability, air-gapped | TUF root metadata expired. | Refresh the private TUF mirror; `features.tuf.root` must be current. |

### 9.3 Inspecting policy state

```
$ kubectl get clusterpolicy verify-acme-api
NAME              ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
verify-acme-api   true        false        Enforce           True    12d   Ready

$ kubectl describe clusterpolicy verify-acme-api | sed -n '/Conditions/,$p'
Conditions:
  Last Transition Time:  2026-08-01T09:14:22Z
  Message:               Ready
  Reason:                Succeeded
  Status:                True
  Type:                  Ready
```

A `READY: False` on an image-verification policy almost always means Kyverno failed to build the registry client — check the controller logs for `failed to create registry client`.

---

## 10. Rollout strategy and exceptions

Never introduce `verifyImages` with `Enforce` on day one. The measured sequence:

```
Phase 1  Audit, cluster-wide, required: false
         → Build the inventory. Which images have signatures at all?

Phase 2  Audit, cluster-wide, required: true
         → PolicyReport now shows every image that WOULD be blocked.
         → Drive that count to zero by fixing pipelines, not by weakening policy.

Phase 3  Enforce in one non-critical namespace via validationFailureActionOverrides

Phase 4  Enforce everywhere; overrides carve out kube-system and vendor namespaces

Phase 5  Add verifyDigest: true once every producer emits digests
```

Phase 1→2 in one policy:

```yaml
spec:
  validationFailureAction: Audit
  validationFailureActionOverrides:
    - action: Enforce
      namespaces: ["sandbox-supplychain"]     # phase 3 beachhead
    - action: Audit
      namespaces: ["*"]
```

### 10.1 Time-boxed exceptions

Vendor images that will never be signed need an explicit, auditable, expiring carve-out — not a permanent hole in `imageReferences`:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: vendor-monitoring-unsigned
  namespace: observability
  annotations:
    acme.io/ticket: SEC-4412
    acme.io/expires: "2026-11-30"
    acme.io/approver: platform-security
spec:
  exceptions:
    - policyName: verify-acme-api
      ruleNames:
        - verify-signature-and-sbom
        - autogen-verify-signature-and-sbom
  match:
    any:
      - resources:
          kinds: [Pod, Deployment, DaemonSet]
          namespaces: [observability]
          names: ["vendor-agent-*"]
```

Note that you must list the **autogen** rule name as well; forgetting it is why exceptions "don't work" for Deployments.

Pair this with a cleanup policy so the exception cannot outlive its ticket:

```yaml
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: expire-policy-exceptions
spec:
  match:
    any:
      - resources:
          kinds: [PolicyException]
  conditions:
    any:
      - key: "{{ time_before('{{ target.metadata.annotations.\"acme.io/expires\" }}T00:00:00Z', '{{ time_now_utc() }}') }}"
        operator: Equals
        value: true
  schedule: "0 3 * * *"
```

### 10.2 Hardening: protect the verification annotation

The `kyverno.io/verify-images` annotation is Kyverno's own record. Deny user-supplied writes to it so nobody can forge a "verified" marker on a resource that bypasses the mutating webhook path:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: protect-verify-images-annotation
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: block-annotation-writes
      match:
        any:
          - resources:
              kinds: [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob]
      exclude:
        any:
          - subjects:
              - kind: ServiceAccount
                name: kyverno-admission-controller
                namespace: kyverno
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value: [CREATE, UPDATE]
      validate:
        message: "The kyverno.io/verify-images annotation is managed by Kyverno and may not be set directly."
        deny:
          conditions:
            any:
              - key: "kyverno.io/verify-images"
                operator: AnyIn
                value: "{{ request.object.metadata.annotations.keys(@) || `[]` }}"
```

---

## 11. `ImageValidatingPolicy` — the CEL-based successor (Kyverno ≥ 1.14, `v1alpha1`)

Kyverno 1.14 introduced a new family of policy CRDs under `policies.kyverno.io/v1alpha1` that align with upstream Kubernetes `ValidatingAdmissionPolicy` conventions: `matchConstraints` instead of `match`, CEL instead of JMESPath, `validationActions` instead of `validationFailureAction`. `ImageValidatingPolicy` (short name `ivpol`) is the image-verification member.

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ImageValidatingPolicy
metadata:
  name: verify-acme-ivpol
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  evaluation:
    background:
      enabled: false
    mutateDigest:
      enabled: true
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchImageReferences:
    - glob: "ghcr.io/acme/*"
  attestors:
    - name: acme-ci
      cosign:
        keyless:
          identities:
            - issuer: "https://token.actions.githubusercontent.com"
              subjectRegExp: "^https://github\\.com/acme/api/\\.github/workflows/release\\.yaml@refs/tags/.*$"
  attestations:
    - name: sbom
      intoto:
        type: https://cyclonedx.org/bom
  validations:
    - expression: >-
        images.containers.map(image,
          verifyImageSignatures(image, [attestors.acme_ci]) > 0
        ).all(e, e)
      message: "every ACME container image must carry a valid CI signature"
```

| | `ClusterPolicy.verifyImages` (v1) | `ImageValidatingPolicy` (v1alpha1) |
|---|---|---|
| Stability | GA, the exam's primary target | Alpha — field names move between minor releases |
| Expression language | JMESPath | CEL |
| Matching | Kyverno `match`/`exclude` | Kubernetes `matchConstraints` (VAP-compatible) |
| Boolean logic over attestors | `attestors[].count` sets | Arbitrary CEL over `verifyImageSignatures()` results |
| Autogen for controllers | Yes | Via `autogen` configuration |
| Exceptions | `PolicyException` | `PolicyException` |

**Practical guidance.** Author production controls on `ClusterPolicy.verifyImages` today. Treat `ImageValidatingPolicy` as the direction of travel, and before writing one, confirm the shape against the CRD actually installed in your cluster rather than any document — including this one:

```
$ kubectl get crd imagevalidatingpolicies.policies.kyverno.io \
    -o jsonpath='{.spec.versions[*].name}{"\n"}'
v1alpha1

$ kubectl explain ivpol.spec --recursive | head -60
```

---

## 12. Exam-focused summary

- `verifyImages` runs in the **mutating** admission phase, because `mutateDigest` emits a JSONPatch. Validating rules see the already-pinned spec.
- `mutateDigest: true` is what closes the TOCTOU gap between verification and pull. A verification without digest pinning is theatre.
- `required: true` means "an image matching `imageReferences` that satisfies no attestor set is a violation." `required: false` is verify-if-present and is almost never what you want.
- **Attestor sets are ANDed; entries within a set are ANDed unless `count` is set, in which case `count`-of-N.** This is the boolean algebra the exam tests.
- Keyless binds the image to a *source workflow identity*; keys bind it only to *possession of a key*. `subject: "*"` destroys the control entirely.
- `attestations[].conditions[].key` JMESPath is rooted at the **predicate**, not the in-toto Statement.
- Kyverno's admission controller performs registry I/O with **its own** credentials — never the pod's `imagePullSecrets` and never the node's.
- Image references are **normalized** before glob matching (`nginx:1.27` → `docker.io/library/nginx:1.27`).
- Background scans do not re-verify signatures; a clean report is not evidence that running images are still signed.
- `failurePolicy: Fail` is correct for a security control and creates a hard availability coupling to the registry — mitigate with narrow `match`, replicas, a PDB, a regional mirror, and generous `timeoutSeconds`.
- Triage split: `no signatures found` = nothing there; `no matching signatures` = wrong identity.

---

## Referencias

**Kyverno — official documentation**
- Verify Images rule reference — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Verify Images: Sigstore/Cosign — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/
- Verify Images: Notary — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/
- Policy Exceptions — https://kyverno.io/docs/exceptions/
- Kyverno installation and configuration flags — https://kyverno.io/docs/installation/customization/
- Kyverno CLI (`apply`, `test`, `--registry`) — https://kyverno.io/docs/kyverno-cli/
- Kyverno metrics reference — https://kyverno.io/docs/monitoring/
- JMESPath custom filters (`time_since`, `regex_match`, `time_before`) — https://kyverno.io/docs/policy-types/cluster-policy/jmespath/
- Kyverno policy library — image verification — https://kyverno.io/policies/?policytypes=Sigstore
- Kyverno source (`ImageVerification` API types) — https://github.com/kyverno/kyverno/blob/main/api/kyverno/v1/image_verification_types.go
- Kyverno releases and upgrade notes — https://github.com/kyverno/kyverno/releases

**Sigstore**
- Cosign documentation — https://docs.sigstore.dev/cosign/signing/overview/
- Keyless signing / Fulcio — https://docs.sigstore.dev/certificate_authority/overview/
- Rekor transparency log — https://docs.sigstore.dev/logging/overview/
- Verifying with `cosign verify` / `verify-attestation` — https://docs.sigstore.dev/cosign/verifying/verify/
- `cosign-installer` GitHub Action — https://github.com/sigstore/cosign-installer
- Private/self-hosted Sigstore stack — https://github.com/sigstore/scaffolding

**Notary Project**
- Notation CLI documentation — https://notaryproject.dev/docs/
- Notary Project specifications — https://github.com/notaryproject/specifications

**Supply-chain standards**
- SLSA v1.0 specification and threat model — https://slsa.dev/spec/v1.0/threats
- SLSA provenance predicate — https://slsa.dev/spec/v1.0/provenance
- in-toto attestation framework — https://github.com/in-toto/attestation
- SLSA GitHub generator (container) — https://github.com/slsa-framework/slsa-github-generator
- CycloneDX specification — https://cyclonedx.org/specification/overview/

**OCI and Kubernetes**
- OCI Distribution Specification — referrers API — https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers
- Kubernetes admission webhooks (`failurePolicy`, `timeoutSeconds`, ordering) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Kubernetes images and image pull policy — https://kubernetes.io/docs/concepts/containers/images/

**Exam**
- KCA curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf