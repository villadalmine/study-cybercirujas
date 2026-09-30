# CKNE 4.3 — Managing TLS Certificates for Gateway API: Guided Exercises

> **Exam weight:** 6.24%
> **Goal:** Configure, debug and rotate the certificates a Gateway presents to clients. Automate issuance with cert-manager, pass TLS through untouched, and have the Gateway validate the certificates your backends present.

## Official references

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Gateway API TLS guide: https://gateway-api.sigs.k8s.io/guides/tls/
- Gateway API spec reference: https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
- ReferenceGrant: https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
- BackendTLSPolicy: https://gateway-api.sigs.k8s.io/reference/api-types/policy/backendtlspolicy/
- Kubernetes TLS Secrets: https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- cert-manager Gateway API integration: https://cert-manager.io/docs/usage/gateway/
- Envoy Gateway, securing Gateways: https://gateway.envoyproxy.io/docs/tasks/security/secure-gateways/
- Envoy Gateway, TLS passthrough: https://gateway.envoyproxy.io/docs/tasks/security/tls-passthrough/

The exercises use **Envoy Gateway** as the implementation. Every Gateway API object shown here works with any conformant implementation. Only the lines that find the data-plane Service are specific to Envoy Gateway.

---

## Exercise 0 — Lab setup

### Steps

1. Create a disposable cluster, for example with kind:

   ```bash
   kind create cluster --name ckne-tls
   kubectl cluster-info --context kind-ckne-tls
   ```

2. Install Envoy Gateway. Set the version to the current release from the project's release page:

   ```bash
   export EG_VERSION=v1.5.0
   helm install eg oci://docker.io/envoyproxy/gateway-helm \
     --version "${EG_VERSION}" \
     -n envoy-gateway-system --create-namespace
   kubectl -n envoy-gateway-system wait deploy/envoy-gateway \
     --for=condition=Available --timeout=5m
   ```

3. Check which Gateway API CRDs exist, and at which versions:

   ```bash
   kubectl api-resources --api-group=gateway.networking.k8s.io
   ```

   Expected output (versions depend on the bundle installed):

   ```
   NAME                  SHORTNAMES   APIVERSION                           NAMESPACED   KIND
   backendtlspolicies    btlspolicy   gateway.networking.k8s.io/v1         true         BackendTLSPolicy
   gatewayclasses        gc           gateway.networking.k8s.io/v1         false        GatewayClass
   gateways              gtw          gateway.networking.k8s.io/v1         true         Gateway
   grpcroutes                         gateway.networking.k8s.io/v1         true         GRPCRoute
   httproutes                         gateway.networking.k8s.io/v1         true         HTTPRoute
   referencegrants       refgrant     gateway.networking.k8s.io/v1beta1    true         ReferenceGrant
   tcproutes                          gateway.networking.k8s.io/v1alpha2   true         TCPRoute
   tlsroutes                          gateway.networking.k8s.io/v1alpha2   true         TLSRoute
   udproutes                          gateway.networking.k8s.io/v1alpha2   true         UDPRoute
   ```

   Write down the `APIVERSION` shown for `tlsroutes` and `backendtlspolicies`. Exercises 7 and 8 need them. If either resource is missing, install the Gateway API **experimental** channel bundle from https://github.com/kubernetes-sigs/gateway-api/releases.

