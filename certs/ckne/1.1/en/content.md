# 1.1 Installing and Configuring CNI Plugins

> **Exam weight: 3.0.** You are expected to take a node that reports `NotReady` because it has no pod network and make pod networking work. That means knowing where the container runtime looks for CNI configuration and binaries, what a valid conflist looks like, how the major plugins (Flannel, Calico, Cilium) get installed and what they write to disk, and how to find the failing layer when a pod is stuck in `ContainerCreating`.

---

## 1. The production problem CNI solves

Kubernetes sets the rules for pod networking but ships no code that implements them. The cluster networking model requires ([kubernetes.io — Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)):

1. Every pod gets its own IP address, unique across the whole cluster.
2. A pod can reach any other pod on any node without NAT.
3. Node agents (kubelet, system daemons) can reach every pod on that node.

The kubelet does none of this itself. Since Kubernetes 1.24 removed dockershim, the kubelet has no network-plugin flags at all (`--network-plugin`, `--cni-bin-dir` and `--cni-conf-dir` are gone). **CNI is invoked by the container runtime** (containerd or CRI-O) when the kubelet asks it, over CRI, to create a pod sandbox ([kubernetes.io — Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)).

This has consequences in production:

| Architectural fact | Production consequence |
|---|---|
| The CNI config lives on every node's filesystem (`/etc/cni/net.d`) | Nodes can drift. One node with a leftover `10-flannel.conflist` behaves differently from the rest. |
| The runtime runs a **binary** per pod create/delete | A missing binary in `/opt/cni/bin` breaks every new pod on that node, while running pods keep working. |
| The runtime picks **the first config file in lexical order** | Installing a second CNI without removing the first gives you non-deterministic behaviour across nodes. |
| IPAM state often lives on the node (`host-local`) | A crash between ADD and DEL leaks IPs until the range is exhausted. |
| The CNI decides encapsulation, routing and MTU | A wrong MTU passes `ping` and silently breaks large TLS responses. |

A node with no valid CNI config reports this:

```
$ kubectl get nodes
NAME       STATUS     ROLES           AGE   VERSION
cp-1       NotReady   control-plane   4m    v1.34.1
worker-1   NotReady   <none>          2m    v1.34.1

$ kubectl describe node worker-1 | grep -A1 Ready
  Ready            False   Mon, 29 Sep 2026 10:12:03 +0000   Mon, 29 Sep 2026 10:08:41 +0000   KubeletNotReady              container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

This is the most common starting state in hands-on network tasks. Read it literally: the **runtime** (not the kubelet) says its **network** is not ready because it found **no loadable CNI config**.

---

## 2. How CNI actually works

### 2.1 The contract

CNI (Container Network Interface) is a CNCF specification plus a set of reference plugins ([CNI spec](https://www.cni.dev/docs/spec/)). The contract is intentionally primitive:

- A **plugin is an executable.** The runtime runs it, passes parameters through **environment variables**, passes the network configuration as **JSON on stdin**, and reads a **JSON result (or error) on stdout**.
- The runtime creates the network namespace and hands its path to the plugin. The plugin creates interfaces inside it.
- Plugins are **chained** through a *network configuration list* (a "conflist"). Each plugin receives the previous plugin's result as `prevResult`.

| Environment variable | Meaning |
|---|---|
| `CNI_COMMAND` | `ADD`, `DEL`, `CHECK`, `VERSION`, and in spec 1.1 also `STATUS` and `GC` |
| `CNI_CONTAINERID` | Unique ID of the sandbox (the pause container in Kubernetes) |
| `CNI_NETNS` | Path to the network namespace, e.g. `/var/run/netns/cni-7c1e…` |
| `CNI_IFNAME` | Interface name to create inside the netns (`eth0` in Kubernetes) |
| `CNI_ARGS` | Extra `KEY=VALUE;...` pairs; Kubernetes runtimes pass `K8S_POD_NAMESPACE`, `K8S_POD_NAME`, `K8S_POD_INFRA_CONTAINER_ID`, `K8S_POD_UID` |
| `CNI_PATH` | Directories searched for plugin binaries (this is how delegation, e.g. to IPAM, finds `host-local`) |

**Verbs and their semantics** (from the [spec](https://github.com/containernetworking/cni/blob/main/SPEC.md)):

| Verb | Semantics | Operational note |
|---|---|---|
| `ADD` | Attach the container to the network and return a result | Called on sandbox creation. Failure gives `FailedCreatePodSandBox`. |
| `DEL` | Release everything ADD created | **Must be idempotent** and must tolerate a netns that no longer exists. Buggy DEL is the source of IP leaks. |
| `CHECK` | Verify the attachment is still as expected | Kubernetes runtimes rarely use it. Don't rely on it for health. |
| `VERSION` | Report supported spec versions | Used to negotiate `cniVersion`. |
| `STATUS` (1.1) | "Is this plugin ready to accept ADDs?" | Lets the runtime report `NetworkReady=false` based on the plugin's own readiness, not just whether a config file exists. |
| `GC` (1.1) | Clean up attachments that aren't in a list of valid ones | Addresses leaked resources. The runtime supplies the list of valid attachments. |

### 2.2 The invocation path in Kubernetes

```
kubelet ──CRI RunPodSandbox──▶ containerd (CRI plugin)
                                  │ 1. creates netns /var/run/netns/cni-<uuid>
                                  │ 2. starts pause container in it
                                  │ 3. loads FIRST valid file in conf_dir (lexical order)
                                  │ 4. for each plugin in "plugins": exec <bin_dir>/<type>
                                  ▼
          /opt/cni/bin/calico  (stdin: net config + prevResult, env: CNI_*)
                                  │ delegates IPAM: exec /opt/cni/bin/calico-ipam
                                  ▼
          /opt/cni/bin/bandwidth  → /opt/cni/bin/portmap   (chained, receive prevResult)
                                  │
                                  ▼
          final Result JSON ──▶ containerd ──▶ kubelet ──▶ PodIP in pod.status
