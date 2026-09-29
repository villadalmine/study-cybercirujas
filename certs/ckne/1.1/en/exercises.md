# 1.1 Installing and Configuring CNI Plugins: Guided Exercises

## Lab environment

These exercises assume:

- A **single-node** kubeadm cluster, Kubernetes v1.32 or later, on Ubuntu 22.04/24.04 with containerd 1.7 or 2.x. You need a single node for exercises 4–6 because a hand-written `host-local` configuration has no cross-node routing. Exercise 7 works on multiple nodes.
- The cluster was initialized with **no CNI installed** and a pod CIDR that matches Flannel's default:

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
mkdir -p $HOME/.kube && sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

- The kubeadm kernel prerequisites are in place: `br_netfilter` and `overlay` are loaded, and `net.bridge.bridge-nf-call-iptables=1` and `net.ipv4.ip_forward=1` are set.
- The tools `jq`, `iproute2`, `iptables` and `crictl` are installed.

Reference sources:

- CNI specification: https://github.com/containernetworking/cni/blob/main/SPEC.md
- Reference plugins: https://www.cni.dev/plugins/current/ and https://github.com/containernetworking/plugins
- Kubernetes network plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- containerd CRI configuration: https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- kubeadm cluster creation: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- Flannel: https://github.com/flannel-io/flannel
- CKNE exam page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/

---

## Exercise 1: See how a node looks with no CNI

1. Check the node status and the reason for it:

```bash
kubectl get nodes -o wide
kubectl describe node $(hostname) | grep -A2 -i "Ready "
```

Expected output (trimmed):

```
NAME     STATUS     ROLES           AGE   VERSION
cp-1     NotReady   control-plane   3m    v1.34.1

  Ready            False   ...   KubeletNotReady   container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

2. Ask the runtime directly, through CRI:

```bash
sudo crictl info | jq '.status.conditions'
```

```
[
  { "type": "RuntimeReady", "status": true, "reason": "", "message": "" },
  { "type": "NetworkReady", "status": false, "reason": "NetworkPluginNotReady",
    "message": "Network plugin returns error: cni plugin not initialized" }
]
```

3. Find out where containerd looks for CNI binaries and configuration:

```bash
sudo containerd config dump | grep -A8 -E "\.cni\]"
ls -l /etc/cni/net.d/ /opt/cni/bin/ 2>&1
kubectl -n kube-system get pods -o wide
```

On containerd 2.x the section is `[plugins.'io.containerd.cri.v1.runtime'.cni]`. On 1.7 it is `[plugins."io.containerd.grpc.v1.cri".cni]`. Look for `bin_dir` (or `bin_dirs` on 2.1+), `conf_dir` and `max_conf_num`.

**Questions**

- **Q1.1** Which component reports `NetworkReady=false`: the kubelet or the container runtime? Which component actually runs the CNI plugins?
- **Q1.2** The CoreDNS pods are `Pending`, but `kube-apiserver`, `etcd` and `kube-proxy` are `Running`. Why?
- **Q1.3** What does `max_conf_num = 1` mean for a directory that holds several configuration files?

---

## Exercise 2: Install and verify the reference plugins

1. See whether a package already installed plugins. On pkgs.k8s.io, the `kubelet` package depends on `kubernetes-cni`.

```bash
ls /opt/cni/bin/ 2>/dev/null && /opt/cni/bin/bridge 2>&1 | head -2
```

2. Download a specific release, check its checksum, and install it:

```bash
CNI_PLUGINS_VERSION="v1.6.2"
ARCH="amd64"
BASE="https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}"
TGZ="cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz"
cd /tmp
curl -fsSLO "${BASE}/${TGZ}"
curl -fsSLO "${BASE}/${TGZ}.sha256"
sha256sum -c "${TGZ}.sha256"
sudo mkdir -p /opt/cni/bin
sudo tar -xzf "${TGZ}" -C /opt/cni/bin
ls /opt/cni/bin
```

Expected output:

```
cni-plugins-linux-amd64-v1.6.2.tgz: OK
bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan  LICENSE  loopback  macvlan  portmap  ptp  README.md  sbr  static  tap  tuning  vlan  vrf
```

3. Ask a plugin for its version and supported spec versions. First run it with no `CNI_COMMAND`, then use the `VERSION` verb from the spec:

```bash
/opt/cni/bin/bridge
echo '{"cniVersion":"1.0.0"}' | CNI_COMMAND=VERSION /opt/cni/bin/bridge | jq
```

```
CNI bridge plugin v1.6.2
CNI protocol versions supported: 0.1.0, 0.2.0, 0.3.0, 0.3.1, 0.4.0, 1.0.0, 1.1.0

