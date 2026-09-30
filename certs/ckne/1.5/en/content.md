# 1.5 Configuring Multi-interface Pods

> **Scope note.** The CKNE curriculum lists this objective as "Configuring Multi-interface Pods". Kubernetes has no built-in API for giving a Pod more than one network interface. In practice the objective means the Network Plumbing Working Group (NPWG) de-facto standard: **Multus CNI**, the `NetworkAttachmentDefinition` CRD, the pod selection and status annotations, and the CNI plugins and IPAM drivers that sit behind them. The exam version is listed as *unknown*, so this material covers the upstream mechanics and does not assume a particular exam environment.

---

## 1. Motivation: the architectural problem

### 1.1 The single-interface contract

The Kubernetes network model assumes each Pod gets **one** IP address that is routable to every other Pod in the cluster. That address is used for Services, NetworkPolicy, the Endpoints/EndpointSlice machinery, probes and DNS. The kubelet, through the container runtime (containerd or CRI-O), calls **one** CNI network configuration per sandbox: the first valid file in `/etc/cni/net.d` in lexical order. That configuration creates `eth0` in the Pod's network namespace. The kubelet does nothing else with networking.

This contract works well for stateless microservices. It breaks down for several classes of production workloads:

| Workload | Why one interface is not enough |
|---|---|
| **Telco CNFs (5G UPF, vRouter, SBC)** | They need separate control, user and management planes, often on separate VLANs, with line-rate throughput (SR-IOV/DPDK). |
| **Storage clients (NFS, iSCSI, Ceph public/cluster)** | Storage traffic has to stay off the overlay so it avoids encapsulation overhead and competition with east-west application traffic. Jumbo frames (MTU 9000) are also common. |
| **Legacy integration** | An appliance on a physical L2 segment expects to reach the workload at a fixed IP on *its* subnet, with no NAT or SNAT. |
| **Multicast / L2 protocols** | VRRP, PTP (IEEE 1588), some clustering protocols and financial market-data feeds need L2 adjacency. Overlays usually drop or mangle this traffic. |
| **Network segregation / compliance** | PCI or regulatory rules require management and data traffic on physically or logically separate networks. |
| **Network appliances in K8s** | Firewalls, load balancers or routers packaged as Pods need an "inside" leg and an "outside" leg. |

### 1.2 The solution: a meta-plugin

The CNI specification allows a plugin to call other plugins. **Multus** uses this to act as a *meta-plugin*:

1. Multus is installed as the **first** CNI configuration on each node (`00-multus.conf`), so the runtime calls it instead of the "real" plugin.
2. Multus first calls the **cluster default network** (Calico, Cilium, Flannel, OVN-Kubernetes and so on) to create `eth0`. This keeps the Kubernetes network contract intact.
3. Multus reads the Pod annotation `k8s.v1.cni.cncf.io/networks`, looks up the referenced `NetworkAttachmentDefinition` objects through the API server, and calls each **delegate** plugin in turn (macvlan, ipvlan, bridge, host-device, sriov and others). These create `net1`, `net2`, and so on.
4. Multus writes the aggregated result to the Pod annotation `k8s.v1.cni.cncf.io/network-status`.

```
                        kubelet
                           │ CRI RunPodSandbox
                           ▼
                 containerd / CRI-O
                           │ CNI ADD (reads /etc/cni/net.d/00-multus.conf)
                           ▼
        ┌──────────── multus-shim ─────────────┐
        │   (thin binary in /opt/cni/bin)      │
        └───────────────┬──────────────────────┘
                        │ unix socket
                        ▼
        ┌──────── multus-daemon (DaemonSet) ────────┐
        │ 1. delegate → cluster network  → eth0      │
        │ 2. GET NetworkAttachmentDefinition(s)      │──► kube-apiserver
        │ 3. delegate → macvlan/ipvlan/sriov → net1..│
        │ 4. PATCH pod annotation network-status     │──► kube-apiserver
        └────────────────────────────────────────────┘
```

### 1.3 What you give up

Plan around this before you design a multi-network topology. **Secondary interfaces are invisible to Kubernetes.**

- **Services** do not load-balance to `net1` addresses. kube-proxy, Cilium's kube-proxy replacement and similar components only program the primary IP from `status.podIPs`.
- **NetworkPolicy** does not apply to secondary interfaces. Enforcement engines hook `eth0` or the primary datapath.
- **Probes** go to the primary IP.
- **DNS** (CoreDNS) publishes only primary IPs.
- The secondary IPs appear only in the `network-status` annotation, not in `status.podIPs`.

Upstream work on native multi-network support (KEP-3698 "Multi-Network") exists, but it is not a GA API you can depend on. The production standard today is the NPWG specification implemented by Multus.

---

## 2. Components and technical comparisons

### 2.1 Building blocks

| Component | Role | Where it lives |
|---|---|---|
| **Multus CNI** | Meta-plugin that calls the default network plus N delegates | DaemonSet `kube-multus-ds` in `kube-system`, shim binary in `/opt/cni/bin`, config in `/etc/cni/net.d/00-multus.conf` |
| **NetworkAttachmentDefinition (NAD)** | CRD `network-attachment-definitions.k8s.cni.cncf.io`, short name `net-attach-def`. Holds a CNI config as a JSON string. | Namespaced API object |
| **Reference CNI plugins** | `macvlan`, `ipvlan`, `bridge`, `host-device`, `vlan`, `tuning`, `sbr`, `static`, `host-local`, `dhcp`… | Binaries in `/opt/cni/bin` on **each node** |
| **IPAM plugin** | Assigns addresses to the secondary interface | `host-local`, `static`, `dhcp`, `whereabouts` |
| **Whereabouts** | Cluster-wide IPAM backed by CRDs (`IPPool`, `OverlappingRangeIPReservation`) | DaemonSet plus CRDs |
| **SR-IOV Network Device Plugin** | Advertises VFs as extended resources (`intel.com/...`) | DaemonSet |
| **multi-networkpolicy** | `MultiNetworkPolicy` CRD plus an enforcement implementation for secondary networks | CRD plus DaemonSet |

