# Guided Exercises — CKNE 1.2: Managing IPAM and Pod CIDR Allocation

## Lab prerequisites

| Tool | Purpose | Check |
|---|---|---|
| Docker or Podman | Runs the kind node containers | `docker info` |
| `kind` v0.24+ | Local multi-node clusters | `kind version` |
| `kubectl` matching the node image | API client | `kubectl version --client` |
| `helm` v3 | Cilium install (Exercise 7) | `helm version` |

The node image must be Kubernetes **1.33 or later** for the `ServiceCIDR` exercise (the API is `networking.k8s.io/v1` from 1.33). Current kind releases already ship such an image.

Reference documentation used throughout:

- CKNE certification page — https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cluster networking model — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- `kube-controller-manager` flags — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- Node API (`spec.podCIDR`, `spec.podCIDRs`) — https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/node-v1/
- IPv4/IPv6 dual-stack — https://kubernetes.io/docs/concepts/services-networking/dual-stack/
- Service ClusterIP allocation — https://kubernetes.io/docs/concepts/services-networking/cluster-ip-allocation/
- Extend Service IP ranges — https://kubernetes.io/docs/tasks/network/extend-service-ip-ranges/
- CNI `host-local` IPAM — https://www.cni.dev/plugins/current/ipam/host-local/
- kind configuration — https://kind.sigs.k8s.io/docs/user/configuration/
- Cilium cluster-pool IPAM — https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/
- Cilium Kubernetes host-scope IPAM — https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/
- Calico block size — https://docs.tigera.io/calico/latest/networking/ipam/change-block-size

**The mental model these exercises build.** IPAM in Kubernetes has three layers, and each has its own owner:

1. **Cluster range.** A large pod prefix, e.g. `10.244.0.0/16`. It comes from `--cluster-cidr`, or from the CNI's own pool.
2. **Per-node range.** One slice of that prefix per node, e.g. `10.244.3.0/24`. It is written to `node.spec.podCIDRs` by the `nodeipam` controller in `kube-controller-manager`, or kept in a CNI-specific object.
3. **Per-pod address.** One IP from the node's slice. The CNI IPAM plugin (`host-local`, Cilium, Calico, …) hands it out when the sandbox is created.

Most IPAM incidents come down to one question: **which layer ran out, and who owns it?**

---

## Exercise 1 — Baseline: where the pod range is configured and how it is sliced

### Steps

1. Create the cluster configuration file `ipam-lab.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ipam-lab
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
- role: worker
- role: worker
```

2. Create the cluster:

```bash
kind create cluster --config ipam-lab.yaml
kubectl cluster-info --context kind-ipam-lab
```

3. Look at the IPAM flags that kubeadm passed to `kube-controller-manager`:

```bash
kubectl -n kube-system get pod kube-controller-manager-ipam-lab-control-plane \
  -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -E 'cidr|allocate'
```

Expected output (the order may vary):

```
"--allocate-node-cidrs=true"
"--cluster-cidr=10.244.0.0/16"
"--service-cluster-ip-range=10.96.0.0/16"
```

