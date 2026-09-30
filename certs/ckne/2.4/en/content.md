# 2.4 Troubleshooting Service Network Traffic

> **Exam weight:** 4.17% · **Certification:** CKNE (Certified Kubernetes Network Engineer)
> **Prerequisites:** 2.1 Configuring L4 Services, 1.4 Troubleshooting Pod Connectivity

---

## 1. Motivation: why Service traffic fails in ways Pod traffic does not

When two Pods talk to each other directly, the data path is simple: CNI routing, then the veth and the bridge or eBPF program. If the packet does not arrive, something between two real IP addresses is broken.

A Service adds a **virtual IP that no network interface owns**. In the default kube-proxy modes, nothing answers ARP for a ClusterIP and nothing replies to ICMP for it. The address only exists as a match rule in the kernel (iptables, nftables, IPVS or eBPF maps), and each node programs that rule independently from state it watches in the API server. That creates problems that do not exist for Pod-to-Pod traffic:

| Production symptom | Why the Service layer causes it |
|---|---|
| `connection refused` on a ClusterIP while every Pod is `Running` | Pods exist but none is `Ready`, or the selector matches nothing, so kube-proxy installs a REJECT rule |
| Connections hang (timeout) only from some nodes | kube-proxy on those nodes is stale, crashed, or failed its last rule sync |
| Every Nth request fails | One endpoint in the EndpointSlice is broken (wrong `targetPort`, crashed container), and load balancing spreads requests onto it |
| UDP/DNS keeps failing after the backend was fixed | A stale conntrack entry still points at the old, dead endpoint |
| A LoadBalancer works on 2 of 5 nodes | `externalTrafficPolicy: Local`, so nodes with no local endpoint drop the traffic by design |
| The backend sees the node IP, not the client IP | SNAT (masquerade) under `externalTrafficPolicy: Cluster` |
| A Pod cannot reach itself through its own Service | Hairpin NAT is not configured on the bridge |

The key difficulty is that **the control plane can look healthy while the data plane is wrong**. `kubectl get svc` shows a perfectly valid object even when no node has programmed it correctly. Troubleshooting Service traffic means checking every translation step, from the name down to the packet, and not trusting any layer you have not verified.

---

## 2. Mental model: the translation chain

Every request to a Service goes through a chain of lookups. Each one can fail on its own, and each one has its own tool.

```
 client Pod
    │ 1. DNS: web.shop.svc.cluster.local ──► CoreDNS ──► ClusterIP 10.96.120.15
    ▼
 socket connect(10.96.120.15:80)
    │ 2. Service object: port 80 ──► targetPort 8080 (or a named port)
    │ 3. EndpointSlice: selector ──► ready Pod IPs {10.244.1.12, 10.244.2.7}
    ▼
 node kernel (client's node)
    │ 4. kube-proxy rules: DNAT 10.96.120.15:80 ──► 10.244.2.7:8080
    │ 5. conntrack: records the NAT so replies are un-DNATed
    │ 6. (optional) SNAT/masquerade for external or hairpin traffic
    ▼
 CNI data path ──► 7. NetworkPolicy enforcement ──► backend Pod :8080
```

| Layer | Owner | Where the state lives | Primary tool |
|---|---|---|---|
| 1. Name resolution | CoreDNS + kubelet (`resolv.conf`) | CoreDNS cache, Pod `/etc/resolv.conf` | `nslookup`, `dig`, CoreDNS logs |
| 2. Port mapping | Service spec | API server | `kubectl get svc -o yaml` |
| 3. Endpoint selection | EndpointSlice controller | `EndpointSlice` objects | `kubectl get endpointslices` |
| 4. Virtual IP translation | kube-proxy (or CNI kube-proxy replacement) | iptables / nftables / IPVS / eBPF maps on **each node** | `iptables-save`, `nft`, `ipvsadm`, `cilium-dbg` |
| 5. Connection tracking | Linux netfilter | `nf_conntrack` table per node | `conntrack` |
| 6. Source NAT | kube-proxy | `KUBE-POSTROUTING` / nft `masquerading` | `iptables-save -t nat`, `tcpdump` |
| 7. Policy | CNI | CNI-specific (iptables, eBPF) | `kubectl get netpol`, `hubble observe` |

**Core troubleshooting rule:** first find the **lowest layer that still works**, then move up one layer at a time. A request by Pod IP that succeeds proves layers 3–7 of the backend are fine. A request by ClusterIP that then fails points you at layers 4–6.

---

## 3. Lab environment

Every command in this document runs against the manifests below. They are complete, so you can apply them unchanged to a kind, kubeadm or managed cluster.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    kubernetes.io/metadata.name: shop
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
  labels:
    app.kubernetes.io/name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
        tier: frontend
    spec:
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
            - --udp-port=8081
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: udp-echo
              containerPort: 8081
              protocol: UDP
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
    - name: udp-echo
      protocol: UDP
      port: 8081
      targetPort: udp-echo
---
apiVersion: v1
kind: Service
metadata:
  name: web-external
  namespace: shop
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
      nodePort: 30080
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  namespace: shop
  labels:
    role: client
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command:
        - sleep
        - infinity
  terminationGracePeriodSeconds: 0
```

```
$ kubectl apply -f lab.yaml
namespace/shop created
deployment.apps/web created
service/web created
service/web-external created
pod/netshoot created

