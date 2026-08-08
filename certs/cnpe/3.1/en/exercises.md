# Guided Exercises — Topic 3.1: Configuring Secure Service-to-Service Communication

> **Certification:** CNPE (Certified Cloud Native Platform Engineer) — Exam weight: 3
> **Domain:** Security & Compliance / Service Communication
> **Role framing:** You are the platform engineer. Your job is not to secure one app — it is to deliver *secure service-to-service communication as a platform capability* so that every tenant workload inherits identity, encryption in transit, and least-privilege authorization by default.

These labs build on one another. Do them in order. Every manifest is complete and syntactically valid; every command is real. Expected outputs are representative (versions and IPs will differ on your cluster).

**Prerequisites**

- A Kubernetes cluster (`v1.28+`), `kubectl` configured, cluster-admin.
- A CNI that enforces `NetworkPolicy` (Cilium, Calico, or equivalent). On kind/minikube the default CNI does **not** enforce policies — install Calico or run `kind` with a policy-capable CNI, otherwise Exercise 2 silently no-ops.
- `istioctl` (`1.20+`) on your PATH, and `helm` (`3.x`).
- `openssl`, `jq`, and `tcpdump` available locally or via an ephemeral debug container.

Sources of truth used throughout:
- Istio Security concepts — https://istio.io/latest/docs/concepts/security/
- Istio `PeerAuthentication` / `AuthorizationPolicy` reference — https://istio.io/latest/docs/reference/config/security/
- Kubernetes `NetworkPolicy` — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- SPIFFE/SPIRE — https://spiffe.io/docs/latest/spiffe-about/overview/
- cert-manager — https://cert-manager.io/docs/

---

## Exercise 1 — Establish the baseline: traffic is plaintext by default

**Objective:** Prove to yourself that, out of the box, pod-to-pod traffic is unencrypted and unauthenticated. You cannot argue for a control you have not shown is needed.

1. Create a dedicated namespace and deploy a client and a server.

   ```bash
   kubectl create namespace shop
   ```

   ```yaml
   # save as baseline.yaml, then: kubectl apply -f baseline.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: backend
     namespace: shop
     labels: { app: backend }
   spec:
     replicas: 1
     selector: { matchLabels: { app: backend } }
     template:
       metadata:
         labels: { app: backend }
       spec:
         containers:
           - name: backend
             image: hashicorp/http-echo:1.0
             args: ["-text=hello from backend", "-listen=:8080"]
             ports:
               - containerPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: backend
     namespace: shop
   spec:
     selector: { app: backend }
     ports:
       - name: http
         port: 8080
         targetPort: 8080
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: frontend
     namespace: shop
     labels: { app: frontend }
   spec:
     replicas: 1
     selector: { matchLabels: { app: frontend } }
     template:
       metadata:
         labels: { app: frontend }
       spec:
         containers:
           - name: curl
             image: curlimages/curl:8.6.0
             command: ["sleep", "infinity"]
   ```

2. Confirm the frontend can reach the backend with no credentials.

   ```bash
   kubectl -n shop exec deploy/frontend -c curl -- curl -s http://backend:8080
   ```

   Expected:

   ```
   hello from backend
   ```

3. Capture the raw bytes on the wire. Start a `tcpdump` sidecar-style debug pod on the backend's node, then re-issue the request. (Node name and interface will differ.)

   ```bash
   BACKEND_NODE=$(kubectl -n shop get pod -l app=backend -o jsonpath='{.items[0].spec.nodeName}')
   kubectl debug node/$BACKEND_NODE -it --image=nicolaka/netshoot -- \
     tcpdump -A -i any -c 20 'tcp port 8080'
   ```

   In a second terminal, generate traffic:

   ```bash
   kubectl -n shop exec deploy/frontend -c curl -- curl -s http://backend:8080
   ```

   In the `tcpdump` output you will see the literal strings `GET / HTTP/1.1`, the `Host:` header, and `hello from backend` in cleartext.

**Comprehension check**

- **Q1.1** — Nothing about this exchange required authentication. Name the two distinct guarantees that are *both* missing here, and why one does not imply the other.
- **Q1.2** — A colleague says "we're inside the cluster, the network is trusted." State the security model this assumption belongs to, and the model the rest of these exercises replace it with.
- **Q1.3** — Why is capturing on the *node* (via `kubectl debug node/...`) the correct vantage point rather than `tcpdump` inside the application container?