4. Look at the per-node slices the controller wrote:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR,PODCIDRS:.spec.podCIDRs
```

Expected output (which node gets which `/24` depends on the order they registered):

```
NAME                     PODCIDR         PODCIDRS
ipam-lab-control-plane   10.244.0.0/24   [10.244.0.0/24]
ipam-lab-worker          10.244.1.0/24   [10.244.1.0/24]
ipam-lab-worker2         10.244.2.0/24   [10.244.2.0/24]
```

5. Check the kubelet pod ceiling on one node:

```bash
kubectl get node ipam-lab-worker -o jsonpath='{.status.capacity.pods}{"\n"}'
```

Expected output:

```
110
```

6. Try to change a node's `podCIDR` after it has been allocated:

```bash
kubectl patch node ipam-lab-worker --type merge -p '{"spec":{"podCIDR":"10.244.99.0/24","podCIDRs":["10.244.99.0/24"]}}'
```

Expected result: the API server rejects the update with a validation error. The error says that node updates may not change `podCIDR` except from empty to a valid value.

### Questions

1.1. `--node-cidr-mask-size` is not in the output of step 3. What mask did the controller use, and where does that value come from?

1.2. With `--cluster-cidr=10.244.0.0/16` and a `/24` per node, what is the maximum number of nodes that can receive a pod CIDR?

1.3. A `/24` holds 256 addresses, and the kubelet reports `pods: 110`. Which of the two limits the number of pods on a node in this cluster, and why do the defaults leave that gap on purpose?

1.4. Step 6 fails. How do you move a node to a different pod CIDR, then?

1.5. What does `--allocate-node-cidrs=true` do, and what happens to `spec.podCIDRs` if it is `false`?

---

## Exercise 2 — Node-level IPAM: from `podCIDR` to a pod IP

### Steps

1. Start a few pods and see where they land:

```bash
kubectl create deployment web --image=registry.k8s.io/pause:3.10 --replicas=6
kubectl rollout status deployment/web
kubectl get pods -l app=web -o wide
```

2. For every pod, check that its IP falls inside `spec.podCIDR` of the node it runs on (see Exercise 1, step 4).

3. Open the CNI configuration that the container runtime reads on a worker:

```bash
docker exec ipam-lab-worker ls -l /etc/cni/net.d/
docker exec ipam-lab-worker sh -c 'cat /etc/cni/net.d/*.conflist'
```

Find the `"ipam"` object and note its `"type"`. Also note the subnet or range it lists, if it lists one.

4. If the IPAM type is `host-local`, list its on-disk state. The directory name is the `"name"` field of the conflist:

```bash
docker exec ipam-lab-worker sh -c 'ls /var/lib/cni/networks/*/'
docker exec ipam-lab-worker sh -c 'for f in /var/lib/cni/networks/*/10.*; do echo "$f -> $(head -1 "$f")"; done'
```

`host-local` writes one file per allocated IP, named after the IP, whose first line is the container ID. It also writes a `last_reserved_ip.0` file for each range.

If your CNI uses a different IPAM type, find where it keeps its state instead. Look for a database file or a directory under `/var/lib/`.

5. Find out how the range in the conflist got onto the node. Look at the environment and arguments of the node-level CNI daemon:

```bash
kubectl -n kube-system get ds -o name
kubectl -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n'
```

### Questions

2.1. Which component actually picks the IP for a new pod: `kube-controller-manager`, the kubelet, the container runtime, or the CNI IPAM plugin?

2.2. In `host-local`, what decides which addresses in the node's `/24` can never be handed to a pod?

2.3. The daemon in step 5 wrote the node's range into the CNI config. What input did it have to read to do that, and what breaks if that input is empty?

2.4. A node reboots and its IPAM state files survive, but the pods are gone. What leak can this cause with `host-local`, and what mechanism normally cleans it up?

---

## Exercise 3 — Exhausting the cluster range

This exercise builds a deliberately tight cluster: a `/27` pod range cut into `/28` per-node slices. That makes only **two** node slices, for **three** nodes.

### Steps

1. Create `ipam-tight.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ipam-tight
networking:
  podSubnet: "10.244.0.0/27"
kubeadmConfigPatches:
- |
  kind: ClusterConfiguration
  controllerManager:
    extraArgs:
    - name: node-cidr-mask-size
      value: "28"
nodes:
- role: control-plane
- role: worker
- role: worker
```

> The list form of `extraArgs` (`name`/`value`) belongs to kubeadm's `v1beta4` config, which kind generates for recent Kubernetes versions. If `kind create cluster` fails while parsing the kubeadm config, your kind/node image pair uses `v1beta3`. In that case use the map form instead: `extraArgs:` followed by `node-cidr-mask-size: "28"`.

2. Create the cluster and confirm that the flag was applied:

```bash
kind create cluster --config ipam-tight.yaml
docker exec ipam-tight-control-plane grep -E 'cluster-cidr|node-cidr-mask' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
```

Expected output:

```
    - --cluster-cidr=10.244.0.0/27
    - --node-cidr-mask-size=28
```

3. Look at node allocation and readiness:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.podCIDRs,READY:.status.conditions[-1].status
kubectl get nodes
```

One node has `<none>` as its `PODCIDRS` and stays `NotReady`. Write down its name. The rest of this guide calls it `<starved-node>`.

4. Find the evidence in three places:

```bash
kubectl get events -A --field-selector reason=CIDRNotAvailable
kubectl -n kube-system logs kube-controller-manager-ipam-tight-control-plane | grep -i 'cidr' | tail -5
kubectl describe node <starved-node> | grep -A2 -i 'NetworkReady\|Ready '
```

Expected output, approximately:

```
NAMESPACE   LAST SEEN   TYPE     REASON             OBJECT                     MESSAGE
default     30s         Normal   CIDRNotAvailable   node/ipam-tight-worker2    Node ipam-tight-worker2 status is now: CIDRNotAvailable
```