4. Create the GatewayClass, the namespace and a plaintext backend:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: eg
   spec:
     controllerName: gateway.envoyproxy.io/gatewayclass-controller
   ---
   apiVersion: v1
   kind: Namespace
   metadata:
     name: demo
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: app
     namespace: demo
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: app
     template:
       metadata:
         labels:
           app: app
       spec:
         containers:
         - name: netexec
           image: registry.k8s.io/e2e-test-images/agnhost:2.53
           args: ["netexec", "--http-port=8080"]
           ports:
           - containerPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: app
     namespace: demo
   spec:
     selector:
       app: app
     ports:
     - name: http
       port: 80
       targetPort: 8080
   ```

   ```bash
   kubectl apply -f 00-base.yaml
   kubectl get gatewayclass eg
   ```

   Expected output:

   ```
   NAME   CONTROLLER                                      ACCEPTED   AGE
   eg     gateway.envoyproxy.io/gatewayclass-controller   True       10s
   ```

### Questions

- **Q0.1** Why does the exercise check the `APIVERSION` of `tlsroutes` and `backendtlspolicies` before writing manifests, instead of copying a version from a blog post?
- **Q0.2** What does `ACCEPTED=True` on a GatewayClass prove, and what does it not prove?

---

## Exercise 1 — Build a private CA and a server certificate

### Steps

1. Create a lab CA and a leaf certificate with a proper **Subject Alternative Name**:

   ```bash
   mkdir -p ~/ckne-tls && cd ~/ckne-tls

   # Lab CA
   openssl req -x509 -new -nodes -newkey rsa:2048 -sha256 -days 365 \
     -keyout ca.key -out ca.crt -subj "/CN=CKNE Lab CA"

   # Leaf for app.example.test
   openssl req -new -nodes -newkey rsa:2048 \
     -keyout app.key -out app.csr -subj "/CN=app.example.test"

   openssl x509 -req -in app.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out app.crt -days 90 -sha256 \
     -extfile <(printf "subjectAltName=DNS:app.example.test\nextendedKeyUsage=serverAuth\n")
   ```

2. Inspect the leaf certificate:

   ```bash
   openssl x509 -in app.crt -noout -subject -issuer -serial -enddate -ext subjectAltName
   ```

   Expected output (serial and dates will differ):

   ```
   subject=CN=app.example.test
   issuer=CN=CKNE Lab CA
   serial=3B1F...E2
   notAfter=Dec 29 10:00:00 2026 GMT
   X509v3 Subject Alternative Name:
       DNS:app.example.test
   ```

3. Check that the key and the certificate belong together by comparing their public keys:

   ```bash
   diff <(openssl x509 -in app.crt -noout -pubkey) <(openssl pkey -in app.key -pubout) \
     && echo "key matches cert"
   ```

4. Store the pair as a TLS Secret and inspect it:

   ```bash
   kubectl -n demo create secret tls app-tls --cert=app.crt --key=app.key
   kubectl -n demo get secret app-tls -o jsonpath='{.type}{"\n"}{.data}' | cut -c1-120
   ```

   Expected output:

   ```
   kubernetes.io/tls
   {"tls.crt":"LS0tLS1CRUdJTi...","tls.key":"LS0tLS1CRUdJTi...
   ```

### Questions

- **Q1.1** Modern TLS clients ignore the certificate's `CN` when checking the hostname. Which field do they check, and what would `curl` report if you left it out?
- **Q1.2** Which two data keys must a `kubernetes.io/tls` Secret contain? What does the API server check when you create one, and what does it leave unchecked?
- **Q1.3** If the server needs an intermediate CA, in what order must `tls.crt` contain the certificates?

---

## Exercise 2 — HTTPS listener with TLS termination

### Steps

1. Create a Gateway with an HTTP listener and an HTTPS listener:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: web
     namespace: demo
   spec:
     gatewayClassName: eg
     listeners:
     - name: http
       protocol: HTTP
       port: 80
       hostname: app.example.test
     - name: https-app
       protocol: HTTPS
       port: 443
       hostname: app.example.test
       tls:
         mode: Terminate
         certificateRefs:
         - group: ""
           kind: Secret
           name: app-tls
       allowedRoutes:
         namespaces:
           from: Same
   ```

2. Attach one HTTPRoute to the HTTPS listener, and a redirect route to the HTTP listener:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: app
     namespace: demo
   spec:
     parentRefs:
     - name: web
       sectionName: https-app
     hostnames:
     - app.example.test
     rules:
     - backendRefs:
       - name: app
         port: 80
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: app-redirect
     namespace: demo
   spec:
     parentRefs:
     - name: web
       sectionName: http
     hostnames:
     - app.example.test
     rules:
     - filters:
       - type: RequestRedirect
         requestRedirect:
           scheme: https
           statusCode: 301
   ```

   ```bash
   kubectl apply -f 02-gateway.yaml -f 02-routes.yaml
   kubectl -n demo wait gateway/web --for=condition=Programmed --timeout=2m
   ```

3. Read the status of each listener. Keep this command at hand, because every later exercise uses it:

   ```bash
   kubectl -n demo get gateway web -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
   ```

   Expected output:

   ```
   http        Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
   https-app   Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
   ```

4. Reach the data plane. On kind, port-forward the Service that Envoy Gateway created for this Gateway:

   ```bash
   export ENVOY_SVC=$(kubectl -n envoy-gateway-system get svc \
     -l gateway.envoyproxy.io/owning-gateway-namespace=demo,gateway.envoyproxy.io/owning-gateway-name=web \
     -o jsonpath='{.items[0].metadata.name}')
   kubectl -n envoy-gateway-system port-forward "svc/${ENVOY_SVC}" 8080:80 8443:443 >/dev/null 2>&1 &
   ```

5. Test the HTTPS listener, the redirect and the handshake:

   ```bash
   curl -sS --cacert ca.crt --resolve app.example.test:8443:127.0.0.1 \
     https://app.example.test:8443/hostname; echo

   curl -sI --resolve app.example.test:8080:127.0.0.1 http://app.example.test:8080/ | head -3

   openssl s_client -connect 127.0.0.1:8443 -servername app.example.test \
     -CAfile ca.crt </dev/null 2>/dev/null | grep -E 'subject=|issuer=|Verify return code'
   ```

   Expected output:

   ```
   app-6d9f7c8b5-x2kqp
   HTTP/1.1 301 Moved Permanently
   location: https://app.example.test/
   date: ...
   subject=CN=app.example.test
   issuer=CN=CKNE Lab CA
   Verify return code: 0 (ok)
   ```

   The `location` header drops `:8080`. The redirect uses the default port for `https`, which is correct in production. Behind a port-forward, it means you have to add the port back by hand when you follow the redirect.

### Questions

- **Q2.1** Why does the application HTTPRoute use `sectionName: https-app`? What would happen without it?
- **Q2.2** Run `openssl s_client` again with `-servername other.example.test`. What do you expect: a different certificate, or a failed handshake? Why?
- **Q2.3** What happens to TLS between the Gateway and `app` Pods in this setup?

---

## Exercise 3 — Break the certificate reference and read the status

### Steps

1. Point the listener at a Secret that does not exist:

   ```bash
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs/0/name","value":"does-not-exist"}]'
   ```

2. Read the listener conditions:

   ```bash
   kubectl -n demo get gateway web -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
   ```

   Expected output (the exact `Programmed` reason varies by implementation):

   ```
   http        Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
   https-app   Accepted=True(Accepted) Programmed=False(Invalid) ResolvedRefs=False(InvalidCertificateRef)
   ```

3. Read the full message, then test the endpoint:

   ```bash
   kubectl -n demo get gateway web \
     -o jsonpath='{.status.listeners[?(@.name=="https-app")].conditions[?(@.type=="ResolvedRefs")].message}'; echo
   curl -sS --cacert ca.crt --resolve app.example.test:8443:127.0.0.1 https://app.example.test:8443/ ; echo "exit=$?"
   ```

4. Now create a Secret with the right name but the wrong type, and point the listener at it:

   ```bash
   kubectl -n demo create secret generic opaque-tls --from-file=tls.crt=app.crt --from-file=tls.key=app.key
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs/0/name","value":"opaque-tls"}]'
   ```

   Read the listener conditions again.

5. Restore the working Secret:

   ```bash
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs/0/name","value":"app-tls"}]'
   ```

### Questions

- **Q3.1** Which condition and reason tell you that the certificate reference is the problem? At what level of the status do they appear?
- **Q3.2** Did the broken HTTPS listener take down the `http` listener? What does that tell you about the scope of a certificate error?
- **Q3.3** What result did step 4 give, and why is an `Opaque` Secret rejected even though it has the same keys?

---

## Exercise 4 — Multiple certificates selected by SNI

### Steps

1. Issue a wildcard certificate:

   ```bash
   openssl req -new -nodes -newkey rsa:2048 -keyout wild.key -out wild.csr -subj "/CN=*.example.test"
   openssl x509 -req -in wild.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out wild.crt -days 90 -sha256 \
     -extfile <(printf "subjectAltName=DNS:*.example.test\nextendedKeyUsage=serverAuth\n")
   kubectl -n demo create secret tls wildcard-tls --cert=wild.crt --key=wild.key
   ```

2. Add a wildcard HTTPS listener on the same port. Note the quotes around the wildcard:

   ```bash
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"add","path":"/spec/listeners/-","value":{
       "name":"https-wildcard","protocol":"HTTPS","port":443,"hostname":"*.example.test",
       "tls":{"mode":"Terminate","certificateRefs":[{"group":"","kind":"Secret","name":"wildcard-tls"}]}}}]'
   ```

   The same listener, as YAML:

   ```yaml
   - name: https-wildcard
     protocol: HTTPS
     port: 443
     hostname: "*.example.test"
     tls:
       mode: Terminate
       certificateRefs:
       - group: ""
         kind: Secret
         name: wildcard-tls
   ```

3. Attach a route for `api.example.test`:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: api
     namespace: demo
   spec:
     parentRefs:
     - name: web
       sectionName: https-wildcard
     hostnames:
     - api.example.test
     rules:
     - backendRefs:
       - name: app
         port: 80
   ```