### 2.2 Multus: thin vs thick plugin

Since Multus v4.0 the recommended deployment is the **thick** plugin, a client/server architecture.

| Aspect | Thin plugin (`multus-daemonset.yml`) | Thick plugin (`multus-daemonset-thick.yml`) |
|---|---|---|
| Binary executed by the runtime | `multus` (does all the work) | `multus-shim` (forwards to the daemon over a unix socket) |
| API server access | Every CNI ADD/DEL runs a new binary process that authenticates with a kubeconfig on disk (`/etc/cni/net.d/multus.d/multus.kubeconfig`) | A long-lived daemon with an informer cache and the Pod's ServiceAccount |
| API server load | Higher (GET Pod and GET NADs on every call) | Lower (cached) |
| Metrics / observability | Minimal | The daemon exposes metrics and logs in one place (`kubectl logs`) |
| Resources | Lighter | Heavier (daemon memory) |
| Recommendation | Legacy or very constrained environments | **Default for new deployments** |

### 2.3 Secondary interface CNI plugins

| Plugin | Mechanism | Throughput | Unique MAC per Pod | Talks to the host through the parent? | Main use case | Main limitation |
|---|---|---|---|---|---|---|
| **macvlan** | L2 sub-interfaces of a physical parent (`master`) | High (no bridge, no veth) | Yes | **No** (by kernel design, parent ↔ children) | Put the Pod directly on the physical L2 segment | The switch or port-security has to accept multiple MACs per port; many clouds filter unknown MACs |
| **ipvlan** | Sub-interfaces that **share the parent's MAC**; modes `l2`, `l3`, `l3s` | High | No (same MAC) | No | Environments with a per-port MAC limit, Wi-Fi, some clouds | DHCP by client-id only; not suitable where each endpoint needs its own MAC |
| **bridge** | Linux bridge on the node plus veth | Medium | Yes | Yes (if the bridge has an IP) | Local node-internal networks, labs, simple VLANs | Does not span nodes unless the bridge enslaves a physical interface or you add routing |
| **host-device** | **Moves** an existing interface from the host into the Pod | Native | The device's own | N/A (the host loses it) | Dedicated NICs, preassigned VFs, VLAN interfaces | One interface per Pod. The host loses the device while the Pod lives. |
| **vlan** | Creates an 802.1Q sub-interface of the `master` in the Pod | High | Yes | No | Tagged VLAN segregation without SR-IOV | One VLAN ID per interface |
| **sriov** | Moves a hardware VF into the Pod | Line-rate, bypasses the host stack | Yes (VF) | Via the switch | Telco, HPC, low latency | Needs SR-IOV hardware, drivers, the device plugin and a finite number of VFs |

#### macvlan modes

| Mode | Child ↔ child traffic on the same parent | Typical use |
|---|---|---|
| `bridge` (default) | Switched internally by the kernel | The most common choice |
| `vepa` | Sent out to the switch, which has to hairpin it back (802.1Qbg) | Force all traffic through an external firewall |
| `private` | Blocked | Isolation between Pods on the same node |
| `passthru` | A single child takes over the parent | One dedicated Pod per NIC |

#### ipvlan modes

| Mode | Behavior |
|---|---|
| `l2` | Similar to macvlan bridge, but all children share one MAC; ARP/NDP are processed by each slave |
| `l3` | The parent routes between slaves; no broadcast/multicast; the external network needs routes to the Pod subnet |
| `l3s` | Like `l3` but traffic crosses netfilter/conntrack in the host namespace (allows iptables rules) |

### 2.4 IPAM for secondary networks

| IPAM | Scope | State | Pros | Cons |
|---|---|---|---|---|
| `host-local` | **Per node** | Files in `/var/lib/cni/networks/<name>` | Simple, no dependencies | **Collisions** if you reuse the same range on several nodes. You have to split the range per node. |
| `static` | Per Pod | None | Fully deterministic; works with the `ips` annotation | You manage every IP by hand; one IP per Deployment replica is impossible without per-Pod annotations |
| `dhcp` | External DHCP server | Needs the `dhcp` daemon running on each node (`/opt/cni/bin/dhcp daemon`) | Integrates with existing corporate IPAM | Extra dependency; with macvlan the DHCP server sees one MAC per Pod |
| **whereabouts** | **Cluster** | CRDs `IPPool` and `OverlappingRangeIPReservation` | One range shared by the whole cluster without collisions; `exclude`, `range_start`/`range_end` | Another component to operate; leaked IPs if Pods die abnormally (it has a reconciler) |

### 2.5 Ways to reference a NAD from a Pod

| Form | Example | Supports |
|---|---|---|
| Short name, same namespace | `k8s.v1.cni.cncf.io/networks: macvlan-a` | Just the attachment |
| Comma-separated list | `macvlan-a,macvlan-b` | Several interfaces |
| `namespace/name` | `infra/storage-net` | NAD in another namespace (unless `namespaceIsolation` blocks it) |
| `name@ifname` | `macvlan-a@data0` | Custom interface name |
| **JSON list** | `[{"name":"macvlan-a","interface":"data0","ips":["10.10.0.50/24"],"mac":"02:00:00:00:00:50","default-route":["10.10.0.1"]}]` | Static IPs, MAC, interface name, default route selection |

---

## 3. Complete manifests and infrastructure

### 3.1 Lab: kind cluster with installed reference plugins

kind nodes ship with only the plugins that kindnet needs (`ptp`, `host-local`, `portmap`, `loopback`). `macvlan`, `ipvlan`, `bridge`, `static`, `tuning` and the rest are **not** included. You have to install them on every node, and this is also the most common failure in real clusters.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: multinet
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
```

```
$ kind create cluster --config kind-multinet.yaml
Creating cluster "multinet" ...
 ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-multinet"

