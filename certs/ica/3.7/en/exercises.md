# Topic 3.7 — Using Fault Injection

> **Scope (ICA, exam weight 5).** Fault injection lets you *deliberately* introduce failures — added latency and HTTP/gRPC error responses — into requests that match a route, without changing a single line of application code. It is the mesh's tool for **resilience testing**: you validate that timeouts, retries, circuit breakers and graceful-degradation logic actually behave the way the design assumes. In Istio this is a field of the `VirtualService` HTTP route: `spec.http[].fault`, with two independent sub-objects, `delay` and `abort`.
>
> **Key mental model you must carry through this lab:** the fault is injected by the **Envoy proxy of the *client* (the caller)**, on the *outbound* route toward the destination host — not by the destination's sidecar and not by the destination app. The destination may never even see the request (an `abort` short-circuits locally). This single fact explains every diagnostic step below.
>
> **Reference sources (official):**
> - Task: `https://istio.io/latest/docs/tasks/traffic-management/fault-injection/`
> - API — `HTTPFaultInjection`: `https://istio.io/latest/docs/reference/config/networking/virtual-service/#HTTPFaultInjection`
> - API — `Delay` / `Abort` / `Percent`: same page, anchors `#HTTPFaultInjection-Delay`, `#HTTPFaultInjection-Abort`, `#Percent`
> - Envoy fault filter (underlying implementation): `https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/fault_filter`

---

## Exercise 0 — Build a deterministic lab environment

We use two of Istio's stock sample workloads so every result is reproducible: `httpbin` (the destination) and `sleep` (a curl-equipped client). A dedicated namespace with automatic sidecar injection keeps the blast radius contained.

1. Create the namespace and enable injection, then deploy both workloads:

   ```bash
   kubectl create namespace fault-lab
   kubectl label namespace fault-lab istio-injection=enabled

   kubectl apply -n fault-lab -f samples/httpbin/httpbin.yaml
   kubectl apply -n fault-lab -f samples/sleep/sleep.yaml
   ```

