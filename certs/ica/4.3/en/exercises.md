# ICA — Topic 4.3: Securing Edge Traffic with TLS — Guided Exercises

> **Scope.** These labs cover terminating and forwarding TLS at the Istio ingress gateway: `SIMPLE` termination, HTTP→HTTPS redirect, `MUTUAL` (client-cert) authentication, `PASSTHROUGH` with SNI routing, TLS hardening, and SDS-based diagnostics. Every step is idempotent enough to re-run; delete the objects you create at the end of each exercise if you want a clean slate.
>
> **Assumed environment.** A cluster with Istio installed (`istioctl install` / demo profile), the `istio-ingressgateway` Service present in `istio-system`, and `kubectl`, `istioctl`, `openssl` and `curl` on your path. Where a `LoadBalancer` IP is unavailable (kind/minikube), the labs show the `NodePort`/port-forward fallback.
>
> **Official references**
> - Secure Ingress Gateways — https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
> - Ingress Gateway without TLS Termination (SNI passthrough) — https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/
> - `Gateway` / `ServerTLSSettings` reference — https://istio.io/latest/docs/reference/config/networking/gateway/
> - TLS configuration operations guide — https://istio.io/latest/docs/ops/configuration/traffic-management/tls-configuration/
> - ICA curriculum — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

---

## Exercise 0 — Lab bootstrap: sample workload and ingress coordinates

You need a backend to route to and the address of the ingress gateway. `httpbin` is used throughout because its `/status/<code>` endpoint makes success/failure unambiguous.

1. Create a namespace with sidecar injection and deploy `httpbin`:

   ```bash
   kubectl create namespace edge-tls
   kubectl label namespace edge-tls istio-injection=enabled
   kubectl apply -n edge-tls \
     -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/httpbin/httpbin.yaml
   ```

