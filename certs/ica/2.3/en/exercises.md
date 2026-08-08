# Guided Exercises — Troubleshooting the Mesh Data Plane

> **Domain 2.3 · exam weight 6 · Istio Certified Associate (ICA)**
>
> The *data plane* is the set of Envoy proxies that actually move your traffic: the sidecar (`istio-proxy`) injected next to each workload, plus the ingress/egress gateways. The *control plane* (`istiod`) only computes configuration and pushes it via xDS; when a request behaves wrong, the truth lives in what Envoy was actually told and what Envoy actually did. These exercises train the reflex loop every operator needs: **is the proxy there → is it in sync → what config does it hold → what did it log → is mTLS the culprit → turn up the volume.** Every command is real `istioctl`/`kubectl`/Envoy tooling; run them against your own cluster and compare.

---

## Exercise 0 — Build the lab

You need a Kubernetes cluster with Istio installed (the `demo` profile enables access logs and tracing out of the box) and two sample workloads that talk to each other.

1. Install Istio with a profile that emits access logs, and label a namespace for automatic sidecar injection:

   ```bash
   istioctl install --set profile=demo -y
   kubectl label namespace default istio-injection=enabled --overwrite
   ```

2. Deploy the standard `sleep` (client) and `httpbin` (server) samples that ship with the Istio release:

   ```bash
   kubectl apply -f samples/sleep/sleep.yaml
   kubectl apply -f samples/httpbin/httpbin.yaml
   ```

3. Confirm both pods are `Running` and note the container count:

   ```bash
   kubectl get pods
   ```

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-5d9f7c8b4-abcde    2/2     Running   0          40s
   sleep-9454cc476-fghij      2/2     Running   0          38s
   ```

4. Generate a baseline request through the mesh so later logs have something to show:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/status/200
   ```

**Comprehension check**

- **Q0.1** The pod reads `2/2` under `READY`. Which two containers are those, and which one is the data plane component? What would `1/1` have told you about this exercise before you ran a single diagnostic?
- **Q0.2** You ran the `curl` with `-c sleep`. Why target the app container explicitly instead of letting `kubectl exec` pick the default?

---

## Exercise 1 — Is the proxy even there, and is it healthy?

Half of "the mesh is broken" tickets are really "the sidecar was never injected" or "the proxy is not Ready." Rule that out first — it costs nothing.

1. Ask `istioctl` for a mesh-wide census of every Envoy the control plane knows about:

   ```bash
   istioctl proxy-status
   ```

   ```
   NAME                              CLUSTER      CDS      LDS      EDS      RDS      ECDS       ISTIOD                     VERSION
   httpbin-5d9f7c8b4-abcde.default   Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6f7b94d5c-xyz12     1.22.0
   sleep-9454cc476-fghij.default     Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   NOT SENT   istiod-6f7b94d5c-xyz12     1.22.0
   ```

2. Inspect the injected containers and the readiness probe wiring of the server pod:

   ```bash
   kubectl get pod -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
   kubectl describe pod -l app=httpbin | grep -A2 Readiness
   ```

   ```
   httpbin istio-proxy
   Readiness:  http-get http://:15021/healthz/ready delay=1s timeout=3s period=15s
   ```

3. Now simulate the most common failure. Deploy a workload into a namespace that is **not** labelled for injection:

   ```bash
   kubectl create namespace legacy
   kubectl -n legacy apply -f samples/sleep/sleep.yaml
   kubectl -n legacy get pods
   ```

   ```
   NAME                     READY   STATUS    RESTARTS   AGE
   sleep-9454cc476-klmno    1/1     Running   0          10s
   ```

4. Confirm the control plane does not see it, then find out *why* it was skipped:

   ```bash
   istioctl proxy-status | grep legacy      # returns nothing
   kubectl get namespace -L istio-injection
   ```

**Comprehension check**

- **Q1.1** A workload appears in `kubectl get pods` as `Running` but never appears in `istioctl proxy-status`. What does that combination tell you, and where do you look next?
- **Q1.2** The httpbin readiness probe points at port **15021**, not at the app's port 80. Why does Istio route the kubelet health check through the proxy port, and what would break if you left the app's original `readinessProbe` pointed straight at the container?
- **Q1.3** Name the four sidecar ports 15000, 15006, 15001, and 15090, and say which one you would `port-forward` to reach Envoy's admin interface.

