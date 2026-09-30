# Guided Exercises — CKNE 2.4: Troubleshooting Service Network Traffic

These labs have you break a working Service in the ways it most often breaks in production, then trace each fault down the stack: DNS → ClusterIP → EndpointSlice → kube-proxy data plane → Pod → NetworkPolicy → node-level traffic policy.

**Official sources used:**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Service concepts: https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and Service Proxies (kube-proxy modes): https://kubernetes.io/docs/reference/networking/virtual-ips/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Preserving the client source IP (`externalTrafficPolicy`): https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip
- kind quick start: https://kind.sigs.k8s.io/docs/user/quick-start/

> **Note:** Pod IPs, ClusterIPs, NodePorts, and random suffixes (`hostnames-7c9f8d6b5-xk2lp`, `KUBE-SVC-…`) will differ in your cluster. Outputs marked "similar to" show the shape you should see, not exact values.

---

## Exercise 0 — Lab setup

### Steps

1. Create a three-node kind cluster. You need several nodes for Exercise 8. Save this as `kind-svc-lab.yaml`:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: svc-lab
   nodes:
   - role: control-plane
   - role: worker
   - role: worker
   ```

   ```bash
   kind create cluster --config kind-svc-lab.yaml
   kubectl get nodes -o wide
   ```

   Expected output (similar to):

   ```
   NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP
   svc-lab-control-plane   Ready    control-plane   60s   v1.3x.x   172.18.0.4
   svc-lab-worker          Ready    <none>          40s   v1.3x.x   172.18.0.2
   svc-lab-worker2         Ready    <none>          40s   v1.3x.x   172.18.0.3
   ```

2. Create the namespace, the backend, the Service, and a client Pod. Save this as `svc-lab.yaml`:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: svc-lab
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: hostnames
     namespace: svc-lab
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: hostnames
     template:
       metadata:
         labels:
           app: hostnames
       spec:
         containers:
         - name: hostnames
           image: registry.k8s.io/serve_hostname
           ports:
           - name: http
             containerPort: 9376
             protocol: TCP
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: hostnames
     namespace: svc-lab
   spec:
     selector:
       app: hostnames
     ports:
     - name: http
       protocol: TCP
       port: 80
       targetPort: 9376
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: client
     namespace: svc-lab
   spec:
     containers:
     - name: netshoot
       image: nicolaka/netshoot:v0.13
       command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f svc-lab.yaml
   kubectl -n svc-lab rollout status deploy/hostnames
   kubectl -n svc-lab wait --for=condition=Ready pod/client --timeout=120s
   ```

3. Define a shortcut for running commands from the client:

   ```bash
   alias kc='kubectl -n svc-lab exec client --'
   ```

### Questions — Exercise 0

- **Q0.1** The `serve_hostname` container listens on 9376, but clients use port 80. Which Service field makes that mapping, and which component actually rewrites the packet?
- **Q0.2** Why use a dedicated client Pod (netshoot) instead of running `curl` from your workstation?

---

## Exercise 1 — The baseline: walk the path while it works

You can't recognise a broken path until you know what a healthy one looks like. Record every value you see here, because the later exercises compare against it.

### Steps

1. **DNS.** Resolve the Service name from the client:

   ```bash
   kc nslookup hostnames
   ```

   Expected output (similar to):

   ```
   Server:         10.96.0.10
   Address:        10.96.0.10#53

   Name:   hostnames.svc-lab.svc.cluster.local
   Address: 10.96.211.47
   ```

2. **ClusterIP.** Compare that IP with the Service object:

   ```bash
   kubectl -n svc-lab get svc hostnames
   ```

   ```
   NAME        TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
   hostnames   ClusterIP   10.96.211.47   <none>        80/TCP    2m
   ```

3. **Load balancing.** Call the Service several times:

   ```bash
   for i in $(seq 1 6); do kc curl -s --max-time 2 http://hostnames; echo; done
   ```

   Expected output: the names of the backend Pods, in no fixed order:

   ```
   hostnames-7c9f8d6b5-xk2lp
   hostnames-7c9f8d6b5-9qwrt
   hostnames-7c9f8d6b5-xk2lp
   hostnames-7c9f8d6b5-mb4zd
   ...
   ```

4. **EndpointSlices.** Check what the control plane published as the Service backends:

   ```bash
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames
   kubectl -n svc-lab get pods -l app=hostnames -o wide
   ```

   ```
   NAME              ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
   hostnames-8xq7v   IPv4          9376    10.244.1.3,10.244.2.2,10.244.2.3   2m
   ```