2. Confirm each pod has **two** containers (app + `istio-proxy`) and is `Running`:

   ```bash
   kubectl get pods -n fault-lab
   ```

   Expected (the `2/2` is the sidecar proof):

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7b8b9c8f9d-4qk2t   2/2     Running   0          40s
   sleep-6c4f8d7b5-9xr7p      2/2     Running   0          38s
   ```

3. Capture the client pod name and run a baseline call. `httpbin`'s `/status/200` echoes back the code you ask for, so this is a clean control:

   ```bash
   export CLIENT=$(kubectl get pod -n fault-lab -l app=sleep -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Expected baseline (no VirtualService yet, so mesh default routing applies):

   ```
   code=200 time=0.012s
   ```

**Comprehension check 0**
1. Both pods report `2/2` even though `httpbin.yaml` defines a single application container. Where did the second container come from, and what triggered it?
2. When you eventually apply a fault to the `httpbin` host, which pod's Envoy will actually execute the fault logic — `sleep`'s or `httpbin`'s? Why does that matter for *where you look* when debugging?

---

## Exercise 1 — Inject an HTTP delay fault

A `delay` fault holds the request in the client proxy for a fixed duration **before** forwarding it upstream. Use it to simulate a slow dependency, network congestion, or an overloaded backend.

1. Apply a VirtualService that delays **100%** of traffic to `httpbin` by 5 seconds:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         delay:
           percentage:
             value: 100
           fixedDelay: 5s
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-delay.yaml
   ```

2. Measure the round trip. The request still **succeeds** — a delay does not fail the request, it only slows it:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Expected:

   ```
   code=200 time=5.013s
   ```

3. Make it *partial*. Edit `percentage.value` to `50`, re-apply, and fire ten requests. Because each request draws an independent Bernoulli sample, you will see roughly — not exactly — half delayed:

   ```yaml
         delay:
           percentage:
             value: 50
           fixedDelay: 5s
   ```

   ```bash
   for i in $(seq 1 10); do
     kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
       curl -s -o /dev/null -w "%{time_total}s\n" http://httpbin:8000/status/200
   done
   ```

   Expected (order and exact split vary — this is a sample, not a rota):

   ```
   0.011s
   5.010s
   5.009s
   0.010s
   0.012s
   5.011s
   0.011s
   5.010s
   0.010s
   5.012s
   ```

**Comprehension check 1**
1. A colleague sets `percentage: { value: 0.5 }` intending "half of all requests" and reports that "almost nothing gets delayed." What did they actually configure, and what value did they want?
2. The delayed requests returned `code=200`, not an error. In one sentence, what real-world failure mode is a pure `delay` fault meant to test?
3. With `value: 50`, is it guaranteed that exactly 5 of 10 requests are delayed? Explain the sampling model.

---

## Exercise 2 — Inject an HTTP abort fault

An `abort` fault makes the client proxy synthesize an error response **locally** and return it immediately; the upstream destination is **never contacted** for the aborted requests.

1. Replace the delay with an abort that returns HTTP `500` for **100%** of traffic:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         abort:
           percentage:
             value: 100
           httpStatus: 500
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-abort.yaml
   ```

2. Call the service and inspect the **body**, not just the code. Envoy stamps a signature string:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -w "\ncode=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Expected:

   ```
   fault filter abort
   code=500 time=0.006s
   ```

3. Prove the destination was bypassed. Ask `httpbin` for `/status/200` — a code it *would* have returned `200` for — and note you still get `500` in ~0 ms, far faster than any real backend round trip. (For gRPC destinations you would instead set `grpcStatus`, e.g. `grpcStatus: 14` for `UNAVAILABLE`, rather than `httpStatus`.)

4. Dial it back to `percentage.value: 50` for a realistic "one dependency is flapping" scenario, then re-apply and re-run the 10-request loop from Exercise 1 (swap the write-out to `%{http_code}`).

**Comprehension check 2**
1. The abort responses came back in ~6 ms while a normal call to `httpbin` also took ~12 ms — but the abort *never reached* `httpbin`. Where was the `500` generated?
2. You want to test how a caller handles a service being *completely gone* versus *slow*. Which fault type models each, and why can't a single fault do both jobs at once for the same request in the simple form above?
3. What is the significance of the body string `fault filter abort` when triaging a `500` in production — how does it let you distinguish an injected fault from a genuine application error?

---

## Exercise 3 — Scope the fault: control the blast radius with `match`

Injecting a fault into 100% of a shared service in a real cluster is reckless. The professional pattern is to gate the fault behind a `match` condition — typically a header your test harness sets — so only *your* synthetic traffic is affected while everyone else routes normally.

1. Apply a VirtualService with **two** ordered routes: a matched route that aborts, and a catch-all route that behaves normally. Order matters — Istio evaluates `http[]` top to bottom and takes the first match:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - match:
       - headers:
           x-fault-test:
             exact: "true"
       fault:
         abort:
           percentage:
             value: 100
           httpStatus: 503
       route:
       - destination:
           host: httpbin
     - route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-scoped.yaml
   ```

2. Normal traffic — **no** header — is untouched:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "no-header  code=%{http_code}\n" \
     http://httpbin:8000/status/200
   ```

   Expected:

   ```
   no-header  code=200
   ```

3. Test traffic — carrying the header — hits the fault:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "with-header code=%{http_code}\n" \
     -H "x-fault-test: true" http://httpbin:8000/status/200
   ```

   Expected:

   ```
   with-header code=503
   ```

**Comprehension check 3**
1. If you *swapped* the order of the two `http[]` entries (catch-all first), what would happen to a request carrying `x-fault-test: true`, and why?
2. In a shared staging cluster used by five teams, why is a header-gated fault dramatically safer than the 100%-abort VirtualService from Exercise 2?
3. The fault sits on the *matched* route only. If a request matches the second (catch-all) route, does it experience any fault? What does this tell you about the relationship between `match`, `fault` and `route` within a single HTTP route entry?

---

## Exercise 4 — Uncover a hidden timeout bug (delay × timeout interaction)

This is the flagship reason fault injection exists on the exam: it reveals mismatches between a dependency's real latency and the timeout a caller assumes. We build the mismatch deterministically.

1. Apply a route that **both** injects a 5 s delay **and** declares a 3 s request timeout on the same destination:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: fault-lab
   spec:
     hosts:
     - httpbin
     http:
     - fault:
         delay:
           percentage:
             value: 100
           fixedDelay: 5s
       timeout: 3s
       route:
       - destination:
           host: httpbin
   ```

   ```bash
   kubectl apply -f httpbin-delay-timeout.yaml
   ```

2. Call it and watch the timeout win the race — the request fails at ~3 s, not at 5 s:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code} time=%{time_total}s\n" \
     http://httpbin:8000/status/200
   ```

   Expected:

   ```
   code=504 time=3.010s
   ```

3. Interpret the result. The injected 5 s latency exceeds the 3 s timeout, so Envoy aborts the request with `504 Gateway Timeout`. **This is exactly the class of bug the technique exists to find**: in the canonical Bookinfo task, a 7 s delay injected into `ratings` surfaces a hard-coded, too-short timeout between `reviews:v2/v3` and `ratings`, producing an "Error fetching product reviews!" banner even though no service actually crashed. The fix is to *raise the timeout* (or *lower the assumed dependency latency*) until it survives the delay — here, set `timeout: 6s` and re-apply to watch the same request succeed at ~5 s.

4. Re-run with `timeout: 6s` to confirm the fix:

   ```
   code=200 time=5.011s
   ```

**Comprehension check 4**
1. The request returned `504` at ~3 s, but the app (`httpbin`) is perfectly healthy and fast. Which two configured numbers are in conflict, and which one "won"?
2. In the Bookinfo scenario, the bug is a hard-coded application timeout you *cannot* see in any manifest. Explain how fault injection made an invisible, code-level assumption visible without reading the application source.
3. You "fixed" the lab by raising the VirtualService `timeout` to 6 s. In a real system, name one situation where raising the caller's timeout is the *wrong* fix and lowering the dependency's latency budget is correct instead.

---

## Exercise 5 — Verify and diagnose fault injection from the data plane

You must be able to *prove* a fault is programmed and *observe* it firing — not merely trust that `kubectl apply` succeeded. Every check below reads the client sidecar, because that is where the fault lives.

1. Re-apply the simple 100% delay from Exercise 1. Then dump the client's route config and confirm the fault filter is present on the outbound route to `httpbin`:

   ```bash
   istioctl proxy-config routes "$CLIENT.fault-lab" \
     --name 8000 -o json | \
     grep -A6 '"envoy.filters.http.fault"'
   ```

   Expected fragment (the fault is attached via `typedPerFilterConfig`, keyed by the Envoy fault filter name):

   ```json
   "envoy.filters.http.fault": {
     "@type": "type.googleapis.com/envoy.extensions.filters.http.fault.v3.HTTPFault",
     "delay": {
       "percentage": { "numerator": 100 },
       "fixedDelay": "5s"
     }
   }
   ```

2. Read the Envoy fault counters from the **client** proxy. `delays_injected` / `aborts_injected` increment each time a fault actually fires:

   ```bash
   kubectl exec -n fault-lab "$CLIENT" -c istio-proxy -- \
     pilot-agent request GET stats | grep 'fault\.'
   ```

   Expected (values grow as you send traffic):

   ```
   http.outbound_...httpbin...8000.fault.delays_injected: 12
   http.outbound_...httpbin...8000.fault.aborts_injected: 0
   ```

3. Correlate with **access-log response flags**. Enable access logs if needed (Telemetry API or mesh config), send traffic, and inspect the client sidecar log. Envoy stamps `DI` for a delay-injected request and `FI` for a fault-aborted one in the `%RESPONSE_FLAGS%` field:

   ```bash
   kubectl logs -n fault-lab "$CLIENT" -c istio-proxy --tail=3
   ```

   Expected (note the `DI` flag):

   ```
   [2026-08-08T12:00:03.101Z] "GET /status/200 HTTP/1.1" 200 DI ... 5013 ...
   ```

   If you switch back to the abort fault, the same field shows `FI` with a `500`.

**Comprehension check 5**
1. You queried `istioctl proxy-config routes` against the **`sleep`** pod, not `httpbin`, to find the fault config — and it was there. Restate the rule this confirms about *where* Istio programs a VirtualService's routing/fault rules.
2. A teammate insists the fault "isn't working" but is reading `fault.aborts_injected` on the **`httpbin`** sidecar and sees `0`. Diagnose their mistake in one sentence.
3. In an access log, you see a `504` with response flags `DI`. Walk through what that single line tells you about how the request died.

---

## Cleanup

```bash
kubectl delete virtualservice httpbin -n fault-lab --ignore-not-found
kubectl delete namespace fault-lab
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0
1. **The sidecar was injected automatically.** Labeling the namespace with `istio-injection=enabled` makes Istio's mutating admission webhook (`sidecar-injector`) rewrite every new pod spec to add the `istio-proxy` (Envoy) container plus the `istio-init` init container. `httpbin.yaml` defines one app container; the mesh adds the second. `2/2 Running` is your proof that injection succeeded — a `1/1` workload is *not* in the mesh and no VirtualService/fault applies to it.
2. **`sleep`'s Envoy executes the fault**, not `httpbin`'s. Istio programs a VirtualService's HTTP routes (including `fault`) into the **outbound** listener/route of the *client* sidecars in the mesh that call the host. So when debugging you inspect the **caller's** proxy (routes, stats, logs), not the destination's. Looking at `httpbin`'s sidecar for the fault is the single most common wrong turn.