$ CNI_VER=v1.6.2
$ curl -sLO https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-amd64-${CNI_VER}.tgz
$ for n in $(kind get nodes --name multinet); do
    docker cp cni-plugins-linux-amd64-${CNI_VER}.tgz ${n}:/tmp/
    docker exec ${n} tar -xzf /tmp/cni-plugins-linux-amd64-${CNI_VER}.tgz -C /opt/cni/bin
  done

$ docker exec multinet-worker ls /opt/cni/bin
bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan
loopback  macvlan  portmap  ptp  sbr  static  tap  tuning  vlan  vrf
```

> In production, do not copy binaries by hand. Distribute them with a DaemonSet (the Multus thick image installs its own shim, and some distributions such as OpenShift bundle the reference plugins), or bake them into the node image (Packer/AMI/Talos extension).

### 3.2 Installing Multus (thick plugin)

```
$ kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
customresourcedefinition.apiextensions.k8s.io/network-attachment-definitions.k8s.cni.cncf.io created
clusterrole.rbac.authorization.k8s.io/multus created
clusterrolebinding.rbac.authorization.k8s.io/multus created
serviceaccount/multus created
configmap/multus-daemon-config created
daemonset.apps/kube-multus-ds created

$ kubectl -n kube-system rollout status ds/kube-multus-ds
daemon set "kube-multus-ds" successfully rolled out

$ kubectl -n kube-system get pods -l app=multus -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP           NODE
kube-multus-ds-7xq2p   1/1     Running   0          48s   172.18.0.3   multinet-worker
kube-multus-ds-g9m4k   1/1     Running   0          48s   172.18.0.2   multinet-control-plane
kube-multus-ds-vw8lz   1/1     Running   0          48s   172.18.0.4   multinet-worker2
```

> For production, pin a release tag (`.../multus-cni/v4.x.y/deployments/...`) instead of `master`. You want reproducible versions and controlled rollbacks.

Verify what Multus wrote on the node:

```
$ docker exec multinet-worker ls /etc/cni/net.d/
00-multus.conf  10-kindnet.conflist  multus.d

$ docker exec multinet-worker cat /etc/cni/net.d/00-multus.conf
{"cniVersion":"0.3.1","logLevel":"verbose","logToStderr":true,"name":"multus-cni-network","clusterNetwork":"/host/etc/cni/net.d/10-kindnet.conflist","type":"multus-shim"}
```

Key points:
- `00-` sorts before `10-kindnet.conflist`, so the runtime calls Multus.
- `clusterNetwork` points to the original configuration, which becomes the delegate for `eth0`.
- With `"multusConfigFile": "auto"` in the `multus-daemon-config` ConfigMap, Multus picks the first configuration it finds in lexical order. If your primary CNI writes its config **after** Multus starts, or renames it, Multus can end up pointing at the wrong file. More on this in the diagnostics section.

The thick plugin's daemon configuration looks like this:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: multus-daemon-config
  namespace: kube-system
  labels:
    tier: node
    app: multus
data:
  daemon-config.json: |
    {
        "chrootDir": "/hostroot",
        "cniVersion": "0.3.1",
        "logLevel": "verbose",
        "logToStderr": true,
        "cniConfigDir": "/host/etc/cni/net.d",
        "multusAutoconfigDir": "/host/etc/cni/net.d",
        "multusConfigFile": "auto",
        "socketDir": "/host/run/multus/"
    }
```

Useful fields you can add: `"namespaceIsolation": true` (a Pod can only use NADs from its own namespace, plus namespaces listed in `globalNamespaces`) and `"globalNamespaces": "default,infra"`.

### 3.3 Cluster-wide IPAM: Whereabouts

```
$ git clone https://github.com/k8snetworkplumbingwg/whereabouts && cd whereabouts
$ kubectl apply \
    -f doc/crds/daemonset-install.yaml \
    -f doc/crds/whereabouts.cni.cncf.io_ippools.yaml \
    -f doc/crds/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml
serviceaccount/whereabouts created
clusterrolebinding.rbac.authorization.k8s.io/whereabouts created
clusterrole.rbac.authorization.k8s.io/whereabouts-cni created
daemonset.apps/whereabouts created
customresourcedefinition.apiextensions.k8s.io/ippools.whereabouts.cni.cncf.io created
customresourcedefinition.apiextensions.k8s.io/overlappingrangeipreservations.whereabouts.cni.cncf.io created
```

The Whereabouts DaemonSet installs the `whereabouts` binary into `/opt/cni/bin` on every node and writes its own kubeconfig so it can reach the API server.

### 3.4 NetworkAttachmentDefinitions

Namespace for the lab:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: multinet-lab
  labels:
    purpose: multi-interface-lab
```

**a) macvlan in bridge mode with Whereabouts (cluster-wide range):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: data-macvlan
  namespace: multinet-lab
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "data-macvlan",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "mtu": 1500,
      "ipam": {
        "type": "whereabouts",
        "range": "10.10.0.0/24",
        "range_start": "10.10.0.10",
        "range_end": "10.10.0.200",
        "exclude": [
          "10.10.0.100/30"
        ],
        "gateway": "10.10.0.1"
      }
    }
```

> `master` has to exist **with that name on every node** where the Pod can be scheduled. In real clusters NIC names differ between hardware generations (`ens1f0`, `eno2`, `enp65s0f1`). Standardize them with udev/systemd-link rules or with a *bond*, or restrict scheduling with `nodeSelector`/affinity. If you omit `master`, macvlan uses the interface that holds the host's default route.

