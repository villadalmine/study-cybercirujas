# Guided Exercises — 3.2 Implementing Routing to Expose Networks

> **Exam:** CKNE · **Domain 3 — Advanced Traffic Management** · **Weight:** 5%
>
> **Goal:** make pod CIDRs and `LoadBalancer` Service IPs reachable from a network outside the cluster by advertising them over BGP. You will peer Kubernetes nodes with an upstream router, choose what gets advertised, check the result on both sides of the session, and fix the failures you are most likely to see in production.

**References (official sources):**

- CNCF / Linux Foundation — CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cilium — BGP Control Plane (v2 resources): https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-v2/
- Cilium — BGP Control Plane operation and troubleshooting: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/
- Cilium — LoadBalancer IP Address Management (LB IPAM): https://docs.cilium.io/en/stable/network/lb-ipam/
- Cilium — Native routing: https://docs.cilium.io/en/stable/network/concepts/routing/#native-routing
- Kubernetes — Service type `LoadBalancer`: https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer
- Kubernetes — External traffic policy: https://kubernetes.io/docs/reference/networking/virtual-ips/#external-traffic-policy
- FRRouting — BGP documentation: https://docs.frrouting.org/en/latest/bgp.html
- MetalLB — BGP mode concepts (an alternative implementation): https://metallb.io/concepts/bgp/
- kind — cluster configuration: https://kind.sigs.k8s.io/docs/user/configuration/
- RFC 8212 (eBGP default route propagation behavior): https://www.rfc-editor.org/rfc/rfc8212
- RFC 1997 (BGP communities): https://www.rfc-editor.org/rfc/rfc1997

---

## Lab topology

```
                    ┌───────────────────────────────┐
                    │  tor (FRR)  AS 65000          │
                    │  172.18.0.100                 │
                    │  bgp listen range 172.18/16   │
                    └──────┬─────────────────┬──────┘
                    eBGP   │                 │   eBGP
             ┌─────────────┴───┐     ┌───────┴─────────┐
             │ ckne-bgp-worker │     │ ckne-bgp-worker2│   AS 65001
             │ podCIDR 10.244.x│     │ podCIDR 10.244.y│   (Cilium BGP CP)
             └─────────────────┘     └─────────────────┘
             ┌──────────────────────────┐
             │ ckne-bgp-control-plane   │   not labeled → no BGP instance
             └──────────────────────────┘

  Advertised prefixes:  PodCIDR per node  +  LoadBalancer IPs from 10.100.100.10-50
```

The LB IPs (`10.100.100.0/24`) do not belong to any L2 segment. They are reachable **only** because the nodes advertise them over BGP. That is the main difference from L2/ARP announcements.

**Prerequisites:** `docker`, `kind` ≥ 0.24, `kubectl`, `helm` ≥ 3.14, `cilium` CLI ≥ 0.16. The lab uses the Cilium `cilium.io/v2` BGP resources (`CiliumBGPClusterConfig`, `CiliumBGPPeerConfig`, `CiliumBGPAdvertisement`), which are available from Cilium 1.18 onward. The older `CiliumBGPPeeringPolicy` (v1) API is deprecated. Do not use it for new designs.

---

## Exercise 1 — Build a cluster without a CNI or kube-proxy

1. Create the kind configuration:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ckne-bgp
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

Save it as `kind-bgp.yaml` and create the cluster:

```bash
kind create cluster --config kind-bgp.yaml
kubectl get nodes -o wide
```

Expected output (abridged). The nodes are `NotReady` because there is no CNI yet:

```
NAME                     STATUS     ROLES           INTERNAL-IP
ckne-bgp-control-plane   NotReady   control-plane   172.18.0.2
ckne-bgp-worker          NotReady   <none>          172.18.0.3
ckne-bgp-worker2         NotReady   <none>          172.18.0.4
```

2. Record the Docker subnet and each node's pod CIDR:

```bash
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
```

```
172.18.0.0/16 fc00:f853:ccd:e793::/64
NAME                     PODCIDR
ckne-bgp-control-plane   10.244.0.0/24
ckne-bgp-worker          10.244.1.0/24
ckne-bgp-worker2         10.244.2.0/24
```

> If your IPv4 subnet is not `172.18.0.0/16`, replace `172.18.0.x` with your subnet everywhere in this lab.

**Questions**

- **Q1.1** Who assigned `spec.podCIDR` to each node, and which flag controls the size of each block?
- **Q1.2** Why is `kubeProxyMode: none` required before Cilium can handle `LoadBalancer` IPs that arrive from outside the cluster?

---

