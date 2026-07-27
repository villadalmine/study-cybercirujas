# 5.6 CoreDNS in Kubernetes

## What is CoreDNS?

CoreDNS is the default cluster DNS server in Kubernetes (since v1.13, replacing `kube-dns`) providing in-cluster **service discovery**. CoreDNS is a CNCF graduated project written in Go with an architecture based on a chain of modular **plugins**: every incoming DNS query passes through a configurable sequence of plugin middlewares that resolve, cache, rewrite, or forward requests.

In standard clusters, CoreDNS executes as a `Deployment` inside namespace `kube-system`, exposed internally via a `ClusterIP` `Service` named `kube-dns` (retained for backwards compatibility).

```bash
kubectl -n kube-system get deployment coredns
kubectl -n kube-system get svc kube-dns
```

```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           10d

NAME       TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10    <none>        53/UDP,53/TCP,9153/TCP   10d
```

Every Pod receives the `kube-dns` ClusterIP address as its primary `nameserver` in `/etc/resolv.conf`, configured automatically by `kubelet`.

---

## Architecture and Corefile

CoreDNS deploys with 2 replicas for high availability using pod anti-affinity. Its configuration resides in a `ConfigMap` named `coredns` in namespace `kube-system`, mounted into Pods as `/etc/coredns/Corefile`.

```bash
kubectl -n kube-system get configmap coredns -o yaml
```

Example Corefile layout:

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

Key plugins:

| Plugin | Function |
|---|---|
| `kubernetes` | Resolves DNS records for Services and Pods querying API server objects |
| `forward` | Forwards external queries outside the cluster domain to node upstream DNS (`/etc/resolv.conf`) |
| `cache` | Caches responses for specified TTL durations to reduce API server load |
| `loop` | Detects forwarding loops and aborts execution when infinite loops occur |
| `reload` | Automatically reloads Corefile configuration changes without Pod restarts |
| `loadbalance` | Applies round-robin distribution across A/AAAA record sets |

Update cluster DNS behavior by editing the ConfigMap:

```bash
kubectl -n kube-system edit configmap coredns
kubectl -n kube-system rollout restart deployment coredns
```

---

## DNS Naming Conventions

### Service Domain Names

```
<service-name>.<namespace>.svc.cluster.local
```

- **ClusterIP Services**: Return **A/AAAA** records pointing to virtual ClusterIPs.
- **Headless Services** (`clusterIP: None`): Return **A/AAAA** records for each matching backend Pod IP.
- **ExternalName Services**: Return **CNAME** records targeting `externalName` values.

### Pod Domain Names

```
<hyphenated-pod-ip>.<namespace>.pod.cluster.local
```

Example: Pod IP `10.244.1.5` in namespace `default` resolves to `10-244-1-5.default.pod.cluster.local`.

---

## Pod `/etc/resolv.conf` & `dnsPolicy`

```bash
kubectl exec test-pod -- cat /etc/resolv.conf
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` forces queries with fewer than 5 dots to iterate through `search` domain suffixes prior to absolute FQDN resolution.

### `dnsPolicy` Options

- `ClusterFirst` (default): Routes queries through CoreDNS.
- `Default`: Inherits host node `/etc/resolv.conf` configuration bypassing CoreDNS.
- `ClusterFirstWithHostNet`: Used for Pods running with `hostNetwork: true`.
- `None`: Ignores automatic configurations; requires explicit `dnsConfig`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-dns
spec:
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 1.1.1.1
    searches:
      - custom.svc.cluster.local
    options:
      - name: ndots
        value: "2"
  containers:
    - name: app
      image: busybox:1.28
      command: ["sleep", "3600"]
```

---

## CoreDNS Troubleshooting Checklist

```bash
# 1. Verify CoreDNS Pod health
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide

# 2. Check CoreDNS log streams for SERVFAIL or forwarding loops
kubectl -n kube-system logs -l k8s-app=kube-dns

# 3. Verify kube-dns Endpoints contain active Pod IPs
kubectl -n kube-system get endpoints kube-dns

# 4. Test DNS resolution using test Pods
kubectl run -it --rm dns-test --image=busybox:1.28 --restart=Never -- \
  nslookup kubernetes.default
```

Common causes of DNS failure: `CrashLoopBackOff` triggered by Corefile syntax errors, empty `kube-dns` Endpoints due to CNI issues, or NetworkPolicies blocking UDP/TCP port 53.

---

## References

- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Customizing DNS Service (CoreDNS): https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
