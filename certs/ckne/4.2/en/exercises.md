# 4.2 Implementing Node and Pod Level Encryption: Guided Exercises

**Exam weight:** 6.25%
**Goal:** encrypt pod-to-pod traffic between nodes and prove it on the wire. You encrypt node-to-node traffic with Cilium (WireGuard, then IPsec) and with Calico (WireGuard). Then you compare these with the workload-identity mTLS a service mesh provides (Istio ambient).

**Official references used throughout:**

- CKNE program: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cilium transparent encryption overview: https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium WireGuard: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium IPsec: https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Calico WireGuard: https://docs.tigera.io/calico/latest/network-policy/encrypt-cluster-pod-traffic
- Istio ambient mode: https://istio.io/latest/docs/ambient/overview/
- Istio PeerAuthentication: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- WireGuard protocol: https://www.wireguard.com/protocol/
- Node debugging with kubectl: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/

---

## Prerequisites

| Tool | Purpose |
|---|---|
| `kind` ≥ 0.23 | Multi-node local cluster (nodes are containers that share the host kernel) |
| `kubectl` ≥ 1.30 | Cluster access, `kubectl debug node/...` |
| `cilium` CLI | Install and upgrade Cilium through Helm |
| `istioctl` ≥ 1.24 | Exercise 5 only |
| `openssl` | Generate IPsec keys |
| Host kernel ≥ 5.6 | Built-in WireGuard module (`modinfo wireguard` must succeed) |

> kind nodes share the **host kernel**, so the WireGuard and XFRM (IPsec) modules must be available on your workstation. On Fedora, Ubuntu 22.04+ and Debian 12 they are available by default.

The lab doesn't install `tcpdump` on the nodes. Every capture runs from an ephemeral **node debug pod**, which shares the node's network namespace:

```
kubectl debug node/<node> -it --profile=sysadmin --image=nicolaka/netshoot -- <command>
```

---

## Exercise 1: Establish a plaintext baseline

You can't prove that encryption works until you have seen the same traffic unencrypted. In this exercise you capture an HTTP header in cleartext on the physical interface (`eth0`) of a node.

### Step 1.1: Create a 3-node cluster without a CNI

Save this as `kind-enc.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: enc
networking:
  disableDefaultCNI: true
nodes:
- role: control-plane
- role: worker
- role: worker
```

```bash
kind create cluster --config kind-enc.yaml
kubectl get nodes
```

Expected output (the nodes stay `NotReady` because there is no CNI yet):

```
NAME                STATUS     ROLES           AGE   VERSION
enc-control-plane   NotReady   control-plane   45s   v1.3x.x
enc-worker          NotReady   <none>          25s   v1.3x.x
enc-worker2         NotReady   <none>          25s   v1.3x.x
```

### Step 1.2: Install Cilium without encryption

```bash
cilium install
cilium status --wait
```

Confirm the routing mode and that encryption is off:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'Encryption|Routing'
```

```
Encryption:              Disabled
Routing:                 Network: Tunnel [vxlan]   Host: Legacy
```

> In production, pin the version with `cilium install --version <x.y.z>` and use the same version for every `cilium upgrade`.

### Step 1.3: Deploy a server and a client on different nodes

Save this as `workload.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: enc-demo
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  namespace: enc-demo
  labels:
    app: server
spec:
  nodeName: enc-worker
  containers:
  - name: nginx
    image: nginx:1.27
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: server
  namespace: enc-demo
spec:
  selector:
    app: server
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: enc-demo
spec:
  nodeName: enc-worker2
  containers:
  - name: netshoot
    image: nicolaka/netshoot:latest
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-local
  namespace: enc-demo
spec:
  nodeName: enc-worker
  containers:
  - name: netshoot
    image: nicolaka/netshoot:latest
    command: ["sleep", "infinity"]