## Exercise 2 — Install Cilium with native routing and the BGP Control Plane

1. Install Cilium:

```bash
helm repo add cilium https://helm.cilium.io && helm repo update
CILIUM_VERSION=1.18.3

helm install cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=ckne-bgp-control-plane \
  --set k8sServicePort=6443 \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
  --set autoDirectNodeRoutes=true \
  --set ipam.mode=kubernetes \
  --set bpf.masquerade=true \
  --set bgpControlPlane.enabled=true

cilium status --wait
```

2. Confirm that the BGP Control Plane is enabled and its CRDs exist:

```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-bgp-control-plane}{"\n"}'
kubectl get crd | grep -E 'ciliumbgp|ciliumloadbalancerippools'
```

```
true
ciliumbgpadvertisements.cilium.io
ciliumbgpclusterconfigs.cilium.io
ciliumbgpnodeconfigoverrides.cilium.io
ciliumbgpnodeconfigs.cilium.io
ciliumbgppeerconfigs.cilium.io
ciliumloadbalancerippools.cilium.io
```

3. Check how the nodes reach each other's pod CIDRs **inside** the cluster:

```bash
docker exec ckne-bgp-worker ip route | grep 10.244
```

```
10.244.0.0/24 via 172.18.0.2 dev eth0 proto kernel
10.244.1.0/24 via 10.244.1.x dev cilium_host proto kernel src 10.244.1.x
10.244.2.0/24 via 172.18.0.4 dev eth0 proto kernel
```

**Questions**

- **Q2.1** `autoDirectNodeRoutes=true` already gives the nodes routes to each other's pod CIDRs. Why is BGP still needed?
- **Q2.2** What does `ipv4NativeRoutingCIDR` control? What happens to traffic from a pod to a destination outside that CIDR?
- **Q2.3** Why is `routingMode=native` a prerequisite for exposing pod IPs to an external router in a meaningful way? What would the router see with VXLAN tunneling?

---

## Exercise 3 — Deploy the upstream router (FRR)

1. Prepare the FRR configuration:

```bash
mkdir -p frr && cd frr

cat > daemons <<'EOF'
zebra=yes
bgpd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
EOF

cat > frr.conf <<'EOF'
frr defaults traditional
hostname tor
log stdout
!
router bgp 65000
 bgp router-id 172.18.0.100
 no bgp ebgp-requires-policy
 neighbor K8S peer-group
 neighbor K8S remote-as 65001
 bgp listen range 172.18.0.0/16 peer-group K8S
 !
 address-family ipv4 unicast
  maximum-paths 8
 exit-address-family
!
EOF

touch vtysh.conf
cd ..
```

2. Start the router on the `kind` network with a fixed IP:

```bash
docker run -d --name tor --privileged --network kind --ip 172.18.0.100 \
  -v "$PWD/frr:/etc/frr" quay.io/frrouting/frr:10.2.1

docker exec tor vtysh -c 'show bgp summary'
```

```
IPv4 Unicast Summary:
BGP router identifier 172.18.0.100, local AS number 65000 VRF default vrf-id 0
...
% No BGP neighbors found in VRF default
```

**Questions**

- **Q3.1** `bgp listen range` creates *dynamic neighbors*. Which side opens the TCP/179 connection, and why does that suit Kubernetes nodes?
- **Q3.2** What does `maximum-paths 8` change in the router's RIB/FIB, and what would happen to `LoadBalancer` traffic without it?
- **Q3.3** Why do nodes and router use different ASNs (eBGP) here, rather than one iBGP AS?

---

## Exercise 4 — Establish the BGP sessions

1. Mark the nodes that will peer:

```bash
kubectl label nodes ckne-bgp-worker ckne-bgp-worker2 bgp=enabled
```

2. Create the peer profile and the cluster configuration:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer
spec:
  timers:
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
    connectRetryTimeSeconds: 5
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 30
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: bgp
---
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: ckne-bgp
spec:
  nodeSelector:
    matchLabels:
      bgp: enabled
  bgpInstances:
    - name: instance-65001
      localASN: 65001
      peers:
        - name: tor
          peerASN: 65000
          peerAddress: 172.18.0.100
          peerConfigRef:
            name: tor-peer
