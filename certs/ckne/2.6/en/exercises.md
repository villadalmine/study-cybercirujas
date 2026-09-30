# Guided Exercises — Topic 2.6: Managing Traffic with the Gateway API (Gateway, HTTPRoutes)

> **Exam weight:** 4.17%. **Certification:** CKNE.
>
> **Official references:**
> - CKNE program page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
> - Gateway API overview: https://gateway-api.sigs.k8s.io/
> - Gateway API reference: https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/
> - HTTPRoute: https://gateway-api.sigs.k8s.io/reference/api-types/httproute/
> - Gateway: https://gateway-api.sigs.k8s.io/reference/api-types/gateway/
> - ReferenceGrant: https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/
> - Traffic splitting guide: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/
> - Redirects and rewrites guide: https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/
> - TLS guide: https://gateway-api.sigs.k8s.io/guides/tls/
> - Cross-namespace routing guide: https://gateway-api.sigs.k8s.io/guides/multiple-ns/
> - Envoy Gateway quickstart: https://gateway.envoyproxy.io/docs/tasks/quickstart/

## What you will build

```
                        namespace: infra
 curl ──► port-forward ──► Gateway "web" (GatewayClass "eg", Envoy Gateway)
                           ├── listener "http"  :80   *.example.com
                           └── listener "https" :443  *.example.com (TLS Terminate)
                                   │
         ┌─────────────────────────┼──────────────────────────────┐
         ▼                         ▼                              ▼
  namespace: shop           namespace: payments            namespace: untrusted
  HTTPRoutes + store-v1/v2  Service billing (target        HTTPRoute (must be
                            of a ReferenceGrant)            rejected)
```

You need `kind`, `kubectl`, `helm`, `curl`, `jq` and `openssl` on your workstation. Every exercise builds on the previous one, so do them in order.

---

## Exercise 1: Install the Gateway API and a controller

### Step 1.1: Create the cluster

```bash
kind create cluster --name ckne-gw
kubectl cluster-info --context kind-ckne-gw
```

### Step 1.2: Install Envoy Gateway

The Envoy Gateway Helm chart ships the Gateway API CRDs from the **standard channel**, as well as its own CRDs. Look up the current release at https://gateway.envoyproxy.io/news/releases/ and adjust the version if needed.

```bash
export EG_VERSION=v1.4.0
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${EG_VERSION}" \
  -n envoy-gateway-system --create-namespace

kubectl wait --timeout=5m -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available
```

### Step 1.3: Look at the installed API

```bash
kubectl get crd | grep gateway.networking.k8s.io
kubectl api-resources --api-group=gateway.networking.k8s.io
```

Expected output (the list can vary between versions):

```
backendtlspolicies.gateway.networking.k8s.io   ...
gatewayclasses.gateway.networking.k8s.io       ...
gateways.gateway.networking.k8s.io             ...
grpcroutes.gateway.networking.k8s.io           ...
httproutes.gateway.networking.k8s.io           ...
referencegrants.gateway.networking.k8s.io      ...
```

```bash
kubectl get crd httproutes.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}{.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
```

**Questions:**

- **Q1.1** What does the `channel` annotation mean, and what practical difference is there between `standard` and `experimental`?
- **Q1.2** Why doesn't the Gateway API come preinstalled with Kubernetes the way `Ingress` does?

### Step 1.4: Create a GatewayClass with parameters

On a kind cluster no `LoadBalancer` implementation assigns external IPs. Without one, the proxy Service would stay `<pending>` and the Gateway would never become `Programmed`. You fix that with an implementation-specific resource that the GatewayClass references through `parametersRef`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: clusterip-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: clusterip-proxy
    namespace: envoy-gateway-system