```

```bash
kubectl apply -f workload.yaml
kubectl -n enc-demo wait --for=condition=Ready pod --all --timeout=120s
kubectl -n enc-demo get pods -o wide
```

```
NAME           READY   STATUS    RESTARTS   AGE   IP             NODE
client         1/1     Running   0          30s   10.0.2.41      enc-worker2
client-local   1/1     Running   0          30s   10.0.1.112     enc-worker
server         1/1     Running   0          30s   10.0.1.87      enc-worker
```

> `nodeName` bypasses the scheduler. It's used here only so the lab is deterministic. In real workloads, use affinity or anti-affinity instead.

### Step 1.4: Capture cleartext on the wire

**Terminal A:** capture on `enc-worker` (the server's node), on the physical interface, with no port filter:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  sh -c 'tcpdump -ni eth0 -l -A 2>/dev/null | grep --line-buffered "TOP-SECRET"'
```

**Terminal B:** generate cross-node traffic that carries a marker header:

```bash
for i in $(seq 1 5); do
  kubectl -n enc-demo exec client -- \
    curl -s -o /dev/null -w '%{http_code}\n' -H "X-Secret: TOP-SECRET-4242" http://server
  sleep 1
done
```

Terminal A shows:

```
X-Secret: TOP-SECRET-4242
X-Secret: TOP-SECRET-4242
...
```

Stop the capture with `Ctrl+C`. Then look at the traffic's outer envelope:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -ni eth0 -c 4 'udp port 8472'
```

Generate traffic again from Terminal B. Expected output:

```
IP 172.18.0.3.39812 > 172.18.0.2.8472: OTV, flags [I] (0x08), overlay 0, instance 41204
IP 10.0.2.41.51234 > 10.0.1.87.80: Flags [P.], seq 1:94, ack 1, win 502, length 93: HTTP: GET / HTTP/1.1
```

### Questions, block 1

1. The HTTP header was visible even though the traffic travels inside a VXLAN tunnel. What does VXLAN provide, and what doesn't it provide?
2. `tcpdump` decodes port 8472 as "OTV". Why, and what is that port in Cilium?
3. Why was the capture run on `eth0` of the node and not inside the `server` pod?

---

## Exercise 2: WireGuard transparent encryption with Cilium

### Step 2.1: Enable WireGuard

```bash
cilium upgrade --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

### Step 2.2: Inspect the encryption state

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption
```

```
Encryption:              Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: 3kY0Vd...Zq0=, Port: 51871, Peers: 2)]
```

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
```

```
Encryption: Wireguard
Interface: cilium_wg0
	Public key: 3kY0Vd...Zq0=
	Number of peers: 2
```

Look at the interface from the node:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  ip -d link show cilium_wg0
```

```
8: cilium_wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN mode DEFAULT group default
    link/none  promiscuity 0 allmulti 0 minmtu 0 maxmtu 2147483552
    wireguard ...
```

Look at how public keys are distributed:

```bash
kubectl get ciliumnodes -o custom-columns='NODE:.metadata.name,WG_PUBKEY:.metadata.annotations.network\.cilium\.io/wg-pub-key'
```

```
NODE                WG_PUBKEY
enc-control-plane   Hq2x...8Fk=
enc-worker          3kY0Vd...Zq0=
enc-worker2         pT7b...Mw4=
```

### Step 2.3: Repeat the capture

**Terminal A:** the same capture as in step 1.4:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  sh -c 'tcpdump -ni eth0 -l -A 2>/dev/null | grep --line-buffered "TOP-SECRET"'
```

**Terminal B:** run the same curl loop.

Expected result: **nothing appears** in Terminal A. Now look at the outer envelope:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -ni eth0 -c 6 'udp port 51871'
```

```
IP 172.18.0.3.51871 > 172.18.0.2.51871: UDP, length 176
IP 172.18.0.2.51871 > 172.18.0.3.51871: UDP, length 128
...
```

Then capture on the tunnel interface itself, **before** encryption:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  sh -c 'tcpdump -ni cilium_wg0 -l -A 2>/dev/null | grep --line-buffered "TOP-SECRET"'
```

This time the header **does** appear.

### Step 2.4: Same-node traffic

Keep the capture from step 2.3 on `cilium_wg0` running, and send the header from the pod on the same node:

```bash
kubectl -n enc-demo exec client-local -- \
  curl -s -o /dev/null -H "X-Secret: TOP-SECRET-4242" http://server
```