$ kubectl -n shop get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
netshoot               1/1     Running   0          40s   10.244.1.20   worker-1   <none>           <none>
web-7d9f8c6b5d-4xk2p   1/1     Running   0          40s   10.244.1.12   worker-1   <none>           <none>
web-7d9f8c6b5d-9qwlm   1/1     Running   0          40s   10.244.2.7    worker-2   <none>           <none>
web-7d9f8c6b5d-tz8rn   1/1     Running   0          40s   10.244.2.9    worker-2   <none>           <none>
```

The IPs, node names and hashes shown below come from this lab. Yours will be different.

---

## 4. A systematic method: isolate one layer at a time

Always work through the same sequence. Under exam time pressure, skipping steps costs more time than it saves.

```
┌─────────────────────────────────────────────────────────────────┐
│ Step 0  Reproduce from a client Pod (not from your laptop)      │
│ Step 1  Does the Service object exist, with the right ports?    │
│ Step 2  Does the EndpointSlice list READY endpoints?            │
│ Step 3  Does Pod IP:targetPort work directly? (bypass Service)  │
│ Step 4  Does ClusterIP:port work? (tests kube-proxy)            │
│ Step 5  Does the DNS name work? (tests CoreDNS + search path)   │
│ Step 6  From another node / another namespace? (policy, nodes)  │
│ Step 7  External path: NodePort / LoadBalancer / traffic policy │
└─────────────────────────────────────────────────────────────────┘
```

Each outcome points at the next step:

| Pod IP works | ClusterIP works | DNS name works | Most likely layer at fault |
|---|---|---|---|
| ❌ | ❌ | ❌ | Backend app, wrong `targetPort`/`containerPort`, NetworkPolicy, CNI |
| ✅ | ❌ | ❌ | Endpoints (selector/readiness), kube-proxy, conntrack |
| ✅ | ✅ | ❌ | DNS: CoreDNS, `resolv.conf`, wrong namespace in the name |
| ✅ | ✅ | ✅ (from some nodes only) | kube-proxy on a specific node, node-local conntrack |
| ✅ | ✅ | ✅ (internal only) | NodePort/LB, `externalTrafficPolicy`, cloud firewall |

### 4.1 Step 0: always test from inside the cluster

```
$ kubectl -n shop exec -it netshoot -- bash
netshoot:~# curl -s -m 3 http://web.shop.svc.cluster.local/hostname; echo
web-7d9f8c6b5d-9qwlm
```

`agnhost netexec` answers `/hostname` with the Pod name. That makes load-balancing behavior visible without any extra tooling:

```
netshoot:~# for i in $(seq 1 9); do curl -s -m 2 http://web/hostname; echo; done | sort | uniq -c
      3 web-7d9f8c6b5d-4xk2p
      4 web-7d9f8c6b5d-9qwlm
      2 web-7d9f8c6b5d-tz8rn
```

If one backend never appears, or there are fewer lines than requests, then an endpoint is missing or broken.

---

## 5. Layer by layer: diagnosis in depth

### 5.1 The Service object: ports, selector, type

```
$ kubectl -n shop get svc web -o wide
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)           AGE   SELECTOR
web    ClusterIP   10.96.120.15   <none>        80/TCP,8081/UDP   5m    app.kubernetes.io/name=web
```

Check these three fields every time:

1. **`SELECTOR`**: it must match the **Pod template labels**, not the Deployment's labels. Compare them directly:

```
$ kubectl -n shop get pods -l app.kubernetes.io/name=web --no-headers | wc -l
3
```

If this returns `0`, the selector is wrong. It is the most common Service bug.

2. **`targetPort`**: it must be a port the container actually **listens on**. A named `targetPort` (`http`) is resolved **per Pod** from `containerPort` names. That allows a rolling migration where old and new Pods listen on different numbers. It also means that a Pod missing the named port silently drops out of the endpoints.

```
$ kubectl -n shop get svc web -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}{"\t"}{.targetPort}{"\t"}{.protocol}{"\n"}{end}'
http	80	http	TCP
udp-echo	8081	udp-echo	UDP
```

3. **`protocol`**: a Service port declared as `TCP` produces no UDP rules. DNS-like workloads need both protocols declared explicitly.

> ⚠️ `containerPort` in the Pod spec is **informational** for traffic. The container can listen on ports it does not declare. The exception is **named** `targetPort` resolution, which requires the name to be declared.

### 5.2 EndpointSlices: the real source of truth

kube-proxy does not read Pods. It reads **EndpointSlices**. If an address is not in a slice, no node will ever route to it.

```
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS       ENDPOINTS                            AGE
web-k8x2d   IPv4          8080,8081   10.244.1.12,10.244.2.7,10.244.2.9   5m
```

```
$ kubectl -n shop get endpointslice web-k8x2d -o yaml
```

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: web-k8x2d
  namespace: shop
  labels:
    endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io
    kubernetes.io/service-name: web
addressType: IPv4
endpoints:
  - addresses:
      - 10.244.1.12
    conditions:
      ready: true
      serving: true
      terminating: false
    nodeName: worker-1
    targetRef:
      kind: Pod
      name: web-7d9f8c6b5d-4xk2p
      namespace: shop
    zone: zone-a
  - addresses:
      - 10.244.2.7
    conditions:
      ready: true
      serving: true
      terminating: false
    nodeName: worker-2
    targetRef:
      kind: Pod
      name: web-7d9f8c6b5d-9qwlm
      namespace: shop
    zone: zone-b
  - addresses:
      - 10.244.2.9
    conditions:
      ready: false
      serving: false
      terminating: false
    nodeName: worker-2
    targetRef:
      kind: Pod
      name: web-7d9f8c6b5d-tz8rn
      namespace: shop
    zone: zone-b
ports:
  - name: http
    port: 8080
    protocol: TCP
  - name: udp-echo
    port: 8081
    protocol: UDP
```

How to read the conditions:

| `ready` | `serving` | `terminating` | Meaning | Does kube-proxy route to it? |
|---|---|---|---|---|
| true | true | false | Healthy | Yes |
| false | false | false | Failing readiness probe | No |
| false | true | true | Shutting down but still passing readiness | Only as a fallback, when **no** ready endpoints remain (terminating-endpoint fallback, mainly relevant with `Local` traffic policies) |
| false | false | true | Shutting down and not serving | No |

Things to check:

- **Empty `endpoints:`** means the selector matches nothing, or every Pod is unready.
- **Endpoint present with `ready: false`** means a readiness-probe problem. Run `kubectl describe pod` and look at the `Readiness probe failed` events.
- **`ports:` numbers**: here the slice shows `8080`, the *resolved* target port. If this number is not what the application listens on, you have found the bug.
- **No EndpointSlice at all** for a Service *without* a selector is expected. Those Services need slices you manage yourself (see §5.2.1).

> The legacy `v1 Endpoints` API was deprecated in Kubernetes v1.33 in favor of EndpointSlice. `kubectl get endpoints` still works but prints a deprecation warning, and it truncates to 1000 addresses. Use EndpointSlices for diagnosis.

