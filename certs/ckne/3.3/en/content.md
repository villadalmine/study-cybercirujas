# 3.3 Configuring Egress Gateways for Cluster Exit Traffic

> **Exam weight: 5%.** This objective is about controlling **how** traffic leaves the cluster, **with which source IP**, and **through which chokepoint**. The CKNE curriculum is new, and the Linux Foundation page does not name one implementation. Learn the model that all egress gateways share. Then practice the two implementations you are most likely to be handed: the **Cilium Egress Gateway** (L3/L4, CNI level) and the **Istio egress gateway** (L7, mesh level). Also know the equivalent CRDs in Antrea and OVN-Kubernetes.

---

## 1. Motivation: the production problem

### 1.1 What happens to egress traffic by default

A Pod sends a packet to `203.0.113.50:443`, outside the cluster. In almost every CNI's default configuration, this happens:

1. The packet leaves the Pod's network namespace with `src = <PodIP>` (for example `10.0.3.17`).
2. It reaches the host network stack of the node where the Pod runs (or the CNI's eBPF datapath).
3. The destination is outside the Pod CIDR and the cluster CIDR, so the CNI applies **SNAT/masquerade** to the IP of the **node's egress interface**.
4. The external server sees `src = <NodeIP>`, where NodeIP is whichever node the scheduler chose for that Pod.

```
 Pod (10.0.3.17) ── node-7 ──[SNAT → 192.168.10.27]──► Internet / partner API
 Pod (10.0.5.44) ── node-2 ──[SNAT → 192.168.10.22]──► Internet / partner API
```

The source IP is therefore **a function of scheduling**. It changes when a Pod is rescheduled, when a node is replaced by the cluster-autoscaler, or when a node pool is rotated.

### 1.2 Why this breaks in production

| Real-world requirement | Why the default behavior fails |
|---|---|
| A partner API or legacy database allows only a **list of source IPs** | You would have to allow every current and future node IP. The autoscaler makes that list unbounded. |
| Corporate firewall with per-application rules | All Pods on a node share one IP, so the firewall cannot tell `payments` from `batch`. |
| Audit and compliance (PCI-DSS, SOC 2): "all traffic to the card processor leaves through a controlled point" | Traffic leaves from N nodes, and no single component sees it all. |
| Data-exfiltration control | Any compromised Pod can open connections to any destination. |
| Cloud NAT gateway with per-IP port limits (SNAT port exhaustion) | Without distribution or dedicated IPs, a noisy workload exhausts ports for everyone. |
| TLS origination / mTLS toward external services with a client certificate | Each application would have to manage the certificate itself. |

### 1.3 The architectural pattern

An **egress gateway** introduces a **deterministic exit point**:

```
                        ┌─────────────────────────────┐
 Pod A (node-7) ──┐     │  Gateway node(s)            │
                  ├────►│  SNAT → 198.51.100.10 (fixed)│────► Partner API
 Pod B (node-2) ──┘     │  (+ optional: L7 policy,     │      (allowlist: 198.51.100.10)
                        │   logs, TLS origination)     │
                        └─────────────────────────────┘
 Pod C (not selected) ── node-2 ── SNAT → NodeIP ────────────► Internet (default behavior)
```

There are two families, and they solve **different problems**:

- **Network-level egress gateway (CNI):** it redirects packets selected by `(podSelector, destinationCIDR)` to a gateway node, which masquerades them with a **specific egress IP**. It operates at L3/L4, does not inspect content, and adds no proxy. Examples: Cilium `CiliumEgressGatewayPolicy`, Antrea `Egress`, OVN-Kubernetes `EgressIP`, and the Calico Enterprise egress gateway.
- **Application-level egress gateway (service mesh):** a dedicated Envoy proxy through which traffic to external hosts is **routed** via mesh configuration. It provides L7 routing, SNI/Host-based policy, access logs, TLS origination and mTLS inside the mesh. Examples: the Istio egress gateway, and Gateway API–based egress in some meshes.

> **Key point for the exam and for production:** a mesh egress gateway **does not guarantee a stable source IP** by itself, because the gateway Pod still leaves through the IP of the node it runs on. A CNI egress gateway **does not give you L7 visibility or policy**. In regulated environments the two are **combined**.

---

## 2. Comparison of implementations

### 2.1 Capability matrix

| Implementation | API / CRD | Layer | Stable IP | Built-in HA of the egress IP | Traffic selection | Notes |
|---|---|---|---|---|---|---|
| **Cilium Egress Gateway** (OSS) | `cilium.io/v2` `CiliumEgressGatewayPolicy` | L3/L4 (eBPF) | Yes (`egressIP` or the IP of an `interface`) | **No** in OSS: if the gateway node falls, the policy falls back to another node that matches the `nodeSelector` (if one exists), but the IP must also exist there | podSelector / namespaceSelector + `destinationCIDRs` / `excludedCIDRs` | Requires `bpf.masquerade=true` and kube-proxy replacement; does not manage the IP on the interface |
| **Antrea Egress** | `crd.antrea.io/v1beta1` `Egress` + `ExternalIPPool` | L3/L4 (OVS) | Yes | **Yes**: the IP moves between the pool's nodes (memberlist) and Antrea assigns it to the interface | `appliedTo` (namespace/pod selector) | Can also apply bandwidth limits per Egress |
| **OVN-Kubernetes EgressIP** | `k8s.ovn.org/v1` `EgressIP` | L3 (OVN) | Yes | Yes: reassigns among nodes labeled `k8s.ovn.org/egress-assignable` | namespaceSelector + podSelector | The standard in OpenShift |
| **Calico** OSS | `IPPool.natOutgoing` | L3 | Not per workload | — | Per IP pool | Dedicated Egress Gateways exist only in Calico Enterprise/Cloud |
| **Istio egress gateway** | `Gateway`, `VirtualService`, `DestinationRule`, `ServiceEntry` (`networking.istio.io/v1`) | L4/L7 (Envoy) | Only if gateway Pods are pinned to nodes with known IPs, or combined with a CNI egress IP | HA of the Deployment (replicas, HPA) | Destination host (SNI/Host), namespace via `exportTo`/Sidecar | Bypassable without a NetworkPolicy |
| **Kubernetes NetworkPolicy** (egress) | `networking.k8s.io/v1` | L3/L4 | No | — | podSelector + ipBlock/ports | Not a gateway: it only **allows or denies**. It is the complement that closes the bypass. |

### 2.2 Architectural trade-offs

| Dimension | CNI egress gateway | Mesh egress gateway |
|---|---|---|
| Latency | One extra hop to the gateway node (tunnel or native routing), with no L7 proxy | An extra hop plus Envoy processing (the sidecar and the gateway both terminate/inspect) |
| Throughput | Close to line rate; the limit is the gateway node's NIC and conntrack | Limited by the gateway's Envoy CPU; must scale horizontally |
| Protocols | Any IP protocol (TCP, UDP, ICMP, depending on implementation) | TCP/HTTP/TLS; UDP generally not |
| Destination granularity | CIDR. Ineffective for SaaS with rotating IPs (for example, APIs behind a CDN) | FQDN/SNI. Well suited to SaaS |
| Security | Selection by Pod labels; the Pod **cannot** escape it because the datapath enforces it | A Pod without a sidecar, or one that talks straight to the IP, escapes it unless a NetworkPolicy/`REGISTRY_ONLY` is in place |
| Observability | Flows (Hubble, conntrack, tcpdump) | Access logs, per-host metrics, traces |
| Blast radius | The gateway node is a SPOF if the IP does not fail over | The gateway Deployment is a SPOF if under-provisioned |
| Cloud IP management | Secondary IP/ENI, EIP; external automation is needed in Cilium OSS | The same, if a fixed IP is needed |

### 2.3 Decision guide

- **"The partner allows only one IP"** → a CNI egress gateway (Cilium/Antrea/OVN-K) with an IP that fails over, or Cilium plus external automation that moves the IP.
- **"Only `*.github.com` may be reached, and I need logs of every request"** → Istio `REGISTRY_ONLY` + egress gateway + NetworkPolicy that blocks direct egress.
- **"Both"** → Istio egress gateway running on dedicated nodes, **plus** a CNI egress policy that selects the egress gateway Pods and SNATs them to the fixed IP.

---

## 3. Cilium Egress Gateway

### 3.1 Internal mechanics

1. The **cilium-agent** on each node watches `CiliumEgressGatewayPolicy` and builds an eBPF map (`cilium_egress_gw_policy_v4`) of `(sourcePodIP, destinationCIDR) → (gatewayNodeIP, egressIP)`.
2. On the **source node**, when a selected Pod sends to a destination inside `destinationCIDRs` (and outside `excludedCIDRs`), the eBPF program intercepts the packet and **forwards it to the gateway node**: over the tunnel (VXLAN/Geneve) in tunnel mode, or via native routing. The source IP is still the Pod's.
3. On the **gateway node**, the eBPF program recognizes the packet as egress-gateway traffic and applies **SNAT to the `egressIP`** using BPF masquerading, recording the entry in the BPF NAT/conntrack tables.
4. Return traffic arrives at the gateway node (because the external server replies to the `egressIP`), is reverse-NATed to the Pod's IP, and travels back to the source node.
5. If the source Pod is on the gateway node itself, no inter-node hop happens and only the SNAT is applied.

Consequences:

- The **`egressIP` must already be configured** on an interface of the gateway node. Cilium OSS **does not assign it**. It does validate the IP: if the IP is not on the node, the policy does not take effect correctly.
- **BPF masquerading** is required: iptables masquerading does not understand this redirection.
- `excludedCIDRs` is what lets you apply `0.0.0.0/0` without breaking traffic to internal networks such as the VPC or on-prem.

### 3.2 Requirements and installation

According to the official documentation (`docs.cilium.io` → *Egress Gateway*), the feature requires:

- `egressGateway.enabled=true`
- `bpf.masquerade=true`
- `kubeProxyReplacement=true`
- A Linux kernel compatible with BPF masquerading
- Documented incompatibilities: Cluster Mesh (for cross-cluster traffic), and other features listed in the *Compatibility* section of the page. Check it for your version.

`values-egress.yaml` file for Helm:

```yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.10.10
k8sServicePort: 6443
bpf:
  masquerade: true
egressGateway:
  enabled: true
  reconciliationTriggerInterval: 1s
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
```

```
$ helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version 1.18.2 \
    -f values-egress.yaml
Release "cilium" has been upgraded. Happy Helming!
NAME: cilium
LAST DEPLOYED: Wed Sep 30 10:12:44 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 4

$ kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
daemonset.apps/cilium restarted
deployment.apps/cilium-operator restarted

$ kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out
```

Verify that the agent has the feature enabled:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg config --all | grep -iE 'egress-gateway|masquerade|kube-proxy-replacement'
EnableBPFMasquerade               : true
EnableIPv4EgressGateway           : true
KubeProxyReplacement              : true
```

Or through the ConfigMap:

```
$ kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'egress-gateway|bpf-masquerade|kube-proxy-replacement'
  enable-bpf-masquerade: "true"
  enable-ipv4-egress-gateway: "true"
  kube-proxy-replacement: "true"
```

### 3.3 Preparing the gateway node

Label the node or nodes that will act as the gateway:

```
$ kubectl label node worker-egress-1 egress-gateway=true
node/worker-egress-1 labeled

$ kubectl get nodes -l egress-gateway=true -o wide
NAME              STATUS   ROLES    AGE   VERSION   INTERNAL-IP     ...
worker-egress-1   Ready    <none>   41d   v1.34.1   192.168.10.31   ...
```

Assign the egress IP to the node's interface (on bare metal; in the cloud this is a secondary IP on the ENI/NIC, allocated through the provider's API):

```
$ ssh worker-egress-1 'sudo ip addr add 192.168.10.200/24 dev eth0 && ip -4 addr show dev eth0'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    inet 192.168.10.31/24 brd 192.168.10.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet 192.168.10.200/24 scope global secondary eth0
       valid_lft forever preferred_lft forever
```

To make this persistent, use your node's network manager: a netplan, NetworkManager or systemd-networkd drop-in. For example, a systemd-networkd drop-in:

```ini
# /etc/systemd/network/10-eth0.network.d/egress.conf
[Network]
Address=192.168.10.200/24
```

### 3.4 Complete policy

Scenario: the `payments` namespace (Pods labeled `app=checkout`) must reach the processor's network `203.0.113.0/24` and the rest of the Internet **with IP `192.168.10.200`**, while internal networks keep their normal path.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    compliance: pci
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: payments
  labels:
    app: checkout
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      containers:
        - name: checkout
          image: nicolaka/netshoot:v0.13
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
---
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-egress
spec:
  selectors:
    - podSelector:
        matchLabels:
          app: checkout
          io.kubernetes.pod.namespace: payments
  destinationCIDRs:
    - "0.0.0.0/0"
  excludedCIDRs:
    - "10.0.0.0/8"
    - "192.168.0.0/16"
    - "172.16.0.0/12"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    egressIP: 192.168.10.200
```

Notes on the spec:

- `CiliumEgressGatewayPolicy` is **cluster-scoped**. The namespace is selected with the special label `io.kubernetes.pod.namespace` inside `podSelector`, or with `namespaceSelector` in the same selector element (supported in recent versions).
- `egressGateway.egressIP` and `egressGateway.interface` are alternatives. With `interface: eth1`, Cilium uses the first IPv4 address of that interface as the egress IP.
- If several nodes match the `nodeSelector`, Cilium OSS picks **one** deterministically. The IP must exist on the chosen node. There is no active-active load balancing in OSS; the Isovalent Enterprise edition adds HA with multiple gateways.
- Overlapping policies for the same `(Pod, destination)` pair are undefined behavior in practice. Design destination CIDRs that do not overlap.

```
$ kubectl apply -f payments-egress.yaml
namespace/payments created
deployment.apps/checkout created
ciliumegressgatewaypolicy.cilium.io/payments-egress created

$ kubectl get ciliumegressgatewaypolicies
NAME              AGE
payments-egress   8s
```

### 3.5 Verification

**1) BPF map on any node** (the source node must also have the entries, because it decides the redirection):

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf egress list
Source IP     Destination CIDR   Egress IP        Gateway IP
10.0.1.87     0.0.0.0/0          192.168.10.200   192.168.10.31
10.0.2.14     0.0.0.0/0          192.168.10.200   192.168.10.31
10.0.4.203    0.0.0.0/0          192.168.10.200   192.168.10.31
```

Interpretation: one line per selected Pod IP. `Gateway IP` is the InternalIP of the chosen gateway node. When the map is read on a node that is *not* the gateway, `Egress IP` may appear as `0.0.0.0`: that node only redirects and does not SNAT. Excluded CIDRs show up as entries whose gateway is marked "excluded CIDR", depending on the version.

**2) The source IP as seen by an external server.** Deploy an echo server outside the cluster (VM `192.168.20.5`) or use a public service:

```
$ kubectl -n payments exec deploy/checkout -- curl -s --max-time 5 http://192.168.20.5:8080/ip
192.168.10.200

