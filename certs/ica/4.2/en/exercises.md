# ICA — Topic 4.2: Configuring Authentication (mTLS, JWT)

## Guided Exercises

> **Scope.** Istio splits authentication into two independent planes: **peer authentication** (service-to-service, transport-level, driven by `PeerAuthentication` + mTLS certificates minted by `istiod`) and **request authentication** (end-user, application-level, driven by `RequestAuthentication` + JWT). This lab walks both, from `PERMISSIVE` default through `STRICT` mesh-wide enforcement, then layers JWT validation and shows how authentication and **authorization** interlock.
>
> **Prerequisites.** A Kubernetes cluster with Istio installed (`demo` or `default` profile), `istioctl` on `PATH`, and `kubectl` context pointing at the cluster. Confirm before starting:
>
> ```bash
> istioctl version
> ```
> ```text
> client version: 1.22.0
> control plane version: 1.22.0
> data plane version: 1.22.0 (4 proxies)
> ```
>
> Throughout, replace `release-1.22` in sample URLs with the tag matching **your** control-plane version.

---

### Block 0 — Build the test topology

We create three namespaces that isolate the three states a workload can be in: injected (`foo`, `bar`) and non-injected / no-sidecar (`legacy`). This is the canonical shape used to *prove* mTLS is actually happening — a client with no sidecar cannot speak Istio mTLS, so its success or failure tells you the server's real policy.

1. Create and label the namespaces:

   ```bash
   kubectl create namespace foo
   kubectl create namespace bar
   kubectl create namespace legacy
   kubectl label namespace foo    istio-injection=enabled
   kubectl label namespace bar    istio-injection=enabled
   # legacy is intentionally NOT labelled
   ```

2. Deploy `httpbin` (server) and `sleep` (client) into each namespace:

   ```bash
   for ns in foo bar legacy; do
     kubectl apply -n "$ns" -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/httpbin/httpbin.yaml
     kubectl apply -n "$ns" -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/sleep/sleep.yaml
   done
   ```

3. Confirm sidecar counts. Injected namespaces show `2/2` containers (app + `istio-proxy`); `legacy` shows `1/1`:

   ```bash
   kubectl get pod -n foo
   kubectl get pod -n legacy
   ```
   ```text
   # foo
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7f9d8c9c4d-5nq2t   2/2     Running   0          40s
   sleep-6d5c9b7f8-x7k2p      2/2     Running   0          40s
   # legacy
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7f9d8c9c4d-qz8mn   1/1     Running   0          40s
   sleep-6d5c9b7f8-l4v9r      1/1     Running   0          40s
   ```

4. Establish a baseline: with **no** `PeerAuthentication` applied, Istio's default is `PERMISSIVE`. Every client — sidecar or not — should reach every `httpbin`:

   ```bash
   for from in foo bar legacy; do
     for to in foo bar legacy; do
       code=$(kubectl exec "$(kubectl get pod -l app=sleep -n "$from" -o jsonpath='{.items[0].metadata.name}')" \
         -c sleep -n "$from" -- \
         curl -s -o /dev/null -w "%{http_code}" "http://httpbin.$to:8000/ip" 2>/dev/null)
       echo "sleep.$from -> httpbin.$to: $code"
     done
   done
   ```
   ```text
   sleep.foo -> httpbin.foo: 200
   sleep.foo -> httpbin.bar: 200
   sleep.foo -> httpbin.legacy: 200
   sleep.bar -> httpbin.foo: 200
   ...
   sleep.legacy -> httpbin.foo: 200
   sleep.legacy -> httpbin.legacy: 200
   ```

**Comprehension check — Block 0**
1. Why is a namespace *without* sidecar injection (`legacy`) essential to this experiment rather than just noise?
2. What is the mesh-wide default peer-authentication mode when no `PeerAuthentication` resource exists, and why did Istio choose that default instead of `STRICT`?
3. `sleep.legacy -> httpbin.foo` returned `200` even though `httpbin.foo` has a sidecar. What does that tell you about how a `PERMISSIVE` server treats plaintext?

---

### Block 1 — Inspect the identity and certificates behind mTLS

Before enforcing anything, look at *what* mTLS authenticates with: an X.509 SVID whose SAN encodes the SPIFFE identity `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`.