4. Compare the certificate served for each SNI name:

   ```bash
   for h in app.example.test api.example.test; do
     echo "== $h"
     openssl s_client -connect 127.0.0.1:8443 -servername "$h" -CAfile ca.crt </dev/null 2>/dev/null \
       | openssl x509 -noout -subject
   done
   ```

   Expected output:

   ```
   == app.example.test
   subject=CN=app.example.test
   == api.example.test
   subject=CN=*.example.test
   ```

### Questions

- **Q4.1** `app.example.test` matches both listeners. Which one wins, and under which rule?
- **Q4.2** Why must `"*.example.test"` be quoted in YAML?
- **Q4.3** Does a certificate for `*.example.test` cover `v1.api.example.test`? Does it cover `example.test`?
- **Q4.4** A listener's `certificateRefs` is a list. When would you put more than one certificate in it?

---

## Exercise 5 — Certificates in another namespace: ReferenceGrant

### Steps

1. Move the wildcard certificate into a dedicated namespace, as a platform team would:

   ```bash
   kubectl create namespace certs
   kubectl -n certs create secret tls wildcard-tls --cert=wild.crt --key=wild.key
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"add","path":"/spec/listeners/2/tls/certificateRefs/0/namespace","value":"certs"}]'
   ```

2. Check the listener status:

   ```bash
   kubectl -n demo get gateway web -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
   ```

   Expected output:

   ```
   http             Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
   https-app        Accepted=True(Accepted) Programmed=True(Programmed) ResolvedRefs=True(ResolvedRefs)
   https-wildcard   Accepted=True(Accepted) Programmed=False(Invalid) ResolvedRefs=False(RefNotPermitted)
   ```