---

## Exercise 2 — Reading synchronization state: SYNCED, STALE, NOT SENT

`proxy-status` is not just "is it alive." Each column is the acknowledgement state of one xDS subsystem. Understanding these words is the difference between blaming the network and blaming your YAML.

1. Re-read the columns from Exercise 1 and map each acronym to what it configures:

   - **CDS** — Clusters (upstream service definitions)
   - **LDS** — Listeners (the ports Envoy opens)
   - **EDS** — Endpoints (the actual pod IPs behind a cluster)
   - **RDS** — Routes (HTTP routing rules attached to listeners)
   - **ECDS** — Extension Config (WASM/ext_authz filters; `NOT SENT` when unused)

2. Drill into a single proxy to see the *version hashes* istiod holds versus what Envoy acknowledged:

   ```bash
   istioctl proxy-status httpbin-5d9f7c8b4-abcde.default
   ```

   A healthy proxy reports matching `Sent`/`Acked` nonces for each type; a divergence is what surfaces as `STALE`.

3. Provoke drift. Apply a `VirtualService`, then immediately re-check status while the push propagates:

   ```bash
   kubectl apply -f - <<'EOF'
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
           port:
             number: 8000
   EOF
   istioctl proxy-status
   ```

4. Cross-check that the config you *wrote* is even valid, since a rejected config is a classic cause of a stuck/stale state:

   ```bash
   istioctl analyze
   ```

**Comprehension check**

- **Q2.1** Distinguish `SYNCED`, `STALE`, and `NOT SENT`. Which one is normal, which one is an alarm, and which one is merely "nothing to send"?
- **Q2.2** A proxy shows `RDS: STALE` for several minutes and never recovers. List two mechanically distinct causes — one on the istiod→Envoy path and one caused by the config content itself.
- **Q2.3** You added an `EnvoyFilter` and now a proxy is `STALE`. How would `istioctl analyze` plus the istiod logs (`kubectl logs deploy/istiod`) let you decide whether Envoy *rejected* (NACKed) the push rather than never receiving it?

---

## Exercise 3 — Walking the Envoy configuration with `proxy-config`

When routing misbehaves, you stop guessing and read the config Envoy is actually running. The mental model is a chain: a request hits a **listener**, matches a **route**, which names a **cluster**, which resolves to **endpoints**. Debug in that order.

1. Start at the client's outbound listeners and find the one for httpbin's port:

   ```bash
   istioctl proxy-config listeners deploy/sleep --port 8000
   ```

   ```
   ADDRESS   PORT   MATCH                                DESTINATION
   0.0.0.0   8000   Trans: raw_buffer; App: HTTP         Route: 8000
   0.0.0.0   8000   ALL                                  PassthroughCluster
   ```

2. Follow the `Route: 8000` reference to see which cluster a request to `httpbin` selects:

   ```bash
   istioctl proxy-config routes deploy/sleep --name 8000
   ```

   ```
   NAME     VHOST NAME                    DOMAINS                  MATCH     VIRTUAL SERVICE
   8000     httpbin.default.svc...:8000   httpbin, httpbin.default HTTP      httpbin.default
   ```

3. Resolve that cluster and confirm the destination it points to:

   ```bash
   istioctl proxy-config clusters deploy/sleep --fqdn httpbin.default.svc.cluster.local --port 8000
   ```

   ```
   SERVICE FQDN                        PORT   SUBSET   DIRECTION   TYPE   DESTINATION RULE
   httpbin.default.svc.cluster.local   8000   -        outbound    EDS
   ```

4. Finally, list the concrete endpoints and their health — this is where "no healthy upstream" is proven, not assumed:

   ```bash
   istioctl proxy-config endpoints deploy/sleep --cluster \
     "outbound|8000||httpbin.default.svc.cluster.local"
   ```

   ```
   ENDPOINT           STATUS      OUTLIER CHECK   CLUSTER
   10.244.0.15:80     HEALTHY     OK              outbound|8000||httpbin.default.svc.cluster.local
   ```

5. Let a human-readable summary tie the resources together for one pod, including which `VirtualService`/`DestinationRule` apply and the effective mTLS mode:

   ```bash
   istioctl experimental describe pod -l app=httpbin
   ```

**Comprehension check**

