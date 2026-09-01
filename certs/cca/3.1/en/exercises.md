# CCA 3.1 — Kubernetes Networking with Cilium
## Guided Exercises (production-grade lab)

> **Exam weight:** 20 %
> **Source of record:** [CCA curriculum](https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md)
> **Reference docs used throughout:** [docs.cilium.io — Concepts / Networking](https://docs.cilium.io/en/stable/network/), [Kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/), [IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/), [Routing](https://docs.cilium.io/en/stable/network/concepts/routing/), [Masquerading](https://docs.cilium.io/en/stable/network/concepts/masquerading/)

---

## 0. Lab prerequisites

You need a Linux host (kernel ≥ 5.10 recommended, ≥ 5.15 for TCX attach), Docker, `kind` ≥ 0.23, `kubectl`, `helm` and the `cilium` CLI (`cilium-cli` ≥ v0.16).

```bash
# Verify the kernel is new enough for the full eBPF datapath
uname -r
# 6.8.0-45-generic

# Verify BPF filesystem support and cgroup v2 (required by socket-LB)
mount | grep -E 'bpf|cgroup2'
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)

cilium version --client
# cilium-cli: v0.16.20 compiled with go1.23.2 on linux/amd64
```

Two conventions used in every exercise:

* `cilium` (the CLI on your laptop) manages the **installation**.
* `cilium-dbg` (the binary **inside** the agent pod) inspects the **datapath**. In Cilium ≤ 1.14 this binary was called `cilium`; since 1.15 it is `cilium-dbg` to remove the ambiguity. Getting these two confused is the single most common source of wasted time in the exam lab.

---

## Exercise 1 — The CNI contract: a cluster with no network

**Goal:** observe exactly which parts of Kubernetes break without a CNI plugin, so that you can later attribute each recovered behaviour to a specific Cilium subsystem.

### Steps

1. Write the cluster definition. Note the three deliberate choices: no default CNI, no kube-proxy, and a Pod CIDR that matches Cilium's cluster-pool default.

```bash
cat > kind-cca.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-net
networking:
  disableDefaultCNI: true      # no kindnet
  kubeProxyMode: "none"        # no iptables/IPVS service proxy
  podSubnet: "10.0.0.0/8"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --config kind-cca.yaml
```

2. Inspect node readiness and the reason behind it.

```bash
kubectl get nodes
```

```
NAME                     STATUS     ROLES           AGE   VERSION
cca-net-control-plane    NotReady   control-plane   45s   v1.31.0
cca-net-worker           NotReady   <none>          25s   v1.31.0
cca-net-worker2          NotReady   <none>          25s   v1.31.0
```

```bash
kubectl describe node cca-net-worker | grep -A3 'Ready '
```

```
  Ready   False   Fri, 01 Sep 2026 10:02:11 +0000   KubeletNotReady
          container runtime network not ready: NetworkReady=false
          reason:NetworkPluginNotReady message:Network plugin returns error:
          cni plugin not initialized
```

3. Confirm the CNI configuration directory is empty and that kubelet is polling it.

```bash
docker exec cca-net-worker ls -la /etc/cni/net.d/
```

```
total 8
drwxr-xr-x 1 root root 4096 Sep  1 10:02 .
drwxrwxr-x 1 root root 4096 Sep  1 10:02 ..
```

4. Observe which Pods still schedule and which do not.

```bash
kubectl get pods -A -o wide
```

```
NAMESPACE     NAME                                            READY   STATUS    IP            NODE
kube-system   coredns-7c65d6cfc9-8xk4p                        0/1     Pending   <none>        <none>
kube-system   etcd-cca-net-control-plane                      1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-apiserver-cca-net-control-plane            1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-controller-manager-cca-net-control-plane   1/1     Running   172.18.0.2    cca-net-control-plane
kube-system   kube-scheduler-cca-net-control-plane            1/1     Running   172.18.0.2    cca-net-control-plane
```

5. Look at what the API server believes about Pod CIDRs, even with no CNI installed.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
```

```
NAME                    PODCIDR
cca-net-control-plane   10.0.0.0/24
cca-net-worker          10.1.0.0/24
cca-net-worker2         10.2.0.0/24
```

### Check your understanding — Block 1

* **Q1.1** — The control-plane Pods (`etcd`, `kube-apiserver`) are `Running` with IP `172.18.0.2` while CoreDNS is `Pending`. What property of the control-plane Pods makes them immune to the missing CNI, and what is the exact IP they carry?
* **Q1.2** — Which component actually reports `NetworkPluginNotReady`: the API server, the scheduler, or the kubelet? Where does that component get the signal from?
* **Q1.3** — `kube-controller-manager` has already assigned `10.1.0.0/24` to `cca-net-worker`. If you now install Cilium with `ipam.mode=cluster-pool`, will Pods on that node receive addresses from `10.1.0.0/24`? Justify.
* **Q1.4** — Name the two artefacts a CNI plugin must place on the node filesystem for kubelet to consider the network ready.

---

## Exercise 2 — Install Cilium and read the datapath status

**Goal:** install Cilium as the CNI **and** as the service proxy, then learn to read `cilium-dbg status --verbose` line by line. That single output answers roughly a third of the datapath questions you will be asked.

### Steps

1. Install Cilium with every relevant knob made explicit rather than defaulted. Being explicit is the point: in the exam you must know which value produces which datapath.

```bash
cilium install --version 1.16.5 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=cca-net-control-plane \
  --set k8sServicePort=6443 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={10.0.0.0/8} \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set bpf.masquerade=true \
  --set operator.replicas=1
```

```
ℹ️  Using Cilium version 1.16.5
🔮 Auto-detected cluster name: kind-cca-net
🔮 Auto-detected kube-proxy has not been installed
ℹ️  Cilium will fully replace all functionalities of kube-proxy
```

2. Wait for convergence and read the CLI-level summary.

```bash
cilium status --wait
```

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet              cilium                   Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator          Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 3
                       cilium-envoy             Running: 3
                       cilium-operator          Running: 1
Cluster Pods:          3/3 managed by Cilium
Helm chart version:    1.16.5
```

3. Verify the node is now Ready and that the CNI conf file appeared.

```bash
kubectl get nodes
docker exec cca-net-worker cat /etc/cni/net.d/05-cilium.conflist
```

```
{
  "cniVersion": "0.3.1",
  "name": "cilium",
  "plugins": [
    {
      "type": "cilium-cni",
      "enable-debug": false,
      "log-file": "/var/run/cilium/cilium-cni.log"
    }
  ]
}
```

4. Create a convenience alias pointing at the agent on one worker. Every later exercise uses it.

```bash
export CIL_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=cca-net-worker \
  -o jsonpath='{.items[0].metadata.name}')
alias cdbg="kubectl -n kube-system exec -i $CIL_POD -c cilium-agent -- cilium-dbg"
echo $CIL_POD
```

5. Read the full datapath status.

```bash
cdbg status --verbose | head -45
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.0) [linux/amd64]
KubeProxyReplacement:    True   [eth0   172.18.0.3 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
Cilium:                  Ok   1.16.5 (v1.16.5-a1b2c3d4)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 3/254 allocated from 10.0.1.0/24,
Allocated addresses:
  10.0.1.19 (kube-system/coredns-7c65d6cfc9-8xk4p)
  10.0.1.135 (health)
  10.0.1.170 (router)
ClusterMesh:             0/0 clusters ready
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       48/48 healthy
Proxy Status:            OK, ip 10.0.1.170, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Encryption:              Disabled
Cluster health:          3/3 reachable   (2026-09-01T10:14:02Z)
Modules Health:          Stopped(0) Degraded(0) OK(82)
```

6. Inspect the specific kube-proxy-replacement details.

```bash
cdbg status --verbose | grep -A14 'KubeProxyReplacement Details'
```

```
KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0  172.18.0.3 fe80::42:acff:fe12:3 (Direct Routing)
  Mode:                   SNAT
  Backend Selection:      Random
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Disabled
  Services:
  - ClusterIP:            Enabled
  - NodePort:             Enabled (Range: 30000-32767)
  - LoadBalancer:         Enabled
  - externalIPs:          Enabled
  - HostPort:             Enabled
```

### Check your understanding — Block 2

* **Q2.1** — `Routing: Network: Tunnel [vxlan]   Host: BPF`. Decompose this line: what does *Network* describe, what does *Host* describe, and what would each field read if you had installed with `routingMode=native` and `bpf.masquerade=false`?
* **Q2.2** — The `IPAM` line shows `3/254 allocated from 10.0.1.0/24`, yet `.spec.podCIDR` for this node was `10.1.0.0/24`. Which component allocated `10.0.1.0/24`, and where is that allocation persisted?
* **Q2.3** — Three of the allocated addresses belong to no user Pod: `health`, `router`, and a CoreDNS Pod. What is the `router` IP (also called `cilium_host` IP) used for, and what is `health` used for?
* **Q2.4** — Why does `cilium install` require `k8sServiceHost` / `k8sServicePort` when kube-proxy is absent? Describe the bootstrap circularity that this breaks.
* **Q2.5** — `Attach Mode: TCX`. What is the alternative, and which kernel version introduced TCX?

---

## Exercise 3 — IPAM: how a Pod gets its address

**Goal:** trace an IP address from the operator's pool, through the `CiliumNode` CRD, to the `CiliumEndpoint` and finally to the veth pair in the Pod's netns.

### Steps

1. Look at the per-node allocation object.

```bash
kubectl get ciliumnodes
```

```
NAME                    CILIUMINTERNALIP   INTERNALIP    AGE
cca-net-control-plane   10.0.0.144         172.18.0.2    6m
cca-net-worker          10.0.1.170         172.18.0.3    6m
cca-net-worker2         10.0.2.61          172.18.0.4    6m
```

```bash
kubectl get ciliumnode cca-net-worker -o jsonpath='{.spec.ipam.podCIDRs}{"\n"}'
```

```
["10.0.1.0/24"]
```

2. Deploy a workload spread across both workers.

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=4
kubectl rollout status deploy/web
kubectl get pods -o wide -l app=web
```

```
NAME                   READY   STATUS    IP           NODE
web-6f8d4c9b7-2wqzr    1/1     Running   10.0.1.201   cca-net-worker
web-6f8d4c9b7-6rjhk    1/1     Running   10.0.2.118   cca-net-worker2
web-6f8d4c9b7-9lbxc    1/1     Running   10.0.1.44    cca-net-worker
web-6f8d4c9b7-pmt8z    1/1     Running   10.0.2.203   cca-net-worker2
```

3. Look at the Cilium-side object for one Pod.

```bash
kubectl get ciliumendpoints
```

```
NAME                  SECURITY IDENTITY   ENDPOINT STATE   IPV4         IPV6
web-6f8d4c9b7-2wqzr   14127               ready            10.0.1.201
web-6f8d4c9b7-6rjhk   14127               ready            10.0.2.118
web-6f8d4c9b7-9lbxc   14127               ready            10.0.1.44
web-6f8d4c9b7-pmt8z   14127               ready            10.0.2.203
```

4. Correlate with the agent's endpoint table on `cca-net-worker`.

```bash
cdbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS                              IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
331        Disabled           Disabled          4          reserved:health                     10.0.1.135   ready
794        Disabled           Disabled          14127      k8s:app=web                         10.0.1.44    ready
1288       Disabled           Disabled          1          reserved:host                                    ready
2104       Disabled           Disabled          14127      k8s:app=web                         10.0.1.201   ready
3376       Disabled           Disabled          25911      k8s:k8s-app=kube-dns                10.0.1.19    ready
```

5. Inspect the datapath plumbing on the node for endpoint `2104`.

```bash
cdbg endpoint get 2104 -o jsonpath='{[0].status.networking}' | python3 -m json.tool
```

```json
{
    "addressing": [{"ipv4": "10.0.1.201", "ipv4-pool-name": "default"}],
    "host-mac": "3e:1a:9c:44:8b:02",
    "interface-index": 14,
    "interface-name": "lxc7f3a19d2c0e4",
    "mac": "ba:0c:11:8e:7d:41"
}
```

```bash
docker exec cca-net-worker ip -d link show lxc7f3a19d2c0e4
```

```
14: lxc7f3a19d2c0e4@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP
    link/ether 3e:1a:9c:44:8b:02 brd ff:ff:ff:ff:ff:ff link-netnsid 2
    veth
```

6. Confirm the eBPF programs attached to that interface.

```bash
docker exec cca-net-worker bpftool net show dev lxc7f3a19d2c0e4
```

```
tc:
lxc7f3a19d2c0e4(14) tcx/ingress cil_from_container prog_id 412 link_id 39
lxc7f3a19d2c0e4(14) tcx/egress cil_to_container prog_id 418 link_id 40
```

7. Look inside the Pod's network namespace.

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- ip route
```

```
default via 10.0.1.170 dev eth0 mtu 1450
10.0.1.170 dev eth0 scope link
```

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- ip neigh
```

```
10.0.1.170 dev eth0 lladdr 3e:1a:9c:44:8b:02 PERMANENT
```

### Check your understanding — Block 3

* **Q3.1** — The Pod's default gateway is `10.0.1.170`, which is the node's `cilium_host` (router) IP, and the ARP entry for it is `PERMANENT`. Why does Cilium install a static neighbour entry instead of relying on ARP resolution? What is the MAC address it points at?
* **Q3.2** — Every Pod has exactly two routes and a `/32`-style setup rather than a subnet route to `10.0.1.0/24`. Explain the design intent — where is the forwarding decision actually made?
* **Q3.3** — The `lxc*` interface has `mtu 1450` while the node's `eth0` has 1500. Compute the 50-byte delta for VXLAN. What would the value be with Geneve, and with WireGuard encryption enabled on top?
* **Q3.4** — All four `web` Pods share security identity `14127`, and the identity is identical on both nodes. What is the scope of a security identity, and which component allocates it?
* **Q3.5** — Endpoint `1288` has identity `1` (`reserved:host`) and no IPv4 in the listing. What does this endpoint represent, and why does it matter for `hostNetwork` Pods?

---

## Exercise 4 — Routing mode: tunnel (VXLAN) versus native routing

**Goal:** see the encapsulation on the wire, read the tunnel map, then switch the cluster to native routing and observe the datapath change.

### Steps

1. Read the tunnel map on `cca-net-worker`. It maps *remote Pod CIDR* → *remote node underlay IP*.

```bash
cdbg bpf tunnel list
```

```
TUNNEL         VALUE
10.0.0.0:0     172.18.0.2:0
10.0.2.0:0     172.18.0.4:0
```

2. Confirm the tunnel device and its port.

```bash
docker exec cca-net-worker ip -d link show cilium_vxlan
```

```
6: cilium_vxlan: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN
    link/ether 4a:8e:11:0f:2b:73 brd ff:ff:ff:ff:ff:ff
    vxlan external id 0 srcport 0 0 dstport 8472 nolearning ttl auto ageing 300 udpcsum
```

3. Capture a cross-node Pod-to-Pod packet on the underlay interface. In one terminal:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'udp port 8472' -c 4 -vv
```

In a second terminal, generate the traffic (source on `worker`, destination on `worker2`):

```bash
kubectl exec web-6f8d4c9b7-2wqzr -- curl -s -o /dev/null -w '%{http_code}\n' http://10.0.2.118
```

Expected capture:

```
10:31:44.118203 172.18.0.3.51923 > 172.18.0.4.8472: VXLAN, flags [I] (0x08), vni 0
    10.0.1.201.44112 > 10.0.2.118.80: Flags [S], seq 2839114923, win 64860,
      options [mss 1410,sackOK,TS val 913 ecr 0,nop,wscale 7], length 0
10:31:44.118688 172.18.0.4.39117 > 172.18.0.3.8472: VXLAN, flags [I] (0x08), vni 0
    10.0.2.118.80 > 10.0.1.201.44112: Flags [S.], seq 1194772341, ack 2839114924, ...
```

4. Note the *absence* of source NAT: the inner source is still the Pod IP `10.0.1.201`. Verify why by reading the masquerade CIDR.

```bash
cdbg status | grep Masquerading
```

```
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

5. Now switch the cluster to **native routing**. In kind, all nodes sit on the same Docker bridge, so they are L2-adjacent and `autoDirectNodeRoutes` can install the routes.

```bash
cilium upgrade --reuse-values \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Verify the new datapath.

```bash
cdbg status | grep -E 'Routing|Masquerading'
```

```
Routing:        Network: Native   Host: BPF
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

```bash
docker exec cca-net-worker ip route
```

```
default via 172.18.0.1 dev eth0
10.0.0.0/24 via 172.18.0.2 dev eth0 proto kernel
10.0.1.0/24 via 10.0.1.170 dev cilium_host proto kernel src 10.0.1.170
10.0.1.170 dev cilium_host proto kernel scope link
10.0.2.0/24 via 172.18.0.4 dev eth0 proto kernel
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.3
```

7. Confirm the tunnel map is now empty and the MTU recovered.

```bash
cdbg bpf tunnel list
```

```
TUNNEL   VALUE
```

```bash
kubectl delete pod -l app=web --wait
kubectl exec deploy/web -- ip link show eth0 | head -1
```

```
25: eth0@if26: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
```

8. Capture again — the packet is now unencapsulated.

```bash
docker exec cca-net-worker tcpdump -ni eth0 'net 10.0.0.0/8 and tcp port 80' -c 2
```

```
10:44:02.771 IP 10.0.1.58.49224 > 10.0.2.91.80: Flags [S], seq 771290033, win 64240, length 0
10:44:02.772 IP 10.0.2.91.80 > 10.0.1.58.49224: Flags [S.], seq 33091772, ack 771290034, length 0
```

### Check your understanding — Block 4

* **Q4.1** — The VXLAN device uses destination port **8472**, not the IANA-assigned 4789. Why? Which port would Geneve use?
* **Q4.2** — The `cilium_vxlan` device shows `external` and `id 0` (VNI 0). What does "external mode" mean, and which component supplies the tunnel key at runtime?
* **Q4.3** — In step 3 the inner source IP is the Pod IP, unmasqueraded. State the masquerading rule Cilium applies by default and why `10.0.2.118` is exempt from it.
* **Q4.4** — `autoDirectNodeRoutes=true` worked in kind. Name the topology precondition it requires, and describe what you must do instead in a cloud VPC where nodes sit in different subnets.
* **Q4.5** — After switching to native routing, why did existing Pods keep MTU 1450 until they were recreated? What is the production-safe procedure for this change?
* **Q4.6** — `ipv4NativeRoutingCIDR=10.0.0.0/8` is mandatory in native mode with BPF masquerade. What does the agent do with traffic destined *outside* that CIDR?

---

## Exercise 5 — Identity, ipcache, and how Cilium knows who is who

**Goal:** understand the identity model, which is the substrate for both policy and observability.

### Steps

1. List identities cluster-wide.

```bash
kubectl get ciliumidentities
```

```
NAME    NAMESPACE     AGE
14127   default       21m
25911   kube-system   28m
39204   kube-system   28m
```

2. Inspect one identity's label set.

```bash
cdbg identity get 14127
```

```
ID      LABELS
14127   k8s:app=web
        k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
        k8s:io.cilium.k8s.policy.cluster=kind-cca-net
        k8s:io.cilium.k8s.policy.serviceaccount=default
        k8s:io.kubernetes.pod.namespace=default
```

3. List the reserved identities.

```bash
cdbg identity list | head -12
```

```
ID     LABELS
1      reserved:host
2      reserved:world
3      reserved:unmanaged
4      reserved:health
5      reserved:init
6      reserved:remote-node
7      reserved:kube-apiserver
8      reserved:ingress
```

4. Read the ipcache — the IP → identity (+ tunnel endpoint) map that every eBPF program consults.

```bash
cdbg bpf ipcache list | head -12
```

```
IP PREFIX/ADDRESS   IDENTITY
0.0.0.0/0           identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.44/32        identity=14127 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.170/32       identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.2.118/32       identity=14127 encryptkey=0 tunnelendpoint=172.18.0.4 flags=<none>
10.0.2.0/24         identity=2 encryptkey=0 tunnelendpoint=172.18.0.4 flags=<none>
172.18.0.2/32       identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
172.18.0.4/32       identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

5. Prove that identity is label-derived, not IP-derived: add a label and watch the identity change.

```bash
kubectl label pod -l app=web tier=frontend
sleep 5
kubectl get ciliumendpoints -l app=web
```

```
NAME                  SECURITY IDENTITY   ENDPOINT STATE   IPV4
web-6f8d4c9b7-2wqzr   51338               ready            10.0.1.201
web-6f8d4c9b7-6rjhk   51338               ready            10.0.2.118
web-6f8d4c9b7-9lbxc   51338               ready            10.0.1.44
web-6f8d4c9b7-pmt8z   51338               ready            10.0.2.203
```

6. Confirm the ipcache was updated on the *other* node too.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg bpf ipcache get 10.0.1.201
```

```
10.0.1.201 maps to identity identity=51338 encryptkey=0 tunnelendpoint=172.18.0.3 flags=<none>
```

### Check your understanding — Block 5

* **Q5.1** — Identity `14127` was allocated once and used by four Pods on two nodes. What is the numeric range for cluster-scoped ("global") identities, and where are they stored in a CRD-mode installation?
* **Q5.2** — In the ipcache, `10.0.2.118/32` has `tunnelendpoint=172.18.0.4` while `10.0.1.44/32` has `0.0.0.0`. Explain both values from the perspective of the agent on `cca-net-worker`.
* **Q5.3** — Distinguish `reserved:host` (1) from `reserved:remote-node` (6). Why did Cilium split these two, and what breaks if you write a policy assuming they are the same?
* **Q5.4** — `0.0.0.0/0 → identity=2 (reserved:world)`. Given longest-prefix-match semantics, what happens to a packet destined to an IP that has a more specific ipcache entry, e.g. a CIDR-based policy entry?
* **Q5.5** — Adding the label `tier=frontend` changed the identity from `14127` to `51338`. What is the security consequence of this during the propagation window, and which Cilium feature exists to avoid a policy gap on new endpoints?

---

## Exercise 6 — kube-proxy replacement: services in eBPF

**Goal:** read the eBPF service and backend maps, and demonstrate socket-level load balancing (connection-time translation) as distinct from packet-level NAT.

### Steps

1. Expose the deployment and read the service tables.

```bash
kubectl expose deployment web --port=80 --target-port=80 --name=web-svc
kubectl get svc web-svc
```

```
NAME      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.142.201   <none>        80/TCP    8s
```

```bash
cdbg service list
```

```
ID   Frontend               Service Type   Backend
1    10.96.0.1:443/TCP      ClusterIP      1 => 172.18.0.2:6443 (active)
2    10.96.0.10:53/UDP      ClusterIP      1 => 10.0.1.19:53 (active)
                                           2 => 10.0.2.31:53 (active)
3    10.96.0.10:53/TCP      ClusterIP      1 => 10.0.1.19:53 (active)
                                           2 => 10.0.2.31:53 (active)
4    10.96.0.10:9153/TCP    ClusterIP      1 => 10.0.1.19:9153 (active)
                                           2 => 10.0.2.31:9153 (active)
9    10.96.142.201:80/TCP   ClusterIP      1 => 10.0.1.201:80 (active)
                                           2 => 10.0.1.44:80 (active)
                                           3 => 10.0.2.118:80 (active)
                                           4 => 10.0.2.203:80 (active)
```

2. Read the raw eBPF map behind it.

```bash
cdbg bpf lb list | grep -A5 '10.96.142.201'
```

```
10.96.142.201:80/TCP (0)   0.0.0.0:0 (9) (0) [ClusterIP, non-routable]
10.96.142.201:80/TCP (1)   10.0.1.201:80 (9) (1)
10.96.142.201:80/TCP (2)   10.0.1.44:80 (9) (2)
10.96.142.201:80/TCP (3)   10.0.2.118:80 (9) (3)
10.96.142.201:80/TCP (4)   10.0.2.203:80 (9) (4)
```

3. Confirm there are **no** iptables rules doing service translation.

```bash
docker exec cca-net-worker iptables-save -t nat | grep -c KUBE-SERVICES
```

```
0
```

```bash
docker exec cca-net-worker iptables-save -t nat | grep -c CILIUM
```

```
6
```

4. Demonstrate socket LB. Run a client and capture inside the Pod's own namespace.

```bash
kubectl run client --image=nicolaka/netshoot:v0.13 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/client
```

Terminal A — capture inside the client Pod:

```bash
kubectl exec client -- timeout 15 tcpdump -ni eth0 'tcp port 80' -c 2
```

Terminal B — generate the request:

```bash
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web-svc
```

Terminal A output:

```
10:58:31.402 IP 10.0.1.77.38412 > 10.0.1.44.80: Flags [S], seq 405512093, win 64860, length 0
10:58:31.403 IP 10.0.1.44.80 > 10.0.1.77.38412: Flags [S.], seq 2210345, ack 405512094, length 0
```

5. Confirm from userspace inside the Pod that the kernel already rewrote the peer.

```bash
kubectl exec client -- sh -c 'curl -s -o /dev/null http://web-svc & sleep 1; ss -tnp | grep :80'
```

```
ESTAB  0  0   10.0.1.77:38416   10.0.1.44:80   users:(("curl",pid=41,fd=5))
```

6. Verify the cgroup-attached programs that implement it.

```bash
docker exec cca-net-worker bpftool cgroup show /run/cilium/cgroupv2
```

```
ID    AttachType        AttachFlags  Name
231   cgroup_inet4_connect          cil_sock4_connect
233   cgroup_inet4_post_bind        cil_sock4_post_bind
235   cgroup_inet4_getpeername      cil_sock4_getpeername
239   cgroup_udp4_sendmsg           cil_sock4_sendmsg
241   cgroup_udp4_recvmsg           cil_sock4_recvmsg
```

7. Distribution check.

```bash
for i in $(seq 1 20); do
  kubectl exec client -- curl -s http://web-svc -o /dev/null -w '%{remote_ip}\n'
done | sort | uniq -c
```

```
      6 10.0.1.201
      4 10.0.1.44
      5 10.0.2.118
      5 10.0.2.203
```

### Check your understanding — Block 6

* **Q6.1** — The `tcpdump` inside the client Pod shows the **backend** IP `10.0.1.44`, never the ClusterIP `10.96.142.201`. At which point in the syscall path did the translation occur, and which eBPF program did it?
* **Q6.2** — Given Q6.1, what does an application see if it calls `getpeername(2)` on that socket, and why does Cilium attach `cil_sock4_getpeername`?
* **Q6.3** — Entry `10.96.142.201:80/TCP (0)` maps to `0.0.0.0:0` and is flagged `[ClusterIP, non-routable]`. What is slot 0 for?
* **Q6.4** — `iptables -t nat` still contains 6 `CILIUM` rules even with full kube-proxy replacement. What are those rules for, and why are they not service translation?
* **Q6.5** — Socket LB is `Full` coverage here. Under what circumstance would `cilium-dbg status` report `Socket LB Coverage: Hostns-only`, and which datapath handles Pod traffic in that case?
* **Q6.6** — A colleague claims "socket LB breaks Kubernetes NetworkPolicy on the client side because the ClusterIP is gone before policy runs." Is that correct? Reason about where egress policy is evaluated.

---

## Exercise 7 — NodePort, source IP preservation, DSR and Maglev

**Goal:** understand the three externally reachable service paths and the trade-offs of `SNAT` versus `DSR` versus `Hybrid`, and of `Random` versus `Maglev` backend selection.

### Steps

1. Convert the service to NodePort and inspect the generated frontends.

```bash
kubectl patch svc web-svc -p '{"spec":{"type":"NodePort"}}'
kubectl get svc web-svc
```

```
NAME      TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
web-svc   NodePort   10.96.142.201   <none>        80:31544/TCP   22m
```

```bash
cdbg service list | grep -A8 31544
```

```
9    10.96.142.201:80/TCP    ClusterIP   1 => 10.0.1.201:80 (active)
                                         2 => 10.0.1.44:80 (active)
                                         3 => 10.0.2.118:80 (active)
                                         4 => 10.0.2.203:80 (active)
10   0.0.0.0:31544/TCP       NodePort    1 => 10.0.1.201:80 (active)
                                         ...
11   172.18.0.3:31544/TCP    NodePort    1 => 10.0.1.201:80 (active)
                                         ...
```

2. Call the NodePort from **outside** the cluster and observe the source IP the backend sees.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix
```

```
[pod/web-6f8d4c9b7-pmt8z/nginx] 172.18.0.3 - - [01/Sep/2026:11:12:07 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.5.0"
```

3. Observe the SNAT state that made the reply route back correctly.

```bash
cdbg bpf nat list | grep 31544 | head -4
```

```
TCP IN 172.18.0.1:54120 -> 172.18.0.3:31544 XLATE_DST 172.18.0.3:54120  Created=12sec ago NeedsCT=1
TCP OUT 172.18.0.3:54120 -> 10.0.2.203:80 XLATE_SRC 172.18.0.1:54120  Created=12sec ago NeedsCT=1
```

4. Set `externalTrafficPolicy: Local` and re-test.

```bash
kubectl patch svc web-svc -p '{"spec":{"externalTrafficPolicy":"Local"}}'
cdbg service list | grep -A4 '172.18.0.3:31544'
```

```
11   172.18.0.3:31544/TCP   NodePort   1 => 10.0.1.201:80 (active)
                                       2 => 10.0.1.44:80 (active)
```

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix | grep -v '^$'
```

```
[pod/web-6f8d4c9b7-9lbxc/nginx] 172.18.0.1 - - [01/Sep/2026:11:15:44 +0000] "GET / HTTP/1.1" 200 615
```

5. Switch the load-balancer to **DSR with Geneve dispatch** and **Maglev** backend selection.

```bash
cilium upgrade --reuse-values \
  --set loadBalancer.mode=dsr \
  --set loadBalancer.dsrDispatch=geneve \
  --set loadBalancer.algorithm=maglev \
  --set maglev.tableSize=16381 \
  --set maglev.hashSeed=$(head -c12 /dev/urandom | base64 -w0)

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Confirm the new mode.

```bash
cdbg status --verbose | grep -E 'Mode:|Backend Selection'
```

```
  Mode:                  DSR
  Backend Selection:     Maglev (Table Size: 16381)
```

7. Inspect the Maglev lookup table for the service.

```bash
cdbg bpf lb maglev list
```

```
SVC ID   LOOKUP TABLE
9        [2 4 1 3 2 1 4 3 1 2 3 4 4 1 2 3 ...]
10       [3 1 4 2 3 4 1 2 2 3 1 4 ...]
```

8. Reset `externalTrafficPolicy` to `Cluster` and verify that with DSR the client IP survives even for a cross-node hop.

```bash
kubectl patch svc web-svc -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
curl -s -o /dev/null http://172.18.0.3:31544
kubectl logs -l app=web --tail=1 --prefix
```

```
[pod/web-6f8d4c9b7-6rjhk/nginx] 172.18.0.1 - - [01/Sep/2026:11:22:03 +0000] "GET / HTTP/1.1" 200 615
```

### Check your understanding — Block 7

* **Q7.1** — In step 1, three frontends were created for one service: `10.96.142.201:80`, `0.0.0.0:31544` and `172.18.0.3:31544`. What is each one for, and why is a wildcard `0.0.0.0` frontend not sufficient on its own?
* **Q7.2** — With SNAT mode and `externalTrafficPolicy: Cluster`, nginx logged `172.18.0.3` (the node) instead of the real client. Explain the mechanism and name the exact trade-off `externalTrafficPolicy: Local` makes to fix it.
* **Q7.3** — In DSR mode with `externalTrafficPolicy: Cluster`, the client IP `172.18.0.1` was preserved **and** the request was served by a Pod on a different node. Describe the return path of the reply packet — which node does it leave from, and what source address does it carry?
* **Q7.4** — DSR needs to convey the original service VIP/port to the backend node. Compare the three `dsrDispatch` options (`opt`, `geneve`, `ipip`) and state one concrete environment where `opt` fails.
* **Q7.5** — `maglev.tableSize=16381`. Why must this be a prime number, and what is the operational consequence of two nodes in the same cluster having different `maglev.hashSeed` values?
* **Q7.6** — Contrast `Random` and `Maglev` backend selection for a *new* connection when one backend is removed. Which one causes fewer existing flows on other nodes to be re-hashed, and why does this matter with DSR specifically?

---

## Exercise 8 — Masquerading and egress to the outside world

**Goal:** distinguish eBPF masquerading from iptables masquerading, and control which destinations are exempt.

### Steps

1. Confirm the masquerade mode and the interface it is bound to.

```bash
cdbg status | grep Masquerading
```

```
Masquerading:   BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
```

2. Verify there is no iptables masquerade rule for Pod traffic.

```bash
docker exec cca-net-worker iptables-save -t nat | grep -i masq
```

```
(no output)
```

3. Generate egress to an address outside the cluster and capture on the node uplink.

Terminal A:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'icmp' -c 2
```

Terminal B:

```bash
kubectl exec client -- ping -c 2 172.18.0.1
```

Terminal A output:

```
11:33:12.881 IP 172.18.0.3 > 172.18.0.1: ICMP echo request, id 12, seq 1, length 64
11:33:12.881 IP 172.18.0.1 > 172.18.0.3: ICMP echo reply, id 12, seq 1, length 64
```

4. Inspect the NAT map entry created for it.

```bash
cdbg bpf nat list | grep ICMP | head -2
```

```
ICMP OUT 10.0.1.77:12 -> 172.18.0.1:0 XLATE_SRC 172.18.0.3:32410 Created=3sec ago NeedsCT=1
ICMP IN 172.18.0.1:32410 -> 172.18.0.3:0 XLATE_DST 10.0.1.77:12 Created=3sec ago NeedsCT=1
```

5. Add an exemption so that traffic to a specific external CIDR keeps the Pod source IP.

```bash
cilium upgrade --reuse-values \
  --set ipMasqAgent.enabled=true \
  --set ipMasqAgent.config.nonMasqueradeCIDRs='{172.18.0.0/16}' \
  --set ipMasqAgent.config.masqLinkLocal=false

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

6. Verify the exemption map and re-test.

```bash
cdbg bpf ipmasq list
```

```
IP PREFIX/ADDRESS
169.254.0.0/16
172.18.0.0/16
```

Terminal A:

```bash
docker exec cca-net-worker tcpdump -ni eth0 'icmp' -c 1
```

Terminal B:

```bash
kubectl exec client -- ping -c 1 172.18.0.1
```

Terminal A output:

```
11:41:55.220 IP 10.0.1.77 > 172.18.0.1: ICMP echo request, id 14, seq 1, length 64
```

### Check your understanding — Block 8

* **Q8.1** — With `bpf.masquerade=true`, at which hook and on which interface is the masquerade performed? What is the equivalent when `bpf.masquerade=false`?
* **Q8.2** — The `Masquerading` line shows the CIDR `10.0.0.0/8`. State precisely the predicate Cilium uses to decide "masquerade or not" in native routing mode.
* **Q8.3** — In step 4, the ICMP `id` field `12` was rewritten to `32410` in `XLATE_SRC`. Why does an ICMP echo need a NAT "port" at all?
* **Q8.4** — After the `ipMasqAgent` change, the ping left the node with source `10.0.1.77`. What must be true of the network `172.18.0.0/16` for the reply to come back? Name the failure mode if it is not true.
* **Q8.5** — You need *all* egress from a namespace to leave the cluster with one fixed, allowlistable IP. Which Cilium feature is the right answer, which CRD implements it, and what does it require of `bpf.masquerade`?

---

## Exercise 9 — Diagnosing the datapath end to end

**Goal:** build the reflex sequence for "traffic is not working": verify, observe, then drop-trace.

### Steps

1. Run the built-in connectivity suite. This is the fastest single signal.

```bash
cilium connectivity test --test-concurrency 2
```

```
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [kind-cca-net] Creating namespace cilium-test-1 for connectivity check...
⌛ [kind-cca-net] Waiting for deployments [client client2 echo-same-node] to become ready...
🏃 Running 1/78 tests: no-unexpected-packet-drops
🏃 Running 12/78 tests: pod-to-pod
...
✅ [kind-cca-net] All 78 tests (312 actions) successful, 15 tests skipped, 0 scenarios skipped.
```

2. Introduce a fault: point the Service at a selector nothing matches.

```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web-typo"}}}'
kubectl exec client -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://web-svc
```

```
000
```

3. Diagnose from the service table first — the cheapest check.

```bash
cdbg service list | grep 10.96.142.201
```

```
9    10.96.142.201:80/TCP   ClusterIP
```

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-svc
```

```
NAME            ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-svc-x9k2m   IPv4          <unset> <unset>     41m
```

4. Repair it and move to a genuinely datapath-level fault: a policy drop.

```bash
kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'

cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-allow-nothing
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: web
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: nonexistent
EOF
```

5. Confirm enforcement flipped on the endpoints.

```bash
cdbg endpoint list | grep web
```

```
794    Enabled    Disabled    51338    k8s:app=web    10.0.1.44    ready
2104   Enabled    Disabled    51338    k8s:app=web    10.0.1.201   ready
```

6. Trace the drop live with the monitor.

Terminal A:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg monitor --type drop
```

Terminal B:

```bash
kubectl exec client -- curl -s -m 3 -o /dev/null http://web-svc
```

Terminal A output:

```
Listening for events on 8 CPUs with 64x4096 of shared memory
xx drop (Policy denied) flow 0x8f2a1c33 to endpoint 794, ifindex 14,
   file bpf_lxc.c:2011, identity 39117->51338: 10.0.1.77:51204 -> 10.0.1.44:80 tcp SYN
```

7. Same answer through Hubble, which is what you will actually use in production.

```bash
cilium hubble enable
cilium status --wait
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 >/dev/null 2>&1 &
sleep 3
hubble observe --to-label app=web --verdict DROPPED --last 5
```

```
Sep  1 11:58:20.114: default/client:51210 (ID:39117) -> default/web-6f8d4c9b7-9lbxc:80 (ID:51338) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 11:58:21.117: default/client:51210 (ID:39117) -> default/web-6f8d4c9b7-9lbxc:80 (ID:51338) Policy denied DROPPED (TCP Flags: SYN)
```

8. Confirm the verdict from the policy engine directly, without generating traffic.

```bash
cdbg policy trace --src-identity 39117 --dst-identity 51338 --dport 80/TCP
```

```
Resolving ingress policy for [k8s:app=web k8s:io.kubernetes.pod.namespace=default]
* Rule {"matchLabels":{"any:app":"web",...}}: selected
    Allows from labels {"matchLabels":{"any:app":"nonexistent",...}}
      No label match for [k8s:run=client ...]
1/1 rules selected
Found no allow rule
Ingress verdict: denied

Final verdict: DENIED
```

9. Clean up the fault and confirm recovery.

```bash
kubectl delete cnp web-allow-nothing
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web-svc
```

```
200
```

### Check your understanding — Block 9

* **Q9.1** — In step 3, the service had a frontend but zero backends, and the symptom was `curl` exit code 28 / HTTP `000` (timeout), not `connection refused`. Explain why an empty backend list times out rather than resetting, given socket LB.
* **Q9.2** — The monitor line says `file bpf_lxc.c:2011` and `to endpoint 794`. What does the file name tell you about *where* in the datapath the drop happened, and is this ingress or egress enforcement?
* **Q9.3** — `identity 39117->51338`. Which is source and which is destination, and how would you turn each number into a human-readable label set?
* **Q9.4** — `cilium connectivity test` printed "Monitor aggregation detected, will skip some flow validation steps." What is monitor aggregation, which Helm value controls it, and what is the cost of setting it to `none`?
* **Q9.5** — Both `cilium-dbg monitor` and `hubble observe` showed the same drop. State two concrete production reasons to prefer Hubble.
* **Q9.6** — Order these four checks from cheapest to most expensive for "Pod A cannot reach Service B", and justify the order: `cilium-dbg monitor --type drop`, `kubectl get endpointslices`, `cilium connectivity test`, `cilium-dbg service list`.

---

## Exercise 10 — Cleanup

```bash
kubectl delete deployment web
kubectl delete svc web-svc
kubectl delete pod client
cilium uninstall
kind delete cluster --name cca-net
```

---

<details>
<summary><strong>Answers</strong> — expand only after attempting every block</summary>

### Block 1 — The CNI contract

**A1.1** — They are `hostNetwork: true` (static Pods manifested from `/etc/kubernetes/manifests`). A host-network Pod shares the node's root network namespace, so kubelet never invokes the CNI `ADD` operation for it: there is no sandbox netns to wire up and no IP to allocate. The IP `172.18.0.2` is the node's own address on the Docker bridge — the node IP, not a Pod IP. This is why control-plane components can bootstrap before any network plugin exists, and it is also the reason a broken CNI never takes the API server down with it.

**A1.2** — The **kubelet**. It calls the container runtime's status endpoint (CRI `Status()`), and containerd reports `NetworkReady=false` because it found no valid CNI configuration in `--cni-conf-dir` (default `/etc/cni/net.d`). Kubelet propagates that into the `Ready` condition on the Node object. The scheduler then refuses to place non-host-network Pods; that is why CoreDNS stays `Pending`.

**A1.3** — **No.** `.spec.podCIDR` is written by `kube-controller-manager`'s node-ipam controller and is authoritative only for IPAM modes that consume it — that is `ipam.mode=kubernetes`. With `ipam.mode=cluster-pool` (the Cilium default), the **cilium-operator** carves per-node `/24`s out of `clusterPoolIPv4PodCIDRList` and writes them to `CiliumNode.spec.ipam.podCIDRs`. The two allocations are independent, which is exactly why the lab node ends up with `10.0.1.0/24` while `.spec.podCIDR` still says `10.1.0.0/24`. Confusing them is a classic misdiagnosis.

**A1.4** — (1) A CNI configuration file in `/etc/cni/net.d/` (Cilium installs `05-cilium.conflist`), and (2) the CNI plugin binary in `/opt/cni/bin/` (`cilium-cni`). Cilium's agent copies both out of its own image on startup via the `install-cni-binaries` init container plus the agent's CNI-conf writer.

---

### Block 2 — Installation and status

**A2.1** —
* *Network* = how a packet gets from node to node: `Tunnel [vxlan]`, `Tunnel [geneve]`, or `Native`.
* *Host* = how a packet gets between the host stack and the endpoint on the local node: `BPF` (eBPF host routing, packets go endpoint→endpoint entirely in eBPF, bypassing the host's iptables/netfilter path) or `Legacy` (packets traverse the host's upper stack).

With `routingMode=native` and `bpf.masquerade=false` you would see `Routing: Network: Native   Host: BPF` and `Masquerading: IPTables`. Note that `Host: BPF` depends on kernel support and on eBPF host-routing prerequisites, not on the masquerade setting — they are orthogonal knobs that people frequently conflate.

**A2.2** — The **cilium-operator** allocated it, out of `ipam.operator.clusterPoolIPv4PodCIDRList=10.0.0.0/8` cut into `/24`s. It is persisted in the `CiliumNode` CRD at `.spec.ipam.podCIDRs`. The agent then reads its own `CiliumNode` object and initialises the local allocator from it. This is why the operator is a hard dependency for Pod scheduling in cluster-pool mode: if the operator is down and a new node joins, that node gets no CIDR and no Pod ever comes up on it.

**A2.3** —
* **router** = the `cilium_host` IP. It is the default gateway inside every Pod netns on that node and the source address Cilium uses for the local end of the datapath. It is also the address the L7 proxy (Envoy) binds to for redirected traffic.
* **health** = the IP of the `cilium-health` endpoint, a per-node probe endpoint. The agents run periodic node-to-node and endpoint-to-endpoint connectivity probes against each other's health endpoints; the result is the `Cluster health: 3/3 reachable` line and `cilium-dbg status --verbose` health output. It is your first signal that a specific node pair has lost datapath connectivity.

**A2.4** — Circularity: Cilium *is* the service proxy, so it is the thing that would normally translate the `kubernetes.default.svc` ClusterIP (`10.96.0.1:443`) to the real API-server endpoint. But the agent must reach the API server **before** it has programmed any service map, in order to read its own configuration and the `CiliumNode` object. `k8sServiceHost`/`k8sServicePort` give the agent a direct, non-translated address to bootstrap against. Once running, it programs `10.96.0.1:443` into the eBPF LB map for everyone else. (In managed clusters you can instead use `kubeProxyReplacementHealthzBindAddr`-style setups or keep a minimal kube-proxy; but with kube-proxy fully absent, these two values are mandatory.)

**A2.5** — The alternative is **`tc` (legacy clsact/`tc` BPF)**. **TCX** is the newer BPF link-based attachment for tc-style programs, introduced in **Linux 6.6**. TCX gives ownership semantics (programs are attached via a `bpf_link`, so they cannot be silently detached by another tool such as a stray `tc filter del`), plus deterministic ordering relative to other TCX programs. Practically: on ≥ 6.6 Cilium coexists much more safely with other tc-based agents.

---

### Block 3 — IPAM and endpoint plumbing

**A3.1** — Cilium installs a static (`PERMANENT`) neighbour entry so the Pod never has to ARP for its gateway. There is nothing on the other side that would answer an ARP request in the conventional sense — the `lxc*` veth peer is not a router doing normal L3, it is a hook point where eBPF takes over immediately. Removing ARP also removes a whole class of startup races and a per-Pod broadcast. The MAC it points at, `3e:1a:9c:44:8b:02`, is the **host-side veth (`lxc*`) MAC**, matching `host-mac` in the endpoint's networking status.

**A3.2** — The Pod has only `default via <router>` plus a link-scope route to the router. There is deliberately **no** subnet route, so *every* packet — even to a Pod on the same node in the same `/24` — is sent to the gateway MAC and hits `cil_from_container` on the veth's TCX ingress. The forwarding decision therefore happens entirely in eBPF, where Cilium can consult the ipcache, apply policy by identity, and route local-to-local traffic directly into the peer endpoint without going through the host's routing table or netfilter. Uniformity is the point: one code path, one policy enforcement point, no same-subnet shortcut that would bypass enforcement.

**A3.3** — VXLAN overhead is 50 bytes: 14 (outer Ethernet) + 20 (outer IPv4) + 8 (UDP) + 8 (VXLAN header) = 50, so 1500 − 50 = **1450**. Geneve with no options has the same base overhead (14 + 20 + 8 + 8 = 50), but Cilium reserves additional headroom when Geneve options are in use (for example DSR Geneve dispatch), so do not assume a fixed number — read it from `cilium-dbg status --verbose | grep -i mtu`. **WireGuard** adds **60 bytes** on top of whatever the underlying mode costs (`routingMode=native` + WireGuard → 1440; tunnel + WireGuard → lower still). The operational rule: never hardcode MTU; let Cilium auto-detect, or set `MTU` explicitly and verify with `cilium-dbg status`.

**A3.4** — A security identity is **cluster-scoped** (global), derived deterministically from the endpoint's *security-relevant* label set — Kubernetes namespace, Pod labels, service account, cluster name — after filtering out labels excluded by `labels`/`--labels` configuration. It is allocated by the **cilium-agent** through the identity allocator, backed in CRD mode by `CiliumIdentity` objects in the API server (or by the kvstore in kvstore mode). Because it is label-derived and global, four Pods across two nodes with identical labels collapse to one identity — which is precisely what makes policy scale independently of Pod count.

**A3.5** — Endpoint `1288` / identity `1` / `reserved:host` is the **local node itself** — the host network namespace, represented as an endpoint so that Cilium can apply policy to traffic entering and leaving the host stack (this is the basis of the Host Firewall feature). It has no Pod IPv4 in the listing because it covers *all* the node's own addresses, not one. Consequence for `hostNetwork: true` Pods: they have **no** dedicated Cilium endpoint and no per-Pod identity — from the datapath's perspective they are the host. They are therefore invisible to Pod-selecting policy and are matched only by `reserved:host` / host-firewall rules. This surprises people constantly: a `NetworkPolicy` selecting a host-network Pod's labels does nothing.

---

### Block 4 — Routing modes

**A4.1** — 8472 is the **pre-standard Linux VXLAN port**, chosen by the Linux implementation before IANA assigned 4789, and kept by Cilium as the default for compatibility with existing deployments and firewall rules. It is configurable via `tunnelPort`. **Geneve** uses **6081** (the IANA-assigned port). Practical consequence: your security groups / firewall must allow UDP 8472 (or 6081) node-to-node, plus the health-check ports, or you get the classic "same-node traffic works, cross-node traffic hangs" symptom.

**A4.2** — "External mode" (`ip link ... vxlan external`) means the device carries **no fixed VNI or remote endpoint** in its own configuration. Instead, the tunnel key — remote IP and VNI — is supplied per packet at runtime by the eBPF program, via `bpf_skb_set_tunnel_key()`, using the value looked up in the tunnel map (`cilium_tunnel_map`) or the ipcache's `tunnelendpoint` field. That is why `id 0` and no `remote` appear in `ip -d link`, and why one device serves every remote node. The component supplying the key is **cilium-agent's eBPF datapath** (`bpf_overlay.c` / `bpf_lxc.c`).

**A4.3** — Default rule: masquerade traffic **leaving the cluster**, i.e. traffic whose destination is *not* a known cluster/Pod destination, and preserve the Pod IP for everything internal. Concretely in this configuration, `10.0.2.118` is inside `ipv4NativeRoutingCIDR` / the cluster Pod CIDR *and* has an ipcache entry identifying it as a cluster endpoint, so it is treated as intra-cluster and is exempt. Preserving the real Pod source IP is not a nicety — identity-based policy, Hubble attribution and application-level source-IP logic all depend on it.

**A4.4** — `autoDirectNodeRoutes` installs a plain route `remotePodCIDR via remoteNodeIP dev <uplink>` on every node. That only works if **all nodes are on the same L2 segment** (directly reachable without a router hop), because the node IP must be resolvable as an on-link next hop. In a cloud VPC with nodes in different subnets you must instead make the underlay itself aware of the Pod CIDRs: use the cloud's native IPAM (`ipam.mode=eni` / `azure` / `gke`, where Pod IPs are real VPC IPs), or advertise Pod CIDRs with the **BGP Control Plane** (`CiliumBGPClusterConfig`/`CiliumBGPPeerConfig`) to the fabric, or add routes to the VPC route table. If you cannot do any of those, stay on tunnel mode — that is exactly the problem encapsulation exists to solve.

**A4.5** — MTU is written into the Pod's `eth0` at CNI `ADD` time, i.e. when the sandbox is created. Changing the agent's configuration does not retroactively rewrite an already-configured netns, so running Pods keep the old value until they are recreated. Production-safe procedure: change the config, roll the agent DaemonSet, then **drain and roll workloads node by node** (or do the change during a planned node rotation). Skipping the workload roll leaves Pods with 1450 in a 1500 network — which is harmless — but the reverse direction (tunnel enabled while Pods still have 1500) causes silent black-holing of large packets and PMTUD failures, the single nastiest symptom in this area.

**A4.6** — Traffic destined **outside** `ipv4NativeRoutingCIDR` is considered to be leaving the cluster and is therefore **masqueraded** to the node's IP by the eBPF masquerade program on egress from the uplink device. Traffic **inside** the CIDR is assumed to be natively routable by the underlay and is left with its Pod source IP. This is why the value must exactly cover all Pod (and, where relevant, node) address space: too narrow and intra-cluster traffic gets SNATed, destroying identity attribution; too wide and genuinely external traffic escapes unmasqueraded and is dropped by the fabric as un-routable.

---

### Block 5 — Identity and ipcache

**A5.1** — Global identities occupy **256 – 65535** (`Global Identity Range: min 256, max 65535` in the status output). 1–255 is the reserved range; above 65535 are the special ranges used for local-scoped identities (CIDR identities, remote-node identities in some configurations). In **CRD mode** (the default, `identityAllocationMode=crd`) they are stored as cluster-scoped `CiliumIdentity` objects in the Kubernetes API server; in `kvstore` mode they live in etcd. Practical limit: the global identity space is finite, and label churn (e.g. injecting a unique label per Pod) will exhaust it — this is a real production incident pattern.

**A5.2** — From `cca-net-worker`'s point of view:
* `10.0.2.118/32 → tunnelendpoint=172.18.0.4` — a **remote** Pod. To reach it, encapsulate and send to node `172.18.0.4`. The ipcache is what supplies the tunnel destination to `bpf_skb_set_tunnel_key()`.
* `10.0.1.44/32 → tunnelendpoint=0.0.0.0` — a **local** endpoint. No tunnel needed; the datapath resolves it through the local endpoint map and delivers straight into the peer veth.

In native routing mode all `tunnelendpoint` fields go to `0.0.0.0` because the underlay routes the packet.

**A5.3** — `reserved:host` (1) is **the local node** — the host netns of the node the agent runs on. `reserved:remote-node` (6) is **any other node** in the cluster (or in a ClusterMesh). They were split because collapsing them makes `reserved:host` mean "any node anywhere", which is far too broad for host-firewall rules: a rule intended to allow the kubelet on *this* node to reach a Pod would silently allow every node in the cluster. If you write a policy assuming they are the same, you either over-permit (treating remote nodes as trusted local host) or you break health checks and kubelet probes (denying `remote-node` traffic that carries node-sourced health probes). Note `policyCIDRMatchMode` and `enable-remote-node-identity` history here — on modern versions remote-node is always a distinct identity.

**A5.4** — The ipcache is an **LPM (longest-prefix-match) trie**. A packet's destination resolves to the *most specific* matching entry. `0.0.0.0/0 → 2 (reserved:world)` is the catch-all fallback, so anything with no better match is classed as `world`. When you write a `toCIDR`/`toCIDRSet` policy rule, Cilium allocates a **local-scoped CIDR identity** and inserts the corresponding prefix into the ipcache; a packet to an address inside that prefix then resolves to the CIDR identity instead of `world`, and the policy for that identity applies. This is exactly how CIDR-based egress policy works and why a `toCIDR: 0.0.0.0/0` rule and a `toEntities: world` rule behave subtly differently.

**A5.5** — During the propagation window the endpoint's identity is being reallocated and the new identity must be pushed into every node's ipcache and policy map. If a policy allowed the *old* identity and not the new one (or vice versa), there is a brief interval where flows can be dropped or, worse, allowed under a stale identity. The feature that closes the gap for **newly created** endpoints is **`endpointStatus`/policy-enforcement-at-init**: a new endpoint starts in `reserved:init` (identity 5) with policy already enforced, so it is never "open" while its identity resolves. For label changes on existing endpoints, the endpoint enters a regenerating state and Cilium regenerates its BPF policy program before the change is considered complete; `cilium-dbg endpoint list` showing `regenerating` rather than `ready` is the observable signal. Operationally: do not mutate security-relevant labels on running production Pods.

---

### Block 6 — kube-proxy replacement

**A6.1** — Translation happened at **`connect(2)` time**, before a single packet was built, in the **`cil_sock4_connect`** program attached to the cgroup v2 hook `cgroup/connect4`. It rewrote the socket's destination address from the ClusterIP to a chosen backend address in place. Because the socket itself now points at `10.0.1.44:80`, every packet the kernel subsequently emits already carries the backend IP — there is nothing left for `tcpdump` to see. The benefit is that per-packet DNAT and the associated conntrack cost are eliminated entirely for Pod-to-Service traffic within the node's cgroup hierarchy.

**A6.2** — `getpeername(2)` would naturally return the **backend** address `10.0.1.44:80`, not the ClusterIP the application asked for. Some applications compare the peer address against what they dialled (TLS SNI/hostname logic, some gRPC and Java clients, and notably anything doing its own address bookkeeping) and break. Cilium attaches **`cil_sock4_getpeername`** to the `cgroup/getpeername4` hook to rewrite the answer back to the original service VIP, restoring the illusion that the socket is connected to the ClusterIP.

**A6.3** — Slot 0 is the **service "master" entry**: it holds service-level metadata rather than a backend — backend count, service flags (`ClusterIP`, `NodePort`, `LoadBalancer`, `non-routable`, affinity settings, `externalTrafficPolicy`), and the reverse-NAT index. Backends live in slots 1..N. `non-routable` here means the frontend is a ClusterIP that must never be routed on the wire — it exists only as a lookup key. When you read `cilium-dbg bpf lb list`, always expect one slot-0 line per frontend.

**A6.4** — They are Cilium's own housekeeping chains, not service DNAT. Typically: rules to exclude Cilium-managed traffic from other agents' processing, the `CILIUM_OUTPUT`/`CILIUM_POST_nat` chains used for L7 proxy redirection bookkeeping and for marking, and — when `bpf.masquerade=false` — the actual masquerade rule (absent here). Cilium also uses connmark/`--set-xmark` rules to coordinate with the kernel for proxied traffic. The key point for the exam: **zero `KUBE-SERVICES` rules** is the positive proof that kube-proxy replacement is doing the service work; the presence of `CILIUM_*` chains is normal and unrelated.

**A6.5** — `Socket LB Coverage: Hostns-only` appears when socket LB is deliberately restricted to the **host network namespace** — set via `socketLB.hostNamespaceOnly=true`. You need this when something else in the Pod netns must observe or intercept the original ClusterIP: most commonly a sidecar-based service mesh (Istio/Linkerd) whose iptables redirection expects to see the VIP, or custom eBPF/`SO_ORIGINAL_DST` logic. In that case Pod traffic is handled by the **per-packet eBPF LB at the tc/TCX layer** on the `lxc*` interface instead (DNAT + conntrack in `bpf_lxc.c`), which is slightly more expensive but preserves the VIP inside the Pod netns.

**A6.6** — The colleague is **incorrect**. Cilium's egress policy is evaluated by **identity**, and the identity of the destination is resolved from the ipcache using the *post-translation* backend IP — which maps to the backend Pod's identity, exactly the thing you want to authorise. Furthermore, Cilium supports `toServices` in `CiliumNetworkPolicy`, which it resolves to the backing endpoints. What socket LB *does* change is anything that inspects the literal ClusterIP on the wire — e.g. a `toCIDR` rule written against the Service CIDR, which will not match because the packet never carries that address. The correct pattern is to select the backend by label (`toEndpoints`) or by `toServices`, never by service VIP CIDR.

---

### Block 7 — External traffic, DSR, Maglev

**A7.1** —
* `10.96.142.201:80` — the **ClusterIP** frontend, for in-cluster clients.
* `0.0.0.0:31544` — the **wildcard NodePort** frontend, matching the NodePort on any address the datapath sees, including addresses not known at program time (and it is what the socket-LB path uses for host-namespace access to the NodePort).
* `172.18.0.3:31544` — an **explicit per-device NodePort** frontend, bound to the address of each detected device in `devices`.

The wildcard alone is not sufficient because Cilium must distinguish traffic actually addressed to *this node's* IP on the NodePort — needed for correct reverse-NAT bookkeeping, for `externalTrafficPolicy: Local` decisions, and to avoid hijacking traffic merely transiting the node. Multi-homed nodes get one explicit frontend per device address.

**A7.2** — With `externalTrafficPolicy: Cluster` and `loadBalancer.mode=snat`, the receiving node may forward the request to a backend on a *different* node. For the reply to come back through the same node (so it can be un-NATed and returned to the client), the ingress node rewrites the **source** address to its own IP (`172.18.0.3`). The backend therefore sees the node, not the client.

`externalTrafficPolicy: Local` fixes it by **restricting the backend set to Pods local to the receiving node** — no cross-node hop, so no SNAT is needed and the client IP survives. The trade-off is twofold: (1) **uneven load distribution**, since traffic is split by node rather than by backend count — a node with 1 replica gets the same share as a node with 5; and (2) **traffic blackholing on nodes with zero local backends**, which is why an external LB must use the service's `healthCheckNodePort` to stop sending traffic to those nodes. Notice in step 4 that the backend list for the frontend shrank from 4 to 2.

**A7.3** — In DSR, the ingress node forwards the request to the backend node **without** rewriting the source address; the client IP `172.18.0.1` is preserved end to end. The backend node's datapath, having learned the original service VIP and port from the DSR dispatch mechanism, sets up reverse-NAT locally and the reply is sent **directly from the backend node to the client**, bypassing the ingress node entirely. The reply's source address is the **original service VIP/NodePort** (`172.18.0.3:31544`), not the backend Pod IP — otherwise the client's conntrack would reject it as an unsolicited packet from an unknown peer.

That asymmetry is the whole point of DSR (one hop out instead of two, and no return-path bottleneck at the ingress node), and also its main deployment constraint: the fabric must permit a node to emit packets sourced from an address it does not own.

**A7.4** —
* **`opt`** — encodes the VIP/port in an **IPv4 option** (a Cilium-specific option) appended to the original header. Cheapest (small overhead, no extra encapsulation) but IPv4-only in effect and fragile: many cloud fabrics, hardware middleboxes and security appliances **drop IPv4 packets carrying unknown options**. AWS and several enterprise fabrics are concrete environments where `opt` silently blackholes traffic.
* **`geneve`** — encapsulates in **Geneve** and carries the service address in a Geneve TLV option. Works for IPv4 and IPv6, survives fabrics that dislike IP options, costs ~50 bytes of MTU. This is the most broadly compatible choice and the reason the lab uses it.
* **`ipip`** — **IP-in-IP** encapsulation carrying the metadata in the outer header. Available for IPv4 and IPv6; requires the fabric to permit protocol 4/41, which many security groups do not by default.

**A7.5** — The Maglev lookup table size must be **prime** because the algorithm's permutation for each backend is generated as `offset + i * skip mod M`, and the guarantee that each backend's permutation visits **every** table slot exactly once — which is what produces near-perfect, evenly distributed population — holds only when `M` is prime and coprime with the skip value. A composite `M` would let a backend's permutation cycle through a subset of slots, wrecking both balance and disruption properties. 16381 is the default (a prime just under 2^14).

If two nodes have **different `maglev.hashSeed`** values, they compute **different lookup tables** for the same service and backend set. They will therefore disagree about which backend a given 5-tuple belongs to. With DSR — where the ingress node and the reply path can differ, and where consistent selection across nodes is the whole reason to use Maglev — this produces **broken connections on any path change**, and with `externalTrafficPolicy: Cluster` it undermines the consistency that makes Maglev worth its extra memory. The seed must be identical cluster-wide; Helm generates one at install time and `--reuse-values` preserves it, which is why you must be careful not to regenerate it accidentally on upgrade.

**A7.6** — With **`Random`**, each node independently picks a backend at random per new connection. Removing a backend does not affect *established* flows (conntrack pins them), but there is no consistency between nodes and no guarantee about how new flows redistribute.

With **`Maglev`**, backend choice is a deterministic function of the 5-tuple and the backend set, identical on every node sharing the seed. Removing one backend of N perturbs only roughly `1/N` of the table entries — this is *consistent hashing* with minimal disruption. Fewer existing flows land on a different backend than they did before.

This matters specifically with **DSR** because DSR relies on any node that receives a packet for an existing flow being able to route it to the same backend — the ingress node may change (ECMP re-hash upstream, node failure, anycast VIP), and there is no shared conntrack across nodes to consult. Maglev makes "which backend does this 5-tuple belong to" a stateless, node-independent answer, so a flow survives a change of ingress node. With `Random`, the new ingress node would pick a different backend and the connection would reset.

---

### Block 8 — Masquerading

**A8.1** — With `bpf.masquerade=true`, masquerading is performed by the eBPF program attached at the **tc/TCX egress hook of the native/uplink device(s)** listed in `devices` (here `eth0`) — the `cil_to_netdev` path in `bpf_host.c` — using Cilium's own NAT map (`cilium_snat_v4_external`), entirely independent of netfilter conntrack. With `bpf.masquerade=false`, masquerading falls back to an **iptables `MASQUERADE` rule** in the `nat` table's `POSTROUTING` chain (in a `CILIUM_POST_nat` chain), using kernel netfilter conntrack. The eBPF path is faster, does not populate netfilter conntrack (avoiding table exhaustion under high egress churn), and is a prerequisite for features such as the Egress Gateway.

**A8.2** — In native routing mode: masquerade a packet leaving the node through a masquerade-enabled device **if and only if its destination is outside `ipv4NativeRoutingCIDR`** and its source is a Pod IP managed by Cilium — with the additional exemptions that (a) the destination is not another cluster node, and (b) the destination is not listed in the ip-masq-agent's non-masquerade CIDRs when that agent is enabled. Anything inside `ipv4NativeRoutingCIDR` keeps its Pod source address. In tunnel mode the equivalent predicate is "destination is not a known cluster endpoint / remote node", since intra-cluster traffic goes through the tunnel and never reaches the masquerade hook on the uplink in the same way.

**A8.3** — ICMP echo has no L4 ports, so a NAT implementation cannot use a port to demultiplex return traffic. It instead rewrites the ICMP **identifier** field, which serves the same purpose: several Pods can ping the same external host concurrently, and the node needs a per-flow key to map each echo *reply* back to the correct originating Pod. Cilium's NAT map therefore treats the ICMP id as the "port" — hence `10.0.1.77:12` becoming `172.18.0.3:32410`. This is standard NAPT behaviour for ICMP (RFC 5508), not a Cilium invention.

**A8.4** — The underlay `172.18.0.0/16` must have a **route back to the Pod CIDR `10.0.0.0/8` via the correct node**. Otherwise the destination receives a packet from `10.0.1.77`, replies to `10.0.1.77`, and its routing table has no idea where that is — the reply is dropped or sent to a default gateway that blackholes it. The failure mode is **one-way traffic**: `tcpdump` on the node shows the request leaving, nothing comes back, and the application reports a timeout. This is the standard trap with `ipMasqAgent` non-masquerade CIDRs: exempting a destination from SNAT is only safe if that destination's network can route to your Pod CIDR. In practice, use non-masquerade CIDRs for on-prem networks where you have advertised the Pod CIDR (via BGP or static routes), never for the internet.

**A8.5** — The **Egress Gateway**, implemented by the **`CiliumEgressGatewayPolicy`** CRD. It selects source Pods (by namespace/label) and destination CIDRs, and routes their egress through a designated gateway node, where the traffic is SNATed to a specific **egress IP** on that node. That single stable IP is what you give the external party for their allowlist. Requirements: `egressGateway.enabled=true`, **`bpf.masquerade=true`** (the feature is built on the eBPF masquerade/NAT path and does not work with iptables masquerading), kube-proxy replacement enabled, and a suitable kernel. Be aware of the availability implication: the gateway node becomes a chokepoint and a failure domain for that namespace's egress — size and pair it accordingly.

---

### Block 9 — Diagnosis

**A9.1** — With socket LB, the `connect(2)` hook looks up `10.96.142.201:80` in the service map. The frontend still exists (slot 0 is present) but has **zero backends**, so there is no address to rewrite to. Cilium's behaviour in that case is to leave the connection to be dropped rather than to reject it: the packet is either not emitted to a valid destination or is dropped in the datapath, so the client sees **no response at all** and its TCP stack retransmits the SYN until the `curl` timeout fires — hence `000` and exit code 28. A `connection refused` would require an RST from something that owns the address, and nothing does. This distinction is diagnostically useful: *timeout* on a ClusterIP points at "no backends / policy drop / datapath"; *refused* points at "a backend exists and is actively rejecting", i.e. an application-level problem.

**A9.2** — **`bpf_lxc.c`** is the program attached to the **Pod's veth (`lxc*`) interface** — i.e. the drop happened at the *destination endpoint's* datapath, not on the uplink (`bpf_host.c`) or in the overlay (`bpf_overlay.c`). Combined with `to endpoint 794`, this is the packet arriving at the endpoint, so it is **ingress policy enforcement** on the destination — consistent with `cilium-dbg endpoint list` showing `POLICY (ingress) ENFORCEMENT: Enabled` for the `web` endpoints and `Disabled` for egress. Reading the file name is the fastest way to localise a drop: `bpf_lxc.c` = at a Pod, `bpf_host.c` = at the host/uplink, `bpf_overlay.c` = on the tunnel path, `bpf_sock.c` = socket layer.

**A9.3** — The format is `identity <source>-><destination>`. So **39117 is the source** (the `client` Pod) and **51338 is the destination** (the `web` Pods, after the `tier=frontend` relabel in Exercise 5). Resolve either with `cilium-dbg identity get <id>` inside an agent pod, or cluster-wide with `kubectl get ciliumidentity <id> -o yaml` (the `security-labels` field). Hubble does this for you automatically, printing `default/client (ID:39117)`.

**A9.4** — **Monitor aggregation** suppresses repeated datapath events for the same connection to reduce the volume of events pushed to the monitor/Hubble ring buffer — for example, reporting only the first packet of a flow in each direction and any packet with new TCP flags, instead of every packet. It is controlled by **`bpf.monitorAggregation`** (values `none`, `low`, `medium` (default), `maximum`), with `bpf.monitorInterval` and `bpf.monitorFlags` as refinements. Setting it to `none` gives you every single packet event — invaluable when chasing an intermittent mid-flow drop — but the cost is significant: high CPU on the agent, high perf-ring throughput, and a real risk of **lost events** and increased latency on busy nodes. Turn it down temporarily on one node, never cluster-wide in production.

**A9.5** — Two production reasons, from several valid ones:
1. **Cluster-wide, aggregated view.** `cilium-dbg monitor` shows only the node you exec'd into; with Hubble Relay, `hubble observe` queries every node at once. When you do not yet know which node the drop is on — the normal case — the per-node tool means N exec sessions and a race against the ring buffer.
2. **Kubernetes-aware identity resolution and filtering.** Hubble prints `default/client:51210 (ID:39117) -> default/web-...:80`, resolving identities to namespace/Pod names, and supports server-side filters (`--to-label`, `--verdict DROPPED`, `--protocol`, `--namespace`) plus L7 visibility. `cilium-dbg monitor` gives you raw identity numbers you must resolve by hand.

Also valid: Hubble does not require `exec` into a privileged system pod (better RBAC posture), it exports metrics and can persist flows, and it has a UI for service-map visualisation.

**A9.6** — Cheapest to most expensive:

1. **`kubectl get endpointslices`** — a single API read, no cluster mutation, no privileged access. Answers "does the Service have backends at all?", which is the most common root cause. Always start here.
2. **`cilium-dbg service list`** — one exec into one agent, read-only map dump. Answers "did Cilium program what the API server says?", isolating a control-plane-to-datapath sync problem from a Kubernetes object problem.
3. **`cilium-dbg monitor --type drop`** — requires a privileged exec, streams live events (so you must reproduce the traffic), and imposes real overhead on a busy node. Use it once you know *which* node to look at, which the first two steps tell you.
4. **`cilium connectivity test`** — by far the most expensive: it creates namespaces, deployments and services, runs dozens of tests over several minutes, and consumes cluster resources. It is a broad regression check for "is the installation healthy", not a targeted diagnostic for one failing flow. Run it after a change or an upgrade, not as a first response to a single broken service.

The general principle: move from *declarative state* (API objects) → *programmed state* (eBPF maps) → *observed behaviour* (live events) → *synthetic validation* (test suite). Each step costs more and narrows less.

</details>

---

## Sources

* CCA curriculum — https://github.com/cncf/curriculum/blob/master/cca/README.md
* Cilium — Networking concepts — https://docs.cilium.io/en/stable/network/concepts/
* Cilium — Routing modes — https://docs.cilium.io/en/stable/network/concepts/routing/
* Cilium — IP Address Management — https://docs.cilium.io/en/stable/network/concepts/ipam/
* Cilium — Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
* Cilium — Kubernetes without kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
* Cilium — Egress Gateway — https://docs.cilium.io/en/stable/network/egress-gateway/
* Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
* Cilium — Helm reference — https://docs.cilium.io/en/stable/helm-reference/
* Hubble — Observability — https://docs.cilium.io/en/stable/observability/hubble/
* Maglev: A Fast and Reliable Software Network Load Balancer (Google, NSDI 2016) — https://research.google/pubs/pub44824/
* RFC 5508 — NAT Behavioral Requirements for ICMP — https://datatracker.ietf.org/doc/html/rfc5508