5. **Bypass the Service.** Call one Pod directly on its IP and container port:

   ```bash
   POD_IP=$(kubectl -n svc-lab get pods -l app=hostnames -o jsonpath='{.items[0].status.podIP}')
   kc curl -s --max-time 2 http://$POD_IP:9376; echo
   ```

6. **ICMP to the ClusterIP.**

   ```bash
   kc ping -c 2 -W 2 10.96.211.47   # use your ClusterIP
   ```

### Questions — Exercise 1

- **Q1.1** Which *search domain* completed the short name `hostnames` to its FQDN? Where did the client get that list?
- **Q1.2** Step 4 shows port `9376`, not `80`. Why does the EndpointSlice store the target port and not the Service port?
- **Q1.3** Step 5 works but step 3 fails. Which layers have you just ruled out, and which ones remain suspect?
- **Q1.4** Why does `ping` to a ClusterIP usually fail (in iptables/nftables mode) even though HTTP works?

---

## Exercise 2 — Fault: the selector matches no Pods

### Steps

1. Break the selector. The typo is deliberate:

   ```bash
   kubectl -n svc-lab patch svc hostnames --type=merge -p '{"spec":{"selector":{"app":"hostname"}}}'
   ```

2. Reproduce the symptom:

   ```bash
   kc curl -sS --max-time 3 http://hostnames
   ```

   Expected output:

   ```
   curl: (7) Failed to connect to hostnames port 80 after 1 ms: Couldn't connect to server
   ```

3. Walk the ladder from Exercise 1. DNS and the ClusterIP still exist:

   ```bash
   kc nslookup hostnames
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames
   ```

   ```
   NAME              ADDRESSTYPE   PORTS     ENDPOINTS   AGE
   hostnames-8xq7v   IPv4          <unset>   <unset>     6m
   ```

4. Compare the selector with the real labels:

   ```bash
   kubectl -n svc-lab get svc hostnames -o jsonpath='{.spec.selector}'; echo
   kubectl -n svc-lab get pods --show-labels
   kubectl -n svc-lab get pods -l app=hostname      # the Service's selector, as a query
   ```

5. See how kube-proxy programmed the node for a Service with no backends:

   ```bash
   docker exec svc-lab-worker iptables-save -t filter | grep 'svc-lab/hostnames'
   ```

   Expected output (similar to):

   ```
   -A KUBE-SERVICES -d 10.96.211.47/32 -p tcp -m comment --comment "svc-lab/hostnames:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
   ```

6. Repair it:

   ```bash
   kubectl -n svc-lab patch svc hostnames --type=merge -p '{"spec":{"selector":{"app":"hostnames"}}}'
   kc curl -s --max-time 2 http://hostnames; echo
   ```

### Questions — Exercise 2

- **Q2.1** Name the fastest single command that tells you "the Service has no backends".
- **Q2.2** Why does the client get an immediate *connection refused* instead of a timeout?
- **Q2.3** DNS kept resolving during the fault. What does that tell you about where CoreDNS gets its data for a ClusterIP Service?
- **Q2.4** When does a Service with an empty EndpointSlice *not* mean something is broken?

---

## Exercise 3 — Fault: wrong `targetPort`

### Steps

1. Point the Service at a port nothing listens on:

   ```bash
   kubectl -n svc-lab patch svc hostnames --type=json \
     -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
   ```

2. Reproduce the symptom:

   ```bash
   kc curl -sS --max-time 3 http://hostnames
   ```

   ```
   curl: (7) Failed to connect to hostnames port 80 after 2 ms: Couldn't connect to server
   ```

3. This time the EndpointSlice is **not** empty:

   ```bash
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames
   ```

   ```
   NAME              ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
   hostnames-8xq7v   IPv4          8080    10.244.1.3,10.244.2.2,10.244.2.3   9m
   ```

4. Test the Pod on each port:

   ```bash
   kc curl -sS --max-time 2 http://$POD_IP:8080
   kc curl -s  --max-time 2 http://$POD_IP:9376; echo
   ```

5. Check which port the Pod declares:

   ```bash
   kubectl -n svc-lab get deploy hostnames \
     -o jsonpath='{.spec.template.spec.containers[0].ports}'; echo
   ```

