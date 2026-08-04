# CKS 4.3 — Secure Your Supply Chain

## Guided Exercises: Permitted Registries, Artifact Signing and Validation

> **Exam domain:** Supply Chain Security (20% of CKS v1.34) — competency *"Secure your supply chain (permitted registries, sign and validate artifacts, etc.)"*
> **Reference:** [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

---

## Lab topology and version pinning

Every exercise below assumes this environment. Pin these versions — CEL policy syntax, containerd's registry plugin path and Kyverno's policy schema all moved between minor releases, and silently running a different version is the single most common reason these labs "don't work".

| Component | Version | Notes |
|---|---|---|
| Kubernetes | v1.34.x, `kubeadm` | 1 control-plane (`cp01`, `10.0.1.10`), 2 workers (`w01`, `w02`) |
| Container runtime | containerd 2.0+ | CRI plugin path differs from 1.7 — see Exercise 7 |
| cosign | v2.4.x | v1 syntax (`COSIGN_EXPERIMENTAL=1`) is gone |
| Kyverno | v1.14.x | Helm chart `kyverno/kyverno` |
| syft | v1.x | SBOM generation |
| Registry | `registry:2.8.3` | run in-cluster as a static Pod at `registry.internal:5000` |

```
                         ┌──────────────────────────────────────────────┐
                         │              cp01 (control plane)            │
   kubectl apply ──────► │  kube-apiserver                              │
                         │    ├─ ImagePolicyWebhook ──► image-policy    │  Exercise 3
                         │    ├─ ValidatingAdmissionPolicy (CEL)        │  Exercise 2
                         │    └─ ValidatingWebhook ──► Kyverno          │  Exercise 5
                         │  registry.internal:5000 (static Pod)         │  Exercise 0
                         └──────────────────────────────────────────────┘
                                         │ scheduled Pod
                                         ▼
                         ┌──────────────────────────────────────────────┐
                         │              w01 / w02 (kubelet)             │
                         │   containerd ─ /etc/containerd/certs.d/      │  Exercise 7
                         │     ├─ registry.internal:5000/hosts.toml     │
                         │     └─ _default/hosts.toml  (deny fallback)  │
                         └──────────────────────────────────────────────┘
```

The four control points are deliberately layered. Admission (Exercises 2, 3, 5) is *policy*; the runtime allowlist (Exercise 7) is *enforcement of last resort* for anything that bypasses the API server — static Pods, a compromised controller, a kubelet pulling directly.

---

## Exercise 0 — Stand up a private registry with a real TLS chain

Signing exercises are worthless against a plaintext registry, because you cannot demonstrate the distinction between *transport trust* and *artifact trust*. Build the registry properly.

**Steps**

1. On `cp01`, create a lab CA and a server certificate for the registry:

```bash
mkdir -p /etc/registry/certs && cd /etc/registry/certs

# Lab CA
openssl req -x509 -newkey rsa:4096 -sha256 -days 90 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=teach-plat-lab-ca"

# Registry server key + CSR
openssl req -newkey rsa:4096 -nodes \
  -keyout registry.key -out registry.csr -subj "/CN=registry.internal"

# Sign it, with the SANs that actually matter
openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out registry.crt -days 90 -sha256 \
  -extfile <(printf "subjectAltName=DNS:registry.internal,IP:10.0.1.10\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth")

openssl x509 -in registry.crt -noout -text | grep -A1 "Subject Alternative Name"
```

Expected:

```console
            X509v3 Subject Alternative Name:
                DNS:registry.internal, IP Address:10.0.1.10
```

2. Add the name resolution on **all three nodes** (`cp01`, `w01`, `w02`):

```bash
echo "10.0.1.10 registry.internal" >> /etc/hosts
```

3. Run the registry as a static Pod on `cp01` so it survives reboots without depending on the scheduler:

```yaml
# /etc/kubernetes/manifests/registry.yaml
apiVersion: v1
kind: Pod
metadata:
  name: registry
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-cluster-critical
  containers:
    - name: registry
      image: registry:2.8.3
      env:
        - name: REGISTRY_HTTP_ADDR
          value: "0.0.0.0:5000"
        - name: REGISTRY_HTTP_TLS_CERTIFICATE
          value: /certs/registry.crt
        - name: REGISTRY_HTTP_TLS_KEY
          value: /certs/registry.key
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
      volumeMounts:
        - { name: certs, mountPath: /certs, readOnly: true }
        - { name: data,  mountPath: /var/lib/registry }
      resources:
        requests: { cpu: 100m, memory: 128Mi }
  volumes:
    - name: certs
      hostPath: { path: /etc/registry/certs, type: Directory }
    - name: data
      hostPath: { path: /var/lib/registry, type: DirectoryOrCreate }
```

4. Verify the registry answers over TLS and that the chain validates:

```bash
curl --cacert /etc/registry/certs/ca.crt https://registry.internal:5000/v2/ -i
```

Expected:

```console
HTTP/2 200
content-type: application/json; charset=utf-8
docker-distribution-api-version: registry/2.0
...
{}
```

5. Teach containerd to trust the CA on every node. Create the per-host directory (the directory name **must** include the port when the reference includes it):

```bash
mkdir -p /etc/containerd/certs.d/registry.internal:5000
cp /etc/registry/certs/ca.crt /etc/containerd/certs.d/registry.internal:5000/ca.crt

cat > /etc/containerd/certs.d/registry.internal:5000/hosts.toml <<'EOF'
server = "https://registry.internal:5000"

[host."https://registry.internal:5000"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/registry.internal:5000/ca.crt"
EOF
```

6. Point containerd at that directory. **containerd 2.x** uses a different plugin key than 1.7 — check first:

```bash
containerd --version
```

```toml
# containerd 2.x — /etc/containerd/config.toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

# containerd 1.7.x — /etc/containerd/config.toml
# [plugins."io.containerd.grpc.v1.cri".registry]
#   config_path = "/etc/containerd/certs.d"
```

```bash
systemctl restart containerd
crictl pull registry.internal:5000/library/busybox:1.36 2>&1 | tail -2
```

At this point the pull will fail with a 404 — nothing is pushed yet. That is the correct failure; a TLS error here means step 5/6 is wrong.

### Checkpoint questions — block 0

- **Q0.1** — You copied `ca.crt` into `certs.d` and also into the OS trust store with `update-ca-certificates`. Which one does containerd actually consult when pulling from `registry.internal:5000`, and why does the distinction matter in an air-gapped cluster?
- **Q0.2** — The registry Pod is a static Pod. Name two supply-chain-relevant consequences of that choice — one that helps you and one that is a security weakness you must compensate for elsewhere.
- **Q0.3** — Your teammate "fixes" a pull failure by adding `skip_verify = true` to `hosts.toml`. Exactly which attack does that re-enable, and does image signing (Exercise 4) compensate for it?

---

## Exercise 1 — Map the supply-chain surface and pin by digest

You cannot secure a supply chain you have not enumerated. This is the first thing to do on any cluster you inherit, and it is a fast, high-value exam habit.

**Steps**

1. Enumerate every distinct image *requested* across the cluster, grouped by registry:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

Expected (abridged):

```console
registry.k8s.io/coredns/coredns:v1.12.1
registry.k8s.io/etcd:3.6.4-0
registry.k8s.io/kube-apiserver:v1.34.1
docker.io/library/registry:2.8.3
docker.io/calico/node:v3.29.1
```

2. Extract just the registry hosts — this is your *de facto* allowlist, the input for Exercise 2:

```bash
kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | sed -E 's|^([^/]*\.[^/]*(:[0-9]+)?)/.*|\1|; t; s|^.*$|docker.io (implicit)|' \
  | sort | uniq -c | sort -rn
```

Expected:

```console
     18 registry.k8s.io
      6 docker.io (implicit)
      3 quay.io
```

3. Now compare *requested* image against *resolved* image. `.spec` is what the author asked for; `.status.containerStatuses[].imageID` is what the node actually ran:

```bash
kubectl run drift --image=nginx:1.27 --restart=Never
kubectl wait --for=condition=Ready pod/drift --timeout=60s

kubectl get pod drift -o jsonpath='requested: {.spec.containers[0].image}{"\n"}resolved:  {.status.containerStatuses[0].imageID}{"\n"}'
```

Expected:

```console
requested: nginx:1.27
resolved:  docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

4. Re-pin the same workload by digest and prove the tag is now irrelevant:

```bash
DIGEST=$(kubectl get pod drift -o jsonpath='{.status.containerStatuses[0].imageID}' | cut -d@ -f2)
kubectl delete pod drift

kubectl run pinned --restart=Never \
  --image="docker.io/library/nginx@${DIGEST}" \
  --image-pull-policy=IfNotPresent
kubectl get pod pinned -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Expected:

```console
docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

5. Inspect what the runtime believes about that image, bypassing the API server entirely:

```bash
NODE=$(kubectl get pod pinned -o jsonpath='{.spec.nodeName}')
ssh "$NODE" 'crictl images --digests | grep nginx'
ssh "$NODE" 'crictl inspecti docker.io/library/nginx@'"$DIGEST"' | jq ".status.repoDigests, .status.repoTags"'
```

Expected:

```console
["docker.io/library/nginx@sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c"]
["docker.io/library/nginx:1.27"]
```

### Checkpoint questions — block 1

- **Q1.1** — A Deployment specifies `image: internal/app:v2.3.1` with `imagePullPolicy: IfNotPresent`. An attacker with push rights to the registry overwrites `v2.3.1`. Which existing Pods are compromised, which new Pods are compromised, and why is the answer "it depends on the node"?
- **Q1.2** — Digest pinning defeats tag mutation. Name two concrete operational costs it introduces, and the mechanism you would use to keep digests current without abandoning pinning.
- **Q1.3** — `.status.containerStatuses[].imageID` returned a digest. Is that digest the manifest digest of the image the author referenced, or something else? What changes for a multi-arch image?
- **Q1.4** — Why is enumerating `.spec.containers[*].image` alone an incomplete inventory of the cluster's supply chain? List at least three image sources it misses.

---

## Exercise 2 — Allowlist registries with ValidatingAdmissionPolicy (CEL, in-tree)

This is the modern, dependency-free way to restrict registries: no external webhook, no extra Pod, no availability risk from a third-party controller. It is GA and available in v1.34 as `admissionregistration.k8s.io/v1`.

**Steps**

1. Store the allowlist as parameters so the policy is data-driven — you will edit a ConfigMap, not a policy, when the list changes:

```yaml
# allowlist-params.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-allowlist
  namespace: kube-system
data:
  # newline-separated prefixes; matched with startsWith()
  prefixes: |
    registry.internal:5000/
    registry.k8s.io/
```

```bash
kubectl apply -f allowlist-params.yaml
```

2. Write the policy. Note the handling of `initContainers` / `ephemeralContainers`: they are optional fields, so a naive `object.spec.initContainers` expression throws at evaluation time and — with `failurePolicy: Fail` — bricks every Pod creation in the cluster.

```yaml
# vap-allowed-registries.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries.supplychain.local
spec:
  failurePolicy: Fail
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # never gate the control plane's own bootstrap path
    - name: exclude-system-namespaces
      expression: >-
        !(request.namespace in ['kube-system', 'kube-node-lease'])
  variables:
    - name: prefixes
      expression: >-
        params.data['prefixes'].split('\n').filter(p, p != '')
    - name: allImages
      expression: >-
        object.spec.containers.map(c, c.image) +
        (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
    - name: violations
      expression: >-
        variables.allImages.filter(img,
          !variables.prefixes.exists(p, img.startsWith(p)))
  validations:
    - expression: "size(variables.violations) == 0"
      messageExpression: >-
        'image(s) from a non-permitted registry: ' + variables.violations.join(', ') +
        ' — permitted prefixes: ' + variables.prefixes.join(', ')
      reason: Forbidden
```

3. Bind it. The binding is what actually turns the policy on; a policy with no binding is inert.

```yaml
# vap-allowed-registries-binding.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries.supplychain.local
  validationActions: ["Deny", "Audit"]
  paramRef:
    name: registry-allowlist
    namespace: kube-system
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system"]
```

```bash
kubectl apply -f vap-allowed-registries.yaml -f vap-allowed-registries-binding.yaml
```

4. Test the deny path:

```bash
kubectl create namespace app
kubectl -n app run bad --image=docker.io/library/nginx:1.27 --restart=Never
```

Expected:

```console
The pods "bad" is forbidden: ValidatingAdmissionPolicy 'allowed-registries.supplychain.local'
with binding 'allowed-registries-binding' denied request: image(s) from a non-permitted
registry: docker.io/library/nginx:1.27 — permitted prefixes: registry.internal:5000/, registry.k8s.io/
```

5. Test the allow path, and then the subtle case — an `initContainer` from a bad registry with a good main container:

```bash
kubectl -n app run good --image=registry.k8s.io/pause:3.10 --restart=Never
# → pod/good created

kubectl -n app apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: sneaky }
spec:
  initContainers:
    - name: fetch
      image: docker.io/library/busybox:1.36
      command: ["true"]
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
EOF
```

Expected:

```console
Error from server (Forbidden): error when creating "STDIN": pods "sneaky" is forbidden:
ValidatingAdmissionPolicy '...' denied request: image(s) from a non-permitted registry:
docker.io/library/busybox:1.36 — ...
```

6. Now the trap that catches most people. Create a **Deployment** with a forbidden image:

```bash
kubectl -n app create deployment ghost --image=docker.io/library/redis:7
```

Expected:

```console
deployment.apps/ghost created
```

The Deployment is accepted. Find out where the enforcement actually landed:

```bash
kubectl -n app get deploy ghost
kubectl -n app describe replicaset -l app=ghost | tail -8
```

Expected:

```console
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
ghost   0/1     0            0           25s

Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  10s   replicaset-controller  Error creating: pods "ghost-7d9c..."
    is forbidden: ValidatingAdmissionPolicy 'allowed-registries.supplychain.local' ...
```

7. Confirm the audit trail exists even for allowed requests, by checking the policy is being evaluated:

```bash
kubectl get validatingadmissionpolicy allowed-registries.supplychain.local \
  -o jsonpath='{.status.typeChecking}{"\n"}'
```

An empty result (`{}` or nothing) means the CEL type-checker found no problems against the matched types. Non-empty output lists expression warnings — always read them before trusting the policy.

### Checkpoint questions — block 2

- **Q2.1** — In step 6 the Deployment was created and only the ReplicaSet failed. Explain precisely why, and give two different ways to make the failure surface at `kubectl create deployment` time. State the trade-off of each.
- **Q2.2** — Your allowlist entry is `registry.internal:5000/`. An attacker pushes to `registry.internal:5000.evil.com/team/app:v1`. Does the policy allow it? Now change the prefix to `registry.internal` (no slash) and answer again. What is the general lesson about prefix matching on image references?
- **Q2.3** — Why is `matchConditions` excluding `kube-system` necessary here, and what would happen on the next control-plane reboot if you set `failurePolicy: Fail` without that exclusion *and* the ConfigMap were deleted?
- **Q2.4** — `parameterNotFoundAction: Deny` versus `Allow`: describe the exact cluster behaviour in each case if someone runs `kubectl -n kube-system delete cm registry-allowlist`.
- **Q2.5** — The policy checks `object.spec.containers`. A user updates a running Pod's `image` field via `kubectl set image pod/...`. Does the policy fire? What about `kubectl debug` injecting an ephemeral container?
- **Q2.6** — VAP cannot rewrite the request. Name one supply-chain control you therefore *cannot* implement with `ValidatingAdmissionPolicy` alone, and what you would use instead.

---

## Exercise 3 — ImagePolicyWebhook: the API-server-side gate

`ImagePolicyWebhook` is the in-tree admission plugin that asks an external service "may I run this image?". It is the canonical CKS exercise for this topic because it requires editing the API server static Pod manifest correctly — including the volume mounts everyone forgets.

**Steps**

1. Build a minimal policy backend on `cp01`. It denies anything not from `registry.internal:5000` and anything tagged `:latest`:

```python
# /opt/imagepolicy/server.py
import json, ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ALLOWED_PREFIX = "registry.internal:5000/"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        review = json.loads(body)
        images = [c["image"] for c in review["spec"].get("containers", [])]
        denied = [i for i in images
                  if not i.startswith(ALLOWED_PREFIX) or i.endswith(":latest")]

        # Break-glass: only annotations matching *.image-policy.k8s.io/* reach us
        ann = review["spec"].get("annotations", {}) or {}
        breakglass = ann.get("lab.image-policy.k8s.io/break-glass") == "true"

        allowed = (not denied) or breakglass
        status = {"allowed": allowed}
        if not allowed:
            status["reason"] = ("images rejected by policy backend: "
                                + ", ".join(denied))
        status["auditAnnotations"] = {"policy-backend": "v1", "evaluated": str(len(images))}

        resp = json.dumps({"apiVersion": "imagepolicy.k8s.io/v1alpha1",
                           "kind": "ImageReview", "status": status}).encode()
        sys.stderr.write(f"review ns={review['spec'].get('namespace')} "
                         f"images={images} allowed={allowed}\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, *a): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/opt/imagepolicy/tls.crt", "/opt/imagepolicy/tls.key")
srv = HTTPServer(("127.0.0.1", 8443), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
```

2. Issue its serving certificate from the lab CA and start it:

```bash
mkdir -p /opt/imagepolicy && cd /opt/imagepolicy
openssl req -newkey rsa:2048 -nodes -keyout tls.key -out tls.csr -subj "/CN=image-policy"
openssl x509 -req -in tls.csr -CA /etc/registry/certs/ca.crt -CAkey /etc/registry/certs/ca.key \
  -CAcreateserial -out tls.crt -days 90 -sha256 \
  -extfile <(printf "subjectAltName=IP:127.0.0.1,DNS:image-policy\nextendedKeyUsage=serverAuth")

nohup python3 /opt/imagepolicy/server.py >/var/log/imagepolicy.log 2>&1 &
ss -ltnp | grep 8443
```

Expected:

```console
LISTEN 0  5   127.0.0.1:8443   0.0.0.0:*   users:(("python3",pid=4711,fd=4))
```

3. Write the kubeconfig the API server will use to reach the backend:

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-policy-backend
    cluster:
      certificate-authority: /etc/kubernetes/admission/ca.crt
      server: https://127.0.0.1:8443/image-policy
users:
  - name: kube-apiserver
    user: {}
contexts:
  - name: webhook
    context:
      cluster: image-policy-backend
      user: kube-apiserver
current-context: webhook
preferences: {}
```

```bash
mkdir -p /etc/kubernetes/admission
cp /etc/registry/certs/ca.crt /etc/kubernetes/admission/ca.crt
```

4. Write the admission configuration file. **`defaultAllow` is the whole security decision here:**

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: false
```

5. Wire it into the API server. Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` — **three** edits, and the last two are where candidates lose the point:

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        # (1) enable the plugin — append, never replace the existing list
        - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
        # (2) point it at the config
        - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
        ...
      volumeMounts:
        # (3a) the API server container cannot see host paths unless you mount them
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
  volumes:
    # (3b)
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

6. The kubelet restarts the static Pod on file change. Watch it come back — and know how to debug it if it does not:

```bash
watch -n2 'crictl ps -a --name kube-apiserver --latest'
# once Running:
kubectl get --raw='/readyz?verbose' | tail -5
```

If the API server never returns, `kubectl` is dead and you must go under it:

```bash
crictl ps -a --name kube-apiserver --latest -q | xargs crictl logs 2>&1 | tail -20
```

Typical failure and its meaning:

```console
Error: unknown admission plugin: ImagePolicyWebhook   → typo in --enable-admission-plugins
error reading admission control config: open /etc/kubernetes/admission/admission-config.yaml:
  no such file or directory                           → you forgot the volume / volumeMount
```

7. Test the gate:

```bash
kubectl -n app run bad2 --image=docker.io/library/alpine:3.20 --restart=Never -- sleep 3600
```

Expected:

```console
Error from server (Forbidden): pods "bad2" is forbidden: image policy webhook backend denied
one or more images: images rejected by policy backend: docker.io/library/alpine:3.20
```

8. Exercise the break-glass path and observe that the annotation reached the backend:

```bash
kubectl -n app apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: breakglass
  annotations:
    lab.image-policy.k8s.io/break-glass: "true"
spec:
  containers:
    - name: c
      image: docker.io/library/alpine:3.20
      command: ["sleep", "3600"]
EOF

tail -3 /var/log/imagepolicy.log
```

Expected:

```console
pod/breakglass created
review ns=app images=['docker.io/library/alpine:3.20'] allowed=True
```

*(If `ValidatingAdmissionPolicy` from Exercise 2 is still bound, this Pod is rejected by that policy instead — a useful demonstration that validating admission is an AND of all gates. Temporarily delete the binding to isolate this exercise.)*

9. Prove the fail-closed behaviour, which is the entire reason you set `defaultAllow: false`:

```bash
kill %1                      # stop the policy backend
kubectl -n app run any --image=registry.internal:5000/library/pause:3.10 --restart=Never
```

Expected:

```console
Error from server (Forbidden): pods "any" is forbidden: Post
"https://127.0.0.1:8443/image-policy": dial tcp 127.0.0.1:8443: connect: connection refused
```

```bash
nohup python3 /opt/imagepolicy/server.py >>/var/log/imagepolicy.log 2>&1 &
```

### Checkpoint questions — block 3

- **Q3.1** — `defaultAllow: true` versus `false`. Describe the failure mode of each with the backend down, and state the one production scenario in which `true` is the defensible choice.
- **Q3.2** — The API server hit `connection refused` and denied. Which two config fields determine *how long* and *how often* it retried before giving up, and what is the risk of setting them too high?
- **Q3.3** — Only annotations whose keys contain `.image-policy.k8s.io/` are forwarded to the backend. Given the break-glass design in step 8, write the RBAC-level control that stops any namespace user from bypassing the gate. Why is annotation-based break-glass structurally different from an RBAC exception?
- **Q3.4** — `allowTTL: 50` caches an allow decision. An image tag is re-pushed with malicious content and the digest changes. Does the cache let it through? What is the cache key?
- **Q3.5** — `ImagePolicyWebhook` only inspects resources of kind `Pod`, and cannot mutate. Enumerate three supply-chain bypasses that follow directly from those two properties.
- **Q3.6** — You added `--enable-admission-plugins=ImagePolicyWebhook` and the cluster lost `NodeRestriction` protections. Explain what went wrong and how `--enable-admission-plugins` interacts with the default plugin set.

---

## Exercise 4 — Sign and verify artifacts with cosign

Registry allowlisting answers *where* an image came from. Signing answers *who built it and whether it changed*. The two are orthogonal; you need both.

**Steps**

1. Install cosign and confirm the version:

```bash
curl -sSLo /usr/local/bin/cosign \
  https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64
chmod +x /usr/local/bin/cosign
cosign version --json | jq -r '.gitVersion, .goVersion'
```

Expected:

```console
v2.4.1
go1.23.2
```

2. Seed the private registry with a real image, then note the *digest*, which is what you will sign:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt   # cosign/crane must trust the lab CA

crane copy docker.io/library/nginx:1.27 registry.internal:5000/prod/nginx:1.27
DIGEST=$(crane digest registry.internal:5000/prod/nginx:1.27)
echo "$DIGEST"
```

Expected:

```console
sha256:d2b2f2b2ee1a4d1a4b52e0ba2d3ba9e17bc1a1ba4e02be2f1f1f0b8b2f0b9a1c
```

3. Generate a key pair and sign **by digest, never by tag**:

```bash
cd /root/keys
COSIGN_PASSWORD='' cosign generate-key-pair
ls -l cosign.key cosign.pub

COSIGN_PASSWORD='' cosign sign --key cosign.key --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${DIGEST}"
```

Expected:

```console
Pushing signature to: registry.internal:5000/prod/nginx
```

4. Look at *where* the signature physically lives. It is an ordinary OCI artifact in the same repository, under a derived tag:

```bash
cosign triangulate "registry.internal:5000/prod/nginx@${DIGEST}"
crane ls registry.internal:5000/prod/nginx
cosign tree "registry.internal:5000/prod/nginx@${DIGEST}"
```

Expected:

```console
registry.internal:5000/prod/nginx:sha256-d2b2f2b2ee1a...9a1c.sig

1.27
sha256-d2b2f2b2ee1a...9a1c.sig

📦 Supply Chain Security Related artifacts for an image: registry.internal:5000/prod/nginx@sha256:d2b2...
└── 🔐 Signatures for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.sig
   └── 🍒 sha256:6d1f...
```

5. Verify, and read the payload rather than trusting the exit code alone:

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  "registry.internal:5000/prod/nginx@${DIGEST}" | jq '.[0].critical'
```

Expected:

```console
Verification for registry.internal:5000/prod/nginx@sha256:d2b2... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

{
  "identity": { "docker-reference": "registry.internal:5000/prod/nginx" },
  "image": { "docker-manifest-digest": "sha256:d2b2f2b2ee1a...9a1c" },
  "type": "cosign container image signature"
}
```

6. Demonstrate that the signature is bound to content, not to a name. Push a *different* image under the same tag and re-verify:

```bash
crane copy docker.io/library/nginx:1.25 registry.internal:5000/prod/nginx:1.27
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
  registry.internal:5000/prod/nginx:1.27
```

Expected:

```console
Error: no matching signatures:
  ...
main.go:74: error during command execution: no matching signatures
```

```bash
echo $?
```

```console
1
```

7. Verify with the *wrong* key to see the distinct failure text — you must be able to tell "unsigned" from "signed by someone else" during an incident:

```bash
COSIGN_PASSWORD='' cosign generate-key-pair --output-key-prefix attacker
cosign verify --key attacker.pub --insecure-ignore-tlog=true \
  "registry.internal:5000/prod/nginx@${DIGEST}"
```

Expected:

```console
Error: no matching signatures:
searching log query: [POST /api/v1/log/entries/retrieve] ... (or, offline)
  crypto/rsa: verification error
```

8. Now the keyless flow, which is what real CI uses. On a workstation with browser access:

```bash
cosign sign --yes docker.io/youruser/demo@sha256:...
# → opens an OIDC flow, mints a 10-minute Fulcio certificate,
#   records the entry in the Rekor transparency log

cosign verify docker.io/youruser/demo@sha256:... \
  --certificate-identity-regexp='^https://github\.com/youruser/demo/\.github/workflows/.*' \
  --certificate-oidc-issuer='https://token.actions.githubusercontent.com' | jq '.[0].optional'
```

Expected (abridged):

```console
{
  "Bundle": { "SignedEntryTimestamp": "MEUCIQ...", "Payload": { "logIndex": 152893441, ... } },
  "Issuer": "https://token.actions.githubusercontent.com",
  "Subject": "https://github.com/youruser/demo/.github/workflows/release.yml@refs/tags/v1.0.0"
}
```

9. Store the verification key where an in-cluster controller can consume it, and confirm cosign can sign directly from a Secret:

```bash
kubectl create namespace cosign-system
COSIGN_PASSWORD='' cosign generate-key-pair k8s://cosign-system/prod-signing-key
kubectl -n cosign-system get secret prod-signing-key -o jsonpath='{.data}' | jq 'keys'
```

Expected:

```console
["cosign.key","cosign.password","cosign.pub"]
```

### Checkpoint questions — block 4

- **Q4.1** — In step 6 the tag was repointed and verification failed, yet the `.sig` artifact was untouched in the registry. Explain the mechanism: what exactly does cosign compute and compare?
- **Q4.2** — You signed with `--tlog-upload=false` and verified with `--insecure-ignore-tlog=true`. What security property did you give up, and describe the concrete attack that Rekor's transparency log is designed to detect.
- **Q4.3** — Keyless signing produces a certificate valid for ~10 minutes, yet verification works months later. Explain how that is possible, and name the two Sigstore services involved and their distinct roles.
- **Q4.4** — `cosign verify` on a *tag* is dangerous even when it succeeds. Describe the TOCTOU window between `cosign verify nginx:1.27` in a CI step and the kubelet pulling `nginx:1.27`, and give the two fixes.
- **Q4.5** — An attacker gains push access to `registry.internal:5000` but not to your signing key. List everything they can and cannot do to a consumer that enforces signature verification. Include denial-of-service in your answer.
- **Q4.6** — `cosign generate-key-pair k8s://ns/name` put the *private* key in a Secret. Justify or reject this practice for a production signing key, and name the alternatives.

---

## Exercise 5 — Enforce signatures at admission with Kyverno

`ImagePolicyWebhook` cannot verify signatures and cannot mutate. Kyverno does both: it verifies against your public key and rewrites the tag to the verified digest in the same admission pass, closing the TOCTOU window from Q4.4.

**Steps**

1. Install Kyverno and give it trust in the lab CA (a private registry with a private CA is the #1 cause of `failed to fetch image` errors in `verifyImages`):

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update

kubectl create namespace kyverno
kubectl -n kyverno create configmap lab-ca --from-file=ca.crt=/etc/registry/certs/ca.crt

helm install kyverno kyverno/kyverno -n kyverno --version 3.4.x \
  --set admissionController.container.extraEnvVars[0].name=SSL_CERT_DIR \
  --set admissionController.container.extraEnvVars[0].value=/etc/ssl/lab \
  --set admissionController.extraVolumes[0].name=lab-ca \
  --set admissionController.extraVolumes[0].configMap.name=lab-ca \
  --set admissionController.extraVolumeMounts[0].name=lab-ca \
  --set admissionController.extraVolumeMounts[0].mountPath=/etc/ssl/lab

kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

2. Write the image-verification policy:

```yaml
# kyverno-verify-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-internal-registry-signatures
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-prod-images
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
            - "registry.internal:5000/prod/*"
          # rewrite tag → verified digest, atomically, in this same request
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...REPLACE_WITH_cosign.pub...
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true      # lab only — no public tlog entry
                    ctlog:
                      ignoreSCT: true       # lab only
```

> Kyverno's schema drifts between minors. Before applying, confirm the field names on *your* build:
> `kubectl explain clusterpolicy.spec.validationFailureAction` and `kubectl explain clusterpolicy.spec.rules.verifyImages`. In recent versions `spec.validationFailureAction` and `spec.failurePolicy` are deprecated in favour of `spec.rules[].validate.failureAction` and `spec.webhookConfiguration.failurePolicy`.

```bash
sed -i "s|MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...REPLACE_WITH_cosign.pub...|$(grep -v -- '-----' /root/keys/cosign.pub | tr -d '\n')|" kyverno-verify-images.yaml
kubectl apply -f kyverno-verify-images.yaml
kubectl get cpol verify-internal-registry-signatures
```

Expected:

```console
NAME                                 ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE
verify-internal-registry-signatures  true        false        Enforce           True    8s
```

3. Re-sign the current `1.27` tag (you repointed it in Exercise 4 step 6) and deploy by tag:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
D=$(crane digest registry.internal:5000/prod/nginx:1.27)
COSIGN_PASSWORD='' cosign sign --key /root/keys/cosign.key --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"

kubectl -n app run signed --restart=Never --image=registry.internal:5000/prod/nginx:1.27
kubectl -n app get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

Expected — note the tag is **gone**, replaced by the digest Kyverno verified:

```console
pod/signed created
registry.internal:5000/prod/nginx@sha256:d2b2f2b2ee1a...9a1c
```

4. Push an unsigned image and try to run it:

```bash
crane copy docker.io/library/redis:7 registry.internal:5000/prod/redis:7
kubectl -n app run unsigned --restart=Never --image=registry.internal:5000/prod/redis:7
```

Expected:

```console
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/app/unsigned was blocked due to the following policies

verify-internal-registry-signatures:
  verify-prod-images: 'failed to verify image registry.internal:5000/prod/redis:7:
    .attestors[0].entries[0].keys: no matching signatures'
```

5. Inspect the machine-readable record of every verification decision:

```bash
kubectl -n app get policyreport -o wide
kubectl -n app get policyreport -o jsonpath='{.items[0].results[?(@.result=="fail")].message}{"\n"}'
```

6. Verify the mutation is *not* bypassable by pre-supplying a different digest:

```bash
BAD=$(crane digest registry.internal:5000/prod/redis:7)
kubectl -n app run forged --restart=Never \
  --image="registry.internal:5000/prod/nginx@${BAD}"
```

Expected:

```console
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
... failed to verify image registry.internal:5000/prod/nginx@sha256:...: no matching signatures
```

### Checkpoint questions — block 5

- **Q5.1** — `mutateDigest: true` changed the Pod spec. Which admission phase does that happen in, and why must it happen *before* validation rather than after? Explain how this closes the TOCTOU window from Q4.4.
- **Q5.2** — `failurePolicy: Fail` on the Kyverno webhook. Kyverno's own Pods live in namespace `kyverno`, and the policy `exclude`s that namespace. Walk through what happens on a full cluster cold start if that exclusion is missing.
- **Q5.3** — `required: true` versus `false` in `verifyImages`. Describe the behaviour for an image that matches `imageReferences` but has no signature at all, under each setting.
- **Q5.4** — The policy only matches `registry.internal:5000/prod/*`. An attacker pushes to `registry.internal:5000/staging/app`. What stops them, and which of the layers you built in Exercises 2, 3, 5 and 7 is responsible?
- **Q5.5** — Kyverno needed `SSL_CERT_DIR` and a mounted CA. Explain the trust relationship this establishes and why it is *separate* from the signature trust established by `publicKeys`. Which one, if compromised, is worse?
- **Q5.6** — `count: 1` under `attestors`. Design the policy change for "must be signed by the build system **and** countersigned by the release manager", and explain what `count` means relative to `entries`.

---

## Exercise 6 — SBOM attestations and policy over predicates

A signature says "this bytes-blob is mine". An *attestation* says "here is a signed claim *about* this bytes-blob" — its SBOM, its build provenance, its scan result. This is what "understand your supply chain" turns into operationally.

**Steps**

1. Generate a CycloneDX SBOM for the image you signed:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
D=$(crane digest registry.internal:5000/prod/nginx:1.27)

syft "registry.internal:5000/prod/nginx@${D}" -o cyclonedx-json > sbom.cdx.json
jq '{bomFormat, specVersion, components: (.components|length)}' sbom.cdx.json
```

Expected:

```console
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "components": 148
}
```

2. Attach it as a **signed attestation** (not a bare attachment):

```bash
COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key \
  --type cyclonedx --predicate sbom.cdx.json \
  --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"

cosign tree "registry.internal:5000/prod/nginx@${D}"
```

Expected:

```console
📦 Supply Chain Security Related artifacts for an image: registry.internal:5000/prod/nginx@sha256:d2b2...
├── 🔐 Signatures for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.sig
│  └── 🍒 sha256:6d1f...
└── 💾 Attestations for an image tag: registry.internal:5000/prod/nginx:sha256-d2b2...9a1c.att
   └── 🍒 sha256:9ab3...
```

3. Read the attestation the way a policy engine does — decode the in-toto Statement wrapped in the DSSE envelope:

```bash
cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true "registry.internal:5000/prod/nginx@${D}" 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject: .subject[0].name, bomFormat: .predicate.bomFormat}'
```

Expected:

```console
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://cyclonedx.org/bom",
  "subject": "registry.internal:5000/prod/nginx",
  "bomFormat": "CycloneDX"
}
```

4. Write a CUE policy that asserts properties of the predicate, not just the signature:

```cue
// sbom-policy.cue
predicateType: "https://cyclonedx.org/bom"
predicate: {
  bomFormat: "CycloneDX"
  // components must exist — an empty SBOM is a common CI failure that silently passes
  components: [_, ...]
}
```

```bash
cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true --policy sbom-policy.cue \
  "registry.internal:5000/prod/nginx@${D}" >/dev/null && echo "POLICY OK"