#### 5.2.1 Selector-less Services (external backends)

A Service with no `selector` gets no automatic slices. You have to create them yourself, with the label `kubernetes.io/service-name` and a port **name** that matches the Service port name.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-db
  namespace: shop
spec:
  ports:
    - name: pg
      protocol: TCP
      port: 5432
      targetPort: 5432
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-db-1
  namespace: shop
  labels:
    kubernetes.io/service-name: legacy-db
    endpointslice.kubernetes.io/managed-by: platform-team
addressType: IPv4
ports:
  - name: pg
    protocol: TCP
    port: 5432
endpoints:
  - addresses:
      - 192.168.50.20
    conditions:
      ready: true
```

A typical failure is a port `name` in the slice (`postgres`) that does not match the Service port name (`pg`). kube-proxy then pairs nothing, and clients get `connection refused`.

#### 5.2.2 `publishNotReadyAddresses`

StatefulSets that need peer discovery before becoming ready (etcd, Cassandra, ZooKeeper) often use a headless Service with `publishNotReadyAddresses: true`. If that field is set on a normal client-facing Service, **unready Pods receive traffic**. The symptom looks like "intermittent 5xx during rollouts". Check the field:

```
$ kubectl -n shop get svc web -o jsonpath='{.spec.publishNotReadyAddresses}{"\n"}'
false
```

### 5.3 Bypass the Service: hit the Pod IP directly

This single test tells you whether the fault is in the backend or in the Service machinery:

```
netshoot:~# curl -s -m 3 http://10.244.2.7:8080/hostname; echo
web-7d9f8c6b5d-9qwlm

netshoot:~# nc -zv -w 2 10.244.2.9 8080
nc: 10.244.2.9 (10.244.2.9:8080): Connection refused
```

`10.244.2.9` refuses connections: the application is not listening, which agrees with `ready: false`. Confirm from inside the Pod what is listening:

```
$ kubectl -n shop debug -it web-7d9f8c6b5d-tz8rn --image=nicolaka/netshoot:v0.13 --target=web -- ss -ltnup
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096    127.0.0.1:8080       0.0.0.0:*          users:(("agnhost",pid=1,fd=3))
```

`127.0.0.1:8080` is a **classic production bug**: the app binds to loopback, so it is reachable only from inside its own network namespace. Neither the Pod IP nor the Service can reach it. The fix belongs in the application (bind to `0.0.0.0` or `::`), not in Kubernetes.

> `kubectl port-forward svc/web 8080:80` is **not** a Service test. It resolves the Service to *one* Pod and tunnels through the API server and kubelet into the Pod's network namespace, where it connects to localhost. That bypasses kube-proxy, ClusterIP, NetworkPolicy and the loopback-binding problem. It is useful for proving the application works, and useless for proving the Service works.

### 5.4 ClusterIP: testing kube-proxy

```
netshoot:~# curl -s -m 3 http://10.96.120.15/hostname; echo
web-7d9f8c6b5d-4xk2p
```

Here is what each failure tells you:

| Symptom | Meaning |
|---|---|
| `Connection refused` immediately | kube-proxy installed a **REJECT** rule because the Service has **no ready endpoints** |
| Hang, then timeout | Rules exist but packets are lost: the backend is unreachable via CNI, a NetworkPolicy drops them, or rules are **missing** on this node (no Service rule at all means the packet is routed toward a non-existent IP) |
| Works intermittently | One backend in the rotation is bad, or stale rules exist on one node |
| `ping 10.96.120.15` fails | **Expected** in iptables/nftables mode, because the VIP only matches port rules. Do not use ping to test a Service. |

#### 5.4.1 Is kube-proxy alive and syncing?

```
$ kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
NAME               READY   STATUS    RESTARTS   AGE   IP              NODE
kube-proxy-5hq8r   1/1     Running   0          3d    192.168.178.11  worker-1
kube-proxy-lm2wz   1/1     Running   0          3d    192.168.178.12  worker-2
kube-proxy-x7c4n   1/1     Running   0          3d    192.168.178.10  cp-1

$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^(mode|clusterCIDR):'
clusterCIDR: 10.244.0.0/16
mode: iptables

$ kubectl -n kube-system logs kube-proxy-5hq8r --tail=20
I0930 09:12:44.118902       1 server_linux.go:66] "Using iptables proxy"
I0930 09:12:44.131277       1 proxier.go:245] "Setting route_localnet=1 to allow node-ports on localhost"
I0930 09:12:44.201553       1 shared_informer.go:320] Caches are synced for service config
I0930 09:12:44.201602       1 shared_informer.go:320] Caches are synced for endpoint slice config
```

An empty `mode:` means the platform default, which is `iptables` on Linux.

kube-proxy exposes a health endpoint on port **10256** and metrics on port **10249** (bound to `127.0.0.1` by default, so query them from the node):

```
$ kubectl debug node/worker-1 -it --image=nicolaka/netshoot:v0.13 --profile=sysadmin
root@worker-1:/# curl -s http://127.0.0.1:10256/healthz; echo
{"lastUpdated": "2026-09-30 09:40:02.118 +0000 UTC","currentTime": "2026-09-30 09:40:05.771 +0000 UTC","nodeEligible": true}

