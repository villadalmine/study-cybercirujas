# Guided Exercises — 5.5 Ingress controllers and Ingress resources

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with an active Ingress controller.

---

## Exercise 1 — Inspecting Ingress Controller Architecture

1. Verify running controller instances:
   ```bash
   kubectl get pods --all-namespaces -l app.kubernetes.io/name=ingress-nginx
   kubectl get ingressclass
   ```

---

## Exercise 2 — Deploying Backend Services

1. Create target namespace and Deployments:
   ```bash
   kubectl create namespace ingress-demo
   kubectl create deployment app-blue --image=hashicorp/http-echo -n ingress-demo -- -text="blue"
   kubectl create deployment app-green --image=hashicorp/http-echo -n ingress-demo -- -text="green"
   ```
2. Expose Deployments as Services:
   ```bash
   kubectl expose deployment app-blue -n ingress-demo --port=80 --target-port=5678
   kubectl expose deployment app-green -n ingress-demo --port=80 --target-port=5678
   ```

---

## Exercise 3 — Creating an Ingress Resource

1. Manifest Ingress object using imperatives:
   ```bash
   kubectl create ingress demo-basic -n ingress-demo \
     --class=nginx \
     --rule="demo.local/*=app-blue:80"
   ```
2. Query Ingress resources:
   ```bash
   kubectl get ingress demo-basic -n ingress-demo -o yaml
   ```

---

## Exercise 4 — Path-Based Routing (Prefix vs Exact)

1. Manifest multi-path routing:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: demo-paths
     namespace: ingress-demo
   spec:
     ingressClassName: nginx
     rules:
     - host: demo.local
       http:
         paths:
         - path: /blue
           pathType: Prefix
           backend:
             service:
               name: app-blue
               port:
                 number: 80
         - path: /green
           pathType: Prefix
           backend:
             service:
               name: app-green
               port:
                 number: 80
   ```
   ```bash
   kubectl apply -f demo-paths.yaml
   ```

---

## Exercise 5 — TLS Termination

1. Create TLS secret:
   ```bash
   openssl req -x509 -nodes -days 365 \
     -newkey rsa:2048 \
     -keyout tls.key -out tls.crt \
     -subj "/CN=secure.demo.local/O=secure.demo.local"
   kubectl create secret tls demo-tls -n ingress-demo --cert=tls.crt --key=tls.key
   ```
2. Apply TLS-enabled Ingress:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: demo-tls
     namespace: ingress-demo
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - secure.demo.local
       secretName: demo-tls
     rules:
     - host: secure.demo.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: app-blue
               port:
                 number: 80
   ```

---

<details>
<summary>View Answers</summary>

1. Ingress APIs define routing rules; Ingress Controllers enforce rules by routing proxy traffic.
2. `pathType: Prefix` matches path segment prefixes; `Exact` requires strict character-for-character matching.
3. TLS secrets require `tls.crt` and `tls.key` entries.

</details>
