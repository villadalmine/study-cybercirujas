# Guided Exercises — 2.1 Configuring L4 Services

> **Certification:** CKNE · **Domain weight:** 4.17%
> **Goal:** Build, inspect and fix every L4 Service shape Kubernetes offers (ClusterIP, NodePort, LoadBalancer, headless, selectorless). Trace a packet through kube-proxy's dataplane. Explain the effect of each traffic-policy knob on source IP, load distribution and availability.

**Official references used throughout**

- Service concept: https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and service proxies (kube-proxy modes): https://kubernetes.io/docs/reference/networking/virtual-ips/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Service internal traffic policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Using source IP (tutorial): https://kubernetes.io/docs/tutorials/services/source-ip/
- Create an external load balancer: https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/
- cloud-provider-kind: https://github.com/kubernetes-sigs/cloud-provider-kind
- CKNE program page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/

---

## Lab 0 — Build the lab cluster

You need a cluster with **more than one worker**. Traffic policies only change behaviour when some nodes host an endpoint and others don't. The lab uses kind with kube-proxy pinned to `iptables` mode, so every rule you read in Lab 3 is deterministic.

1. Save this as `kind-l4.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: l4
networking:
  kubeProxyMode: "iptables"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Create the cluster and check the nodes:

```bash
kind create cluster --config kind-l4.yaml
kubectl get nodes -o wide
```

Expected output (your IPs may differ):

```
NAME               STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
l4-control-plane   Ready    control-plane   60s   v1.34.0   172.18.0.4    ...
l4-worker          Ready    <none>          40s   v1.34.0   172.18.0.2    ...
l4-worker2         Ready    <none>          40s   v1.34.0   172.18.0.3    ...
```

3. Confirm which proxy mode kube-proxy actually runs:

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
kubectl -n kube-system logs ds/kube-proxy | grep -i "proxier"
```

Expected:

```
mode: iptables
... "Using iptables Proxier"
```

4. Create the working namespace, the backend and a client toolbox. Save the following as `web.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: l4lab
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
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: web
      containers:
        - name: netexec
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080", "--udp-port=8081"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: udp-echo
              containerPort: 8081
              protocol: UDP
```

```bash
kubectl create namespace l4lab
kubectl apply -f web.yaml
kubectl -n l4lab run client --image=nicolaka/netshoot --command -- sleep infinity
kubectl -n l4lab rollout status deploy/web
kubectl -n l4lab get pods -o wide
```

`agnhost netexec` is the Kubernetes e2e test server. Two of its HTTP endpoints matter here: `/hostname` returns the pod name, and `/clientip` returns the `ip:port` the server saw as the source. The UDP server answers the `hostname` command with the pod name. With those two endpoints you can see load distribution and source-address translation directly.

**Check your understanding (Lab 0)**

- **Q0.1** The control plane node has no `web` pods, yet you asked for 3 replicas with `maxSkew: 1`. How are they distributed, and why doesn't the scheduler use the control-plane node?
- **Q0.2** Why do the exercises pin kube-proxy to `iptables` mode instead of leaving the default?

---

## Lab 1 — ClusterIP: `port`, `targetPort` and named ports

1. Create the Service as `svc-web.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: l4lab
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
    - name: udp-echo
      protocol: UDP
      port: 9000
      targetPort: udp-echo
```

```bash
kubectl apply -f svc-web.yaml
kubectl -n l4lab get svc web -o wide
```

Expected:

```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)            AGE   SELECTOR
web    ClusterIP   10.96.143.27   <none>        80/TCP,9000/UDP    5s    app=web
```

2. Watch the load distribution over TCP:

```bash
kubectl -n l4lab exec client -- sh -c \
  'for i in $(seq 1 30); do curl -s web/hostname; echo; done | sort | uniq -c'
```

Expected (the counts vary around 10 each):

```
     11 web-7c9d8f6b5-8kq2x
      9 web-7c9d8f6b5-m4tzp
     10 web-7c9d8f6b5-x7rwn
```

3. Now test over UDP:

```bash
kubectl -n l4lab exec client -- sh -c \
  'for i in $(seq 1 6); do printf hostname | nc -u -w1 web 9000; echo; done'
```

4. Repeat the UDP loop, but make every datagram leave from the **same source port**:

```bash
kubectl -n l4lab exec client -- sh -c \
  'for i in $(seq 1 6); do printf hostname | nc -u -p 40000 -w1 web 9000; echo; done'
```

5. Check the name resolution the client used:

```bash
kubectl -n l4lab exec client -- dig +search +short web
kubectl -n l4lab exec client -- dig +short web.l4lab.svc.cluster.local
kubectl -n l4lab exec client -- cat /etc/resolv.conf
```

**Check your understanding (Lab 1)**