- **Q3.1** Put the four resource types in the order a request traverses them, and state the one-line question each answers ("which port? → which cluster? → …").
- **Q3.2** The endpoints command returns **zero** rows for `outbound|8000||httpbin...`. Which layer is broken, and which two non-Envoy Kubernetes objects would you inspect to explain an empty EDS list?
- **Q3.3** In the listener output, what is `PassthroughCluster`, and why does its presence mean a request to a port Istio doesn't recognize is *forwarded* rather than dropped? How does that behavior change under `outboundTrafficPolicy: REGISTRY_ONLY`?

---

## Exercise 4 — Diagnosing 503s with access logs and `RESPONSE_FLAGS`

A `503` is a category, not a diagnosis. Envoy stamps every response with a **response flag** that tells you *why*. Reading that flag turns a vague outage into a specific fault.

1. Make the client curl verbose so you can see the raw status, then hammer a route that will fail:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "code=%{http_code}\n" http://httpbin:8000/status/200
   ```

2. Pull the **client-side** sidecar's access log — the outbound proxy records the upstream failure:

   ```bash
   kubectl logs deploy/sleep -c istio-proxy --tail=5
   ```

   A representative line for a broken upstream connection:

   ```
   [2026-08-08T12:34:56.789Z] "GET /status/200 HTTP/1.1" 503 UC
   upstream_reset_before_response_started{connection_termination} - "-"
   0 95 4 - "-" "curl/8.5.0" "b2c3d4e5-..." "httpbin:8000" "10.244.0.15:80"
   outbound|8000||httpbin.default.svc.cluster.local 10.244.0.20:41234
   10.96.1.10:8000 10.244.0.20:52344 - default
   ```

3. Read the fields that matter: the `503` is followed by `UC` (the flag) and `upstream_reset_before_response_started{connection_termination}` (the `RESPONSE_CODE_DETAILS`). The `UPSTREAM_HOST` `10.244.0.15:80` and `UPSTREAM_CLUSTER` tell you exactly where it went.

4. Compare against a **no-route** failure by requesting a host the mesh has no route for, and observe the different flag:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:9999/status/200
   kubectl logs deploy/sleep -c istio-proxy --tail=1
   ```

5. Build the flag→cause table you will use forever. The essentials:

   | Flag | Meaning | Typical root cause |
   |------|---------|--------------------|
   | `UH` | No healthy upstream | All endpoints failing outlier/health checks |
   | `UF` | Upstream connection failure | App down, wrong port, **or mTLS handshake failure** |
   | `UC` | Upstream connection termination | Upstream reset the connection — often app closed it, or plaintext↔mTLS mismatch |
   | `NR` | No route configured | Missing/mismatched `VirtualService`, wrong Host/port |
   | `UO` | Upstream overflow | Circuit breaker (`connectionPool`) tripped |
   | `URX` | Retry/limit exceeded | Max retries or max requests reached |
   | `-`  | No flag | Failure is at the app (a real 503 from httpbin itself) |

**Comprehension check**

- **Q4.1** You see `503 UC` on the *client* sidecar but the *server* pod's app logs show no request arriving. Where did the request die, and what does that narrow the cause to?
- **Q4.2** Contrast `503 NR` with `503 UF`. One is a control-plane/config problem and one is a connectivity/handshake problem — which is which, and what's your first command for each?
- **Q4.3** An access log line ends in `503` with the response-flag field showing `-` (no flag). Why does this *exonerate* the mesh, and where do you take the investigation instead?

---

## Exercise 5 — mTLS in the data plane: STRICT vs plaintext

The single most misdiagnosed data-plane failure is a mutual-TLS mismatch: the server proxy is enforcing `STRICT`, a client sends plaintext, the connection is reset, and the symptom is a bare `503 UF`/`UC` that looks like the app is down. Learn to prove it.

1. Enforce `STRICT` mTLS for the httpbin workload:

   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: httpbin-strict
     namespace: default
   spec:
     selector:
       matchLabels:
         app: httpbin
     mtls:
       mode: STRICT
   EOF
   ```

2. From the **meshed** client, the call still works, because its sidecar performs the mTLS handshake transparently:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "meshed=%{http_code}\n" http://httpbin:8000/status/200
   ```