1. Dump the workload certificate that `istiod` issued to `httpbin.foo`:

   ```bash
   HTTPBIN_FOO=$(kubectl get pod -l app=httpbin -n foo -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$HTTPBIN_FOO" -n foo -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 --decode \
     | openssl x509 -noout -text
   ```
   ```text
   Certificate:
       Data:
           Version: 3 (0x2)
           Issuer: O = cluster.local
           Validity
               Not Before: ...
               Not After : ...   (≈24h later)
           Subject:
           X509v3 extensions:
               X509v3 Subject Alternative Name: critical
                   URI:spiffe://cluster.local/ns/foo/sa/httpbin
   ```

2. Note the short validity window (~24h by default) and that the `Subject` is empty — identity lives entirely in the SAN URI. Confirm the effective auth status Istio computes for the workload:

   ```bash
   istioctl experimental describe pod "$HTTPBIN_FOO" -n foo
   ```
   ```text
   Pod: httpbin-7f9d8c9c4d-5nq2t.foo
   ...
   Effective PeerAuthentication:
      Workload mTLS mode: PERMISSIVE
   ```

**Comprehension check — Block 1**
1. Decode the identity `spiffe://cluster.local/ns/foo/sa/httpbin`: which three pieces of Kubernetes metadata does it bind together, and which component signs it?
2. The certificate is valid for only ~24 hours. What operational property does this short lifetime buy you, and what mesh component is responsible for rotating it before expiry?
3. Two pods run under the *same* ServiceAccount in the same namespace. Can a `PeerAuthentication` or `AuthorizationPolicy` distinguish them by cryptographic identity? Why or why not?

---

### Block 2 — Enforce STRICT mTLS on one namespace

Now flip `foo` to `STRICT`. A `STRICT` server accepts **only** mTLS connections and rejects plaintext at L4 (TCP reset) — so `sleep.legacy` (no sidecar, plaintext) must break, while injected clients keep working.

1. Apply a namespace-scoped `PeerAuthentication`. A `PeerAuthentication` with **no** `selector` applies to the whole namespace it lives in:

   ```yaml
   # peerauth-foo-strict.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: foo
   spec:
     mtls:
       mode: STRICT
   ```
   ```bash
   kubectl apply -f peerauth-foo-strict.yaml
   ```

2. Re-run the reachability matrix from Block 0. Expect injected → `httpbin.foo` to stay `200`, but `sleep.legacy -> httpbin.foo` to fail:

   ```bash
   for from in foo bar legacy; do
     code=$(kubectl exec "$(kubectl get pod -l app=sleep -n "$from" -o jsonpath='{.items[0].metadata.name}')" \
       -c sleep -n "$from" -- \
       curl -s -o /dev/null -w "%{http_code}" "http://httpbin.foo:8000/ip" 2>/dev/null)
     echo "sleep.$from -> httpbin.foo: ${code:-FAILED}"
   done
   ```
   ```text
   sleep.foo -> httpbin.foo: 200
   sleep.bar -> httpbin.foo: 200
   sleep.legacy -> httpbin.foo: FAILED
   ```

3. Look at the actual failure from the plaintext client — it is a transport-level reset, not an HTTP status:

   ```bash
   SLEEP_LEGACY=$(kubectl get pod -l app=sleep -n legacy -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -sS "http://httpbin.foo:8000/ip"
   ```
   ```text
   curl: (56) Recv failure: Connection reset by peer
   command terminated with exit code 56
   ```

4. Confirm other namespaces are untouched — `httpbin.bar` still accepts the plaintext legacy client:

   ```bash
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.bar:8000/ip"
   ```
   ```text
   200
   ```

**Comprehension check — Block 2**
1. The `PeerAuthentication` is named `default`. Is that name *functionally* required for the namespace-wide effect, or is the scoping driven by something else? What actually determines that it applies to all of `foo`?
2. `sleep.legacy` got `curl: (56) Connection reset by peer`, not `403` or `401`. At which OSI layer was it rejected, and why is there no HTTP status code at all?
3. You have a mesh-wide `STRICT` rollout planned but some legacy clients still send plaintext. Which mode lets injected clients speak mTLS while plaintext keeps working during migration — and what is the danger of leaving it there permanently?

---

### Block 3 — Precedence: workload-level and port-level overrides

`PeerAuthentication` resolves by specificity: **workload-specific** (has a `selector`) overrides **namespace-wide** overrides **mesh-wide**. Within one resource, **`portLevelMtls`** overrides the top-level `mtls.mode` for named ports. Prove the hierarchy.