6. Repair it with the **named port**, which is sturdier than a number:

   ```bash
   kubectl -n svc-lab patch svc hostnames --type=json \
     -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":"http"}]'
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames
   kc curl -s --max-time 2 http://hostnames; echo
   ```

### Questions — Exercise 3

- **Q3.1** The symptom looks exactly like Exercise 2. Which single observation tells the two faults apart?
- **Q3.2** In this fault, where exactly is the TCP RST generated: in kube-proxy, on the node, or in the Pod's network namespace?
- **Q3.3** Why is `targetPort: http` sturdier than `targetPort: 9376` when the application changes port in a new version?
- **Q3.4** `declared ports` in `containerPort` do not control what the process listens on. Then what is the `containerPort` field actually for?

---

## Exercise 4 — Fault: Pods that aren't Ready

### Steps

1. Add a readiness probe that always fails (port 9999):

   ```bash
   kubectl -n svc-lab patch deploy hostnames --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":{"httpGet":{"path":"/","port":9999},"periodSeconds":2,"failureThreshold":1}}]'
   ```

2. Watch the rollout:

   ```bash
   kubectl -n svc-lab rollout status deploy/hostnames --timeout=30s
   kubectl -n svc-lab get pods -l app=hostnames
   ```

   Expected output (similar to):

   ```
   Waiting for deployment "hostnames" rollout to finish: 1 out of 3 new replicas have been updated...
   error: timed out waiting for the condition

   NAME                         READY   STATUS    RESTARTS   AGE
   hostnames-5d8b7f9c4-qh7tn    0/1     Running   0          35s
   hostnames-7c9f8d6b5-9qwrt    1/1     Running   0          14m
   hostnames-7c9f8d6b5-mb4zd    1/1     Running   0          14m
   hostnames-7c9f8d6b5-xk2lp    1/1     Running   0          14m
   ```

3. Inspect the endpoint **conditions**, not just the addresses:

   ```bash
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"  ready="}{.conditions.ready}{"  serving="}{.conditions.serving}{"  pod="}{.targetRef.name}{"\n"}{end}'
   ```

   ```
   10.244.1.3  ready=true  serving=true  pod=hostnames-7c9f8d6b5-xk2lp
   10.244.2.2  ready=true  serving=true  pod=hostnames-7c9f8d6b5-9qwrt
   10.244.2.3  ready=true  serving=true  pod=hostnames-7c9f8d6b5-mb4zd
   10.244.1.5  ready=false  serving=false  pod=hostnames-5d8b7f9c4-qh7tn
   ```

4. Confirm that traffic never reaches the new Pod:

   ```bash
   for i in $(seq 1 12); do kc curl -s --max-time 2 http://hostnames; echo; done | sort | uniq -c
   ```

5. Find the cause in the events:

   ```bash
   kubectl -n svc-lab describe pod -l app=hostnames | grep -A2 'Readiness probe failed' | head
   ```

   ```
   Warning  Unhealthy  3s (x15 over 33s)  kubelet  Readiness probe failed: Get "http://10.244.1.5:9999/": dial tcp 10.244.1.5:9999: connect: connection refused
   ```

6. Roll back:

   ```bash
   kubectl -n svc-lab rollout undo deploy/hostnames
   kubectl -n svc-lab rollout status deploy/hostnames
   ```

### Questions — Exercise 4

- **Q4.1** Why does the Service keep answering even though the rollout is broken? Which Deployment parameters caused that "safe" behaviour?
- **Q4.2** If the Deployment used `strategy.type: Recreate`, what would the client see, and what would `get endpointslices` show?
- **Q4.3** Which Service field makes kube-proxy and DNS include endpoints that aren't Ready? Give one legitimate use case for it.
- **Q4.4** What does `serving=true, ready=false` mean, and when does it happen?

---

## Exercise 5 — DNS: names, namespaces, and headless Services

### Steps

1. Read the client's resolver configuration:

   ```bash
   kc cat /etc/resolv.conf
   ```

   ```
   search svc-lab.svc.cluster.local svc.cluster.local cluster.local
   nameserver 10.96.0.10
   options ndots:5
   ```

2. Resolve from **another namespace**:

   ```bash
   kubectl run dns-other -n default --image=nicolaka/netshoot:v0.13 --restart=Never --command -- sleep infinity
   kubectl -n default wait --for=condition=Ready pod/dns-other --timeout=120s
   kubectl -n default exec dns-other -- nslookup hostnames
   kubectl -n default exec dns-other -- nslookup hostnames.svc-lab
   ```

   The first query fails (`NXDOMAIN` / `can't find hostnames`). The second one resolves.