- The controller log should contain `there are no remaining CIDRs left to allocate in the accepted range`.
- The node description should show `NetworkPluginNotReady` / `cni plugin not initialized`.

5. Check the taint on the starved node:

```bash
kubectl get node <starved-node> -o jsonpath='{.spec.taints}{"\n"}'
```

### Questions

3.1. Work out the slice count from the masks: how many `/28` slices fit in a `/27`?

3.2. The starved node is `NotReady`, but nothing ever tried to give its pods an IP. Trace the chain of cause and effect from "no `podCIDR`" to "`NotReady`".

3.3. Why do new pods not get stuck on the starved node, even though it joined the cluster?

3.4. Was the cluster range really used up by addresses, or by something else? How many pod IPs are actually in use on the node that received `10.244.0.0/28`?

---

## Exercise 4 — Exhausting a node's own range

Stay on `ipam-tight`. Only one worker has a pod CIDR, and it has room for very few pods.

### Steps

1. Count the pods that already hold a pod IP on the ready worker. Skip `hostNetwork` pods, since they use the node's IP:

```bash
READY_WORKER=$(kubectl get nodes -o jsonpath='{range .items[?(@.spec.podCIDR)]}{.metadata.name}{"\n"}{end}' | grep worker)
echo "$READY_WORKER"
kubectl get pods -A -o wide --field-selector spec.nodeName="$READY_WORKER"
```

2. Oversubscribe it:

```bash
kubectl create deployment filler --image=registry.k8s.io/pause:3.10 --replicas=20
sleep 30
kubectl get pods -l app=filler -o wide | awk 'NR==1 || /ContainerCreating|Running/' | sort -k3
```

3. Count the pods that are `Running` and the pods stuck in `ContainerCreating`:

```bash
kubectl get pods -l app=filler --no-headers | awk '{print $3}' | sort | uniq -c
```

4. Read the failure on a stuck pod:

```bash
STUCK=$(kubectl get pods -l app=filler --no-headers | awk '/ContainerCreating/{print $1; exit}')
kubectl describe pod "$STUCK" | sed -n '/Events:/,$p'
```

Expected result: `FailedCreatePodSandBox` events keep repeating, and their message comes from the CNI IPAM plugin. With `host-local` it looks like this:

```
failed to allocate for range 0: no IP addresses available in range set: 10.244.0.18-10.244.0.30
```

5. Confirm that the scheduler still sees plenty of room:

```bash
kubectl describe node "$READY_WORKER" | sed -n '/Allocated resources/,/Events/p'
kubectl get node "$READY_WORKER" -o jsonpath='{.status.allocatable.pods}{"\n"}'
```

### Questions

4.1. With `host-local` defaults, how many pod IPs can a `/28` actually hand out? Show the subtraction.

4.2. Why did the scheduler put 20 pods on a node that can only address about a dozen?

4.3. How does this failure look different from Exercise 3 — in the pod status, in the node status, and in *where* the error message comes from?

4.4. What single kubelet setting keeps IP capacity and scheduling capacity consistent, and what value would you give it here?

---

## Exercise 5 — Recovering: widening the cluster range online

### Steps

1. Widen `--cluster-cidr` from `/27` to `/26`. The new range contains the old one, so every existing allocation stays valid:

```bash
docker exec ipam-tight-control-plane sed -i \
  's#--cluster-cidr=10.244.0.0/27#--cluster-cidr=10.244.0.0/26#' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
```

2. Wait for the static pod to restart, then look at the nodes again:

```bash
kubectl -n kube-system wait --for=condition=Ready pod/kube-controller-manager-ipam-tight-control-plane --timeout=120s
sleep 20
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.podCIDRs
kubectl get nodes
```

Expected result: `<starved-node>` receives `10.244.0.32/28` and turns `Ready`.

3. Look at the pods stuck on the first worker:

```bash
kubectl get pods -l app=filler -o wide | grep ContainerCreating
```

4. Scale up and see where the new replicas go:

```bash
kubectl scale deployment filler --replicas=30
sleep 20
kubectl get pods -l app=filler -o wide --no-headers | awk '{print $3, $7}' | sort | uniq -c
```

5. Find every other copy of the old cluster range:

```bash
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -i podSubnet
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -i clusterCIDR
kubectl -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 POD_SUBNET
```

### Questions

