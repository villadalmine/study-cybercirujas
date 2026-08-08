# ICA 2.1 — Troubleshooting Configuration (Guided Exercises)

> **Domain weight:** 7 · **Platform:** Istio service mesh · **Reference:** [CNCF ICA Curriculum](https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf)
>
> These labs train the single most valuable troubleshooting instinct on the exam: **stop guessing, and read what the mesh actually computed.** Every Istio API object (`VirtualService`, `DestinationRule`, `PeerAuthentication`, `Sidecar`, `Gateway`) is compiled by istiod into concrete Envoy xDS config (clusters, listeners, routes, endpoints, secrets) and pushed to each sidecar. When behaviour is wrong, the fault is almost always a *gap between the object you wrote and the Envoy config it produced*. The tools below let you see that gap directly.

**Learning objectives**

- Confirm control-plane and data-plane health before blaming configuration.
- Run static analysis with `istioctl analyze` and read its message codes.
- Diagnose sidecar-injection failures.
- Trace a request through the generated Envoy config with `istioctl proxy-config`.
- Correlate `istioctl proxy-status` sync states with push failures.
- Read Envoy **response flags** in access logs and map them to root causes.
- Debug an mTLS / `PeerAuthentication` misconfiguration end to end.

**Official sources used throughout**

- Diagnostic tools — [https://istio.io/latest/docs/ops/diagnostic-tools/](https://istio.io/latest/docs/ops/diagnostic-tools/)
- Requesting an analysis with `istioctl` — [https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/](https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/)
- Understand your mesh with `istioctl proxy-config` — [https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/](https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/)
- Debugging Envoy and Istiod — [https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/](https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/)
- Configuration Analysis message codes — [https://istio.io/latest/docs/reference/config/analysis/](https://istio.io/latest/docs/reference/config/analysis/)
- Envoy access logging & response flags — [https://istio.io/latest/docs/tasks/observability/logs/access-log/](https://istio.io/latest/docs/tasks/observability/logs/access-log/) and [https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage#config-access-log-format-response-flags](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)

---

## Prerequisites — build the fixture mesh

You need a cluster with Istio installed (`istioctl install --set profile=demo -y`) and `kubectl` / `istioctl` on your PATH. We use the canonical `httpbin` (server) + `curl`/`sleep` (client) fixtures plus a two-version deployment for subset routing.

```bash
# 1. Create a namespace that is NOT yet enabled for injection (deliberate — Exercise 3).
kubectl create namespace foo

# 2. Deploy the server and a client into it.
kubectl -n foo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/httpbin/httpbin.yaml
kubectl -n foo apply -f https://raw.githubusercontent.com/istio/istio/release-1.22/samples/curl/curl.yaml

# 3. A second app with two versions, used for subset-routing labs.
cat <<'EOF' | kubectl -n foo apply -f -
apiVersion: v1
kind: Service
metadata:
  name: reviews
  labels: { app: reviews }
spec:
  selector: { app: reviews }
  ports:
  - name: http
    port: 9080
    targetPort: 9080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v1
spec:
  replicas: 1
  selector: { matchLabels: { app: reviews, version: v1 } }
  template:
    metadata:
      labels: { app: reviews, version: v1 }
    spec:
      containers:
      - name: reviews
        image: docker.io/istio/examples-bookinfo-reviews-v1:1.20.1
        ports: [ { containerPort: 9080 } ]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v2
spec:
  replicas: 1
  selector: { matchLabels: { app: reviews, version: v2 } }
  template:
    metadata:
      labels: { app: reviews, version: v2 }
    spec:
      containers:
      - name: reviews
        image: docker.io/istio/examples-bookinfo-reviews-v2:1.20.1
        ports: [ { containerPort: 9080 } ]
EOF
```

> Keep this fixture running; every exercise builds on it.

---

## Exercise 1 — Prove the mesh is healthy before touching config

A huge fraction of "Istio is broken" reports are a broken *control plane* or a proxy that never received a push. Rule those out first.

1. Verify client/control-plane versions and that istiod is reachable:

   ```bash
   istioctl version
   ```

   Expected shape:

   ```
   client version: 1.22.1
   control plane version: 1.22.1
   data plane version: 1.22.1 (2 proxies)
   ```

2. Check control-plane pods and their restart counts:

   ```bash
   kubectl -n istio-system get pods -l app=istiod
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   istiod-6d8f7c9b7f-abcde   1/1     Running   0          3h
   ```

3. Ask each sidecar whether it is in sync with istiod:

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                          CLUSTER      CDS      LDS      EDS      RDS      ECDS       ISTIOD                    VERSION
   curl-abc.foo                  Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6d8f7c9b7f-abcde   1.22.1
   httpbin-def.foo               Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6d8f7c9b7f-abcde   1.22.1
   ```

**Comprehension check**

- **Q1.1** What does each column (CDS/LDS/EDS/RDS) of `proxy-status` represent, and what is the difference between `SYNCED`, `STALE`, and `NOT SENT`?
- **Q1.2** A proxy shows `STALE` for `CDS`. Is the fault more likely in the proxy, in istiod, or in the network between them? What single command would you run next?
- **Q1.3** Why is a discrepancy between `control plane version` and `data plane version` a troubleshooting signal, even when nothing is "broken" yet?

---

## Exercise 2 — Static analysis with `istioctl analyze`

`istioctl analyze` reasons about the *whole set* of live + local resources and flags contradictions **without sending any traffic**. On the exam it is the fastest way to localize a config fault.

1. Apply a deliberately broken `VirtualService` that routes to a subset no `DestinationRule` defines:

   ```bash
   cat <<'EOF' | kubectl -n foo apply -f -
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
           subset: v3          # <-- no such subset exists
   EOF
   ```

2. Run the analyzer against the namespace:

   ```bash
   istioctl analyze -n foo
   ```

   Expected (message code will appear):

   ```
   Error [IST0101] (VirtualService reviews.foo) Referenced host+subset in destinationrule not found: "reviews+v3"
   Error: Analyzers found issues when analyzing namespace: foo.
   See https://istio.io/v1.22/docs/reference/config/analysis for more information about causes and resolutions.
   ```

3. Fix it by creating the `DestinationRule` that declares the subsets, then re-analyze:

   ```bash
   cat <<'EOF' | kubectl -n foo apply -f -
   apiVersion: networking.istio.io/v1
   kind: DestinationRule
   metadata:
     name: reviews
   spec:
     host: reviews
     subsets:
     - name: v1
       labels: { version: v1 }
     - name: v2
       labels: { version: v2 }
   EOF

   # Point the VS at a subset that now exists.
   kubectl -n foo patch virtualservice reviews --type=json \
     -p='[{"op":"replace","path":"/spec/http/0/route/0/destination/subset","value":"v1"}]'

   istioctl analyze -n foo
   ```

   ```
   ✔ No validation issues found when analyzing namespace: foo.
   ```

4. Analyze a *local file before applying it* — the "shift-left" pattern:

   ```bash
   istioctl analyze reviews-vs.yaml
   # Combine live cluster state with a local file:
   istioctl analyze -n foo reviews-vs.yaml
   ```

**Comprehension check**

- **Q2.1** `istioctl analyze` reports `IST0101` for `reviews+v3` but the pods are healthy and traffic to `reviews` still works. Explain how both can be true at once — what actually happens to a request routed to an undefined subset?
- **Q2.2** What is the difference in scope between `istioctl analyze -n foo`, `istioctl analyze --all-namespaces`, and `istioctl analyze somefile.yaml`? Which one would catch a `VirtualService` that references a `Gateway` in another namespace?
- **Q2.3** The analyzer emits `Info`, `Warning`, and `Error` severities. Name one `Warning`-level condition that will *not* fail a CI gate by default but still matters in production.

---

## Exercise 3 — Sidecar injection is not happening

If a workload has no Envoy sidecar, none of your traffic/security policy applies to it — a classic "my `AuthorizationPolicy` is ignored" bug.

1. Confirm the symptom — `httpbin` has only its app container, no `istio-proxy`:

   ```bash
   kubectl -n foo get pod -l app=httpbin \
     -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   ```

   ```
   httpbin
   ```

   (A meshed pod would print `httpbin istio-proxy`.)

2. Let the analyzer name the cause:

   ```bash
   istioctl analyze -n foo
   ```

   ```
   Warning [IST0102] (Namespace foo) The namespace is not enabled for Istio injection. Run 'kubectl label namespace foo istio-injection=enabled' to enable it, or 'kubectl label namespace foo istio-injection=disabled' to explicitly mark it as not needing injection.
   ```

3. Inspect what the webhook keys off — namespace labels and (for revisioned installs) the `istio.io/rev` label:

   ```bash
   kubectl get namespace foo --show-labels
   kubectl get mutatingwebhookconfiguration -l app=sidecar-injector \
     -o jsonpath='{.items[0].webhooks[0].namespaceSelector}{"\n"}'
   ```

4. Enable injection and **restart** the workloads (injection only happens at pod *creation*):

   ```bash
   kubectl label namespace foo istio-injection=enabled --overwrite
   kubectl -n foo rollout restart deploy httpbin curl reviews-v1 reviews-v2
   kubectl -n foo wait --for=condition=ready pod -l app=httpbin --timeout=90s
   ```

5. Confirm the sidecar is present now:

   ```bash
   kubectl -n foo get pod -l app=httpbin \
     -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   ```

   ```
   httpbin istio-proxy
   ```

**Comprehension check**

- **Q3.1** Injection can be controlled at three levels: the namespace label, a pod-template annotation, and the webhook's `namespaceSelector`/`objectSelector`. If the namespace has `istio-injection=enabled` but one Deployment still comes up with no sidecar, what pod-level setting most likely overrides the namespace, and what is its exact key/value?
- **Q3.2** You labelled the namespace but the *existing* pods still have no sidecar. Why, and what is the minimal action to fix it?
- **Q3.3** On a **revisioned** install (canary upgrades), the label `istio-injection=enabled` may do nothing. What label must the namespace carry instead, and how do you discover the correct value?

---

## Exercise 4 — Routing works "on paper" but returns 503

Static analysis is green, yet requests fail. Now you must read the **generated Envoy config**, not the Istio objects.

1. Introduce a subtle fault — a `DestinationRule` subset whose label selector matches **no** pods:

   ```bash
   kubectl -n foo patch destinationrule reviews --type=json \
     -p='[{"op":"replace","path":"/spec/subsets/0/labels/version","value":"v9"}]'
   ```

2. Send a request from the client and observe the failure:

   ```bash
   kubectl -n foo exec deploy/curl -c curl -- \
     curl -sS -o /dev/null -w "%{http_code}\n" http://reviews:9080/
   ```

   ```
   503
   ```

3. Find *which* cluster the route selects, then check that cluster's endpoints:

   ```bash
   # Which cluster does the outbound route resolve to?
   istioctl proxy-config route deploy/curl -n foo \
     --name 9080 -o json | grep -A2 '"cluster"'
   ```

   ```
   "cluster": "outbound|9080|v1|reviews.foo.svc.cluster.local",
   ```

   ```bash
   # Does that subset cluster have any healthy endpoints?
   istioctl proxy-config endpoints deploy/curl -n foo \
     --cluster "outbound|9080|v1|reviews.foo.svc.cluster.local"
   ```

   ```
   ENDPOINT   STATUS   OUTLIER CHECK   CLUSTER
   (empty — no endpoints)
   ```

4. Contrast with the base (subset-less) cluster, which *does* have endpoints:

   ```bash
   istioctl proxy-config endpoints deploy/curl -n foo \
     --cluster "outbound|9080||reviews.foo.svc.cluster.local"
   ```

   ```
   ENDPOINT           STATUS    OUTLIER CHECK   CLUSTER
   10.244.1.21:9080   HEALTHY   OK              outbound|9080||reviews.foo.svc.cluster.local
   10.244.2.14:9080   HEALTHY   OK              outbound|9080||reviews.foo.svc.cluster.local
   ```

5. Fix the label so the subset selects the real `v1` pods, and re-test:

   ```bash
   kubectl -n foo patch destinationrule reviews --type=json \
     -p='[{"op":"replace","path":"/spec/subsets/0/labels/version","value":"v1"}]'

   kubectl -n foo exec deploy/curl -c curl -- \
     curl -sS -o /dev/null -w "%{http_code}\n" http://reviews:9080/
   ```

   ```
   200
   ```

**Comprehension check**

- **Q4.1** The subset cluster `outbound|9080|v1|...` existed in CDS but had zero endpoints in EDS. Which Envoy **response flag** would you expect to see in the client sidecar's access log for this request, and what does it stand for?
- **Q4.2** Decode the four fields of the Envoy cluster name `outbound|9080|v1|reviews.foo.svc.cluster.local`. What does an **empty** third field mean?
- **Q4.3** `istioctl analyze` stayed green through this whole failure. Why can't static analysis catch a subset whose labels match no pods, and what does that tell you about when to reach for `proxy-config endpoints`?

---

## Exercise 5 — Trace one request through the Envoy config

This is the core `proxy-config` muscle. You will follow a single outbound request from **listener → route → cluster → endpoint**.

1. **Listener** — the outbound port 9080 listener on the client sidecar:

   ```bash
   istioctl proxy-config listeners deploy/curl -n foo --port 9080
   ```

   ```
   ADDRESS       PORT   MATCH                  DESTINATION
   0.0.0.0       9080   Trans: raw_buffer; App: http/1.1,h2c   Route: 9080
   0.0.0.0       9080   ALL                    PassthroughCluster
   ```

2. **Route** — which virtual host / VirtualService the port-9080 route uses:

   ```bash
   istioctl proxy-config routes deploy/curl -n foo --name 9080
   ```

   ```
   NAME   VHOST NAME                             DOMAINS                              MATCH   VIRTUAL SERVICE
   9080   reviews.foo.svc.cluster.local:9080     reviews, reviews.foo, reviews.foo.svc + 1   /*   reviews.foo
   ```

3. **Cluster** — confirm the destination cluster and its discovery type:

   ```bash
   istioctl proxy-config clusters deploy/curl -n foo \
     --fqdn reviews.foo.svc.cluster.local --port 9080
   ```

   ```
   SERVICE FQDN                         PORT   SUBSET   DIRECTION   TYPE   DESTINATION RULE
   reviews.foo.svc.cluster.local        9080   -        outbound    EDS    reviews.foo
   reviews.foo.svc.cluster.local        9080   v1       outbound    EDS    reviews.foo
   reviews.foo.svc.cluster.local        9080   v2       outbound    EDS    reviews.foo
   ```

4. **Endpoint** — the actual pod IPs behind the chosen cluster (as in Exercise 4).

5. **Bootstrap & secrets** — when TLS is in play, dump the static bootstrap and the workload certificates:

   ```bash
   istioctl proxy-config bootstrap deploy/curl -n foo | head -30
   istioctl proxy-config secret    deploy/curl -n foo
   ```

   ```
   RESOURCE NAME     TYPE           STATUS     VALID CERT   SERIAL NUMBER    NOT AFTER                NOT BEFORE
   default           Cert Chain     ACTIVE     true         2f3a...          2026-08-09T11:00:00Z     2026-08-08T10:58:00Z
   ROOTCA            CA             ACTIVE     true         9c11...          2027-08-08T00:00:00Z     2026-08-08T00:00:00Z
   ```

**Comprehension check**

- **Q5.1** Put the five `proxy-config` subcommands in the order Envoy consults them to serve one outbound HTTP request, and state in one line what each answers.
- **Q5.2** In the listeners output there is a second line: `ALL → PassthroughCluster`. What is `PassthroughCluster`, and how does its presence change how you interpret a request that "succeeds" but ignores your `VirtualService`?
- **Q5.3** `proxy-config secret` shows the `default` cert with a `NOT AFTER` only ~24 h out. Is that a problem? What component rotates it, and what would you check if `VALID CERT` were `false`?

---

## Exercise 6 — mTLS / PeerAuthentication misconfiguration

`STRICT` mTLS on a server, reached by a client that cannot speak mTLS, is one of the highest-yield troubleshooting scenarios on the exam.

1. Enforce `STRICT` mTLS on `httpbin` only:

   ```bash
   cat <<'EOF' | kubectl -n foo apply -f -
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-strict
     namespace: foo
   spec:
     selector:
       matchLabels: { app: httpbin }
     mtls:
       mode: STRICT
   EOF
   ```

2. Call it from a **meshed** client — this must still succeed (both sides have sidecars → mTLS):

   ```bash
   kubectl -n foo exec deploy/curl -c curl -- \
     curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin:8000/status/200
   ```

   ```
   200
   ```

3. Now simulate a **non-meshed** client by calling from the app container while bypassing its own sidecar interception is hard — instead, deploy a sidecar-less client in a plain namespace and call across:

   ```bash
   kubectl create namespace legacy          # NOT injection-enabled
   kubectl -n legacy run legacy-curl --image=curlimages/curl:8.5.0 \
     --restart=Never -- sleep 3600
   kubectl -n legacy wait --for=condition=ready pod/legacy-curl --timeout=60s

   kubectl -n legacy exec legacy-curl -- \
     curl -sS -o /dev/null -w "%{http_code}\n" \
     http://httpbin.foo.svc.cluster.local:8000/status/200 || echo "curl failed"
   ```

   ```
   000
   curl failed          # connection reset — plaintext client rejected by STRICT server
   ```

4. Prove *where* the rejection happens by reading the **server** sidecar's logs and its inbound TLS config:

   ```bash
   # Raise log verbosity on the server proxy's RBAC/connection filters:
   istioctl proxy-config log deploy/httpbin -n foo --level "connection:debug,filter:debug"

   kubectl -n foo logs deploy/httpbin -c istio-proxy --tail=20
   ```

   ```
   ...TLS error: 268435612:SSL routines:OPENSSL_internal:HTTP_REQUEST
   ...remote address: 10.244.3.5:52012  requested server name: -  no TLS
   ```

5. Confirm the effective policy and reset:

   ```bash
   # Effective mTLS on the httpbin workload:
   istioctl proxy-config listeners deploy/httpbin -n foo \
     --port 8000 -o json | grep -i requireClientCertificate

   # Remediate: allow both mTLS and plaintext during migration.
   kubectl -n foo patch peerauthentication httpbin-strict --type=json \
     -p='[{"op":"replace","path":"/spec/mtls/mode","value":"PERMISSIVE"}]'

   kubectl -n legacy exec legacy-curl -- \
     curl -sS -o /dev/null -w "%{http_code}\n" \
     http://httpbin.foo.svc.cluster.local:8000/status/200

   # Restore proxy log level.
   istioctl proxy-config log deploy/httpbin -n foo --reset
   ```

   ```
   200          # PERMISSIVE now accepts the plaintext client
   ```

**Comprehension check**

- **Q6.1** With `STRICT`, the meshed client got `200` but the non-meshed client got a reset. Explain the mechanism — which side terminates the connection, and why `PERMISSIVE` changes the outcome.
- **Q6.2** A very common trap: mTLS `mode` is set two ways — `PeerAuthentication` (server-side, "what I accept") and `DestinationRule` `trafficPolicy.tls.mode` (client-side, "what I send"). Describe the failure you get when server `PeerAuthentication` is `STRICT` but a `DestinationRule` sets client TLS `mode: DISABLE` for that host. Which response flag appears?
- **Q6.3** Which single `istioctl` subcommand tells you the *effective* mTLS posture without reading raw Envoy JSON, and what is its output when policy is inconsistent between two ports of the same service?

---

## Exercise 7 — Config not propagating; read the flags, raise the logs

The last skill: distinguish "istiod never pushed it" from "the push arrived but Envoy dropped the request."

1. Turn on the client sidecar's access log at debug and generate one good and one bad request:

   ```bash
   istioctl proxy-config log deploy/curl -n foo --level info

   # Good request:
   kubectl -n foo exec deploy/curl -c curl -- \
     curl -sS -o /dev/null http://httpbin:8000/status/200

   # Bad request to a host with no route (unknown service):
   kubectl -n foo exec deploy/curl -c curl -- \
     curl -sS -o /dev/null http://nonexistent:8000/ || true

   kubectl -n foo logs deploy/curl -c istio-proxy --tail=5
   ```

   ```
   [2026-08-08T12:00:00.123Z] "GET /status/200 HTTP/1.1" 200 - via_upstream - "-" 0 0 5 4 "-" "curl/8.5.0" "a1b2" "httpbin:8000" "10.244.1.7:80" outbound|8000||httpbin.foo.svc.cluster.local ...
   [2026-08-08T12:00:02.501Z] "GET / HTTP/1.1" 503 NR route_not_found - "-" 0 0 0 - "-" "curl/8.5.0" "c3d4" "nonexistent:8000" "-" - ...
   ```

2. When a *specific* proxy is stuck `STALE` in `proxy-status`, look at istiod's push side:

   ```bash
   # Config-distribution / push metrics and any rejected config:
   kubectl -n istio-system logs deploy/istiod --tail=50 | grep -Ei "rejected|error|Push"
   # Live xDS connections and what each requested:
   istioctl proxy-status
   ```

3. Diff *desired vs delivered* config for one proxy — the definitive "did it actually arrive?" check:

   ```bash
   istioctl proxy-config all deploy/curl -n foo -o json > /tmp/curl-envoy.json
   wc -l /tmp/curl-envoy.json
   # Grep for the object you expect to see materialized, e.g. a route host:
   grep -c "httpbin.foo.svc.cluster.local" /tmp/curl-envoy.json
   ```

4. Reset log levels when done:

   ```bash
   istioctl proxy-config log deploy/curl -n foo --reset
   ```

**Comprehension check — Envoy response flags**

- **Q7.1** For each flag, give the one-line meaning **and** the most likely Istio misconfiguration behind it: `NR`, `UH`, `UF`, `UC`, `UO`, `RL`, `URX`.
- **Q7.2** A request returns `503 UH`. Walk the exact `proxy-config` sequence you would run to confirm the root cause, in order.
- **Q7.3** `proxy-status` shows a proxy `SYNCED` on every xDS type, but `istioctl proxy-config routes` for it is missing a route you just created. What are the two most likely explanations, and how does `kubectl -n istio-system logs deploy/istiod | grep rejected` help decide between them?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** The columns are the xDS APIs istiod pushes to each Envoy: **CDS** (Cluster Discovery — upstream clusters), **LDS** (Listener Discovery — ports/filter chains), **EDS** (Endpoint Discovery — the pod IPs behind each cluster), **RDS** (Route Discovery — HTTP routing rules), and **ECDS** (Extension Config). States: **`SYNCED`** — istiod sent the config and Envoy ACKed it (in agreement). **`STALE`** — istiod sent an update but has not received the ACK; the proxy is running older config (a push that is in flight, or a proxy that isn't applying updates). **`NOT SENT`** — istiod has nothing of that type to send (e.g. no WasmPlugins → `ECDS: NOT SENT`); this is normal, not an error.

**A1.2** `STALE` means the **push left istiod but was not ACKed**, so the problem is on the *proxy or connection* side, not istiod's computation — istiod already produced and sent the config. Next: `kubectl -n foo logs <pod> -c istio-proxy | grep -Ei "warn|error|xds"` (or `istioctl proxy-config all` to see what it currently holds), and check for a wedged/overloaded Envoy or a broken xDS connection. Persistent `STALE` across many proxies instead points at an istiod push storm — check istiod CPU and `pilot_xds_pushes`/`pilot_xds_push_time` metrics.

**A1.3** A version skew means some sidecars are running an **older Envoy/proxy than the control plane** — usually pods that were not restarted after an upgrade. Config features or defaults added in the new istiod may be silently unsupported or behave differently in old proxies, producing "works on some pods, not others" bugs that look like config errors but are really a data-plane upgrade you forgot to finish (`kubectl rollout restart`).

### Exercise 2

**A2.1** Both are true because the `VirtualService` and the *actual routing* are decoupled. When a route names a subset with no matching `DestinationRule` subset, istiod cannot build a subset cluster; depending on version the route either falls through to the base (subset-less) cluster or produces `503 NR`. In this fixture traffic to `reviews` may still land on the base cluster's healthy endpoints, so the app "works," while `analyze` correctly flags that the *declared intent* (subset `v3`) is unsatisfiable — a latent bug waiting for the moment you rely on that subset.

**A2.2** `-n foo` analyzes objects in namespace `foo` plus cluster-scoped context; `--all-namespaces` analyzes the entire mesh (needed for cross-namespace references); `analyze somefile.yaml` merges the local file(s) with live cluster state so you can validate *before* applying. A `VirtualService` referencing a `Gateway` in **another** namespace is only reliably caught by `--all-namespaces` (or by passing both namespaces' resources), because a single-namespace run can't see the other side of the reference.

**A2.3** Examples of `Warning`-level, non-blocking conditions: a **deprecated API/annotation** still in use (`IST0106`-class), a Deployment associated with **multiple services** on conflicting ports, a `Sidecar` resource that captures no workloads, or a `Gateway` port not backed by any workload. They pass CI but signal drift or future breakage — e.g. the deprecated annotation disappears in the next Istio upgrade.

### Exercise 3

**A3.1** The pod-template annotation `sidecar.istio.io/inject: "false"` (under `spec.template.metadata.annotations`) overrides an injection-enabled namespace — the webhook honours the explicit per-pod opt-out. (`hostNetwork: true` pods and pods in the control-plane namespace are also skipped.)

**A3.2** Injection is done by the **mutating admission webhook at pod creation time only** — labelling the namespace does not retroactively mutate running pods. Minimal fix: `kubectl rollout restart` the workloads (or delete the pods) so they are recreated and pass back through the webhook.

**A3.3** With a revisioned/canary install the namespace must carry `istio.io/rev=<revision>` (e.g. `istio.io/rev=1-22-1`) instead of `istio-injection=enabled`; the two are mutually exclusive. Discover the value with `kubectl get mutatingwebhookconfiguration -l app=sidecar-injector -o yaml | grep -A5 namespaceSelector` or `istioctl tag list` / `kubectl -n istio-system get deploy -l app=istiod --show-labels` to see which revision tags exist.

### Exercise 4

**A4.1** `503 UH` — **U**pstream **H**ealthy-hosts: **no healthy upstream**. The subset cluster was created but EDS delivered zero endpoints (the label matched nothing), so Envoy has no host to route to and fails fast.

**A4.2** `direction|port|subset|hostname`: **`outbound`** (traffic leaving this proxy) · **`9080`** (service port) · **`v1`** (the `DestinationRule` subset) · **`reviews.foo.svc.cluster.local`** (the service FQDN). An **empty third field** (`outbound|9080||reviews...`) is the *base* cluster — all endpoints of the service, no subset filtering.

**A4.3** `istioctl analyze` validates *references between Istio objects and known label keys*, but a subset whose labels match no **pods** is only knowable by comparing against live endpoint state, which is what EDS/`proxy-config endpoints` reflects. Lesson: analysis proves the objects are *internally consistent*; `proxy-config endpoints` proves the config is *satisfiable by the current pods*. Any "green analyze but 503" points you straight at endpoints.

### Exercise 5

**A5.1** Order Envoy consults per outbound request: **listeners** (which port/filter-chain accepts the connection → answers "who handles this socket?") → **routes** (match `:authority`/path to a cluster → "where does this HTTP request go?") → **clusters** (the upstream definition + discovery type/TLS → "what is the destination and how do I talk to it?") → **endpoints** (concrete pod IPs + health → "which instance?"). **bootstrap** is the static startup config Envoy was born with (node metadata, xDS wiring) — consulted at boot, not per request; **secret** holds the TLS certs used once a cluster requires mTLS.

**A5.2** `PassthroughCluster` (a.k.a. `BlackHoleCluster`'s opposite) is the fallback cluster for traffic to destinations Istio has **no explicit config for**, used when `outboundTrafficPolicy.mode` is `ALLOW_ANY`. If a request "succeeds" but ignores your `VirtualService`, it may be going out via `PassthroughCluster` (original-destination passthrough), meaning your routing/policy is being bypassed entirely. Switching the mode to `REGISTRY_ONLY` makes such requests fail loudly (`BlackHoleCluster`, `503 NR`) so misconfig surfaces instead of silently escaping.

**A5.3** Not a problem — workload certs are **short-lived by design** (default ~24 h) and rotated automatically by **istio-agent** (the pilot-agent/SDS in the sidecar) well before expiry, so you never restart pods for cert rotation. If `VALID CERT` were `false`, check istiod/istio-agent connectivity to the CA, the workload's `ServiceAccount`/token, and `istioctl proxy-config secret` for the `ROOTCA` trust chain; also look for CA rotation or clock skew.

### Exercise 6

**A6.1** With `STRICT`, the **server sidecar** requires a valid client certificate on inbound connections (`requireClientCertificate: true` in its filter chain). A meshed client's sidecar presents the mesh-issued cert → TLS handshake succeeds → `200`. A non-meshed client sends **plaintext**; the server sidecar sees a non-TLS/HTTP payload where a TLS ClientHello is required and **resets the connection** (`curl` gets `000`/reset, and the server proxy logs an `SSL routines: HTTP_REQUEST` error). `PERMISSIVE` makes the server accept **both** mTLS and plaintext on the same port, so the plaintext client now gets `200` — this is the migration mode.

**A6.2** Server `STRICT` says "I only accept mTLS," but the client `DestinationRule` `tls.mode: DISABLE` says "send plaintext." The client's sidecar therefore originates plaintext to a server that demands mTLS → the server resets the connection and the client sees `503 UF` (upstream connection **failure** — the TLS handshake never completes) or a reset. It's the mirror of the classic auto-mTLS: `PeerAuthentication` and `DestinationRule` TLS mode must agree.

**A6.3** `istioctl x describe pod <httpbin-pod> -n foo` (the experimental `describe`) reports the effective mTLS mode and any policy/route affecting the workload in plain language. When two ports disagree, it lists them per-port (e.g. one port `STRICT`, another `PERMISSIVE`/disabled via a port-level `PeerAuthentication` override), which is exactly the inconsistency raw JSON hides.

### Exercise 7

**A7.1**
- **`NR`** — **No Route** configured for the request (`route_not_found`). Cause: request `:authority`/host not covered by any `VirtualService`/service, or a `VirtualService` match that doesn't fire; also `REGISTRY_ONLY` blocking an unknown host.
- **`UH`** — **No healthy Upstream Host.** Cause: cluster exists but EDS has zero healthy endpoints — subset labels match nothing, all pods failing readiness, or scaled to zero.
- **`UF`** — **Upstream connection Failure** (couldn't establish the connection). Cause: mTLS mode mismatch, wrong port, or the upstream refusing connections.
- **`UC`** — **Upstream Connection termination** (upstream closed mid-stream). Cause: app crash/keep-alive mismatch, or a `PeerAuthentication` change resetting live connections.
- **`UO`** — **Upstream Overflow** — circuit breaker tripped. Cause: `DestinationRule` `connectionPool`/`outlierDetection` limits exceeded.
- **`RL`** — **Rate Limited** locally. Cause: local rate-limit filter / `EnvoyFilter` limit hit.
- **`URX`** — Upstream **Retry/Request limit** exceeded (max retries or per-try timeout budget hit). Cause: retries configured in the `VirtualService` all failed.

**A7.2** For `503 UH`: (1) `istioctl proxy-config routes <pod> --name <port>` → find the target cluster the request resolves to; (2) `istioctl proxy-config clusters <pod> --fqdn <svc>` → confirm the cluster exists and its subset; (3) `istioctl proxy-config endpoints <pod> --cluster "<cluster-name>"` → see whether it has **healthy** endpoints; (4) if empty, compare the `DestinationRule` subset labels against `kubectl get pods -l <labels>` and check pod readiness. Empty/unhealthy endpoints confirm `UH`.

**A7.3** Two explanations: (a) istiod **rejected** the new config (schema/semantic error) so it was never compiled into a route — the proxy is legitimately `SYNCED` on the *last valid* config; (b) the route is there but **doesn't match** your test (wrong host/port/gateway binding, or an `exportTo`/`Sidecar` egress scope hiding it). `kubectl -n istio-system logs deploy/istiod | grep -i rejected` distinguishes them: a rejection line (with the object name and reason) proves case (a); silence means the config was accepted and you should re-examine matching/scoping (case b), e.g. via `istioctl proxy-config routes <pod> -o json` and the object's `exportTo`.

</details>