root@worker-1:/# curl -s http://127.0.0.1:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules_(last_timestamp_seconds|duration_seconds_count|iptables_total)'
kubeproxy_sync_proxy_rules_duration_seconds_count 1893
kubeproxy_sync_proxy_rules_iptables_total{table="filter"} 11
kubeproxy_sync_proxy_rules_iptables_total{table="nat"} 64
kubeproxy_sync_proxy_rules_last_timestamp_seconds 1.7592264021e+09
```

If `lastUpdated` falls far behind `currentTime`, or `last_timestamp_seconds` stops advancing, then kube-proxy on that node is stuck. Every Service change since then is invisible **on that node only**. A pattern of "fails only from Pods on worker-3" almost always has this cause.

> `kubectl debug node/...` runs the container in the node's host network and PID namespaces, with the node's root filesystem mounted at `/host`. `--profile=sysadmin` grants the privileges `iptables`/`nft`/`conntrack` need. When you are done, delete the leftover `node-debugger-*` Pod.

#### 5.4.2 iptables mode: tracing the DNAT chain

```
root@worker-1:/# iptables-save -t nat | grep 'shop/web:http'
-A KUBE-SERVICES -d 10.96.120.15/32 -p tcp -m comment --comment "shop/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-5JZ3V6QAY4ZHR3DQ
-A KUBE-SVC-5JZ3V6QAY4ZHR3DQ ! -s 10.244.0.0/16 -d 10.96.120.15/32 -p tcp -m comment --comment "shop/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-5JZ3V6QAY4ZHR3DQ -m comment --comment "shop/web:http -> 10.244.1.12:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-QGH7N2MZ3RLPXW4K
-A KUBE-SVC-5JZ3V6QAY4ZHR3DQ -m comment --comment "shop/web:http -> 10.244.2.7:8080" -j KUBE-SEP-TL4VJQ6D7C2YHMRA
-A KUBE-SEP-QGH7N2MZ3RLPXW4K -s 10.244.1.12/32 -m comment --comment "shop/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-QGH7N2MZ3RLPXW4K -p tcp -m comment --comment "shop/web:http" -m tcp -j DNAT --to-destination 10.244.1.12:8080
-A KUBE-SEP-TL4VJQ6D7C2YHMRA -s 10.244.2.7/32 -m comment --comment "shop/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-TL4VJQ6D7C2YHMRA -p tcp -m comment --comment "shop/web:http" -m tcp -j DNAT --to-destination 10.244.2.7:8080
```

Reading the chain:

1. `KUBE-SERVICES` matches `dst=ClusterIP, dport=80` and jumps to the per-Service chain `KUBE-SVC-*`.
2. The `! -s 10.244.0.0/16 ... KUBE-MARK-MASQ` rule marks traffic that does **not** come from the Pod CIDR (for example a host-network process) for SNAT, so replies return through this node.
3. Endpoints are chosen with `statistic --mode random`. The probabilities are **cascading**: with N endpoints the first rule is 1/N, the next 1/(N−1), and so on, and the last rule has no probability because it catches everything left. The result is uniform distribution.
4. `KUBE-SEP-*` performs the DNAT. The `-s <own IP> -j KUBE-MARK-MASQ` rule handles **hairpin**: a Pod that reaches itself through its own Service is SNATed so the reply does not short-circuit.
5. Only **two** endpoints appear, because `10.244.2.9` is not ready. The rules match the EndpointSlice, and that is the consistency check to make.

When the Service has **no** ready endpoints, the rule is in the **filter** table:

```
root@worker-1:/# iptables-save -t filter | grep 'shop/web'
-A KUBE-SERVICES -d 10.96.120.15/32 -p tcp -m comment --comment "shop/web:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

That is why "no endpoints" shows up as an **immediate** `connection refused` and not as a timeout.

Count packets hitting a rule while you reproduce the problem:

```
root@worker-1:/# iptables -t nat -L KUBE-SVC-5JZ3V6QAY4ZHR3DQ -v -n
Chain KUBE-SVC-5JZ3V6QAY4ZHR3DQ (1 references)
 pkts bytes target                     prot opt in  out  source          destination
    0     0 KUBE-MARK-MASQ             6    --  *   *   !10.244.0.0/16   10.96.120.15   /* shop/web:http cluster IP */ tcp dpt:80
   14   840 KUBE-SEP-QGH7N2MZ3RLPXW4K  0    --  *   *    0.0.0.0/0       0.0.0.0/0      /* shop/web:http -> 10.244.1.12:8080 */ statistic mode random probability 0.50000000000
   11   660 KUBE-SEP-TL4VJQ6D7C2YHMRA  0    --  *   *    0.0.0.0/0       0.0.0.0/0      /* shop/web:http -> 10.244.2.7:8080 */
```

Counters only increase for the **first** packet of each connection, because the NAT table is consulted once per flow and conntrack handles the rest. A counter stuck at zero while you send requests means the traffic never reaches this node's NAT path, or it matches an earlier rule.

#### 5.4.3 nftables mode

The `nftables` mode (GA since Kubernetes v1.33) keeps everything in its own tables, `ip kube-proxy` and `ip6 kube-proxy`, and looks Services up with **verdict maps** instead of a linear chain. This is the main reason it scales better than iptables mode.

```
root@worker-1:/# nft list map ip kube-proxy service-ips | grep 'shop/web'
		10.96.120.15 . tcp . 80 : goto service-5JZ3V6QA-shop/web/tcp/http,
		10.96.120.15 . udp . 8081 : goto service-HB3N4XQK-shop/web/udp/udp-echo,

root@worker-1:/# nft list chain ip kube-proxy service-5JZ3V6QA-shop/web/tcp/http
table ip kube-proxy {
	chain service-5JZ3V6QA-shop/web/tcp/http {
		ip daddr 10.96.120.15 tcp dport 80 ip saddr != 10.244.0.0/16 jump mark-for-masquerade
		numgen random mod 2 vmap { 0 : goto endpoint-QGH7N2MZ-shop/web/tcp/http__10.244.1.12/8080, 1 : goto endpoint-TL4VJQ6D-shop/web/tcp/http__10.244.2.7/8080 }
	}
}

root@worker-1:/# nft list map ip kube-proxy no-endpoint-services
table ip kube-proxy {
	map no-endpoint-services {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "vmap to drop or reject packets to services with no endpoints"
		elements = { 10.96.44.201 . tcp . 443 comment "shop/legacy-api:https" : goto reject-chain }
	}
}
```

> In nftables mode, `iptables-save` shows **nothing** for Services. If you grep iptables on an nftables-mode node, you will wrongly conclude the rules are missing. Check `mode` in the kube-proxy ConfigMap first.

#### 5.4.4 IPVS mode

```
root@worker-1:/# ipvsadm -Ln -t 10.96.120.15:80
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.120.15:80 rr
  -> 10.244.1.12:8080             Masq    1      0          3
  -> 10.244.2.7:8080              Masq    1      1          2

root@worker-1:/# ip addr show kube-ipvs0 | grep 10.96.120.15
    inet 10.96.120.15/32 scope global kube-ipvs0
```

