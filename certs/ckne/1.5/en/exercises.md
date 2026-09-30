# CKNE 1.5 — Configuring Multi-interface Pods: Guided Exercises

> **Exam context.** The CKNE curriculum (version not yet published, see <https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/>) lists "Configuring Multi-interface Pods" at a weight of 3.0. Kubernetes does not support multiple interfaces natively. A pod gets exactly one network, the one set up by the cluster's primary CNI plugin. In practice, extra interfaces come from a *meta-plugin*, and the reference implementation is **Multus CNI**. Multus implements the Network Plumbing Working Group (NPWG) *Kubernetes Network Custom Resource Definition De-facto Standard*. These exercises build that setup step by step, from an empty cluster through to diagnosing a broken pod.

**Primary sources used throughout:**

- Multus CNI: <https://github.com/k8snetworkplumbingwg/multus-cni>
- Multus quickstart and how-to: <https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/quickstart.md>, <https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/how-to-use.md>
- Multus thick plugin: <https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/thick-plugin.md>
- NPWG specification: <https://github.com/k8snetworkplumbingwg/multi-net-spec>
- CNI reference plugins: <https://www.cni.dev/plugins/current/> (bridge, macvlan, host-local, static, tuning)
- Whereabouts IPAM: <https://github.com/k8snetworkplumbingwg/whereabouts>
- Kubernetes network plugins: <https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/>

---

## Lab prerequisites

- Linux host with Docker, `kind` ≥ 0.23, `kubectl`, and `curl`
- Internet access to pull the manifests and images
- About 4 GB of free RAM

The test image is `ghcr.io/nicolaka/netshoot:v0.13`. It includes `ip`, `ping`, `tcpdump` and `arping`.

---

## Exercise 1 — Build the lab and install Multus

### Steps

1. Create a kind cluster with one control plane and two workers:

   ```yaml
   # kind-multus.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: multus-lab
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   ```

   ```bash
   kind create cluster --config kind-multus.yaml
   kubectl get nodes
   ```

   Expected output (versions will vary):

   ```
   NAME                       STATUS   ROLES           AGE   VERSION
   multus-lab-control-plane   Ready    control-plane   60s   v1.33.1
   multus-lab-worker          Ready    <none>          40s   v1.33.1
   multus-lab-worker2         Ready    <none>          40s   v1.33.1
   ```

2. Check which CNI binaries the nodes already have:

   ```bash
   docker exec multus-lab-worker ls /opt/cni/bin
   ```

   ```
   host-local  loopback  portmap  ptp
   ```

   `bridge`, `macvlan`, `static` and `tuning` are missing. Multus only *delegates* to other plugins; it does not ship them. Install the reference plugins on every node:

   ```bash
   CNI_VER=v1.6.2
   curl -sSL -o /tmp/cni-plugins.tgz \
     "https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-amd64-${CNI_VER}.tgz"
   for n in $(kind get nodes --name multus-lab); do
     docker cp /tmp/cni-plugins.tgz "$n":/tmp/cni-plugins.tgz
     docker exec "$n" tar -xzf /tmp/cni-plugins.tgz -C /opt/cni/bin
   done
   docker exec multus-lab-worker ls /opt/cni/bin | tr '\n' ' '
   ```

   ```
   bandwidth bridge dhcp dummy firewall host-device host-local ipvlan loopback macvlan portmap ptp sbr static tap tuning vlan vrf
   ```

3. Record the primary CNI configuration **before** Multus is installed:

   ```bash
   docker exec multus-lab-worker ls /etc/cni/net.d
   ```

   ```
   10-kindnet.conflist
   ```