{
  "cniVersion": "1.0.0",
  "supportedVersions": ["0.1.0", "0.2.0", "0.3.0", "0.3.1", "0.4.0", "1.0.0", "1.1.0"]
}
```

4. Check the node again with `kubectl get nodes`.

**Questions**

- **Q2.1** The node is still `NotReady` even though the binaries are installed. What is missing?
- **Q2.2** Is it safe to overwrite `/opt/cni/bin` with a newer release while pods are running? Explain your answer using how plugins are executed.
- **Q2.3** Sort the listed binaries into three groups: *main/interface* plugins, *IPAM* plugins and *meta/chained* plugins.

---

## Exercise 3: Run a plugin by hand, with no Kubernetes

A CNI plugin is just an executable. It reads its configuration from stdin, takes its parameters from `CNI_*` environment variables, and writes a result to stdout. Here you play the role of the runtime.

1. Create a network namespace and a single-plugin configuration:

```bash
sudo ip netns add ckne-a
cat <<'EOF' > /tmp/lab-bridge.json
{
  "cniVersion": "1.0.0",
  "name": "lab-net",
  "type": "bridge",
  "bridge": "cni-lab0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "ranges": [[{ "subnet": "10.99.0.0/24" }]],
    "routes": [{ "dst": "0.0.0.0/0" }],
    "dataDir": "/tmp/cni-lab-ipam"
  }
}
EOF
```

2. Run `ADD`:

```bash
sudo CNI_COMMAND=ADD CNI_CONTAINERID=ckne-a CNI_NETNS=/var/run/netns/ckne-a \
     CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin \
     /opt/cni/bin/bridge < /tmp/lab-bridge.json | jq
```

Expected output (MACs and the veth name will differ):

```
{
  "cniVersion": "1.0.0",
  "interfaces": [
    { "name": "cni-lab0", "mac": "4a:..." },
    { "name": "veth3f1c2a9b", "mac": "a2:..." },
    { "name": "eth0", "mac": "6e:...", "sandbox": "/var/run/netns/ckne-a" }
  ],
  "ips": [
    { "interface": 2, "address": "10.99.0.2/24", "gateway": "10.99.0.1" }
  ],
  "routes": [ { "dst": "0.0.0.0/0" } ],
  "dns": {}
}
```

3. Look at what the plugin changed on the host and inside the namespace:

```bash
ip -br addr show cni-lab0
bridge link show | grep cni-lab0
sudo ip netns exec ckne-a ip -br addr
sudo ip netns exec ckne-a ip route
sudo ip netns exec ckne-a ping -c1 10.99.0.1
sudo ls /tmp/cni-lab-ipam/lab-net/
sudo cat /tmp/cni-lab-ipam/lab-net/10.99.0.2; echo
sudo iptables -t nat -S POSTROUTING | grep -i cni
```

```
cni-lab0         UP             10.99.0.1/24 ...
eth0@if12        UP             10.99.0.2/24 ...
default via 10.99.0.1 dev eth0
10.99.0.0/24 dev eth0 proto kernel scope link src 10.99.0.2
10.99.0.2  last_reserved_ip.0  lock
ckne-a
eth0
-A POSTROUTING -s 10.99.0.2/32 -m comment --comment "name: \"lab-net\" id: \"ckne-a\"" -j CNI-...
```

4. Run `ADD` again with a different container ID and namespace (`ckne-b`), then ping between the two namespaces:

```bash
sudo ip netns add ckne-b
sudo CNI_COMMAND=ADD CNI_CONTAINERID=ckne-b CNI_NETNS=/var/run/netns/ckne-b \
     CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin \
     /opt/cni/bin/bridge < /tmp/lab-bridge.json | jq -r '.ips[0].address'
sudo ip netns exec ckne-a ping -c1 10.99.0.3
```

5. Tear everything down with `DEL`. Leave the namespaces in place until `DEL` has finished.

```bash
for id in ckne-a ckne-b; do
  sudo CNI_COMMAND=DEL CNI_CONTAINERID=$id CNI_NETNS=/var/run/netns/$id \
       CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge < /tmp/lab-bridge.json
