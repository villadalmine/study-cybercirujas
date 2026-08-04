# CKS 4.3 — Secure your supply chain

**Certification:** Certified Kubernetes Security Specialist (CKS), curriculum v1.34
**Domain:** Supply Chain Security (20 %) · **Sub-topic weight:** 5
**Scope:** permitted registries, image provenance, signing and validating artifacts (signatures, attestations, SBOMs), admission-time enforcement, node-level (containerd) enforcement.

---

## 1. The architectural problem

### 1.1 The trust gap

A Kubernetes `Pod` spec contains a string:

```yaml
containers:
- name: api
  image: acme/api:v2.7.1
```

That string is a **name resolution request**, not a proof of anything. Between the source commit and the process running under a kubelet, control passes through at least seven trust boundaries:

```
   developer          CI runner            registry            cluster
   ─────────          ─────────            ────────            ───────
   git commit ──► build (Dockerfile) ──► push manifest ──► kube-apiserver
        │              │                      │                 │  admission
        │              │                      │                 ▼
        │              │                      │            scheduler
        │              │                      │                 │
        ▼              ▼                      ▼                 ▼
   [1] identity   [2] build env         [3] registry      [4] kubelet
       of author       + dependencies       mutability        image pull
                       (base image,         (tag → digest)         │
                        packages)                                  ▼
                                                            [5] containerd
                                                                resolve + unpack
```

Each boundary has a documented, exploited failure mode:

| # | Boundary | Attack | Real-world precedent |
|---|---|---|---|
| 1 | Author identity | Stolen maintainer credentials, malicious co-maintainer | `xz-utils`/CVE-2024-3094 (2024) |
| 2 | Build environment | Compromised CI injects payload at build time; source stays clean | SolarWinds Orion (2020), Codecov bash uploader (2021) |
| 3 | Registry / naming | Typosquatting, dependency confusion, tag re-push, registry account takeover | `docker.io/*` cryptominer campaigns; namespace confusion (Birsan, 2021) |
| 4 | Pull path | MITM on a plaintext mirror, DNS hijack of a registry hostname | Misconfigured `insecure-registries` |
| 5 | Node cache | Pre-seeded malicious layer with a legitimate tag on a compromised node | `imagePullPolicy: IfNotPresent` on multi-tenant nodes |

**A tag is not an identity.** `acme/api:v2.7.1` is a mutable pointer in someone else's database. The only immutable identifier in OCI is the manifest digest — `sha256:…` — because it is the content address of the manifest, which in turn content-addresses the config blob and every layer.

### 1.2 What "securing the supply chain" means at admission time

You cannot verify a build from inside a cluster. What you *can* do is refuse to run anything whose provenance you cannot check, and reduce the set of things you are willing to check. That decomposes into exactly three enforceable questions, in order:

1. **Where did this come from?** → *permitted registries* (allowlist by registry host / repository path).
2. **Is it exactly what was published?** → *digest pinning* (reject mutable tags, or resolve tag → digest at admission and pin it).
3. **Who vouches for it, and what do they claim?** → *signature and attestation verification* (cosign/Sigstore, SLSA provenance, SBOM).

Question 1 is cheap, offline, and stops 80 % of accidental exposure. Question 3 is the only one that survives a registry compromise. **The registry allowlist without signature verification is a perimeter; the signature verification without an allowlist is unbounded work.** Production clusters need both, in that order, because signature policies are per-image-glob and a glob only means something if the namespace of possible images is closed.

### 1.3 Where enforcement can live

```
kubectl create -f pod.yaml
        │
        ▼
  ┌──────────────────────── kube-apiserver ────────────────────────┐
  │ authn ─► authz ─► MUTATING admission ─► object schema ─►       │
  │                    │                    VALIDATING admission   │
  │                    │                     │                     │
  │                    │  Kyverno mutate     │  ValidatingAdmissionPolicy (CEL, in-process)
  │                    │  (resolve digest)   │  ImagePolicyWebhook (in-tree plugin)
  │                    │                     │  Gatekeeper / Kyverno validate (webhook)
  │                    │                     │  policy-controller (webhook)
  │                    └─────────────────────┴──► etcd
  └────────────────────────────────────────────────────────────────┘
        │
        ▼  (scheduler binds)
  ┌─────────── kubelet ───────────┐
  │ imagePullPolicy               │
  │ imagePullSecrets              │
  │ CRI ImagePull ────────────────┼──► containerd
  └───────────────────────────────┘        │  /etc/containerd/certs.d/*/hosts.toml
                                           │  registry mirrors, capabilities, TLS pinning
                                           ▼
                                        registry
```

Two independent layers, and you want both:

* **Admission** is authoritative for policy and produces good error messages, but it only sees the *string*. If a node is compromised or a registry hostname is hijacked, admission has already said yes.
* **containerd** is authoritative for what bytes actually arrive, but it has no notion of namespace, tenant, or workload. It cannot say "team-a may pull from repo X".

---

## 2. Comparative analysis of enforcement mechanisms

### 2.1 Permitted-registry enforcement

| Mechanism | Where it runs | Signature capable | Network calls | Latency | Survives webhook outage | Ops cost | CKS-exam relevant |
|---|---|---|---|---|---|---|---|
| **ValidatingAdmissionPolicy** (CEL) | In-process, kube-apiserver | ❌ (CEL cannot do crypto or egress) | none | ~µs | N/A — cannot be down | Very low (no components) | High (GA since 1.30) |
| **ImagePolicyWebhook** (in-tree plugin) | apiserver → external HTTPS backend | ✅ if backend does it | yes, per pod | 1–50 ms + backoff | `defaultAllow` decides | High: static-pod flags, certs, no cluster DNS | **Very high** — classic CKS task |
| **OPA Gatekeeper** | Webhook (Rego) | ⚠️ only via external data / providers | webhook hop | 5–30 ms | `failurePolicy` | Medium; Rego skillset | Medium |
| **Kyverno** | Webhook (YAML/JMESPath/CEL) | ✅ native `verifyImages` | webhook + registry | 20 ms–2 s (registry round-trip) | `failurePolicy` | Medium | Medium |
| **sigstore policy-controller** | Webhook | ✅ purpose-built | webhook + Fulcio/Rekor | 50 ms–2 s | `failurePolicy` | Medium | Low, but production-standard |
| **containerd `hosts.toml`** | Node | ❌ | pull-time only | 0 | Always on | Per-node config mgmt | Medium |
| **NetworkPolicy / egress firewall** | Node/CNI | ❌ | n/a | 0 | Always on | Low | Medium |

