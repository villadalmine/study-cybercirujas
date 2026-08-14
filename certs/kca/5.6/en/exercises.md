# Exercises — 5.6 VerifyImage Rules

> **Scope.** These exercises build a full Sigstore/Notary supply-chain gate on a throwaway cluster and then break it on purpose. Every step is meant to be typed. Where the exact output depends on your Kyverno version, the step tells you to *observe* rather than to assume — the point of the topic is that you can read what the admission controller actually tells you.
>
> **Time:** ~120 min. **Exam weight:** 2.91.

---

## Lab prerequisites

| Tool | Minimum | Check |
|---|---|---|
| `kind` (or any cluster you can break) | 0.23 | `kind version` |
| `kubectl` | 1.28 | `kubectl version --client` |
| `helm` | 3.12 | `helm version --short` |
| Kyverno | 1.11+ (1.13 assumed) | `kubectl -n kyverno get deploy` |
| `cosign` | 2.2+ | `cosign version` |
| `crane` | 0.19+ | `crane version` |
| `jq`, `yq` (v4) | — | `jq --version; yq --version` |

The lab uses **`ttl.sh`** — an anonymous, ephemeral, no-authentication public registry (images expire after the TTL in the tag). It is chosen because *both* the kubelet and the Kyverno admission controller pod must be able to reach the registry, which a `localhost:5001` kind registry cannot satisfy. Exercise 9 covers the private-registry case explicitly.

Egress to `ttl.sh`, `fulcio.sigstore.dev` and `rekor.sigstore.dev` is required for the keyless exercise only.

---

## Exercise 1 — Build the lab and locate the moving parts

**Goal:** install Kyverno, publish an unsigned image, and identify *which* component performs the registry round-trip during admission.

1. Create the cluster.

   ```bash
   kind create cluster --name kca-5-6 --image kindest/node:v1.31.0
   kubectl config use-context kind-kca-5-6
   ```

2. Install Kyverno with all four controllers.

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno \
     --namespace kyverno --create-namespace \
     --set admissionController.replicas=1 \
     --set backgroundController.replicas=1 \
     --set reportsController.replicas=1 \
     --set cleanupController.replicas=1
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
   ```

3. List the webhook configurations Kyverno registered, **before** any policy exists.

   ```bash
   kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations \
     -o custom-columns=NAME:.metadata.name | grep -i kyverno
   ```

   Representative output:

   ```
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-policy-mutating-webhook-cfg
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-mutating-webhook-cfg
   mutatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-verify-mutating-webhook-cfg
   validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-policy-validating-webhook-cfg
   validatingwebhookconfiguration.admissionregistration.k8s.io/kyverno-resource-validating-webhook-cfg
   ...
   ```

   Note that `kyverno-resource-mutating-webhook-cfg` currently has an empty or wildcard-free `rules` list — Kyverno populates webhook rules dynamically from installed policies.

4. Install `cosign` and `crane`.

   ```bash
   curl -sSfL -o cosign https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   sudo install -m 0755 cosign /usr/local/bin/cosign && rm cosign
   curl -sSL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz \
     | sudo tar -xz -C /usr/local/bin crane
   cosign version && crane version
   ```

5. Publish two identical images under two different repositories — one you will sign, one you will not.

   ```bash
   export RAND=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
   export SIGNED="ttl.sh/kca-signed-${RAND}:24h"
   export UNSIGNED="ttl.sh/kca-unsigned-${RAND}:24h"

   crane copy busybox:1.36 "$SIGNED"
   crane copy busybox:1.36 "$UNSIGNED"

   crane digest "$SIGNED"
   crane digest "$UNSIGNED"
   echo "SIGNED=$SIGNED  UNSIGNED=$UNSIGNED"
   ```

   Both digests are identical — same bytes, different repositories.

6. Confirm the cluster can actually run one of them (no policy is installed yet).

   ```bash
   kubectl run smoke --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod smoke -o jsonpath='{.status.phase}{"\n"}'
   kubectl delete pod smoke
   ```

**Checkpoint questions**

- **Q1.1** During image verification, *which process* opens the TCP connection to the registry, and from which network position in the cluster? Why is "the kubelet can pull the image" not evidence that verification will succeed?
- **Q1.2** Both images have the same digest. If you sign `$SIGNED`, will a `cosign verify` of `$UNSIGNED` succeed, given that the signature covers the digest and the digests are equal? Explain in terms of *where* the signature artifact is stored.
- **Q1.3** Kyverno's admission controller is a webhook. Name the two fields on a `ClusterPolicy` that decide what happens to a `Pod` creation when the registry is unreachable and verification hangs.

---

## Exercise 2 — Sign the image and inspect what Sigstore actually pushed

**Goal:** stop treating the signature as magic. See the OCI artifact.

1. Generate a key pair. The empty password is a lab shortcut only.

   ```bash
   export COSIGN_PASSWORD=""
   cosign generate-key-pair
   ls -l cosign.key cosign.pub
   cat cosign.pub
   ```

   ```
   -----BEGIN PUBLIC KEY-----
   MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
   -----END PUBLIC KEY-----
   ```

2. Sign the image **without** uploading to the public transparency log.

   ```bash
   cosign sign --key cosign.key --tlog-upload=false --yes "$SIGNED"
   ```

   ```
   Pushing signature to: ttl.sh/kca-signed-9f3a2b1c
   ```

3. List the tags in the repository and locate the signature artifact.

   ```bash
   crane ls "ttl.sh/kca-signed-${RAND}"
   cosign triangulate "$SIGNED"
   ```

   ```
   24h
   sha256-9ae97d36d5b9e7d9a29a7f3d1e0b6f4c5a2d8e7b6c4a3f2e1d0c9b8a7f6e5d4c.sig
   ```

4. Look inside the signature manifest.

   ```bash
   crane manifest "$(cosign triangulate "$SIGNED")" | jq '.layers[0]'
   ```

   ```json
   {
     "mediaType": "application/vnd.dev.cosign.simplesigning.v1+json",
     "size": 251,
     "digest": "sha256:3b1e...",
     "annotations": {
       "dev.cosignproject.cosign/signature": "MEUCIQD8k...=="
     }
   }
   ```

5. Verify locally, with cosign only — no Kyverno involved yet.

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog "$SIGNED" | jq '.[0].critical'
   ```

   ```json
   {
     "identity": { "docker-reference": "ttl.sh/kca-signed-9f3a2b1c" },
     "image": { "docker-manifest-digest": "sha256:9ae97d36..." },
     "type": "cosign container image signature"
   }
   ```

6. Now do the same against the unsigned image and read the error verbatim.

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog "$UNSIGNED"
   ```

   ```
   Error: no matching signatures:
   ...
   main.go:74: error during command execution: no matching signatures
   ```

**Checkpoint questions**

- **Q2.1** The signature is stored as a tag named `sha256-<digest>.sig` in the *same repository*. What operational consequence does that have for `crane copy` / registry mirroring / air-gapped promotion pipelines? Which cosign and Kyverno settings exist to decouple the two?
- **Q2.2** The `critical.image.docker-manifest-digest` field pins the digest, while `critical.identity.docker-reference` records the repository. What attack does the second field prevent that the first one does not?
- **Q2.3** You passed `--tlog-upload=false`. What did you give up, and what must you now change in the Kyverno policy for verification to succeed?
- **Q2.4** Why did step 6 fail with `no matching signatures` rather than `no signatures found`? What does the difference between those two cosign errors tell you when you are debugging a real pipeline?

---

## Exercise 3 — Your first `verifyImages` rule, in Audit

**Goal:** write the rule, observe that Audit does not block, and read the `PolicyReport`.

1. Render the policy. The public key is injected with a `sed` that indents each PEM line by **14 spaces** — it must be deeper than the `publicKeys:` key at column 12.

   ```bash
   cat > 01-verify-audit.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-lab-images
   spec:
     validationFailureAction: Audit
     background: false
     failurePolicy: Fail
     webhookTimeoutSeconds: 30
     rules:
     - name: check-cosign-signature
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         verifyDigest: true
         required: true
         attestors:
         - count: 1
           entries:
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' cosign.pub)
               rekor:
                 ignoreTlog: true
   EOF
   ```

   > **Tip — do not count spaces in production.** Write the policy with a placeholder and inject the key structurally:
   > ```bash
   > yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("cosign.pub")' 01-verify-audit.yaml
   > ```

2. Sanity-check the YAML before it reaches the API server.

   ```bash
   yq '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys' 01-verify-audit.yaml
   ```

   You must see the full PEM, `-----BEGIN` through `-----END`, with no leading spaces inside the block.

3. Apply and wait for the policy to become ready.

   ```bash
   kubectl apply -f 01-verify-audit.yaml
   kubectl get cpol verify-lab-images
   ```

   ```
   NAME                ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
   verify-lab-images   true        false        Audit             True    5s    Ready
   ```

4. Observe that Kyverno has now registered webhook rules for `pods`.

   ```bash
   kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
     -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.rules[*].resources}{"\n"}{end}'
   ```

5. Create both pods.

   ```bash
   kubectl run signed   --image="$SIGNED"   --restart=Never --command -- sleep 3600
   kubectl run unsigned --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   kubectl get pods
   ```

6. Compare the image reference *as stored in the API server* for each pod.

   ```bash
   kubectl get pod signed   -o jsonpath='{.spec.containers[0].image}{"\n"}'
   kubectl get pod unsigned -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

