# Topic 2.2 — Secure Service-to-Service Communication

**Certification:** CNPA (Cloud Native Platform Engineering Associate) · Exam version 2025-04-01
**Exam weight:** 4.0 · **Format:** guided, hands-on labs

> These labs build a **zero-trust** communication fabric between two workloads and then break, inspect and repair it. You will move up the stack deliberately: **workload identity** (who is calling) → **transport encryption / mTLS** (is the channel authenticated and confidential) → **L7 authorization** (is *this* caller allowed to do *this* operation) → **L3/L4 segmentation** (defense in depth) → **certificate lifecycle** → **diagnostics**. Each layer is independently bypassable; the platform's job is to compose them.

---

## Prerequisites & environment

You need a cluster where you control the CNI and can install a mesh. A local `kind` cluster is fine for most steps, but **kindnet (kind's default CNI) does not enforce `NetworkPolicy`** — Exercise 4 requires Calico or Cilium.

```bash
# 1. A 2-node kind cluster (disable the default CNI so we can install Calico)
cat <<'EOF' > kind-znt.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true      # we will install Calico for NetworkPolicy enforcement
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF
kind create cluster --name znt --config kind-znt.yaml

# 2. Calico (a NetworkPolicy-enforcing CNI)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=180s

# 3. Istio (sidecar/demo profile) + istioctl on PATH
istioctl install --set profile=demo -y
istioctl version
```

Expected `istioctl version` output (versions will vary):

```
client version: 1.22.1
control plane version: 1.22.1
data plane version: 1.22.1 (2 proxies)
```

> **Sources**
> - Istio security concepts — https://istio.io/latest/docs/concepts/security/
> - Kubernetes NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
> - SPIFFE overview — https://spiffe.io/docs/latest/spiffe-about/overview/
> - CNPA curriculum — https://github.com/cncf/curriculum

---

## Exercise 0 — Baseline: plaintext service-to-service traffic

**Goal:** deploy a client (`sleep`) and a server (`httpbin`) *without* a mesh and confirm the channel is unauthenticated and unencrypted. This is the state a zero-trust platform must eliminate.

1. Create the namespace and two workloads, each with its **own ServiceAccount** (identity starts at the ServiceAccount — never share one across workloads):

   ```bash
   kubectl create namespace secure-demo
   ```

   ```yaml
   # baseline.yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata: { name: sleep, namespace: secure-demo }
   ---
   apiVersion: v1
   kind: ServiceAccount
   metadata: { name: httpbin, namespace: secure-demo }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: httpbin, namespace: secure-demo, labels: { app: httpbin } }
   spec:
     replicas: 1
     selector: { matchLabels: { app: httpbin } }
     template:
       metadata: { labels: { app: httpbin } }
       spec:
         serviceAccountName: httpbin
         containers:
         - name: httpbin
           image: kennethreitz/httpbin
           ports: [ { containerPort: 80 } ]
   ---
   apiVersion: v1
   kind: Service
   metadata: { name: httpbin, namespace: secure-demo, labels: { app: httpbin } }
   spec:
     selector: { app: httpbin }
     ports: [ { name: http, port: 80, targetPort: 80 } ]
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: sleep, namespace: secure-demo, labels: { app: sleep } }
   spec:
     replicas: 1
     selector: { matchLabels: { app: sleep } }
     template:
       metadata: { labels: { app: sleep } }
       spec:
         serviceAccountName: sleep
         containers:
         - name: sleep
           image: curlimages/curl
           command: ["/bin/sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f baseline.yaml
   kubectl -n secure-demo rollout status deploy/httpbin deploy/sleep
   ```

2. Confirm the two pods talk in **plaintext**:

   ```bash
   kubectl -n secure-demo exec deploy/sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin/get
   ```

   Expected:

   ```
   200
   ```

3. Prove there is **no authentication and no encryption**. Echo the request headers the server received:

   ```bash
   kubectl -n secure-demo exec deploy/sleep -- curl -s http://httpbin/headers
   ```

   Expected (note: *no* client-certificate header, plain `http`):

   ```json
   {
     "headers": {
       "Accept": "*/*",
       "Host": "httpbin",
       "User-Agent": "curl/8.x.x"
     }
   }
   ```

**❓ Comprehension check — Exercise 0**

- **0.1** The server received a request and returned `200`. What did it actually *verify* about the caller's identity?
- **0.2** Two different ServiceAccounts were created even though nothing yet enforces identity. Why is "one ServiceAccount per workload" a prerequisite for everything that follows?
- **0.3** In this baseline, an attacker who lands *any* pod in the namespace (or on the pod network) can reach `httpbin`. Name the two distinct security properties that are missing on this channel.

---

## Exercise 1 — Workload identity: ServiceAccounts, projected tokens & SPIFFE IDs

**Goal:** understand the identity primitive the mesh will bind certificates to. In Kubernetes the workload's cryptographic identity derives from its **ServiceAccount**; in a SPIFFE-based mesh that becomes a **SPIFFE ID** encoded into an X.509 SVID.

1. Mint a short-lived, **audience-scoped** ServiceAccount token (the modern bound token — not a legacy forever-secret):

   ```bash
   kubectl -n secure-demo create token sleep --audience=httpbin --duration=1h > /tmp/sleep.jwt
   # Decode the payload (base64url of the middle segment)
   cut -d. -f2 /tmp/sleep.jwt | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
   ```

   Expected (abridged):

   ```json
   {
     "aud": ["httpbin"],
     "exp": 1712345678,
     "iss": "https://kubernetes.default.svc.cluster.local",
     "kubernetes.io": {
       "namespace": "secure-demo",
       "serviceaccount": { "name": "sleep", "uid": "…" }
     },
     "sub": "system:serviceaccount:secure-demo:sleep"
   }
   ```

2. Predict the **SPIFFE ID** the mesh will assign to each workload. Istio's default trust domain is `cluster.local`, and the SPIFFE ID template is `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`:

   ```bash
   echo "sleep    -> spiffe://cluster.local/ns/secure-demo/sa/sleep"
   echo "httpbin  -> spiffe://cluster.local/ns/secure-demo/sa/httpbin"
   ```

3. Inspect where an in-cluster caller would fetch the OIDC-style discovery for these tokens (the trust anchor for token verification):

   ```bash
   kubectl get --raw /.well-known/openid-configuration | jq '.issuer, .jwks_uri'
   ```

   Expected:

   ```json
   "https://kubernetes.default.svc.cluster.local"
   "https://kubernetes.default.svc.cluster.local/openid/v1/jwks"
   ```

**❓ Comprehension check — Exercise 1**

- **1.1** The token in step 1 has `"aud": ["httpbin"]` and a 1-hour `exp`. What two attacks does binding the audience *and* a short expiry mitigate, compared with a legacy non-expiring ServiceAccount secret?
- **1.2** Map the JWT claim(s) that will become the SPIFFE ID `spiffe://cluster.local/ns/secure-demo/sa/sleep`. Which claim carries the namespace, and which carries the ServiceAccount name?
- **1.3** SPIFFE separates *identity* from *credential*. In `spiffe://cluster.local/ns/secure-demo/sa/httpbin`, which part is the identity and what is the short-lived credential that actually proves it on the wire (introduced in Exercise 2)?
- **1.4** Two teams each deploy a `frontend` Deployment, one in namespace `team-a`, one in `team-b`, both using a ServiceAccount named `frontend`. Do they collide in identity? Justify using the SPIFFE ID template.

---

## Exercise 2 — Encrypt & authenticate the channel: mTLS with Istio

**Goal:** put both workloads in the mesh, turn on **STRICT mTLS**, and observe that (a) the channel is now encrypted and mutually authenticated, and (b) a non-mesh caller is rejected at the transport layer.

1. Enable sidecar injection and restart so both pods get an Envoy sidecar:

   ```bash
   kubectl label namespace secure-demo istio-injection=enabled --overwrite
   kubectl -n secure-demo rollout restart deploy/httpbin deploy/sleep
   kubectl -n secure-demo rollout status deploy/httpbin deploy/sleep
   kubectl -n secure-demo get pods
   ```

   Expected (`2/2` = app container + sidecar):

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-6c8b9f9c9d-abcde   2/2     Running   0          25s
   sleep-7d9f8c7b6a-fghij     2/2     Running   0          25s
   ```

2. Inspect the **X.509 SVID** Istio issued to the `sleep` sidecar — this is the credential that proves the SPIFFE ID from Exercise 1:

   ```bash
   POD=$(kubectl -n secure-demo get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$POD.secure-demo" -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -text \
     | grep -A1 "Subject Alternative Name"
   ```

   Expected — the SPIFFE ID is carried in the certificate's **SAN URI**:

   ```
   X509v3 Subject Alternative Name: critical
       URI:spiffe://cluster.local/ns/secure-demo/sa/sleep
   ```

3. Enforce **STRICT** mTLS for the whole namespace with a `PeerAuthentication`:

   ```yaml
   # strict-mtls.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: secure-demo
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f strict-mtls.yaml
   ```

4. Confirm the *effective* policy on the server workload (do not trust that "applied" == "effective" — mesh/namespace/workload policies layer):

   ```bash
   HB=$(kubectl -n secure-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   istioctl x describe pod "$HB.secure-demo" | sed -n '/PeerAuthentication/,/---/p'
   ```

   Expected:

   ```
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
   ```

5. Prove mutual authentication is happening. Echo headers again — the sidecar injects `X-Forwarded-Client-Cert` (XFCC) carrying the *verified caller's* SPIFFE ID:

   ```bash
   kubectl -n secure-demo exec deploy/sleep -c sleep -- curl -s http://httpbin/headers | jq '.headers["X-Forwarded-Client-Cert"]'
   ```

   Expected:

   ```
   "By=spiffe://cluster.local/ns/secure-demo/sa/httpbin;Hash=…;Subject=\"\";URI=spiffe://cluster.local/ns/secure-demo/sa/sleep"
   ```

6. Now attack it. Deploy a **non-mesh** pod (no sidecar) and try to reach `httpbin`:

   ```bash
   kubectl -n secure-demo run rogue --image=curlimages/curl \
     --annotations sidecar.istio.io/inject=false --restart=Never -- sleep infinity
   kubectl -n secure-demo wait --for=condition=Ready pod/rogue
   kubectl -n secure-demo exec rogue -- curl -s -m 5 http://httpbin/get ; echo "exit=$?"
   ```

   Expected — rejected at the **transport layer**, before any HTTP is processed:

   ```
   curl: (56) Recv failure: Connection reset by peer
   exit=56
   ```

**❓ Comprehension check — Exercise 2**

- **2.1** In step 5 the server saw the caller's SPIFFE ID in `X-Forwarded-Client-Cert`. Which side presented a certificate in mTLS, and how does this differ from ordinary "one-way" TLS (server-only cert)?
- **2.2** The `rogue` pod in step 6 was rejected with a TCP reset, *not* an HTTP `403`. Which component rejected it and at which layer? Why is that a stronger guarantee than an application-level `401/403`?
- **2.3** You applied `PeerAuthentication` mode `STRICT`. What behavior would `PERMISSIVE` mode have produced for the `rogue` pod, and why is `PERMISSIVE` the recommended *migration* mode but not a *destination* mode?
- **2.4** `PeerAuthentication` authenticated the peer, yet `sleep` can still call `httpbin`. What class of control is still missing — i.e., what does mTLS *not* decide?
- **2.5** Istio issued each sidecar a certificate automatically. Which control-plane component is the CA, and what did it validate before signing the `sleep` workload's SVID?

---

## Exercise 3 — Authorize the caller: L7 `AuthorizationPolicy`

**Goal:** move from "who are you" (authN) to "are you allowed to do this" (authZ). Establish **deny-by-default** and then grant the minimum: only `sleep` may `GET /get`.

1. Establish deny-by-default for the namespace. An `AuthorizationPolicy` with action `ALLOW` and **no rules** denies everything:

   ```yaml
   # deny-all.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-all
     namespace: secure-demo
   spec: {}          # ALLOW action, zero rules => all requests denied
   ```

   ```bash
   kubectl apply -f deny-all.yaml
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin/get
   ```

   Expected:

   ```
   403
   ```

   ```bash
   # Confirm it is Istio authz, not the app
   kubectl -n secure-demo exec deploy/sleep -c sleep -- curl -s http://httpbin/get
   ```

   ```
   RBAC: access denied
   ```

2. Grant least privilege — only the `sleep` **identity** (not its IP) may call `GET /get` on `httpbin`:

   ```yaml
   # allow-sleep.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-sleep-to-httpbin
     namespace: secure-demo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           principals: ["cluster.local/ns/secure-demo/sa/sleep"]
       to:
       - operation:
           methods: ["GET"]
           paths: ["/get"]
   ```

   ```bash
   kubectl apply -f allow-sleep.yaml
   ```

3. Verify the allow, and verify least privilege holds on the negative cases:

   ```bash
   # Allowed: sleep -> GET /get
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "GET /get      => %{http_code}\n" http://httpbin/get

   # Denied: same identity, different path (not in the allow-list)
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "GET /headers  => %{http_code}\n" http://httpbin/headers

   # Denied: same identity+path, wrong method
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "POST /get     => %{http_code}\n" -X POST http://httpbin/get
   ```

   Expected:

   ```
   GET /get      => 200
   GET /headers  => 403
   POST /get     => 403
   ```

4. Demonstrate that authorization is bound to **cryptographic identity**, not network location. The `principals` matcher requires a *verified* SPIFFE ID, which only exists when mTLS is present. (This is why Exercise 2's STRICT mTLS is a hard prerequisite for identity-based authz.)

**❓ Comprehension check — Exercise 3**

- **3.1** `spec: {}` denied everything, yet the action defaults to `ALLOW`. Explain the seemingly paradoxical rule that makes an empty `ALLOW` policy a deny-all.
- **3.2** In `allow-sleep.yaml` the matcher is `principals`, not `ipBlocks` or `namespaces`. Why is `principals` (SPIFFE-based) the correct choice for zero-trust, and what would break if you keyed on source IP instead?
- **3.3** The evaluation order in Istio authz is: `CUSTOM` → `DENY` → `ALLOW`. If you *also* applied a `DENY` policy that matched `GET /get` from `sleep`, would the request succeed? Why?
- **3.4** `AuthorizationPolicy` requires a verified `principal`. Trace *why* it silently fails (matches nothing / denies) if `PeerAuthentication` is `DISABLE` instead of `STRICT`.
- **3.5** A teammate proposes deleting `deny-all` and relying only on `allow-sleep-to-httpbin` to "keep it simple." What security property is lost the moment `deny-all` is removed?

---

## Exercise 4 — Defense in depth: L3/L4 segmentation with `NetworkPolicy`

**Goal:** the mesh authenticates and authorizes at L7 *inside* the pod's Envoy — but a compromised node, a misconfigured sidecar bypass, or a workload the mesh doesn't cover can still open raw sockets. Add a Kubernetes-native L3/L4 control that is enforced by the **CNI**, independent of the mesh.

1. Apply **default-deny ingress** for the namespace (nothing may connect to any pod unless explicitly allowed):

   ```yaml
   # default-deny.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: secure-demo
   spec:
     podSelector: {}          # selects all pods in the namespace
     policyTypes: [ Ingress ]
   ```

   ```bash
   kubectl apply -f default-deny.yaml
   # rogue (still running from Ex.2) can no longer even open the socket
   kubectl -n secure-demo exec rogue -- curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://httpbin/get ; echo "exit=$?"
   ```

   Expected — connection never establishes (dropped by CNI, times out):

   ```
   000
   exit=28
   ```

2. Allow only `sleep` pods to reach `httpbin` on port 80 (label-selected at L3/L4):

   ```yaml
   # allow-sleep-l4.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-sleep-to-httpbin-l4
     namespace: secure-demo
   spec:
     podSelector:
       matchLabels: { app: httpbin }
     policyTypes: [ Ingress ]
     ingress:
     - from:
       - podSelector:
           matchLabels: { app: sleep }
       ports:
       - protocol: TCP
         port: 80
   ```

   ```bash
   kubectl apply -f allow-sleep-l4.yaml
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "sleep -> httpbin:80 => %{http_code}\n" http://httpbin/get
   kubectl -n secure-demo exec rogue -- \
     curl -s -m 5 -o /dev/null -w "rogue -> httpbin:80 => %{http_code}\n" http://httpbin/get ; echo "exit=$?"
   ```

   Expected:

   ```
   sleep -> httpbin:80 => 200
   rogue -> httpbin:80 => 000
   exit=28
   ```

3. Reflect on the layering: `rogue` is now blocked **twice** — by mTLS/authz (L7, inside Envoy) *and* by `NetworkPolicy` (L3/L4, in the CNI). Removing either one still leaves a control standing.

**❓ Comprehension check — Exercise 4**

- **4.1** `NetworkPolicy` matched on `podSelector` (labels/IPs); `AuthorizationPolicy` matched on `principals` (SPIFFE IDs). State precisely which threat each one catches that the other cannot.
- **4.2** In step 1 the denied request returned `000`/exit `28` (timeout), whereas Istio authz returned `403`. Explain the observable difference and what it tells you about *where* the packet died.
- **4.3** Why did the labs insist on Calico/Cilium and `disableDefaultCNI` in the setup? What happens to every `NetworkPolicy` in this exercise on a cluster whose CNI does not implement the policy API?
- **4.4** A node is compromised and the attacker runs a process in the host network namespace that speaks raw TCP to `httpbin`'s pod IP. Which of the two controls (mesh authz vs. `NetworkPolicy`) still has a chance to stop it, and under what condition?
- **4.5** `NetworkPolicy` is **deny-by-default only once a policy selects the pod**. Explain why a namespace with *zero* NetworkPolicies is fully open, and how `default-deny-ingress` changes that.

---

## Exercise 5 — Certificate lifecycle: issuance, rotation & root of trust

**Goal:** understand the credential supply chain behind Exercise 2. mTLS is only as strong as its CA and its rotation. You will observe short-lived workload certs, their automatic rotation, and how to replace Istio's self-signed root with a managed CA.

1. Inspect the **workload certificate lifetime** — Istio issues short-lived SVIDs (default 24h) and rotates them well before expiry:

   ```bash
   POD=$(kubectl -n secure-demo get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$POD.secure-demo" -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -dates -issuer
   ```

   Expected (note the ~24h validity window and the Istio CA issuer):

   ```
   notBefore=Aug  6 10:00:00 2026 GMT
   notAfter=Aug  7 10:00:00 2026 GMT
   issuer=O = cluster.local
   ```

2. Inspect the **root of trust** — the CA cert every sidecar validates peers against. By default this is `istiod`'s self-signed root, distributed as a ConfigMap:

   ```bash
   kubectl -n istio-system get configmap istio-ca-root-cert \
     -o jsonpath='{.data.root-cert\.pem}' | openssl x509 -noout -subject -dates
   ```

   Expected (a long-lived, self-signed root):

   ```
   subject=O = cluster.local
   notBefore=Aug  1 09:00:00 2026 GMT
   notAfter=Jul 30 09:00:00 2036 GMT
   ```

3. Observe **automatic rotation** without downtime: force a rotation by restarting the workload and confirm a *new* `notBefore` while the same SPIFFE ID persists:

   ```bash
   kubectl -n secure-demo rollout restart deploy/sleep
   kubectl -n secure-demo rollout status deploy/sleep
   POD=$(kubectl -n secure-demo get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$POD.secure-demo" -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -dates | head -1
   ```

   Expected — a fresh `notBefore` (the identity is unchanged; only the credential rotated):

   ```
   notBefore=Aug  6 10:42:11 2026 GMT
   ```

4. (Production pattern — read, do not necessarily run) Replace the self-signed root with an **externally managed CA** so the mesh's trust anchor is auditable and rotatable. Two common approaches:

   - **Plug-in intermediate CA:** create the `cacerts` secret in `istio-system` *before* installing istiod, so istiod signs workload certs from *your* intermediate under *your* root:

     ```bash
     kubectl create secret generic cacerts -n istio-system \
       --from-file=ca-cert.pem --from-file=ca-key.pem \
       --from-file=root-cert.pem --from-file=cert-chain.pem
     ```

   - **cert-manager `istio-csr`:** istiod delegates all workload CSRs to cert-manager, which signs them from an `Issuer`/`ClusterIssuer` (e.g. a Vault or a private PKI). The mesh CA becomes a first-class, policy-governed PKI object.

**❓ Comprehension check — Exercise 5**

- **5.1** Workload SVIDs live ~24h and rotate automatically; the root lives ~10 years. Explain why these two lifetimes are deliberately different, and what the blast radius is if each one leaks.
- **5.2** After the rollout in step 3, the certificate's `notBefore` changed but the SAN URI did not. Which one is the *identity* and which is the *credential*? Tie this back to Exercise 1's SPIFFE distinction.
- **5.3** In the default install, who holds the private key of the mesh root CA, and why is that a governance concern that the `cacerts` / `istio-csr` patterns in step 4 are designed to solve?
- **5.4** Why must the `cacerts` secret exist *before* istiod starts? What happens to already-issued workload certs and the trust bundle if you swap the root CA on a running mesh without a planned overlap of trust anchors?
- **5.5** Rotation is described as "no downtime." Mechanically, how does the sidecar pick up a new certificate without restarting the app container or dropping in-flight connections?

---

## Exercise 6 — Diagnostics: debugging a broken secure channel

**Goal:** build the reflexes to localize a failure across the four layers. You will inject a fault, then walk the standard triage path.

1. Inject a fault: mismatch the authorization principal so the caller is silently denied:

   ```bash
   kubectl -n secure-demo patch authorizationpolicy allow-sleep-to-httpbin \
     --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/from/0/source/principals/0","value":"cluster.local/ns/secure-demo/sa/nonexistent"}]'

   kubectl -n secure-demo exec deploy/sleep -c sleep -- curl -s http://httpbin/get
   ```

   Expected:

   ```
   RBAC: access denied
   ```

2. Triage top-down. **Is it authz or transport?** `RBAC: access denied` is an *authorization* verdict (L7) — the connection and mTLS succeeded, so skip the transport layer:

   ```bash
   HB=$(kubectl -n secure-demo get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   # Turn up Envoy RBAC logging on the SERVER sidecar and read the denial
   istioctl -n secure-demo proxy-config log "$HB" --level rbac:debug
   kubectl -n secure-demo logs "$HB" -c istio-proxy --tail=20 | grep -i rbac
   ```

   Expected (the log names the enforcing policy and the observed principal):

   ```
   [… rbac] enforced denied, matched policy none
   … shadow denied, matched policy ns[secure-demo]-policy[allow-sleep-to-httpbin]-rule[0]: false
   … observed principal: spiffe://cluster.local/ns/secure-demo/sa/sleep
   ```

3. **Confirm mTLS/identity are healthy** (rule out the layers below authz):

   ```bash
   POD=$(kubectl -n secure-demo get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
   istioctl x describe pod "$POD.secure-demo" | grep -Ei 'mTLS|PeerAuthentication'
   ```

   Expected:

   ```
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
   ```

4. **Root cause and fix:** observed principal is `…/sa/sleep`, policy expects `…/sa/nonexistent` → mismatch. Restore:

   ```bash
   kubectl apply -f allow-sleep.yaml
   kubectl -n secure-demo exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin/get
   ```

   Expected:

   ```
   200
   ```

5. Learn the **error-signature table** — each layer fails with a distinct fingerprint:

   | Symptom | Failing layer | First command to run |
   |---|---|---|
   | `curl: (56) Recv failure: Connection reset` from a **meshed** peer | mTLS handshake (mode/cert mismatch) | `istioctl x describe pod`, `istioctl proxy-config secret` |
   | `curl` **timeout** / `000` / exit `28` | L3/L4 — CNI `NetworkPolicy` dropped it | `kubectl get networkpolicy`, `kubectl describe netpol` |
   | HTTP `403` + body `RBAC: access denied` | L7 `AuthorizationPolicy` | `proxy-config log …rbac:debug`, read istio-proxy logs |
   | HTTP `401`/`403` from the **app** (no `RBAC:` body) | application-level auth, not mesh | app logs |
   | Meshed peer works, non-mesh peer reset | STRICT mTLS working as intended | none — expected |

**❓ Comprehension check — Exercise 6**

- **6.1** You get `curl: (56) Connection reset` between two *meshed* pods. Using the table, list the top two hypotheses and the single command that best distinguishes them.
- **6.2** Why is a `403` with body `RBAC: access denied` diagnostically valuable? Specifically, which two lower layers does it *prove* are already working?
- **6.3** A request from a meshed `sleep` to `httpbin` **times out** (exit 28), not `403`. Which control is the prime suspect, and why is it *not* the `AuthorizationPolicy`?
- **6.4** Envoy logged both `enforced denied` and a `shadow` line. What is the purpose of a *shadow* (dry-run) authorization policy, and how would you use it to roll out a stricter policy safely?
- **6.5** Order the four layers from the one that fails *earliest* in the connection lifecycle to the one that fails *latest*, and give the observable signature of each.

---

## ✅ Answers

<details>
<summary><strong>Click to reveal all answers</strong></summary>

### Exercise 0

- **0.1** Nothing. It verified only that a TCP/HTTP request arrived; there was no authentication of the caller's identity at all. `200` means "the server processed the request," not "the server trusts the caller."
- **0.2** Cryptographic identity (SPIFFE ID, mTLS cert) and identity-based authorization (`principals`) are derived from the **ServiceAccount**. If two workloads share a ServiceAccount they are indistinguishable to the mesh — you could never write a policy that allows one and denies the other. One SA per workload is the minimum granularity for least privilege.
- **0.3** (1) **Confidentiality/integrity** — traffic is plaintext, so it can be sniffed or tampered on the pod network. (2) **Peer authentication** — neither side proves who it is, so any pod can impersonate a client and the "server" could be a spoof.

### Exercise 1

- **1.1** Binding `aud` prevents a **token-replay / confused-deputy** attack: a token minted for `httpbin` is rejected by any other audience, so a leaked token can't be reused against a different service. The short `exp` bounds the **exposure window** if the token leaks — a legacy non-expiring SA secret is a permanent credential that must be manually revoked. (Legacy secrets are also stored at rest indefinitely; bound tokens are projected, short-lived, and auto-rotated.)
- **1.2** `kubernetes.io.namespace` = `secure-demo` → `/ns/secure-demo`; `kubernetes.io.serviceaccount.name` = `sleep` → `/sa/sleep`. (`sub: system:serviceaccount:secure-demo:sleep` encodes both.) The trust domain `cluster.local` comes from the mesh config, not the token.
- **1.3** The **identity** is the SPIFFE ID string `spiffe://cluster.local/ns/secure-demo/sa/httpbin` (stable, human-meaningful). The **credential** is the short-lived X.509 **SVID** whose SAN URI equals that SPIFFE ID — the thing actually presented and verified during the mTLS handshake.
- **1.4** No collision. The SPIFFE ID template includes the namespace: `spiffe://cluster.local/ns/team-a/sa/frontend` ≠ `spiffe://cluster.local/ns/team-b/sa/frontend`. Namespace is part of the identity, so identically-named SAs in different namespaces are distinct principals.

### Exercise 2

- **2.1** In mTLS **both** peers present a certificate: the server presents its SVID (as in one-way TLS) *and* the client presents its SVID, which the server validates against the trust root. One-way TLS authenticates only the server, so the server never cryptographically knows who the client is. The XFCC header exists precisely because the client's cert was verified.
- **2.2** The **server's Envoy sidecar** rejected it at the **TLS/transport layer** — the `rogue` pod sent plaintext into a port expecting a TLS ClientHello, so the handshake failed and the socket was reset. This is stronger than an app-level `403` because the request never reached the application at all; there is no HTTP surface, no parsing, and no app logic an attacker could exploit — the workload is invisible to unauthenticated peers.
- **2.3** In `PERMISSIVE` mode the sidecar accepts *both* mTLS and plaintext, so `rogue` would have gotten `200`. `PERMISSIVE` is the correct **migration** mode because it lets meshed and not-yet-meshed workloads coexist during rollout without an outage. It is not a **destination** because it leaves a plaintext bypass open — an attacker just speaks plaintext to skip authentication. You migrate through `PERMISSIVE`, then lock to `STRICT`.
- **2.4** **Authorization.** mTLS decides *whether the peer is authenticated and who it is*; it does not decide *whether that authenticated peer is allowed to perform this specific operation*. `sleep` can reach `httpbin` because no `AuthorizationPolicy` yet restricts it (default-allow). That gap is closed in Exercise 3.
- **2.5** `istiod` (the Istio control plane, via its embedded CA — "Citadel" function). Before signing, it validates the workload's identity by verifying the ServiceAccount token the node's `istio-agent` presents with the CSR (checked against the Kubernetes TokenReview API), then issues an SVID whose SAN URI is the corresponding SPIFFE ID.

### Exercise 3

- **3.1** Istio authz is default-allow **only when no `ALLOW` policy applies to a workload**. The moment *any* `ALLOW` policy selects a workload, the workload switches to deny-by-default and *only* requests matching a rule are permitted. `spec: {}` creates an `ALLOW` policy (action defaults to ALLOW) with an empty rule set — it selects everything and matches nothing, so everything is denied.
- **3.2** `principals` matches the cryptographically **verified SPIFFE ID** from the mTLS handshake, which cannot be forged without the peer's private key. Source IP is spoofable, is reused across pods via NAT/SNAT, and churns on every reschedule — an attacker landing on any pod would inherit the "trusted" IP range. Keying on IP would authorize *location* instead of *identity*, defeating zero-trust.
- **3.3** No — it would be **denied**. Istio evaluates `CUSTOM` → `DENY` → `ALLOW`. A `DENY` match short-circuits before `ALLOW` is ever considered, so an explicit deny always wins over an allow. (Precedence: DENY > ALLOW.)
- **3.4** With `PeerAuthentication: DISABLE`, connections are plaintext, so there is **no peer certificate and therefore no verified `principal`**. A `principals` matcher can only match a present, verified identity; with none, the rule matches nothing, and under deny-by-default the request is denied. Identity-based authz *requires* mTLS to supply the identity — that's why Exercise 2 is a hard prerequisite.
- **3.5** **Deny-by-default (fail-closed)** for anything the allow-list doesn't cover. Without `deny-all`, `httpbin` still has an `ALLOW` policy selecting it (`allow-sleep-to-httpbin`), so it actually *stays* deny-by-default for `httpbin` specifically — but any *other* workload in the namespace with no policy reverts to **default-allow**. `deny-all` guarantees the whole namespace fails closed regardless of which workloads have explicit policies. (Key nuance: default-deny applies per selected workload, so a namespace-wide deny-all is what makes the *whole* namespace fail-closed.)

### Exercise 4

- **4.1** `NetworkPolicy` catches **unauthorized network reachability** — it stops packets from ever reaching a pod based on L3/L4 identity (pod labels, IP blocks, ports), including from workloads the mesh doesn't cover or that bypass the sidecar. `AuthorizationPolicy` catches **unauthorized operations by an authenticated identity** — it can say "this verified SPIFFE ID may `GET /get` but not `POST`," which L3/L4 cannot express. NetworkPolicy can't see identity or HTTP verb/path; authz can't stop a raw socket that never reaches Envoy.
- **4.2** `403` means the packet reached the server's Envoy, completed mTLS, and was *rejected by policy* — the connection lived. `000`/timeout means the CNI dropped the packet in the kernel/dataplane before any connection was established — the client never got a response at all. The difference localizes the failure: `403` = L7 (inside the pod), timeout = L3/L4 (in the CNI, before the pod).
- **4.3** `NetworkPolicy` is only an API; enforcement is the CNI's job. kindnet (kind's default) does **not** implement it, so every policy is silently accepted and ignored — a dangerous false sense of security. Calico/Cilium actually program the dataplane. `disableDefaultCNI` + Calico ensures the policies in this lab are truly enforced.
- **4.4** **`NetworkPolicy`** still has a chance — it's enforced by the CNI/kernel independent of the sidecar, so a host-network process hitting the pod IP is dropped *if* a policy selects that pod and doesn't allow the source. The mesh authz cannot help here because a raw socket that bypasses Envoy never presents a verified identity (and if the attacker also bypasses the CNI on the node, only node-level controls remain — hence defense in depth, not a single control).
- **4.5** Kubernetes `NetworkPolicy` is **additive allow-list, default-allow until a policy selects a pod**. A namespace with zero policies leaves every pod fully reachable because no policy selects them. `default-deny-ingress` uses `podSelector: {}` to select *all* pods with an empty ingress rule set, flipping the whole namespace to deny-by-default; subsequent policies then punch specific allow holes.

### Exercise 5

- **5.1** Workload SVIDs are short-lived so a leaked workload key is useless within ~a day and rotation is routine/automatic — small blast radius, self-healing. The root is long-lived because rotating it means re-establishing trust across the *entire* mesh (a heavy, coordinated operation); its blast radius is catastrophic (a leaked root can mint *any* identity), so it is guarded far more tightly and touched rarely. Different lifetimes match different blast radii and rotation costs.
- **5.2** The SAN URI (`spiffe://…/sa/sleep`) is the **identity** — stable across rotations. The certificate (its keypair, `notBefore`/`notAfter`) is the **credential** — replaced on every rotation. This is exactly Exercise 1's SPIFFE ID (identity) vs. SVID (credential) distinction: the credential rotates continuously while the identity it asserts stays fixed.
- **5.3** In the default install, **`istiod` holds the root CA private key** (self-signed, in-cluster). That's a governance concern because the key controlling all mesh identity lives inside the workload cluster with no external audit, HSM, or separation of duties. The `cacerts` plug-in (istiod signs from *your* intermediate under an offline root) and `istio-csr` (cert-manager/Vault owns signing) move the trust anchor into managed, auditable, rotatable PKI.
- **5.4** istiod reads `cacerts` at startup to configure its signing CA; if it starts without it, it self-signs a root and begins issuing certs under that root. Every already-issued cert and the distributed trust bundle chain to whatever root was active. Swapping the root on a running mesh without an **overlapping trust bundle** (old + new roots trusted simultaneously during transition) invalidates all in-flight certs at once — peers can no longer validate each other and you get a mesh-wide mTLS outage. Root rotation must stage both roots in the trust bundle, roll workloads onto the new intermediate, then retire the old root.
- **5.5** The `istio-agent` (SDS server) inside each pod fetches/renews certs from istiod and pushes them to Envoy over the **Secret Discovery Service (SDS)** as dynamic secrets — Envoy hot-swaps the cert in memory without restarting. Existing connections keep their negotiated session; only new handshakes use the new cert. No app restart, no dropped connections.

### Exercise 6

- **6.1** Top hypotheses: (a) an mTLS **mode mismatch** (e.g., one side STRICT, the other DISABLE, or a stray `PeerAuthentication`/`DestinationRule` disagreeing), or (b) a **certificate/trust problem** (expired SVID, wrong trust root). Best single distinguisher: `istioctl x describe pod <server>` (and its counterpart on the client) to read the *effective* mTLS mode on both ends — a mode disagreement shows immediately; if modes agree, pivot to `istioctl proxy-config secret` to inspect cert validity.
- **6.2** `RBAC: access denied` proves that (1) **L3/L4 connectivity** succeeded (the packet reached the server's Envoy) and (2) **mTLS/identity** succeeded (Envoy has a verified principal to evaluate the RBAC rule against). The failure is purely at the authorization layer, so you can skip network and transport debugging entirely and go straight to the `AuthorizationPolicy`.
- **6.3** The prime suspect is **`NetworkPolicy` (L3/L4)** — a timeout/`000` means the packet was dropped before a connection formed. It is *not* the `AuthorizationPolicy`, because authz runs *inside* the server's Envoy and can only reject a connection that already established; its rejection is a fast HTTP `403`, never a timeout. (A DNS or Service/routing fault could also time out, but with a working name and a NetworkPolicy in play, the netpol is first suspect.)
- **6.4** A **shadow (dry-run)** policy is evaluated and logged but **not enforced** — it tells you what *would* happen without breaking traffic. You roll out a stricter policy by first deploying it in shadow/dry-run mode, watching the `shadow denied/allowed` logs (and metrics) to confirm it only denies what you intend, then promoting it to enforcing. This prevents a mis-scoped policy from causing an outage.
- **6.5** Earliest → latest: (1) **L3/L4 `NetworkPolicy`** — packet dropped by CNI before a connection; signature: **timeout / `000` / exit 28**. (2) **mTLS handshake** — connection opens but TLS fails; signature: **`curl (56) connection reset`** between meshed peers. (3) **L7 `AuthorizationPolicy`** — connection + mTLS succeed, request rejected by policy; signature: **HTTP `403` + body `RBAC: access denied`**. (4) **Application auth** — request reaches the app, app rejects; signature: **app-specific `401/403`, no `RBAC:` body**, visible only in app logs.

</details>