$ kubectl -n default run tmp --rm -it --restart=Never --image=nicolaka/netshoot:v0.13 -- \
    curl -s --max-time 5 http://192.168.20.5:8080/ip
192.168.10.24
pod "tmp" deleted
```

A Pod that is not selected leaves with the IP of its own node (`192.168.10.24`). That is the expected behavior.

Wait: `192.168.20.5` falls inside the `192.168.0.0/16` in `excludedCIDRs`, so with the policy above that traffic would **not** go through the gateway. In the real test, pick an echo server outside the excluded ranges, or adjust the exclusions:

```
$ kubectl -n payments exec deploy/checkout -- curl -s --max-time 5 https://ifconfig.me
198.51.100.10
```

(If there is a NAT/firewall in front, you will see its public IP. To validate the egress IP itself, use an echo server on the gateway node's segment that is not excluded, or capture traffic on the gateway node.)

**3) Capture on the gateway node:**

```
$ ssh worker-egress-1 'sudo tcpdump -ni eth0 -c 4 "host 203.0.113.50 and tcp port 443"'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:31:02.118233 IP 192.168.10.200.41532 > 203.0.113.50.443: Flags [S], seq 3021934411, win 64860, length 0
10:31:02.131907 IP 203.0.113.50.443 > 192.168.10.200.41532: Flags [S.], seq 118830021, ack 3021934412, win 65160, length 0
10:31:02.132011 IP 192.168.10.200.41532 > 203.0.113.50.443: Flags [.], ack 1, win 507, length 0
10:31:02.132390 IP 192.168.10.200.41532 > 203.0.113.50.443: Flags [P.], seq 1:518, ack 1, length 517
```

**4) BPF NAT table on the gateway:**

```
$ kubectl -n kube-system exec cilium-7xk2p -c cilium-agent -- cilium-dbg bpf nat list | grep 203.0.113.50
TCP OUT 10.0.2.14:52110 -> 203.0.113.50:443 XLATE_SRC 192.168.10.200:41532 Created=12sec ago NeedsCT=1
TCP IN 203.0.113.50:443 -> 192.168.10.200:41532 XLATE_DST 10.0.2.14:52110 Created=12sec ago NeedsCT=1
```

**5) Hubble** (if enabled):

```
$ hubble observe --namespace payments --to-ip 203.0.113.50 --last 5
Sep 30 10:31:02.118: payments/checkout-6d9c8f7b5-q2m4x:52110 (ID:48211) -> 203.0.113.50:443 (world) to-stack FORWARDED (TCP Flags: SYN)
```

### 3.6 Failover with Cilium OSS

Cilium OSS does not move the IP. Common production patterns:

- **keepalived (VRRP)** across two or more gateway nodes, with the egress IP as the VIP, plus a `nodeSelector` that selects both. Watch for a mismatch between the node Cilium picks and the node that holds the VIP. The robust option is to have a controller update the node label that holds the VIP.
- **Cloud:** a controller that reassigns the secondary IP/EIP to the ENI of the new gateway node and relabels the node.
- **Enterprise:** Isovalent's `IsovalentEgressGatewayPolicy` offers native HA across multiple gateway nodes.

---

## 4. Antrea Egress (with automatic IP failover)

Antrea separates the **IP pool** from the **policy**, and it assigns and moves the IP among nodes itself.

```yaml
apiVersion: crd.antrea.io/v1beta1
kind: ExternalIPPool
metadata:
  name: prod-egress-pool
