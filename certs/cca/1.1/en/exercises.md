# Cilium Fundamentals — Guided Exercises
### CCA · Domain 1.1 (exam weight 20%)

> **What you will build.** A three-node Kubernetes cluster with **no CNI and no kube-proxy**, then install Cilium into it and take the datapath apart layer by layer: veth pairs and eBPF hook points, the `cilium_lxc` / `cilium_ipcache` / `cilium_lb4_*` maps, security identities, the tunnel map, socket-level load balancing, and finally identity-based policy with L3/L4 and L7 enforcement.
>
> **How to work through this.** Every numbered step is meant to be executed. Outputs shown are real-shaped but **your IDs, IPs, ifindexes and identity numbers will differ** — that is the point: you must learn to read the structure, not memorise the values. After each block there are verification questions (**Q1 … Q34**); all answers are in the collapsible section at the end.
>
> **Version note.** Written against **Cilium 1.16.x on Kubernetes 1.31**. Three things are version-sensitive and are flagged inline: (a) the in-agent CLI was renamed `cilium` → `cilium-dbg` in 1.15; (b) `kubeProxyReplacement` accepts only `true`/`false` since 1.16 (`strict`/`partial`/`probe` were removed); (c) the standalone `cilium-envoy` DaemonSet is enabled by default since 1.16. Run `cilium version --client` and `kubectl -n kube-system exec ds/cilium -- cilium-dbg version` before assuming anything.

**Prerequisites on your workstation:** `docker` (or podman with the kind provider), `kind` ≥ 0.24, `kubectl` ≥ 1.30, the `cilium` CLI ≥ 0.16, the `hubble` CLI ≥ 1.16, and a Linux kernel ≥ 5.10 on the machine running the containers (5.15+ strongly recommended — several features below silently degrade on older kernels).

---

## Lab conventions

Set these once per shell. Everything downstream depends on them.

```bash
export CLUSTER=cca-lab
export CILIUM_VERSION=1.16.5

# Shorthand for "run this inside the Cilium agent on a given node".
# $1 = node name, rest = command
cnode() { local n="$1"; shift
  kubectl -n kube-system exec -it \
    "$(kubectl -n kube-system get pod -l k8s-app=cilium \
        --field-selector spec.nodeName="$n" -o name | head -1)" \
    -c cilium-agent -- "$@"
}

# Shorthand for "run this inside *some* agent" (fine for cluster-wide reads)
cany() { kubectl -n kube-system exec -it ds/cilium -c cilium-agent -- "$@"; }
```

---

## Exercise 1 — Build a cluster with no CNI and no kube-proxy

The default kind cluster ships `kindnetd` (a CNI) and `kube-proxy` (a Service implementation). Cilium replaces both. Installing it over them produces a cluster that *appears* to work while two datapaths fight over the same packets — the single most common cause of "my NetworkPolicy is not enforced" in the field.

1. **Write the cluster definition.**

```yaml
# kind-cca.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Do not install kindnetd; the cluster stays NotReady until a CNI arrives.
  disableDefaultCNI: true
  # Do not run kube-proxy at all; Cilium will own Service translation.
  kubeProxyMode: none
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. **Create it.**

```bash
kind create cluster --config kind-cca.yaml
kubectl config use-context kind-cca-lab
```

3. **Observe the cluster in its broken state — this is expected.**

```bash
kubectl get nodes -o wide
```

```
NAME                      STATUS     ROLES           AGE   VERSION   INTERNAL-IP
cca-lab-control-plane     NotReady   control-plane   47s   v1.31.2   172.18.0.2
cca-lab-worker            NotReady   <none>          31s   v1.31.2   172.18.0.3
cca-lab-worker2           NotReady   <none>          31s   v1.31.2   172.18.0.4
```

4. **Confirm *why* the nodes are NotReady.**

```bash
kubectl describe node cca-lab-worker | grep -A2 'Ready '
```

```
  Ready   False   ...   KubeletNotReady   container runtime network not ready:
          NetworkReady=false reason:NetworkPluginNotReady
          message:Network plugin returns error: cni plugin not initialized
```

5. **Confirm kube-proxy really is absent.**

```bash
kubectl -n kube-system get ds
kubectl get pods -A -o wide | grep -c kube-proxy || echo "no kube-proxy pods"
```

6. **Capture the API server endpoint** — with no kube-proxy, the Cilium agent cannot reach `10.96.0.1:443` (nothing translates that VIP yet), so it needs the real address to bootstrap.

```bash
API_SERVER_IP=$(docker inspect -f \
  '{{ .NetworkSettings.Networks.kind.IPAddress }}' cca-lab-control-plane)
API_SERVER_PORT=6443
echo "$API_SERVER_IP:$API_SERVER_PORT"     # e.g. 172.18.0.2:6443
```

> **Q1.** The nodes are `NotReady`, yet `kubectl get nodes` works and the kubelet is running. Which specific kubelet subsystem is failing, and why do control-plane static pods (etcd, kube-apiserver) still start?
>
> **Q2.** Why must you pass `k8sServiceHost`/`k8sServicePort` explicitly to Cilium in this cluster, but *not* in a cluster that still runs kube-proxy? Describe the exact chicken-and-egg cycle.
>
> **Q3.** You skipped `kubeProxyMode: none` and installed Cilium with `kubeProxyReplacement=true` anyway. Both kube-proxy's iptables/IPVS rules and Cilium's eBPF socket LB are now present. At which point in a pod's `connect()` path does each act, and which one wins for a ClusterIP connection originating in a pod?

---

## Exercise 2 — Install Cilium and read the control plane

7. **Install.** The Helm values below are the ones the exam expects you to recognise.

```bash
cilium install --version "$CILIUM_VERSION" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$API_SERVER_IP" \
  --set k8sServicePort="$API_SERVER_PORT" \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set operator.replicas=1 \
  --set bpf.monitorAggregation=none
```

`bpf.monitorAggregation=none` disables event coalescing so `cilium-dbg monitor` shows *every* packet event in Exercise 7. Never do this in production — it is a measurable per-packet cost.

8. **Wait for convergence and read the summary.**

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

DaemonSet         cilium             Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet         cilium-envoy       Desired: 3, Ready: 3/3, Available: 3/3
Deployment        cilium-operator    Desired: 1, Ready: 1/1, Available: 1/1
Containers:       cilium             Running: 3
                  cilium-envoy       Running: 3
                  cilium-operator    Running: 1
Cluster Pods:     3/3 managed by Cilium
Helm chart version: 1.16.5
```

9. **Nodes go Ready.** The CNI configuration file is written to disk by the agent's init container.

```bash
kubectl get nodes
docker exec cca-lab-worker ls -l /etc/cni/net.d/
docker exec cca-lab-worker cat /etc/cni/net.d/05-cilium.conflist
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

10. **Enumerate what each component actually does.**

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l name=cilium-operator -o wide
kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o wide
```

11. **Read the agent's own view of itself** (note the binary name — `cilium-dbg`, not `cilium`):

```bash
cany cilium-dbg status --verbose | head -45
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:         ["cilium/v2::CiliumClusterwideNetworkPolicy", ...]
KubeProxyReplacement:    True   [eth0   172.18.0.3 fe80::42:acff:fe12:3 (Direct Routing)]
Host firewall:           Disabled
SRv6:                    Disabled
CNI Chaining:            none
Cilium:                  Ok   1.16.5 (v1.16.5-xxxxxxxx)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 3/254 allocated from 10.0.1.0/24,
Allocated addresses:
  10.0.1.115 (health)
  10.0.1.211 (kube-system/coredns-...)
  10.0.1.87  (router)
ClusterMesh:             0/0 clusters ready
IPv4 BIG TCP:            Disabled
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.0.0.0/8 [IPv4: Enabled, IPv6: Disabled]
Encryption:              Disabled
Cluster health:          3/3 reachable
```