---

## Exercise 2 — L3/L4 segmentation with NetworkPolicy (default-deny)

**Objective:** Before encrypting anything, reduce the blast radius. A `NetworkPolicy` is your identity-independent, kernel-enforced perimeter. Encryption protects a conversation; segmentation decides whether the conversation is allowed to happen at all.

1. Add a second, *unauthorized* client to prove the policy later.

   ```bash
   kubectl -n shop create deployment attacker --image=curlimages/curl:8.6.0 -- sleep infinity
   ```

2. Confirm that today, **any** pod can reach the backend.

   ```bash
   kubectl -n shop exec deploy/attacker -- curl -s --max-time 5 http://backend:8080
   ```

   Expected: `hello from backend` (this is the problem).

3. Apply a **default-deny** ingress policy for the whole namespace, then a narrow allow.

   ```yaml
   # save as netpol.yaml, then: kubectl apply -f netpol.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: shop
   spec:
     podSelector: {}          # every pod in the namespace
     policyTypes: ["Ingress"]
     # no ingress rules => deny all ingress
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-backend
     namespace: shop
   spec:
     podSelector:
       matchLabels: { app: backend }
     policyTypes: ["Ingress"]
     ingress:
       - from:
           - podSelector:
               matchLabels: { app: frontend }
         ports:
           - protocol: TCP
             port: 8080
   ```

4. Re-test both clients.

   ```bash
   kubectl -n shop exec deploy/frontend -c curl -- curl -s --max-time 5 http://backend:8080   # allowed
   kubectl -n shop exec deploy/attacker      -- curl -s --max-time 5 http://backend:8080   # blocked (times out)
   ```

   Expected: the frontend returns `hello from backend`; the attacker's request **hangs until the timeout** and exits non-zero.

**Comprehension check**

- **Q2.1** — The blocked request *times out* rather than returning "connection refused." Explain, at the packet level, why NetworkPolicy produces a hang and not a reset.
- **Q2.2** — This policy selects the frontend by **label** (`app: frontend`). Why is a pod label a weak basis for *identity*, and what could a malicious tenant in the same namespace do to defeat it?
- **Q2.3** — You wrote a `default-deny-ingress` with an empty `podSelector: {}`. What traffic is still *not* covered by these two policies, and what would you add to close it?

---

## Exercise 3 — Cryptographic identity + mTLS with a service mesh

**Objective:** Move from "which label" to "which cryptographically-attested identity." Install Istio and turn on mesh-wide STRICT mutual TLS. Now every request carries a SPIFFE identity backed by a short-lived certificate, and the label-forgery problem from Q2.2 disappears.

1. Install Istio with the `demo`/`default` profile and enable sidecar injection on the namespace.

   ```bash
   istioctl install --set profile=default -y
   kubectl label namespace shop istio-injection=enabled --overwrite
   ```

2. Restart the workloads so the Envoy sidecar is injected. (Injection happens at pod creation; existing pods are untouched.)

   ```bash
   kubectl -n shop rollout restart deploy/backend deploy/frontend
   kubectl -n shop rollout status  deploy/backend deploy/frontend
   ```

   Confirm each pod now has **2/2** containers:

   ```bash
   kubectl -n shop get pods
   ```

   ```
   NAME                        READY   STATUS    RESTARTS   AGE
   backend-6c8f...             2/2     Running   0          40s
   frontend-7d5b...            2/2     Running   0          38s
   ```

3. Inspect the identity Istio issued to the backend workload.

   ```bash
   istioctl proxy-config secret deploy/backend -n shop -o json \
     | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
     | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
   ```

   Expected — a SPIFFE URI SAN, **not** a DNS name:

   ```
   X509v3 Subject Alternative Name:
       URI:spiffe://cluster.local/ns/shop/sa/default
   ```

4. Enforce STRICT mTLS mesh-wide (applied in the Istio root namespace so it is the default everywhere).

   ```yaml
   # save as peerauth-strict.yaml, then: kubectl apply -f peerauth-strict.yaml
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: istio-system     # root namespace => mesh-wide default
   spec:
     mtls:
       mode: STRICT
   ```

