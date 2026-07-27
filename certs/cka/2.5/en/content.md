# 2.5 Troubleshoot Services and Networking

## Introduction

Networking troubleshooting carries significant weight on the CKA exam because it requires isolating failures across multiple abstraction layers: the Kubernetes network model, `kube-proxy`, CoreDNS, the active CNI plugin, and Linux kernel datapath rules (`iptables` / IPVS). Rather than relying on a single command, network troubleshooting requires systematic layer-by-layer elimination.

The Kubernetes network model mandates three fundamental rules:
- Every Pod can communicate with every other Pod without NAT (enforced by the CNI plugin).
- Every Node can communicate with every Pod without NAT.
- The IP a Pod sees as its own address matches the IP other entities see for it.

When network connectivity fails, isolate issues in this sequence: **Pod → Service → Endpoints → kube-proxy → CNI → DNS → NetworkPolicy → Ingress**.

---

## 1. General Troubleshooting Methodology

Standard diagnostic workflow when backend connectivity fails:

1. Is the Pod reporting `Running` and `Ready` statuses? (`kubectl get pods -o wide`)
2. Is the container process listening on expected ports? (`kubectl exec -- ss -tlnp` or `netstat -tlnp`)
3. Does the Service populate target Endpoints? (`kubectl get endpoints <svc>`)
4. Do Service `selector` keys match Pod `labels` exactly?
5. Has `kube-proxy` generated corresponding kernel datapath rules? (`iptables-save` / `ipvsadm -Ln`)
6. Does a active `NetworkPolicy` restrict traffic flow?
7. Does CoreDNS resolve the target Service DNS hostname? (`nslookup` or `dig` from a debug Pod)
8. Is the CNI plugin operational across all nodes? (`kubectl get pods -n kube-system`, check Pod CIDR assignments)

Recommended diagnostic debug Pod (includes networking utilities omitted from `distroless`/`scratch` images):

```bash
kubectl run tmp-shell --rm -it --image=nicolaka/netshoot -- sh
```

Or attach ephemeral debug containers directly to active Pods:

```bash
kubectl debug -it pod/mypod --image=nicolaka/netshoot --target=mypod -- sh
```

---

## 2. Service Troubleshooting

### 2.1 Inspecting Endpoints

The most frequent cause of Service connectivity failures is mismatched label selectors or unready Pods (unready Pods are excluded from Service Endpoints).

```bash
kubectl get svc web
```
```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.45.12    <none>        80/TCP    5m
```

```bash
kubectl get endpoints web
```
```
NAME   ENDPOINTS   AGE
web    <none>      5m
```

An empty `<none>` in `ENDPOINTS` signals that the Service lacks active backends. Typical root causes:

- Mismatched `selector` definitions:
```bash
kubectl get svc web -o jsonpath='{.spec.selector}'
```
```
{"app":"web"}
```
```bash
kubectl get pods --show-labels
```
```
NAME        READY   STATUS    LABELS
web-6d9f8   1/1     Running   app=webapp
```
The Service searches for `app=web` while Pod labels report `app=webapp` (label mismatch).

- Pods fail `readinessProbe` checks (only Pods reporting `Ready` enter Endpoints lists, unless `publishNotReadyAddresses: true` is configured):
```bash
kubectl describe pod web-6d9f8 | grep -A5 Readiness
```
```
Readiness probe failed: Get "http://10.244.1.5:8080/healthz": connection refused
```

- Mismatched `targetPort` configurations vs container listening ports:
```bash
kubectl get svc web -o jsonpath='{.spec.ports[0].targetPort}'
```
Compare configured `targetPort` values against process listening sockets inside container environments (`ss -tlnp`).

### 2.2 EndpointSlices

Since Kubernetes 1.21+, Service backends are tracked via `EndpointSlices`. Inspecting EndpointSlices directly provides detailed endpoint readiness states:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpointslices web-x7k2p -o yaml
```
```yaml
endpoints:
- addresses: ["10.244.1.5"]
  conditions:
    ready: true
    serving: true
    terminating: false