spec:
  ipRanges:
    - start: 192.168.10.200
      end: 192.168.10.209
  subnetInfo:
    gateway: 192.168.10.1
    prefixLength: 24
  nodeSelector:
    matchLabels:
      egress-gateway: "true"
---
apiVersion: crd.antrea.io/v1beta1
kind: Egress
metadata:
  name: payments-egress
spec:
  appliedTo:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: payments
    podSelector:
      matchLabels:
        app: checkout
  externalIPPool: prod-egress-pool
  egressIP: 192.168.10.200
```

```
$ kubectl get egress payments-egress
NAME              EGRESSIP         AGE   NODE
payments-egress   192.168.10.200   30s   worker-egress-1

$ kubectl drain worker-egress-1 --ignore-daemonsets --delete-emptydir-data
node/worker-egress-1 cordoned
...
$ kubectl get egress payments-egress
NAME              EGRESSIP         AGE   NODE
payments-egress   192.168.10.200   3m    worker-egress-2
```

Note: `drain` does not evict the antrea-agent DaemonSet, so this migration only happens when the agent or node stops responding in memberlist. Simulate the failure by stopping the node or the agent.

Points to remember:

- If `egressIP` is omitted, Antrea allocates one from the pool.
- Failover detection uses memberlist among the agents of the nodes in the pool, and Antrea announces the IP (gratuitous ARP / NDP).
- `spec.bandwidth` (rate/burst) lets you limit egress per policy.

---

## 5. OVN-Kubernetes EgressIP (reference)

```yaml
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: payments-egressip
spec:
  egressIPs:
    - 192.168.10.200
    - 192.168.10.201
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: payments
  podSelector:
    matchLabels:
      app: checkout