**b) ipvlan L2 with static IPAM and runtime-supplied IPs (`capabilities.ips`):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: legacy-ipvlan
  namespace: multinet-lab
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "name": "legacy-ipvlan",
      "plugins": [
        {
          "type": "ipvlan",
          "master": "eth0",
          "mode": "l2",
          "capabilities": { "ips": true },
          "ipam": {
            "type": "static",
            "routes": [
              { "dst": "192.168.50.0/24", "gw": "10.20.0.1" }
            ]
          }
        }
      ]
    }
```

Here the NAD defines no address. The IP comes from the Pod annotation (`"ips": [...]`), and Multus passes it as `runtimeConfig` **only if** the plugin declares `"capabilities": { "ips": true }`. Without that capability the `ips` field in the annotation is silently ignored and `static` fails because it has no addresses.

**c) macvlan with a fixed MAC (needs `tuning` in the chain):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: appliance-macvlan
  namespace: multinet-lab
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "name": "appliance-macvlan",
      "plugins": [
        {
          "type": "macvlan",
          "master": "eth0",
          "mode": "bridge",
          "capabilities": { "ips": true },
          "ipam": {
            "type": "static"
          }
        },
        {
          "type": "tuning",
          "capabilities": { "mac": true },
          "sysctl": {
            "net.ipv4.conf.IFNAME.arp_notify": "1"
          }
        }
      ]
    }
```

The `IFNAME` token in the sysctl key is replaced by `tuning` with the real interface name (`net1`, `data0`...).

**d) Local node bridge (L2 within one node, useful for sidecar/appliance chains):**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: node-bridge
  namespace: multinet-lab
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "node-bridge",
      "type": "bridge",
      "bridge": "br-multinet",
      "isGateway": false,
      "ipMasq": false,
      "hairpinMode": false,
      "ipam": {
        "type": "host-local",
        "subnet": "10.30.0.0/24",
        "rangeStart": "10.30.0.10",
        "rangeEnd": "10.30.0.250"
      }
    }
```

> Anti-pattern: `host-local` with the **same** `subnet` on a bridge that enslaves a physical NIC shared across nodes. Each node keeps its own state in `/var/lib/cni/networks/node-bridge/`, so two Pods on different nodes get `10.30.0.10` and you get an intermittent ARP conflict that is hard to diagnose. For multi-node networks use Whereabouts or split ranges per node.

**e) VLAN over a trunk interface:**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan120-storage
  namespace: multinet-lab
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "vlan120-storage",
      "type": "vlan",
      "master": "eth0",
      "vlanId": 120,
      "mtu": 1500,
      "ipam": {
        "type": "whereabouts",
        "range": "172.16.120.0/24",
        "range_start": "172.16.120.20",
        "range_end": "172.16.120.250"
      }
    }
```

**f) SR-IOV (needs hardware and the device plugin):**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriovdp-config
  namespace: kube-system
data:
  config.json: |
    {
      "resourceList": [
        {
          "resourceName": "intel_sriov_netdevice",
          "selectors": {
            "vendors": ["8086"],
            "devices": ["154c", "10ed", "1889"],
            "drivers": ["iavf", "ixgbevf"]
          }
        }
      ]
    }
```

> The `selectors` schema has changed between releases of `sriov-network-device-plugin`. Check the README for the version you deploy.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-fronthaul
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/resourceName: intel.com/intel_sriov_netdevice
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "sriov-fronthaul",
      "type": "sriov",
      "vlan": 300,
      "spoofchk": "on",
      "trust": "off",
      "ipam": {
        "type": "whereabouts",
        "range": "10.40.0.0/24"
      }
    }
```

The `k8s.v1.cni.cncf.io/resourceName` annotation links the NAD to the extended resource. Multus reads the device the kubelet assigned to the container (through the kubelet's PodResources API) and passes the VF's PCI address to the `sriov` plugin. **The Pod still has to request the resource** in `resources.requests/limits`, either explicitly or through the Network Resources Injector webhook, which adds it automatically. Without the request the scheduler does not know the Pod needs a VF, and the sandbox fails.

Apply and list:

```
$ kubectl apply -f ns.yaml -f nad-data-macvlan.yaml -f nad-legacy-ipvlan.yaml \
                -f nad-appliance-macvlan.yaml -f nad-node-bridge.yaml -f nad-vlan120.yaml
namespace/multinet-lab created
networkattachmentdefinition.k8s.cni.cncf.io/data-macvlan created
networkattachmentdefinition.k8s.cni.cncf.io/legacy-ipvlan created
networkattachmentdefinition.k8s.cni.cncf.io/appliance-macvlan created
networkattachmentdefinition.k8s.cni.cncf.io/node-bridge created
networkattachmentdefinition.k8s.cni.cncf.io/vlan120-storage created

$ kubectl -n multinet-lab get net-attach-def
NAME                AGE
appliance-macvlan   6s
data-macvlan        6s
legacy-ipvlan       6s
node-bridge         6s
vlan120-storage     6s
```

> The API server does **not** validate `spec.config` as a CNI configuration. A JSON syntax error, a nonexistent `type` or a wrong `master` only shows up when a Pod tries to use the NAD. Validate the JSON in CI (`jq -e . <<< "$config"`), because the failure otherwise lands at runtime.

### 3.5 Pods and Deployments with multiple interfaces

**Simple Pod, one secondary interface:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client-a
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/networks: data-macvlan
spec:
  nodeSelector:
    kubernetes.io/hostname: multinet-worker
  containers:
  - name: netshoot
    image: nicolaka/netshoot:v0.13
    command: ["sleep", "infinity"]
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
```

**Pod on a different node, with two secondary interfaces and custom names:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client-b
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/networks: data-macvlan@data0,vlan120-storage@stor0
spec:
  nodeSelector:
    kubernetes.io/hostname: multinet-worker2
  containers:
  - name: netshoot
    image: nicolaka/netshoot:v0.13
    command: ["sleep", "infinity"]
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
```

**Pod with a static IP, fixed MAC and default route through the secondary network (JSON form):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: legacy-gw
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "appliance-macvlan",
          "namespace": "multinet-lab",
          "interface": "ext0",
          "ips": ["10.10.0.250/24"],
          "mac": "02:42:0a:0a:00:fa",
          "default-route": ["10.10.0.1"]
        },
        {
          "name": "legacy-ipvlan",
          "interface": "legacy0",
          "ips": ["10.20.0.15/24"]
        }
      ]