```

```bash
kubectl apply -f gatewayclass.yaml
kubectl get gatewayclass eg
```

```
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       10s
```

**Questions:**

- **Q1.3** Which controller decides whether to accept this GatewayClass, and how does it recognize the ones that belong to it?
- **Q1.4** Why is `parametersRef` a reference to a separate CRD, rather than a set of fields inside `GatewayClass`?

---

## Exercise 2: Deploy the Gateway and the backends

### Step 2.1: Namespaces

```bash
kubectl create namespace infra
kubectl create namespace shop
kubectl create namespace payments
kubectl create namespace untrusted
kubectl label namespace shop gateway-access=true
```

### Step 2.2: The Gateway (owned by the platform team)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: infra
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.example.com"
    allowedRoutes:
      kinds:
      - kind: HTTPRoute
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: "true"
```

```bash
kubectl apply -f gateway.yaml
kubectl wait --for=condition=Programmed gateway/web -n infra --timeout=120s
kubectl get gateway web -n infra
```

```
NAME   CLASS   ADDRESS        PROGRAMMED   AGE
web    eg      10.96.45.118   True         25s
```

Inspect the listener status:

```bash
kubectl get gateway web -n infra \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{range .conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}{end}'
```

```
http: attachedRoutes=0
  Programmed=True (Programmed)
  Accepted=True (Accepted)
  ResolvedRefs=True (ResolvedRefs)
```

### Step 2.3: Find the data plane the controller created

```bash
kubectl get deploy,svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=infra,gateway.envoyproxy.io/owning-gateway-name=web
```

```
NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/envoy-infra-web-...   1/1     1            1           40s

NAME                          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/envoy-infra-web-...   ClusterIP   10.96.45.118   <none>        80/TCP    40s
```

Open a port-forward in **a second terminal** and leave it running:

```bash
export ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=infra,gateway.envoyproxy.io/owning-gateway-name=web \
  -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system "svc/${ENVOY_SERVICE}" 8888:80
```

### Step 2.4: The backends

`echo-basic` is the echo server used by the Gateway API conformance suite. It returns a JSON body that contains the path, host, headers and pod that served the request.

```bash
deploy_echo() {
  local ns=$1 name=$2
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
      - name: echo
        image: gcr.io/k8s-staging-gateway-api/echo-basic:v20231214-v1.0.0-140-gf544a46e
        ports:
        - containerPort: 3000
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: SERVICE_NAME
          value: ${name}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  selector:
    app: ${name}
  ports:
  - name: http
    port: 80
    targetPort: 3000
EOF
}

deploy_echo shop store-v1
deploy_echo shop store-v2
deploy_echo payments billing
kubectl wait --for=condition=Available deploy --all -n shop --timeout=120s
kubectl wait --for=condition=Available deploy --all -n payments --timeout=120s
```

**Questions:**

- **Q2.1** The Gateway is `Programmed=True` but `attachedRoutes=0`. What does a request to `localhost:8888` return right now, and why?
- **Q2.2** Which resource created the `envoy-infra-web-...` Deployment and Service? What happens to them if you delete the Gateway?
- **Q2.3** The listener declares `hostname: "*.example.com"`. Why are the quotes required in YAML?
- **Q2.4** Which of the three `allowedRoutes.namespaces.from` values (`Same`, `All`, `Selector`) is the default? What would change if you had left the field out?

---

## Exercise 3: Your first HTTPRoute, and match precedence

### Step 3.1: A basic route

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path:
        type: Exact
        value: /checkout
    backendRefs:
    - name: store-v2
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: store-v1
      port: 80
```

```bash
kubectl apply -f route-store.yaml
kubectl get httproute store -n shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
```

### Step 3.2: Test it

```bash
curl -s -H 'Host: shop.example.com' http://localhost:8888/ | jq '{path, host, namespace, pod}'
```

```
{
  "path": "/",
  "host": "shop.example.com",
  "namespace": "shop",
  "pod": "store-v1-6d5f8c7b9d-x2k8p"
}
```

Now run this series and note which backend answers each request:

```bash
for p in /checkout /checkout/ /checkout/pay /checkoutx /products; do
  printf '%-14s -> ' "$p"
  curl -s -H 'Host: shop.example.com' "http://localhost:8888${p}" | jq -r .pod