```

Expected:

```console
will be validating against CUE policies: [sbom-policy.cue]
Verification for registry.internal:5000/prod/nginx@sha256:d2b2... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
POLICY OK
```

5. Prove the policy actually bites. Attest a deliberately empty SBOM to a second image and watch it fail:

```bash
crane copy docker.io/library/busybox:1.36 registry.internal:5000/prod/busybox:1.36
D2=$(crane digest registry.internal:5000/prod/busybox:1.36)
jq '.components = []' sbom.cdx.json > sbom-empty.json

COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key --type cyclonedx \
  --predicate sbom-empty.json --tlog-upload=false --yes \
  "registry.internal:5000/prod/busybox@${D2}"

cosign verify-attestation --key /root/keys/cosign.pub --type cyclonedx \
  --insecure-ignore-tlog=true --policy sbom-policy.cue \
  "registry.internal:5000/prod/busybox@${D2}"
```

Expected:

```console
Error: 1 validation errors occurred
predicate.components: incomplete value [_, ...]
```

6. Attach a *vulnerability scan* attestation, which is what gates a release in practice:

```bash
trivy image --format cyclonedx --output vuln.cdx.json "registry.internal:5000/prod/nginx@${D}"
COSIGN_PASSWORD='' cosign attest --key /root/keys/cosign.key \
  --type vuln --predicate vuln.cdx.json --tlog-upload=false --yes \
  "registry.internal:5000/prod/nginx@${D}"