3. Watch how search domains expand a name with fewer than 5 dots:

   ```bash
   kc dig +search +noall +answer +stats hostnames.svc-lab | tail -n 5
   kc dig +noall +answer hostnames.svc-lab.svc.cluster.local.
   ```

4. Create a **headless** Service over the same Pods:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: hostnames-headless
     namespace: svc-lab
   spec:
     clusterIP: None
     selector:
       app: hostnames
     ports:
     - name: http
       protocol: TCP
       port: 9376
       targetPort: http
   ```

   ```bash
   kubectl apply -f hostnames-headless.yaml
   kc dig +short hostnames.svc-lab.svc.cluster.local
   kc dig +short hostnames-headless.svc-lab.svc.cluster.local
   kc dig +short SRV _http._tcp.hostnames.svc-lab.svc.cluster.local
   ```

   Expected output (similar to):

   ```
   10.96.211.47

   10.244.1.3
   10.244.2.2
   10.244.2.3

   0 100 80 hostnames.svc-lab.svc.cluster.local.
   ```

5. If DNS itself fails, check CoreDNS (the procedure from the DNS debugging page):

   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
   kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
   kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20
   kc dig @10.96.0.10 kubernetes.default.svc.cluster.local +short
   ```

### Questions — Exercise 5

- **Q5.1** With `ndots:5`, how many queries can `curl http://api.example.com` generate before it reaches the real domain? What's the production impact, and how do you mitigate it?
- **Q5.2** The headless Service returned Pod IPs. Which component load-balances in that case?
- **Q5.3** In step 5, why is it worth checking the EndpointSlices of the `kube-dns` **Service** and not just whether the CoreDNS Pods are `Running`?
- **Q5.4** A client in another namespace uses `http://hostnames` and gets NXDOMAIN. Is that a network fault? What's the fix?

---

## Exercise 6 — The data plane: kube-proxy, iptables, and conntrack

### Steps