Now capture on the server pod's `lxc*` interface. Find the interface through the endpoint:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | grep server
```

> `ds/cilium` picks *any* agent. To inspect the endpoint on `enc-worker`, run the command on the agent for that node:
> `kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=enc-worker -o name`

### Step 2.5: MTU impact

```bash
kubectl -n enc-demo exec client -- ip link show eth0 | head -1
```

Compare the value with what you would expect from a 1500-byte Docker network.

### Step 2.6: Node-to-node encryption (host traffic)

```bash
cilium upgrade --reuse-values --set encryption.nodeEncryption=true
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait

for n in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  echo "== $n"
  kubectl -n kube-system exec "$n" -c cilium-agent -- cilium-dbg status | grep Encryption
done
```

```
== pod/cilium-4xk2p
Encryption:              Wireguard   [NodeEncryption: OptedOut, cilium_wg0 (Pubkey: Hq2x...8Fk=, Port: 51871, Peers: 2)]
== pod/cilium-8fzqn
Encryption:              Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: 3kY0Vd...Zq0=, Port: 51871, Peers: 2)]
== pod/cilium-r7wmd
Encryption:              Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: pT7b...Mw4=, Port: 51871, Peers: 2)]
```

### Questions, block 2

4. Why doesn't the header appear on `eth0`, but does appear on `cilium_wg0`? Which trust boundary does that show?
5. Why are there 2 peers and not 3 in a 3-node cluster?
6. How does each node learn the other nodes' public keys? What happens to the private key?
7. Is the `client-local` → `server` traffic encrypted? Why or why not?
8. Why did the pod MTU drop compared to Exercise 1? What happens if the MTU is not adjusted?
9. Why does the control-plane node report `NodeEncryption: OptedOut`? Which Cilium setting controls that?
10. In which firewall or security group do you need to open UDP/51871, and in which direction?

---

## Exercise 3: IPsec with Cilium and key rotation

WireGuard isn't FIPS 140 validated (ChaCha20-Poly1305 and Curve25519 are fixed by the protocol). Environments that require FIPS use IPsec with AES-GCM.

### Step 3.1: Reinstall Cilium with IPsec

Changing the encryption type in place interrupts cross-node connectivity. In the lab, reinstall Cilium:

```bash
cilium uninstall
```

Create the key **before** the install. The format is `<SPI>[+] <algorithm> <key+salt in hex> <ICV bits>`. For `rfc4106(gcm(aes))` with a 128-bit key you need 20 bytes: 16 for the key plus 4 for the salt.

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3+ rfc4106(gcm(aes)) $(openssl rand -hex 20) 128"

kubectl -n kube-system get secret cilium-ipsec-keys -o jsonpath='{.data.keys}' | base64 -d; echo
```

```
3+ rfc4106(gcm(aes)) 9f1c...a07b 128
```

```bash
cilium install \
  --set encryption.enabled=true \
  --set encryption.type=ipsec
cilium status --wait
```

### Step 3.2: Verify IPsec

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
```

```
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 1
Max Seq. Number: 0x1a3/0xffffffff
Errors: 0
```

Look at the XFRM state programmed in the kernel:

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  ip xfrm state
```

```
src 172.18.0.2 dst 172.18.0.3
	proto esp spi 0x00000003 reqid 1 mode tunnel
	replay-window 0
	mark 0x3e00/0xff00 output-mark 0xe00/0xf00
	aead rfc4106(gcm(aes)) 0x9f1c...a07b 128
	...
```

> `ip xfrm state` prints key material. In a real incident, never paste this output into a ticket.

### Step 3.3: Prove it on the wire

Delete the pods and recreate them so they get endpoints from the new agent:

```bash
kubectl delete -f workload.yaml --wait
kubectl apply -f workload.yaml
kubectl -n enc-demo wait --for=condition=Ready pod --all --timeout=120s
```

**Terminal A:**

```bash
kubectl debug node/enc-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -ni eth0 -c 6 esp
```

**Terminal B:** run the curl loop from step 1.4.