```

7. Require the attestation at admission by extending the Kyverno policy:

```yaml
      verifyImages:
        - imageReferences: ["registry.internal:5000/prod/*"]
          mutateDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
                    rekor: { ignoreTlog: true }
                    ctlog: { ignoreSCT: true }
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keys:
                        publicKeys: |-
                          -----BEGIN PUBLIC KEY-----
                          ...
                          -----END PUBLIC KEY-----
                        rekor: { ignoreTlog: true }
                        ctlog: { ignoreSCT: true }
              conditions:
                - all:
                    - key: "{{ bomFormat }}"
                      operator: Equals
                      value: "CycloneDX"
```

```bash
kubectl apply -f kyverno-verify-images.yaml
kubectl -n app run attested --restart=Never --image=registry.internal:5000/prod/nginx:1.27
kubectl -n app run notattested --restart=Never --image=registry.internal:5000/prod/redis:7
```

Expected:

```console
pod/attested created
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
... image attestations verification failed, .attestations[0]: no matching attestations
```

### Checkpoint questions — block 6

- **Q6.1** — Distinguish precisely: a signature, an attestation, and an *attachment* (`cosign attach sbom`). Which of the three is unauthenticated, and what is the practical consequence?
- **Q6.2** — The in-toto Statement has a `subject` array with a digest. Why is that field the load-bearing part of the whole scheme? What would break if a policy engine checked only `predicateType` and the signature?
- **Q6.3** — Your Kyverno policy requires a CycloneDX attestation signed by the same key as the image. Argue for and against using a *different* key for attestations, and describe what SLSA build level that separation supports ([slsa.dev/spec/v1.0/levels](https://slsa.dev/spec/v1.0/levels)).
- **Q6.4** — An SBOM attestation is signed at build time and is immutable. A CVE is published two weeks later. Explain why the SBOM attestation is still valuable and why the *vuln* attestation from step 6 must be treated completely differently in policy.
- **Q6.5** — Someone proposes enforcing "zero CRITICAL vulnerabilities" via the `vuln` attestation at admission time. Give the two strongest technical objections and the design you would use instead.

---

## Exercise 7 — Defense in depth at the node: containerd allowlist and credential hygiene

Everything so far runs on the API server. A static Pod, a compromised kubelet, or `crictl` on the node bypasses all of it. Close that path.

**Steps**

1. Demonstrate the bypass first — this is the point of the exercise:

```bash
ssh w01 'crictl pull docker.io/library/alpine:3.20 && crictl images | grep alpine'
```

Expected — the admission layers were never consulted:

```console
Image is up to date for sha256:a8560b36e8b8...
docker.io/library/alpine   3.20   a8560b36e8b8   3.62MB
```

2. Now install a default-deny fallback in containerd's registry configuration. containerd ≥1.7 consults `_default` when no host-specific directory matches:

```bash
ssh w01 'mkdir -p /etc/containerd/certs.d/_default'
ssh w01 'cat > /etc/containerd/certs.d/_default/hosts.toml' <<'EOF'
# Any registry without an explicit certs.d directory resolves here.
# 127.0.0.1:1 is a closed port: pulls fail fast and loudly.
server = "https://127.0.0.1:1"