done

curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: shop.example.org' http://localhost:8888/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: blog.example.com' http://localhost:8888/
```

**Questions:**

- **Q3.1** Which backend served each of the five paths? Explain each case using the difference between `Exact` and `PathPrefix`.
- **Q3.2** Both rules match `/checkout`. Why does `store-v2` win, when the `PathPrefix /` rule could also take it? Does the order of the rules in the manifest matter?
- **Q3.3** Would a `PathPrefix` with value `/check` match `/checkout`?
- **Q3.4** Why does `shop.example.org` return 404, and does `blog.example.com` return the same code? At which layer is each one rejected: the listener, or the route?
- **Q3.5** Check `attachedRoutes` on the `http` listener again. What value does it show now?

---

## Exercise 4: Header matching and canary traffic splitting

### Step 4.1: A route with a header match and weights

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - canary.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
      headers:
      - type: Exact
        name: x-canary
        value: "true"
    backendRefs:
    - name: store-v2
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: store-v1
      port: 80
      weight: 90
    - name: store-v2
      port: 80
      weight: 10
```

```bash
kubectl apply -f route-canary.yaml
```

### Step 4.2: Measure the split

```bash
count() {
  for i in $(seq 1 200); do
    curl -s "$@" http://localhost:8888/ | jq -r .pod
  done | sed -E 's/-[a-z0-9]+-[a-z0-9]+$//' | sort | uniq -c
}

count -H 'Host: canary.example.com'
count -H 'Host: canary.example.com' -H 'x-canary: true'
count -H 'Host: canary.example.com' -H 'X-Canary: TRUE'
```

Expected output (approximate for the first run):

```
    181 store-v1
     19 store-v2

    200 store-v2

    181 store-v1
     19 store-v2
```

### Step 4.3: Promote the canary

Edit the second rule to `weight: 0` for `store-v1` and `weight: 100` for `store-v2`, apply it, and repeat `count -H 'Host: canary.example.com'`.

**Questions:**

- **Q4.1** Why does `x-canary: true` go 100% to v2, while `X-Canary: TRUE` falls back to the 90/10 split? Which part of the match is case-insensitive, and which part isn't?
- **Q4.2** Why does the rule with the header win, when both rules have the same `PathPrefix /`?
- **Q4.3** Are the weights percentages? What would happen with `weight: 3` and `weight: 1`?
- **Q4.4** Is the split per request or per connection? What does that mean for a user session that needs stickiness?
- **Q4.5** What is the operational difference between this canary and one done by changing replica counts in a single Service?

---

## Exercise 5: Filters, rewrite and redirect

### Step 5.1: A route with filters

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - api.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /legacy
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /v2
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: x-team
          value: shop
        remove:
        - x-debug
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: x-served-by
          value: gateway-web
    backendRefs:
    - name: store-v1
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /old-docs
    filters:
    - type: RequestRedirect
      requestRedirect:
        path:
          type: ReplaceFullPath
          replaceFullPath: /docs
        statusCode: 301
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: store-v1
      port: 80
```

```bash
kubectl apply -f route-api.yaml
```

### Step 5.2: Check the rewrite and the headers

```bash
curl -s -H 'Host: api.example.com' -H 'x-debug: 1' \
  http://localhost:8888/legacy/items | jq '{path, xteam: .headers["X-Team"], xdebug: .headers["X-Debug"]}'