3. Grant the reference **in the namespace that owns the Secret**:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: ReferenceGrant
   metadata:
     name: allow-demo-gateways
     namespace: certs
   spec:
     from:
     - group: gateway.networking.k8s.io
       kind: Gateway
       namespace: demo
     to:
     - group: ""
       kind: Secret
       name: wildcard-tls
   ```

   ```bash
   kubectl apply -f 05-refgrant.yaml
   ```

   Check the listener status again. `https-wildcard` should now show `ResolvedRefs=True`.

4. Test the scope of the grant. Create a second Secret in `certs`, point the listener at it, and read the status:

   ```bash
   kubectl -n certs create secret tls other-tls --cert=wild.crt --key=wild.key
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"replace","path":"/spec/listeners/2/tls/certificateRefs/0/name","value":"other-tls"}]'
   ```

   Then set the name back to `wildcard-tls`.

### Questions

- **Q5.1** Why does the ReferenceGrant live in `certs` and not in `demo`?
- **Q5.2** What was the result of step 4, and why?
- **Q5.3** In the ReferenceGrant, `from.kind` is `Gateway`, not `HTTPRoute`. Why?
- **Q5.4** Name one security benefit of keeping certificates in their own namespace.

---

## Exercise 6 — Rotating a certificate without downtime

### Steps

1. Record the serial number currently served:

   ```bash
   openssl s_client -connect 127.0.0.1:8443 -servername app.example.test </dev/null 2>/dev/null \
     | openssl x509 -noout -serial -enddate
   ```

2. Start continuous traffic in a second terminal:

   ```bash
   while true; do
     curl -s -o /dev/null -w '%{http_code}\n' --cacert ~/ckne-tls/ca.crt \
       --resolve app.example.test:8443:127.0.0.1 https://app.example.test:8443/hostname
     sleep 0.2
   done | uniq -c
   ```

3. Reissue the certificate and replace the Secret in place:

   ```bash
   openssl x509 -req -in app.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out app-v2.crt -days 90 -sha256 \
     -extfile <(printf "subjectAltName=DNS:app.example.test\nextendedKeyUsage=serverAuth\n")

   kubectl -n demo create secret tls app-tls --cert=app-v2.crt --key=app.key \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

4. After a few seconds, repeat step 1. The serial number must be different. Look at the traffic loop too: it should only have printed `200`.

### Questions

- **Q6.1** Why is `create --dry-run=client -o yaml | kubectl apply -f -` better here than `delete` followed by `create`?
- **Q6.2** How does the new certificate reach Envoy without a Pod restart?
- **Q6.3** Connections that already existed keep the old certificate. Why is that not a security problem during a normal rotation?

---

## Exercise 7 — Automating with cert-manager

### Steps

1. Install cert-manager with Gateway API support turned on:

   ```bash
   helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
     -n cert-manager --create-namespace \
     --set crds.enabled=true \
     --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
     --set config.kind=ControllerConfiguration \
     --set config.enableGatewayAPI=true
   kubectl -n cert-manager rollout status deploy/cert-manager
   ```

2. Create a CA ClusterIssuer backed by the lab CA:

   ```bash
   kubectl -n cert-manager create secret tls lab-ca --cert=ca.crt --key=ca.key
   ```

   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: lab-ca
   spec:
     ca:
       secretName: lab-ca
   ```

   ```bash
   kubectl apply -f 07-issuer.yaml
   kubectl get clusterissuer lab-ca
   ```

   Expected output:

   ```
   NAME     READY   AGE
   lab-ca   True    5s
   ```

3. Create a second Gateway, annotated so that cert-manager manages its certificates. The Secret `shop-tls` does not exist yet:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: shop
     namespace: demo
     annotations:
       cert-manager.io/cluster-issuer: lab-ca
       cert-manager.io/duration: 2160h
       cert-manager.io/renew-before: 360h
   spec:
     gatewayClassName: eg
     listeners:
     - name: https-shop
       protocol: HTTPS
       port: 443
       hostname: shop.example.test
       tls:
         mode: Terminate
         certificateRefs:
         - group: ""
           kind: Secret
           name: shop-tls
   ```