- **Q1.1** `targetPort: http` is a string. What does kube-proxy resolve it to, and what advantage does a named `targetPort` have during a rolling update that changes the container port?
- **Q1.2** In step 4 every reply probably came from the same pod, while step 3 spread across pods. Why? Which kernel subsystem is responsible?
- **Q1.3** A Service has two ports. Why is `name` mandatory on each of them, and where does that name show up again later (hint: EndpointSlice and DNS SRV)?
- **Q1.4** Why is mixing TCP and UDP on one ClusterIP Service unremarkable, but was historically a problem on `type: LoadBalancer`?

---

## Lab 2 — EndpointSlices: the real backend list

1. List the slices that belong to the Service:

```bash
kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=web
```

Expected:

```
NAME        ADDRESSTYPE   PORTS       ENDPOINTS                              AGE
web-6xk2p   IPv4          8080,8081   10.244.1.3,10.244.2.3,10.244.2.4       2m
```

2. Look at the full object:

```bash
kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=web -o yaml
```

Fields to find: `addressType`, `ports[].name` (it must equal the Service port name), `endpoints[].conditions.{ready,serving,terminating}`, `endpoints[].nodeName`, `endpoints[].targetRef` and the label `endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io`.

3. Scale down and watch a terminating endpoint appear:

```bash
kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=web -w -o yaml &
kubectl -n l4lab scale deploy web --replicas=2
sleep 5; kill %1
kubectl -n l4lab scale deploy web --replicas=3
```

For about the 30 s grace period you'll see one endpoint with:

```
conditions:
  ready: false
  serving: true
  terminating: true
```

`agnhost` exits quickly on SIGTERM, so the window may be short. Add `--delay-shutdown=20` to the container args if you want to watch it longer.

4. Gate readiness manually. Save as `gated.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gated
  namespace: l4lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gated
  template:
    metadata:
      labels:
        app: gated
    spec:
      containers:
        - name: netexec
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            exec:
              command: ["test", "-f", "/tmp/ready"]
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: gated
  namespace: l4lab
spec:
  selector:
    app: gated
  ports:
    - name: http
      port: 80
      targetPort: http
```

```bash
kubectl apply -f gated.yaml
kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=gated -o yaml | grep -A3 conditions
kubectl -n l4lab exec client -- curl -s -m 2 gated/hostname; echo "exit=$?"
```

5. Mark one pod ready:

```bash
POD=$(kubectl -n l4lab get pod -l app=gated -o jsonpath='{.items[0].metadata.name}')
kubectl -n l4lab exec "$POD" -- touch /tmp/ready
sleep 4
kubectl -n l4lab exec client -- sh -c 'for i in 1 2 3 4; do curl -s gated/hostname; echo; done'
```

**Check your understanding (Lab 2)**

- **Q2.1** In step 4, `curl` to `gated` fails. Is the failure a timeout or an immediate "connection refused"? Which kube-proxy rule produces that behaviour for a Service with **zero** ready endpoints?
- **Q2.2** What is the difference between `ready` and `serving`? When does kube-proxy route to an endpoint that is `serving: true` but `ready: false`?
- **Q2.3** Why did Kubernetes replace the single `Endpoints` object with multiple EndpointSlices? What is the default maximum number of endpoints per slice?
- **Q2.4** You see two EndpointSlices for one Service, one with `addressType: IPv4` and one with `IPv6`. What does that tell you about the Service's `ipFamilyPolicy`?

---

## Lab 3 — Inside the iptables dataplane

kube-proxy in iptables mode programs NAT chains. A ClusterIP exists only as a match in those chains. No interface carries it.

1. Capture the ClusterIP and dump the relevant rules from a worker:

```bash
CIP=$(kubectl -n l4lab get svc web -o jsonpath='{.spec.clusterIP}'); echo $CIP
docker exec l4-worker iptables-save -t nat | grep 'l4lab/web:http'
```

Expected (hashes differ):

```
-A KUBE-SERVICES -d 10.96.143.27/32 -p tcp -m comment --comment "l4lab/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-4N57TFCL4MD7ZTDA
-A KUBE-SVC-4N57TFCL4MD7ZTDA ! -s 10.244.0.0/16 -d 10.96.143.27/32 -p tcp -m comment --comment "l4lab/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-4N57TFCL4MD7ZTDA -m comment --comment "l4lab/web:http -> 10.244.1.3:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-AAAA...
-A KUBE-SVC-4N57TFCL4MD7ZTDA -m comment --comment "l4lab/web:http -> 10.244.2.3:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-BBBB...
-A KUBE-SVC-4N57TFCL4MD7ZTDA -m comment --comment "l4lab/web:http -> 10.244.2.4:8080" -j KUBE-SEP-CCCC...
-A KUBE-SEP-AAAA... -s 10.244.1.3/32 -m comment --comment "l4lab/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-AAAA... -p tcp -m comment --comment "l4lab/web:http" -m tcp -j DNAT --to-destination 10.244.1.3:8080
```

2. Look at the rule that rejects traffic for the Service with no endpoints (before you made a `gated` pod ready, or scale it to 0 now):