curl -si -H 'Host: api.example.com' http://localhost:8888/legacy/items | grep -i '^x-served-by'
```

```
{
  "path": "/v2/items",
  "xteam": [
    "shop"
  ],
  "xdebug": null
}
x-served-by: gateway-web
```

### Step 5.3: Check the redirect

```bash
curl -si -H 'Host: api.example.com' http://localhost:8888/old-docs/install | grep -iE '^(HTTP|location)'
```

```
HTTP/1.1 301 Moved Permanently
location: http://api.example.com/docs
```

**Questions:**

- **Q5.1** What does the backend receive when the client requests `/legacy`, and `/legacy/items`? What would happen with `/legacyfoo`?
- **Q5.2** Why can't you put `URLRewrite` and `RequestRedirect` in the same rule?
- **Q5.3** The redirect rule has no `backendRefs`. Is that valid, and why?
- **Q5.4** What is the difference between `set` and `add` in a header modifier?
- **Q5.5** Why doesn't the `location` header include port 8888, even though you connected to that port?

---

## Exercise 6: Cross-namespace, allowedRoutes and ReferenceGrant

### Step 6.1: A route in a namespace the Gateway doesn't allow

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: intruder
  namespace: untrusted
spec:
  parentRefs:
  - name: web
    namespace: infra
  hostnames:
  - shop.example.com
  rules:
  - backendRefs:
    - name: store-v1
      namespace: shop
      port: 80
```

```bash
kubectl apply -f route-intruder.yaml
kubectl get httproute intruder -n untrusted \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}'
```

```
Accepted=False (NotAllowedByListeners): No listeners included by this parent ref allowed this attachment.
ResolvedRefs=False (RefNotPermitted): Backend ref to Service shop/store-v1 not permitted by any ReferenceGrant.
```

### Step 6.2: A route that points at a Service in another namespace

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: billing
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - billing.example.com
  rules:
  - backendRefs:
    - name: billing
      namespace: payments
      port: 80
```

```bash
kubectl apply -f route-billing.yaml
kubectl get httproute billing -n shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: billing.example.com' http://localhost:8888/
```

```
Accepted=True (Accepted)
ResolvedRefs=False (RefNotPermitted)
500
```

### Step 6.3: The owner of `payments` grants access

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-shop-routes
  namespace: payments
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: shop
  to:
  - group: ""
    kind: Service
    name: billing
```

```bash
kubectl apply -f referencegrant.yaml
sleep 3
kubectl get httproute billing -n shop \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
curl -s -H 'Host: billing.example.com' http://localhost:8888/ | jq -r '.namespace + "/" + .pod'
```

```
Accepted=True (Accepted)
ResolvedRefs=True (ResolvedRefs)
payments/billing-7c9d6b8f4-q7m2z
```

**Questions:**

- **Q6.1** The `intruder` route declares `hostnames: [shop.example.com]`, the same host as the legitimate route. Could it hijack its traffic? Which mechanism prevents that?
- **Q6.2** The `billing` route in `shop` attaches to a Gateway in `infra` without any ReferenceGrant. Why is that allowed, when the reference to the Service in `payments` isn't?
- **Q6.3** Why must the ReferenceGrant live in `payments`, not in `shop`?
- **Q6.4** Why does the request return 500 while `ResolvedRefs=False`, instead of 404 or 503?
- **Q6.5** What would change if you removed `name: billing` from the `to` block of the ReferenceGrant?

---

## Exercise 7: TLS termination and HTTP→HTTPS redirect

### Step 7.1: Certificate and Secret

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=*.example.com" \
  -addext "subjectAltName=DNS:*.example.com"
kubectl create secret tls example-tls -n infra --cert=tls.crt --key=tls.key
```

### Step 7.2: Add the HTTPS listener

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: infra
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.example.com"
    allowedRoutes:
      kinds:
      - kind: HTTPRoute
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: "true"
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        group: ""
        name: example-tls
    allowedRoutes:
      kinds:
      - kind: HTTPRoute
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: "true"
```

```bash
kubectl apply -f gateway.yaml
kubectl wait --for=condition=Programmed gateway/web -n infra --timeout=120s
```