1. Keep `foo` at namespace `STRICT` (Block 2), but carve out `httpbin`'s port `8080` (the container port behind the `8000` service port) back to `PERMISSIVE` using a workload selector:

   ```yaml
   # peerauth-foo-httpbin-portoverride.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-port-override
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     mtls:
       mode: STRICT
     portLevelMtls:
       "8080":
         mode: PERMISSIVE
   ```
   ```bash
   kubectl apply -f peerauth-foo-httpbin-portoverride.yaml
   ```

   > `portLevelMtls` keys are the workload's **container ports** (`targetPort`), not the Service port. `httpbin` listens on container port `8080`; the Service exposes it as `8000`.

2. The plaintext legacy client can now reach `httpbin.foo` again, because the port it lands on is `PERMISSIVE`:

   ```bash
   kubectl exec "$SLEEP_LEGACY" -c sleep -n legacy -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip"
   ```
   ```text
   200
   ```

3. Ask Istio which policy *wins* for this workload:

   ```bash
   istioctl experimental describe pod "$HTTPBIN_FOO" -n foo
   ```
   ```text
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
      Port 8080  mTLS mode: PERMISSIVE
   ```

4. Clean up the override before moving on, so `foo` is uniformly `STRICT` again:

   ```bash
   kubectl delete peerauthentication httpbin-port-override -n foo
   ```

**Comprehension check — Block 3**
1. Order these from highest to lowest precedence: mesh-wide `PeerAuthentication`, namespace-wide `PeerAuthentication`, workload-selector `PeerAuthentication`, `portLevelMtls` entry.
2. The `portLevelMtls` key was `"8080"`, but clients connect to the Service on `8000`. Explain the mapping and why using the Service port here would silently do nothing.
3. A mesh-wide policy named `default` in the **root namespace** (`istio-system`) sets `STRICT`, and a namespace policy in `foo` sets `PERMISSIVE`. What is the effective mode for a workload in `foo`, and what makes the `istio-system` one "mesh-wide" rather than just another namespace policy?

---

### Block 4 — The client side: DestinationRule TLS mode

`PeerAuthentication` governs the **server**. The **client** sidecar decides how to *originate* the connection via a `DestinationRule` `trafficPolicy.tls.mode`. With auto-mTLS (default since 1.5) Istio picks `ISTIO_MUTUAL` automatically toward mTLS-capable servers — but you can misconfigure it, and this is a classic exam failure mode.

1. Force the client toward `httpbin.foo` to send **plaintext** with an explicit `DISABLE`, while the server is `STRICT`:

   ```yaml
   # dr-foo-disable.yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin-foo-disable-tls
     namespace: foo
   spec:
     host: httpbin.foo.svc.cluster.local
     trafficPolicy:
       tls:
         mode: DISABLE
   ```
   ```bash
   kubectl apply -f dr-foo-disable.yaml
   ```

2. Now an **injected** client fails, even though it has a sidecar — because the `DestinationRule` told the client to drop mTLS while the server demands it:

   ```bash
   SLEEP_BAR=$(kubectl get pod -l app=sleep -n bar -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_BAR" -c sleep -n bar -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip" || echo "FAILED (reset)"
   ```
   ```text
   000
   FAILED (reset)
   ```

3. Fix it by aligning the client to `ISTIO_MUTUAL` (or simply deleting the rule to let auto-mTLS take over):

   ```bash
   kubectl patch destinationrule httpbin-foo-disable-tls -n foo --type=merge \
     -p '{"spec":{"trafficPolicy":{"tls":{"mode":"ISTIO_MUTUAL"}}}}'
   kubectl exec "$SLEEP_BAR" -c sleep -n bar -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/ip"
   ```
   ```text
   200
   ```

4. Remove the `DestinationRule` — auto-mTLS makes it unnecessary:

   ```bash
   kubectl delete destinationrule httpbin-foo-disable-tls -n foo
   ```

**Comprehension check — Block 4**
1. In one sentence each, state whose behaviour `PeerAuthentication` controls versus whose `DestinationRule` `trafficPolicy.tls` controls.
2. What is the difference between `MUTUAL` and `ISTIO_MUTUAL` in a `DestinationRule`, and which one requires you to supply certificate file paths?
3. A `STRICT` server plus a client `DestinationRule` with `mode: DISABLE` produced a reset. Which of the two sides do you change to fix it if the security requirement is "traffic must be encrypted," and why is deleting the `DestinationRule` also a valid fix here?

---

### Block 5 — Request authentication with JWT

Switch planes: peer auth proves *which service* is calling; **request auth** proves *which end user*. `RequestAuthentication` tells the sidecar how to validate a JWT (issuer, JWKS). Crucially, on its own it does **not require** a token — it only rejects *invalid* ones.

