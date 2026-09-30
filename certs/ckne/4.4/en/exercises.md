# Guided Exercises — 4.4 Implementing Pod-level Authentication and Authorization

**Exam weight:** 6.24%
**What you will build:** a small mesh where every pod has a cryptographic identity. You will lock down the transport with mTLS, write identity-based and JWT-based authorization rules, diagnose why requests get denied, and finish with the Kubernetes-native identity underneath all of it: the bound ServiceAccount token.

**Official references**

- CKNE program: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Istio security concepts: https://istio.io/latest/docs/concepts/security/
- PeerAuthentication reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- AuthorizationPolicy reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- RequestAuthentication reference: https://istio.io/latest/docs/reference/config/security/request_authentication/
- Mutual TLS migration task: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- HTTP authorization task: https://istio.io/latest/docs/tasks/security/authorization/authz-http/
- JWT authorization task: https://istio.io/latest/docs/tasks/security/authorization/authz-jwt/
- SPIFFE concepts: https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- ServiceAccounts: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- TokenReview API: https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-review-v1/

**Requirements:** `kind` (or any disposable cluster running Kubernetes 1.30 or later), `kubectl`, `jq`, `openssl`, internet access from the cluster.

---

## Exercise 1 — Build the lab: three namespaces, two trust levels

The lab uses three namespaces:

| Namespace | Sidecar injected? | Role |
|---|---|---|
| `server` | yes | runs `httpbin`, the protected workload |
| `client` | yes | runs `curl`, a trusted mesh client |
| `legacy` | **no** | runs `curl`, a workload outside the mesh that speaks plaintext |

### Steps

1. Create the cluster and install Istio with the `minimal` profile. That profile installs only istiod, with no gateways.

   ```bash
   kind create cluster --name ckne-authz
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.27.1 sh -
   export PATH="$PWD/istio-1.27.1/bin:$PATH"
   istioctl install --set profile=minimal -y
   ```

   Expected output:

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ Installation complete
   ```

2. Create the namespaces. Only two of them get the injection label.

   ```bash
   kubectl create namespace server
   kubectl create namespace client
   kubectl create namespace legacy
   kubectl label namespace server istio-injection=enabled
   kubectl label namespace client istio-injection=enabled
   ```

3. Save this as `httpbin.yaml` and apply it:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: httpbin
     namespace: server
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: httpbin
     namespace: server
     labels:
       app: httpbin
   spec:
     selector:
       app: httpbin
     ports:
     - name: http
       port: 8000
       targetPort: 8080
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: httpbin
     namespace: server
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: httpbin
     template:
       metadata:
         labels:
           app: httpbin
       spec:
         serviceAccountName: httpbin
         containers:
         - name: httpbin
           image: docker.io/mccutchen/go-httpbin:v2.15.0
           ports:
           - containerPort: 8080
   ```

   ```bash
   kubectl apply -f httpbin.yaml
   ```