5. Verify mTLS is actually in force. First, confirm mesh clients still work:

   ```bash
   kubectl -n shop exec deploy/frontend -c curl -- curl -s http://backend:8080
   ```

   Expected: `hello from backend`.

   Now prove a **non-mesh** client is rejected at the transport layer. Deploy a client *without* a sidecar in a separate namespace:

   ```bash
   kubectl create namespace outside
   kubectl -n outside create deployment plainclient --image=curlimages/curl:8.6.0 -- sleep infinity
   kubectl -n outside exec deploy/plainclient -- \
     curl -s --max-time 5 http://backend.shop:8080
   ```

   Expected: **empty response / connection reset** — the backend's Envoy requires a client certificate the plain client cannot present.

6. Re-run the node `tcpdump` from Exercise 1 while the *mesh* frontend calls the backend. The payload is now TLS records — you will **not** find `hello from backend` in cleartext.

**Comprehension check**

- **Q3.1** — The certificate SAN is `spiffe://cluster.local/ns/shop/sa/default`. Decompose this URI: what does each segment bind the identity to, and which Kubernetes object is the *root* of that identity?
- **Q3.2** — You applied `PeerAuthentication` in `istio-system`, not `shop`. What is the precedence order of `PeerAuthentication` (mesh vs. namespace vs. workload), and how would you carve out one legacy workload that cannot do mTLS yet?
- **Q3.3** — Under STRICT mode, the non-mesh client was rejected but the mesh frontend still used a *plaintext* `http://` URL in `curl`. Explain how the connection is encrypted even though the application spoke plain HTTP.
- **Q3.4** — Istio certificates default to a ~24h lifetime and rotate roughly hourly. Why are short-lived, auto-rotated certs a *platform* win over long-lived certs you'd manage with a `Secret`?

---

## Exercise 4 — Verify, don't assume: proving the mTLS posture

**Objective:** A platform engineer must be able to *demonstrate* the posture to an auditor, not claim it. Learn the read-side tooling.

1. Ask Istio to describe the effective policy for the backend pod.

   ```bash
   BACKEND_POD=$(kubectl -n shop get pod -l app=backend -o jsonpath='{.items[0].metadata.name}')
   istioctl x describe pod $BACKEND_POD -n shop
   ```

   Expected excerpt:

   ```
   Pod: backend-6c8f...
      Pod Ports: 8080 (backend), 15090 (istio-proxy)
   ...
   Effective PeerAuthentication:
      Workload mTLS mode: STRICT
   ```

2. Inspect the Envoy listener to confirm the inbound filter chain requires TLS.

   ```bash
   istioctl proxy-config listener deploy/backend -n shop --port 8080 -o json \
     | jq '.[].filterChains[].transportSocket.name' | sort -u
   ```

   Expected: the transport socket is `envoy.transport_sockets.tls` (mTLS terminated by the sidecar), not raw TCP.

3. Confirm the client side is presenting a certificate and the peer identity it validates.

   ```bash
   istioctl proxy-config cluster deploy/frontend -n shop \
     --fqdn backend.shop.svc.cluster.local -o json \
     | jq '.[].transportSocketMatches // .[].transportSocket'
   ```

4. (Optional, powerful) Turn a certificate into an audit artifact — dump the issuer chain to confirm it chains to the Istio CA and not some rogue CA.

   ```bash
   istioctl proxy-config secret deploy/frontend -n shop -o json \
     | jq -r '.dynamicActiveSecrets[] | select(.name=="ROOTCA") | .secret.validationContext.trustedCa.inlineBytes' \
     | base64 -d | openssl x509 -noout -issuer -subject -dates
   ```

**Comprehension check**

- **Q4.1** — `istioctl x describe` reports `Workload mTLS mode: STRICT`. Which two independent config objects together determine whether a *given call* is actually mutually authenticated *and* authorized? (mTLS mode is only one of them.)
- **Q4.2** — You verified the client cluster config, the server listener, and the trust root. Why is checking only the server's `PeerAuthentication` mode insufficient to prove a connection was mTLS?
- **Q4.3** — An auditor asks "how do you know traffic isn't silently falling back to plaintext?" Which single `PeerAuthentication` field distinguishes a *provable* posture from an *aspirational* one, and what is the value that makes it provable?