In IPVS mode the ClusterIP **is** bound to the dummy interface `kube-ipvs0`, so `ping <ClusterIP>` gets an answer from the local node. That tells you nothing about the backends, so do not read a successful ping as "the Service works". The IPVS mode was deprecated in recent Kubernetes releases in favor of nftables. You will still find it on existing clusters.

#### 5.4.5 kube-proxy mode comparison for troubleshooting

| Aspect | iptables | nftables | IPVS | eBPF (e.g. Cilium KPR) |
|---|---|---|---|---|
| Where to look | `iptables-save -t nat` / `-t filter` | `nft list table ip kube-proxy` | `ipvsadm -Ln` + iptables for masquerade | `cilium-dbg service list`, `cilium-dbg bpf lb list` |
| Service lookup cost | O(n) chain walk | O(1) verdict map | O(1) hash | O(1) BPF map |
| Rule sync at scale | Slow, full-table restore with thousands of Services | Incremental, fast | Fast | Fast, map updates |
| ClusterIP answers ping | No | No | Yes (`kube-ipvs0`) | Depends on configuration; generally no |
| No-endpoint behavior | REJECT in filter table | `no-endpoint-services` map → reject | Virtual server with no real servers, which **hangs** | BPF drop/reject, visible in Hubble |
| Load-balancing algorithm | Random (uniform) | Random (uniform) | rr, lc, sh, and others | Random / Maglev |
| Visible in `tcpdump` on host | DNAT already applied at PREROUTING/OUTPUT | Same | Same | Often DNAT at the **socket** (connect-time), so no VIP ever appears on the wire |
| Main pitfall | Grepping the wrong table | Grepping iptables at all | Mixed IPVS and iptables state | kube-proxy still running alongside, so double programming |

### 5.5 conntrack: fixed backends that still fail

Every NATed flow is recorded in `nf_conntrack`. For **UDP** there is no connection teardown, so an entry lives until its timeout. If a client keeps sending from the same source port (DNS resolvers, syslog, StatsD), it can **stay pinned to a dead backend**.

```
root@worker-1:/# conntrack -L -p udp --orig-dst 10.96.120.15 2>/dev/null
udp      17 28 src=10.244.1.20 dst=10.96.120.15 sport=41822 dport=8081 [UNREPLIED] src=10.244.2.9 dst=10.244.1.20 sport=8081 dport=41822 mark=0 use=1
conntrack v1.4.8 (conntrack-tools): 1 flow entries have been shown.
```

How to read the entry: the original tuple went to the VIP, and the **reply tuple** shows the backend chosen by DNAT (`10.244.2.9`, the broken Pod). `[UNREPLIED]` means it never answered.

kube-proxy clears UDP conntrack entries for removed endpoints itself. If that cleanup fails (for example when the `conntrack` binary or the netlink permissions are missing in older kube-proxy images), delete the entries by hand:

```
root@worker-1:/# conntrack -D -p udp --orig-dst 10.96.120.15 --orig-port-dst 8081
udp      17 25 src=10.244.1.20 dst=10.96.120.15 sport=41822 dport=8081 [UNREPLIED] src=10.244.2.9 dst=10.244.1.20 sport=8081 dport=41822 mark=0 use=1
conntrack v1.4.8 (conntrack-tools): 1 flow entries have been deleted.
```

Watch the table for exhaustion and insert races:

```
root@worker-1:/# sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_count = 18342
net.netfilter.nf_conntrack_max = 262144

root@worker-1:/# conntrack -S | head -3
cpu=0   found=0 invalid=412 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=37
cpu=1   found=0 invalid=388 insert=0 insert_failed=27 drop=27 early_drop=0 error=0 search_restart=41
cpu=2   found=0 invalid=401 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=29
```

| Counter | Production meaning |
|---|---|
| `nf_conntrack_count` near `_max` | Table full: new flows are dropped (`nf_conntrack: table full, dropping packet` in `dmesg`) |
| `insert_failed` / `drop` rising | Race when two packets of a new UDP flow are DNATed in parallel. The classic cause of the "5-second DNS delay", because glibc sends A and AAAA queries from the same socket |
| `invalid` rising | Asymmetric routing or out-of-window TCP. Often a sign that replies bypass the node that did the DNAT |

Mitigations for the DNS race: NodeLocal DNSCache, `options single-request-reopen` in `dnsConfig`, or TCP for DNS.

### 5.6 DNS: the name layer

If the ClusterIP works but the name does not, the problem is DNS. See the dedicated DNS topic for depth. The Service-specific checks are:

```
netshoot:~# cat /etc/resolv.conf
search shop.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5

netshoot:~# dig +short web.shop.svc.cluster.local
10.96.120.15

netshoot:~# dig +short web.payments.svc.cluster.local
netshoot:~# echo $?
0
```

An empty answer with exit code 0 means NXDOMAIN: there is no `web` Service in `payments`. The short name `web` only resolves inside the **client's own namespace**. Cross-namespace calls need at least `web.shop`.

SRV records confirm the port **names** a client library will discover:

```
netshoot:~# dig +short SRV _http._tcp.web.shop.svc.cluster.local
0 100 80 web.shop.svc.cluster.local.
```

For a **headless** Service (`clusterIP: None`), DNS returns the Pod IPs directly. kube-proxy is **not** involved, so load balancing happens on the client side:

```
netshoot:~# dig +short web-headless.shop.svc.cluster.local
10.244.1.12
10.244.2.7
```

A headless Service that returns no records is **always** an endpoint problem (selector or readiness), because DNS is built directly from the EndpointSlices.

If DNS itself fails, check its dependencies:

```
$ kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
NAME             ADDRESSTYPE   PORTS        ENDPOINTS                 AGE
kube-dns-wv2kq   IPv4          53,53,9153   10.244.0.3,10.244.0.4     30d

$ kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5
[INFO] 10.244.1.20:41822 - 18830 "A IN web.shop.svc.cluster.local. udp 44 false 512" NOERROR qr,aa,rd 86 0.000121s
```

DNS is itself a Service (`kube-dns`, typically `10.96.0.10`). Every failure mode in this document can therefore break name resolution cluster-wide.

### 5.7 NetworkPolicy: silent drops