5.1. Why was widening from `/27` to `/26` safe here, while changing to `10.250.0.0/16` would not be?

5.2. The pods stuck in step 3 did not move to the node that now has room. Why not, and how do you get them running?

5.3. List every place from step 5 that still says `/27`. For each one, say what goes wrong if you leave it.

5.4. Could you have fixed the starved node by lowering `--node-cidr-mask-size` from 28 to 29 instead? What would happen to the two nodes that already have `/28` slices?

---

## Exercise 6 — Dual-stack allocation

### Steps

1. Create `ipam-dual.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ipam-dual
networking:
  ipFamily: dual
  podSubnet: "10.244.0.0/16,fd00:10:244::/56"
  serviceSubnet: "10.96.0.0/16,fd00:10:96::/112"
nodes:
- role: control-plane
- role: worker
```

2. Create the cluster and look at the allocation:

```bash
kind create cluster --config ipam-dual.yaml
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR,PODCIDRS:.spec.podCIDRs
kubectl -n kube-system get pod kube-controller-manager-ipam-dual-control-plane \
  -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -E 'cidr'
```

Expected output, approximately:

```
NAME                      PODCIDR         PODCIDRS
ipam-dual-control-plane   10.244.0.0/24   [10.244.0.0/24 fd00:10:244::/64]
ipam-dual-worker          10.244.1.0/24   [10.244.1.0/24 fd00:10:244:1::/64]
```

3. Check pod IPs across both families:

```bash
kubectl run dual --image=registry.k8s.io/pause:3.10
kubectl wait --for=condition=Ready pod/dual --timeout=60s
kubectl get pod dual -o jsonpath='{.status.podIPs}{"\n"}'
```

4. Create a dual-stack Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: dual-svc
spec:
  ipFamilyPolicy: PreferDualStack
  ipFamilies:
  - IPv4
  - IPv6
  selector:
    run: dual
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f dual-svc.yaml
kubectl get svc dual-svc -o jsonpath='{.spec.clusterIPs}{"\n"}'
```

### Questions

6.1. Which flags set the per-node mask for each family, and what are their defaults?

6.2. With a `/56` IPv6 cluster range and a `/64` per node, how many nodes can get an IPv6 slice? Which family runs out first in this cluster?

6.3. `spec.podCIDR` (singular) still exists. Which element of `spec.podCIDRs` does it mirror?

6.4. Can you change an existing single-stack IPv4 cluster to dual-stack by adding an IPv6 range to `--cluster-cidr`? What happens to nodes that already exist?

---

## Exercise 7 — CNI-owned IPAM: Cilium cluster-pool

This exercise shows that `node.spec.podCIDRs` is only the source of truth when the CNI chooses to use it.

### Steps

1. Create `ipam-cilium.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ipam-cilium
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
nodes:
- role: control-plane
- role: worker
- role: worker
```

2. Create the cluster and install Cilium with its own pool. The pool deliberately uses a different prefix from `podSubnet`:

```bash
kind create cluster --config ipam-cilium.yaml
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.200.0.0/22}' \
  --set ipam.operator.clusterPoolIPv4MaskSize=24
kubectl -n kube-system rollout status ds/cilium --timeout=300s
```

3. Compare the two sources of per-node ranges:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,K8S_PODCIDRS:.spec.podCIDRs
kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,CILIUM_PODCIDRS:.spec.ipam.podCIDRs
```

Expected output, approximately:

```
NAME                        K8S_PODCIDRS
ipam-cilium-control-plane   [10.244.0.0/24]
ipam-cilium-worker          [10.244.1.0/24]
ipam-cilium-worker2         [10.244.2.0/24]

NAME                        CILIUM_PODCIDRS
ipam-cilium-control-plane   [10.200.0.0/24]
ipam-cilium-worker          [10.200.2.0/24]
ipam-cilium-worker2         [10.200.1.0/24]
```

4. Start pods and check which range their IPs come from:

```bash
kubectl create deployment web --image=registry.k8s.io/pause:3.10 --replicas=6
kubectl rollout status deployment/web
kubectl get pods -l app=web -o wide
```

