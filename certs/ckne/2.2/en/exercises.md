# Topic 2.2 — Understanding kube-proxy and CNI Alternatives: Guided Exercises

These exercises follow one Service through every dataplane Kubernetes supports: kube-proxy in `iptables`, `nftables` and `ipvs` mode, and then an eBPF CNI (Cilium) that replaces kube-proxy entirely. In each mode you look at the rules the node actually programs, rather than reading a description of them.

**Official references**

- CKNE exam page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Virtual IPs and Service Proxies: https://kubernetes.io/docs/reference/networking/virtual-ips/
- kube-proxy command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- kube-proxy configuration API (v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Service Internal Traffic Policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- NFTables mode for kube-proxy (Kubernetes blog): https://kubernetes.io/blog/2025/02/28/nftables-kube-proxy/
- kind configuration (kube-proxy mode, disabling the default CNI): https://kind.sigs.k8s.io/docs/user/configuration/
- Cilium kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Calico eBPF dataplane: https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf

**Lab prerequisites**

- Docker or Podman, `kind` v0.24 or later, `kubectl`, and `helm` v3.
- A Linux host kernel of 5.13 or later, which `nftables` mode requires. Check with `uname -r`.
- Run one cluster at a time and delete it before creating the next one (`kind delete cluster --name <name>`). Each exercise starts on a clean dataplane, so rules left over from another mode can't confuse what you see.

---

## Exercise 1 — Build the iptables baseline and find kube-proxy

### Step 1.1 — Create a cluster that uses iptables mode

Save this file as `kp-iptables.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kp-iptables
networking:
  kubeProxyMode: "iptables"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --config kp-iptables.yaml
kubectl get nodes -o wide
```

Expected output (versions and IPs will differ):

```
NAME                        STATUS   ROLES           AGE   VERSION   INTERNAL-IP
kp-iptables-control-plane   Ready    control-plane   60s   v1.34.0   172.18.0.4
kp-iptables-worker          Ready    <none>          40s   v1.34.0   172.18.0.3
kp-iptables-worker2         Ready    <none>          40s   v1.34.0   172.18.0.2
```

### Step 1.2 — Look at how kube-proxy is deployed

```bash
kubectl -n kube-system get ds kube-proxy -o wide
kubectl -n kube-system get ds kube-proxy \
  -o jsonpath='{.spec.template.spec.hostNetwork}{"\n"}{.spec.template.spec.containers[0].command}{"\n"}'
kubectl -n kube-system get ds kube-proxy \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}{"\n"}'
```

Expected output:

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   2m
true
["/usr/local/bin/kube-proxy","--config=/var/lib/kube-proxy/config.conf","--hostname-override=$(NODE_NAME)"]
{"privileged":true}
```

### Step 1.3 — Read the configured mode, then the mode that is actually running

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' \
  | grep -E '^(mode|clusterCIDR|metricsBindAddress):|^  (masqueradeAll|syncPeriod|minSyncPeriod):'
docker exec kp-iptables-worker curl -s http://127.0.0.1:10249/proxyMode; echo
```

Expected output:

```
clusterCIDR: 10.244.0.0/16
  masqueradeAll: false
  minSyncPeriod: 1s
  syncPeriod: 30s
metricsBindAddress: ""
mode: iptables
iptables
```

**Questions**

1. Why must kube-proxy run with `hostNetwork: true` and `privileged: true`? What would it change if it ran in a normal Pod network namespace?
2. The ConfigMap sets `metricsBindAddress: ""`, yet `127.0.0.1:10249` answers. Where does that address come from, and why is binding to loopback a sensible default?
3. What is the difference between reading `mode:` from the ConfigMap and querying `/proxyMode`? Which one would you trust during an incident, and why?

---

## Exercise 2 — Trace a ClusterIP through the iptables chains

### Step 2.1 — Deploy a workload with three endpoints

Save as `web.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: default
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
      containers:
        - name: agnhost
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /hostname
              port: http
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: default
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

```bash
kubectl apply -f web.yaml
kubectl rollout status deploy/web
kubectl get svc web
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o custom-columns=NAME:.metadata.name,ADDRS:.endpoints[*].addresses[0]
```

Expected output:

```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.143.21   <none>        80/TCP    10s
NAME        ADDRS
web-7x2kq   10.244.1.3,10.244.2.3,10.244.2.4
```

### Step 2.2 — Open a shell in the kube-proxy Pod on a known node

```bash
KP=$(kubectl -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=kp-iptables-worker -o name)
echo "$KP"
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
```

### Step 2.3 — Follow the chain from the entry point to the endpoints

```bash
kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep -E "^-A KUBE-SERVICES .*default/web"
```

Expected output:

```
-A KUBE-SERVICES -d 10.96.143.21/32 -p tcp -m comment --comment "default/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-KVBHMDK4KAQAUVCN
```

```bash
SVC_CHAIN=$(kubectl -n kube-system exec "$KP" -- iptables-save -t nat \
  | grep -oE "KUBE-SVC-[A-Z0-9]+" | sort -u | while read c; do
      kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep -q "^-A $c .*default/web" && echo "$c"; done | head -1)
kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep "^-A $SVC_CHAIN "
```

Expected output:

```
-A KUBE-SVC-KVBHMDK4KAQAUVCN ! -s 10.244.0.0/16 -d 10.96.143.21/32 -p tcp -m comment --comment "default/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-KVBHMDK4KAQAUVCN -m comment --comment "default/web:http -> 10.244.1.3:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-AAAAAAAAAAAAAAA1
-A KUBE-SVC-KVBHMDK4KAQAUVCN -m comment --comment "default/web:http -> 10.244.2.3:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-AAAAAAAAAAAAAAA2
-A KUBE-SVC-KVBHMDK4KAQAUVCN -m comment --comment "default/web:http -> 10.244.2.4:8080" -j KUBE-SEP-AAAAAAAAAAAAAAA3
```

```bash
kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep -E "^-A KUBE-SEP-.*10.244.1.3"
kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep -E "^-A KUBE-POSTROUTING"
```

Expected output:

```
-A KUBE-SEP-AAAAAAAAAAAAAAA1 -s 10.244.1.3/32 -m comment --comment "default/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-AAAAAAAAAAAAAAA1 -p tcp -m comment --comment "default/web:http" -m tcp -j DNAT --to-destination 10.244.1.3:8080
-A KUBE-POSTROUTING -m mark ! --mark 0x4000/0x4000 -j RETURN
-A KUBE-POSTROUTING -j MARK --set-xmark 0x4000/0x0
-A KUBE-POSTROUTING -m comment --comment "kubernetes service traffic requiring SNAT" -j MASQUERADE --random-fully
```

> The hash suffixes in chain names (`KVBHMDK4...`) are derived from the Service or endpoint identity and will be different in your cluster. The chain names above are placeholders, so always copy yours from your own output.

### Step 2.4 — Confirm that the probabilities add up to an even split

```bash
kubectl run client --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --restart=Never -- pause
kubectl wait --for=condition=Ready pod/client
for i in $(seq 1 60); do kubectl exec client -- curl -s http://web/hostname; echo; done | sort | uniq -c
```

Expected output (roughly 20 each):

```
     21 web-6d8f7c9b5-4kq7n
     18 web-6d8f7c9b5-9xw2p
     21 web-6d8f7c9b5-tz6lm
```

**Questions**

4. The three `statistic` rules use probabilities 1/3, 1/2 and then no match condition at all. Show that each endpoint ends up receiving exactly 1/3 of new connections.
5. The first rule in `KUBE-SVC-*` calls `KUBE-MARK-MASQ` only for sources that are `! -s 10.244.0.0/16`. Which traffic does that match, and why does it need SNAT?
6. Every `KUBE-SEP-*` chain starts with `-s <podIP> -j KUBE-MARK-MASQ`. Which scenario ("hairpin") is this for, and what would break without it?
7. The load-balancing decision is taken only for the **first** packet of a connection. Which kernel subsystem makes sure the rest of the packets reach the same backend?

---

## Exercise 3 — Measure iptables mode: conntrack, session affinity, and sync cost

### Step 3.1 — See the DNAT recorded in conntrack

```bash
kubectl exec client -- sh -c 'for i in 1 2 3; do curl -s http://web/hostname >/dev/null; done'
kubectl -n kube-system exec "$KP" -- conntrack -L -d "$SVC_IP" -p tcp 2>/dev/null | head -3
```

Expected output (only if `client` is scheduled on `kp-iptables-worker`; otherwise run the command in the kube-proxy Pod of the client's node):

```
tcp      6 118 TIME_WAIT src=10.244.1.5 dst=10.96.143.21 sport=41870 dport=80 src=10.244.2.3 dst=10.244.1.5 sport=8080 dport=41870 [ASSURED] mark=0 use=1
```

### Step 3.2 — Turn on `sessionAffinity: ClientIP` and look at the rule that changes

```bash
kubectl patch svc web -p '{"spec":{"sessionAffinity":"ClientIP","sessionAffinityConfig":{"clientIP":{"timeoutSeconds":600}}}}'
sleep 3
kubectl -n kube-system exec "$KP" -- iptables-save -t nat | grep "^-A $SVC_CHAIN " | grep recent
for i in $(seq 1 10); do kubectl exec client -- curl -s http://web/hostname; echo; done | sort | uniq -c
```

Expected output:

```
-A KUBE-SVC-KVBHMDK4KAQAUVCN -m comment --comment "default/web:http -> 10.244.1.3:8080" -m recent --name KUBE-SEP-AAAAAAAAAAAAAAA1 --mask 255.255.255.255 --rsource --rcheck --seconds 600 --reap -j KUBE-SEP-AAAAAAAAAAAAAAA1
...
     10 web-6d8f7c9b5-9xw2p
```

Turn affinity back off:

```bash
kubectl patch svc web -p '{"spec":{"sessionAffinity":"None","sessionAffinityConfig":null}}'
```

### Step 3.3 — Measure the cost of each sync as the number of Services grows

```bash
docker exec kp-iptables-worker sh -c \
  'curl -s http://127.0.0.1:10249/metrics | grep -E "^kubeproxy_sync_proxy_rules_duration_seconds_(sum|count)"'

for i in $(seq 1 200); do
  kubectl create service clusterip "bulk-$i" --tcp=80:8080 --dry-run=client -o yaml
  echo "---"
done | kubectl apply -f - >/dev/null

docker exec kp-iptables-worker sh -c \
  'curl -s http://127.0.0.1:10249/metrics | grep -E "^kubeproxy_sync_proxy_rules_duration_seconds_(sum|count)"'
kubectl -n kube-system exec "$KP" -- sh -c 'iptables-save -t nat | wc -l'
```

Expected output (the shape of the numbers matters, not their exact values):

```
kubeproxy_sync_proxy_rules_duration_seconds_sum 0.412
kubeproxy_sync_proxy_rules_duration_seconds_count 31
kubeproxy_sync_proxy_rules_duration_seconds_sum 1.973
kubeproxy_sync_proxy_rules_duration_seconds_count 58
1213
```

Clean up:

```bash
kubectl get svc -o name | grep bulk- | xargs kubectl delete
```

**Questions**

8. In the conntrack entry, which tuple shows the original destination (the ClusterIP), and which one shows the DNATed reply? Why does this entry make a `conntrack -D` necessary after a UDP endpoint is removed?
9. How does `-m recent` implement affinity? Is that state held per node or per cluster, and what does that mean for a client whose traffic reaches the Service from two different nodes?
10. The 200 new Services had no endpoints. Why do they still add rules to the node, and what does that say about how iptables mode scales?

Delete this cluster before moving on:

```bash
kind delete cluster --name kp-iptables
```

---

## Exercise 4 — nftables mode: the same Service, a different data structure

### Step 4.1 — Create the cluster

Save as `kp-nft.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kp-nft
networking:
  kubeProxyMode: "nftables"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --config kp-nft.yaml
kubectl apply -f web.yaml && kubectl rollout status deploy/web
docker exec kp-nft-worker curl -s http://127.0.0.1:10249/proxyMode; echo
KP=$(kubectl -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=kp-nft-worker -o name)
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
```

Expected output: `nftables`

### Step 4.2 — List the kube-proxy table and the service dispatch map

```bash
kubectl -n kube-system exec "$KP" -- nft list tables
kubectl -n kube-system exec "$KP" -- nft list map ip kube-proxy service-ips
```

Expected output:

```
table ip kube-proxy
table ip6 kube-proxy
table ip filter
table ip nat
...
table ip kube-proxy {
	map service-ips {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
		elements = { 10.96.0.1 . tcp . 443 : goto service-2QRHZV4L-default/kubernetes/tcp/https,
			     10.96.0.10 . udp . 53 : goto service-FY5PMXPG-kube-system/kube-dns/udp/dns,
			     10.96.143.21 . tcp . 80 : goto service-HVFWP5L3-default/web/tcp/http,
			     ... }
	}
}
```

### Step 4.3 — Open the per-service chain

```bash
CHAIN=$(kubectl -n kube-system exec "$KP" -- nft list map ip kube-proxy service-ips \
  | grep -oE "service-[A-Z0-9]+-default/web/tcp/http" | head -1)
kubectl -n kube-system exec "$KP" -- nft list chain ip kube-proxy "$CHAIN"
```

Expected output:

```
table ip kube-proxy {
	chain service-HVFWP5L3-default/web/tcp/http {
		ip daddr 10.96.143.21 tcp dport 80 ip saddr != 10.244.0.0/16 jump mark-for-masquerade
		numgen random mod 3 vmap { 0 : goto endpoint-5OJB2KTY-default/web/tcp/http__10.244.1.3/8080, 1 : goto endpoint-VJ7VIZ4D-default/web/tcp/http__10.244.2.3/8080, 2 : goto endpoint-ZCE3GQ6I-default/web/tcp/http__10.244.2.4/8080 }
	}
}
```

```bash
EP=$(kubectl -n kube-system exec "$KP" -- nft list chain ip kube-proxy "$CHAIN" \
  | grep -oE "endpoint-[A-Z0-9]+-default/web/tcp/http__[0-9.]+/8080" | head -1)
kubectl -n kube-system exec "$KP" -- nft list chain ip kube-proxy "$EP"
```

Expected output:

```
table ip kube-proxy {
	chain endpoint-5OJB2KTY-default/web/tcp/http__10.244.1.3/8080 {
		ip saddr 10.244.1.3 jump mark-for-masquerade
		meta l4proto tcp dnat to 10.244.1.3:8080
	}
}
```

### Step 4.4 — Scale the Deployment and watch the change

```bash
kubectl scale deploy/web --replicas=5 && kubectl rollout status deploy/web
kubectl -n kube-system exec "$KP" -- nft list chain ip kube-proxy "$CHAIN" | grep numgen
kubectl -n kube-system exec "$KP" -- sh -c 'iptables-save -t nat | grep -c KUBE-SVC' || true
```

Expected output:

```
		numgen random mod 5 vmap { 0 : goto endpoint-..., 1 : goto endpoint-..., 2 : goto endpoint-..., 3 : goto endpoint-..., 4 : goto endpoint-... }
0
```

**Questions**

11. In iptables mode, a packet walks `KUBE-SERVICES` rule by rule until one matches. What does the `service-ips` verdict map do instead, and how does the per-packet cost change as the number of Services grows?
12. Compare `numgen random mod N vmap {...}` with the chain of `statistic` rules in iptables mode. Why does nftables need neither cascading probabilities nor a "last rule without a match"?
13. Why does kube-proxy create its own table (`ip kube-proxy`) instead of adding chains to the shared `ip nat` table? What does that give you when other software (firewalld, Docker, a CNI) also programs netfilter?
14. What are the kernel and version prerequisites for this mode, and what should you check before migrating a production cluster that has NetworkPolicy or monitoring tools that parse `KUBE-*` iptables chains?

```bash
kind delete cluster --name kp-nft
```

---

## Exercise 5 — IPVS mode: an in-kernel L4 load balancer

### Step 5.1 — Create the cluster and install `ipvsadm` on one node

Save as `kp-ipvs.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kp-ipvs
networking:
  kubeProxyMode: "ipvs"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --config kp-ipvs.yaml
kubectl apply -f web.yaml && kubectl rollout status deploy/web
docker exec kp-ipvs-worker curl -s http://127.0.0.1:10249/proxyMode; echo
docker exec kp-ipvs-worker bash -c 'apt-get update -qq && apt-get install -y -qq ipvsadm >/dev/null'
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
```

Expected output: `ipvs`

### Step 5.2 — Inspect the virtual server, the dummy interface, and the ipsets

```bash
docker exec kp-ipvs-worker ipvsadm -Ln -t "$SVC_IP:80"
docker exec kp-ipvs-worker ip -brief addr show kube-ipvs0
docker exec kp-ipvs-worker ipset list KUBE-CLUSTER-IP | head -12
KP=$(kubectl -n kube-system get pod -l k8s-app=kube-proxy \
  --field-selector spec.nodeName=kp-ipvs-worker -o name)
kubectl -n kube-system exec "$KP" -- sh -c 'iptables-save -t nat | grep -E "KUBE-SERVICES.*KUBE-CLUSTER-IP"'
```

Expected output:

```
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.143.21:80 rr
  -> 10.244.1.3:8080              Masq    1      0          0
  -> 10.244.2.3:8080              Masq    1      0          0
  -> 10.244.2.4:8080              Masq    1      0          0
kube-ipvs0       DOWN           10.96.0.1/32 10.96.0.10/32 10.96.143.21/32
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 6
Header: family inet hashsize 1024 maxelem 65536 bucketsize 12 initval 0x...
Size in memory: ...
References: 2
Number of entries: 5
Members:
10.96.143.21,tcp:80
10.96.0.10,udp:53
...
-A KUBE-SERVICES ! -s 10.244.0.0/16 -m comment --comment "Kubernetes service cluster ip + port for masquerade purpose" -m set --match-set KUBE-CLUSTER-IP dst,dst -j KUBE-MARK-MASQ
```

### Step 5.3 — Change the scheduler

IPVS supports several scheduling algorithms. The standard ones in kube-proxy are `rr`, `wrr`, `lc`, `wlc`, `sh`, `dh`, `sed`, `nq`, `mh` and `lblc`. Edit the ConfigMap so that `ipvs.scheduler` is `lc`, and restart kube-proxy:

```bash
kubectl -n kube-system get cm kube-proxy -o yaml \
  | sed 's/^      scheduler: ""/      scheduler: "lc"/' \
  | kubectl apply -f -
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -A8 '^ipvs:'
kubectl -n kube-system rollout restart ds kube-proxy
kubectl -n kube-system rollout status ds kube-proxy
docker exec kp-ipvs-worker ipvsadm -Ln -t "$SVC_IP:80" | sed -n 3p
```

Expected output (the last line):

```
TCP  10.96.143.21:80 lc
```

> If the `sed` didn't match (because the indentation or default value of your ConfigMap is different), use `kubectl -n kube-system edit cm kube-proxy` and set `scheduler: lc` under `ipvs:` by hand.

**Questions**

15. Why does kube-proxy assign every ClusterIP to the `kube-ipvs0` dummy interface? Which IPVS hook requires the address to be local to the node?
16. IPVS mode still uses iptables. What for, exactly, and why are ipsets used in those rules instead of one rule per Service?
17. `Forward: Masq` means IPVS does DNAT. Why can't kube-proxy use IPVS Direct Routing (`Route`) or tunnelling for ClusterIP Services?
18. Upstream, what is the current status of IPVS mode compared with nftables? Which argument would you give a team that proposes adopting it today "for performance"?

```bash
kind delete cluster --name kp-ipvs
```

---

## Exercise 6 — Traffic policies and what they change in the dataplane

This exercise uses nftables mode again, but the concepts apply to every mode.

### Step 6.1 — Recreate the cluster and publish the Service as a NodePort

```bash
kind create cluster --config kp-nft.yaml
kubectl apply -f web.yaml && kubectl rollout status deploy/web
kubectl scale deploy/web --replicas=1 && kubectl rollout status deploy/web
kubectl patch svc web -p '{"spec":{"type":"NodePort"}}'
NODE_PORT=$(kubectl get svc web -o jsonpath='{.spec.ports[0].nodePort}')
POD_NODE=$(kubectl get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
OTHER_NODE=$(kubectl get nodes -o name | sed 's#node/##' | grep -v control-plane | grep -v "$POD_NODE")
echo "pod on=$POD_NODE other=$OTHER_NODE nodePort=$NODE_PORT"
```

### Step 6.2 — Compare `externalTrafficPolicy: Cluster` with `Local`

```bash
POD_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$POD_NODE")
OTHER_NODE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$OTHER_NODE")

# Cluster (default): both nodes answer, and the source IP is rewritten
docker run --rm --network kind curlimages/curl -s -m 3 "http://$OTHER_NODE_IP:$NODE_PORT/clientip"; echo

kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
sleep 3
docker run --rm --network kind curlimages/curl -s -m 3 "http://$POD_NODE_IP:$NODE_PORT/clientip"; echo
docker run --rm --network kind curlimages/curl -s -m 3 "http://$OTHER_NODE_IP:$NODE_PORT/clientip" || echo "TIMEOUT/DROP"
kubectl get svc web -o jsonpath='{.spec.healthCheckNodePort}{"\n"}'
```

Expected output:

```
10.244.2.1:39214
172.18.0.5:51522
TIMEOUT/DROP
31987
```

> `172.18.0.5` is the IP of the throwaway `curl` container on the `kind` network. With `Local`, the Pod sees the client's real address. With `Cluster`, it sees the address of the node that forwarded the request (or of its `cni0`/gateway interface).

### Step 6.3 — Query the health check a cloud load balancer would use

```bash
HC=$(kubectl get svc web -o jsonpath='{.spec.healthCheckNodePort}')
docker exec "$POD_NODE" curl -s "http://127.0.0.1:$HC/healthz"; echo
docker exec "$OTHER_NODE" curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$HC/healthz"
```

Expected output:

```
{"service":{"namespace":"default","name":"web"},"localEndpoints":1,"serviceProxyHealthy":true}
503
```

### Step 6.4 — `internalTrafficPolicy: Local`

```bash
kubectl patch svc web -p '{"spec":{"type":"ClusterIP","externalTrafficPolicy":null,"internalTrafficPolicy":"Local"}}'
kubectl run c-other --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$OTHER_NODE\"}}" -- pause
kubectl run c-same --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$POD_NODE\"}}" -- pause
kubectl wait --for=condition=Ready pod/c-other pod/c-same
kubectl exec c-same -- curl -s -m 3 http://web/hostname; echo
kubectl exec c-other -- curl -s -m 3 http://web/hostname || echo "NO LOCAL ENDPOINT"
```

Expected output:

```
web-6d8f7c9b5-4kq7n
NO LOCAL ENDPOINT
```

**Questions**

19. With `externalTrafficPolicy: Cluster`, why does the Pod see a node IP instead of the client's IP? Which trade-off does `Local` make to preserve the client IP?
20. What is `healthCheckNodePort` for, and who consumes it? What would happen with `Local` if the external load balancer ignored it?
21. `internalTrafficPolicy: Local` doesn't fall back to remote endpoints. Give a use case where that is exactly what you want, and one where it is a trap.

```bash
kind delete cluster --name kp-nft
```

---

## Exercise 7 — Replacing kube-proxy with an eBPF CNI (Cilium)

### Step 7.1 — A cluster without a CNI and without kube-proxy

Save as `kp-cilium.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kp-cilium
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --config kp-cilium.yaml
kubectl -n kube-system get ds kube-proxy 2>&1 | tail -1
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

Expected output:

```
Error from server (NotFound): daemonsets.apps "kube-proxy" not found
NAME                      STATUS     ROLES           AGE   VERSION
kp-cilium-control-plane   NotReady   control-plane   50s   v1.34.0
kp-cilium-worker          NotReady   <none>          30s   v1.34.0
kp-cilium-worker2         NotReady   <none>          30s   v1.34.0
NAME                       READY   STATUS    RESTARTS   AGE
coredns-7c65d6cfc9-8hq2l   0/1     Pending   0          50s
coredns-7c65d6cfc9-kz7mt   0/1     Pending   0          50s
```

### Step 7.2 — Install Cilium with kube-proxy replacement

Save as `cilium-values.yaml`:

```yaml
kubeProxyReplacement: true
k8sServiceHost: kp-cilium-control-plane
k8sServicePort: 6443
ipam:
  mode: kubernetes
routingMode: tunnel
tunnelProtocol: vxlan
```

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm install cilium cilium/cilium --namespace kube-system -f cilium-values.yaml
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl get nodes
```

Expected output: all three nodes `Ready`.

### Step 7.3 — Confirm the replacement is active

```bash
CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=kp-cilium-worker -o name)
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg status | grep -E "KubeProxyReplacement|Routing|Masquerading"
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg status --verbose | sed -n '/KubeProxyReplacement Details/,/^$/p' | head -20
```

Expected output (the exact format depends on the Cilium version):

```
KubeProxyReplacement:    True   [eth0   172.18.0.3 fc00:f853:ccd:e793::3 (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Devices:                eth0   172.18.0.3 (Direct Routing)
  Mode:                   SNAT
  Backend Selection:      Random
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

### Step 7.4 — The same Service, now in BPF maps

```bash
kubectl apply -f web.yaml && kubectl rollout status deploy/web
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg service list | grep -E "^ID|$SVC_IP"
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg bpf lb list | grep -A3 "$SVC_IP:80"
docker exec kp-cilium-worker sh -c 'iptables-save -t nat 2>/dev/null | grep -c "KUBE-SVC\|KUBE-SEP"; nft list tables 2>/dev/null | grep -c kube-proxy' || true
```

Expected output:

```
ID   Frontend              Service Type   Backend
7    10.96.143.21:80/TCP   ClusterIP      1 => 10.244.1.47:8080/TCP (active)
                                          2 => 10.244.2.12:8080/TCP (active)
                                          3 => 10.244.2.88:8080/TCP (active)
SERVICE ADDRESS          BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.96.143.21:80/TCP (1)  10.244.1.47:8080/TCP (7) (1)
10.96.143.21:80/TCP (2)  10.244.2.12:8080/TCP (7) (2)
10.96.143.21:80/TCP (3)  10.244.2.88:8080/TCP (7) (3)
0
0
```

### Step 7.5 — Socket-level load balancing: where did the DNAT go?

```bash
kubectl run client --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --restart=Never \
  --overrides='{"spec":{"nodeName":"kp-cilium-worker"}}' -- pause
kubectl wait --for=condition=Ready pod/client
kubectl exec client -- sh -c 'curl -s http://web/hostname; echo'
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg bpf ct list global | grep -c "$SVC_IP" || true
kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg bpf ct list global | grep -E "10\.244\.[0-9]+\.[0-9]+:8080" | head -2
```

Expected output: the `$SVC_IP` count is `0` or very low, while entries exist straight to `PodIP:8080`.

**Questions**

22. What must be configured *before* installing Cilium on a cluster without kube-proxy (`k8sServiceHost`/`k8sServicePort`), and why? What would the Cilium agent use to reach the API server otherwise?
23. With socket LB enabled, why do conntrack entries point at the backend directly instead of the ClusterIP? At which hook is the translation done, and what does that save on every packet?
24. Name two situations where replacing kube-proxy brings clear operational benefits, and two risks or limitations you should check before doing it (kernel, tools, visibility, compatibility).

```bash
kind delete cluster --name kp-cilium
```

---

## Exercise 8 — Decision and migration (a written exercise, no cluster)

### Step 8.1 — Fill in the comparison table

Copy the table below and fill in each cell from what you observed in Exercises 2 to 7:

| Dimension | iptables | nftables | ipvs | eBPF (Cilium KPR) |
|---|---|---|---|---|
| Per-packet lookup complexity as Services grow | | | | |
| How endpoints are selected | | | | |
| Where the DNAT happens | | | | |
| Visibility tools | | | | |
| Minimum kernel requirement | | | | |
| Upstream status | | | | |

### Step 8.2 — Plan a migration

A cluster with 4,000 Services running kube-proxy in iptables mode shows `kubeproxy_sync_proxy_rules_duration_seconds` p99 at 8 s, and new endpoints take a long time to receive traffic. The nodes run kernel 6.1. Write the migration plan to nftables mode: what you change, in what order, how you validate each node, and how you roll back.

**Questions**

25. Which metric proves that the migration improved endpoint propagation latency, and which one checks that rules are being applied without errors?
26. During a mode change on a live node, why is it risky to have iptables and nftables rules from kube-proxy at the same time, and what does `kube-proxy --cleanup` do?

---

<details>
<summary><strong>Answers</strong></summary>

**1.** kube-proxy programs netfilter/IPVS/nftables in the **node's** network namespace, which is the one that sees Pod-to-Service and external-to-NodePort traffic. That needs `CAP_NET_ADMIN` (and in practice `privileged`, to load kernel modules and write to `/proc/sys`). In a Pod's network namespace it would only change the rules of its own namespace, which no other traffic crosses, so no Service would work.

**2.** An empty `metricsBindAddress` takes the binary's default, `127.0.0.1:10249`, as described in the kube-proxy command-line reference. Binding to loopback keeps `/metrics` and `/proxyMode` (which reveal information about the cluster) off the node's network. To let Prometheus scrape them, set `0.0.0.0:10249` explicitly and protect the port.

**3.** The ConfigMap is the **desired** configuration. `/proxyMode` is what the running process **actually** uses. They can differ if kube-proxy wasn't restarted after the ConfigMap changed, if a flag overrides the config, or if the requested mode failed its prerequisites (older versions fell back to iptables silently). In an incident, trust `/proxyMode`.

**4.** P(ep1) = 1/3. P(ep2) = (1 − 1/3) × 1/2 = 1/3. P(ep3) = (1 − 1/3) × (1 − 1/2) × 1 = 1/3. Each rule's probability is conditional on the earlier ones not matching, so the i-th rule of N uses 1/(N − i + 1), and the last one needs no condition.

**5.** It matches traffic addressed to the ClusterIP from outside the Pod CIDR, such as processes on the node itself (hostNetwork) or external traffic arriving through ExternalIPs. Without SNAT, the backend would reply directly to the original IP, the reply wouldn't pass back through the node that did the DNAT, conntrack couldn't reverse the translation, and the client would receive a packet from an IP it never contacted. Because `clusterCIDR` was set, kube-proxy can tell Pod traffic, which doesn't need SNAT, from traffic that does.

**6.** Hairpin is when a Pod reaches its own Service and the load balancer picks that same Pod. After the DNAT, source and destination are the same Pod. Without SNAT, the reply would stay inside the Pod without passing through conntrack's reverse translation, and the client would get a reply from `PodIP:8080` instead of `ClusterIP:80`. The TCP connection breaks.

**7.** Netfilter's conntrack. The NAT table is only evaluated for packets in the `NEW` state. Once the translation is recorded in the conntrack entry, every later packet in the flow (in both directions) is translated from that entry without going through the chains again.

**8.** The first tuple (`src=client dst=10.96.143.21 dport=80`) is the original direction. The second (`src=10.244.2.3 sport=8080 dst=client`) is the expected reply, already DNATed. UDP has no close handshake, so an entry for a UDP flow to a deleted endpoint stays valid until its timeout, and the client keeps sending to a dead backend (the classic DNS case). That is why kube-proxy runs `conntrack -D` on UDP entries for removed endpoints.

**9.** Each `KUBE-SEP` has a list in the `xt_recent` module, named after the chain. A `--set` rule records the source IP when an endpoint is picked, and `--rcheck --seconds 600` sends traffic back to that endpoint if the IP was seen recently. The state lives **in each node's kernel**, so it isn't shared across the cluster. A client whose traffic arrives through two different nodes (for example NodePort behind an external LB without its own affinity) can land on different backends.

**10.** kube-proxy creates the entry in `KUBE-SERVICES` and a rule that `REJECT`s traffic to a Service without endpoints (in the `filter` table, `KUBE-SVC-*`/`KUBE-EXTERNAL-SERVICES` chains), so that clients fail fast instead of timing out. The rule count grows with Services × endpoints. Matching `KUBE-SERVICES` is a linear walk, and each resync generates and applies a large ruleset through `iptables-restore` (partial syncs have been the default since 1.28 and reduce the cost, but full resyncs still happen). Both the per-packet cost and the sync cost grow with the size of the cluster.

**11.** A verdict map is a hash table keyed by `(daddr . proto . dport)`. One lookup jumps straight to the right service chain, so the per-packet cost is about O(1) whether there are 10 or 10,000 Services. iptables compares rules one by one. Updates are also incremental: kube-proxy adds or removes map elements in an atomic `nft` transaction instead of rewriting chains.

**12.** `numgen random mod N` produces a uniform integer in [0, N), and the `vmap` sends each value to one endpoint. Each endpoint gets exactly 1/N with no chained conditional probabilities and no need for a "catch-all" rule. Changing N means updating one rule.

**13.** A separate table isolates kube-proxy's rules. It never flushes, reorders or rewrites chains that belong to other components, and other components can't break its chains. It can also recreate or delete the whole table atomically. In iptables mode, everyone shares `nat`/`filter`, and ordering conflicts and accidental flushes (from firewalld, Docker, or scripts that run `iptables -F`) are a known source of incidents.

**14.** nftables mode is GA since Kubernetes v1.33 (beta in v1.31) and needs a node kernel of 5.13 or later, plus the nft userspace tools in the kube-proxy image. Before migrating, check that: nothing parses `KUBE-*` chains or depends on iptables jump behaviour (dashboards, scripts, some older CNIs or NetworkPolicy agents); the CNI implements NetworkPolicy in a way that doesn't expect kube-proxy's iptables marks; and the documented behaviour differences are covered, such as NodePorts no longer answering on `127.0.0.1` and the different default for `nodePortAddresses`, all listed in "Virtual IPs and Service Proxies" and the blog post above. Migrate node by node.

**15.** IPVS hooks into netfilter at `LOCAL_IN`, so it only looks at packets whose destination is an IP local to the node. Assigning every ClusterIP to `kube-ipvs0` (a `DOWN` dummy interface, so it never answers ARP on the network) makes the kernel treat those IPs as local and hand the packets to IPVS.

**16.** IPVS does no SNAT, packet filtering, or `REJECT`s for Services without endpoints. kube-proxy keeps a small fixed set of iptables rules for masquerade (`KUBE-MARK-MASQ`), NodePort, `externalTrafficPolicy` handling and filtering. Those rules match against **ipsets** (hash tables in the kernel) such as `KUBE-CLUSTER-IP`, so the number of iptables rules stays constant whatever the number of Services, and the lookup is O(1).

**17.** DR and tunnelling require the backend to own the VIP (on a loopback or tunnel interface) and to reply directly to the client, which isn't how Pods work. Pods don't have the ClusterIP configured, and replies would bypass the node's conntrack. NAT (`Masq`) is the only forwarding method compatible with the Kubernetes Service model.

**18.** IPVS mode sees little upstream maintenance, has long-standing known differences from the iptables behaviour, and is deprecated (from v1.35). The project recommends nftables mode for new deployments. Argument: nftables already gives the O(1) lookup that was IPVS's reason for existing, keeps the semantics consistent with iptables mode, and has an active future. If advanced L4 load balancing is really needed, the path forward is an eBPF dataplane, not IPVS.

**19.** With `Cluster`, the node that receives the traffic can forward it to a backend on another node. For the reply to come back through that node (where the DNAT is in conntrack), it applies SNAT with its own IP, so the Pod loses the client's IP. `Local` only forwards to endpoints on the receiving node, so no SNAT is needed and the source IP is preserved. The trade-off is that nodes without an endpoint drop the traffic, and load can be uneven when Pods are spread unevenly across nodes.

**20.** `healthCheckNodePort` is an HTTP port served by kube-proxy (or its replacement) that answers `200` when the node has local endpoints and `503` when it doesn't. External or cloud load balancers use it to send traffic only to nodes that can serve it. If the LB ignores it, it will send connections to nodes without endpoints, and those connections get dropped: intermittent timeouts that are hard to diagnose.

**21.** A good use: node-local agents such as a DaemonSet running a logging, metrics or DNS cache proxy, where talking to the local instance avoids network hops and cross-zone traffic, and going remote makes no sense. A trap: a normal Deployment with fewer replicas than nodes. Pods on nodes without a replica lose connectivity to the Service entirely, with no fallback.

**22.** Without kube-proxy, nothing translates the `kubernetes` ClusterIP (`10.96.0.1:443`) to the real API server endpoints. The Cilium agent itself needs to reach the API server to learn about Services and program the BPF maps, a chicken-and-egg problem. `k8sServiceHost`/`k8sServicePort` give it a direct address (node IP/hostname and port 6443, or a VIP/LB) that doesn't depend on ClusterIP translation.

**23.** Socket LB hooks BPF programs to cgroup hooks for `connect()`/`sendmsg()`. When an application calls `connect(ClusterIP:80)`, Cilium rewrites the destination to `PodIP:8080` **before the first packet exists**. From then on, packets travel straight to the backend with no per-packet DNAT, and the connection needs no Service NAT conntrack entry. That saves translation work on every packet and lowers latency. The reverse translation is done on `getpeername()`/`recvmsg()`, so the application still sees the ClusterIP.

**24.** Benefits: (a) large clusters with high Service or endpoint churn, where BPF hash maps give O(1) lookup and incremental updates without resyncing whole rulesets; (b) advanced L4 features such as DSR, Maglev consistent hashing, XDP acceleration for NodePort/LB, and source-IP preservation without the limits of `externalTrafficPolicy`. Risks: (a) it depends on a recent kernel and on features that vary with the distro and kernel version; (b) familiar tools (`iptables-save`, `conntrack`, many runbooks) stop showing Service state, so the team needs `cilium-dbg`, Hubble and `bpftool`; there are also integrations that assume kube-proxy exists (some service meshes, HostPort, scripts, managed-cluster providers), and moving from kube-proxy to replacement needs a controlled plan with old rules cleaned up.

**Step 8.1 (reference answer):**

| Dimension | iptables | nftables | ipvs | eBPF (Cilium KPR) |
|---|---|---|---|---|
| Per-packet lookup complexity as Services grow | O(n) walk of `KUBE-SERVICES` | ~O(1) verdict map | ~O(1) IPVS hash + ipset | ~O(1) BPF hash maps |
| How endpoints are selected | `statistic random` chain | `numgen random mod N vmap` | IPVS scheduler (`rr`, `lc`, `sh`, ...) | random or Maglev |
| Where the DNAT happens | netfilter `nat` PREROUTING/OUTPUT | netfilter (`ip kube-proxy` table) | IPVS at `LOCAL_IN` | cgroup/socket hook or tc/XDP |
| Visibility tools | `iptables-save`, `conntrack` | `nft list`, `conntrack` | `ipvsadm`, `ipset` | `cilium-dbg`, `bpftool`, Hubble |
| Minimum kernel requirement | any supported | ≥ 5.13 | IPVS modules loaded | recent (see Cilium's docs) |
| Upstream status | default, stable | GA in v1.33, recommended | deprecated | maintained by the CNI |

**Step 8.2 (reference outline):** (1) Confirm the kernel is 5.13 or later on every node (6.1 is fine), that the kube-proxy version supports GA nftables, and that nothing depends on `KUBE-*` chains or on NodePorts at `127.0.0.1`. (2) Set `nodePortAddresses` explicitly if you need it. (3) Canary: create a second kube-proxy DaemonSet with `mode: nftables` and a `nodeSelector` for a small pool, and exclude that pool from the original DaemonSet with node affinity. Before starting it on each node, run `kube-proxy --cleanup` (or drain and reboot the node) so that no iptables rules are left over. (4) Validate each node: `/proxyMode` returns `nftables`, `nft list table ip kube-proxy` is populated, `iptables-save | grep -c KUBE-SVC` returns 0, ClusterIP/NodePort/LB e2e tests pass, and the metrics look healthy. (5) Widen the rollout pool by pool. (6) Rollback: move the nodes back to the iptables DaemonSet after cleaning up nftables (`--cleanup` in nftables mode, or delete the `kube-proxy` table).

**25.** `kubeproxy_network_programming_duration_seconds` measures the time from an endpoint change in the API to the rule being programmed on the node, which is the latency students and users notice. `kubeproxy_sync_proxy_rules_duration_seconds` should drop sharply as well. For errors: `kubeproxy_sync_proxy_rules_last_timestamp_seconds` should keep advancing, and the mode's failure counters (`kubeproxy_sync_proxy_rules_iptables_restore_failures_total` in iptables mode, and its nftables equivalents in recent versions), together with kube-proxy's logs, should show no errors.

**26.** Both sets of rules would try to DNAT the same traffic. Depending on hook priority, a packet may be translated by stale rules (from a previous sync, pointing at endpoints that no longer exist) or translated twice, which causes intermittent failures that are very hard to diagnose. `kube-proxy --cleanup` removes the rules, chains, tables and ipsets that kube-proxy creates for the configured mode, then exits. Run it on the node (with the right mode, or with each mode in turn) before starting kube-proxy in the new mode, or reboot the node, which leaves the kernel state clean.

</details>