spec:
  containers:
  - name: app
    image: nicolaka/netshoot:v0.13
    command: ["sleep", "infinity"]
```

`default-route` moves the Pod's default route to `ext0`. Multus removes the `eth0` default route that the cluster CNI installed. **Consequence:** traffic to the cluster network (Services, kube-dns, other Pods) now needs specific routes through `eth0`. Some cluster CNIs install them and some do not. Test DNS resolution and ClusterIP reachability before you adopt this pattern. A safer alternative is to keep the default route on `eth0` and add specific routes to the external networks in the NAD's IPAM (`"routes"`), or to use the `sbr` (source-based routing) plugin so replies go out through the interface they came in on.

**Deployment with replicas on a secondary network (IPAM has to be dynamic):**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storage-client
  namespace: multinet-lab
spec:
  replicas: 3
  selector:
    matchLabels:
      app: storage-client
  template:
    metadata:
      labels:
        app: storage-client
      annotations:
        k8s.v1.cni.cncf.io/networks: vlan120-storage@stor0
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: storage-client
      containers:
      - name: client
        image: nicolaka/netshoot:v0.13
        command: ["sleep", "infinity"]
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            memory: 64Mi
```

> The annotation goes in `spec.template.metadata.annotations`, **not** in the Deployment's `metadata.annotations`. Putting it on the Deployment is a very common mistake: the Pods come up with only `eth0` and there is no error anywhere.

**Pod consuming an SR-IOV VF:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: upf-0
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/networks: sriov-fronthaul@fh0
spec:
  containers:
  - name: upf
    image: registry.example.com/cnf/upf:1.4.2
    resources:
      requests:
        cpu: "4"
        memory: 8Gi
        intel.com/intel_sriov_netdevice: "1"
      limits:
        cpu: "4"
        memory: 8Gi
        intel.com/intel_sriov_netdevice: "1"
```

### 3.6 Policy for secondary networks: MultiNetworkPolicy

Standard `NetworkPolicy` does not cover `net1+`. The NPWG project `multi-networkpolicy` defines an equivalent CRD that is bound to a NAD through an annotation. Enforcement needs a separate implementation (for example `multi-networkpolicy-iptables`), and each implementation supports a limited set of CNI plugins, so check its compatibility list.

```yaml
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: storage-only-from-clients
  namespace: multinet-lab
  annotations:
    k8s.v1.cni.cncf.io/policy-for: multinet-lab/vlan120-storage
spec:
  podSelector:
    matchLabels:
      app: nfs-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: storage-client
    - ipBlock:
        cidr: 172.16.120.0/24
    ports:
    - protocol: TCP
      port: 2049
```

### 3.7 Coexistence with the primary CNI

| Primary CNI | What to check |
|---|---|
| **Cilium** | By default Cilium takes exclusive ownership of `/etc/cni/net.d` and renames other configurations (`*.cilium_bak`). Set the Helm value `cni.exclusive=false` so `00-multus.conf` survives. |
| **Calico** | Multus has to delegate to `10-calico.conflist`. Check `clusterNetwork` after each Calico upgrade. |
| **OpenShift** | Multus is built in (Cluster Network Operator). You declare additional networks in `networks.operator.openshift.io` or with NADs directly. |
| **Any** | The primary CNI's DaemonSet has to write its config **before** Multus generates `00-multus.conf`, or Multus has to point explicitly at the file (`clusterNetwork`). |

---

## 4. Verification commands and expected output

### 4.1 Pod status and network-status annotation

```
$ kubectl apply -f client-a.yaml -f client-b.yaml
pod/client-a created
pod/client-b created

$ kubectl -n multinet-lab get pods -o wide
NAME       READY   STATUS    RESTARTS   AGE   IP            NODE
client-a   1/1     Running   0          12s   10.244.1.7    multinet-worker
client-b   1/1     Running   0          12s   10.244.2.5    multinet-worker2
```

The `IP` column shows **only** the primary IP. The source of truth for secondary IPs is the annotation:

```
$ kubectl -n multinet-lab get pod client-b \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
[{
    "name": "kindnet",
    "interface": "eth0",
    "ips": [
        "10.244.2.5"
    ],
    "mac": "2e:91:5c:3a:0b:14",
    "default": true,
    "dns": {},
    "gateway": [
        "10.244.2.1"
    ]
},{
    "name": "multinet-lab/data-macvlan",
    "interface": "data0",
    "ips": [
        "10.10.0.11"
    ],
    "mac": "b6:7e:21:9f:40:c2",
    "dns": {}
},{
    "name": "multinet-lab/vlan120-storage",
    "interface": "stor0",
    "ips": [
        "172.16.120.20"
    ],
    "mac": "6a:1d:e0:55:8c:31",
    "dns": {}
}]
```

To extract IPs in scripts:

```
$ kubectl -n multinet-lab get pod client-b \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
  | jq -r '.[] | "\(.interface)\t\(.name)\t\(.ips | join(","))"'
eth0	kindnet	10.244.2.5
data0	multinet-lab/data-macvlan	10.10.0.11
stor0	multinet-lab/vlan120-storage	172.16.120.20
```

> Old versions wrote `k8s.v1.cni.cncf.io/networks-status` (with an "s"). That name is deprecated. Current tooling reads `network-status`.

### 4.2 Inside the Pod

```
$ kubectl -n multinet-lab exec client-b -- ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if9         UP             10.244.2.5/24 fe80::2c91:5cff:fe3a:b14/64
data0@if2        UP             10.10.0.11/24 fe80::b47e:21ff:fe9f:40c2/64
stor0@if2        UP             172.16.120.20/24 fe80::681d:e0ff:fe55:8c31/64

