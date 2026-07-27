# 5.4 Use the Gateway API to manage Ingress traffic

## What is the Gateway API?

The **Gateway API** is an official Kubernetes API suite (`gateway.networking.k8s.io` group) designed to supersede and extend legacy `Ingress` resources for exposing HTTP, HTTPS, gRPC, TCP, UDP, and TLS passthrough traffic to cluster Services. Installed via Custom Resource Definitions (**CRDs**), the Gateway API requires an active **Gateway Controller** implementation (e.g. NGINX Gateway Fabric, Envoy Gateway, Istio, Cilium, Kgateway).

Key problems solved relative to legacy `Ingress`:

- `Ingress` merged infrastructure provisioning, host routing, and traffic policy definitions into a single object, requiring vendor-specific, non-portable annotations.
- `Ingress` strictly modeled HTTP/HTTPS L7 traffic, lacking native specs for L4 TCP/UDP, TLS passthrough, or gRPC.
- `Ingress` lacked role-oriented separation between infrastructure providers, cluster operators, and application developers.

The Gateway API separates operational concerns into distinct role-based resources featuring native multi-protocol routing and portable traffic filtering mechanisms.

---

## Role-Oriented Architecture

| Role | Resource | Operational Scope |
|---|---|---|
| Infrastructure Provider | `GatewayClass` | Defines controller implementation specs (cloud LB, gateway fabric) |
| Cluster Operator | `Gateway` | Defines physical ingress entrypoints (listeners, ports, TLS certificates) |
| Application Developer | `HTTPRoute` / `GRPCRoute` / `TCPRoute` / `TLSRoute` | Defines path/header routing rules forwarding traffic to `Services` |

---

## Core Gateway API Resources

- **GatewayClass** (cluster-scoped): Analogous to `IngressClass`. References external `controllerName` implementations.
- **Gateway** (namespaced): Declares listener entrypoints (protocol, port, hostname, TLS termination). Controller implementations allocate external load balancers, populating addresses into `status.addresses`.
- **HTTPRoute**: Defines L7 HTTP routing matches (`path`, `headers`, `methods`) targeting `backendRefs` with native traffic weight splitting and header/path transformation `filters`.
- **GRPCRoute**: Specifies gRPC service routing rules.
- **TCPRoute / UDPRoute / TLSRoute**: Enables L4 transport routing and TLS passthrough.
- **ReferenceGrant**: Explicitly authorizes cross-namespace references (e.g. an `HTTPRoute` in namespace `default` routing to a `Service` in namespace `backend-ns`).

---

## CRD Installation

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

```
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io created
```

Verify installed CRDs:

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

---

## Exposing Services via Gateway API

### 1. GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx-gateway
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller
```

### 2. Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: default
spec:
  gatewayClassName: nginx-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
kubectl apply -f gateway.yaml
kubectl get gateway web-gateway
```

```
NAME          CLASS           ADDRESS         PROGRAMMED   AGE
web-gateway   nginx-gateway   10.96.200.15    True         30s
```

### 3. HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
  namespace: default
spec:
  parentRefs:
    - name: web-gateway
  hostnames:
    - "shop.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend-svc
          port: 80
```

```bash
kubectl get httproute web-route -o wide
```

---

## Path-Based Multi-Backend Routing

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: default
spec:
  parentRefs:
    - name: web-gateway
  hostnames:
    - "shop.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-svc
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend-svc
          port: 80
```

---

## Weight-Based Canary Traffic Splitting

`backendRefs` accepts relative `weight` values to split traffic proportionally across backends natively without vendor annotations:

```yaml
  rules:
    - backendRefs:
        - name: web-v1
          port: 80
          weight: 90
        - name: web-v2
          port: 80
          weight: 10
```

---

## TLS Termination

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: default
spec:
  gatewayClassName: nginx-gateway
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: web-tls-cert
```

The referenced `Secret` must exist within the Gateway's namespace (or be authorized via `ReferenceGrant`) containing a `kubernetes.io/tls` secret payload.

---

## Cross-Namespace References via ReferenceGrant

When an `HTTPRoute` in namespace `default` routes to a `Service` in namespace `backend-ns`, a `ReferenceGrant` must explicitly authorize access inside `backend-ns`:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-route-to-svc
  namespace: backend-ns
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: default
  to:
    - group: ""
      kind: Service
```

Omitting `ReferenceGrant` sets `ResolvedRefs=False` status on the routing resource.

---

## Troubleshooting Status & Conditions

Resource status conditions provide immediate diagnostic feedback:

```bash
kubectl describe gateway web-gateway
kubectl describe httproute web-route
```

Key failure conditions:
- `GatewayClass` `Accepted=False`: No active controller handles specified `controllerName`.
- `Gateway` `Programmed=False`: Controller failed load balancer allocation.
- `HTTPRoute` `ResolvedRefs=False`: Referenced `backendRef` Service does not exist, port mismatches occur, or cross-namespace authorization is missing.

---

## Comparison: Ingress vs Gateway API

| Feature | Ingress | Gateway API |
|---|---|---|
| Extensibility | Controller-specific annotations | Native typed fields (`filters`, `weight`, `matches`) |
| Role Separation | Single monolithic object | Role-separated (`GatewayClass`, `Gateway`, `*Route`) |
| Protocols | HTTP / HTTPS only | HTTP, HTTPS, gRPC, TCP, UDP, TLS Passthrough |
| Traffic Splitting | Non-standard annotations | Native `weight` fields under `backendRefs` |
| Multi-Namespace | Unsupported natively | Native support via `ReferenceGrant` |

---

## References

- Gateway API Official Documentation: https://gateway-api.sigs.k8s.io/
- Gateway API Spec Reference: https://gateway-api.sigs.k8s.io/reference/spec/
- Gateway API Releases & Installation: https://github.com/kubernetes-sigs/gateway-api/releases
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