12. **Compare the effective agent configuration with what you asked for.**

```bash
cilium config view | grep -E 'routing-mode|tunnel|ipam|kube-proxy|enable-policy|enable-ipv4'
cany cilium-dbg config | head -30
```

> **Q4.** Name the four Cilium components you can see in this cluster and state, in one sentence each, what breaks if that component alone is deleted: `cilium` (DaemonSet), `cilium-operator` (Deployment), `cilium-envoy` (DaemonSet), `cilium-cni` (the binary on disk).
>
> **Q5.** `cilium-operator` runs with one replica. Pods keep being scheduled and networked while it is down — for how long, and what is the first thing that fails? (Hint: think about what the operator owns in `ipam.mode=cluster-pool`.)
>
> **Q6.** `Routing: Network: Tunnel [vxlan] Host: BPF`. What does "Host: BPF" refer to, and how does it differ from the "Network" routing mode?
>
> **Q7.** `Attach Mode: TCX` and `Device Mode: veth`. What is TCX, which kernel version introduced it, and what does Cilium fall back to when it is unavailable?
>
> **Q8.** The kind config declares `podSubnet: 10.244.0.0/16`, but the agent reports allocations from `10.0.1.0/24`. Explain precisely why, and name the field on the `CiliumNode` CRD where the per-node range is recorded.

---

## Exercise 3 — The per-node datapath: interfaces, hooks and maps

Deploy workloads first so there is something to look at.

13. **Deploy the Star Wars demo** (canonical for Cilium; the L7 path in Exercise 8 depends on it).

```yaml
# starwars.yaml
apiVersion: v1
kind: Service
metadata:
  name: deathstar
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  selector:
    org: empire
    class: deathstar
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deathstar
spec:
  replicas: 2
  selector:
    matchLabels:
      org: empire
      class: deathstar
  template:
    metadata:
      labels:
        org: empire
        class: deathstar
    spec:
      containers:
        - name: deathstar
          image: docker.io/cilium/starwars
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: tiefighter
  labels:
    org: empire
    class: tiefighter
spec:
  containers:
    - name: spaceship
      image: docker.io/tgraf/netperf
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: xwing
  labels:
    org: alliance
    class: xwing
spec:
  containers:
    - name: spaceship
      image: docker.io/tgraf/netperf
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f starwars.yaml
kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -o wide
```

14. **Look at the host-side interfaces on one node.**

```bash
docker exec cca-lab-worker ip -brief link show
```

```
lo               UNKNOWN  00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
cilium_net@cilium_host  UP  9a:1c:...  <BROADCAST,MULTICAST,UP,LOWER_UP>
cilium_host@cilium_net  UP  4e:8b:...  <BROADCAST,MULTICAST,UP,LOWER_UP>
cilium_vxlan     UNKNOWN  16:df:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
lxc_health@if9   UP       ba:22:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
lxc8a3f21c94b17@if11 UP   3e:04:...     <BROADCAST,MULTICAST,UP,LOWER_UP>
eth0@if12        UP       02:42:ac:12:00:03 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

15. **Correlate one `lxc*` interface with the pod that owns it.**

```bash
POD=$(kubectl get pod -l class=tiefighter -o jsonpath='{.metadata.name}')
NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')

# ifindex of eth0 *inside* the pod
kubectl exec "$POD" -- cat /sys/class/net/eth0/iflink
# -> 11

# the host device with that ifindex is the peer
docker exec "$NODE" ip -o link | awk -F': ' '$1==11 {print}'
```

16. **List the eBPF programs attached to that device.**

```bash
LXC=lxc8a3f21c94b17    # substitute yours
cnode "$NODE" bpftool net show dev "$LXC"
```

```
tc:
xdp:
flow_dissector:
netfilter:
tcx/ingress:
  cil_from_container prog_id 412 link_id 33
tcx/egress:
  cil_to_container prog_id 415 link_id 34
```

17. **Inspect one of those programs and the maps it holds open.**

```bash
cnode "$NODE" bpftool prog show id 412
cnode "$NODE" bpftool prog show id 412 --json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["map_ids"])'
```

```
412: sched_cls  name cil_from_container  tag 9d1f0a7c2b3e4d55
     loaded_at 2026-09-01T11:02:41+0000  uid 0
     xlated 41288B  jited 23904B  memlock 45056B
     map_ids 88,91,93,104,117,120
     btf_id 55
```

18. **Enumerate the pinned map set.**

```bash
cnode "$NODE" ls -1 /sys/fs/bpf/tc/globals/ | sort
cnode "$NODE" cilium-dbg map list --verbose | head -30
```

```
cilium_call_policy
cilium_calls_00412
cilium_ct4_global
cilium_ct_any4_global
cilium_events
cilium_ipcache
cilium_lb4_backends_v3
cilium_lb4_reverse_nat
cilium_lb4_services_v2
cilium_lxc
cilium_metrics
cilium_node_map
cilium_policy_v2_00412
cilium_runtime_config
cilium_tunnel_map
```

19. **Read the endpoint map — the "who lives on this node" table.**

```bash
cnode "$NODE" cilium-dbg bpf endpoint list
```

```
IP ADDRESS        LOCAL ENDPOINT INFO
10.0.1.87:0       id=2623  sec_id=10530 flags=0x0000 ifindex=11  mac=3E:04:.. nodemac=..
10.0.1.115:0      id=191   sec_id=4     flags=0x0000 ifindex=9   mac=BA:22:.. nodemac=..
172.18.0.3:0      (localhost)
```

> **Q9.** `cilium_net` and `cilium_host` are a veth pair with each other, not with any pod. What is that pair for, and which IP does `cilium_host` carry?
>
> **Q10.** The program on the pod's host-side device is named `cil_from_container` and it is attached at **`tcx/ingress`**. Traffic *leaving* the pod hits it. Explain why "ingress" is the correct direction here — from whose point of view?
>
> **Q11.** Programs are pinned under `/sys/fs/bpf/tc/globals/`. Why does Cilium pin maps to a bpffs instead of relying on the program's own reference? What survives an agent restart, and what does the agent do on startup as a result?
>
> **Q12.** `cilium_calls_00412` and `cilium_policy_v2_00412` are per-endpoint, while `cilium_ipcache` and `cilium_ct4_global` are node-global. Why is the policy map per-endpoint but conntrack global by default? Name the agent flag that makes conntrack per-endpoint instead and one reason you would not want that.
>
> **Q13.** Delete a pod and immediately re-create it. Its endpoint ID changes, but `cilium_lxc` never accumulates stale entries. Which component performs that cleanup, and via which interface (CNI, Kubernetes watch, or both)?

---

## Exercise 4 — Endpoints, labels and security identities

This is the conceptual core of the domain: **Cilium does not write policy about IP addresses; it writes policy about identities, and identities are derived from labels.**

20. **List the endpoints on a node and read the identity column.**

```bash
cnode "$NODE" cilium-dbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                   IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
191        Disabled           Disabled          4          reserved:health                               10.0.1.115   ready
842        Disabled           Disabled          1          k8s:node-role.kubernetes.io/worker
                                                           reserved:host                                              ready
2623       Disabled           Disabled          33807      k8s:class=tiefighter                          10.0.1.87    ready
                                                           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
                                                           k8s:io.cilium.k8s.policy.cluster=default
                                                           k8s:io.cilium.k8s.policy.serviceaccount=default
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
```

21. **List the identities the cluster has allocated.**

```bash
cany cilium-dbg identity list
kubectl get ciliumidentities.cilium.io
```

```
ID      LABELS
1       reserved:host
2       reserved:world
3       reserved:unmanaged
4       reserved:health
5       reserved:init
6       reserved:remote-node
7       reserved:kube-apiserver
8       reserved:ingress
9       reserved:world-ipv4
10530   k8s:class=deathstar
        k8s:io.kubernetes.pod.namespace=default
        k8s:org=empire
        ...