$ kubectl -n multinet-lab exec client-b -- ip -d link show data0
3: data0@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether b6:7e:21:9f:40:c2 brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0 allmulti 0 minmtu 68 maxmtu 65521
    macvlan mode bridge bcqueuelen 1000 usedbcqueuelen 1000 addrgenmode eui64 numtxqueues 1 numrxqueues 1

$ kubectl -n multinet-lab exec client-b -- ip -d link show stor0
4: stor0@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether 6a:1d:e0:55:8c:31 brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0 allmulti 0 minmtu 0 maxmtu 65535
    vlan protocol 802.1Q id 120 <REORDER_HDR> addrgenmode eui64 numtxqueues 1 numrxqueues 1

$ kubectl -n multinet-lab exec client-b -- ip route
default via 10.244.2.1 dev eth0
10.10.0.0/24 dev data0 proto kernel scope link src 10.10.0.11
10.244.2.0/24 via 10.244.2.1 dev eth0 src 10.244.2.5
10.244.2.1 dev eth0 scope link src 10.244.2.5
172.16.120.0/24 dev stor0 proto kernel scope link src 172.16.120.20
```

`@if2` means the parent is interface index 2 in the node's namespace (the node's `eth0`). The default route stays on `eth0`.

### 4.3 Cross-node L2 connectivity over macvlan

```
$ kubectl -n multinet-lab exec client-a -- ip -br addr show net1
net1@if2         UP             10.10.0.10/24 fe80::a0c1:4bff:fe11:9e02/64

$ kubectl -n multinet-lab exec client-a -- ping -c 3 -I net1 10.10.0.11
PING 10.10.0.11 (10.10.0.11) from 10.10.0.10 net1: 56(84) bytes of data.
64 bytes from 10.10.0.11: icmp_seq=1 ttl=64 time=0.212 ms
64 bytes from 10.10.0.11: icmp_seq=2 ttl=64 time=0.098 ms
64 bytes from 10.10.0.11: icmp_seq=3 ttl=64 time=0.101 ms

--- 10.10.0.11 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2031ms
rtt min/avg/max/mdev = 0.098/0.137/0.212/0.052 ms

$ kubectl -n multinet-lab exec client-a -- ip neigh show dev net1
10.10.0.11 lladdr b6:7e:21:9f:40:c2 REACHABLE
```

The neighbor MAC is the macvlan child's MAC on the other node, not the node's MAC. This confirms real L2 adjacency with no encapsulation and no NAT: `ttl=64` means no router hop.

### 4.4 Whereabouts state

```
$ kubectl -n kube-system get ippools.whereabouts.cni.cncf.io
NAME               AGE
10.10.0.0-24       2m
172.16.120.0-24    2m

$ kubectl -n kube-system get ippool 10.10.0.0-24 -o jsonpath='{.spec.allocations}' | jq
{
  "10": {
    "id": "5c1e0e6b0f3a...",
    "ifname": "net1",
    "podref": "multinet-lab/client-a"
  },
  "11": {
    "id": "91d4a7c2e8b1...",
    "ifname": "data0",
    "podref": "multinet-lab/client-b"
  }
}
```

The map keys are **offsets** from the start of the range (`10.10.0.0 + 10 = 10.10.0.10`), not full IPs.

### 4.5 Node-level inspection

```
$ docker exec multinet-worker2 ip -d link show eth0 | head -3
2: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default
    link/ether 02:42:ac:12:00:04 brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0 allmulti 0

$ docker exec multinet-worker2 bash -c 'ls /var/lib/cni/networks/ 2>/dev/null; ls /run/multus/'
cni.sock

$ kubectl -n kube-system logs ds/kube-multus-ds --tail=20 | grep -i client-b
2026-09-30T12:04:11Z [verbose] ADD starting CNI request ContainerID:"3f2a..." Netns:"/var/run/netns/cni-7b0c..." IfName:"eth0" Args:"...K8S_POD_NAMESPACE=multinet-lab;K8S_POD_NAME=client-b..."
2026-09-30T12:04:11Z [verbose] Add: multinet-lab:client-b:...:kindnet(kindnet):eth0 {"cniVersion":"0.3.1",...}
2026-09-30T12:04:11Z [verbose] Add: multinet-lab:client-b:...:multinet-lab/data-macvlan(data-macvlan):data0 {"cniVersion":"0.3.1",...}
2026-09-30T12:04:11Z [verbose] Add: multinet-lab:client-b:...:multinet-lab/vlan120-storage(vlan120-storage):stor0 {"cniVersion":"0.3.1",...}
```

---

## 5. Diagnostics and fault finding

### 5.1 Methodology

Every multi-interface failure happens at one of these layers. Check them in order:

1. **Was the annotation read?** Is it on the Pod, not the Deployment? Is the name spelled exactly `k8s.v1.cni.cncf.io/networks`?
2. **Does the NAD exist and is it reachable?** Right namespace, `namespaceIsolation`, RBAC for Multus.
3. **Is the CNI config valid?** JSON syntax, `type`, `master`, IPAM.
4. **Does the plugin binary exist on that node?** Look in `/opt/cni/bin`.
5. **Did the plugin succeed?** Check the Pod events and the Multus logs.
6. **Is the interface correct in the netns?** Check `ip addr`, `ip route`, `ip -d link`.
7. **Does the physical network accept it?** Consider MAC filtering, VLAN trunking, port-security and cloud anti-spoofing.

The sandbox error shows up as an event on the Pod. The Pod stays in `ContainerCreating`:

```
$ kubectl -n multinet-lab describe pod client-x | sed -n '/Events/,$p'
Events:
  Type     Reason                  Age               From     Message
  ----     ------                  ----              ----     -------
  Warning  FailedCreatePodSandBox  3s (x5 over 50s)  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "a91c...": plugin type="multus-shim" name="multus-cni-network" failed (add): CmdAdd (shim): CNI request failed with status 400: '... error adding container to network "data-macvlan": ...'
