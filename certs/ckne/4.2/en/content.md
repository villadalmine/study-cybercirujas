# 4.2 Implementing Node and Pod Level Encryption

## 1. Why this matters in production

Kubernetes assumes a flat, routable pod network. Any pod can reach any other pod IP, and **none of that traffic is encrypted by default**. The kubelet, API server and etcd use TLS for control-plane traffic. The data plane is different: pod-to-pod packets, whether they go through a VXLAN/Geneve overlay or native routing, cross the physical or virtual network in plaintext.

That becomes a real problem in several common situations:

| Scenario | Why plaintext pod traffic is a problem |
|---|---|
| Multi-AZ / multi-datacenter clusters | Traffic crosses links you do not control (provider backbone, leased lines, dark fiber) |
| Hybrid / edge nodes | Nodes join over the Internet or shared WAN |
| Regulated workloads (PCI-DSS, HIPAA, FedRAMP) | Encryption in transit is a documented control, and "the VPC is private" is not accepted as compensation |
| Shared L2 / bare metal | A compromised host or switch port can mirror and sniff traffic between other nodes |
| Zero-trust mandates | The network location of a peer must not imply trust. Identity has to be proven cryptographically |

Two layers of encryption solve different problems. The exam, and production design, expect you to know which layer answers which threat:

- **Node-level (transparent) encryption:** a kernel tunnel (WireGuard or IPsec) between nodes. Every packet leaving node A for node B is encrypted, and pods don't notice. **The identity is the node.** It is implemented by the CNI (Cilium, Calico, and others).
- **Pod-level (workload) encryption:** mutual TLS between workloads, using per-workload identities (SPIFFE IDs bound to ServiceAccounts). **The identity is the workload.** It is implemented by a service mesh (Istio sidecar or ambient, Linkerd), by Cilium mutual authentication, or by the application itself.

```
                 NODE-LEVEL (WireGuard/IPsec)                 POD-LEVEL (mTLS)
 ┌──────── node A ────────┐         ┌──────── node B ────────┐
 │ pod-a ──plaintext──┐   │         │   ┌──plaintext── pod-b │   identity = node key
 │                    ▼   │ ══enc══ │   ▼                    │   same-node traffic NOT encrypted
 │              cilium_wg0│         │cilium_wg0              │
 └────────────────────────┘         └────────────────────────┘

 ┌──────── node A ────────┐         ┌──────── node B ────────┐
 │ pod-a ─▶ proxy/ztunnel │ ══mTLS═ │ ztunnel/proxy ─▶ pod-b │   identity = spiffe://…/sa/frontend
 └────────────────────────┘         └────────────────────────┘   AuthZ can use the peer identity
```

**Key architectural point:** node-level encryption proves that "this packet came from a legitimate node". It does **not** prove which pod sent it. A compromised pod on a legitimate node still sends traffic that gets encrypted and accepted. Only workload identity (mTLS) lets you write policy such as "only `sa/frontend` in `ns/web` may call `payments-api`".

---

## 2. Technical comparisons

### 2.1 Protocols: WireGuard vs IPsec vs mTLS

| Property | WireGuard | IPsec (ESP, XFRM) | mTLS (TLS 1.2/1.3) |
|---|---|---|---|
| OSI layer | L3 (UDP-encapsulated) | L3 (IP protocol 50, ESP) | L4/L7 (inside the TCP stream) |
| Crypto | Fixed: Curve25519, ChaCha20-Poly1305, BLAKE2s. No negotiation | Negotiable. In K8s CNIs typically AES-GCM (`rfc4106(gcm(aes))`) | Negotiable cipher suites (AES-GCM, ChaCha20) |
| FIPS 140 | **No** (primitives are not FIPS-approved) | **Yes**, with a FIPS-validated kernel crypto module | Yes, with a FIPS build of the proxy (e.g. BoringSSL-FIPS) |
| Key management | Automatic: each agent generates a keypair and publishes the public key | **Operator-managed** pre-shared key in a Secret (Cilium). Rotation is manual | Automatic: mesh CA issues short-lived certs (Istio: 24 h default) |
| Identity granularity | Node | Node | Workload (ServiceAccount / SPIFFE ID) |
| Same-node pod traffic | Not encrypted (never leaves the host) | Not encrypted | Encrypted (sidecar); passes through the proxy |
| Hardware acceleration | SIMD. Fast even without AES-NI | AES-NI, and NIC/XFRM offload possible | AES-NI in userspace proxy |
| Wire overhead | ~60 B IPv4 / ~80 B IPv6 | ~50–73 B (ESP header + IV + ICV + padding) | TLS record overhead + proxy hop |
| Firewall requirement | One UDP port between nodes | ESP (IP proto 50) must be allowed | Nothing new (same TCP ports / HBONE 15008 in ambient) |
| Authorization by peer identity | No | No | **Yes** |
| App-transparent | Yes | Yes | Yes with a mesh; no if the app does TLS itself |