33807   k8s:class=tiefighter
        ...
51402   k8s:class=xwing
        k8s:org=alliance
        ...
```

22. **Inspect one identity in detail, and its CRD backing object.**

```bash
cany cilium-dbg identity get 10530
kubectl get ciliumidentity 10530 -o yaml | head -30
```

23. **Prove that identity follows labels, not pods.** Scale the deployment and watch the identity count stay flat.

```bash
kubectl scale deploy/deathstar --replicas=4
kubectl wait --for=condition=Ready pod -l class=deathstar --timeout=90s
kubectl get ciliumendpoints.cilium.io
```

```
NAME                         ENDPOINT ID   IDENTITY ID   INGRESS   EGRESS   IPV4         STATUS
deathstar-6fb5694d48-5hmds   1287          10530         <status>  <status> 10.0.2.31    ready
deathstar-6fb5694d48-9k4xq   2044          10530         <status>  <status> 10.0.1.203   ready
deathstar-6fb5694d48-p2rlz   3311          10530         <status>  <status> 10.0.2.140   ready
deathstar-6fb5694d48-wq7fn   1902          10530         <status>  <status> 10.0.1.66    ready
tiefighter                   2623          33807         <status>  <status> 10.0.1.87    ready
xwing                        1455          51402         <status>  <status> 10.0.2.88    ready
```

24. **Now change a label and watch a *new* identity appear.**

```bash
cany cilium-dbg identity list | wc -l
kubectl label pod xwing tier=frontend
sleep 3
kubectl get ciliumendpoint xwing -o jsonpath='{.status.identity.id}{"\n"}'
cany cilium-dbg identity list | wc -l
```

25. **Reset it and confirm garbage collection.**

```bash
kubectl label pod xwing tier-
sleep 5
kubectl get ciliumidentities.cilium.io --sort-by=.metadata.creationTimestamp | tail -5
```

> **Q14.** Four `deathstar` pods on two nodes share identity `10530`. State the consequence for the size of the eBPF policy map: how many entries does an "allow from tiefighter" rule need, and how does that scale as replicas grow to 400?
>
> **Q15.** From the label list of endpoint 2623, name the two labels Cilium synthesises that do **not** exist on the Kubernetes pod object, and explain what each one makes expressible in a policy.
>
> **Q16.** `reserved:world` is `2`, `reserved:remote-node` is `6`, `reserved:host` is `1`. A pod on worker1 connects to a pod on worker2. Which identity is on the *packet* at each hop, and why is `remote-node` distinct from `host`?
>
> **Q17.** Cluster-local identities are numbered from 256 upward. CIDR-derived identities show up as very large numbers (≥ 16777216). What structural distinction does that bit encode, and why can a CIDR identity not be allocated cluster-wide the way a label-based one is?
>
> **Q18.** Adding `tier=frontend` produced a new identity. Give the operational risk this creates on a cluster where a mutating webhook injects a unique label (e.g. a build SHA) into every pod.
>
> **Q19.** `CiliumIdentity` is a cluster-scoped CRD here. Name the alternative identity-allocation backend Cilium supports, and one concrete reason to choose it over CRDs.

---

## Exercise 5 — ipcache, routing mode and the tunnel map

The endpoint map answers "who is local". The **ipcache** answers "who is *anyone*, anywhere, and how do I reach them".

26. **Read the ipcache.**

```bash
cnode "$NODE" cilium-dbg bpf ipcache list | head -20
```

```
IP PREFIX/ADDRESS   IDENTITY
0.0.0.0/0           identity=2 encryptkey=0
10.0.0.0/24         identity=6 encryptkey=0 tunnelendpoint=172.18.0.2
10.0.1.87/32        identity=33807 encryptkey=0 tunnelendpoint=0.0.0.0
10.0.1.115/32       identity=4 encryptkey=0 tunnelendpoint=0.0.0.0
10.0.2.0/24         identity=6 encryptkey=0 tunnelendpoint=172.18.0.4
10.0.2.31/32        identity=10530 encryptkey=0 tunnelendpoint=172.18.0.4
172.18.0.3/32       identity=1 encryptkey=0
172.18.0.4/32       identity=6 encryptkey=0
```

27. **Read the tunnel map — the overlay's forwarding table.**

```bash
cnode "$NODE" cilium-dbg bpf tunnel list
```

```
TUNNEL       VALUE
10.0.0.0:0   172.18.0.2:0
10.0.2.0:0   172.18.0.4:0
```

28. **Check the MTU the agent handed to pods.**

```bash
kubectl exec tiefighter -- ip link show eth0 | head -2
docker exec "$NODE" ip link show eth0 | head -2
```

```
2: eth0@if11: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...   # pod
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...  # node
```

29. **Watch encapsulation on the wire.** Generate cross-node traffic and capture VXLAN on the node uplink.

```bash
# terminal A
docker exec cca-lab-worker timeout 20 \
  tcpdump -ni eth0 'udp port 8472' -c 6 -vv

# terminal B
DS=$(kubectl get svc deathstar -o jsonpath='{.spec.clusterIP}')
kubectl exec tiefighter -- \
  sh -c 'for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code}\n" \
         -XPOST http://deathstar/v1/request-landing; done'
```

```
11:41:07.220314 IP (tos 0x0, ttl 64, id 0, offset 0, flags [DF], proto UDP (17), length 128)
    172.18.0.3.36815 > 172.18.0.4.8472: VXLAN, flags [I] (0x08), vni 0
    IP (tos 0x0, ttl 63, id 12094, ..., length 78)
    10.0.1.87.44210 > 10.0.2.31.80: Flags [S], seq 2718281828, win 64240, length 0
```

30. **Read the node map (the "which node is which" table used for native routing and health).**

```bash
cnode "$NODE" cilium-dbg bpf nodeid list | head
cany cilium-dbg node list
```

31. **Compare the alternative.** Do **not** apply this in the lab cluster unless you want to rebuild it — read and predict instead:

```bash
# Native routing: no encapsulation. Requires the underlay to route PodCIDRs.
cilium upgrade --reuse-values \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.0.0.0/8 \
  --set autoDirectNodeRoutes=true
```

> **Q20.** In the ipcache, `10.0.2.31/32` has `tunnelendpoint=172.18.0.4` while `10.0.1.87/32` has `tunnelendpoint=0.0.0.0`. What does the zero value mean, and what does the datapath do differently in each case?
>
> **Q21.** The ipcache holds both a `/24` for the remote node's pod range **and** `/32` entries for individual remote pods. Why both? Which one supplies the security identity for policy decisions, and what happens if only the `/24` is present when a packet arrives?
>
> **Q22.** Pod MTU is 1450 while node MTU is 1500. Derive the 50 bytes. What symptom appears if you force pod MTU to 1500 in VXLAN mode — and why does `curl` to a small endpoint succeed while a large `POST` hangs?
>
> **Q23.** `--set routingMode=native --set autoDirectNodeRoutes=true` works in this kind cluster but would fail on most cloud VPCs without extra work. State the underlay requirement `autoDirectNodeRoutes` assumes, and name the cloud-native alternative Cilium offers instead.
>
> **Q24.** In native routing mode, what happens to the `cilium_vxlan` device and to `cilium_tunnel_map`? Which map takes over the "how do I reach that node" job?

---

## Exercise 6 — kube-proxy replacement and the load-balancer maps

32. **Confirm the replacement is fully active.**

```bash
cany cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/^$/p'
```

```
KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0   172.18.0.3 (Direct Routing)
  Mode:                   SNAT
  Backend Selection:      Random
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Disabled
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

33. **Read the service table as the agent sees it, then as the datapath sees it.**

```bash
cany cilium-dbg service list
cany cilium-dbg bpf lb list
```