4. Save this as `curl.yaml`. It has no namespace field because you will deploy it twice:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: curl
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: curl
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: curl
     template:
       metadata:
         labels:
           app: curl
       spec:
         serviceAccountName: curl
         containers:
         - name: curl
           image: curlimages/curl:8.10.1
           command:
           - /bin/sleep
           - infinity
   ```

   ```bash
   kubectl apply -n client -f curl.yaml
   kubectl apply -n legacy -f curl.yaml
   kubectl wait --for=condition=Available deploy --all -n server --timeout=120s
   kubectl wait --for=condition=Available deploy --all -n client --timeout=120s
   kubectl wait --for=condition=Available deploy --all -n legacy --timeout=120s
   ```

5. Check the pods:

   ```bash
   kubectl get pods -A -l 'app in (httpbin,curl)'
   ```

   Expected output:

   ```
   NAMESPACE   NAME                       READY   STATUS    RESTARTS   AGE
   client      curl-6d8b9c7f4d-x2l8k      2/2     Running   0          40s
   legacy      curl-6d8b9c7f4d-p9qzr      1/1     Running   0          40s
   server      httpbin-7f9c6b5d8-7kq4t    2/2     Running   0          55s
   ```

6. Call httpbin from both clients:

   ```bash
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.server:8000/headers
   kubectl exec -n legacy deploy/curl -- \
     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.server:8000/headers
   ```

   Both calls should return `200`.

### Questions

- **Q1.1** Why does `legacy/curl` show `1/1` and the other two pods show `2/2`? What is the second container, and what put it there?
- **Q1.2** The Service listens on port `8000`, but the container listens on `8080`. Which of the two does the server-side sidecar actually intercept? (This matters again in Exercise 3.)
- **Q1.3** Both calls returned `200`, yet only one of them was encrypted. Why doesn't Istio reject the plaintext call by default?

---

## Exercise 2 — A pod's identity is a certificate: SPIFFE in practice

### Steps

1. Pull the certificate that istiod issued to the `client/curl` sidecar and read its Subject Alternative Name:

   ```bash
   istioctl proxy-config secret deploy/curl -n client -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d \
     | openssl x509 -noout -text \
     | grep -E -A1 'Subject Alternative Name|Not Before|Not After'
   ```

   Expected output (your dates will differ):

   ```
               Not Before: Sep 30 10:02:11 2026 GMT
               Not After : Oct  1 10:04:11 2026 GMT
               X509v3 Subject Alternative Name: critical
                   URI:spiffe://cluster.local/ns/client/sa/curl
   ```

2. Look at the summary view:

   ```bash
   istioctl proxy-config secret deploy/curl -n client
   ```

   ```
   RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER        NOT AFTER                NOT BEFORE
   default           Cert Chain     ACTIVE     true           3a1f...              2026-10-01T10:04:11Z     2026-09-30T10:02:11Z
   ROOTCA            CA             ACTIVE     true           9c2e...              2036-09-28T09:58:40Z     2026-09-30T09:58:40Z
   ```

3. See the identity from the **server's** side. The server sidecar tells the application who called it through the `X-Forwarded-Client-Cert` (XFCC) header:

   ```bash
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s http://httpbin.server:8000/headers | grep -A2 -i x-forwarded-client-cert
   ```

   ```
       "X-Forwarded-Client-Cert": [
         "By=spiffe://cluster.local/ns/server/sa/httpbin;Hash=5f0c...;Subject=\"\";URI=spiffe://cluster.local/ns/client/sa/curl"
       ],
   ```

4. Make the same call from `legacy`:

   ```bash
   kubectl exec -n legacy deploy/curl -- \
     curl -s http://httpbin.server:8000/headers | grep -ci x-forwarded-client-cert
   ```

   ```
   0
   ```

### Questions

- **Q2.1** Break down `spiffe://cluster.local/ns/client/sa/curl`. Which Kubernetes object does the identity come from, and what does *not* appear in it (pod name, IP, labels)? Why is that a deliberate design choice?
- **Q2.2** The certificate lasts about 24 hours. Who rotates it, and does the private key ever leave the pod?
- **Q2.3** What does the absence of XFCC in step 4 tell you about the legacy request, and what will it mean for any policy that matches on `principals`?

---

## Exercise 3 — PeerAuthentication: from PERMISSIVE to STRICT

### Steps

1. Check which mode is in effect right now:

   ```bash
   kubectl get peerauthentication -A
   ```

   ```
   No resources found
   ```

   With no resource at all, the effective mode is `PERMISSIVE`.

2. Enforce STRICT mTLS for the `server` namespace. Save this as `pa-server-strict.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: server
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f pa-server-strict.yaml
   ```

3. Test both clients again:

   ```bash
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.server:8000/headers
   kubectl exec -n legacy deploy/curl -- \
     curl -sS -o /dev/null -w '%{http_code}\n' http://httpbin.server:8000/headers
   ```

   Expected output:

   ```
   200
   curl: (56) Recv failure: Connection reset by peer
   000
   command terminated with exit code 56
   ```

4. Add a port-level exception on the *workload* port. Save this as `pa-httpbin-port.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-port-exception
     namespace: server
   spec:
     selector:
       matchLabels:
         app: httpbin
     mtls:
       mode: STRICT
     portLevelMtls:
       8080:
         mode: PERMISSIVE
   ```

   ```bash
   kubectl apply -f pa-httpbin-port.yaml
   kubectl exec -n legacy deploy/curl -- \
     curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.server:8000/headers
   ```

   This returns `200` again.