### 2.2 Implementations you should recognize

| Implementation | Mechanism | Enable with | Interface / port | Notes |
|---|---|---|---|---|
| Cilium WireGuard | In-kernel WireGuard, eBPF steering | Helm `encryption.enabled=true`, `encryption.type=wireguard` | `cilium_wg0`, UDP **51871** | Public key published as CiliumNode annotation `network.cilium.io/wg-pub-key`. `nodeEncryption` adds host traffic |
| Cilium IPsec | Kernel XFRM | Helm `encryption.type=ipsec` + Secret `cilium-ipsec-keys` | ESP | FIPS-capable. You own key rotation (SPI 1–15) |
| Calico WireGuard | In-kernel WireGuard via Felix | FelixConfiguration `wireguardEnabled: true` | `wireguard.cali` UDP **51820**, `wg-v6.cali` UDP **51821** | Public key in node annotation `projectcalico.org/WireguardPublicKey` |
| Istio sidecar | Envoy per pod, mTLS with SPIFFE certs from istiod | PeerAuthentication `STRICT` | Pod ports | Full L7 policy. Memory/latency cost per pod |
| Istio ambient | ztunnel per node (L4 mTLS over HBONE), optional waypoint (L7) | Namespace label `istio.io/dataplane-mode=ambient` | HBONE TCP **15008** | Identities are still per workload, even though ztunnel is per node |
| Linkerd | linkerd2-proxy sidecar, mTLS on by default | `linkerd.io/inject: enabled` | Pod ports | Automatic for meshed-to-meshed TCP |
| Cilium mutual auth | SPIFFE/SPIRE handshake out-of-band, policy `authentication.mode: required` | Helm `authentication.mutual.spire.enabled=true` | n/a | **Authenticates but does not encrypt.** Combine with WireGuard/IPsec |

### 2.3 Decision matrix

| Requirement | Recommended choice |
|---|---|
| "Encrypt everything between nodes, minimal operations, no FIPS" | CNI WireGuard (Cilium or Calico) |
| FIPS 140-validated crypto for the data plane | Cilium IPsec with a FIPS kernel, or a mesh with a FIPS proxy build |
| Authorization based on which workload is calling | Service mesh mTLS (Istio / Linkerd) |
| Zero-trust with low per-pod overhead | Istio ambient (ztunnel) |
| Defense in depth (compliance asks for both) | WireGuard + mesh mTLS. Expect double encryption CPU cost |
| Traffic between nodes and non-pod endpoints (host network, NodePort backends) | Cilium `nodeEncryption=true`, or Calico `wireguardHostEncryptionEnabled` |

---

## 3. Node-level encryption with Cilium WireGuard

### 3.1 How it works

1. Each `cilium-agent` generates a Curve25519 keypair and stores the private key on the node, under `/var/run/cilium/`.
2. It publishes the public key as the `network.cilium.io/wg-pub-key` annotation on its `CiliumNode` object.
3. Every agent watches the `CiliumNode` objects and adds a WireGuard peer for each remote node. `AllowedIPs` are that node's pod CIDRs (plus node IPs when `nodeEncryption` is on).
4. eBPF programs redirect packets whose destination is a remote endpoint to `cilium_wg0`. The kernel encrypts them and sends them as UDP/51871 to the peer node.
5. Pod-to-pod traffic on the same node never touches `cilium_wg0`.

Default scope: only traffic between pods on different nodes. With `encryption.nodeEncryption=true`, traffic pod↔remote-node and node↔node is also encrypted. Nodes carrying the label in `node-encryption-opt-out-labels` are excluded; the default is `node-role.kubernetes.io/control-plane`, so control-plane nodes are skipped unless you change it.

### 3.2 Helm values (complete)

```yaml
# cilium-values-wireguard.yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.10.10
k8sServicePort: 6443
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
encryption:
  enabled: true
  type: wireguard
  nodeEncryption: true
hubble:
  enabled: true
  relay:
    enabled: true
operator:
  replicas: 2
```

```
$ helm repo add cilium https://helm.cilium.io/
$ helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --version 1.17.6 \
    -f cilium-values-wireguard.yaml
$ kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out
```