```

```
$ kubectl label node worker-egress-1 worker-egress-2 k8s.ovn.org/egress-assignable=""
node/worker-egress-1 labeled
node/worker-egress-2 labeled

$ kubectl get egressip
NAME                EGRESSIPS        ASSIGNED NODE     ASSIGNED EGRESSIPS
payments-egressip   192.168.10.200   worker-egress-1   192.168.10.200
```

With two IPs and two eligible nodes, OVN-K spreads the IPs across nodes, and traffic from the selected Pods is balanced between them.

---

## 6. Istio egress gateway (L7 chokepoint)

### 6.1 Model

1. **`outboundTrafficPolicy.mode: REGISTRY_ONLY`**: the sidecars reject any destination not registered through a `ServiceEntry`. This produces the `BlackHoleCluster` in Envoy.
2. **`ServiceEntry`** registers the external host (`api.github.com`) in the mesh registry.
3. **`Gateway`** (Istio API) configures the `istio-egressgateway` Deployment to listen for that host.
4. **`VirtualService`** with two routes: *mesh → egress gateway* and *egress gateway → external host*.
5. **`DestinationRule`** defines the subset toward the gateway (and, optionally, mTLS between the sidecar and the gateway).
6. **NetworkPolicy**: without it, a Pod can open a socket straight to the IP. It also bypasses the gateway if it has no sidecar or if it runs with `NET_ADMIN` and alters iptables. The NetworkPolicy is **the actual enforcement**.

### 6.2 Installation with the egress gateway enabled

`istio-egress.yaml` file:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: default
  meshConfig:
    accessLogFile: /dev/stdout
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
  components:
    egressGateways:
      - name: istio-egressgateway
        enabled: true
        k8s:
          replicaCount: 2
          nodeSelector:
            egress-gateway: "true"
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
          hpaSpec:
            minReplicas: 2
            maxReplicas: 5
```

