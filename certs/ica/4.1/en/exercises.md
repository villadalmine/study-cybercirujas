# Topic 4.1 — Configuring Authorization (Istio `AuthorizationPolicy`)

> **Scope.** This lab drives Istio's authorization subsystem end to end: the deny‑by‑default posture, ALLOW/DENY/CUSTOM/AUDIT actions, the `from`/`to`/`when` rule triple, source identity via mTLS principals, request‑level JWT claims, policy precedence, and the diagnostics you use when a policy does not behave as written. Every request is enforced in the sidecar by Envoy's `envoy.filters.http.rbac` filter — Istiod compiles your CRDs into that filter's config and pushes it via xDS. Understanding *where* enforcement happens is half of understanding *why* a rule matched or did not.
>
> **Reference sources (official):**
> - Authorization concept — https://istio.io/latest/docs/concepts/security/#authorization
> - `AuthorizationPolicy` API — https://istio.io/latest/reference/config/security/authorization-policy/
> - HTTP authorization task — https://istio.io/latest/docs/tasks/security/authorization/authz-http/
> - Deny action & precedence — https://istio.io/latest/docs/tasks/security/authorization/authz-deny/
> - JWT authorization — https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
> - External (CUSTOM) authorization — https://istio.io/latest/docs/tasks/security/authorization/authz-custom/
> - `AuthorizationPolicy` normative conditions — https://istio.io/latest/docs/reference/config/security/conditions/

---

## Exercise 0 — Build the test mesh

You need two namespaces so you can prove *cross‑namespace* identity behavior, and a strict‑mTLS baseline so that `principals` and `namespaces` matchers actually have a verified identity to match against. Adjust the Istio release tag in the JWKS/sample URLs to the version installed in your cluster (`istioctl version`).

1. Confirm Istio and `istioctl` are present:

   ```bash
   istioctl version
   kubectl -n istio-system get pods
   ```

2. Create two injected namespaces:

   ```bash
   kubectl create namespace foo
   kubectl label  namespace foo istio-injection=enabled
   kubectl create namespace bar
   kubectl label  namespace bar istio-injection=enabled
   ```

3. Deploy the server (`httpbin`, service port 8000) and a client in `foo`, and a second client in `bar`. The `curl` sample ships its own `ServiceAccount` named `curl`, which becomes your source identity:

   ```bash
   kubectl apply -f samples/httpbin/httpbin.yaml -n foo
   kubectl apply -f samples/curl/curl.yaml       -n foo
   kubectl apply -f samples/curl/curl.yaml       -n bar
   ```

4. Enforce strict mTLS in both namespaces so identities are cryptographically verified:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: foo
   spec:
     mtls:
       mode: STRICT
   ---
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: bar
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f peerauth.yaml
   ```

5. Define a reusable probe helper and confirm the baseline (no `AuthorizationPolicy` yet → **allow all**):

   ```bash
   FOO_CURL=$(kubectl get pod -l app=curl -n foo -o jsonpath='{.items[0].metadata.name}')
   BAR_CURL=$(kubectl get pod -l app=curl -n bar -o jsonpath='{.items[0].metadata.name}')

   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "from foo -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "from bar -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Expected:

   ```
   from foo -> 200
   from bar -> 200
   ```

> **Checkpoint questions**
> - **Q0.1** With zero `AuthorizationPolicy` objects in the mesh, both probes return `200`. Is that "allow‑all" behavior a property of the RBAC filter, or of Istiod's decision *not to install* an RBAC filter? Why does the distinction matter for latency and for the deny‑by‑default myth?
> - **Q0.2** Why is `PeerAuthentication: STRICT` a prerequisite before you rely on `source.principals` or `source.namespaces` in an `AuthorizationPolicy`? What identity would those matchers see for a plaintext request?

---

## Exercise 1 — Deny‑by‑default with an empty policy

An `AuthorizationPolicy` with an empty `spec` (`spec: {}`) is the canonical "allow‑nothing" object: it is an ALLOW policy with **no rules**, so nothing can ever match, so everything selected is denied.