3. Now call from the **un-injected** `legacy/sleep` pod created in Exercise 1. It sends plaintext, the server refuses, and you get a failure:

   ```bash
   kubectl -n legacy exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null -w "plaintext=%{http_code}\n" \
     --max-time 5 http://httpbin.default:8000/status/200
   ```

4. Confirm the *effective* mTLS mode the server is applying and that the client proxy holds valid certificates:

   ```bash
   istioctl experimental describe pod -l app=httpbin | grep -i mtls
   istioctl proxy-config secret deploy/sleep
   ```

   ```
   RESOURCE NAME   TYPE           STATUS   VALID CERT   SERIAL NUMBER   NOT AFTER              NOT BEFORE
   default         Cert Chain     ACTIVE   true         3a...           2026-08-09T12:00:00Z   2026-08-08T11:58:00Z
   ROOTCA          CA             ACTIVE   true         1f...           2036-08-05T09:00:00Z   2026-08-05T09:00:00Z
   ```

5. Read the server sidecar's log during the failed plaintext call to see the handshake rejection reason:

   ```bash
   kubectl logs deploy/httpbin -c istio-proxy --tail=10 | grep -i tls
   ```

**Comprehension check**

- **Q5.1** The exact same `curl` to the exact same Service succeeds from `default/sleep` and fails from `legacy/sleep`. What single variable differs, and why does that variable decide the outcome under `STRICT`?
- **Q5.2** You suspect mTLS but want proof, not a hunch. Which command shows the *server's effective* enforcement mode, and which shows whether the *client* even has a workload certificate to present?
- **Q5.3** If you had set the `PeerAuthentication` mode to `PERMISSIVE` instead of `STRICT`, would the plaintext call from `legacy/sleep` have succeeded? Explain what `PERMISSIVE` does to the server listener and why it exists as a migration tool.

---

## Exercise 6 — Turning up the volume: Envoy log levels and the admin API

When the access log isn't enough, you go inside Envoy. Every sidecar exposes an admin interface on `15000` and a per-logger verbosity control you can change *at runtime* without restarting the pod.

1. Raise the connection and HTTP loggers of the client proxy to debug, scoped so you aren't drowned in noise:

   ```bash
   istioctl proxy-config log deploy/sleep --level connection:debug,http:debug
   ```

2. Reproduce the request, then read the freshly verbose log:

   ```bash
   kubectl exec deploy/sleep -c sleep -- \
     curl -s -o /dev/null http://httpbin:8000/status/200
   kubectl logs deploy/sleep -c istio-proxy --tail=40
   ```

3. Reach Envoy's admin interface directly for ground-truth state. Port-forward `15000` and query the cluster health and full config:

   ```bash
   kubectl port-forward deploy/sleep 15000:15000 &
   curl -s localhost:15000/clusters | grep httpbin | grep health_flags
   curl -s localhost:15000/config_dump | jq '.configs[].dynamic_active_clusters' | head
   ```

   Or let `istioctl` open the same admin dashboard for you:

   ```bash
   istioctl dashboard envoy deploy/sleep
   ```

4. Query the live stats to quantify what the flags in Exercise 4 were counting:

   ```bash
   curl -s localhost:15000/stats | grep -E \
     'cluster.outbound.*httpbin.*(upstream_cx_connect_fail|upstream_rq_5xx|membership_healthy)'
   ```

5. When you're done, **reset the log level** so you don't leave a proxy spewing debug into your logging pipeline:

   ```bash
   istioctl proxy-config log deploy/sleep --level info
   # or reset every logger to its default:
   istioctl proxy-config log deploy/sleep --reset
   ```

**Comprehension check**

- **Q6.1** `istioctl proxy-config log ... --level debug` changed Envoy's verbosity without a pod restart. Which admin endpoint does that command actually drive under the hood, and why is being able to do this live (not via a redeploy) critical during an incident?
- **Q6.2** In `/clusters`, an endpoint line shows `health_flags::/failed_active_hc`. Translate that into plain language and connect it to which `RESPONSE_FLAG` from Exercise 4 you'd expect to see if *every* endpoint carried it.
- **Q6.3** Why is `/config_dump` from the admin port considered more authoritative than `istioctl proxy-config`, even though both claim to show "the Envoy config"? (Hint: think about where each one reads from.)

---

## Beyond sidecars — a note on the ambient data plane

If your mesh runs in **ambient mode**, the per-pod Envoy is gone: L4 is handled by the per-node **ztunnel** and L7 by **waypoint** proxies. The troubleshooting verbs are the same but the tools change — `istioctl ztunnel-config workloads`, `istioctl ztunnel-config certificates`, and `kubectl logs` on the `ztunnel` DaemonSet replace `proxy-config` and the sidecar log. The concept transfers: identity, then listeners/routing, then endpoints, then logs.

---

## Answer key

<details>
<summary><strong>Show answers — Exercises 0 through 6</strong></summary>

**Q0.1** The two containers are your application container (`sleep` or `httpbin`) and `istio-proxy`, the injected Envoy sidecar — that sidecar *is* the data plane component for this workload. A `1/1` would have meant no sidecar was injected: there is no mesh to troubleshoot for that pod, and every "mesh" symptom would actually be plain Kubernetes networking.

**Q0.2** With two containers, `kubectl exec` needs to know which one to enter. Naming `-c sleep` guarantees you run inside the application container. If you accidentally exec into `istio-proxy`, the toolset, the network namespace view, and (critically) the iptables redirection context are different, so results can mislead you.

**Q1.1** `Running` + absent from `proxy-status` = the pod has no functioning Envoy that istiod recognizes, almost always because **the sidecar was never injected**. Check the namespace `istio-injection=enabled` (or `istio.io/rev`) label, any pod-level `sidecar.istio.io/inject: "false"` annotation, and that the mutating webhook was reachable when the pod was created. Confirm with the container count (`1/1`).

**Q1.2** Istio's iptables rules redirect the pod's inbound traffic through Envoy on 15006; a probe aimed straight at the app port can be intercepted or blocked by mTLS, causing false "unready" churn. Routing the probe through **15021** (`/healthz/ready`, an explicitly excluded port served by the agent, which also verifies Envoy itself came up) gives the kubelet a reliable signal that both the proxy and the app are ready. Leaving the original probe on the app port risks the kubelet failing the check because it can't complete an mTLS handshake.

**Q1.3** 15000 = Envoy **admin** interface; 15006 = **inbound** capture port; 15001 = **outbound** capture port; 15090 = Envoy **Prometheus telemetry**. You `port-forward` **15000** to reach the admin interface.

**Q2.1** `SYNCED` = Envoy has acknowledged (ACKed) the last config istiod sent — the normal, healthy state. `STALE` = istiod sent an update but Envoy has not acknowledged it — the alarm state, meaning the push is stuck, rejected, or the proxy is unhealthy/overloaded. `NOT SENT` = istiod had nothing of that type to send (e.g., `ECDS` with no extension filters) — benign.

**Q2.2** (1) istiod→Envoy path: the xDS stream is broken or the proxy is disconnected/overloaded, so the ACK never arrives — check istiod↔proxy connectivity, istiod load/CPU, and the proxy's own health. (2) Config content: istiod pushed a config Envoy **rejected (NACKed)** — a malformed `EnvoyFilter`, an invalid route — so it never reaches ACK. Distinguish them with the istiod logs and `istioctl analyze`.

**Q2.3** Run `istioctl analyze` to catch statically invalid config, then grep the istiod logs (`kubectl logs deploy/istiod -n istio-system`) for `NACK`/`rejected`/`ads` warnings naming that proxy. A NACK means the config was received and refused (fix the config); no NACK and no ACK means the push isn't landing at all (a delivery/connection problem).

**Q3.1** **Listener → Route → Cluster → Endpoint.** Listener: "which port/protocol did the request arrive on?" Route: "given the Host/path, which cluster handles it?" Cluster: "what upstream service, and how do I load-balance/secure it?" Endpoint: "which concrete pod IPs, and are they healthy?"

**Q3.2** The **endpoint (EDS)** layer is broken — Envoy has a cluster but no backends. The two non-Envoy objects to inspect are the Kubernetes **Service** (does its label selector match the pods, and is the port named/numbered correctly?) and the resulting **EndpointSlice/Endpoints** (are any pod IPs actually listed and Ready?). An empty EDS list almost always traces to a selector or port mismatch, or all pods failing readiness.

**Q3.3** `PassthroughCluster` is Envoy's catch-all that forwards traffic to its original destination IP:port without mesh routing, used when a request targets something not in the service registry. Under the default `ALLOW_ANY` policy this lets unknown/external traffic through. Under `outboundTrafficPolicy: REGISTRY_ONLY`, that catch-all becomes `BlackHoleCluster` and unknown destinations are **rejected** — so the same request that previously passed through now fails (a deliberate egress lockdown, and a frequent surprise cause of new 502/503s after tightening policy).

**Q4.1** The request died at the **client sidecar's attempt to reach the upstream** — it never got a usable response from the server, and since the server app logged nothing, the server *application* never processed it. That narrows the cause to the connection between the two proxies or the server sidecar refusing the connection: wrong port, upstream down, or (very commonly) an **mTLS mismatch** that reset the connection before the app was reached.

**Q4.2** `503 NR` = **No Route**: a config problem — Envoy has no route matching that Host/port, so fix the `VirtualService`/`Gateway` and verify with `istioctl proxy-config routes`. `503 UF` = **Upstream Failure**: a connectivity/handshake problem — the connection to the upstream failed, so check endpoint health (`istioctl proxy-config endpoints`) and mTLS state (`istioctl x describe pod`, `proxy-config secret`).

**Q4.3** A `-` response flag means Envoy successfully proxied the request end-to-end and simply relayed whatever the upstream returned — the `503` is the **application's own** response, not a mesh-injected failure. The mesh did its job; take the investigation into the httpbin application itself (its logs, its dependencies, its own upstreams).

**Q5.1** The differing variable is **whether the client has a sidecar** (`default/sleep` does, `legacy/sleep` does not). Under `STRICT`, the server's inbound listener accepts *only* mTLS connections; the meshed client's sidecar presents a workload certificate and completes the handshake, while the un-injected client sends plaintext, which the server rejects — hence success vs. failure to the identical Service.

**Q5.2** `istioctl experimental describe pod -l app=httpbin` reports the server's **effective** mTLS mode (the merged result of mesh-, namespace-, and workload-level `PeerAuthentication`). `istioctl proxy-config secret deploy/sleep` shows whether the **client** proxy actually holds a valid `default` workload cert (and the `ROOTCA`) to present — an empty or expired secret list is itself a root cause.

**Q5.3** No — under `PERMISSIVE` the plaintext call **succeeds**. `PERMISSIVE` makes the server listener accept *both* mTLS and plaintext on the same port, which is exactly why it exists: it lets you onboard workloads into the mesh incrementally without a flag-day cutover, then you flip to `STRICT` once every client is meshed. It is a migration mode, not a target state.

**Q6.1** It drives Envoy's admin **`POST /logging?level=...`** endpoint on port 15000. Being able to change verbosity live is critical because an incident is often not reproducible after a restart — restarting the pod destroys the very connection state and in-flight condition you're trying to observe. Live log-level changes let you capture the failure as it happens, then dial back down without disturbing the workload.

**Q6.2** `failed_active_hc` means that endpoint **failed Envoy's active health check**, so Envoy has removed it from the load-balancing pool. If *every* endpoint in the cluster carried a failing health flag, the cluster would have zero healthy members and requests would return **`503 UH`** (No Healthy Upstream).

**Q6.3** `/config_dump` is read **directly from the running Envoy process** over its admin port — it is the actual, live configuration Envoy is executing right now. `istioctl proxy-config` also queries the proxy's admin API, but the meaningful distinction operators rely on is between what *Envoy holds* (both admin views) and what *istiod believes it sent* (`proxy-status`); when in doubt about whether a push truly landed in the data plane, the admin `config_dump` is the ground truth, because it reflects post-ACK live state rather than the control plane's intent.

</details>

---

### Sources

- Istio — *Debugging Envoy and Istiod* (`proxy-status`, `proxy-config`): https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — *Diagnose your Configuration with Istioctl Analyze*: https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- Istio — *Understanding 503 errors / Network problems*: https://istio.io/latest/docs/ops/common-problems/network-issues/
- Istio — *Security problems* (mTLS troubleshooting): https://istio.io/latest/docs/ops/common-problems/security-issues/
- Istio — *Ports used by Istio*: https://istio.io/latest/docs/ops/deployment/requirements/
- Istio — *Getting Envoy's Access Logs*: https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Istio — *PeerAuthentication* reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — *istioctl* command reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Envoy — *Access logging — response flags*: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy — *Administration interface*: https://www.envoyproxy.io/docs/envoy/latest/operations/admin