```

Two details that come up in troubleshooting:

- The **pod IP that `kubectl` shows comes from the CNI result.** If a plugin returns no `ips`, the pod runs but has no IP in status.
- On **DEL**, containerd runs the chain **in reverse** (`portmap` first, then the main plugin) and uses the cached result at `/var/lib/cni/results/`.

### 2.3 The configuration list format

A conflist is one JSON document. This one is complete and valid, the kind you would write by hand for a bridge-based cluster ("hard way" style) on a node that owns `10.244.1.0/24`:

```json
{
  "cniVersion": "1.0.0",
  "name": "k8s-pod-network",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "mtu": 1500,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [
            {
              "subnet": "10.244.1.0/24",
              "gateway": "10.244.1.1"
            }
          ]
        ],
        "routes": [
          {
            "dst": "0.0.0.0/0"
          }
        ],
        "dataDir": "/var/lib/cni/networks"
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      },
      "snat": true
    },
    {
      "type": "bandwidth",
      "capabilities": {
        "bandwidth": true
      }
    }
  ]
}
```

Field by field:

| Field | Meaning |
|---|---|
| `cniVersion` | Spec version the config is written against. The runtime and **every** plugin in the chain must support it. Spec 1.1 adds `cniVersions` (an array) so a config can offer several versions. |
| `name` | Network name. `host-local` uses it as the directory name under `dataDir`, and it must be unique per node. |
| `plugins[].type` | **Binary name** looked up in `CNI_PATH`. A typo here gives `failed to find plugin "brdge" in path [/opt/cni/bin]`. |
| `ipam` | Delegated IPAM plugin (`host-local`, `dhcp`, `static`, or a vendor one like `calico-ipam`). |
| `capabilities` | Declares that this plugin wants **runtime config** injected. `portMappings` comes from `hostPort` in the pod spec, `bandwidth` from pod annotations. |
| `disableCheck` / `disableGC` | Turn off CHECK / GC for the whole list (`disableGC` is spec 1.1). |

On `isGateway`, `ipMasq` and routing: `bridge` + `host-local` only gives you **node-local** connectivity. Pods on other nodes are reachable only if something routes `10.244.2.0/24` to worker-2: static routes, BGP, or an overlay. That missing piece is exactly what Flannel, Calico and Cilium provide.

```
$ sudo ip route add 10.244.2.0/24 via 192.168.10.12 dev ens3   # on worker-1
$ sudo ip route add 10.244.1.0/24 via 192.168.10.11 dev ens3   # on worker-2
```

### 2.4 The reference plugins

These come from [containernetworking/plugins](https://github.com/containernetworking/plugins), documented at [cni.dev/plugins](https://www.cni.dev/plugins/current/). Many vendor CNIs **depend on them**. Flannel, for example, delegates to `bridge` and `host-local`, so a missing `bridge` binary breaks Flannel.

| Category | Plugin | What it does | Typical use |
|---|---|---|---|
| Main (interface) | `bridge` | veth pair from the netns to a Linux bridge on the host | Flannel's delegate, simple labs |
| | `ptp` | veth pair with a /32 point-to-point route, no bridge | Routed designs |
| | `macvlan` / `ipvlan` | Sub-interfaces of a host NIC | Secondary networks (via Multus), L2 adjacency |
| | `host-device` | Moves an existing host device into the netns | SR-IOV VFs, dedicated NICs |
| | `vlan` | 802.1Q sub-interface | Tenant VLANs |
| | `loopback` | Brings up `lo` | Required by containerd unless internal loopback is enabled |
| IPAM | `host-local` | File-based allocation from ranges, state under `/var/lib/cni/networks/<name>/` | Per-node pod CIDR |
| | `dhcp` | Leases from an external DHCP server (needs the `dhcp daemon` running) | macvlan into existing LANs |
| | `static` | Fixed addresses from config/args | Tests, special workloads |
| Meta (chained) | `portmap` | iptables/nftables DNAT for `hostPort` | Needed for `hostPort` to work at all |
| | `bandwidth` | TBF shaping via the `kubernetes.io/{ingress,egress}-bandwidth` annotations | Noisy-neighbour control |
| | `tuning` | sysctls, MTU, MAC, promiscuous mode inside the netns | Per-pod kernel tuning |
| | `firewall` | Adds iptables/firewalld rules that allow pod traffic | Hosts with a restrictive default FORWARD policy |
| | `sbr` | Source-based routing | Multi-homed pods |

---

## 3. Where the runtime looks: containerd and CRI-O

This is the most exam-relevant part of the topic. **Two directories, one rule:**

| | Default | Rule |
|---|---|---|
| Config directory | `/etc/cni/net.d` | Files `*.conf`, `*.conflist`, `*.json`, loaded in **lexical order**. containerd uses only the first valid one (`max_conf_num = 1`). |
| Binary directory | `/opt/cni/bin` | Every `type` in the chain, plus IPAM, plus `loopback`. |

### 3.1 containerd

For containerd 2.x (config `version = 3`), the CRI runtime settings sit under `io.containerd.cri.v1.runtime` ([containerd CRI config](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)):

```toml
version = 3