```
ID   Frontend              Service Type   Backend
1    10.96.0.1:443/TCP     ClusterIP      1 => 172.18.0.2:6443/TCP (active)
2    10.96.0.10:53/UDP     ClusterIP      1 => 10.0.1.211:53/UDP (active)
                                          2 => 10.0.2.99:53/UDP (active)
3    10.96.0.10:53/TCP     ClusterIP      1 => 10.0.1.211:53/TCP (active)
                                          2 => 10.0.2.99:53/TCP (active)
7    10.96.184.22:80/TCP   ClusterIP      1 => 10.0.2.31:80/TCP (active)
                                          2 => 10.0.1.203:80/TCP (active)
                                          3 => 10.0.2.140:80/TCP (active)
                                          4 => 10.0.1.66:80/TCP (active)
```

34. **Prove that the translation happens at `connect()` time, not on the wire.** Start a capture on the pod's own interface, then curl the ClusterIP.

```bash
# terminal A — capture inside the pod's netns
kubectl exec tiefighter -- timeout 15 tcpdump -ni eth0 'tcp port 80' -c 4

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' \
  -XPOST http://10.96.184.22/v1/request-landing
```

Observe the destination address in the capture:

```
11:52:44.101223 IP 10.0.1.87.51124 > 10.0.2.31.80: Flags [S], seq ...
```

35. **Confirm there are no iptables Service rules.**

```bash
docker exec "$NODE" iptables-save | grep -c KUBE-SERVICES || echo "0 KUBE-SERVICES chains"
docker exec "$NODE" iptables-save | grep -c CILIUM || true
```

36. **Watch the socket LB decision directly** (requires `Socket LB Tracing: Enabled`):

```bash
# terminal A
cnode "$NODE" cilium-dbg monitor -t trace-sock

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null http://10.96.184.22/
```

```
xx [pre-xlate-rev] cgroup_id: 8123 sock_cookie: 41028, dst [10.0.2.31]:80 tcp
xx [post-xlate-fwd] cgroup_id: 8123 sock_cookie: 41028, dst [10.0.2.31]:80 tcp
```

37. **Exercise NodePort and see the reverse-NAT entry.**

```bash
kubectl patch svc deathstar -p '{"spec":{"type":"NodePort"}}'
NP=$(kubectl get svc deathstar -o jsonpath='{.spec.ports[0].nodePort}')
curl -s -o /dev/null -w '%{http_code}\n' "http://172.18.0.3:$NP/"
cany cilium-dbg bpf lb list --revnat
kubectl patch svc deathstar -p '{"spec":{"type":"ClusterIP"}}'
```

> **Q25.** The capture inside the pod shows the destination as `10.0.2.31:80`, never `10.96.184.22:80`. At which kernel hook did the translation happen, and what is the performance consequence versus DNAT in `iptables`/conntrack?
>
> **Q26.** Socket LB rewrites the destination in `connect()`. What kind of client is therefore *not* covered by it, and which mechanism handles those instead? (Consider a pod in host network namespace, and traffic entering the node from outside.)
>
> **Q27.** `Mode: SNAT` appears under KubeProxyReplacement Details. What is being SNAT'd, in which scenario, and what is the alternative mode that avoids it? Name one trade-off of that alternative.
>
> **Q28.** `Graceful Termination: Enabled`. A backend pod enters `Terminating`. What state does its entry take in `cilium_lb4_backends_v3`, and what happens to (a) existing connections and (b) new connections?
>
> **Q29.** You must debug "ClusterIP works from a pod but not from the node itself". Give the three checks you would run, in order, and what each would prove.

---

## Exercise 7 — Observability: `cilium-dbg monitor` and Hubble

38. **Raw datapath events, from the perf ring buffer.**

```bash
# terminal A
cnode "$NODE" cilium-dbg monitor -v --type drop --type trace

# terminal B
kubectl exec tiefighter -- curl -s -o /dev/null \
  -XPOST http://deathstar/v1/request-landing
```

```
-> endpoint 2623 flow 0x8f2a1c34 , identity 10530->33807 state reply ifindex lxc8a3f21c94b17 orig-ip 10.0.2.31: 10.0.2.31:80 -> 10.0.1.87:44210 tcp ACK
-> stack flow 0x3b1e0022 , identity 33807->10530 state new ifindex 0 orig-ip 0.0.0.0: 10.0.1.87:44210 -> 10.0.2.31:80 tcp SYN
```

39. **Enable Hubble and its UI.**

```bash
cilium hubble enable --ui
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=hubble-relay
```

40. **Point the CLI at Relay and check it.**

```bash
cilium hubble port-forward &          # local 4245 -> hubble-relay
sleep 3
hubble status
```

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,288/12,288 (100.00%)
Flows/s: 21.14
Connected Nodes: 3/3
```

41. **Observe flows with identity context.**

```bash
kubectl exec tiefighter -- \
  sh -c 'for i in $(seq 5); do curl -s -o /dev/null \
         -XPOST http://deathstar/v1/request-landing; done'

hubble observe --last 10 --pod default/tiefighter
```

```
Sep  1 12:03:11.412: default/tiefighter:44210 (ID:33807) -> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) to-overlay FORWARDED (TCP Flags: SYN)
Sep  1 12:03:11.413: default/tiefighter:44210 (ID:33807) -> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:03:11.414: default/deathstar-6fb5694d48-5hmds:80 (ID:10530) -> default/tiefighter:44210 (ID:33807) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
```

42. **Filter the way you will need to under exam time pressure.**

```bash
hubble observe --verdict DROPPED --last 20
hubble observe --to-label class=deathstar --protocol tcp --port 80 -f
hubble observe --namespace kube-system --type l7 --last 20
hubble observe -o json --last 1 | python3 -m json.tool | head -40
```

43. **Open the UI** (optional, browser required):

```bash
cilium hubble ui        # opens http://localhost:12000
```

> **Q30.** `cilium-dbg monitor` and `hubble observe` both read the same underlying event source. Name it, and state two things `hubble observe` gives you that `cilium-dbg monitor` cannot.
>
> **Q31.** In step 38 you saw `to-overlay` and `to-endpoint` for one HTTP request. Explain the difference, and say which one appears on the *source* node versus the *destination* node.
>
> **Q32.** You set `bpf.monitorAggregation=none` at install time. What is the default value, what does it aggregate, and what will you *stop seeing* if you set it back to the default before the drop test in Exercise 8?

---

## Exercise 8 — First CiliumNetworkPolicy: L3/L4, then L7

44. **Establish the baseline: everything talks to everything.**

```bash
for p in tiefighter xwing; do
  echo -n "$p -> deathstar: "
  kubectl exec "$p" -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
    -XPOST http://deathstar/v1/request-landing
done
```

```
tiefighter -> deathstar: 200
xwing -> deathstar: 200
```

45. **Apply an identity-based L3/L4 ingress policy.**

```yaml
# cnp-l34.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-empire-only
  namespace: default
spec:
  description: "Only endpoints labelled org=empire may reach the deathstar on 80/TCP"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

```bash
kubectl apply -f cnp-l34.yaml
kubectl get cnp deathstar-empire-only -o wide
```

46. **Observe enforcement flip on, per direction.**

```bash
cany cilium-dbg endpoint list | grep -E 'ENDPOINT|deathstar|33807|51402'
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
1287       Enabled            Disabled          10530      k8s:class=deathstar ...
2623       Disabled           Disabled          33807      k8s:class=tiefighter ...
```

47. **Retest.**

```bash
kubectl exec tiefighter -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing        # 200
kubectl exec xwing      -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing        # hangs, then exits 28
```

48. **See the drop from both observability layers.**

```bash
hubble observe --verdict DROPPED --last 5
```

