# Guided Exercises — Topic 5.3: Use Ingress rules to expose applications (CKAD v1.35, weight 5%)

Reference source: [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Prerequisite: A cluster with an installed Ingress controller (e.g. `ingress-nginx`). On minikube, enable via `minikube addons enable ingress`.

## Exercise 1 — Inspecting Ingress Controller and Available IngressClass Objects

1. List Pods in the Ingress controller namespace:
   ```bash
   kubectl get pods -n ingress-nginx
   ```
2. Confirm at least one `IngressClass` object exists:
   ```bash
   kubectl get ingressclass
   ```
3. Inspect default `IngressClass` (look for annotation `ingressclass.kubernetes.io/is-default-class`):
   ```bash
   kubectl get ingressclass -o yaml
   ```

**Verification Questions:**
- What is the difference between an `Ingress` API resource and an Ingress controller?
- What happens if you create an `Ingress` omitting `ingressClassName` when no default `IngressClass` exists?

---

## Exercise 2 — Deploying Applications and Exposing via Service

1. Create a simple Deployment:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   ```
2. Expose Deployment via a `ClusterIP` Service:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80
   ```
3. Verify Service populates Endpoints:
   ```bash
   kubectl get endpoints web
   ```

**Verification Questions:**
- Why does an `Ingress` require a `Service` backend rather than targeting Pods directly?
- What would `<none>` returned by `kubectl get endpoints web` indicate?

---

## Exercise 3 — Creating a Basic Ingress with Path Rules

1. Create `ingress-web.yaml`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
   spec:
     ingressClassName: nginx
     rules:
     - host: web.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: web
               port:
                 number: 80
   ```
2. Apply manifest:
   ```bash
   kubectl apply -f ingress-web.yaml
   ```
3. Retrieve assigned IP or hostname:
   ```bash
   kubectl get ingress web-ingress
   ```
4. Test access setting `Host` header (replace `<IP>` with Ingress controller IP):
   ```bash
   curl -H "Host: web.local" http://<IP>/
   ```

**Verification Questions:**
- What is the difference between `pathType: Prefix` vs `pathType: Exact`?
- Why must `Host` header be passed in `curl` for requests to hit the rule?

---

## Exercise 4 — Path-Based Fan-Out Routing Across Services

1. Deploy a second app and expose it:
   ```bash
   kubectl create deployment api --image=hashicorp/http-echo -- -text="api response"
   kubectl expose deployment api --port=5678 --target-port=5678
   ```
2. Edit `ingress-web.yaml` adding a second path under the same host:
   ```yaml
       - path: /api
         pathType: Prefix
         backend:
           service:
             name: api
             port:
               number: 5678
   ```
3. Re-apply and test both paths:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -H "Host: web.local" http://<IP>/
   curl -H "Host: web.local" http://<IP>/api
   ```

**Verification Questions:**
- If two paths overlap (e.g. `/` and `/api`), which rule takes precedence?
- What happens if `/api` specifies `pathType: Exact` instead of `Prefix`?

---

## Exercise 5 — Name-Based Virtual Hosting (Multiple Hosts)

1. Add a second host rule in the same `Ingress`, routing `api.local` to `api` Service:
   ```yaml
     - host: api.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: api
               port:
                 number: 5678
   ```
2. Re-apply manifest and test both hosts:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -H "Host: web.local" http://<IP>/
   curl -H "Host: api.local" http://<IP>/
   ```

**Verification Questions:**
- What is the conceptual difference between path-based routing (fan-out) vs host-based routing (virtual hosting)?
- What happens if a request omits `Host` header or specifies an unmatched host?

---

## Exercise 6 — TLS Termination at Ingress

1. Generate a self-signed certificate and `kubernetes.io/tls` Secret:
   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout tls.key -out tls.crt -subj "/CN=web.local/O=web.local"
   kubectl create secret tls web-tls --key tls.key --cert tls.crt
   ```
2. Add `tls` section to `Ingress`:
   ```yaml
   spec:
     tls:
     - hosts:
       - web.local
       secretName: web-tls
   ```
3. Re-apply and test HTTPS bypassing certificate validation:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -k -H "Host: web.local" https://<IP>/
   ```

**Verification Questions:**
- Where does TLS termination occur: in application Pods or at Ingress controller?
- Which keys are mandatory inside a `kubernetes.io/tls` Secret?

---

## Exercise 7 — Troubleshooting Ingress

1. Intentionally trigger an error: update Service `name` in a path to non-existent target (`web-typo`) and re-apply.
2. Describe Ingress to inspect events:
   ```bash
   kubectl describe ingress web-ingress
   ```
3. Fix Service name and verify error clears.

**Verification Questions:**
- What event message appears in `kubectl describe ingress` when backend Service is missing?
- If `Ingress` is configured correctly but returns 404, which two components should be inspected besides Ingress resource itself?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- `Ingress` is a declarative rules API object; Ingress controller is active software (e.g. `ingress-nginx` running as Pods) observing objects and configuring proxy/load balancer rules. Without a controller, `Ingress` objects have no runtime effect.
- If `ingressClassName` is omitted and no default `IngressClass` exists, controllers ignore the `Ingress` object, leaving rules unconfigured.

**Exercise 2**
- `Ingress` targets `Services` to leverage Service Endpoints for load balancing and Pod lifecycle decoupling. Direct Pod targeting is unsupported.
- Empty Endpoints indicate Service selectors match zero `Ready` Pods, causing gateway 502/503 errors.

**Exercise 3**
- `Prefix` matches URL path segments (`/` matches all; `/api` matches `/api`, `/api/v1`). `Exact` requires identical case-sensitive string matching without subpath evaluation.
- Ingress controllers route using HTTP `Host` headers; missing or unmatched headers trigger default backend responses or 404 errors.

**Exercise 4**
- Most specific path segment wins (longest prefix match). `ingress-nginx` orders paths by length.
- `pathType: Exact` on `/api` matches strictly `/api`; subpaths like `/api/status` fall through to `/` or return 404.

**Exercise 5**
- Fan-out routes distinct URL paths under a single host to different Services; virtual hosting routes distinct HTTP `Host` headers to different Services.
- Unmatched `Host` headers route to `spec.defaultBackend` or return controller 404.

**Exercise 6**
- TLS terminates at Ingress controller proxy; traffic between controller and internal Services typically travels over unencrypted HTTP.
- Mandatory keys: `tls.crt` (certificate) and `tls.key` (private key).

**Exercise 7**
- Warning event stating backend service was not found (`service "web-typo" not found`).
- Inspect target `Service` (existence, ports) and `Endpoints`/Pods (readiness probes, label selectors).

</details>
