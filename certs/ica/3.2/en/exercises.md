# Exercises — Topic 3.2: Configuring Routing within a Service Mesh

> **Certification:** Istio Certified Associate (ICA) · **Domain:** Traffic Management · **Exam weight:** 5
> **What you will practice:** applying `VirtualService` + `DestinationRule` to control L7 routing inside the mesh — subset routing, weighted traffic shifting (canary), match-based routing, fault injection, timeouts, retries, request mirroring, ingress routing through a `Gateway`, and route diagnostics with `istioctl`.
>
> Every manifest below uses the stable API group `networking.istio.io/v1` (GA since Istio 1.22). On older meshes substitute `v1beta1`; the schema is identical for the fields used here.

---

## Exercise 0 — Prepare the mesh and the sample application

You need a running mesh with sidecar injection and the Bookinfo demo, whose `reviews` service ships three versions (`v1` = no stars, `v2` = black stars, `v3` = red stars). This makes routing changes *visible* in the product page.

1. Confirm the control plane is healthy and note the version:

   ```bash
   istioctl version
   ```

   ```
   client version: 1.24.1
   control plane version: 1.24.1
   data plane version: 1.24.1 (8 proxies)
   ```

2. Enable automatic sidecar injection on the target namespace and deploy Bookinfo:

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
   ```

3. Wait until every pod is `2/2` (app container **plus** the `istio-proxy` sidecar):

   ```bash
   kubectl get pods
   ```

   ```
   NAME                              READY   STATUS    RESTARTS   AGE
   details-v1-5f4d584748-8xk2z       2/2     Running   0          61s
   productpage-v1-564d4686f-2rl7q    2/2     Running   0          60s
   ratings-v1-686ccfb5d8-9nq4p       2/2     Running   0          61s
   reviews-v1-86896b7648-7t2sd       2/2     Running   0          60s
   reviews-v2-b7dcd98fb-4kd6l        2/2     Running   0          60s
   reviews-v3-5b9bd44f4-plj9m        2/2     Running   0          60s
   ```

4. Generate traffic from inside the mesh and observe that, with **no** routing rules, requests are load-balanced across all three `reviews` versions round-robin:

   ```bash
   for i in $(seq 1 6); do
     kubectl exec deploy/ratings-v1 -c ratings -- \
       curl -s http://productpage:9080/productpage | grep -o 'reviews-v[0-9]*' | head -1
   done
   ```

   ```
   reviews-v1
   reviews-v2
   reviews-v3
   reviews-v1
   reviews-v2
   reviews-v3
   ```

**Check your understanding — 0**

- **0.1** The pods show `2/2` rather than `1/1`. Which container is the second one, and *how* does it come to intercept the pod's traffic without any change to the application code?
- **0.2** With zero `VirtualService`/`DestinationRule` objects applied, why does traffic still reach all three `reviews` versions, and which component decides the distribution?

---

## Exercise 1 — Pin traffic with subsets (`DestinationRule` + `VirtualService`)

A `VirtualService` can only route to a **subset** if a `DestinationRule` has *defined* that subset from pod labels. You will pin all `reviews` traffic to `v1`.

1. Define the subsets for every Bookinfo service. Subsets are named groups of endpoints selected by label:

   ```yaml
   # destination-rules-all.yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     subsets:
       - name: v1
         labels:
           version: v1
       - name: v2
         labels:
           version: v2
       - name: v3
         labels:
           version: v3
   ---
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: ratings
   spec:
     host: ratings
     subsets:
       - name: v1
         labels:
           version: v1
   ```

   ```bash
   kubectl apply -f destination-rules-all.yaml
   ```

2. Route 100% of `reviews` to subset `v1`:

   ```yaml
   # vs-reviews-v1.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
       - reviews
     http:
       - route:
           - destination:
               host: reviews
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-reviews-v1.yaml
   ```

3. Validate the configuration with the static analyzer *before* trusting the runtime:

   ```bash
   istioctl analyze
   ```

   ```
   ✔ No validation issues found when analyzing namespace: default.
   ```

4. Re-run the traffic loop from Exercise 0.4. Every request must now hit `reviews-v1` (the version with no stars).

   ```
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   reviews-v1
   ```

5. Prove *why* a missing subset breaks routing: temporarily apply a `VirtualService` that points to `subset: v2` **without** the DestinationRule present and observe `istioctl analyze` flag it (then revert):

   ```
   Error [IST0101] (VirtualService reviews) Referenced host+subset in destinationrule not found: "reviews+v2"
   ```

**Check your understanding — 1**

- **1.1** What is the precise division of responsibility between the `DestinationRule` and the `VirtualService` here? Which object *names* a subset and which object *selects* it as a route target?
- **1.2** In `spec.host: reviews`, the value is a short name. What does Istio expand it to, and why is a bare short name a portability hazard across namespaces?
- **1.3** If you apply the `VirtualService` pointing at `subset: v2` but forget the `DestinationRule`, what does a client request receive at runtime, and which free check catches it before a user does?

---

## Exercise 2 — Match-based routing on an HTTP header

Route users identified by an `end-user: jason` header to `reviews v2`, and everyone else to `v1`. Order matters: Istio evaluates `http[]` rules **top to bottom** and takes the first match.

1. Apply the conditional routing:

   ```yaml
   # vs-reviews-header.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
       - reviews
     http:
       - match:
           - headers:
               end-user:
                 exact: jason
         route:
           - destination:
               host: reviews
               subset: v2
       - route:                     # default / fallthrough — no match block
           - destination:
               host: reviews
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-reviews-header.yaml
   ```

2. In the Bookinfo product page, log in as user **jason** (any password). The reviews panel now shows **black stars** (`v2`). Log in as any other user, or browse anonymously — you see **no stars** (`v1`).

3. Confirm the header origin: the `productpage` service is what forwards the `end-user` header downstream to `reviews`. Inspect the effective route the sidecar compiled:

   ```bash
   istioctl proxy-config routes deploy/productpage-v1 --name 9080 -o json | \
     jq '.[0].virtualHosts[].routes[] | {match, route: .route.cluster}'
   ```

   ```json
   {
     "match": { "headers": [ { "name": "end-user", "exactMatch": "jason" } ], "prefix": "/" },
     "route": "outbound|9080|v2|reviews.default.svc.cluster.local"
   }
   {
     "match": { "prefix": "/" },
     "route": "outbound|9080|v1|reviews.default.svc.cluster.local"
   }
   ```

**Check your understanding — 2**

- **2.1** If you swap the order of the two `http[]` entries (default rule first), what happens to jason's traffic, and why?
- **2.2** A route entry with a `match` block **and** a route entry without one both appear. What is the role of the match-less entry, and what would a request that matches *no* rule receive if it were removed?
- **2.3** The Envoy cluster name is `outbound|9080|v2|reviews.default.svc.cluster.local`. Decode each of the four `|`-separated fields.

---

## Exercise 3 — Weighted traffic shifting (canary release)

Roll `reviews` from `v1` toward `v3` (red stars) in stages using `weight`. This is the mechanism behind canary and blue/green.

1. Send 90% to `v1`, 10% to `v3`:

   ```yaml
   # vs-reviews-canary.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
       - reviews
     http:
       - route:
           - destination:
               host: reviews
               subset: v1
             weight: 90
           - destination:
               host: reviews
               subset: v3
             weight: 10
   ```

   ```bash
   kubectl apply -f vs-reviews-canary.yaml
   ```

2. Drive 100 requests and count the split empirically:

   ```bash
   for i in $(seq 1 100); do
     kubectl exec deploy/ratings-v1 -c ratings -- \
       curl -s http://productpage:9080/productpage | grep -o 'reviews-v[0-9]*' | head -1
   done | sort | uniq -c
   ```

   ```
      91 reviews-v1
       9 reviews-v3
   ```

3. Promote to 50/50, then to 100% `v3`, re-applying the same object each time (the shift is atomic — no dropped connections):

   ```bash
   kubectl patch virtualservice reviews --type=merge -p \
     '{"spec":{"http":[{"route":[{"destination":{"host":"reviews","subset":"v1"},"weight":50},{"destination":{"host":"reviews","subset":"v3"},"weight":50}]}]}}'
   ```

**Check your understanding — 3**

- **3.1** Weighted routing splits traffic by *percentage of requests*, not by number of pods. Why is this fundamentally different from a plain Kubernetes `Service` that fronts a mix of `v1` and `v3` pods, and what happens to the ratio if `v3` is scaled from 1 to 5 replicas under each model?
- **3.2** The two `weight` values are `90` and `10`. What is the required constraint on the sum of weights within a single route, and what does Istio do if they sum to less than 100?
- **3.3** Header-based routing (Exercise 2) and weighted routing (this exercise) are both expressed as `http[]` entries. Can they coexist in one `VirtualService`, and if so how would you canary *only* jason's traffic?

---

## Exercise 4 — Fault injection: delay and abort

Fault injection tests resilience by making the mesh *itself* inject errors, with no change to any service. Use the `ratings` service.

1. Inject a **7-second delay** into 100% of jason's `ratings` calls:

   ```yaml
   # vs-ratings-delay.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: ratings
   spec:
     hosts:
       - ratings
     http:
       - match:
           - headers:
               end-user:
                 exact: jason
         fault:
           delay:
             percentage:
               value: 100
             fixedDelay: 7s
         route:
           - destination:
               host: ratings
               subset: v1
       - route:
           - destination:
               host: ratings
               subset: v1
   ```

   ```bash
   kubectl apply -f vs-ratings-delay.yaml
   ```

2. Log in as **jason** and load the product page. Because `reviews:v2` calls `ratings` with a hard-coded **10s** timeout but retries once (~2×3.5s ≈ 7s budget), the page renders an error long before 7s elapses:

   ```
   Error fetching product reviews!
   Sorry, product reviews are currently unavailable for this book.
   ```

   This is a **latent bug surfaced by the mesh**: the delay (7s) is under the service's own 10s timeout, yet the page still fails — revealing an inconsistency between the client's retry math and the declared timeout.

3. Replace the delay with an **HTTP 500 abort** on 100% of jason's traffic:

   ```yaml
       fault:
         abort:
           percentage:
             value: 100
           httpStatus: 500
   ```

   ```bash
   kubectl apply -f vs-ratings-abort.yaml
   ```

   Reloading as jason now fails **immediately** (`Ratings service is currently unavailable`) instead of hanging.

**Check your understanding — 4**

- **4.1** Fault injection is scoped by the same `match` block as normal routing. What guarantees that only *jason's* requests are delayed while every other user's traffic to `ratings` is untouched?
- **4.2** Contrast the failure signature a user perceives from `delay` versus `abort`. Which one is the right tool to test a *timeout/retry* configuration, and which tests *error-handling* logic?
- **4.3** The injected delay is enforced by the sidecar proxy, not the `ratings` application. On the *client* side or the *server* side of the connection does Envoy hold the request, and why does that distinction matter for what the `ratings` app's own logs show?

---

## Exercise 5 — Timeouts and retries

Timeouts and retries are declared on the route, overriding Envoy's default (no request timeout; automatic retries off unless configured).

1. Add a half-second timeout to the `reviews` route so a slow upstream fails fast:

   ```yaml
   # vs-reviews-timeout.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: reviews
   spec:
     hosts:
       - reviews
     http:
       - route:
           - destination:
               host: reviews
               subset: v2
         timeout: 0.5s
   ```

   ```bash
   kubectl apply -f vs-reviews-timeout.yaml
   ```

2. Keep the 2-second `ratings` delay from Exercise 4 in place. Because `reviews:v2` calls `ratings`, the 0.5s `reviews` timeout now trips first. The product page returns in ~0.5s with a reviews error instead of waiting on `ratings`:

   ```
   Error fetching product reviews!
   ```

3. Add a retry policy to `ratings` so transient upstream failures are retried before the caller sees them:

   ```yaml
   # vs-ratings-retry.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: ratings
   spec:
     hosts:
       - ratings
     http:
       - route:
           - destination:
               host: ratings
               subset: v1
         retries:
           attempts: 3
           perTryTimeout: 2s
           retryOn: gateway-error,connect-failure,refused-stream
   ```

   ```bash
   kubectl apply -f vs-ratings-retry.yaml
   ```

4. Confirm the retry policy compiled into the proxy config:

   ```bash
   istioctl proxy-config routes deploy/reviews-v2 --name 9080 -o json | \
     jq '.[0].virtualHosts[].routes[].route.retryPolicy | {numRetries, perTryTimeout, retryOn}'
   ```

   ```json
   {
     "numRetries": 3,
     "perTryTimeout": "2s",
     "retryOn": "gateway-error,connect-failure,refused-stream"
   }
   ```

**Check your understanding — 5**

- **5.1** With `attempts: 3` and `perTryTimeout: 2s`, what is the *maximum* wall-clock time `ratings` retries can consume, and how does an overall route `timeout` interact with (and cap) that budget?
- **5.2** `retryOn: gateway-error,connect-failure,refused-stream` is set. Why is it deliberate *not* to retry on, say, an HTTP `400`, and what class of failures does `gateway-error` cover?
- **5.3** A route timeout of `0.5s` sits above a service that itself has `perTryTimeout: 2s` downstream. Explain how a too-tight outer timeout can defeat an inner retry policy entirely.

---

## Exercise 6 — Request mirroring (traffic shadowing)

Mirroring sends a *copy* of live traffic to a second version and **discards the response** — a way to test `v2` against production load with zero user impact. Deploy `httpbin` in two versions for this.

1. Deploy `httpbin-v1` and `httpbin-v2` (both labelled `app: httpbin`, differing `version`) and a `Service`, then define subsets:

   ```yaml
   # dr-httpbin.yaml
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: httpbin
   spec:
     host: httpbin
     subsets:
       - name: v1
         labels:
           version: v1
       - name: v2
         labels:
           version: v2
   ```

2. Send all live traffic to `v1` and mirror 100% of it to `v2`:

   ```yaml
   # vs-httpbin-mirror.yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
   spec:
     hosts:
       - httpbin
     http:
       - route:
           - destination:
               host: httpbin
               subset: v1
             weight: 100
         mirror:
           host: httpbin
           subset: v2
         mirrorPercentage:
           value: 100.0
   ```

   > In the `v1` API this may also be written as a `mirrors:` list of `HTTPMirrorPolicy` (each with `destination` + `percentage`); `mirror`/`mirrorPercentage` remain valid and are shown here for clarity.

   ```bash
   kubectl apply -f vs-httpbin-mirror.yaml
   ```

3. Send a request from a client pod and then tail *both* versions' logs:

   ```bash
   kubectl exec deploy/sleep -c sleep -- curl -s http://httpbin:8000/headers >/dev/null

   kubectl logs deploy/httpbin-v1 -c httpbin | tail -1
   kubectl logs deploy/httpbin-v2 -c httpbin | tail -1
   ```

   ```
   # v1 (primary):
   GET /headers HTTP/1.1" 200 ... host: httpbin
   # v2 (mirrored):
   GET /headers HTTP/1.1" 200 ... host: httpbin-shadow
   ```

   Note the mirrored request arrives at `v2` with the `Host`/`Authority` header suffixed with **`-shadow`** — the mesh's marker that this is shadowed, fire-and-forget traffic.

**Check your understanding — 6**

- **6.1** The primary route has `weight: 100` to `v1` and mirrors to `v2`. What does the *client* receive — `v1`'s response, `v2`'s, or both — and what happens to `v2`'s response?
- **6.2** Why does Istio rewrite the mirrored request's `Host` header to `httpbin-shadow`? What real-world hazard does that guard against when `v2` writes to a database?
- **6.3** You set `mirrorPercentage.value: 100.0`. Give a production reason you would mirror only, say, 5% instead of 100%.

---

## Exercise 7 — Ingress routing through a `Gateway`

Everything so far routed *east-west* (mesh-internal). To route *north-south* traffic from outside the cluster, a `VirtualService` must be **bound to a `Gateway`** and use the gateway's external host.

1. Create the ingress gateway and bind a `VirtualService` that exposes only the Bookinfo product-page paths:

   ```yaml
   # bookinfo-gateway.yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: bookinfo-gateway
   spec:
     selector:
       istio: ingressgateway          # matches the istio-ingressgateway pods
     servers:
       - port:
           number: 80
           name: http
           protocol: HTTP
         hosts:
           - "*"
   ---
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: bookinfo
   spec:
     hosts:
       - "*"
     gateways:
       - bookinfo-gateway             # binds this VS to the gateway
     http:
       - match:
           - uri:
               exact: /productpage
           - uri:
               prefix: /static
           - uri:
               exact: /login
           - uri:
               exact: /logout
           - uri:
               prefix: /api/v1/products
         route:
           - destination:
               host: productpage
               port:
                 number: 9080
   ```

   ```bash
   kubectl apply -f bookinfo-gateway.yaml
   istioctl analyze
   ```

2. Resolve the external address and curl through the gateway:

   ```bash
   export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   export INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

   curl -sSI "http://$INGRESS_HOST:$INGRESS_PORT/productpage" | head -1
   ```

   ```
   HTTP/1.1 200 OK
   ```

3. Confirm a *non-exposed* path is rejected at the gateway (only the whitelisted URIs are routed):

   ```bash
   curl -sSI "http://$INGRESS_HOST:$INGRESS_PORT/etc/passwd" | head -1
   ```

   ```
   HTTP/1.1 404 Not Found
   ```

**Check your understanding — 7**

- **7.1** The `Gateway` and the `VirtualService` are two separate objects. What does each one define — and what specifically links them together so the VS's rules actually apply to inbound gateway traffic?
- **7.2** `spec.selector: istio: ingressgateway` appears on the `Gateway`. What does that label select, and what would happen if no pod carried that label?
- **7.3** A mesh-internal `VirtualService` (e.g. `reviews`) has **no** `gateways:` field. What is the implicit default value of `gateways`, and why does that keep internal and ingress routing rules from leaking into each other?

---

## Exercise 8 — Diagnose routing with `istioctl`

When routing "doesn't work," the answer is almost always in the compiled Envoy config, not the YAML. Practice the core diagnostic commands.

1. Get a single, human-readable summary of everything affecting one pod's traffic — the fastest triage tool:

   ```bash
   istioctl experimental describe pod "$(kubectl get pod -l app=reviews,version=v2 -o jsonpath='{.items[0].metadata.name}')"
   ```

   ```
   Pod: reviews-v2-b7dcd98fb-4kd6l
      Pod Revision: default
      Pod Ports: 9080 (reviews), 15090 (istio-proxy)
   --------------------
   Service: reviews
      Port: http 9080/HTTP targets pod port 9080
   DestinationRule: reviews for "reviews"
      Matching subsets: v2
         (Non-matching subsets v1,v3)
   VirtualService: reviews
      WeightedRoute to reviews.default.svc.cluster.local subset v2 weight 50
   ```

2. List the routes a caller's sidecar knows for port 9080, and dump one to JSON to see match order and clusters:

   ```bash
   istioctl proxy-config routes deploy/productpage-v1 --name 9080
   ```

   ```
   NAME     VHOST NAME                      DOMAINS     MATCH                  VIRTUAL SERVICE
   9080     reviews.default.svc.cluster...  reviews     /* (end-user=jason)    reviews.default
   9080     reviews.default.svc.cluster...  reviews     /*                     reviews.default
   ```

3. Confirm the caller's sidecar has actually *received* the latest config from the control plane (the #1 cause of "my rule isn't taking effect"):

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                             CDS      LDS      EDS      RDS      ISTIOD                  VERSION
   productpage-v1.default           SYNCED   SYNCED   SYNCED   SYNCED   istiod-6b8...           1.24.1
   reviews-v2.default               SYNCED   SYNCED   SYNCED   SYNCED   istiod-6b8...           1.24.1
   ```

**Check your understanding — 8**

- **8.1** `istioctl proxy-config routes` is run against `deploy/productpage-v1`, **not** against `reviews`. Why must you inspect the routes on the *caller's* sidecar to debug how traffic reaches `reviews`?
- **8.2** In `istioctl proxy-status`, one row shows `RDS  STALE` instead of `SYNCED`. What does that specifically tell you about your just-applied `VirtualService`, and where is the fault — the YAML, `istiod`, or the data plane?
- **8.3** `istioctl experimental describe pod` reports `Matching subsets: v2 (Non-matching subsets v1,v3)`. In one sentence, what does that line let you verify at a glance about your `DestinationRule`?

---

## Answers

<details>
<summary>Click to reveal answers for all exercises</summary>

**Exercise 0**

- **0.1** The second container is the `istio-proxy` (Envoy) sidecar, injected automatically because the namespace carries `istio-injection=enabled` (a mutating admission webhook rewrites the pod spec at creation). An init container (`istio-init`, or the CNI plugin) installs `iptables` rules that redirect the pod's inbound and outbound TCP through the sidecar's ports (15006 inbound / 15001 outbound). The application is unaware; it still binds and dials normally, but every packet transits Envoy.
- **0.2** Traffic reaches all three versions because the plain Kubernetes `Service reviews` selects all pods labelled `app: reviews` regardless of `version`, and its `Endpoints` list contains v1/v2/v3. With no Istio routing rule, the sidecar simply load-balances across all healthy endpoints of that service (default round-robin / least-request). The **Envoy sidecar of the caller** performs client-side load balancing — not kube-proxy.

**Exercise 1**

- **1.1** The `DestinationRule` *names and defines* subsets — it maps a subset name (`v1`) to a label selector (`version: v1`) applied after the service's endpoints are resolved. The `VirtualService` *selects* a subset as a route destination (`destination.host + subset`). A `VirtualService` cannot invent a subset; the subset must already exist in a `DestinationRule` for the same host.
- **1.2** Istio expands the short name `reviews` to the FQDN of the caller's own namespace: `reviews.default.svc.cluster.local`. A bare short name resolves relative to the *client's* namespace, so the identical rule applied in another namespace silently points at a different service. In shared/multi-namespace configs, always use the FQDN.
- **1.3** At runtime the client gets **HTTP 503** with `NR` (No Route / no healthy upstream) because the referenced cluster `outbound|9080|v2|...` has no endpoints defined. `scripts/check` equivalents / `istioctl analyze` catch it statically as **IST0101** ("Referenced host+subset in destinationrule not found") before it reaches a user.

**Exercise 2**

- **2.1** jason would be routed to `v1`, never `v2`. Istio evaluates `http[]` first-match-wins from top to bottom; a match-less default rule at the top matches *everything*, so it short-circuits and the header rule below it becomes dead code. Specific rules must precede the catch-all.
- **2.2** The match-less entry is the **default / fallthrough** route: it has no `match` block so it matches any request that fell through the preceding conditional rules. If removed, a request that matches no rule has no route and receives **HTTP 404** (`NR`) — the `VirtualService` "captures" the host but offers no destination for it.
- **2.3** `outbound` = traffic direction (client-side, leaving the pod) · `9080` = the destination service port · `v2` = the DestinationRule subset · `reviews.default.svc.cluster.local` = the destination service FQDN. This four-tuple is Envoy's cluster name.

**Exercise 3**

- **3.1** Istio weighting is **request-proportional at L7**: 90/10 means 90% of *requests* go to `v1` regardless of replica counts. A plain Service load-balances across *endpoints*, so the split follows the pod ratio. Under Istio, scaling `v3` from 1→5 replicas keeps the 10% share (traffic is then spread across the 5 v3 pods). Under a plain Service, scaling `v3` to 5 pods (vs 1 v1 pod) shifts ~83% of traffic to v3 — the ratio is an accident of replica counts, which is exactly why weighted VirtualService routing exists.
- **3.2** The weights within one route **must sum to 100**. If they sum to less than 100 the configuration is rejected/flagged (`istioctl analyze` warns), and a single-destination route may omit `weight` entirely (implicitly 100). You cannot rely on "the rest goes somewhere" — every percent must be accounted for.
- **3.3** Yes. Put a `match` (e.g. `end-user: jason`) block whose `route` carries the weighted split (say v1:90/v3:10) **first**, and a match-less default route (all → v1) second. Only jason's traffic is canaried; everyone else stays on the stable version. Match rules and weighted routes compose because a single `http[]` entry can hold both a `match` and a multi-destination weighted `route`.

**Exercise 4**

- **4.1** The `fault` block lives *inside* the same `http[]` entry as its `match: end-user=jason`. Fault injection is applied only to requests that satisfy that match; the second, match-less route entry carries no `fault`, so all other users pass through untouched. Fault scope = match scope.
- **4.2** `delay` makes the request *hang* then (usually) succeed late — the user perceives slowness/timeouts; it is the right tool to test **timeout and retry** behaviour and cascading-latency budgets. `abort` returns an immediate error code (e.g. 500) — the user perceives a hard failure; it is the right tool to test **error-handling / circuit-breaking / fallback** logic. Delay tests "too slow"; abort tests "broke."
- **4.3** The delay is enforced by the **client-side sidecar** (the Envoy of the caller, e.g. `reviews-v2`'s proxy holds the outbound request before dispatch). It matters because the `ratings` application itself never sees the added latency — its own access logs show normal, fast responses — so a developer grepping `ratings` logs for the slowness finds nothing; the latency exists only in the mesh, between the services.

**Exercise 5**

- **5.1** Worst case ≈ `attempts × perTryTimeout` = `3 × 2s = 6s` of retry budget. However, an overall route `timeout` is a hard cap on the *entire* request including all retries: if `timeout: 5s`, retries stop the moment 5s elapses even if attempt 3 hasn't run. The route timeout always wins over the retry budget.
- **5.2** A `400` is a *client* error — the request is malformed; retrying it sends the same bad request and will fail identically while adding load, so it must not be retried. `gateway-error` covers 502/503/504 (upstream unreachable/overloaded/timed out) — genuinely transient conditions where a fresh attempt to a different endpoint can succeed. Retry only idempotent, server-side-transient failures.
- **5.3** If the outer route `timeout` (0.5s) is shorter than even one `perTryTimeout` (2s), the request is aborted by the outer timeout before the first attempt can complete, so attempts 2 and 3 never run — the retry policy is effectively dead. The overall timeout must exceed `attempts × perTryTimeout` (plus jitter) for retries to have room to work.

**Exercise 6**

- **6.1** The client receives **only `v1`'s response**. The mirror to `v2` is *fire-and-forget*: Envoy sends a full copy of the request to `v2` but **discards `v2`'s response entirely** (success, error, or latency on `v2` never reaches the client). Mirroring is observation-only.
- **6.2** The `-shadow` suffix on the `Host`/`Authority` header marks the request as shadowed so downstream code can detect and *no-op side effects*. The hazard it guards against: if `v2` shares a database with `v1` and blindly processes the mirrored request, it would perform **double writes** (duplicate orders, double-charged payments) from a single real user action. Shadow traffic must be treated as read-only.
- **6.3** Mirroring doubles the load on your dependencies (DB, downstream services, the `v2` deployment). At 100% you fully load-test `v2` but also double DB read pressure and risk overwhelming an under-provisioned canary; a small percentage (5%) gives a representative sample of real traffic shapes while keeping the extra load — and blast radius of any `v2` bug — bounded.

**Exercise 7**

- **7.1** The `Gateway` defines the *edge listener* — which ports/protocols/hosts the ingress proxy accepts (L4–L6: port 80, HTTP, host `*`). The `VirtualService` defines the *routing rules* — which paths map to which internal service. They are linked by the VS's `spec.gateways: [bookinfo-gateway]` field (and matching `hosts`); without that binding the VS applies only to mesh-internal traffic and the gateway accepts connections but has nowhere to route them.
- **7.2** `selector: istio: ingressgateway` selects the running ingress-gateway **pods** carrying that label (the `istio-ingressgateway` deployment in `istio-system`). The Gateway's listener config is pushed to those pods. If no pod carries the label, the Gateway resource is valid but *nothing* implements it — the listener never opens and external requests are refused/unrouted.
- **7.3** The implicit default is `gateways: ["mesh"]` — the reserved keyword meaning "all sidecars in the mesh." So an internal `VirtualService` applies to sidecar-to-sidecar traffic only. Because ingress-bound rules must *explicitly* list a named gateway, and internal rules default to `mesh`, the two sets don't overlap — ingress routing and east-west routing stay isolated unless you deliberately list both (`["mesh", "bookinfo-gateway"]`).

**Exercise 8**

- **8.1** In Istio, routing decisions are made by the **caller's client-side sidecar** at the moment it dispatches an outbound request. The `reviews` sidecars only see *inbound* traffic already destined for them; they don't decide subset/weight. So to debug how `productpage` reaches `reviews`, you inspect the routes compiled into `productpage`'s Envoy — that's where the `VirtualService`/`DestinationRule` for `reviews` actually takes effect.
- **8.2** `RDS STALE` means the **R**oute **D**iscovery config for that proxy has been computed/pushed by `istiod` but the data-plane Envoy hasn't yet ACKed applying it (or the two disagree). It tells you your `VirtualService` change *has* reached `istiod` and is being distributed, but the proxy hasn't converged yet — the fault is in propagation/convergence (transient, or a proxy under pressure), not in the YAML (which would show as an analyze error) and not a total `istiod` failure (which would show all rows stale). Wait/retry; if persistent, inspect that pod's proxy.
- **8.3** It confirms at a glance that your `DestinationRule` subsets' label selectors correctly match this pod — `v2` matched, so the subset labels line up with the pod's `version: v2` label (a mismatch would show the subset as non-matching or missing, explaining a `503 NR`).

</details>

---

### Sources

- Istio — Request Routing task: https://istio.io/latest/docs/tasks/traffic-management/request-routing/
- Istio — Traffic Shifting task: https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/
- Istio — Fault Injection task: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/
- Istio — Setting Request Timeouts: https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/
- Istio — Mirroring task: https://istio.io/latest/docs/tasks/traffic-management/mirroring/
- Istio — Ingress Gateways task: https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
- Istio — `VirtualService` reference: https://istio.io/latest/docs/reference/config/networking/virtual-service/
- Istio — `DestinationRule` reference: https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — `Gateway` reference: https://istio.io/latest/docs/reference/config/networking/gateway/
- Istio — Debugging Envoy and Istiod / `istioctl proxy-config`, `proxy-status`, `describe`: https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — Bookinfo sample application: https://istio.io/latest/docs/examples/bookinfo/
- CNCF ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf