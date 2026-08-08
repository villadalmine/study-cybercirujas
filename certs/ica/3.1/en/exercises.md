# Guided Exercises — ICA Topic 3.1: Configuring Ingress and Egress Traffic

These labs take you through the four pillars of edge traffic control in Istio: exposing a mesh service through the **ingress gateway**, terminating **TLS** at the edge, restricting and admitting **egress** traffic with `ServiceEntry`, and funneling outbound traffic through a dedicated **egress gateway** with TLS origination. Each block ends with comprehension questions; consolidated answers are in the collapsible section at the very end.

> **Source references**
> - Ingress control — https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/
> - Secure ingress (TLS) — https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
> - Egress control (`ServiceEntry`, `outboundTrafficPolicy`) — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
> - Egress gateway with TLS origination — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
> - `Gateway` API ref — https://istio.io/latest/docs/reference/config/networking/gateway/
> - `ServiceEntry` API ref — https://istio.io/latest/docs/reference/config/networking/service-entry/
> - `Sidecar` API ref — https://istio.io/latest/docs/reference/config/networking/sidecar/

---

## Prerequisites

```bash
# A cluster with Istio installed (demo profile is fine for these labs).
istioctl version

# Enable automatic sidecar injection in the default namespace.
kubectl label namespace default istio-injection=enabled --overwrite

# Deploy the standard sample workloads (shipped with the Istio release).
kubectl apply -f samples/httpbin/httpbin.yaml
kubectl apply -f samples/sleep/sleep.yaml
kubectl get pods
```

Expected (the `2/2` READY column proves the sidecar was injected next to each app container):

```
NAME                       READY   STATUS    RESTARTS   AGE
httpbin-7c9f5c6b6d-abcde   2/2     Running   0          20s
sleep-6d6b49d8b8-fghij     2/2     Running   0          18s
```

```bash
# Capture the sleep pod name; we drive egress tests from it.
export SOURCE_POD=$(kubectl get pod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
```

---

## Exercise 1 — Expose an HTTP service through the Istio ingress gateway

**Goal:** publish `httpbin` at the virtual host `httpbin.example.com` on the mesh's ingress gateway.

1. Confirm the ingress gateway is running and note its Service type:

    ```bash
    kubectl get svc istio-ingressgateway -n istio-system
    ```

    ```
    NAME                   TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                        AGE
    istio-ingressgateway   LoadBalancer   10.96.120.14   <pending>     15021/TCP,80:31380/TCP,443:31390/TCP   5m
    ```

2. Create the **`Gateway`** — this configures the *listener* on the shared gateway proxy but does **not** route anything yet:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: httpbin-gateway
      namespace: default
    spec:
      selector:
        istio: ingressgateway     # binds to the pod labeled istio=ingressgateway
      servers:
      - port:
          number: 80
          name: http
          protocol: HTTP
        hosts:
        - "httpbin.example.com"
    ```

    ```bash
    kubectl apply -f httpbin-gateway.yaml
    ```

3. Create the **`VirtualService`** and attach it to the Gateway via the `gateways` field — this is what actually routes host + path to the backend:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: httpbin
      namespace: default
    spec:
      hosts:
      - "httpbin.example.com"
      gateways:
      - httpbin-gateway            # same namespace; else use ns/name
      http:
      - match:
        - uri:
            prefix: /status
        - uri:
            prefix: /headers
        route:
        - destination:
            host: httpbin           # short name resolves to httpbin.default.svc.cluster.local
            port:
              number: 8000
    ```

    ```bash
    kubectl apply -f httpbin-vs.yaml
    ```

4. Resolve the ingress host and port (LoadBalancer path shown; fall back to NodePort if `EXTERNAL-IP` stays `<pending>`):

    ```bash
    export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

    # NodePort fallback:
    # export INGRESS_HOST=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    # export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    ```

5. Send a request. We inject the `Host` header so the gateway matches our virtual host without real DNS:

    ```bash
    curl -sS -I -H "Host: httpbin.example.com" \
      "http://$INGRESS_HOST:$INGRESS_PORT/status/200"
    ```

    Expected:

    ```
    HTTP/1.1 200 OK
    server: istio-envoy
    date: ...
    content-length: 0
    ```

6. Confirm that a **non-configured path is not routed** (proves the `VirtualService` match, not the Gateway, defines the routing table):

    ```bash
    curl -sS -o /dev/null -w "%{http_code}\n" -H "Host: httpbin.example.com" \
      "http://$INGRESS_HOST:$INGRESS_PORT/ip"
    ```

    Expected: `404` (no `http.match` prefix covers `/ip`).

**Comprehension questions (1):**
1. What does the Gateway's `spec.selector` actually select, and what happens if no pod carries that label?
2. Why does applying only the `Gateway` (without the `VirtualService`) leave `httpbin.example.com` unreachable?
3. In the `VirtualService`, what is the purpose of the `gateways:` list, and what would it mean if you added the reserved value `mesh` to it?
4. The request to `/ip` returned `404` while `/status/200` returned `200`. Which resource decides that difference?

---

## Exercise 2 — Terminate TLS at the ingress gateway (SIMPLE mode)

**Goal:** serve `https://httpbin.example.com` with a server certificate delivered to the gateway via SDS.

1. Create a root CA and a server certificate/key for the virtual host:

    ```bash
    # Root CA
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
      -subj '/O=example Inc./CN=example.com' -keyout example.com.key -out example.com.crt

    # Server cert signed by that CA
    openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
      -keyout httpbin.example.com.key -subj "/CN=httpbin.example.com/O=httpbin org"
    openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key \
      -set_serial 0 -in httpbin.example.com.csr -out httpbin.example.com.crt
    ```

2. Store the cert as a **`kubernetes.io/tls`** secret **in the namespace where the ingress gateway pod runs** (`istio-system`), because that proxy is what must load it:

    ```bash
    kubectl create -n istio-system secret tls httpbin-credential \
      --key=httpbin.example.com.key \
      --cert=httpbin.example.com.crt
    ```

3. Update the Gateway to add an HTTPS server referencing the secret by `credentialName` (drop the `.crt/.key` suffix — Istio appends them):

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: httpbin-gateway
      namespace: default
    spec:
      selector:
        istio: ingressgateway
      servers:
      - port:
          number: 443
          name: https
          protocol: HTTPS
        tls:
          mode: SIMPLE            # one-way TLS, gateway presents a server cert
          credentialName: httpbin-credential
        hosts:
        - "httpbin.example.com"
    ```

    ```bash
    kubectl apply -f httpbin-gateway-tls.yaml
    ```

4. Resolve the secure port and call the endpoint, pinning our CA:

    ```bash
    export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
      -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

    curl -sS -v -HHost:httpbin.example.com \
      --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
      --cacert example.com.crt \
      "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/200"
    ```

    Expected (handshake succeeds and the presented cert chains to our CA):

    ```
    * Server certificate:
    *  subject: CN=httpbin.example.com; O=httpbin org
    *  SSL certificate verify ok.
    ...
    < HTTP/2 200
    ```

5. Verify the certificate reached the proxy **without restarting the gateway** — istiod pushed it over SDS:

    ```bash
    istioctl proxy-config secret deploy/istio-ingressgateway.istio-system | grep httpbin-credential
    ```

    Expected: a row for `kubernetes://httpbin-credential` with a valid (not expired) status.

**Comprehension questions (2):**
1. Which namespace must the `httpbin-credential` secret live in, and why is putting it in `default` a common mistake that yields a `connection reset`?
2. Compare `tls.mode` values `SIMPLE`, `MUTUAL`, and `PASSTHROUGH`. Which one makes the ingress gateway *not* decrypt the traffic at all?
3. You rotated the secret (`kubectl create secret ... --dry-run | kubectl apply`). Do you need to restart or redeploy the ingress gateway for the new cert to take effect? Explain the mechanism.
4. Why does the `curl` command use `--resolve` and `--cacert` instead of relying on public DNS and the system trust store?

---

## Exercise 3 — Restrict and admit egress traffic (`outboundTrafficPolicy` + `ServiceEntry`)

**Goal:** switch the mesh from "allow any external destination" to "registry only", observe the block, then admit one external host with a `ServiceEntry`.

1. Inspect the current outbound policy:

    ```bash
    kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | grep -A2 outboundTrafficPolicy
    ```

    On the demo profile this is `ALLOW_ANY` — sidecars forward unknown destinations to a `PassthroughCluster`.

2. Confirm unrestricted egress works today:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Expected: `200`.

3. Tighten the mesh to **`REGISTRY_ONLY`** so only hosts present in Istio's service registry may be reached:

    ```bash
    istioctl install --set profile=demo \
      --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
    ```

4. Repeat the external call — it is now black-holed:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Expected: `502` (the sidecar routed to `BlackHoleCluster`).

5. Admit exactly that host with a **`ServiceEntry`**, which inserts `httpbin.org` into the registry:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: ServiceEntry
    metadata:
      name: httpbin-ext
      namespace: default
    spec:
      hosts:
      - httpbin.org
      ports:
      - number: 80
        name: http
        protocol: HTTP
      - number: 443
        name: https
        protocol: HTTPS
      resolution: DNS          # Envoy resolves the host via DNS at request time
      location: MESH_EXTERNAL   # not part of the mesh; no mTLS expected
    ```

    ```bash
    kubectl apply -f httpbin-se.yaml
    ```

6. Re-test — the call now succeeds through a real (non-blackhole) cluster:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sS -o /dev/null -w "%{http_code}\n" \
      http://httpbin.org/status/200
    ```

    Expected: `200`.

**Comprehension questions (3):**
1. In one sentence each, contrast `ALLOW_ANY` and `REGISTRY_ONLY`. Which is the more secure posture and why?
2. In step 4 the call returned `502`, not a TCP connection error. What Envoy cluster produced that response, and how does it differ from the `PassthroughCluster`?
3. The `ServiceEntry` sets `resolution: DNS`. What would `resolution: NONE` mean instead, and when would you need `resolution: STATIC` with explicit `endpoints`?
4. Does `location: MESH_EXTERNAL` change whether the sidecar attempts mTLS to the destination? Contrast with `MESH_INTERNAL`.

---

## Exercise 4 — Route egress through a dedicated egress gateway with TLS origination

**Goal:** force outbound traffic to `edition.cnn.com` through the `istio-egressgateway`, and have Istio *originate* TLS so the application can speak plain HTTP internally. This is the pattern for a controlled, auditable mesh exit point.

Traffic path: `sleep (HTTP :80)` → sidecar → **egress gateway** (mTLS in-mesh) → **TLS originated** → `edition.cnn.com:443`.

1. Define the external service on both ports:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: ServiceEntry
    metadata:
      name: cnn
      namespace: default
    spec:
      hosts:
      - edition.cnn.com
      ports:
      - number: 80
        name: http-port
        protocol: HTTP
      - number: 443
        name: https-port
        protocol: HTTPS
      resolution: DNS
    ```

2. Create the **egress `Gateway`** listening on port 80 but with protocol HTTPS + `ISTIO_MUTUAL` — the sidecar↔egress-gateway hop is secured by mesh mTLS:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: istio-egressgateway
      namespace: default
    spec:
      selector:
        istio: egressgateway
      servers:
      - port:
          number: 80
          name: https-port-for-tls-origination
          protocol: HTTPS
        hosts:
        - edition.cnn.com
        tls:
          mode: ISTIO_MUTUAL
    ```

3. Create a **`DestinationRule`** describing the egress gateway subset the sidecars will target, with `ISTIO_MUTUAL` and the correct SNI:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: DestinationRule
    metadata:
      name: egressgateway-for-cnn
      namespace: default
    spec:
      host: istio-egressgateway.istio-system.svc.cluster.local
      subsets:
      - name: cnn
        trafficPolicy:
          loadBalancer:
            simple: ROUND_ROBIN
          portLevelSettings:
          - port:
              number: 80
            tls:
              mode: ISTIO_MUTUAL
              sni: edition.cnn.com
    ```

4. Wire the two hops with one **`VirtualService`** bound to *both* `mesh` and the egress gateway:

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: direct-cnn-through-egress-gateway
      namespace: default
    spec:
      hosts:
      - edition.cnn.com
      gateways:
      - istio-egressgateway
      - mesh                     # reserved keyword = every sidecar in the mesh
      http:
      - match:                   # HOP 1: sidecar → egress gateway
        - gateways:
          - mesh
          port: 80
        route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: cnn
            port:
              number: 80
          weight: 100
      - match:                   # HOP 2: egress gateway → external host
        - gateways:
          - istio-egressgateway
          port: 80
        route:
        - destination:
            host: edition.cnn.com
            port:
              number: 443        # target the TLS port
          weight: 100
    ```

5. Add the **`DestinationRule` that originates TLS** on the external leg (plain HTTP in, HTTPS out):

    ```yaml
    apiVersion: networking.istio.io/v1
    kind: DestinationRule
    metadata:
      name: originate-tls-for-edition-cnn-com
      namespace: default
    spec:
      host: edition.cnn.com
      trafficPolicy:
        portLevelSettings:
        - port:
            number: 443
          tls:
            mode: SIMPLE          # Istio performs the TLS handshake to CNN
    ```

    ```bash
    kubectl apply -f cnn-se.yaml -f egress-gw.yaml -f egress-dr.yaml -f egress-vs.yaml -f originate-tls-dr.yaml
    ```

6. Send **plain HTTP** from the app and observe a successful HTTPS-backed response:

    ```bash
    kubectl exec "$SOURCE_POD" -c sleep -- curl -sSL -o /dev/null -w "%{http_code}\n" \
      http://edition.cnn.com/politics
    ```

    Expected: `200`.

7. Prove the traffic actually transited the egress gateway (not a direct sidecar exit):

    ```bash
    kubectl logs -l istio=egressgateway -n istio-system -c istio-proxy | tail -1
    ```

    Expected: an access-log line referencing `edition.cnn.com` and outbound cluster `outbound|443||edition.cnn.com`.

**Comprehension questions (4):**
1. The application issues an `http://` request on port 80, yet CNN is reached over TLS on 443. Which resource performs the TLS origination, and at which hop?
2. Why is the egress gateway listener declared as `protocol: HTTPS` with `mode: ISTIO_MUTUAL` even though the app speaks plain HTTP to it?
3. The `VirtualService` lists `mesh` and `istio-egressgateway` under `gateways`, and each `http` rule matches a specific `gateways`/`port`. What breaks if you omit the `match.gateways` selectors and let both rules match everywhere?
4. Give two operational reasons an organization forces egress through a gateway instead of letting sidecars exit directly.

---

## Exercise 5 — Diagnose edge configuration with `istioctl proxy-config`

**Goal:** read the generated Envoy config to confirm your intent, and recognize the black-hole/passthrough signature.

1. Inspect the ingress gateway's listeners and the HTTPS route created in Exercise 2:

    ```bash
    istioctl proxy-config listeners deploy/istio-ingressgateway.istio-system
    istioctl proxy-config routes  deploy/istio-ingressgateway.istio-system \
      --name https.443.https.httpbin-gateway.default -o json | head -40
    ```

    You should see a `0.0.0.0:8443` listener and a route whose `domains` include `httpbin.example.com`.

2. From the app sidecar, confirm the `ServiceEntry` from Exercise 3 produced a real cluster:

    ```bash
    istioctl proxy-config clusters "$SOURCE_POD" --fqdn httpbin.org
    ```

    Expected: a `outbound|80||httpbin.org` / `outbound|443||httpbin.org` cluster of type `STRICT_DNS`.

3. Look for the tell-tale synthetic clusters:

    ```bash
    istioctl proxy-config clusters "$SOURCE_POD" | grep -E 'BlackHole|Passthrough'
    ```

    Under `REGISTRY_ONLY` you'll see `BlackHoleCluster`; under `ALLOW_ANY` you'll see `PassthroughCluster`.

4. Get a human-readable summary of everything affecting the pod, including which `ServiceEntry`/`VirtualService` apply:

    ```bash
    istioctl x describe pod "$SOURCE_POD"
    ```

**Comprehension questions (5):**
1. Using `proxy-config`, which subcommand and filter proves that a specific `ServiceEntry` host became a routable cluster on a given proxy?
2. You see `BlackHoleCluster` in a sidecar's cluster dump and requests to an external host return `502`. What single mesh-level setting most likely explains it, and what is the fix that does *not* loosen the whole mesh?
3. What is the practical difference in symptom between hitting `BlackHoleCluster` (HTTP `502`) and `PassthroughCluster` when the destination is genuinely unreachable?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
1. `spec.selector` is a label selector matched against the **pods** of gateway proxies (e.g. `istio=ingressgateway` on the `istio-ingressgateway` deployment). If no pod carries the label, the `Gateway` config is generated but attached to nothing, so the listener never materializes and the host stays unreachable.
2. A `Gateway` only opens a **listener** (port + protocol + permitted hosts) on the proxy. It carries no routing table. Without a `VirtualService` bound to it, the proxy accepts the connection for `httpbin.example.com` but has no `route` telling it which backend to forward to, so it returns `404` (no matching virtual host/route) — effectively unreachable.
3. `gateways:` binds the `VirtualService`'s routes to specific gateways by name (`httpbin-gateway`, or `namespace/name` across namespaces). Adding the reserved value **`mesh`** would additionally apply the same routing rules to *sidecar-originated* (east-west) traffic inside the mesh, not just north-south traffic entering through the gateway.
4. The **`VirtualService`**. Its `http.match` only covers `/status` and `/headers` prefixes; `/ip` matches nothing and yields `404`. The `Gateway` merely admitted the host on port 80.

### Exercise 2
1. It must live in **`istio-system`** — the namespace of the ingress gateway **pod** that loads it, because that proxy's SDS client fetches the credential. A secret named `httpbin-credential` in `default` is invisible to the gateway, so the TLS listener has no cert and the handshake fails with a connection reset / `Nc TLS` error.
2. `SIMPLE` = one-way TLS: the gateway presents a server cert and terminates TLS (client is not authenticated). `MUTUAL` = mTLS: the gateway *also* validates the client cert against a CA (add `caCertificates`/`credentialName` for the CA). `PASSTHROUGH` = the gateway does **not** decrypt; it inspects only the TLS SNI and forwards the still-encrypted bytes to the backend (used with `tls` route matching in the `VirtualService`).
3. **No restart is needed.** istiod watches the `Secret`; on change it pushes the new certificate to the gateway proxy over **SDS** (Secret Discovery Service) as an xDS update. The Envoy hot-swaps the cert in place. This is precisely why cert rotation is a live operation.
4. There is no public DNS record for `httpbin.example.com` and the CA is self-signed. `--resolve` maps the virtual host to the ingress IP/port so SNI and the `Host` header are correct, and `--cacert example.com.crt` trusts our private CA so verification passes.

### Exercise 3
1. `ALLOW_ANY`: sidecars forward traffic to *unknown* destinations to a `PassthroughCluster`, i.e. anything can be reached. `REGISTRY_ONLY`: only hosts present in Istio's service registry (cluster services + `ServiceEntry` hosts) are allowed; everything else is black-holed. `REGISTRY_ONLY` is the more secure posture because it is default-deny — external access must be explicitly declared.
2. The **`BlackHoleCluster`** produced the `502`. It is a synthetic cluster with no endpoints that Istio routes disallowed traffic to, so the request is *rejected at L7 with a `502`* rather than leaving the pod. The `PassthroughCluster` is the opposite: an `ORIGINAL_DST` cluster that forwards the connection to whatever address the client asked for, allowing the traffic.
3. `resolution: DNS` makes Envoy resolve the host name itself and load-balance across the resolved IPs. `resolution: NONE` means Envoy performs **no** resolution and connects to the original destination IP the client used (passthrough-style, for opaque/IP traffic). `resolution: STATIC` is required when you enumerate fixed backend IPs in `spec.endpoints` (e.g. a legacy VM fleet) rather than relying on DNS.
4. `location: MESH_EXTERNAL` tells Istio the destination is outside the mesh, so the sidecar does **not** attempt Istio mTLS and treats it as a plain external endpoint (TLS, if any, is the app's or is originated via a `DestinationRule`). `MESH_INTERNAL` marks the host as part of the mesh, making it eligible for mTLS and mesh identity — appropriate for services running on VMs joined to the mesh.

### Exercise 4
1. The **`DestinationRule` `originate-tls-for-edition-cnn-com`** performs TLS origination, at the **second hop** (egress gateway → `edition.cnn.com:443`). Its `portLevelSettings[443].tls.mode: SIMPLE` tells Envoy to open a TLS connection to CNN. The app and the sidecar-to-gateway hop stay plaintext-as-far-as-the-app-is-concerned (the gateway hop is wrapped in mesh mTLS).
2. `ISTIO_MUTUAL` secures the in-mesh hop between the client sidecar and the egress gateway with Istio's automatic mTLS (mesh identities/certs). The listener is `HTTPS` because that mTLS *is* TLS; the app still speaks plain HTTP on port 80, and Istio wraps it. This gives you an authenticated, encrypted path to the exit node without the app doing anything.
3. The two `http` rules are disambiguated by `match.gateways` + `port`: the first applies only to `mesh` traffic, the second only to traffic arriving *on* the egress gateway. If you drop the selectors, both rules match the same traffic; the first (send-to-egress-gateway) matches on the gateway too, creating a **routing loop / ambiguous match** where the egress gateway keeps sending traffic back to itself instead of out to CNN.
4. Any two of: (a) a **single audited/monitored exit point** for compliance and access logging; (b) apply **egress policy / allow-lists** and TLS origination centrally rather than per-app; (c) let nodes running sidecars stay on a private network while only the gateway nodes need public egress (firewall/NAT allow-listing by the gateway's IPs); (d) offload TLS origination and certificate management from applications.

### Exercise 5
1. `istioctl proxy-config clusters <pod> --fqdn <host>` — if the `ServiceEntry` host appears as an `outbound|<port>||<host>` cluster (type `STRICT_DNS`/`EDS`), it became routable on that proxy. (`istioctl x describe pod` corroborates which config objects apply.)
2. The mesh is set to **`outboundTrafficPolicy.mode: REGISTRY_ONLY`** and the host isn't in the registry, so it falls to `BlackHoleCluster`. The scoped fix is to add a `ServiceEntry` for that specific host (optionally namespace-scoped via a `Sidecar` resource) — this admits only the intended destination and does **not** loosen the whole mesh back to `ALLOW_ANY`.
3. `BlackHoleCluster` is a **policy decision**: the destination was *disallowed*, so Envoy short-circuits with a clean `502` regardless of whether the host is up. `PassthroughCluster` means the traffic *was allowed to leave*; if the destination is genuinely unreachable you instead see connection-level failures (timeouts, connection refused/reset, `503 UF`/`UO` upstream flags) because the packet actually went out and failed on the network — not a policy `502`.

</details>