```

The useful part is always at the **end** of the message, after `error adding container to network "<nad>"`.

### 5.2 Symptom → cause → fix table

| Symptom (end of the event or behavior) | Probable cause | Fix |
|---|---|---|
| Pod `Running` but only has `eth0`; no `network-status` entry for the NAD | Annotation on the Deployment instead of the template; typo in the key (`k8s.v1.cni.cncf.io/network` without the "s"); Multus not in the chain | Move it to `spec.template.metadata.annotations`; check that `00-multus.conf` is first in `/etc/cni/net.d` on that node |
| `cannot find a network-attachment-definition (data-macvlan) in namespace (default)` | NAD in another namespace, or the Pod in the wrong namespace | Use `namespace/name` or create the NAD in the Pod's namespace; check `namespaceIsolation` |
| `failed to find plugin "macvlan" in path [/opt/cni/bin]` | Reference plugins not installed on **that** node | Install `containernetworking/plugins` on every node (DaemonSet or node image) |
| `failed to lookup master "ens1f0": Link not found` | Parent interface name differs on that node | Standardize NIC names; use `nodeSelector`; or create per-hardware-pool NADs |
| `invalid character '}' looking for beginning of object key string` | Invalid JSON in `spec.config` (trailing comma) | Validate with `jq`; the API server does not validate the content |
| `IPAM plugin returned missing IP config` / `static: missing address` | `static` IPAM without `ips` in the annotation, or `ips` given but the plugin lacks `"capabilities": {"ips": true}` | Add the capability, or put `addresses` in the NAD |
| Two Pods with the same secondary IP, intermittent ARP | `host-local` with the same range on several nodes | Migrate to Whereabouts or split ranges per node |
| `Could not allocate IP in range: ip: 10.10.0.10 / - 10.10.0.200 / range: ...` (Whereabouts) | Range exhausted or leaked allocations | Check `ippool .spec.allocations` for Pods that no longer exist; let the reconciler clean up or remove the stale entry |
| Pods can ping each other over macvlan on the same node, but not across nodes | Switch or hypervisor filters unknown MACs (port-security, AWS/GCP/Azure anti-spoofing, vSphere without *promiscuous/forged transmits*) | Use ipvlan (same MAC as the parent); enable forged transmits/MAC learning; in public clouds use provider-native solutions (secondary ENIs with host-device/ipvlan) |
| The Pod cannot reach its own **node** over macvlan | Kernel design: the macvlan parent does not deliver traffic to or from its own children | Create a macvlan interface on the host in bridge mode on the same parent and put the host IP on it, or use another path (eth0) |
| VLAN reaches the Pod but no traffic flows | Switch port is not a trunk or the VLAN is not allowed; MTU mismatch | Check the switch configuration; `tcpdump -e -i <parent> vlan 120` on the node |
| SR-IOV: `no available VF` / Pod stuck `Pending` with `Insufficient intel.com/intel_sriov_netdevice` | VFs not created (`sriov_numvfs`), device plugin did not advertise them, or the Pod did not request the resource | `cat /sys/class/net/<pf>/device/sriov_numvfs`; `kubectl get node -o jsonpath='{.status.allocatable}'`; add `resources.requests` |
| After upgrading the primary CNI, **every** new Pod fails at sandbox creation | Multus points `clusterNetwork` at a config file that no longer exists (renamed), or Cilium `cni.exclusive=true` moved `00-multus.conf` | Check `/etc/cni/net.d` on the node; restart `kube-multus-ds` to regenerate; set `cni.exclusive=false` |
| Default route moved to `net1` and DNS/Services stopped working | `default-route` in the annotation removed the default on `eth0` | Add specific routes for the Pod/Service CIDRs through eth0, or use specific routes on net1 instead of `default-route` |
| `network-status` annotation missing even though interfaces exist | Multus has no RBAC to `patch pods`, or the thin-plugin kubeconfig has expired | Check ClusterRole `multus`; Multus logs will show `failed to update the pod ... forbidden` |

### 5.3 Deep-dive commands

**List the NAD and its effective config (the JSON is a string, so extract it and validate it):**

```
$ kubectl -n multinet-lab get net-attach-def data-macvlan -o jsonpath='{.spec.config}' | jq -e . >/dev/null && echo "JSON OK"
JSON OK
```

**Check the CNI chain on a specific node:**

```
$ NODE=multinet-worker2
$ kubectl debug node/${NODE} -it --image=busybox:1.36 -- sh -c \
    'ls -l /host/etc/cni/net.d; ls /host/opt/cni/bin | tr "\n" " "'
total 12
-rw-------    1 root root   201 Sep 30 12:01 00-multus.conf
-rw-r--r--    1 root root   509 Sep 30 11:58 10-kindnet.conflist
drwxr-xr-x    2 root root  4096 Sep 30 12:01 multus.d
bandwidth bridge dhcp dummy firewall host-device host-local ipvlan loopback macvlan multus-shim portmap ptp sbr static tap tuning vlan vrf whereabouts
```

**Find the Pod's netns on the node and inspect it directly (useful when the image has no `ip`):**

```
$ crictl pods --name client-b -q
3f2a8b7c1d9e...
$ crictl inspectp 3f2a8b7c1d9e | jq -r '.info.runtimeSpec.linux.namespaces[] | select(.type=="network") | .path'
/var/run/netns/cni-7b0c1a2d-5e6f-4a3b-9c8d-0e1f2a3b4c5d
$ ip netns exec cni-7b0c1a2d-5e6f-4a3b-9c8d-0e1f2a3b4c5d ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
eth0@if9         UP             2e:91:5c:3a:0b:14 <BROADCAST,MULTICAST,UP,LOWER_UP>
data0@if2        UP             b6:7e:21:9f:40:c2 <BROADCAST,MULTICAST,UP,LOWER_UP>
stor0@if2        UP             6a:1d:e0:55:8c:31 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

