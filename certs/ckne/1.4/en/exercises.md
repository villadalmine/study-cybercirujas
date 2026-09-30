# Guided Exercises — Topic 1.4: Troubleshooting Pod Connectivity (DNS, pod-to-pod)

These exercises build a small lab, break it in controlled ways, and diagnose each fault one layer at a time. Every failure is diagnosed in the same order, from the bottom up:

1. **Pod IP reachability.** This is the CNI's job.
2. **Service → endpoints.** This is the control plane plus kube-proxy or the eBPF dataplane.
3. **DNS name → Service IP.** This is CoreDNS plus the pod's `resolv.conf`.
4. **Policy.** This is NetworkPolicy enforcement by the CNI.

**Official references used throughout:**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Debug Running Pods (ephemeral containers, `kubectl debug`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Cluster Networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- CoreDNS `kubernetes` plugin: https://coredns.io/plugins/kubernetes/
- CoreDNS `log` plugin: https://coredns.io/plugins/log/
- kind configuration: https://kind.sigs.k8s.io/docs/user/configuration/

> IP addresses, pod names and node names in the sample outputs will differ in your cluster. Compare the **shape** of the output, not the exact values.

---

## Exercise 0 — Build the lab

You need a cluster with **at least two worker nodes**, because some faults only show up when traffic crosses nodes. Any conformant cluster works. The steps below use kind.

**Step 0.1.** Save this as `kind-lab.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

**Step 0.2.** Create the cluster and the namespace:

```bash
kind create cluster --name lab --config kind-lab.yaml
kubectl create namespace lab-net
kubectl get nodes -o wide
```

Expected output (shape):

```
NAME                STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
lab-control-plane   Ready    control-plane   60s   v1.3x.x   172.18.0.2    ...
lab-worker          Ready    <none>          40s   v1.3x.x   172.18.0.3    ...
lab-worker2         Ready    <none>          40s   v1.3x.x   172.18.0.4    ...
```

**Step 0.3.** Save the backend Deployment as `backend-deploy.yaml`. The `topologySpreadConstraints` block places the two replicas on different nodes.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: lab-net
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: backend
      containers:
        - name: backend
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
```

**Step 0.4.** Save a ClusterIP Service as `backend-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: lab-net
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 80
      targetPort: http
```

**Step 0.5.** Save a headless Service as `backend-headless.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-headless
  namespace: lab-net
spec:
  clusterIP: None
  selector:
    app: backend
  ports:
    - name: http
      port: 8080
      targetPort: http
```

**Step 0.6.** Save the diagnostic client as `client.yaml`. It gets `NET_ADMIN` and `NET_RAW` so that `tcpdump` works inside it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: lab-net
  labels:
    app: client
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
```

**Step 0.7.** Apply everything and wait for it to become ready:

```bash
kubectl apply -f backend-deploy.yaml -f backend-svc.yaml -f backend-headless.yaml -f client.yaml
kubectl -n lab-net rollout status deploy/backend
kubectl -n lab-net wait --for=condition=Ready pod/client --timeout=120s
kubectl -n lab-net get pods -o wide
```

Expected output (shape):

```
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE
backend-6d8f7c9b5d-7kq2x   1/1     Running   0          30s   10.244.1.3   lab-worker
backend-6d8f7c9b5d-zx9pl   1/1     Running   0          30s   10.244.2.3   lab-worker2
client                     1/1     Running   0          25s   10.244.1.4   lab-worker
```

**Questions**

- **Q0.1** Why is `targetPort: http` more robust than `targetPort: 8080`?
- **Q0.2** What would happen to the Deployment if the cluster had only one worker node and the control-plane node is tainted? Why?

---

## Exercise 1 — Layer 1: pod-to-pod reachability without DNS or Services

This layer takes DNS and Services out of the picture. If a pod cannot reach another pod's IP, nothing built on top of that will work.

**Step 1.1.** Save the backend pod IPs in variables:

```bash
B1=$(kubectl -n lab-net get pods -l app=backend -o jsonpath='{.items[0].status.podIP}')
B2=$(kubectl -n lab-net get pods -l app=backend -o jsonpath='{.items[1].status.podIP}')
echo "$B1 $B2"
```

**Step 1.2.** Call each pod IP directly. One call stays on the client's node and the other crosses nodes.

```bash
kubectl -n lab-net exec client -- curl -s --max-time 3 http://$B1:8080/hostname; echo
kubectl -n lab-net exec client -- curl -s --max-time 3 http://$B2:8080/hostname; echo
```

Expected output: each call prints the name of the pod that answered.

```
backend-6d8f7c9b5d-7kq2x
backend-6d8f7c9b5d-zx9pl
```

**Step 1.3.** Look at the network namespace from inside the client pod:

```bash
kubectl -n lab-net exec client -- ip -brief addr
kubectl -n lab-net exec client -- ip route
```

Expected output (shape, from a kindnet/ptp-style CNI):

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if7         UP             10.244.1.4/24 ...

default via 10.244.1.1 dev eth0
10.244.1.0/24 via 10.244.1.1 dev eth0 src 10.244.1.4
10.244.1.1 dev eth0 scope link src 10.244.1.4
```

**Step 1.4.** Open a debug shell on the client's node. This shell shares the node's network namespace. `--profile=sysadmin` makes it privileged.

```bash
NODE=$(kubectl -n lab-net get pod client -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
```

Inside that shell, run:

```bash
ip route | grep 10.244
ip -brief link | grep veth
```

Expected output (shape):

```
10.244.0.0/24 via 172.18.0.2 dev eth0
10.244.1.3 dev veth1a2b3c4d scope host
10.244.1.4 dev veth5e6f7a8b scope host
10.244.2.0/24 via 172.18.0.4 dev eth0
veth1a2b3c4d@if2  UP  ...
veth5e6f7a8b@if2  UP  ...
```

Type `exit` to leave the shell. `kubectl debug node` leaves a pod named `node-debugger-...` behind. Delete it:

```bash
kubectl get pods -o name | grep node-debugger | xargs -r kubectl delete
```

**Step 1.5.** Capture traffic on the backend with an **ephemeral container** that shares the backend container's process namespace:

```bash
BPOD=$(kubectl -n lab-net get pods -l app=backend -o jsonpath='{.items[1].metadata.name}')
kubectl -n lab-net debug -it pod/$BPOD --profile=netadmin --image=nicolaka/netshoot:v0.13 --target=backend -- tcpdump -ni eth0 -c 6 tcp port 8080
```

In a second terminal, run the Step 1.2 `curl` against `$B2` again. Expected output (shape):

```
IP 10.244.1.4.51234 > 10.244.2.3.8080: Flags [S], seq ...
IP 10.244.2.3.8080 > 10.244.1.4.51234: Flags [S.], seq ...
IP 10.244.1.4.51234 > 10.244.2.3.8080: Flags [.], ack ...
...
```

**Questions**

- **Q1.1** In the Step 1.5 capture, the source IP is the client pod's IP and not the node IP. Which requirement of the Kubernetes network model does that show?
- **Q1.2** In Step 1.4, pod IPs on the local node have `/32` host routes and other nodes' pod CIDRs have `via <nodeIP>` routes. If the `10.244.2.0/24` route were missing on `lab-worker`, which of the two Step 1.2 curls would fail, and how would the failure look (timeout or refused)?
- **Q1.3** Why do you need `--profile=netadmin` (or explicit capabilities) to run `tcpdump` in an ephemeral container, while `curl` works without them?
- **Q1.4** Pod-to-pod works on the same node but times out across nodes. List three likely causes, ordered by how often you would check them.

---

## Exercise 2 — Layer 2: Service → endpoints

**Step 2.1.** Check that the Service has endpoints. EndpointSlices are the current source of truth.

```bash
kubectl -n lab-net get svc backend
kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend
```

Expected output (shape):

```
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
backend   ClusterIP   10.96.143.21   <none>        80/TCP    5m

NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
backend-abcde   IPv4          8080    10.244.1.3,10.244.2.3   5m
```

**Step 2.2.** Call the ClusterIP a few times and watch the requests spread across pods:

```bash
SVC=$(kubectl -n lab-net get svc backend -o jsonpath='{.spec.clusterIP}')
for i in 1 2 3 4 5 6; do kubectl -n lab-net exec client -- curl -s --max-time 3 http://$SVC/hostname; echo; done
```

**Step 2.3 — Fault A: selector mismatch.** Break the selector:

```bash
kubectl -n lab-net patch svc backend -p '{"spec":{"selector":{"app":"backend-v2"}}}'
kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend
kubectl -n lab-net exec client -- curl -sS --max-time 3 http://$SVC/hostname
kubectl -n lab-net exec client -- nslookup backend
```

Expected output (shape):

```
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
backend-abcde   IPv4          <unset>   <unset>     6m

curl: (7) Failed to connect to 10.96.143.21 port 80 after 1 ms: Couldn't connect to server

Name:   backend.lab-net.svc.cluster.local
Address: 10.96.143.21
```

Restore the selector:

```bash
kubectl -n lab-net patch svc backend -p '{"spec":{"selector":{"app":"backend"}}}'
```

**Step 2.4 — Fault B: wrong targetPort.** Point the Service at a port nothing listens on:

```bash
kubectl -n lab-net patch svc backend --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9090}]'
kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend
kubectl -n lab-net exec client -- curl -sS --max-time 3 http://$SVC/hostname
```

Expected output (shape):

```
NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
backend-abcde   IPv4          9090    10.244.1.3,10.244.2.3   7m

curl: (7) Failed to connect to 10.96.143.21 port 80 after 2 ms: Couldn't connect to server
```

Restore the targetPort:

```bash
kubectl -n lab-net patch svc backend --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
```

**Step 2.5 — Fault C: pod not Ready.** agnhost exposes no readiness toggle, so simulate one: add a readiness probe that always fails to one pod's template and watch the endpoint state.

```bash
kubectl -n lab-net patch deploy backend --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":{"exec":{"command":["false"]},"periodSeconds":2}}]'
sleep 20
kubectl -n lab-net get pods -l app=backend
kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
```

Expected output (shape). This is during the rollout: with `maxUnavailable` the old pods keep serving, so the new pods show as not ready while the old ones are still ready.

```
NAME                       READY   STATUS    RESTARTS   AGE
backend-6d8f7c9b5d-7kq2x   1/1     Running   0          9m
backend-6d8f7c9b5d-zx9pl   1/1     Running   0          9m
backend-7f9c8d6e4b-q1w2e   0/1     Running   0          20s

10.244.1.3 ready=true
10.244.2.3 ready=true
10.244.2.7 ready=false
```

Roll back:

```bash
kubectl -n lab-net rollout undo deploy/backend
kubectl -n lab-net rollout status deploy/backend
```

**Questions**

- **Q2.1** In Fault A, DNS still returned the ClusterIP. Why does that prove DNS is **not** the problem? What does the empty EndpointSlice tell you?
- **Q2.2** Faults A and B both give "Couldn't connect" almost instantly. Which component answered in each case, and which single command told them apart?
- **Q2.3** In Fault C, why is a failing readiness probe safer than a failing liveness probe for this kind of test? Why did the rollout not take the Service down completely?
- **Q2.4** With kube-proxy in iptables mode, how could you confirm on a node that rules for the ClusterIP exist? Give the command.

---

## Exercise 3 — Layer 3: how the pod resolves names

**Step 3.1.** Look at the resolver configuration the kubelet wrote into the pod:

```bash
kubectl -n lab-net exec client -- cat /etc/resolv.conf
kubectl -n kube-system get svc kube-dns
```

Expected output (shape):

```
search lab-net.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5

NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   30m
```

**Step 3.2.** Resolve the same Service with names of increasing length:

```bash
kubectl -n lab-net exec client -- nslookup backend
kubectl -n lab-net exec client -- nslookup backend.lab-net
kubectl -n lab-net exec client -- nslookup backend.lab-net.svc.cluster.local
kubectl -n lab-net exec client -- nslookup kubernetes.default
```

**Step 3.3.** Compare the ClusterIP Service with the headless Service, then query SRV records:

```bash
kubectl -n lab-net exec client -- dig +short backend.lab-net.svc.cluster.local
kubectl -n lab-net exec client -- dig +short backend-headless.lab-net.svc.cluster.local
kubectl -n lab-net exec client -- dig +short SRV _http._tcp.backend.lab-net.svc.cluster.local
kubectl -n lab-net exec client -- dig +short SRV _http._tcp.backend-headless.lab-net.svc.cluster.local
```

Expected output (shape):

```
10.96.143.21

10.244.1.3
10.244.2.3

0 100 80 backend.lab-net.svc.cluster.local.

0 50 8080 10-244-1-3.backend-headless.lab-net.svc.cluster.local.
0 50 8080 10-244-2-3.backend-headless.lab-net.svc.cluster.local.
```

**Step 3.4.** Watch the **ndots amplification** on the wire. Start a capture in the background, then resolve an external name that has fewer than 5 dots:

```bash
kubectl -n lab-net exec client -- sh -c 'tcpdump -ni eth0 -c 16 udp port 53 2>/dev/null & sleep 1; nslookup kubernetes.io >/dev/null 2>&1; sleep 2'
```

Expected output (shape, trimmed; A and AAAA queries go out for each attempt):

```
IP 10.244.1.4.40211 > 10.96.0.10.53: A? kubernetes.io.lab-net.svc.cluster.local.
IP 10.96.0.10.53 > 10.244.1.4.40211: NXDomain
IP 10.244.1.4.40211 > 10.96.0.10.53: A? kubernetes.io.svc.cluster.local.
IP 10.96.0.10.53 > 10.244.1.4.40211: NXDomain
IP 10.244.1.4.40211 > 10.96.0.10.53: A? kubernetes.io.cluster.local.
IP 10.96.0.10.53 > 10.244.1.4.40211: NXDomain
IP 10.244.1.4.40211 > 10.96.0.10.53: A? kubernetes.io.
IP 10.96.0.10.53 > 10.244.1.4.40211: 1/0/0 A ...
```

> If your cluster has no Internet egress, the last query returns SERVFAIL or times out. The search-list expansion before it is what this step demonstrates.

Repeat the capture with a fully qualified name (note the trailing dot):

```bash
kubectl -n lab-net exec client -- sh -c 'tcpdump -ni eth0 -c 4 udp port 53 2>/dev/null & sleep 1; nslookup kubernetes.io. >/dev/null 2>&1; sleep 2'
```

**Step 3.5.** Tune ndots per pod with `dnsConfig`. Save this as `client-ndots.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client-ndots
  namespace: lab-net
  labels:
    app: client
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
```

```bash
kubectl apply -f client-ndots.yaml
kubectl -n lab-net wait --for=condition=Ready pod/client-ndots --timeout=120s
kubectl -n lab-net exec client-ndots -- cat /etc/resolv.conf
kubectl -n lab-net exec client-ndots -- nslookup backend
kubectl -n lab-net exec client-ndots -- nslookup backend.lab-net
```

**Questions**

- **Q3.1** With `ndots:5`, why does `nslookup backend` succeed on the **first** query, while `kubernetes.io` needs four attempts (eight counting AAAA)?
- **Q3.2** With `ndots:2`, what happens to `backend.lab-net` (one dot) and to `backend.lab-net.svc` (two dots)? Which of the two now needs an extra NXDOMAIN round trip or fails outright?
- **Q3.3** The headless Service returned pod IPs and the ClusterIP Service returned a single virtual IP. For a client that caches DNS for a long time, which of the two is more fragile during a rolling update, and why?
- **Q3.4** Name two ways to cut external-lookup amplification without changing the cluster-wide DNS configuration.

---

## Exercise 4 — Layer 3: CoreDNS health and dnsPolicy mistakes

**Step 4.1.** Check the CoreDNS control plane:

```bash
kubectl -n kube-system get deploy coredns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

Expected Corefile (shape; typical kubeadm/kind default):

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

**Step 4.2.** Query one CoreDNS pod **directly**, bypassing the `kube-dns` Service, and read its metrics:

```bash
DNSPOD_IP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
kubectl -n lab-net exec client -- dig +short @$DNSPOD_IP backend.lab-net.svc.cluster.local
kubectl -n lab-net exec client -- sh -c "curl -s http://$DNSPOD_IP:9153/metrics | grep '^coredns_dns_responses_total'"
```

Expected output (shape):

```
10.96.143.21
coredns_dns_responses_total{plugin="kubernetes",rcode="NOERROR",server="dns://:53",...} 42
coredns_dns_responses_total{plugin="kubernetes",rcode="NXDOMAIN",server="dns://:53",...} 18
```

**Step 4.3.** Turn on query logging. Add the `log` plugin on its own line after `errors` in the Corefile. The `reload` plugin picks the change up on its own. ConfigMap propagation plus the reload interval can take up to about 1–2 minutes.

```bash
kubectl -n kube-system edit configmap coredns
# add a line containing only:  log
sleep 90
kubectl -n lab-net exec client -- nslookup backend >/dev/null
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5
```

Expected output (shape):

```
[INFO] plugin/reload: Running configuration SHA512 = 3c1d...
[INFO] 10.244.1.4:52811 - 1234 "A IN backend.lab-net.svc.cluster.local. udp 51 false 512" NOERROR qr,aa,rd 100 0.000213s
```

Remove the `log` line afterwards. On a busy cluster, per-query logging is expensive.

**Step 4.4 — Fault D: DNS unavailable.** Scale CoreDNS to zero:

```bash
kubectl -n kube-system scale deploy coredns --replicas=0
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n lab-net exec client -- nslookup -timeout=2 backend
kubectl -n lab-net exec client -- curl -s --max-time 3 http://$SVC/hostname; echo
```

Expected output (shape; the exact error text depends on the tool and on whether the dataplane rejects or drops):

```
;; communications error to 10.96.0.10#53: connection refused
;; no servers could be reached

backend-6d8f7c9b5d-7kq2x
```

Restore CoreDNS:

```bash
kubectl -n kube-system scale deploy coredns --replicas=2
kubectl -n kube-system rollout status deploy coredns
```

**Step 4.5 — Fault E: the wrong dnsPolicy.** Save this as `client-default-dns.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client-default-dns
  namespace: lab-net
spec:
  dnsPolicy: Default
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f client-default-dns.yaml
kubectl -n lab-net wait --for=condition=Ready pod/client-default-dns --timeout=120s
kubectl -n lab-net exec client-default-dns -- cat /etc/resolv.conf
kubectl -n lab-net exec client-default-dns -- nslookup backend.lab-net.svc.cluster.local
```

Expected output (shape):

```
nameserver 172.18.0.1
options ndots:0

** server can't find backend.lab-net.svc.cluster.local: NXDOMAIN
```

**Questions**

- **Q4.1** In Step 4.2 you queried a CoreDNS pod IP directly. If the direct query works but queries to `10.96.0.10` fail, which layer is broken?
- **Q4.2** During Fault D, the `curl` to the ClusterIP **still worked**. What does that tell you about where name resolution sits relative to Service forwarding?
- **Q4.3** In Fault E, why does `dnsPolicy: Default` **not** mean "the Kubernetes default"? What is the actual default?
- **Q4.4** A pod with `hostNetwork: true` cannot resolve `backend.lab-net.svc.cluster.local` even though its `dnsPolicy` is `ClusterFirst`. What is the fix?
- **Q4.5** Which three distinct DNS failure signatures have you seen so far (rcode or error), and which layer does each point to?

---

## Exercise 5 — Layer 4: NetworkPolicy breaks DNS

**Step 5.1.** Check that your CNI enforces NetworkPolicy. A policy object is accepted by the API server even when no dataplane enforces it. Save this as `np-deny-egress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: lab-net
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
    - Egress
```

```bash
kubectl apply -f np-deny-egress.yaml
kubectl -n lab-net exec client -- curl -s --max-time 3 http://$B1:8080/hostname; echo "exit=$?"
```

If `curl` still prints a hostname, your CNI does **not** enforce NetworkPolicy. Recent kind releases ship kindnet with enforcement; otherwise install Calico or Cilium. Continue only if you get a timeout:

```
exit=28
```

**Step 5.2.** Confirm that DNS broke as a side effect:

```bash
kubectl -n lab-net exec client -- nslookup -timeout=2 backend
```

Expected output (shape):

```
;; connection timed out; no servers could be reached
```

**Step 5.3.** Allow DNS egress to CoreDNS only, over both UDP and TCP. Save this as `np-allow-dns.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: lab-net
spec:
  podSelector:
    matchLabels:
      app: client
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
```

```bash
kubectl apply -f np-allow-dns.yaml
kubectl -n lab-net exec client -- nslookup backend
kubectl -n lab-net exec client -- curl -s --max-time 3 http://backend/hostname; echo "exit=$?"
```

Expected output: DNS resolves, but the HTTP call still times out.

```
Name:   backend.lab-net.svc.cluster.local
Address: 10.96.143.21
exit=28
```

**Step 5.4.** Allow egress to the backend. Look closely at the **port** in this policy. Save this as `np-allow-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-backend
  namespace: lab-net
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl apply -f np-allow-backend.yaml
kubectl -n lab-net exec client -- curl -s --max-time 3 http://backend/hostname; echo
```

**Step 5.5.** Try the version that looks right but is wrong. Change `port: 8080` to `port: 80` (the Service port), re-apply, and test again:

```bash
sed 's/port: 8080/port: 80/' np-allow-backend.yaml | kubectl apply -f -
kubectl -n lab-net exec client -- curl -s --max-time 3 http://backend/hostname; echo "exit=$?"
kubectl apply -f np-allow-backend.yaml
```

**Step 5.6.** List what now applies to the client:

```bash
kubectl -n lab-net get networkpolicy
kubectl -n lab-net describe networkpolicy allow-dns-egress
```

**Questions**

- **Q5.1** Why did Step 5.2 fail with a *timeout*, while Fault D (Exercise 4) failed with *connection refused*? What does that difference tell you right away during an incident?
- **Q5.2** Why must the DNS policy allow **TCP** 53 as well as UDP 53?
- **Q5.3** In Step 5.3, `namespaceSelector` and `podSelector` sit in the **same** list element. What would change if they were two separate elements (two `-` entries)?
- **Q5.4** Why did `port: 80` in Step 5.5 block traffic to the Service, when the client calls `http://backend` on port 80?
- **Q5.5** Several NetworkPolicies select the same pod. How are they combined? Can a later policy "deny" something an earlier one allowed?

---

## Exercise 6 — Final scenario: diagnose without hints

**Step 6.1.** Run this script. It injects **two** faults at once:

```bash
kubectl -n lab-net delete networkpolicy --all
kubectl -n lab-net label pods -l app=backend app=backend-old --overwrite
kubectl apply -f np-deny-egress.yaml
```

**Step 6.2.** Using only what you have practiced, bring `kubectl -n lab-net exec client -- curl -s --max-time 3 http://backend/hostname` back to working. Keep a written record of the order in which you checked each layer.

**Questions**

- **Q6.1** What were the two faults, and which command revealed each one?
- **Q6.2** Relabeling the pods had a side effect on the Deployment. What did the ReplicaSet controller do, and why?
- **Q6.3** Write the minimal fix and explain why you would clean up the orphaned pods.

**Cleanup**

```bash
kind delete cluster --name lab
```

---

## Answers

<details>
<summary><strong>Exercise 0</strong></summary>

**Q0.1** A named `targetPort` is looked up in each pod's `containerPort` list. If a new image version moves the port and updates `containerPort` with the same name, the Service keeps working with no change to the Service object. Different pods behind the same Service can even use different port numbers during a migration.

**Q0.2** The second replica stays `Pending`. `whenUnsatisfiable: DoNotSchedule` with `maxSkew: 1` forbids putting both replicas on the only schedulable node, because the skew against a node with zero replicas would be 2. The control-plane node is excluded by its `NoSchedule` taint. `kubectl describe pod` shows the scheduler event explaining the unmet topology spread constraint.

</details>

<details>
<summary><strong>Exercise 1</strong></summary>

**Q1.1** Every pod can talk to every other pod **without NAT**: the IP a pod sees for itself is the IP its peers see. This is a core requirement of the Kubernetes network model (https://kubernetes.io/docs/concepts/cluster-administration/networking/).

**Q1.2** Only the curl to `$B2` fails, because it lives on `lab-worker2`, in `10.244.2.0/24`. Same-node traffic uses the host-scope veth route. With no specific route, the packet follows the node's default route toward the Docker bridge or gateway, which does not know the pod CIDR. It is usually dropped or black-holed, so you see a **timeout**, not a refusal. Cross-node timeouts point at routing, tunnels (VXLAN/Geneve), MTU or policy; a fast "refused" points at a live host rejecting.

**Q1.3** `tcpdump` opens a raw `AF_PACKET` socket, which needs `CAP_NET_RAW` (and `CAP_NET_ADMIN` for some interface operations). `curl` uses ordinary TCP sockets, which need no extra capability. The `netadmin` profile of `kubectl debug` adds those capabilities to the ephemeral container.

**Q1.4** In a typical order:
1. Missing routes, or the CNI agent or daemon is unhealthy on one node (`kubectl -n kube-system get pods -o wide` for the CNI; `ip route` on the node).
2. The overlay is blocked between nodes: a cloud security group or host firewall drops VXLAN UDP 4789/8472, Geneve 6081 or IP-in-IP (protocol 4), or BGP sessions are down.
3. MTU mismatch. Small packets such as the SYN pass while large ones are dropped. The classic symptom is "connects, then hangs". Test with `ping -M do -s <size>`.

Also check the pod CIDR assigned to each node (`kubectl get nodes -o jsonpath='{..podCIDR}'`) for overlaps with the underlay network.

</details>

<details>
<summary><strong>Exercise 2</strong></summary>

**Q2.1** DNS answers from the Service object, not from its endpoints. A correct ClusterIP proves that name → IP resolution works. The empty EndpointSlice says that no Ready pod matches the selector, so the problem is between the Service and its pods: labels, selector or readiness. Compare `kubectl get svc backend -o jsonpath='{.spec.selector}'` with `kubectl get pods --show-labels`.

**Q2.2** In Fault A, the **node's dataplane** answered. kube-proxy in iptables mode installs a `REJECT` rule for Services with no endpoints, so the client gets an immediate refusal from its own node. In Fault B, packets were DNAT'd to a real pod, and the **pod's kernel** sent a TCP RST because nothing listens on 9090. The command that separated them is `kubectl get endpointslices -l kubernetes.io/service-name=backend`: empty in A, populated with port `9090` in B.

**Q2.3** A failing readiness probe only removes the pod from the endpoints (`ready=false`). The container keeps running, so you can still inspect it. A failing liveness probe makes the kubelet restart the container repeatedly (CrashLoop/backoff), which adds noise. The Service survived because the rolling update respects `maxUnavailable`: the old Ready pods stayed in the EndpointSlice while the new pods never became Ready, so the rollout stalled instead of taking capacity away.

**Q2.4** From a privileged node shell (`kubectl debug node/<n> -it --profile=sysadmin ...`):

```bash
iptables-save -t nat | grep 10.96.143.21
```

You should see a `KUBE-SERVICES` rule jumping to a `KUBE-SVC-...` chain, which in turn jumps to `KUBE-SEP-...` chains, one per endpoint, each with a `DNAT --to-destination <podIP>:8080`. In nftables mode, use `nft list table ip kube-proxy`. In IPVS mode, use `ipvsadm -Ln -t 10.96.143.21:80`. With eBPF dataplanes such as Cilium, use their own tooling, for example `cilium-dbg service list`.

</details>

<details>
<summary><strong>Exercise 3</strong></summary>

**Q3.1** A name with fewer dots than `ndots` is first tried with each search domain appended, in order. `backend` has 0 dots, so the first candidate is `backend.lab-net.svc.cluster.local`, which exists, and the lookup stops there. `kubernetes.io` has 1 dot (< 5), so the resolver tries `kubernetes.io.lab-net.svc.cluster.local`, then `.svc.cluster.local`, then `.cluster.local`, all NXDOMAIN, and only then the absolute name. That is 4 attempts per record type; with A and AAAA it becomes 8 queries. The search-list and `ndots` behavior is described in https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/.

**Q3.2** With `ndots:2`:
- `backend.lab-net` has 1 dot (< 2), so the search list is still applied first. `backend.lab-net.lab-net.svc.cluster.local` fails, then `backend.lab-net.svc.cluster.local` succeeds. That costs **one extra NXDOMAIN** round trip.
- `backend.lab-net.svc` has 2 dots (≥ 2), so it is tried **as an absolute name first**. `backend.lab-net.svc.` goes upstream and returns NXDOMAIN, and only then does the search list run. The lookup is slower and leaks a query outside the cluster.

Lowering ndots speeds up external names and penalizes partially qualified internal ones. The robust practice is to use short names (`backend`) or fully qualified names with a trailing dot (`backend.lab-net.svc.cluster.local.`).

**Q3.3** The **headless** Service is more fragile. Its A records are pod IPs, and when pods are replaced those IPs disappear. A client holding a stale cached answer (the JVM historically cached indefinitely, and some HTTP clients pin connections) keeps dialing dead IPs. A ClusterIP never changes for the life of the Service; the dataplane re-maps it to current endpoints on every new connection.

**Q3.4** Any two of these:
- Use FQDNs with a trailing dot in application config (`api.example.com.`).
- Set a lower `ndots` via `dnsConfig` on the affected workloads.
- Run NodeLocal DNSCache, which does not change the Corefile semantics but absorbs the NXDOMAIN burst on the node.
- Make sure the upstream answers AAAA fast; the CoreDNS `cache` plugin also caches negative answers.

</details>

<details>
<summary><strong>Exercise 4</strong></summary>

**Q4.1** CoreDNS itself is healthy, so the problem is in the **Service layer for `kube-dns`**: empty or stale EndpointSlices, missing kube-proxy/dataplane rules for `10.96.0.10` on the client's node, a broken kube-proxy on that node, or a NetworkPolicy that treats traffic to the Service differently. Next, check `kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns` and the kube-proxy (or CNI) pod logs on that node.

**Q4.2** Name resolution happens **before** a connection and is fully independent of it. The dataplane forwards the ClusterIP with no involvement from DNS. A DNS outage breaks only *new* lookups; clients that already have an IP (hardcoded, cached, or held on existing connections) keep working. That is why DNS outages often show up as partial failures that grow over time as caches expire (the `cache 30` / `ttl 30` values).

**Q4.3** `dnsPolicy: Default` means "inherit the **node's** resolver configuration". The pod gets the node's `/etc/resolv.conf` (in kind, the Docker network's DNS), which knows nothing about `cluster.local`, hence the NXDOMAIN. The actual default when the field is omitted is **`ClusterFirst`**: queries go to the cluster DNS Service, with the namespace search list and `ndots:5`.

**Q4.4** Set `dnsPolicy: ClusterFirstWithHostNet`. For `hostNetwork: true` pods, `ClusterFirst` quietly falls back to `Default` behavior. `ClusterFirstWithHostNet` makes them use cluster DNS.

**Q4.5**
- **NXDOMAIN** (Fault E; also typos or the wrong namespace): the server answered authoritatively that the name does not exist. Suspect the name, the search list, or the pod using the wrong resolver (`dnsPolicy`).
- **Connection refused / no servers reached** (Fault D): the dataplane rejected traffic to the kube-dns ClusterIP because it had no endpoints. Suspect CoreDNS availability.
- **Timeout** (Exercise 5): packets were silently dropped. Suspect NetworkPolicy, a firewall, conntrack/UDP issues, or an overloaded CoreDNS.

A fourth signature to remember is **SERVFAIL**. CoreDNS is reachable but its upstream (`forward`) failed, or the `loop` plugin detected a forwarding loop. Check the CoreDNS logs.

</details>

<details>
<summary><strong>Exercise 5</strong></summary>

**Q5.1** NetworkPolicy enforcement usually **drops** packets silently, so the client waits until its timeout. A missing-endpoints Service is **rejected** actively (ICMP port unreachable or TCP RST), so the error is immediate. In an incident, "instant failure" points at endpoints or a closed port, and "hangs then times out" points at policy, routing, firewall or MTU. The exact behavior can vary by CNI: some can be configured to reject instead of drop.

**Q5.2** DNS falls back to TCP when a response is truncated (TC bit), which happens with large answers such as headless Services with many endpoints or DNSSEC-sized records. Some clients and CoreDNS paths also use TCP on their own. With only UDP allowed, these lookups time out intermittently, which is hard to diagnose.

**Q5.3** In one element, the two selectors are **ANDed**: pods labeled `k8s-app=kube-dns` *that are in* `kube-system`. In two elements they are **ORed**: *any* pod in `kube-system`, **or** any pod labeled `k8s-app=kube-dns` in the policy's own namespace (`lab-net`). The ORed version is broader than intended and is a common source of overly permissive policies. See https://kubernetes.io/docs/concepts/services-networking/network-policies/.

**Q5.4** Policy is evaluated on packets **after** the ClusterIP has been DNAT'd to the pod's IP and **target port**. What the dataplane checks is `10.244.x.y:8080`, not `10.96.143.21:80`. A NetworkPolicy never sees Service ports; it always matches pod ports. The same applies to the DNS policy, which works because CoreDNS pods listen on 53.

**Q5.5** NetworkPolicies are **additive (a union of allows)**. Once a pod is selected by any policy for a direction, only traffic allowed by *at least one* of those policies passes. No standard `networking.k8s.io/v1` NetworkPolicy can deny something another policy allows; there are no deny rules. Explicit deny and priority need CNI-specific CRDs or the AdminNetworkPolicy API from SIG Network.

</details>

<details>
<summary><strong>Exercise 6</strong></summary>

**Q6.1**
1. **Egress deny on the client.** `nslookup backend` from the client **timed out**, even though a direct `dig @<corednsPodIP>` from another pod (for example `client-ndots`, which is also labeled `app=client` and therefore also affected, so use a pod without that label, or read `kubectl -n lab-net get networkpolicy`) showed CoreDNS was healthy. The command that exposed it was `kubectl -n lab-net get networkpolicy`, which showed `default-deny-egress` alone, with no allow policies.
2. **Selector no longer matching.** Once DNS was fixed, `curl http://backend` failed instantly. `kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend` came back empty, and `kubectl -n lab-net get pods --show-labels` showed `app=backend-old`.

**Q6.2** The ReplicaSet selector is `app=backend`. Once the labels changed, the existing pods were **orphaned**: they no longer match, so the controller released them. The ReplicaSet then counted 0 of 2 replicas and **created two new pods** labeled `app=backend`. Depending on timing, by the time you look at endpoints the new pods may already be Ready and the Service may already have healthy endpoints again. This is exactly why you must verify each layer instead of assuming the "obvious" fault is still present.

**Q6.3** Minimal fix:

```bash
kubectl apply -f np-allow-dns.yaml -f np-allow-backend.yaml
kubectl -n lab-net get endpointslices -l kubernetes.io/service-name=backend
kubectl -n lab-net exec client -- curl -s --max-time 3 http://backend/hostname; echo
```

Then remove the orphans:

```bash
kubectl -n lab-net delete pods -l app=backend-old
```

The orphaned `app=backend-old` pods are unmanaged. No controller will reschedule, update or remove them. They use resources, they keep running the old image, and a future Service or NetworkPolicy that happens to select `app=backend-old` would silently send traffic to them. Leaving stray pods around after an incident creates the next incident.

</details>