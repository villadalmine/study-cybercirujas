# 5.3 Use Ingress rules to expose applications

## What Problem Ingress Solves

Exposing applications via `Service` types `NodePort` or `LoadBalancer` requires each service to consume its own node port or dedicated cloud load balancer. This model scales poorly: running ten HTTP applications in a cluster would require ten separate `LoadBalancer` instances (each carrying monetary cost and public IP addresses) or ten random high ports per node.

**Ingress** is a Kubernetes API resource (`networking.k8s.io/v1`) declaring **HTTP/HTTPS routing rules** based on `host` and `path` toward internal `Service` backends (typically `ClusterIP`). A single entry point (one IP or cloud `LoadBalancer`) can thus route traffic across numerous internal applications.

Ingress by itself **does nothing at runtime**: it is strictly a declarative rules object. An **Ingress Controller** must be running in the cluster (e.g. `ingress-nginx`, Traefik, HAProxy, Contour) to observe `Ingress` resources and program underlying proxies. Without an active controller, `Ingress` objects remain unconfigured in the API server.

## Core Components

| Object | Role |
|---|---|
| `Ingress` | Declares routing rules (which host/path routes to which internal Service) |
| `IngressClass` | Identifies which Ingress Controller should process the Ingress object |
| Ingress Controller | Pod(s) reading Ingress manifests and configuring actual load balancers/proxies |
| `Service` (ClusterIP) | Internal backend target to which the Ingress Controller forwards traffic |

On the CKAD exam, the Ingress controller is typically **pre-installed** in the cluster (e.g. `ingress-nginx`); your task is creating or modifying the `Ingress` API resource correctly, rather than installing controllers.

## Anatomy of an Ingress Manifest

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
```

Key fields:

- **`spec.ingressClassName`**: Replaces legacy annotation `kubernetes.io/ingress.class`. Must match `metadata.name` of an existing `IngressClass` object. If omitted, uses default `IngressClass` (annotated `ingressclass.kubernetes.io/is-default-class: "true"`).
- **`rules[].host`**: Domain-based virtual hosting rule. If omitted, rule applies to all incoming HTTP traffic matching the Ingress Controller IP.
- **`pathType`**: Defines matching logic for URL paths:
  - `Exact`: Exact string match (case-sensitive).
  - `Prefix`: URL path segment matching (`/foo` matches `/foo` and `/foo/bar`, but not `/foobar`).
  - `ImplementationSpecific`: Controller-dependent custom matching.
- **`backend.service.name` / `port`**: Destination target `Service`. Port can be specified via `number` or `name` (matching `ports[].name` on the `Service`).

## Checking Available IngressClass

```console
$ kubectl get ingressclass
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       10d
```

## Creating Ingress via `kubectl create ingress`

During the exam, imperatively generating YAML manifests is significantly faster than writing by hand:

```console
$ kubectl create ingress web-ingress \
    --rule="app.example.com/*=web-svc:80" \
    --class=nginx \
    --dry-run=client -o yaml > ingress.yaml
```

Generates an equivalent manifest to the one above. `--rule` accepts `host/path=service:port[,tls=secret]` format.

## Example: Path-Based Fan-Out Routing

Route `/api` and `/` under the same hostname to different internal services:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-svc
            port:
              number: 80
```

Requests to `/api/users` route to `api-svc`; all other paths fall back to `frontend-svc`. Evaluation precedence between rules sharing a host is controller-dependent (`ingress-nginx` evaluates most specific prefix first).

## Example: Name-Based Virtual Hosting

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-host-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: blog.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: blog-svc
            port:
              number: 80
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop-svc
            port:
              number: 80
```

The Ingress Controller reads the HTTP `Host` header to select matching routing rules. When testing via `curl`, specify the `Host` header or resolve DNS targeting the Ingress Controller `EXTERNAL-IP`:

```console
$ curl -H "Host: shop.example.com" http://<EXTERNAL-IP>/
```

## `defaultBackend` Fallback Configuration

```yaml
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: fallback-svc
      port:
        number: 80
  rules:
  - host: app.example.com
    ...
```

Requests failing all `rules` host/path conditions route to `defaultBackend` (typically custom application 404 handler). If undefined, controller returns its default 404 response.

## TLS Termination at Ingress

```yaml
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: app-tls-secret
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
```

`secretName` points to a `kubernetes.io/tls` `Secret` containing `tls.crt` and `tls.key` data:

```console
$ kubectl create secret tls app-tls-secret \
    --cert=path/to/tls.crt --key=path/to/tls.key
```

TLS terminates at the Ingress Controller; internal traffic to backend `Services` typically traverses the cluster network over HTTP.

## Inspection and Troubleshooting

```console
$ kubectl get ingress
NAME          CLASS   HOSTS              ADDRESS         PORTS   AGE
web-ingress   nginx   app.example.com    192.168.49.2    80      2m

$ kubectl describe ingress web-ingress
Name:             web-ingress
...
Rules:
  Host              Path  Backends
  ----              ----  --------
  app.example.com
                     /   web-svc:80 (10.244.0.5:80)
...
Events:
  Type    Reason  Age   From                      Message
  ----    ------  ----  ----                      -------
  Normal  Sync    2m    nginx-ingress-controller  Scheduled for sync
```

Common failure scenarios checklist:

1. **`ADDRESS` is empty or missing sync events**: No controller is watching `ingressClassName`, or controller Pod is crashing/stopped (`kubectl get pods -n ingress-nginx`).
2. **404 from controller default backend**: HTTP request `Host`/`path` matches no configured rule — verify sent `Host` header.
3. **502/503 from controller**: Target backend `Service` exists but has no `Endpoints` (selector mismatch or Pods not `Ready`). Verify via `kubectl get endpoints <service>`.
4. **`Backends` in `describe ingress` shows `<none>` or unpopulated IPs**: Confirms missing Endpoints — referenced `Service` has no active Pod backends.
5. **Referenced `Service` must be in the same namespace** as `Ingress` — Ingress cannot target cross-namespace Services.

## References

- [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) — kubernetes.io
- [Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/) — kubernetes.io
- [IngressClass](https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class) — kubernetes.io
- [kubectl create ingress](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-ingress) — kubernetes.io
- [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf) — CNCF