1. Find out which mode kube-proxy is running in:

   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
   docker exec svc-lab-worker curl -s http://localhost:10249/proxyMode; echo
   kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
   ```

   Expected output: `iptables`. The ConfigMap may show `mode: iptables` or `mode: ""`, which means the platform default.

2. Follow the Service through the NAT chains:

   ```bash
   docker exec svc-lab-worker iptables-save -t nat | grep 'svc-lab/hostnames:http'
   ```

   Expected output (similar to):

   ```
   -A KUBE-SERVICES -d 10.96.211.47/32 -p tcp -m comment --comment "svc-lab/hostnames:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-4WJ3Q5ZKOQ2XHVRS
   -A KUBE-SVC-4WJ3Q5ZKOQ2XHVRS ! -s 10.244.0.0/16 -d 10.96.211.47/32 -p tcp -m comment --comment "svc-lab/hostnames:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
   -A KUBE-SVC-4WJ3Q5ZKOQ2XHVRS -m comment --comment "svc-lab/hostnames:http -> 10.244.1.3:9376" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-AAAAAAAAAAAAAAAA
   -A KUBE-SVC-4WJ3Q5ZKOQ2XHVRS -m comment --comment "svc-lab/hostnames:http -> 10.244.2.2:9376" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-BBBBBBBBBBBBBBBB
   -A KUBE-SVC-4WJ3Q5ZKOQ2XHVRS -m comment --comment "svc-lab/hostnames:http -> 10.244.2.3:9376" -j KUBE-SEP-CCCCCCCCCCCCCCCC
   -A KUBE-SEP-AAAAAAAAAAAAAAAA -s 10.244.1.3/32 -m comment --comment "svc-lab/hostnames:http" -j KUBE-MARK-MASQ
   -A KUBE-SEP-AAAAAAAAAAAAAAAA -p tcp -m comment --comment "svc-lab/hostnames:http" -m tcp -j DNAT --to-destination 10.244.1.3:9376
   ```

3. Check that **every** node has the same rules:

   ```bash
   for n in svc-lab-control-plane svc-lab-worker svc-lab-worker2; do
     echo "== $n"; docker exec $n iptables-save -t nat | grep -c 'svc-lab/hostnames:http ->'
   done
   ```

4. Look at the connection tracking table while traffic flows:

   ```bash
   kc sh -c 'for i in $(seq 1 5); do curl -s -o /dev/null http://hostnames; done'
   CLIENT_NODE=$(kubectl -n svc-lab get pod client -o jsonpath='{.spec.nodeName}')
   docker exec $CLIENT_NODE conntrack -L -p tcp -d 10.96.211.47 2>/dev/null | head -n 3
   ```

   Expected output (similar to):

   ```
   tcp  6 118 TIME_WAIT src=10.244.2.4 dst=10.96.211.47 sport=41822 dport=80 src=10.244.1.3 dst=10.244.2.4 sport=9376 dport=41822 [ASSURED] mark=0 use=1
   ```

5. If a node is missing rules or they're out of date, check kube-proxy on that node:

   ```bash
   kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=20 --prefix
   ```

6. (Optional, if your cluster uses nftables mode) The equivalent is:

   ```bash
   nft list table ip kube-proxy | grep 'svc-lab/hostnames'
   ```

### Questions — Exercise 6

- **Q6.1** Explain the probabilities `0.333…`, `0.5`, and "no probability". Why do they produce an even 1/3 split?
- **Q6.2** In the conntrack entry, what does the second tuple (`src=10.244.1.3 … sport=9376`) show, and why does it prove DNAT happened?
- **Q6.3** Why does the `KUBE-MARK-MASQ` rule in `KUBE-SVC-…` apply only to traffic with `! -s 10.244.0.0/16`?
- **Q6.4** A Service works from Pods on `worker` but not from Pods on `worker2`. The EndpointSlice is correct. What do you check first, and why does the fault affect only one node?
- **Q6.5** You deleted a backend Pod and some long-lived connections still hang. Which data-plane component explains that?

---

## Exercise 7 — NetworkPolicy: timeout versus refused

> Requires a CNI that enforces NetworkPolicy. Recent kind versions (kindnet with network policy support) enforce it. With a CNI that doesn't, step 3 will keep working, and that is the first lesson: **a NetworkPolicy the CNI doesn't implement is silently ignored.**

### Steps

1. Apply a default-deny for ingress to the backend Pods, plus an allow for labelled clients:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: hostnames-ingress
     namespace: svc-lab
   spec:
     podSelector:
       matchLabels:
         app: hostnames
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             role: client
       ports:
       - protocol: TCP
         port: 9376
   ```

   ```bash
   kubectl apply -f hostnames-netpol.yaml
   ```

2. Measure the symptom, and time it:

   ```bash
   kc sh -c 'time curl -sS --max-time 5 http://hostnames'
   ```

   Expected output:

   ```
   curl: (28) Connection timed out after 5002 milliseconds
   real    0m 5.00s
   ```

3. Confirm that the Service and the endpoints are healthy, so the fault is somewhere else:

   ```bash
   kubectl -n svc-lab get endpointslices -l kubernetes.io/service-name=hostnames
   kubectl -n svc-lab get networkpolicy
   kubectl -n svc-lab describe networkpolicy hostnames-ingress
   ```

4. Fix it by labelling the client, not by weakening the policy:

   ```bash
   kubectl -n svc-lab label pod client role=client
   kc curl -s --max-time 3 http://hostnames; echo
   ```

5. Check that the other namespace is still blocked:

   ```bash
   kubectl -n default exec dns-other -- curl -sS --max-time 3 http://hostnames.svc-lab
   ```

### Questions — Exercise 7

- **Q7.1** Why does a NetworkPolicy produce a *timeout* while Exercises 2 and 3 produced *connection refused*? What does that tell you when triaging?
- **Q7.2** The policy allows port `9376`, not `80`. Why is that correct?
- **Q7.3** Step 5 fails even if you label `dns-other` with `role=client`. Why? How would you allow it?
- **Q7.4** If you added `policyTypes: [Egress]` with no rules to a policy selecting the client, what would break first, even before HTTP?

---

## Exercise 8 — NodePort and `externalTrafficPolicy: Local`

### Steps