---

## Exercise 5 — Least-privilege authorization (L7, identity-based)

**Objective:** mTLS answers *"is this really the frontend?"* Authorization answers *"is the frontend allowed to do THIS?"* Encryption without authorization is a confidential channel for actions you never intended to permit.

1. Right now, any *authenticated* mesh workload can call the backend. Prove it by adding a second in-mesh service that should have **no** business calling the backend.

   ```bash
   kubectl -n shop create deployment reporting --image=curlimages/curl:8.6.0 -- sleep infinity
   kubectl -n shop rollout status deploy/reporting     # gets a sidecar, so it's a valid mesh identity
   kubectl -n shop exec deploy/reporting -- curl -s http://backend:8080
   ```

   Expected: `hello from backend` — authenticated, but it *shouldn't* be authorized.

2. Apply a **deny-by-default** `AuthorizationPolicy` on the namespace, then an explicit allow scoped to the frontend's identity and the exact method/path.

   ```yaml
   # save as authz.yaml, then: kubectl apply -f authz.yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-all
     namespace: shop
   spec:
     {}                          # empty spec => deny all requests in the namespace
   ---
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: allow-frontend-get
     namespace: shop
   spec:
     selector:
       matchLabels: { app: backend }
     action: ALLOW
     rules:
       - from:
           - source:
               principals: ["cluster.local/ns/shop/sa/default"]
         to:
           - operation:
               methods: ["GET"]
               paths: ["/"]
   ```

   > Note: in this lab the `frontend`, `reporting`, and `attacker` pods all run under the `default` ServiceAccount, so `principals` alone cannot separate them — see the follow-up. First observe the deny-all effect.

3. Test the deny-all catches everything:

   ```bash
   kubectl -n shop exec deploy/frontend  -c curl -- curl -s -o /dev/null -w "%{http_code}\n" http://backend:8080
   ```

   Because all three share the `default` SA, the current rule allows them all. To make identity-based authorization *meaningful*, give the frontend its own ServiceAccount and re-scope.

4. Assign a dedicated identity to the frontend and tighten the rule.

   ```bash
   kubectl -n shop create serviceaccount frontend-sa
   kubectl -n shop patch deployment frontend \
     --type merge -p '{"spec":{"template":{"spec":{"serviceAccountName":"frontend-sa"}}}}'
   kubectl -n shop rollout status deploy/frontend
   ```

   ```yaml
   # replace the allow rule's principal
   # kubectl -n shop patch authorizationpolicy allow-frontend-get --type=json \
   #   -p='[{"op":"replace","path":"/spec/rules/0/from/0/source/principals","value":["cluster.local/ns/shop/sa/frontend-sa"]}]'
   ```

5. Test the three callers now:

   ```bash
   kubectl -n shop exec deploy/frontend  -c curl -- curl -s -o /dev/null -w "front: %{http_code}\n" http://backend:8080
   kubectl -n shop exec deploy/reporting        -- curl -s -o /dev/null -w "report: %{http_code}\n" http://backend:8080
   kubectl -n shop exec deploy/frontend  -c curl -- curl -s -o /dev/null -w "post: %{http_code}\n" -X POST http://backend:8080
   ```

   Expected:

   ```
   front: 200
   report: 403
   post: 403
   ```

   The 403 is returned by the backend's Envoy **before** the request ever reaches the application container.

**Comprehension check**

- **Q5.1** — In step 3, before you split the ServiceAccounts, `reporting` was still allowed. Root-cause it: why did `principals: ["cluster.local/ns/shop/sa/default"]` fail to express the intent, and what does this teach about mapping ServiceAccounts to workloads?
- **Q5.2** — An empty `AuthorizationPolicy` spec (`spec: {}`) denies all traffic, but *omitting* an AuthorizationPolicy entirely allows all traffic. Explain Istio's evaluation logic (ALLOW vs. DENY vs. no-policy) that produces this asymmetry, and the order in which DENY and ALLOW policies are evaluated.
- **Q5.3** — The `reporting` request got a `403` from Envoy, not a TCP reset. Contrast this with the NetworkPolicy denial in Q2.1 — what does each failure mode reveal (or leak) to the caller, and why does that difference matter for an attacker probing your services?
- **Q5.4** — Why is enforcing this rule in the sidecar (before the app) strictly better than implementing the same check in the backend's application code?