```
Sep  1 12:14:02.905: default/xwing:52104 (ID:51402) <> default/deathstar-6fb5694d48-5hmds:80 (ID:10530) Policy denied DROPPED (TCP Flags: SYN)
```

```bash
DS_NODE=$(kubectl get pod -l class=deathstar -o jsonpath='{.items[0].spec.nodeName}')
cnode "$DS_NODE" cilium-dbg monitor -t drop
```

```
xx drop (Policy denied) flow 0x0 to endpoint 1287, ifindex 15, file bpf_lxc.c:2054,
   identity 51402->10530: 10.0.2.88:52104 -> 10.0.2.31:80 tcp SYN
```

49. **Read the compiled policy map for the enforcing endpoint.**

```bash
cnode "$DS_NODE" cilium-dbg bpf policy get 1287
```

```
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
Allow    Ingress     33807      k8s:class=tiefighter          80/TCP       NONE         disabled    2914    24
                                k8s:org=empire
Allow    Ingress     10530      k8s:class=deathstar           80/TCP       NONE         disabled    0       0
                                k8s:org=empire
Allow    Egress      0          reserved:unknown              ANY          NONE         disabled    18422   142
```

50. **Use the policy tracer to answer "would this be allowed?" without sending a packet.**

```bash
cnode "$DS_NODE" cilium-dbg policy trace \
  --src-identity 51402 --dst-identity 10530 --dport 80/TCP
```

51. **Now upgrade to L7.** Replace the policy so only `POST /v1/request-landing` is permitted.

```yaml
# cnp-l7.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-empire-only
  namespace: default
spec:
  description: "Empire ships may only request landing; no other HTTP verb or path"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
```

```bash
kubectl apply -f cnp-l7.yaml
kubectl exec tiefighter -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -XPOST http://deathstar/v1/request-landing         # 200
kubectl exec tiefighter -- curl -s -m 5 -w '%{http_code}\n' \
  -XPUT http://deathstar/v1/exhaust-port             # 403 Access denied
```

52. **Confirm the proxy is now in the path.**

```bash
cnode "$DS_NODE" cilium-dbg bpf policy get 1287 | grep -E 'PROXY|Allow'
cnode "$DS_NODE" cilium-dbg status --verbose | grep -A5 'Proxy Status'
hubble observe --type l7 --last 5
```

```
Sep  1 12:21:44.010: default/tiefighter:44780 (ID:33807) -> default/deathstar-...:80 (ID:10530) http-request FORWARDED (HTTP/1.1 POST http://deathstar/v1/request-landing)
Sep  1 12:21:49.552: default/tiefighter:44782 (ID:33807) -> default/deathstar-...:80 (ID:10530) http-request DROPPED (HTTP/1.1 PUT http://deathstar/v1/exhaust-port)
```

> **Q33.** Two failure modes, two symptoms: the L3/L4 denial made `curl` **hang until timeout**, the L7 denial returned **HTTP 403 immediately**. Explain the mechanism behind each, and say what each tells you about where the packet died.
>
> **Q34.** In step 49, egress shows a single `Allow Egress → identity 0 / reserved:unknown / ANY`. Why is egress wide open on an endpoint that has an ingress policy? State the rule about default-deny in Cilium, and how you would make egress default-deny for this endpoint with a minimal edit.

---

## Exercise 9 — Validate, then tear down

53. **Run the built-in conformance suite.** With a policy in place it will fail — remove it first.

```bash
kubectl delete cnp deathstar-empire-only
cilium connectivity test --test-namespace cilium-test
```

```
✅ [cca-lab] 47/47 tests successful (0 warnings)
```

54. **Sanity-check the whole stack one last time.**

```bash
cilium status
cany cilium-dbg status --brief          # -> OK
cany cilium-dbg-health status 2>/dev/null || cany cilium-health status
```

55. **Tear down.**

```bash
kubectl delete -f starwars.yaml --ignore-not-found
cilium connectivity test --test-namespace cilium-test --purge 2>/dev/null || \
  kubectl delete ns cilium-test --ignore-not-found
kind delete cluster --name "$CLUSTER"
```

---

<details>
<summary><strong>Answers (Q1 – Q34)</strong></summary>

### Exercise 1

**A1.** The failing subsystem is the kubelet's **CRI network plugin check**: kubelet polls for a valid CNI config in `--cni-conf-dir` (`/etc/cni/net.d`) and a matching binary in `/opt/cni/bin`; finding none it sets the `NetworkReady=false` condition, which surfaces as `NotReady`. Control-plane static pods still start because they run with `hostNetwork: true` — they use the node's network namespace directly and never invoke the CNI plugin. This is exactly why `kubectl` keeps working: the API server is on `172.18.0.2:6443`, the node's own IP.

**A2.** With no kube-proxy, nothing programs the `10.96.0.1:443` ClusterIP. The cycle: the Cilium agent needs the API server to read Kubernetes objects → the in-cluster API endpoint is a Service VIP → the VIP is only translated once Cilium itself has installed the Service into `cilium_lb4_services_v2` → which requires having read the Service from the API server. Passing `k8sServiceHost`/`k8sServicePort` breaks the cycle by giving the agent a concrete address. With kube-proxy present, it has already programmed the VIP in iptables/IPVS before Cilium starts, so `10.96.0.1:443` resolves and no override is needed.

**A3.** Cilium's socket LB runs at the **cgroup BPF hooks** (`connect4`/`connect6`, `sendmsg`, `recvmsg`) — i.e. inside the `connect()` syscall, *before a packet exists*. kube-proxy's iptables DNAT runs in **netfilter's `nat` table at `OUTPUT`/`PREROUTING`**, on a packet already on the wire. Cilium therefore wins for pod-originated ClusterIP traffic: the socket's destination is already rewritten to a backend IP by the time netfilter sees it, so the `KUBE-SERVICES` rules never match. The danger is not "which wins" but the inconsistency: NodePort and host-namespace paths may still traverse kube-proxy's rules, giving you two independent, divergent Service tables and stale conntrack entries.

### Exercise 2

**A4.**
- **`cilium` DaemonSet (agent)** — one per node; compiles and attaches the eBPF programs, owns every BPF map on that node, allocates IPs, translates Kubernetes objects into datapath state, exposes the Hubble server. Delete it: existing flows keep working (the eBPF programs stay loaded and the maps stay pinned), but no *new* pods get networking and no policy/Service change is applied on that node.
- **`cilium-operator` Deployment** — cluster-scoped, one or two replicas, not in the datapath. Owns cluster-wide IPAM (carving PodCIDRs per `CiliumNode`), `CiliumIdentity` garbage collection, `CiliumEndpoint` GC, kvstore heartbeat. Delete it: the datapath is untouched, but see A5.
- **`cilium-envoy` DaemonSet** — the L7 proxy. Since 1.16 it runs as its own DaemonSet rather than embedded in the agent, so that an agent restart does not tear down live L7 connections. Delete it: L3/L4 policy is unaffected; every policy with an `http`/`kafka`/`dns` rule loses enforcement capability and the affected traffic is dropped.
- **`cilium-cni`** — the CNI binary the kubelet execs on pod sandbox creation; it talks to the local agent over a Unix socket to get an IP and create the endpoint. Delete it: no new pod can be networked on that node (`FailedCreatePodSandBox`); running pods are unaffected.

**A5.** In `ipam.mode=cluster-pool` the operator is what allocates each node's PodCIDR into `CiliumNode.spec.ipam.podCIDRs`. Each node has already been given a `/24` and holds a local pool, so pods keep being networked for as long as that pool has free addresses. The first thing to break is **a node exhausting its pool, or a *new* node joining and never receiving a PodCIDR** — its agent will sit reporting `waiting for IPAM`, and every pod scheduled there fails to start. The second is `CiliumIdentity` garbage collection stopping, so identities leak.