In **a third terminal** (the existing port-forward doesn't pick up the new port):

```bash
kubectl port-forward -n envoy-gateway-system "svc/${ENVOY_SERVICE}" 8443:443
```

### Step 7.3: Move `store` to HTTPS and redirect HTTP

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: https
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path:
        type: Exact
        value: /checkout
    backendRefs:
    - name: store-v2
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: store-v1
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store-https-redirect
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - shop.example.com
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

```bash
kubectl apply -f route-store-tls.yaml

curl -si -H 'Host: shop.example.com' http://localhost:8888/checkout | grep -iE '^(HTTP|location)'

curl -sk --resolve shop.example.com:8443:127.0.0.1 \
  https://shop.example.com:8443/checkout | jq -r .pod

curl -sv --resolve shop.example.com:8443:127.0.0.1 --cacert tls.crt \
  https://shop.example.com:8443/ -o /dev/null 2>&1 | grep -E 'subject:|SSL connection'
```

```
HTTP/1.1 301 Moved Permanently
location: https://shop.example.com/checkout
store-v2-5b7f9d6c8-h4t9n
*  subject: CN=*.example.com
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
```

**Questions:**

- **Q7.1** What role does `sectionName` play here? What would happen if the `store` route had no `sectionName`?
- **Q7.2** Why doesn't the redirect's `location` carry port 443?
- **Q7.3** The Secret is in `infra`, the same namespace as the Gateway. What would you need if it lived in a `certs` namespace?
- **Q7.4** In `Terminate` mode, is the traffic between Envoy and `store-v1` encrypted? Which mode or resource would you use for end-to-end TLS?
- **Q7.5** Why did you use `--resolve` instead of `-H 'Host: ...'` for the HTTPS test?

---

## Exercise 8: Diagnosing broken routes

Apply these three broken routes all at once:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: broken-backend
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - broken.example.com
  rules:
  - backendRefs:
    - name: store-v3
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: broken-hostname
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: http
  hostnames:
  - shop.example.org
  rules:
  - backendRefs:
    - name: store-v1
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: broken-section
  namespace: shop
spec:
  parentRefs:
  - name: web
    namespace: infra
    sectionName: htpp
  hostnames:
  - typo.example.com
  rules:
  - backendRefs:
    - name: store-v1
      port: 80
```

```bash
kubectl apply -f broken.yaml
for r in broken-backend broken-hostname broken-section; do
  echo "== $r"
  kubectl get httproute "$r" -n shop \
    -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
done
curl -s -o /dev/null -w 'broken.example.com -> %{http_code}\n' -H 'Host: broken.example.com' http://localhost:8888/
curl -s -o /dev/null -w 'typo.example.com   -> %{http_code}\n' -H 'Host: typo.example.com' http://localhost:8888/
```

Expected output (reasons follow the spec; messages vary by implementation):

```
== broken-backend
Accepted=True (Accepted)
ResolvedRefs=False (BackendNotFound)
== broken-hostname
Accepted=False (NoMatchingListenerHostname)
ResolvedRefs=True (ResolvedRefs)
== broken-section
Accepted=False (NoMatchingParent)
ResolvedRefs=True (ResolvedRefs)
broken.example.com -> 500
typo.example.com   -> 404
```

A quick overview of the whole state:

```bash
kubectl get httproute -A
kubectl get gateway web -n infra \
  -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
kubectl logs -n envoy-gateway-system deploy/envoy-gateway --tail=50 | grep -i -E 'error|broken'
```

**Questions:**

- **Q8.1** For each broken route, name the condition and reason you would look at first, and the fix.
- **Q8.2** `broken-backend` is `Accepted=True`, yet it doesn't work. What does each of the two conditions tell you?
- **Q8.3** Do the `broken-hostname` and `broken-section` routes count toward `attachedRoutes`?
- **Q8.4** Give a general troubleshooting order for "my HTTPRoute doesn't respond", from the top of the hierarchy down.

---

## Exercise 9: Cleanup

```bash
kind delete cluster --name ckne-gw
rm -f tls.crt tls.key
```

---

## Answers

<details>
<summary>Exercise 1</summary>

**Q1.1** The `standard` channel contains only resources and fields at GA or beta level, with backward-compatibility guarantees (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`). `experimental` adds alpha resources and fields (`TCPRoute`, `UDPRoute`, `TLSRoute` in older versions, some new fields) that can change or disappear between releases. In production you install `standard` unless you need a specific feature, and mixing channels between clusters produces manifests that aren't portable.