1. Create a NodePort Service with `Local` policy, and reduce the backend to one replica:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: hostnames-ext
     namespace: svc-lab
   spec:
     type: NodePort
     externalTrafficPolicy: Local
     selector:
       app: hostnames
     ports:
     - name: http
       protocol: TCP
       port: 80
       targetPort: http
       nodePort: 30080
   ```

   ```bash
   kubectl -n svc-lab delete networkpolicy hostnames-ingress
   kubectl apply -f hostnames-ext.yaml
   kubectl -n svc-lab scale deploy hostnames --replicas=1
   kubectl -n svc-lab rollout status deploy/hostnames
   kubectl -n svc-lab get pods -l app=hostnames -o wide
   kubectl -n svc-lab get svc hostnames-ext -o jsonpath='{.spec.healthCheckNodePort}'; echo
   ```

2. Call the NodePort **from outside the cluster** (a container on the `kind` Docker network) on each node:

   ```bash
   for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
     echo "== $ip"
     docker run --rm --network kind nicolaka/netshoot:v0.13 curl -sS --max-time 3 http://$ip:30080
     echo
   done
   ```

   Only the node hosting the Pod answers. The others end in `curl: (28) … timed out`.

3. Query the health endpoint an external load balancer would use:

   ```bash
   HC=$(kubectl -n svc-lab get svc hostnames-ext -o jsonpath='{.spec.healthCheckNodePort}')
   for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
     echo "== $ip"
     docker run --rm --network kind nicolaka/netshoot:v0.13 curl -s -w ' HTTP %{http_code}\n' http://$ip:$HC/healthz
   done
   ```

   Expected output (similar to):

   ```
   == 172.18.0.2
   {"service":{"namespace":"svc-lab","name":"hostnames-ext"},"localEndpoints":1,"serviceProxyHealthy":true} HTTP 200
   == 172.18.0.3
   {"service":{"namespace":"svc-lab","name":"hostnames-ext"},"localEndpoints":0,"serviceProxyHealthy":true} HTTP 503
   ```

4. Switch to `Cluster` and repeat step 2:

   ```bash
   kubectl -n svc-lab patch svc hostnames-ext --type=merge -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
   ```

   Now every node answers.

### Questions — Exercise 8

- **Q8.1** What is the trade-off between `Local` and `Cluster`? Mention the client source IP and the extra hop.
- **Q8.2** With `Local`, the NodePort "fails" on two of the three nodes. Is that a bug? What keeps a real cloud LoadBalancer from sending traffic to those nodes?
- **Q8.3** Why run the test with `docker run --network kind` instead of `curl` from inside a node or a Pod?
- **Q8.4** How is `internalTrafficPolicy: Local` different, and what symptom would it cause for a Pod on a node with no local backend?

---

## Cleanup

```bash
kubectl -n default delete pod dns-other
kind delete cluster --name svc-lab
```

---

## Summary: symptom → first check

| Symptom at the client | Most likely cause | First command |
|---|---|---|
| `NXDOMAIN` / `can't find` | Wrong name or namespace, CoreDNS down | `cat /etc/resolv.conf`, `nslookup <svc>.<ns>` |
| Immediate `Connection refused`, empty EndpointSlice | Selector doesn't match / no Pod is Ready | `get endpointslices -l kubernetes.io/service-name=<svc>` |
| Immediate `Connection refused`, EndpointSlice has endpoints | Wrong `targetPort` / process not listening | `curl <podIP>:<port>` directly |
| Some backends never receive traffic | `ready=false` on those endpoints | EndpointSlice conditions + `describe pod` |
| Timeout | NetworkPolicy, routing between nodes, `externalTrafficPolicy: Local` | `get networkpolicy`, test Pod to Pod |
| Works from some nodes only | kube-proxy / stale rules on that node | `iptables-save` / `nft list` per node, kube-proxy logs |

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

- **Q0.1** `spec.ports[].targetPort` maps port 80 to 9376. No Service process rewrites the packet. kube-proxy only *programs* the rules; the node's kernel (netfilter DNAT in iptables/nftables mode, or IPVS) rewrites the destination.
- **Q0.2** A ClusterIP is only reachable from inside the cluster network. Testing from a Pod also runs through the same path a real client uses: Pod DNS (`resolv.conf` with search domains), the node's kube-proxy rules, and the NetworkPolicy enforced by the CNI. From your workstation you'd be testing something else.

### Exercise 1