**Capture on the physical parent to see whether frames leave the node:**

```
$ tcpdump -e -n -i eth0 ether host b6:7e:21:9f:40:c2 -c 4
12:10:02.114233 b6:7e:21:9f:40:c2 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 42: Request who-has 10.10.0.10 tell 10.10.0.11, length 28
12:10:02.114412 a2:c1:4b:11:9e:02 > b6:7e:21:9f:40:c2, ethertype ARP (0x0806), length 42: Reply 10.10.0.10 is-at a2:c1:4b:11:9e:02, length 28
12:10:02.114520 b6:7e:21:9f:40:c2 > a2:c1:4b:11:9e:02, ethertype IPv4 (0x0800), length 98: 10.10.0.11 > 10.10.0.10: ICMP echo request, id 7, seq 1, length 64
12:10:02.114601 a2:c1:4b:11:9e:02 > b6:7e:21:9f:40:c2, ethertype IPv4 (0x0800), length 98: 10.10.0.10 > 10.10.0.11: ICMP echo reply, id 7, seq 1, length 64
```

If you see the ARP *request* go out and no *reply* comes back, the problem is outside the node: switch, MAC filtering or VLAN.

**Raise Multus verbosity temporarily:**

```
$ kubectl -n kube-system get cm multus-daemon-config -o jsonpath='{.data.daemon-config\.json}' | jq .logLevel
"verbose"
$ kubectl -n kube-system rollout restart ds/kube-multus-ds
daemonset.apps/kube-multus-ds restarted
```

Valid levels are `panic`, `error`, `verbose` and `debug`.

### 5.4 Lifecycle and cleanup

- **Deleting a NAD does not affect Pods that are already running.** Their interfaces already exist. The DEL on Pod deletion can fail, though, if Multus no longer finds the NAD (recent versions cache the config used at ADD time for this reason). Delete NADs only after you drain their consumers.
- **Changing `spec.config` of a NAD does not reconfigure live Pods.** Changes apply only to new sandboxes. For a Deployment, run `kubectl rollout restart`.
- **Whereabouts leaks**: if a node dies abruptly, no CNI DEL runs. The Whereabouts reconciler (a CronJob or controller, depending on the version) releases allocations whose `podref` no longer exists. Monitor pool occupancy.

---

## 6. Production design checklist

| Decision | Recommendation |
|---|---|
| Multus mode | Thick plugin, pinned version, `namespaceIsolation: true` in multi-tenant clusters |
| Plugin distribution | Node image or DaemonSet; never by hand |
| Parent NIC | Consistent names across nodes (bond or udev rules), or node pools with `nodeSelector` |
| Plugin choice | Physical L2 with unique MACs: **macvlan**. MAC limits or clouds: **ipvlan**. Performance or telco: **SR-IOV**. Internal to the node: **bridge**. Dedicated NIC: **host-device**. |
| IPAM | Multi-node: **Whereabouts** or external DHCP. Fixed addresses: `static` with `capabilities.ips`. Avoid shared `host-local`. |
| Routing | Keep the default route on `eth0`; specific routes in the NAD; `sbr` if there is asymmetric ingress |
| Security | `MultiNetworkPolicy` plus segmentation on the switch/firewall; secondary networks sit outside `NetworkPolicy` |
| Observability | Alert on `FailedCreatePodSandBox` events; monitor IPPool occupancy; ship `kube-multus-ds` logs |
| GitOps | Manage NADs as code; validate the embedded JSON in CI; `rollout restart` after changing a NAD |
| Primary CNI upgrades | Test on canary nodes; check that `00-multus.conf` and `clusterNetwork` remain valid |

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes: cluster networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes: network plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- KEP-3698 Multi-Network (tracking issue): https://github.com/kubernetes/enhancements/issues/3698
- Multus CNI repository: https://github.com/k8snetworkplumbingwg/multus-cni
- Multus quickstart: https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/quickstart.md
- Multus usage guide (annotations, `ips`, `mac`, `default-route`): https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/how-to-use.md
- Multus configuration reference: https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/configuration.md
- Multus thick plugin: https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/thick-plugin.md
- NPWG multi-network specification (NetworkAttachmentDefinition): https://github.com/k8snetworkplumbingwg/multi-net-spec
- CNI specification: https://www.cni.dev/docs/spec/
- CNI plugin macvlan: https://www.cni.dev/plugins/current/main/macvlan/
- CNI plugin ipvlan: https://www.cni.dev/plugins/current/main/ipvlan/
- CNI plugin bridge: https://www.cni.dev/plugins/current/main/bridge/
- CNI plugin vlan: https://www.cni.dev/plugins/current/main/vlan/
- CNI plugin host-device: https://www.cni.dev/plugins/current/main/host-device/
- CNI IPAM static: https://www.cni.dev/plugins/current/ipam/static/
- CNI IPAM host-local: https://www.cni.dev/plugins/current/ipam/host-local/
- CNI meta-plugin tuning: https://www.cni.dev/plugins/current/meta/tuning/
- CNI meta-plugin sbr: https://www.cni.dev/plugins/current/meta/sbr/
- Reference plugin releases: https://github.com/containernetworking/plugins/releases
- Whereabouts IPAM: https://github.com/k8snetworkplumbingwg/whereabouts
- SR-IOV Network Device Plugin: https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin
- SR-IOV CNI: https://github.com/k8snetworkplumbingwg/sriov-cni
- Network Resources Injector: https://github.com/k8snetworkplumbingwg/network-resources-injector
- MultiNetworkPolicy: https://github.com/k8snetworkplumbingwg/multi-networkpolicy
- Cilium Helm reference (`cni.exclusive`): https://docs.cilium.io/en/stable/helm-reference/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/