---

## Exercise 6 — Portable workload identity with SPIFFE/SPIRE

**Objective:** Istio's identity is great *inside* the mesh. But platforms are heterogeneous — VMs, multiple clusters, non-mesh workloads. SPIFFE is the vendor-neutral standard for workload identity (and it is exactly what Istio's SPIFFE IDs implement). Deploy SPIRE and issue an SVID to a bare pod so you understand the layer beneath the mesh.

1. Install the SPIRE server + agent via the community Helm chart.

   ```bash
   helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/
   helm repo update
   helm upgrade --install spire-crds spiffe/spire-crds \
     -n spire-mgmt --create-namespace
   helm upgrade --install spire spiffe/spire \
     -n spire-mgmt \
     --set global.spire.trustDomain=cluster.local
   kubectl -n spire-server get pods    # or the namespace the chart creates
   ```

2. Register an entry that binds a SPIFFE ID to a selector (here: a Kubernetes ServiceAccount). This is the *attestation policy* — "a workload matching these selectors is entitled to this identity."

   ```bash
   kubectl exec -n spire-server -c spire-server \
     $(kubectl -n spire-server get pod -l app.kubernetes.io/name=server -o jsonpath='{.items[0].metadata.name}') -- \
     /opt/spire/bin/spire-server entry create \
       -spiffeID spiffe://cluster.local/ns/shop/sa/frontend-sa \
       -parentID  spiffe://cluster.local/spire/agent/k8s_psat/<cluster>/<node-uid> \
       -selector  k8s:ns:shop \
       -selector  k8s:sa:frontend-sa
   ```

   Expected:

   ```
   Entry ID         : 9a1c...
   SPIFFE ID        : spiffe://cluster.local/ns/shop/sa/frontend-sa
   Parent ID        : spiffe://cluster.local/spire/agent/k8s_psat/...
   Selector         : k8s:ns:shop
   Selector         : k8s:sa:frontend-sa
   ```

3. From a workload that mounts the SPIRE agent socket, fetch the SVID with the Workload API and inspect it.

   ```bash
   kubectl -n shop exec deploy/frontend -c curl -- \
     /opt/spire/bin/spire-agent api fetch x509 \
     -socketPath /run/spire/sockets/agent.sock
   ```

   Expected excerpt:

   ```
   Received 1 svid after ...
   SPIFFE ID:  spiffe://cluster.local/ns/shop/sa/frontend-sa
   SVID Valid After:  2026-08-07 ...
   SVID Valid Until:  2026-08-07 ...   # ~1h later
   ```

**Comprehension check**

- **Q6.1** — SPIRE never ships a long-lived credential into the workload for it to prove *who it is*. Describe the two-stage attestation (node attestation, then workload attestation) and what the "root of trust" is in each stage.
- **Q6.2** — The registration entry uses selectors like `k8s:ns:shop` and `k8s:sa:frontend-sa` rather than an IP or a hostname. Why are these selectors a stronger binding, and what is the platform engineer's responsibility in curating them?
- **Q6.3** — Istio issues `spiffe://cluster.local/ns/shop/sa/frontend-sa` and so does SPIRE here. What does it mean that both use the SPIFFE format, and what does adopting SPIFFE as a platform standard buy you across meshes, clusters, and VMs?

---

## Exercise 7 — Managing the trust anchor: rotation and cross-domain trust

**Objective:** Every identity system rests on a CA. If you cannot rotate the root of trust and federate across domains, you have built a single point of failure. Understand the CA layer and bundle federation.

1. Inspect the CA Istio is using by default (self-signed, generated at install).

   ```bash
   kubectl -n istio-system get secret istio-ca-secret -o jsonpath='{.data.ca-cert\.pem}' \
     | base64 -d | openssl x509 -noout -subject -issuer -dates
   ```

   Expected — a self-signed root whose subject == issuer.

2. Understand production-grade rotation: plug an intermediate CA signed by *your* org root, using cert-manager as the issuer. Sketch (do not run against prod):

   ```yaml
   # cacerts wired from cert-manager output (conceptual)
   apiVersion: v1
   kind: Secret
   metadata:
     name: cacerts                 # Istio reads this at startup instead of self-signing
     namespace: istio-system
   type: Opaque
   data:
     ca-cert.pem:    <intermediate cert>
     ca-key.pem:     <intermediate key>
     root-cert.pem:  <org root cert>
     cert-chain.pem: <intermediate + root>
   ```