5. Ask the agent on one node how much of its slice is in use:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --all-addresses | sed -n '/IPAM/,/^[A-Z]/p'
```

Expected result: a line similar to `IPv4: 4/254 allocated from 10.200.x.0/24`, followed by the allocated addresses and their owners.

6. The `/22` pool holds four `/24` slices, and three are already taken. Add a worker to use up the fourth:

```bash
docker run -d --name tmp 2>/dev/null; true   # no-op placeholder removed below
docker rm -f tmp >/dev/null 2>&1
kind get nodes --name ipam-cilium
```

kind cannot add a node to an existing cluster. Instead, run the arithmetic in question 7.3, then **extend** the pool as Cilium supports it: append a CIDR, never change or remove an existing one.

```bash
helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.200.0.0/22,10.210.0.0/22}'
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout status deployment/cilium-operator
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.cluster-pool-ipv4-cidr}{"\n"}'
```

### Questions

7.1. The pods have `10.200.x.x` addresses, yet `kube-controller-manager` still gave every node a `10.244.x.0/24`. Which component allocated the pod IPs? Is anything harmful about the `10.244` slices in `node.spec.podCIDRs`?

7.2. What would you change so that Cilium uses `node.spec.podCIDRs`, and what is that IPAM mode called?

7.3. The pool `10.200.0.0/22` with `clusterPoolIPv4MaskSize=24` fits how many nodes? What happens to the fourth-plus-one node's Cilium agent?

7.4. Why does Cilium let you append CIDRs to `clusterPoolIPv4PodCIDRList` but forbid changing the mask size or removing an entry?

---

## Exercise 8 — Calico block sizing (design exercise, no cluster needed)

Calico does not hand whole-node slices to nodes. It hands out **blocks** (`blockSize`, a `/26` by default for IPv4). Each block is affine to one node, and a node claims more blocks as it needs them.

Study this pool:

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool-a
spec:
  cidr: 10.48.0.0/20
  blockSize: 26
  ipipMode: Never
  vxlanMode: CrossSubnet
  natOutgoing: true
  nodeSelector: all()
```

### Steps

1. Work out how many blocks the pool holds, and how many addresses are in each block.
2. The fleet is 50 nodes, each running up to 110 pods. Work out how many blocks one full node needs, and how many the whole fleet needs.
3. Draft the migration for moving to a larger pool, `10.64.0.0/16` with `blockSize: 26`, without an outage.

The migration begins with this new pool:

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool-b
spec:
  cidr: 10.64.0.0/16
  blockSize: 26
  ipipMode: Never
  vxlanMode: CrossSubnet
  natOutgoing: true
  nodeSelector: all()
```

### Questions

8.1. How many blocks and addresses does `pool-a` provide, and is it enough for the fleet in step 2?

8.2. When every block is claimed but one node still has free addresses in its own blocks, what can a node that is out of addresses do? What does that cost in routing?

8.3. Why can't you simply edit `blockSize` on `pool-a`? List the migration steps after creating `pool-b`.

8.4. Compare a `blockSize` of 29 with a `blockSize` of 24 for this fleet: what do you gain and what do you pay with each?

---

## Exercise 9 — Service IP ranges: `ServiceCIDR` and `IPAddress`

Go back to the first cluster: `kubectl config use-context kind-ipam-lab`.

### Steps

1. List the Service ranges and the addresses allocated from them:

```bash
kubectl get servicecidrs
kubectl get ipaddresses
```

Expected output, approximately:

```
NAME         CIDRS          AGE
kubernetes   10.96.0.0/16   25m

NAME         PARENTREF
10.96.0.1    services/default/kubernetes
10.96.0.10   services/kube-system/kube-dns
```

2. Add a second Service range:

```yaml
apiVersion: networking.k8s.io/v1
kind: ServiceCIDR
metadata:
  name: extra-range
spec:
  cidrs:
  - 10.97.0.0/24