**A6.** `Network: Tunnel [vxlan]` is how packets get **between nodes** (encapsulated in VXLAN). `Host: BPF` is how packets traverse the **host network namespace on the way to and from the pod** — Cilium's "eBPF host routing" bypasses the host's upper network stack (netfilter, routing table lookups) by redirecting directly from the physical device's BPF program into the pod's device. They are orthogonal: you can have BPF host routing with either tunnel or native network routing. Without it (`Host: Legacy`) packets take the normal iptables/routing path, costing throughput and latency.

**A7.** **TCX** (`BPF_PROG_TYPE_SCHED_CLS` attached via `bpf_link` at `BPF_TCX_INGRESS`/`BPF_TCX_EGRESS`) is a kernel attach API introduced in **Linux 6.6**. It replaces the old `tc` classifier/qdisc attachment with link-based ownership, giving atomic replacement, deterministic multi-program ordering, and automatic detach when the link's owner exits — which removes a whole class of "stale tc filter left behind after an agent crash" bugs. When the kernel is older, Cilium falls back to classic **tc BPF via a `clsact` qdisc** (`tc filter add dev … ingress bpf …`), visible with `tc filter show dev <lxc> ingress`.

**A8.** `podSubnet` in the kind config is only consumed by kube-controller-manager (`--cluster-cidr`) and by the default CNI — which you disabled. Cilium's **cluster-pool IPAM ignores it entirely** and carves from its own `clusterPoolIPv4PodCIDRList`, whose default is `10.0.0.0/8` with `clusterPoolIPv4MaskSize: 24`. The per-node range is recorded on the `CiliumNode` CRD at **`spec.ipam.podCIDRs`** (verify with `kubectl get ciliumnode cca-lab-worker -o jsonpath='{.spec.ipam.podCIDRs}'`). To honour kind's subnet you would set `--set ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}`; to have Cilium read `node.spec.podCIDR` instead, use `--set ipam.mode=kubernetes`.

### Exercise 3

**A9.** `cilium_host`/`cilium_net` is the veth pair that connects the **host network namespace to the Cilium-managed datapath**. `cilium_host` carries the node's **router IP** (also called the `cilium_host` IP or gateway IP) — the first address of the node's PodCIDR, `10.0.1.87`-style in the `Allocated addresses` list under the label `(router)`. Every pod's default route points at it (`default via <router-ip> dev eth0`), and it is the source address used for host-originated traffic that must appear to come from inside the pod network (e.g. health probes traversing the overlay).

**A10.** The direction is named **from the host kernel's point of view on that device**, not the pod's. The `lxcXXXX` device lives in the host namespace and is the peer of the pod's `eth0`. A packet the pod *sends* arrives at the host end of the veth as **ingress on `lxcXXXX`** — hence `cil_from_container` at `tcx/ingress`. Symmetrically, a packet destined *for* the pod is transmitted out of `lxcXXXX`, i.e. **egress**, handled by `cil_to_container`. Getting this backwards is a classic source of confusion when reading `bpftool net show`.

**A11.** A BPF map lives only as long as something holds a file descriptor to it. Pinning to bpffs (`/sys/fs/bpf`) creates a filesystem reference that keeps the map alive **independently of the agent process**. Consequence: when the agent restarts or is upgraded, the maps — and therefore the conntrack table, the ipcache, the LB tables and the policy maps — **survive**, so existing connections are not broken and Service translation keeps working during the restart window. On startup the agent **re-opens the pinned maps and reconciles** them against the desired state from Kubernetes, adding/removing deltas rather than rebuilding from scratch. If the map's *definition* changed (new key/value layout in a new Cilium version), the agent detects the mismatch, unpins and recreates it — which is why upgrades that change map layouts cause a brief drop of the corresponding state.

**A12.** The **policy map is per-endpoint** because the policy verdict set is a property of one identity's rules: the datapath does a single lookup keyed by `(peer identity, port, protocol, direction)` in *that endpoint's* map, so the lookup stays O(1) and small regardless of how many other workloads exist on the node. Making it global would force the endpoint ID into the key and blow up both the key space and the tail-call structure. **Conntrack is global** because it is a shared node resource — one large, pre-sized LRU hash is far more memory-efficient than N per-endpoint tables that each have to be sized for the worst case, and it lets the node cap total conntrack memory. The flag for per-endpoint conntrack is **`--enable-endpoint-routes` combined with the legacy per-endpoint CT option (`conntrack-local` / `--enable-local-conntrack`)**; the reason to avoid it is memory amplification and the loss of a single node-wide conntrack accounting/eviction policy — with hundreds of endpoints per node you multiply the table overhead by the endpoint count.

**A13.** Both, and the distinction matters. The **CNI plugin's `DEL` call** is the primary path: kubelet invokes `cilium-cni DEL` on sandbox teardown, which tells the agent to remove the endpoint, free the IP and delete the `cilium_lxc` entry. Because CNI `DEL` can be missed (node reboot, kubelet crash, agent down during the delete), the agent additionally runs a **restore/reconcile pass against the Kubernetes pod watch** on startup and periodically, deleting endpoints whose pod no longer exists. Cluster-wide, `cilium-operator` GCs orphaned `CiliumEndpoint` objects. Nothing depends on a single mechanism.

### Exercise 4

**A14.** Exactly **one** entry: `Allow / Ingress / identity 33807 / 80 TCP`. That entry is identical on every node hosting a `deathstar` pod, and identical in every `deathstar` endpoint's policy map. Scaling to **400 replicas adds zero policy-map entries** — identity is derived from the label set, and 400 identically-labelled pods collapse to one identity. This is the central scaling property of Cilium's model versus IP-set-based implementations, where an "allow from X" rule grows linearly with X's replica count and every scale event triggers a rule-set recompute on every node.

**A15.** The two synthesised labels are:
- **`k8s:io.kubernetes.pod.namespace=default`** — makes the namespace part of the identity, so `endpointSelector` and `fromEndpoints` can express namespace scoping (and so that identically-labelled pods in different namespaces get *different* identities). Cilium also adds `k8s:io.cilium.k8s.namespace.labels.<key>=<value>` mirroring the namespace object's own labels, which is what lets `fromEndpoints: matchLabels: {io.cilium.k8s.namespace.labels.team: payments}` work.
- **`k8s:io.cilium.k8s.policy.serviceaccount=default`** — makes the pod's ServiceAccount part of the identity, enabling ServiceAccount-based policy (`fromEndpoints: matchLabels: {io.cilium.k8s.policy.serviceaccount: frontend}`), i.e. policy tied to workload identity rather than to pod labels an attacker could set.

(`k8s:io.cilium.k8s.policy.cluster=default` is the third, and is what makes identities unambiguous across a ClusterMesh.)

**A16.** The packet carries the **source pod's identity** (e.g. `33807`) end to end — that is the whole point: the identity travels with the packet, in the VXLAN header's reserved/VNI-adjacent field in tunnel mode, or in an IPsec/WireGuard-adjacent field or via the ipcache lookup in native mode. The receiving node's `cil_to_container` program uses that identity for the policy lookup. `reserved:host` (1) and `reserved:remote-node` (6) are distinct because **"the host I am running on" and "some other node in the cluster" warrant different trust levels**: traffic from the local host namespace (kubelet health probes, hostNetwork pods) is inherently local and is allowed by default, whereas traffic from a *remote* node is a distinct security principal you may want to policy separately — this is what makes the Host Firewall (`CiliumClusterwideNetworkPolicy` with `nodeSelector`) expressible. Before this split existed, remote nodes were folded into `reserved:host` and could not be distinguished.