**Q1.2** The Gateway API is developed out-of-tree as CRDs, under SIG Network. That lets it ship on its own release cadence, independent of Kubernetes minor versions, and lets each cluster choose its version. The flip side is that someone, whether the cluster operator or the implementation's chart, has to install the CRDs, and their version has to be compatible with the controller.

**Q1.3** The Envoy Gateway controller. Each implementation watches GatewayClasses and processes only those whose `spec.controllerName` equals its own identifier (`gateway.envoyproxy.io/gatewayclass-controller`). When it accepts one, it writes `Accepted=True` to the status. A GatewayClass whose `controllerName` no implementation claims stays with no conditions, or `Unknown`, forever.

**Q1.4** The Gateway API core defines only what is portable. Anything implementation-specific (Service type, replicas, proxy resources, bootstrap) lives in each vendor's CRD, referenced through `parametersRef`. That way the core API doesn't bloat with fields that only one implementation understands, and the vendor can version its parameters independently.
</details>

<details>
<summary>Exercise 2</summary>

**Q2.1** Envoy returns **404**. The listener exists and is programmed, but there is no route, so no virtual host or route matches. A Gateway without routes accepts connections but doesn't route anything.

**Q2.2** The Envoy Gateway controller creates them from the `Gateway` (with the `EnvoyProxy` parameters applied), in its own namespace, and labels them `owning-gateway-*`. They are derived infrastructure: if you delete the Gateway, the controller deletes them. This "one Gateway → one provisioned data plane" model is common, but the spec doesn't mandate it; other implementations share one proxy across several Gateways.

**Q2.3** In YAML, a value that starts with `*` is interpreted as an **alias** (a reference to an `&anchor`). Unquoted, the document either fails to parse or means something else. Quoting it makes it a literal string.

**Q2.4** The default is `Same`: only routes in the Gateway's own namespace (`infra`) can attach. Without the field, the routes in `shop` would be rejected with `NotAllowedByListeners`. `Selector` lets the platform team delegate by label without opening the Gateway to the whole cluster, as `All` would.
</details>

<details>
<summary>Exercise 3</summary>

**Q3.1**
- `/checkout` → `store-v2`: an exact match.
- `/checkout/` → `store-v1`: `Exact` compares the full string, and the trailing slash makes it different, so it falls through to the `PathPrefix /` rule.
- `/checkout/pay` → `store-v1`: it isn't exactly `/checkout`.
- `/checkoutx` → `store-v1`: same reason.
- `/products` → `store-v1`: `PathPrefix /` matches everything.

**Q3.2** The spec defines precedence by match specificity, not by position: `Exact` beats `PathPrefix`. Among prefixes, the longest one wins, then the method, then the number of header matches, then the number of query-param matches. The order of the rules in the manifest doesn't decide the winner. Order only matters as the last tie-breaker (between routes: oldest `creationTimestamp`, then alphabetical `namespace/name`; within a route, the first matching rule).

**Q3.3** No. `PathPrefix` matches by **path elements** separated by `/`. `/check` matches `/check` and `/check/...`, but not `/checkout` or `/checkx`. That is a common difference from a naive string-prefix match.

**Q3.4** `shop.example.org` is rejected at the **listener**: it doesn't match `*.example.com`, so no configuration applies to it (404). `blog.example.com` does match the listener, but no route declares that hostname, so it gets rejected at the **route** level, also with a 404. The code is the same, but the rejection happens at a different layer, which matters when you trace the problem.

**Q3.5** `attachedRoutes=1`.
</details>