done
sudo ls /tmp/cni-lab-ipam/lab-net/
sudo iptables -t nat -S POSTROUTING | grep -c lab-net
sudo ip netns del ckne-a; sudo ip netns del ckne-b
sudo ip link del cni-lab0
```

**Questions**

- **Q3.1** The `bridge` plugin never allocated an IP itself. How did it find and call `host-local`?
- **Q3.2** Why does the result list three interfaces, and why does only one of them have `sandbox` set?
- **Q3.3** What happens to IPAM state if a runtime crashes and never calls `DEL`? How would you see that on this node?
- **Q3.4** After `DEL`, the bridge `cni-lab0` was still there. Why doesn't `DEL` remove it?

---

## Exercise 4: Make the node Ready with a hand-written `.conflist`

1. Read the pod CIDR that kube-controller-manager assigned to this node:

```bash
POD_CIDR=$(kubectl get node $(hostname) -o jsonpath='{.spec.podCIDR}'); echo $POD_CIDR
```

```
10.244.0.0/24
```

2. Write a network *list* configuration into the runtime's `conf_dir`:

```bash
sudo tee /etc/cni/net.d/10-ckne-bridge.conflist >/dev/null <<EOF
{
  "cniVersion": "1.0.0",
  "name": "ckne-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "ckne0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{ "subnet": "${POD_CIDR}" }]],
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true }
    }
  ]
}
EOF
jq . /etc/cni/net.d/10-ckne-bridge.conflist >/dev/null && echo "valid JSON"
```

3. Wait a few seconds. Do not restart anything yet.

```bash
sudo crictl info | jq '.status.conditions[] | select(.type=="NetworkReady")'
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

```
{ "type": "NetworkReady", "status": true, "reason": "", "message": "" }
NAME   STATUS   ROLES           AGE   VERSION
cp-1   Ready    control-plane   20m   v1.34.1
coredns-...   1/1   Running   0   20m   10.244.0.2   cp-1
coredns-...   1/1   Running   0   20m   10.244.0.3   cp-1
```

4. Start a workload and test Pod-to-Pod and Service connectivity:

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=2
kubectl expose deployment web --port=80
kubectl rollout status deployment/web
kubectl run client --image=busybox:1.36 --restart=Never --rm -it -- wget -qO- -T3 http://web | head -4
sudo ls /var/lib/cni/networks/ckne-bridge/
```

**Questions**

- **Q4.1** Neither the kubelet nor containerd was restarted, yet the node became `Ready`. What noticed the new file?
- **Q4.2** Why must `subnet` match `.spec.podCIDR` and not some arbitrary range? What would break if they differed, even on a single node?
- **Q4.3** What would happen with this exact configuration on a second node, and what does a real CNI add to fix it?
- **Q4.4** Where is the IPAM state stored now, and why is it different from Exercise 3?

---

## Exercise 5: Chaining: `portmap` and `bandwidth`

1. Create a pod that uses `hostPort`. `portmap` handles it, not kube-proxy.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hostport-demo
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
          hostPort: 8080
          protocol: TCP
```

```bash
kubectl apply -f hostport-demo.yaml && kubectl wait --for=condition=Ready pod/hostport-demo
NODE_IP=$(kubectl get node $(hostname) -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl -sI http://${NODE_IP}:8080 | head -1
sudo iptables -t nat -S CNI-HOSTPORT-DNAT
```

```
HTTP/1.1 200 OK
-N CNI-HOSTPORT-DNAT
-A CNI-HOSTPORT-DNAT -p tcp -m comment --comment "dnat name: \"ckne-bridge\" id: \"...\"" -m multiport --dports 8080 -j CNI-DN-...
```

2. Add `bandwidth` to the chain by appending a third element to `plugins`:

```bash
sudo jq '.plugins += [{"type": "bandwidth", "capabilities": {"bandwidth": true}}]' \
  /etc/cni/net.d/10-ckne-bridge.conflist | sudo tee /tmp/new.conflist >/dev/null
sudo mv /tmp/new.conflist /etc/cni/net.d/10-ckne-bridge.conflist
jq '.plugins[].type' /etc/cni/net.d/10-ckne-bridge.conflist
```