```

### 2.3 Service Types and Typical Failures

| Type | Failure Scenario | Diagnostic Command |
|---|---|---|
| ClusterIP | Mismatched selector, missing Endpoints | `kubectl get endpoints` |
| NodePort | Host node firewall blocks port range 30000–32767 | `iptables -L`, `curl <nodeIP>:<nodePort>` |
| LoadBalancer | `EXTERNAL-IP` stuck in `<pending>` state due to missing cloud-controller-manager | `kubectl describe svc` (Events section) |
| ExternalName | DNS lookup failure due to invalid target CNAME record | `nslookup` from inside cluster |
| Headless (`clusterIP: None`) | Client expects single IP but receives multiple A-records | Inspect `dig` output (expected headless behavior) |

Example showing an unfulfilled `LoadBalancer` Service on bare-metal environments lacking load balancer controllers (e.g. MetalLB):

```bash
kubectl get svc frontend
```
```
NAME       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
frontend   LoadBalancer   10.96.88.20   <pending>     80:31840/TCP   2m
```

In the absence of a cloud controller, access can be validated using the assigned NodePort (`31840` in this instance).

### 2.4 Validating Direct Pod Connectivity (Bypassing Services)

To isolate whether failures stem from Service configurations or Pod containers:

```bash
kubectl get pod web-6d9f8 -o jsonpath='{.status.podIP}'
# 10.244.1.5
kubectl run tmp --rm -it --image=busybox -- wget -qO- http://10.244.1.5:8080
```

If direct Pod IP access succeeds while Service IP requests fail, isolate selector, Endpoint, or `kube-proxy` configurations.

---

## 3. kube-proxy

`kube-proxy` translates Service and Endpoint objects into kernel datapath rules. It executes as a `DaemonSet` inside `kube-system`.

```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
kubectl logs -n kube-system kube-proxy-abcde
```

### 3.1 iptables Mode

Verify that kernel rules exist for the target ClusterIP (`10.96.45.12:80`):

```bash
iptables-save | grep 10.96.45.12
```
```
-A KUBE-SERVICES -d 10.96.45.12/32 -p tcp -m tcp --dport 80 -j KUBE-SVC-XPGD46QRK7WJZT7O
-A KUBE-SVC-XPGD46QRK7WJZT7O -j KUBE-SEP-57KPRZ3JQVENLNBR
-A KUBE-SEP-57KPRZ3JQVENLNBR -p tcp -m tcp -j DNAT --to-destination 10.244.1.5:8080
```

If matching rule chains are missing, `kube-proxy` has failed to process the Service object (inspect `kube-proxy` logs or verify cluster CIDR settings).

### 3.2 IPVS Mode

```bash
ipvsadm -Ln
```
```
TCP  10.96.45.12:80 rr
  -> 10.244.1.5:8080              Masq    1      0          0
```

Confirm active proxy mode:

```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```
```
mode: "ipvs"
```

### 3.3 Common kube-proxy Failure Scenarios

- Outdated `kube-proxy` ConfigMap configurations following `--cluster-cidr` modifications: restart the DaemonSet.
- `kube-proxy` pod crashes or missing instances on worker nodes → Pods on affected nodes fail to route traffic to ClusterIP Services.
- Host firewall rules (`firewalld`, `ufw`) interfering with `KUBE-*` chains on Linux nodes.

---

## 4. DNS Troubleshooting (CoreDNS)

### 4.1 Inspecting CoreDNS Pods and Services

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get svc -n kube-system kube-dns
```
```
NAME       TYPE        CLUSTER-IP   PORT(S)
kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

### 4.2 Testing DNS Resolution from Pod Environments

```bash
kubectl run dnsutils --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.39 -- /bin/sh
nslookup web.default.svc.cluster.local
```
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web.default.svc.cluster.local
Address:   10.96.45.12
```

If resolution fails:
```
;; connection timed out; no servers could be reached
```

Typical causes:
- Misconfigured container `/etc/resolv.conf` (verify Pod `dnsPolicy`).
```bash
kubectl exec dnsutils -- cat /etc/resolv.conf
```
```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```
- CoreDNS Pod outages or `CrashLoopBackOff` states — inspect logs:
```bash
kubectl logs -n kube-system -l k8s-app=kube-dns
```
- Active NetworkPolicies blocking UDP/TCP port 53 traffic toward `kube-system`.
- Circular DNS loops detected by CoreDNS `loop` plugin (occurs when host node `/etc/resolv.conf` targets `127.0.0.1` via `systemd-resolved` without valid upstream forwarding):
```
[FATAL] plugin/loop: Loop (127.0.0.1:53 -> 127.0.0.1:53) detected for zone ".", see https://coredns.io/plugins/loop#troubleshooting
```
Resolution: Update kubelet `--resolv-conf` arguments or modify the `coredns` ConfigMap to prevent loopback upstream forwarding.

### 4.3 Inspecting Corefile Configurations

```bash
kubectl get configmap coredns -n kube-system -o yaml
```
```yaml
Corefile: |
  .:53 {
      errors
      health
      ready
      kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
      }
      forward . /etc/resolv.conf
      cache 30
      loop
      reload
  }
```

Updating `Corefile` configurations requires triggering a deployment rollout to apply changes:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

---

## 5. CNI Plugin Troubleshooting

### 5.1 Verifying Active CNI Plugins

```bash
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|flannel|cilium|weave'
```

Pods remaining in `ContainerCreating` states with network setup errors indicate CNI plugin failures:

```bash
kubectl describe pod web-6d9f8
```
```
Warning  FailedCreatePodSandBox  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "abc123": plugin type="calico" failed (add): error getting ClusterInformation: Get "https://10.96.0.1:443/apis/...": dial tcp 10.96.0.1:443: i/o timeout
```

This error signals that the CNI plugin cannot reach API server endpoints — verify `kubernetes` Service endpoints in `default` namespace and node-to-apiserver connectivity.

### 5.2 Inspecting Host Node CNI Files

```bash
ls /etc/cni/net.d/
cat /etc/cni/net.d/10-calico.conflist
```