```
IP 172.18.0.3 > 172.18.0.2: ESP(spi=0x00000003,seq=0x1b2), length 180
IP 172.18.0.2 > 172.18.0.3: ESP(spi=0x00000003,seq=0x1a9), length 132
```

Repeat the `grep TOP-SECRET` capture on `eth0` and confirm that nothing appears.

### Step 3.4: Rotate the key

```bash
read KEYID ALGO PSK KEYSIZE < <(kubectl -n kube-system get secret cilium-ipsec-keys \
  -o go-template='{{.data.keys | base64decode}}')
KEYID=${KEYID%+}
NEW_KEYID=$(( KEYID % 15 + 1 ))
NEW_PSK=$(openssl rand -hex 20)

kubectl -n kube-system patch secret cilium-ipsec-keys \
  -p "{\"stringData\":{\"keys\":\"${NEW_KEYID}+ ${ALGO} ${NEW_PSK} ${KEYSIZE}\"}}"
```

Watch the transition. It takes a few minutes for every agent to pick up the new Secret:

```bash
watch -n 5 "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status"
```

```
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 2
...
```

After the rotation window ends (5 minutes by default), the count returns to `Keys in use: 1`. The `tcpdump ... esp` capture shows the new SPI (`spi=0x00000004`).

### Questions, block 3

11. What does the SPI mean, and why does the rotation have to **change** it rather than keep the same one with a new key?
12. Why does `Keys in use` go up to 2 temporarily? What would break if the old key were removed immediately?
13. What does the `+` suffix after the SPI mean?
14. Why is `NEW_KEYID` computed modulo 15 and not with a simple `+1`?
15. Compare how keys are managed in WireGuard and in IPsec in Cilium. Which one depends on a human, or on automation you have to build?
16. Where does the IPsec PSK live, and who can read it? Name a concrete RBAC control to protect it.

---

## Exercise 4: WireGuard with Calico

The same capability exists in a different CNI, with a different control plane and different field names. On the exam you might see either one.

### Step 4.1: A new cluster with Calico

Save this as `kind-calico.yaml`. The pod CIDR must match Calico's default `IPPool`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: calico
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
- role: control-plane
- role: worker
- role: worker
```

```bash
kind delete cluster --name enc
kind create cluster --config kind-calico.yaml

CALICO_VERSION=v3.30.0
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml
kubectl wait --for=condition=Available tigerastatus --all --timeout=300s
```

Adapt `workload.yaml` to the new node names (`calico-worker`, `calico-worker2`) and apply it:

```bash
sed -e 's/enc-worker2/calico-worker2/' -e 's/enc-worker$/calico-worker/' workload.yaml | kubectl apply -f -
kubectl -n enc-demo wait --for=condition=Ready pod --all --timeout=120s
```

### Step 4.2: Enable WireGuard through FelixConfiguration

```bash
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"wireguardEnabled":true}}'
```

The resulting object, for reference (declarative equivalent):

```yaml
apiVersion: projectcalico.org/v3
kind: FelixConfiguration
metadata:
  name: default
spec:
  wireguardEnabled: true
  wireguardEnabledV6: false
  wireguardListeningPort: 51820
  wireguardInterfaceName: wireguard.cali
```

> `projectcalico.org/v3` is served by the Calico API server that the operator installs. Without it, use `crd.projectcalico.org/v1` or `calicoctl`.

### Step 4.3: Verify

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,WG_PUBKEY:.metadata.annotations.projectcalico\.org/WireguardPublicKey'
```

```
NODE                   WG_PUBKEY
calico-control-plane   Yd0q...kE8=
calico-worker          7GvR...P1s=
calico-worker2         cN3m...Xa0=
```

```bash
kubectl debug node/calico-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  ip -d link show wireguard.cali
```

Repeat the two-terminal test:

```bash
kubectl debug node/calico-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -ni eth0 -c 6 'udp port 51820'
```

```
IP 172.18.0.4.51820 > 172.18.0.3.51820: UDP, length 160
```

The `grep TOP-SECRET` capture on `eth0` shows nothing.

### Questions, block 4