1. Apply a namespace‑wide deny‑all in `foo` (no `selector` ⇒ every workload in `foo`):

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-nothing
     namespace: foo
   spec: {}
   ```

   ```bash
   kubectl apply -f allow-nothing.yaml
   ```

2. Re‑probe, and this time keep the body to see Envoy's rejection string:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -w "\nHTTP %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Expected:

   ```
   RBAC: access denied
   HTTP 403
   ```

3. Prove the deny is scoped to `foo` only — `httpbin` does not exist in `bar`, so instead confirm the *policy object* is not present there:

   ```bash
   kubectl get authorizationpolicy -A
   ```

   Expected (one row, in `foo`):

   ```
   NAMESPACE   NAME            AGE
   foo         allow-nothing   30s
   ```

> **Checkpoint questions**
> - **Q1.1** `spec: {}` denies everything, yet its `action` field defaults to `ALLOW`. Reconcile those two facts in one sentence.
> - **Q1.2** You want a *mesh‑wide* allow‑nothing, not just `foo`. Which namespace must the object live in, and what is that namespace called in Istio's model? What single field would you have to be careful **not** to set for it to apply mesh‑wide?
> - **Q1.3** A teammate writes `spec:` with the key present but the value literally empty/omitted in YAML. Is that the same as `spec: {}`? What would `kubectl apply` do, and does the resulting object still deny everything?

---

## Exercise 2 — Grant a narrow ALLOW (selector + `to` operation)

Now open a precise hole: allow only `GET` on `/ip` and `/headers` against `httpbin`, and nothing else. This introduces the `selector`, `action: ALLOW`, and the `to.operation` block.

1. Apply the workload‑scoped ALLOW:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-get
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - to:
       - operation:
           methods: ["GET"]
           paths: ["/ip", "/headers"]
   ```

   ```bash
   kubectl apply -f httpbin-get.yaml
   ```