```
$ istioctl install -f istio-egress.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Egress gateways installed 🛫
✔ Ingress gateways installed 🛬
✔ Installation complete

$ kubectl -n istio-system get pods -l istio=egressgateway -o wide
NAME                                   READY   STATUS    RESTARTS   AGE   IP           NODE
istio-egressgateway-7f9c6b8d5f-8kqlz   1/1     Running   0          45s   10.0.6.21    worker-egress-1
istio-egressgateway-7f9c6b8d5f-v2wrc   1/1     Running   0          45s   10.0.7.9     worker-egress-2

$ kubectl label namespace payments istio-injection=enabled
namespace/payments labeled
$ kubectl -n payments rollout restart deploy/checkout
deployment.apps/checkout restarted
```

Check `REGISTRY_ONLY` before configuring anything else:

```
$ kubectl -n payments exec deploy/checkout -c checkout -- curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com
curl: (35) OpenSSL SSL_connect: Connection reset by peer in connection to api.github.com:443
command terminated with exit code 35
```

### 6.3 Complete manifests (TLS passthrough through the gateway)

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: github-api
  namespace: payments
spec:
  hosts:
    - api.github.com
  ports:
    - number: 443
      name: tls
      protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: egress-github
  namespace: payments
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 443
        name: tls
        protocol: TLS
      hosts:
        - api.github.com
      tls:
        mode: PASSTHROUGH
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-github
  namespace: payments
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
    - name: github
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: github-through-egress-gateway
  namespace: payments
