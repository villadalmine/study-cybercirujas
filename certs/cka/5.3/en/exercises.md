# Guided Exercises — 5.3 Service types and Endpoints: ClusterIP, NodePort, LoadBalancer

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with `kubectl` configured.

```bash
kubectl create namespace svc-lab
kubectl config set-context --current --namespace=svc-lab
```

---

## Exercise 1 — ClusterIP: In-Cluster Service Exposure

1. Deploy a test Deployment with 3 replicas:
   ```bash
   kubectl create deployment web --image=nginx:alpine --replicas=3 -n svc-lab
   ```
2. Verify assigned labels:
   ```bash
   kubectl get pods -n svc-lab --show-labels
   ```
3. Expose Deployment via `ClusterIP` Service:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 -n svc-lab
   ```
4. Inspect Service details:
   ```bash
   kubectl get svc web -n svc-lab -o wide
   kubectl describe svc web -n svc-lab
   ```
5. Test internal connectivity:
   ```bash
   kubectl run tmp-curl --image=busybox:1.36 --rm -it --restart=Never -n svc-lab -- \
     wget -qO- http://web.svc-lab.svc.cluster.local
   ```
6. Scale Deployment replicas and observe Endpoints updates:
   ```bash
   kubectl scale deployment web --replicas=5 -n svc-lab
   kubectl get endpoints web -n svc-lab
   ```

---

## Exercise 2 — NodePort: Exposing Services Externally

1. Patch Service `type` to `NodePort`:
   ```bash
   kubectl patch svc web -n svc-lab -p '{"spec": {"type": "NodePort"}}'
   ```
2. Retrieve assigned node port number:
   ```bash
   kubectl get svc web -n svc-lab
   ```
3. Test external connectivity targeting host Node IPs:
   ```bash
   kubectl get nodes -o wide
   curl http://<NODE_IP>:<NODE_PORT>
   ```

---

## Exercise 3 — LoadBalancer Service Types

1. Patch Service `type` to `LoadBalancer`:
   ```bash
   kubectl patch svc web -n svc-lab -p '{"spec": {"type": "LoadBalancer"}}'
   kubectl get svc web -n svc-lab
   ```
2. Note `EXTERNAL-IP` status: Cloud providers provision public IPs; bare-metal environments without MetalLB remain in `<pending>` status.

---

## Exercise 4 — Endpoints and EndpointSlices

1. Inspect Endpoints:
   ```bash
   kubectl get endpoints web -n svc-lab -o yaml
   kubectl get endpointslices -n svc-lab
   ```
2. Manifest a Service without a `selector`, along with manual `Endpoints`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: external-db
     namespace: svc-lab
   spec:
     ports:
       - port: 5432
         targetPort: 5432
   ---
   apiVersion: v1
   kind: Endpoints
   metadata:
     name: external-db
     namespace: svc-lab
   subsets:
     - addresses:
         - ip: 10.0.0.50
       ports:
         - port: 5432
   ```
   ```bash
   kubectl apply -f external-db.yaml
   kubectl get endpoints external-db -n svc-lab
   ```

---

## Teardown

```bash
kubectl delete namespace svc-lab
```

---

<details>
<summary>View Answers</summary>

1. `ClusterIP` Services match Pod labels via `spec.selector` definitions.
2. Virtual ClusterIPs remain static throughout Pod scale and replacement operations.
3. NodePort Services extend `ClusterIP` by binding static node ports across all host nodes.
4. `EndpointSlice` partitions Service endpoints into scalable subsets of up to 100 entries.

</details>