Prerequisites: WireGuard is in the mainline kernel since 5.6. Check with `modinfo wireguard` on every node. Allow **UDP 51871** between all nodes in security groups and host firewalls.

### 3.3 Verification

```
$ kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'enable-wireguard|encrypt-node'
  enable-wireguard: "true"
  encrypt-node: "true"

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep Encryption
Encryption:              Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: 3SVPRwJxT+AQUVTmj/4vX3yUd5B0wPvj2m+5W5XSaWk=, Port: 51871, Peers: 2)]

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
        Public key: 3SVPRwJxT+AQUVTmj/4vX3yUd5B0wPvj2m+5W5XSaWk=
        Number of peers: 2

$ kubectl get ciliumnodes -o custom-columns='NODE:.metadata.name,WGKEY:.metadata.annotations.network\.cilium\.io/wg-pub-key'
NODE       WGKEY
cp-1       3SVPRwJxT+AQUVTmj/4vX3yUd5B0wPvj2m+5W5XSaWk=
worker-1   kqF0xN1mXk8fM3cS7c9n6P0bXx2mJ6y1tQ4c1bXvD1s=
worker-2   Y2d9bPq5nT8sV6hR1wK3mZ0aL7fJ4cE9xU2yN5oI8gA=
```

**Rule of thumb:** `Peers` should be `number_of_nodes - 1`. Fewer peers means a node could not read another node's key, or the CiliumNode annotation is missing.

On the node itself, if `wireguard-tools` is installed:

```
$ sudo wg show cilium_wg0
interface: cilium_wg0
  public key: kqF0xN1mXk8fM3cS7c9n6P0bXx2mJ6y1tQ4c1bXvD1s=
  private key: (hidden)
  listening port: 51871
  fwmark: 0x1e00

peer: Y2d9bPq5nT8sV6hR1wK3mZ0aL7fJ4cE9xU2yN5oI8gA=
  endpoint: 192.168.10.22:51871
  allowed ips: 10.0.2.0/24, 192.168.10.22/32
  latest handshake: 41 seconds ago
  transfer: 18.42 MiB received, 22.07 MiB sent
```

`latest handshake` is the most useful field. If it is missing or older than about 3 minutes while traffic is flowing, the UDP path between the nodes is broken.

### 3.4 Proving the traffic is encrypted (packet-level test)

First, deploy a server and a client on **different** nodes:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: enc-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  namespace: enc-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: echo-server
  namespace: enc-test
spec:
  selector:
    app: echo-server
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: enc-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: echo-server
            topologyKey: kubernetes.io/hostname
      containers:
      - name: netshoot
        image: nicolaka/netshoot:v0.13
        command:
        - sleep
        - infinity
```

```
$ kubectl apply -f enc-test.yaml
$ kubectl -n enc-test get pods -o wide
NAME                           READY   STATUS    IP           NODE
client-6d8f7b9c5-xk2lp         1/1     Running   10.0.1.47    worker-1
echo-server-5c9d6f8b7-q8wzt    1/1     Running   10.0.2.113   worker-2
```

On `worker-2`, capture on the physical interface while the client sends requests:

```
$ kubectl -n enc-test exec deploy/client -- sh -c 'for i in $(seq 1 5); do curl -s -o /dev/null -w "%{http_code}\n" http://echo-server; done'
200
200
200
200
200

# worker-2, underlay NIC: only WireGuard UDP, no TCP/80
$ sudo tcpdump -ni eth0 'udp port 51871' -c 4
IP 192.168.10.21.51871 > 192.168.10.22.51871: UDP, length 128
IP 192.168.10.22.51871 > 192.168.10.21.51871: UDP, length 128
IP 192.168.10.21.51871 > 192.168.10.22.51871: UDP, length 208
IP 192.168.10.22.51871 > 192.168.10.21.51871: UDP, length 96

# Negative check: plaintext HTTP must NOT appear on the underlay
$ sudo tcpdump -ni eth0 'tcp port 80 and host 10.0.2.113' -c 1 --immediate-mode
(no output — Ctrl-C)
0 packets captured