```

```bash
kubectl apply -f bgp-peering.yaml
```

3. Check the sessions from the cluster side:

```bash
cilium bgp peers
```

```
Node               Local AS   Peer AS   Peer Address   Session State   Uptime   Family         Received   Advertised
ckne-bgp-worker    65001      65000     172.18.0.100   established     15s      ipv4/unicast   0          0
ckne-bgp-worker2   65001      65000     172.18.0.100   established     15s      ipv4/unicast   0          0
```

4. Check them from the router side:

```bash
docker exec tor vtysh -c 'show bgp summary'
```

```
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
*172.18.0.3     4      65001         8         8        0    0    0 00:00:20            0        0 N/A
*172.18.0.4     4      65001         8         8        0    0    0 00:00:20            0        0 N/A

Total number of neighbors 2
* - dynamic neighbor
2 dynamic neighbor(s), limit 100
```

5. Look at the per-node resource that the operator generated:

```bash
kubectl get ciliumbgpnodeconfigs
kubectl get ciliumbgpnodeconfig ckne-bgp-worker -o jsonpath='{.status.bgpInstances[0].peers[0]}{"\n"}' | jq .
```

**Questions**

- **Q4.1** The sessions are `established` but `Advertised` is `0`. Explain why, based on how `CiliumBGPPeerConfig` and `CiliumBGPAdvertisement` relate to each other.
- **Q4.2** How many `CiliumBGPNodeConfig` objects exist, and why is there none for `ckne-bgp-control-plane`?
- **Q4.3** What do `holdTimeSeconds: 9` / `keepAliveTimeSeconds: 3` buy you, and what does very aggressive tuning cost on a large cluster?
- **Q4.4** With graceful restart enabled, what happens to routes on the router when you restart the Cilium agent on one node?

---

## Exercise 5 — Advertise the pod CIDRs

1. Create the advertisement. The label must match the selector in `tor-peer`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: k8s-routes
  labels:
    advertise: bgp
spec:
  advertisements:
    - advertisementType: PodCIDR
```

```bash
kubectl apply -f bgp-adv.yaml
cilium bgp routes advertised ipv4 unicast
```

```
Node               VRouter   Peer           Prefix          NextHop      Age   Attrs
ckne-bgp-worker    65001     172.18.0.100   10.244.1.0/24   172.18.0.3   5s    [{Origin: i} {AsPath: 65001} {Nexthop: 172.18.0.3}]
ckne-bgp-worker2   65001     172.18.0.100   10.244.2.0/24   172.18.0.4   5s    [{Origin: i} {AsPath: 65001} {Nexthop: 172.18.0.4}]
```

2. Confirm that the router learned and installed the routes:

```bash
docker exec tor vtysh -c 'show ip bgp'
docker exec tor ip route | grep bgp
```

```
   Network          Next Hop            Metric LocPrf Weight Path
*> 10.244.1.0/24    172.18.0.3                             0 65001 i
*> 10.244.2.0/24    172.18.0.4                             0 65001 i
```

```
10.244.1.0/24 nhid 20 via 172.18.0.3 dev eth0 proto bgp metric 20
10.244.2.0/24 nhid 21 via 172.18.0.4 dev eth0 proto bgp metric 20
```

3. Deploy a workload and reach a pod **directly by its IP** from outside the cluster:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: agnhost
          image: registry.k8s.io/e2e-test-images/agnhost:2.52
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
```

```bash
kubectl apply -f web.yaml
kubectl rollout status deploy/web
kubectl get pods -l app=web -o wide

POD_IP=$(kubectl get pods -l app=web -o jsonpath='{.items[0].status.podIP}')
docker run --rm --network container:tor nicolaka/netshoot curl -s "http://${POD_IP}:8080/hostname"; echo
docker run --rm --network container:tor nicolaka/netshoot curl -s "http://${POD_IP}:8080/clientip"; echo
```

```
web-6d8f7c9b8d-4kq2x
172.18.0.100:51234
```

4. Check whether the Cilium nodes installed any route received from the router:

```bash
cilium bgp routes available ipv4 unicast
docker exec ckne-bgp-worker ip route | grep -c bgp
```

**Questions**

- **Q5.1** Why is `10.244.0.0/24` (the control plane's CIDR) not advertised? Which pods become unreachable from outside, and how would you fix it?
- **Q5.2** `/clientip` returned `172.18.0.100`, the router's real IP. Why is the source not SNATed, even with `bpf.masquerade=true`?
- **Q5.3** Does Cilium program into the node kernel the routes it *receives* over BGP? What does that mean for designs that expect nodes to learn a default route from the ToR?
- **Q5.4** In which mode of `ipam.mode` could each node advertise **more than one** prefix, and why?

---

## Exercise 6 — Expose `LoadBalancer` Services with LB IPAM and BGP

1. Create an IP pool that only serves Services labeled `bgp: public`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: public-pool
spec:
  blocks:
    - start: "10.100.100.10"
      stop: "10.100.100.50"
  serviceSelector:
    matchLabels:
      bgp: public
```