1. Promote `httpbin.foo` to be reached through the ingress isn't needed; test in-mesh from `sleep`. First apply a `RequestAuthentication` accepting Istio's demo issuer:

   ```yaml
   # req-auth-foo.yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata:
     name: httpbin-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     jwtRules:
       - issuer: "testing@secure.istio.io"
         jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/jwks.json"
   ```
   ```bash
   kubectl apply -f req-auth-foo.yaml
   ```

2. Request with **no token** → still `200`, because `RequestAuthentication` alone does not mandate a token:

   ```bash
   SLEEP_FOO=$(kubectl get pod -l app=sleep -n foo -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

3. Request with a **deliberately malformed** token → `401`, because a *present* token must be valid:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer deadbeef.not.ajwt" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   401
   ```

4. Fetch Istio's valid demo token and send it → `200`:

   ```bash
   TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/demo.jwt)
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

**Comprehension check — Block 5**
1. Step 2 sent **no** token and got `200`; step 3 sent a **bad** token and got `401`. State the rule about `RequestAuthentication` that reconciles those two results.
2. What does `jwksUri` point at, and what would happen to token validation if that endpoint became unreachable at request time (assume the key set was never cached)?
3. Two other `jwtRules` fields — `audiences` and `forwardOriginalToken` — do what? Give one security reason you might set each.

---

### Block 6 — Require a JWT and authorize on claims

To actually *demand* a valid token you combine `RequestAuthentication` (validate) with an `AuthorizationPolicy` (require). The bridge is the **`requestPrincipal`**, formatted `<issuer>/<subject>`. Then we authorize on a specific JWT **claim**.

1. Require *any* authenticated principal. `requestPrincipals: ["*"]` means "the request must carry a validated JWT identity":

   ```yaml
   # authz-require-jwt.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-require-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
       - from:
           - source:
               requestPrincipals: ["*"]
   ```
   ```bash
   kubectl apply -f authz-require-jwt.yaml
   ```

2. Now **no token** flips from `200` to `403` (`RBAC: access denied`) — the request has no principal to satisfy the rule:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -w " -> %{http_code}\n" "http://httpbin.foo:8000/headers"
   ```
   ```text
   RBAC: access denied -> 403
   ```

3. With the valid demo token → `200` again:

   ```bash
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" \
     "http://httpbin.foo:8000/headers"
   ```
   ```text
   200
   ```

4. Tighten to a **claim** check. Replace the policy to require both a specific principal *and* membership in the `group1` group. Istio's `groups-scope.jwt` sample carries `groups: ["group1", "group2"]`:

   ```yaml
   # authz-require-claim.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-require-jwt
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
       - from:
           - source:
               requestPrincipals: ["testing@secure.istio.io/testing@secure.istio.io"]
         when:
           - key: request.auth.claims[groups]
             values: ["group1"]
   ```
   ```bash
   kubectl apply -f authz-require-claim.yaml
   ```

5. The plain `demo.jwt` has **no** `groups` claim → `403`; the `groups-scope.jwt` token → `200`:

   ```bash
   GROUPS_TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.22/security/tools/jwt/samples/groups-scope.jwt)

   # demo.jwt: valid signature, but missing the groups claim
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "demo.jwt   -> %{http_code}\n" \
     --header "Authorization: Bearer $TOKEN" "http://httpbin.foo:8000/headers"

   # groups-scope.jwt: carries groups=[group1, group2]
   kubectl exec "$SLEEP_FOO" -c sleep -n foo -- \
     curl -s -o /dev/null -w "groups.jwt -> %{http_code}\n" \
     --header "Authorization: Bearer $GROUPS_TOKEN" "http://httpbin.foo:8000/headers"
   ```
   ```text
   demo.jwt   -> 403
   groups.jwt -> 200
   ```

6. Tear down the topic's resources:

   ```bash
   kubectl delete requestauthentication httpbin-jwt -n foo
   kubectl delete authorizationpolicy httpbin-require-jwt -n foo
   kubectl delete peerauthentication default -n foo
   kubectl delete namespace foo bar legacy
   ```