### Exercise 1
1. `percentage.value` is a **percent on a 0–100 scale**, expressed as a float — not a fraction. `value: 0.5` means **0.5%** (one request in two hundred), which is why "almost nothing" was delayed. They wanted `value: 50`.
2. It tests the caller's tolerance of a **slow dependency** (latency / network congestion / an overloaded but still-responding backend) — the request eventually succeeds, so it exercises timeout and slow-path handling rather than error handling.
3. **No.** Each request is an independent Bernoulli trial with p = 0.50; the count of delayed requests in 10 tries is binomially distributed. You expect ≈5 but any value 0–10 is possible. Fault percentage is a per-request probability, never a fixed rotation like "every other request."

### Exercise 2
1. **In the `sleep` (client) Envoy.** An `abort` fault is a *local reply* synthesized by the Envoy fault filter on the outbound route. The request is short-circuited before it leaves the client proxy, which is why it returns in microseconds and why `httpbin` never logs it.
2. `abort` models a dependency that is **down / returning errors** (immediate error code); `delay` models one that is **slow** (added latency, eventual success). A single simple `fault` block tests one failure mode per matched request — an aborted request never experiences the delay path, since the abort short-circuits it. (You *can* configure both `delay` and `abort` on one route; each is then sampled independently, but for a given aborted request the delay is moot because it never forwards.)
3. `fault filter abort` is Envoy's fixed body for an injected abort. Seeing it in a `500`/`503` body — or the `FI` response flag in access logs — tells you the error was **synthetically injected by the mesh**, not emitted by the application. In production that instantly rules out an app bug and points you at a lingering fault-injection VirtualService.