2. Extend the advertisement to announce `LoadBalancer` IPs as well. Replace the `k8s-routes` object:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: k8s-routes
  labels:
    advertise: bgp
spec:
  advertisements:
    - advertisementType: PodCIDR
    - advertisementType: Service
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          bgp: public
      attributes:
        communities:
          standard:
            - "65001:100"
```

3. Create the Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-lb
  labels:
    bgp: public
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

```bash
kubectl apply -f pool.yaml -f bgp-adv.yaml -f web-lb.yaml
kubectl get svc web-lb
```

```
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
web-lb   LoadBalancer   10.96.143.21   10.100.100.10   80:31544/TCP   4s
```

4. Check the /32 advertisement, the ECMP route, and the community on the router:

```bash
LB_IP=$(kubectl get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
docker exec tor vtysh -c "show bgp ipv4 unicast ${LB_IP}/32"
docker exec tor ip route show "${LB_IP}"
```

```
BGP routing table entry for 10.100.100.10/32, version 5
Paths: (2 available, best #1, table default)
  65001
    172.18.0.3 from 172.18.0.3 (172.18.0.3)
      Origin IGP, valid, external, multipath, best (Router ID)
      Community: 65001:100
  65001
    172.18.0.4 from 172.18.0.4 (172.18.0.4)
      Origin IGP, valid, external, multipath
      Community: 65001:100
```

```
10.100.100.10 nhid 30 proto bgp metric 20
	nexthop via 172.18.0.3 dev eth0 weight 1
	nexthop via 172.18.0.4 dev eth0 weight 1
```

5. Consume the Service from outside:

```bash
for i in $(seq 1 6); do
  docker run --rm --network container:tor nicolaka/netshoot curl -s "http://${LB_IP}/hostname"; echo
done
```

6. Create a second `LoadBalancer` Service **without** the `bgp: public` label and compare:

```bash
kubectl expose deploy web --name web-internal --type LoadBalancer --port 80 --target-port 8080
kubectl get svc web-internal
kubectl get svc web-internal -o jsonpath='{.status.conditions}' | jq .
```

**Questions**

- **Q6.1** Why is the advertised prefix a `/32` rather than the pool's range? What is the trade-off compared to advertising an aggregate?
- **Q6.2** `web-internal` stays `<pending>`. Which of the two selectors (pool or advertisement) causes that, and what would happen if only the other one excluded it?
- **Q6.3** How would you request a specific IP (`10.100.100.42`) for a Service using LB IPAM?
- **Q6.4** What is the Linux kernel's default ECMP hash for IPv4, and how do you make distribution depend on L4 ports as well?
- **Q6.5** Why can this lab not use Cilium L2 Announcements (ARP) for `10.100.100.0/24`, and what does BGP provide that L2 does not?

---

## Exercise 7 — `externalTrafficPolicy: Local` controls where the route is advertised

1. Switch the policy and reduce the replicas to 1:

```bash
kubectl patch svc web-lb -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl scale deploy web --replicas=1
kubectl rollout status deploy/web
kubectl get pods -l app=web -o wide
```

2. Look at who advertises the LB IP now:

```bash
cilium bgp routes advertised ipv4 unicast | grep "${LB_IP}"
docker exec tor ip route show "${LB_IP}"
```

```
ckne-bgp-worker2   65001   172.18.0.100   10.100.100.10/32   172.18.0.4   6s   [...]
```

```
10.100.100.10 nhid 21 via 172.18.0.4 dev eth0 proto bgp metric 20
```

3. Check that the client's real IP is preserved:

```bash
docker run --rm --network container:tor nicolaka/netshoot curl -s "http://${LB_IP}/clientip"; echo
```

4. Move the pod to the other node and watch the route follow it:

```bash
NODE=$(kubectl get pods -l app=web -o jsonpath='{.items[0].spec.nodeName}')
kubectl cordon "${NODE}"
kubectl delete pod -l app=web
kubectl rollout status deploy/web
docker exec tor ip route show "${LB_IP}"
kubectl uncordon "${NODE}"
```

5. Scale to 0 and check again:

```bash
kubectl scale deploy web --replicas=0
sleep 5
docker exec tor vtysh -c "show bgp ipv4 unicast ${LB_IP}/32"
kubectl scale deploy web --replicas=2
```

**Questions**

- **Q7.1** With `Local`, why does Cilium withdraw the /32 from nodes that have no local ready endpoint? What problem would it cause to keep advertising it?
- **Q7.2** With `Cluster` and 2 replicas, `/clientip` could return a node IP instead of `172.18.0.100`. In which case, and why?
- **Q7.3** With `Local`, 2 nodes and 3 replicas (2 on worker, 1 on worker2), how is traffic split? Why is that a problem, and how could you mitigate it?
- **Q7.4** Which Endpoint/EndpointSlice readiness state does Cilium use to decide whether a node has a "local endpoint"? What does a `terminating` pod change?

---

## Exercise 8 — Break-fix: diagnose broken sessions and filtered routes

### Fault A — wrong ASN

1. Introduce the fault:

```bash
kubectl patch ciliumbgpclusterconfig ckne-bgp --type=json \
  -p '[{"op":"replace","path":"/spec/bgpInstances/0/peers/0/peerASN","value":65099}]'
sleep 15
cilium bgp peers
docker logs tor 2>&1 | grep -i -E 'notification|bad peer as|remote-as' | tail -5
docker exec tor ip route | grep -c bgp
```

2. Diagnose it: session state on each side, the NOTIFICATION message, and the effect on the routes. Then revert:

```bash
kubectl patch ciliumbgpclusterconfig ckne-bgp --type=json \
  -p '[{"op":"replace","path":"/spec/bgpInstances/0/peers/0/peerASN","value":65000}]'
cilium bgp peers
```

### Fault B — RFC 8212 on the router

3. Re-enable the default policy requirement for eBGP in FRR:

```bash
docker exec tor vtysh -c 'conf t' -c 'router bgp 65000' -c 'bgp ebgp-requires-policy'
docker exec tor vtysh -c 'clear bgp ipv4 unicast * soft'
docker exec tor vtysh -c 'show bgp summary'
docker exec tor ip route | grep bgp
```

```
Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
*172.18.0.3     4      65001       120       118        0    0    0 00:05:40     (Policy) (Policy) N/A
*172.18.0.4     4      65001       119       118        0    0    0 00:05:40     (Policy) (Policy) N/A
```

4. Fix it properly with explicit route-maps that accept only the expected prefixes. Do not just disable the check:

```bash
docker exec tor vtysh \
  -c 'conf t' \
  -c 'ip prefix-list K8S-IN seq 10 permit 10.244.0.0/16 ge 24 le 24' \
  -c 'ip prefix-list K8S-IN seq 20 permit 10.100.100.0/24 ge 32 le 32' \
  -c 'route-map K8S-IN permit 10' \
  -c 'match ip address prefix-list K8S-IN' \
  -c 'exit' \
  -c 'route-map K8S-OUT deny 10' \
  -c 'exit' \
  -c 'router bgp 65000' \
  -c 'address-family ipv4 unicast' \
  -c 'neighbor K8S route-map K8S-IN in' \
  -c 'neighbor K8S route-map K8S-OUT out'
docker exec tor vtysh -c 'clear bgp ipv4 unicast * soft'
docker exec tor vtysh -c 'show bgp summary'
docker exec tor ip route | grep bgp
```

### Fault C — the advertisement label does not match

5. Change the label on the advertisement:

```bash
kubectl label ciliumbgpadvertisement k8s-routes advertise=nope --overwrite
sleep 5
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
kubectl label ciliumbgpadvertisement k8s-routes advertise=bgp --overwrite
```

**Questions**

- **Q8.1** In Fault A, which state do you see on the Cilium side (`active`, `connect`, `idle`), and which NOTIFICATION code/subcode does FRR send?
- **Q8.2** In Fault B the session stays `Established` but no prefixes are exchanged. Why is this failure more dangerous in production than a session that goes down?
- **Q8.3** Why does `K8S-OUT` deny everything toward the nodes? What would happen if the router re-advertised the full table to the cluster?
- **Q8.4** In Fault C, what is the fastest signal that the problem is route **selection** rather than **peering**?
- **Q8.5** Write the minimal triage sequence (5 commands) you would run on the exam if "the LoadBalancer IP is not reachable from outside".

---

## Exercise 9 — Advertise ClusterIPs (optional, with judgment)

1. Add a second advertisement for the ClusterIP of `web-lb`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: clusterip-routes
  labels:
    advertise: bgp
spec:
  advertisements:
    - advertisementType: Service
      service:
        addresses:
          - ClusterIP
      selector:
        matchLabels:
          bgp: public
```

```bash
kubectl apply -f clusterip-adv.yaml
CIP=$(kubectl get svc web-lb -o jsonpath='{.spec.clusterIP}')
docker exec tor ip route show "${CIP}"
docker run --rm --network container:tor nicolaka/netshoot curl -s "http://${CIP}/hostname"; echo
```

2. Note that the prefix list from Fault B (`K8S-IN`) filters it out. Decide whether it should be allowed. Then remove the advertisement:

```bash
kubectl delete ciliumbgpadvertisement clusterip-routes
```

**Questions**

- **Q9.1** List two risks of exposing ClusterIPs outside the cluster.
- **Q9.2** In what legitimate scenario would you do it?

---

## Cleanup

```bash
docker rm -f tor
kind delete cluster --name ckne-bgp
rm -rf frr
```

---

## Answers

<details>
<summary>Show answers</summary>

### Exercise 1

**Q1.1** The `kube-controller-manager`, through its node IPAM controller (`--allocate-node-cidrs=true`, `--cluster-cidr`). The block size comes from `--node-cidr-mask-size` (`/24` by default for IPv4). kind sets these from `podSubnet`. Because we use `ipam.mode=kubernetes`, Cilium consumes that `spec.podCIDR`. That is exactly the prefix that will be advertised per node.

**Q1.2** Without kube-proxy there are no iptables rules for Services. Cilium, with `kubeProxyReplacement=true`, implements ClusterIP, NodePort and LoadBalancer in eBPF, including the programs on the node's external device (`eth0`). Those programs recognize a packet addressed to an LB IP and DNAT it to a backend. If kube-proxy and Cilium both managed Services, you would have two data planes competing for the same traffic. For the exercise, it also matters that Cilium programs the LB IP it advertises itself.

### Exercise 2

**Q2.1** `autoDirectNodeRoutes` only installs routes **between nodes** that share an L2 segment. Anything outside the cluster (routers, VMs, other networks) has no idea that `10.244.1.0/24` lives behind `172.18.0.3`. BGP gives that knowledge to the external network dynamically, and withdraws it when a node disappears.

**Q2.2** It tells Cilium which destinations are reachable without masquerade (the pod network, routed natively). Traffic from a pod to a destination **outside** that CIDR is SNATed to the node IP (eBPF masquerade). Traffic inside it keeps the pod IP as the source.

**Q2.3** In native mode the packet leaves the node with the real pod IP, and the node forwards packets addressed to its pod CIDR. With VXLAN, pod-to-pod traffic is encapsulated between nodes, and traffic to the outside is masqueraded. The router could learn the route and send packets to the node, but the rest of the design (visible pod IPs, symmetric routing, no overlay) is lost. Advertising pod CIDRs only makes full sense when the fabric routes those prefixes natively.

### Exercise 3

**Q3.1** With dynamic neighbors FRR is **passive**. It accepts connections from any IP in the range, and the nodes (GoBGP inside cilium-agent) open TCP/179 to the router. That suits Kubernetes because nodes come and go (autoscaling, replacements): the router needs no per-node configuration. The trade-off is that the range must be tight and the prefixes must be filtered (see Fault B), because any IP in the range can peer.

**Q3.2** It allows installing up to 8 equal-cost paths for the same prefix in the RIB/FIB (BGP multipath → ECMP in the kernel). Without it, FRR picks a single best path (here, by lowest router-id), and **all** traffic to the LB IP enters through one node. The other nodes then act only as backup.

**Q3.3** With eBGP, routes received from one node are re-advertised to other peers without extra configuration. The AS path prevents loops, and the next hop is rewritten predictably. With iBGP, you need a full mesh or route reflectors (iBGP does not re-advertise iBGP-learned routes) and you must manage next-hop-self. The common production pattern is one AS per cluster or per rack talking eBGP with the ToR.

### Exercise 4

**Q4.1** In the v2 API, `CiliumBGPPeerConfig.spec.families[].advertisements` is a **label selector** over `CiliumBGPAdvertisement` objects. Only advertisements carrying those labels are announced to that peer. At this point no `CiliumBGPAdvertisement` with `advertise: bgp` exists yet, so there is a session with nothing to announce. That is intentional: Cilium advertises nothing by default.

**Q4.2** Two: one per node selected by `nodeSelector` (`bgp=enabled`). The operator expands `CiliumBGPClusterConfig` into a `CiliumBGPNodeConfig` named after each node. The control plane is not labeled, so it gets no BGP instance. If you need to adjust something for one node (router-id, source address, local port), use `CiliumBGPNodeConfigOverride` with the node name.

**Q4.3** Failure detection in about 9 s instead of the 90 s default: the router stops sending traffic to a dead node much sooner. On large clusters, aggressive timers add CPU and keepalive traffic on the router (N nodes × sessions), and they risk *flaps* when the agent or the network is under load. BFD is the usual alternative for sub-second detection, where the implementation supports it.

**Q4.4** The agent announces the graceful-restart capability. When it restarts, the router keeps the node's routes marked *stale* for `restartTimeSeconds` (30 s) while the data plane (eBPF, still loaded in the kernel) keeps forwarding. When the session comes back and End-of-RIB is exchanged, the routes are refreshed. If the node does not come back in time, they are withdrawn. Without graceful restart, a routine agent upgrade causes a withdraw/re-advertise and brief loss.

### Exercise 5

**Q5.1** Because the control plane is not selected by `nodeSelector`, it has no BGP session. Any pod on the control plane (for example, CoreDNS, which tolerates the control-plane taint in kind) is unreachable **from outside** by its pod IP. Inside the cluster it keeps working thanks to `autoDirectNodeRoutes`. Fix: label the node with `bgp=enabled`, or assume and document that nothing outside needs to reach it (and use `nodeSelector`/`affinity` so exposed workloads do not run there).

**Q5.2** The router initiated the connection, so the pod's replies belong to an existing connection (conntrack *reply* direction), and eBPF masquerade does not rewrite replies to inbound flows. The packet reaches the pod with no DNAT and no SNAT at all: it is plain routing to an IP inside `ipv4NativeRoutingCIDR`.

**Q5.3** No. The Cilium BGP Control Plane is an **advertise-only** design: it announces prefixes but does not install received routes into the node's kernel (`cilium bgp routes available` can show them, `ip route` on the node does not). If the design expects nodes to learn a default route or specific prefixes over BGP, you need another component (for example, an FRR/BIRD on the host) or static routes. Calico, which uses BIRD, does install routes.

**Q5.4** With `ipam.mode=cluster-pool` or `multi-pool`, the Cilium operator can assign a node more than one pod CIDR as it runs out of addresses. `advertisementType: PodCIDR` then announces each block assigned to the node. (With `multi-pool` there is also `advertisementType: CiliumPodIPPool` to advertise per-pool blocks with a selector.)

### Exercise 6

**Q6.1** Each Service is announced as a /32 so that the route points **only** to the nodes that can serve it (it can vary per Service, especially with `Local`) and disappears when the Service stops existing. An aggregate (`10.100.100.0/24`) would reduce the router's table, but every node would attract traffic for every IP in the range, including unassigned IPs and Services with no endpoints on that node. Many fabrics limit the number of /32s per peer, so on large deployments you need to size for that (or aggregate on the upstream router).

**Q6.2** The **pool** selector (`serviceSelector` in `CiliumLoadBalancerIPPool`). No pool matches `web-internal`, so LB IPAM does not assign an IP. The Service stays `<pending>` with the condition `io.cilium/lb-ipam-request-satisfied=False`. If the pool matched it but the advertisement did not, the Service **would** get an `EXTERNAL-IP` but nobody would announce it: it looks healthy in `kubectl` and is unreachable from outside, which is the most misleading case.

**Q6.3** With the annotation `lbipam.cilium.io/ips: "10.100.100.42"` on the Service (it takes a comma-separated list for dual-stack or several IPs). The IP must belong to a pool that selects the Service. `spec.loadBalancerIP` is deprecated in Kubernetes and should not be used for new designs.

**Q6.4** By default (`net.ipv4.fib_multipath_hash_policy=0`) the hash is L3 only (source IP, destination IP). A single client always goes to the same next hop. With `sysctl -w net.ipv4.fib_multipath_hash_policy=1` on the router, the 5-tuple is used (L4), and different connections from the same client spread across nodes. In physical fabrics this is set in the switch's hashing profile.

**Q6.5** L2 Announcements answer ARP/NDP for the IP, so the IP has to belong to the subnet the clients are on (here, `172.18.0.0/16`). `10.100.100.0/24` is not on any segment, so nobody would send ARP for it. L2 also elects **one** node per IP (lease): no ECMP, and failover depends on gratuitous ARP. BGP lets you use any range, distributes traffic across several nodes (ECMP), withdraws quickly when a node fails, and scales across L3 networks (multiple racks), at the cost of needing BGP-capable routers.

### Exercise 7

**Q7.1** With `Local`, a node without local endpoints **drops** the traffic (it does not forward it to other nodes, to preserve the source IP). If it kept advertising the /32, the router would send it part of the flows through ECMP and those connections would fail. Cilium withdraws the route from those nodes, so the router's routing table reflects where there really are backends. It is effectively a health check through the routing protocol.

**Q7.2** When the node picked by ECMP forwards the request to a pod on **another** node. With `Cluster` in SNAT mode (Cilium's default), the node SNATs to its own IP so the reply comes back through it. The pod then sees the node IP as the client. If the backend is local to the node that received the packet, the IP is preserved. DSR mode (`loadBalancer.mode=dsr`) avoids the SNAT, but it requires native routing and a network that allows it.

**Q7.3** The router does ECMP **per node**, not per pod: 50% to worker (split between 2 pods → 25% each) and 50% to worker2 (1 pod → 50%). One pod gets twice the load. Mitigations: `topologySpreadConstraints` / anti-affinity to spread evenly, a replica count that is a multiple of the node count, or `Cluster` if you do not need the client IP. Some implementations can signal weights; plain BGP ECMP does not.

**Q7.4** It uses the Service's local endpoints that are **ready** (`conditions.ready=true` in the EndpointSlice). A `terminating` pod drops out of the ready set; if it was the last one on the node, the route is withdrawn. Kubernetes keeps `serving=true` during termination so that, with `Local`, in-flight traffic can still be routed to terminating endpoints when no other ready endpoints remain, which reduces drops during rolling updates. It is worth pairing that with a `preStop` or a large enough `terminationGracePeriodSeconds` so that withdrawal propagates through BGP before the process exits.

### Exercise 8

**Q8.1** The Cilium side oscillates between `active`/`connect`/`idle` (it never reaches `established`), and `cilium bgp peers` shows `Peer AS 65099`. FRR rejects the OPEN because the ASN the node sends (65001) is valid, but the node rejects the router's OPEN because it announces AS 65000 while the node expects 65099. The NOTIFICATION is code 2 (*OPEN Message Error*), subcode 2 (*Bad Peer AS*). All BGP routes disappear from the router, so the pod CIDRs and LB IPs become unreachable.

**Q8.2** Because it looks healthy: `Established`, uptime increasing, green monitoring on "session up". But no prefixes are accepted or sent (`(Policy)`), so the outage is in the data plane. Alerts have to watch the **prefix count** per neighbor (`PfxRcd`), not just the session state. RFC 8212 makes this the default behavior on modern eBGP implementations (FRR ≥ 7.4, several vendors) to prevent route leaks.

**Q8.3** Because Cilium does not install received routes anyway (Q5.3), and sending the full table only costs memory and CPU in every agent. It also avoids accidentally turning a node into a transit path. The principle is to make the least necessary routing information flow in each direction: nodes → router only `10.244.0.0/16 le 24` and /32s from the LB pool; router → nodes nothing (or only a default if another component installs it).

**Q8.4** `cilium bgp peers` still shows `established` and the `Advertised` count drops to 0. `cilium bgp routes advertised` returns nothing. A healthy session with 0 advertised routes points directly at advertisement selection (labels on `CiliumBGPAdvertisement` vs `families[].advertisements` in the peer config, or the advertisement's Service selector), not at connectivity or ASNs.

**Q8.5** A reasonable sequence:

1. `kubectl get svc <svc> -o wide`: is there an `EXTERNAL-IP`? If it is `<pending>`, look at the pool/LB IPAM (`kubectl get ciliumloadbalancerippools`, the Service conditions).
2. `kubectl get endpointslices -l kubernetes.io/service-name=<svc>`: are there ready endpoints, and on which nodes (critical with `Local`)?
3. `cilium bgp peers`: are the sessions `established` and is `Advertised` > 0?
4. `cilium bgp routes advertised ipv4 unicast | grep <LB_IP>`: which nodes announce the /32?
5. On the router, `show bgp ipv4 unicast <LB_IP>/32` plus `ip route show <LB_IP>` (or the equivalent): was it received, accepted by policy, and installed with the expected next hops?

### Exercise 9

**Q9.1** (a) ClusterIP ranges are often identical across clusters (`10.96.0.0/12` by default), so advertising them from several clusters creates overlaps and ambiguous routing. (b) Services designed to be internal (without authentication, because "they are only reachable inside the cluster") become exposed to the whole network, and the NetworkPolicy/firewall perimeter changes without anyone noticing. A third risk is the growth of the table of /32s.

**Q9.2** Flat networks where external VMs or legacy systems need to consume cluster Services without an extra LB, with no overlapping ClusterIP ranges between clusters and with explicit filtering on the router. Another case is migrations, where an external client keeps using a stable ClusterIP while it moves to a `LoadBalancer`. Even then, a selective (label-based) advertisement is preferable to one that selects every Service.

</details>