<details>
<summary>Exercise 4</summary>

**Q4.1** Header names are case-insensitive (HTTP semantics), so `X-Canary` matches `x-canary`. The **value**, however, is compared exactly with `type: Exact`: `TRUE` ≠ `true`. The rule doesn't match, and the request falls into the weighted rule. If you need flexibility, use `type: RegularExpression`, which has implementation-specific support and a regex dialect that depends on the implementation.

**Q4.2** With equal paths, the next precedence criterion is the **number of header matches**. The first rule has one; the second has none. The more specific rule wins.

**Q4.3** They aren't percentages; they're relative proportions. Each backend receives `weight / sum(weights)`. With 3 and 1, the split is 75% / 25%. A `weight: 0` backend receives no traffic, but stays declared, which makes a rollback trivial. The default weight is 1.

**Q4.4** Per request. The proxy picks a backend for each HTTP request, so the same user can alternate between v1 and v2 across consecutive requests. For stickiness, route by header or cookie (a rule with a `headers` match, as `x-canary` does here) or use implementation-specific session persistence; that feature is still maturing in the API.

**Q4.5** With replicas, the split depends on the pod ratio and the kube-proxy/endpoint balancing, it's coarse (1 of 10 pods = 10%), and it couples capacity to percentage. With weights on the Gateway, the percentage is exact and independent of how many replicas each version has, it can be changed declaratively with one `apply`, and it combines with header or path matches for internal users.
</details>

<details>
<summary>Exercise 5</summary>

**Q5.1** `ReplacePrefixMatch` replaces only the matched prefix: `/legacy` → `/v2`, `/legacy/items` → `/v2/items`. `/legacyfoo` doesn't match the `PathPrefix /legacy` rule (element-wise matching). It goes to the `/` rule without a rewrite, so the backend receives `/legacyfoo`. `ReplacePrefixMatch` is only valid with a `PathPrefix` match.

**Q5.2** They're mutually exclusive by definition. A redirect answers the client directly (3xx) without contacting any backend, and a rewrite modifies the request that goes *to* the backend. Combined, one of the two would have no effect, so the API rejects that combination through validation.

**Q5.3** Yes. The redirect is answered by the proxy itself, so no backend is needed. A rule with neither `backendRefs` nor a redirect or response filter would instead return 500 or 404, depending on the case.

**Q5.4** `set` overwrites the header if it exists, or creates it. `add` appends a value, so if the header already exists, the result has multiple values. `remove` deletes it. Use `set` for headers the client must not be able to spoof (`x-team`), and `remove` to strip internal headers (`x-debug`) before they reach the backend.

**Q5.5** Envoy sees the listener on port 80. Port-forward is transparent to Envoy, so 8888 exists only on your workstation. Per the spec, if the redirect doesn't set `port`, it inherits the listener's port. Port 80 is the well-known port for `http`, so it's omitted from the `location` header.
</details>

<details>
<summary>Exercise 6</summary>

**Q6.1** No. Attachment requires a **two-way handshake**: the route has to reference the Gateway in `parentRefs`, *and* the Gateway listener has to allow the route's namespace through `allowedRoutes`. `untrusted` doesn't carry `gateway-access=true`, so the route is `Accepted=False (NotAllowedByListeners)` and generates no configuration. Declaring a hostname in the route is worth nothing without acceptance by the parent.

**Q6.2** The route → Gateway reference is controlled by the Gateway owner through `allowedRoutes`; that is the consent from the "receiving" side. The route → Service reference in another namespace has no equivalent field on the Service, so the API uses `ReferenceGrant`, which the owner of the target namespace creates. The principle is the same in both cases: the owner of the referenced resource has to consent.

**Q6.3** A ReferenceGrant is a statement from the owner of the **target** namespace. If it could live in the origin namespace, anyone who can create routes could authorize themselves to reach any Service in the cluster, which is the confused-deputy problem the API avoids.