```

```bash
kubectl apply -f extra-range.yaml
kubectl get servicecidr extra-range -o jsonpath='{.status.conditions}{"\n"}'
```

3. Create a Service with an address from the new range:

```bash
kubectl create service clusterip in-extra --tcp=80:80 --clusterip=10.97.0.10
kubectl get svc in-extra
kubectl get ipaddress 10.97.0.10 -o yaml | grep -A6 parentRef
```

4. Try to delete the range while the Service still uses it:

```bash
kubectl delete servicecidr extra-range --wait=false
kubectl get servicecidr extra-range -o jsonpath='{.metadata.finalizers}{"\n"}{.status.conditions}{"\n"}'
```

5. Free the address and watch the range disappear:

```bash
kubectl delete svc in-extra
sleep 5
kubectl get servicecidrs
```

### Questions

9.1. Pod IPs and Service IPs are allocated by different mechanisms. Who allocates each one, and where does the allocator keep its state?

9.2. What does the `ServiceCIDR` object stuck in `Terminating` in step 4 protect you from?

9.3. The API server does not reject a `ServiceCIDR` that overlaps the pod range, e.g. `10.244.200.0/24`. Why is that still a misconfiguration, and what symptom would you see?

9.4. Before the `ServiceCIDR` API, how did you grow a full Service range, and why was it disruptive?

---

## Cleanup

```bash
kind delete cluster --name ipam-lab
kind delete cluster --name ipam-tight
kind delete cluster --name ipam-dual
kind delete cluster --name ipam-cilium
```

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1.1.** The controller used the built-in default: `/24` for IPv4 (`--node-cidr-mask-size-ipv4`) and `/64` for IPv6 (`--node-cidr-mask-size-ipv6`). kubeadm only passes the flag when you set it in `ClusterConfiguration.controllerManager.extraArgs`. The defaults are listed in the `kube-controller-manager` reference.

**1.2.** 2^(24 − 16) = **256 nodes**. Node 257 registers but gets no pod CIDR (Exercise 3 shows exactly this).

**1.3.** The **kubelet's `maxPods` (110)** is the binding limit. `host-local` could hand out about 253 addresses from a `/24`. The gap is deliberate: pods churn, an address is only released after the sandbox is torn down, and a rolling update briefly doubles the pods on a node. Having about twice as many addresses as pods keeps the IP range from being the bottleneck. GKE documents the same ratio (110 pods → `/24`).

**1.4.** `spec.podCIDR(s)` can only be set once, from empty to a value. To change it:
- drain the node and delete the Node object;
- clean up the CNI state on the host;
- restart the kubelet so the node registers again and is allocated a fresh slice.

In practice most teams replace the node instead.

**1.5.** It turns on the `nodeipam` controller's allocator, which fills `spec.podCIDRs` from `--cluster-cidr`. With `false`, nodes get no `podCIDR`. That is correct when the CNI owns IPAM (Calico, or Cilium cluster-pool) or a cloud controller assigns ranges, and wrong for CNIs that read `podCIDR` (kindnet, flannel, Cilium `kubernetes` mode).

### Exercise 2

**2.1.** The **CNI IPAM plugin**. The kubelet asks the runtime (via CRI) to create a sandbox, and the runtime calls the CNI plugin with `ADD`. The main plugin (e.g. `ptp` or `bridge`) delegates the address choice to the IPAM plugin. `kube-controller-manager` only decides the node-wide slice.

**2.2.** The range configuration:
- the network address, and the gateway (`.1` by default), are never handed out;
- `rangeStart` defaults to the address after the network address, and the gateway is skipped;
- `rangeEnd` defaults to the address before broadcast.

This is covered in the `host-local` documentation. Any `rangeStart`/`rangeEnd` in the conflist narrows it further.

**2.3.** It reads `node.spec.podCIDRs` of its own Node object from the API. If that field is empty, it cannot write a valid config. The CNI config stays missing, the runtime reports `NetworkReady=false`, and the node stays `NotReady`. Exercise 3 reproduces this.

**2.4.** A **leaked reservation**: an IP file whose container no longer exists stays reserved, which slowly shrinks the node's usable range. Two things normally clean it up:
- the runtime calls CNI `DEL` when it tears down a sandbox;
- after an unclean reboot, CNI `GC` (CNI spec 1.1, where the runtime supports it) or the runtime's sandbox cleanup does it.

Many distributions also put `/var/lib/cni` on tmpfs, or wipe it at boot. Otherwise the fix is to delete the orphan files by hand after checking the container ID against `crictl pods`.

### Exercise 3

**3.1.** 2^(28 − 27) = **2** slices: `10.244.0.0/28` and `10.244.0.16/28`. Three nodes compete for them.

**3.2.** The chain runs like this:
1. The `nodeipam` controller cannot allocate (`CIDRNotAvailable` event, and "no remaining CIDRs" in its log).
2. `spec.podCIDRs` stays empty.
3. The node's CNI daemon cannot render its config.
4. No file appears in `/etc/cni/net.d`.
5. The container runtime reports the network plugin as not initialized.
6. The kubelet sets `Ready=False`.

**3.3.** The node lifecycle controller adds the `node.kubernetes.io/not-ready:NoSchedule` taint (and `NoExecute`). The scheduler does not place ordinary pods on it. DaemonSet pods tolerate the taint, but they are usually `hostNetwork` and need no pod IP.

**3.4.** It was used up by **slices**, not addresses. Each node claims a whole `/28` however few pods it runs. The node with `10.244.0.0/28` typically runs only CoreDNS and local-path-provisioner (2–3 IPs), while a whole other node sits idle. Oversized per-node masks combined with an undersized cluster range is the classic way to hit a node cap long before running out of addresses.

### Exercise 4

**4.1.** 16 addresses − network (`.16`) − broadcast (`.31`) − gateway (`.17`) = **13** pod IPs. Subtract any non-`hostNetwork` pods already on the node. If your CNI uses a different IPAM implementation, repeat the arithmetic with the range shown in its config.

**4.2.** The scheduler does not know about IP addresses. It checks `allocatable.pods` (110), CPU, memory and so on. Nothing in the default scheduler links pod count to how big the node's CIDR is.

**4.3.**
- **Pods:** here they are bound to the node and stuck in `ContainerCreating`, with `FailedCreatePodSandBox` events. In Exercise 3 the pods were fine and a *node* was `NotReady`.
- **Node:** here it stays `Ready`.
- **Where the error comes from:** here the CNI plugin reports it through the runtime, on the pod. In Exercise 3 `kube-controller-manager` reported it, on the node.

**4.4.** Set kubelet `maxPods` (`KubeletConfiguration.maxPods`, or `--max-pods`) to no more than the usable addresses: **13** or lower here. Then the scheduler refuses to overcommit, and pods stay `Pending` with a clear `Too many pods` reason instead of failing inside the runtime.

### Exercise 5

**5.1.** `10.244.0.0/26` is a superset of `/27`. When the allocator restarts, it marks every existing node slice as used, and all of them are still inside the range, so it only adds free space. Switching to an unrelated `10.250.0.0/16` leaves existing slices outside the range:
- the allocator logs errors for them;
- routing and masquerade rules in kube-proxy and the CNI no longer match the pods that are running;
- the existing nodes still cannot be given new slices, because `podCIDR` is immutable.

**5.2.** Those pods are already **bound** to the full node. The scheduler never looks at a bound pod again, and the kubelet just keeps retrying sandbox creation. Delete them (`kubectl delete pod …`, or `kubectl rollout restart deployment/filler`), so the ReplicaSet creates new pods that the scheduler can place on the node with free addresses.

**5.3.**
- **`kubeadm-config` `podSubnet`:** the next `kubeadm upgrade` regenerates the static pod manifest and **reverts** the controller to `/27`. Update the ConfigMap as well.
- **kube-proxy `clusterCIDR`:** kube-proxy uses it to decide which traffic to masquerade. Pods from `10.244.0.32/28` count as "outside the cluster", so their Service traffic may get SNATed, and NetworkPolicy/source-IP behavior changes.
- **kindnet `POD_SUBNET`:** its masquerade exclusion list. Pod-to-pod traffic to or from the new slice may be NATed.

Every component that keeps its own copy of the cluster CIDR has to be updated alongside the controller.

**5.4.** Lowering the mask only affects *new* allocations, so the starved node could get a `/29` (6 usable pod IPs). The two existing `/28` slices are immutable and stay as they are. Changing the mask while allocations are live gives you mixed-size nodes. It is valid for the range allocator, but it makes capacity planning harder. Widening the cluster range is the cleaner fix.

### Exercise 6

**6.1.** `--node-cidr-mask-size-ipv4` (default `24`) and `--node-cidr-mask-size-ipv6` (default `64`). The single-family `--node-cidr-mask-size` cannot be used in a dual-stack cluster.

**6.2.** 2^(64 − 56) = **256** IPv6 slices. IPv4 `/16` → `/24` also gives 256, so both families run out together. The controller needs **both** families to allocate a node, so the smaller of the two counts sets the node cap.

**6.3.** The first element, `podCIDRs[0]`, which is the primary family. It exists for clients that predate dual-stack.

**6.4.** You can add the second family (API server, controller manager, kubelet and kube-proxy flags, plus CNI support). But nodes that already exist keep a single-family `podCIDRs`, because the field only goes from empty to a value. The Kubernetes dual-stack docs say that existing nodes and pods do not become dual-stack. Nodes have to be recycled (drained, deleted and re-registered) to receive a second slice.

### Exercise 7

**7.1.** The **Cilium operator** carved `/24` slices out of `10.200.0.0/22` into each `CiliumNode`, and the **Cilium agent** handed out pod IPs from its node's slice. The `10.244` values come from `--allocate-node-cidrs=true` and have no effect on the data path. The harm is operational:
- they mislead anyone who debugs from `kubectl get nodes`;
- they can collide with real networks if someone later routes `10.244.0.0/16`;
- tools that read `podCIDR` (some monitoring, or kube-proxy's `--detect-local-mode=NodeCIDR`) get the wrong answer.

**7.2.** Install with `ipam.mode=kubernetes` ("Kubernetes host-scope" IPAM). The agent then reads `node.spec.podCIDRs`, which requires `--allocate-node-cidrs=true` in the controller manager.

**7.3.** 2^(24 − 22) = **4** nodes. A fifth node's `CiliumNode` gets no pod CIDR, its agent cannot allocate, and pods there fail to get IPs. The operator logs that the pool is exhausted. Appending `10.210.0.0/22` adds four more slices.

**7.4.** Slices that are already allocated are recorded in `CiliumNode` objects and are routed by the data path. Removing a CIDR, or changing the mask, would make those slices invalid or overlap new ones while pods still use them. Appending only adds new address space, and the operator can hand it out without touching existing slices. The Cilium cluster-pool docs call out this limitation.

### Exercise 8

**8.1.** A `/20` holds 4096 addresses. 2^(26 − 20) = **64** blocks of **64** addresses each. A full node needs ⌈110 / 64⌉ = 2 blocks, so the fleet needs up to 100 blocks. **The pool is not enough**: only 64 blocks exist, even though 4096 addresses exceed the 5500 needed only on paper.

**8.2.** With the default `strictAffinity: false`, the node **borrows** single addresses from blocks affine to other nodes. Each borrowed IP needs a `/32` route pointing at the borrowing node, so the aggregated block routes stop being enough, and routing tables and BGP updates grow. Setting `strictAffinity: true` forbids borrowing, and allocation fails instead.

**8.3.** Allocated blocks in `ipamblocks` are sized by the pool's `blockSize`, so changing it would invalidate every existing block. That is why the field cannot be changed once the pool exists. The Calico procedure is:
1. Create `pool-b`.
2. Set `disabled: true` on `pool-a`, so no new addresses come from it.
3. Recreate workloads (rolling restart) so they get addresses from `pool-b`.
4. Confirm with `calicoctl ipam show` that `pool-a` has no addresses left in use.
5. Delete `pool-a`.

**8.4.**
- **`/29` (8 IPs):** 512 blocks, so there is less stranded space on lightly loaded nodes. But a full node needs 14 blocks, which means more route entries per node and more IPAM API writes.
- **`/24` (256 IPs):** one block covers a full node and there are very few routes. But `pool-a` would only have 16 blocks — fewer than the 50 nodes — and every node strands most of its 256 addresses.

The default `/26` is the compromise between the two.

### Exercise 9

**9.1.**
- **Pod IPs:** the CNI IPAM on each node allocates them, from the node's slice. State is kept on the node (`host-local` files) or in CNI objects (`CiliumNode`, Calico `ipamblocks`).
- **ClusterIPs:** the **API server** allocates them when it creates the Service. With the `ServiceCIDR`/`IPAddress` model, each allocated ClusterIP is an `IPAddress` object in etcd, parented to its Service, and ranges are `ServiceCIDR` objects.

**9.2.** The finalizer (`networking.k8s.io/service-cidr-finalizer`) keeps the range from disappearing while an `IPAddress` in it still exists. Without it, a Service would keep a ClusterIP from a range the cluster no longer claims, and the address could later be handed out again for something else. The object is deleted once no other `ServiceCIDR` covers the address in use and the Service is gone.

**9.3.** The API server does not know the CNI's pod range. An overlapping ClusterIP gets captured by kube-proxy's Service rules (iptables/nftables/IPVS) on every node. A pod that happens to get the same address becomes unreachable at that IP, because traffic to it is DNATed to the Service backends instead. The result is intermittent, address-specific connection failures that are very hard to trace. Keep pod, Service and node ranges disjoint, and document them together.

**9.4.** You had to change `--service-cluster-ip-range` on **every** API server, to a range that contains the old one, restarting each in turn. If the flag was inconsistent between API servers during the rollout, allocation could conflict. Shrinking or moving the range meant recreating Services. The `ServiceCIDR` API makes growth an ordinary object you `kubectl apply`, with no restart.

</details>