```bash
kubectl -n l4lab scale deploy gated --replicas=0
sleep 3
docker exec l4-worker iptables-save -t filter | grep 'l4lab/gated'
```

Expected:

```
-A KUBE-SERVICES -d 10.96.88.14/32 -p tcp -m comment --comment "l4lab/gated:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

3. Try ICMP against the ClusterIP:

```bash
kubectl -n l4lab exec client -- ping -c 2 -W 1 $CIP
```

4. Watch conntrack translate a live connection. Run the request and dump the entry from the node where the **client** pod lives:

```bash
CNODE=$(kubectl -n l4lab get pod client -o jsonpath='{.spec.nodeName}')
kubectl -n l4lab exec client -- curl -s web/hostname; echo
docker exec "$CNODE" conntrack -L -d $CIP -p tcp 2>/dev/null | head
```

Expected (one line per connection):

```
tcp  6 118 TIME_WAIT src=10.244.2.5 dst=10.96.143.27 sport=51234 dport=80 src=10.244.1.3 dst=10.244.2.5 sport=8080 dport=51234 [ASSURED] mark=0 use=1
```

5. *(Optional)* Recreate the cluster with `kubeProxyMode: "nftables"` (GA since v1.33) and compare:

```bash
docker exec l4-worker nft list table ip kube-proxy | grep -A6 'l4lab/web'
```

**Check your understanding (Lab 3)**

- **Q3.1** Explain the probabilities 0.333…, 0.5 and "unconditional" in the `KUBE-SVC` chain. What probabilities would you expect with 4 endpoints?
- **Q3.2** What is the purpose of the `! -s 10.244.0.0/16 … -j KUBE-MARK-MASQ` rule? And of the `-s <podIP> … KUBE-MARK-MASQ` rule in each `KUBE-SEP` chain (the hairpin case)?
- **Q3.3** Why does `ping` to the ClusterIP fail in iptables mode? Would it behave differently in IPVS mode, and why?
- **Q3.4** In the conntrack entry, identify the original tuple and the reply tuple. Which one shows the DNAT result?
- **Q3.5** Name one scalability reason the nftables mode was introduced to replace iptables.

---

## Lab 4 — NodePort and `externalTrafficPolicy`

For this lab, reduce `web` to **one** replica, so there's always a node with no local endpoint.

1. Scale and find where the pod landed:

```bash
kubectl -n l4lab scale deploy web --replicas=1
kubectl -n l4lab rollout status deploy/web
kubectl -n l4lab get pod -l app=web -o wide
```

2. Create a NodePort Service with a fixed port as `svc-web-np.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-np
  namespace: l4lab
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
      nodePort: 30080
