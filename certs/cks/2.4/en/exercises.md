# Exercises — 2.4 Implement Pod-to-Pod Encryption (Cilium, Istio)

**Certification:** CKS 1.34 · **Domain weight:** 5%

These are hands-on guided exercises. Every block ends with verification questions; answers are collapsed at the bottom. Do not read the answers until you have executed the block.

---

## Lab setup

You need a **multi-node** cluster. Pod-to-pod encryption in Cilium only applies to traffic that leaves the node, so a single-node cluster will silently make every verification step pass for the wrong reason.

```bash
cat <<'EOF' > kind-enc.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true      # we install Cilium ourselves
  kubeProxyMode: none          # Cilium will replace kube-proxy
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

kind create cluster --name enc --config kind-enc.yaml
```

Install Cilium **without** encryption first — the first exercise depends on traffic being in cleartext.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set k8sServiceHost=enc-control-plane \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=true

kubectl -n kube-system rollout status ds/cilium --timeout=180s
kubectl get nodes
```

Requirements checklist before you continue:

| Requirement | Check |
|---|---|
| Kernel with WireGuard support (5.6+, or `wireguard` module) | `grep -i wireguard /lib/modules/$(uname -r)/modules.builtin` or `modprobe wireguard` |
| `helm`, `kubectl`, `jq`, `openssl` on the client | `which helm kubectl jq openssl` |
| All nodes `Ready` | `kubectl get nodes` |

---

## Exercise 1 — Prove that pod-to-pod traffic is cleartext by default

**Goal:** establish a baseline. You cannot claim you encrypted something if you never saw it unencrypted.

1. Create the lab namespace and a canary HTTP server pinned to `enc-worker`:

```bash
kubectl create ns enc-lab

kubectl -n enc-lab run canary \
  --image=hashicorp/http-echo \
  --port=5678 \
  --overrides='{"spec":{"nodeName":"enc-worker"}}' \
  -- -listen=:5678 -text=CKS-PLAINTEXT-CANARY
```

2. Create a client pod on the **other** worker, so the traffic must cross the network:

```bash
kubectl -n enc-lab run probe \
  --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeName":"enc-worker2"}}' \
  -- sleep infinity

kubectl -n enc-lab wait --for=condition=Ready pod/canary pod/probe --timeout=120s
kubectl -n enc-lab get pods -o wide
```

3. Save the canary IP:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
echo "$CANARY_IP"
```

4. Deploy a sniffer with host networking on the server's node. This is the only reliable way to see what actually goes on the wire:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sniffer
  namespace: enc-lab
spec:
  nodeName: enc-worker
  hostNetwork: true
  tolerations:
    - operator: Exists
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
EOF

kubectl -n enc-lab wait --for=condition=Ready pod/sniffer --timeout=120s
```

5. **Terminal A** — start the capture. Include the VXLAN overlay port, the WireGuard port and ESP so the same command works for every later exercise:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 30 tcpdump -ni any -A -s0 -l \
  'udp port 8472 or udp port 51871 or esp or tcp port 5678'
```

6. **Terminal B** — generate one request:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

7. Read Terminal A's output. Look for the literal string `CKS-PLAINTEXT-CANARY` and for the packet headers around it.

**Questions**

- **Q1.1** Did the string `CKS-PLAINTEXT-CANARY` appear in the capture? What does that prove about the default Cilium data path?
- **Q1.2** Which transport protocol and port carried the request between the two nodes? What is that mechanism called?
- **Q1.3** The traffic was *encapsulated*. Explain in one sentence why encapsulation is not encryption.
- **Q1.4** Why did the exercise force `canary` and `probe` onto two different nodes with `nodeName`? What would a same-node test have shown once encryption is enabled?
- **Q1.5** Why does the sniffer need `hostNetwork: true` rather than just `NET_RAW` in the lab namespace?

---

## Exercise 2 — Enable Cilium transparent encryption with WireGuard

**Goal:** turn on the option the CKS curriculum actually names, and understand its blast radius.

1. Enable WireGuard encryption by upgrading the Cilium release. Reuse the existing values so you do not lose the kube-proxy replacement settings:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
```

2. Confirm the agent picked it up. Cilium 1.16+ ships the in-agent CLI as `cilium-dbg`; older versions use `cilium`:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i -A2 Encryption
```

Expected shape:

```
Encryption: Wireguard [NodeEncryption: Disabled, cilium_wg0 (Pubkey: <key>, Port: 51871, Peers: 2)]
```