[plugins.'io.containerd.cri.v1.runtime'.cni]
  # containerd >= 2.1 accepts a list; 2.0 uses the single-valued bin_dir = '/opt/cni/bin'
  bin_dirs = ['/opt/cni/bin']
  conf_dir = '/etc/cni/net.d'
  # Only the first conflist (lexical order) is loaded; keep this at 1 in Kubernetes
  max_conf_num = 1
  conf_template = ''
  # Set up lo inside the netns without the loopback binary (containerd 2.x)
  use_internal_loopback = false
```

For containerd 1.7 (config `version = 2`), the same settings live under the old grpc CRI plugin:

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"
  max_conf_num = 1
  conf_template = ""
```

Check the **effective** config, not the file, because defaults apply to anything the file leaves out:

```
$ sudo containerd config dump | grep -A8 "cri.v1.runtime'.cni\]"
  [plugins.'io.containerd.cri.v1.runtime'.cni]
    bin_dir = ''
    bin_dirs = ['/opt/cni/bin']
    conf_dir = '/etc/cni/net.d'
    conf_template = ''
    ip_pref = ''
    max_conf_num = 1
    setup_serially = false
    use_internal_loopback = false
```

On some distributions (k3s, RKE2, some managed images) the paths are **not** the defaults. For example, k3s uses `/var/lib/rancher/k3s/agent/etc/cni/net.d` and its own bin directory. Always read the effective config before assuming paths.

### 3.2 CRI-O

```toml
# /etc/crio/crio.conf.d/10-cni.conf
[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = [
  "/opt/cni/bin/",
  "/usr/libexec/cni/",
]
```

CRI-O ships its own `/etc/cni/net.d/11-crio-ipv4-bridge.conflist`. **If you install Calico or Cilium on CRI-O, that file can win the lexical sort** unless the vendor file sorts earlier (`05-cilium.conflist`, `10-calico.conflist`). Remove it:

```
$ sudo mv /etc/cni/net.d/11-crio-ipv4-bridge.conflist /root/
$ sudo systemctl restart crio
```

### 3.3 Node prerequisites (every CNI)

The Kubernetes container-runtime guide requires forwarding and bridged-traffic filtering ([kubernetes.io — Container Runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)):

```
# /etc/modules-load.d/k8s.conf
overlay
br_netfilter
```

```
# /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

```
$ sudo modprobe overlay && sudo modprobe br_netfilter
$ sudo sysctl --system
$ sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
```

Without `ip_forward`, pods reach their own node and nothing else. Without `br_netfilter`, Service traffic between two pods on the same bridge bypasses kube-proxy's iptables rules.

### 3.4 Installing the reference plugins by hand

Most vendor CNIs install their own binaries with an init container. Flannel and hand-built clusters need the reference set first. The version below is an example; pin the release you have validated from the [plugins releases page](https://github.com/containernetworking/plugins/releases).

```
$ CNI_PLUGINS_VERSION=v1.7.1
$ ARCH=amd64
$ sudo mkdir -p /opt/cni/bin
$ curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
$ curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz.sha256"
$ sha256sum -c "cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz.sha256"
cni-plugins-linux-amd64-v1.7.1.tgz: OK
$ sudo tar -C /opt/cni/bin -xzf "cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
$ ls /opt/cni/bin
bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan  loopback
macvlan  portmap  ptp  sbr  static  tap  tuning  vlan  vrf
$ /opt/cni/bin/bridge --version
CNI bridge plugin v1.7.1
CNI protocol versions supported: 0.1.0, 0.2.0, 0.3.0, 0.3.1, 0.4.0, 1.0.0, 1.1.0
```

---

## 4. Planning before you install: CIDRs and IPAM ownership

The most expensive CNI mistake happens **before** installation: overlapping CIDRs, or pod CIDR ownership that nobody understands.

| CIDR | Set by | Must not overlap with |
|---|---|---|
| Node network | Infrastructure | Pod CIDR, Service CIDR, VPN/peered ranges |
| Pod CIDR | `kubeadm --pod-network-cidr` / `networking.podSubnet`, **and** the CNI's own config | Everything else |
| Service CIDR | `--service-cidr` / `networking.serviceSubnet` (default `10.96.0.0/12`) | Everything else |

A complete kubeadm config that declares both:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
controlPlaneEndpoint: "192.168.10.10:6443"
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv4
      value: "24"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
```

Setting `podSubnet` makes kube-controller-manager run with `--allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16` and write a `/24` to every `node.spec.podCIDR`. **Whether the CNI uses that value depends on the CNI:**

| CNI | Where pod IPs come from | Uses `node.spec.podCIDR`? |
|---|---|---|
| Flannel | `host-local` on the node's `podCIDR` (kube subnet manager) | **Yes, mandatory.** Without `--pod-network-cidr`, flannel crashes with `node "x" pod cidr not assigned`. |
| Calico (Calico IPAM) | `/26` blocks carved from `IPPool` resources, assigned dynamically to nodes | **No.** `podCIDR` is ignored unless you choose `host-local` IPAM. |
| Cilium `cluster-pool` (default) | The Cilium operator hands a per-node CIDR from `clusterPoolIPv4PodCIDRList` | **No.** The default list is `10.0.0.0/8`, which collides with many corporate networks. |
| Cilium `kubernetes` | `node.spec.podCIDR` | Yes |

```
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
NAME       PODCIDR
cp-1       10.244.0.0/24
worker-1   10.244.1.0/24
worker-2   10.244.2.0/24
```

If you run Calico or Cilium in cluster-pool mode, pod IPs will **not** match that column. That's expected, not a bug.

---

## 5. Choosing a CNI: technical trade-offs

| Criterion | Flannel | Calico | Cilium |
|---|---|---|---|
| Dataplane | Linux bridge + kernel routing | iptables, nftables, or eBPF | eBPF (tc/XDP), optional netkit |
| Cross-node transport | VXLAN (default), host-gw, WireGuard | BGP (no encap), IPIP, VXLAN, CrossSubnet modes | VXLAN/Geneve tunnel, or native routing (+ BGP control plane) |
| NetworkPolicy | **None** (needs another component) | Full K8s NetworkPolicy plus Calico global/tiered policy | Full K8s NetworkPolicy plus L7 CiliumNetworkPolicy |
| kube-proxy replacement | No | Yes (eBPF mode) | Yes (`kubeProxyReplacement: true`) |
| IPAM | host-local on `podCIDR` | Block-based Calico IPAM | cluster-pool, kubernetes, multi-pool, cloud ENI/Azure |
| Observability | Minimal | Flow logs (Goldmane/Whisker in recent releases) | Hubble (L3–L7 flows) |
| Kernel requirements | Low | Low (iptables), higher for eBPF | Modern kernel (check the system requirements page) |
| Operational complexity | Very low | Medium (operator + CRDs) | Medium-high (eBPF debugging skills) |
| Typical fit | Labs, edge, simple clusters | On-prem with BGP to ToR, mixed policy needs | Large scale, L7 policy, observability, no kube-proxy |

Weave Net is archived and unmaintained. Don't choose it for new clusters.

**Encapsulation trade-offs** (these matter for MTU and firewalling):

| Mode | Overhead | Pod MTU on a 1500 underlay | Requires | Ports to open between nodes |
|---|---|---|---|---|
| Native / BGP routing | 0 | 1500 | L3 fabric that learns pod routes (BGP peering or cloud routes) | TCP 179 (BGP) |
| IP-in-IP (Calico) | 20 B | 1480 | IP protocol 4 allowed (often blocked in cloud) | IP proto 4 |
| VXLAN | 50 B | 1450 | UDP between nodes | UDP 4789 (Calico), UDP 8472 (Flannel/Cilium default) |
| Geneve (Cilium) | 50 B + options | 1450 or less | UDP | UDP 6081 |
| WireGuard (encrypted) | ~60–80 B | ~1420 or less | Kernel WireGuard | UDP 51820 (Flannel), 51871 (Calico), 51871 (Cilium) |
| CrossSubnet (Calico) | 0 in-subnet, 50 B across subnets | Mixed | Node subnet awareness | 179 + 4789 |

Always confirm current ports on the vendor's requirements page ([Calico](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements), [Cilium](https://docs.cilium.io/en/stable/operations/system_requirements/)). A security group that blocks UDP 8472 gives you pods that reach their own node and time out everywhere else, the classic "works on one node" symptom.

---

## 6. Installing Flannel

```
$ kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
namespace/kube-flannel created
clusterrole.rbac.authorization.k8s.io/flannel created
clusterrolebinding.rbac.authorization.k8s.io/flannel created
serviceaccount/flannel created
configmap/kube-flannel-cfg created
daemonset.apps/kube-flannel-ds created
```

The part you configure is the `kube-flannel-cfg` ConfigMap. Its `net-conf.json` **must match** `--pod-network-cidr`. This is a complete, standalone version of that ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    app: flannel
    tier: node
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan"
      }
    }
```

What happens on each node:

1. An init container copies the `flannel` binary to `/opt/cni/bin`, and another copies `cni-conf.json` to `/etc/cni/net.d/10-flannel.conflist`.
2. `flanneld` reads `node.spec.podCIDR`, creates `flannel.1` (VXLAN), and writes `/run/flannel/subnet.env`.
3. At pod ADD, the `flannel` plugin reads `subnet.env` and **delegates to `bridge` + `host-local`**, which must already be in `/opt/cni/bin` (section 3.4).

```
$ cat /run/flannel/subnet.env
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.1.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true

