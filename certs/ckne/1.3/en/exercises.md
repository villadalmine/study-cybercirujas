# CKNE 1.3 — Guided Exercises: Using Linux Tools (iptables, ip, tcpdump) for Packet-level Issues

These exercises follow one packet from a client Pod to a Service backend and check its state at every hop. You will look at it with `ip`, capture it with `tcpdump`, read the NAT rules that rewrite it with `iptables-save`, and inspect the connection-tracking entry that keeps the rewrite in place with `conntrack`. You will then inject two faults, a silent drop and an MTU reduction, and find each one from packet evidence alone.

The whole lab runs on a local kind cluster. It does not depend on a particular CNI's NetworkPolicy support, because every fault is created with plain Linux tools.

**Official references used throughout:**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Virtual IPs and Service proxies: https://kubernetes.io/docs/reference/networking/virtual-ips/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Debugging Kubernetes nodes with kubectl: https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/
- Debug running Pods: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- kube-proxy reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/
- `iptables(8)`: https://man7.org/linux/man-pages/man8/iptables.8.html
- `ip-route(8)` / `ip-link(8)`: https://man7.org/linux/man-pages/man8/ip-route.8.html, https://man7.org/linux/man-pages/man8/ip-link.8.html
- `tcpdump(1)` and `pcap-filter(7)`: https://www.tcpdump.org/manpages/tcpdump.1.html, https://www.tcpdump.org/manpages/pcap-filter.7.html
- `conntrack(8)`: https://conntrack-tools.netfilter.org/manual.html

> **About the outputs shown.** IP addresses, interface indexes, chain hashes and veth names **will be different** in your cluster. The expected outputs show the *shape* you should see. Always substitute your own values; never copy an IP from this document.

---

## Exercise 0 — Lab setup

**Prerequisites:** `docker` (or `podman`), `kind` ≥ v0.20, and a `kubectl` recent enough to support `kubectl debug --profile` (v1.27+).

1. Create a kind cluster with one control-plane node and two workers. Force kube-proxy into `iptables` mode so that Exercise 3 is deterministic:

   ```yaml
   # kind-ckne-1.3.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: ckne
   networking:
     kubeProxyMode: iptables
     podSubnet: "10.244.0.0/16"
     serviceSubnet: "10.96.0.0/16"
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   ```

   ```bash
   kind create cluster --config kind-ckne-1.3.yaml
   kubectl get nodes -o wide
   ```

   Expected (shape):

   ```
   NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
   ckne-control-plane   Ready    control-plane   60s   v1.3x.x   172.18.0.4    ...
   ckne-worker          Ready    <none>          40s   v1.3x.x   172.18.0.3    ...
   ckne-worker2         Ready    <none>          40s   v1.3x.x   172.18.0.2    ...
   ```

2. Deploy the workload. The **backends** are pinned to `ckne-worker2` and the **client** is pinned to `ckne-worker`, so every request has to cross between nodes. The client runs `nicolaka/netshoot` with `NET_ADMIN` and `NET_RAW` so it can run `tcpdump` and change its own interface settings.

   ```yaml
   # lab.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: lab
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: lab
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         nodeSelector:
           kubernetes.io/hostname: ckne-worker2
         containers:
           - name: nginx
             image: nginx:1.27
             ports:
               - name: http
                 containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: lab
   spec:
     type: ClusterIP
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
         protocol: TCP
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: client
     namespace: lab
   spec:
     nodeSelector:
       kubernetes.io/hostname: ckne-worker
     containers:
       - name: netshoot
         image: nicolaka/netshoot:latest
         command: ["sleep", "infinity"]
         securityContext:
           capabilities:
             add: ["NET_ADMIN", "NET_RAW"]
   ```

   ```bash
   kubectl apply -f lab.yaml
   kubectl -n lab rollout status deploy/web
   kubectl -n lab wait --for=condition=Ready pod/client --timeout=120s
   kubectl -n lab get pods -o wide
   kubectl -n lab get svc web
   kubectl -n lab get endpointslices -l kubernetes.io/service-name=web
   ```

3. Write down the values you will use throughout the lab:

   ```bash
   export CLUSTER_IP=$(kubectl -n lab get svc web -o jsonpath='{.spec.clusterIP}')
   export CLIENT_IP=$(kubectl -n lab get pod client -o jsonpath='{.status.podIP}')
   kubectl -n lab get pods -l app=web -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.podIP}{"\n"}{end}'
   echo "ClusterIP=$CLUSTER_IP  client=$CLIENT_IP"
   ```

4. Check that the Service works from start to finish:

   ```bash
   kubectl -n lab exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://web.lab.svc.cluster.local
   ```

   Expected: `200`.

**Questions — Exercise 0**

- **Q0.1** The EndpointSlice lists three addresses, and the Service shows one ClusterIP. Which component turns "one ClusterIP" into "one of three Pod IPs", and on which node does that happen for traffic coming from `client`?
- **Q0.2** Why does it matter that the backends and the client are pinned to *different* nodes?