4. Install Multus in *thick* mode. It runs a server daemon in each node's DaemonSet pod plus a small shim binary. In production, pin a release tag instead of `master`.

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
   kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
   ```

   ```
   daemon set "kube-multus-ds" successfully rolled out
   ```

5. Inspect what Multus changed:

   ```bash
   kubectl get crd network-attachment-definitions.k8s.cni.cncf.io
   docker exec multus-lab-worker ls /etc/cni/net.d
   docker exec multus-lab-worker cat /etc/cni/net.d/00-multus.conf
   ```

   ```
   NAME                                             CREATED AT
   network-attachment-definitions.k8s.cni.cncf.io   2026-09-30T10:12:03Z

   00-multus.conf  10-kindnet.conflist  multus.d

   {"cniVersion":"0.3.1","logLevel":"verbose","logToStderr":true,"name":"multus-cni-network","clusterNetwork":"/host/etc/cni/net.d/10-kindnet.conflist","type":"multus-shim"}
   ```

### Check questions (Exercise 1)

1.1. The container runtime (containerd) reads `/etc/cni/net.d` and uses only **one** configuration file. Why does Multus name its file `00-multus.conf`?

1.2. What does the `clusterNetwork` key in `00-multus.conf` point to, and what role does that network play for every pod?

1.3. Multus is installed, but you had to install `bridge`/`macvlan` separately in step 2. What does that tell you about how Multus relates to the CNI plugins?

1.4. What is the practical difference between the *thin* and *thick* Multus deployments?

---

## Exercise 2 — A second interface on a node-local bridge

### Steps

1. Create a `NetworkAttachmentDefinition` (NAD) that uses the `bridge` plugin with `host-local` IPAM. `spec.config` is a **string** that contains a CNI configuration in JSON.

   ```yaml
   # nad-bridge.yaml
   apiVersion: k8s.cni.cncf.io/v1
   kind: NetworkAttachmentDefinition
   metadata:
     name: bridge-net
     namespace: default
   spec:
     config: |
       {
         "cniVersion": "0.4.0",
         "name": "bridge-net",
         "type": "bridge",
         "bridge": "br-lab",
         "isGateway": false,
         "ipam": {
           "type": "host-local",
           "subnet": "10.20.0.0/24",
           "rangeStart": "10.20.0.10",
           "rangeEnd": "10.20.0.50"
         }
       }
   ```

   ```bash
   kubectl apply -f nad-bridge.yaml
   kubectl get net-attach-def
   ```

   ```
   NAME         AGE
   bridge-net   3s
   ```

2. Start two pods on the **same** node, each attached to `bridge-net`:

   ```yaml
   # pods-bridge.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: br-a
     annotations:
       k8s.v1.cni.cncf.io/networks: bridge-net
   spec:
     nodeName: multus-lab-worker
     containers:
       - name: shell
         image: ghcr.io/nicolaka/netshoot:v0.13
         command: ["sleep", "infinity"]
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: br-b
     annotations:
       k8s.v1.cni.cncf.io/networks: bridge-net
   spec:
     nodeName: multus-lab-worker
     containers:
       - name: shell
         image: ghcr.io/nicolaka/netshoot:v0.13
         command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f pods-bridge.yaml
   kubectl wait --for=condition=Ready pod/br-a pod/br-b --timeout=120s
   ```

3. Look at the pod's interfaces:

   ```bash
   kubectl exec br-a -- ip -brief addr
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   eth0@if7         UP             10.244.1.5/24 fe80::...
   net1@if8         UP             10.20.0.10/24 fe80::...
   ```

4. Read the status annotation that Multus writes on the pod:

   ```bash
   kubectl get pod br-a -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'; echo
   ```

   ```
   [{
       "name": "kindnet",
       "interface": "eth0",
       "ips": ["10.244.1.5"],
       "mac": "a2:4e:...",
       "default": true,
       "dns": {},
       "gateway": ["10.244.1.1"]
   },{
       "name": "default/bridge-net",
       "interface": "net1",
       "ips": ["10.20.0.10"],
       "mac": "3e:91:...",
       "dns": {}
   }]
   ```

5. Test connectivity over `net1` and look at the bridge on the node:

   ```bash
   B_IP=$(kubectl exec br-b -- ip -4 -o addr show net1 | awk '{print $4}' | cut -d/ -f1)
   kubectl exec br-a -- ping -c 2 -I net1 "$B_IP"
   docker exec multus-lab-worker ip -brief link show master br-lab
   docker exec multus-lab-worker ls /var/lib/cni/networks/bridge-net/
   ```

   ```
   64 bytes from 10.20.0.11: icmp_seq=1 ttl=64 time=0.081 ms
   64 bytes from 10.20.0.11: icmp_seq=2 ttl=64 time=0.060 ms

   veth1a2b3c4d@if3   UP   ...
   veth5e6f7a8b@if3   UP   ...

   10.20.0.10  10.20.0.11  last_reserved_ip.0  lock
   ```

6. Now start a third pod on the **other** worker:

   ```bash
   sed -e 's/name: br-a/name: br-c/' -e 's/multus-lab-worker$/multus-lab-worker2/' pods-bridge.yaml \
     | awk 'BEGIN{RS="---"} NR==1' | kubectl apply -f -
   kubectl wait --for=condition=Ready pod/br-c --timeout=120s
   kubectl exec br-c -- ip -4 -brief addr show net1
   kubectl exec br-a -- ping -c 2 -W 1 -I net1 10.20.0.11 >/dev/null && echo same-node-ok
   kubectl exec br-c -- ping -c 2 -W 1 -I net1 10.20.0.11 || echo cross-node-FAILS
   ```

   ```
   net1@if4         UP             10.20.0.10/24
   same-node-ok
   ...
   2 packets transmitted, 0 received, 100% packet loss
   cross-node-FAILS
   ```

### Check questions (Exercise 2)

2.1. Which interface carries the pod's default route, Service traffic and kube-proxy/NetworkPolicy handling: `eth0` or `net1`? Why?

2.2. The NAD is named `bridge-net`, but `network-status` shows `default/bridge-net`. Why does Multus add the namespace?

2.3. `br-c` got `10.20.0.10`, **the same IP as `br-a`**. Explain the mechanism, using what you saw in `/var/lib/cni/networks/bridge-net/`.

2.4. Even if the IPs were unique, why is there no connectivity between `br-c` and `br-b`?

2.5. Who writes the `k8s.v1.cni.cncf.io/network-status` annotation, and why should you trust it more than `k8s.v1.cni.cncf.io/networks`?

---

## Exercise 3 — Cross-node L2 with macvlan and cluster-wide IPAM (Whereabouts)

### Steps

1. Install Whereabouts. It stores its allocations in CRDs, so it is consistent across the whole cluster.

   ```bash
   WA=https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds
   kubectl apply -f $WA/daemonset-install.yaml \
                 -f $WA/whereabouts.cni.cncf.io_ippools.yaml \
                 -f $WA/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml
   kubectl -n kube-system rollout status ds/whereabouts --timeout=120s
   ```

2. Create a macvlan NAD whose parent (`master`) is the node's `eth0`:

   ```yaml
   # nad-macvlan.yaml
   apiVersion: k8s.cni.cncf.io/v1
   kind: NetworkAttachmentDefinition
   metadata:
     name: macvlan-wa
     namespace: default
   spec:
     config: |
       {
         "cniVersion": "0.4.0",
         "name": "macvlan-wa",
         "type": "macvlan",
         "master": "eth0",
         "mode": "bridge",
         "ipam": {
           "type": "whereabouts",
           "range": "10.30.0.0/24",
           "range_start": "10.30.0.20",
           "range_end": "10.30.0.60"
         }
       }
   ```

3. Deploy two replicas and use anti-affinity to force them onto different nodes:

   ```yaml
   # deploy-macvlan.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: mv
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: mv
     template:
       metadata:
         labels:
           app: mv
         annotations:
           k8s.v1.cni.cncf.io/networks: macvlan-wa
       spec:
         affinity:
           podAntiAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               - labelSelector:
                   matchLabels:
                     app: mv
                 topologyKey: kubernetes.io/hostname
         containers:
           - name: shell
             image: ghcr.io/nicolaka/netshoot:v0.13
             command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f nad-macvlan.yaml -f deploy-macvlan.yaml
   kubectl rollout status deploy/mv
   kubectl get pods -l app=mv -o wide
   for p in $(kubectl get pods -l app=mv -o name); do
     kubectl exec "$p" -- ip -4 -brief addr show net1
   done
   ```

   ```
   NAME                  READY   STATUS    ...   NODE
   mv-6d7c9b8f5-4kq2x    1/1     Running   ...   multus-lab-worker
   mv-6d7c9b8f5-zt8wn    1/1     Running   ...   multus-lab-worker2

   net1@if2         UP             10.30.0.20/24
   net1@if2         UP             10.30.0.21/24
   ```

4. Test cross-node connectivity and look at the allocation state:

   ```bash
   P1=$(kubectl get pods -l app=mv -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$P1" -- ping -c 2 -I net1 10.30.0.21
   kubectl get ippools.whereabouts.cni.cncf.io -A
   kubectl get ippools.whereabouts.cni.cncf.io -n kube-system -o yaml | grep -A3 allocations
   ```

   ```
   64 bytes from 10.30.0.21: icmp_seq=1 ttl=64 time=0.21 ms

   NAMESPACE     NAME           AGE
   kube-system   10.30.0.0-24   40s
   ```

   macvlan children on kind's veth `eth0` reach each other across nodes because the Docker bridge forwards them like any other MACs. On bare metal, the physical switch plays that role, and port security or a MAC limit can block it.

5. Try to reach the node itself over the macvlan network. First give the node an address in that range:

   ```bash
   docker exec multus-lab-worker ip addr add 10.30.0.250/24 dev eth0
   kubectl exec "$P1" -- ping -c 2 -W 1 -I net1 10.30.0.250
   docker exec multus-lab-worker ip addr del 10.30.0.250/24 dev eth0
   ```

   Where `$P1` runs on `multus-lab-worker`, the result is `100% packet loss`.

### Check questions (Exercise 3)

3.1. Why did Whereabouts avoid the duplicate you saw with `host-local` in Exercise 2?

3.2. In step 5 the pod cannot ping its own node's `eth0`. What property of macvlan explains this, and what are two common ways to fix it?

3.3. The macvlan interface has its own MAC address. What problem can this cause in a cloud VPC (AWS/GCP/Azure), and which plugin is often used instead?

3.4. The pod's traffic on `net1` never goes through the node's netfilter stack in the usual way. What does that mean for Kubernetes NetworkPolicies and kube-proxy?

---

## Exercise 4 — Static IP, fixed MAC, custom interface name and routes

### Steps

1. Build a NAD from a **plugin chain** (`plugins` list). `macvlan` has `static` IPAM and accepts the `ips` capability; `tuning` accepts the `mac` capability.

   ```yaml
   # nad-static.yaml
   apiVersion: k8s.cni.cncf.io/v1
   kind: NetworkAttachmentDefinition
   metadata:
     name: macvlan-static
     namespace: default
   spec:
     config: |
       {
         "cniVersion": "0.4.0",
         "name": "macvlan-static",
         "plugins": [
           {
             "type": "macvlan",
             "master": "eth0",
             "mode": "bridge",
             "capabilities": { "ips": true },
             "ipam": {
               "type": "static",
               "routes": [ { "dst": "192.168.100.0/24", "gw": "10.40.0.1" } ]
             }
           },
           {
             "type": "tuning",
             "capabilities": { "mac": true },
             "sysctl": { "net.ipv4.conf.all.rp_filter": "0" }
           }
         ]
       }
   ```

2. Request the attachment with the **JSON form** of the annotation:

   ```yaml
   # pod-static.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: static-1
     annotations:
       k8s.v1.cni.cncf.io/networks: '[{"name": "macvlan-static", "interface": "storage0", "ips": ["10.40.0.10/24"], "mac": "02:00:00:40:00:10"}]'
   spec:
     containers:
       - name: shell
         image: ghcr.io/nicolaka/netshoot:v0.13
         command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f nad-static.yaml -f pod-static.yaml
   kubectl wait --for=condition=Ready pod/static-1 --timeout=120s
   kubectl exec static-1 -- ip -brief link show storage0
   kubectl exec static-1 -- ip -4 -brief addr show storage0
   kubectl exec static-1 -- ip route
   ```

   ```
   storage0@if2     UP             02:00:00:40:00:10 <BROADCAST,MULTICAST,UP,LOWER_UP>
   storage0@if2     UP             10.40.0.10/24
   default via 10.244.2.1 dev eth0
   10.40.0.0/24 dev storage0 proto kernel scope link src 10.40.0.10
   10.244.2.0/24 via 10.244.2.1 dev eth0 src 10.244.2.7
   192.168.100.0/24 via 10.40.0.1 dev storage0
   ```

3. Attach the **same network twice** to one pod, and use the `namespace/name` syntax:

   ```yaml
   # pod-dual.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dual-1
     annotations:
       k8s.v1.cni.cncf.io/networks: default/macvlan-wa@data0, default/macvlan-wa@data1
   spec:
     containers:
       - name: shell
         image: ghcr.io/nicolaka/netshoot:v0.13
         command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f pod-dual.yaml
   kubectl wait --for=condition=Ready pod/dual-1 --timeout=120s
   kubectl exec dual-1 -- ip -4 -brief addr | grep data
   ```

   ```
   data0@if2        UP             10.30.0.22/24
   data1@if2        UP             10.30.0.23/24
   ```

### Check questions (Exercise 4)

4.1. What happens if you ask for `"ips"` in the annotation but the NAD does not declare `"capabilities": { "ips": true }`?

4.2. Why is the MAC applied by the `tuning` plugin, and not directly by the annotation?

4.3. Where did the route to `192.168.100.0/24` come from, and why is the default route still on `eth0`? Which annotation field would move it?

4.4. In `dual-1`, what does `@data0` do, and what would Multus name the interfaces without it?

4.5. Why is `ips` in the annotation normally combined with `static` IPAM rather than `whereabouts` or `host-local`?

---

## Exercise 5 — Diagnosing broken attachments

### Steps

1. Reference a NAD that does not exist:

   ```yaml
   # pod-broken-1.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: broken-1
     annotations:
       k8s.v1.cni.cncf.io/networks: does-not-exist
   spec:
     containers:
       - name: shell
         image: ghcr.io/nicolaka/netshoot:v0.13
         command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f pod-broken-1.yaml
   sleep 15
   kubectl get pod broken-1
   kubectl describe pod broken-1 | sed -n '/Events/,$p'
   ```

   ```
   NAME       READY   STATUS              RESTARTS   AGE
   broken-1   0/1     ContainerCreating   0          15s

   Warning  FailedCreatePodSandBox  ...  Failed to create pod sandbox: rpc error: ...
   plugin type="multus-shim" name="multus-cni-network" failed (add): ... cannot find a network-attachment-definition
   (does-not-exist) in namespace (default): network-attachment-definitions.k8s.cni.cncf.io "does-not-exist" not found
   ```

2. Use a NAD from **another namespace** without qualifying its name:

   ```bash
   kubectl create namespace team-b
   kubectl run broken-2 -n team-b --image=ghcr.io/nicolaka/netshoot:v0.13 \
     --annotations=k8s.v1.cni.cncf.io/networks=bridge-net -- sleep infinity
   sleep 15
   kubectl -n team-b describe pod broken-2 | grep -m1 -A2 FailedCreatePodSandBox
   ```

   Fix it by recreating the pod with `k8s.v1.cni.cncf.io/networks=default/bridge-net`:

   ```bash
   kubectl -n team-b delete pod broken-2
   kubectl run fixed-2 -n team-b --image=ghcr.io/nicolaka/netshoot:v0.13 \
     --annotations=k8s.v1.cni.cncf.io/networks=default/bridge-net -- sleep infinity
   kubectl -n team-b wait --for=condition=Ready pod/fixed-2 --timeout=120s
   ```

3. Create a NAD whose `master` interface does not exist:

   ```yaml
   # nad-badmaster.yaml
   apiVersion: k8s.cni.cncf.io/v1
   kind: NetworkAttachmentDefinition
   metadata:
     name: bad-master
   spec:
     config: |
       {
         "cniVersion": "0.4.0",
         "name": "bad-master",
         "type": "macvlan",
         "master": "ens999",
         "mode": "bridge",
         "ipam": { "type": "host-local", "subnet": "10.50.0.0/24" }
       }
   ```

   ```bash
   kubectl apply -f nad-badmaster.yaml
   kubectl run broken-3 --image=ghcr.io/nicolaka/netshoot:v0.13 \
     --annotations=k8s.v1.cni.cncf.io/networks=bad-master -- sleep infinity
   sleep 15
   kubectl describe pod broken-3 | grep -m1 -o 'failed to lookup master.*'
   ```

   ```
   failed to lookup master "ens999": Link not found
   ```

4. Read the logs of the Multus daemon on the node that ran the pod:

   ```bash
   NODE=$(kubectl get pod broken-3 -o jsonpath='{.spec.nodeName}')
   MPOD=$(kubectl -n kube-system get pod -l app=multus --field-selector spec.nodeName=$NODE -o name)
   kubectl -n kube-system logs "$MPOD" --tail=30 | grep -i -E 'error|bad-master'
   ```

5. Change the NAD **after** a pod is already running, and see what happens:

   ```bash
   kubectl patch net-attach-def bridge-net --type=merge -p \
     '{"spec":{"config":"{\"cniVersion\":\"0.4.0\",\"name\":\"bridge-net\",\"type\":\"bridge\",\"bridge\":\"br-lab\",\"ipam\":{\"type\":\"host-local\",\"subnet\":\"10.21.0.0/24\"}}"}}'
   kubectl exec br-a -- ip -4 -brief addr show net1
   kubectl delete pod br-b && kubectl apply -f pods-bridge.yaml
   kubectl wait --for=condition=Ready pod/br-b --timeout=120s
   kubectl exec br-b -- ip -4 -brief addr show net1
   ```

   ```
   net1@if8         UP             10.20.0.10/24
   net1@if9         UP             10.21.0.2/24
   ```

6. Clean up:

   ```bash
   kind delete cluster --name multus-lab
   ```

### Check questions (Exercise 5)

5.1. Why do all three failures show up as `ContainerCreating` with `FailedCreatePodSandBox`, and not as `CrashLoopBackOff`?

5.2. When the annotation has no namespace, which namespace does Multus look up the NAD in? How would a cluster administrator publish shared networks for many teams?

5.3. List a troubleshooting order, from cheapest to most expensive, for a pod stuck in `ContainerCreating` that has a `networks` annotation.

5.4. After step 5, `br-a` and `br-b` are in different subnets on the same bridge. Why didn't changing the NAD reconfigure `br-a`? What does that mean for NAD changes in production?

5.5. If the Multus DaemonSet pod on a node is down, what happens to *new* pods on that node, including pods **without** the annotation?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1.** The runtime uses the first configuration file in lexical order in `/etc/cni/net.d`. With `00-` in front, Multus's file sorts before `10-kindnet.conflist`, so every pod is created through Multus. Multus then delegates to the real primary CNI. If Multus's file sorted later, it would never be called.

**1.2.** It points to the primary CNI's config (kindnet). That delegate is always run first and creates `eth0`, the "cluster default network". This network gives the pod its `status.podIP` and carries Services, DNS and NetworkPolicy. Extra networks are always *in addition to* this one.

**1.3.** Multus is a **meta-plugin**. It does not create interfaces itself. It reads NADs and calls other CNI binaries (`bridge`, `macvlan`, `ipvlan`, `sriov`, …) in order, following the CNI spec. Every binary named in a NAD must exist in `/opt/cni/bin` on **every** node where such a pod may land.

**1.4.** *Thin* is a single binary that the runtime runs for each CNI operation. It reads the API server with the kubeconfig on the node. *Thick* splits the work: a small `multus-shim` binary is run by the runtime and forwards the request over a Unix socket to a long-running daemon in the DaemonSet pod. The daemon keeps API watches and caches, exposes metrics, and scales better. The trade-off: if the daemon is down, no pod on that node gets a network (see 5.5).

### Exercise 2

**2.1.** `eth0`. Multus attaches the cluster default network first as `eth0`, and it keeps the default route. The pod's IP in `status.podIP`, Endpoints/EndpointSlices, kube-proxy and the primary CNI's NetworkPolicies all refer to that IP only. `net1` is outside the Kubernetes network model.

**2.2.** NADs are namespaced objects. The NPWG spec identifies each network as `<namespace>/<name>`, so two teams can have a `bridge-net` without ambiguity.

**2.3.** `host-local` stores its allocations as files on **each node's** local disk (`/var/lib/cni/networks/<network>/`). The node `multus-lab-worker2` knows nothing about the other node's files, so it hands out the first free address in the range again (`10.20.0.10`). `host-local` is only safe when each node gets a separate range, or when the network is node-local by design.

**2.4.** The `bridge` plugin creates a Linux bridge `br-lab` **on each node**, with no uplink. The two bridges are isolated L2 islands. Joining them would require enslaving a physical interface to the bridge, or a tunnel (VXLAN), and neither is configured.

**2.5.** Multus writes it after the delegates return (through the API server, so it needs RBAC to patch pods). It reflects what actually happened: real interface names, IPs, MACs and which network is the default. `networks` is only what the user *asked for*. It can be wrong or not yet applied.

### Exercise 3

**3.1.** Whereabouts keeps its allocations in the API server (the `IPPool` CRD, plus `OverlappingRangeIPReservation` to detect the same IP in overlapping ranges) and uses leader election/locks. Every node sees the same pool, so each address is unique across the cluster. It also reclaims addresses from deleted pods.

**3.2.** By design, macvlan children cannot talk to their own parent interface: the kernel does not deliver frames between the parent and its children. Common fixes: (a) create a macvlan interface on the host too (for example `ip link add mv-host link eth0 type macvlan mode bridge`) and put the host's IP on it; (b) use `ipvlan`, or `bridge` with an uplink, when the host must talk to the pods; (c) route the traffic through an external gateway.

**3.3.** Cloud VPCs normally deliver frames only to MAC/IP pairs the provider knows about. Unknown MACs are dropped, and source/destination checks drop unknown IPs. `ipvlan` (L2 or L3 mode) is often used instead because all children share the parent's MAC. Even then, the IPs must usually be registered as secondary IPs of the NIC.

**3.4.** Primary CNI NetworkPolicies and kube-proxy Service rules apply to the cluster network (`eth0`). On `net1` there are no Services, no kube-proxy load balancing, and no policy enforcement from the primary CNI. Filtering secondary networks needs separate tooling, such as `MultiNetworkPolicy` (k8snetworkplumbingwg/multi-networkpolicy) or hardware/network-side ACLs.

### Exercise 4

**4.1.** The `ips` field is passed to the plugin as a CNI `runtimeConfig` argument **only** for plugins that declare that capability. Without it, Multus does not deliver the request. The pod either gets an IP from whatever IPAM is configured, or it fails. With `static` IPAM and no addresses, the IPAM call fails and the pod stays in `ContainerCreating`.

**4.2.** Multus translates annotation fields into CNI capabilities (`mac` → `runtimeConfig.mac`), and a plugin in the chain has to act on them. `tuning` is the reference plugin that changes interface properties (MAC, MTU, sysctls, promiscuous mode) after the main plugin creates the interface. That is why it goes second in the `plugins` list.

**4.3.** From the `routes` list in the `static` IPAM section. IPAM returns them in its result, and the main plugin installs them in the pod. The default route stays on `eth0` because Multus keeps the cluster network as the default gateway. The `"default-route": ["<gw>"]` field in the JSON annotation asks Multus to move the default route to that attachment's gateway. Doing so breaks nothing inside Kubernetes itself, but it changes how the pod leaves the node, so use it with care.

**4.4.** It sets the interface name inside the pod (short form of `"interface"`). Without it, Multus names interfaces `net1`, `net2`, … in the order of the annotation. Explicit names give applications and monitoring stable names, for example `storage0` for iSCSI/NFS traffic.

**4.5.** The CNI plugin must honour the `ips` capability. `static` is built for that. `host-local` and `whereabouts` allocate from a pool and generally do not take a per-pod requested IP through this path. Mixing fixed IPs with a dynamic pool invites conflicts unless the static addresses are excluded from the pool's range (Whereabouts has `exclude` for that).

### Exercise 5

**5.1.** Pod networking is set up while the runtime creates the **sandbox** (pause container), before any application container starts. If the CNI ADD fails, kubelet reports `FailedCreatePodSandBox` and keeps retrying. The container never exists, so it cannot crash-loop. The diagnosis is in the pod's `Events`, not in `kubectl logs`.

**5.2.** In the **pod's** namespace. Two common patterns: (a) put shared NADs in one namespace (for example `default` or a dedicated `network-attachments` namespace), have teams reference them as `<ns>/<name>`, and restrict who can create NADs with RBAC; (b) have a controller or GitOps copy the NAD into each tenant namespace. Multus can also be started with `--namespace-isolation`, which forbids cross-namespace references except to globally allowed namespaces. Check it in production.

**5.3.** (1) `kubectl describe pod` → Events (the exact CNI error). (2) `kubectl get net-attach-def -n <ns>`: does it exist, and in which namespace? (3) Check `spec.config`: is the JSON valid, does the `type` binary exist in `/opt/cni/bin`, and does the `master` interface exist on that node? (4) Is the Multus DaemonSet pod on that node Running, and what do its logs say? (5) Check IPAM state (Whereabouts `IPPool`s, `host-local` files, pool exhaustion). (6) Only then use node-level tools (`crictl`, runtime logs, `ip link` on the node).

**5.4.** CNI runs only at sandbox **creation** (ADD) and deletion (DEL). Nothing watches a NAD to reconfigure running pods, and Multus does not re-run ADD. Existing pods keep the old configuration until they are recreated. In production, treat NAD changes as a rolling change: create a new NAD (versioned, for example `bridge-net-v2`), update the workload's annotation, and let the Deployment roll. Editing a NAD in place leaves the fleet inconsistent.

**5.5.** In thick mode, the runtime still calls `multus-shim` for **every** pod, because `00-multus.conf` is the active CNI config. With the daemon's socket unavailable, the shim fails and *all* new pods on that node get stuck in `ContainerCreating`, even pods without a `networks` annotation. Pods that are already running are not affected. This is why Multus DaemonSet health is critical to the node and needs monitoring and alerting like the primary CNI.

</details>