7. Inspect the annotations Kyverno stamped on each pod.

   ```bash
   kubectl get pod signed   -o jsonpath='{.metadata.annotations}' | jq .
   kubectl get pod unsigned -o jsonpath='{.metadata.annotations}' | jq .
   ```

8. Read the policy report (allow the reports controller a few seconds).

   ```bash
   sleep 10
   kubectl get polr -n default
   kubectl get polr -n default -o yaml | yq '.items[].results[] | {rule, result, message}'
   ```

   ```yaml
   rule: check-cosign-signature
   result: fail
   message: 'failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h: .attestors[0].entries[0].keys: no signatures found'
   ```

**Checkpoint questions**

- **Q3.1** The `unsigned` pod is `Running`. Which field allowed that, and where does the failure survive instead?
- **Q3.2** Compare the two image strings from step 6. What did Kyverno change on the `signed` pod, and which field is responsible?
- **Q3.3** Which annotation appears on the verified pod, what does its value encode, and why does Kyverno persist the result on the object instead of only logging it?
- **Q3.4** The report message contains the JSON path `.attestors[0].entries[0].keys`. Reconstruct what that path is telling you and how you would use it in a policy with four attestor entries.
- **Q3.5** `spec.background` is `false`. Try setting it to `true` and re-applying. Whatever the API server answers, explain *why* image verification is a poor fit for background scanning.

---

## Exercise 4 — Enforce, and read the denial correctly

**Goal:** identify which webhook rejects a `verifyImages` failure, and why that is not the validating one.

1. Switch the policy to `Enforce`.

   ```bash
   kubectl patch cpol verify-lab-images --type merge \
     -p '{"spec":{"validationFailureAction":"Enforce"}}'
   kubectl delete pod signed unsigned --ignore-not-found
   ```

2. Recreate the unsigned pod and capture the whole error.

   ```bash
   kubectl run unsigned --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   ```

   Representative output:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

   resource Pod/default/unsigned was blocked due to the following policies

   verify-lab-images:
     check-cosign-signature: 'failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h:
       .attestors[0].entries[0].keys: no signatures found'
   ```

3. Confirm the signed pod is still admitted.

   ```bash
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

4. Use a server-side dry run — the standard way to test a policy without leaving objects behind.

   ```bash
   kubectl run probe --image="$UNSIGNED" --restart=Never --dry-run=server -o yaml
   ```

5. Now test a controller, not a bare pod.

   ```bash
   kubectl create deployment bad-deploy --image="$UNSIGNED"
   kubectl get deploy bad-deploy 2>/dev/null || echo "deployment was rejected"
   ```

6. Look at what Kyverno generated on your behalf.

   ```bash
   kubectl get cpol verify-lab-images -o yaml | yq '.status'
   kubectl get cpol verify-lab-images -o yaml | yq '.metadata.annotations'
   ```

7. Watch the events Kyverno emitted.

   ```bash
   kubectl get events -n default --sort-by=.lastTimestamp | tail -n 10
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
     | grep -iE 'imageverify|cosign|verifyimages'
   ```

**Checkpoint questions**

- **Q4.1** The denial came from `mutate.kyverno.svc-fail`, not from a validating webhook. Explain why a `verifyImages` rule is evaluated in the mutating admission phase, and what that implies about ordering relative to other mutations that rewrite the `image` field.
- **Q4.2** In the webhook name, what does the `-fail` suffix mean, and which policy field produced it? What would the suffix be if you set the other value?
- **Q4.3** In step 5, was the `Deployment` rejected outright, or was it accepted and then failed at ReplicaSet level? Which Kyverno feature decides this, and which annotation controls it?
- **Q4.4** A colleague argues that `Enforce` on a `verifyImages` rule is dangerous because "if the registry is slow, nothing can be deployed". Give the three configuration levers that shape that risk and the trade-off each one makes.

---

## Exercise 5 — `mutateDigest`, `verifyDigest`, `required`

**Goal:** these three booleans are the most-tested part of the topic. Change one at a time and observe.

1. Turn off digest mutation and re-test.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":false},
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":false}
   ]'
   kubectl delete pod signed --ignore-not-found
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

2. Now demand a digest but refuse to add one.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":true}
   ]'
   kubectl delete pod signed --ignore-not-found
   kubectl run signed --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   Representative output:

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

   resource Pod/default/signed was blocked due to the following policies

   verify-lab-images:
     check-cosign-signature: 'image ttl.sh/kca-signed-9f3a2b1c:24h does not have a digest'
   ```

3. Satisfy it by pinning the digest yourself.

   ```bash
   export DIG=$(crane digest "$SIGNED")
   kubectl run signed-pinned --image="ttl.sh/kca-signed-${RAND}@${DIG}" \
     --restart=Never --command -- sleep 3600
   kubectl get pod signed-pinned -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

4. Restore the safe defaults.

   ```bash
   kubectl patch cpol verify-lab-images --type json -p '[
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/mutateDigest","value":true},
     {"op":"replace","path":"/spec/rules/0/verifyImages/0/verifyDigest","value":true}
   ]'
   ```

5. Test the scope of the rule. `nginx` is *not* matched by `ttl.sh/kca-*`.

   ```bash
   kubectl run offscope --image=nginx:1.27 --restart=Never
   kubectl get pod offscope -o jsonpath='{.spec.containers[0].image}{"\n"}'
   kubectl get pod offscope -o jsonpath='{.metadata.annotations}' | jq .
   ```

6. Inspect how Kyverno normalises short image references before matching.

   ```bash
   kubectl -n kyverno get cm kyverno -o yaml | yq '.data | {defaultRegistry, enableDefaultRegistryMutation}'
   ```

7. Close the hole with a catch-all entry plus explicit exclusions.

   ```bash
   cat > 02-catch-all.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: deny-unverified-images
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: everything-must-be-verified
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "*"
         skipImageReferences:
         - "ttl.sh/kca-*"
         - "registry.k8s.io/*"
         - "ghcr.io/kyverno/*"
         required: true
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - keyless:
               subject: "https://github.com/my-org/*"
               issuer: "https://token.actions.githubusercontent.com"
               rekor:
                 url: https://rekor.sigstore.dev
   EOF
   kubectl apply -f 02-catch-all.yaml
   kubectl delete pod offscope --ignore-not-found
   kubectl run offscope --image=nginx:1.27 --restart=Never
   kubectl get polr -n default -o yaml | yq '.items[].results[] | select(.policy=="deny-unverified-images")'
   ```

8. Clean up the catch-all before continuing.

   ```bash
   kubectl delete -f 02-catch-all.yaml
   kubectl delete pod --all --ignore-not-found
   ```

**Checkpoint questions**

- **Q5.1** Write, in one sentence each, what `mutateDigest`, `verifyDigest` and `required` do, and give each field's default.
- **Q5.2** Why is `mutateDigest: true` a *security* control and not merely a convenience? Name the concrete race it closes between admission and `kubelet` pull.
- **Q5.3** In step 2, verification of the signature had already **succeeded**, yet the pod was denied. Which of the three booleans denied it, and why is that combination (`verifyDigest: true`, `mutateDigest: false`) a legitimate production choice for some teams?
- **Q5.4** In step 5, the `nginx` pod was admitted even though `required: true`. Explain the scope of `required` precisely. What is the *only* correct way to make "any image not covered by a verification rule is denied" true?
- **Q5.5** `required` is the field that survives the mutating phase. Describe the admission path where verification never runs but `required` still blocks the request.
- **Q5.6** `skipImageReferences` in step 7 excludes `registry.k8s.io/*`. Argue both sides: why excluding control-plane images is standard practice, and what it costs you.

---

## Exercise 6 — Attestor sets: `count`, AND vs OR, and key rotation

**Goal:** model "two independent teams must sign" and then rotate a key with zero downtime.

1. Generate a second key pair, representing the security team.

   ```bash
   mkdir -p sec && (cd sec && COSIGN_PASSWORD="" cosign generate-key-pair)
   ls sec/cosign.key sec/cosign.pub
   ```