**A17.** The high bit (`1 << 24`, i.e. 16777216) marks a **local-scope identity**: one that is meaningful only on the node that allocated it. Label-based identities are allocated **cluster-wide** through a shared allocator (the `CiliumIdentity` CRD or the kvstore) so that identity `10530` means the same label set on every node — required, because the number travels inside the packet. CIDR identities cannot work that way because they are derived from **the set of CIDR policy rules a given node has to enforce**, and the same IP prefix may be covered by different, overlapping prefixes on different nodes; the mapping is a per-node function of the local longest-prefix-match tree, not a global fact. So they are allocated from a node-local range and are never put on the wire as a peer identity for a remote node to interpret.

**A18.** Every unique label combination produces a new `CiliumIdentity` object and a new numeric identity. A webhook injecting a per-build SHA gives **one identity per pod**, which destroys the entire scaling property: identities grow linearly with pod count, `CiliumIdentity` objects flood etcd, the operator's GC falls behind, policy maps grow linearly with peer count, and you can hit the cluster-local identity ceiling (default range 256–65535). The mitigation is `--labels` / Helm `labels:` on the agent — an explicit allow-list (or `--exclude-labels` regex) of which label keys participate in identity computation. Auditing that list is a standard production hardening step.

**A19.** The alternative is a **kvstore backend — etcd** (`identityAllocationMode: kvstore`, historically also Consul). Reasons to choose it: identity allocation and propagation go through a dedicated etcd rather than the Kubernetes API server, which removes very-high-churn identity writes from the cluster's own etcd and its watch fan-out — this matters at large scale (thousands of nodes / high pod churn), and a dedicated kvstore is also the transport used by ClusterMesh. The cost is an additional stateful component to run, secure and back up; CRD mode has been the default since 1.6 precisely because most clusters prefer no extra dependency.

### Exercise 5

**A20.** `tunnelendpoint=0.0.0.0` means **"this IP is local to this node"** — there is no remote tunnel endpoint to encapsulate towards; the datapath resolves the destination in `cilium_lxc` and redirects straight into the local pod's device (`redirect_peer`/`redirect_neigh`), never touching the overlay. A non-zero `tunnelendpoint` means the destination is on **that** remote node, so the packet is pushed into `cilium_vxlan` with the outer destination set to `172.18.0.4`. Concretely: same-node pod-to-pod traffic never gets encapsulated and never leaves the node.

**A21.** They answer different questions at different times.
- The **`/32`** is the authoritative per-endpoint entry: it supplies the **security identity** for the policy lookup, plus the exact tunnel endpoint. Policy decisions use this.
- The **`/24`** is the node-level summary, installed when a `CiliumNode` is learned. It supplies reachability and the `reserved:remote-node` identity for the *node*, and it is what lets a packet be forwarded to the right node even for a destination whose `/32` has not yet been learned.

The ipcache is a **longest-prefix-match (LPM) trie**, so a specific `/32` always wins over the covering `/24`. If only the `/24` is present when a packet arrives, the lookup resolves to identity `6` (`reserved:remote-node`) instead of the real workload identity, and an "allow from `class=tiefighter`" rule will **not** match — the packet is dropped as `Policy denied`. This is the mechanism behind the classic transient drops right after a pod starts on a remote node, before ipcache propagation completes.

**A22.** VXLAN overhead = **outer Ethernet header 14 + outer IPv4 header 20 + outer UDP header 8 + VXLAN header 8 = 50 bytes**. 1500 − 50 = **1450**.

If you force pod MTU to 1500, a full-size 1500-byte pod frame becomes 1550 bytes after encapsulation, exceeding the node link's 1500 MTU. Small requests succeed because they never produce a full-size segment; a large `POST` hangs because the *data* segments are full-size and get dropped, while the handshake and headers went through. Classic **PMTU black hole**: TCP retransmits the same oversized segment forever. It is intermittent and traffic-dependent, which is what makes it so painful to diagnose — and it is why `hubble observe` showing a clean handshake followed by silence should push you straight to MTU.

**A23.** `autoDirectNodeRoutes` installs a plain kernel route on every node saying "remote PodCIDR X is reachable via node Y's IP". That only works if **all nodes are on the same L2 segment / directly-connected L3 network** — the next hop must be directly reachable, and no intervening router may need to know about the PodCIDRs. In a cloud VPC, nodes across subnets are separated by the VPC router, which has no route for pod IPs, so packets are dropped or the source/destination check rejects them. The cloud-native alternative is **cloud-provider IPAM with native routing**: `ipam.mode=eni` on AWS (pods get real VPC IPs from ENI secondary addresses, so the VPC routes them natively), `ipam.mode=azure` / Azure delegated IPAM, or `gke` mode on GKE with alias IP ranges. The generic alternative when the underlay speaks BGP is Cilium's **BGP Control Plane** (`CiliumBGPClusterConfig`), advertising PodCIDRs to the fabric.

**A24.** In native routing mode the agent **does not create `cilium_vxlan` at all** (or removes it), and **`cilium_tunnel_map` is not used** — the ipcache entries carry `tunnelendpoint=0.0.0.0` for remote pods too, because there is no encapsulation. The "how do I reach that node" job moves to the **host's own routing table** (populated by `autoDirectNodeRoutes`, by BGP, or by the cloud's VPC route table), consulted through `cilium_node_map` / the ipcache for identity and through normal FIB lookup (`bpf_fib_lookup`) for the next hop. Pod MTU also rises to the full underlay MTU, since the 50-byte overhead disappears.

### Exercise 6

**A25.** The translation happened at the **cgroup v2 BPF hook `cgroup/connect4`**, inside the `connect()` syscall, before any packet was built — the socket's destination address is rewritten from the ClusterIP to a selected backend, so the very first SYN on the wire already carries `10.0.2.31:80`. Performance consequence versus iptables DNAT: (a) **no per-packet NAT** — translation is once per connection, at socket setup, not on every packet; (b) **no conntrack entry needed for the Service translation itself** and no reverse-NAT lookup on the return path, since the socket was never lying about its destination; (c) **O(1) hash lookup** instead of a linear walk of `KUBE-SERVICES`/`KUBE-SVC-*` chains that grows with Service count. The practical result is that latency stays flat as the number of Services grows, whereas iptables mode degrades measurably past a few thousand Services.

**A26.** Socket LB only covers clients whose `connect()`/`sendmsg()` happens **inside a cgroup the Cilium BPF programs are attached to** — i.e. pods managed by Cilium, and (with the cgroup root attachment) host-namespace processes on that node. It does **not** cover traffic that was never `connect()`ed locally: packets **arriving at the node from outside** (NodePort, LoadBalancer, externalIPs, HostPort), and traffic from network namespaces outside Cilium's cgroup scope. Those are handled by the **tc/XDP BPF programs on the node's physical devices** (`cil_from_netdev` at `tcx/ingress` on `eth0`, or an XDP program when `loadBalancer.acceleration=native`), which do a real DNAT plus a `cilium_lb4_reverse_nat` entry so the reply can be un-translated. `Socket LB Coverage: Full` in the status output tells you the host-namespace cgroup hook is attached too; `Hostns-only` or a missing cgroup mount means it is not.

**A27.** What is SNAT'd is the **source address of a NodePort/LoadBalancer packet that has to be forwarded to a backend on a *different* node**. Node A receives the request, picks a backend on node B, and must ensure the reply comes back through node A (which holds the reverse-NAT state), so it replaces the client's source IP with node A's IP. The trade-off is the well-known one: **the backend loses the original client source IP**, and there is an extra hop. The alternative is **DSR (Direct Server Return)**, `--set loadBalancer.mode=dsr`, where node B replies directly to the client with the Service VIP as source, preserving the client IP and halving the return path. Its trade-offs: the original destination must be carried to node B out-of-band (an IPv4 option / IPv6 extension header, or Geneve option — `loadBalancer.dsrDispatch`), which some middleboxes and cloud fabrics strip or drop; it requires the reply path from B to the client to be routable; and it costs MTU. `loadBalancer.mode=hybrid` uses DSR for TCP and SNAT for UDP as a compromise.