### Exercise 3
1. The catch-all (no `match`) would match **first** for every request, including one carrying `x-fault-test: true`. Istio evaluates `http[]` **in order and stops at the first match**; a leading catch-all makes the faulted route unreachable — the header'd request would return `200`, and the fault would silently never fire.
2. Because the fault only applies to requests carrying the test header, the other four teams' normal traffic falls through to the catch-all route and is served normally. A blanket 100% abort would break the shared service for **everyone**, turning a test into an outage.
3. A request matching the second (catch-all) route experiences **no fault** — that entry has no `fault` block. This shows that `match`, `fault` and `route` are scoped **to the individual HTTP route entry**: a fault applies only to requests that match *that* entry's conditions and follow *that* entry's route. Faults are per-route, not per-VirtualService.

### Exercise 4
1. The injected **5 s delay** and the route's **3 s timeout** are in conflict. The **timeout won**: it fired first and Envoy returned `504 Gateway Timeout` at ~3 s. `httpbin` itself was never the bottleneck.
2. The delay reproduced, on demand, the exact latency a real slow dependency would exhibit. That extra latency exceeded a timeout that lived **only in code / config assumptions** — nowhere visible in a manifest — so the timeout tripped and surfaced as a user-facing error. Fault injection converted an invisible latency-budget assumption into an observable `504`/error banner **without touching or reading the application source**.
3. Raising the caller's timeout is wrong whenever the caller is itself on a **latency-sensitive path** — e.g. it holds a user request (a browser will give up), consumes a connection/thread from a bounded pool, or is called by *its* upstream under an even tighter timeout. Lengthening the timeout there just cascades slowness and risks resource exhaustion. The correct fix is to bring the **dependency's latency back under the existing budget** (optimize it, cache, add a fallback / graceful degradation) so the timeout stays realistic.

### Exercise 5
1. Istio programs a VirtualService's routing and fault rules into the **client (caller) sidecars' outbound configuration**. The rule lives wherever the *traffic originates* toward the host — here, the `sleep` pod — which is exactly why the config appeared on `sleep`, not `httpbin`.
2. They are reading the **wrong proxy**: the fault fires on the **client** (`sleep`) sidecar's outbound route, so `fault.aborts_injected` increments there; `httpbin`'s sidecar never processes the aborted request and correctly shows `0`.
3. A `504` with the `DI` flag means: the request was **delay-injected** by the fault filter (`DI`), the injected delay pushed the total time past the route's timeout, and Envoy then terminated the request with a gateway timeout (`504`). One line tells you the failure was a **fault-injected latency colliding with a timeout** — a synthetic slow-dependency test tripping a too-short timeout — not a real upstream outage.

</details>