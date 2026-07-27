# 5.3 Service types: ClusterIP, NodePort, LoadBalancer and Endpoints

## Purpose of Kubernetes Services

Pods are ephemeral resources: when a Pod terminates and gets recreated by controllers (Deployments, ReplicaSets, etc.), it receives a new IP address. Relying directly on Pod IP addresses creates fragile connectivity dependencies. A `Service` solves this by assigning a **stable virtual network identity** (a virtual ClusterIP address and CoreDNS hostname) targeting a set of Pods matched via label `selector` keys.

`kube-proxy` runs on every node to route traffic destined for a virtual ClusterIP address to target Pods.

---

## ClusterIP (Default)

Exposes the Service on an internal cluster-virtual IP address accessible exclusively within the cluster (from other Pods or Nodes). This is the default Service `type` when unspecified.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80        # Virtual Service port
      targetPort: 8080 # Target container listening port
      protocol: TCP
```

```bash
kubectl apply -f web-svc.yaml
kubectl get svc web-svc
```

```
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.44.211   <none>        80/TCP    5s
```

Any cluster Pod can reach the Service via its ClusterIP (`10.96.44.211:80`) or via internal FQDN (`web-svc.default.svc.cluster.local`, resolved via CoreDNS).

Imperative shortcut:

```bash
kubectl expose deployment web --port=80 --target-port=8080 --name=web-svc
```

---

## NodePort

Extends `ClusterIP` by allocating a static host port (default range `30000–32767`) across **all nodes** in the cluster. Incoming traffic hitting `<NodeIP>:<nodePort>` routes directly to the Service, regardless of which node executes the destination Pod.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080   # Optional; assigned dynamically when omitted
```

```bash
kubectl get svc web-nodeport
```

```
NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-nodeport   NodePort   10.96.90.12    <none>        80:30080/TCP   10s
```

```bash
curl http://<any-node-ip>:30080
```

`NodePort` Services automatically provision an underlying ClusterIP. Useful for local development or bare-metal environments lacking external load balancers.

---

## LoadBalancer

Extends `NodePort` by requesting an external cloud load balancer (AWS NLB, GCP Load Balancing) or on-premise controller (MetalLB) with an assigned public IP, forwarding traffic to node `NodePorts`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-lb
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

```bash
kubectl get svc web-lb
```

```
NAME     TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)        AGE
web-lb   LoadBalancer   10.96.5.201   203.0.113.10    80:31445/TCP   2m
```

An `EXTERNAL-IP` stuck in `<pending>` status indicates no active load balancer controller exists to fulfill provisioning requests (typical on bare-metal clusters missing MetalLB). `LoadBalancer` Services remain accessible via `NodePort` ports.

---

## Endpoints and EndpointSlices

A Service specifying a `selector` automatically generates an `Endpoints` object (and one or more `EndpointSlice` objects in modern clusters) containing IPs and port mappings for matching Pods passing **readiness probes**.

```bash
kubectl get endpoints web-svc
```

```
NAME      ENDPOINTS                         AGE
web-svc   10.244.1.5:8080,10.244.2.7:8080   3m
```

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-svc
kubectl describe endpointslice web-svc-xk2lp
```

If `ENDPOINTS` displays `<none>`, inspect common causes:

- Service `selector` keys fail to match Pod `labels`.
- Pods exist but fail **readiness probes** (unready Pods are excluded from Endpoints).
- `targetPort` configurations do not match container listening ports.

```bash
kubectl get pods --show-labels
kubectl describe svc web-svc   # Displays Selector and Endpoints simultaneously
```

Services can also be created **without** `selector` keys to manage `Endpoints` or `EndpointSlices` manually — useful for referencing external databases with stable internal identities:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db
spec:
  ports:
    - port: 5432
---
apiVersion: v1
kind: Endpoints
metadata:
  name: external-db   # Must match Service name
subsets:
  - addresses:
      - ip: 192.168.1.50
    ports:
      - port: 5432
```

---

## Multi-Port Services

Services can expose multiple ports by assigning explicit `name` entries to each port configuration:

```yaml
spec:
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9090
      targetPort: 9090
```

---

## Traffic Policies & Session Affinity

- `externalTrafficPolicy: Cluster` (default): External traffic routes to any cluster node and can be forwarded to Pods running on different nodes (may incur extra hops, but balances load evenly across nodes).
- `externalTrafficPolicy: Local`: Traffic routes strictly to Pods running on the node receiving the connection, preserving client source IPs (connections drop if no local Pod exists on the target node).

```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
```

- `sessionAffinity: ClientIP`: Routes requests from specific client IPs to the same Pod instance (`None` is default round-robin routing).

```yaml
spec:
  sessionAffinity: ClientIP
```

---

## kube-proxy Routing Modes

`kube-proxy` monitors API server objects and translates Services/Endpoints into local host network rules across modes:

- **iptables**: Random `DNAT` selection per Service.
- **IPVS**: Uses kernel `IPVS` load balancing, supporting algorithms like round-robin or least connection.

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```

---

## Diagnostic Commands

```bash
kubectl get svc -A
kubectl describe svc <name>
kubectl get endpoints <name>
kubectl get endpointslices
kubectl run tmp --rm -it --image=busybox -- wget -qO- http://<svc-name>:<port>
kubectl get pods -o wide --selector=app=web
```

---

## References

- Service Overview: https://kubernetes.io/docs/concepts/services-networking/service/
- Connecting Applications with Services: https://kubernetes.io/docs/tutorials/services/connect-applications-service/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Service Traffic Policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- kube-proxy Reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