4. Watch cert-manager create the objects:

   ```bash
   kubectl apply -f 07-shop-gateway.yaml
   kubectl -n demo get certificate,certificaterequest
   kubectl -n demo get certificate shop-tls -o jsonpath='{.spec.dnsNames}{"\n"}{.spec.issuerRef}{"\n"}'
   ```

   Expected output:

   ```
   NAME                                   READY   SECRET     AGE
   certificate.cert-manager.io/shop-tls   True    shop-tls   8s

   NAME                                            APPROVED   DENIED   READY   ISSUER   REQUESTER                                         AGE
   certificaterequest.cert-manager.io/shop-tls-1   True                True    lab-ca   system:serviceaccount:cert-manager:cert-manager   8s

   ["shop.example.test"]
   {"group":"cert-manager.io","kind":"ClusterIssuer","name":"lab-ca"}
   ```

5. Check who owns the Certificate, then force a renewal (requires the `cmctl` binary):

   ```bash
   kubectl -n demo get certificate shop-tls -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
   cmctl renew shop-tls -n demo
   kubectl -n demo get certificaterequest
   ```

   Expected output of the first command:

   ```
   Gateway/shop
   ```

6. Edit the Certificate by hand, for example add a DNS name, and wait a few seconds. Then check `spec.dnsNames` again.

### Questions

- **Q7.1** Which fields of a listener does cert-manager's gateway-shim need to create a Certificate? Which listeners does it skip?
- **Q7.2** You install the Gateway API CRDs **after** cert-manager. The annotation does nothing. Why, and how do you fix it?
- **Q7.3** What happened to your manual edit in step 6? Where must the change be made instead?
- **Q7.4** For a public ACME issuer that uses HTTP-01, which solver type do you configure so the challenge is served through the Gateway, not an Ingress?

---

## Exercise 8 — TLS passthrough with TLSRoute

### Steps

1. Issue a certificate that the backend will serve itself. It includes the in-cluster DNS name, which Exercise 9 needs:

   ```bash
   openssl req -new -nodes -newkey rsa:2048 -keyout be.key -out be.csr -subj "/CN=secure-backend"
   openssl x509 -req -in be.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out be.crt -days 90 -sha256 \
     -extfile <(printf "subjectAltName=DNS:passthrough.example.test,DNS:secure-backend.demo.svc.cluster.local\nextendedKeyUsage=serverAuth\n")
   kubectl -n demo create secret tls backend-tls --cert=be.crt --key=be.key
   ```

2. Deploy an nginx backend that terminates TLS itself:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: secure-backend-conf
     namespace: demo
   data:
     default.conf: |
       server {
         listen 8443 ssl;
         ssl_certificate     /etc/tls/tls.crt;
         ssl_certificate_key /etc/tls/tls.key;
         location / {
           default_type text/plain;
           return 200 "served by secure-backend over TLS\n";
         }
       }
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: secure-backend
     namespace: demo
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: secure-backend
     template:
       metadata:
         labels:
           app: secure-backend
       spec:
         containers:
         - name: nginx
           image: nginx:1.27
           ports:
           - containerPort: 8443
           volumeMounts:
           - name: conf
             mountPath: /etc/nginx/conf.d
           - name: tls
             mountPath: /etc/tls
             readOnly: true
         volumes:
         - name: conf
           configMap:
             name: secure-backend-conf
         - name: tls
           secret:
             secretName: backend-tls
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: secure-backend
     namespace: demo
   spec:
     selector:
       app: secure-backend
     ports:
     - name: https
       port: 443
       targetPort: 8443
   ```

3. Add a passthrough listener on its own port to the `web` Gateway:

   ```yaml
   - name: tls-passthrough
     protocol: TLS
     port: 8443
     hostname: passthrough.example.test
     tls:
       mode: Passthrough
     allowedRoutes:
       kinds:
       - kind: TLSRoute
   ```

   ```bash
   kubectl -n demo patch gateway web --type=json -p='[
     {"op":"add","path":"/spec/listeners/-","value":{
       "name":"tls-passthrough","protocol":"TLS","port":8443,"hostname":"passthrough.example.test",
       "tls":{"mode":"Passthrough"},"allowedRoutes":{"kinds":[{"kind":"TLSRoute"}]}}}]'
   ```

4. Create the TLSRoute. Use the `apiVersion` you recorded in Exercise 0:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1alpha2
   kind: TLSRoute
   metadata:
     name: passthrough
     namespace: demo
   spec:
     parentRefs:
     - name: web
       sectionName: tls-passthrough
     hostnames:
     - passthrough.example.test
     rules:
     - backendRefs:
       - name: secure-backend
         port: 443
   ```