**Q6.4** The spec requires that requests routed to an invalid backend (not found, not permitted, or of an unsupported kind) receive **500**, in proportion to that backend's weight. The route was accepted, so the host and path exist (not a 404). The failure is a configuration error, not a transient unavailability (not a 503).

**Q6.5** Without `name`, the grant covers **all** Services in `payments` for routes from `shop`. That works, but it violates least privilege; with `name`, it's limited to `billing`.
</details>

<details>
<summary>Exercise 7</summary>

**Q7.1** `sectionName` selects which specific listener of the Gateway the route attaches to. `store` attaches only to `https`, and `store-https-redirect` only to `http`, so for the same host, HTTP redirects and HTTPS serves. Without `sectionName`, `store` would attach to **both** listeners: plain HTTP would serve content, and it would collide with the redirect route on the same host, with precedence settled by the tie-breakers (oldest route first). The result is fragile and not what you intended.

**Q7.2** With `scheme: https` and no `port`, the spec derives the port from the scheme's well-known port (443), which is omitted from the `location` header. If your external HTTPS listener used a non-standard port, you'd have to declare `port` explicitly in the filter.

**Q7.3** A `ReferenceGrant` in `certs` with `from: {group: gateway.networking.k8s.io, kind: Gateway, namespace: infra}` and `to: {group: "", kind: Secret}`. Otherwise the listener shows `ResolvedRefs=False (RefNotPermitted)` and isn't programmed.

**Q7.4** No. `Terminate` decrypts at the Gateway, and the hop to the backend goes out in plain HTTP. For re-encryption to the backend, use `BackendTLSPolicy` (standard in recent versions). For TLS passthrough without terminating, use a listener with `protocol: TLS` and `mode: Passthrough` together with a `TLSRoute` (experimental channel).

**Q7.5** With `-H 'Host: ...'`, curl would send SNI `localhost` (derived from the URL), and the Host header only travels *inside* the already-established TLS. The listener chooses its certificate and filter chain by **SNI**. `--resolve` makes curl use `shop.example.com` as both SNI and Host while it connects to 127.0.0.1.
</details>

<details>
<summary>Exercise 8</summary>

**Q8.1**
- `broken-backend`: `ResolvedRefs=False (BackendNotFound)`. The `store-v3` Service doesn't exist. Fix the name, or create the Service.
- `broken-hostname`: `Accepted=False (NoMatchingListenerHostname)`. `shop.example.org` doesn't intersect `*.example.com`. Fix the route's hostname, or add a listener that covers it.
- `broken-section`: `Accepted=False (NoMatchingParent)`. The listener `htpp` doesn't exist. Change `sectionName` to `http`.

**Q8.2** `Accepted=True` means the parent accepted the route: the host, the listener and the permissions are fine, and the route is programmed. `ResolvedRefs=False` means one or more references inside the route couldn't be resolved. The route exists in the data plane, but its traffic goes to an invalid backend, and that produces the 500s. Always read both conditions.

**Q8.3** No. `attachedRoutes` counts only routes the listener accepted. Routes with `Accepted=False` aren't attached, so a count lower than the number of routes you expected is a quick signal of rejection.

**Q8.4**
1. `GatewayClass`: `Accepted=True`? Does the `controllerName` match an installed controller?
2. `Gateway`: `Accepted` and `Programmed`, with an address assigned?
3. Listener: `Programmed`, `ResolvedRefs` (certificates), no `Conflicted`, and `attachedRoutes` increases?
4. `HTTPRoute` → `status.parents[]` for **that** parentRef: `Accepted` (namespace allowed? hostname intersects? `sectionName` correct?).
5. `ResolvedRefs`: do the Services and ports exist, and are there ReferenceGrants for cross-namespace references?
6. Endpoints: does the Service have ready pods (`kubectl get endpointslices`)?
7. Data plane: reach the proxy Service directly, with the correct Host/SNI, and check the controller and Envoy logs.
</details>