# 2.4 Implement Pod-to-Pod encryption (Cilium, Istio)

## 1. Why this topic exists

A `NetworkPolicy` answers *"who is allowed to talk to whom"*. It says nothing about *"can a third party read what they said"*. In a default Kubernetes cluster, pod-to-pod traffic that crosses a node boundary leaves the node as plain IP packets on the underlay network — VXLAN/Geneve encapsulation and native routing are **not** encryption, they are framing.

The threat model you are defending against:

| Attacker position | What they get without encryption |
|---|---|
| Compromised node (root) | `tcpdump` on the physical NIC → every flow transiting that node, including other tenants' traffic |
| Compromised network device / VPC mirroring / cloud provider tap | Full plaintext of pod-to-pod traffic |
| Attacker who joins the underlay (bare metal, on-prem, shared L2) | Passive sniffing, ARP/route spoofing, active MITM |
| Compromised pod without NetworkPolicy | Reaches services it should not — mitigated by policy, *and* by workload identity if you use mTLS |

Encryption in transit gives you **confidentiality**, **integrity** and — depending on the mechanism — **peer authentication**. That last one is the important distinction, and it is the axis on which the two exam technologies differ.

A quick demonstration of the problem. Node `worker-1` runs the client, `worker-2` runs the server:

```bash
$ kubectl exec -it client -- curl -s -H 'X-Token: CKS-SECRET-PAYLOAD' http://10.0.2.45:80/
```

On `worker-1`, sniffing the physical interface:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp and host 10.0.2.45' 2>/dev/null | grep -i CKS-SECRET
X-Token: CKS-SECRET-PAYLOAD
```

The header is on the wire in clear text. Everything below is about making that `grep` return nothing.

---

## 2. The three layers where you can encrypt

| Layer | Mechanism | Identity of the peer | Effort | Covers |
|---|---|---|---|---|
| **L3 / datapath (CNI)** | Cilium WireGuard or IPsec, Calico WireGuard | **Node** — one key pair per node | Very low: a flag, no app changes | *All* pod traffic between nodes, any protocol (TCP, UDP, SCTP, ICMP) |
| **L4-L7 / service mesh** | Istio mTLS (sidecar or ambient), Linkerd | **Workload** — SPIFFE identity derived from the ServiceAccount | Medium: mesh install, injection, policy | TCP-based mesh traffic between enrolled workloads |
| **Application** | TLS terminated in the app, cert-manager for certs | Whatever the app validates | High: code + cert lifecycle | Only what you implement |

Key mental model for the exam:

- **CNI-level encryption is transparent bulk encryption.** It protects the wire. Two pods on the *same node* trust each other implicitly, and any process with node-level access to the datapath sees plaintext. It cannot express "only `frontend` may authenticate as a client to `payments`".
- **Mesh mTLS is cryptographic workload identity.** Every pod gets its own short-lived X.509 certificate with a SPIFFE URI SAN, so you can authorize on *who the peer proves to be* rather than on IP. It only covers traffic that actually goes through the proxies.

They are complementary, not alternatives. A hardened cluster commonly runs Cilium WireGuard *and* Istio STRICT mTLS.

---

## 3. Cilium transparent encryption

Cilium offers two mutually exclusive modes: **WireGuard** and **IPsec**. Both are enabled per-cluster and both encrypt pod traffic that leaves the node.

### 3.1 WireGuard

Modern, simple, no key material for you to manage: each agent generates a key pair on startup, publishes the public key on its own `CiliumNode` CRD, and every other agent picks it up and builds a peer entry. Crypto is ChaCha20-Poly1305; the tunnel interface is `cilium_wg0` on UDP port **51871**.

**Enable it (Helm — the documented path):**

```bash
helm upgrade cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
```

**Enable it (ConfigMap — the fast path when the exam cluster already has Cilium and no Helm release metadata):**

```bash
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"enable-wireguard":"true"}}'
kubectl -n kube-system rollout restart ds/cilium
```

**Verify.** Inside the agent pod the CLI is `cilium-dbg` (1.16+; it is called `cilium` in older images):

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i encryption
Encryption:  Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: jL8t...9Uk=, Port: 51871, Peers: 2)]
```

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
	Public key: jL8tQ2r6bK1s0mV7oR4pZ3hN5cY8wX2fT6dA1eQ9Uk=
	Number of peers: 2
```

`Number of peers` must be `<number of nodes> - 1` on every agent. A node missing from the peer list is a node whose traffic is still in the clear. On the host itself:

```bash
$ sudo wg show cilium_wg0
interface: cilium_wg0
  public key: jL8tQ2r6bK1s0mV7oR4pZ3hN5cY8wX2fT6dA1eQ9Uk=
  listening port: 51871

peer: 7Hs2...pQ4=
  endpoint: 192.168.1.12:51871
  allowed ips: 10.0.2.0/24, 192.168.1.12/32
  latest handshake: 42 seconds ago
  transfer: 1.21 MiB received, 986.44 KiB sent
```

**Prove it on the wire.** Re-run the earlier request, then sniff:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp and host 10.0.2.45' 2>/dev/null | grep -i CKS-SECRET
# (nothing — the flow is no longer visible as TCP on eth0)

$ sudo tcpdump -ni eth0 -c 4 'udp port 51871'
09:41:02.113442 IP 192.168.1.11.51871 > 192.168.1.12.51871: UDP, length 176
09:41:02.114018 IP 192.168.1.12.51871 > 192.168.1.11.51871: UDP, length 128
```

You can do the same from inside the agent pod when you have no node shell:

```bash
kubectl -n kube-system exec ds/cilium -- tcpdump -ni any -c 5 'udp port 51871'
```

**Two hardening options worth knowing:**

```bash
# Also encrypt host-level (node-to-node) traffic, not just pod traffic
--set encryption.nodeEncryption=true

# Fail closed: drop unencrypted traffic inside the given CIDR instead of
# silently falling back to plaintext
--set encryption.strictMode.enabled=true \
--set encryption.strictMode.cidr=10.0.0.0/16
```

Strict mode is the answer to "encryption was enabled but a misconfigured node kept sending cleartext and nobody noticed".

### 3.2 IPsec

Uses the kernel XFRM stack with ESP. Unlike WireGuard, **you supply the key material** as a Secret, and you are responsible for rotating it.

**Create the key Secret.** The format is `<key-id> <cipher-suite> <hex-key> <key-length>`:

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"
```

```bash
$ kubectl -n kube-system get secret cilium-ipsec-keys \
    -o jsonpath='{.data.keys}' | base64 -d
3 rfc4106(gcm(aes)) 5f2c9a7e13b48d06fa5c8e21b7409dd3ac61e5f8 128
```

**Enable it:**

```bash
helm upgrade cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=ipsec \
  --set encryption.ipsec.secretName=cilium-ipsec-keys \
  --set encryption.ipsec.keyFile=keys \
  --set encryption.ipsec.interface=eth0

kubectl -n kube-system rollout restart ds/cilium
```

**Verify:**

```bash
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: IPsec
Decryption interface(s): eth0
Keys in use: 1
Max Seq. Number: 0x2f1/0xffffffff
Errors: 0
```

```bash
$ sudo ip xfrm state | head -6
src 192.168.1.11 dst 192.168.1.12
	proto esp spi 0x00000003 reqid 1 mode tunnel
	replay-window 0
	aead rfc4106(gcm(aes)) 0x5f2c...e5f8 128
	anti-replay context: seq 0x0, oseq 0x2f1, bitmap 0x00000000
	sel src 0.0.0.0/0 dst 0.0.0.0/0
```

```bash
$ sudo tcpdump -ni eth0 -c 3 'esp'
09:52:44.007731 IP 192.168.1.11 > 192.168.1.12: ESP(spi=0x00000003,seq=0x2f2), length 200
```

Three signals to check: `Keys in use: 1` (a value >1 means a rotation is in flight and not finished), `Errors: 0`, and `Max Seq. Number` far from the `0xffffffff` ceiling.

**Key rotation** — increment the key ID and patch the Secret; agents pick it up and negotiate the new SPI:

```bash
NEW_ID=4
NEW_KEY="$NEW_ID rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system patch secret cilium-ipsec-keys \
  -p "{\"stringData\":{\"keys\":\"$NEW_KEY\"}}"

# Wait until every agent reports a single key again before rotating next time
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status | grep 'Keys in use'
```

### 3.3 Choosing between them

| | WireGuard | IPsec |
|---|---|---|
| Key management | Automatic, per-node, in `CiliumNode` CRDs | Manual Secret, manual rotation |
| Cipher | ChaCha20-Poly1305 | AES-GCM / AES-CBC+HMAC (FIPS-friendly suites available) |
| Kernel requirement | WireGuard support (5.6+ or module) | XFRM/ESP, widely available |
| Observability | `wg show`, peer list | `ip xfrm state/policy`, ESP counters |
| Typical choice | Default recommendation | Regulatory requirement for a specific cipher suite, or NIC ESP offload |

### 3.4 Limitations you must be able to state

- **Same-node pod-to-pod traffic is not encrypted.** It never touches the wire; it is switched in the kernel.
- **Host-network pods and node-level traffic** (kubelet → apiserver, etcd peers) are outside the pod datapath unless you set `nodeEncryption=true` — and even then, control-plane traffic has its own TLS.
- **Identity is the node, not the workload.** Any root process on a node can read every flow that node handles. This is why CNI encryption does not replace mTLS for zero-trust authorization.
- **MTU drops.** WireGuard adds ~60 bytes of overhead for IPv4; Cilium lowers the pod MTU automatically, but hard-coded MTUs or `DF`-set jumbo traffic in applications can start failing after you enable it.
- Switching encryption mode requires an agent restart, which briefly disrupts datapath programming.

---

## 4. Istio mTLS

### 4.1 How identity works

1. `istiod` runs an internal CA. Its root certificate is distributed to every namespace as the `istio-ca-root-cert` ConfigMap.
2. Each proxy generates a key, sends a CSR to `istiod` over its ServiceAccount token, and receives a short-lived X.509 leaf certificate (default ~24 h, rotated automatically at ~50% of lifetime) delivered over **SDS** — the private key never leaves the pod.
3. The certificate's identity lives in the SAN as a SPIFFE URI:

```
spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>
```

That string is the unit of authorization. This is why "run every workload under its own ServiceAccount" matters: with a shared default SA, all workloads in a namespace are cryptographically indistinguishable.

### 4.2 Sidecar mode: install and enroll

```bash
istioctl install --set profile=default -y
kubectl -n istio-system get pods
```

```
NAME                      READY   STATUS    RESTARTS   AGE
istiod-7c9f5b8d64-2xkqr   1/1     Running   0          58s
```

Enroll a namespace and restart the workloads (injection happens at pod creation):

```bash
kubectl label namespace app istio-injection=enabled
kubectl -n app rollout restart deploy
kubectl -n app get pod
```

```
NAME                        READY   STATUS    RESTARTS   AGE
frontend-6d8f9c7b54-lm2zp   2/2     Running   0          21s
backend-5b7c4d9f8a-qr7tn    2/2     Running   0          19s
```

`2/2` is the signal: app container + `istio-proxy`. A `1/1` pod in a labelled namespace was created before the label and is **not** in the mesh — it will be the reason your STRICT policy "does not work". Revision-based installs use `istio.io/rev=<revision>` instead of `istio-injection=enabled`.

### 4.3 PeerAuthentication — turning mTLS on and making it mandatory

Out of the box, injected sidecars already use mTLS *when both ends have a proxy*, but the receiving side stays in **PERMISSIVE** mode: it accepts both mTLS and plaintext. Permissive is a migration aid, not an end state — an attacker simply speaks plaintext.

**Mesh-wide STRICT** (namespace must be the Istio root namespace, name must be `default`):

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

**Namespace scope:**

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: app
spec:
  mtls:
    mode: STRICT
```

**Workload scope with a port exception** — the realistic pattern when one legacy port must stay open (note `portLevelMtls` keys are *workload* ports, and this block only applies when a `selector` is present):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: legacy-metrics
  namespace: app
spec:
  selector:
    matchLabels:
      app: backend
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:
      mode: PERMISSIVE
```

Modes: `STRICT` (mTLS required), `PERMISSIVE` (both accepted), `DISABLE` (no mTLS), `UNSET` (inherit from the wider scope). Precedence is **workload > namespace > mesh**.

**Client side.** `PeerAuthentication` governs what a server *accepts*. To force clients to originate mTLS, use a `DestinationRule`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: default
  namespace: istio-system
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Modern Istio auto-detects and defaults to mTLS for mesh destinations, so this is mostly needed to override a narrower `DestinationRule` that set `tls.mode: DISABLE`. Remember that an explicit `DestinationRule` with `DISABLE` plus a server in `STRICT` is a classic self-inflicted outage.

### 4.4 Verifying

**Effective policy per pod:**

```bash
$ istioctl x describe pod frontend-6d8f9c7b54-lm2zp -n app
Pod: frontend-6d8f9c7b54-lm2zp
   Pod Revision: default
   Pod Ports: 8080 (frontend), 15090 (istio-proxy)
--------------------
Service: frontend
   Port: http 8080/HTTP targets pod port 8080
Effective PeerAuthentication:
   Workload mTLS mode: STRICT
Applied DestinationRule: default (istio-system)
```

**The certificate actually in use:**

```bash
$ istioctl proxy-config secret deploy/frontend -n app
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER   NOT AFTER                NOT BEFORE
default           Cert Chain     ACTIVE     true           1a2b3c4d5e      2026-07-31T09:14:22Z     2026-07-30T09:12:22Z
ROOTCA            CA             ACTIVE     true           4d5e6f7a8b      2036-07-27T08:00:00Z     2026-07-28T08:00:00Z
```

**Extract the SPIFFE identity** — this is the check that proves *whose* identity the proxy holds:

```bash
$ istioctl proxy-config secret deploy/frontend -n app -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:spiffe://cluster.local/ns/app/sa/frontend
```

**Negative test — the only test that really proves STRICT.** Run a client with no sidecar (a namespace without the injection label) and hit the service directly:

```bash
$ kubectl -n outside run probe --rm -it --image=curlimages/curl --restart=Never -- \
    curl -sS -m 5 http://backend.app.svc.cluster.local:8080/
curl: (56) Recv failure: Connection reset by peer
pod "probe" deleted
pod default/probe terminated (Error)
```

The reset comes from the target's sidecar rejecting a non-TLS handshake. From an injected client the same call succeeds. If the plaintext call *succeeds*, you are still in PERMISSIVE, the target pod has no sidecar, or your policy landed in the wrong namespace.

**On the wire**, plaintext HTTP becomes a TLS record stream:

```bash
$ sudo tcpdump -ni eth0 -A 'tcp port 8080' 2>/dev/null | head -4
E..4..@.@....... .....  ....................
.......&.....!...*.spiffe://cluster.local/ns/app/sa/frontend
```

(You may still see the SPIFFE URI in the ClientHello/certificate exchange — identities are public, payloads are not.)

**Counters** confirming traffic is going through the encrypted path:

```bash
$ kubectl -n app exec deploy/backend -c istio-proxy -- \
    pilot-agent request GET stats | grep -E 'ssl.handshake|ssl.connection_error'
listener.0.0.0.0_8080.ssl.handshake: 412
listener.0.0.0.0_8080.ssl.connection_error: 0
```

### 4.5 Ambient mode (sidecar-less)

Istio's ambient data plane replaces per-pod sidecars with a per-node **ztunnel** DaemonSet. Pod-to-pod traffic is tunnelled over **HBONE** — HTTP/2 CONNECT inside mTLS on port **15008** — so you get mTLS and L4 authorization with no sidecar injection and no pod restarts. L7 features require an additional **waypoint** proxy.

```bash
istioctl install --set profile=ambient -y
kubectl label namespace app istio.io/dataplane-mode=ambient
kubectl -n istio-system get ds ztunnel
```

```
NAME      DESIRED   CURRENT   READY   AGE
ztunnel   3         3         3       74s
```

Note the differences that trip people up: pods stay `1/1` (no extra container), enrollment takes effect without a restart, and mTLS is on by default for ambient-enrolled workloads. `PeerAuthentication` with `STRICT` still applies and is still what you write to make it mandatory. Verification uses `istioctl ztunnel-config workload` instead of `proxy-config`:

```bash
$ istioctl ztunnel-config workload --namespace app
NAMESPACE  POD NAME                    ADDRESS    NODE      WAYPOINT  PROTOCOL
app        frontend-6d8f9c7b54-lm2zp   10.0.1.17  worker-1  None      HBONE
app        backend-5b7c4d9f8a-qr7tn    10.0.2.45  worker-2  None      HBONE
```

`PROTOCOL: HBONE` means the workload is enrolled and its traffic is mTLS-encrypted; `TCP` means it is not.

### 4.6 mTLS is authentication — add authorization

STRICT mTLS proves *who* the caller is. It does not restrict *what* they may call: every mesh workload still has a valid certificate. Pair it with an `AuthorizationPolicy` keyed on the SPIFFE principal:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backend-allow-frontend
  namespace: app
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/app/sa/frontend"]
    to:
    - operation:
        methods: ["GET", "POST"]
        paths: ["/api/*"]
```

A `deny-all` baseline in the namespace, then explicit allows, is the pattern that matches the "minimize microservice vulnerabilities" mindset:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: app
spec:
  {}          # no rules + no action → ALLOW nothing
```

Two accuracy notes: `principals` are matched **without** the `spiffe://` prefix, and principal-based rules only work when mTLS is actually in force — under PERMISSIVE, a plaintext caller has no principal and such a rule silently never matches.

### 4.7 Common Istio gotchas

- **Pods created before the injection label** have no sidecar; `READY 1/1` is your tell. Restart the Deployment.
- **`PeerAuthentication` in the wrong namespace.** Mesh-wide policy *must* be named `default` in the root namespace (`istio-system` by default). A mesh-wide-looking policy in `app` only covers `app`.
- **Exclusion annotations defeat encryption.** `traffic.sidecar.istio.io/excludeInboundPorts` and `excludeOutboundPorts` route traffic around the proxy entirely — audit them; they are a plausible-looking backdoor.
- **`hostNetwork: true` pods** and traffic that bypasses the Service (raw pod IP for a workload the proxy has no listener for) can escape the mesh.
- **Health probes** are rewritten by Istio automatically; if probe rewrite is disabled, kubelet's plaintext probe will be rejected under STRICT.
- **Traffic leaving the mesh** (external databases, non-mesh namespaces) is not covered by `ISTIO_MUTUAL`; use `SIMPLE`/`MUTUAL` TLS origination in a `DestinationRule` instead.
- Sidecars only handle **TCP-based** protocols. UDP traffic — including DNS — is not encrypted by the sidecar; a CNI-level mechanism is.

---

## 5. Combining the mechanisms

Defence in depth for pod-to-pod traffic:

1. **CNI encryption (Cilium WireGuard)** — blanket protection of everything on the wire, including UDP/DNS and non-mesh namespaces, with strict mode so it fails closed.
2. **Istio STRICT mTLS** — per-workload cryptographic identity, so a compromised pod cannot impersonate another workload.
3. **NetworkPolicy / CiliumNetworkPolicy** — default-deny reachability, so an attacker cannot even open the connection.
4. **AuthorizationPolicy** — least privilege on top of identity.

They stack cleanly, with one operational caveat: when a mesh is present, all pod traffic flows through the sidecars, so your L3/L4 policies must permit the proxy's ports (15001/15006/15008/15021) and the pods' access to `istiod` on 15012. Encrypting twice costs CPU; that is a performance decision, not a correctness problem.

---

## 6. Troubleshooting quick reference

| Symptom | Likely cause | Check |
|---|---|---|
| `cilium-dbg encrypt status` shows `Encryption: Disabled` | Agent restarted without the new config, or ConfigMap key wrong | `kubectl -n kube-system get cm cilium-config -o yaml \| grep -E 'wireguard\|ipsec'` |
| `Number of peers` less than nodes−1 | An agent is unhealthy or its `CiliumNode` has no public key | `kubectl get ciliumnodes -o yaml \| grep -i wireguard` |
| IPsec `Keys in use: 2` for a long time | Rotation stuck; a node never received the new key | `cilium-dbg encrypt status` on every agent |
| Traffic still plaintext in tcpdump | Both pods are on the **same node** | `kubectl get pod -o wide` — compare `NODE` |
| Intermittent failures after enabling encryption | MTU | Test with `ping -M do -s 1400`, check `ip link show cilium_wg0` |
| STRICT policy has no effect | Target pod has no sidecar / policy in the wrong namespace | `kubectl get pod` (`2/2`?), `kubectl get peerauthentication -A` |
| `upstream connect error ... reset before headers` | Client sends plaintext or `DestinationRule` sets `tls.mode: DISABLE` against a STRICT server | `istioctl x describe pod <pod>` |
| 503 only for one port | `portLevelMtls` uses the Service port instead of the workload port | Compare `targetPort` with the `portLevelMtls` key |

---

## 7. Exam runbook

Fast, high-value sequence when a task says "encrypt pod-to-pod traffic":

```bash
# --- Which mechanism is already present? ---
kubectl -n kube-system get pods | grep -E 'cilium|calico'
kubectl get ns istio-system && kubectl -n istio-system get pods

# --- Cilium WireGuard, minimum keystrokes ---
kubectl -n kube-system patch cm cilium-config --type merge \
  -p '{"data":{"enable-wireguard":"true"}}'
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status

# --- Istio STRICT mesh-wide ---
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
kubectl get peerauthentication -A
```

Things to be able to answer in one sentence each:

- Why VXLAN is not encryption.
- Why same-node traffic stays in the clear under CNI encryption.
- Why PERMISSIVE is not a security posture.
- Why per-workload ServiceAccounts are a prerequisite for meaningful mTLS authorization.
- The difference between what `PeerAuthentication` and `AuthorizationPolicy` enforce.

Always finish with a **negative test** (a plaintext client that must fail, or a `tcpdump` that must show no cleartext). A configuration that was applied is not the same as a configuration that is in force.

---

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Cilium — Transparent Encryption: https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — WireGuard Transparent Encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium — IPsec Transparent Encryption and key rotation: https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Cilium — `cilium-dbg` CLI reference: https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Istio — Mutual TLS Migration: https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — Peer Authentication (concepts): https://istio.io/latest/docs/concepts/security/#peer-authentication
- Istio — `PeerAuthentication` API reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — `AuthorizationPolicy` API reference: https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Certificate management and identity: https://istio.io/latest/docs/concepts/security/#istio-identity
- Istio — Ambient mode overview: https://istio.io/latest/docs/ambient/overview/
- Istio — Ambient mTLS and HBONE: https://istio.io/latest/docs/ambient/architecture/data-plane/
- Istio — `istioctl` reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Kubernetes — Network Policies (what they do and do not cover): https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Securing a Cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- SPIFFE — ID format specification: https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md
- WireGuard — Protocol overview: https://www.wireguard.com/protocol/