5. Restart the port-forward so it includes the new port, then test:

   ```bash
   kill %1 2>/dev/null
   kubectl -n envoy-gateway-system port-forward "svc/${ENVOY_SVC}" 8080:80 8443:443 9443:8443 >/dev/null 2>&1 &
   curl -sS --cacert ca.crt --resolve passthrough.example.test:9443:127.0.0.1 \
     https://passthrough.example.test:9443/
   openssl s_client -connect 127.0.0.1:9443 -servername passthrough.example.test </dev/null 2>/dev/null \
     | openssl x509 -noout -subject
   ```

   Expected output:

   ```
   served by secure-backend over TLS
   subject=CN=secure-backend
   ```

### Questions

- **Q8.1** Why does the passthrough listener have no `certificateRefs`? What would the API do if you added some?
- **Q8.2** Why must the route be a TLSRoute rather than an HTTPRoute? What routing information does the Gateway still have?
- **Q8.3** Name two features you give up with passthrough compared with termination.
- **Q8.4** Why does this exercise use port 8443 instead of sharing port 443 with the HTTPS listeners?

---

## Exercise 9 — Re-encrypting to the backend: BackendTLSPolicy

### Steps

1. Route plaintext HTTP to the TLS backend and watch it fail:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: secure
     namespace: demo
   spec:
     parentRefs:
     - name: web
       sectionName: https-wildcard
     hostnames:
     - secure.example.test
     rules:
     - backendRefs:
       - name: secure-backend
         port: 443
   ```

   ```bash
   kubectl apply -f 09-route.yaml
   curl -sS -o /dev/null -w '%{http_code}\n' --cacert ca.crt \
     --resolve secure.example.test:8443:127.0.0.1 https://secure.example.test:8443/
   ```

   You should see a 400 from nginx ("plain HTTP request was sent to HTTPS port") or a 5xx from the proxy.

2. Publish the CA the Gateway should trust for this backend:

   ```bash
   kubectl -n demo create configmap backend-ca --from-file=ca.crt=ca.crt
   ```

3. Create the policy. Use the `apiVersion` you recorded in Exercise 0; `v1` is shown here:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: BackendTLSPolicy
   metadata:
     name: secure-backend-tls
     namespace: demo
   spec:
     targetRefs:
     - group: ""
       kind: Service
       name: secure-backend
     validation:
       caCertificateRefs:
       - group: ""
         kind: ConfigMap
         name: backend-ca
       hostname: secure-backend.demo.svc.cluster.local
   ```

   ```bash
   kubectl apply -f 09-btls.yaml
   kubectl -n demo get backendtlspolicy secure-backend-tls \
     -o jsonpath='{range .status.ancestors[*]}{.ancestorRef.name}{": "}{range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
   curl -sS --cacert ca.crt --resolve secure.example.test:8443:127.0.0.1 https://secure.example.test:8443/
   ```

   Expected output:

   ```
   web: Accepted=True ResolvedRefs=True
   served by secure-backend over TLS
   ```

4. Break the validation. Set `hostname` to `wrong.demo.svc.cluster.local`, apply, and repeat the curl. Then restore the correct value.

### Questions

- **Q9.1** What is `validation.hostname` used for? Name two separate effects.
- **Q9.2** What was the result of step 4, and what exactly did the Gateway reject?
- **Q9.3** Why does BackendTLSPolicy attach to the **Service** and not to the HTTPRoute?
- **Q9.4** What does `wellKnownCACertificates: System` do? Can it be combined with `caCertificateRefs`?

---

## Exercise 10 — Troubleshooting drill

### Steps

Each scenario below is a symptom. Before you check the answers, write down which command you would run first and what you expect it to show.

1. `curl: (60) SSL certificate problem: unable to get local issuer certificate`, while the listener shows `ResolvedRefs=True`.
2. `curl: (60) SSL: no alternative certificate subject name matches target host name 'app.example.test'`.
3. The listener shows `ResolvedRefs=False(RefNotPermitted)`.
4. cert-manager shows no Certificate for a listener with the `cert-manager.io/cluster-issuer` annotation. The listener has `hostname: "*.example.test"` and `tls.mode: Passthrough`.
5. Browsers report "certificate expired" even though the Certificate object shows `READY=True` and a future `notAfter`.

Useful commands:

```bash
kubectl -n demo describe gateway web
kubectl -n demo get certificate -o wide
kubectl -n demo describe certificate <name>
kubectl -n demo get secret <name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -enddate -ext subjectAltName
openssl s_client -connect <addr>:<port> -servername <host> -showcerts </dev/null
kubectl -n envoy-gateway-system logs deploy/envoy-gateway | grep -i -E 'secret|tls|certificate'
```

### Questions

- **Q10.1–Q10.5** For each scenario, give the most likely cause and the fix.

---

## Answers

<details>
<summary>Exercise 0</summary>