3. Inspect the tunnel device and its peers on one node:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
kubectl -n enc-lab exec sniffer -- ip -d link show cilium_wg0
kubectl -n enc-lab exec sniffer -- wg show all 2>/dev/null || echo "wg tool not on host"
```

4. Confirm `Peers` equals the number of *other* nodes participating, and that every agent reports the same encryption type:

```bash
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -- cilium-dbg status | grep -i '^Encryption'
done
```

**Questions**

- **Q2.1** What network interface does Cilium create for WireGuard, and what UDP port does it use by default?
- **Q2.2** On a 3-node cluster, how many `Peers` should each agent report, and why is that number not 3?
- **Q2.3** `NodeEncryption: Disabled` appears in the status. What traffic is therefore still *not* encrypted, and which Helm value changes that?
- **Q2.4** You enabled encryption with `helm upgrade --reuse-values`. What breaks if you omit `--reuse-values` in this lab?
- **Q2.5** Cilium calls this "transparent" encryption. Transparent to whom — name the two things that did **not** have to change.

---

## Exercise 3 — Verify the encryption on the wire

**Goal:** never trust a status line. Prove it with packets.

1. **Terminal A** — repeat the exact capture from Exercise 1:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 30 tcpdump -ni any -A -s0 -l \
  'udp port 8472 or udp port 51871 or esp or tcp port 5678'
```

2. **Terminal B** — regenerate traffic:

```bash
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

3. Compare against the baseline. Then capture on the *inside* of the tunnel to see the same flow in the clear:

```bash
kubectl -n enc-lab exec sniffer -- \
  timeout 20 tcpdump -ni cilium_wg0 -A -s0 -l 'tcp port 5678'
```

Regenerate traffic in Terminal B while this runs.

4. Now do the negative test — same-node traffic. Schedule a second client on the **server's** node:

```bash
kubectl -n enc-lab run probe-local \
  --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeName":"enc-worker"}}' \
  -- sleep infinity

kubectl -n enc-lab wait --for=condition=Ready pod/probe-local --timeout=120s
```

Capture on the WireGuard device, then send the request:

```bash
# Terminal A
kubectl -n enc-lab exec sniffer -- timeout 20 tcpdump -ni cilium_wg0 -c 5 -A -s0

# Terminal B
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe-local -- curl -sS "http://$CANARY_IP:5678/"
```

5. Check the error counters, which is what you would grep in a real incident:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg statedb health | grep -i -E 'encrypt|wireguard' || true
```

**Questions**

- **Q3.1** In step 2, was `CKS-PLAINTEXT-CANARY` still visible? What did the cross-node packets look like instead?
- **Q3.2** In step 3 you captured on `cilium_wg0` and the plaintext reappeared. Why is that expected and not a security failure?
- **Q3.3** In step 4, did any packet appear on `cilium_wg0`? Explain the result in terms of where the encryption boundary sits.
- **Q3.4** A colleague concludes "Cilium WireGuard encrypts all pod-to-pod traffic in the cluster." Correct the statement precisely.
- **Q3.5** You need to *guarantee* that no unencrypted pod traffic can leave a node, not merely that encryption is available. Which Cilium feature addresses that, and what is its main operational risk?

---

## Exercise 4 — The IPsec alternative and key rotation

**Goal:** IPsec is the other Cilium transparent-encryption mode. The exam-relevant part is the key secret and its rotation rules.

1. Disable WireGuard and switch to IPsec. IPsec needs a pre-shared key secret **before** the agents restart:

```bash
kubectl create -n kube-system secret generic cilium-ipsec-keys \
  --from-literal=keys="3 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system get secret cilium-ipsec-keys -o jsonpath='{.data.keys}' | base64 -d
```

2. Reconfigure Cilium:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=ipsec

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s

kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i -A2 Encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

3. Verify on the wire. IPsec uses ESP, not a UDP tunnel port:

```bash
# Terminal A
kubectl -n enc-lab exec sniffer -- timeout 30 tcpdump -ni any -A -s0 -l 'esp or tcp port 5678'

# Terminal B
CANARY_IP=$(kubectl -n enc-lab get pod canary -o jsonpath='{.status.podIP}')
kubectl -n enc-lab exec probe -- curl -sS "http://$CANARY_IP:5678/"
```

4. Look at the kernel security associations that Cilium installed:

```bash
kubectl -n enc-lab exec sniffer -- ip xfrm state | head -30
kubectl -n enc-lab exec sniffer -- ip xfrm policy | head -20
```

5. Rotate the key. The rule is: **increment the key ID**, keep the same secret name, and let Cilium converge:

```bash
NEW_KEY="4 rfc4106(gcm(aes)) $(dd if=/dev/urandom count=20 bs=1 2>/dev/null | xxd -p -c 64) 128"

kubectl -n kube-system patch secret cilium-ipsec-keys \
  --type merge \
  -p "{\"stringData\":{\"keys\":\"$NEW_KEY\"}}"

sleep 20
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

6. Watch for decrypt errors during and after the rotation:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status | grep -i -E 'error|keys in use'
```

**Questions**

- **Q4.1** Decompose the key string `3 rfc4106(gcm(aes)) <hex> 128`. What is each of the four fields?
- **Q4.2** What is the valid range of the key ID, and what happens if you rotate past it?
- **Q4.3** Why must the key ID *change* on rotation instead of just the key material?
- **Q4.4** In step 3, which IP protocol carried the pod traffic, and what does `tcpdump` show for the payload?
- **Q4.5** Give one operational advantage of WireGuard over IPsec here, and one reason an organisation might still be required to choose IPsec.
- **Q4.6** Both modes are "transparent". What single thing do they both fail to protect that an application-layer mesh does protect?

---

## Exercise 5 — Install Istio and get a workload into the mesh

**Goal:** move up the stack. Cilium encrypts node-to-node; Istio mTLS encrypts and *authenticates* workload-to-workload.

1. Install Istio with the default profile:

```bash
istioctl install --set profile=default -y
kubectl -n istio-system get pods
istioctl version
```

2. Create two namespaces — one inside the mesh, one deliberately outside:

```bash
kubectl create ns mesh-a
kubectl create ns plain

kubectl label ns mesh-a istio-injection=enabled
kubectl get ns mesh-a plain --show-labels
```

3. Deploy the sample workloads. `httpbin` is the server inside the mesh; `sleep` is a client, deployed twice — once injected, once not:

```bash
kubectl -n mesh-a apply -f samples/httpbin/httpbin.yaml
kubectl -n mesh-a apply -f samples/sleep/sleep.yaml
kubectl -n plain  apply -f samples/sleep/sleep.yaml

kubectl -n mesh-a rollout status deploy/httpbin deploy/sleep --timeout=180s
kubectl -n plain  rollout status deploy/sleep --timeout=180s
```

4. Confirm injection by counting containers:

```bash
kubectl -n mesh-a get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl -n plain  get pods -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo
```

5. Establish the baseline: both clients can reach `httpbin` right now.

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a  -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "plain   -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

**Questions**

- **Q5.1** Which label enabled sidecar injection, and at which scope was it applied? Name the admission mechanism that acts on it.
- **Q5.2** Name the sidecar container and the init container you observed. What does the init container do to the pod's network namespace?
- **Q5.3** Both curls returned `200`. Since Istio is installed, is the `mesh-a → httpbin` call encrypted at this point? Justify your answer.
- **Q5.4** Why did applying the injection label to the namespace *after* creating it still work for these deployments, and what would you have to do if the pods had existed already?
- **Q5.5** The `plain` client succeeded. Which default Istio setting made that possible?

---

## Exercise 6 — Enforce mTLS with PeerAuthentication

**Goal:** the core Istio task. Go from opportunistic to enforced mutual TLS, and observe exactly what breaks.

1. Inspect the effective policy before changing anything:

```bash
kubectl get peerauthentication -A
istioctl x describe pod -n mesh-a $(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')
```

2. Apply **namespace-scoped** STRICT mTLS. The name `default` plus no `selector` is the idiom for namespace-wide:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: mesh-a
spec:
  mtls:
    mode: STRICT
EOF

kubectl -n mesh-a get peerauthentication default -o yaml
```

3. Re-run both clients and note the difference:

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a  -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -w "plain   -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

4. Prove the identities in use. Pull the workload certificate from the Envoy SDS store and decode it:

```bash
istioctl proxy-config secret deploy/sleep -n mesh-a

istioctl proxy-config secret deploy/sleep -n mesh-a -o json \
  | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep -E 'Issuer|Subject:|Not After|URI:|X509v3 Subject Alternative Name' -A1
```

5. Confirm handshakes are happening and nothing is failing:

```bash
POD=$(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

kubectl -n mesh-a exec "$POD" -c istio-proxy -- \
  pilot-agent request GET stats | grep -E 'ssl\.handshake|ssl\.connection_error|ssl\.fail'
```

6. Check what the inbound listener now requires:

```bash
istioctl proxy-config listener "$POD" -n mesh-a --port 15006 -o json \
  | grep -E 'requireClientCertificate|transport_socket|tlsMinimumProtocolVersion' | sort -u | head
```

**Questions**

- **Q6.1** What HTTP code or curl error did the `plain` client get, and at which layer was it rejected — Envoy, iptables, or the application?
- **Q6.2** Write out the SPIFFE identity of the `mesh-a` sleep workload in full. Which three pieces of Kubernetes metadata does it encode?
- **Q6.3** What is the certificate's validity period, who issues it, and which component rotates it?
- **Q6.4** Name the two other scopes a `PeerAuthentication` can target besides a single namespace, and state what makes each one distinct in the manifest.
- **Q6.5** `PeerAuthentication` at STRICT protects inbound traffic. Which resource governs whether the *client* offers a certificate, and what is the relevant field value?
- **Q6.6** Compare `PERMISSIVE` and `STRICT`. Why does a migration to STRICT normally pass through PERMISSIVE first?

---

## Exercise 7 — Exceptions, ordering, and the mistakes that cost marks

**Goal:** most exam failures on this topic are scope and precedence errors, not syntax errors.

1. Add a mesh-wide STRICT policy in the Istio root namespace, then observe how it interacts with the namespace policy:

```bash
cat <<'EOF' | kubectl apply -f -
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

2. Now carve out a legacy port. Suppose `httpbin` must accept plaintext on container port `80` only:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: httpbin-legacy-port
  namespace: mesh-a
spec:
  selector:
    matchLabels:
      app: httpbin
  mtls:
    mode: STRICT
  portLevelMtls:
    "80":
      mode: PERMISSIVE
EOF

kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "plain -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

3. Introduce a classic self-inflicted outage — a `DestinationRule` that disables client-side TLS against a STRICT server:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: httpbin-break
  namespace: mesh-a
spec:
  host: httpbin.mesh-a.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE
EOF

sleep 5
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

4. Diagnose it the way you would in the exam, then remove it:

```bash
istioctl analyze -n mesh-a
istioctl x describe pod -n mesh-a $(kubectl -n mesh-a get pod -l app=httpbin -o jsonpath='{.items[0].metadata.name}')

kubectl -n mesh-a delete destinationrule httpbin-break
sleep 5
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get
```

5. Restore a clean, correct end state: mesh-wide STRICT, no exceptions, no broken DestinationRule.

```bash
kubectl -n mesh-a delete peerauthentication httpbin-legacy-port
kubectl get peerauthentication -A
kubectl -n plain exec deploy/sleep -c sleep -- \
  curl -sS -w "plain -> %{http_code}\n" http://httpbin.mesh-a:8000/get || echo "rejected (expected)"
```

**Questions**

- **Q7.1** State the precedence order for `PeerAuthentication` when workload-, namespace- and mesh-level policies all exist. Where does `portLevelMtls` sit?
- **Q7.2** In step 2 the port-level exception was written for `"80"`, yet the client calls the service on port `8000`. Which port number does `portLevelMtls` match, and why does that distinction matter?
- **Q7.3** In step 3 the request failed even though both pods have sidecars and valid certificates. Explain the failure in one sentence.
- **Q7.4** What is the functional split between `PeerAuthentication` and `DestinationRule` for mTLS? Which is server-side and which is client-side?
- **Q7.5** You enable mesh-wide STRICT and a Prometheus server outside the mesh stops scraping application metrics. Name two ways to resolve it without weakening the policy globally.
- **Q7.6** After STRICT is enabled, why do kubelet HTTP liveness probes usually keep working without any change from you?
- **Q7.7** `PeerAuthentication` STRICT means "callers must present a valid mesh certificate". Which resource do you additionally need if the requirement is "only the `frontend` service account may call `httpbin`"?

---

## Exercise 8 — Choosing the right layer, and cleanup

**Goal:** consolidate. The exam may hand you a requirement and expect you to pick Cilium, Istio, or both.

1. Bring both layers up at once. Re-enable Cilium WireGuard while Istio STRICT is active:

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i '^Encryption'
```

2. Verify the mesh still works, and capture the doubly-protected traffic:

```bash
kubectl -n mesh-a exec deploy/sleep -c sleep -- \
  curl -sS -o /dev/null -w "mesh-a -> %{http_code}\n" http://httpbin.mesh-a:8000/get

kubectl -n enc-lab exec sniffer -- timeout 20 tcpdump -ni any -c 10 -A -s0 'udp port 51871'
```

3. Fill in this decision table from what you observed (write your answers before checking):

| Requirement | Cilium WireGuard/IPsec | Istio mTLS |
|---|---|---|
| Encrypt traffic between pods on **different** nodes | ? | ? |
| Encrypt traffic between pods on the **same** node | ? | ? |
| Authenticate the *calling workload* by cryptographic identity | ? | ? |
| Works for **non-HTTP/TCP-agnostic** protocols with no app change | ? | ? |
| Requires a sidecar or per-node proxy in the data path | ? | ? |
| Encrypt node-to-node control/host traffic | ? | ? |
| Per-request authorization decisions | ? | ? |

4. Tear the lab down:

```bash
kubectl delete ns enc-lab mesh-a plain --ignore-not-found
kubectl delete peerauthentication default -n istio-system --ignore-not-found
istioctl uninstall --purge -y
kubectl delete ns istio-system --ignore-not-found
kind delete cluster --name enc
```

**Questions**

- **Q8.1** With both layers on, how many times is the `sleep → httpbin` payload encrypted when the pods are on different nodes? On the same node?
- **Q8.2** Is running both layers redundant waste, or is there a defensible reason? Give the strongest argument for each side.
- **Q8.3** A requirement states: "all traffic between microservices must be encrypted **and** each service must prove its identity." Which layer alone satisfies this, and why does the other one not?
- **Q8.4** A requirement states: "encrypt everything leaving a node, including the kubelet and etcd client traffic, without touching any application." Which layer, and which specific setting?
- **Q8.5** You are asked to verify a claim of pod-to-pod encryption on a cluster you did not build. List, in order, the three checks you would run — one for Cilium, one for Istio, one on the wire.

---

## Answers

<details>
<summary>Click to reveal all answers</summary>

### Exercise 1

**A1.1** Yes — `CKS-PLAINTEXT-CANARY` is visible in the `-A` ASCII output. Cilium's default data path does **not** encrypt pod-to-pod traffic. A CNI plugin gives you connectivity and (optionally) policy; confidentiality is a separate, opt-in feature. Anyone with packet capture on the node, on a mirrored switch port, or on the underlay network reads your inter-pod traffic.

**A1.2** UDP port **8472** — VXLAN. That is Cilium's default tunnel routing mode: the inner pod-to-pod IP packet is wrapped in a VXLAN header and sent between node IPs. (If the cluster used native/direct routing you would see the pod packets unencapsulated instead — still cleartext.)

**A1.3** Encapsulation only changes the *addressing* wrapper so packets can be routed across the underlay; the original payload bytes are carried verbatim and any observer can strip the outer header and read them. Encryption changes the *bytes*.

**A1.4** Cilium's transparent encryption operates on traffic that leaves the node. Two pods on the same node communicate entirely inside the kernel's local data path and are never handed to the WireGuard or IPsec device. A same-node test would have shown plaintext even with encryption correctly enabled, leading you to conclude — wrongly — that the configuration failed.

**A1.5** The pod's own network namespace only shows that pod's `eth0`. The interfaces that matter — the physical NIC, `cilium_vxlan`, and later `cilium_wg0` — live in the **host** network namespace. `hostNetwork: true` puts the sniffer there; `privileged`/`NET_ADMIN`+`NET_RAW` then allow promiscuous capture. In a hardened cluster this pod spec is exactly what a Pod Security Standard at `baseline`/`restricted` is meant to block — note that you needed a privileged escape hatch to run it.

### Exercise 2

**A2.1** Interface `cilium_wg0`; UDP port **51871**.

**A2.2** **2** peers. WireGuard builds a full mesh of *remote* peers, so each agent lists every node except itself: 3 nodes → 2 peers each. If you see fewer, a node's agent has not converged or the WireGuard port is blocked between nodes.

**A2.3** Only pod-to-pod (and pod-to-remote-node-endpoint) traffic is encrypted. Traffic originating from the **host network namespace** — kubelet, host-network pods, node-level daemons, control-plane client traffic — is left in the clear. `--set encryption.nodeEncryption=true` extends WireGuard to that host-level traffic.

**A2.4** `helm upgrade` without `--reuse-values` resets unspecified values to chart defaults, so `kubeProxyReplacement=true`, `k8sServiceHost` and `k8sServicePort` would be dropped. In this kind cluster (built with `kubeProxyMode: none`) that removes service routing entirely and the cluster loses in-cluster service connectivity. Either pass `--reuse-values` or re-supply the full value set / a values file. A values file committed to git is the safer production habit.

**A2.5** Transparent to (1) the **application** — no library, TLS config, certificate, or code change; and (2) the **Kubernetes API objects** — no change to Deployments, Services, or pod specs. Encryption is negotiated between Cilium agents below the workload.

### Exercise 3

**A3.1** No, the canary string is gone. Cross-node traffic now appears as **UDP to port 51871** with an opaque encrypted payload. The VXLAN packets on 8472 disappear from view as such, because they are now carried inside the WireGuard tunnel.

**A3.2** `cilium_wg0` is the *pre-encryption* side of the tunnel — packets are handed to the device in the clear and encrypted on the way out to the physical NIC. Seeing plaintext there is exactly what a correctly functioning tunnel looks like. This is also a useful troubleshooting tool: plaintext on `cilium_wg0` plus ciphertext on the NIC confirms the full path.

**A3.3** No packets on `cilium_wg0`. Same-node pod-to-pod traffic is switched by the eBPF data path inside the kernel and never crosses the encryption boundary. The boundary is the **node**, not the pod. Security implication: if your threat model includes a compromised node or a co-located hostile pod, node-boundary encryption does nothing for you — you need workload-level mTLS.

**A3.4** Precisely: Cilium WireGuard encrypts pod-to-pod traffic **between different nodes**. Same-node pod traffic is not encrypted, and host-network traffic is not encrypted unless `nodeEncryption` is also enabled. It also does not authenticate the peer *workload* — only the peer *node*.

**A3.5** WireGuard **strict mode** (`encryption.strictMode.*`, with a pod CIDR and related flags; naming varies by Cilium version — check the docs for your release). It drops unencrypted traffic within the configured CIDR instead of allowing it to fall back to cleartext, closing the window during rollouts or partial configuration. The risk is exactly that: any node or endpoint that has not converged, or any legitimate flow inside the CIDR that cannot be encrypted, is **dropped** — it converts a confidentiality gap into an availability outage. Roll it out only after confirming full agent convergence.

### Exercise 4

**A4.1**
- `3` — the **key ID** (SPI-related identifier Cilium uses to select the key).
- `rfc4106(gcm(aes))` — the **cipher suite**: AES-GCM authenticated encryption as specified for ESP in RFC 4106.
- `<hex>` — the **key material**, 20 random bytes hex-encoded (16-byte key + 4-byte salt for AES-128-GCM).
- `128` — the **ICV / key length in bits** for the algorithm.

**A4.2** **1 to 15** (4 bits). When you reach 15, the next rotation wraps back to 1. You cannot use 0.

**A4.3** The key ID is what lets old and new keys coexist during the rollout. Agents pick up the new secret at slightly different times; with a new ID, a node still using the old key can be decrypted by the new key ID's peer because both SAs exist briefly. If you reused the ID, nodes would install a different key under the same identifier and in-flight traffic would fail to decrypt — you would see a spike in `XfrmInNoStates`/decrypt errors and dropped connections.

**A4.4** IP protocol **50 (ESP)** — `tcpdump` shows `ESP(spi=0x...,seq=...)` and no readable payload. There is no UDP tunnel port unless NAT traversal (UDP encapsulation) is in play.

**A4.5** WireGuard advantage: far simpler operationally — no pre-shared key secret to create, distribute, or rotate; keys are generated per node and exchanged automatically, and there is much less state to debug. IPsec may be mandated where a compliance regime requires a FIPS-validated cipher implementation or an approved standard-track protocol, or where existing network equipment/policy is built around ESP.

**A4.6** Neither authenticates the **workload identity** of the peer. Both authenticate *nodes*: any pod on a trusted node can talk to any pod on another trusted node, and the receiving side cannot cryptographically tell which service called it. Istio mTLS binds a certificate to a ServiceAccount, which is what makes identity-based authorization possible.

### Exercise 5

**A5.1** `istio-injection=enabled` on the **namespace**. It is acted on by a **MutatingAdmissionWebhook** (`istio-sidecar-injector`) that rewrites pod specs at creation time. Revision-based installs use `istio.io/rev=<revision>` instead, and a per-pod annotation/label (`sidecar.istio.io/inject`) can override the namespace setting.

**A5.2** Sidecar container: **`istio-proxy`** (Envoy plus `pilot-agent`). Init container: **`istio-init`** (or the `istio-cni` plugin when the CNI mode is installed). It programs iptables/nftables rules in the pod's network namespace that redirect all inbound traffic to Envoy on port **15006** and all outbound traffic to port **15001**, so the proxy is unavoidably in the path.

**A5.3** Almost certainly **yes** — but not *enforced*. Istio's default `PeerAuthentication` mode is `PERMISSIVE`, and Istio's automatic mTLS makes the client-side proxy prefer mTLS when the destination has a sidecar. So the sidecar-to-sidecar hop is encrypted opportunistically. The security problem is that it is not *required*: a plaintext caller is equally accepted, so an attacker simply declines to use TLS. Encryption that is optional is not a control.

**A5.4** Injection happens at **pod creation**, and the Deployments created their pods after the label was applied. If the pods already existed, they would carry no sidecar; you must restart them — `kubectl -n mesh-a rollout restart deploy/<name>` — to have the webhook re-mutate the new pods.

**A5.5** `PERMISSIVE` mTLS mode — the default. The server-side proxy accepts both mTLS and plaintext on the same port, which exists to allow incremental mesh migration without an outage.

### Exercise 6

**A6.1** curl fails with a transport error, typically `curl: (56) Recv failure: Connection reset by peer` and `%{http_code}` of `000`. The rejection happens in **Envoy** on the server pod: the inbound listener on 15006 now requires a client certificate, and the plaintext connection is reset during the TLS handshake. It is not an application response and not an iptables drop — the TCP connection is accepted and then torn down, which is why you get a reset rather than a timeout or a `403`.

**A6.2** `spiffe://cluster.local/ns/mesh-a/sa/sleep`. It encodes the **trust domain** (`cluster.local`), the **namespace** (`mesh-a`), and the **ServiceAccount** (`sleep`). It appears in the certificate's Subject Alternative Name as a URI SAN — the Subject DN itself is empty, which surprises people reading these certs for the first time.

**A6.3** Validity is short — on the order of **24 hours** by default. The issuer is the Istio CA (`istiod`, shown as `CN=cluster.local` or the configured root). `pilot-agent` inside the sidecar requests and rotates the certificate over the **SDS** (Secret Discovery Service) API well before expiry, so no secret is ever written to disk or stored as a Kubernetes Secret. That is why there is no cert to rotate manually and no key material for an attacker to steal from etcd.

**A6.4**
- **Mesh-wide**: the policy lives in the **Istio root namespace** (`istio-system` by default) and has **no `selector`**.
- **Workload-specific**: it lives in the workload's namespace and **has a `selector.matchLabels`** matching the target pods.

(A namespace-wide policy is the middle case: workload namespace, no selector. The conventional name `default` is a readability convention, not a functional requirement, except that only one mesh-wide/namespace-wide policy should exist per scope.)

**A6.5** `DestinationRule`, field `spec.trafficPolicy.tls.mode: ISTIO_MUTUAL`. In modern Istio you rarely write it — automatic mTLS handles the client side — but it is the resource that overrides client behaviour, and `mode: DISABLE` or `SIMPLE` there is a frequent cause of "STRICT broke my mesh".

**A6.6** `PERMISSIVE` accepts both mTLS and plaintext on the same port; `STRICT` accepts **only** mTLS. Migration goes through PERMISSIVE because sidecars are injected pod-by-pod over time: flipping straight to STRICT would break every caller that has not yet been injected or restarted. The correct sequence is: inject everywhere → confirm via `ssl.handshake` counters and telemetry that essentially all traffic is already mTLS → then set STRICT. PERMISSIVE is a migration state, never an end state.

### Exercise 7

**A7.1** Most specific wins: **workload-level** (with `selector`) overrides **namespace-level**, which overrides **mesh-level** (root namespace). `portLevelMtls` is more specific still — it overrides the `mtls.mode` of the very policy it appears in, for the listed ports only. Note the override is *not* a merge: the winning policy replaces the broader one wholesale, so a workload policy that omits a setting does not inherit it from the namespace policy.

**A7.2** `portLevelMtls` matches the **workload / container port** that the pod actually listens on, not the Service port. `httpbin` is exposed as Service port `8000` targeting container port `80`, so the exception written for `"80"` is the correct one and the plaintext call succeeds. Getting this backwards is a common exam trap: read `targetPort`, not `port`.

**A7.3** The client proxy was told to send **plaintext** to a destination whose proxy **requires** mTLS, so the handshake never happens and the connection is reset — a self-inflicted mismatch between the client-side `DestinationRule` and the server-side `PeerAuthentication`.

**A7.4** `PeerAuthentication` is **server-side**: it declares what inbound traffic a workload will accept. `DestinationRule.trafficPolicy.tls` is **client-side**: it declares what the caller's proxy will send. They must agree; `istioctl analyze` and `istioctl x describe pod` both flag the conflict explicitly.

**A7.5** Any two of:
- Add a **`portLevelMtls: PERMISSIVE`** exception for the metrics port on the scraped workloads.
- Bring Prometheus **into the mesh** (inject its sidecar) so it can present a certificate.
- Scrape via the sidecar's **merged metrics endpoint on port 15020**, which is exempt from mTLS enforcement.

The first is narrowest in blast radius; the second is the cleanest long-term.

**A7.6** The sidecar injector **rewrites HTTP probes** by default (`sidecar.istio.io/rewriteAppHTTPProbe`), pointing kubelet at `pilot-agent`'s health port (15021) which then probes the application locally. Since kubelet lives in the host network namespace and cannot do mesh mTLS, without this rewrite STRICT would fail every HTTP probe and CrashLoop the workload. Note the caveat: **exec** probes and probes on ports handled unusually may still need attention, and if you disable probe rewriting you must exclude the probe port yourself.

**A7.7** An **`AuthorizationPolicy`**. `PeerAuthentication` establishes *that* the caller has a verified mesh identity; `AuthorizationPolicy` decides *which* identities may do *what* — e.g. `rules[].from[].source.principals: ["cluster.local/ns/mesh-a/sa/frontend"]`. Authentication and authorization are separate resources, and an exam task naming a specific caller wants the second one.

### Exercise 8

**A8.1** **Twice** across nodes: Istio mTLS encrypts the payload sidecar-to-sidecar, and Cilium WireGuard encrypts the resulting packets node-to-node. That is why the capture on UDP 51871 is opaque even at the outer layer. On the **same node**: **once** — only the Istio mTLS layer applies, since Cilium's encryption boundary is not crossed.

**A8.2** *Against*: real CPU and MTU overhead for a second wrapping of data that is already authenticated-encrypted, plus two systems to debug when something breaks. *For*: they defend different boundaries. Istio mTLS covers only traffic that traverses sidecars — it leaves out non-meshed pods, host-network traffic, and anything that bypasses the proxy; Cilium encryption covers everything leaving the node regardless of mesh membership, including that residue. Defence in depth also means a misconfiguration in one layer (a stray `DestinationRule: DISABLE`) does not expose plaintext on the wire. In regulated environments this layering is often mandated.

**A8.3** **Istio mTLS**. Cilium's transparent encryption authenticates *nodes*, not workloads — the receiving pod has no cryptographic evidence of which service called it, so per-service identity requirements cannot be met and identity-based authorization is impossible. Istio issues a per-ServiceAccount SPIFFE certificate, which satisfies both halves of the requirement.

**A8.4** **Cilium**, with **`encryption.nodeEncryption=true`** alongside `encryption.enabled=true` and the chosen `encryption.type`. This extends encryption to host-network traffic, which no sidecar mesh can reach. Verify with `cilium-dbg status | grep Encryption` — `NodeEncryption` should read `Enabled`.

**A8.5** In order:
1. **Cilium**: `kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i Encryption` — check type, `NodeEncryption`, and peer count on *every* agent, not just one; then `cilium-dbg encrypt status` for error counters.
2. **Istio**: `kubectl get peerauthentication -A` to find every policy and its scope, checking for `PERMISSIVE`, `DISABLE`, and `portLevelMtls` exceptions; cross-check with `kubectl get destinationrule -A -o yaml | grep -A3 tls:` for client-side overrides, and `istioctl x describe pod <pod>` for the effective per-workload verdict.
3. **On the wire**: capture from a `hostNetwork` privileged pod on a node and confirm a known plaintext marker does **not** appear on the physical interface — and remember to run the test **across nodes**, because a same-node test proves nothing about Cilium's layer.

Configuration says what was intended; the capture says what is true. Do both.

</details>

---

## References

- CNCF CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Cilium — Transparent Encryption (WireGuard & IPsec) — https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — WireGuard Transparent Encryption — https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cilium — IPsec Transparent Encryption and key rotation — https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Cilium — Helm reference (`encryption.*`) — https://docs.cilium.io/en/stable/helm-reference/
- Cilium — CLI / `cilium-dbg` troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- WireGuard protocol overview — https://www.wireguard.com/protocol/
- RFC 4106 — The Use of Galois/Counter Mode (GCM) in IPsec ESP — https://www.rfc-editor.org/rfc/rfc4106
- RFC 4303 — IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303
- Istio — Mutual TLS Migration — https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/
- Istio — PeerAuthentication API reference — https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Authentication concepts and policy precedence — https://istio.io/latest/docs/concepts/security/#authentication
- Istio — DestinationRule TLS settings — https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — AuthorizationPolicy reference — https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Sidecar injection — https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — Health checking with mTLS (probe rewrite) — https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/
- Istio — Prometheus scraping with mTLS — https://istio.io/latest/docs/ops/integrations/prometheus/
- SPIFFE ID specification — https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE-ID.md
- kind — Configuration (`disableDefaultCNI`, `kubeProxyMode`) — https://kind.sigs.k8s.io/docs/user/configuration/