[host."https://127.0.0.1:1"]
  capabilities = ["pull", "resolve"]
EOF
ssh w01 'systemctl restart containerd'
```

3. Create the explicit allow entries for the registries you *do* permit (`registry.internal:5000` already exists from Exercise 0):

```bash
ssh w01 'mkdir -p /etc/containerd/certs.d/registry.k8s.io'
ssh w01 'cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml' <<'EOF'
server = "https://registry.k8s.io"
[host."https://registry.k8s.io"]
  capabilities = ["pull", "resolve"]
EOF
ssh w01 'systemctl restart containerd'
```

4. Verify the allowlist from both directions:

```bash
ssh w01 'crictl rmi docker.io/library/alpine:3.20 >/dev/null 2>&1; crictl pull docker.io/library/alpine:3.20' 2>&1 | tail -2
ssh w01 'crictl pull registry.k8s.io/pause:3.10' 2>&1 | tail -1
ssh w01 'crictl pull registry.internal:5000/prod/nginx:1.27' 2>&1 | tail -1
```

Expected:

```console
E... PullImage "docker.io/library/alpine:3.20" failed: rpc error: code = Unknown
  desc = failed to pull and unpack image ...: dial tcp 127.0.0.1:1: connect: connection refused

Image is up to date for sha256:873ed750...    # registry.k8s.io — allowed
Image is up to date for sha256:d2b2f2b2...    # registry.internal:5000 — allowed
```

5. Confirm the effect propagates to Kubernetes, and learn what the failure looks like from the API side:

```bash
kubectl -n app run runtime-blocked --restart=Never \
  --image=docker.io/library/alpine:3.20 --overrides='{"spec":{"nodeName":"w01"}}' -- sleep 3600
sleep 15
kubectl -n app describe pod runtime-blocked | grep -A3 Events:
```

Expected:

```console
Events:
  Type     Reason   Age   From     Message
  ----     ------   ----  ----     -------
  Warning  Failed   5s    kubelet  Failed to pull image "docker.io/library/alpine:3.20":
    ... dial tcp 127.0.0.1:1: connect: connection refused
  Warning  Failed   5s    kubelet  Error: ErrImagePull
```

6. Audit registry credentials — leaked pull secrets are how attackers get *push* access:

```bash
kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'

# decode one and check the scope of the credential
kubectl -n app get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'
```

7. Find every ServiceAccount that silently injects a pull secret into every Pod that uses it:

```bash
kubectl get sa -A -o json | jq -r '
  .items[] | select(.imagePullSecrets != null)
  | "\(.metadata.namespace)/\(.metadata.name): \([.imagePullSecrets[].name]|join(","))"'