- **Q0.1** Gateway API has two release channels (standard and experimental), and resources graduate between versions. For example, BackendTLSPolicy moved from `v1alpha3` to `v1`, and TLSRoute has lived in `v1alpha2`. A manifest with an `apiVersion` the cluster does not serve fails with `no matches for kind`. The cluster itself is the only reliable source.
- **Q0.2** It proves that a controller has claimed the class and accepts its parameters. It says nothing about any Gateway working. Listener errors, certificates included, show up on each **Gateway**, per listener.

</details>

<details>
<summary>Exercise 1</summary>

- **Q1.1** The `subjectAltName` extension, with `DNS:` entries (RFC 6125; browsers stopped using CN long ago). Without it, curl fails with `SSL: no alternative certificate subject name matches target host name`.
- **Q1.2** `tls.crt` and `tls.key`. The API server only checks that both keys are present. It does not check that they are valid PEM, that the key matches the certificate, or when the certificate expires. The Gateway controller finds those problems later, or the client finds them during the handshake. That is why step 3 checks the pair before uploading it.
- **Q1.3** Leaf first, then each intermediate up the chain. The root is optional and usually left out. If the intermediates are missing, some clients fail with "unable to get local issuer certificate".

</details>

<details>
<summary>Exercise 2</summary>

- **Q2.1** Without `sectionName`, the route attaches to **every** listener whose hostname and allowed routes match, including the plaintext `http` listener. The application would then also be served over HTTP, with no redirect. `sectionName` pins the route to the TLS listener only.
- **Q2.2** Both listeners have `hostname: app.example.test`, so no listener matches `other.example.test`. With Envoy Gateway, the handshake typically fails because no filter chain matches (`alert handshake failure` or the connection is reset). No certificate for another name is served. Some implementations serve a default certificate instead. Either way, `other.example.test` never reaches your route.
- **Q2.3** `mode: Terminate` decrypts at the Gateway, and the traffic continues to `app` as plaintext HTTP. Encrypting that hop needs BackendTLSPolicy (Exercise 9) or a mesh.

</details>

<details>
<summary>Exercise 3</summary>

- **Q3.1** `ResolvedRefs=False` with reason `InvalidCertificateRef`, in `status.listeners[].conditions`. It is reported per listener, not in the Gateway's top-level conditions.
- **Q3.2** No. `http` stays `Programmed=True`. A certificate error invalidates only the listener that refers to it. However, the curl to 8443 fails, because no valid HTTPS listener handles that host.
- **Q3.3** `ResolvedRefs=False(InvalidCertificateRef)`. The spec says a referenced Secret must be of type `kubernetes.io/tls`. The type is the contract that guarantees the keys and their meaning; having keys with the right names is not enough.

</details>

<details>
<summary>Exercise 4</summary>

- **Q4.1** The `https-app` listener wins. When several listeners on the same port match, the most specific hostname wins, and an exact match beats a wildcard. So `app.example.test` gets its dedicated certificate, and every other `*.example.test` name gets the wildcard.
- **Q4.2** In YAML, a value that starts with `*` is read as an alias reference (`*anchor`). Without quotes, the document fails to parse or means something else.
- **Q4.3** No, in both cases. A wildcard covers exactly one DNS label. It does not cover `v1.api.example.test` (two labels) or the apex `example.test`, which needs its own SAN.
- **Q4.4** To serve different key types for the same hostname, for example ECDSA and RSA, so that the implementation picks the one the client supports. Support for more than one certificate is implementation-specific. Check the conformance report before relying on it.

</details>

<details>
<summary>Exercise 5</summary>

- **Q5.1** A grant has to be given by the owner of the resource. If the namespace that makes the reference could authorize itself, any tenant could take any certificate from any namespace. Only someone who can write to `certs` can allow the reference.
- **Q5.2** `ResolvedRefs=False(RefNotPermitted)`. The grant has `to.name: wildcard-tls`, so it covers only that Secret. Leaving out `name` would allow every Secret in `certs`, which is broader than you usually want.
- **Q5.3** The object that references the Secret is the **Gateway**, through `listeners[].tls.certificateRefs`. Routes never reference certificates. A ReferenceGrant describes the object that makes the reference, not the traffic.
- **Q5.4** Application teams get RBAC on `demo` without read access to the private keys. The keys stay in a namespace that only the platform team or cert-manager can read, which limits the blast radius if an application namespace is compromised.

</details>

<details>
<summary>Exercise 6</summary>

- **Q6.1** `apply` updates the existing object atomically. `delete` + `create` leaves a window in which the Secret does not exist. During that window the listener becomes `ResolvedRefs=False`, and the controller may remove its configuration, so traffic fails.
- **Q6.2** The Envoy Gateway controller watches the Secrets that listeners reference. When one changes, it recomputes the configuration and pushes it to the Envoy proxies over xDS (the SDS/LDS resources). Envoy swaps the certificate in memory. New handshakes use it, and nothing restarts.
- **Q6.3** Those connections were already authenticated with a certificate that was still valid. Rotation replaces a certificate before it expires, not because it was compromised. If the key **was** compromised, you also need to revoke the certificate, rotate the key (not just the certificate), and drain existing connections, for example by restarting the proxies.