2. Build a policy with **one** attestor set holding **two** entries and `count: 1`.

   ```bash
   cat > 03-attestors-or.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-two-keys
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
     - name: any-of-two-keys
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         attestors:
         - count: 1
           entries:
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' cosign.pub)
               rekor:
                 ignoreTlog: true
           - keys:
               publicKeys: |-
   $(sed 's/^/              /' sec/cosign.pub)
               rekor:
                 ignoreTlog: true
   EOF
   kubectl delete cpol verify-lab-images --ignore-not-found
   kubectl apply -f 03-attestors-or.yaml
   kubectl run or-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   The image carries only the *first* key's signature and is admitted.

3. Change `count` to `2` and retry.

   ```bash
   kubectl patch cpol verify-two-keys --type json \
     -p '[{"op":"replace","path":"/spec/rules/0/verifyImages/0/attestors/0/count","value":2}]'
   kubectl delete pod or-test --ignore-not-found
   kubectl run and-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ...
     any-of-two-keys: 'failed to verify image ttl.sh/kca-signed-9f3a2b1c:24h:
       .attestors[0].entries[1].keys: no matching signatures'
   ```

4. Add the second signature and retry.

   ```bash
   COSIGN_PASSWORD="" cosign sign --key sec/cosign.key --tlog-upload=false --yes "$SIGNED"
   crane ls "ttl.sh/kca-signed-${RAND}"
   kubectl run and-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get pod and-test -o jsonpath='{.spec.containers[0].image}{"\n"}'
   ```

   Note that `crane ls` still shows a **single** `.sig` tag.

5. Now express the same requirement as **two attestor sets** and confirm it behaves identically.

   ```bash
   kubectl get cpol verify-two-keys -o yaml \
     | yq '.spec.rules[0].verifyImages[0].attestors' > /tmp/attestors.yaml
   # Split the single set of two entries into two sets of one entry each:
   yq -i '.spec.rules[0].verifyImages[0].attestors =
     [ {"entries":[ .spec.rules[0].verifyImages[0].attestors[0].entries[0] ]},
       {"entries":[ .spec.rules[0].verifyImages[0].attestors[0].entries[1] ]} ]' 03-attestors-or.yaml
   yq '.spec.rules[0].verifyImages[0].attestors | length' 03-attestors-or.yaml
   kubectl apply -f 03-attestors-or.yaml
   kubectl delete pod and-test --ignore-not-found
   kubectl run and-test-2 --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

6. Move a key out of the policy body and into a `Secret` — the pattern you want in Git.

   ```bash
   COSIGN_PASSWORD="" cosign generate-key-pair k8s://kyverno/cosign-rotation
   kubectl -n kyverno get secret cosign-rotation -o jsonpath='{.data}' | jq 'keys'
   ```

   ```json
   ["cosign.key","cosign.password","cosign.pub"]
   ```

   ```bash
   cat > 04-secret-key.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-secret-key
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: key-from-secret
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         attestors:
         - count: 1
           entries:
           - keys:
               secret:
                 name: cosign-rotation
                 namespace: kyverno
               rekor:
                 ignoreTlog: true
   EOF
   kubectl apply -f 04-secret-key.yaml
   kubectl get cpol verify-secret-key
   ```