```

```bash
kubectl apply -f svc-web-np.yaml
kubectl get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address
```

3. From outside the cluster (a container on the `kind` Docker network), call `/clientip` on **both** workers:

```bash
W1=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' l4-worker)
W2=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' l4-worker2)
docker run --rm --network kind nicolaka/netshoot sh -c "
  echo my-ip: \$(hostname -i)
  echo via-worker:  \$(curl -s -m 2 http://$W1:30080/clientip)
  echo via-worker2: \$(curl -s -m 2 http://$W2:30080/clientip)"
```

Example output (the pod is on `l4-worker`):

```
my-ip: 172.18.0.5
via-worker:  10.244.1.1:48122
via-worker2: 172.18.0.3:31877
```

4. Switch to `Local` and repeat step 3:

```bash
kubectl -n l4lab patch svc web-np -p '{"spec":{"externalTrafficPolicy":"Local"}}'
```

Example output:

```
my-ip: 172.18.0.5
via-worker:  172.18.0.5:39410
via-worker2:
```

5. Look at the rules kube-proxy wrote for the node **without** a local endpoint:

```bash
EMPTY=l4-worker2   # replace with the node that has no web pod
docker exec "$EMPTY" iptables-save -t nat | grep 'l4lab/web-np'
```

Expect a `KUBE-EXT-…` chain that sends external traffic to `KUBE-SVL-…`, the local-only endpoint chain. On this node that chain has no endpoints and ends in a drop for external clients. Cluster-internal clients hitting the NodePort still get routed normally.

6. Restore:

```bash
kubectl -n l4lab patch svc web-np -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

**Check your understanding (Lab 4)**

- **Q4.1** With `Cluster`, why does the pod see `172.18.0.3` (worker2's address) when you enter via worker2, and a `10.244.x.1` address when you enter via the node that hosts the pod?
- **Q4.2** With `Local`, the source IP is preserved. What is the cost? Describe the load-imbalance problem when an external LB spreads traffic evenly over nodes with 1 and 5 local pods respectively.
- **Q4.3** Why does the request via the empty node time out rather than get rejected?
- **Q4.4** A NodePort must fall inside a range. Which flag defines it, what's the default, and what happens if two Services request the same `nodePort`?

---

## Lab 5 — LoadBalancer and `healthCheckNodePort` (optional, needs cloud-provider-kind)

1. In a **separate terminal on the host**, run the kind cloud controller:

```bash
go install sigs.k8s.io/cloud-provider-kind@latest
sudo ~/go/bin/cloud-provider-kind
```

2. Create a LoadBalancer Service with `Local` policy as `svc-web-lb.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-lb
  namespace: l4lab
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: web
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
```

```bash
kubectl apply -f svc-web-lb.yaml
kubectl -n l4lab get svc web-lb -w
```

Wait until `EXTERNAL-IP` is populated, then:

```bash
LB=$(kubectl -n l4lab get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
HC=$(kubectl -n l4lab get svc web-lb -o jsonpath='{.spec.healthCheckNodePort}')
echo "LB=$LB HC=$HC"
for i in 1 2 3; do curl -s http://$LB/hostname; echo; done
```

3. Query kube-proxy's per-Service health check on each worker:

```bash
docker run --rm --network kind nicolaka/netshoot sh -c "
  curl -s -o /dev/stderr -w ' -> HTTP %{http_code}\n' http://$W1:$HC/healthz
  curl -s -o /dev/stderr -w ' -> HTTP %{http_code}\n' http://$W2:$HC/healthz"
```

Output similar to:

```
{"service":{"namespace":"l4lab","name":"web-lb"},"localEndpoints":1,"serviceProxyHealthy":true} -> HTTP 200
{"service":{"namespace":"l4lab","name":"web-lb"},"localEndpoints":0,"serviceProxyHealthy":true} -> HTTP 503
```

4. Look at the node-port allocation and turn it off:

```bash
kubectl -n l4lab get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
kubectl -n l4lab patch svc web-lb -p '{"spec":{"allocateLoadBalancerNodePorts":false}}'
kubectl -n l4lab get svc web-lb -o yaml | grep -E 'nodePort|allocateLoadBalancerNodePorts'
```

**Check your understanding (Lab 5)**

- **Q5.1** Who allocates `healthCheckNodePort`, who serves it, and who consumes it? Why does it exist only when `externalTrafficPolicy: Local`?
- **Q5.2** After setting `allocateLoadBalancerNodePorts: false`, is the existing `nodePort` removed? For which kind of load balancer implementation is disabling node ports appropriate?
- **Q5.3** A `type: LoadBalancer` Service stays `<pending>` forever in a bare-metal cluster. Which component is missing, and name two ways to provide it.

---

## Lab 6 — Session affinity

1. Scale back to 3 replicas and create an affinity Service as `svc-web-sticky.yaml`:

```bash
kubectl -n l4lab scale deploy web --replicas=3
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-sticky
  namespace: l4lab
spec:
  selector:
    app: web
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 60
  ports:
    - name: http
      port: 80
      targetPort: http
```

```bash
kubectl apply -f svc-web-sticky.yaml
kubectl -n l4lab exec client -- sh -c \
  'for i in $(seq 1 20); do curl -s web-sticky/hostname; echo; done | sort | uniq -c'
```

Expected:

```
     20 web-7c9d8f6b5-x7rwn
```

2. See how iptables implements it:

```bash
docker exec l4-worker iptables-save -t nat | grep 'l4lab/web-sticky' | grep -E 'recent' | head -4
```

Expect rules with `-m recent --name KUBE-SEP-… --rcheck --seconds 60 --reap` and `--set`.

3. Start a second client pod and repeat the loop from it:

```bash
kubectl -n l4lab run client2 --image=nicolaka/netshoot --command -- sleep infinity
kubectl -n l4lab wait --for=condition=Ready pod/client2
kubectl -n l4lab exec client2 -- sh -c \
  'for i in $(seq 1 20); do curl -s web-sticky/hostname; echo; done | sort | uniq -c'
```

**Check your understanding (Lab 6)**

- **Q6.1** What is the default `timeoutSeconds`, and is the timer measured from the first packet or from the last one?
- **Q6.2** Many users sit behind one corporate NAT and hit a NodePort with `ClientIP` affinity and `externalTrafficPolicy: Cluster`. Why can affinity be both ineffective and harmful here?
- **Q6.3** Why is `ClientIP` affinity not a substitute for application-level (cookie) session stickiness?

---

## Lab 7 — `internalTrafficPolicy` and `trafficDistribution`

1. Create a node-local Service as `svc-web-local.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-local
  namespace: l4lab
spec:
  selector:
    app: web
  internalTrafficPolicy: Local
  ports:
    - name: http
      port: 80
      targetPort: http
```

```bash
kubectl apply -f svc-web-local.yaml
kubectl -n l4lab get pod -o wide
kubectl -n l4lab exec client -- sh -c \
  'for i in $(seq 1 10); do curl -s -m 1 web-local/hostname; echo; done | sort | uniq -c'
```

Every reply comes from a `web` pod on the **same node as `client`**.

2. Force a node with no local endpoint. Drain the pods off the client's node:

```bash
CNODE=$(kubectl -n l4lab get pod client -o jsonpath='{.spec.nodeName}')
kubectl -n l4lab patch deploy web --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$CNODE\"]}]}]}}}}}}}"
kubectl -n l4lab rollout status deploy/web
kubectl -n l4lab exec client -- curl -s -m 2 web-local/hostname; echo "exit=$?"
kubectl -n l4lab exec client -- curl -s -m 2 web/hostname; echo "exit=$?"
```

If `rollout status` hangs, remove the `topologySpreadConstraints` first. With `DoNotSchedule` and only one eligible node, the pods can't satisfy `maxSkew: 1`.

3. Compare with the softer, preference-based knob:

```bash
kubectl -n l4lab patch svc web -p '{"spec":{"trafficDistribution":"PreferClose"}}'
kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -A3 hints
```

In kind the nodes carry no `topology.kubernetes.io/zone` label, so hints may not appear. Label the workers (`kubectl label node l4-worker topology.kubernetes.io/zone=a`, `l4-worker2` → `b`, control plane → `a`) and look again.

4. Clean up the affinity:

```bash
kubectl -n l4lab patch deploy web --type=json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'
```

**Check your understanding (Lab 7)**

- **Q7.1** In step 2, `web-local` fails while `web` works. Does `internalTrafficPolicy: Local` ever fall back to remote endpoints?
- **Q7.2** Name a legitimate use case for `internalTrafficPolicy: Local` (hint: DaemonSets).
- **Q7.3** How does `trafficDistribution: PreferClose` differ from `internalTrafficPolicy: Local` in failure behaviour? What data structure does it write, and who consumes it?
- **Q7.4** Does `internalTrafficPolicy` affect traffic that enters through a NodePort from outside the cluster?

---

## Lab 8 — Headless and selectorless Services

1. Create a headless Service as `svc-web-headless.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-headless
  namespace: l4lab
spec:
  clusterIP: None
  selector:
    app: web
  ports:
    - name: http
      port: 8080
      targetPort: http
```

```bash
kubectl apply -f svc-web-headless.yaml
kubectl -n l4lab exec client -- dig +short web-headless.l4lab.svc.cluster.local
kubectl -n l4lab exec client -- dig +short SRV _http._tcp.web-headless.l4lab.svc.cluster.local
kubectl -n l4lab exec client -- dig +short SRV _http._tcp.web.l4lab.svc.cluster.local
docker exec l4-worker iptables-save -t nat | grep -c 'l4lab/web-headless'
```

Expected: the A query returns **one record per ready pod IP**. SRV works for both Services. The iptables grep returns `0`.

2. Create a selectorless Service backed by a manually managed EndpointSlice. First grab a real pod IP to stand in for an "external" backend:

```bash
kubectl -n l4lab get pod -l app=web -o jsonpath='{.items[0].status.podIP}{"\n"}'
```

Save as `legacy.yaml`, replacing `10.244.1.3` with the IP printed above:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy
  namespace: l4lab
spec:
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 8080
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-1
  namespace: l4lab
  labels:
    kubernetes.io/service-name: legacy
    endpointslice.kubernetes.io/managed-by: staff.l4lab
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 8080
endpoints:
  - addresses:
      - "10.244.1.3"
    conditions:
      ready: true
```

```bash
kubectl apply -f legacy.yaml
kubectl -n l4lab exec client -- curl -s legacy/hostname; echo
```

3. Break it on purpose: change the slice's `ports[0].name` to `web` and re-apply.

```bash
sed -i 's/    - name: http\n    protocol: TCP\n    port: 8080//' legacy.yaml
kubectl -n l4lab patch endpointslice legacy-1 --type=json \
  -p '[{"op":"replace","path":"/ports/0/name","value":"web"}]'
kubectl -n l4lab exec client -- curl -s -m 2 legacy/hostname; echo "exit=$?"
kubectl -n l4lab patch endpointslice legacy-1 --type=json \
  -p '[{"op":"replace","path":"/ports/0/name","value":"http"}]'
```

(The `sed` line is a no-op kept only as a reminder that you could edit the file instead. The `patch` is what matters.)

4. Compare with `ExternalName`:

```bash
kubectl -n l4lab create service externalname docs --external-name kubernetes.io
kubectl -n l4lab exec client -- dig +short docs.l4lab.svc.cluster.local
```

**Check your understanding (Lab 8)**

- **Q8.1** Why does a headless Service produce no kube-proxy rules at all? Who does the "load balancing" then?
- **Q8.2** What does `publishNotReadyAddresses: true` do on a headless Service, and which workload type relies on it for peer discovery?
- **Q8.3** Why is the `endpointslice.kubernetes.io/managed-by` label important on a hand-made slice? What could happen if you set it to `endpointslice-controller.k8s.io`?
- **Q8.4** In step 3, why did traffic stop when only the port *name* changed?
- **Q8.5** Is `ExternalName` an L4 Service in the kube-proxy sense? What happens to the port you declare on it?

---

## Lab 9 — Troubleshooting drill

Apply this broken setup and make `curl -s shop/hostname` work from `client` **without touching the Deployment**. Save as `broken.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: l4lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shop
      tier: backend
  template:
    metadata:
      labels:
        app: shop
        tier: backend
    spec:
      containers:
        - name: netexec
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: web
              containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: shop
  namespace: l4lab
spec:
  selector:
    app: shop
    tier: frontend
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: http
```

```bash
kubectl apply -f broken.yaml
kubectl -n l4lab exec client -- curl -s -m 2 shop/hostname; echo "exit=$?"
```

Follow this diagnostic ladder and write down what each rung shows:

1. `kubectl -n l4lab get svc shop -o wide` — is there a ClusterIP, and what is the selector?
2. `kubectl -n l4lab get endpointslices -l kubernetes.io/service-name=shop -o wide` — are there endpoints?
3. `kubectl -n l4lab get pods -l app=shop --show-labels` — do the pod labels match the selector?
4. Fix the selector and repeat rung 2. Are endpoints now present, and **which port** do they list?
5. `kubectl -n l4lab get pod -l app=shop -o jsonpath='{.items[0].spec.containers[0].ports}'` — does `targetPort` match a named port?
6. Fix `targetPort` and confirm with `curl`.
7. If it still failed: `docker exec <node> iptables-save -t nat | grep l4lab/shop` and `kubectl -n kube-system logs ds/kube-proxy --tail=50`.

**Check your understanding (Lab 9)**

- **Q9.1** Which two defects did you find, and what symptom did each produce on its own?
- **Q9.2** Why does the EndpointSlice controller silently drop a pod whose container has no port matching a named `targetPort`, instead of raising an event?
- **Q9.3** Write the one-line `kubectl patch` that fixes both defects at once.

---

## Cleanup

```bash
kind delete cluster --name l4
```

---

## Answers

<details>
<summary><strong>Lab 0</strong></summary>

**Q0.1** kind taints the control-plane node with `node-role.kubernetes.io/control-plane:NoSchedule`, and the pod has no toleration. The two workers are the only eligible domains, so `maxSkew: 1` produces a 2/1 split. The scheduler only counts nodes that pass filtering, so the tainted control-plane node isn't an empty domain that would violate the skew.

**Q0.2** Every mode (iptables, nftables, IPVS) has different observable artifacts. IPVS binds ClusterIPs to `kube-ipvs0`, so ping works. nftables uses sets and maps instead of linear chains. Pinning the mode makes the expected output in Labs 3–6 reproducible. On Linux, iptables is the default, but relying on a default in a lab is fragile. See https://kubernetes.io/docs/reference/networking/virtual-ips/.

</details>

<details>
<summary><strong>Lab 1</strong></summary>

**Q1.1** kube-proxy doesn't resolve it. The EndpointSlice controller looks up the container port named `http` in **each pod** and writes the resulting number into the slice's `ports[].port`. During a rollout, old pods may expose 8080 and new pods 9090 under the same name. The Service keeps working for both sets because resolution happens per pod.

**Q1.2** UDP is connectionless, but netfilter conntrack still tracks a "flow" by the 5-tuple. The first datagram creates a conntrack entry with the DNAT decision, and later datagrams with the **same** source IP and port reuse it until the UDP timeout expires. In step 3 `nc` picks a new ephemeral source port each time, so each datagram is a new flow and a new random choice. This is also why stale UDP conntrack entries are a classic post-rollout failure. kube-proxy actively flushes UDP entries for removed endpoints.

**Q1.3** A multi-port Service must name its ports so they're unambiguous. The EndpointSlice matches `ports[].name` to the Service port name (you break exactly this in Lab 8). DNS publishes SRV records as `_<port-name>._<protocol>.<svc>.<ns>.svc.<zone>`.

**Q1.4** kube-proxy just programs one set of rules per (port, protocol). Cloud load balancers historically supported one protocol per LB, so the API rejected mixed protocols on LoadBalancer. `MixedProtocolLBService` went GA in v1.26. Whether it works now depends on the cloud provider.

</details>

<details>
<summary><strong>Lab 2</strong></summary>

**Q2.1** It's immediate: `curl: (7) Failed to connect … Connection refused`. For a Service with no endpoints, kube-proxy installs a `REJECT --reject-with icmp-port-unreachable` rule in the **filter** table (`KUBE-SERVICES`/`KUBE-EXTERNAL-SERVICES`), so clients fail fast instead of hanging on a SYN that goes nowhere.

**Q2.2** `ready` means "serving and not terminating", which is what normal routing uses. `serving` reflects only the readiness probe, regardless of termination. When **all** endpoints of a Service are terminating, kube-proxy falls back to endpoints that are `serving: true, terminating: true` rather than dropping traffic. This lets rolling updates with `externalTrafficPolicy: Local` drain gracefully. It's the ProxyTerminatingEndpoints behaviour, GA in v1.28.

**Q2.3** One `Endpoints` object held every backend, so any single pod change rewrote and redistributed the whole object to every node. For large Services that exhausted etcd object size limits and watch bandwidth. EndpointSlices shard the list (default max **100** endpoints per slice, set by `--max-endpoints-per-slice` on kube-controller-manager), and they add topology, conditions and dual-stack. See https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/.

**Q2.4** The Service is dual-stack: `ipFamilyPolicy` is `PreferDualStack` or `RequireDualStack`, with two entries in `ipFamilies`. The controller creates one slice family per address type.

</details>

<details>
<summary><strong>Lab 3</strong></summary>

**Q3.1** iptables evaluates rules in order, so the probabilities are conditional: 1/3 chance for the first, then 1/2 of the remaining 2/3 (= 1/3), then the last gets everything left (= 1/3). With 4 endpoints: 0.25, 0.333…, 0.5, unconditional.

**Q3.2** The first rule marks traffic to the ClusterIP from **outside the pod CIDR** (e.g. a node process or host-network pod). That traffic is SNAT'd, so the reply returns through the same node's conntrack. The `KUBE-SEP` rule handles **hairpin**: a pod reaches a Service and gets load-balanced to itself. Without masquerade, the pod would receive a packet from its own IP and reply directly to itself, bypassing the reverse NAT. The mark is consumed later in `KUBE-POSTROUTING` by a `MASQUERADE` rule.

**Q3.3** In iptables mode the ClusterIP exists only as a `-d <ip> -p tcp --dport 80` match. Nothing matches ICMP echo, and no interface owns the address, so the ping is routed toward the default gateway and lost. In IPVS mode kube-proxy binds every ClusterIP to the dummy interface `kube-ipvs0`, so the node's kernel answers ICMP itself. Ping succeeds, but that proves nothing about the backends.

**Q3.4** The first `src=… dst=10.96.143.27 … dport=80` tuple is the **original** direction as the client sent it. The second `src=10.244.1.3 … sport=8080` is the expected **reply** tuple. The reply's source is the backend pod, and that is how you see the DNAT result.

**Q3.5** iptables rules are evaluated linearly and updated by rewriting whole tables (`iptables-restore`). With tens of thousands of Services, both the per-packet lookup and the rule-sync time grow badly. nftables uses verdict maps and sets for O(1)-ish matching and supports incremental updates. See https://kubernetes.io/docs/reference/networking/virtual-ips/.

</details>

<details>
<summary><strong>Lab 4</strong></summary>

**Q4.1** With `Cluster`, kube-proxy marks externally arriving NodePort traffic for masquerade. On worker2 the packet is DNAT'd to a pod on worker, then SNAT'd to worker2's outgoing address, `172.18.0.3`. That's required so the reply goes back through worker2, which holds the conntrack state. When you enter on the pod's own node, the packet goes to the local bridge and is SNAT'd to the node's address on that interface, the pod-CIDR gateway `10.244.x.1`. Either way the real client IP is lost. See https://kubernetes.io/docs/tutorials/services/source-ip/.

**Q4.2** `Local` never forwards to another node, so no SNAT is needed and the client IP is preserved. The cost is that load is balanced **per node**, not per pod. An LB that splits 50/50 across two nodes sends 50% to the single pod on node A and 10% to each of the five pods on node B. Nodes without endpoints must also be taken out of rotation, which Lab 5's health check does. Topology spread keeps the imbalance small.

**Q4.3** For external traffic on a node with no local endpoint, kube-proxy uses a `DROP`, not a `REJECT`. The external LB is expected to use the health check to avoid that node, and a silent drop avoids confusing clients with RSTs while the LB converges. The client sees a timeout.

**Q4.4** The range is set by `--service-node-port-range` on kube-apiserver, default `30000-32767`. The apiserver's allocator rejects a duplicate: `Service "x" is invalid: spec.ports[0].nodePort: Invalid value: 30080: provided port is already allocated`.

</details>

<details>
<summary><strong>Lab 5</strong></summary>

**Q5.1** kube-apiserver allocates it from the NodePort range. kube-proxy serves `/healthz` on it on every node, answering 200 when the node has at least one local ready endpoint and 503 otherwise. The cloud load balancer (via the cloud controller manager) uses it as its target health check. It exists only for `Local` because with `Cluster` every node can forward to any endpoint, so per-node endpoint presence is irrelevant.

**Q5.2** No. Setting it to `false` stops **new** allocations, but existing `nodePort` values stay until you remove them explicitly from the spec. Disabling node ports suits load balancers that route **directly to pod IPs**, such as cloud LBs in "IP target" mode or MetalLB/BGP setups with pod routing. They never use node ports, so allocating them wastes the range and opens unnecessary ports on every node.

**Q5.3** No controller implements `type: LoadBalancer`. In clouds that's the cloud-controller-manager. Bare metal needs something like MetalLB (L2/ARP or BGP), kube-vip, or Cilium's LB-IPAM with BGP/L2 announcements. Until one of them writes `status.loadBalancer.ingress`, the Service stays `<pending>`, although its ClusterIP and NodePort work.

</details>

<details>
<summary><strong>Lab 6</strong></summary>

**Q6.1** The default is **10800 s (3 h)**. In iptables mode the `recent` module is refreshed with `--set` on every packet that matches, so the timeout counts from the **last** packet seen, not the first.

**Q6.2** With `Cluster` policy, NodePort traffic is SNAT'd **before** reaching the backend, but affinity is evaluated on the source IP at the node that received the packet. So affinity follows the NAT gateway address. Every user behind the corporate NAT pins to one pod, which is a hot spot, and stickiness per real user doesn't exist at all. Different nodes also keep independent affinity tables, so if an external LB sprays the same client across nodes, it can land on different pods.

**Q6.3** L4 affinity only knows IP addresses. It breaks with NAT, IP changes (mobile clients), per-node tables, and endpoint churn. When the pinned pod goes away the session moves with no notice. Cookie stickiness at L7 (Ingress/Gateway) identifies the user, not the address.

</details>

<details>
<summary><strong>Lab 7</strong></summary>

**Q7.1** Never. `Local` means "only endpoints on the node where the client runs". With none, kube-proxy drops the traffic, and `curl` times out (`exit=28`). That's the intended semantics. See https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/.

**Q7.2** Node-local agents run as a DaemonSet, e.g. a log/metrics collector, a node-local DNS cache, or a tracing agent. Pods should talk to the instance on their own node to avoid cross-node hops and keep per-node data local. Because a DaemonSet guarantees one endpoint per node, the "no fallback" rule is acceptable.

**Q7.3** `PreferClose` is a **preference**: kube-proxy uses same-zone endpoints when the hints allow it and otherwise falls back to all endpoints, so traffic never drops just because the zone is empty. The EndpointSlice controller writes `endpoints[].hints.forZones`, and kube-proxy on each node reads those hints and keeps only the endpoints hinted for its own zone.

**Q7.4** No. `internalTrafficPolicy` applies only to traffic that originates **inside** the cluster and targets the ClusterIP. External traffic arriving through NodePort, LoadBalancer or externalIPs follows `externalTrafficPolicy`.

</details>

<details>
<summary><strong>Lab 8</strong></summary>

**Q8.1** A headless Service has no virtual IP, so there's nothing to DNAT. The EndpointSlices still exist, but kube-proxy skips headless Services. CoreDNS returns the set of pod A/AAAA records, and the **client** chooses: usually its resolver takes the first answer, possibly rotated. That's why client-side load balancing and connection pooling matter with headless Services.

**Q8.2** It publishes DNS records for pods even before they're ready. A StatefulSet (etcd, ZooKeeper, Cassandra, and so on) behind a governing headless Service relies on it: peers must be able to resolve `pod-0.svc` to form a quorum **before** any of them can pass a readiness probe that requires the quorum.

**Q8.3** The label tells controllers and tooling who owns the slice. The built-in EndpointSlice controller only manages, and garbage-collects, slices labeled `endpointslice-controller.k8s.io`. If you forge that value on a selectorless Service, the controller may treat the slice as its own and delete or rewrite it, and your manual endpoints disappear.

**Q8.4** kube-proxy joins a Service port to slice ports **by name**. The Service port is `http`, and the slice advertised only `web`, so for the `http` port the Service had zero endpoints. That produced the REJECT rule from Q2.1, even though an address and port were present.

**Q8.5** No. `ExternalName` is implemented purely in DNS as a CNAME to `kubernetes.io`. No ClusterIP, no kube-proxy rules and no port translation exist. The declared port is informational only: the client connects to whatever port it uses against the CNAME target.

</details>

<details>
<summary><strong>Lab 9</strong></summary>

**Q9.1** The first defect is the selector `tier: frontend` while the pods are `tier: backend`. On its own it gives zero endpoints, so the connection is refused immediately (REJECT rule). The second defect is `targetPort: http` while the container port is named `web`. Once the selector is fixed, the pods are still excluded from the slice, because the named port can't be resolved on them. The symptom stays the same: no endpoints, connection refused. That's why rung 4 is the one that reveals it.

**Q9.2** A missing named port is valid by design. A Service may target a heterogeneous set of pods where only some expose that port name (see Q1.1), so the controller treats "no such port on this pod" as "this pod doesn't serve this Service port", not as an error. You have to find it by comparing `targetPort` with `spec.containers[].ports[].name`.

**Q9.3**

```bash
kubectl -n l4lab patch svc shop --type=merge \
  -p '{"spec":{"selector":{"app":"shop","tier":"backend"},"ports":[{"name":"http","protocol":"TCP","port":80,"targetPort":"web"}]}}'
```

With a merge patch, `selector` is merged key by key, and the `ports` list is replaced as a whole, which is what you want here. Check with `kubectl -n l4lab exec client -- curl -s shop/hostname`.

</details>