NetworkPolicy is evaluated against the **post-DNAT** destination, meaning the Pod IP and the **target port**, not the Service port. This mistake appears constantly:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-clients
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 80
```

The policy allows port **80**, but after DNAT the packet arrives on **8080**. Every Service request is dropped as a **timeout**, not a refusal. The fix is to allow the container port (a named port also works, because NetworkPolicy resolves it against the Pod):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-clients
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: http
```

Other policy traps with Services:

- **Egress default-deny** on the client namespace also blocks **DNS**. Allow UDP and TCP 53 to `kube-system`/`k8s-app: kube-dns`, or name resolution fails before the Service is even contacted.
- **NodePort/LoadBalancer + `externalTrafficPolicy: Cluster`**: the backend sees the **node IP** (SNAT), so an `ipBlock` for the external client never matches. Use `Local` to preserve the client IP.
- Policies are enforced by the **CNI**. On a CNI without policy support (plain flannel), policies are accepted by the API and have no effect.

With Cilium, drops are directly visible:

```
$ hubble observe --namespace shop --verdict DROPPED --last 5
Sep 30 09:52:11.402: shop/netshoot:50312 (ID:18233) <> shop/web-7d9f8c6b5d-9qwlm:8080 (ID:40211) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 09:52:11.402: shop/netshoot:50312 (ID:18233) <> shop/web-7d9f8c6b5d-9qwlm:8080 (ID:40211) Policy denied DROPPED (TCP Flags: SYN)
```

The destination is shown as `web-...:8080`, the Pod and target port, which confirms that the DNAT already happened.

### 5.8 Traffic policies and external paths

#### 5.8.1 `externalTrafficPolicy`

| | `Cluster` (default) | `Local` |
|---|---|---|
| Nodes that accept NodePort/LB traffic | All | Only nodes with a **ready local endpoint** (others drop it) |
| Source IP seen by the Pod | Node IP (SNAT) | Real client IP |
| Extra hop | Possible (node → other node) | Never |
| Load distribution | Even across Pods | Even across **nodes**, so Pods on crowded nodes get less |
| Health check | None needed | `healthCheckNodePort` answers 200/503 for the LB |
| Typical failure | "Why is the client IP wrong?" | "Works from some nodes only", "LB marks half the nodes unhealthy" |

```
$ kubectl -n shop get svc web-external -o jsonpath='{.spec.externalTrafficPolicy}{"\t"}{.spec.healthCheckNodePort}{"\n"}'
Local	31742
```

`healthCheckNodePort` is only allocated for `type: LoadBalancer`. On this NodePort Service it is empty. For a LoadBalancer Service, probe it on each node:

```
$ curl -s http://192.168.178.11:31742/healthz
{"service": {"namespace": "shop","name": "web-lb"},"localEndpoints": 1,"serviceProxyHealthy": true}
$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.178.10:31742/healthz
503
```

`cp-1` has no local endpoint, so it returns `503` and the cloud LB takes it out of rotation. That is the **correct** behavior. With `NodePort` and `Local`, **your** client must pick a node that runs an endpoint:

```
$ curl -s -m 3 http://192.168.178.11:30080/hostname; echo
web-7d9f8c6b5d-4xk2p
$ curl -s -m 3 http://192.168.178.10:30080/hostname; echo
curl: (28) Connection timed out after 3001 milliseconds
```

#### 5.8.2 `internalTrafficPolicy: Local`

This restricts **in-cluster** traffic to endpoints on the same node. It is intended for node-local agents (log collectors, NodeLocal DNS). It is a common cause of "works on worker-1, fails on worker-2", because a client on a node with no local endpoint gets **no fallback** and its traffic is dropped.

```
$ kubectl get svc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ITP:.spec.internalTrafficPolicy,ETP:.spec.externalTrafficPolicy | grep -w Local
shop          web-external   Cluster   Local
monitoring    node-agent     Local     <none>
```

#### 5.8.3 `trafficDistribution` and topology

`spec.trafficDistribution: PreferClose` is a **preference** (same-zone endpoints first, then others), unlike the hard filter of `internalTrafficPolicy`. When distribution looks skewed, look at the `hints` in the EndpointSlice:

```
$ kubectl -n shop get endpointslice -l kubernetes.io/service-name=web -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.zone}{"\t"}{.hints.forZones[*].name}{"\n"}{end}'
10.244.1.12	zone-a	zone-a
10.244.2.7	zone-b	zone-b
```

A zone with a single endpoint concentrates all of that zone's traffic on it. This is deliberate (it saves cross-zone cost), but it can overload that one endpoint.

#### 5.8.4 Session affinity

`sessionAffinity: ClientIP` pins a source IP to one endpoint for `timeoutSeconds` (default 10800 = 3 h). Behind a SNAT hop, every client shares the node IP, so **every request goes to one Pod**. The usual report is "the load balancer doesn't balance".

```
$ kubectl -n shop get svc web -o jsonpath='{.spec.sessionAffinity}{"\n"}'
None
```

In iptables mode, affinity uses the `recent` module (`-m recent --rcheck --seconds 10800 --reap --name KUBE-SEP-...`), which you can see in `iptables-save`.

### 5.9 Hairpin traffic

A Pod that calls **its own** Service can be load-balanced back to itself. Without hairpin NAT, the reply leaves with the Pod's own IP as source, the client socket does not recognize it, and the connection hangs.

```
$ kubectl -n shop exec web-7d9f8c6b5d-4xk2p -- /agnhost connect --timeout=3s web:80
TIMEOUT
```

Check the bridge (for bridge-based CNIs):

```
root@worker-1:/# for p in /sys/class/net/cni0/brif/*/hairpin_mode; do echo "$p $(cat $p)"; done
/sys/class/net/cni0/brif/veth3a1f9c02/hairpin_mode 0
/sys/class/net/cni0/brif/veth7bc2d418/hairpin_mode 1
```

The fix belongs in the CNI configuration (`"hairpinMode": true` for the bridge plugin) or in the kubelet `hairpinMode` setting (`hairpin-veth` / `promiscuous-bridge`). It is not a per-Service setting.

### 5.10 eBPF data planes (Cilium kube-proxy replacement)