</details>

<details>
<summary>Exercise 7</summary>

- **Q7.1** A `hostname`, which becomes the `dnsNames`; `tls.mode` set to `Terminate` or unset; and a `certificateRefs` entry naming a Secret in the Gateway's namespace, which becomes the Certificate name and `secretName`. It skips `Passthrough` listeners, listeners without a hostname, and references to other namespaces.
- **Q7.2** cert-manager checks for the Gateway API CRDs at startup. If they are not there yet, it never starts the gateway-shim controller. Restart it with `kubectl -n cert-manager rollout restart deploy/cert-manager`, and check that `config.enableGatewayAPI=true` is set (older releases used the `ExperimentalGatewayAPISupport` feature gate instead).
- **Q7.3** It was reverted. The Certificate is owned by the Gateway, and the shim reconciles it from the listener and the annotations. Change the listener `hostname` or the `cert-manager.io/*` annotations on the Gateway. If you need full control, create the Certificate yourself and remove the annotation.
- **Q7.4** An ACME `http01` solver of type `gatewayHTTPRoute`, with `parentRefs` pointing at a Gateway that has an HTTP listener on port 80. cert-manager then creates a temporary HTTPRoute for `/.well-known/acme-challenge/...`.

</details>

<details>
<summary>Exercise 8</summary>

- **Q8.1** In `Passthrough` mode the Gateway never decrypts, so it has no use for a certificate. Validation rejects a passthrough listener that sets `certificateRefs` (a CEL rule on the CRD).
- **Q8.2** The HTTP layer is encrypted end to end, so the Gateway cannot see paths, headers or methods. It can only route on the **SNI** in the ClientHello, which is what TLSRoute `hostnames` match.
- **Q8.3** Any two of: routing by path or header, header rewriting, redirects, HTTP-level auth or rate limits at the Gateway, HTTP metrics and access logs with URL and status, and central certificate management. Each backend has to manage its own certificate.
- **Q8.4** Listeners that share a port must use compatible protocols. Mixing `HTTPS` (terminate) and `TLS` (passthrough) on one port is not supported everywhere. A separate port is portable. When an implementation does support sharing, SNI decides which listener handles the connection.

</details>

<details>
<summary>Exercise 9</summary>

- **Q9.1** (1) It is sent as the **SNI** in the Gateway's connection to the backend. (2) It is the name checked against the backend certificate's SAN. The backend certificate includes `secure-backend.demo.svc.cluster.local` for this reason.
- **Q9.2** The upstream handshake failed the hostname check. The CA is trusted, but no SAN matches `wrong.demo.svc.cluster.local`. The client receives a 503 (`upstream connect error ... TLS error ... CERTIFICATE_VERIFY_FAILED`). The frontend TLS between curl and the Gateway still works.
- **Q9.3** The way a backend expects to be reached (TLS, which CA, which name) belongs to the backend. Attaching the policy to the Service means every route that sends traffic to it inherits the same behavior. The Service owner makes the decision once, instead of every route author repeating it.
- **Q9.4** It trusts the proxy's system root CAs, which suits backends with publicly issued certificates. The spec says exactly one of `caCertificateRefs` and `wellKnownCACertificates` must be set, so they cannot be combined.

</details>

<details>
<summary>Exercise 10</summary>

- **Q10.1** The Secret has a leaf without its intermediates, or the client does not trust the private CA. Check with `openssl s_client -showcerts`. Fix it by putting the full chain in `tls.crt`, or by distributing the CA to clients.
- **Q10.2** The certificate's SAN does not cover the requested name, or the client reached a different listener (for example the wildcard one) because of SNI. Compare the Secret's `-ext subjectAltName` with the listener hostnames, and reissue with the right SAN.
- **Q10.3** The listener references a Secret in another namespace without a matching ReferenceGrant. Create one in the **Secret's** namespace, with `from.kind: Gateway` and the Gateway's namespace, and a `to.name` that matches.
- **Q10.4** The gateway-shim skips `Passthrough` listeners because the Gateway does not terminate TLS there. Either switch to `Terminate`, or issue the certificate for the backend with a separate `Certificate` object that the backend mounts. The wildcard hostname is not the blocker: the shim creates Certificates for wildcard hostnames. With ACME, though, a wildcard needs DNS-01, not HTTP-01.
- **Q10.5** The Secret was renewed, but whatever serves it did not pick up the change. Possible causes: a passthrough backend that reads the file only at startup, a listener pointing at a different Secret than the Certificate writes, or a `ResolvedRefs=False` listener that keeps its old configuration. Compare the serial from `openssl s_client` with the serial in the Secret, then fix the reference or reload the backend.

</details>