7. Clean up.

   ```bash
   kubectl delete cpol verify-two-keys verify-secret-key --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Checkpoint questions**

- **Q6.1** State the boolean algebra of `attestors` precisely: what does a list of attestor *sets* mean, what does a list of *entries* within one set mean, and what does `count` change? What is the default when `count` is omitted?
- **Q6.2** In step 4, `crane ls` still shows one `.sig` tag after two signings. Where did the second signature go, and how does Kyverno's `count: 2` see two distinct signatures in one artifact?
- **Q6.3** Steps 3 and 5 enforce the same requirement two different ways. Give one concrete reason to prefer two attestor sets over `count: 2` in a real policy.
- **Q6.4** Design a **zero-downtime key rotation**: you must retire key A and adopt key B across thousands of images without any window in which running deployments are blocked. Write the sequence of policy edits and re-signing steps in order.
- **Q6.5** `keys.secret` reads a `Secret` in the `kyverno` namespace. What are the two security properties of that namespace choice, and what RBAC mistake would silently defeat the whole policy?
- **Q6.6** Besides `keys`, name the other attestor entry types and one scenario where each is the right choice.

---

## Exercise 7 — Keyless verification and identity anchoring

**Goal:** verify by *who signed* rather than by *which key*, and see how a sloppy identity pattern nullifies the control.

> Steps 1–3 require an interactive browser OIDC flow and egress to Fulcio and Rekor. If you cannot run them, do step 4 onward — the analysis is what the exam tests.

1. Sign keylessly. A browser window opens for OIDC.

   ```bash
   cosign sign --yes "$SIGNED"
   ```

2. Inspect the ephemeral Fulcio certificate that was minted for you.

   ```bash
   cosign verify --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" "$SIGNED" | jq '.[0].optional.Subject'
   ```

3. Locate the Rekor transparency-log entry.

   ```bash
   cosign verify --certificate-identity "you@example.com" \
     --certificate-oidc-issuer "https://accounts.google.com" "$SIGNED" \
     | jq '.[0].optional.Bundle.Payload | {logIndex, integratedTime}'
   ```

4. Write a keyless policy for a **CI identity**, which is what you will actually do in production.

   ```bash
   cat > 05-keyless.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-keyless-ci
   spec:
     validationFailureAction: Audit
     background: false
     webhookTimeoutSeconds: 30
     rules:
     - name: github-actions-identity
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ghcr.io/my-org/*"
         mutateDigest: true
         required: true
         attestors:
         - count: 1
           entries:
           - keyless:
               issuer: "https://token.actions.githubusercontent.com"
               subjectRegExp: "^https://github\\.com/my-org/[^/]+/\\.github/workflows/release\\.yaml@refs/heads/main$"
               rekor:
                 url: https://rekor.sigstore.dev
               ctlog:
                 ignoreSCT: false
   EOF
   kubectl apply -f 05-keyless.yaml
   kubectl get cpol verify-keyless-ci
   ```

5. Now write down — **before** reading the answers — what each of these four variants would allow. Do not apply them; this is a desk exercise.

   ```yaml
   # (a)
   keyless: { issuer: "https://token.actions.githubusercontent.com", subject: "*" }

   # (b)
   keyless: { issuer: "https://accounts.google.com", subject: "release-bot@my-org.com" }

   # (c)
   keyless: { issuer: "https://token.actions.githubusercontent.com",
              subjectRegExp: "https://github.com/my-org/.*" }

   # (d)
   keyless: { issuer: "https://token.actions.githubusercontent.com",
              subjectRegExp: "^https://github\\.com/my-org/[^/]+/\\.github/workflows/release\\.yaml@refs/tags/v.*$" }
   ```

6. Sketch the private-Sigstore variant (BYO Fulcio/Rekor), which is the common enterprise deployment.

   ```yaml
   attestors:
   - entries:
     - keyless:
         issuer: "https://oidc.corp.example.com"
         subject: "spiffe://corp.example.com/ns/ci/sa/builder"
         roots: |-
           -----BEGIN CERTIFICATE-----
           <corporate Fulcio root CA>
           -----END CERTIFICATE-----
         rekor:
           url: https://rekor.corp.example.com
           pubkey: |-
             -----BEGIN PUBLIC KEY-----
             <corporate Rekor log public key>
             -----END PUBLIC KEY-----
         ctlog:
           pubkey: |-
             -----BEGIN PUBLIC KEY-----
             <corporate CT log public key>
             -----END PUBLIC KEY-----
   ```

7. Clean up.

   ```bash
   kubectl delete cpol verify-keyless-ci --ignore-not-found
   ```

**Checkpoint questions**

- **Q7.1** In keyless mode there is no long-lived key. What replaces it as the root of trust, and what is the lifetime of the signing certificate? Why is a transparency log *mandatory* rather than optional in that design?
- **Q7.2** Rank variants (a)–(d) from weakest to strongest and state the concrete attack each weaker one permits.
- **Q7.3** Variant (c) uses `subjectRegExp` without anchors. Construct a subject string that an attacker could obtain which matches (c) but not (d).
- **Q7.4** What do `rekor.ignoreTlog: true` and `ctlog.ignoreSCT: true` each disable, and in which of the two — key-based or keyless — is each one relevant?
- **Q7.5** Your organisation runs a private Fulcio. Which three fields in step 6 must be populated, and what breaks if you populate `roots` but omit `ctlog.pubkey`?
- **Q7.6** Keyless verification makes an outbound call to Rekor on every unique admission. What are the availability and latency consequences, and which two Kyverno settings mitigate them?

---

## Exercise 8 — Attestations: verifying *claims*, not just authorship

**Goal:** attach SLSA provenance to the image and gate on its content with JMESPath conditions.

1. Author a minimal SLSA v0.2 provenance predicate.

   ```bash
   cat > provenance.json <<'EOF'
   {
     "builder": { "id": "https://ci.example.com/kca-lab@v1" },
     "buildType": "https://ci.example.com/build@v1",
     "invocation": {
       "configSource": {
         "uri": "git+https://github.com/example/app@refs/heads/main",
         "digest": { "sha1": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" },
         "entryPoint": "release.yaml"
       }
     },
     "metadata": {
       "buildInvocationID": "4711",
       "reproducible": false,
       "completeness": { "parameters": true, "environment": false, "materials": false }
     },
     "materials": [
       { "uri": "git+https://github.com/example/app",
         "digest": { "sha1": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" } }
     ]
   }
   EOF
   ```

2. Attach it as a signed in-toto attestation.

   ```bash
   COSIGN_PASSWORD="" cosign attest --key cosign.key --type slsaprovenance \
     --predicate provenance.json --tlog-upload=false --yes "$SIGNED"
   crane ls "ttl.sh/kca-signed-${RAND}"
   ```

   ```
   24h
   sha256-9ae97d36...d4c.sig
   sha256-9ae97d36...d4c.att
   ```

3. Read the attestation back and decode the in-toto statement.

   ```bash
   cosign verify-attestation --key cosign.pub --type slsaprovenance \
     --insecure-ignore-tlog "$SIGNED" \
     | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject}'
   ```

   ```json
   {
     "_type": "https://in-toto.io/Statement/v0.1",
     "predicateType": "https://slsa.dev/provenance/v0.2",
     "subject": [{ "name": "ttl.sh/kca-signed-9f3a2b1c",
                   "digest": { "sha256": "9ae97d36..." } }]
   }
   ```

4. Write a policy that verifies the attestation **and** asserts facts about the predicate.

   ```bash
   cat > 06-attestations.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-slsa-provenance
   spec:
     validationFailureAction: Enforce
     background: false
     webhookTimeoutSeconds: 30
     rules:
     - name: check-provenance
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         attestations:
         - type: https://slsa.dev/provenance/v0.2
           attestors:
           - count: 1
             entries:
             - keys:
                 publicKeys: |-
   $(sed 's/^/                  /' cosign.pub)
                 rekor:
                   ignoreTlog: true
           conditions:
           - all:
             - key: "{{ builder.id }}"
               operator: Equals
               value: "https://ci.example.com/kca-lab@v1"
             - key: "{{ regex_match('^git\\\\+https://github\\\\.com/example/app@refs/heads/main\$', invocation.configSource.uri) }}"
               operator: Equals
               value: true
   EOF
   yq '.spec.rules[0].verifyImages[0].attestations[0].conditions' 06-attestations.yaml
   kubectl apply -f 06-attestations.yaml
   ```

   > Indentation note: `attestations[].attestors` sits two levels deeper than in Exercise 3, so the PEM body is indented **18 spaces** here.

5. Test the passing case, then break the condition on purpose.

   ```bash
   kubectl delete pod --all --ignore-not-found
   kubectl run prov-ok --image="$SIGNED" --restart=Never --command -- sleep 3600

   kubectl patch cpol verify-slsa-provenance --type json -p '[
     {"op":"replace",
      "path":"/spec/rules/0/verifyImages/0/attestations/0/conditions/0/all/0/value",
      "value":"https://ci.example.com/some-other-builder@v1"}
   ]'
   kubectl delete pod prov-ok --ignore-not-found
   kubectl run prov-bad --image="$SIGNED" --restart=Never --command -- sleep 3600
   ```

   ```
   Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
   ...
     check-provenance: 'failed to verify image ttl.sh/kca-signed-9f3a2b1c:24h:
       attestation checks failed for https://slsa.dev/provenance/v0.2 and predicate ...'
   ```

6. Test the "signed but no attestation" case with the *unsigned* image.

   ```bash
   kubectl run prov-missing --image="$UNSIGNED" --restart=Never --command -- sleep 3600
   ```

7. Clean up.

   ```bash
   kubectl delete cpol verify-slsa-provenance --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Checkpoint questions**

- **Q8.1** Distinguish a *signature* from an *attestation* at three levels: what is signed, where it is stored in the registry, and what security question each one answers.
- **Q8.2** In the `conditions` block you wrote `{{ builder.id }}`, not `{{ predicate.builder.id }}`. What is the JMESPath evaluation root for `attestations[].conditions`, and what would the expression be if the root were the whole in-toto statement?
- **Q8.3** The `attestations[]` entry carries its own `attestors`. What does it mean if a `verifyImages` entry has **both** a top-level `attestors` and an `attestations[].attestors` list?
- **Q8.4** Attestations are how you gate on things a signature cannot express. Give three production gates you could enforce this way, and name the predicate type for each.
- **Q8.5** An image carries the correct SLSA predicate type but the attestation is signed with an untrusted key. Which of the two failure messages do you expect — "no matching signatures" or "attestation checks failed" — and why does the ordering matter for debugging?
- **Q8.6** `--tlog-upload=false` on `cosign attest` also skipped the log. In a real SLSA L3 pipeline, why is skipping the transparency log for provenance worse than skipping it for a plain signature?

---

## Exercise 9 — Notary Project (`type: Notary`) and private registries

**Goal:** the second supported signature format, and the credential path that breaks in every real cluster.

1. Install `notation` and create a test certificate.

   ```bash
   curl -sSL https://github.com/notaryproject/notation/releases/latest/download/notation_Linux_amd64.tar.gz \
     | sudo tar -xz -C /usr/local/bin notation
   notation version
   notation cert generate-test --default "kca-lab.io"
   notation cert ls
   ```

2. Sign the image with notation and inspect what landed in the registry.

   ```bash
   notation sign "$SIGNED"
   notation ls "$SIGNED"
   crane manifest "$SIGNED" | jq '.mediaType'
   ```

   > If your registry does not implement the OCI 1.1 **referrers API**, `notation sign` falls back to a referrers tag schema (`sha256-<digest>`). Record which one you observed.

3. Export the certificate for the policy.

   ```bash
   CERT=$(ls ~/.config/notation/localkeys/kca-lab.io.crt)
   cat "$CERT" | head -3
   ```

4. Write the Notary policy.

   ```bash
   cat > 07-notary.yaml <<EOF
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-notary
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: check-notation-signature
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - type: Notary
         imageReferences:
         - "ttl.sh/kca-*"
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - certificates:
               cert: |-
   $(sed 's/^/              /' "$CERT")
   EOF
   kubectl apply -f 07-notary.yaml
   kubectl delete pod --all --ignore-not-found
   kubectl run notary-test --image="$SIGNED" --restart=Never --command -- sleep 3600
   kubectl get polr -n default -o yaml | yq '.items[].results[] | select(.policy=="verify-notary")'
   ```

5. Now model a **private registry**. Create a pull secret in the Kyverno namespace and wire it into the rule.

   ```bash
   kubectl -n kyverno create secret docker-registry regcred \
     --docker-server=registry.corp.example.com \
     --docker-username=ci-bot \
     --docker-password='<token>'

   cat > 08-private-registry.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-private-registry
   spec:
     validationFailureAction: Audit
     background: false
     rules:
     - name: check-corp-images
       match:
         any:
         - resources:
             kinds:
             - Pod
       verifyImages:
       - imageReferences:
         - "registry.corp.example.com/*"
         imageRegistryCredentials:
           allowInsecureRegistry: false
           providers:
           - default
           - amazon
           - google
           secrets:
           - regcred
         useCache: true
         mutateDigest: true
         attestors:
         - count: 1
           entries:
           - keyless:
               issuer: "https://oidc.corp.example.com"
               subject: "spiffe://corp.example.com/ns/ci/sa/builder"
   EOF
   kubectl apply -f 08-private-registry.yaml
   ```

6. Inspect the global credential and cache knobs on the admission controller.

   ```bash
   kubectl -n kyverno get deploy kyverno-admission-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'imagepull|imageverifycache|registry'
   ```

   ```
   "--imagePullSecrets=regcred"
   "--imageVerifyCacheEnabled=true"
   "--imageVerifyCacheMaxSize=1000"
   "--imageVerifyCacheTTLDuration=60m"
   ```

7. Clean up.

   ```bash
   kubectl delete cpol verify-notary verify-private-registry --ignore-not-found
   kubectl delete pod --all --ignore-not-found
   ```

**Checkpoint questions**

- **Q9.1** How does a Notary Project signature differ from a cosign signature in *where the registry stores it*? Which registry API feature does Notary depend on, and what is the practical failure you see on a registry that lacks it?
- **Q9.2** In a `type: Notary` rule, which attestor entry type do you use, and why is `keys.publicKeys` not the right field?
- **Q9.3** `imageRegistryCredentials.secrets` names a secret — in which namespace must it exist, and why not in the pod's namespace? What is the multi-tenancy consequence of that answer?
- **Q9.4** What does `providers: [amazon, google]` add that a static secret does not? Which cluster identity feature is it consuming?
- **Q9.5** `allowInsecureRegistry: true` — precisely what does it relax, and why is it a strictly worse control than adding the registry CA to Kyverno's trust store?
- **Q9.6** The verification cache has a 60-minute TTL. You discover a signing key was compromised and remove it from the policy at 14:00. Reason through the exact exposure window for (a) new pods of an image already verified at 13:59, and (b) an image never seen before. Which knob shortens it and what does that cost?

---

## Exercise 10 — Testing policies in CI and diagnosing failures

**Goal:** get verification out of the cluster and into a pull request, then build a fault dictionary.

1. Restore the Exercise 3 policy and create a resource manifest for offline testing.

   ```bash
   kubectl apply -f 01-verify-audit.yaml
   cat > pods.yaml <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: good
   spec:
     containers:
     - name: app
       image: ${SIGNED}
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad
   spec:
     containers:
     - name: app
       image: ${UNSIGNED}
   EOF
   ```

2. Run the policy with the Kyverno CLI. `--registry` is what allows real registry calls.

   ```bash
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry
   ```

   Representative output:

   ```
   Applying 1 policy rule(s) to 2 resource(s)...

   policy verify-lab-images -> resource default/Pod/bad failed:
   1. check-cosign-signature: failed to verify image ttl.sh/kca-unsigned-9f3a2b1c:24h: .attestors[0].entries[0].keys: no signatures found

   pass: 1, fail: 1, warn: 0, error: 0, skip: 0
   ```

3. Turn that into a declarative test that CI can assert on.

   ```bash
   cat > kyverno-test.yaml <<'EOF'
   apiVersion: cli.kyverno.io/v1alpha1
   kind: Test
   metadata:
     name: verify-image-signatures
   policies:
   - 01-verify-audit.yaml
   resources:
   - pods.yaml
   results:
   - policy: verify-lab-images
     rule: check-cosign-signature
     kind: Pod
     resources:
     - good
     result: pass
   - policy: verify-lab-images
     rule: check-cosign-signature
     kind: Pod
     resources:
     - bad
     result: fail
   EOF
   kyverno test . --registry
   ```

4. Deliberately produce each fault below and record the exact message you get. Fill the table yourself before checking the answers.

   ```bash
   # (a) wrong key
   (cd /tmp && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix wrong)
   yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("/tmp/wrong.pub")' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry

   # (b) transparency log required but absent
   yq -i 'del(.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.rekor)' 01-verify-audit.yaml
   yq -i '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys = load_str("cosign.pub")' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry

   # (c) pattern that never matches
   yq -i '.spec.rules[0].verifyImages[0].imageReferences = ["kca-*"]' 01-verify-audit.yaml
   kyverno apply 01-verify-audit.yaml --resource pods.yaml --registry
   ```

   | # | Fault injected | Message observed | Root cause |
   |---|---|---|---|
   | a | wrong public key | | |
   | b | `rekor.ignoreTlog` removed | | |
   | c | `imageReferences: ["kca-*"]` | | |

5. Learn where the signal lives at runtime.

   ```bash
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=300 \
     | grep -iE 'imageVerify|cosign|notation|attestor'
   kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail
   kubectl get clusterpolicyreports,policyreports -A
   kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
   curl -s localhost:8000/metrics | grep -E 'kyverno_policy_results_total|kyverno_admission_review_duration'
   ```

6. Cover images that are **not** in a pod spec — a CRD field. Read this rule and predict its behaviour.

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: verify-tekton-step-images
   spec:
     validationFailureAction: Enforce
     background: false
     rules:
     - name: check-task-steps
       match:
         any:
         - resources:
             kinds:
             - tasks.tekton.dev/v1beta1
       imageExtractors:
         Task:
         - path: /spec/steps/*/image
       verifyImages:
       - imageReferences:
         - "ghcr.io/my-org/*"
         mutateDigest: true
         attestors:
         - entries:
           - keyless:
               issuer: "https://token.actions.githubusercontent.com"
               subjectRegExp: "^https://github\\.com/my-org/.+@refs/heads/main$"
   ```

7. Tear down.

   ```bash
   kubectl delete cpol --all
   kind delete cluster --name kca-5-6
   ```

**Checkpoint questions**

- **Q10.1** Why does `kyverno apply` need an explicit `--registry` flag instead of always contacting registries? Give the CI consequence of forgetting it.
- **Q10.2** Complete the fault table from step 4 and explain, for each, the single most efficient next diagnostic command.
- **Q10.3** Fault (c) is the dangerous one. The CLI reported no failure at all. What did the result summary look like, and why is a policy that silently matches nothing worse than one that fails loudly? What test assertion catches it?
- **Q10.4** In step 6, what would happen to that policy *without* the `imageExtractors` block, and what does `mutateDigest: true` rewrite in a `Task`?
- **Q10.5** You are on call. Pods across the cluster suddenly fail admission with `context deadline exceeded` from `mutate.kyverno.svc-fail`. List, in order, the four checks you run and the immediate mitigation that does **not** delete the policy.
- **Q10.6** Enumerate the ways a `verifyImages` gate can be bypassed by a determined operator with cluster access, and state which one `required: true` closes.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** The **Kyverno admission controller pod** performs the registry round-trip, from inside the cluster, using the pod network and the Kyverno ServiceAccount's environment (its own DNS, egress policy, proxy env vars and credentials). The kubelet's ability to pull is unrelated: the kubelet runs on the node network, may use node-level credentials and a different proxy, and pulls the *image*, while Kyverno fetches the *signature and attestation artifacts*. This asymmetry is the single most common cause of "it works on my laptop and the node can pull, but admission fails": a `NetworkPolicy` on the `kyverno` namespace, an egress proxy that the pod does not inherit, or a registry reachable only from the node network.

**A1.2** It will fail. The signature is not embedded in the image manifest; cosign pushes a **separate OCI artifact into the same repository**, tagged `sha256-<digest>.sig`. `$UNSIGNED` lives in a different repository, so that tag does not exist there — cosign reports `no signatures found`. Identical content does not carry identical signatures, because the signature's storage location is repository-scoped, and because the payload also records `docker-reference`.

**A1.3** `spec.failurePolicy` (`Fail` blocks the request when the webhook errors or times out; `Ignore` admits it) and `spec.webhookTimeoutSeconds` (how long the API server waits; capped at 30 by Kubernetes). Together they define the availability/security trade-off of the gate.

### Exercise 2

**A2.1** Because the signature is a sibling tag rather than part of the manifest, `crane copy image:tag newrepo/image:tag` copies the image and **silently leaves the signature behind** — the promoted image then fails verification in the target environment. Remedies: copy the whole repository or explicitly copy the `.sig` tag (`cosign copy src dst`, which copies signatures/attestations too); or decouple storage entirely with `COSIGN_REPOSITORY` at signing time and the matching `repository:` field on the Kyverno attestor, so signatures always live in one dedicated repo regardless of where the image goes.

**A2.2** `docker-manifest-digest` binds the signature to exact content. `docker-reference` binds it to the *name* it was signed under, which prevents a **repository-confusion / relocation attack**: an attacker who can push to a repo you trust cannot take a legitimately signed artifact from an untrusted repo and re-host it under a trusted name, because the recorded reference will not match.

**A2.3** You skipped uploading the signature entry to the Rekor transparency log, so there is no independent, tamper-evident, timestamped record that the signature existed — you lose detectability of key compromise and the ability to verify signatures made before a key was revoked. Consequently the Kyverno attestor must set `rekor: { ignoreTlog: true }`; otherwise Kyverno demands a log entry and fails even though the signature itself is valid.

**A2.4** `no signatures found` means the `.sig` artifact does not exist at all in that repository (nothing was ever signed, or you are looking at the wrong repo/digest). `no matching signatures` means signature artifacts **do** exist but none of them verify against the material you supplied (wrong key, wrong identity, wrong certificate chain, or a Rekor/SCT requirement not satisfied). Step 6 produced `no matching signatures` in cosign's phrasing because it distinguishes only at verification time. The practical rule: *found* → registry/repo/copy problem; *matching* → trust-material problem. That single distinction routes most incidents correctly on the first attempt.

### Exercise 3

**A3.1** `spec.validationFailureAction: Audit`. The failure is recorded in a `PolicyReport` in the resource's namespace (and as a Kubernetes `Event`), while the request is admitted. In Kyverno 1.13+ the equivalent is the per-rule `spec.rules[].verifyImages[].failureAction`, with `validationFailureAction` deprecated — recognise both spellings.

**A3.2** The `signed` pod's image was rewritten to contain `@sha256:…`, pinning it to the exact manifest that was verified. `mutateDigest: true` (the default) does this. The `unsigned` pod was left untouched because verification failed — Kyverno does not pin what it could not verify.

**A3.3** `kyverno.io/verify-images`, whose value is a JSON map of image reference → verification boolean, for example `{"ttl.sh/kca-signed-9f3a2b1c:24h":true}`. Persisting it on the object (a) lets the validating phase confirm that verification actually happened without re-contacting the registry, (b) makes the decision auditable on the resource itself, and (c) avoids re-verification on subsequent updates of an unchanged image. It is Kyverno-managed state, not a client input.

**A3.4** The path locates the failure inside the rule's own structure: attestor set index 0 → entry index 0 → the `keys` attestor type. With four entries you read it as "entry N of set M is the one that did not verify", which is exactly what you need when a `count: 2`-of-4 rule fails and you must know *which* signer is missing rather than re-testing all four by hand.

**A3.5** Kyverno excludes `verifyImages` rules from background scanning, and the recommended (and in many versions required) setting is `background: false`. The reasons are substantive, not cosmetic: background scans re-evaluate stored resources outside admission, where there is no request to mutate — so `mutateDigest` cannot apply — and each scan would re-issue registry and Rekor calls for every pod in the cluster on every scan interval, turning a per-admission cost into a continuous one, with results that are stale the moment a tag moves. Verification belongs at admission, where it can both decide and pin.

### Exercise 4

**A4.1** `verifyImages` runs in the **mutating** admission phase because a successful verification must be able to rewrite the image reference to its digest and stamp the `kyverno.io/verify-images` annotation — both are mutations. A rule that can mutate must run where mutations are allowed, so its denial also surfaces from the mutating webhook. Ordering consequence: any other mutation that rewrites `image` (a registry-rewriting mutate rule, a mirror injector, another webhook) must be ordered **before** verification, or you will verify one reference and run another. Within Kyverno, image verification rules are processed ahead of ordinary mutate rules for this reason; across webhooks, you control it with webhook ordering and by keeping image rewriting inside Kyverno.

**A4.2** `-fail` encodes `spec.failurePolicy: Fail`. Kyverno registers separate webhook endpoints per failure policy so that `Fail` and `Ignore` policies can coexist; with `failurePolicy: Ignore` the request would be handled by `mutate.kyverno.svc-ignore`.

**A4.3** The `Deployment` is rejected outright, because Kyverno's **auto-generation** (autogen) synthesises equivalent rules for pod controllers — `Deployment`, `DaemonSet`, `StatefulSet`, `Job`, `CronJob`, `ReplicaSet`, `ReplicationController` — and you can see them under `status.autogen.rules`. The `pod-policies.kyverno.io/autogen-controllers` annotation controls the set (e.g. `none` to disable, or an explicit list). This matters enormously for UX: without autogen, `kubectl create deployment` succeeds and the failure appears asynchronously as ReplicaSet events that the user never sees.

**A4.4** (1) `failurePolicy` — `Ignore` keeps the cluster deployable when Kyverno or the registry is down, at the cost of a fail-open window; `Fail` is the secure choice and makes the registry a control-plane dependency. (2) `webhookTimeoutSeconds` — a shorter timeout limits API-server latency but converts slow registries into failures sooner. (3) Verification caching (`useCache`, `--imageVerifyCacheTTLDuration`) — removes the registry from the hot path for already-seen digests, at the cost of a revocation lag. Secondary levers: `resourceFilters` in the `kyverno` ConfigMap to exclude `kube-system` and the `kyverno` namespace so a broken policy cannot deadlock the control plane, and running the admission controller with multiple replicas and a PDB.

### Exercise 5

**A5.1** `mutateDigest` (default `true`): after successful verification, rewrite the image reference to include the resolved `@sha256:` digest. `verifyDigest` (default `true`): require that the image reference contains a digest — a validation, not a mutation. `required` (default `true`): require that every image this rule selects actually carries a passing verification result; enforced in the validating phase.

**A5.2** Without digest pinning there is a genuine **time-of-check to time-of-use** gap: Kyverno resolves `app:v1` to a digest, verifies the signature on that digest, and admits the pod — but the pod spec still says `app:v1`. Between admission and the kubelet's pull (and on every later restart, rescheduling, or node replacement), an attacker with push access can move the `v1` tag to a different, unsigned manifest, and the kubelet will happily pull it. `mutateDigest: true` writes the verified digest into the spec, so the kubelet pulls exactly the bytes that were verified, forever.

**A5.3** `verifyDigest: true` denied it: the signature verified, but the reference had no digest and Kyverno was not permitted to add one. The combination is legitimate for teams who require *their CI* to emit digest-pinned manifests — the cluster refuses to guess. It makes provenance the pipeline's responsibility, keeps the stored spec byte-identical to what was reviewed in Git (important for GitOps drift detection, since a Kyverno mutation would otherwise show up as permanent drift against the Argo CD/Flux desired state), and avoids Kyverno mutating resources at all.

**A5.4** `required` is scoped to the images that this rule's `imageReferences` selects. It does not mean "all images in the cluster must be verified"; an image no `verifyImages` entry matches is simply outside the rule's jurisdiction and is admitted. The only correct way to make "unverified is denied" true is a **catch-all rule** — `imageReferences: ["*"]` with `required: true` — plus a deliberate `skipImageReferences` allowlist for images you accept unsigned (control-plane images, third-party base images). Note that Kyverno normalises short references using the `defaultRegistry` and `enableDefaultRegistryMutation` keys in the `kyverno` ConfigMap, so `nginx` is matched as `docker.io/nginx`; always write fully qualified patterns and prove them with `kyverno apply` rather than assuming.

**A5.5** The mutating phase can be skipped or fail to verify — the `Ignore` failure policy swallowing a webhook error, a namespace excluded by `resourceFilters` or webhook `namespaceSelector`, a `reinvocationPolicy` interaction, or an **update** to an existing pod that swaps an image without re-triggering verification. In all of these the `kyverno.io/verify-images` annotation is absent or does not cover the image, and the validating phase — driven by `required: true` — rejects the request. `required` is the second lock; setting it to `false` removes the only check that survives a bypassed mutation.

**A5.6** *For:* control-plane and CNI images are pulled before Kyverno itself is running, and a `Fail` policy covering them can deadlock a cluster restart — nothing can start because the verifier cannot start. Kubernetes' own images are also not cosign-signed with a key you hold. *Against:* every entry in `skipImageReferences` is a permanent, unmonitored hole. `registry.k8s.io/*` is broad, and a compromise there or a typo-squatted path inside it bypasses the gate entirely. Mitigate by pinning those images by digest via a separate mutate/validate rule, keeping the skip list short and reviewed, and alerting on changes to it.

### Exercise 6

**A6.1** A list of **attestor sets** is a logical **AND** — every set must be satisfied. Within one set, `entries` combined with `count` is a **threshold**: at least `count` entries must verify. `count: 1` is therefore OR; `count: N` with N entries is AND. When `count` is omitted the default is **all entries** must match.

**A6.2** Cosign appends each signature as an **additional layer with its own annotations inside the same `.sig` artifact**; the tag name is derived from the image digest and never changes, so the tag count stays at one while the manifest grows a layer. Kyverno fetches that artifact, iterates over all layers, and tries each attestor entry against each signature — so `count: 2` is satisfied when two distinct entries each find a layer they can verify.

**A6.3** Two sets express *organisational independence* rather than a numeric threshold. With `count: 2` over four entries, any two of four suffice — including two keys held by the same team. Two sets of one entry each say "the dev-team key **and** the security-team key", which is the actual separation-of-duties requirement. It also documents intent in the YAML and fails with a path (`.attestors[1]...`) that names the responsible party.

**A6.4** (1) Add key B as a **second entry in the same attestor set** and ensure `count: 1` — now A *or* B is accepted; nothing breaks. (2) Roll the CI pipeline over to sign with B, and back-sign the existing image inventory with B (`cosign sign --key B` over every digest still deployed — this is why an image inventory matters). (3) Verify coverage: no running or deployable image lacks a B signature. (4) Remove the A entry from the policy. (5) Revoke/destroy key A and, if it was in a KMS, disable it. The invariant is that at no point is the set of accepted keys empty of the keys currently on your images.

**A6.5** (a) It keeps trust material out of the policy object, which is world-readable to anyone with `get clusterpolicies`, and out of Git. (b) It centralises rotation: updating the `Secret` changes verification everywhere without a policy edit. The RBAC mistake: granting write access to the `kyverno` namespace — or to that specific `Secret` — to anyone outside the platform/security team. Whoever can update `cosign.pub` in that `Secret` can substitute their own key and sign anything, silently, with no change visible in the policy or in Git. Treat it as a trust root: RBAC-restricted, audited, and ideally reconciled from a sealed/external secret store.

**A6.6** `keys` — a fixed public key you control (also `secret:` for a Kubernetes `Secret`, and `kms:` for a URI like `awskms://…`, `gcpkms://…`, `azurekms://…`, `hashivault://…`, which is the right choice when the private key must never leave an HSM). `certificates` — verification against a certificate and chain; required for Notary Project signatures and used for X.509-based cosign signing. `keyless` — Fulcio/OIDC identity-based verification, the right choice for CI-signed images where no key needs custody. `attestor` — a nested attestor set, for composing reusable trust blocks. Additionally `annotations` constrains required signature annotations, and `repository` points verification at a signature repository other than the image's own.

### Exercise 7

**A7.1** The root of trust becomes an **OIDC identity** attested by **Fulcio**, which issues a short-lived (≈10-minute) X.509 signing certificate bound to that identity. Because the certificate expires almost immediately, a verifier at time T cannot check whether the certificate was valid at signing time — so the signature must be accompanied by an entry in a **transparency log (Rekor)** that provides an independent, tamper-evident timestamp proving the signature was made while the certificate was valid. Without the log, keyless verification has no way to distinguish a signature made during the certificate's lifetime from one forged afterwards; that is why the log is structural, not optional. The same log is what makes key/identity misuse *detectable* after the fact.

**A7.2** Weakest to strongest:
- **(a)** `subject: "*"` — anyone with *any* GitHub Actions workflow in *any* repository on GitHub can sign an image your cluster accepts. This is effectively no control.
- **(c)** `subjectRegExp: "https://github.com/my-org/.*"` — unanchored, so any subject *containing* that string matches; see A7.3. Also accepts any workflow, any branch, any repo in the org, including a fork's workflow or a pull-request-triggered build.
- **(b)** a single human's Google identity — a real constraint, but a human account with phishable credentials and no build-integrity guarantee; the human can sign anything from a laptop.
- **(d)** anchored regexp pinning org, a single-segment repo name, a specific workflow file, and a tag ref — signing is possible only from a release workflow on a tagged commit. Strongest of the four.

**A7.3** Because (c) is unanchored, any subject that merely *contains* the substring matches. An attacker who controls the GitHub organisation `evil-my-org-clone` or the repository `attacker/x` can obtain a Fulcio certificate whose subject is, for example,
`https://github.com/attacker/evil/.github/workflows/build.yaml@refs/heads/https://github.com/my-org/anything` — or more simply, since the regexp is unanchored on both ends, any subject with the literal `https://github.com/my-org/` anywhere in it, including a repository path an attacker can create such as `https://github.com/attacker/https://github.com/my-org/x/...`. Variant (d) rejects all of these because `^`/`$` force the whole subject to match and `[^/]+` prevents extra path segments. **Always anchor identity regexps and escape the dots.**

**A7.4** `rekor.ignoreTlog: true` disables the requirement that the signature have a verifiable **transparency-log entry** — relevant to both modes, but only *safe* in key-based mode with `--tlog-upload=false`, and never safe in keyless mode (see A7.1). `ctlog.ignoreSCT: true` disables verification of the **Signed Certificate Timestamp**, the proof that the Fulcio certificate was published to a certificate transparency log — relevant only where a certificate exists, i.e. keyless and `certificates` attestors. Both are escape hatches for private or air-gapped Sigstore deployments; each one silently removes a detection mechanism, so pair them with `roots`/`pubkey` values for your own infrastructure instead wherever possible.

**A7.5** `keyless.roots` (your Fulcio root CA), `keyless.rekor.url` plus `keyless.rekor.pubkey` (your log's public key), and `keyless.ctlog.pubkey` (your CT log's public key). If you set `roots` but omit `ctlog.pubkey`, verification will attempt to validate the SCT against the **public** Sigstore CT log key, which cannot verify a certificate issued by your private Fulcio — you get an SCT verification failure. The (worse) workaround is `ctlog.ignoreSCT: true`; the correct fix is to supply your CT log key.

**A7.6** Every unique image digest not in cache costs at least one Fulcio-chain validation and one Rekor lookup on the admission hot path, inside the API server's webhook timeout. If Rekor is slow or unreachable and `failurePolicy: Fail`, deployments stop cluster-wide — you have made a public internet service a dependency of your control plane. Mitigations: the **image verification cache** (`useCache: true` plus `--imageVerifyCacheEnabled`/`--imageVerifyCacheTTLDuration`), which removes repeat digests from the hot path, and `webhookTimeoutSeconds` tuned against measured registry latency. Structurally, running a **private Rekor/Fulcio** removes the external dependency altogether; `failurePolicy: Ignore` is the availability escape hatch and should be a deliberate, documented decision.

### Exercise 8

**A8.1** *What is signed:* a signature covers the image **digest** only. An attestation covers an **in-toto Statement** — a document with a `subject` (the image digest) and a `predicate` (arbitrary structured claims), which is itself then signed. *Where stored:* signatures at `sha256-<digest>.sig`, attestations at `sha256-<digest>.att`, both siblings of the image in the same repository. *What each answers:* a signature answers "**who** vouches for these exact bytes"; an attestation answers "**what is claimed** about these bytes, and who vouches for that claim" — how it was built, from which source, whether it passed a scan.

**A8.2** The evaluation root for `attestations[].conditions` is the **predicate** contents, so `builder.id` addresses `predicate.builder.id` in the full statement. If the root were the whole in-toto Statement you would write `{{ predicate.builder.id }}`, and you would also be able to reach `{{ _type }}`, `{{ predicateType }}` and `{{ subject[0].digest.sha256 }}`. Kyverno already verifies the statement envelope (type and subject binding) for you, which is why conditions operate on the payload you actually care about.

**A8.3** They are independent, cumulative requirements combined with AND. The top-level `attestors` requires a valid **signature** on the image; `attestations[].attestors` requires the **attestation of that predicate type** to be signed by those attestors. A realistic policy uses both with different trust material: the image must be signed by the release key, *and* the SLSA provenance must be signed by the build system's keyless identity. Omitting the top-level `attestors` means you verify claims about the image without ever requiring the image itself to be signed.

**A8.4** (1) **Build provenance** — `https://slsa.dev/provenance/v0.2` or `https://slsa.dev/provenance/v1` — assert the builder ID, source repository and branch/tag, so an image built on a developer laptop is rejected. (2) **Vulnerability scan results** — `https://cosign.sigstore.dev/attestation/vuln/v1` — assert that a scan was performed recently (compare `metadata.scanFinishedOn` with a freshness window) and that it found no critical findings. (3) **SBOM** — `https://spdx.dev/Document` or CycloneDX — assert the presence of an SBOM and gate on the absence of a banned component or licence. Others worth knowing: SARIF for static analysis, and custom predicate types for internal approvals such as change-management ticket IDs.

**A8.5** You expect **`no matching signatures`** (or an equivalent attestation-signature error) rather than `attestation checks failed`, because Kyverno verifies the attestation's signature *before* it will trust its contents enough to evaluate the JMESPath conditions. The ordering matters because it partitions the problem instantly: a signature-shaped error means your trust material is wrong (key, identity, Rekor requirement) and the conditions were never evaluated; a `conditions`/`attestation checks failed` error means the signature was *valid* and the dispute is about the claim's content — go read the decoded predicate with `cosign verify-attestation | jq` and compare field by field. Debugging the conditions when the real fault is the key wastes the entire incident.

**A8.6** Because provenance is the document that asserts *how the artifact was built*, and SLSA's higher levels depend on that assertion being **non-falsifiable and auditable**. A signature without a log entry can still be checked against a key you control today. Provenance without a log entry cannot be independently corroborated after the fact: if the build key is later found to be compromised, you have no timestamped record distinguishing provenance generated by the real builder from provenance forged afterwards, so you cannot determine which of your deployed images are affected. The transparency log is what makes retroactive incident scoping possible — exactly the scenario provenance exists for.

### Exercise 9

**A9.1** Cosign stores signatures under a **derived tag** (`sha256-<digest>.sig`) — a plain image tag that works on any registry. Notary Project stores the signature as an **OCI artifact with a `subject` descriptor** pointing at the image, discovered through the **OCI Distribution v1.1 referrers API** (`GET /v2/<name>/referrers/<digest>`). On a registry that does not implement referrers, clients fall back to the referrers **tag schema** (`sha256-<digest>`), and if the registry supports neither, `notation sign` or verification fails to find the signature — the classic symptom on older registry versions. Practical difference: cosign works essentially everywhere; Notary needs a modern registry but produces a cleaner, standards-track linkage.

**A9.2** `certificates`, with `cert` (the signing certificate or trust anchor) and optionally `certChain`. Notary signatures are **X.509 certificate-based**, so trust is established by validating the signing certificate against a trust root, not by comparing against a bare public key. `keys.publicKeys` describes a raw key pair with no identity, chain, validity period or revocation semantics, which is not how the Notary trust model works.

**A9.3** In the **`kyverno` namespace** — the namespace of the admission controller that performs the pull. It cannot be the pod's namespace because the tenant owning that namespace could then supply credentials of their choosing, and because Kyverno would need read access to secrets in every namespace, turning the admission controller into a cluster-wide secret reader. The multi-tenancy consequence is deliberate: registry credentials used for verification are **platform-team-owned**, not tenant-owned, so a tenant cannot point verification at a registry they control. It also means the platform team must maintain credentials for every registry any tenant uses.

**A9.4** `providers` uses the cloud **credential keychains** — IAM Roles for Service Accounts on EKS, Workload Identity on GKE, Managed Identity on AKS, and GitHub's token provider — so Kyverno authenticates to ECR/GAR/ACR/GHCR using the pod's own cloud identity, with automatically rotated short-lived tokens and no static secret to leak or rotate. `default` is the standard Docker keychain (config file plus `--imagePullSecrets`). This is strictly better than a static secret wherever it is available.

**A9.5** `allowInsecureRegistry: true` permits plain HTTP and skips TLS certificate verification for the registry connection. It is worse than trusting the registry's CA because it disables authentication of the *server* entirely: anyone able to intercept the connection between the Kyverno pod and the registry can serve fabricated signature artifacts, so verification returns "verified" for images an attacker chose. It defeats the control it appears to support. Use it only for a throwaway lab; in production, mount the registry CA into the Kyverno pod's trust store and leave the flag `false`.

**A9.6** (a) **Already-verified digest:** the cache is keyed on the digest and the verification parameters, so pods created after 14:00 referencing that digest can be admitted from the cache until the entry's TTL elapses — worst case ~60 minutes after the entry was populated, so up to ~59 minutes past your policy change. (Kyverno invalidates cache entries when the policy changes, so in current versions the edit itself should clear them — verify this on your version rather than assuming it, since the whole exposure argument rests on it.) (b) **Never-seen image:** no cache entry exists, so the new policy applies immediately, with zero exposure. The knob is `--imageVerifyCacheTTLDuration` (and `useCache: false` per rule). Shortening it costs registry and Rekor round-trips on the admission hot path — more latency per pod creation, more load on the registry, and a larger blast radius if the registry is slow. During an active key-compromise incident, the correct move is not to tune the TTL but to remove the key from the policy *and* restart the admission controller, which drops the in-memory cache outright.

### Exercise 10

**A10.1** Because `kyverno apply` and `kyverno test` are designed to run offline and hermetically — in a pull-request check with no registry credentials, no network egress and no cluster. Contacting registries by default would make every policy test slow, flaky and dependent on external availability. The CI consequence of forgetting `--registry`: image verification rules cannot fetch signatures, so they are skipped or error rather than genuinely evaluated, and a test suite that looks green proves nothing about your `verifyImages` rules. Assert on the summary counts, not just the exit code.

**A10.2**
| # | Fault | Message | Root cause | Next command |
|---|---|---|---|---|
| a | wrong public key | `.attestors[0].entries[0].keys: no matching signatures` | signature artifact exists but no layer verifies against this key | `cosign verify --key <policy key> --insecure-ignore-tlog $IMG` — reproduces the exact check outside Kyverno |
| b | `rekor` block deleted | signature verification fails citing the transparency log / no valid tlog entry | Kyverno now demands a Rekor entry the image never got (`--tlog-upload=false`) | `cosign verify --key cosign.pub $IMG` *without* `--insecure-ignore-tlog` — same failure, confirming it is the log requirement, not the key |
| c | `imageReferences: ["kca-*"]` | **no message at all**; the resource is neither pass nor fail | the pattern does not match the fully-qualified `ttl.sh/kca-…` reference, so the rule never applies | `kyverno apply … --registry` and read the counts; then `kubectl -n kyverno get cm kyverno -o yaml \| yq .data.defaultRegistry` to confirm normalisation |

**A10.3** The summary read `pass: 0, fail: 0, warn: 0, error: 0, skip: 2` (or reported the rule as skipped) — a **silently inert policy**. This is worse than a loud failure because every dashboard, report and exit code says "clean": the policy exists, it is `Ready`, `kubectl get cpol` shows `Enforce`, and auditors will accept it — while unsigned images flow into the cluster unchallenged. A loud failure gets fixed within the hour; an inert policy survives for months. The assertion that catches it is a **positive** expectation in `kyverno-test.yaml`: assert `result: pass` for a known-good resource and `result: fail` for a known-bad one. If the rule stops matching, the `pass` expectation fails too, so the test breaks in both directions. Never write a policy test that only asserts failures.

**A10.4** Without `imageExtractors`, Kyverno only knows how to find images in well-known Kubernetes pod specs (`containers`, `initContainers`, `ephemeralContainers`). A Tekton `Task` keeps its images at `/spec/steps/*/image`, which Kyverno cannot discover, so the rule would find **zero images** and admit everything — the inert-policy failure mode from A10.3, now on your CI system's own definitions. With the extractor declared, `mutateDigest: true` rewrites each `spec.steps[*].image` in the `Task` to its verified digest, exactly as it would rewrite a container image in a pod.

**A10.5** (1) Confirm it is Kyverno and not the API server generally: `kubectl -n kyverno get pods` and `kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200`, looking for registry/Rekor timeouts. (2) Confirm reachability from Kyverno's network position, not yours: `kubectl -n kyverno exec deploy/kyverno-admission-controller -- <probe>` or a debug pod in that namespace against the registry and `rekor.sigstore.dev`; check for a new `NetworkPolicy`, DNS failure or proxy change. (3) Check the registry/Rekor side — provider status, rate limiting (`429`), expired credentials in the pull secret. (4) Check load and resources: admission review duration in the metrics endpoint, CPU throttling, and whether the cache was recently invalidated by a policy edit (a cold cache after a policy change turns every pod into a registry round-trip and is a very common trigger for exactly this symptom). **Immediate mitigation without deleting the policy:** flip `spec.failurePolicy` to `Ignore` — the gate stops blocking on webhook errors while remaining in force for requests it can actually evaluate. Raising `webhookTimeoutSeconds` toward the 30-second ceiling helps only if the registry is slow rather than unreachable, and it makes every admission slower. Switching the rule to `Audit` is the next step down if `Ignore` is not enough. Record the fail-open window; it is a security event, not just an outage.

**A10.6** Bypasses available to an operator with cluster access: **(1)** editing or deleting the `ClusterPolicy`; **(2)** deleting or editing Kyverno's webhook configurations, or adding a `namespaceSelector`/`objectSelector` exclusion; **(3)** adding their namespace to `resourceFilters` in the `kyverno` ConfigMap; **(4)** scaling the admission controller to zero while `failurePolicy: Ignore` is set — the gate silently disappears; **(5)** creating a resource whose images live in a field no extractor covers; **(6)** updating an existing, already-verified workload to swap in a different image; **(7)** submitting a resource that carries a hand-written `kyverno.io/verify-images` annotation. **`required: true` closes (6) and (7)**: it is evaluated in the validating phase, so an update whose images have no passing verification result is rejected, and a client-supplied annotation does not survive because Kyverno recomputes verification state during the mutating phase rather than trusting the request. It closes nothing else — (1) through (4) are **RBAC** problems (nobody outside the platform team should hold write access to `clusterpolicies`, `*webhookconfigurations`, the `kyverno` namespace, or its ConfigMap), and (5) is a **coverage** problem solved by `imageExtractors` plus a catch-all rule. A signature policy is only as strong as the RBAC protecting it.

</details>

---

## References

- Kyverno — *Verify Images* policy documentation: <https://kyverno.io/docs/writing-policies/verify-images/>
- Kyverno — policy library (image verification samples): <https://kyverno.io/policies/>
- Kyverno — source and API types: <https://github.com/kyverno/kyverno>
- Kyverno — CLI (`apply`, `test`): <https://kyverno.io/docs/kyverno-cli/>
- Sigstore — cosign: <https://github.com/sigstore/cosign> · docs: <https://docs.sigstore.dev/>
- Notary Project: <https://notaryproject.dev/docs/>
- in-toto Attestation specification: <https://github.com/in-toto/attestation>
- SLSA provenance predicate: <https://slsa.dev/spec/v1.0/provenance>
- OCI Distribution Specification (referrers API): <https://github.com/opencontainers/distribution-spec>
- Kubernetes — dynamic admission control (`failurePolicy`, `timeoutSeconds`): <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- CNCF — KCA curriculum: <https://github.com/cncf/curriculum>