With a kube-proxy replacement, there are **no** iptables Service rules. Check the BPF load-balancer maps instead:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A3 10.96.120.15
14   10.96.120.15:80/TCP      ClusterIP      1 => 10.244.1.12:8080/TCP (active)
                                             2 => 10.244.2.7:8080/TCP (active)
15   10.96.120.15:8081/UDP    ClusterIP      1 => 10.244.1.12:8081/UDP (active)
                                             2 => 10.244.2.7:8081/UDP (active)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement
KubeProxyReplacement:    True   [eth0   192.168.178.11 fe80::5054:ff:fe12:3456 (Direct Routing)]

$ hubble observe --namespace shop --to-service shop/web --last 3
Sep 30 09:58:02.113: shop/netshoot:51022 (ID:18233) -> shop/web-7d9f8c6b5d-4xk2p:8080 (ID:40211) to-endpoint FORWARDED (TCP Flags: SYN)
```

`kubectl exec ds/cilium` picks **one** agent Pod. To inspect a specific node, run `kubectl -n kube-system get pods -l k8s-app=cilium -o wide` and exec into the Pod on that node.

Two Cilium-specific traps:

- **Socket-level LB**: Cilium rewrites the destination at `connect()` time, so `tcpdump` in the client Pod shows the **backend Pod IP**, never the ClusterIP. That is expected.
- **kube-proxy still deployed** alongside `KubeProxyReplacement=True` produces two programmers for the same VIPs. Remove the kube-proxy DaemonSet and flush its rules (`kube-proxy --cleanup` / `iptables-save | grep -v KUBE | iptables-restore`) during migration.

### 5.11 Packet capture: final proof

When every piece of state looks correct and traffic still fails, capture it. Run a capture **on the backend's node, inside the backend Pod's namespace**:

```
$ kubectl -n shop debug -it web-7d9f8c6b5d-9qwlm --image=nicolaka/netshoot:v0.13 --target=web -- tcpdump -ni eth0 -c 6 'tcp port 8080'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
09:59:10.401122 IP 10.244.1.20.51204 > 10.244.2.7.8080: Flags [S], seq 3013398112, win 64860, length 0
09:59:10.401160 IP 10.244.2.7.8080 > 10.244.1.20.51204: Flags [S.], seq 1188270015, ack 3013398113, win 64308, length 0
09:59:10.401902 IP 10.244.1.20.51204 > 10.244.2.7.8080: Flags [.], ack 1, win 507, length 0
```

What each capture result means:

| What you see at the backend | Conclusion |
|---|---|
| SYN arrives, SYN-ACK leaves, handshake completes | Service path is fine; the problem is in the application or client |
| SYN arrives, **RST** leaves | Nothing listens on that port (wrong `targetPort`, loopback bind) |
| SYN arrives, **no reply** | Local firewall/policy in the Pod, or app accept queue full |
| **Nothing** arrives | DNAT goes elsewhere, CNI routing broken, or policy drops it upstream |
| Source is a **node IP** instead of the client | SNAT: `externalTrafficPolicy: Cluster` or masquerade from the host network |

---

## 6. Failure catalog: symptom → cause → fix

| # | Symptom | Diagnostic evidence | Root cause | Fix |
|---|---|---|---|---|
| 1 | Immediate `connection refused` on ClusterIP | EndpointSlice empty; filter-table REJECT "has no endpoints" | Selector ≠ Pod labels | Correct `spec.selector` |
| 2 | Immediate refusal, Pods Running | Endpoints `ready: false` | Readiness probe failing | Fix the probe or the app |
| 3 | Timeout on Service, Pod IP also times out | tcpdump shows SYN, no reply, or nothing | NetworkPolicy allows the Service port instead of the target port | Allow `targetPort` / named port |
| 4 | Refused on Pod IP and Service | `ss -ltn` shows `127.0.0.1:8080` | App binds to loopback | Bind `0.0.0.0` |
| 5 | Refused on Pod IP:targetPort | App listens on a different port | `targetPort` wrong | Correct `targetPort` or use a named port |
| 6 | Every Nth request fails | One backend fails a direct test | Broken Pod without readiness probe | Add a readiness probe |
| 7 | Fails only from Pods on one node | kube-proxy `healthz` stale / no rule on that node | kube-proxy stuck or crashlooping | Restart it and check logs (API connectivity, iptables lock) |
| 8 | UDP fails after the backend was replaced | conntrack reply tuple points to a dead IP | Stale UDP conntrack | `conntrack -D --orig-dst <VIP>`; check kube-proxy cleanup |
| 9 | Short name fails, FQDN works | `resolv.conf` search list | Cross-namespace call using the short name | Use `svc.ns` or the FQDN |
| 10 | Intermittent 5 s DNS latency | `insert_failed` rising | conntrack UDP race | NodeLocal DNSCache / `single-request-reopen` |
| 11 | NodePort works on some nodes | `externalTrafficPolicy: Local` | Nodes without a local endpoint drop traffic | Expected: target correct nodes, or use `Cluster` |
| 12 | In-cluster works on some nodes | `internalTrafficPolicy: Local` | No local endpoint, no fallback | Set `Cluster`, or run a DaemonSet |
| 13 | Backend logs node IP as the client | `externalTrafficPolicy: Cluster` | SNAT | Set `Local` (and accept its trade-offs) |
| 14 | All traffic to one Pod | `sessionAffinity: ClientIP` behind NAT | Affinity keyed on the shared SNAT IP | Remove affinity or preserve the source IP |
| 15 | Pod cannot reach its own Service | bridge `hairpin_mode 0` | Hairpin not configured | CNI `hairpinMode: true` |
| 16 | Unready Pods receive traffic | `publishNotReadyAddresses: true` | Field misused on a client-facing Service | Remove it; keep it only on the peer-discovery headless Service |
| 17 | Selector-less Service refuses | Slice port name ≠ Service port name | Manual EndpointSlice mismatch | Match port `name` and label `kubernetes.io/service-name` |
| 18 | UDP Service unreachable, TCP fine | Service port `protocol: TCP` only | Missing UDP port declaration | Add a UDP port entry |
| 19 | LoadBalancer `EXTERNAL-IP <pending>` forever | Service events; no LB controller | No cloud controller / MetalLB | Install and configure an LB implementation |

---

## 7. Hands-on break/fix drills

Apply each broken manifest on top of the lab, diagnose it using only the methodology in §4, then apply the fix.

### Drill A: selector typo

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: frontend
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
    - name: udp-echo
      protocol: UDP
      port: 8081
      targetPort: udp-echo
```