17. Cilium publishes the key on the `CiliumNode`, while Calico publishes it on the `Node`. What permission does each agent need, and what does that mean if a node is compromised?
18. Before WireGuard was enabled, Calico in kind (the default `VXLANCrossSubnet` encapsulation, with every node on the same L2 network) sent pod traffic **without** encapsulation. Is plain routing more or less exposed than VXLAN from a confidentiality point of view?
19. What is the Calico field for host-to-host encryption, and on which platforms is it documented?

---

## Exercise 5: Pod-level mTLS with Istio ambient, compared with node encryption

WireGuard and IPsec encrypt **between nodes** and authenticate **nodes**. A mesh encrypts **between workloads** and authenticates **identities** (SPIFFE, derived from the ServiceAccount).

### Step 5.1: Disable Calico WireGuard (to isolate the effect)

```bash
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"wireguardEnabled":false}}'
```

### Step 5.2: Install Istio ambient and enroll the namespace

```bash
istioctl install --set profile=ambient --skip-confirmation
kubectl -n istio-system get pods
```

```
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-5xqpl      1/1     Running   0          40s
istio-cni-node-9tl2c      1/1     Running   0          40s
istio-cni-node-wv4zh      1/1     Running   0          40s
istiod-6c9d8b7f5-hk2m4    1/1     Running   0          55s
ztunnel-2kq8d             1/1     Running   0          40s
ztunnel-7nw5c             1/1     Running   0          40s
ztunnel-mfx6p             1/1     Running   0          40s
```

```bash
kubectl label namespace enc-demo istio.io/dataplane-mode=ambient
istioctl ztunnel-config workloads | grep enc-demo
```

```
NAMESPACE  POD NAME      ADDRESS          NODE            WAYPOINT  PROTOCOL
enc-demo   client        192.168.x.x      calico-worker2  None      HBONE
enc-demo   client-local  192.168.x.x      calico-worker   None      HBONE
enc-demo   server        192.168.x.x      calico-worker   None      HBONE
```

> The pods did not restart. In ambient mode, the istio-cni node agent redirects each pod's traffic to the node's ztunnel without injecting a sidecar.

### Step 5.3: Observe HBONE on the wire

**Terminal A:**

```bash
kubectl debug node/calico-worker -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -ni eth0 -c 6 'tcp port 15008'
```

**Terminal B:** run the curl loop from step 1.4.

```
IP 192.168.x.x.43122 > 192.168.x.x.15008: Flags [P.], seq 1:1449, ack 1, win 502, length 1448
```

Run the `grep TOP-SECRET` capture on `eth0` again and confirm that nothing appears.

### Step 5.4: Enforce STRICT and test a client outside the mesh

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f peerauth-strict.yaml

kubectl create namespace outsider
kubectl -n outsider run probe --image=nicolaka/netshoot --restart=Never -- sleep infinity
kubectl -n outsider wait --for=condition=Ready pod/probe --timeout=60s
kubectl -n outsider exec probe -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://server.enc-demo
```

```
000
command terminated with exit code 56
```

From inside the mesh it still works:

```bash
kubectl -n enc-demo exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server
```

```
200
```

Look at the identity used in the logs of the ztunnel on the server's node:

```bash
ZT=$(kubectl -n istio-system get pod -l app=ztunnel --field-selector spec.nodeName=calico-worker -o name)
kubectl -n istio-system logs "$ZT" --tail=20 | grep enc-demo
```

```
... src.identity="spiffe://cluster.local/ns/enc-demo/sa/default" dst.identity="spiffe://cluster.local/ns/enc-demo/sa/default" ...
```

### Step 5.5: Clean up

```bash
kubectl delete namespace outsider enc-demo
istioctl uninstall --purge --skip-confirmation
kind delete cluster --name calico
```

### Questions, block 5

20. The `outsider` pod reached the server in plaintext before STRICT existed. Why did STRICT block it, and which component rejected it?
21. With Calico WireGuard and Istio ambient enabled together, how many encryption layers does a cross-node packet carry? Is that redundant?
22. Name one attack that WireGuard between nodes does **not** mitigate, but mesh mTLS does.
23. Name one case where node encryption covers something the mesh doesn't.
24. What happens to `client-local` → `server` (same node) with ambient enabled, compared with question 7?

---

## Answers

<details>
<summary>Show answers</summary>

**1.** VXLAN is **encapsulation**, not encryption. It wraps the L2 frame in UDP so it can cross an L3 network, but the payload travels readable. It provides overlay addressing and network isolation, and nothing more: no confidentiality, integrity or authentication.

**2.** Port 8472 is the Linux kernel's historical default for VXLAN. It predates the IANA port 4789, and Cilium uses it by default. `tcpdump` associates that port with the OTV protocol (Cisco Overlay Transport Virtualization), which is why it decodes it that way. The inner packet is still the VXLAN payload.

**3.** Because the threat model for transparent encryption is the network **between** nodes: switches, taps, the cloud provider, a neighbor on the same L2 segment. Inside the pod and on the `lxc*` veth, the traffic is always plaintext, because transparent encryption doesn't change what the application sees.

**4.** The kernel encrypts the packet when it leaves through `cilium_wg0`. What you see on `cilium_wg0` is the pre-encryption packet, and what reaches `eth0` is WireGuard UDP (port 51871). The trust boundary is the **node**: anyone with root on the node, or `CAP_NET_ADMIN` in its network namespace, sees plaintext. Transparent encryption protects the wire, not the node.

**5.** Each node creates a WireGuard peer for **each other** node, so N nodes means N−1 peers. A node doesn't peer with itself.

**6.** Each agent generates its key pair locally. It keeps the private key on the node, in the agent's state directory, and it never leaves the node. It publishes the public key as an annotation on its own `CiliumNode` (`network.cilium.io/wg-pub-key`). The other agents watch `CiliumNode` objects and configure the peer with that key plus the node's pod CIDRs as `AllowedIPs`.

**7.** No. Traffic between pods on the same node never leaves the host. It goes from one veth to the other (or through eBPF redirection) and never touches `cilium_wg0` or `eth0`. The transparent encryption threat model doesn't cover it. If you need confidentiality within the node too, you need application-level mTLS or a mesh.

**8.** Each layer adds bytes to the header: VXLAN ≈ 50 bytes, WireGuard ≈ 60 bytes over IPv4 (80 over IPv6). Cilium subtracts them from the pod MTU so the outer packet doesn't exceed the physical 1500. If the MTU isn't adjusted, large packets need fragmentation or get dropped when DF is set. The classic symptom is that small `curl` requests work, but TLS handshakes or large responses hang (a PMTU black hole).

**9.** Cilium excludes nodes with the `node-role.kubernetes.io/control-plane` label by default through `encryption.nodeEncryption` together with the agent's opt-out setting (`node-encryption-opt-out-labels`). This avoids breaking bootstrap and kube-apiserver connectivity in the chicken-and-egg phase where the agent isn't running yet. You change it with the Helm value `encryption.wireguard.nodeEncryptionOptOutLabels` or the equivalent agent flag. Do that only after you have evaluated the risk.

**10.** UDP/51871 between **all** nodes in the cluster, in both directions. WireGuard is peer-to-peer and either side can start the handshake. In the cloud, that means allowing it in the security group, NSG or firewall rules that apply to node-to-node traffic. For Calico the port is UDP/51820. For Cilium IPsec it's IP protocol 50 (ESP), plus VXLAN or native routing underneath depending on the mode.

**11.** The SPI (Security Parameter Index) identifies the Security Association that the receiver must use to decrypt. During a rotation, both keys coexist. The receiver has to tell which packet was encrypted with which key, and the SPI in the ESP header is how it does that. With the same SPI and a different key, the node that hasn't been updated yet would fail to decrypt, and you'd get drops and `Errors` counted in `encrypt status`.

**12.** Agents don't pick up the new Secret at the same moment. For a period, some nodes send with the new key and others are still sending with the old one. Each node keeps both SAs in order to **receive** with either one. If you removed the old one immediately, traffic from the nodes that haven't been updated would be dropped: a partial cross-node outage.

**13.** `+` enables per-tunnel keys. A distinct key is derived for each node pair from the global PSK, so every direction/pair has its own key. Without `+` every node shares exactly the same key, which widens the blast radius and, with AES-GCM, increases the risk of nonce reuse. The docs recommend it and require it in modern versions.

**14.** Cilium uses 4 bits for the SPI in its encryption marks, so the valid range is 1–15. A simple `+1` from 15 would give 16, which is invalid. `KEYID % 15 + 1` wraps from 15 back to 1.

**15.** With WireGuard, keys are **automatic**: each node generates its own pair and publishes it through the Kubernetes API, and there's no shared secret. With IPsec in Cilium, it's a **pre-shared key** in a Secret that you create and rotate yourself (a human or a CronJob/pipeline you build). IPsec gives you FIPS-compatible algorithms and fine-grained control, at the price of operational work and the risk of forgetting to rotate.

**16.** In `Secret/cilium-ipsec-keys` in `kube-system`. Anyone with `get`/`list`/`watch` on Secrets in `kube-system` can read it, and so can anyone with etcd access if etcd isn't encrypted at rest. Controls:

- Avoid ClusterRoles with `secrets: get/list/watch` on `*`.
- Audit `ClusterRoleBinding`s that include `kube-system`.
- Enable `EncryptionConfiguration` for Secrets at rest.
- Optionally use a `resourceNames`-scoped Role for the operator that rotates the key.

**17.** Each Cilium agent needs `update`/`patch` on `ciliumnodes`. Each Calico node agent needs to write to its `Node` or to Calico's node resource. On a compromised node, an attacker with those credentials could publish a public key under their control for **their own** node, but can't read other nodes' private keys, which never leave them. Well-configured versions restrict each agent to writing only its own object. The remaining risk is that the compromised node sees its own traffic in plaintext (question 4).

**18.** From a confidentiality standpoint, it's **equally** exposed: both travel in plaintext. VXLAN only adds a header. Plain routing has less overhead and is more readable in a capture, but neither protects the payload.

**19.** `wireguardHostEncryptionEnabled` in `FelixConfiguration`. It's documented for managed clusters (EKS with the AWS CNI and AKS), because there Calico doesn't control pod networking and host-to-host is the only point where it can encrypt. It's not the general mechanism for self-managed clusters.

**20.** Without STRICT, the default mode is PERMISSIVE: ztunnel accepts both HBONE/mTLS and plaintext towards meshed pods. With STRICT, the ztunnel on the **destination** node rejects any inbound connection towards `server` that doesn't arrive over HBONE with a valid mesh certificate. The `outsider` pod isn't in ambient, so it doesn't go through a ztunnel on egress and it has no SPIFFE identity. The TCP connection gets reset (`curl` exit code 56).

**21.** Two layers. HBONE is mTLS inside TCP/15008, and that travels inside Calico WireGuard (UDP/51820). It's redundant for confidentiality on the wire, but not for security as a whole: WireGuard authenticates nodes, while mTLS authenticates workloads and enables identity-based authorization policies. The cost is double the CPU and double the overhead on the MTU.

**22.** Lateral movement or spoofing between pods. A compromised pod that knows the IP of `server` connects to it, and WireGuard encrypts that connection without asking who it is: the only authentication is node to node. With mesh mTLS plus `AuthorizationPolicy`, the server only accepts specific SPIFFE identities.

**23.** Traffic that doesn't go through the mesh: pods in namespaces that aren't enrolled, hostNetwork components (with `nodeEncryption` or `wireguardHostEncryptionEnabled`), non-TCP protocols (UDP such as DNS, or SCTP), and traffic from workloads whose code or sidecar you don't control. Node encryption is also independent of applications and of the mesh's certificate lifecycle.

**24.** With ambient, even same-node traffic goes through the node's ztunnel, which establishes HBONE with mTLS between the source and destination identities. In question 7 it wasn't encrypted at all. Here it is authenticated and encrypted with mTLS, and STRICT and `AuthorizationPolicy` apply to it just as they do to cross-node traffic.

</details>