- **Q1.1** `svc-lab.svc.cluster.local`, the first entry in `search`. The kubelet generates `/etc/resolv.conf` for each Pod (with the default `dnsPolicy: ClusterFirst`): the Pod's namespace, `svc.cluster.local`, `cluster.local`, plus the CoreDNS Service IP as `nameserver`.
- **Q1.2** The EndpointSlice describes where traffic actually goes (Pod IP and container port). The Service port (80) exists only on the ClusterIP. kube-proxy combines the two: it matches `ClusterIP:80` and DNATs to `podIP:9376`.
- **Q1.3** It rules out the Pod, the application, and Pod-to-Pod routing between nodes (if the Pod is on another node). What remains suspect is whatever is Service-specific: DNS, the selector/EndpointSlice, `port`/`targetPort`, and the kube-proxy rules. The official debug-service guide uses exactly this ladder.
- **Q1.4** In iptables/nftables mode, the ClusterIP isn't assigned to any interface. It only exists as a match in rules that are specific to protocol and port (TCP/80). An ICMP echo matches no rule and nobody answers it. (In IPVS mode the IP is bound to `kube-ipvs0` and may answer ping.) So ping is not a valid test for a Service.

### Exercise 2

- **Q2.1** `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` (with `-n`): `ENDPOINTS <unset>`.
- **Q2.2** kube-proxy installs a `REJECT --reject-with icmp-port-unreachable` rule for Services with no endpoints. The client's kernel turns that ICMP into `ECONNREFUSED` straight away. Failing fast is on purpose: it's better than making the client wait for a timeout.
- **Q2.3** CoreDNS (the `kubernetes` plugin) answers from the **Service** object for the ClusterIP record. The A record exists whether or not there are endpoints. Resolving DNS proves nothing about backends. (Headless Services are different: their records *do* come from the endpoints.)
- **Q2.4** When the Service has no `selector` on purpose (endpoints managed by hand or by another controller, e.g. an external database) and nobody has created the EndpointSlices yet. Also when the backend is legitimately scaled to 0. The same applies to `type: ExternalName`, which has no endpoints at all.

### Exercise 3

- **Q3.1** The EndpointSlice: in Exercise 2 it is empty; in Exercise 3 it has endpoints but with port 8080. Direct `curl` to `podIP:9376` confirms that the application is fine.
- **Q3.2** In the Pod's network namespace. The DNAT goes through (kube-proxy did its job). The SYN reaches `10.244.x.x:8080`, and the Pod's kernel, with no socket listening, replies with a RST. Neither kube-proxy nor the node rejects it.
- **Q3.3** With a named port, the EndpointSlice controller resolves the number *per Pod* from `containerPort`. During a rollout where v1 listens on 9376 and v2 on 8080 (both named `http`), each endpoint publishes its correct port. A fixed number would break half the endpoints during the transition.
- **Q3.4** It's mostly informational (the process listens where it wants to). What it does provide: named-port resolution for `targetPort`, `hostPort`, and readable documentation. Leaving a port out does not block traffic to it.

### Exercise 4

- **Q4.1** With 3 replicas, the default `RollingUpdate` values (`maxUnavailable: 25%` → 0 after rounding, `maxSurge: 25%` → 1) create one new Pod and wait for it to be Ready before removing an old one. It never becomes Ready, so the rollout stalls with the 3 old Pods intact. The EndpointSlice lists the new Pod with `ready=false`, and kube-proxy leaves it out.
- **Q4.2** `Recreate` deletes all the old Pods first. Every new endpoint would show `ready=false`. kube-proxy would treat the Service as having no *usable* endpoints and reject: the client would see an immediate `Connection refused`, with addresses in the slice but none of them ready. It's a total outage.
- **Q4.3** `spec.publishNotReadyAddresses: true`. A typical case is a headless Service for a StatefulSet (etcd, Cassandra, and similar) where peers must find each other through DNS *before* they are Ready, so they can form the cluster.
- **Q4.4** The endpoint is terminating (`terminating=true`) but still passes its readiness probe. `ready` is always false while terminating, and `serving` reflects the probe. kube-proxy uses `serving` endpoints as a fallback when there are no ready ones (for example with `externalTrafficPolicy: Local` during a drain), to avoid dropping traffic.

### Exercise 5

