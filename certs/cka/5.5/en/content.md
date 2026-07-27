# 5.5 Ingress controllers and Ingress resources

## What Problem Does Ingress Solve?

Exposing every web workload using individual `NodePort` or `LoadBalancer` Services becomes expensive and unmanageable as application counts grow.

An **Ingress** resource (`networking.k8s.io/v1`) defines HTTP and HTTPS routing rules to in-cluster `Services` based on:

- **Host headers** (domain names, e.g. `app.example.com`).
- **URL Path prefixes** (e.g. `/api`, `/web`).

With a single entrypoint IP or cloud LoadBalancer, an Ingress routes traffic to multiple backend `Services` (typically of type `ClusterIP`) operating as a reverse proxy.

Important: **Ingress resources do not replace Services**. The `Ingress` object defines declarative rules; the **Ingress Controller** enforces those rules by watching API objects and balancing traffic.

---

## Ingress Controllers

Kubernetes **does not include a default Ingress Controller**. An `Ingress` API resource created without an active Ingress Controller remains inert.

Common Ingress Controllers:

- **ingress-nginx** (Kubernetes community project).
- **NGINX Inc. Ingress Controller**.
- Traefik.
- HAProxy Ingress.

Controllers typically execute as `Deployments` in dedicated namespaces (e.g. `ingress-nginx`), exposed externally via `LoadBalancer` or `NodePort` Services.

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

---

## IngressClass

Since `networking.k8s.io/v1`, every `Ingress` specifies its target controller using `spec.ingressClassName` referencing an `IngressClass` resource:

```bash
kubectl get ingressclass
```

```
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       3d
```

If an `IngressClass` carries annotation `ingressclass.kubernetes.io/is-default-class: "true"`, Ingress resources omitting `ingressClassName` adopt it automatically.

---

## Structure of an Ingress Manifest

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
            name: web-service
            port:
              number: 80
```

Key fields:

- **`rules`**: Host and path routing definitions.
- **`pathType`**: Matching strategy (`Exact`, `Prefix`, `ImplementationSpecific`).
- **`backend.service`**: Destination `Service` name and port.
- **`annotations`**: Advanced controller behaviors (URL rewrites, rate limits, SSL redirects).

---

## Path-Based Routing (Fan-Out)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fanout-ingress
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
            name: api-service
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-service
            port:
              number: 80
```

---

## Name-Based Virtual Hosting (Multi-Host)

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
            name: blog-service
            port:
              number: 80
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop-service
            port:
              number: 80
```

---

## TLS / HTTPS Configuration

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-ingress
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
            name: web-service
            port:
              number: 80
```

Create TLS secrets using:

```bash
kubectl create secret tls app-tls-secret --cert=tls.crt --key=tls.key
```

---

## Imperative Command Shortcut

```bash
kubectl create ingress simple-ingress \
  --class=nginx \
  --rule="app.example.com/*=web-service:80"
```

---

## Troubleshooting Ingress

```bash
kubectl get ingress
kubectl describe ingress web-ingress
```

Common failures:
1. `ADDRESS` field remains blank: Ingress Controller missing or misconfigured.
2. 404 from Controller: Target `Service` missing or selector mismatch.
3. Namespace mismatch: Ingress resources must reside in the same namespace as target backend Services.

```bash
curl --resolve app.example.com:80:203.0.113.10 http://app.example.com/
```

---

## References

- Ingress Overview: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Ingress Controllers: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