```

8. Prefer node-level credential providers over long-lived Secrets for cloud registries — the kubelet fetches a short-lived token per pull:

```yaml
# /etc/kubernetes/credential-provider-config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages: ["*.dkr.ecr.*.amazonaws.com"]
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
```

```bash
# kubelet flags
--image-credential-provider-config=/etc/kubernetes/credential-provider-config.yaml
--image-credential-provider-bin-dir=/opt/kubelet/credential-providers
```

### Checkpoint questions — block 7

- **Q7.1** — You now have registry restrictions at admission (Exercise 2) *and* at containerd (this exercise). Give a concrete attack that only the containerd layer stops, and a concrete legitimate change that only the admission layer catches. Why is neither sufficient alone?
- **Q7.2** — The `_default` fallback points at a dead port. Name the operational hazard this creates on node rebuild, and how you would detect the misconfiguration before it takes down a cluster.
- **Q7.3** — A `kubernetes.io/dockerconfigjson` Secret in namespace `app` grants push access to `registry.internal:5000`. Trace the full compromise path from "attacker can `exec` into one Pod in `app`" to "attacker controls production images", and name the two controls that break the chain.
- **Q7.4** — `imagePullSecrets` on a ServiceAccount versus on a Pod. Which is harder to audit and why? Which one does a namespace-scoped attacker with `create pods` rights get for free?
- **Q7.5** — The kubelet credential provider issues 12-hour cached credentials. Compare its blast radius to a static `dockerconfigjson` Secret across three axes: rotation, scope, and exfiltration value.

---

## Exercise 8 — Failure-mode drill

Supply-chain controls fail closed by design, which means they take production down when they misbehave. Being able to diagnose them under time pressure is the actual skill.

**Steps**

1. Break the gate and diagnose without hints. Corrupt the admission config path:

```bash
sed -i 's|/etc/kubernetes/admission/admission-config.yaml|/etc/kubernetes/admission/typo.yaml|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 30
kubectl get nodes
```

Expected:

```console
The connection to the server 10.0.1.10:6443 was refused - did you specify the right host or port?
```

Diagnose from under the API server:

```bash
crictl ps -a --name kube-apiserver --latest
crictl ps -a --name kube-apiserver --latest -q | xargs crictl logs 2>&1 | tail -5
```

Expected:

```console
CONTAINER      IMAGE       STATE    NAME             ATTEMPT
9f2c1a...      c2e17b...   Exited   kube-apiserver   4

Error: failed to create admission plugin config: open
/etc/kubernetes/admission/typo.yaml: no such file or directory
```

```bash
sed -i 's|typo.yaml|admission-config.yaml|' /etc/kubernetes/manifests/kube-apiserver.yaml
```

2. Break Kyverno and observe the difference between an API-server-internal failure and a webhook failure:

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=0
kubectl -n app run whatever --restart=Never --image=registry.internal:5000/prod/nginx:1.27
```

Expected:

```console
Error from server (InternalError): Internal error occurred: failed calling webhook
"mutate.kyverno.svc-fail": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/...":
no endpoints available for service "kyverno-svc"
```

Find the exact webhook responsible and its timeout/failure policy:

```bash
kubectl get mutatingwebhookconfigurations -o custom-columns=\
'NAME:.metadata.name,WEBHOOK:.webhooks[*].name,POLICY:.webhooks[*].failurePolicy,TIMEOUT:.webhooks[*].timeoutSeconds'
```

```bash
kubectl -n kyverno scale deploy/kyverno-admission-controller --replicas=1
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
```

3. Simulate the emergency you will actually face — a signing key rotation that invalidates every running image's signature. Determine, without deleting anything, exactly which workloads would fail to reschedule:

```bash
export SSL_CERT_FILE=/etc/registry/certs/ca.crt
for img in $(kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
             | grep '^registry.internal:5000/prod/' | sort -u); do
  if cosign verify --key /root/keys/cosign.pub --insecure-ignore-tlog=true "$img" >/dev/null 2>&1; then
    echo "OK      $img"
  else
    echo "UNSIGNED $img"
  fi
done
```

Expected:

```console
OK      registry.internal:5000/prod/nginx@sha256:d2b2f2b2ee1a...9a1c
UNSIGNED registry.internal:5000/prod/redis:7
```

4. Practise the controlled bypass. Move Kyverno from blocking to reporting *without* deleting the policy, so you retain visibility:

```bash
kubectl patch cpol verify-internal-registry-signatures --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'
kubectl -n app run emergency --restart=Never --image=registry.internal:5000/prod/redis:7
kubectl -n app get policyreport -o jsonpath='{.items[*].results[?(@.result=="fail")].policy}{"\n"}'
```

Expected:

```console
pod/emergency created
verify-internal-registry-signatures
```

Restore:

