# 3.4 Networking

## The Kubernetes Networking Model

Kubernetes requires that any network implementation satisfy three fundamental rules (the "Kubernetes networking model"):

1. All Pods can communicate with all other Pods without NAT, regardless of which Node they are on.
2. All Nodes can communicate with all Pods without NAT.
3. The IP that a Pod sees of itself is the same IP that others see.

This creates a "flat" network: each Pod receives its own unique IP within the cluster (unlike standalone Docker, where containers on the same host share a network namespace via NAT). Within a Pod, all containers share the same network namespace (same IP, same port space) thanks to the **pause container** (or "infra container"), which is created first and holds the network namespace for the rest.

Kubernetes itself **does not implement** this network: it delegates the task to a **CNI (Container Network Interface)** plugin.

## CNI (Container Network Interface)

CNI is a specification (from the CNCF) that defines how a container runtime should invoke network plugins to assign IPs and connect containers to the network. The kubelet invokes the configured CNI plugin each time a Pod is created or destroyed.

Common CNI plugins:

- **Calico**: L3 routing, supports advanced NetworkPolicies, BGP.
- **Flannel**: simple, overlay with VXLAN, focuses on basic connectivity (does not implement NetworkPolicy).
- **Cilium**: based on **eBPF**, high performance, observability and L3-L7 NetworkPolicy.
- **Weave Net**: overlay with optional encryption.

Check the installed CNI in a cluster:

```
$ kubectl get pods -n kube-system | grep -E 'calico|flannel|cilium|weave'
calico-node-4x2vp                         1/1     Running   0          10d
calico-kube-controllers-6f9c...           1/1     Running   0          10d
```

The plugin configuration usually lives in `/etc/cni/net.d/` on each Node.

## Pod-to-Pod Communication and Service Discovery

Since Pod IPs are ephemeral (they change when the Pod is recreated), they are not used directly for stable communication between components. For that, the **Service** object exists.

A Service is an abstraction that defines a logical set of Pods (via a `selector` with labels) and an access policy, exposing a stable virtual IP (**ClusterIP**) that routes traffic to the "backend" Pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 8080
```

```
$ kubectl get svc web-svc
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.45.210   <none>        80/TCP    2m

$ kubectl get endpoints web-svc
NAME      ENDPOINTS                       AGE
web-svc   10.244.1.5:8080,10.244.2.7:8080   2m
```

The **Endpoints** object (or **EndpointSlice** in recent versions, more scalable) maintains the updated list of Pod IPs that match the selector.

### Service Types

| Type | Usage |
|---|---|
| **ClusterIP** (default) | Internal IP, only accessible within the cluster. |
| **NodePort** | Exposes a port (30000-32767) on every Node, forwarding to the Service. |
| **LoadBalancer** | Provisions an external load balancer (via cloud provider) that points to the Service. |
| **ExternalName** | Maps the Service to an external DNS name (CNAME record), no traffic proxy. |

Example of NodePort:

```
$ kubectl get svc web-svc
NAME      TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-svc   NodePort   10.96.45.210   <none>        80:30080/TCP   1m
```

Any Node in the cluster now exposes port `30080` to the Service.

There are also **Headless Services** (`clusterIP: None`), which do not assign a virtual IP: DNS resolution returns the Pod IPs directly. They are often used with StatefulSets, where each Pod needs its own network identity.

## kube-proxy

**kube-proxy** runs as a DaemonSet on each Node and is the component responsible for implementing the Service's virtual IP, programming rules to redirect traffic destined to the ClusterIP to one of the backend Pods (basic round‑robin/random load balancing).

Modes of operation:

- **iptables** (historical default): uses `iptables` rules in the Linux kernel to DNAT the ClusterIP to a Pod IP.
- **IPVS** (IP Virtual Server): uses the kernel's load balancing subsystem, more efficient in clusters with thousands of Services (avoids the O(n) cost of traversing iptables rules).
- **userspace** (legacy mode, deprecated).

```
$ iptables -t nat -L KUBE-SERVICES -n | grep web-svc
KUBE-SVC-XYZ123  tcp  --  0.0.0.0/0   10.96.45.210   /* default/web-svc */ tcp dpt:80
```

## DNS in Kubernetes

**CoreDNS** is the standard DNS server of the cluster (runs as a Deployment in `kube-system`) and provides name resolution for Services and Pods.

Each Service gets a DNS name in the format:

```
<service-name>.<namespace>.svc.cluster.local
```

```
$ kubectl run tmp --rm -it --image=busybox -- sh
/ # nslookup web-svc.default.svc.cluster.local
Server:    10.96.0.10
Name:      web-svc.default.svc.cluster.local
Address:   10.96.45.210
```

Each Pod's resolver is automatically configured via `/etc/resolv.conf`, pointing to the CoreDNS ClusterIP (typically `10.96.0.10` or similar, exposed by the `kube-dns` Service).

## Ingress and Ingress Controller

A **Service** of type LoadBalancer provisions one load balancer per Service (expensive in the cloud). To expose multiple HTTP/HTTPS services under a single external IP, with routing by host/path, **Ingress** is used.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
spec:
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

The Ingress object is only a **rule specification**; it requires an **Ingress Controller** (NGINX Ingress Controller, Traefik, HAProxy, Contour, etc.) running in the cluster that actually implements the routing (Kubernetes does not ship one by default).

```
$ kubectl get ingress web-ingress
NAME           CLASS   HOSTS             ADDRESS         PORTS   AGE
web-ingress    nginx   app.example.com   203.0.113.10    80      5m
```

> Note: the modern API successor to Ingress is the **Gateway API** (`gateway.networking.k8s.io`), which separates roles (infrastructure vs. application routes) and supports more protocols besides HTTP.

## NetworkPolicy

By default, traffic between Pods is fully allowed ("allow all"). **NetworkPolicy** allows restricting ingress/egress traffic at the Pod level, acting as a declarative firewall (requires that the CNI supports it: Calico, Cilium, Weave do; pure Flannel does not).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-only
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

This policy allows inbound traffic only to Pods with label `app: backend` on port 8080, and only from Pods with label `app: frontend`. Any other source is blocked.

## Service Mesh (Conceptual Mention)

A **Service Mesh** (e.g. **Istio**, **Linkerd**) adds an application‑layer network between Pods, typically by injecting a **sidecar proxy** (e.g. Envoy) into each Pod to handle mTLS, retries, circuit breaking, observability (metrics/tracing) and traffic shifting (canary, blue‑green), without changing application code. KCNA does not require configuring it, only recognizing the concept and its purpose within the cloud native architecture.

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs, *Cluster Networking*: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes docs, *Service*: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes docs, *Ingress*: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes docs, *Ingress Controllers*: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes docs, *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs, *DNS for Services and Pods*: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- CNI project: https://github.com/containernetworking/cni
- Kubernetes docs, *Gateway API*: https://gateway-api.sigs.k8s.io/
- Istio docs: https://istio.io/latest/docs/concepts/what-is-istio/