2. Confirm the pod is running with **two** containers (app + `istio-proxy`):

   ```bash
   kubectl get pod -n edge-tls -l app=httpbin
   ```
   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7c8b9f4d5b-mxz2k   2/2     Running   0          25s
   ```

3. Capture the ingress host and the two ports you will use (HTTP `80`, HTTPS `443`):

   ```bash
   export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
   export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
   echo "HOST=$INGRESS_HOST  HTTP=$INGRESS_PORT  HTTPS=$SECURE_INGRESS_PORT"
   ```
   ```
   HOST=203.0.113.10  HTTP=80  HTTPS=443
   ```

4. **Fallback if `INGRESS_HOST` is empty** (no external load balancer). Use the NodePorts and a node IP instead:

   ```bash
   export INGRESS_HOST=$(kubectl get nodes \
     -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
   export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   ```

**Comprehension check**

- Q0.1 — Why does `kubectl get pod` show `2/2` and not `1/1`, and which container actually performs TLS work for edge traffic — the one in `edge-tls` or the one in `istio-system`?
- Q0.2 — The `httpbin` Service listens on plain HTTP port `8000`. Given that, at which hop in the path `client → ingress → httpbin` is the TLS you configure in the next exercises actually terminated?

---

## Exercise 1 — TLS termination at the edge (`SIMPLE` mode)

Here the gateway terminates TLS: the client speaks HTTPS to the gateway, the gateway speaks plaintext to `httpbin`.

1. Create a self-signed root CA, then a server certificate for `httpbin.example.com` signed by it:

   ```bash
   mkdir -p certs && cd certs

   # Root CA
   openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
     -subj '/O=example Inc./CN=example.com' \
     -keyout example.com.key -out example.com.crt

   # Server key + CSR
   openssl req -out httpbin.example.com.csr -newkey rsa:2048 -nodes \
     -keyout httpbin.example.com.key \
     -subj "/CN=httpbin.example.com/O=httpbin organization"

   # Sign the server cert with the CA
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 1 \
     -in httpbin.example.com.csr -out httpbin.example.com.crt
   cd ..
   ```

2. Load the server cert/key into a **Kubernetes `tls` Secret in the `istio-system` namespace** (the namespace where the gateway workload runs — *not* `edge-tls`):

   ```bash
   kubectl create -n istio-system secret tls httpbin-credential \
     --key=certs/httpbin.example.com.key \
     --cert=certs/httpbin.example.com.crt
   ```

3. Declare a `Gateway` that serves HTTPS on `443` in `SIMPLE` mode, referencing the secret by name via `credentialName`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: httpbin-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway            # matches the istio-ingressgateway pod labels
     servers:
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential   # secret name in the gateway's namespace
       hosts:
       - httpbin.example.com
   ```

4. Bind a `VirtualService` to that gateway so the host is actually routed to `httpbin`:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: httpbin
     namespace: edge-tls
   spec:
     hosts:
     - httpbin.example.com
     gateways:
     - httpbin-gateway
     http:
     - match:
       - uri:
           prefix: /status
       route:
       - destination:
           host: httpbin.edge-tls.svc.cluster.local
           port:
             number: 8000
   ```

5. Apply both manifests (assume you saved them as `gw-simple.yaml` and `vs-httpbin.yaml`):

   ```bash
   kubectl apply -f gw-simple.yaml -f vs-httpbin.yaml
   ```

6. Send an HTTPS request. `--resolve` forces the SNI/Host `httpbin.example.com` to your ingress IP, and `--cacert` trusts your CA:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * Server certificate:
   *  subject: CN=httpbin.example.com; O=httpbin organization
   *  issuer: O=example Inc.; CN=example.com
   *  SSL certificate verify ok.
   > GET /status/418 HTTP/2
   < HTTP/2 418
   ...
   -=[ teapot ]=-
   ```

**Comprehension check**

- Q1.1 — You created the secret in `istio-system`, but the `Gateway` object lives in `edge-tls`. Why does `credentialName` resolve against `istio-system` and not `edge-tls`? What single symptom appears in the client if you had created the secret in `edge-tls` by mistake?
- Q1.2 — The `Gateway` `selector` is `istio: ingressgateway`. What does this selector actually match, and what happens to the `Gateway` config if no pod carries that label?
- Q1.3 — After editing the Secret with a renewed certificate, do you need to restart or redeploy the `istio-ingressgateway` pod for the new cert to be served? Name the mechanism that makes your answer true.
- Q1.4 — In `curl`, what is the difference in purpose between `--resolve` and `--cacert` here? Which one would you drop if the cert’s SAN already matched a real DNS name you control?

---

## Exercise 2 — Force HTTPS: HTTP→HTTPS redirect

Serving `443` is not enough; port `80` should not silently serve plaintext.

1. Add an HTTP server block on port `80` with `httpsRedirect: true`. Edit the same `Gateway` so it now has **two** servers:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: httpbin-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway
     servers:
     - port:
         number: 80
         name: http
         protocol: HTTP
       tls:
         httpsRedirect: true          # 301 to https:// for this host
       hosts:
       - httpbin.example.com
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential
       hosts:
       - httpbin.example.com
   ```

2. Apply and test the plaintext port. You should receive a redirect, not content:

   ```bash
   kubectl apply -f gw-simple.yaml
   curl -sI --resolve "httpbin.example.com:$INGRESS_PORT:$INGRESS_HOST" \
     "http://httpbin.example.com:$INGRESS_PORT/status/418"
   ```
   ```
   HTTP/1.1 301 Moved Permanently
   location: https://httpbin.example.com/status/418
   server: istio-envoy
   ```

**Comprehension check**

- Q2.1 — `httpsRedirect: true` sits under `tls:` even though the server block’s protocol is `HTTP`. Where does the redirect happen — the gateway (Envoy) or the backend — and what status code and header prove it?
- Q2.2 — The `Location` header points at `https://httpbin.example.com/...` with no port. If your ingress HTTPS port is a NodePort like `31390`, why can this redirect break a real browser, and what production fix removes the problem?

---

## Exercise 3 — Mutual TLS at the edge (`MUTUAL` mode)

Now the gateway also authenticates the **client**: only callers presenting a certificate signed by a CA you trust get through.

1. Create a client key/cert signed by the same CA:

   ```bash
   cd certs
   openssl req -out client.example.com.csr -newkey rsa:2048 -nodes \
     -keyout client.example.com.key \
     -subj "/CN=client.example.com/O=client organization"
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 2 \
     -in client.example.com.csr -out client.example.com.crt
   cd ..
   ```

2. Recreate the credential as a **generic Secret carrying the CA cert** under `ca.crt`, alongside the server `tls.crt`/`tls.key`. Delete the old one first:

   ```bash
   kubectl delete -n istio-system secret httpbin-credential
   kubectl create -n istio-system secret generic httpbin-credential \
     --from-file=tls.key=certs/httpbin.example.com.key \
     --from-file=tls.crt=certs/httpbin.example.com.crt \
     --from-file=ca.crt=certs/example.com.crt
   ```

3. Switch the HTTPS server block’s `mode` from `SIMPLE` to `MUTUAL`:

   ```yaml
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: MUTUAL
         credentialName: httpbin-credential
       hosts:
       - httpbin.example.com
   ```
   ```bash
   kubectl apply -f gw-simple.yaml
   ```

4. Prove that a request **without** a client cert is now rejected at the handshake:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * TLSv1.3 (OUT), TLS handshake, Client hello (1):
   * TLSv1.3 (IN), TLS alert, unknown (628):
   * OpenSSL/3.x: error:0A000418:SSL routines::tlsv1 alert unknown ca
   * Closing connection
   ```

5. Now present the client cert/key and succeed:

   ```bash
   curl -v --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     --cert certs/client.example.com.crt \
     --key certs/client.example.com.key \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418"
   ```
   ```
   * TLSv1.3 (OUT), TLS handshake, Certificate (11):
   < HTTP/2 418
   -=[ teapot ]=-
   ```

**Comprehension check**

- Q3.1 — Which key in the Secret (`tls.crt`, `tls.key`, or `ca.crt`) is the one that `MUTUAL` needs and `SIMPLE` ignores, and what is it used for during the handshake?
- Q3.2 — The failed request in step 4 aborts during the TLS handshake, before any HTTP request line is sent. Why is that architecturally significant compared with enforcing client identity in application code or a `RequestAuthentication`?
- Q3.3 — Istio also supports a separate Secret named `<credentialName>-cacert` as an alternative to embedding `ca.crt`. When would you prefer the separate `-cacert` Secret over one combined Secret?
- Q3.4 — `MUTUAL` rejects clients lacking a cert. Which `ServerTLSSettings` mode would let you *request* a client cert but still admit clients that present none (e.g. during a migration)?

---

## Exercise 4 — TLS passthrough with SNI routing (`PASSTHROUGH` mode)

Sometimes the backend must terminate TLS itself (end-to-end encryption, or the app owns its own cert). The gateway then routes purely on the SNI in the ClientHello, without decrypting.

1. Deploy an NGINX that terminates its **own** TLS on `443`. First build its config and cert into secrets:

   ```bash
   cd certs
   openssl req -out nginx.example.com.csr -newkey rsa:2048 -nodes \
     -keyout nginx.example.com.key \
     -subj "/CN=nginx.example.com/O=some organization"
   openssl x509 -req -sha256 -days 365 \
     -CA example.com.crt -CAkey example.com.key -set_serial 3 \
     -in nginx.example.com.csr -out nginx.example.com.crt
   cd ..

   kubectl create -n edge-tls secret tls nginx-server-certs \
     --key certs/nginx.example.com.key \
     --cert certs/nginx.example.com.crt
   ```

2. Provide an NGINX config that serves HTTPS, store it as a ConfigMap, and deploy NGINX mounting both:

   ```bash
   cat > nginx.conf <<'EOF'
   events {}
   http {
     log_format main '$remote_addr - $remote_user [$time_local] $status "$request"';
     access_log /var/log/nginx/access.log main;
     server {
       listen 443 ssl;
       root /usr/share/nginx/html;
       index index.html;
       server_name nginx.example.com;
       ssl_certificate     /etc/nginx-server-certs/tls.crt;
       ssl_certificate_key /etc/nginx-server-certs/tls.key;
     }
   }
   EOF
   kubectl create -n edge-tls configmap nginx-configmap --from-file=nginx.conf=nginx.conf
   ```

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: my-nginx
     namespace: edge-tls
     labels: { run: my-nginx }
   spec:
     ports:
     - port: 443
       protocol: TCP
     selector: { run: my-nginx }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: my-nginx
     namespace: edge-tls
   spec:
     selector: { matchLabels: { run: my-nginx } }
     replicas: 1
     template:
       metadata: { labels: { run: my-nginx } }
       spec:
         containers:
         - name: my-nginx
           image: nginx
           ports: [ { containerPort: 443 } ]
           volumeMounts:
           - { name: nginx-config, mountPath: /etc/nginx, readOnly: true }
           - { name: nginx-server-certs, mountPath: /etc/nginx-server-certs, readOnly: true }
         volumes:
         - name: nginx-config
           configMap: { name: nginx-configmap }
         - name: nginx-server-certs
           secret: { secretName: nginx-server-certs }
   ```

3. Define a `Gateway` whose server uses `protocol: TLS` and `mode: PASSTHROUGH`. Note there is **no `credentialName`** — the gateway holds no cert:

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: Gateway
   metadata:
     name: nginx-gateway
     namespace: edge-tls
   spec:
     selector:
       istio: ingressgateway
     servers:
     - port:
         number: 443
         name: https
         protocol: TLS
       tls:
         mode: PASSTHROUGH
       hosts:
       - nginx.example.com
   ```

4. Route with a `VirtualService` `tls` block that matches on `sniHosts` (not HTTP paths — the gateway can’t see inside the encrypted stream):

   ```yaml
   apiVersion: networking.istio.io/v1
   kind: VirtualService
   metadata:
     name: nginx
     namespace: edge-tls
   spec:
     hosts:
     - nginx.example.com
     gateways:
     - nginx-gateway
     tls:
     - match:
       - port: 443
         sniHosts:
         - nginx.example.com
       route:
       - destination:
           host: my-nginx.edge-tls.svc.cluster.local
           port:
             number: 443
   ```

5. Apply and test. The response cert is signed by your CA and issued to `nginx.example.com` — proof the **backend**, not the gateway, terminated TLS:

   ```bash
   kubectl apply -f nginx.yaml -f gw-passthrough.yaml -f vs-nginx.yaml
   curl -v --resolve "nginx.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://nginx.example.com:$SECURE_INGRESS_PORT/"
   ```
   ```
   * Server certificate:
   *  subject: CN=nginx.example.com; O=some organization
   *  issuer: O=example Inc.; CN=example.com
   < HTTP/1.1 200 OK
   < server: nginx/1.27.0
   ```

**Comprehension check**

- Q4.1 — In `PASSTHROUGH`, why does the `VirtualService` route on `tls.match.sniHosts` instead of `http.match.uri`? What information is the *only* thing the gateway can see to make a routing decision?
- Q4.2 — The server block uses `protocol: TLS`, while the `SIMPLE`/`MUTUAL` exercises used `protocol: HTTPS`. Explain the semantic difference between `HTTPS` and `TLS` here.
- Q4.3 — A client connects with SNI `other.example.com`, for which no `sniHosts` match exists. What does the gateway do with that connection, and why is it *not* a 404?
- Q4.4 — With passthrough, which two Istio features become unavailable for this traffic that you *would* have with `SIMPLE` termination (think L7 routing and observability)?

---

## Exercise 5 — Hardening the TLS listener

Production edges pin a minimum protocol version and an approved cipher list.

1. Add `minProtocolVersion` and an explicit `cipherSuites` list to the `SIMPLE`/`MUTUAL` HTTPS server block (revert `mode` to `SIMPLE` first if you left it at `MUTUAL`):

   ```yaml
     - port:
         number: 443
         name: https
         protocol: HTTPS
       tls:
         mode: SIMPLE
         credentialName: httpbin-credential
         minProtocolVersion: TLSV1_2
         maxProtocolVersion: TLSV1_3
         cipherSuites:
         - ECDHE-ECDSA-AES256-GCM-SHA384
         - ECDHE-RSA-AES256-GCM-SHA384
         - ECDHE-ECDSA-AES128-GCM-SHA256
         - ECDHE-RSA-AES128-GCM-SHA256
   ```
   ```bash
   kubectl apply -f gw-simple.yaml
   ```

2. Prove a TLS 1.1 client is refused, and a TLS 1.2+ client succeeds:

   ```bash
   # Forced down-level handshake — must fail
   curl -v --tlsv1.1 --tls-max 1.1 \
     --resolve "httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST" \
     --cacert certs/example.com.crt \
     "https://httpbin.example.com:$SECURE_INGRESS_PORT/status/200"
   ```
   ```
   * TLSv1.1 (OUT), TLS handshake, Client hello (1):
   * OpenSSL/3.x: error: ... tlsv1 alert protocol version
   ```

**Comprehension check**

- Q5.1 — `cipherSuites` here uses TLS 1.2 cipher names, but you also allowed `TLSV1_3`. Does `cipherSuites` govern the TLS 1.3 cipher selection? Explain what actually happens for a TLS 1.3 handshake.
- Q5.2 — Besides per-`Gateway` `ServerTLSSettings`, name the mesh-wide place where you could enforce a minimum TLS version for *all* gateways at once, so a new team can’t ship a weaker listener.

---

## Exercise 6 — Diagnosing edge TLS with `istioctl` and SDS

When the handshake fails, the question is always: *did the cert actually reach Envoy?*

1. Find the ingress gateway pod and inspect the secrets Envoy received via **SDS** (Secret Discovery Service):

   ```bash
   INGRESS_POD=$(kubectl -n istio-system get pod -l istio=ingressgateway \
     -o jsonpath='{.items[0].metadata.name}')
   istioctl proxy-config secret "$INGRESS_POD" -n istio-system
   ```
   ```
   RESOURCE NAME                          TYPE           STATUS      VALID CERT     SERIAL NUMBER   NOT AFTER
   kubernetes://httpbin-credential        Cert Chain     ACTIVE      true           1               2027-08-08T...
   kubernetes://httpbin-credential-cacert Cert Chain     ACTIVE      true           -               2027-08-08T...
   default                                Cert Chain     ACTIVE      true           ...             ...
   ROOTCA                                 CA             ACTIVE      true           ...             ...
   ```

2. Confirm a listener actually exists on `443` and is wired to the credential:

   ```bash
   istioctl proxy-config listener "$INGRESS_POD" -n istio-system --port 443 -o json \
     | grep -A2 -i 'sdsConfig\|serverNames\|filterChainMatch' | head -30
   ```

3. If SDS shows the secret as `WARMING` or missing, watch the gateway logs while you re-apply the Secret:

   ```bash
   kubectl logs -n istio-system "$INGRESS_POD" | grep -iE 'sds|secret|warming|failed'
   ```

4. Verify what the gateway presents on the wire, independent of Istio, with `openssl s_client`:

   ```bash
   openssl s_client -connect "$INGRESS_HOST:$SECURE_INGRESS_PORT" \
     -servername httpbin.example.com -CAfile certs/example.com.crt </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer -dates
   ```
   ```
   subject=CN=httpbin.example.com, O=httpbin organization
   issuer=O=example Inc., CN=example.com
   notBefore=... notAfter=...
   ```

**Comprehension check**

- Q6.1 — `istioctl proxy-config secret` shows a `kubernetes://httpbin-credential` entry with `STATUS: ACTIVE`. What does that prove that a `kubectl get secret` in `istio-system` does *not*?
- Q6.2 — You updated the Secret but SDS still shows the old serial number. Give two plausible causes and the first command you’d run for each.
- Q6.3 — In step 4 you deliberately bypass `curl`’s Istio-aware flags and use `openssl s_client -servername`. Why is passing `-servername` essential to reproduce what the gateway does, especially once more than one host shares port `443`?

---

## Cleanup

```bash
kubectl delete namespace edge-tls
kubectl delete -n istio-system secret httpbin-credential nginx-server-certs --ignore-not-found
rm -rf certs nginx.conf gw-*.yaml vs-*.yaml nginx.yaml
```

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 0**

- **A0.1** — `2/2` means the pod runs the `httpbin` app container plus the injected `istio-proxy` (Envoy) sidecar, because the `edge-tls` namespace carries `istio-injection=enabled`. But the edge TLS work in these labs is done by a *different* Envoy: the shared `istio-ingressgateway` pod in `istio-system`. The `edge-tls` sidecar handles east-west/mesh traffic to `httpbin`, not the north-south TLS handshake with the external client.
- **A0.2** — With `SIMPLE`/`MUTUAL` termination, TLS is terminated at the **ingress gateway** (`istio-system`). From gateway to `httpbin:8000` the traffic is plaintext HTTP inside the mesh (optionally re-encrypted with Istio mTLS between the sidecars, but that is a separate mechanism from the edge cert you configure here). With `PASSTHROUGH` the gateway terminates nothing and TLS is terminated at the backend pod.

**Exercise 1**

- **A1.1** — `credentialName` is resolved by the ingress gateway’s `istio-agent`, which pulls the Secret from **its own namespace** — the namespace where the `istio-ingressgateway` workload runs (`istio-system`), regardless of where the `Gateway` object lives. If you put the Secret in `edge-tls`, the gateway never gets a server certificate, the TLS listener stays in a warming/no-cert state, and the client sees a connection reset / handshake failure (`curl` reports a TLS error, not an HTTP status).
- **A1.2** — The `selector` matches **pod labels** on the gateway workload (the `istio-ingressgateway` Deployment’s pods carry `istio: ingressgateway`). Istio programs the `Gateway` config only into Envoys whose pods match. If no pod carries the label, the config is accepted by the API server but never programmed onto any proxy — nothing listens, and requests fail at the network level.
- **A1.3** — No restart is needed. The gateway uses **SDS (Secret Discovery Service)**: `istio-agent` watches the Kubernetes Secret and streams cert updates to Envoy dynamically over the SDS gRPC API. Rotating the Secret hot-swaps the cert with no pod restart and no config reload.
- **A1.4** — `--resolve` overrides DNS so the SNI/Host `httpbin.example.com` maps to your ingress IP:port (needed because the name isn’t in real DNS). `--cacert` tells `curl` to trust your self-signed CA so verification of the server cert passes. If `httpbin.example.com` were a real DNS name pointing at the ingress, you could drop `--resolve`; `--cacert` would still be required until the cert is issued by a publicly trusted CA.

**Exercise 2**

- **A2.1** — The redirect is issued by the **gateway (Envoy)** itself; the request never reaches `httpbin`. Proof: `HTTP/1.1 301 Moved Permanently`, a `location:` header pointing at the `https://` URL, and `server: istio-envoy`. `httpsRedirect` is a property of the HTTP listener’s TLS settings even though the listener speaks plaintext, because it governs how that listener responds.
- **A2.2** — Envoy builds the redirect target as `https://<host>/<path>` using the *standard* HTTPS port (443), dropping any non-standard NodePort. A browser then tries `https://httpbin.example.com/` on 443, which isn’t where the gateway listens, so it fails. The production fix is to expose the gateway on the standard `443` (a real LoadBalancer or an external LB/NodePort mapping 443→ingress), so the redirect lands on a listening port.

**Exercise 3**

- **A3.1** — `ca.crt` (the CA bundle). `MUTUAL` uses it to verify the client certificate the caller presents during the handshake. `SIMPLE` never asks for a client cert, so `ca.crt` is irrelevant there; only `tls.crt`/`tls.key` (the server identity) are used.
- **A3.2** — Rejection happens **during the TLS handshake**, before the HTTP request is parsed or even fully received. An unauthorized client can’t send a request body, exploit an L7 parser bug, or consume backend resources — the connection is dropped at the transport layer. Application-level or `RequestAuthentication`/JWT checks run *after* the request is decoded and admitted, a strictly larger attack surface.
- **A3.3** — Use the separate `<credentialName>-cacert` Secret when the CA trust bundle is managed by a different team/rotation cadence than the server cert, or when you want to update the trusted-CA list without touching (and risking) the server key/cert. Combining them is simpler but couples their lifecycles.
- **A3.4** — `OPTIONAL_MUTUAL`. It requests a client certificate and verifies it if presented, but still admits clients that send none — useful for gradually onboarding clients to mTLS.

**Exercise 4**

- **A4.1** — In passthrough the gateway does **not** decrypt the stream, so it cannot see the HTTP method, path, or headers — the only cleartext available is the **SNI (Server Name Indication)** in the TLS ClientHello. Routing must therefore match on `sniHosts`. HTTP-level matches (`uri`, `headers`) are impossible.
- **A4.2** — `protocol: HTTPS` tells Istio the gateway terminates TLS and then treats the inner traffic as HTTP (enabling L7 routing/observability). `protocol: TLS` (with `PASSTHROUGH`) tells Istio to treat the connection as an opaque TLS stream to be forwarded based on SNI, with no termination and no L7 visibility.
- **A4.3** — With no matching `sniHosts` route, there is no filter chain / route for that SNI, so Envoy **closes/resets the connection** at the TLS layer. It can’t return a 404 because a 404 is an HTTP response, and the gateway never terminates TLS to speak HTTP — there’s no decrypted request to answer.
- **A4.4** — L7 features are lost: (1) HTTP-level routing (path/header/method matching, retries, fault injection, header manipulation), and (2) L7 telemetry/observability (per-request metrics, tracing, access logs with HTTP details). You only get L4 connection-level data.

**Exercise 5**

- **A5.1** — No. The `cipherSuites` field controls **TLS 1.2 (and below)** cipher selection only. TLS 1.3 uses its own fixed set of AEAD cipher suites negotiated by the TLS stack (BoringSSL/Envoy); the `cipherSuites` list does not restrict them. If you must forbid TLS 1.3’s ciphers, you’d cap `maxProtocolVersion` at `TLSV1_2` — but that’s usually the wrong trade-off.
- **A5.2** — The mesh-wide `MeshConfig` (`meshConfig.meshMTLS.minProtocolVersion`, and TLS defaults such as `meshConfig.tlsDefaults`/`minProtocolVersion`) lets you set a floor applied across proxies, so a per-`Gateway` config can’t silently drop below the org minimum. (In practice this is enforced via the Istio install/`IstioOperator` `meshConfig`.)

**Exercise 6**

- **A6.1** — `kubectl get secret` proves the Secret *exists in the API server*. `istioctl proxy-config secret ... STATUS: ACTIVE` proves the cert was actually **delivered to Envoy over SDS and loaded** into the running proxy — i.e. the data path is armed. A Secret can exist yet never reach Envoy (wrong namespace, wrong key names, SDS error), which the second command catches and the first does not.
- **A6.2** — (1) SDS hasn’t pushed yet / is stuck warming → run `kubectl logs -n istio-system "$INGRESS_POD" | grep -i sds` (or restart the agent as a last resort). (2) The Secret keys are wrong (e.g. `cert`/`key` instead of `tls.crt`/`tls.key`, or missing `ca.crt` for `MUTUAL`) so the new material was rejected → run `kubectl get secret httpbin-credential -n istio-system -o yaml` and check the key names. A stale serial can also mean you edited a *different* Secret/namespace than the one `credentialName` resolves to.
- **A6.3** — When multiple hosts share port `443`, Envoy selects the filter chain / server cert by **SNI**. Without `-servername`, `openssl s_client` sends no SNI, so you may hit a default/other chain and see the wrong cert (or a handshake failure) — not what a real client requesting `httpbin.example.com` would get. `-servername httpbin.example.com` reproduces the exact SNI-based selection the gateway performs.

</details>