spec:
  hosts:
    - api.github.com
  gateways:
    - mesh
    - egress-github
  tls:
    - match:
        - gateways:
            - mesh
          port: 443
          sniHosts:
            - api.github.com
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: github
            port:
              number: 443
    - match:
        - gateways:
            - egress-github
          port: 443
          sniHosts:
            - api.github.com
      route:
        - destination:
            host: api.github.com
            port:
              number: 443
          weight: 100
```

- The first route applies **in the sidecars** (`gateways: mesh`): anything with SNI `api.github.com` goes to the gateway Service.
- The second route applies **in the gateway** (`gateways: egress-github`): it forwards to the real host.
- With `PASSTHROUGH` the gateway sees only the SNI, not the HTTP. For L7 policy on method or path, use **TLS origination** at the gateway: the application speaks plain HTTP inside the mesh, and the gateway opens TLS toward the outside through a `DestinationRule` with `tls.mode: SIMPLE`.
- The `Gateway` selector matches Pods in any namespace unless `PILOT_SCOPE_GATEWAY_TO_NAMESPACE` is enabled.

### 6.4 Closing the bypass with NetworkPolicy

Default-deny egress in the application namespace, allowing only DNS, the mesh control plane and the egress gateway:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-istiod-egressgw
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              app: istiod
      ports:
        - protocol: TCP
          port: 15012
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              istio: egressgateway
      ports:
        - protocol: TCP
          port: 8443
        - protocol: TCP
          port: 8080
```

> Note the ports: NetworkPolicy evaluates the **Pod port** (targetPort), not the Service port. By default the Istio egress gateway Service maps `443→8443` and `80→8080`. A policy that allows `443` toward the gateway Pod silently blocks the traffic. This is one of the most common mistakes.

Optionally, restrict the gateway itself so it only reaches the Internet (and not internal networks):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egressgw-internet-only
  namespace: istio-system
spec:
  podSelector:
    matchLabels:
      istio: egressgateway
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: istiod
      ports:
        - protocol: TCP
          port: 15012
```

### 6.5 Stable IP plus L7: combining with the CNI

Pin the gateway Pods (already done with the `nodeSelector` in the IstioOperator) and select them with a Cilium policy:

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: istio-egressgw-fixed-ip
spec:
  selectors:
    - podSelector:
        matchLabels:
          istio: egressgateway
          io.kubernetes.pod.namespace: istio-system
  destinationCIDRs:
    - "0.0.0.0/0"
  excludedCIDRs:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    egressIP: 192.168.10.200
```

Result: a single exit point, an L7 access log per request, and one source IP that the partner can allowlist.

### 6.6 Verifying Istio

```
$ kubectl -n payments exec deploy/checkout -c checkout -- \
    curl -sS -o /dev/null -w '%{http_code}\n' https://api.github.com/zen
200

$ kubectl -n istio-system logs -l istio=egressgateway -c istio-proxy --tail=2
[2026-09-30T10:44:12.301Z] "- - -" 0 - - - "-" 1203 5541 212 - "-" "-" "-" "-" "140.82.121.6:443" outbound|443||api.github.com 10.0.6.21:50812 10.0.6.21:8443 10.0.2.14:39410 api.github.com -

$ istioctl proxy-config listeners deploy/istio-egressgateway -n istio-system --port 8443
ADDRESSES PORT MATCH                  DESTINATION
0.0.0.0   8443 SNI: api.github.com    Cluster: outbound|443||api.github.com

$ istioctl -n payments proxy-config routes deploy/checkout | grep -i github
$ istioctl -n payments proxy-config clusters deploy/checkout | grep -E 'github|egressgateway'
api.github.com                                             443   -          outbound  STRICT_DNS
istio-egressgateway.istio-system.svc.cluster.local         443   github     outbound  EDS    egressgateway-for-github.payments
```