```
netshoot:~# curl -s -m 3 http://web/hostname
curl: (7) Failed to connect to web port 80 after 1 ms: Couldn't connect to server

$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
web-k8x2d   IPv4          <unset>   <none>      12m

$ kubectl -n shop get pods -l app.kubernetes.io/name=frontend
No resources found in shop namespace.
```

**Fix:** patch the selector back.

```
$ kubectl -n shop patch svc web --type=merge -p '{"spec":{"selector":{"app.kubernetes.io/name":"web"}}}'
service/web patched
```

### Drill B: numeric targetPort mismatch

```
$ kubectl -n shop patch svc web --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9090}]'
service/web patched

netshoot:~# curl -s -m 3 http://web/hostname
curl: (7) Failed to connect to web port 80 after 2 ms: Couldn't connect to server

$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS       ENDPOINTS                            AGE
web-k8x2d   IPv4          9090,8081   10.244.1.12,10.244.2.7,10.244.2.9   14m
```

The endpoints are **populated**, so the selector is fine. The failure is a refusal delivered **by the Pod** (TCP RST), which tcpdump on the backend confirms. Restore with `"value":"http"`.

### Drill C: NetworkPolicy on the wrong port

Apply the first `web-allow-clients` policy from §5.7:

```
netshoot:~# curl -s -m 3 http://web/hostname
curl: (28) Connection timed out after 3001 milliseconds

netshoot:~# curl -s -m 3 http://10.244.2.7:8080/hostname
curl: (28) Connection timed out after 3002 milliseconds

$ kubectl -n shop get netpol
NAME                POD-SELECTOR                  AGE
web-allow-clients   app.kubernetes.io/name=web    30s
```

A timeout on **both** the Service and the Pod IP points below kube-proxy. Apply the corrected policy with `port: http`.

### Drill D: externalTrafficPolicy Local on a node without endpoints

```
$ kubectl -n shop scale deploy web --replicas=1
deployment.apps/web scaled

$ kubectl -n shop get pods -l app.kubernetes.io/name=web -o wide --no-headers | awk '{print $7}'
worker-1

$ for n in 192.168.178.11 192.168.178.12; do echo -n "$n: "; curl -s -m 2 -o /dev/null -w '%{http_code}\n' http://$n:30080/hostname || echo timeout; done
192.168.178.11: 200
192.168.178.12: 000
timeout
```

This is not a bug. Explain it, then decide: switch to `Cluster` (lose the client IP) or keep `Local` and route only to nodes with endpoints (via LB health checks).

---

## 8. Verification checklist

Run this after every fix. Do not stop at "curl worked once".

```
# 1. Object and endpoints agree
$ kubectl -n shop get svc web -o wide
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web -o wide

# 2. All ready endpoints are individually reachable on the target port
$ for ip in $(kubectl -n shop get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{" "}{end}'); do
    kubectl -n shop exec netshoot -- curl -s -m 2 -o /dev/null -w "$ip %{http_code}\n" http://$ip:8080/hostname
  done
10.244.1.12 200
10.244.2.7 200
10.244.2.9 200

# 3. Load balancing reaches every backend through the VIP
$ kubectl -n shop exec netshoot -- sh -c 'for i in $(seq 1 30); do curl -s -m 2 http://web/hostname; echo; done' | sort | uniq -c

# 4. DNS: short name, namespaced name, FQDN
$ kubectl -n shop exec netshoot -- sh -c 'for n in web web.shop web.shop.svc.cluster.local; do echo "$n -> $(dig +short $n)"; done'

# 5. From a client on EVERY node (catches per-node kube-proxy drift)
$ kubectl get nodes -o name | cut -d/ -f2 | while read node; do
    kubectl -n shop run probe-$node --rm -i --restart=Never --image=nicolaka/netshoot:v0.13 \
      --overrides="{\"spec\":{\"nodeName\":\"$node\"}}" -- curl -s -m 3 -o /dev/null -w "$node %{http_code}\n" http://web.shop/hostname
  done

# 6. No stale kube-proxy anywhere
$ kubectl -n kube-system get pods -l k8s-app=kube-proxy
```

Expected results: every endpoint returns `200`, every backend appears in step 3, all three names resolve to the same ClusterIP, and every node returns `200` in step 5. Step 5 also works as a regression test after upgrading kube-proxy or the CNI.

---

## 9. Exam-oriented summary

- **Endpoints first.** `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` answers more Service questions than any other single command.
- **Refused ≠ timeout.** An immediate refusal means no endpoints (REJECT rule) or nothing listening (RST from the Pod). A timeout means packets are lost: policy, routing, traffic policy, or missing rules.
- **Bypass layers deliberately**: Pod IP → ClusterIP → DNS name → NodePort. The first layer that fails is your culprit.
- **NetworkPolicy sees `targetPort`**, never the Service `port`.
- **Know which data plane you are on** (`mode` in the kube-proxy ConfigMap, or `cilium-dbg status`) before grepping for rules.
- **Do not ping ClusterIPs**, and do not use `port-forward` to prove a Service works.
- **`Local` traffic policies drop by design** on nodes without endpoints.
- **UDP plus a changed backend** calls for checking conntrack.

---

## References

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Service concepts: https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and Service proxies (kube-proxy modes, traffic policies, session affinity): https://kubernetes.io/docs/reference/networking/virtual-ips/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Service ClusterIP allocation: https://kubernetes.io/docs/concepts/services-networking/cluster-ip-allocation/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Debugging DNS resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Using Source IP (externalTrafficPolicy): https://kubernetes.io/docs/tutorials/services/source-ip/
- Service internal traffic policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- kube-proxy command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Debugging running Pods (`kubectl debug`, node debugging): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Cilium troubleshooting: https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Hubble observability: https://docs.cilium.io/en/stable/observability/hubble/
- conntrack-tools user manual: https://conntrack-tools.netfilter.org/manual.html
- nftables wiki: https://wiki.nftables.org/