**Comprehension check — Block 6**
1. Trace the two distinct rejections you produced: a **bad** token returned `401`, but a **missing** token (with the require-JWT policy) returned `403`. Which Istio object is responsible for each response, and why are the status codes different?
2. In step 5, `demo.jwt` had a perfectly valid signature yet was denied `403`. Distinguish "authentication succeeded" from "authorization succeeded" using this exact case.
3. If you applied **only** the `AuthorizationPolicy` with `requestPrincipals: ["*"]` but *forgot* the `RequestAuthentication`, what would happen to a request carrying a valid-looking token, and why?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 0
1. **`legacy` is the control group.** A pod with no sidecar can only ever send **plaintext** — it has no Envoy to originate Istio mTLS. So its ability (or inability) to reach a server is a *direct measurement* of whether that server truly demands mTLS. Injected-to-injected traffic can succeed for reasons unrelated to the server's policy (auto-mTLS, both sides encrypting regardless), so it can't by itself prove enforcement. The non-injected client removes that ambiguity.
2. The default is **`PERMISSIVE`**. Istio chose it so that installing the mesh or injecting sidecars into an existing application **does not break** plaintext traffic on day one. `STRICT` by default would sever every non-injected client the instant a sidecar appeared, making incremental adoption impossible. `PERMISSIVE` is explicitly a **migration** mode — a server accepts *both* mTLS and plaintext simultaneously.
3. A `PERMISSIVE` server **accepts plaintext as well as mTLS on the same port.** Envoy sniffs the connection: TLS handshake → treat as mTLS; otherwise → treat as plaintext. So the legacy plaintext client is accepted. That is exactly why `PERMISSIVE` is safe for migration but does **not** provide a security guarantee — an attacker can still connect in the clear.

### Block 1
1. The SPIFFE ID binds **trust domain** (`cluster.local`), **namespace** (`foo`), and **ServiceAccount** (`httpbin`) — i.e., `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`. It is signed by **`istiod`** (the mesh CA), which issues the workload's X.509 SVID after validating the pod's Kubernetes ServiceAccount token. Identity is Kubernetes-ServiceAccount-based, *not* per-pod.
2. Short lifetimes **shrink the blast radius of a leaked key** and remove the need for CRL/OCSP revocation infrastructure — a stolen cert is useless within a day. The **istio-agent** (pipe: agent ↔ istiod SDS) requests rotation and hot-reloads the new cert into Envoy via SDS well before expiry, with no pod restart.
3. **No.** Cryptographic identity is per-**ServiceAccount**, not per-pod. Two pods sharing a ServiceAccount present the *same* SPIFFE identity and the same certificate class, so no peer-authentication or `requestPrincipal`/`principal` rule can tell them apart. To distinguish them you must give them **different ServiceAccounts** (or authorize on other attributes like labels via other mechanisms).

### Block 2
1. The name `default` is **not** functionally required — a `PeerAuthentication` applies namespace-wide whenever it has **no `selector`**, regardless of its name. (`default` is merely the conventional name.) What makes it namespace-wide is the absence of a `selector`; what makes it apply to `foo` specifically is that it lives in namespace `foo`. *(The `default` name **is** special in exactly one place: the **root namespace**, where a selector-less policy becomes the mesh-wide default.)*
2. It was rejected at **L4 (transport)**. `STRICT` requires a TLS handshake; the plaintext bytes never complete one, so Envoy resets the TCP connection. There is **no HTTP status** because the request never became an HTTP exchange — the connection died below L7, hence `curl: (56) Connection reset by peer` rather than `401`/`403`.
3. **`PERMISSIVE`** — it accepts both mTLS (from injected clients) and plaintext (from legacy clients) on the same port, so you can inject sidecars incrementally. The danger of leaving it permanently is that it provides **no enforcement**: any plaintext client — including an attacker — is still accepted, so an unencrypted path remains open. The goal is to reach `STRICT` and stay there.

### Block 3
1. Highest → lowest: **`portLevelMtls` entry** > **workload-selector `PeerAuthentication`** > **namespace-wide `PeerAuthentication`** > **mesh-wide (root-namespace) `PeerAuthentication`**. More specific always wins.
2. `portLevelMtls` keys are the workload's **container/`targetPort`** (`8080` for `httpbin`), which is what Envoy actually binds and enforces on. The Service port `8000` is only a routing abstraction the client dials; it is not what the server-side policy matches. Keying on `8000` would match no listener and the override would **silently have no effect**, leaving the port at the inherited `STRICT`.
3. The effective mode is **`PERMISSIVE`** — the namespace policy in `foo` is *more specific* than the mesh-wide one and overrides it. The `istio-system` policy is "mesh-wide" (not merely namespace-scoped) because it lives in the **root namespace** (the Istio install namespace, configured as `meshConfig.rootNamespace`, default `istio-system`) **and** is selector-less; a selector-less `PeerAuthentication` there becomes the default for the entire mesh.