In the gateway access log, the downstream field (`10.0.2.14:39410`) is the application Pod's IP and the SNI is `api.github.com`. If the access log is empty, traffic is not reaching the gateway. Go to the diagnostics table.

Static analysis:

```
$ istioctl analyze -n payments
✔ No validation issues found when analyzing namespace: payments.
```

---

## 7. Diagnostics and troubleshooting

### 7.1 Methodology

1. **Define the expected flow**: Pod → (sidecar?) → (gateway node/Pod) → SNAT → destination.
2. **Observe the source IP at the destination** (echo server) and capture on each hop (`tcpdump` on the source node's `lxc*`/`eth0` and on the gateway's `eth0`).
3. **Check the control plane** (CRD accepted, BPF map or Envoy config generated).
4. **Check the data plane** (conntrack/NAT, Envoy access log).
5. **Check the complementary policies** (NetworkPolicy, cloud security groups, firewall).

### 7.2 Symptom table

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Cilium: the destination sees the NodeIP, not the egress IP | Feature disabled, or `bpf.masquerade=false` | `cilium-dbg config --all \| grep -i egress` | Enable `egressGateway.enabled`, `bpf.masquerade`, KPR; restart the agents |
| Cilium: `bpf egress list` is empty | The selector does not match: wrong labels, or the namespace is not specified with `io.kubernetes.pod.namespace` | `kubectl get pods -n payments --show-labels`; `cilium-dbg endpoint list` | Fix `podSelector` / `namespaceSelector` |
| Cilium: entries exist but connections time out | `egressIP` is not configured on the gateway node's interface, or reverse-path filtering drops the return traffic | `ip addr` on the gateway; `tcpdump` shows SYN out but no SYN-ACK, or the SYN-ACK is not forwarded | Assign the IP; check `rp_filter`; check ARP on the segment (`arping` the egress IP) |
| Cilium: internal traffic (DB in the VPC) broken after the policy | `destinationCIDRs: 0.0.0.0/0` with no `excludedCIDRs` | `bpf egress list` shows internal destinations covered | Add `excludedCIDRs` for internal ranges |
| Cilium: the egress IP changes when a node is lost | No HA in OSS; the `nodeSelector` picked another node that lacks the IP | `bpf egress list` shows a new `Gateway IP` | VRRP/external controller, or Enterprise HA; narrow the `nodeSelector` |
| Cloud: SYN leaves, nothing comes back | Source/destination check or anti-spoofing on the VM/ENI; the IP is not associated with the NIC in the provider | The VPC flow logs show a REJECT | Associate the secondary IP/EIP; disable the src/dst check where applicable |
| Antrea: `Egress` with no `NODE` | No node in the pool is healthy, or the `nodeSelector` of the `ExternalIPPool` matches nothing | `kubectl get externalippool`; `kubectl describe egress` | Label the nodes; check the agents |
| Istio: `curl` returns `Connection reset` / 502 | `REGISTRY_ONLY` with no `ServiceEntry`, or a mismatched SNI/host | `istioctl proxy-config clusters` shows no `outbound\|443\|\|host`; the sidecar log shows `BlackHoleCluster` | Create a `ServiceEntry` whose host matches exactly |
| Istio: it works, but the gateway access log is empty | The VirtualService is not applied to `mesh`, or it is in a namespace whose `exportTo` does not include the client | `istioctl -n payments proxy-config clusters` lacks the `github` subset | Fix `gateways: [mesh, ...]` and the namespaces |
| Istio: timeout toward the gateway after a NetworkPolicy | The policy allows `443` instead of the Pod's targetPort `8443` | `kubectl -n istio-system get svc istio-egressgateway -o yaml` (targetPort) | Allow `8443`/`8080` |
| Istio: a Pod without a sidecar reaches the Internet directly | No default-deny NetworkPolicy | Test from a Pod with `sidecar.istio.io/inject: "false"` | Apply default-deny egress plus explicit allows |
| DNS fails after the default-deny | DNS was not allowed toward CoreDNS (UDP **and** TCP 53) | `nslookup` from the Pod times out | Add the DNS rule |
| Intermittent SNAT port exhaustion | Many connections to one destination from a single egress IP (65k ports per `srcIP:dstIP:dstPort` tuple) | `conntrack -S` / `cilium-dbg bpf nat list \| wc -l`; errors from the cloud NAT | More egress IPs (Antrea/OVN-K with several), keepalive/connection pooling in the application |