3. Understand cross-cluster / cross-mesh trust via SPIFFE **bundle federation**: two trust domains each publish their trust bundle; each configures the other as a `ClusterFederatedTrustDomain` so a workload in `cluster.local` can validate an SVID from `spiffe://prod.example.org`.

   ```yaml
   apiVersion: spire.spiffe.io/v1alpha1
   kind: ClusterFederatedTrustDomain
   metadata:
     name: prod-partner
   spec:
     trustDomain: prod.example.org
     bundleEndpointURL: https://spire.prod.example.org/bundle
     bundleEndpointProfile:
       type: https_spiffe
       endpointSPIFFEID: spiffe://prod.example.org/spire/server
   ```

**Comprehension check**

- **Q7.1** — Why is Istio's default self-signed CA acceptable for a lab but a liability for a regulated production platform, and what specifically does plugging an intermediate CA (step 2) let you do that the default does not?
- **Q7.2** — During a root CA rotation you must avoid an outage. Describe the "trust both, then switch" sequence: what must every workload trust *before* the new signing key is used, and why the order cannot be reversed.
- **Q7.3** — Bundle federation lets `cluster.local` accept identities from `prod.example.org`. What is the crucial thing federation does **not** grant, and which layer (from these exercises) still decides whether the federated identity may actually *do* anything?

---

## Cleanup

```bash
kubectl delete namespace shop outside --ignore-not-found
helm uninstall spire spire-crds -n spire-mgmt --ignore-not-found
kubectl delete namespace spire-mgmt spire-server --ignore-not-found
istioctl uninstall --purge -y
kubectl delete namespace istio-system --ignore-not-found
```

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.1** — The missing guarantees are (a) **confidentiality/integrity in transit** (the payload is plaintext, readable and tamperable by anyone on-path) and (b) **peer authentication** (neither side proved who it is). One does not imply the other: you can have an encrypted channel to an *unverified* peer (plain TLS to a spoofed service), or an authenticated but plaintext channel. Service-to-service security needs both — that is why **mutual** TLS (Exercise 3) and **authorization** (Exercise 5) are separate steps.

**Q1.2** — The "the network is trusted" assumption is the **perimeter / castle-and-moat** model: trust is a function of network location. The exercises replace it with **zero trust**: no implicit trust from network position; every request is authenticated (mTLS), authorized (AuthorizationPolicy), and encrypted, regardless of where it originates. Ref: https://istio.io/latest/docs/concepts/security/

**Q1.3** — The application container often can't see the wire before its own TLS termination, may lack `tcpdump`/`NET_RAW`, and (once a mesh is added) the *sidecar* handles TLS so the app only ever sees decrypted localhost traffic. Capturing at the **node** observes the actual pod-to-pod packets on the shared interface — the ground truth of what crosses the network.

**Q2.1** — A NetworkPolicy is enforced by the CNI's dataplane (iptables/eBPF), which **drops** packets silently rather than sending a TCP RST or ICMP unreachable. The client's SYN gets no SYN-ACK and no reset, so the TCP stack retransmits until it gives up → a **timeout**. A "connection refused" (RST) would instead mean the port was reachable but nothing was listening. The drop-vs-reset distinction is itself a security property: it leaks less.

