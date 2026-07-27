# Guided Exercises — 5.4 Use the Gateway API to manage Ingress traffic

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf) | [Gateway API Official Docs](https://gateway-api.sigs.k8s.io/)

Prerequisites: A working cluster with `kubectl` and `helm` installed.

---

## Exercise 1 — Install Gateway API CRDs

1. Verify existing Gateway API CRDs:
   ```bash
   kubectl get crd | grep gateway.networking.k8s.io
   ```
2. Install standard release channel CRDs:
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   ```
3. Confirm CRD installation:
   ```bash
   kubectl get crd -l gateway.networking.k8s.io/bundle-version
   ```

### Questions

1. What separates standard channel CRDs from experimental channel CRDs?

---

## Exercise 2 — Deploy Envoy Gateway Controller

1. Install Envoy Gateway via Helm:
   ```bash
   helm install eg oci://docker.io/envoyproxy/gateway-helm \
     --version v1.2.0 \
     -n envoy-gateway-system --create-namespace
   ```
2. Verify `GatewayClass` status:
   ```bash
   kubectl get gatewayclass
   kubectl describe gatewayclass eg
   ```

---

## Exercise 3 — Deploy Gateway and Backends

1. Deploy target application workloads:
   ```bash
   kubectl create namespace gw-demo
   kubectl -n gw-demo create deployment web --image=nginxdemos/hello --replicas=2
   kubectl -n gw-demo expose deployment web --port=80
   ```
2. Manifest `Gateway`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: demo-gateway
     namespace: gw-demo
   spec:
     gatewayClassName: eg
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
   kubectl -n gw-demo get gateway demo-gateway -o wide
   ```

---

## Exercise 4 — Configure Host-Based HTTPRoute

1. Manifest `HTTPRoute`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: web-route
     namespace: gw-demo
   spec:
     parentRefs:
       - name: demo-gateway
     hostnames:
       - "web.example.local"
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: web
             port: 80
   ```
2. Apply and test HTTP routing matching Host headers:
   ```bash
   kubectl apply -f web-route.yaml
   ```

---

## Exercise 5 — Weight-Based Traffic Splitting (Canary)

1. Deploy `web-v2`:
   ```bash
   kubectl -n gw-demo create deployment web-v2 --image=nginxdemos/hello --replicas=1
   kubectl -n gw-demo expose deployment web-v2 --port=80
   ```
2. Update `HTTPRoute` with relative weights:
   ```yaml
         backendRefs:
           - name: web
             port: 80
             weight: 90
           - name: web-v2
             port: 80
             weight: 10
   ```

---

## Exercise 6 — Cross-Namespace References with ReferenceGrant

1. Create target service in `billing` namespace:
   ```bash
   kubectl create namespace billing
   kubectl -n billing create deployment reports --image=nginxdemos/hello
   kubectl -n billing expose deployment reports --port=80
   ```
2. Authorize cross-namespace reference inside target `billing` namespace:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1beta1
   kind: ReferenceGrant
   metadata:
     name: allow-gw-demo-to-billing
     namespace: billing
   spec:
     from:
       - group: gateway.networking.k8s.io
         kind: HTTPRoute
         namespace: gw-demo
     to:
       - group: ""
         kind: Service
   ```
   ```bash
   kubectl apply -f referencegrant.yaml
   ```

---

## Teardown

```bash
kubectl delete namespace gw-demo billing envoy-gateway-system
```

---

<details>
<summary>View Answers</summary>

1. Standard channel CRDs contain stable GA/Beta specifications (`GatewayClass`, `Gateway`, `HTTPRoute`).
2. `Accepted` status validates syntax; `Programmed` status indicates underlying data plane proxy allocation.
3. ReferenceGrants must be created in the **target** namespace holding the referenced resource.

</details>