**A28.** The backend moves to state **`terminating`** in `cilium_lb4_backends_v3` (visible as `(terminating)` in `cilium-dbg bpf lb list`) rather than being deleted. Consequently: **(a) existing connections keep being served** — the conntrack entry still resolves to that backend, so in-flight requests and keep-alive connections finish cleanly; **(b) new connections are never sent to it** — it is excluded from the backend-selection set, so no fresh SYN lands on a pod that is shutting down. The entry is removed only once the endpoint is fully deleted. This is what turns a rolling update from "a burst of connection resets" into a clean drain, and it depends on the Kubernetes `EndpointSlice` terminating-condition fields being propagated (`enableK8sTerminatingEndpoint`, on by default).

**A29.** In order:

1. **`cany cilium-dbg service list`** (or `bpf lb list`) — confirms the Service exists in the datapath with live backends at all. If it is missing or has zero backends, the problem is upstream (EndpointSlice, selector, operator), not the host path, and you stop here.
2. **`cany cilium-dbg status --verbose | grep -A6 'KubeProxyReplacement Details'`, reading `Socket LB Coverage`** — `Full` means the cgroup hook is attached at the cgroup root and host-namespace processes *are* covered; anything else (or a bad/missing cgroup v2 mount at `/run/cilium/cgroupv2`) explains exactly this symptom: pods work, host does not. This is the single most likely cause.
3. **`cnode $NODE cilium-dbg monitor -t trace-sock -t drop` while reproducing from the node** (`docker exec <node> curl <clusterIP>`) — if you see no `trace-sock` event at all, the syscall is not being intercepted, confirming (2). If you see the translation but then a drop, you have a policy or routing problem instead, and `-t drop` names it. A useful fourth check when host traffic must egress a device: verify `Devices:` in the status output actually lists the interface the node routes out of (`--set devices=`), since an unlisted device has no `cil_from_netdev` attached.

### Exercise 7

**A30.** Both consume the same source: the **`cilium_events` perf ring buffer (`BPF_MAP_TYPE_PERF_EVENT_ARRAY`)**, into which the datapath programs push trace/drop/debug/policy-verdict records. `cilium-dbg monitor` is a raw, node-local tap on that buffer. `hubble observe` gets, among others:
- **Cluster-wide aggregation** — Hubble Relay fans out to every node's Hubble server (gRPC on `:4244`) and merges the streams, so one command shows both ends of a cross-node flow. `cilium-dbg monitor` only ever shows one node.
- **Kubernetes and DNS enrichment plus a queryable model** — raw events carry numeric identities and IPs; Hubble resolves them to `namespace/pod`, service names, FQDNs and labels, keeps a ring buffer of recent flows you can query retroactively (`--last`, `--since`), filters server-side (`--verdict`, `--to-label`, `--protocol`, `--http-status`), emits structured JSON, and exports L7 records and Prometheus metrics.

**A31.** They are different **trace observation points** in the datapath:
- **`to-overlay`** — emitted on the **source node**, at the moment the packet is handed to the tunnel device (`cilium_vxlan`) for encapsulation towards the remote node.
- **`to-endpoint`** — emitted on the **destination node**, at the moment the packet is delivered into the target pod's device (`cil_to_container` on the `lxc*` interface), *after* the ingress policy verdict.

Seeing `to-overlay` with no matching `to-endpoint` is the signature of a packet lost between nodes — underlay MTU, a firewall blocking UDP/8472, or a missing tunnel-map entry. (The companion points are `to-stack`, `to-network`, `to-proxy` and `from-*`; `cilium-dbg monitor -t trace` shows them all.)

**A32.** The default is **`bpf.monitorAggregation=maximum`**. It suppresses repeated trace events for a flow that is already in a known conntrack state, emitting a notification only when the observed **TCP flags change** (SYN, FIN, RST) or once per aggregation interval (`bpf.monitorInterval`, default `5s`) — dramatically reducing ring-buffer pressure and CPU on busy nodes. Set it back to the default and you **stop seeing per-packet forward traces for established connections**: you will get the SYN and the FIN but not the packets in between. Critically, **drop events are never aggregated** — `--type drop` and policy-verdict notifications are always delivered — so the Exercise 8 denial test works identically at the default setting. That is the correct production posture: keep aggregation on, and rely on drops plus flag-change traces.

### Exercise 8

**A33.**
- **L3/L4 denial → hang.** The verdict is made in eBPF in `cil_to_container` before the packet ever reaches the pod, and the packet is **silently discarded** — no RST, no ICMP administratively-prohibited. The client's SYN simply vanishes, so TCP retransmits it (1s, 2s, 4s …) until `curl -m 5` gives up with exit 28. The connection was **never established**; nothing above L4 was involved. This is deliberate: a silent drop leaks nothing to a scanner about whether the target exists.
- **L7 denial → immediate 403.** With an `http` rule present, the eBPF program **allows the TCP connection and redirects it to the local Envoy proxy** (a `PROXY PORT` appears in `cilium-dbg bpf policy get`). Envoy completes the TCP handshake and the TLS/HTTP parse, evaluates the request line against the rule, and — because `PUT /v1/exhaust-port` matches no rule — synthesises a **`403 Access denied`** response itself. The backend never sees the request.

Diagnostically: **a hang means the packet died at L3/L4 in eBPF; a 403 means it died at L7 in Envoy**, which also tells you the L3/L4 layer *allowed* it and your problem is the HTTP matcher, not the identity selector.

**A34.** Cilium's default-deny is **per-endpoint and per-direction**. An endpoint becomes default-deny **only in the directions for which at least one rule selects it**. `deathstar` is selected by a policy that has an `ingress:` section and no `egress:` section, so ingress flips to `Enabled` (default-deny + the listed allows) while **egress remains `Disabled`** — completely unrestricted, which is why the policy map shows the catch-all `Allow Egress → identity 0 (reserved:unknown) → ANY`. The other endpoints (`tiefighter`, `xwing`) are not selected at all and stay `Disabled` in both directions.

The minimal edit to make egress default-deny is to add an **empty egress section** to the same policy — its presence is what triggers enforcement in that direction:

```yaml
spec:
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
  egress: []          # <- selects the endpoint for egress; denies everything
```

In practice you would never ship `egress: []` bare — it breaks DNS. The production form allows CoreDNS explicitly:

```yaml
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
```

The equivalent idiom in a standard Kubernetes `NetworkPolicy` is `policyTypes: [Ingress, Egress]` with an empty `egress` list; `CiliumNetworkPolicy` infers the policy types from which sections are present.

</details>

---

## Official sources

- CCA curriculum — <https://github.com/cncf/curriculum/blob/master/cca/README.md>
- Cilium introduction & component overview — <https://docs.cilium.io/en/stable/overview/intro/> · <https://docs.cilium.io/en/stable/overview/component-overview/>
- Terminology: endpoints, identity, labels — <https://docs.cilium.io/en/stable/gettingstarted/terminology/>
- Installation with kind — <https://docs.cilium.io/en/stable/installation/kind/>
- IPAM concepts and modes — <https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Routing modes (encapsulation / native) — <https://docs.cilium.io/en/stable/network/concepts/routing/>
- eBPF datapath internals — <https://docs.cilium.io/en/stable/reference-guides/bpf/>
- kube-proxy replacement — <https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Network policy reference (CNP, L3/L4/L7) — <https://docs.cilium.io/en/stable/security/policy/>
- Hubble observability — <https://docs.cilium.io/en/stable/observability/hubble/>
- `cilium-dbg` command reference — <https://docs.cilium.io/en/stable/cmdref/cilium-dbg/>
- Troubleshooting guide — <https://docs.cilium.io/en/stable/operations/troubleshooting/>
- kind quick start — <https://kind.sigs.k8s.io/docs/user/quick-start/>