# Inside the tunnel device you see the decrypted inner packets
$ sudo tcpdump -ni cilium_wg0 -c 2
IP 10.0.1.47.51322 > 10.0.2.113.80: Flags [S], seq 1123581321, win 64860, length 0
IP 10.0.2.113.80 > 10.0.1.47.51322: Flags [S.], seq 3141592653, ack 1123581322, win 64308, length 0
```

With VXLAN tunnel mode and **no** encryption, the same underlay capture shows `UDP 8472` VXLAN frames. `tcpdump -A` then reveals the inner HTTP headers in cleartext. That is the "before" picture you use to justify the change.

Hubble also shows whether a flow was encrypted:

```
$ hubble observe -n enc-test --to-pod enc-test/echo-server -o compact --last 2
Sep 30 10:12:04.118: enc-test/client-6d8f7b9c5-xk2lp:51322 (ID:2941) -> enc-test/echo-server-5c9d6f8b7-q8wzt:80 (ID:10387) to-endpoint FORWARDED (TCP Flags: SYN)
Sep 30 10:12:04.119: enc-test/client-6d8f7b9c5-xk2lp:51322 (ID:2941) <- enc-test/echo-server-5c9d6f8b7-q8wzt:80 (ID:10387) to-network FORWARDED (TCP Flags: SYN, ACK)
```

With `-o json`, check `"is_encrypted": true` inside the `IP` object of each flow. Recent Cilium versions populate it for WireGuard/IPsec.

### 3.5 Strict mode (preventing unencrypted leaks)

During key exchange or a node join, Cilium can briefly send pod traffic unencrypted. Strict mode drops unencrypted pod-to-pod traffic within a CIDR instead of letting it leak:

```yaml
encryption:
  enabled: true
  type: wireguard
  strictMode:
    enabled: true
    cidr: "10.0.0.0/16"
    allowRemoteNodeIdentities: false
```

**Trade-off:** you get availability loss (drops) instead of confidentiality loss (plaintext) whenever the WireGuard mesh is incomplete. Hubble shows the drops as `DROPPED (Traffic is unencrypted)`. The strict-mode keys have changed between Cilium minor versions, so confirm them in the Helm values reference for your release.

---

## 4. Node-level encryption with Cilium IPsec

### 4.1 How it works

Cilium programs Linux **XFRM** states and policies (`ip xfrm state` / `ip xfrm policy`). Packets marked by eBPF are matched by an XFRM policy and encrypted with ESP using the key from a Kubernetes Secret. The Secret holds a single pre-shared key. With the `+` suffix on the SPI, Cilium derives **per-node-pair** keys from it.

Key format in the Secret: `<SPI>[+] <algorithm> <key-hex> <icv-bits>`

- SPI: 1–15. It must change on every rotation.
- `rfc4106(gcm(aes))`: AES-GCM AEAD, hardware-accelerated with AES-NI.
- 20 random bytes = 16-byte AES-128 key + 4-byte salt. The ICV is 128 bits.

### 4.2 Deployment

```
$ kubectl create -n kube-system secret generic cilium-ipsec-keys \
    --from-literal=keys="3+ rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"
secret/cilium-ipsec-keys created
```

```yaml
# cilium-values-ipsec.yaml
kubeProxyReplacement: true
k8sServiceHost: 192.168.10.10
k8sServicePort: 6443
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
encryption:
  enabled: true
  type: ipsec
hubble:
  enabled: true
  relay:
    enabled: true
```

```
$ helm upgrade --install cilium cilium/cilium -n kube-system --version 1.17.6 -f cilium-values-ipsec.yaml
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 1
Max Seq. Number: 0x1f4/0xffffffff
Errors: 0
```

On a node:

```
$ sudo ip xfrm state | head -6
src 192.168.10.21 dst 192.168.10.22
        proto esp spi 0x00000003 reqid 1 mode tunnel
        replay-window 0
        mark 0x3e00/0xff00 output-mark 0xe00/0xf00
        aead rfc4106(gcm(aes)) 0x... 128
        anti-replay context: seq 0x0, oseq 0x1f4, bitmap 0x00000000

$ sudo tcpdump -ni eth0 esp -c 2
IP 192.168.10.21 > 192.168.10.22: ESP(spi=0x00000003,seq=0x1f5), length 140
IP 192.168.10.22 > 192.168.10.21: ESP(spi=0x00000003,seq=0x1c2), length 140
```

### 4.3 Key rotation (you own this)

IPsec has no automatic rekeying in Cilium. Plan the rotation, and rotate before `Max Seq. Number` approaches its limit, or on your compliance schedule:

```
$ KEYID=$(kubectl get secret -n kube-system cilium-ipsec-keys -o go-template --template={{.data.keys}} | base64 -d | grep -oP "^\d+")
$ if [[ $KEYID -ge 15 ]]; then KEYID=0; fi
$ data=$(echo "{\"stringData\":{\"keys\":\"$((KEYID+1))+ rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128\"}}")
$ kubectl patch secret -n kube-system cilium-ipsec-keys -p="${data}"
secret/cilium-ipsec-keys patched

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 2
Max Seq. Number: 0x12/0xffffffff
Errors: 0
```

`Keys in use: 2` is expected during the rotation window: the old key is still accepted for decryption for `ipsec-key-rotation-duration` (default 5 min). After that it should return to 1. **Every agent must pick up the new Secret before the window ends.** If an agent pod is stuck, cross-node traffic from that node breaks.

---

## 5. Node-level encryption with Calico WireGuard

### 5.1 Enabling

```
$ kubectl patch felixconfiguration default --type=merge -p '{"spec":{"wireguardEnabled":true}}'
felixconfiguration.projectcalico.org/default patched
```

Declarative equivalent (manage it via GitOps rather than ad-hoc patches):

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
  wireguardMTU: 1440
  wireguardHostEncryptionEnabled: false
```

`wireguardHostEncryptionEnabled` also encrypts host-network traffic. It is intended for specific managed platforms (e.g. EKS with the AWS VPC CNI, AKS), so read the Calico docs before turning it on elsewhere.

### 5.2 Verification

```
$ kubectl get node worker-1 -o yaml | grep -i wireguard
    projectcalico.org/IPv4WireguardInterfaceAddr: 10.244.171.0
    projectcalico.org/WireguardPublicKey: jlkVyQYooZYzI2wFfNhSZez5eWh44yfq1wKVjLvSXgY=

$ kubectl get nodes -o custom-columns='NODE:.metadata.name,WGKEY:.metadata.annotations.projectcalico\.org/WireguardPublicKey'
NODE       WGKEY
cp-1       0kX6c2cJq1v9eT4mE8yH3aP7rL5sW2dN6fG1bZ0uQ4o=
worker-1   jlkVyQYooZYzI2wFfNhSZez5eWh44yfq1wKVjLvSXgY=
worker-2   Qm3tX8vL1nC6pR9sE2yK5aH0dF7gJ4bW1zU8oI3eN6c=

# on a node
$ ip -d link show wireguard.cali
14: wireguard.cali: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1440 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/none  promiscuity 0 minmtu 0 maxmtu 2147483552
    wireguard

$ sudo wg show wireguard.cali | grep -E 'peer|handshake'
peer: 0kX6c2cJq1v9eT4mE8yH3aP7rL5sW2dN6fG1bZ0uQ4o=
  latest handshake: 17 seconds ago
peer: Qm3tX8vL1nC6pR9sE2yK5aH0dF7gJ4bW1zU8oI3eN6c=
  latest handshake: 1 minute, 2 seconds ago
```

A node **without** the `WireguardPublicKey` annotation is not taking part. Check `calico-node` logs on that node. A typical message is that WireGuard is not supported by the kernel. Calico then keeps sending that node's traffic unencrypted rather than dropping it.

```
$ kubectl -n calico-system logs ds/calico-node -c calico-node | grep -i wireguard | tail -3
2026-09-30 10:02:11.482 [INFO][61] felix/wireguard.go 1672: Wireguard is not supported by the kernel
```

---

## 6. Pod-level encryption: mTLS with workload identity

### 6.1 Identity model (SPIFFE)

Istio, Linkerd and Cilium mutual authentication all identify workloads with **SPIFFE IDs** derived from the ServiceAccount:

```
spiffe://cluster.local/ns/payments/sa/payments-api
```

The mesh CA (istiod, Linkerd identity, or SPIRE) issues short-lived X.509 SVIDs. Istio's default lifetime is 24 h and rotation is automatic. The peers authenticate each other during the TLS handshake. Encryption is then a side effect of the TLS session, and **authorization can use the verified peer identity**. Node-level encryption cannot offer that.

### 6.2 Istio: enforcing STRICT mTLS

Istio defaults to `PERMISSIVE`: it accepts both mTLS and plaintext, so non-meshed clients keep working during migration. Production target: `STRICT`, applied mesh-wide from the root namespace:

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

Namespace override during a migration, plus a port-level exception for a Prometheus scrape port. `portLevelMtls` needs a `selector` and applies to sidecar mode only; ztunnel in ambient mode does not honour it:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: legacy-migration
  namespace: payments
spec:
  mtls:
    mode: PERMISSIVE
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: payments-api-metrics
  namespace: payments
spec:
  selector:
    matchLabels:
      app: payments-api
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:
      mode: PERMISSIVE
```

Precedence: workload selector > namespace > root namespace.

Authorization based on identity, which only works because mTLS is in place:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payments-api-allow-frontend
  namespace: payments
spec:
  selector:
    matchLabels:
      app: payments-api
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/web/sa/frontend
    to:
    - operation:
        ports:
        - "8080"
```

If a request arrives over plaintext, which is possible in PERMISSIVE mode, it has no principal and does not match `principals`. **An ALLOW policy based on principals therefore quietly depends on mTLS.**

### 6.3 Istio ambient mode (node-local proxy, workload identity)

Ambient mode moves L4 mTLS into **ztunnel**, one DaemonSet pod per node. ztunnel tunnels traffic over **HBONE** (HTTP/2 CONNECT over mTLS, TCP 15008). It still presents a **per-workload** certificate for each pod it proxies. This is the architectural midpoint: operationally close to node-level encryption, with the identity of pod-level encryption.

```
$ kubectl label namespace payments istio.io/dataplane-mode=ambient
namespace/payments labeled

$ istioctl ztunnel-config workloads -n istio-system | grep payments
payments   payments-api-7d9c8b6f4-2mzqk   10.0.2.41   worker-2   None      HBONE
payments   payments-db-0                  10.0.1.88   worker-1   None      HBONE
web        frontend-5f7c9d8b6-kq4xz       10.0.1.52   worker-1   None      TCP
```

`PROTOCOL=TCP` for `frontend` means that namespace is **not** in the mesh. Its traffic to `payments` is plaintext and, under STRICT, it will be rejected.

```
$ istioctl ztunnel-config certificates -n istio-system | grep payments
spiffe://cluster.local/ns/payments/sa/payments-api   Leaf   Available  true   4f1a...   2026-10-01T10:04:12Z   2026-09-30T10:02:12Z
spiffe://cluster.local/ns/payments/sa/payments-api   Root   Available  true   0      2036-09-27T08:11:40Z   2026-09-29T08:11:40Z
```

### 6.4 Istio sidecar verification

```
$ istioctl proxy-config secret deploy/payments-api -n payments
RESOURCE NAME   TYPE         STATUS   VALID CERT   SERIAL NUMBER                      NOT AFTER              NOT BEFORE
default         Cert Chain   ACTIVE   true         8e2f51c0a4b1d7c3e9f6a2b5c8d1e4f7   2026-10-01T10:04:12Z   2026-09-30T10:02:12Z
ROOTCA          CA           ACTIVE   true         1f0e3d2c4b5a69788796a5b4c3d2e1f0   2036-09-27T08:11:40Z   2026-09-29T08:11:40Z

# A non-meshed client under STRICT is refused at the TLS layer
$ kubectl run plain --rm -it -n default --image=curlimages/curl:8.10.1 --restart=Never -- \
    curl -sv http://payments-api.payments:8080/healthz
*   Trying 10.96.144.12:8080...
* Connected to payments-api.payments (10.96.144.12) port 8080
> GET /healthz HTTP/1.1
* Recv failure: Connection reset by peer
curl: (56) Recv failure: Connection reset by peer
```

`Connection reset by peer` from a non-meshed client is the expected STRICT behaviour. It is not a network fault.

### 6.5 Linkerd

Linkerd turns on mTLS automatically for all TCP between meshed pods, with no policy object needed. To also *reject* unauthenticated traffic:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  annotations:
    linkerd.io/inject: enabled
    config.linkerd.io/default-inbound-policy: all-authenticated
```

```
$ linkerd viz edges deployment -n payments
SRC            DST            SRC_NS   DST_NS     SECURED
frontend       payments-api   web      payments   √
prometheus     payments-api   linkerd-viz payments √
```

A missing `√` means that edge is plaintext. Usually one side is not injected.

### 6.6 Cilium mutual authentication (not encryption on its own)

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-require-mutual-auth
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: payments-api
  ingress:
  - fromEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: web
        app: frontend
    authentication:
      mode: required
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
```

Cilium performs an out-of-band SPIFFE handshake between the agents, using SPIRE-issued identities. It caches the result and then allows the datapath flow. **The data packets themselves are not encrypted by this feature.** Pair it with WireGuard or IPsec so you get both identity and confidentiality. The feature is still beta, so check its status in your Cilium version before relying on it for compliance.

---

## 7. Operational trade-offs you must plan for

### 7.1 MTU

Every encapsulation layer uses part of the MTU. Stacked overheads on a 1500-byte underlay:

| Stack | Approx. overhead | Effective pod MTU |
|---|---|---|
| Native routing, no encryption | 0 | 1500 |
| VXLAN | 50 | 1450 |
| WireGuard (IPv4) | 60 | 1440 (Calico default) / ~1420 |
| VXLAN + WireGuard | ~110 | ~1390 |
| IPsec ESP (AES-GCM) + VXLAN | ~50 + ~73 | ~1370–1380 |

Cilium and Calico detect the MTU automatically and subtract the overhead. MTU problems come from overridden values, nested virtualization, or jumbo frames on some nodes only. **Symptom:** small requests (`/healthz`) succeed while large responses or TLS handshakes with long cert chains hang. Checks:

```
$ kubectl -n enc-test exec deploy/client -- ping -M do -s 1400 -c 2 10.0.2.113
PING 10.0.2.113 (10.0.2.113) 1400(1428) bytes of data.
ping: local error: message too long, mtu=1370

$ kubectl -n enc-test exec deploy/client -- ip link show eth0 | grep mtu
2: eth0@if31: <BROADCAST,MULTICAST,UP,LOWER_UP,M-DOWN> mtu 1370 qdisc noqueue state UP
```

### 7.2 CPU and latency

- WireGuard: kernel-space, multi-core since 5.x. Typical cost is single-digit CPU percent per Gbps on modern x86. It works well on ARM or other hosts without AES-NI.
- IPsec AES-GCM: fastest per byte when AES-NI is present, and can be NIC-offloaded. Sequential XFRM lookups can bottleneck on older kernels.
- Sidecar mTLS: adds a userspace proxy hop on **both** ends, typically 1–3 ms p99 plus ~50–100 MiB memory per pod. Ambient ztunnel removes the per-pod memory and keeps one L4 hop per node.
- Double encryption (WireGuard + mTLS): roughly adds both CPU costs. Justify it with a threat model or a compliance requirement, not by default.

### 7.3 What each layer does *not* cover

| Gap | Node-level WG/IPsec | Pod-level mTLS |
|---|---|---|
| Same-node pod traffic | Not encrypted | Encrypted |
| Traffic to non-meshed or external endpoints | Not encrypted once it leaves the cluster | Not encrypted unless egress TLS is originated |
| Compromised pod on a legit node | Accepted | Rejected by AuthZ if its identity isn't allowed |
| Host-network pods / kubelet health probes | Only with `nodeEncryption` / host encryption | Probes are rewritten or excluded by the mesh |
| UDP workloads (DNS, QUIC) | Encrypted | Istio/Linkerd mTLS is TCP-only |

The last row is often overlooked: **DNS and any other UDP between pods is only protected by node-level encryption.**

---

## 8. Troubleshooting guide

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Cross-node pod traffic times out, same-node works (Cilium WG) | UDP 51871 blocked between nodes | `tcpdump -ni eth0 udp port 51871` shows egress but no reply. `wg show` has no `latest handshake` | Open UDP 51871 (Calico: 51820/51821) in SG / NACL / host firewall |
| `Peers:` lower than node count − 1 | CiliumNode missing `wg-pub-key`, or agent crash-looping | `kubectl get ciliumnodes -o yaml \| grep wg-pub-key`, `kubectl -n kube-system get pods -l k8s-app=cilium` | Restart the failed agent. Check kernel `modinfo wireguard` |
| Hubble shows `DROPPED (Traffic is unencrypted)` | Strict mode on, and a peer is not yet in the WireGuard mesh | `cilium-dbg encrypt status` on both nodes | Fix the lagging node, or widen/adjust the strict-mode CIDR |
| Large payloads hang, small succeed | MTU mismatch after enabling encryption | `ping -M do -s <size>`, compare `ip link` MTU on pod vs `cilium_wg0` / `wireguard.cali` | Let the CNI auto-detect, or set the MTU explicitly and restart the pods (MTU is set at pod creation) |
| IPsec: cross-node dies after key rotation | An agent did not reload the Secret within the rotation window | `cilium-dbg encrypt status` → `Keys in use` differs across nodes. `ip xfrm state` shows different SPIs | Restart the stale agent. Rotate only when all agents are healthy |
| IPsec: `Errors:` counter increasing | Replay/proto errors, SPI mismatch | `cat /proc/net/xfrm_stat` (e.g. `XfrmInNoStates`, `XfrmInStateProtoError` > 0) | Align keys/SPIs across nodes. Check for NAT between nodes rewriting ESP |
| IPsec: nothing flows in cloud | ESP (IP protocol 50) blocked or not routed | `tcpdump -ni eth0 esp` on sender vs receiver | Allow protocol 50 between node subnets, or use WireGuard (plain UDP) |
| Calico node traffic still plaintext | Node has no `WireguardPublicKey` annotation | `kubectl get node <n> -o yaml \| grep -i wireguard`, calico-node logs | Install a kernel with WireGuard. Calico falls back to plaintext silently |
| Istio: `connection reset by peer` from some clients | STRICT mTLS, client not meshed | `istioctl ztunnel-config workloads` (`PROTOCOL TCP`) or the client has no sidecar | Enrol the client namespace, or scoped PERMISSIVE during migration |
| Istio: `503 UF,URX` with `upstream connect error ... TLS error` | Client sends plaintext to a STRICT sidecar (e.g. DestinationRule with `tls.mode: DISABLE`) | `istioctl x describe pod <pod>`, `istioctl proxy-config cluster <pod> -o json` | Remove the conflicting DestinationRule TLS setting. Rely on auto-mTLS |
| AuthorizationPolicy with `principals` denies legitimate traffic | Traffic arrives as plaintext (PERMISSIVE), so there is no principal | Envoy access log shows no `%DOWNSTREAM_PEER_URI_SAN%` | Enforce STRICT on that workload |
| Linkerd edge not `SECURED` | One side not injected, or traffic is via an opaque/skip port | `linkerd viz edges`, `kubectl get pod -o yaml \| grep linkerd-proxy` | Inject both sides. Review `config.linkerd.io/skip-*-ports` annotations |

A standard diagnostic sequence for "is it actually encrypted?":

```
# 1. Control plane says it's on
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status

# 2. Every node participates
$ kubectl get ciliumnodes -o custom-columns='N:.metadata.name,K:.metadata.annotations.network\.cilium\.io/wg-pub-key' | awk '$2=="<none>"'

# 3. Handshakes are recent (node shell)
$ sudo wg show cilium_wg0 latest-handshakes

# 4. The wire proves it: no plaintext for the pod IPs on the underlay
$ sudo tcpdump -ni eth0 'host 10.0.2.113 and not udp port 51871' -c 5

# 5. Workload identity layer (if a mesh is present)
$ istioctl ztunnel-config workloads -n istio-system | awk '$NF!="HBONE"'
```

Step 4 is the only one that directly demonstrates encryption. Every other step only shows that it is configured.

---

## 9. Exam-oriented summary

- Node-level (WireGuard/IPsec) = transparent, CNI-managed, **node identity**, protects the wire between nodes, covers UDP, and does not cover same-node traffic.
- Pod-level (mTLS) = mesh-managed, **workload identity (SPIFFE)**, enables identity-based authorization, TCP only. STRICT vs PERMISSIVE is the enforcement switch.
- Cilium WG: `encryption.enabled=true`, `encryption.type=wireguard`, `cilium_wg0`, UDP 51871, `cilium-dbg encrypt status`, CiliumNode annotation `network.cilium.io/wg-pub-key`, `nodeEncryption` for host traffic.
- Cilium IPsec: Secret `cilium-ipsec-keys`, format `SPI+ rfc4106(gcm(aes)) <hex> 128`, manual rotation by incrementing the SPI (1–15), `ip xfrm state`, ESP on the wire.
- Calico WG: FelixConfiguration `wireguardEnabled: true`, `wireguard.cali`, UDP 51820, node annotation `projectcalico.org/WireguardPublicKey`.
- Istio: `PeerAuthentication` mode `STRICT`, root namespace = mesh-wide. Ambient uses ztunnel + HBONE (15008). `AuthorizationPolicy.principals` requires mTLS.
- Always verify at the packet level (`tcpdump` on the underlay), and account for the MTU reduction.

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cilium, transparent encryption overview: https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium, WireGuard transparent encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium, IPsec transparent encryption: https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Cilium, mutual authentication: https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
- Cilium Helm values reference: https://docs.cilium.io/en/stable/helm-reference/
- Calico, encrypt in-cluster pod traffic (WireGuard): https://docs.tigera.io/calico/latest/network-policy/encrypt-cluster-pod-traffic
- Calico FelixConfiguration reference: https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- Istio security concepts: https://istio.io/latest/docs/concepts/security/
- Istio PeerAuthentication reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio AuthorizationPolicy reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio ambient mode overview: https://istio.io/latest/docs/ambient/overview/
- Linkerd automatic mTLS: https://linkerd.io/2/features/automatic-mtls/
- Linkerd authorization policy: https://linkerd.io/2/features/server-policy/
- WireGuard protocol and cryptography: https://www.wireguard.com/protocol/
- SPIFFE overview: https://spiffe.io/docs/latest/spiffe-about/overview/
- Kubernetes, securing a cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/