$ ip -d link show flannel.1 | head -3
5: flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default
    link/ether 3e:8a:12:9c:51:0f brd ff:ff:ff:ff:ff:ff promiscuity 0 minmtu 68 maxmtu 65535
    vxlan id 1 local 192.168.10.11 dev ens3 srcport 0 0 dstport 8472 nolearning ttl auto ageing 300
```

---

## 7. Installing Calico with the Tigera operator

The operator is Calico's supported installation method ([Calico on-premises install](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises)). Pin a version you have validated:

```
$ CALICO_VERSION=v3.30.3
$ kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml
$ kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml
namespace/tigera-operator created
serviceaccount/tigera-operator created
clusterrole.rbac.authorization.k8s.io/tigera-operator created
clusterrolebinding.rbac.authorization.k8s.io/tigera-operator created
deployment.apps/tigera-operator created
```

Use `kubectl create`, not `apply`, for the CRDs. They exceed the 262 KB `last-applied-configuration` annotation limit and `apply` fails with `metadata.annotations: Too long`. If you manage them declaratively, use `kubectl apply --server-side`.

Then declare the network. This is a complete `Installation` for a VXLAN-CrossSubnet cluster using the kubeadm pod CIDR from section 4 ([Installation API reference](https://docs.tigera.io/calico/latest/reference/installation/api)):

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  variant: Calico
  cni:
    type: Calico
    ipam:
      type: Calico
  calicoNetwork:
    bgp: Disabled
    linuxDataplane: Iptables
    nodeAddressAutodetectionV4:
      kubernetes: NodeInternalIP
    ipPools:
      - name: default-ipv4-ippool
        cidr: 10.244.0.0/16
        blockSize: 26
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
```

Design decisions in that manifest:

- **`nodeAddressAutodetectionV4: kubernetes: NodeInternalIP`.** The default `firstFound` picks the first interface. On multi-NIC nodes it picks the wrong one (a docker bridge, a storage NIC), and the VXLAN tunnels point at unreachable addresses.
- **`bgp: Disabled` + VXLAN.** Works on any L3 network without touching routers. If your ToR switches speak BGP, `bgp: Enabled` + `encapsulation: None` removes encapsulation overhead completely.
- **`blockSize: 26`.** Each node claims 64-address blocks and more on demand. Nodes that run more than 64 pods get several blocks, which means more routes.
- **The `ipPools` CIDR is written only when first created.** Editing `Installation` later does **not** migrate existing pools. You change CIDRs by creating a new `IPPool`, disabling the old one, and recycling pods.

```
$ kubectl create -f calico-installation.yaml
installation.operator.tigera.io/default created
apiserver.operator.tigera.io/default created

$ kubectl get tigerastatus
NAME        AVAILABLE   PROGRESSING   DEGRADED   SINCE
apiserver   True        False         False      41s
calico      True        False         False      86s
ippools     True        False         False      2m

$ kubectl get pods -n calico-system -o wide
NAME                                       READY   STATUS    RESTARTS   AGE   IP              NODE
calico-kube-controllers-6d8f7b9c5d-kq2xw   1/1     Running   0          2m    10.244.93.1     worker-1
calico-node-7rkq4                          1/1     Running   0          2m    192.168.10.11   worker-1
calico-node-mz8fx                          1/1     Running   0          2m    192.168.10.10   cp-1
calico-node-wd2lt                          1/1     Running   0          2m    192.168.10.12   worker-2
calico-typha-5f7d9c8b6-hx4tn               1/1     Running   0          2m    192.168.10.12   worker-2
csi-node-driver-4hn6s                      2/2     Running   0          2m    10.244.93.2     worker-1

$ ls /etc/cni/net.d/
10-calico.conflist  calico-kubeconfig
$ ls /opt/cni/bin | grep calico
calico
calico-ipam
```

Calico's CNI plugin authenticates to the API server with `/etc/cni/net.d/calico-kubeconfig`. If that token expires or the file is corrupted, ADDs fail with `Unauthorized` while `calico-node` stays Running. It's a confusing symptom, so check this file when you see it.

---

## 8. Installing Cilium with Helm