5. Remove the exception, then make STRICT mesh-wide through the root namespace:

   ```bash
   kubectl delete -f pa-httpbin-port.yaml
   ```

   ```yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: istio-system
   spec:
     mtls:
       mode: STRICT
   ```

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: istio-system
   spec:
     mtls:
       mode: STRICT
   EOF
   kubectl get peerauthentication -A
   ```

   ```
   NAMESPACE      NAME      MODE     AGE
   istio-system   default   STRICT   5s
   server         default   STRICT   4m
   ```

6. Confirm which policy actually applies to the httpbin pod:

   ```bash
   POD=$(kubectl get pod -n server -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   istioctl x describe pod "$POD" -n server
   ```

   The output includes a line similar to:

   ```
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
   Applied PeerAuthentication:
      default.istio-system, default.server
   ```

### Questions

- **Q3.1** Why did `legacy` get a TCP reset (exit code 56) instead of an HTTP 403? At which layer does the rejection happen?
- **Q3.2** The port-level exception used `8080`, not `8000`. Explain why, and why `portLevelMtls` needs a `selector`.
- **Q3.3** Three PeerAuthentications can match one pod: mesh (root namespace), namespace, and workload. Which one wins? What happens if two workload-level policies select the same pod?
- **Q3.4** `client/curl` never had to be configured to *send* mTLS. What feature took care of that, and what does it look at to decide?
- **Q3.5** In production, why would you migrate through PERMISSIVE first instead of switching straight to STRICT?

---

## Exercise 4 — AuthorizationPolicy: identity-based L7 access

Target behaviour for `httpbin`:

- Only the `client/curl` identity may call it.
- Only `GET` on `/headers` and `/status/*` is allowed.
- `/status/500` is forbidden to everyone, even the allowed identity.

### Steps

1. Start from deny-by-default in the namespace. Save this as `authz-allow-nothing.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-nothing
     namespace: server
   spec: {}
   ```

   ```bash
   kubectl apply -f authz-allow-nothing.yaml
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -w '\n%{http_code}\n' http://httpbin.server:8000/headers
   ```

   ```
   RBAC: access denied
   403
   ```

2. Allow the trusted identity. Save this as `authz-allow-curl.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-allow-curl
     namespace: server
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           principals:
           - cluster.local/ns/client/sa/curl
       to:
       - operation:
           methods:
           - GET
           paths:
           - /headers
           - /status/*
   ```

3. Add an explicit DENY. Save this as `authz-deny-500.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-deny-500
     namespace: server
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: DENY
     rules:
     - to:
       - operation:
           paths:
           - /status/500
   ```

   ```bash
   kubectl apply -f authz-allow-curl.yaml -f authz-deny-500.yaml
   ```

4. Run the test matrix:

   ```bash
   C="kubectl exec -n client deploy/curl -c curl -- curl -s -o /dev/null -w %{http_code}\n"
   $C http://httpbin.server:8000/headers
   $C -X POST http://httpbin.server:8000/post
   $C http://httpbin.server:8000/status/418
   $C http://httpbin.server:8000/status/500
   $C http://httpbin.server:8000/ip
   ```

   Expected output:

   ```
   200
   403
   418
   403
   403
   ```

5. Show that authorization follows the ServiceAccount, not the namespace. Create a second identity in the **same** `client` namespace:

   ```bash
   kubectl create serviceaccount intruder -n client
   kubectl run intruder -n client --image=curlimages/curl:8.10.1 \
     --overrides='{"spec":{"serviceAccountName":"intruder"}}' \
     --command -- /bin/sleep infinity
   kubectl wait --for=condition=Ready pod/intruder -n client --timeout=90s
   kubectl exec -n client intruder -c intruder -- \
     curl -s -w '\n%{http_code}\n' http://httpbin.server:8000/headers
   ```

   ```
   RBAC: access denied
   403
   ```

### Questions

- **Q4.1** Why does `spec: {}` deny everything instead of allowing everything? What default `action` does it get, and why does it match nothing?
- **Q4.2** `/status/500` matches the ALLOW rule's `/status/*` pattern, yet it returns `403`. State the full evaluation order Istio uses for `CUSTOM`, `DENY` and `ALLOW`.
- **Q4.3** Why is `/ip` denied even though no policy mentions it?
- **Q4.4** The principal is written `cluster.local/ns/client/sa/curl`, without `spiffe://`. What would happen if the mesh STRICT policy were removed, `legacy/curl` called httpbin in plaintext, and you had allowed `source.namespaces: ["legacy"]`?
- **Q4.5** In this rule, are `methods` and `paths` combined with AND or with OR? And are two entries inside `paths` combined with AND or with OR?

---

## Exercise 5 — RequestAuthentication: end-user identity with JWT

mTLS authenticates the **workload**. A JWT authenticates the **request**, usually on behalf of an end user. You will require both.

### Steps

1. Download Istio's test tokens:

   ```bash
   BASE=https://raw.githubusercontent.com/istio/istio/release-1.27/security/tools/jwt/samples
   TOKEN=$(curl -s $BASE/demo.jwt)
   TOKEN_GROUP=$(curl -s $BASE/groups-scope.jwt)
   echo "$TOKEN_GROUP" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
   ```

   ```
   {
     "exp": 3537391104,
     "groups": [
       "group1",
       "group2"
     ],
     "iat": 1537391104,
     "iss": "testing@secure.istio.io",
     "scope": [
       "scope1",
       "scope2"
     ],
     "sub": "testing@secure.istio.io"
   }
   ```

   (If `jq` complains, the payload is missing its base64 padding; append `==` before decoding.)

2. Tell the httpbin sidecar how to validate tokens. Save this as `reqauthn.yaml`:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: RequestAuthentication
   metadata:
     name: httpbin-jwt
     namespace: server
   spec:
     selector:
       matchLabels:
         app: httpbin
     jwtRules:
     - issuer: testing@secure.istio.io
       jwksUri: https://raw.githubusercontent.com/istio/istio/release-1.27/security/tools/jwt/samples/jwks.json
   ```

   ```bash
   kubectl apply -f reqauthn.yaml
   C="kubectl exec -n client deploy/curl -c curl -- curl -s -o /dev/null -w %{http_code}\n"
   $C http://httpbin.server:8000/headers
   $C -H "Authorization: Bearer invalidtoken" http://httpbin.server:8000/headers
   $C -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/headers
   ```

   Expected output:

   ```
   200
   401
   200
   ```

3. Make the token mandatory by replacing the ALLOW policy. Workload identity and request identity go in the **same** `source` block, and a new rule restricts `/anything/admin` to members of `group1`. Save this as `authz-allow-curl.yaml`, overwriting the old file:

   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: httpbin-allow-curl
     namespace: server
   spec:
     selector:
       matchLabels:
         app: httpbin
     action: ALLOW
     rules:
     - from:
       - source:
           principals:
           - cluster.local/ns/client/sa/curl
           requestPrincipals:
           - testing@secure.istio.io/testing@secure.istio.io
       to:
       - operation:
           methods:
           - GET
           paths:
           - /headers
           - /status/*
     - from:
       - source:
           principals:
           - cluster.local/ns/client/sa/curl
           requestPrincipals:
           - testing@secure.istio.io/testing@secure.istio.io
       to:
       - operation:
           methods:
           - GET
           paths:
           - /anything/admin
       when:
       - key: request.auth.claims[groups]
         values:
         - group1
   ```

   ```bash
   kubectl apply -f authz-allow-curl.yaml
   $C http://httpbin.server:8000/headers
   $C -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/headers
   $C -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/anything/admin
   $C -H "Authorization: Bearer $TOKEN_GROUP" http://httpbin.server:8000/anything/admin
   ```

   Expected output:

   ```
   403
   200
   403
   200
   ```

4. Confirm that the token alone is not enough without the workload identity:

   ```bash
   kubectl exec -n client intruder -c intruder -- \
     curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/headers
   ```

   ```
   403
   ```

### Questions

- **Q5.1** In step 2, a request *without* a token got `200` and a request with an *invalid* token got `401`. Explain both results. What is RequestAuthentication's job, and what is it *not* responsible for?
- **Q5.2** Why did you edit the existing ALLOW policy instead of adding a second policy that only required `requestPrincipals`? Describe the security hole the second approach would create.
- **Q5.3** How is a `requestPrincipal` string built? What would you write to accept any valid token from that issuer?
- **Q5.4** The `jwksUri` in this lab points to the internet. Which component fetches it by default, and what is the alternative for an air-gapped cluster?
- **Q5.5** A `401` and a `403` come from different Envoy filters. Which filter produces each one?

---

## Exercise 6 — Diagnosing a denial

### Steps

1. List the policies that apply to the pod:

   ```bash
   POD=$(kubectl get pod -n server -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
   istioctl x authz check "$POD" -n server
   ```

   The output looks similar to this:

   ```
   ACTION   AuthorizationPolicy               RULES
   DENY     httpbin-deny-500.server           1
   ALLOW    _anonymous_match_nothing_         1
   ALLOW    httpbin-allow-curl.server         2
   ```

2. Turn on RBAC debug logging only on that sidecar, then trigger a request that gets denied:

   ```bash
   istioctl proxy-config log "$POD" -n server --level rbac:debug
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/status/500
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" http://httpbin.server:8000/ip
   kubectl logs "$POD" -n server -c istio-proxy --since=1m | grep -E 'enforced (denied|allowed)'
   ```

   Look for lines similar to these:

   ```
   ... rbac ... enforced denied, matched policy ns[server]-policy[httpbin-deny-500]-rule[0]
   ... rbac ... enforced denied, matched policy none
   ```

3. Correlate with the access log. Enable it first if it is not already on:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: telemetry.istio.io/v1
   kind: Telemetry
   metadata:
     name: mesh-logging
     namespace: istio-system
   spec:
     accessLogging:
     - providers:
       - name: envoy
   EOF
   kubectl exec -n client deploy/curl -c curl -- \
     curl -s -o /dev/null http://httpbin.server:8000/headers
   kubectl logs "$POD" -n server -c istio-proxy --tail=1
   ```

   The line contains `403` and `rbac_access_denied_matched_policy[none]`.

4. Reset the log level:

   ```bash
   istioctl proxy-config log "$POD" -n server --level rbac:warning
   ```

### Questions

- **Q6.1** What is the practical difference between `matched policy ns[server]-policy[httpbin-deny-500]-rule[0]` and `matched policy none`? Which one points to a missing ALLOW rule?
- **Q6.2** A developer reports `curl: (56) Connection reset by peer` and wants you to check the AuthorizationPolicies. Why is that the wrong place to start, and what do you check first?
- **Q6.3** Why read the **server's** `istio-proxy` logs rather than the client's?

---

## Exercise 7 — Under the mesh: bound ServiceAccount tokens

The SPIFFE identity from Exercise 2 is derived from the ServiceAccount. That same ServiceAccount also gives a pod a Kubernetes-native credential that any service can verify through the API server.

### Steps

1. Issue a short-lived token bound to a specific audience:

   ```bash
   SA_TOKEN=$(kubectl create token curl -n client --audience=inventory-api --duration=10m)
   echo "$SA_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{aud, sub, exp}'
   ```

   ```
   {
     "aud": [
       "inventory-api"
     ],
     "sub": "system:serviceaccount:client:curl",
     "exp": 1790763120
   }
   ```

2. Have the API server verify the token, as a receiving service would:

   ```bash
   cat <<EOF | kubectl create -o json -f - | jq '.status | {authenticated, user: .user.username, audiences, error}'
   apiVersion: authentication.k8s.io/v1
   kind: TokenReview
   spec:
     token: ${SA_TOKEN}
     audiences:
     - inventory-api
   EOF
   ```

   ```
   {
     "authenticated": true,
     "user": "system:serviceaccount:client:curl",
     "audiences": [
       "inventory-api"
     ],
     "error": null
   }
   ```

3. Present the same token to a *different* audience:

   ```bash
   cat <<EOF | kubectl create -o json -f - | jq '.status | {authenticated, error}'
   apiVersion: authentication.k8s.io/v1
   kind: TokenReview
   spec:
     token: ${SA_TOKEN}
     audiences:
     - payments-api
   EOF
   ```

   ```
   {
     "authenticated": false,
     "error": "[invalid bearer token, token audiences [\"inventory-api\"] is invalid for the target audiences [\"payments-api\"], unknown]"
   }
   ```

4. Give a pod a projected token for one audience, and disable the default API token. Save this as `pod-projected.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: inventory-client
     namespace: legacy
   spec:
     serviceAccountName: curl
     automountServiceAccountToken: false
     containers:
     - name: app
       image: curlimages/curl:8.10.1
       command:
       - /bin/sleep
       - infinity
       volumeMounts:
       - name: inventory-token
         mountPath: /var/run/secrets/inventory
         readOnly: true
     volumes:
     - name: inventory-token
       projected:
         sources:
         - serviceAccountToken:
             audience: inventory-api
             expirationSeconds: 3600
             path: token
   ```

   ```bash
   kubectl apply -f pod-projected.yaml
   kubectl wait --for=condition=Ready pod/inventory-client -n legacy --timeout=60s
   kubectl exec -n legacy inventory-client -- ls /var/run/secrets/
   ```

   ```
   inventory
   ```

### Questions

- **Q7.1** What does the audience binding prevent? Describe the attack it stops.
- **Q7.2** `automountServiceAccountToken: false` removed `/var/run/secrets/kubernetes.io`. Why is that good practice for a workload that never talks to the API server?
- **Q7.3** Compare this token with the mesh's mTLS certificate. What proves identity in each case, and at which layer does the check happen?
- **Q7.4** The token lives for 3600 s. What renews it inside the pod, and when?

---

## Cleanup

```bash
kind delete cluster --name ckne-authz
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** The second container is `istio-proxy`, the Envoy sidecar. When a pod is created in a namespace labelled `istio-injection=enabled`, istiod's mutating admission webhook adds it to the pod spec. `legacy` has no label, so its pod is never mutated. With native sidecars, `istio-proxy` is an init container with `restartPolicy: Always`, and `kubectl` still counts it in READY.

**Q1.2** The sidecar intercepts **8080**, the container (workload) port. The Service port `8000` exists only in the client's view. The client resolves the Service, and after the ClusterIP is translated the packet arrives at `podIP:8080`. That is the port iptables redirects to Envoy's inbound listener.

**Q1.3** With no PeerAuthentication the effective mode is `PERMISSIVE`. The inbound listener accepts both plaintext and mTLS, telling them apart by the TLS ALPN/SNI. That is what lets you migrate workloads gradually without breaking clients that are outside the mesh.

### Exercise 2

**Q2.1** The format is `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`. It comes from the pod's **ServiceAccount**. Pod name, IP and labels are left out on purpose: they are ephemeral or can be changed by anyone who can edit a pod. The ServiceAccount is a stable object controlled by RBAC, and every replica of a workload shares it, so policies stay valid across restarts and scaling.

**Q2.2** The istio-agent (pilot-agent) inside the sidecar generates the private key locally, sends a CSR to istiod over SDS, and receives the signed certificate. It rotates the certificate before it expires, by default at about 50% of its lifetime. The private key never leaves the pod and is never written to etcd.

**Q2.3** The request arrived in plaintext, so there was no client certificate and no peer identity. Any policy that matches `principals` or `namespaces` will **never match** that request: an ALLOW rule denies it, and a DENY rule written with those fields does not catch it.

### Exercise 3

**Q3.1** mTLS is enforced at the connection level (L4/TLS), before any HTTP is parsed. In STRICT mode the inbound listener only has a TLS filter chain. A plaintext client fails the handshake, and Envoy closes the connection. No HTTP layer exists yet that could produce a 403.

**Q3.2** `portLevelMtls` refers to the port the **workload** receives on (8080), not the Service port, for the reason given in Q1.2. It needs a `selector` because a port number only means something for a specific workload. Istio ignores `portLevelMtls` on policies without a selector, which is why it only works on workload-scoped policies.

**Q3.3** The most specific policy wins: **workload > namespace > mesh**. If two workload-level policies select the same pod, the result is undefined: Istio uses the oldest one. Avoid this situation.

**Q3.4** **Auto mTLS**. istiod knows which endpoints have a sidecar, and it configures the client's Envoy to originate Istio mTLS to those endpoints and plaintext to endpoints without one. A DestinationRule with an explicit `tls` setting overrides it.

**Q3.5** STRICT immediately breaks every client without a sidecar. PERMISSIVE first lets you see who still arrives in plaintext (through metrics like `connection_security_policy` in `istio_requests_total`, or the XFCC header). You inject or migrate those clients, and only then switch, namespace by namespace.

### Exercise 4

**Q4.1** A policy with no `action` gets `ALLOW`. Once *any* ALLOW policy applies to a workload, a request is allowed only if some ALLOW rule matches. With no `rules`, nothing can match, so everything is denied. (By contrast, `rules: [{}]`, a single empty rule, matches everything.)

**Q4.2** Istio evaluates policies in this order:
1. If a `CUSTOM` policy denies → deny.
2. If a `DENY` policy matches → deny.
3. If no `ALLOW` policy applies to the workload → allow.
4. If an `ALLOW` policy matches → allow.
5. Otherwise → deny.

DENY is evaluated before ALLOW, so the explicit exclusion wins.

**Q4.3** ALLOW policies exist for the workload (`allow-nothing` and `httpbin-allow-curl`), and none of their rules match `/ip`. Step 5 applies: deny.

**Q4.4** `principals` and `namespaces` are both taken from the peer's mTLS certificate. A plaintext request has no certificate, so the rule would **not** match, and the request would be denied under ALLOW. Identity-based authorization requires mTLS. This is why STRICT and AuthorizationPolicy are deployed together.

**Q4.5** Different fields inside one `operation` (or one `source`) are combined with **AND**. Values inside a single list field are combined with **OR**. Separate `rules` entries are also OR'd, and so are separate `from`/`to` entries.

### Exercise 5

**Q5.1** RequestAuthentication only **validates tokens that are present**: signature against the JWKS, `iss`, `exp`, and `aud` if configured. An invalid token is rejected with `401`. A request without a token is simply unauthenticated: it has no `requestPrincipal`, but RequestAuthentication does not reject it. Requiring a token is **authorization's** job (`requestPrincipals` in an AuthorizationPolicy).

**Q5.2** ALLOW policies are OR'd. If the old policy remained (curl identity, no token needed), a request that satisfied it would be allowed regardless of a second policy that required a token. The JWT requirement could be bypassed simply by not sending one. Putting `principals` and `requestPrincipals` in the same `source` makes them an AND.

**Q5.3** It is `<iss>/<sub>` from the validated token, here `testing@secure.istio.io/testing@secure.istio.io`. `requestPrincipals: ["*"]` accepts any valid token from any configured issuer. `testing@secure.istio.io/*` restricts it to one issuer.

**Q5.4** By default **istiod** fetches the JWKS and pushes it to Envoy inline. The behaviour can be changed with the `PILOT_JWT_ENABLE_REMOTE_JWKS` setting. In air-gapped clusters, embed the key set directly with the `jwks:` field, a JSON string, in the `jwtRules` entry, or host the JWKS inside the cluster.

**Q5.5** `401` comes from the `jwt_authn` filter (authentication failure). `403 RBAC: access denied` comes from the `rbac` filter (authorization failure). Knowing which one fired tells you which resource to look at.

### Exercise 6

**Q6.1** `matched policy ns[...]-policy[X]-rule[N]` means a **DENY** policy explicitly matched, and it tells you exactly which policy and rule. `matched policy none` means that ALLOW policies apply but **none matched**: you are missing an ALLOW rule, or its conditions don't match the request (wrong principal, path, method, or no mTLS).

**Q6.2** A TCP reset happens before HTTP is parsed, so it cannot be an AuthorizationPolicy denial (those return 403 at L7). Check PeerAuthentication first (`istioctl x describe pod`): most likely a plaintext client is hitting a STRICT workload, or a DestinationRule forces the wrong TLS mode.

**Q6.3** Authorization is enforced by the **server-side** (inbound) Envoy of the target workload. The client sidecar only sees an upstream 403; it has no information about which policy matched.

### Exercise 7

**Q7.1** It prevents **token replay**. If service A receives a token from a caller and could present it to service B, a compromised or malicious A could impersonate the caller. When each token is bound to one audience, B rejects any token that was not minted for B.

**Q7.2** It follows least privilege. A token that is never needed is still a credential that can be stolen, for example through a path traversal or an RCE in the app. If the ServiceAccount has any RBAC bindings, that token becomes a foothold into the API.

**Q7.3** mTLS: an X.509 certificate with a SPIFFE URI SAN, plus possession of the private key, verified in the TLS handshake at **L4/transport** by Envoy. ServiceAccount token: a signed JWT bearer credential verified at **L7/application** by the receiving service (via TokenReview or OIDC discovery). Both identities come from the same ServiceAccount, but the bearer token can be replayed if stolen, whereas the key-bound certificate cannot.

**Q7.4** The kubelet refreshes the projected token. It rotates it when the token has passed 80% of its lifetime or is older than 24 hours, and writes the new token atomically to the same path. Applications must re-read the file rather than caching the token at startup.

</details>