2. Probe an allowed path, a disallowed path, and a disallowed method:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /ip      -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /get     -> %{http_code}\n" http://httpbin.foo:8000/get
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "POST /post    -> %{http_code}\n" -X POST http://httpbin.foo:8000/post
   ```

   Expected:

   ```
   GET /ip      -> 200
   GET /get     -> 403
   POST /post    -> 403
   ```

3. Note that `allow-nothing` from Exercise 1 is **still applied**. Both are ALLOW policies. Confirm you understand the union by deleting the deny‑all and re‑testing `/get`:

   ```bash
   kubectl delete authorizationpolicy allow-nothing -n foo
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "GET /get after delete -> %{http_code}\n" http://httpbin.foo:8000/get
   ```

   Expected (still denied — `httpbin-get` alone is now the *only* ALLOW policy selecting `httpbin`, so requests must match it):

   ```
   GET /get after delete -> 403
   ```

> **Checkpoint questions**
> - **Q2.1** After step 3 you *deleted* the deny‑all, yet `/get` is still `403`. Explain the rule: once **any** ALLOW policy selects a workload, what happens to requests that match none of that workload's ALLOW policies?
> - **Q2.2** Two ALLOW policies select the same `httpbin` — one permits `GET /ip`, the other permits `GET /headers`. Is the effective grant the **union** or the **intersection** of the two? What does that imply about accidentally widening access by adding a second ALLOW?
> - **Q2.3** `paths: ["/ip"]` is an exact match. How would you allow the whole `/api/*` subtree, and what is the documented caveat about path matching when the request first passes through a gateway that rewrites or normalizes the path?

---

## Exercise 3 — Source identity: `principals` and `namespaces`

Restrict access by *who* is calling. This is where Exercise 0's strict mTLS pays off: `principals` matches the peer's SPIFFE identity carried in the client certificate.

1. Replace the previous policy: allow `GET` only from the `foo/curl` service account:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-from-foo-curl
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           principals: ["cluster.local/ns/foo/sa/curl"]
       to:
       - operation:
           methods: ["GET"]
   ```

   ```bash
   kubectl delete authorizationpolicy httpbin-get -n foo
   kubectl apply  -f httpbin-from-foo-curl.yaml
   ```

2. Probe from both namespaces:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "foo/curl -> %{http_code}\n" http://httpbin.foo:8000/ip
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar/curl -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Expected:

   ```
   foo/curl -> 200
   bar/curl -> 403
   ```

3. Broaden to *any* workload in `bar` using a namespace matcher instead of an exact principal:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-from-bar-ns
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["bar"]
       to:
       - operation:
           methods: ["GET"]
   ```

   ```bash
   kubectl apply -f httpbin-from-bar-ns.yaml
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar/curl now -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Expected:

   ```
   bar/curl now -> 200
   ```

> **Checkpoint questions**
> - **Q3.1** Decompose the principal string `cluster.local/ns/foo/sa/curl`. Which trust domain, namespace, and identity does each segment encode, and where does that string physically travel on the wire?
> - **Q3.2** You switch the namespace `PeerAuthentication` for `foo` to `PERMISSIVE` and a plaintext client calls `httpbin`. What value do `source.principals` / `source.namespaces` evaluate to for that request, and will the `httpbin-from-foo-curl` policy admit it? Why is `PERMISSIVE` + principal rules a silent‑failure trap?
> - **Q3.3** Within a single `rule`, you have `from` (two sources) **and** `to` (one operation). Within one `source` you list two `principals`. State the AND/OR semantics: across `rules`, across entries in a list like `from`, and across values inside one `principals` list.

---

## Exercise 4 — Conditions with `when`

`when` adds arbitrary attribute matching on top of `from`/`to` using the normative condition keys (headers, source IP, JWT claims, ports…).

1. Require a shared‑secret header in addition to identity:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-header-gate
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["foo", "bar"]
       to:
       - operation:
           methods: ["GET"]
       when:
       - key: request.headers[x-team]
         values: ["platform"]
   ```

   ```bash
   kubectl delete authorizationpolicy httpbin-from-foo-curl httpbin-from-bar-ns -n foo
   kubectl apply  -f httpbin-header-gate.yaml
   ```

2. Probe without and with the header:

   ```bash
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "no header   -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "x-team: platform" \
     -w "with header -> %{http_code}\n" http://httpbin.foo:8000/headers
   ```

   Expected:

   ```
   no header   -> 403
   with header -> 200
   ```

> **Checkpoint questions**
> - **Q4.1** `request.headers[x-team]` is an L7 attribute. What must be true about the mTLS/protocol so this condition is even evaluable, and what happens to a `when` header condition attached to a policy that ends up matching a raw TCP (non‑HTTP) port?
> - **Q4.2** A header is trivially spoofable by any client that can reach the sidecar. Why is `when: request.headers[...]` acceptable as *defense in depth* but unacceptable as the *sole* gate, and which field in this same policy is the real, unspoofable identity control?
> - **Q4.3** You want "source IP in `10.0.0.0/8`". Which condition key expresses the *original* client IP versus the *directly connected* peer, and why do those differ behind a gateway or `X‑Forwarded‑For` chain?

---

## Exercise 5 — DENY action and policy precedence

DENY policies are evaluated **before** ALLOW policies. Use them for guardrails that must win regardless of what ALLOW rules a team later adds.

1. Keep the header gate from Exercise 4, then add a hard DENY on write methods coming from `bar`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-writes-from-bar
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: DENY
     rules:
     - from:
       - source:
           namespaces: ["bar"]
       to:
       - operation:
           methods: ["POST", "PUT", "DELETE"]
   ```

   ```bash
   kubectl apply -f deny-writes-from-bar.yaml
   ```

2. Also add a broad ALLOW that *would* permit those writes, to prove DENY wins:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-bar-everything
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           namespaces: ["bar"]
   ```

   ```bash
   kubectl apply -f allow-bar-everything.yaml
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar POST /post -> %{http_code}\n" -X POST http://httpbin.foo:8000/post
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null -w "bar GET  /ip   -> %{http_code}\n" http://httpbin.foo:8000/ip
   ```

   Expected:

   ```
   bar POST /post -> 403
   bar GET  /ip   -> 200
   ```

> **Checkpoint questions**
> - **Q5.1** State the full evaluation order of actions for a single request. Where do `CUSTOM` and `AUDIT` sit relative to `DENY` and `ALLOW`, and which action never influences the allow/deny outcome at all?
> - **Q5.2** In step 2 the ALLOW `allow-bar-everything` clearly permits `POST`, yet the `POST` is denied. Which policy won and why — and what does this tell you about who should own DENY guardrails versus per‑service ALLOW rules in a multi‑team mesh?
> - **Q5.3** A request from `bar` does a `GET /ip`. Walk it through DENY then ALLOW and explain precisely which policy's *absence of a match* and which policy's *match* combine to produce `200`.

---

## Exercise 6 — Request‑level auth: JWT claims

End‑user authorization is separate from workload identity. `RequestAuthentication` validates the JWT (issuer, signature via JWKS) but by itself only *rejects invalid* tokens — a request with **no** token still passes it. You need an `AuthorizationPolicy` on `requestPrincipals`/claims to *require* a token.

1. Register the JWT issuer (adjust the release tag to your installed version):

   ```yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata:
     name: jwt-testing
     namespace: foo
   spec:
     selector:
       matchLabels:
         app: httpbin
     jwtRules:
     - issuer: "testing@secure.istio.io"
       jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/jwks.json"
   ```

2. Require a valid token AND the `groups` claim to contain `group1`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: require-jwt-group
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
   # remove earlier ALLOW/DENY objects to isolate the JWT test
   kubectl delete authorizationpolicy httpbin-header-gate allow-bar-everything -n foo --ignore-not-found
   kubectl apply -f jwt-testing.yaml -f require-jwt-group.yaml
   ```

3. Fetch the two demo tokens and probe. `demo.jwt` carries `groups: [group1, group2]`; the plain token (`groups-scope`? use `demo.jwt` vs an invalid string):

   ```bash
   TOKEN=$(curl -s https://raw.githubusercontent.com/istio/istio/release-1.23/security/tools/jwt/samples/demo.jwt)

   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -w "no token    -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "Authorization: Bearer $TOKEN" \
     -w "valid token -> %{http_code}\n" http://httpbin.foo:8000/headers
   kubectl exec "$FOO_CURL" -c curl -n foo -- \
     curl -sS -o /dev/null -H "Authorization: Bearer bogus.token.value" \
     -w "bad token   -> %{http_code}\n" http://httpbin.foo:8000/headers
   ```

   Expected:

   ```
   no token    -> 403
   valid token -> 200
   bad token   -> 401
   ```

> **Checkpoint questions**
> - **Q6.1** Three outcomes appear: `401` for a bad token, `403` for no token, `200` for a good one. Which component produced the `401` and which produced the `403`? Why is "no token" a `403` here and not a `401`?
> - **Q6.2** If you delete `require-jwt-group` but keep `RequestAuthentication`, what happens to (a) a request with a **valid** token, (b) a request with an **invalid** token, and (c) a request with **no** token? State the exact rule this demonstrates.
> - **Q6.3** `requestPrincipals` is written `<issuer>/<subject>`. How does that differ conceptually from the `principals` you used in Exercise 3, and can a single policy rule legitimately require *both* a workload principal and a request principal at once?

---

## Exercise 7 — Diagnose it: why did a request match (or not)?

When a policy misbehaves, do not guess — inspect the compiled config and the enforcement logs.

1. List every policy affecting a specific pod, resolved by Istiod's own logic:

   ```bash
   istioctl experimental authz check "$FOO_CURL.foo"
   ```

   You get a table of ACTION / policy name / matched workload — this is the authoritative "what applies here", including policies inherited from the root namespace.

2. Inspect the actual RBAC filter Envoy is running (proves what got pushed, not what you *think* you applied):

   ```bash
   HTTPBIN=$(kubectl get pod -l app=httpbin -n foo -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config listener "$HTTPBIN.foo" -o json \
     | grep -A3 -i '"name": "envoy.filters.http.rbac"' | head -n 20
   ```

3. Turn on RBAC debug logging and watch a denied request being enforced:

   ```bash
   istioctl proxy-config log "$HTTPBIN.foo" --level rbac:debug
   kubectl exec "$BAR_CURL" -c curl -n bar -- \
     curl -sS -o /dev/null http://httpbin.foo:8000/ip || true
   kubectl logs "$HTTPBIN" -n foo -c istio-proxy --tail=20 | grep -i rbac
   ```

   You should see an `enforced denied` (or `shadow`) line naming the matched policy and rule.

> **Checkpoint questions**
> - **Q7.1** `istioctl experimental authz check` reads Envoy's config, while `kubectl get authorizationpolicy` reads the desired state in `etcd`. Name one failure mode that only the *former* can reveal.
> - **Q7.2** In the RBAC access log you see the strings `rbac_access_policy` versus `rbac_access_shadow_policy`. What does a `shadow` decision mean, which `action` produces it, and how would you use it to roll out a new DENY safely?
> - **Q7.3** A policy in `foo` "does nothing" — the request is neither newly allowed nor denied. Give two concrete misconfigurations (one in `selector`, one in `apiVersion`/`namespace`) that make an `AuthorizationPolicy` silently apply to *no* workload, and how each shows up in `authz check`.

---

## Cleanup

```bash
kubectl delete namespace foo bar
```

---

<details>
<summary><strong>Answers &amp; explanations</strong></summary>

**Q0.1** It is Istiod *not installing* the RBAC filter. When no `AuthorizationPolicy` selects a workload, Istiod omits `envoy.filters.http.rbac` from that proxy's config entirely, so there is zero per‑request RBAC evaluation and zero added latency — traffic is allowed simply because nothing inspects it. Istio is therefore **not** deny‑by‑default at the mesh level; you *opt in* to deny‑by‑default by installing an allow‑nothing policy (Exercise 1). The distinction matters because "no policy = open" surprises people who assume a service mesh is closed until told otherwise.

**Q0.2** `principals`/`namespaces` are derived from the peer's verified mTLS client certificate (its SPIFFE identity). Without STRICT mTLS a plaintext request presents **no** certificate, so `source.principal`/`source.namespace` are empty and can never match a non‑empty matcher — the request is denied (if an ALLOW selects the workload) for the wrong reason, or, under PERMISSIVE, quietly bypasses identity checks. STRICT guarantees every request carries a cryptographic identity to match.

**Q1.1** An empty `spec` is an ALLOW policy (the default action) that contains **no rules**; with no rule to match, no request is ever permitted, so the workload is fully denied — deny by absence of any allow.

**Q1.2** It must live in the **root namespace** (by default `istio-system`), which Istio treats as the mesh‑wide policy scope. To apply mesh‑wide you must **not** set a `selector` (a selector would restrict it to matching workloads *in the root namespace only*, not the mesh). An unselected policy in the root namespace applies to every workload in every namespace.

**Q1.3** YAML `spec:` with an omitted value parses to `null`, not `{}`. `kubectl apply` sends `spec: null`; the API server defaults it, and the resulting object still behaves as an empty‑rule ALLOW (deny‑all) — but relying on `null`‑defaulting is fragile; write `spec: {}` explicitly so intent is unambiguous.

**Q2.1** The moment **any** ALLOW policy selects a workload, that workload flips to deny‑by‑default *for the attributes those policies govern*: every request must match at least one rule of at least one ALLOW policy, or it is denied. Deleting `allow-nothing` did not open `/get`, because `httpbin-get` (which does not list `/get`) is still an ALLOW selecting `httpbin`, so `/get` matches nothing and is denied.

**Q2.2** **Union.** Multiple ALLOW policies (and multiple rules within one) are OR‑combined — a request is permitted if it matches any rule of any ALLOW policy. Consequently adding a second ALLOW can only *widen* access, never narrow it; you cannot tighten by piling on ALLOWs — you tighten with DENY or by removing rules.

**Q2.3** Use a prefix: `paths: ["/api/*"]` (Istio supports `*` prefix/suffix wildcards). Caveat: path matching operates on the path Envoy sees. If a gateway rewrites or if path normalization differs, `/api/../admin` style inputs or double‑encoding can defeat naive prefix rules — Istio documents enabling path normalization and warns that exact‑ vs prefix‑matching interacts with gateway rewrites, so author policies against the *post‑normalization* path.

**Q3.1** `cluster.local` = trust domain; `ns/foo` = namespace `foo`; `sa/curl` = ServiceAccount `curl`. It is the SPIFFE ID `spiffe://cluster.local/ns/foo/sa/curl`, encoded in the SAN of the workload's mTLS client certificate and verified by the server sidecar during the TLS handshake — that is where it travels on the wire.

**Q3.2** Under PERMISSIVE a plaintext request has no certificate, so `source.principal`/`source.namespace` are empty; the principal‑based ALLOW cannot match, so the request is denied — *or*, if you also had an allow‑all path, it slips through with no identity. That is the trap: PERMISSIVE silently lets un‑authenticated peers exist, and identity‑based ALLOW rules give a false sense of enforcement. Use STRICT wherever you rely on principals.

**Q3.3** Semantics: **across separate `rules`** → OR (match any rule). **Within one rule, `from` AND `to` AND `when`** must all be satisfied → AND. **Across multiple entries in a `from` list** (multiple `source` blocks) → OR. **Across multiple values inside one field like `principals`** → OR. So a rule is "(any source) AND (any operation) AND (all conditions)".

**Q4.1** The request must be HTTP and, in a mesh, typically over mTLS so the sidecar can parse L7 headers. Header conditions only apply to HTTP; if the policy ends up matching a raw TCP port, HTTP‑only fields like `request.headers[...]`/`methods`/`paths` are not applicable and Istio ignores/short‑circuits them (a rule that requires an HTTP‑only attribute cannot match TCP traffic, effectively denying it under an ALLOW).

**Q4.2** Any client that reaches the sidecar can set an arbitrary header, so `x-team` proves nothing about identity — it is a convenience/segmentation control, fine as an extra AND condition on top of a verified control. The real, unspoofable gate in that policy is `from.source.namespaces` (mTLS‑verified identity). Never let a header be the only thing between a caller and the data.

**Q4.3** `source.ip` (condition key `source.ip` / `remoteIp`) — Istio distinguishes the directly connected peer address from the original client address (`remote.ip` derived from `X‑Forwarded‑For` when `numTrustedProxies`/gateway config is set). Behind a gateway the connected peer is the gateway's IP, while the true client IP is only in the XFF chain — so you must use the original‑client key and configure trusted proxy hops, or you will match the gateway instead of the user.

**Q5.1** Order per request: **CUSTOM** (external authorizer) first → if it denies, stop. Then **DENY** policies → if any matches, deny. Then **ALLOW** policies → if an ALLOW selects the workload, the request must match one, else deny; if no ALLOW selects it, allow. **AUDIT** never affects the outcome — it only logs.

**Q5.2** `deny-writes-from-bar` won, because DENY is evaluated before ALLOW and a matching DENY short‑circuits to `403` regardless of any ALLOW. Lesson: platform/security owners should hold DENY guardrails (they cannot be overridden by a team's ALLOW), while individual teams manage their per‑service ALLOW rules within those guardrails.

**Q5.3** `GET /ip` from `bar`: DENY phase — `deny-writes-from-bar` matches only `POST/PUT/DELETE`, so `GET` does **not** match → no denial. ALLOW phase — `allow-bar-everything` matches source `bar` with no operation restriction → match → `200`. The GET is allowed precisely because the DENY didn't match *and* an ALLOW did.

**Q6.1** The `401` comes from **`RequestAuthentication`** (the JWT filter) rejecting a structurally/signature‑invalid token. The `403` comes from the **`AuthorizationPolicy`** RBAC filter. "No token" is `403` because `RequestAuthentication` accepts absence of a token (it only validates *present* tokens); the request then reaches RBAC, matches no `requestPrincipals` rule, and is authorization‑denied → `403`.

**Q6.2** With only `RequestAuthentication`: (a) valid token → **allowed**, (b) invalid token → **401 rejected**, (c) no token → **allowed**. This demonstrates that `RequestAuthentication` alone never *requires* a token — it only rejects bad ones. To make a token mandatory you must add an `AuthorizationPolicy` on `requestPrincipals`.

**Q6.3** `principals` is a **workload/peer** identity from mTLS (SPIFFE ID in the client cert). `requestPrincipals` is an **end‑user** identity `<issuer>/<subject>` from a validated JWT. Yes — a single rule may put `principals` and `requestPrincipals` in the same `source`, AND‑requiring both: e.g., "calls must come from the `gateway` service account *and* carry a valid end‑user token" (workload identity AND user identity).

**Q7.1** Only inspecting Envoy's config (`authz check` / `proxy-config`) reveals cases where a policy exists in `etcd` but was **not pushed / not compiled** onto the proxy — e.g., a `selector` that matches nothing, a policy in the wrong namespace, an xDS push lag, or a version‑skewed CRD Istiod rejected. `kubectl get` shows the object exists; it cannot tell you the sidecar is actually enforcing it.

**Q7.2** A `shadow` decision is a **dry‑run**: the rule is evaluated and logged but **not enforced**, produced by policies annotated for dry‑run (`istio.io/dry-run`). You roll out a new DENY in dry‑run mode, watch the `rbac_access_shadow_policy` log lines to see exactly what it *would* block, confirm no legitimate traffic is caught, then remove the dry‑run annotation to enforce it — a safe, observable rollout.

**Q7.3** (1) **`selector` mismatch** — labels in `matchLabels` don't match any pod's labels (typo, `app` vs `service`); `authz check` simply won't list the policy against the workload, and `proxy-config` shows no corresponding RBAC rule. (2) **Wrong `namespace` / `apiVersion`** — the object landed in `default` instead of the workload's namespace, or uses a stale/invalid `apiVersion` the API server accepts into a different group version so Istiod ignores it; again `authz check` omits it. Both manifest as "object exists in `kubectl get`, absent from `authz check`," which is the tell that it is applying to zero workloads.

</details>