- **Q5.1** `api.example.com` has 2 dots (< 5), so the resolver tries the search domains first: `api.example.com.svc-lab.svc.cluster.local`, `.svc.cluster.local`, `.cluster.local` (and the host's own domains, if any), before trying the absolute name. That's 3 or more NXDOMAINs per lookup, often doubled for A and AAAA, which means more load on CoreDNS and more latency. Mitigations: use FQDNs with a trailing dot (`api.example.com.`), lower `ndots` through `dnsConfig.options`, or use NodeLocal DNSCache.
- **Q5.2** None in Kubernetes. DNS returns every IP, and the client (its resolver or library) picks one. kube-proxy doesn't take part, because there is no ClusterIP.
- **Q5.3** Pods can be `Running` but not Ready, or the `kube-dns` Service can be missing endpoints (a wrong selector, for example). In that case the `nameserver 10.96.0.10` in every Pod leads nowhere: it's the same fault as Exercise 2, just applied to DNS.
- **Q5.4** No, it's resolution scope. The search domain `default.svc.cluster.local` puts the name in the client's namespace. Use `hostnames.svc-lab` or the FQDN `hostnames.svc-lab.svc.cluster.local`.

### Exercise 6

- **Q6.1** The rules are evaluated in order. The first one takes 1/3. Of the remaining 2/3, the second one takes 1/2 (= 1/3 of the total). The last one takes everything left over (1/3). With n endpoints, rule i has probability 1/(n−i+1).
- **Q6.2** It's the expected reply tuple: the answer comes *from* the Pod (`10.244.1.3:9376`), not from the ClusterIP. conntrack records the translation and reverses it on the replies, so the client sees responses from `10.96.211.47:80`. The difference between the original destination and the reply source is the DNAT.
- **Q6.3** Traffic from outside the Pod CIDR (a node, a hostNetwork process, an external client) is masqueraded (SNAT to the node IP). Otherwise the reply would go straight back from the Pod to the original source without passing through the node that did the DNAT, and the client would get a reply from an IP it never contacted. Pod traffic is routed back correctly already and keeps its source IP.
- **Q6.4** kube-proxy on `worker2`: is it running, what do its logs say (API errors, sync failures), and are the rules there (`iptables-save | grep`)? Each node's data plane is programmed locally by its own kube-proxy, so a stale or dead kube-proxy only affects clients whose traffic is DNATed on that node.
- **Q6.5** conntrack. Established connections keep their existing DNAT entry after the rules change. kube-proxy clears conntrack entries for removed endpoints (especially for UDP), but a TCP connection to a Pod that no longer exists will only fail on timeout or retransmission. That's why graceful termination (`preStop`, `terminationGracePeriodSeconds`) matters.

### Exercise 7

- **Q7.1** The policy *drops* the SYN silently, so nothing replies and the client retransmits until it times out. Exercises 2 and 3 produced an active reply (ICMP unreachable or RST). As a rule of thumb: **refused → the path exists but the destination is missing or rejects (endpoints, port); timeout → something drops packets (policy, routing, firewall, `Local` with no local backend)**.
- **Q7.2** NetworkPolicy is evaluated against the packet as it arrives at the Pod, after the Service DNAT. At that point the destination port is 9376, the container port. Port 80 only exists on the ClusterIP.
- **Q7.3** A `podSelector` with no `namespaceSelector` only selects Pods in the **same namespace** as the policy. To allow it, combine the two in the same `from` element: `namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: default}}` together with `podSelector: {matchLabels: {role: client}}`.
- **Q7.4** DNS. An egress default-deny also blocks UDP/TCP 53 to CoreDNS, so `curl http://hostnames` fails at resolution before it opens any connection. Any egress policy must explicitly allow DNS to the `kube-dns` Pods in `kube-system`.

### Exercise 8

- **Q8.1** `Local`: keeps the real client source IP (no SNAT) and avoids an extra hop between nodes, but only nodes with a local endpoint answer, and load can be uneven (spread by node, not by Pod). `Cluster`: every node answers and load is even, but traffic is SNATed (the backend sees a node IP) and may cross to another node.
- **Q8.2** No, it's the documented behaviour: nodes without a local endpoint drop the traffic. A cloud LoadBalancer polls `healthCheckNodePort` (`/healthz`). Nodes that return 503 (`localEndpoints: 0`) are taken out of the pool, so real traffic only reaches nodes that return 200.
- **Q8.3** kube-proxy treats traffic that starts on the node itself, or (depending on local-traffic detection) from cluster Pods, with `Cluster` semantics, to avoid needless blackholes. That hides exactly the behaviour you want to see. A container on the `kind` Docker network is a genuinely external client.
- **Q8.4** `internalTrafficPolicy: Local` applies to traffic to the ClusterIP from inside the cluster: each node only sends to its own local endpoints. A Pod on a node with no local backend has its traffic dropped (usually a timeout), even though the Service does have endpoints on other nodes. It's used for node agents (DaemonSets) where only local traffic makes sense.

</details>