Cilium can install through the `cilium` CLI or Helm ([Cilium Helm install](https://docs.cilium.io/en/stable/installation/k8s-install-helm/)). Helm is the production path because values are versioned in Git.

A complete values file for a kubeadm cluster **without kube-proxy**. The IPAM range is set explicitly so the `10.0.0.0/8` default doesn't collide with anything:

```yaml
# cilium-values.yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.10.10
k8sServicePort: 6443

ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24

routingMode: tunnel
tunnelProtocol: vxlan

cni:
  exclusive: true
  chainingMode: none

operator:
  replicas: 2

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: false
```

Things to understand in this file:

- **`k8sServiceHost`/`k8sServicePort` are mandatory with `kubeProxyReplacement: true`.** Without kube-proxy, nothing implements the `kubernetes` Service ClusterIP (`10.96.0.1`) yet, so the agent has to reach the API server directly. Leave them out and the agent CrashLoops with `dial tcp 10.96.0.1:443: i/o timeout`.
- **`cni.exclusive: true`.** The agent renames any other conflist in `/etc/cni/net.d` to `*.cilium_bak`. That's useful for making Cilium's `05-cilium.conflist` authoritative. It's also why Cilium conflicts with Multus unless you set it to `false`.
- If kube-proxy is already running, either skip phase-out (`kubeProxyReplacement: false`) or remove it deliberately:

```
$ kubectl -n kube-system delete ds kube-proxy
$ kubectl -n kube-system delete cm kube-proxy
$ sudo iptables-save | grep -v KUBE | sudo iptables-restore   # on every node
```

For new clusters, run `kubeadm init --skip-phases=addon/kube-proxy` instead.

```
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm install cilium cilium/cilium --version 1.18.2 --namespace kube-system -f cilium-values.yaml
NAME: cilium
LAST DEPLOYED: Mon Sep 29 10:31:12 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1

$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy       Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|IPAM|Routing'
KubeProxyReplacement:    True   [ens3   192.168.10.11 fe80::5054:ff:fe12:3456 (Direct Routing)]
IPAM:                    IPv4: 4/254 allocated from 10.244.1.0/24,
Routing:                 Network: Tunnel [vxlan]   Host: BPF

$ cilium connectivity test
...
✅ [cilium-test-1] All 72 tests (612 actions) successful, 0 tests skipped, 0 scenarios skipped.
```

`cilium connectivity test` creates its own namespace and dozens of test pods, and needs egress to the internet for some tests. On an air-gapped cluster, run it with `--test '!/pod-to-world'`, or use the manual checks in section 10.

---

## 9. Pod-level configuration through runtime capabilities

The capabilities declared in the conflist are what make these pod fields do anything. If `portmap` isn't in the chain, `hostPort` is **silently ignored**. If `bandwidth` isn't, the annotations are ignored.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shaped-web
  namespace: default
  annotations:
    kubernetes.io/ingress-bandwidth: 10M
    kubernetes.io/egress-bandwidth: 10M
spec:
  containers:
    - name: web
      image: nginx:1.27
      ports:
        - containerPort: 80
          hostPort: 8080
          protocol: TCP
```

```
$ kubectl apply -f shaped-web.yaml
$ NODE=$(kubectl get pod shaped-web -o jsonpath='{.spec.nodeName}')
$ curl -s -o /dev/null -w '%{http_code}\n' http://${NODE}:8080/
200
# on that node: the bandwidth plugin put a TBF qdisc on the host-side veth
$ tc qdisc show | grep tbf
qdisc tbf 1: dev cali3f8a92b1c7e root refcnt 2 rate 10Mbit burst 256Mb lat 25ms
```

---

## 10. Verification: prove the network, don't assume it

### 10.1 Test harness

This manifest is complete. It runs an HTTP server on every node (including control plane) and a client, so you can test same-node, cross-node, Service and DNS paths:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cni-check
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: echo
  namespace: cni-check
  labels:
    app: echo
spec:
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: agnhost
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: cni-check
spec:
  selector:
    app: echo
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: cni-check
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command:
        - sleep
        - infinity
```

```
$ kubectl apply -f cni-check.yaml
$ kubectl -n cni-check rollout status ds/echo
daemon set "echo" successfully rolled out

$ kubectl -n cni-check get pods -o wide
NAME         READY   STATUS    RESTARTS   AGE   IP             NODE
client       1/1     Running   0          40s   10.244.1.14    worker-1
echo-8x2pq   1/1     Running   0          40s   10.244.0.7     cp-1
echo-kd9wm   1/1     Running   0          40s   10.244.1.13    worker-1
echo-v4tzn   1/1     Running   0          40s   10.244.2.9     worker-2

# 1. Pod -> pod on every node (same-node and cross-node)
$ for ip in $(kubectl -n cni-check get pods -l app=echo -o jsonpath='{.items[*].status.podIP}'); do
    printf '%-14s ' "$ip"; kubectl -n cni-check exec client -- curl -s --max-time 3 "http://$ip:8080/hostname" || echo FAIL; echo
  done
10.244.0.7     echo-8x2pq
10.244.1.13    echo-kd9wm
10.244.2.9     echo-v4tzn

# 2. Service (kube-proxy or eBPF replacement) + DNS
$ kubectl -n cni-check exec client -- curl -s --max-time 3 http://echo.cni-check.svc.cluster.local/hostname
echo-v4tzn

# 3. MTU: largest unfragmented payload across nodes (VXLAN on 1500 -> pod MTU 1450 -> 1422 payload)
$ kubectl -n cni-check exec client -- ping -c1 -M do -s 1422 10.244.2.9
1430 bytes from 10.244.2.9: icmp_seq=1 ttl=62 time=0.61 ms
$ kubectl -n cni-check exec client -- ping -c1 -M do -s 1423 10.244.2.9
ping: sendmsg: Message too long

# 4. Pod interface as the CNI configured it
$ kubectl -n cni-check exec client -- ip -br addr show eth0
eth0@if14        UP             10.244.1.14/32 fe80::a8c1:abff:fe12:3456/64

$ kubectl delete ns cni-check
```

What each result tells you:

| Result | Diagnosis |
|---|---|
| Same-node OK, cross-node FAIL | Overlay/routing: firewall on UDP 4789/8472, wrong node-address detection, missing routes |
| Pod IP OK, Service FAIL | kube-proxy / KPR problem, or `br_netfilter` missing (bridge CNIs) |
| Service by IP OK, name FAIL | CoreDNS (usually because CoreDNS itself was Pending before the CNI existed) |
| Small pings OK, large transfers hang | MTU: pod MTU larger than underlay minus encapsulation overhead |

---

## 11. Troubleshooting runbook

### 11.1 Work from the failing layer outward

```
$ kubectl describe pod web-7d9c6f5b8-2kxlp | sed -n '/Events/,$p'
Events:
  Type     Reason                  Age   From               Message
  ----     ------                  ----  ----               -------
  Normal   Scheduled               45s   default-scheduler  Successfully assigned default/web-7d9c6f5b8-2kxlp to worker-2
  Warning  FailedCreatePodSandBox  44s   kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "4b1f0c...": plugin type="bridge" failed (add): failed to allocate for range 0: no IP addresses available in range set: 10.244.2.1-10.244.2.254
```

The message tells you **which plugin** (`type="bridge"`), **which verb** (`add`), and **what failed**. Then go to the node:

```
# Runtime's view of network readiness
$ sudo crictl info | jq '.status.conditions'
[
  {
    "type": "RuntimeReady",
    "status": true,
    "reason": "",
    "message": ""
  },
  {
    "type": "NetworkReady",
    "status": true,
    "reason": "",
    "message": ""
  }
]

# What config is loaded (first in lexical order wins)
$ ls -l /etc/cni/net.d/
-rw-r--r--. 1 root root  702 Sep 29 10:14 10-calico.conflist
-rw-------. 1 root root 2741 Sep 29 10:14 calico-kubeconfig

# Validate JSON syntax before blaming the plugin
$ jq . /etc/cni/net.d/10-calico.conflist > /dev/null && echo valid
valid

# Every "type" in the chain must exist as an executable
$ jq -r '.plugins[].type, (.plugins[].ipam.type // empty)' /etc/cni/net.d/10-calico.conflist \
    | sort -u | while read t; do test -x /opt/cni/bin/$t && echo "ok   $t" || echo "MISS $t"; done
ok   bandwidth
ok   calico
ok   calico-ipam
ok   portmap

# Runtime logs around the failure
$ sudo journalctl -u containerd --since "10 min ago" | grep -iE 'cni|sandbox' | tail -5
```

### 11.2 Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---|---|---|
| Node `NotReady`, `cni plugin not initialized` | No valid file in `conf_dir`; CNI DaemonSet not deployed or not scheduled on this node | Install the CNI. Check the DaemonSet's tolerations. Check `ls /etc/cni/net.d`. |
| `failed to find plugin "X" in path [/opt/cni/bin]` | Missing binary: reference plugins not installed, wrong `bin_dir`, or a non-default path (k3s/RKE2) | Install the plugins or fix the runtime config, then restart containerd |
| `no IP addresses available in range set` | host-local IP leak (DEL never ran) or `/24` too small for `maxPods` | Find stale reservations (below). Size node CIDRs above `maxPods`. |
| Pods get IPs from an unexpected range | Two conflists present; the lexically first one wins | Remove the stale file (e.g. `10-flannel.conflist` after migrating), restart the runtime, recreate pods |
| `incompatible CNI versions; config is "1.1.0", plugin supports [...]` | Conflist `cniVersion` newer than a plugin binary | Upgrade the binaries or lower `cniVersion` |
| `flannel` CrashLoop: `pod cidr not assigned` | Cluster built without `--pod-network-cidr` | Set `podSubnet` (controller-manager `--allocate-node-cidrs`), or patch `spec.podCIDR` on each node |
| Cilium agent: `dial tcp 10.96.0.1:443: i/o timeout` | KPR enabled without `k8sServiceHost`/`k8sServicePort` | Set both in values and `helm upgrade` |
| Cross-node traffic only fails | Encapsulation port blocked; Calico autodetected the wrong IP | Open UDP 4789/8472/6081 or proto 4. Set `nodeAddressAutodetectionV4`. |
| Calico CNI `Unauthorized` while `calico-node` is Running | Stale `/etc/cni/net.d/calico-kubeconfig` | Restart the `calico-node` pod on that node (it rewrites the file) |
| Pods run but `hostPort` does nothing | No `portmap` in the chain | Add `portmap` with `capabilities.portMappings` |

### 11.3 host-local IP leaks

```
$ ls /var/lib/cni/networks/k8s-pod-network/ | head
10.244.2.10
10.244.2.11
10.244.2.12
last_reserved_ip.0
lock
$ cat /var/lib/cni/networks/k8s-pod-network/10.244.2.10
4b1f0c9a2e...
eth0
# Is that container ID still a live sandbox?
$ sudo crictl pods -q --no-trunc | grep -c 4b1f0c9a2e
0
```

Files whose ID isn't a live sandbox are leaks. To clean up safely: drain the node, stop the kubelet and containerd, delete only the stale entries, and start them again. The spec-1.1 `GC` verb exists to automate exactly this. Don't wipe the whole directory on a running node, or new pods can receive IPs that running pods still use.

### 11.4 Test a plugin in isolation

When you can't tell whether the fault is the runtime or the plugin, drive the plugin the way the runtime does. A single plugin takes a single network config (not a list) on stdin:

```
$ cat > /tmp/br.json <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "debugnet",
  "type": "bridge",
  "bridge": "dbg0",
  "isGateway": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.99.0.0/24"
  }
}
EOF
$ sudo ip netns add dbg
$ sudo CNI_COMMAND=ADD CNI_CONTAINERID=dbg1 CNI_NETNS=/var/run/netns/dbg \
       CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge < /tmp/br.json
{
    "cniVersion": "1.0.0",
    "interfaces": [
        {"name": "dbg0", "mac": "4a:1c:2e:8b:77:10"},
        {"name": "veth5d3a1c2f", "mac": "96:e2:0b:31:4c:aa"},
        {"name": "eth0", "mac": "d2:7f:61:02:3b:9e", "sandbox": "/var/run/netns/dbg"}
    ],
    "ips": [
        {"interface": 2, "address": "10.99.0.2/24", "gateway": "10.99.0.1"}
    ],
    "dns": {}
}
$ sudo ip netns exec dbg ip -br addr
lo               DOWN
eth0@if23        UP             10.99.0.2/24 fe80::d07f:61ff:fe02:3b9e/64

# Clean up with DEL (it must succeed, and must also succeed a second time: idempotency)
$ sudo CNI_COMMAND=DEL CNI_CONTAINERID=dbg1 CNI_NETNS=/var/run/netns/dbg \
       CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge < /tmp/br.json && echo "exit $?"
exit 0
$ sudo ip netns del dbg && sudo ip link del dbg0
```

To test a **whole conflist**, including the chaining and `prevResult`, use `cnitool` from the [CNI repository](https://github.com/containernetworking/cni/tree/main/cnitool). It finds the list by its `name`:

```
$ go install github.com/containernetworking/cni/cnitool@latest
$ sudo ip netns add dbg
$ sudo NETCONFPATH=/etc/cni/net.d CNI_PATH=/opt/cni/bin ~/go/bin/cnitool add k8s-pod-network /var/run/netns/dbg
$ sudo NETCONFPATH=/etc/cni/net.d CNI_PATH=/opt/cni/bin ~/go/bin/cnitool del k8s-pod-network /var/run/netns/dbg
$ sudo ip netns del dbg
```

Vendor plugins such as `calico` or `cilium-cni` expect Kubernetes `CNI_ARGS` and a running agent, so isolate-testing them this way is less useful. Use the agent's own diagnostics instead: `kubectl get tigerastatus`, `cilium-dbg status`, `cilium-dbg endpoint list`.

### 11.5 Replacing one CNI with another

Pods keep the network they were created with, and changing the conflist affects **only new sandboxes**. A safe migration, node by node:

```
$ kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
# on worker-1: remove the old plugin's config and leftover interfaces
$ sudo rm -f /etc/cni/net.d/10-flannel.conflist
$ sudo ip link del cni0 2>/dev/null; sudo ip link del flannel.1 2>/dev/null
$ sudo rm -rf /var/lib/cni/networks/cbr0
$ sudo systemctl restart containerd
$ kubectl uncordon worker-1
```

Then delete the old CNI's DaemonSet and namespace when you're done. Vendors document in-place migration paths (for example, Cilium's migration guide with per-node labels), and they're preferred over this for live production clusters.

---

## 12. Exam-oriented summary

- The **runtime** calls CNI. The kubelet has no CNI flags. Look at `containerd config dump` / `/etc/crio/crio.conf.d/`.
- **`/etc/cni/net.d`** holds the config, and the lexically first valid file wins. **`/opt/cni/bin`** holds a binary for every `type` in the chain, plus IPAM and `loopback`.
- `cniVersion` must be supported by every binary in the chain.
- Pod CIDR ownership is CNI-specific. Flannel needs `node.spec.podCIDR`; Calico IPAM and Cilium cluster-pool ignore it.
- `NotReady` + `cni plugin not initialized` means no config. `FailedCreatePodSandBox` names the plugin and the verb that failed.
- Verify same-node, cross-node, Service, DNS and MTU separately. Each one fails for different reasons.

---

## References

- CKNE certification page — https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- CNI specification — https://www.cni.dev/docs/spec/
- CNI specification (source, SPEC.md) — https://github.com/containernetworking/cni/blob/main/SPEC.md
- cnitool — https://github.com/containernetworking/cni/tree/main/cnitool
- CNI reference plugins (docs) — https://www.cni.dev/plugins/current/
- CNI reference plugins (releases) — https://github.com/containernetworking/plugins/releases
- Kubernetes: Network Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Kubernetes: Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes: Container Runtimes (prerequisites) — https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes: Creating a cluster with kubeadm — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- Kubernetes: Debugging with crictl — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- containerd CRI plugin configuration — https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- CRI-O configuration (crio.conf) — https://github.com/cri-o/cri-o/blob/main/docs/crio.conf.5.md
- Flannel — https://github.com/flannel-io/flannel
- Calico on-premises installation — https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
- Calico Installation API reference — https://docs.tigera.io/calico/latest/reference/installation/api
- Calico system requirements (ports) — https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements
- Cilium Helm installation — https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Cilium kube-proxy replacement — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Cilium IPAM concepts — https://docs.cilium.io/en/stable/network/concepts/ipam/
- Cilium system requirements — https://docs.cilium.io/en/stable/operations/system_requirements/