**Q2.2** — Labels are **self-asserted metadata**, not identity — any principal who can create pods in the namespace (or edit a Deployment's pod template) can attach `app: frontend` to a pod they control and inherit its access. A malicious tenant in `shop` could deploy a pod labeled `app: frontend` and the policy would allow it. Real identity must be **cryptographically attested and issued by a trusted authority** (SPIFFE SVID / mTLS cert), which is what Exercises 3 and 6 provide.

**Q2.3** — These policies only cover **Ingress**. **Egress** is unrestricted — the backend (or a compromised pod) can still initiate connections anywhere (data exfiltration, C2, reaching the API server or metadata endpoint). Close it with a `default-deny-egress` policy (`policyTypes: ["Egress"]`, no egress rules) plus explicit allows for DNS (UDP/TCP 53 to kube-dns) and required destinations. Note also that once a policy selects a pod, it is default-deny *for that direction* — so a pod not selected by any policy is still fully open.

**Q3.1** — `spiffe://cluster.local/ns/shop/sa/default` decomposes as: `cluster.local` = the **trust domain** (the root of the identity namespace, tied to a CA); `ns/shop` = the Kubernetes **namespace**; `sa/default` = the **ServiceAccount**. The root of the identity is the **ServiceAccount**, not the pod, Deployment, or label — which is exactly why Exercise 5 had to give the frontend its own SA to make authorization meaningful.

**Q3.2** — Precedence is **most-specific-wins**: workload-level `PeerAuthentication` (with a `selector`) overrides namespace-level (in that namespace, no selector) which overrides mesh-level (in the Istio root namespace, `istio-system`). To exempt one legacy workload, apply a workload-scoped `PeerAuthentication` with a `selector` matching it and `mtls.mode: PERMISSIVE` (or `DISABLE`), which overrides the mesh-wide STRICT for that workload only. Ref: https://istio.io/latest/docs/reference/config/security/peer_authentication/

**Q3.3** — The application spoke plain HTTP to `localhost`; its **Envoy sidecar** transparently intercepted the outbound connection (via iptables/eBPF redirect), established mTLS to the destination pod's Envoy, and the destination Envoy decrypted and forwarded plaintext to the backend container on localhost. Encryption is added and removed by the sidecars — the app is oblivious. This is why it's a *platform* capability: zero application changes.

**Q3.4** — Short-lived, auto-rotated certs mean (1) a **stolen cert is useless within ~an hour** — no long-window replay; (2) **no manual rotation toil or expiry outages** at scale (thousands of workloads); (3) **revocation is implicit** — you stop re-issuing rather than distributing CRLs/OCSP, which don't scale. Long-lived `Secret`-managed certs become a sprawling inventory of high-value, rarely-rotated credentials — the opposite of least standing privilege.

**Q4.1** — The two objects are **`PeerAuthentication`** (does the connection require/validate mTLS — the *authentication* layer) and **`AuthorizationPolicy`** (is this authenticated principal allowed to perform this operation — the *authorization* layer). STRICT mTLS with no AuthorizationPolicy means *any* mesh identity is allowed (the Exercise 5 problem); an AuthorizationPolicy without STRICT mTLS can be bypassed by a plaintext caller with a spoofed identity claim. You need both.

**Q4.2** — The server's `PeerAuthentication` mode states the *policy* (what the server will accept), but PERMISSIVE mode, for example, accepts *both* mTLS and plaintext — so the mode alone doesn't tell you what a *particular* connection used. Proving a connection was mTLS requires inspecting the actual **filter chain / transport socket** in use (server listener uses `envoy.transport_sockets.tls`) and the client-side cluster's transport socket, plus that both chain to the expected CA. Policy ≠ observed behavior; verify the dataplane.

**Q4.3** — The field is `mtls.mode`, and the provable value is **`STRICT`**. `PERMISSIVE` (the migration default) accepts plaintext *and* mTLS simultaneously — so it can silently fall back and you cannot prove a given call was encrypted. Only `STRICT` guarantees no plaintext fallback, making the posture provable rather than aspirational.

**Q5.1** — All three pods shared the `default` ServiceAccount, so they all carried the SVID `.../sa/default` — the `principals` match couldn't distinguish them because *they were the same principal*. The lesson: **identity is per-ServiceAccount, so ServiceAccounts must be per-workload (or per-trust-boundary)**. Sharing `default` across workloads collapses their identities and makes fine-grained authorization impossible. Give every workload its own SA as a platform default.

**Q5.2** — Istio's rules: if a workload has **no** AuthorizationPolicy applied at all → **allow all** (default-allow, for backward compatibility). Once **any ALLOW policy** applies to a workload → default becomes **deny**, and only requests matching an ALLOW rule pass. **DENY policies are evaluated first** and take precedence; then ALLOW policies. An empty spec (`{}`) matches every request but defines no ALLOW rule, so with the deny-default-on-first-ALLOW logic it denies everything. Ref: https://istio.io/latest/docs/reference/config/security/authorization-policy/

**Q5.3** — NetworkPolicy denial = a silent **packet drop** → the caller sees a hang/timeout at L4 and learns almost nothing (not even whether the service exists). AuthorizationPolicy denial = an application-layer **HTTP 403** → the connection *succeeded* (mTLS handshake completed, TCP established), the caller learns the service is reachable and that it was authenticated but not authorized. The difference matters: the L7 path leaks more (existence, reachability) but enables audit logging of *who* was denied *what*; the L3/L4 drop is stealthier. Defense in depth uses both — segment first, then authorize.

**Q5.4** — Enforcing in the sidecar means: (1) the check is **uniform and centrally managed** — one policy object, not N app codebases in M languages; (2) the request is rejected **before it reaches application code**, shrinking attack surface (no app parsing of a malicious request); (3) it **cannot be forgotten or bypassed** by a new endpoint the developer didn't guard; (4) policy changes deploy **without redeploying the app**. It decouples security policy from application lifecycle — the essence of the platform-engineering value proposition.

**Q6.1** — **Node attestation**: the SPIRE agent proves the *node's* identity to the SPIRE server using a platform mechanism — e.g. `k8s_psat` (a projected ServiceAccount token the server validates against the Kubernetes API), or cloud instance-identity documents (AWS IID, GCP). Root of trust = the platform's own attestation authority (the K8s API / cloud metadata service). **Workload attestation**: when a workload calls the local agent's Workload API over the Unix socket, the agent inspects **kernel-verifiable attributes** of the calling process (its PID → namespace, ServiceAccount, container labels) that the workload cannot forge, and matches them to registration selectors. Root of trust = the OS kernel's process introspection. No bearer secret is ever handed to the workload to prove identity.

**Q6.2** — Selectors like `k8s:ns:shop` / `k8s:sa:frontend-sa` are **kernel/platform-verified facts about the running process**, not credentials the workload presents — they can't be copied or replayed the way a token or IP-based ACL can. IPs are reassigned and spoofable; hostnames are DNS-trust-dependent. The platform engineer owns the **registration entries (the attestation policy)**: they are the authoritative map from "workload with these attested properties" → "entitled to this SPIFFE ID," and a too-broad selector (e.g. only `ns:shop`) over-issues identity. Curating them tightly is the least-privilege control point.

**Q6.3** — Both emitting `spiffe://...` means they share the **SPIFFE identity standard** — a common URI format and X.509-SVID/JWT-SVID document spec (Istio's identity *is* a SPIFFE implementation). Adopting SPIFFE platform-wide gives you **one identity model that spans mesh and non-mesh, multiple clusters, VMs, and even different service meshes**, with interoperable trust bundles (federation) — instead of a per-tool, non-portable identity silo. It future-proofs identity against changing the mesh or runtime underneath it.

**Q7.1** — The default CA is **self-signed and generated at install**, its private key sits in a `Secret` in `istio-system`, and it chains to nothing your org controls — so you can't tie mesh identities into an existing PKI, can't be audited against a corporate root, and rotating/revoking it is all-or-nothing. Plugging an **intermediate CA signed by your org root** lets Istio issue workload certs that **chain to a trusted enterprise root**, enables **federation and cross-cluster trust under one root**, and lets you rotate the *intermediate* without touching the root distributed to every relying party. Ref: https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/

**Q7.2** — "Trust both, then switch": (1) **distribute the new root into every workload's trust bundle** (add it to `root-cert.pem` / the validation context) so all peers will *accept* certificates signed by the new root — while still signing with the old key; (2) only **after** every workload trusts the new root, **switch the signing key** to the new intermediate/root so new leaf certs are issued under it; (3) once all leaves have rotated, **remove the old root** from the bundles. The order is fixed because if you sign with a key nobody trusts yet, every mTLS handshake fails → outage. Trust must precede use.

**Q7.3** — Federation only establishes **authentication trust** — `cluster.local` can now *validate* that an SVID from `prod.example.org` is genuine. It does **not** grant any authorization: the federated identity still can't *do* anything until an **`AuthorizationPolicy`** (Exercise 5) explicitly permits that foreign principal to reach a specific service/operation. Authenticating "who you are" and authorizing "what you may do" remain separate layers — federation only extends the first across trust domains.

</details>