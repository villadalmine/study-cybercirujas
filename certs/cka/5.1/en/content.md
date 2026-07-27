# 5.1 Understand connectivity between Pods

## The Kubernetes Network Model

Kubernetes establishes a straightforward networking specification with profound architectural implications. Core requirements of the **Kubernetes networking model**:

- **Every Pod can communicate with every other Pod without NAT**, regardless of node placement across host boundaries.
- **Every Node can communicate with every Pod without NAT** (and vice versa).
- **The IP a Pod observes for itself matches the IP other entities see for it** (no intra-cluster address translation).

Unlike legacy Docker network models (where each host node runs isolated NAT networks), Kubernetes enforces a **flat cluster network space**: every Pod receives a unique, routable cluster IP address valid for communicating with any other Pod throughout the cluster topology.

Kubernetes **does not implement this network model directly**; responsibility is delegated to container network driver plugins adhering to the **Container Network Interface (CNI)** specification.

---

## CNI (Container Network Interface)

CNI is a standard specification and library suite defining how container runtimes (via `kubelet`) invoke network plugins to:

1. Create network interfaces inside container network namespaces.
2. Assign IP addresses (via IPAM — IP Address Management drivers).
3. Configure host routing tables so assigned IPs remain accessible across cluster nodes.

Common CNI plugins:

- **Calico** (BGP native routing, or overlay VXLAN/IPIP modes)
- **Flannel** (Lightweight VXLAN overlay network)
- **Cilium** (eBPF-driven networking with L3–L7 security controls)
- **Weave Net**

CNI configurations reside in `/etc/cni/net.d/` on each node, with plugin binaries installed under `/opt/cni/bin/`.

```bash
# View active node CNI configurations
cat /etc/cni/net.d/10-calico.conflist

# List available CNI plugin binaries
ls /opt/cni/bin/
```

---

## Intra-Node Communication (Same Host Node)

When two Pods execute on the same host node, communication flows as follows:

1. Each Pod operates inside its own isolated **network namespace**, exposing a virtual `eth0` interface.
2. The `eth0` interface represents one end of a **veth pair** (virtual ethernet pair); the corresponding end resides in the **host** node network namespace.
3. The host-side veth interface attaches to a local **network bridge** (e.g. `cni0` or `flannel.1`).
4. Traffic between Pods on the same host node traverses the local bridge directly, functioning like isolated hosts connected to an L2 Ethernet switch.

```bash
# Inspect host bridge interface
ip addr show cni0

# Inspect container network namespace details
crictl inspect <container-id> | grep -A5 network
```

---

## Inter-Node Communication (Cross-Host Nodes)

When Pods run on separate host nodes, CNI plugins route packets from source Pod IPs on Node A to destination Pod IPs on Node B across physical network infrastructure. Typical routing mechanisms:

- **Overlay Networks** (e.g. Flannel VXLAN, Calico IPIP/VXLAN): Pod traffic is encapsulated inside UDP/IP packets sent between host node IPs. Host daemons decapsulate packets upon arrival and deliver raw payloads to target Pod interfaces. Works across arbitrary physical networks without router changes, but introduces minor packet encapsulation overhead.
- **Native Routing** (e.g. Calico BGP mode): Host nodes advertise assigned Pod subnets directly to physical routers using BGP, eliminating encapsulation overhead. Requires underlying network infrastructure support.

In both modes, Kubernetes assigns each node a non-overlapping **PodCIDR** subnet allocation:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.podCIDR}{"\n"}{end}'
# node-1: 10.244.0.0/24
# node-2: 10.244.1.0/24
```

---

## Verifying Pod-to-Pod Connectivity

Testing direct Pod IP communication bypassing Service and CoreDNS layers:

```bash
kubectl run pod-a --image=nicolaka/netshoot --command -- sleep 3600
kubectl run pod-b --image=nginx

kubectl get pods -o wide
# NAME     READY   STATUS    IP            NODE
# pod-a    1/1     Running   10.244.1.5    node-1
# pod-b    1/1     Running   10.244.2.8    node-2
```

Test direct IP connectivity:

```bash
kubectl exec -it pod-a -- curl -s 10.244.2.8:80 | head -1
# <!DOCTYPE html>

kubectl exec -it pod-a -- ping -c 2 10.244.2.8
```

Inspect container routing tables:

```bash
kubectl exec -it pod-a -- ip route
# default via 10.244.1.1 dev eth0
# 10.244.1.0/24 dev eth0 proto kernel scope link
```

---

## Pod DNS Resolution

**CoreDNS** registers A records for individual Pods (useful for headless Services or auto-generated dash-formatted Pod names):

```bash
# Format: <hyphenated-pod-ip>.<namespace>.pod.cluster.local
kubectl exec -it pod-a -- nslookup 10-244-2-8.default.pod.cluster.local
```

Direct IP connectivity forms the foundation for Kubernetes Services, DNS resolution, and Ingress routing.

---

## Connectivity Troubleshooting Checklist

Diagnostic steps when Pod-to-Pod communication fails:

```bash
# 1. Confirm Pods report Running status with assigned IPs
kubectl get pods -o wide

# 2. Check CNI daemonset Pod status across nodes
kubectl -n kube-system get pods -o wide | grep -E 'calico|flannel|cilium'

# 3. Inspect CNI driver logs on target host nodes
kubectl -n kube-system logs <calico-node-xxxx>

# 4. Verify node PodCIDR assignments
kubectl describe node <node-name> | grep PodCIDR

# 5. Check active NetworkPolicies restricting traffic
kubectl get networkpolicy -A

# 6. Test node-to-node host IP connectivity
ssh node-1 -- ping -c2 <ip-node-2>
```

Common failure scenarios: Inactive `cni0`/`flannel.1` bridge interfaces post-reboot, mismatched controller-manager `--cluster-cidr` flags, or missing CNI plugins leaving Pods stuck in `ContainerCreating` states.

---

## References

- Cluster Networking: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- The Kubernetes Network Model: https://kubernetes.io/docs/concepts/services-networking/#the-kubernetes-network-model
- Container Network Interface (CNI) spec: https://github.com/containernetworking/cni
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