### Block 4
1. **`PeerAuthentication`** controls the **server** sidecar — whether it *requires/accepts* mTLS on inbound connections. **`DestinationRule` `trafficPolicy.tls`** controls the **client** sidecar — how it *originates* the outbound connection.
2. `MUTUAL` = classic mutual TLS where **you supply** the client cert/key/CA file paths (`clientCertificate`, `privateKey`, `caCertificates`) — used for TLS to non-Istio / external services. `ISTIO_MUTUAL` = mutual TLS using **Istio's auto-provisioned SVID certificates**; you supply **no paths** because istiod manages them. `MUTUAL` requires the file paths; `ISTIO_MUTUAL` does not.
3. If the requirement is "traffic must be encrypted," you **change the client side** — set the `DestinationRule` to `ISTIO_MUTUAL` (never weaken the `STRICT` server to `DISABLE`, which would drop encryption). **Deleting the `DestinationRule`** is equally valid because **auto-mTLS** then kicks in: Istio detects the server is mTLS-capable and originates `ISTIO_MUTUAL` automatically. The reset happened only because an explicit `DISABLE` *overrode* auto-mTLS on the client.

### Block 5
1. **`RequestAuthentication` validates tokens but does not require them.** A request with **no** token is left untouched (passes → `200`); a request **with** a token must present a *valid* one for a configured issuer, or it is rejected `401`. To *mandate* a token you need an `AuthorizationPolicy` (Block 6).
2. `jwksUri` points at the issuer's **JWKS** (JSON Web Key Set) — the public keys used to verify the JWT signature. If it were unreachable and the key set had never been fetched/cached, the sidecar could not verify signatures, so valid tokens would be **rejected `401`**. In practice Istio caches JWKS (and you can inline keys via `jwks:`) to survive transient outages; a permanently unreachable, never-cached `jwksUri` breaks all token validation for that rule.
3. **`audiences`** restricts accepted tokens to those whose `aud` claim matches your service — set it so a token minted for service A cannot be **replayed** against service B (audience confinement). **`forwardOriginalToken: true`** forwards the original `Authorization` bearer token to the upstream application (by default Istio may strip it after validation) — set it when the **backend needs the token** for its own claim inspection or downstream propagation.

### Block 6
1. The **`RequestAuthentication`** produced the **`401`** — a *present but invalid* token is an authentication failure at the request-auth layer. The **`AuthorizationPolicy`** produced the **`403 RBAC: access denied`** — the token was **absent**, so the request had no `requestPrincipal` to satisfy the `requestPrincipals: ["*"]` rule, and authorization denied it. `401` = "your credential is bad"; `403` = "you have no/insufficient credential for this policy." Different objects, different failure semantics.
2. **Authentication succeeded** for `demo.jwt`: the signature verified against the issuer's JWKS, so Istio established a valid `requestPrincipal` (`testing@secure.istio.io/testing@secure.istio.io`). **Authorization failed**: the policy additionally demanded `request.auth.claims[groups]` contain `group1`, and `demo.jwt` carries **no `groups` claim**, so the `when` condition was unmet → `403`. Proving identity (authn) is necessary but not sufficient; the policy's claim predicate (authz) is a separate gate.
3. With **only** the `AuthorizationPolicy` and **no** `RequestAuthentication`, Istio has **no configured issuer/JWKS to validate against**, so it never establishes a `requestPrincipal` from the bearer token. The `requestPrincipals: ["*"]` rule therefore matches **nothing**, and even a "valid-looking" token yields **`403`**. `RequestAuthentication` is what turns raw bytes in the `Authorization` header into an authenticated principal; without it there is no principal for authorization to allow.

</details>

---

### Sources

- Istio — *Authentication* (concepts: peer vs. request auth, mTLS, identity/SPIFFE): https://istio.io/latest/docs/concepts/security/#authentication
- Istio — *Mutual TLS Migration* task (foo/bar/legacy topology, PERMISSIVE→STRICT): https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — *Authentication Policy* task (PeerAuthentication, RequestAuthentication, JWT samples): https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Istio — *JWT-based authorization* / *Authorization for HTTP traffic* (requestPrincipals, claim conditions): https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
- API reference — `PeerAuthentication`: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- API reference — `RequestAuthentication`: https://istio.io/latest/docs/reference/config/security/request_authentication/
- API reference — `AuthorizationPolicy`: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- API reference — `DestinationRule` (`ClientTLSSettings` / TLS modes): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf