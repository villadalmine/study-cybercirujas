# Topic 3.3 — Configuring Egress Gateways for Cluster Exit Traffic: Guided Exercises

> **Exam weight:** 5.0%
> **What you will build:** a local 3-node cluster with Cilium (kube-proxy replacement + BPF masquerading), an "external" server that records the client source IP, and then:
> 1. An L3/L4 egress gateway with `CiliumEgressGatewayPolicy` that gives selected pods a fixed, predictable source IP.
> 2. An L7 egress gateway with Istio (`ServiceEntry` + `Gateway` + `VirtualService` + `DestinationRule`) that runs in `REGISTRY_ONLY` mode.
> 3. The combination used in production: Istio decides *what* may leave, Cilium decides *which IP* it leaves from, and a `NetworkPolicy` makes sure nothing can skip the gateway.
>
> **Reference sources:**
> - CKNE certification page — https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
> - Cilium Egress Gateway — https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
> - Cilium masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
> - Cilium kube-proxy replacement — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
> - Cilium on kind — https://docs.cilium.io/en/stable/installation/kind/
> - Istio Egress Gateways task — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
> - Istio Accessing External Services — https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
> - Kubernetes NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
> - kind configuration — https://kind.sigs.k8s.io/docs/user/configuration/

---

## Prerequisites

- `docker`, `kind` ≥ 0.23, `kubectl`, `helm` ≥ 3.14, `curl`
- About 8 GB of free RAM (Istio's demo profile plus three kind nodes)
- A Linux host, or a Linux VM. On Docker Desktop, adding an IP to a node container's interface (Part 2) behaves the same way, but the host can't route to the kind network.

---

## Part 0 — Lab Setup

### Step 0.1 — Create a cluster without a default CNI and without kube-proxy

```bash
mkdir -p ~/egw-lab && cd ~/egw-lab

cat > kind-egw.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: egw-lab
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

kind create cluster --config kind-egw.yaml
kubectl get nodes -o wide
```

Expected output (IPs will vary):

```
NAME                    STATUS     ROLES           AGE   VERSION   INTERNAL-IP   ...
egw-lab-control-plane   NotReady   control-plane   60s   v1.3x.x   172.18.0.3    ...
egw-lab-worker          NotReady   <none>          40s   v1.3x.x   172.18.0.2    ...
egw-lab-worker2         NotReady   <none>          40s   v1.3x.x   172.18.0.4    ...
```

Nodes stay `NotReady` because there is no CNI yet.

**Questions**

- **Q0.1.a** Why do we disable kube-proxy in this lab, instead of just installing Cilium alongside it?
- **Q0.1.b** Each kind "node" is a Docker container on the `kind` bridge network. From the point of view of the external server you will create in Step 0.3, what does a "node IP" look like?

### Step 0.2 — Install Cilium with the egress gateway enabled

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

# Leaving out --version installs the latest stable chart. In a real environment, pin it.
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=egw-lab-control-plane \
  --set k8sServicePort=6443 \
  --set bpf.masquerade=true \
  --set egressGateway.enabled=true \
  --set socketLB.hostNamespaceOnly=true \
  --set ipam.mode=kubernetes \
  --set image.pullPolicy=IfNotPresent

kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m
kubectl get nodes
```

Now check the datapath features the egress gateway depends on:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep -E 'KubeProxyReplacement|Masquerading|Routing'

kubectl -n kube-system get configmap cilium-config \
  -o jsonpath='{.data.enable-ipv4-egress-gateway}{"\n"}'
```

Expected output (similar to):

```
KubeProxyReplacement:    True   [eth0   172.18.0.2 ... (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
true
```

Define a helper you will reuse. It returns the Cilium agent pod running on a given node:

```bash
cilium_on() {
  kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector spec.nodeName="$1" -o name
}
cilium_on egw-lab-worker
```

**Questions**

- **Q0.2.a** Which two Cilium settings are hard prerequisites of the egress gateway, and why does the feature need each one?
- **Q0.2.b** Why do we set `socketLB.hostNamespaceOnly=true`? (Hint: Part 4 installs Istio sidecars.)
- **Q0.2.c** `kubectl exec ds/cilium` runs the command on *one* agent. Why is that a problem for egress gateway troubleshooting, and why does `cilium_on` fix it?

### Step 0.3 — Create an "external" server that logs client IPs

Nginx writes the TCP peer address as the first field of each access log line. That makes it an ideal witness for SNAT.

```bash
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

If the IPv4 subnet is not `172.18.0.0/16`, change the addresses below to match. The rest of the lab uses these variables:

```bash
export ECHO_IP=172.18.0.50        # "external" service A
export ECHO2_IP=172.18.0.51       # "external" service B
export EGRESS_IP=172.18.0.100     # stable egress IP we will own

docker run -d --name egw-echo  --network kind --ip "$ECHO_IP"  nginx:1.27
docker run -d --name egw-echo2 --network kind --ip "$ECHO2_IP" nginx:1.27
```

### Step 0.4 — Create client workloads

Both clients are pinned to `egw-lab-worker`, and **that node will not be the gateway.** This forces traffic to cross nodes, which is the interesting case.

```bash
cat > clients.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: egress-lab
---
apiVersion: v1
kind: Pod
metadata:
  name: client-a
  namespace: egress-lab
  labels:
    app: client
    egress: fixed-ip
spec:
  nodeName: egw-lab-worker
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-b
  namespace: egress-lab
  labels:
    app: client
spec:
  nodeName: egw-lab-worker
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep", "infinity"]
EOF

kubectl apply -f clients.yaml
kubectl -n egress-lab wait --for=condition=Ready pod --all --timeout=2m
kubectl -n egress-lab get pods -o wide
```

**Questions**

- **Q0.4.a** `client-a` and `client-b` differ by only one label. Which one, and what will it be used for?

---

## Part 1 — Baseline: How Pod Traffic Leaves the Cluster Without a Gateway

### Step 1.1 — Observe the default SNAT

```bash
kubectl -n egress-lab exec client-a -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
kubectl -n egress-lab exec client-b -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"

docker logs --tail 2 egw-echo 2>/dev/null
kubectl get node egw-lab-worker \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}'
```

Expected output:

```
200
200
172.18.0.2 - - [30/Sep/2026:10:01:12 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.10.1" "-"
172.18.0.2 - - [30/Sep/2026:10:01:13 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.10.1" "-"
172.18.0.2
```

### Step 1.2 — Find where the translation happens

```bash
kubectl -n egress-lab get pod client-a -o jsonpath='{.status.podIP}{"\n"}'

kubectl -n kube-system exec "$(cilium_on egw-lab-worker)" -c cilium-agent -- \
  cilium-dbg bpf nat list | grep "$ECHO_IP" | head -4
```

Look for a pair of entries: one `OUT` entry that maps `<podIP>:<port> -> 172.18.0.50:80` to `172.18.0.2:<port>`, and the matching `IN` entry for the reverse translation.

**Questions**

- **Q1.1.a** The server sees `172.18.0.2`, not the pod IP. Which component did the translation, and where does the state for the return traffic live?
- **Q1.1.b** Now imagine this cluster has 50 autoscaled nodes and the external service is a partner API with an IP allowlist. Explain why this baseline is operationally unacceptable.
- **Q1.1.c** Why can't the two clients be told apart by source IP in the log?

---

## Part 2 — L3/L4 Egress Gateway with `CiliumEgressGatewayPolicy`

### Step 2.1 — Prepare the gateway node

The egress IP must actually exist on an interface of the gateway node. The policy does **not** assign it for you. In a cloud this would be a secondary IP on an ENI or NIC; here we add it by hand.

```bash
docker exec egw-lab-worker2 ip addr add "$EGRESS_IP/16" dev eth0
docker exec egw-lab-worker2 ip -4 addr show dev eth0

kubectl label node egw-lab-worker2 egress-gateway=true
kubectl get nodes -L egress-gateway
```

**Questions**

- **Q2.1.a** What goes wrong at L2 if the IP is written in the policy but not configured on `egw-lab-worker2`'s interface, even if Cilium SNATs to it?
- **Q2.1.b** In production, why is it a bad idea to select the gateway node by `kubernetes.io/hostname`?

### Step 2.2 — Apply the policy

```bash
cat > cegp-fixed-ip.yaml <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-lab-fixed-ip
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: fixed-ip
        io.kubernetes.pod.namespace: egress-lab
  destinationCIDRs:
  - "172.18.0.50/32"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    egressIP: "172.18.0.100"
EOF

kubectl apply -f cegp-fixed-ip.yaml
kubectl get ciliumegressgatewaypolicies
```

Expected output:

```
NAME                  AGE
egress-lab-fixed-ip   5s
```

> If your subnet is different, change `172.18.0.50` and `172.18.0.100` in the manifest to your `$ECHO_IP` and `$EGRESS_IP`.

**Questions**

- **Q2.2.a** `CiliumEgressGatewayPolicy` has no `metadata.namespace`. What does that tell you about its scope, and how does the policy limit itself to `egress-lab` anyway?
- **Q2.2.b** Why are the values `"true"` and the CIDRs quoted in the YAML?

### Step 2.3 — Verify the source IP

```bash
kubectl -n egress-lab exec client-a -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
kubectl -n egress-lab exec client-b -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"

docker logs --tail 2 egw-echo 2>/dev/null | awk '{print $1, $7, $9}'
```

Expected output:

```
200
200
172.18.0.100 / 200
172.18.0.2 / 200
```

**Questions**

- **Q2.3.a** `client-a` runs on `egw-lab-worker`, yet the server sees `172.18.0.100`, an IP that lives on `egw-lab-worker2`. Describe the packet's path from the pod to the server, and the reply's path back.
- **Q2.3.b** Why is `client-b` unchanged?

### Step 2.4 — Inspect the datapath state

Run the same command on both nodes:

```bash
for n in egw-lab-worker egw-lab-worker2; do
  echo "=== $n"
  kubectl -n kube-system exec "$(cilium_on $n)" -c cilium-agent -- \
    cilium-dbg bpf egress list
done
kubectl -n egress-lab get pod client-a -o jsonpath='{.status.podIP}{"\n"}'
```

Expected output (similar to, and the exact columns depend on the Cilium version):

```
=== egw-lab-worker
Source IP     Destination CIDR   Egress IP   Gateway IP
10.244.1.37   172.18.0.50/32     0.0.0.0     172.18.0.4
=== egw-lab-worker2
Source IP     Destination CIDR   Egress IP      Gateway IP
10.244.1.37   172.18.0.50/32     172.18.0.100   172.18.0.4
```

Now prove that the policy follows *labels*, not pods:

```bash
kubectl -n egress-lab label pod client-b egress=fixed-ip
kubectl -n kube-system exec "$(cilium_on egw-lab-worker)" -c cilium-agent -- \
  cilium-dbg bpf egress list
kubectl -n egress-lab exec client-b -- curl -s -o /dev/null "http://$ECHO_IP/"
docker logs --tail 1 egw-echo 2>/dev/null | awk '{print $1}'

kubectl -n egress-lab label pod client-b egress-   # revert
```

**Questions**

- **Q2.4.a** The BPF map is keyed by *source pod IP + destination CIDR*, not by label. Who turns the label selector into IPs, and what happens when a matching pod is recreated with a new IP?
- **Q2.4.b** Why can the Egress IP column show `0.0.0.0` on the non-gateway node without breaking anything?
- **Q2.4.c** What is the "Gateway IP" column, and how does the client's node use it?

### Step 2.5 — Wider destinations with `excludedCIDRs`

Replace the policy with a whole-subnet version that exempts service B:

```bash
cat > cegp-fixed-ip.yaml <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-lab-fixed-ip
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: fixed-ip
        io.kubernetes.pod.namespace: egress-lab
  destinationCIDRs:
  - "172.18.0.0/16"
  excludedCIDRs:
  - "172.18.0.51/32"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    egressIP: "172.18.0.100"
EOF
kubectl apply -f cegp-fixed-ip.yaml

kubectl -n egress-lab exec client-a -- curl -s -o /dev/null "http://$ECHO_IP/"
kubectl -n egress-lab exec client-a -- curl -s -o /dev/null "http://$ECHO2_IP/"
echo "echo  -> $(docker logs --tail 1 egw-echo  2>/dev/null | awk '{print $1}')"
echo "echo2 -> $(docker logs --tail 1 egw-echo2 2>/dev/null | awk '{print $1}')"

# Check that in-cluster traffic is unaffected
kubectl -n egress-lab exec client-a -- \
  curl -s -o /dev/null -w '%{http_code}\n' -k https://kubernetes.default.svc/healthz

kubectl -n kube-system exec "$(cilium_on egw-lab-worker)" -c cilium-agent -- \
  cilium-dbg bpf egress list
```

Expected output:

```
echo  -> 172.18.0.100
echo2 -> 172.18.0.2
200
```

The egress list now has a second row for `172.18.0.51/32`, marked as excluded. Depending on the version, the Gateway IP column shows it as `0.0.0.1` or as an "Excluded CIDR" label.

**Questions**

- **Q2.5.a** `172.18.0.0/16` contains the node IPs, including the API server's node. Why does the `kubernetes.default.svc` request still work normally, and not get forced through the gateway?
- **Q2.5.b** When would you use `excludedCIDRs` in production instead of just listing narrower `destinationCIDRs`?

---

## Part 3 — Failure Modes and Troubleshooting

### Step 3.1 — The gateway node disappears

Simulate losing every node that matches the selector:

```bash
# Terminal 1: watch drops on the CLIENT's node
kubectl -n kube-system exec -it "$(cilium_on egw-lab-worker)" -c cilium-agent -- \
  cilium-dbg monitor --type drop

# Terminal 2
kubectl label node egw-lab-worker2 egress-gateway-
kubectl -n egress-lab exec client-a -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/" ; echo "exit=$?"
kubectl -n egress-lab exec client-b -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
```

Expected output: `client-a` times out (`000`, `exit=28`), while `client-b` still gets `200`. Terminal 1 shows drops from `client-a`'s IP with a reason similar to `No Egress Gateway found`.

Restore the label:

```bash
kubectl label node egw-lab-worker2 egress-gateway=true
kubectl -n egress-lab exec client-a -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
```

**Questions**

- **Q3.1.a** Why does Cilium *drop* the traffic instead of falling back to normal node masquerading? Argue it from the firewall-allowlist use case.
- **Q3.1.b** With one gateway per policy in open-source Cilium, the gateway node is a single point of failure. List two ways to reduce that risk.
- **Q3.1.c** Established TCP connections through the gateway are not preserved when the gateway changes. Why not? (Think about where the SNAT/conntrack state lives.)

### Step 3.2 — Troubleshooting drill

Break the setup on purpose. Remove the IP from the interface, but leave the label and the policy in place:

```bash
docker exec egw-lab-worker2 ip addr del "$EGRESS_IP/16" dev eth0
kubectl -n egress-lab exec client-a -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
kubectl -n kube-system logs "$(cilium_on egw-lab-worker2)" -c cilium-agent --since=2m \
  | grep -i egress | tail -5
```

Record what you observe. Then repair it:

```bash
docker exec egw-lab-worker2 ip addr add "$EGRESS_IP/16" dev eth0
kubectl -n egress-lab exec client-a -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
```

**Questions**

- **Q3.2.a** Write an ordered troubleshooting checklist for "the partner says our requests aren't coming from the allowlisted IP". Cover at least 6 checks, from control plane to wire.

---

## Part 4 — L7 Egress Gateway with Istio

The Cilium gateway answers *"which IP does this traffic leave from?"* An Istio egress gateway answers *"which external hosts may be reached, by whom, and with what L7 policy, TLS origination and telemetry?"*

### Step 4.1 — Install Istio in `REGISTRY_ONLY` mode

```bash
cd ~/egw-lab
curl -L https://istio.io/downloadIstio | sh -
cd istio-*/ && export PATH="$PWD/bin:$PATH" && cd ..

istioctl install -y \
  --set profile=demo \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY

kubectl -n istio-system get pods -o wide
kubectl -n istio-system get svc istio-egressgateway
```

Expected output: `istiod`, `istio-ingressgateway` and `istio-egressgateway` pods are `Running`. The `istio-egressgateway` Service is `ClusterIP` and exposes ports `80` and `443`.

**Questions**

- **Q4.1.a** What does `REGISTRY_ONLY` change compared with the default `ALLOW_ANY`, and which proxy enforces it?

### Step 4.2 — A meshed client and a baseline

```bash
cat > mesh-client.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-lab
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: Pod
metadata:
  name: sleep
  namespace: mesh-lab
  labels:
    app: sleep
spec:
  nodeName: egw-lab-worker
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep", "infinity"]
EOF
kubectl apply -f mesh-client.yaml
kubectl -n mesh-lab wait --for=condition=Ready pod/sleep --timeout=3m
kubectl -n mesh-lab get pod sleep -o jsonpath='{.spec.containers[*].name}{"\n"}'

kubectl -n mesh-lab exec sleep -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
```

Expected output:

```
curl istio-proxy
502
```

**Questions**

- **Q4.2.a** Why `502` and not a connection timeout? Who answered?

### Step 4.3 — Register the external service

The external host gets a name. `resolution: STATIC` with an explicit endpoint means no real DNS is needed.

```bash
cat > se-echo.yaml <<'EOF'
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: echo-external
  namespace: mesh-lab
spec:
  hosts:
  - echo.external.example
  location: MESH_EXTERNAL
  resolution: STATIC
  ports:
  - number: 80
    name: http
    protocol: HTTP
  endpoints:
  - address: "172.18.0.50"
EOF
kubectl apply -f se-echo.yaml

kubectl -n mesh-lab exec sleep -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve "echo.external.example:80:$ECHO_IP" http://echo.external.example/
docker logs --tail 1 egw-echo 2>/dev/null | awk '{print $1}'
```

Expected output:

```
200
172.18.0.2
```

**Questions**

- **Q4.3.a** What does `--resolve` do here, and why does the sidecar still route by *name*, even though curl connects to an IP?
- **Q4.3.b** Traffic now leaves **directly from the sidecar**, without going through the egress gateway. Which node IP shows up, and why?

### Step 4.4 — Route through the egress gateway

```bash
cat > egress-routing.yaml <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: mesh-lab
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - echo.external.example
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-echo
  namespace: mesh-lab
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: echo
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: echo-through-egress-gateway
  namespace: mesh-lab
spec:
  hosts:
  - echo.external.example
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: echo
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: echo.external.example
        port:
          number: 80
      weight: 100
EOF
kubectl apply -f egress-routing.yaml

kubectl -n mesh-lab exec sleep -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve "echo.external.example:80:$ECHO_IP" http://echo.external.example/

kubectl -n istio-system logs -l istio=egressgateway --tail 2
kubectl -n istio-system get pod -l istio=egressgateway -o wide
docker logs --tail 1 egw-echo 2>/dev/null | awk '{print $1}'
```

Expected output: `200`. The egress gateway access log shows a line similar to:

```
[2026-09-30T10:20:31.114Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 615 3 2 "10.244.1.52" "curl/8.10.1" "..." "echo.external.example" "172.18.0.50:80" outbound|80||echo.external.example 10.244.2.19:41522 10.244.2.19:8080 10.244.1.52:39170 - -
```

Nginx now shows the node IP of **whichever node runs the egress gateway pod**.

Use `istioctl` to look at the proxy's routes:

```bash
istioctl proxy-config routes sleep.mesh-lab --name 80 -o json \
  | grep -A3 '"echo.external.example'
istioctl proxy-config clusters -n istio-system deploy/istio-egressgateway \
  | grep echo.external.example
```

**Questions**

- **Q4.4.a** The `VirtualService` has two `match` blocks bound to two different gateways. Explain what each one does and which proxy executes it.
- **Q4.4.b** Why does the `DestinationRule` define a subset with no labels?
- **Q4.4.c** The server still sees a *node* IP. Which node's IP, and why is that still a problem for an allowlist?

---

## Part 5 — Making It Mandatory and Stable

An egress gateway that clients *can* skip only suggests a path; it doesn't enforce one. A pod without a sidecar, or one using `traffic.sidecar.istio.io/excludeOutboundIPRanges`, goes straight out.

### Step 5.1 — Show the bypass

```bash
cat > bypass.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: rogue
  namespace: mesh-lab
  labels:
    app: rogue
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  nodeName: egw-lab-worker
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep", "infinity"]
EOF
kubectl apply -f bypass.yaml
kubectl -n mesh-lab wait --for=condition=Ready pod/rogue --timeout=2m
kubectl -n mesh-lab exec rogue -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/"
```

Expected output: `200`. `REGISTRY_ONLY` didn't apply because no Envoy was in the path.

### Step 5.2 — Lock down egress at L3/L4

```bash
cat > np-egress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-only-via-mesh
  namespace: mesh-lab
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-system
EOF
kubectl apply -f np-egress.yaml

kubectl -n mesh-lab exec rogue -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$ECHO_IP/" ; echo "exit=$?"
kubectl -n mesh-lab exec sleep -c curl -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  --resolve "echo.external.example:80:$ECHO_IP" http://echo.external.example/
```

Expected output: `rogue` → `000` / `exit=28`. `sleep` → `200`.

**Questions**

- **Q5.2.a** Why does the meshed `sleep` pod still work, even though the policy allows no destination outside the cluster?
- **Q5.2.b** The policy allows *all* ports to `istio-system`. Which port(s) does the sidecar really need there, and how would you tighten the rule?
- **Q5.2.c** Who enforces this `NetworkPolicy` in this cluster?

### Step 5.3 — Give the Istio egress gateway a stable source IP

Point a Cilium egress policy at the Istio egress gateway pods:

```bash
cat > cegp-istio.yaml <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: istio-egressgateway-fixed-ip
spec:
  selectors:
  - podSelector:
      matchLabels:
        istio: egressgateway
        io.kubernetes.pod.namespace: istio-system
  destinationCIDRs:
  - "172.18.0.50/32"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    egressIP: "172.18.0.100"
EOF
kubectl apply -f cegp-istio.yaml

kubectl -n mesh-lab exec sleep -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  --resolve "echo.external.example:80:$ECHO_IP" http://echo.external.example/
docker logs --tail 1 egw-echo 2>/dev/null | awk '{print $1}'
```

Expected output:

```
200
172.18.0.100
```

Now scale the Istio egress gateway and repeat several times:

```bash
kubectl -n istio-system scale deploy/istio-egressgateway --replicas=3
kubectl -n istio-system rollout status deploy/istio-egressgateway
kubectl -n istio-system get pod -l istio=egressgateway -o wide
for i in 1 2 3 4 5 6; do
  kubectl -n mesh-lab exec sleep -c curl -- curl -s -o /dev/null \
    --resolve "echo.external.example:80:$ECHO_IP" http://echo.external.example/
done
docker logs --tail 6 egw-echo 2>/dev/null | awk '{print $1}' | sort | uniq -c
```

Expected output:

```
      6 172.18.0.100
```

**Questions**

- **Q5.3.a** Draw the full path of a request from `sleep` to the server, naming each hop and each address translation.
- **Q5.3.b** Why does this combination beat two alternatives: pinning the Istio egress gateway to a node with `nodeSelector`, or running it with `hostNetwork: true`?
- **Q5.3.c** Which layer would you use to allow `GET` but deny `POST` to the external host, and which layer would you use to prove to an auditor that no other IP ever reaches the partner?

---

## Part 6 — Design Challenge (no commands)

Your platform runs 3 clusters on AWS. A payment provider allowlists **at most 2 IPs** per customer. Only pods in namespace `payments` with label `pci=true` may call `api.payprovider.example:443`. Everything must be TLS end to end, and the security team wants an access log for every call.

**Questions**

- **Q6.a** Propose an architecture using the tools from this lab. State where TLS starts and ends, which resource enforces the host allowlist, which resource enforces the source IP, and how you would spend the 2-IP budget across 3 clusters.
- **Q6.b** Name two risks of your design and how you would monitor each one.

---

## Cleanup

```bash
kind delete cluster --name egw-lab
docker rm -f egw-echo egw-echo2
```

---

## Answers

<details>
<summary>Part 0 — Setup</summary>

**Q0.1.a** Cilium's egress gateway runs in the eBPF datapath, and it needs Cilium to own service translation and masquerading completely. With kube-proxy present, iptables rules would also rewrite and masquerade packets, and the two layers could conflict. The Cilium documentation lists kube-proxy replacement as a requirement of the feature.

**Q0.1.b** A node IP is an address on the `kind` Docker bridge (for example `172.18.0.2`). For the "external" nginx container, a node looks exactly like any other host on its LAN. That's why it's a good model of a real upstream firewall.

**Q0.2.a** `kubeProxyReplacement=true` and `bpf.masquerade=true`, plus `egressGateway.enabled=true` to turn the feature on.
- **BPF masquerading:** the egress gateway *is* a masquerading decision ("SNAT this flow to IP X on node Y instead of the local node IP"). It is built into the BPF SNAT engine, not iptables.
- **KPR:** makes sure service translation and the egress path are all handled in BPF. It is a stated prerequisite.

**Q0.2.b** With `socketLB.hostNamespaceOnly=true`, Cilium does socket-level service translation (connect-time DNAT) only for host-namespace processes, and leaves pod traffic to the tc/XDP layer. Otherwise an app's `connect()` to a ClusterIP would be rewritten to a backend pod IP *before* the Istio sidecar's iptables redirect sees it. Envoy would then see a pod IP instead of the service, and lose service-level routing. The Cilium docs recommend this setting for Istio.

**Q0.2.c** Egress gateway state is per node: the client's node holds the "send to gateway X" rule, and the gateway node holds the SNAT and conntrack entries. `ds/cilium` picks an arbitrary pod, so you might inspect the wrong node. `cilium_on` selects the agent with `spec.nodeName`.

**Q0.4.a** `egress: fixed-ip`. It's the label the `CiliumEgressGatewayPolicy` selects on. `client-b` is the control group.

</details>

<details>
<summary>Part 1 — Baseline</summary>

**Q1.1.a** The Cilium BPF masquerading program on `egw-lab-worker`'s `eth0` (the node where the pod runs). The pod is not in any cluster CIDR and the destination is outside the cluster, so the program SNATs the packet to the node's IP. The translation state is stored in the BPF NAT map (`cilium-dbg bpf nat list`) and the conntrack map *on that node*. Replies come back to that node and are reverse-translated there.

**Q1.1.b** Your source IP becomes "any of the 50 node IPs, and they change": autoscaling adds nodes, and node replacement renumbers them. The partner would have to allowlist a moving set, which in practice means allowlisting your whole VPC or NAT range. That is too broad, and you can't audit it per workload. You also can't tell which workload made a call, because every pod on a node shares one IP.

**Q1.1.c** Both pods are on the same node, so both are SNATed to the same node IP. Source IP carries node identity, not workload identity.

</details>

<details>
<summary>Part 2 — CiliumEgressGatewayPolicy</summary>

**Q2.1.a** The server (or the next-hop router) sends replies to `172.18.0.100` and has to ARP for it. If no interface owns the IP, nobody answers the ARP request, and the replies are lost. Depending on the version, the Cilium agent may also refuse to set up the gateway, because it resolves the egress interface from the IP. The IP must be *routable back to the gateway node*. In clouds, that means a secondary IP on the instance's ENI or NIC, or an Elastic IP associated with it.

**Q2.1.b** Hostnames are tied to one specific machine. When it is replaced (upgrade, autoscaling, failure), no node matches any more and the traffic is dropped. A role label (`egress-gateway=true`), applied by your provisioning tool or by a dedicated node group, survives node replacement. It also lets you make a tainted, dedicated gateway pool.

**Q2.2.a** It is a **cluster-scoped** resource: only cluster administrators create it, and a namespace tenant can't claim the company's egress IP. It limits itself to a namespace through the special label `io.kubernetes.pod.namespace`, which Cilium adds to every endpoint identity. Newer releases also support `namespaceSelector` in `selectors`.

**Q2.2.b** `"true"`: label values must be strings. Unquoted `true` is a YAML boolean, and the API server rejects it for a `map[string]string`. CIDRs and IPs: quoting isn't strictly required, but it keeps them unambiguously strings and avoids surprises with YAML tools.

**Q2.3.a** Outbound:
1. The pod sends to `172.18.0.50`.
2. The BPF program on `egw-lab-worker` matches (source IP = pod, destination in `172.18.0.50/32`) in the egress gateway map.
3. Instead of masquerading locally, it sends the packet **unmodified** (source is still the pod IP) through the VXLAN tunnel to the gateway node `172.18.0.4`.
4. On `egw-lab-worker2`, the packet leaves the tunnel, the BPF SNAT rewrites the source to `172.18.0.100`, and it goes out of `eth0`.

Return: nginx replies to `172.18.0.100`. The ARP lookup finds `egw-lab-worker2`, whose conntrack/NAT entry reverses the SNAT back to the pod IP. The packet is then tunneled back to `egw-lab-worker` and delivered to the pod.

**Q2.3.b** `client-b` has no `egress: fixed-ip` label, so its IP is not in the egress map and it gets normal local masquerading.

**Q2.4.a** The Cilium agent on each node watches `CiliumEgressGatewayPolicy`, the Cilium endpoint identities, and nodes. It computes the set of matching pod IPs and writes the (source IP, destination CIDR) → (egress IP, gateway IP) entries into the BPF map. When a pod is recreated, its new IP is added and the old one removed, which is why labels, not IPs, are the right abstraction. There is a short window between the pod starting and the map update. Traffic sent in that window can leave through the local node.

**Q2.4.b** Only the gateway node does the SNAT, so only it needs to know the egress IP. Other nodes only need to know *which gateway to tunnel to*. (Exact rendering depends on the version.)

**Q2.4.c** The node IP of the selected gateway (`egw-lab-worker2`). The client's node uses it as the tunnel endpoint for matching traffic.

**Q2.5.a** The egress gateway only applies to traffic whose destination is *outside the cluster* (the `world` identity). `kubernetes.default.svc` is translated to the API server endpoint. That endpoint is a node in the cluster (identity `kube-apiserver`/`remote-node`), so the rule doesn't apply and the packet takes the normal path. That's also why `0.0.0.0/0` is a common and safe `destinationCIDRs`.

**Q2.5.b** When the rule is "everything goes through the gateway **except** a few ranges". Examples: `0.0.0.0/0` except the corporate VPN range, or the cloud metadata endpoint `169.254.169.254/32`, or a VPC-internal database that allowlists the node subnet. Listing every allowed destination would be long and brittle, and one exclusion says the intent clearly.

</details>

<details>
<summary>Part 3 — Failure modes</summary>

**Q3.1.a** The policy promises "this traffic leaves from `172.18.0.100`". Silently falling back to a node IP would (1) fail anyway at the partner's firewall, but in a confusing way, and (2) leak traffic from an unexpected IP, which may break security or compliance assumptions ("regulated traffic only ever leaves from the egress IP"). Failing closed makes the problem obvious (`cilium-dbg monitor --type drop`) and keeps the guarantee.

**Q3.1.b** Any two of these:
1. A dedicated gateway node group with a role label, plus automation that re-attaches the egress IP (for example the Elastic IP/secondary IP) to the replacement node and relabels it.
2. A vendor feature with several gateways per policy and failover (for example the HA egress gateway in Isovalent Enterprise for Cilium, or the Calico Enterprise egress gateways).
3. Alerts on drop-reason counters and on "policy with zero matching nodes", so recovery is fast.
4. Splitting workloads across several policies/gateways to limit the blast radius.

**Q3.1.c** The SNAT mapping and conntrack entries live only in the BPF maps of the old gateway node. A new gateway has no state for the existing 5-tuples. And if the egress IP moves, the remote peer sees a different path mid-connection. Either way, established TCP sessions are reset or time out, and clients must reconnect. Design clients with retries.

**Q3.2.a** A reasonable order:
1. Does the policy exist with the expected selectors and CIDRs? (`kubectl get ciliumegressgatewaypolicies -o yaml`)
2. Does the pod really have the labels, and is it in the namespace the `io.kubernetes.pod.namespace` selector expects?
3. Does at least one node match `egressGateway.nodeSelector`? (`kubectl get nodes -l ...`)
4. Is the feature enabled, with its prerequisites? (`cilium-config` `enable-ipv4-egress-gateway`, KPR, BPF masquerade in `cilium-dbg status`)
5. Does the **client node's** `cilium-dbg bpf egress list` have an entry for the pod IP and the destination?
6. Is the egress IP configured on the gateway node's interface (`ip addr`), and can the peer route back to it (ARP/routes, cloud secondary IP)?
7. Do drops appear on the client node (`cilium-dbg monitor --type drop`), and do the agent logs on the gateway node show egress errors?
8. Capture on the gateway node (`tcpdump -ni eth0 host <dest>`) to see the real source IP on the wire.
9. Check whether an L7 `CiliumNetworkPolicy` also selects the pod. The docs say such traffic may be redirected to the L7 proxy and not use the egress gateway.

</details>

<details>
<summary>Part 4 — Istio egress gateway</summary>

**Q4.1.a** With `ALLOW_ANY`, a sidecar forwards traffic to unknown destinations through `PassthroughCluster`. With `REGISTRY_ONLY`, only hosts in the mesh service registry (Kubernetes services plus `ServiceEntry` hosts) are reachable. Everything else goes to `BlackHoleCluster`. The **client's sidecar Envoy** enforces it, so it only applies to traffic that passes through a sidecar.

**Q4.2.a** The sidecar intercepted the connection (iptables redirect) and accepted it. It parsed the HTTP request, found no route for host `172.18.0.50`, and answered with `502` itself. The packet never left the pod network namespace.

**Q4.3.a** `--resolve` makes curl connect to `172.18.0.50:80` but send `Host: echo.external.example`. The sidecar's port-80 outbound listener is an HTTP listener that picks routes by the `Host`/`:authority` header, so it matches the `ServiceEntry` host. It then sends the request to that host's cluster, whose STATIC endpoint is `172.18.0.50`. In production you would rely on real DNS, or on Istio DNS proxying, instead.

**Q4.3.b** The IP of `egw-lab-worker`, the node that runs `sleep`. The sidecar opened the upstream connection from the pod's network namespace, so Cilium masqueraded it locally, exactly as in Part 1.

**Q4.4.a**
- The first match (`gateways: [mesh]`) runs in **every sidecar**: requests to `echo.external.example:80` are sent to the `istio-egressgateway` service, using the `echo` subset.
- The second match (`gateways: [istio-egressgateway]`) runs in the **egress gateway Envoy**: requests arriving on its port-80 server for that host are forwarded to the real external host (the `ServiceEntry` cluster).

Together they make the two-hop path sidecar → egress gateway → external.

**Q4.4.b** The subset names a routing target. You can later attach a traffic policy to it (for example `tls: mode: ISTIO_MUTUAL` with `sni: echo.external.example`, to secure the sidecar-to-gateway hop) without affecting other traffic to the egress gateway. It doesn't need labels because every egress gateway pod qualifies. This is the pattern the Istio egress gateway task uses.

**Q4.4.c** The IP of the node running the egress gateway pod. That pod is a normal pod, so its upstream traffic is masqueraded to its node's IP. If the pod is rescheduled or scaled across nodes, the IP changes. An allowlist problem remains: Istio centralizes the *policy*, but not the *address*.

</details>

<details>
<summary>Part 5 — Enforcement and stable IP</summary>

**Q5.2.a** With the sidecar, the pod's actual packets go to the **egress gateway pod IP** (in `istio-system`, which the policy allows) and to istiod. The external connection is opened by the egress gateway pod, which is in another namespace and isn't selected by this policy. The `rogue` pod has no sidecar, so it tries to reach `172.18.0.50` directly, which is not allowed.

**Q5.2.b** The sidecar needs istiod xDS/CA on `15012/TCP`. It also needs the egress gateway's container ports, which the Service translates to: `8080` for HTTP and `8443` for HTTPS in the default gateway charts. `NetworkPolicy` is evaluated after service translation, so you list target ports, not service ports. To tighten it, split the rule into two: `podSelector: {app: istiod}` with port `15012`, and `podSelector: {istio: egressgateway}` with ports `8080`/`8443`.

**Q5.2.c** Cilium. It implements the standard `networking.k8s.io/v1` `NetworkPolicy` in eBPF (as well as its own `CiliumNetworkPolicy`).

**Q5.3.a**
1. `sleep` app → (iptables redirect) → the sidecar Envoy in the same pod.
2. The sidecar → the egress gateway pod IP. The ClusterIP is translated by Cilium; it may cross nodes over VXLAN, and the source is still the `sleep` pod IP. Optionally this hop uses mTLS.
3. The egress gateway Envoy → opens a new connection to `172.18.0.50:80`, with the egress gateway pod IP as its source.
4. Cilium on the egress gateway pod's node matches the `CiliumEgressGatewayPolicy` and tunnels the packet to `egw-lab-worker2` (unless it's already there).
5. `egw-lab-worker2` SNATs the packet to `172.18.0.100` and sends it out of `eth0` to nginx.

Replies retrace the path using the conntrack state on the gateway node and on the egress gateway pod.

**Q5.3.b**
- **Pinning with `nodeSelector`:** couples L7 capacity and availability to one node, and you still inherit that node's IP (which changes on replacement).
- **`hostNetwork`:** gives up pod isolation, causes port conflicts, and bypasses much of the CNI policy. You still get the node IP.

The combination separates the concerns. The Istio egress gateway can scale to N replicas on any nodes, and the stable IP is a separate, admin-owned construct in the datapath. You can move it to a hardened gateway node pool without touching the mesh.

**Q5.3.c**
- **Method filtering:** Istio L7. For example, a `VirtualService` match on `method`, or an `AuthorizationPolicy` on the egress gateway with `to.operation.methods`.
- **Proof for the auditor:** the L3 evidence. The partner firewall sees one source IP (Cilium egress gateway), non-mesh bypass is blocked (`NetworkPolicy` default-deny egress), and there are egress gateway access logs and Cilium flow logs (Hubble) to show it.

</details>

<details>
<summary>Part 6 — Design challenge</summary>

**Q6.a** One reference design:
- **Identity and scope:** `payments` pods with `pci=true` get sidecars. A `NetworkPolicy` in `payments` defaults to deny egress, and allows only DNS and `istio-system` (istiod port 15012, egress gateway target ports).
- **Host allowlist:** a `ServiceEntry` for `api.payprovider.example:443` (`location: MESH_EXTERNAL`, `resolution: DNS`), with `REGISTRY_ONLY` mesh-wide. There is a dedicated egress gateway, a `Gateway` + `VirtualService` pair as in Part 4, and an `AuthorizationPolicy` on the egress gateway that allows only principals from the `payments` service account.
- **TLS:** either (a) the app does TLS end to end, and the egress gateway routes by SNI in `PASSTHROUGH` mode (no L7 visibility, but true end-to-end TLS), or (b) the sidecar-to-gateway hop uses `ISTIO_MUTUAL` and the gateway does TLS origination to the provider (`DestinationRule` with `tls.mode: SIMPLE` and `sni`), which gives full L7 access logs. The "every call logged" requirement points to (b), if the security team accepts TLS termination at the gateway. Otherwise use (a), and log SNI and connection metadata instead.
- **Source IP:** a `CiliumEgressGatewayPolicy` selecting the egress gateway pods, with a dedicated, tainted gateway node group and an Elastic IP on its ENI.
- **2-IP budget across 3 clusters:** don't give each cluster its own IP. Either route all three clusters' provider traffic through one shared egress point (for example a central egress VPC with a NAT gateway or proxy using 1 EIP, keeping the second for failover), or pick 2 clusters as egress-capable and have the third reach the provider through them (for example Istio multi-cluster routing to a remote egress gateway). Keep the spare IP attached to a standby gateway node, so failover doesn't need a change at the provider.

**Q6.b** Any two of these:
- **Gateway node failure** (traffic fails closed). Monitor drop counters with reason "no egress gateway" (Hubble/Cilium metrics), nodes matching the selector going to zero, and synthetic probes to the provider every minute.
- **Egress IP drift** (EIP detached or reassigned). Run a periodic probe to an IP-echo endpoint and compare the result with the expected IP, plus a cloud config drift check.
- **Bypass through a misconfigured namespace.** Audit that every namespace has default-deny egress (policy-as-code: Kyverno/Gatekeeper), and alert on Hubble flows to `world` that don't come from the egress gateway identity.
- **Certificate or SNI mismatch with TLS origination.** Monitor the egress gateway's `upstream_cx_connect_fail` and TLS handshake error stats.

</details>