3. Create a rate-limited pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: shaped
  annotations:
    kubernetes.io/ingress-bandwidth: "10M"
    kubernetes.io/egress-bandwidth: "10M"
spec:
  containers:
    - name: nginx
      image: nginx:1.27
```

```bash
kubectl apply -f shaped.yaml && kubectl wait --for=condition=Ready pod/shaped
SHAPED_IP=$(kubectl get pod shaped -o jsonpath='{.status.podIP}')
VETH=$(ip -o route get ${SHAPED_IP} | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
echo $VETH
tc qdisc show dev $VETH
```

```
qdisc tbf 1: root refcnt 2 rate 10Mbit burst ... lat ...
```

4. Check `web`, the deployment created before the change:

```bash
for p in $(kubectl get pod -l app=web -o name); do
  IP=$(kubectl get $p -o jsonpath='{.status.podIP}')
  DEV=$(ip -o route get $IP | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  echo "$p $IP $DEV"
done
ip -br link show master ckne0
```

**Questions**

- **Q5.1** In a `.conflist`, what does each plugin after the first receive that the first one does not?
- **Q5.2** What does `"capabilities": {"portMappings": true}` do? Who fills in the actual port data?
- **Q5.3** The `shaped` pod's `route get` returns the bridge `ckne0` instead of a veth, so `tc` on it means little. How would you find the host-side veth of a specific pod reliably? (Hint: use the pod's `eth0` peer ifindex.)
- **Q5.4** Did the change to the conflist affect the `web` pods? What would you need to do to apply it to them?

---

## Exercise 6: Configuration precedence and a broken plugin

1. Add a second configuration whose file name sorts *earlier*. It contains a typo in the plugin type.

```bash
sudo tee /etc/cni/net.d/05-typo.conflist >/dev/null <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "typo-net",
  "plugins": [
    {
      "type": "brdge",
      "bridge": "typo0",
      "ipam": { "type": "host-local", "ranges": [[{ "subnet": "10.98.0.0/24" }]] }
    }
  ]
}
EOF
ls /etc/cni/net.d/
```

2. Check the node, then create a new pod:

```bash
kubectl get nodes
kubectl run victim --image=nginx:1.27
sleep 10
kubectl get pod victim
kubectl describe pod victim | sed -n '/Events/,$p'
```

Expected output (message shape; the ID is truncated):

```
cp-1   Ready   control-plane ...
victim   0/1   ContainerCreating   0   10s
  Warning  FailedCreatePodSandBox  ...  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "3c9a...": plugin type="brdge" name="typo-net" failed (add): failed to find plugin "brdge" in path [/opt/cni/bin]
```

3. Confirm that pods which already existed are unaffected:

```bash
kubectl run client --image=busybox:1.36 --restart=Never --rm -it -- true 2>&1 | tail -1
kubectl get pod -l app=web -o wide
curl -sI http://$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}') | head -1
```

4. Find the evidence on the node side as well:

```bash
sudo journalctl -u containerd --since "5 min ago" | grep -i "failed to find plugin" | tail -2
sudo crictl pods --name victim
```

5. Fix it and watch the pod recover without deleting it:

```bash
sudo rm /etc/cni/net.d/05-typo.conflist
kubectl wait --for=condition=Ready pod/victim --timeout=60s
kubectl get pod victim -o wide
kubectl delete pod victim hostport-demo shaped
```

**Questions**

- **Q6.1** Why did `05-typo.conflist` win over `10-ckne-bridge.conflist`? Which file extensions does the runtime consider?
- **Q6.2** Why did the node stay `Ready` even though every new pod failed? Which check would have caught the problem?
- **Q6.3** The `client` pod also failed to start. Why did the existing `web` pods keep working?
- **Q6.4** Why did `victim` recover on its own after the file was removed?

---

## Exercise 7: Replace the hand-written configuration with Flannel

1. Remove your configuration and the resources it created. Replace the running pods so they don't keep IPs from the old network.

```bash
kubectl delete deployment web; kubectl delete svc web
sudo rm /etc/cni/net.d/10-ckne-bridge.conflist
sudo ip link del ckne0
sudo rm -rf /var/lib/cni/networks/ckne-bridge
ls /etc/cni/net.d/
```

2. Install Flannel and check that its network matches the cluster's pod CIDR:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl -n kube-flannel rollout status ds/kube-flannel-ds
kubectl -n kube-flannel get cm kube-flannel-cfg -o jsonpath='{.data.net-conf\.json}'; echo
kubectl -n kube-system get pod kube-controller-manager-$(hostname) -o yaml | grep cluster-cidr
```

```
{
  "Network": "10.244.0.0/16",
  "EnableNFTables": false,
  "Backend": {
    "Type": "vxlan"
  }
}
    - --cluster-cidr=10.244.0.0/16
```

3. See what the DaemonSet installed on the node:

```bash
ls -l /opt/cni/bin/flannel
cat /etc/cni/net.d/10-flannel.conflist
cat /run/flannel/subnet.env
ip -d link show flannel.1 | grep -o "vxlan id [0-9]* .*dstport [0-9]*"
```

```
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    { "type": "flannel", "delegate": { "hairpinMode": true, "isDefaultGateway": true } },
    { "type": "portmap", "capabilities": { "portMappings": true } }
  ]
}
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
vxlan id 1 local 192.168.1.10 dev ens3 srcport 0 0 dstport 8472
```

4. Recreate CoreDNS and test again:

```bash
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment coredns
kubectl create deployment web --image=nginx:1.27 --replicas=2 && kubectl expose deployment web --port=80
kubectl rollout status deployment/web
kubectl run client --image=busybox:1.36 --restart=Never --rm -it -- wget -qO- -T3 http://web.default.svc.cluster.local | head -4
kubectl run mtu --image=busybox:1.36 --restart=Never --rm -it -- ip link show eth0
```

5. Optional, on multiple nodes: join a worker and confirm it gets its own `/24` and a route through `flannel.1`:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
ip route | grep flannel.1
```

**Questions**

- **Q7.1** Why was it essential to delete `10-ckne-bridge.conflist` before installing Flannel, and not only for tidiness?
- **Q7.2** Flannel's DaemonSet copies only the `flannel` binary. Which other binaries does its conflist need at runtime, and where do they come from?
- **Q7.3** Why is `FLANNEL_MTU` 1450, and what symptom would you see if pods used 1500 over VXLAN?
- **Q7.4** What happens if `--pod-network-cidr` at `kubeadm init` differs from `Network` in `net-conf.json`?
- **Q7.5** Which host firewall port must be open between nodes for this backend?

---

## Cleanup

```bash
kubectl delete deployment web; kubectl delete svc web
rm -f /tmp/lab-bridge.json /tmp/cni-*.tgz* hostport-demo.yaml shaped.yaml
sudo rm -rf /tmp/cni-lab-ipam
```

---

## Answers

<details>
<summary>Exercise 1</summary>

**Q1.1** The container runtime (containerd or CRI-O) reports it. The kubelet reads the `NetworkReady` condition through the CRI `Status` call and copies it into the node's `Ready` condition. The runtime also executes the plugins: during `RunPodSandbox` it creates the pod's network namespace and calls the CNI plugins through libcni. The kubelet never runs CNI binaries itself; dockershim was the last place that did, and it was removed in v1.24.

**Q1.2** Those pods are static pods (`kube-apiserver`, `etcd`) or DaemonSet pods (`kube-proxy`) that use `hostNetwork: true`. They share the node's network namespace, so they need no CNI. The node controller also taints a `NotReady` node with `node.kubernetes.io/not-ready`. CoreDNS has no toleration for that taint and needs a pod network, so it stays `Pending`.

**Q1.3** The runtime loads only the first configuration file in lexical order from `conf_dir`. Any other files are ignored completely; the runtime does not merge them. (With `max_conf_num > 1`, containerd attaches extra networks, but Kubernetes only reports the IP of the first one.)
</details>

<details>
<summary>Exercise 2</summary>

**Q2.1** A network configuration in `/etc/cni/net.d`. Binaries only give you capability. The runtime reports `NetworkReady=true` only after it loads a valid configuration, which tells it which plugins to call and with what parameters.

**Q2.2** Yes, in general. CNI plugins are not daemons: the runtime executes the binary once per `ADD`/`DEL`/`CHECK`/`GC` and the process exits. Running pods do not depend on the binary. They depend on the kernel state it left behind (veth, bridge, routes, iptables rules). Replace the files atomically (extract to a temp directory, then `mv`) so a pod created mid-copy does not execute a half-written file. Also check the release notes for changes to state formats, such as the `host-local` data directory or iptables/nftables chain names.

**Q2.3**
- Main/interface plugins create or move the interface: `bridge`, `ipvlan`, `macvlan`, `ptp`, `host-device`, `vlan`, `tap`, `dummy`, `loopback`.
- IPAM plugins: `host-local`, `dhcp`, `static`.
- Meta/chained plugins change the result of an earlier plugin: `portmap`, `bandwidth`, `tuning`, `firewall`, `sbr`, `vrf`.
</details>

<details>
<summary>Exercise 3</summary>

**Q3.1** The `bridge` plugin reads `ipam.type` from its configuration and runs the binary with that name. It looks for it in the directories listed in `CNI_PATH`, passing the same stdin config and environment. `host-local` returns the IP result, and `bridge` applies it to `eth0`. If `CNI_PATH` is missing or wrong, `ADD` fails with `failed to find plugin "host-local"`.

**Q3.2** The result lists every interface the plugin created or touched, in this order: the host bridge `cni-lab0`, the host end of the veth, and the container end `eth0`. The `sandbox` field names the network namespace an interface lives in. It is empty for interfaces in the host namespace. `ips[].interface: 2` is an index into this array, which ties the IP to `eth0`.

**Q3.3** The IP stays reserved. `host-local` keeps one file per IP, named after the address and containing the container ID and ifname, under `<dataDir>/<network name>/`. A missing `DEL` leaks that file, and a busy node can eventually run out of addresses (`no IP addresses available in range set`). To detect it, compare the files with the sandboxes that actually exist (`crictl pods -q`). Runtimes that support spec v1.1 can call `GC` with the list of valid attachments so the plugin can remove stale ones.

**Q3.4** The bridge is shared by every attachment on that network. `DEL` undoes only the per-container work: the veth, the IPAM reservation and that container's NAT rule. The plugin cannot know whether other containers still use the bridge, so it leaves it in place.
</details>

<details>
<summary>Exercise 4</summary>

**Q4.1** The CRI plugin in containerd watches `conf_dir` (with fsnotify) and reloads the configuration when files change. The next CRI `Status` call returns `NetworkReady=true`, and the kubelet updates the node condition on its next status sync. CRI-O works the same way.

**Q4.2** Many components assume pod IPs fall inside the node's `podCIDR` and the cluster CIDR. kube-proxy uses `--cluster-cidr` to decide which traffic to masquerade. Other nodes and cloud routes send traffic for this `podCIDR` to this node. Some CNIs and NetworkPolicy engines reason in terms of the node's range. On a single node a mismatch might appear to work, but the source NAT decisions and any external routing would be wrong.

**Q4.3** The second node would use its own `.spec.podCIDR` (for example `10.244.1.0/24`) only if you wrote that value into its file. Even then, node A has no route to `10.244.1.0/24`, so Pod-to-Pod traffic across nodes fails. A real CNI adds the cross-node data plane: overlay tunnels (VXLAN/Geneve), routes it programs itself (Flannel host-gw, Calico BGP), or eBPF routing. It also adds automatic per-node configuration, usually from a DaemonSet.

**Q4.4** The default `host-local` data directory: `/var/lib/cni/networks/ckne-bridge/`. Exercise 3 set `dataDir` explicitly to `/tmp/cni-lab-ipam`. The subdirectory is always named after the network `name`, not after the file.
</details>

<details>
<summary>Exercise 5</summary>

**Q5.1** `prevResult`: the runtime injects the result of the previous plugin into each later plugin's configuration. Chained plugins read it to find the interfaces and IPs to work on, for example the container IP that `portmap` uses as its DNAT target. The runtime also injects the list-level `name` and `cniVersion` into every element.

**Q5.2** It declares that the plugin wants the `portMappings` runtime capability. The runtime (containerd/CRI-O) builds the real data from the pod spec's `hostPort` entries. It passes that data only to plugins that declare the capability, in `runtimeConfig.portMappings`. `bandwidth` works the same way: the runtime reads the `kubernetes.io/*-bandwidth` annotations and passes them as `runtimeConfig.bandwidth`.

**Q5.3** The pod IP is reached through the bridge, so a route lookup returns `ckne0`, not a veth. A reliable method is:
`IDX=$(kubectl exec shaped -- cat /sys/class/net/eth0/iflink)` and then `ip -o link | grep "^${IDX}:"`.
This gives the host veth, and `tc qdisc show dev <that veth>` shows the `tbf` qdisc for pod ingress. Egress shaping goes through an `ifb` device that the plugin creates. Images without `cat` can use `crictl inspectp` or `nsenter` into the sandbox's network namespace instead.

**Q5.4** No. The runtime uses the configuration only for `ADD` and `DEL` when a sandbox is created or destroyed. Existing pods keep the setup they got at creation time. To apply the new chain, recreate them (`kubectl rollout restart deployment web`). Keep in mind that the runtime runs `DEL` with the *current* configuration. A plugin removed from the chain therefore never gets to clean up its rules for old pods.
</details>

<details>
<summary>Exercise 6</summary>

**Q6.1** containerd (through libcni) loads files ending in `.conf`, `.conflist` or `.json`, sorts them lexically, and uses the first one (`max_conf_num = 1`). `05-` sorts before `10-`. This is why CNIs use prefixes like `05-cilium.conflist` or `10-calico.conflist`, and why a leftover file from an earlier CNI can quietly take over.

**Q6.2** `NetworkReady` only checks that a configuration was *loaded and parsed*. The runtime does not check that the binaries it names exist until it runs `ADD`. To catch this, create a canary pod after every CNI change. You can also run libcni's validation (for example `cnitool check`, or a `CHECK` against a known sandbox), or check that each `type` exists in `bin_dir` (`jq -r '.plugins[].type' file | xargs -I{} test -x /opt/cni/bin/{}`).

**Q6.3** Network setup happens only when a sandbox is created. The `web` pods already had their network namespaces, veths, IPs and routes in the kernel, and none of that is re-evaluated when the configuration changes. Every *new* sandbox, including the short-lived `client` pod, runs `ADD` against the broken file.

**Q6.4** The kubelet keeps retrying `RunPodSandbox` with back-off. After the file was removed, containerd reloaded `10-ckne-bridge.conflist`, and the next retry succeeded. No manual action was needed.
</details>

<details>
<summary>Exercise 7</summary>

**Q7.1** `10-ckne-bridge.conflist` sorts before `10-flannel.conflist` (`c` < `f`). The runtime would have kept using the hand-written bridge. Flannel's pods would run and `flannel.1` would exist, but no pod would ever be attached through it, and cross-node traffic would fail for no obvious reason. Leftover files, bridges and IPAM directories are the most common cause of broken CNI migrations.

**Q7.2** The `flannel` plugin delegates. It reads `/run/flannel/subnet.env` and runs `bridge` (bridge `cni0`) with `host-local` IPAM for the node's `/24`. Then `portmap` runs as the next element in the chain. The runtime also needs `loopback` for `lo` (containerd 2.x can set it up internally when `use_internal_loopback` is enabled). These binaries come from the containernetworking/plugins reference release. It is usually installed by the `kubernetes-cni` package, or by hand as in Exercise 2. Without them, pods fail with `failed to find plugin "bridge"`.

**Q7.3** VXLAN adds 50 bytes of encapsulation over IPv4: outer Ethernet 14 + IPv4 20 + UDP 8 + VXLAN 8. So 1500 − 50 = 1450. With 1500 inside the pod, small packets such as pings, DNS and TCP handshakes work, but full-size packets get dropped or fragmented once encapsulated. Typical symptoms are TLS handshakes or large HTTP responses that hang between nodes, while the same traffic works within one node.

**Q7.4** kube-controller-manager assigns node `podCIDR`s from `--cluster-cidr`. Flannel (with `kube-subnet-mgr`) expects those ranges to fall inside its `Network`. If they don't, `kube-flannel` fails to start with an error about the subnet not being within the configured network, or pod IPs fall outside what kube-proxy treats as cluster traffic. To fix it, make both values match: edit `net-conf.json` in the ConfigMap and restart the DaemonSet. If node CIDRs are already allocated, re-create the nodes with the right `--cluster-cidr`.

**Q7.5** UDP 8472, the Linux kernel's VXLAN default that Flannel uses (not IANA's 4789). It must be open between all nodes, in both directions.
</details>