Empty CNI configuration directories or conflicting configuration files prevent kubelet from initializing pod networking interfaces.

### 5.3 Validating Pod CIDR Allocations

```bash
kubectl cluster-info dump | grep -m1 cluster-cidr
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

If node `podCIDR` fields report empty strings (`""`), CNI plugins cannot allocate Pod subnets — typically occurring when controller managers start without `--allocate-node-cidrs=true` or missing `--cluster-cidr` parameters.

### 5.4 Validating Container Network Interfaces

```bash
kubectl exec web-6d9f8 -- ip addr
```
```
3: eth0@if15: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
    inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0
```

Mismatched MTU settings (e.g. VXLAN overlay networks using 1500 instead of 1450 MTU) trigger packet fragmentation and intermittent timeouts on large payloads, while small `ping` packets succeed.

### 5.5 Cross-Node Connectivity Failures

If Pod-to-Pod traffic succeeds on the same node but fails across different nodes:

```bash
# Check host node routing tables for remote Pod CIDRs
ip route | grep 10.244
```
```
10.244.0.0/24 via 192.168.1.10 dev eth0
10.244.2.0/24 via 192.168.1.12 dev eth0
```

Missing routes or host firewalls blocking encapsulation protocols (UDP 8472 for VXLAN, or IP protocol 4 for Calico IP-in-IP) sever cross-node pod communication.

---

## 6. NetworkPolicy Troubleshooting

NetworkPolicies require underlying CNI driver enforcement support (e.g. Calico, Cilium).

```bash
kubectl get networkpolicy -A
kubectl describe networkpolicy deny-all -n prod
```

Example policy restricting ingress traffic to specific matching namespaces:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
  namespace: backend
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
    ports:
    - protocol: TCP
      port: 8080
```

Common NetworkPolicy pitfalls:
- Selecting a Pod with any `NetworkPolicy` enables **implicit default-deny** isolation for unallowed traffic types.
- Target namespaces lacking required labels (`kubernetes.io/metadata.name` label is auto-populated in 1.21+):
```bash
kubectl get ns frontend --show-labels
```
- Testing connectivity using `kubectl exec` to confirm expected block behavior:
```bash
kubectl exec -n frontend testpod -- curl -m2 http://api.backend.svc.cluster.local:8080
```
```
curl: (28) Connection timed out after 2000 milliseconds
```

---

## 7. Ingress Troubleshooting

```bash
kubectl get ingress -A
kubectl describe ingress web-ingress
```

Common failure scenarios:
- `ingressClassName` does not match installed IngressClass resources:
```bash
kubectl get ingressclass
```
If Ingress manifests declare `ingressClassName: nginx-internal` while no matching IngressClass exists, ingress controllers silently ignore the resource.

- Referencing non-existent backend Services or invalid port specifications:
```bash
kubectl describe ingress web-ingress
```
```
Warning  BadConfig  ingress-nginx-controller  Service "web" not found
```

- Inspecting Ingress Controller logs when requests return 502/504 status codes:
```bash
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | tail -50
```

---

## 8. Diagnostic System Network Commands

Useful from debug container environments (`netshoot`) or host nodes (`kubectl debug node/<node> -it --image=busybox`):

```bash
ss -tlnp                 # Listening sockets
curl -v telnet://<ip>:<port>
nc -zv <ip> <port>        # TCP port connectivity test
tcpdump -i eth0 port 8080 -w /tmp/cap.pcap
traceroute <ip>
```

Testing TCP ports via `nc`:

```bash
nc -zv 10.244.1.5 8080
```
```
10.244.1.5 (10.244.1.5:8080) open
```

vs.

```
nc: connect to 10.244.1.5 port 8080 (tcp) failed: Connection refused
```

`Connection refused` indicates no process is listening on the target port (container app crash or invalid `targetPort` mapping). `Connection timed out` indicates packet drops (CNI, NetworkPolicy, or host firewall issues).

---

## 9. Troubleshooting Decision Tree Summary

```
Does `kubectl get endpoints <svc>` report `<none>`?
 ├── Yes → Inspect Service selectors, Pod labels, and readinessProbes
 └── No  → Does direct curl to Pod IP succeed?
           ├── No  → Isolate CNI / Pod network layer (check CNI pods, routes, MTU)
           └── Yes → Does curl to ClusterIP succeed from host node?
                     ├── No  → Troubleshoot kube-proxy (iptables / ipvsadm)
                     └── Yes → Does failure occur exclusively on DNS names?
                              ├── Yes → Troubleshoot CoreDNS
                              └── No  → Inspect NetworkPolicies / Ingress rules
```

---

## References

- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Service Overview: https://kubernetes.io/docs/concepts/services-networking/service/
- Ingress Overview: https://kubernetes.io/docs/concepts/services-networking/ingress/
- kube-proxy Reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Debug Running Pods (`kubectl debug`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- CoreDNS Loop Plugin Troubleshooting: https://coredns.io/plugins/loop/#troubleshooting
- Cluster Networking: https://kubernetes.io/docs/concepts/cluster-administration/networking/