### 7.3 Useful commands

```
# Which Pods are selected, and their IPs (compare against bpf egress list)
$ kubectl -n payments get pods -l app=checkout -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
NAME                        IP           NODE
checkout-6d9c8f7b5-q2m4x    10.0.2.14    worker-2
checkout-6d9c8f7b5-r8n7c    10.0.1.87    worker-1
checkout-6d9c8f7b5-z5k1d    10.0.4.203   worker-4

# The Cilium agent on the gateway node
$ kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=worker-egress-1 -o name
pod/cilium-7xk2p

# Egress-gateway policy logs in the agent
$ kubectl -n kube-system logs cilium-7xk2p -c cilium-agent | grep -i egress | tail -3

# The egress IP answers ARP on the segment
$ arping -c 2 -I eth0 192.168.10.200
ARPING 192.168.10.200
42 bytes from 52:54:00:3a:91:0c (192.168.10.200): index=0 time=312.114 usec
42 bytes from 52:54:00:3a:91:0c (192.168.10.200): index=1 time=287.550 usec

# Connectivity to the egress gateway from a sidecar
$ kubectl -n payments exec deploy/checkout -c istio-proxy -- \
    pilot-agent request GET clusters | grep egressgateway | grep -E 'health_flags|cx_active' | head -4
```

### 7.4 Production checklist

- [ ] The egress IP is documented, reserved in IPAM and shared with the partner.
- [ ] `excludedCIDRs` covers every internal network: the VPC, peered networks and on-prem.
- [ ] A failover mechanism for the IP is **tested** (drain or shutdown of the gateway node).
- [ ] Gateway nodes are dedicated (taints/tolerations), with capacity sized for the NIC and conntrack (`nf_conntrack_max`, or the `bpf-ct-global-*` sizes in Cilium).
- [ ] With a mesh: `REGISTRY_ONLY` + `ServiceEntry` + egress gateway **+ default-deny NetworkPolicy** (without the last one, the design is only advisory).
- [ ] Alerts: gateway Pods not Ready, 5xx in the gateway, an empty egress map on a node, SNAT errors.
- [ ] A test that runs in CI or as a synthetic probe: `curl` to an echo server that verifies the source IP.

---

## 8. Exam summary

- An egress gateway gives you **a deterministic source IP and a chokepoint**. Without one, the source IP is the IP of whichever node happens to run the Pod.
- **Cilium**: `CiliumEgressGatewayPolicy` (cluster-scoped), `selectors` + `destinationCIDRs` + `excludedCIDRs` + `egressGateway{nodeSelector, egressIP|interface}`. It requires `egressGateway.enabled`, `bpf.masquerade` and kube-proxy replacement. Verify with `cilium-dbg bpf egress list`. The IP is not managed by Cilium OSS.
- **Antrea** (`Egress` + `ExternalIPPool`) and **OVN-K** (`EgressIP` + the `k8s.ovn.org/egress-assignable` label) do assign the IP and fail it over.
- **Istio**: `REGISTRY_ONLY` → `ServiceEntry` → `Gateway` (selector `istio: egressgateway`) → a `VirtualService` with two routes (`mesh` and the gateway) → `DestinationRule`. Verify with the gateway access log and `istioctl proxy-config`.
- **NetworkPolicy** is what makes the mesh egress gateway mandatory rather than optional. Remember DNS over UDP and TCP, and the targetPort `8443`.

---

## References

- CKNE – Certified Kubernetes Network Engineer (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cilium – Egress Gateway: https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- Cilium – Kubernetes Without kube-proxy: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Cilium – Masquerading: https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Antrea – Egress: https://antrea.io/docs/main/docs/egress/
- OVN-Kubernetes – EgressIP: https://github.com/ovn-kubernetes/ovn-kubernetes/blob/master/docs/features/cluster-egress-controls/egress-ip.md
- Istio – Egress Gateways: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
- Istio – Accessing External Services (outboundTrafficPolicy): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio – Egress Gateways with TLS Origination: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
- Istio – ServiceEntry reference: https://istio.io/latest/docs/reference/config/networking/service-entry/
- Kubernetes – Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Calico – Egress gateways (Calico Enterprise): https://docs.tigera.io/calico-enterprise/latest/networking/egress/