**Selection heuristic:**

* Registry allowlist only, no external dependency wanted → **ValidatingAdmissionPolicy**. It is the cheapest correct answer in ≥1.30 and it cannot fail open because it cannot fail.
* Exam scenario mentioning `--admission-control-config-file` or `AdmissionConfiguration` → **ImagePolicyWebhook**. Nothing else uses that file.
* Signature/attestation verification → **Kyverno** or **policy-controller**. VAP cannot do it: CEL has no crypto primitives and no egress by design.

### 2.2 Signing models (Sigstore/cosign)

| Model | Key material | Identity anchor | Revocation | Rotation | Airgap | Best fit |
|---|---|---|---|---|---|---|
| **Keyed** (`cosign.key`) | Long-lived ECDSA P-256 keypair | The key itself | Rotate + re-sign; no CRL | Manual, painful | ✅ works fully offline | Small teams, airgapped, regulated |
| **KMS-backed** (`awskms://`, `gcpkms://`, `hashivault://`, PKCS#11) | Private key never leaves HSM/KMS | IAM identity on the KMS key | Disable KMS key | KMS key versions | ⚠️ needs KMS reachable | Enterprise default |
| **Keyless** (Fulcio + Rekor) | Ephemeral key, 10-minute X.509 cert bound to an OIDC identity | OIDC subject + issuer (e.g. a GitHub Actions workflow ref) | Not needed — cert already expired; trust is pinned to identity | N/A (nothing to rotate) | ❌ needs Fulcio/Rekor (or a private Sigstore) | CI-driven public/SaaS pipelines |

Keyless is not "no key" — it is *"the key existed for 10 minutes, was bound to a verified OIDC identity by Fulcio, and the binding is in a tamper-evident transparency log (Rekor)"*. Verification checks the certificate chain **and** the Rekor inclusion proof, then asserts the certificate's SAN matches an identity you allow. The critical consequence: **`cosign verify` without `--certificate-identity` is meaningless** — anyone with a Google account can produce a valid keyless signature.

### 2.3 Tag vs digest

| Property | `acme/api:v2.7.1` | `acme/api@sha256:9f2a…` |
|---|---|---|
| Immutable | ❌ (registry can re-point) | ✅ (content-addressed) |
| Survives registry compromise | ❌ | ✅ (bytes fail digest check on pull) |
| Signature binds to it | ❌ (cosign signs the digest; tag is a lookup) | ✅ |
| Human-readable / GitOps-friendly | ✅ | ❌ (needs automation: Renovate, Flux image automation, Kyverno `mutateDigest`) |
| Node cache poisoning (`IfNotPresent`) | ❌ vulnerable | ✅ digest mismatch aborts |

**Production position:** developers write tags; a mutating admission step (Kyverno `mutateDigest: true`) or the CI/CD promotion pipeline rewrites them to digests before the object is persisted. Enforcing "digest-only" on humans without a mutation step is a ticket generator.

---

## 3. Permitted registries — full implementations

Target policy for all examples:

> Every container, initContainer and ephemeralContainer image must come from `registry.internal.acme.io/` or `registry.k8s.io/`. `kube-system` is exempt. Denials must name the offending image.

### 3.1 ValidatingAdmissionPolicy (recommended baseline, K8s ≥ 1.30)

```yaml
# vap-allowed-registries.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries.acme.io
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
  # Normalise: a bare Pod exposes .spec, workloads expose .spec.template.spec,
  # CronJob exposes .spec.jobTemplate.spec.template.spec.
  - name: podSpec
    expression: >-
      has(object.spec.template) ? object.spec.template.spec :
      (has(object.spec.jobTemplate) ? object.spec.jobTemplate.spec.template.spec :
       object.spec)
  - name: allImages
    expression: >-
      variables.podSpec.containers.map(c, c.image) +
      (has(variables.podSpec.initContainers) ?
        variables.podSpec.initContainers.map(c, c.image) : []) +
      (has(variables.podSpec.ephemeralContainers) ?
        variables.podSpec.ephemeralContainers.map(c, c.image) : [])
  - name: allowedPrefixes
    expression: >-
      ['registry.internal.acme.io/', 'registry.k8s.io/']
  - name: badImages
    expression: >-
      variables.allImages.filter(i,
        !variables.allowedPrefixes.exists(p, i.startsWith(p)))
  validations:
  - expression: "size(variables.badImages) == 0"
    messageExpression: >-
      'image(s) from a non-permitted registry: ' + variables.badImages.join(', ') +
      '. Permitted prefixes: ' + variables.allowedPrefixes.join(', ')
    reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries.acme.io
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-node-lease"]
```

Notes that matter in production:

* **Matching the workload controllers as well as `pods` is not redundant** — it is the difference between a developer getting an immediate error on `kubectl apply -f deployment.yaml` and a silently `0/3 READY` Deployment whose real error is buried in `kubectl describe replicaset`.
* `has()` guards are mandatory: `initContainers` and `ephemeralContainers` have `omitempty` semantics, so `object.spec.initContainers` on a Pod without them raises `no such key` and — with `failurePolicy: Fail` — denies every Pod in the cluster.
* Start with `validationActions: ["Audit", "Warn"]`, read the audit log, then flip to `Deny`.

Deployment and verification:

```console
$ kubectl apply -f vap-allowed-registries.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/allowed-registries.acme.io created
validatingadmissionpolicybinding.admissionregistration.k8s.io/allowed-registries-binding created

$ kubectl get validatingadmissionpolicy allowed-registries.acme.io
NAME                         VALIDATIONS   PARAMKIND   AGE
allowed-registries.acme.io   1             <unset>     12s

$ kubectl run rogue --image=docker.io/library/nginx:1.27 -n default
Error from server (Forbidden): pods "rogue" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: docker.io/library/nginx:1.27. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/

$ kubectl run ok --image=registry.internal.acme.io/library/nginx:1.27 -n default
pod/ok created
```

Test a Deployment path without creating anything:

```console
$ kubectl create deployment bad --image=quay.io/prometheus/node-exporter:v1.8.2 \
    --dry-run=server -o yaml
error: failed to create deployment: admission webhook denied the request: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: quay.io/prometheus/node-exporter:v1.8.2. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/
```

### 3.2 ImagePolicyWebhook (in-tree admission plugin)

This is the mechanism the CKS curriculum explicitly points at, and the only one configured through `--admission-control-config-file`. It is also the most fragile, so understand each file.

**Step 1 — AdmissionConfiguration on the control-plane node**

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
      retryBackoff: 500     # MILLISECONDS between retries
      defaultAllow: false   # fail CLOSED — the only correct production value
```

> `defaultAllow: true` means "if my policy engine is unreachable, admit anything." That is a security control that disables itself precisely when something is wrong. Exam tasks almost always want `false`.

**Step 2 — kubeconfig the apiserver uses to reach the backend**

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
- name: image-policy-backend
  cluster:
    certificate-authority: /etc/kubernetes/admission/webhook-ca.crt
    server: https://10.96.71.14:443/image_policy     # ClusterIP or host endpoint, NOT a *.svc name
users:
- name: kube-apiserver
  user:
    client-certificate: /etc/kubernetes/admission/apiserver-client.crt
    client-key: /etc/kubernetes/admission/apiserver-client.key
contexts:
- name: image-policy
  context:
    cluster: image-policy-backend
    user: kube-apiserver
current-context: image-policy
```

**Critical production gotcha:** unlike `ValidatingWebhookConfiguration` (which supports a `service:` reference resolved internally by the apiserver), `ImagePolicyWebhook` takes a raw URL from a kubeconfig. The kube-apiserver runs on the host network and does **not** use cluster DNS, so `https://image-policy.image-policy.svc:443` will not resolve. Use the Service ClusterIP, a node-local endpoint, or run the backend as a systemd service / static pod on the control-plane node.

**Step 3 — wire it into the static Pod manifest**

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml   (excerpt — edit in place)
spec:
  containers:
  - command:
    - kube-apiserver
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
    # ... existing flags unchanged ...
    volumeMounts:
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
  volumes:
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

Forgetting the `volumeMounts`/`volumes` pair is the single most common failure: the apiserver container cannot see the file and crash-loops with `open /etc/kubernetes/admission/admission-config.yaml: no such file or directory`.

**Step 4 — the backend contract (`imagepolicy.k8s.io/v1alpha1`)**

Request the apiserver POSTs:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [
      { "image": "docker.io/library/nginx:1.27" },
      { "image": "registry.internal.acme.io/tools/busybox@sha256:9ae97d3…" }
    ],
    "annotations": {
      "policy.image-policy.k8s.io/ticket-1234": "break-glass"
    },
    "namespace": "team-a"
  }
}
```

Only annotations matching `*.image-policy.k8s.io/*` are forwarded — everything else is stripped, so a tenant cannot smuggle hints to the backend through arbitrary labels.

Expected response:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": {
    "allowed": false,
    "reason": "image docker.io/library/nginx:1.27 is not from a permitted registry"
  }
}
```

A minimal reference backend, deployable as a Deployment + Service (TLS terminated by the container, client cert verified against the apiserver CA):

```yaml
# imagepolicy-backend.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: image-policy
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: imagepolicy-code
  namespace: image-policy
data:
  server.py: |
    import json, ssl
    from http.server import BaseHTTPRequestHandler, HTTPServer

    ALLOWED_PREFIXES = ("registry.internal.acme.io/", "registry.k8s.io/")
    REQUIRE_DIGEST = True

    def evaluate(images):
        for image in images:
            if not image.startswith(ALLOWED_PREFIXES):
                return False, f"image {image} is not from a permitted registry"
            if REQUIRE_DIGEST and "@sha256:" not in image:
                return False, f"image {image} must be pinned to a digest"
        return True, ""

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            review = json.loads(self.rfile.read(length) or b"{}")
            images = [c.get("image", "") for c in review.get("spec", {}).get("containers", [])]
            allowed, reason = evaluate(images)
            body = json.dumps({
                "apiVersion": "imagepolicy.k8s.io/v1alpha1",
                "kind": "ImageReview",
                "status": {"allowed": allowed, "reason": reason},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            print("image-policy %s" % (fmt % args), flush=True)

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/tls/tls.crt", "/tls/tls.key")
    context.load_verify_locations("/tls/client-ca.crt")
    context.verify_mode = ssl.CERT_REQUIRED

    server = HTTPServer(("0.0.0.0", 8443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("image-policy backend listening on :8443", flush=True)
    server.serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-policy
  namespace: image-policy
spec:
  replicas: 2
  selector:
    matchLabels: { app: image-policy }
  template:
    metadata:
      labels: { app: image-policy }
    spec:
      # The backend must be schedulable even when the cluster is unhealthy.
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: { app: image-policy }
      containers:
      - name: server
        image: registry.internal.acme.io/library/python:3.12-slim
        command: ["python3", "/code/server.py"]
        ports:
        - containerPort: 8443
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 10001
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits:   { memory: 128Mi }
        volumeMounts:
        - { name: code, mountPath: /code, readOnly: true }
        - { name: tls,  mountPath: /tls,  readOnly: true }
      volumes:
      - name: code
        configMap: { name: imagepolicy-code }
      - name: tls
        secret: { secretName: image-policy-tls }   # tls.crt, tls.key, client-ca.crt
---
apiVersion: v1
kind: Service
metadata:
  name: image-policy
  namespace: image-policy
spec:
  clusterIP: 10.96.71.14        # pin it: the apiserver kubeconfig hardcodes this address
  selector: { app: image-policy }
  ports:
  - port: 443
    targetPort: 8443
```

Apply, then restart the apiserver by touching the static Pod manifest:

```console
$ sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f imagepolicy-backend.yaml
namespace/image-policy created
configmap/imagepolicy-code created
deployment.apps/image-policy created
service/image-policy created

$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml     # add the two flags + volume
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             POD ID
0c31f9a7c1b2e  0f4b02c4e6d1a  9 seconds ago   Running   kube-apiserver   4a1e0b9c7d3f2

$ kubectl run rogue --image=docker.io/library/alpine:3.20 --restart=Never -- sleep 3600
Error from server (Forbidden): pods "rogue" is forbidden: image policy webhook backend denied one or more images: image docker.io/library/alpine:3.20 is not from a permitted registry
```

### 3.3 Kyverno equivalent (with digest mutation)

```yaml
# kyverno-registry-and-digest.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: registry-allowlist
  annotations:
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce   # Kyverno >=1.12: prefer per-rule validate.failureAction
  background: true
  failurePolicy: Fail
  rules:
  - name: only-permitted-registries
    match:
      any:
      - resources:
          kinds: ["Pod"]
    exclude:
      any:
      - resources:
          namespaces: ["kube-system", "kyverno"]
    validate:
      message: >-
        Images must come from registry.internal.acme.io or registry.k8s.io.
        Found: {{ request.object.spec.containers[].image | join(', ', @) }}
      pattern:
        spec:
          =(ephemeralContainers):
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
          =(initContainers):
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
          containers:
          - image: "registry.internal.acme.io/* | registry.k8s.io/*"
```

The `=( )` prefix is Kyverno's *conditional anchor*: "if this key exists, it must match." Without it, a Pod with no `initContainers` fails the pattern.

---

## 4. Node-level enforcement: containerd

Admission policy is bypassed by anything that talks to the CRI socket directly (a compromised node, a DaemonSet with a mounted socket, `crictl`). Close the registry set at the node too.

**containerd 1.7 (`/etc/containerd/config.toml`)**

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

**containerd 2.x** — the CRI plugin was split; the image half owns registry config:

```toml
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

Then, per-host files. Redirect Docker Hub to the internal pull-through mirror and *remove* the upstream fallback:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry.internal.acme.io"

[host."https://registry.internal.acme.io/v2/dockerhub-remote"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "/etc/containerd/certs.d/acme-root-ca.crt"
```

Because no `[host]` entry points at `registry-1.docker.io`, containerd never contacts Docker Hub — even if admission is bypassed.

Pin the internal registry's CA and forbid plaintext:

```toml
# /etc/containerd/certs.d/registry.internal.acme.io/hosts.toml
server = "https://registry.internal.acme.io"

[host."https://registry.internal.acme.io"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/acme-root-ca.crt"
  skip_verify = false
```

```console
$ sudo systemctl restart containerd
$ sudo crictl pull docker.io/library/alpine:3.20
FATA[0002] pulling image: failed to pull and unpack image "docker.io/library/alpine:3.20": failed to resolve reference "docker.io/library/alpine:3.20": failed to do request: Head "https://registry.internal.acme.io/v2/dockerhub-remote/library/alpine/manifests/3.20": x509: certificate signed by unknown authority

$ sudo crictl pull registry.internal.acme.io/library/alpine:3.20
Image is up to date for sha256:beefc9f9a5a3f52c2b0c9b0f4d31d9c5b78e3f8a2d1e6c4b9a0f7e2d3c1b5a48
```

### 4.1 `AlwaysPullImages` — the multi-tenancy corollary

With `imagePullPolicy: IfNotPresent`, any Pod on a node can run a *private* image that some other tenant already pulled to that node, with no credentials. On shared clusters, enable the in-tree plugin so the kubelet re-authenticates every pull:

```yaml
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ImagePolicyWebhook
```

Trade-off: every Pod start does a registry round-trip (a manifest HEAD if layers are cached). On a 500-node cluster restarting after an outage this is a thundering herd against the registry — size the pull-through cache accordingly, or scope the behaviour with a Kyverno mutation limited to multi-tenant namespaces.

---

## 5. Signing and validating artifacts

### 5.1 What cosign actually writes to the registry

Signing `registry.internal.acme.io/team-a/api@sha256:9f2a…` does not modify the image. cosign pushes a *second* OCI artifact:

* **Tag convention (OCI 1.0, default):** a new tag `sha256-9f2a….sig` in the *same repository*, whose layers are the signature payloads and whose annotations hold the signature (`dev.cosignproject.cosign/signature`) and, for keyless, the Fulcio certificate chain and the Rekor SET bundle.
* **Referrers API (OCI 1.1):** `cosign sign --registry-referrers-mode oci-1-1 …` attaches the signature as a referrer with `subject` pointing at the image digest. Requires registry support (`GET /v2/<name>/referrers/<digest>`).

Consequences you will hit in production:

1. **Copying an image between registries with `docker pull`/`docker push` silently drops the signature.** Use `crane copy`/`skopeo copy --all` on the repository, or `cosign copy`.
2. Repository-level retention/GC policies that delete "untagged or oddly-tagged" artifacts will delete your signatures.
3. Verification requires **pull** access to the same repository — signature discovery is a registry read, not a Rekor read.

### 5.2 Keyed signing — full transcript

```console
$ cosign version
  ______   ______        _______. __    _______ .__   __.
 /      | /  __  \      /       ||  |  /  _____||  \ |  |
|  ,----'|  |  |  |    |   (----`|  | |  |  __  |   \|  |
|  |     |  |  |  |     \   \    |  | |  | |_ | |  . `  |
|  `----.|  `--'  | .----)   |   |  | |  |__| | |  |\   |
 \______| \______/  |_______/    |__|  \______| |__| \__|
cosign: A tool for Container Signing, Verification and Storage in an OCI registry.

GitVersion:    v2.4.1
GitCommit:     8b1a2fd05a0b1b3b4a92f1f8fcb0f2e7f4c9c3a1
GoVersion:     go1.23.2
Platform:      linux/amd64

$ export COSIGN_PASSWORD='<from vault>'
$ cosign generate-key-pair
Private key written to cosign.key
Public key written to cosign.pub

$ IMAGE=registry.internal.acme.io/team-a/api
$ DIGEST=$(crane digest ${IMAGE}:v2.7.1)
$ echo $DIGEST
sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ cosign sign --key cosign.key ${IMAGE}@${DIGEST}
Pushing signature to: registry.internal.acme.io/team-a/api

$ cosign tree ${IMAGE}@${DIGEST}
📦 Supply Chain Security Related artifacts for an image: registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47
└── 🔐 Signatures for an image tag: registry.internal.acme.io/team-a/api:sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.sig
   └── 🍒 sha256:5c1d0b7e3a92f846d5b0c7e2a1f39d84b6c0e5a273f1d8b4c9e0a6f2d3b7c518

$ cosign verify --key cosign.pub ${IMAGE}@${DIGEST} | jq '.[0].optional, .[0].critical'
Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
{
  "Subject": "",
  "Issuer": ""
}
{
  "identity": {
    "docker-reference": "registry.internal.acme.io/team-a/api"
  },
  "image": {
    "docker-manifest-digest": "sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47"
  },
  "type": "cosign container image signature"
}
```

KMS variant — the private key never exists on disk:

```console
$ cosign sign --key awskms:///arn:aws:kms:eu-west-1:111122223333:key/8f0c-…-a91b ${IMAGE}@${DIGEST}
$ cosign public-key --key awskms:///arn:aws:kms:eu-west-1:111122223333:key/8f0c-…-a91b > kms.pub
```

### 5.3 Keyless signing (Fulcio + Rekor)

```console
$ cosign sign ${IMAGE}@${DIGEST}
Generating ephemeral keys...
Retrieving signed certificate...

        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.

By typing 'y', you attest that you grant (or have permission to grant) and agree to have this information stored permanently in transparency logs.
Are you sure you would like to continue? [y/N] y
Your browser will now be opened to:
https://oauth2.sigstore.dev/auth/auth?access_type=online&client_id=sigstore&…
Successfully verified SCT...
tlog entry created with index: 148920371
Pushing signature to: registry.internal.acme.io/team-a/api
```

Verification **must** pin the identity:

```console
$ cosign verify \
    --certificate-identity 'https://github.com/acme/platform/.github/workflows/release.yaml@refs/heads/main' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    ${IMAGE}@${DIGEST}

Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

The corresponding CI job (GitHub Actions, no long-lived secret anywhere):

```yaml
# .github/workflows/release.yaml
name: release
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write          # REQUIRED: mints the OIDC token Fulcio exchanges for a cert

jobs:
  build-sign-attest:
    runs-on: ubuntu-24.04
    steps:
    - uses: actions/checkout@v4

    - uses: sigstore/cosign-installer@v3
      with:
        cosign-release: 'v2.4.1'

    - name: Log in to registry
      uses: docker/login-action@v3
      with:
        registry: registry.internal.acme.io
        username: ${{ secrets.REGISTRY_USER }}
        password: ${{ secrets.REGISTRY_TOKEN }}

    - name: Build and push
      id: build
      uses: docker/build-push-action@v6
      with:
        context: .
        push: true
        tags: registry.internal.acme.io/team-a/api:${{ github.sha }}
        provenance: mode=max
        sbom: true

    - name: Sign the image (keyless)
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        cosign sign --yes "registry.internal.acme.io/team-a/api@${DIGEST}"

    - name: Generate and attach an SBOM attestation
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        syft "registry.internal.acme.io/team-a/api@${DIGEST}" \
          -o spdx-json > sbom.spdx.json
        cosign attest --yes \
          --predicate sbom.spdx.json \
          --type spdxjson \
          "registry.internal.acme.io/team-a/api@${DIGEST}"

    - name: Attach a vulnerability-scan attestation
      env:
        DIGEST: ${{ steps.build.outputs.digest }}
      run: |
        trivy image --format cosign-vuln \
          --output vuln.json "registry.internal.acme.io/team-a/api@${DIGEST}"
        cosign attest --yes \
          --predicate vuln.json \
          --type vuln \
          "registry.internal.acme.io/team-a/api@${DIGEST}"
```

### 5.4 Attestations — signing *claims*, not just bytes

A signature says "I saw this digest." An **attestation** is an in-toto statement — a signed, typed claim *about* that digest.

```console
$ cosign verify-attestation --key cosign.pub --type spdxjson ${IMAGE}@${DIGEST} \
    | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject}'
{
  "_type": "https://in-toto.io/Statement/v1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "registry.internal.acme.io/team-a/api",
      "digest": {
        "sha256": "9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47"
      }
    }
  ]
}
```

Enforce a *property* of the provenance, not just its presence:

```rego
# policy/provenance.rego  — cosign evaluates data.signature.allow
package signature

default allow = false

allow {
  input.predicateType == "https://slsa.dev/provenance/v1"
  input.predicate.buildDefinition.buildType == "https://actions.github.io/buildtypes/workflow/v1"
  startswith(input.predicate.buildDefinition.externalParameters.workflow.repository,
             "https://github.com/acme/")
  input.predicate.runDetails.builder.id == "https://github.com/actions/runner/github-hosted"
}
```

```console
$ cosign verify-attestation \
    --certificate-identity-regexp 'https://github.com/acme/.*' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    --type slsaprovenance1 \
    --policy policy/provenance.rego \
    ${IMAGE}@${DIGEST}
will use provided policy policy/provenance.rego
policy checked
Verification for registry.internal.acme.io/team-a/api@sha256:9f2a4c3d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

### 5.5 Cluster-side verification — Kyverno

```yaml
# kyverno-verify-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false            # verifyImages requires registry access; not a background check
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
  # ---- Internal images: keyed signature, key held in the cluster ----------
  - name: verify-internal-keyed
    match:
      any:
      - resources:
          kinds: ["Pod"]
    exclude:
      any:
      - resources:
          namespaces: ["kube-system", "kyverno"]
    verifyImages:
    - imageReferences:
      - "registry.internal.acme.io/*"
      required: true
      verifyDigest: true       # fail if the tag cannot be resolved to a signed digest
      mutateDigest: true       # rewrite tag -> digest in the admitted object
      imageRegistryCredentials:
        secrets: ["regcred"]
      attestors:
      - count: 1
        entries:
        - keys:
            publicKeys: |-
              -----BEGIN PUBLIC KEY-----
              MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
              8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
              -----END PUBLIC KEY-----
            signatureAlgorithm: sha256
            ctlog:
              ignoreSCT: true          # private PKI: no Certificate Transparency SCT to check
            rekor:
              ignoreTlog: true         # keyed + airgapped: no transparency log entry expected

  # ---- Vendor images: keyless, pinned to the vendor's CI identity ---------
  - name: verify-vendor-keyless
    match:
      any:
      - resources:
          kinds: ["Pod"]
    verifyImages:
    - imageReferences:
      - "ghcr.io/acme-vendor/*"
      required: true
      mutateDigest: true
      attestors:
      - count: 1
        entries:
        - keyless:
            subject: "https://github.com/acme-vendor/*/.github/workflows/release.yaml@refs/tags/*"
            issuer: "https://token.actions.githubusercontent.com"
            rekor:
              url: https://rekor.sigstore.dev

  # ---- Require a recent, clean vulnerability attestation ------------------
  - name: require-vuln-attestation
    match:
      any:
      - resources:
          kinds: ["Pod"]
    verifyImages:
    - imageReferences:
      - "registry.internal.acme.io/*"
      required: true
      attestations:
      - type: https://cosign.sigstore.dev/attestation/vuln/v1
        attestors:
        - count: 1
          entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
                8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
                -----END PUBLIC KEY-----
        conditions:
        - all:
          - key: "{{ metadata.scanFinishedOn }}"
            operator: GreaterThanOrEquals
            value: "{{ time_before_now('720h') }}"     # scanned within 30 days
          - key: "{{ scanner.result.summary.critical || `0` }}"
            operator: Equals
            value: 0
```

> Kyverno ≥ 1.12 deprecates `spec.validationFailureAction` in favour of per-rule `failureAction`; both are accepted through the 1.1x line. Check `kubectl get clusterpolicy -o yaml` after apply — Kyverno reports deprecation in `status.conditions`.

`mutateDigest: true` is the operationally important flag: it turns Kyverno into the tag→digest resolver, so developers keep writing tags while etcd only ever stores digests.

### 5.6 Cluster-side verification — sigstore policy-controller

Purpose-built, smaller blast radius than a general policy engine, and **namespace opt-in** rather than opt-out.

```yaml
# clusterimagepolicy.yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: acme-signed-images
spec:
  images:
  - glob: "registry.internal.acme.io/**"
  - glob: "ghcr.io/acme-vendor/**"
  authorities:
  - name: internal-release-key
    key:
      hashAlgorithm: sha256
      data: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEr9tRq2v9uH0f0PZ1yYqNb0m7pQnA
        8bT4kR3wYh6Xz2Vd5cQ1sK9fL0aJ7nB4mC6eH2tG8dU1oP3wS5xF9yE0Zg==
        -----END PUBLIC KEY-----
  - name: ci-keyless
    keyless:
      url: https://fulcio.sigstore.dev
      identities:
      - issuer: https://token.actions.githubusercontent.com
        subjectRegExp: "^https://github\\.com/acme/platform/\\.github/workflows/release\\.yaml@refs/heads/main$"
      trustRootRef: default
    ctlog:
      url: https://rekor.sigstore.dev
    attestations:
    - name: must-have-slsa-provenance
      predicateType: slsaprovenance1
      policy:
        type: cue
        data: |
          predicateType: "https://slsa.dev/provenance/v1"
          predicate: {
            buildDefinition: {
              buildType: "https://actions.github.io/buildtypes/workflow/v1"
            }
          }
  policy:
    # Both authorities must be satisfied — internal key AND CI identity.
    type: cue
    data: |
      authorityMatches: {
        "internal-release-key": { signatures: [...{}] }
        "ci-keyless": { attestations: { "must-have-slsa-provenance": [...{}] } }
      }
  mode: enforce
```

```console
$ kubectl label namespace team-a policy.sigstore.dev/include=true
namespace/team-a labeled

$ kubectl -n team-a run unsigned --image=registry.internal.acme.io/team-a/api:dirty
Error from server (BadRequest): admission webhook "policy.sigstore.dev" denied the request: validation failed: failed policy: acme-signed-images: spec.containers[0].image
registry.internal.acme.io/team-a/api@sha256:11ab…: none of the attached signatures matched the authorities
```

---

## 6. Verification and failure diagnosis

### 6.1 First question: admission or pull?

The two failure classes look nothing alike and are frequently confused.

| Signal | Admission rejection | Image pull failure |
|---|---|---|
| Where it appears | Synchronously on `kubectl apply` (bare Pod) or in `kubectl describe rs/<name>` (controller-created) | `kubectl get pod` shows `ErrImagePull` / `ImagePullBackOff` |
| Pod object exists | **No** (bare Pod) | Yes, `Pending` |
| Message source | apiserver / webhook | kubelet event `Failed` |
| Fix location | policy, RBAC, webhook health | registry auth, mirror, DNS, TLS |

```console
$ kubectl -n team-a get deploy api
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
api    0/3     0            0           94s

$ kubectl -n team-a describe rs api-6d4f8c7b59 | tail -6
Events:
  Type     Reason        Age               From                   Message
  ----     ------        ----              ----                   -------
  Warning  FailedCreate  12s (x6 over 94s)  replicaset-controller  Error creating: admission webhook "mutate.kyverno.svc-fail" denied the request: resource Pod/team-a/api-6d4f8c7b59- was blocked due to the following policies

verify-image-signatures:
  verify-internal-keyed: 'failed to verify image registry.internal.acme.io/team-a/api:v2.7.1:
    .attestors[0].entries[0].keys: no matching signatures'
```

**Rule:** a Deployment stuck at `0/N` with no Pods at all is *always* an admission problem. Go straight to the ReplicaSet events; the Deployment's own events say nothing useful.

### 6.2 Symptom → root cause table

| Error text | Layer | Root cause | Confirm with |
|---|---|---|---|
| `ValidatingAdmissionPolicy '…' denied request: …` | VAP | Working as designed | `kubectl get validatingadmissionpolicybinding -o yaml` |
| Every Pod denied, message mentions `no such key: initContainers` | VAP | CEL dereferenced an unset optional field; `failurePolicy: Fail` turns the eval error into a denial | `kubectl get validatingadmissionpolicy X -o jsonpath='{.status}'` |
| Policy exists but nothing is denied | VAP | No binding, binding `validationActions: [Audit]` only, or `namespaceSelector` excludes the target | `kubectl get vapb -o yaml \| grep -A5 matchResources` |
| `pods "x" is forbidden: image policy webhook backend denied one or more images: <reason>` | ImagePolicyWebhook | Backend returned `allowed:false` | Backend logs |
| `pods "x" is forbidden: Post "https://10.96.71.14:443/image_policy": dial tcp 10.96.71.14:443: connect: connection refused` | ImagePolicyWebhook | Backend down + `defaultAllow: false` (correct behaviour) | `kubectl -n image-policy get pod,ep` |
| Pod admitted with annotation `alpha.image-policy.k8s.io/failed-open: "true"` | ImagePolicyWebhook | Backend unreachable **and** `defaultAllow: true` — policy silently bypassed | `kubectl get pod X -o jsonpath='{.metadata.annotations}'` |
| apiserver CrashLoopBackOff after enabling the plugin | ImagePolicyWebhook | Config file not mounted, or YAML/`apiVersion` typo | `sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q \| head -1)` |
| `x509: certificate signed by unknown authority` from the apiserver to the backend | ImagePolicyWebhook | `certificate-authority` in the kubeconfig doesn't chain to the backend's serving cert | `openssl s_client -connect 10.96.71.14:443 -showcerts` |
| apiserver logs `dial tcp: lookup image-policy.image-policy.svc: no such host` | ImagePolicyWebhook | `*.svc` name in the kubeconfig — the apiserver does not use cluster DNS | Replace with ClusterIP |
| `no matching signatures` | cosign / Kyverno / policy-controller | Wrong public key, image re-pushed after signing, or signature not copied between registries | `cosign tree <img>@<digest>` |
| `no signatures found` / `MANIFEST_UNKNOWN` on `…​.sig` | cosign | Image was never signed, or registry GC/retention deleted the `.sig` tag, or the image was copied with `docker push` | `crane ls <repo> \| grep '^sha256-'` |
| `error verifying bundle: verifying signature: invalid signature when validating ASN.1 encoded signature` | cosign keyless | Payload digest ≠ signed digest; usually verifying a *tag* that has since moved | Re-resolve with `crane digest` |
| `certificate signed by unknown authority` on keyless verify | cosign | Stale/absent TUF root, or a private Sigstore without `TUF_ROOT` configured | `cosign initialize --mirror https://tuf-repo-cdn.sigstore.dev --root root.json` |
| `updating local metadata and targets: … expired` | cosign | TUF metadata expired or host clock skewed | `timedatectl status`; re-run `cosign initialize` |
| `error during command execution: no provider found for … OIDC` | cosign sign | Missing `id-token: write` permission in the CI job | Job `permissions:` block |
| `failed to verify image …: Get "https://registry…": unauthorized` | Kyverno | Policy engine has no pull credentials for the private repo | `verifyImages[].imageRegistryCredentials.secrets` |
| Kyverno webhook timeout, Pods intermittently rejected | Kyverno | Registry latency > `webhookTimeoutSeconds`; every admission does a network round-trip | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i timeout` |
| `ImagePullBackOff` right after enabling `hosts.toml` | containerd | Mirror path wrong, `override_path` missing, or CA not trusted | `sudo crictl pull <img>` on the node |

### 6.3 Diagnostic runbook

**Confirm the object that actually got persisted (digest, not tag):**

```console
$ kubectl -n team-a get pod api-6d4f8c7b59-2xk4q \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
api	registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ kubectl -n team-a get pod api-6d4f8c7b59-2xk4q \
    -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}'
api	registry.internal.acme.io/team-a/api@sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47
```

`spec.containers[].image` is what you asked for; `status.containerStatuses[].imageID` is what the node actually runs. **If they disagree, the tag moved.** This one-liner is the fastest live-cluster detection of a mutable-tag incident.

**Audit-mode rollout — read the denials before enforcing:**

```console
$ sudo grep -h 'validation.policy.admission.k8s.io/validation_failure' \
    /var/log/kubernetes/audit.log | tail -1 | jq -r '.annotations'
{
  "validation.policy.admission.k8s.io/validation_failure": "[{\"message\":\"image(s) from a non-permitted registry: docker.io/library/redis:7\",\"policy\":\"allowed-registries.acme.io\",\"binding\":\"allowed-registries-binding\",\"expressionIndex\":0,\"validationActions\":[\"Audit\"]}]"
}
```

**Verify a signature the same way the cluster does, from your laptop:**

```console
$ IMG=registry.internal.acme.io/team-a/api
$ D=$(crane digest ${IMG}:v2.7.1) && echo $D
sha256:9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47

$ crane ls registry.internal.acme.io/team-a/api | grep '^sha256-'
sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.att
sha256-9f2a4c3d1e6b8a70f5c2d9e4b1a37c60d8e5f2a91b4c7d0e3f6a8b2c5d9e1f47.sig

$ cosign verify --key cosign.pub ${IMG}@${D} >/dev/null && echo OK
OK
```

If `cosign verify` succeeds on your laptop but Kyverno reports `no matching signatures`, the difference is almost always **credentials or reachability from inside the cluster** — the policy engine pulls the `.sig` artifact itself.

**Prove the transparency-log entry exists (keyless):**

```console
$ rekor-cli search --sha $(echo -n "$D" | sed 's/sha256://')
Found matching entries (listed by UUID):
24296fb24b8ad77a9e1c8f0d2b3a4f5e6c7d8a9b0e1f2a3b4c5d6e7f8091a2b3c

$ rekor-cli get --uuid 24296fb24b8ad77a9e1c8f0d2b3a4f5e6c7d8a9b0e1f2a3b4c5d6e7f8091a2b3c \
    --format json | jq -r '.Body.HashedRekordObj.signature.publicKey.content' \
    | base64 -d | openssl x509 -noout -text | grep -A2 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:https://github.com/acme/platform/.github/workflows/release.yaml@refs/heads/main
```

**Check whether the guard is actually armed** (the failure mode nobody notices — a policy that has silently stopped enforcing):

```console
$ kubectl -n team-a run canary-unsigned \
    --image=docker.io/library/busybox:1.36 --restart=Never --command -- sleep 1
Error from server (Forbidden): pods "canary-unsigned" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.acme.io' with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted registry: docker.io/library/busybox:1.36. Permitted prefixes: registry.internal.acme.io/, registry.k8s.io/
```

Run this as a CronJob and alert if it *succeeds*. A negative control is the only monitoring that catches a webhook silently switched to `failurePolicy: Ignore`, a binding deleted by a bad Helm upgrade, or a namespace that lost its `policy.sigstore.dev/include` label.

### 6.4 Failure-policy trade-offs

| Setting | Behaviour when the enforcement component is down | Cluster impact | When to choose it |
|---|---|---|---|
| `failurePolicy: Fail` / `defaultAllow: false` | All matched creations denied | Cluster cannot self-heal; a Kyverno outage blocks Kyverno's own Pods unless excluded | Regulated / high-assurance. **Mandatory**: exclude `kube-system` and the policy engine's own namespace |
| `failurePolicy: Ignore` / `defaultAllow: true` | Everything admitted, unverified | Cluster survives; control is silently absent | Only during rollout, with an alert on the negative control |
| VAP (in-process) | Cannot be down independently of the apiserver | None | Default for anything CEL can express |

This is the strongest practical argument for putting the registry allowlist in a `ValidatingAdmissionPolicy` and reserving webhooks for signature verification: the cheap check has no availability coupling at all, so a signature-webhook outage degrades you to "trusted registries only" instead of "anything goes".

---

## 7. Production checklist

1. Registry allowlist as a `ValidatingAdmissionPolicy`, matching Pods **and** all workload controllers, `Deny` + `Audit`, `kube-system` excluded.
2. containerd `hosts.toml` on every node: internal mirror only, upstream hosts absent, CA pinned, `skip_verify = false`. Egress firewall blocking `:443` to public registries from node subnets.
3. Signature verification (Kyverno or policy-controller) with `mutateDigest: true`, so etcd only ever holds digests.
4. Keyless in CI with `id-token: write`; identities pinned by `subject` **and** `issuer` — never `--insecure-ignore-tlog` or an unpinned `cosign verify`.
5. SBOM + vulnerability attestations produced at build time; admission requires a clean scan newer than N days.
6. `AlwaysPullImages` on multi-tenant clusters, with a sized pull-through cache.
7. Registry retention rules explicitly preserve `sha256-*.sig` / `.att` tags; cross-registry promotion uses `cosign copy` or `crane copy`, never `docker pull && docker push`.
8. A CronJob negative control that tries to run an unsigned image from an unpermitted registry and pages if it succeeds.
9. Break-glass path documented: which annotation or namespace label bypasses policy, who may set it, and the audit rule that alerts when it is used.

---

## 8. References

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- CEL in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Admission Controllers Reference (`ImagePolicyWebhook`, `AlwaysPullImages`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- `AdmissionConfiguration` API (`apiserver.config.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-config.v1/
- `ImageReview` API (`imagepolicy.k8s.io/v1alpha1`) — https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.34/#imagereview-v1alpha1-imagepolicy-k8s-io
- Images and image pull policy — https://kubernetes.io/docs/concepts/containers/images/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- containerd registry host configuration (`hosts.toml`) — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- containerd CRI plugin configuration — https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- Sigstore documentation — https://docs.sigstore.dev/
- cosign signing containers — https://docs.sigstore.dev/cosign/signing/signing_with_containers/
- cosign keyless / OIDC signing — https://docs.sigstore.dev/cosign/signing/overview/
- cosign attestations — https://docs.sigstore.dev/cosign/verifying/attestation/
- Sigstore policy-controller — https://docs.sigstore.dev/policy-controller/overview/
- Rekor transparency log — https://docs.sigstore.dev/logging/overview/
- Fulcio certificate authority — https://docs.sigstore.dev/certificate_authority/overview/
- Kyverno `verifyImages` rules — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Kyverno image verification policies — https://kyverno.io/policies/?policytypes=Image%2520Verification
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- SLSA specification v1.0 — https://slsa.dev/spec/v1.0/
- in-toto attestation framework — https://github.com/in-toto/attestation
- OCI Distribution Specification (referrers API) — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- SPDX specification — https://spdx.dev/use/specifications/
- CycloneDX specification — https://cyclonedx.org/specification/overview/
- Syft (SBOM generation) — https://github.com/anchore/syft
- Trivy (scanning and `cosign-vuln` output) — https://trivy.dev/latest/docs/
- go-containerregistry / `crane` — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- skopeo — https://github.com/containers/skopeo