---

## Exercise 1 — The Pod's view of the network (`ip`)

Every Pod has its own network namespace. First see what the client can see from inside that namespace.

1. List the interfaces, addresses and routes:

   ```bash
   kubectl -n lab exec client -- ip -br addr
   kubectl -n lab exec client -- ip route
   kubectl -n lab exec client -- ip -d link show eth0
   ```

   Expected (shape, from kindnet):

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   eth0@if9         UP             10.244.1.5/24 fe80::.../64

   default via 10.244.1.1 dev eth0
   10.244.1.0/24 via 10.244.1.1 dev eth0 src 10.244.1.5
   10.244.1.1 dev eth0 scope link src 10.244.1.5

   2: eth0@if9: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ... 
       link/ether 5a:1e:... brd ff:ff:ff:ff:ff:ff link-netnsid 0
       veth ...
   ```

2. Ask the kernel which route it would pick for three different destinations:

   ```bash
   kubectl -n lab exec client -- ip route get "$CLUSTER_IP"
   kubectl -n lab exec client -- ip route get 10.244.2.2      # replace with a real web Pod IP
   kubectl -n lab exec client -- ip route get 1.1.1.1
   ```

3. Generate traffic, then look at the neighbour (ARP) table and the interface counters:

   ```bash
   kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP
   kubectl -n lab exec client -- ip neigh
   kubectl -n lab exec client -- ip -s link show eth0
   ```

**Questions — Exercise 1**

- **Q1.1** In the name `eth0@if9`, what does `if9` mean, and in which network namespace does interface index 9 live?
- **Q1.2** `ip route get $CLUSTER_IP` from inside the Pod returns an ordinary route through the default gateway. Why does the Pod's routing table not know that the address is a Service?
- **Q1.3** Which MAC address shows up in `ip neigh` for traffic to *any* destination: a backend's MAC, or a single gateway MAC? What does that tell you about where routing decisions are made?
- **Q1.4** `ip -s link` shows `RX dropped` and `TX dropped` counters. Name one situation in which a rising TX `dropped` counter on a Pod's `eth0` would be your first clue.

---

## Exercise 2 — Linking the Pod to its host-side veth

For a packet-level investigation you need to know *which host interface* belongs to *which Pod*. `tcpdump` on the wrong veth shows nothing and looks the same as "no traffic".

1. Start a node debugging Pod on `ckne-worker`. It runs in the node's **network namespace** (`hostNetwork`), and the node's root filesystem is mounted at `/host`. The `sysadmin` profile makes it privileged, which `iptables`, `conntrack` and `tcpdump` require. **Keep this shell open in its own terminal; this lab calls it Terminal N1.**

   ```bash
   kubectl debug node/ckne-worker -it --profile=sysadmin --image=nicolaka/netshoot
   ```

2. In the client Pod, read the peer interface index (the number after `@if`):

   ```bash
   kubectl -n lab exec client -- cat /sys/class/net/eth0/iflink
   ```

   Expected: a number, for example `9`.

3. In **Terminal N1**, find the interface with that index and confirm that the node routes the client's IP through it:

   ```bash
   ip -o link | awk -F': ' '$1 == 9 {print $2}'
   ip route get 10.244.1.5          # the client's Pod IP
   ip route | grep 10.244
   ```

   Expected (shape):

   ```
   veth3f2a91c7@if2

   10.244.1.5 dev veth3f2a91c7 src 10.244.1.1 uid 0
       cache

   10.244.1.5 dev veth3f2a91c7 scope host
   10.244.2.0/24 via 172.18.0.2 dev eth0
   10.244.0.0/24 via 172.18.0.4 dev eth0
   ```

4. Save the veth name for later use in N1:

   ```bash
   export CLIENT_VETH=veth3f2a91c7   # your value
   ```

**Questions — Exercise 2**

- **Q2.1** The host-side veth is `...@if2`. What is interface index 2 in this case?
- **Q2.2** Use the node's routing table to explain how a packet addressed to a Pod on `ckne-worker2` leaves `ckne-worker`. Is there any encapsulation (VXLAN, Geneve) in this kind setup? What evidence in the output supports your answer?
- **Q2.3** Many CNIs (for example bridge-based ones) connect veths to a Linux bridge instead of routing to each veth directly. Which command would you use to see which veths are attached to a bridge?

---

## Exercise 3 — How kube-proxy rewrites the packet (`iptables-save`)

1. In **Terminal N1**, confirm the proxy mode. Do not assume it:

   ```bash
   curl -s http://127.0.0.1:10249/proxyMode; echo
   ```

   Expected: `iptables`. If you get `nftables` or `ipvs`, the chains below do not exist, so check your kind config. In nftables mode the equivalent is `nft list table ip kube-proxy`.

2. Check which iptables backend the node uses. Rules written through the `legacy` backend cannot be seen with the `nft` backend, and the reverse is also true. The **node's own binaries** under `/host` are the safest choice:

   ```bash
   chroot /host iptables -V
   iptables -V
   chroot /host iptables-save -t nat | grep -c '^-A KUBE'
   iptables-save -t nat | grep -c '^-A KUBE'
   ```

3. Follow the Service from the entry point to the DNAT:

   ```bash
   chroot /host iptables-save -t nat | grep -E '^-A (PREROUTING|OUTPUT) .*KUBE-SERVICES'
   chroot /host iptables-save -t nat | grep 'lab/web'
   ```

   Expected (shape; hashes and comment wording vary by version):

   ```
   -A PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
   -A OUTPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES

   -A KUBE-SERVICES -d 10.96.143.21/32 -p tcp -m comment --comment "lab/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-Q3JQK6UVQ4UBFBUF
   -A KUBE-SVC-Q3JQK6UVQ4UBFBUF ! -s 10.244.0.0/16 -d 10.96.143.21/32 -p tcp -m comment --comment "lab/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
   -A KUBE-SVC-Q3JQK6UVQ4UBFBUF -m comment --comment "lab/web:http -> 10.244.2.2:80" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-AAAAAAAAAAAAAAAA
   -A KUBE-SVC-Q3JQK6UVQ4UBFBUF -m comment --comment "lab/web:http -> 10.244.2.3:80" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-BBBBBBBBBBBBBBBB
   -A KUBE-SVC-Q3JQK6UVQ4UBFBUF -m comment --comment "lab/web:http -> 10.244.2.4:80" -j KUBE-SEP-CCCCCCCCCCCCCCCC
   -A KUBE-SEP-AAAAAAAAAAAAAAAA -s 10.244.2.2/32 -m comment --comment "lab/web:http" -j KUBE-MARK-MASQ
   -A KUBE-SEP-AAAAAAAAAAAAAAAA -p tcp -m comment --comment "lab/web:http" -m tcp -j DNAT --to-destination 10.244.2.2:80
   ...
   ```

4. Look at the masquerade logic that the `KUBE-MARK-MASQ` jumps feed into:

   ```bash
   chroot /host iptables-save -t nat | grep -E '^-A KUBE-(MARK-MASQ|POSTROUTING)'
   ```

   Expected (shape):

   ```
   -A KUBE-MARK-MASQ -j MARK --set-xmark 0x4000/0x4000
   -A KUBE-POSTROUTING -m mark ! --mark 0x4000/0x4000 -j RETURN
   -A KUBE-POSTROUTING -j MARK --set-xmark 0x4000/0x0
   -A KUBE-POSTROUTING -m comment --comment "kubernetes service traffic requiring SNAT" -j MASQUERADE --random-fully
   ```

5. Watch the counters change while the Service handles requests. Zero them only on the chain you are studying, never globally on a shared node:

   ```bash
   SVC_CHAIN=KUBE-SVC-Q3JQK6UVQ4UBFBUF   # your value
   chroot /host iptables -t nat -Z "$SVC_CHAIN"
   ```

   From your workstation, send 30 requests:

   ```bash
   for i in $(seq 1 30); do kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP; done
   ```

   Back in N1:

   ```bash
   chroot /host iptables -t nat -L "$SVC_CHAIN" -v -n --line-numbers
   ```

**Questions — Exercise 3**

- **Q3.1** Why are the probabilities `0.333…`, `0.5` and then *no* probability on the last rule? Show that each backend receives about 1/3 of new connections.
- **Q3.2** The client's source address is `10.244.1.5`. Will the rule `! -s 10.244.0.0/16 ... -j KUBE-MARK-MASQ` in `KUBE-SVC-…` match it? So what source IP will the backend see?
- **Q3.3** What problem does the rule `-A KUBE-SEP-… -s 10.244.2.2/32 -j KUBE-MARK-MASQ` solve? (Hint: which client would match it?)
- **Q3.4** Run `kubectl -n lab exec client -- ping -c 2 -W 1 $CLUSTER_IP`. It fails. Use the rules you just read to explain why. Is this a fault?
- **Q3.5** The DNAT rules are installed in PREROUTING **and** OUTPUT. Which kinds of traffic use each hook?

---

## Exercise 4 — The state that keeps the rewrite in place (`conntrack`)

The NAT rules are evaluated **only for the first packet of a connection**. After that, the kernel's connection tracking table decides how each packet is translated.

1. In **Terminal N1**, watch events for the ClusterIP:

   ```bash
   conntrack -E -p tcp --orig-dst "$CLUSTER_IP"     # set CLUSTER_IP in N1 first
   ```

2. From the workstation, send a single request:

   ```bash
   kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP
   ```

   Expected in N1 (shape):

   ```
       [NEW] tcp      6 120 SYN_SENT src=10.244.1.5 dst=10.96.143.21 sport=48122 dport=80 [UNREPLIED] src=10.244.2.3 dst=10.244.1.5 sport=80 dport=48122
    [UPDATE] tcp      6 60 SYN_RECV src=10.244.1.5 dst=10.96.143.21 sport=48122 dport=80 src=10.244.2.3 dst=10.244.1.5 sport=80 dport=48122
    [UPDATE] tcp      6 432000 ESTABLISHED src=10.244.1.5 dst=10.96.143.21 sport=48122 dport=80 src=10.244.2.3 dst=10.244.1.5 sport=80 dport=48122 [ASSURED]
    [UPDATE] tcp      6 120 FIN_WAIT ...
    [UPDATE] tcp      6 120 TIME_WAIT ...
   ```

3. Stop the watch (Ctrl-C) and list what is still in the table:

   ```bash
   conntrack -L -p tcp --orig-dst "$CLUSTER_IP" 2>/dev/null
   conntrack -S | head -5
   cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
   ```

4. Run the same `conntrack -L` on `ckne-worker2`. Start a second node debugging shell (**Terminal N2**) for this; you will need it again:

   ```bash
   kubectl debug node/ckne-worker2 -it --profile=sysadmin --image=nicolaka/netshoot
   ```

   ```bash
   # In N2
   conntrack -L -p tcp --orig-dst 10.96.143.21 2>/dev/null   # your ClusterIP
   conntrack -L -p tcp --orig-src 10.244.1.5 2>/dev/null     # your client IP
   ```

**Questions — Exercise 4**

- **Q4.1** Each conntrack line has two tuples. Explain what the *original* and *reply* tuples mean, and how you can tell from the reply tuple which backend was chosen.
- **Q4.2** On `ckne-worker2`, a lookup by `--orig-dst <ClusterIP>` finds nothing, but a lookup by `--orig-src <client IP>` does find an entry. Why?
- **Q4.3** You remove one backend. A long-lived connection that was DNATed to it keeps sending packets that go nowhere. Which command shows the stale entry, and why do the updated iptables rules not fix that connection by themselves?
- **Q4.4** `conntrack -S` shows a rising `insert_failed` or `drop` counter, and `nf_conntrack_count` is close to `nf_conntrack_max`. What will clients experience, and what message would you expect in `dmesg`?

---

## Exercise 5 — Seeing the rewrite happen (`tcpdump` at three points)

Capture the **same connection** at three observation points at the same time. You will need three terminals.

1. **Point A — inside the client Pod** (Pod network namespace):

   ```bash
   kubectl -n lab exec -it client -- tcpdump -ni eth0 -c 6 'tcp port 80'
   ```

2. **Point B — the client's host-side veth** (Terminal N1):

   ```bash
   tcpdump -ni "$CLIENT_VETH" -c 6 'tcp port 80'
   ```

3. **Point C — the node's uplink toward `ckne-worker2`** (also on `ckne-worker`; open a third node shell, or stop B and run it again):

   ```bash
   tcpdump -ni eth0 -c 6 'tcp port 80 and net 10.244.0.0/16'
   ```

4. Generate one request from the workstation:

   ```bash
   kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP
   ```

   Expected (shape):

   ```
   # Point A (Pod eth0)
   IP 10.244.1.5.48130 > 10.96.143.21.80: Flags [S], seq ..., options [mss 1460,...]
   IP 10.96.143.21.80 > 10.244.1.5.48130: Flags [S.], ...

   # Point B (host veth)
   IP 10.244.1.5.48130 > 10.96.143.21.80: Flags [S], ...
   IP 10.96.143.21.80 > 10.244.1.5.48130: Flags [S.], ...

   # Point C (node eth0)
   IP 10.244.1.5.48130 > 10.244.2.4.80: Flags [S], ...
   IP 10.244.2.4.80 > 10.244.1.5.48130: Flags [S.], ...
   ```

5. Save a capture for offline analysis and read it back with more detail:

   ```bash
   # N1
   tcpdump -ni eth0 -s 0 -w /tmp/web.pcap 'tcp port 80' &
   sleep 1
   ```

   ```bash
   # workstation
   for i in 1 2 3; do kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP; done
   ```

   ```bash
   # N1
   kill %1
   tcpdump -nr /tmp/web.pcap -tttt -v 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0'
   ```

**Questions — Exercise 5**

- **Q5.1** Points A and B show the ClusterIP as the destination, and Point C shows a Pod IP. Where in the kernel path, between B and C, does the rewrite happen? Why does `tcpdump` on the veth see the packet *before* the rewrite?
- **Q5.2** The reply at Point C comes from `10.244.2.4`, but at Points A and B it comes from `10.96.143.21`. What reverses the translation, given that no iptables rule mentions the reply direction?
- **Q5.3** The filter `tcp[tcpflags] & (tcp-syn|tcp-rst) != 0` keeps only SYN or RST packets. Why is this a good first filter when you are hunting connection failures on a busy node?
- **Q5.4** If you capture on `-i any` instead of a specific interface, what do you gain and what do you lose? (Consider the link-layer header and seeing the same packet twice.)

---

## Exercise 6 — Fault injection: a silent drop that affects one backend in three

Now create a realistic fault: a packet filter on the backend node drops traffic to **one** backend Pod. From the client's side this looks like an intermittent timeout, the hardest kind of symptom to explain.

1. Pick one backend IP (for example `10.244.2.3`). In **Terminal N2** (`ckne-worker2`), insert the fault with the node's own iptables:

   ```bash
   export BAD_POD=10.244.2.3      # your value
   chroot /host iptables -I FORWARD 1 -d "$BAD_POD" -p tcp --dport 80 -m comment --comment "ckne-lab-fault" -j DROP
   ```

2. From the workstation, reproduce the symptom:

   ```bash
   for i in $(seq 1 12); do
     kubectl -n lab exec client -- curl -s -o /dev/null --connect-timeout 2 -w '%{http_code} %{remote_ip}\n' http://$CLUSTER_IP
   done
   ```

   Expected (shape): most lines show `200 10.96.143.21`, and about one in three shows `000 10.96.143.21`.

3. **Diagnose it as if you had not caused it.** First, from which backend do the failures come? In N1 (`ckne-worker`), capture SYNs and SYN-ACKs on the uplink:

   ```bash
   tcpdump -ni eth0 'tcp port 80 and (tcp[tcpflags] & (tcp-syn) != 0)'
   ```

   Run the loop from step 2 again. Expected (shape):

   ```
   IP 10.244.1.5.50110 > 10.244.2.2.80: Flags [S], ...
   IP 10.244.2.2.80 > 10.244.1.5.50110: Flags [S.], ...
   IP 10.244.1.5.50112 > 10.244.2.3.80: Flags [S], ...
   IP 10.244.1.5.50112 > 10.244.2.3.80: Flags [S], ...      <- retransmission, no SYN-ACK
   IP 10.244.1.5.50114 > 10.244.2.4.80: Flags [S], ...
   IP 10.244.2.4.80 > 10.244.1.5.50114: Flags [S.], ...
   ```

4. Does the SYN arrive at `ckne-worker2`, and does it reach the Pod's veth? In N2, find the veth for `$BAD_POD` and capture on both sides of the node:

   ```bash
   ip route get "$BAD_POD"                  # -> dev vethXXXX
   tcpdump -ni eth0 -c 3 "host $BAD_POD and tcp port 80" &
   tcpdump -ni vethXXXX -c 3 "tcp port 80" &   # your veth
   ```

   Run the loop again. Expected: the `eth0` capture shows SYNs to `$BAD_POD`, and the veth capture shows **nothing** for those connections.

5. The packet enters the node but never reaches the veth, so it is lost in the forwarding path. Find the rule with the counters:

   ```bash
   chroot /host iptables -L FORWARD -v -n --line-numbers | head -8
   ```

   Expected (shape):

   ```
   Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
   num   pkts bytes target     prot opt in     out     source               destination
   1       12   720 DROP       6    --  *      *       0.0.0.0/0            10.244.2.3           tcp dpt:80 /* ckne-lab-fault */
   2     4312  512K KUBE-PROXY-FIREWALL  0 -- *  *     0.0.0.0/0            0.0.0.0/0            ctstate NEW /* kubernetes load balancer firewall */
   ...
   ```

   For a broader search when you do not know which chain is responsible, compare two snapshots and look for the counters that moved:

   ```bash
   chroot /host iptables-save -c > /tmp/before
   # ... reproduce once from the workstation ...
   chroot /host iptables-save -c > /tmp/after
   diff /tmp/before /tmp/after | grep -E 'DROP|REJECT'
   ```

6. Fix the fault and verify the fix:

   ```bash
   chroot /host iptables -D FORWARD -d "$BAD_POD" -p tcp --dport 80 -m comment --comment "ckne-lab-fault" -j DROP
   chroot /host iptables-save | grep -c ckne-lab-fault
   ```

   Expected: `0`. Run the loop from step 2 again; all 12 responses should be `200`.

**Questions — Exercise 6**

- **Q6.1** Why was the fault intermittent from the client's point of view even though the DROP rule is deterministic?
- **Q6.2** Why does the rule belong in the `FORWARD` chain and not `INPUT`? What would an `INPUT` rule with the same match have done to this traffic?
- **Q6.3** Suppose the target had been `REJECT --reject-with tcp-reset` instead of `DROP`. How would the `curl` result and the `tcpdump` output at Point C change? Which one is easier to diagnose?
- **Q6.4** Explain the method you used in steps 3–5 as a general rule: which two capture points bracket the fault, and what does "seen at X, not seen at Y" prove?
- **Q6.5** Why did we use `chroot /host iptables` instead of the debug container's own `iptables` binary? What could go wrong if the two use different backends?

---

## Exercise 7 — MTU and fragmentation problems (`ip link`, `ping -M do`, `tcpdump -v`)

MTU mismatches usually show up as "small requests work, large ones hang". The following steps reproduce that behaviour on purpose.

1. Measure the working path MTU between the client and a backend on the other node. `-M do` sets Don't Fragment, and `-s` is the ICMP payload size:

   ```bash
   kubectl -n lab exec client -- ip link show eth0 | grep -o 'mtu [0-9]*'
   kubectl -n lab exec client -- ping -c 1 -W 1 -M do -s 1472 10.244.2.2   # a backend IP
   kubectl -n lab exec client -- ping -c 1 -W 1 -M do -s 1473 10.244.2.2
   ```

   Expected (shape):

   ```
   mtu 1500
   1480 bytes from 10.244.2.2: icmp_seq=1 ttl=62 time=0.12 ms
   ping: local error: message too long, mtu=1500
   ```

2. Simulate an underlay or overlay with a smaller MTU by lowering the client's MTU. The client has `NET_ADMIN`, so it can change its own namespace:

   ```bash
   kubectl -n lab exec client -- ip link set dev eth0 mtu 1400
   kubectl -n lab exec client -- ping -c 1 -W 1 -M do -s 1372 10.244.2.2
   kubectl -n lab exec client -- ping -c 1 -W 1 -M do -s 1400 10.244.2.2
   ```

3. Watch how TCP adapts. Capture the handshake with `-v` so that the TCP options are printed:

   ```bash
   kubectl -n lab exec -it client -- tcpdump -ni eth0 -v -c 2 'tcp port 80 and tcp[tcpflags] & tcp-syn != 0'
   ```

   In another terminal:

   ```bash
   kubectl -n lab exec client -- curl -s -o /dev/null http://$CLUSTER_IP
   ```

   Expected (shape):

   ```
   IP (tos 0x0, ttl 64, ..., flags [DF], proto TCP (6), length 60)
       10.244.1.5.50200 > 10.96.143.21.80: Flags [S], ..., options [mss 1360,sackOK,TS ...,nop,wscale 7], length 0
   IP (tos 0x0, ttl 62, ..., flags [DF], proto TCP (6), length 60)
       10.96.143.21.80 > 10.244.1.5.50200: Flags [S.], ..., options [mss 1460,sackOK,TS ...,nop,wscale 7], length 0
   ```

4. Restore the MTU:

   ```bash
   kubectl -n lab exec client -- ip link set dev eth0 mtu 1500
   kubectl -n lab exec client -- ip link show eth0 | grep -o 'mtu [0-9]*'
   ```

**Questions — Exercise 7**

- **Q7.1** Why is the largest successful payload 1472 when the MTU is 1500, and 1372 when it is 1400?
- **Q7.2** The SYN advertises `mss 1360` and the SYN-ACK advertises `mss 1460`. Which segment size is used in each direction, and why did the TCP transfer still work after you lowered the MTU?
- **Q7.3** In a real cluster the *Pod* MTU is 1500 but a VXLAN overlay adds 50 bytes over a 1500-byte underlay. Describe the symptom, explain why `curl` of a small page works, and name the ICMP message whose loss turns this into a black hole.
- **Q7.4** Which `tcpdump` filter would catch "fragmentation needed" ICMP messages on a node?

---

## Cleanup

```bash
# Exit the node debugging shells (N1, N2), then:
kubectl get pods -A | grep node-debugger | awk '{print $2}' | xargs -r kubectl delete pod
kubectl delete namespace lab
kind delete cluster --name ckne
```

---

## Answers

<details>
<summary><strong>Exercise 0</strong></summary>

- **Q0.1** kube-proxy, running in `iptables` mode, programs NAT rules on **every** node. For traffic from `client`, the backend is chosen on **`ckne-worker`**, the node where the client runs. The translation happens as soon as the packet leaves the Pod and enters the host network namespace, before the packet is routed toward `ckne-worker2`.
- **Q0.2** Cross-node traffic separates the two things you want to see: the node that performs the DNAT (`ckne-worker`) and the node that delivers to the Pod (`ckne-worker2`). It also puts a real uplink (`eth0`) on the path, where you can see the packet *after* the translation. On a single node, both roles would be mixed together.

</details>

<details>
<summary><strong>Exercise 1</strong></summary>

- **Q1.1** `eth0` is one end of a veth pair. `@if9` means that its peer has interface index 9 **in another network namespace**. `link-netnsid 0` points to the namespace where the peer lives, which here is the node's root namespace. That index is how you find the host-side veth in Exercise 2.
- **Q1.2** Services are not a concept of the Pod's network stack. A ClusterIP is not assigned to any interface, and the Pod routes it like any other remote address, through its default gateway. The Service is implemented *after* the packet leaves the Pod, by netfilter NAT on the node. From inside the Pod, a ClusterIP cannot be told apart from any other remote address.
- **Q1.3** A single gateway MAC (the host side of the veth, or the node-side gateway address). Every packet leaves the Pod through layer-3 routing to the node. All selection of the next hop and all Service translation happen in the node's namespace, not in the Pod.
- **Q1.4** A rising TX `dropped` counter means the kernel dropped packets while trying to send them out of that interface. Examples: a veth peer with a smaller MTU that rejects oversized frames, a full queue, or a qdisc or eBPF program on the path that drops traffic. It is a free first signal that the loss happens *locally*, before the network.

</details>

<details>
<summary><strong>Exercise 2</strong></summary>

- **Q2.1** Index 2 is the Pod's `eth0`, inside the Pod's network namespace. The pair points at itself: `eth0@if9` in the Pod and `veth…@if2` on the node.
- **Q2.2** The node has a route `10.244.2.0/24 via 172.18.0.2 dev eth0`: plain layer-3 routing through the other node's address on the shared Docker network. There is **no encapsulation**. There is no `vxlan`/`geneve` device in `ip -d link`, the next hop is the peer node's real IP, and in Exercise 5 the packets on `eth0` have Pod IPs directly in the IP header, with no outer UDP header. This is what kindnet does when all nodes share one L2 segment.
- **Q2.3** `bridge link show`, or `ip link show master <bridge>` (for example `ip link show master cni0`). `ip -d link show <veth>` also prints `master <bridge>` for an attached port.

</details>

<details>
<summary><strong>Exercise 3</strong></summary>

- **Q3.1** iptables evaluates the rules in order, and each rule gets a chance only if the previous ones did not match. Rule 1 matches with p = 1/3. Rule 2 is reached with probability 2/3 and matches half of those: 2/3 × 1/2 = 1/3. Rule 3 is reached with probability 2/3 × 1/2 = 1/3 and matches unconditionally. Each backend therefore receives 1/3 of **new** connections. The counters from step 5 should be roughly equal (about 10 each for 30 requests, with random variance).
- **Q3.2** No. `10.244.1.5` is inside `10.244.0.0/16`, so the negated source match fails and the packet is not marked. `KUBE-POSTROUTING` returns without masquerading, and the **backend sees the real client Pod IP**. Masquerading on this rule applies only to sources *outside* the Pod CIDR, such as node processes and external clients, which could not otherwise receive the reply through the correct path.
- **Q3.3** Hairpin traffic: a backend Pod that connects to its own Service and gets DNATed back to *itself*. Without SNAT, the reply would go directly from the Pod to itself using the Pod IP. The Pod expects a reply from the ClusterIP, so the connection would break. Marking it for MASQUERADE makes the node the apparent source, so the reply travels back through the node and conntrack reverses it.
- **Q3.4** The `KUBE-SERVICES` rule matches `-p tcp --dport 80` only. ICMP to the ClusterIP matches no DNAT rule, and no interface owns that address, so nothing answers. This is **expected** behaviour, not a fault. Testing a Service with `ping` is a classic false alarm. Test with the real protocol and port (`curl`, `nc -zv`). The Kubernetes "Debug Services" guide points out the same thing.
- **Q3.5** `PREROUTING` sees packets **arriving** at the node from outside its root namespace: from Pods through veths, and from other hosts. `OUTPUT` sees packets **generated locally** by processes in the node's root namespace, including `hostNetwork` Pods, the kubelet, and your node debugging shell. Both have to be hooked so that the Service works for either kind of client.

</details>

<details>
<summary><strong>Exercise 4</strong></summary>

- **Q4.1** The *original* tuple describes the packet as the initiator sent it: `src=client dst=ClusterIP dport=80`. The *reply* tuple describes what the kernel expects replies to look like: `src=<backend Pod IP> dst=client sport=80`. The reply source is the chosen backend. The translation is written down entirely in the difference between the two tuples.
- **Q4.2** `ckne-worker2` never saw the ClusterIP. The packet reached it already translated (`dst=<backend Pod IP>`). Its own conntrack entry, created for forwarding and not for NAT, has the Pod IP as the original destination. Service NAT state exists **only on the node that performed the DNAT**, which is the client's node for ClusterIP traffic.
- **Q4.3** `conntrack -L --reply-src <old Pod IP>` shows it. iptables NAT rules are consulted only for the **first** packet of a connection. Later packets are translated from the existing conntrack entry, so changing the rules has no effect on established flows. kube-proxy clears stale **UDP** entries when endpoints change. For stuck flows you can run `conntrack -D --reply-src <old Pod IP>` yourself, and the application needs to reconnect.
- **Q4.4** New connections fail at random. The first SYN is dropped because no conntrack entry can be created, so the client sees connection timeouts or very long connect times (SYN retransmits at about 1 s, 3 s, …). Existing connections are unaffected. `dmesg` shows `nf_conntrack: table full, dropping packet`. Fix it by raising `nf_conntrack_max` (kube-proxy's `--conntrack-*` flags size it), or by finding the source that creates so many connections.

</details>

<details>
<summary><strong>Exercise 5</strong></summary>

- **Q5.1** The rewrite happens in the netfilter `PREROUTING` hook, `nat` table, of `ckne-worker`'s root namespace, as soon as the packet is received from the veth and before the routing decision. That decision is then made on the *new* destination, which is why the packet goes out of `eth0` toward `ckne-worker2`. `tcpdump` (AF_PACKET) captures received frames at the device level, **before** the IP stack and netfilter process them, so the veth capture shows the original destination. On an egress interface it captures after all of netfilter (POSTROUTING), which is why Point C shows the translated addresses.
- **Q5.2** Connection tracking. The reply `10.244.2.4 → 10.244.1.5` matches the *reply tuple* of the existing entry, and the kernel automatically applies the reverse translation (un-DNAT), rewriting the source back to `10.96.143.21:80`. No reverse rule is needed, which is also why NAT cannot work without conntrack.
- **Q5.3** A connection failure always shows up in the handshake: an unanswered or retransmitted SYN, an RST, or a SYN-ACK that never comes back. Filtering on SYN/RST removes all data traffic from established flows, keeps the output readable on a busy node, and shows immediately which destinations answer and which do not.
- **Q5.4** Gain: one capture shows every interface, including veths that come and go, with no need to know names in advance. Loss: `-i any` uses a "cooked" pseudo link-layer header (Linux SLL/SLL2), so you do not see the real Ethernet header or MACs. You also see a forwarded packet **twice**, once on the ingress interface before NAT and once on the egress interface after NAT, which is confusing unless you add `-e` or read the interface name (`tcpdump -i any` with SLL2 prints it).

</details>

<details>
<summary><strong>Exercise 6</strong></summary>

- **Q6.1** kube-proxy's random selection sends about 1/3 of **new** connections to the broken backend. The drop is deterministic *per backend*, but which backend a connection gets is random, so the client sees failures about 1/3 of the time. "Intermittent failures with a ratio close to 1/N" is a strong hint that one of N endpoints is broken.
- **Q6.2** The destination `10.244.2.3` is not a local address of `ckne-worker2`'s root namespace. The packet is **routed through** the node into the Pod's namespace, so it goes through `FORWARD`. `INPUT` only sees packets addressed to the node itself (for example traffic to a `hostNetwork` Pod or to a NodePort after local delivery). An `INPUT` rule with this match would never have matched, and its counter would have stayed at 0, which is itself a useful lesson in reading counters.
- **Q6.3** With `REJECT --reject-with tcp-reset`, the node answers the SYN with an RST at once. `curl` fails in milliseconds with "Connection refused" (`000`, exit code 7) instead of waiting for the 2 s timeout. Point C would show `10.244.2.3.80 > 10.244.1.5.x: Flags [R.]`. The fast, visible failure is easier to diagnose. A silent `DROP` can only be found by the **absence** of a reply, which is why the bracketing method in Q6.4 is necessary.
- **Q6.4** Capture at two points on either side of the suspected component: here the node's `eth0` (ingress) and the Pod's host-side veth (egress). "Seen at X, not seen at Y" proves that the packet was consumed **between** X and Y: in the node's forwarding path (routing, netfilter, eBPF, or the veth itself). You then narrow it down with rule counters (`iptables -v`, `iptables-save -c` diffs), and in eBPF CNIs with their own drop tooling. Move the bracket inward until only one component is left.
- **Q6.5** The kind node runs iptables with automatic selection between the `nft` and `legacy` backends. The debug image might default to the other one. With a mismatched binary, `iptables -L` shows empty or unrelated chains, and a rule you "insert" goes into a table that no other rule uses. It can still drop packets, but it is invisible to anyone who inspects the node with the node's own tools, which makes it a nasty self-inflicted fault. Always check `iptables -V` and, when in doubt, use the host's binaries.

</details>

<details>
<summary><strong>Exercise 7</strong></summary>

- **Q7.1** An IPv4 header without options is 20 bytes and an ICMP echo header is 8 bytes: 1500 − 20 − 8 = **1472**, and 1400 − 20 − 8 = **1372**. With DF set (`-M do`), the kernel refuses locally to send a larger datagram and reports `message too long, mtu=…`.
- **Q7.2** Each side advertises the largest segment it can **receive**, based on its own MTU: 1400 − 20 (IP) − 20 (TCP) = **1360** for the client, and 1460 for nginx. Each sender limits its segments to the peer's advertised MSS (and to its own MTU): nginx sends at most 1360-byte segments to the client, and the client sends at most 1360 because its own MTU is 1400. The MSS was negotiated during the handshake, so TCP never produced packets that were too large, and the transfer worked.
- **Q7.3** Pods send 1500-byte packets with DF set. Encapsulation brings them to 1550 bytes, which does not fit the 1500-byte underlay. Small requests, handshakes and short responses fit and work. Large responses or TLS certificate exchanges hang after the handshake because every full-size segment is dropped. Path MTU discovery depends on **ICMP "Fragmentation Needed" (type 3, code 4)** getting back to the sender. When that message is not generated, is filtered, or does not reach the Pod (for example because of NAT), the path becomes a PMTU black hole. The fix is to set the Pod or CNI MTU to underlay − overhead (for VXLAN, 1450), or to clamp the MSS.
- **Q7.4** `tcpdump -ni any 'icmp[icmptype] == icmp-unreach and icmp[icmpcode] == 4'` (for IPv6 the equivalent is ICMPv6 "Packet Too Big", type 2: `'icmp6 and ip6[40] == 2'`).

</details>