```bash
kubectl patch cpol verify-internal-registry-signatures --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

### Checkpoint questions — block 8

- **Q8.1** — In step 1 `kubectl` was completely dead. Rank, in order, the three commands you run on the control-plane node to find the cause, and explain what each one tells you that the previous did not.
- **Q8.2** — Step 2's error was `InternalError`, whereas the earlier signature failure was `Forbidden`. Why do those map to different HTTP status codes, and what does each tell you about where to look?
- **Q8.3** — During a real incident you must ship a fix and the signing pipeline is down. Rank these four bypasses from least to most dangerous, and justify: (a) `validationFailureAction: Audit`, (b) deleting the ClusterPolicy, (c) adding the namespace to `exclude`, (d) setting the webhook `failurePolicy: Ignore`.
- **Q8.4** — You rotate the signing key. Design the migration so that zero running workloads are at risk of failing to reschedule, using only the mechanisms in this document.
- **Q8.5** — Which of the controls you built (VAP, ImagePolicyWebhook, Kyverno, containerd allowlist) survive a full control-plane outage, and what does that tell you about where to place the control you most need to be unbypassable?

---

## Teardown

```bash
kubectl delete ns app cosign-system --ignore-not-found
kubectl delete cpol verify-internal-registry-signatures --ignore-not-found
kubectl delete validatingadmissionpolicybinding allowed-registries-binding --ignore-not-found
kubectl delete validatingadmissionpolicy allowed-registries.supplychain.local --ignore-not-found
kubectl -n kube-system delete cm registry-allowlist --ignore-not-found
helm uninstall kyverno -n kyverno; kubectl delete ns kyverno --ignore-not-found
rm -f /etc/kubernetes/manifests/registry.yaml
# revert kube-apiserver.yaml: remove ImagePolicyWebhook from --enable-admission-plugins,
# remove --admission-control-config-file, remove the admission-config volume/volumeMount
rm -rf /etc/containerd/certs.d/_default && systemctl restart containerd
```

---

## Answers

<details>
<summary><strong>Click to reveal all answers (Q0.1 – Q8.5)</strong></summary>

### Block 0 — Private registry and runtime trust

**Q0.1** — containerd consults the `ca` entry inside `/etc/containerd/certs.d/registry.internal:5000/hosts.toml` for that specific host. If no `ca` is specified there, it falls back to the Go system trust pool, which *does* include `update-ca-certificates` output. So both can work, but they behave differently: the `certs.d` entry is **scoped to one registry host**, the system store is **cluster-wide trust for every TLS client on the node** — including anything else that dials out. In an air-gapped cluster the distinction matters because you typically front all pulls with one internal mirror; putting that mirror's CA in `certs.d` only means a compromise of that CA cannot be used to impersonate any other TLS endpoint the node talks to. Principle: grant the narrowest trust that works.

**Q0.2** — *Helps:* a static Pod is managed directly by the kubelet from `/etc/kubernetes/manifests`, so it starts before (and independently of) the scheduler, the API server's admission chain, and any CNI-dependent controller. Your registry therefore survives a control-plane outage and cannot deadlock against the very policies that need it. *Weakness:* static Pods **bypass every admission controller**. The mirror Pod on the API server is a read-only reflection; nothing validated its image, its registry, its signature, or its security context. You compensate elsewhere: file integrity monitoring on `/etc/kubernetes/manifests`, restricting root/SSH on control-plane nodes, and the `NodeRestriction` admission plugin (which stops a kubelet from mutating *other* nodes' objects but does **not** stop it running its own static Pods).

**Q0.3** — `skip_verify = true` disables TLS certificate verification for that registry host, re-enabling **active machine-in-the-middle on image pulls**: anyone who can answer for `registry.internal:5000` (ARP/DNS spoofing, a rogue node, a compromised load balancer) can serve arbitrary image content and the runtime accepts it. Image signing **does** compensate for the content-integrity half — a MITM cannot produce a valid cosign signature for substituted layers, so a signature-enforcing consumer rejects the forgery. It does **not** compensate for the confidentiality half (pull credentials sent over an unverified channel are harvested) nor for availability. And critically, signature verification only helps *where it is enforced*: `crictl pull` on the node is not gated by Kyverno. Never ship `skip_verify`.

### Block 1 — Inventory and digest pinning

**Q1.1** — *Existing Pods:* unaffected. Their containers are already running from the previously resolved layers; the image content on disk does not change under them. *New Pods:* it depends on the node, because `IfNotPresent` only pulls when the tag is absent from that node's image store. A node that already cached `internal/app:v2.3.1` will start the **old, good** image; a freshly joined node, or one where the image was garbage-collected by the kubelet's image GC, pulls the **new, malicious** content. The result is a cluster in a mixed, non-reproducible state that is extremely hard to diagnose — you have one Deployment, one tag, and two different binaries running. This is exactly the class of failure digest pinning eliminates.

**Q1.2** — *Costs:* (1) Human-unreadable manifests — nobody can tell from `image: app@sha256:9f3c...` which version is deployed, so you must carry the version in a label or annotation. (2) Every upgrade becomes a manifest change, so a "just re-roll to pick up the patched base" workflow disappears; you need a machine to compute and commit the new digest. *Mechanism:* automate it — an image updater in the GitOps pipeline (Flux `ImagePolicy`/`ImageUpdateAutomation`, Renovate with digest pinning, Argo CD Image Updater) that resolves tag→digest, opens a commit, and lets the same signature/attestation policy gate the change. Alternatively, let an admission-time mutator do it (Kyverno's `mutateDigest: true`, Exercise 5), which gives you digest-level immutability without human-unreadable manifests — at the cost of the Git manifest no longer being the source of truth for what runs.

**Q1.3** — For a single-arch image, `imageID` is the digest of the image **manifest** as stored by the runtime. For a **multi-arch** image the reference the author used (`nginx:1.27`) resolves to an *index* (manifest list) digest, but the node runs one platform-specific manifest — so `imageID` typically reports the **platform-specific manifest digest**, not the index digest the author would get from `crane digest`. This is why comparing `imageID` against a digest you computed on your laptop can mismatch on a heterogeneous cluster, and why signing should target the **index** digest (cosign follows the index and verification of the index covers the children through the `subject`/attached-signature relationship — check with `cosign tree` on both digests).

**Q1.4** — It misses: (1) **initContainers and ephemeralContainers** — `kubectl debug` injects an image into a running Pod. (2) **Static Pods and mirror Pods**, and anything running on the node outside Kubernetes entirely. (3) **Templates that have not produced Pods yet** — Deployments/StatefulSets/CronJobs/DaemonSets whose Pods are scaled to zero or not yet scheduled, plus operator-managed workloads whose images live in CRs. (4) Sidecar-injecting webhooks (service mesh, secret injectors) that add images at admission time and therefore appear in Pods but never in the author's manifest. (5) `image` fields inside CRDs (operator `spec.image`), Helm values, and node-level images cached by the runtime. A real inventory queries `crictl images` on every node *and* every pod-template-bearing resource.

### Block 2 — ValidatingAdmissionPolicy

**Q2.1** — The `matchConstraints` only matched `resources: ["pods"]`. `kubectl create deployment` creates a **Deployment** object, which the policy does not match; the Deployment controller then creates a ReplicaSet, whose controller creates Pods — and *those* requests get denied. The user sees a healthy-looking `kubectl` exit and a Deployment stuck at 0 replicas. *Fixes:* (a) Add the controller resources to `matchConstraints` — `apiGroups: ["apps","batch"]`, `resources: ["deployments","statefulsets","daemonsets","replicasets","jobs","cronjobs"]` — and rewrite the CEL to read `object.spec.template.spec.containers` (different path per kind, so you need per-rule policies or `variables` that branch on `request.resource.resource`). Trade-off: much more CEL to maintain, and you must keep the Pod rule too, or bare Pods slip through. (b) Use the built-in **Pod Security Admission-style pattern** of matching only Pods and relying on tooling/CI to surface controller-level failures. Trade-off: bad UX, but a single correct expression. In production, do both: match pod-controllers for fast feedback *and* Pods for actual enforcement.

**Q2.2** — With prefix `registry.internal:5000/`, the reference `registry.internal:5000.evil.com/team/app:v1` does **not** start with `registry.internal:5000/` (the character after `5000` is `.`, not `/`), so it is correctly **denied**. With prefix `registry.internal` (no slash and no port), `registry.internal:5000.evil.com/...` **does** start with that string and is wrongly **allowed** — as is `registry.internal.evil.com/...`. *Lesson:* prefix matching on image references must always terminate at a **structural delimiter** — include the trailing `/` (and the port when the registry uses one). Better still, parse the reference: split on the first `/` and compare the host component for exact equality, e.g. `img.split('/')[0] in ['registry.internal:5000','registry.k8s.io']`, remembering that Docker Hub short names (`nginx:1.27`) have no host component at all and must be handled explicitly.

**Q2.3** — `kube-system` hosts the control plane's own static Pods and the CNI/CoreDNS/kube-proxy DaemonSets, whose images come from `registry.k8s.io` and the CNI vendor's registry. Gating them risks a deadlock and, at minimum, blocks legitimate control-plane upgrades. With `failurePolicy: Fail` **and** `parameterNotFoundAction: Deny`, deleting the ConfigMap makes the policy unable to resolve its params, so **every** matching Pod creation is denied. On the next control-plane reboot, mirror Pods for the static control-plane Pods still come up (static Pods bypass admission), but every DaemonSet Pod — CNI, kube-proxy, CoreDNS — is rejected, and the cluster has no networking. Recovery requires deleting the binding through an API server that is running but rejecting all Pod creates. The exclusion (plus never gating `kube-system`) is what makes the failure recoverable.

**Q2.4** — With `parameterNotFoundAction: Deny`: the binding cannot resolve its `paramRef`, and the admission request is **denied** for every resource the binding matches — fail-closed. With `Allow`: the policy is simply **skipped** for those requests and everything is admitted — fail-open. The security choice is `Deny`; the operability choice is `Allow`. The correct production answer is `Deny` *plus* protecting the ConfigMap: restrict `delete`/`update` on it via RBAC, and treat it as a control-plane object under GitOps, not something an operator edits by hand.

**Q2.5** — Yes, the policy fires: `matchConstraints` includes `UPDATE`, and `kubectl set image pod/...` is an update to the Pod object whose new `object.spec.containers[].image` is re-evaluated. (Note: the kubelet only honours image changes for containers in limited ways, but admission still runs.) For `kubectl debug`, the ephemeral container is added through the **`pods/ephemeralcontainers` subresource**, which is a *different* resource from `pods` in `matchConstraints`. The policy as written does **not** match it — the `has(object.spec.ephemeralContainers)` branch only helps on plain pod updates. To gate `kubectl debug` you must add `resources: ["pods/ephemeralcontainers"]` to the `resourceRules`. This is a real bypass and worth testing explicitly.

**Q2.6** — You cannot **rewrite** the request, so you cannot implement *tag-to-digest pinning at admission*, sidecar/label injection, or defaulting `imagePullPolicy: Always`. `ValidatingAdmissionPolicy` can only accept or reject. For mutation you need either `MutatingAdmissionPolicy` (the CEL-based in-tree mutation counterpart, still maturing) or a `MutatingWebhookConfiguration` backed by a controller such as Kyverno (Exercise 5). You also cannot make **network calls** from CEL — so signature verification, which requires fetching the `.sig` artifact from the registry, is structurally impossible in a VAP.

### Block 3 — ImagePolicyWebhook

**Q3.1** — `defaultAllow: true` → when the backend is unreachable (or every retry is exhausted), the API server **admits** the Pod. Fail-open: availability is preserved, the security control silently disappears, and you may not notice for weeks. `defaultAllow: false` → the API server **denies**. Fail-closed: the control is real, but an outage of a single-instance webhook stops all Pod creation cluster-wide, including the Pods that might fix it. *Defensible use of `true`:* an initial rollout/soak phase where you are measuring what the policy *would* block (paired with alerting on backend unavailability), or a cluster where the webhook is genuinely best-effort enrichment and a stronger control (containerd allowlist, signed-image enforcement) is the real gate. Beyond that phase, `false` plus a highly available, in-cluster-independent backend.

**Q3.2** — `retryBackoff: 500` (milliseconds) is the initial backoff between retries, and `allowTTL`/`denyTTL` (seconds) control how long decisions are cached, which indirectly determines how often the backend is consulted at all. Setting `retryBackoff` too high stretches out how long a single admission request blocks the API server handler; combined with a slow backend it consumes API server request slots and can degrade the whole control plane — an admission webhook outage becoming an API server outage. Setting the TTLs too high (see Q3.4) keeps stale decisions alive past the point where they are safe.

**Q3.3** — RBAC control: prevent unprivileged users from setting the annotation at all. Since Kubernetes RBAC is resource-scoped and cannot restrict individual *fields*, you enforce it with a second admission gate — a `ValidatingAdmissionPolicy` that denies any Pod carrying a key matching `*.image-policy.k8s.io/*` unless the requester is in an allowed group:

```yaml
validations:
  - expression: >-
      !object.metadata.?annotations.orValue({}).exists(k, k.contains('.image-policy.k8s.io/')) ||
      ('system:masters' in request.userInfo.groups)
```

*Structural difference:* an RBAC exception is **subject-scoped and auditable in one place** — you can enumerate who has it and revoke it centrally. An annotation-based break-glass is **object-scoped**: the privilege is conferred by the ability to write a field on a resource you already have `create` on, so anyone with `create pods` in any namespace holds it by default. It is a bypass wearing the costume of a control, unless you add the second gate above.

**Q3.4** — The cache is keyed on the **`ImageReview` request contents** — principally the image string as written in the Pod spec, plus namespace and annotations. If the spec says `app:v1` and the tag is re-pushed with different content, the *image string is unchanged*, so a cached allow (up to `allowTTL` seconds) admits the new, malicious content without re-consulting the backend. The digest never enters the picture, because `ImagePolicyWebhook` sees only the unresolved reference. This is a concrete reason `ImagePolicyWebhook` is insufficient on its own and why digest-based verification (Exercises 4–5) exists. Short TTLs reduce but do not eliminate the window.

**Q3.5** — From "Pods only": (1) A **Deployment/DaemonSet/Job** with a forbidden image is accepted at the top level; enforcement only appears as controller events — same trap as Q2.1. (2) **Static Pods** never traverse admission at all. (3) The **`pods/ephemeralcontainers` subresource** — verify whether your version's plugin inspects it; if not, `kubectl debug --image=evil` walks straight in. From "cannot mutate": (4) No tag→digest pinning, so the TOCTOU window between the allow decision and the kubelet's pull remains wide open — the backend approves `app:v1`, and by the time the node pulls, `app:v1` is different bytes. (5) No ability to force `imagePullPolicy: Always`, so nodes can run stale cached content that was never re-evaluated.

**Q3.6** — `--enable-admission-plugins` **adds to** the default-enabled set rather than replacing it, so `NodeRestriction` — which *is* on by default in recent versions — should not have been lost by that flag alone. What actually breaks people is the neighbouring flag **`--disable-admission-plugins`**, or overwriting a kubeadm-generated `--enable-admission-plugins=NodeRestriction` line by *replacing* it instead of appending `,ImagePolicyWebhook`. kubeadm writes `--enable-admission-plugins=NodeRestriction` explicitly, and if you `sed` that line to `--enable-admission-plugins=ImagePolicyWebhook`, `NodeRestriction` reverts to whatever the default is for that version — which historically was *off*. Always append, and always verify afterwards:
`kubectl -n kube-system get pod kube-apiserver-cp01 -o yaml | grep admission-plugins`.

### Block 4 — cosign

**Q4.1** — cosign never signs a tag. It resolves the reference to a **manifest digest**, builds a small "simple signing" payload containing that digest (`critical.image.docker-manifest-digest`), signs *that payload*, and stores the signature as an OCI artifact tagged `sha256-<digest>.sig` in the same repository. On verification, cosign resolves the reference **again** to get the current digest, looks for signatures at `sha256-<current-digest>.sig`, and checks the signature over the payload. After repointing `1.27` to nginx 1.25, the tag resolves to a *different* digest, so cosign looks under a *different* `.sig` tag — which is empty — and reports `no matching signatures`. The old signature is still perfectly valid; it just describes bytes nobody is asking about any more.

**Q4.2** — You gave up **transparency and non-repudiation over time**. Rekor is an append-only, publicly auditable log of signing events with an inclusion proof and a signed timestamp. Without it, the attack it detects is: an attacker who steals your private key signs a malicious image and back-dates nothing — verification against your public key succeeds, and there is **no record anywhere** that the signature was created after the compromise. With a tlog entry, every legitimate signature is discoverable, so (a) you can enumerate everything ever signed with your key and spot entries you did not create, and (b) after a key compromise you can trust signatures whose log entries predate the compromise window and reject the rest. It also enables keyless verification of expired certificates (Q4.3). `--tlog-upload=false` is acceptable only in a genuinely air-gapped lab or with a private Rekor instance.

**Q4.3** — Keyless signing mints an ephemeral key pair, proves an OIDC identity to **Fulcio**, and receives a short-lived (~10 min) X.509 certificate binding the ephemeral public key to that identity. The signature and the certificate are then recorded in **Rekor**, which counter-signs with a trusted timestamp (the Signed Entry Timestamp). At verification time, cosign checks that the certificate was **valid at the moment recorded in the transparency log**, not at the moment of verification. So the certificate's expiry is irrelevant — Rekor is what makes the historical validity provable. *Roles:* Fulcio = short-lived certificate authority binding OIDC identity → key; Rekor = tamper-evident transparency log providing the trusted timestamp and public discoverability. Trust in both is bootstrapped by the TUF root that `cosign initialize` fetches.

**Q4.4** — `cosign verify nginx:1.27` resolves the tag to digest **D1** and validates a signature for D1. Some time later — minutes or days — the kubelet independently resolves `nginx:1.27`. If the tag was repointed in between, the kubelet gets **D2**, which nobody verified. CI reported green; production runs unverified bytes. *Fixes:* (1) Have CI verify by tag, then **emit the digest** and deploy `image: repo@sha256:D1` so the reference is immutable end-to-end. (2) Verify **at admission**, and mutate the tag to the verified digest in the same admission transaction — `mutateDigest: true` in Kyverno (Exercise 5), which makes verification and pinning atomic. Fix (2) is strictly stronger because it also covers Pods created outside CI.

**Q4.5** — *Can:* push new images and new tags; repoint existing tags to arbitrary content; **delete** images, signatures and attestations (if delete is enabled); push malicious `.sig` artifacts signed with their own key; consume storage. The last two matter — deleting your `.sig` artifacts is a **denial of service against a fail-closed verifier**: every deployment and every reschedule of a legitimate workload starts failing admission. That is often the more practical attack than forging content. *Cannot:* produce a signature that verifies against your public key, so no substituted content will be admitted by an enforcing consumer, and no forged attestation will satisfy a policy. Note the asymmetry: signature enforcement converts an **integrity** compromise into an **availability** compromise. Plan for it — registry backups, immutable tags server-side, and separate credentials for push versus delete.

**Q4.6** — **Reject** for a production signing key. A Kubernetes Secret is base64, not encrypted, stored in etcd; anyone with `get secrets` in that namespace, anyone who can read an etcd backup, and anyone who can schedule a Pod mounting it holds your signing identity. The `k8s://` form is a convenience for controllers that must *sign* in-cluster (e.g. an in-cluster build system), and even then requires etcd encryption at rest, tight RBAC, and audit on that Secret. *Alternatives, in increasing order of assurance:* (1) a KMS-backed key — cosign supports `--key awskms://`, `gcpkms://`, `azurekms://`, `hashivault://`, so the private key never leaves the HSM/KMS; (2) an HSM or PKCS#11 token for a root/release key; (3) **keyless** signing in CI, which removes the long-lived key entirely and replaces "who has the key" with "which workflow identity ran" — usually the right answer for a build pipeline.

### Block 5 — Kyverno enforcement

**Q5.1** — It happens in the **mutating admission** phase, which the API server runs *before* validating admission and before persisting the object. It must be first because the whole point is that the digest Kyverno *verified* is the digest that gets **written to etcd** and therefore the digest the kubelet pulls. If the rewrite happened after validation (or, worse, in a controller after persistence), the object would already carry a mutable tag and any later re-resolution could yield different content. Regarding TOCTOU: the "check" (fetch `.sig`, verify signature for digest D) and the "use" (write `image: repo@sha256:D` into the Pod spec) occur inside a single admission request, so there is no window in which the tag can be repointed between them. Anything downstream — scheduling, kubelet pull, node restarts, image GC — operates on an immutable digest.

**Q5.2** — Without the exclusion, Kyverno's own admission webhook is asked to validate the creation of Kyverno's own Pods. On a cold start nothing is running to answer, `failurePolicy: Fail` turns that into a denial, and the Kyverno Deployment can never produce Pods — a permanent deadlock that also blocks CoreDNS, CNI and everything else if those namespaces are not excluded either. Recovering requires deleting the `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` by hand. This is why every serious admission controller ships with namespace exclusions for `kube-system` and its own namespace, and why Kyverno's Helm chart configures `namespaceSelector` exclusions by default. General rule: **a fail-closed webhook must never be in the dependency path of its own bootstrap**.

**Q5.3** — `required: true` (the default): an image matching `imageReferences` that carries **no signature at all** is rejected — absence of evidence is treated as failure. This is what you want. `required: false`: an image with no signature is **allowed through**; the rule only rejects images that have signatures which fail to verify. That turns the control into "we check signatures when they happen to exist", which an attacker defeats by simply not signing — pushing an unsigned image is easier than forging one. `required: false` is only appropriate during a migration where you are onboarding repositories incrementally, and it should be paired with a report on how many images are still unsigned.

**Q5.4** — Nothing in *this* policy stops them — `registry.internal:5000/staging/app` does not match `registry.internal:5000/prod/*`, so `verifyImages` never evaluates and the image runs unsigned. What stops the Pod from running is the layer that gates on **registry** rather than repository path: the `ValidatingAdmissionPolicy` from Exercise 2 allows `registry.internal:5000/` as a whole, so it *permits* it; the `ImagePolicyWebhook` backend from Exercise 3 also allows the whole registry; and the containerd allowlist from Exercise 7 also allows the whole registry. **So the answer is: nothing stops them.** That is the lesson — path-scoped signature policies leave a hole exactly the size of every path you did not enumerate. Fix it by making the *default* deny: `imageReferences: ["registry.internal:5000/*"]` with per-path exceptions, rather than an allowlist of paths that must be signed.

**Q5.5** — The mounted CA establishes **transport trust**: Kyverno will accept a TLS connection to `registry.internal:5000` and fetch the manifest and the `.sig` artifact. The `publicKeys` block establishes **artifact trust**: the signature over the manifest digest must verify against that key. They are independent — a valid TLS connection tells you nothing about who built the image, and a valid signature is verifiable over an untrusted channel. *If compromised:* the **signing key** is far worse. A compromised registry CA lets an attacker MITM the fetch — but the artifact they serve still has to carry a signature verifying against your public key, so the control holds (they get DoS, not code execution). A compromised signing key lets an attacker sign anything, and every enforcing consumer in the fleet accepts it, over a perfectly valid TLS connection. Protect the signing key with a different class of control (KMS/HSM/keyless) than you use for the CA.

**Q5.6** — `count: N` means **at least N of the `entries` in this attestor block must verify**. `count: 1` with two entries = "either signature is sufficient" (OR). For "build system AND release manager", use **two attestor blocks**, because blocks are ANDed while entries within a block are counted:

```yaml
attestors:
  - count: 1
    entries:
      - keys: { publicKeys: "<build-system-key>", rekor: {...} }
  - count: 1
    entries:
      - keys: { publicKeys: "<release-manager-key>", rekor: {...} }
```

Entries within one block with `count: 2` would also require both — but the two-block form is clearer and lets each party have its own key-rotation set (e.g. block one with `count: 1` over three valid build-system keys). This is how you express a two-person rule or a promotion gate between staging and production.

### Block 6 — Attestations

**Q6.1** — A **signature** (`cosign sign`) is a signed assertion over the image's manifest digest and nothing else: "these bytes are mine". An **attestation** (`cosign attest`) is a signed **in-toto Statement** — a DSSE envelope containing `{_type, subject: [{name, digest}], predicateType, predicate}` — that is, a signed *claim about* those bytes: its SBOM, its provenance, its scan result. An **attachment** (`cosign attach sbom`) pushes an SBOM as an OCI artifact alongside the image with **no signature at all**. The attachment is the unauthenticated one, and the consequence is decisive: anyone with push access can replace the attached SBOM with a clean-looking fabrication, so an attachment can never be a policy input. `cosign attach sbom` is deprecated in favour of `cosign attest` for exactly this reason. Rule: if a policy decision depends on it, it must be an attestation.

**Q6.2** — `subject[].digest` is what **binds the claim to the artifact**. Without it, an attestation is a free-floating signed document. If a policy engine checked only `predicateType` and the signature validity, an attacker with any valid attestation signed by the trusted key — say the SBOM of a benign hello-world image the same pipeline built last year — could attach it to a malicious image, and the policy would pass: the signature verifies, the predicate type matches, and nobody asked *what artifact this describes*. The engine must assert `subject[].digest == <digest of the image being admitted>`. cosign does this in `verify-attestation` (it looks up attestations under `sha256-<digest>.att` and checks the subject), which is why you must verify by digest and why the digest resolution must be atomic with the check (Q5.1).

**Q6.3** — *For a different key:* it separates the roles of "who built this artifact" and "who asserts things about it". A scanner produces vuln attestations continuously and must hold a key with a very different lifecycle and blast radius from the release-signing key; if the scanner's key leaks, the attacker can forge scan results but not release artifacts. It also lets you require **independent** attestations from separate systems (Q5.6), which is a genuine two-party control rather than one key wearing two hats. *Against:* more keys is more key management, more rotation, more places to leak, and more policy surface — a small team is more likely to get one key right than four. *SLSA:* the separation supports **Build L2 and above**, which require provenance generated and signed by the *build service* rather than by the person or process supplying the source — and **L3**, which additionally requires the build platform to prevent the build itself from influencing the provenance or accessing the signing material. A single key held by the build script is structurally incompatible with L3. See [slsa.dev/spec/v1.0/levels](https://slsa.dev/spec/v1.0/levels).

**Q6.4** — The SBOM attestation is a **point-in-time inventory of what is inside the artifact**, and that inventory does not change when a CVE is published — the image still contains `openssl 3.0.11` whether or not the world knows it is vulnerable. That is precisely its value: when CVE-2026-XXXX drops, you query every SBOM attestation in the fleet and answer "which of my 400 images contain the affected package and version" in seconds, without re-scanning anything. It is an *asset* record. The **vuln attestation** is a *judgement* record, and judgements decay: it says "as of the vulnerability database of 2026-08-04, this image had zero criticals". Two weeks later that statement is still true and completely useless. In policy, an SBOM attestation can be required to exist and be well-formed indefinitely; a vuln attestation must be required to be **fresh** (predicate `scanFinishedOn` within N days) or it is security theatre.

**Q6.5** — *Objection 1 — it enforces the wrong thing.* Admission runs at Pod creation, which for a long-lived Deployment may be months after the image was built. Enforcing "zero criticals as of build time" blocks nothing that matters and blocks plenty that does not; meanwhile the images already running, which have accumulated real CVEs, are untouched because admission never re-evaluates them. *Objection 2 — it makes availability depend on an external vulnerability feed.* A new critical CVE in glibc will, overnight, make every image in the fleet fail admission. Nodes reboot, Pods reschedule, and the cluster cannot bring workloads back — a vulnerability database update becomes a cluster-wide outage, and the pressure to bypass the control (Q8.3) becomes irresistible. *Design instead:* enforce vulnerability policy in **CI**, where a failed build blocks a release and nothing in production is at risk; at admission, require only that a *fresh, signed* vuln attestation **exists** (proving the artifact went through the scanner) without gating on its contents; and run **continuous** scanning against the SBOM inventory for images already deployed, feeding a remediation SLA rather than an admission denial.

### Block 7 — Node-level defense

**Q7.1** — *Only containerd stops:* an attacker with root on a node, or with the ability to write `/etc/kubernetes/manifests`, creates a **static Pod** pulling `docker.io/attacker/miner:latest`. No admission controller ever sees the request — the kubelet pulls directly. The containerd `_default` deny makes the pull fail. Same for a direct `crictl pull`, or a compromised kubelet. *Only admission catches:* a developer commits a Deployment referencing `quay.io/somevendor/tool:v3` to the GitOps repo. containerd would happily pull it if `quay.io` were in `certs.d` and would fail obscurely as `ImagePullBackOff` if not — but the *admission* layer rejects it at `kubectl apply` with a message naming the policy and the permitted registries, so the developer learns what is wrong in seconds instead of debugging a node. *Neither is sufficient:* admission is bypassable by anything that does not go through the API server; containerd enforcement is per-node configuration drift waiting to happen, gives terrible diagnostics, and cannot express anything richer than a host allowlist (no signatures, no namespace scoping, no identity).

**Q7.2** — *Hazard:* the `_default` deny is node-local file configuration, not cluster state. A node rebuilt from an older image, added by a different automation path, or provisioned before the change simply does not have it — and there is no cluster-level object that says so. You get a silent, partial control: 9 nodes enforce, 1 does not, and the attacker's workload lands on the tenth. The mirror hazard is the opposite failure: a node that *does* have `_default` but is missing a `certs.d` entry for a legitimate registry fails every pull from it with a confusing `connection refused`, and if that registry serves the CNI image, the node never becomes Ready. *Detection:* (1) manage `certs.d` with the same configuration management that provisions the node and alert on drift; (2) run a DaemonSet that reads `/etc/containerd/certs.d` from a hostPath and reports the node's registry configuration as a metric/annotation, then alert on any node whose configuration differs from the fleet; (3) a synthetic canary Job per node that attempts a pull from a known-blocked registry and reports success as a failure.

**Q7.3** — Chain: the attacker `exec`s into a Pod in `app` → reads the mounted ServiceAccount token at `/var/run/secrets/kubernetes.io/serviceaccount/token` → if that SA has `get secrets` in the namespace (or the Pod already has `regcred` projected as a volume/env), reads the `dockerconfigjson` → the credential grants **push**, so they push a malicious layer to `registry.internal:5000/prod/nginx` and repoint the `1.27` tag → every node that pulls fresh, and every rescheduled Pod, runs their code with production's identity. *Two controls that break the chain:* (1) **Split credentials by verb.** The cluster only ever needs **pull**; push belongs exclusively to CI. A pull-only robot account in the cluster makes the stolen credential useless for the attack. (2) **Signature enforcement at admission** (Exercise 5) — even with push access, the attacker cannot produce a signature verifying against your key, so the repointed tag is rejected and the compromise degrades to a DoS (Q4.5). Supporting controls: least-privilege ServiceAccounts (`automountServiceAccountToken: false`), registry-side tag immutability, and per-namespace credential scoping.

**Q7.4** — The **ServiceAccount** one is harder to audit, for two reasons: it is *invisible in the Pod manifest* — nothing in the Deployment YAML tells a reviewer that a registry credential is being injected — and it is *transitive*, applying to every current and future Pod using that SA, including ones created by controllers nobody reviewed. A Pod-level `imagePullSecrets` is at least declared where it is used. The namespace-scoped attacker with `create pods` gets the **ServiceAccount** one for free: they simply create a Pod with `serviceAccountName: <the-one-with-the-secret>` and the kubelet fetches the credential on their behalf — they never need `get secrets` at all, and their Pod can be crafted so the pull happens against a registry they control, capturing the credential in the `Authorization` header. This is why `imagePullSecrets` on the `default` ServiceAccount is a genuine finding, not a nitpick.

**Q7.5** — *Rotation:* the credential provider mints a fresh token per pull (cached ≤12 h) with no human in the loop; a static Secret rotates only when someone remembers, which in practice means never — audit any cluster and you will find `dockerconfigjson` Secrets years old. *Scope:* the provider's credential is derived from the **node's** cloud identity and is constrained by `matchImages` to specific registry patterns and typically to read-only ECR/GCR/ACR access; a static Secret is a bearer credential with whatever permissions were granted at creation, usable from anywhere on the internet by anyone who obtains it. *Exfiltration value:* a stolen provider token is worth at most 12 hours of pull access from a context that can already pull; a stolen `dockerconfigjson` is a durable, portable, often push-capable credential that an attacker can use from their own laptop months later. The provider also never places the credential in etcd or in a Pod's filesystem, removing the entire class of attack in Q7.3. See [kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/).

### Block 8 — Failure modes

**Q8.1** — (1) `crictl ps -a --name kube-apiserver --latest` — tells you whether a container exists at all and its state/restart count. `Exited` with an incrementing `ATTEMPT` means the process starts and dies (config error); *no container* means the kubelet is not even creating it (manifest parse error or kubelet down). (2) `crictl logs <id>` — gives the actual error string from the API server, which for admission problems names the file or plugin. This is the one that usually solves it. (3) `journalctl -u kubelet -n 50 --no-pager` — tells you what you cannot learn from the container, because if step (1) found no container the failure is *above* it: invalid YAML in `/etc/kubernetes/manifests/kube-apiserver.yaml`, a `hostPath` that does not exist with `type: Directory`, or an image pull failure. Each step answers a question the previous one could not: does the container exist → why did the process die → why was the container never created.

**Q8.2** — `Forbidden` is HTTP **403**: a policy evaluated successfully and its verdict was *no*. The request is well-formed, the system is healthy, and the answer is a deliberate denial — look at the **policy**. `InternalError` is HTTP **500**: the API server could not *complete* admission because a component it depends on failed — the webhook was unreachable, timed out, or returned garbage. The system is broken, no verdict was ever reached — look at the **infrastructure** (Endpoints, Pod readiness, network policy between API server and the webhook Service, certificate validity, timeout). The practical shortcut: 403 means read the message text, it names the policy; 500 means run `kubectl -n <ns> get endpoints <webhook-svc>` and work outwards from there.

**Q8.3** — Least to most dangerous:

1. **(a) `validationFailureAction: Audit`** — narrowest and most reversible. The policy still runs, still evaluates every image, and still writes `PolicyReport` entries, so you retain a complete record of exactly what was let through during the incident and can remediate afterwards. Nothing else changes.
2. **(c) Add the namespace to `exclude`** — scoped to one namespace, so the rest of the cluster stays enforced, but you lose *all* visibility for that namespace: no reports, no record of what ran. Worse than (a) because the evidence is gone, better than (b)/(d) because the blast radius is bounded.
3. **(b) Delete the ClusterPolicy** — cluster-wide loss of the control and of all reporting. Recovery requires re-applying the manifest, which is easy if it is in Git and impossible to remember if it was applied by hand. High risk of never being restored.
4. **(d) `failurePolicy: Ignore` on the webhook** — the most dangerous by far, and for a non-obvious reason: it does not just disable *this* policy, it disables **every Kyverno policy** in the cluster, including ones unrelated to images (pod security, resource limits, network policy defaults). It also fails **silently** — there is no denial, no report, no signal that anything is off — and it is the change most likely to be left in place forever because nothing ever complains. Never reach for it under time pressure.

**Q8.4** — Zero-risk key rotation, using only what is built above:

1. **Add before removing.** Extend the Kyverno policy's attestor block to accept *both* keys — a single `entries` list with two `keys` entries under `count: 1` (OR semantics, per Q5.6). Apply it and confirm every currently running image still verifies. Nothing can break, because the old key is still trusted.
2. **Inventory.** Run the loop from step 3 of this exercise across every image in every Pod *and* every pod template (Q1.4), producing the exact list of artifacts that need a new signature.
3. **Counter-sign in place.** For each digest on that list, `cosign sign --key <new-key>` **the existing digest** — signing does not rebuild or modify the image, it just adds another `.sig` artifact. No workload is touched, no Pod restarts, no rollout.
4. **Verify convergence.** Re-run the inventory loop using *only* the new public key. Do not proceed until it returns zero `UNSIGNED`. Include images referenced by scaled-to-zero Deployments and CronJobs that have not fired.
5. **Remove the old key** from the policy, and only then revoke it at the source (KMS disable, or add the compromised key's Rekor entries to a denial list if the rotation was due to compromise rather than routine expiry).
6. **Prove it.** Force a reschedule of a canary workload and confirm it admits. Keep the old key material archived (not active) so you can re-add it if step 4's inventory missed something.

The ordering is the whole answer: **trust the new key everywhere before you sign with it, and sign everything before you distrust the old one.** Reversing any two steps produces an outage.

**Q8.5** — With the control plane down: **VAP, ImagePolicyWebhook and Kyverno all stop enforcing**, because all three are API-server admission mechanisms and there is no API server to run them. But note *what that means* — with the API server down, no new Pods are created through the API either, so the absence of enforcement is mostly moot for API-driven workloads. What still happens is the dangerous part: **kubelets keep running, keep restarting containers, and keep starting static Pods from `/etc/kubernetes/manifests`** — entirely outside admission, control plane or not. The only control that survives is the **containerd registry allowlist**, because it is enforced by the runtime on the node itself. *What that tells you:* place the control you most need to be unbypassable at the **lowest layer that can enforce it**. Admission is where you get good policy expressiveness, good error messages and central management — so put your *primary* controls there — but understand that they are advisory with respect to anyone who holds root on a node. Node-level enforcement (containerd allowlist, immutable node images, read-only `/etc/kubernetes/manifests` with file integrity monitoring, and a runtime security agent such as Falco watching for unexpected image pulls) is what remains when the control plane is gone or an attacker is already inside it. Defense in depth here is not redundancy for its own sake — the two layers fail under genuinely different conditions.

</details>

---

## Official sources

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Admission Controllers Reference — ImagePolicyWebhook* — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Images* (pull policy, digests, imagePullSecrets) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Configure a kubelet image credential provider* — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/
- Kubernetes, *Security Checklist* — https://kubernetes.io/docs/concepts/security/security-checklist/
- Sigstore, *cosign documentation* — https://docs.sigstore.dev/ · https://github.com/sigstore/cosign
- in-toto, *Attestation Framework* — https://github.com/in-toto/attestation
- SLSA, *Security Levels v1.0* — https://slsa.dev/spec/v1.0/levels
- containerd, *Registry Configuration — hosts.toml* — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- Kyverno, *Verify Images* — https://kyverno.io/docs/writing-policies/verify-images/
- OPA Gatekeeper, *Policy Library* (`K8sAllowedRepos`) — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Anchore syft — https://github.com/anchore/syft · Trivy — https://trivy.dev/

> **Exam-strategy note.** The CKS environment only permits `kubernetes.io/docs`, `kubernetes.io/blog`, and a short list of project sites — Sigstore, Kyverno and Gatekeeper documentation are **not** among them. Under exam conditions, the reachable solutions for this competency are `ImagePolicyWebhook` (Exercise 3, fully documented at the kubernetes.io link above), `ValidatingAdmissionPolicy` (Exercise 2), and image inventory/digest work (Exercise 1). Practise Exercise 3 until you can edit `kube-apiserver.yaml` — plugin flag, config-file flag, **volume and volumeMount** — and get the API server healthy again in under four minutes without looking anything up.