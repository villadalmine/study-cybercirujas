# Guided Exercises — Topic 2.3: Customizing CoreDNS for Services

**Certification:** CKNE · **Exam weight:** 4.17%

**Official references**

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Customizing DNS Service: https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- CoreDNS plugins: https://coredns.io/plugins/kubernetes/, https://coredns.io/plugins/forward/, https://coredns.io/plugins/hosts/, https://coredns.io/plugins/rewrite/, https://coredns.io/plugins/reload/, https://coredns.io/plugins/log/, https://coredns.io/plugins/loop/, https://coredns.io/plugins/file/
- CoreDNS plugin execution order (`plugin.cfg`): https://github.com/coredns/coredns/blob/master/plugin.cfg

## Prerequisites

- A disposable kubeadm-style cluster (kind, kubeadm, or similar) with CoreDNS running in `kube-system`. You will edit cluster-wide DNS, so **do not do these exercises on a shared cluster**.
- `kubectl` with cluster-admin rights.
- Managed offerings differ. GKE may run `kube-dns` instead of CoreDNS, and AKS expects customizations in a separate `coredns-custom` ConfigMap. The exercises assume the upstream/kubeadm layout.

---

## Exercise 1 — Anatomy of cluster DNS

**1.** Back up the current Corefile before you touch anything. You will restore from this file at the end.

```bash
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > Corefile.orig
kubectl -n kube-system get configmap coredns -o yaml > coredns-cm-backup.yaml
cat Corefile.orig
```

On a recent kubeadm cluster the output looks similar to this (details vary by version; older releases have a plain `cache 30`):

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
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

**2.** Identify the objects that make up the DNS service:

```bash
kubectl -n kube-system get deployment,pods,service,configmap -l k8s-app=kube-dns
kubectl -n kube-system get configmap coredns
kubectl -n kube-system get service kube-dns -o wide
```

Expected output (abridged):

```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/coredns   2/2     2            2           12d

NAME                           READY   STATUS    RESTARTS   AGE
pod/coredns-7db6d8ff4d-9xk2p   1/1     Running   0          12d
pod/coredns-7db6d8ff4d-t7mzq   1/1     Running   0          12d

NAME               TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
service/kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   12d
```

**3.** Check how the Corefile gets into the container, and which IP the kubelet gives to pods:

```bash
kubectl -n kube-system get deployment coredns \
  -o jsonpath='{.spec.template.spec.volumes}{"\n"}{.spec.template.spec.containers[0].args}{"\n"}'
kubectl -n kube-system get configmap kubelet-config -o yaml | grep -A2 clusterDNS
```

```
[{"configMap":{"defaultMode":420,"items":[{"key":"Corefile","path":"Corefile"}],"name":"coredns"},"name":"config-volume"}]
["-conf","/etc/coredns/Corefile"]
    clusterDNS:
    - 10.96.0.10
```

**Questions**

- **Q1.1** The Deployment is called `coredns`, but the Service is called `kube-dns`. Why, and which of the two names do pods actually depend on?
- **Q1.2** Which plugin applies ConfigMap edits without a pod restart? Roughly how long can it take for an edit to become active?
- **Q1.3** What does `fallthrough in-addr.arpa ip6.arpa` do inside the `kubernetes` block?
- **Q1.4** The volume uses `items: [{key: Corefile, path: Corefile}]`. What happens if you add a second key (for example a zone file) to the `coredns` ConfigMap and reference it from the Corefile?

---

## Exercise 2 — Baseline: what the `kubernetes` plugin answers

**1.** Deploy a debugging pod and a sample workload that has both a ClusterIP Service and a headless Service:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dnsutils
  namespace: default
spec:
  containers:
    - name: dnsutils
      image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
      command: ["sleep", "infinity"]
  restartPolicy: Always
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: default
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
  namespace: default
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: web-headless
  namespace: default
spec:
  clusterIP: None
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
```

```bash
kubectl apply -f ex2.yaml
kubectl wait --for=condition=Ready pod/dnsutils --timeout=90s
kubectl rollout status deployment/web
```

**2.** Look at the pod's resolver configuration:

```bash
kubectl exec dnsutils -- cat /etc/resolv.conf
```

```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

**3.** Resolve the same name with `nslookup` and with `dig`:

```bash
kubectl exec dnsutils -- nslookup kubernetes
kubectl exec dnsutils -- dig +short kubernetes
kubectl exec dnsutils -- dig +short +search kubernetes
kubectl exec dnsutils -- dig +short kubernetes.default.svc.cluster.local
```

```
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   kubernetes.default.svc.cluster.local
Address: 10.96.0.1

(empty output from the plain dig)
10.96.0.1
10.96.0.1
```

**4.** Compare the ClusterIP Service, the headless Service, SRV records and pod records:

```bash
kubectl exec dnsutils -- dig +short web.default.svc.cluster.local
kubectl exec dnsutils -- dig +short web-headless.default.svc.cluster.local
kubectl exec dnsutils -- dig +short SRV _http._tcp.web.default.svc.cluster.local
kubectl exec dnsutils -- dig +short SRV _http._tcp.web-headless.default.svc.cluster.local
kubectl get pods -l app=web -o wide
POD_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
kubectl exec dnsutils -- dig +short "${POD_IP//./-}.default.pod.cluster.local"
```

Output will be similar to:

```
10.104.37.212
10.244.1.8
10.244.2.5
0 100 80 web.default.svc.cluster.local.
0 50 80 10-244-1-8.web-headless.default.svc.cluster.local.
0 50 80 10-244-2-5.web-headless.default.svc.cluster.local.
10.244.1.8
```

**Questions**

- **Q2.1** Why does `nslookup kubernetes` succeed while plain `dig +short kubernetes` returns nothing?
- **Q2.2** What is the difference between the A-record answers for `web` and `web-headless`? What does that mean for client-side load balancing?
- **Q2.3** What makes `_http._tcp.web...` resolvable? What would you get if the Service port had no `name`?
- **Q2.4** Which Corefile line makes `10-244-1-8.default.pod.cluster.local` resolve, and why is that option called `insecure`?

---

## Exercise 3 — Query logging, live reload and the cost of `ndots:5`

**1.** In one terminal, follow the CoreDNS logs:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns -f --max-log-requests=5 --prefix
```

**2.** In another terminal, edit the ConfigMap and add `log` on its own line right after `errors` in the `.:53` block:

```bash
kubectl -n kube-system edit configmap coredns
```

```
.:53 {
    errors
    log
    health {
       lameduck 5s
    }
    ...
}
```

**3.** Wait for the reload. Within about one to two minutes, each pod logs something like:

```
[INFO] Reloading
[INFO] plugin/reload: Running configuration SHA512 = 6f1c0e...
[INFO] Reloading complete
```

**4.** Generate queries and read the log lines:

```bash
kubectl exec dnsutils -- nslookup web
kubectl exec dnsutils -- nslookup example.com
```

Log lines use the default format `client:port - id "TYPE CLASS NAME PROTO SIZE DO BUFSIZE" RCODE FLAGS RSIZE DURATION`:

```
[INFO] 10.244.1.7:52301 - 41533 "A IN web.default.svc.cluster.local. udp 47 false 512" NOERROR qr,aa,rd 92 0.000211s
[INFO] 10.244.1.7:40112 - 1201 "A IN example.com.default.svc.cluster.local. udp 55 false 512" NXDOMAIN qr,aa,rd 148 0.000187s
[INFO] 10.244.1.7:40112 - 1202 "A IN example.com.svc.cluster.local. udp 47 false 512" NXDOMAIN qr,aa,rd 140 0.000143s
[INFO] 10.244.1.7:40112 - 1203 "A IN example.com.cluster.local. udp 43 false 512" NXDOMAIN qr,aa,rd 136 0.000139s
[INFO] 10.244.1.7:40112 - 1204 "A IN example.com. udp 29 false 512" NOERROR qr,rd,ra 56 0.012440s
```

(You may also see matching `AAAA` queries.)

**5.** Look at the Prometheus metrics that the `prometheus :9153` line exposes:

```bash
kubectl -n kube-system port-forward svc/kube-dns 9153:9153 &
curl -s localhost:9153/metrics | grep -E '^coredns_dns_responses_total' | head
kill %1
```

```
coredns_dns_responses_total{plugin="kubernetes",rcode="NOERROR",server="dns://:53",...} 57
coredns_dns_responses_total{plugin="kubernetes",rcode="NXDOMAIN",server="dns://:53",...} 212
...
```

**Questions**

- **Q3.1** How many queries did one `nslookup example.com` generate, and why?
- **Q3.2** Name two ways to reduce the number of queries for external names, one on the client side and one on the server side.
- **Q3.3** Why should `log` usually be enabled only temporarily in production?
- **Q3.4** You saved the ConfigMap, but after 20 seconds nothing is in the logs. Is something broken?

---

## Exercise 4 — Stub domain: forward a private zone to another DNS server

You will simulate a corporate DNS server that is authoritative for `corp.internal`, and then make the cluster forward that zone to it.

**1.** Deploy the "corporate" DNS server. It is a second, independent CoreDNS instance serving a zone file:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: corp-dns
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: corp-dns
  namespace: corp-dns
data:
  Corefile: |
    corp.internal:1053 {
        errors
        log
        file /etc/coredns/db.corp.internal
    }
    .:1053 {
        errors
        health :8080
    }
  db.corp.internal: |
    $ORIGIN corp.internal.
    $TTL 300
    @       IN SOA ns1.corp.internal. admin.corp.internal. (
                2026092901 ; serial
                7200       ; refresh
                3600       ; retry
                1209600    ; expire
                300 )      ; minimum
            IN NS  ns1.corp.internal.
    ns1     IN A   10.10.0.2
    db      IN A   10.10.0.50
    ldap    IN A   10.10.0.60
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: corp-dns
  namespace: corp-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: corp-dns
  template:
    metadata:
      labels:
        app: corp-dns
    spec:
      containers:
        - name: coredns
          image: registry.k8s.io/coredns/coredns:v1.11.3
          args: ["-conf", "/etc/coredns/Corefile"]
          ports:
            - name: dns
              containerPort: 1053
              protocol: UDP
            - name: dns-tcp
              containerPort: 1053
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/coredns
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: corp-dns
---
apiVersion: v1
kind: Service
metadata:
  name: corp-dns
  namespace: corp-dns
spec:
  selector:
    app: corp-dns
  ports:
    - name: dns
      port: 53
      targetPort: 1053
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 1053
      protocol: TCP
```

```bash
kubectl apply -f ex4-corp-dns.yaml
kubectl -n corp-dns rollout status deployment/corp-dns
CORP_DNS_IP=$(kubectl -n corp-dns get svc corp-dns -o jsonpath='{.spec.clusterIP}')
echo "$CORP_DNS_IP"
```

**2.** Query it directly, and then through cluster DNS:

```bash
kubectl exec dnsutils -- dig +short @"$CORP_DNS_IP" db.corp.internal
kubectl exec dnsutils -- dig db.corp.internal | grep -E 'status|ANSWER SECTION' -A1
```

```
10.10.0.50
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 29411
```

Cluster DNS forwards `corp.internal` to the node's upstream resolver, which has never heard of it.

**3.** Add a stub-domain server block to the cluster Corefile. Put it **after** the closing `}` of `.:53`, and replace `10.96.201.14` with your `$CORP_DNS_IP`:

```bash
kubectl -n kube-system edit configmap coredns
```

```
corp.internal:53 {
    errors
    cache 30
    forward . 10.96.201.14
}
```

**4.** Wait for `Reloading complete` in the CoreDNS logs, then test again:

```bash
kubectl exec dnsutils -- dig +short db.corp.internal
kubectl exec dnsutils -- dig +short ldap.corp.internal
kubectl exec dnsutils -- nslookup db.corp.internal
kubectl -n corp-dns logs deploy/corp-dns --tail=5
```

```
10.10.0.50
10.10.0.60
...
Name:   db.corp.internal
Address: 10.10.0.50
[INFO] 10.244.2.3:35012 - 55120 "A IN db.corp.internal. udp 57 true 2048" NOERROR qr,aa,rd 66 0.000154s
```

The client address in the `corp-dns` log is a **CoreDNS pod IP**, not the `dnsutils` IP.

**Questions**

- **Q4.1** Why do you have to use the Service's ClusterIP in `forward` instead of `corp-dns.corp-dns.svc.cluster.local`?
- **Q4.2** Why use a separate `corp.internal:53 { ... }` server block instead of adding a second `forward` line to `.:53`?
- **Q4.3** In the `nslookup db.corp.internal` from step 4, which names were queried before the one that succeeded? How would you avoid those extra queries from the client?
- **Q4.4** Why does the `corp-dns` log show a CoreDNS pod as the client, and what does that mean for firewall rules or ACLs on a real corporate DNS server?
- **Q4.5** Suppose you "simplify" the main block to `forward . 10.96.0.10` (the `kube-dns` ClusterIP itself). What happens after the reload?

---

## Exercise 5 — Static records with the `hosts` plugin

**1.** Add a `hosts` block inside `.:53`. Position within the block does not matter; placing it just before `kubernetes` keeps it readable:

```
.:53 {
    errors
    log
    ...
    hosts {
       192.168.50.10 nas.legacy.lan
       192.168.50.11 printer.legacy.lan
       ttl 60
       fallthrough
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
    ...
}
```

**2.** After the reload, test forward and reverse lookups, and check that normal resolution still works:

```bash
kubectl exec dnsutils -- dig +short nas.legacy.lan
kubectl exec dnsutils -- dig +short -x 192.168.50.11
kubectl exec dnsutils -- dig +short web.default.svc.cluster.local
kubectl exec dnsutils -- dig +short example.com
```

```
192.168.50.10
printer.legacy.lan.
10.104.37.212
93.184.215.14
```

**Questions**

- **Q5.1** What happens to every other query (Services, external names) if you remove `fallthrough` from this `hosts` block? Why?
- **Q5.2** Which plugin answered the PTR query for `192.168.50.11`, and why did it win over `kubernetes`, which also claims `in-addr.arpa`?
- **Q5.3** When would you choose `hosts` over a stub domain (Exercise 4), and vice versa?

---

## Exercise 6 — Service aliases with `rewrite`

Goal: applications should reach `data`-namespace Services as `<name>.corp.lab`, for example `postgres.corp.lab` → `postgres.data.svc.cluster.local`.

**1.** Create the target Service. A selectorless Service still gets a ClusterIP and an A record:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: data
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: data
spec:
  ports:
    - name: postgres
      port: 5432
```

```bash
kubectl apply -f ex6.yaml
kubectl -n data get svc postgres
```

**2.** Add a `rewrite` block to `.:53`:

```
    rewrite stop {
        name regex (.+)\.corp\.lab\.$ {1}.data.svc.cluster.local.
        answer name (.+)\.data\.svc\.cluster\.local\.$ {1}.corp.lab.
    }
```

The complete Corefile should now look similar to this:

```
.:53 {
    errors
    log
    health {
       lameduck 5s
    }
    ready
    rewrite stop {
        name regex (.+)\.corp\.lab\.$ {1}.data.svc.cluster.local.
        answer name (.+)\.data\.svc\.cluster\.local\.$ {1}.corp.lab.
    }
    hosts {
       192.168.50.10 nas.legacy.lan
       192.168.50.11 printer.legacy.lan
       ttl 60
       fallthrough
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
corp.internal:53 {
    errors
    cache 30
    forward . 10.96.201.14
}
```

**3.** Test it:

```bash
kubectl exec dnsutils -- dig postgres.corp.lab | sed -n '/ANSWER SECTION/,/^$/p'
kubectl exec dnsutils -- dig +short postgres.data.svc.cluster.local
kubectl exec dnsutils -- dig +short nothere.corp.lab; echo "rc=$?"
kubectl exec dnsutils -- nslookup postgres.corp.lab
```

```
;; ANSWER SECTION:
postgres.corp.lab.      30      IN      A       10.99.12.40

10.99.12.40
rc=0
...
Name:   postgres.corp.lab
Address: 10.99.12.40
```

In the CoreDNS log, the `postgres.corp.lab.` query is logged under its **original** name, because `log` runs before `rewrite`.

**Questions**

- **Q6.1** The `rewrite` block appears before `hosts` and `kubernetes` in the Corefile. Does moving it to the bottom of the block change anything? What does decide the order?
- **Q6.2** What can go wrong if you remove the `answer name` line?
- **Q6.3** With `ndots:5`, the resolver first tries `postgres.corp.lab.default.svc.cluster.local.` Why does the rule not rewrite that name, and why does that matter?
- **Q6.4** A colleague suggests creating an `ExternalName` Service instead. Compare the two approaches.

---

## Exercise 7 — Per-pod DNS: `dnsPolicy` and `dnsConfig`

**1.** Create a pod with tuned resolver settings:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-tuned
  namespace: default
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    searches:
      - corp.internal
    options:
      - name: ndots
        value: "2"
      - name: timeout
        value: "2"
  containers:
    - name: dnsutils
      image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f ex7.yaml
kubectl wait --for=condition=Ready pod/dns-tuned --timeout=90s
kubectl exec dns-tuned -- cat /etc/resolv.conf
```

Output (the node's own search domains may also appear):

```
search default.svc.cluster.local svc.cluster.local cluster.local corp.internal
nameserver 10.96.0.10
options ndots:2 timeout:2
```

**2.** Compare how short names and dotted names behave:

```bash
kubectl exec dns-tuned -- nslookup db
kubectl exec dns-tuned -- nslookup web
kubectl exec dns-tuned -- nslookup example.com
```

Keep the CoreDNS log from Exercise 3 open and count the queries each lookup generates.

**3.** Look at the other policies without creating pods:

```bash
kubectl explain pod.spec.dnsPolicy
```

**Questions**

- **Q7.1** Where does each entry in the `search` line come from?
- **Q7.2** Why does `nslookup db` resolve to `10.10.0.50`, and why does `example.com` now generate only one query (per record type) instead of four?
- **Q7.3** What breaks for this pod because of `ndots:2`? Give an example name.
- **Q7.4** A developer sets `dnsPolicy: Default` because "default sounds safe". What happens?
- **Q7.5** When is `dnsPolicy: None` justified, and what must you then provide?

---

## Exercise 8 — Break it, observe it, recover

**1.** Make a deliberate typo in the cluster Corefile. Change `forward . /etc/resolv.conf {` to `forwad . /etc/resolv.conf {` and save.

**2.** Watch the logs for about two minutes. You will see a reload attempt fail with an error that names the unknown directive, and **no** `Reloading complete`.

**3.** Check that DNS still works:

```bash
kubectl exec dnsutils -- dig +short web.default.svc.cluster.local
kubectl exec dnsutils -- dig +short example.com
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

Both queries still answer, and the pods stay `Running`.

**4.** Do **not** restart the pods. Fix the typo instead, and confirm `Reloading complete` appears in the logs.

**Questions**

- **Q8.1** Which configuration are the pods serving after step 1, and why?
- **Q8.2** What would have happened if a node had been drained, or someone had run `kubectl -n kube-system rollout restart deployment coredns`, while the typo was in place?
- **Q8.3** Name three safeguards to use before and after editing the production Corefile.

---

## Cleanup

```bash
kubectl -n kube-system create configmap coredns --from-file=Corefile=Corefile.orig \
  --dry-run=client -o yaml | kubectl replace -f -
kubectl delete pod dnsutils dns-tuned
kubectl delete deployment web
kubectl delete service web web-headless
kubectl delete namespace corp-dns data
```

Wait for `Reloading complete`, then check that `dig +short nas.legacy.lan` and `dig +short postgres.corp.lab` no longer resolve.

---

## Answers

<details>
<summary>Exercise 1</summary>

**Q1.1** CoreDNS replaced the older kube-dns add-on. To keep that change invisible, the Service kept the name `kube-dns` and the label `k8s-app=kube-dns`. Pods depend only on the Service **ClusterIP** (`10.96.0.10`). The kubelet writes it into each pod's `/etc/resolv.conf` from its `clusterDNS` setting. The Deployment name is irrelevant to clients.

**Q1.2** The `reload` plugin. It checks the Corefile every 30 s by default (with up to 15 s of jitter). Before that, the kubelet has to project the updated ConfigMap into the volume, which depends on its sync period and cache and often takes up to about a minute. The worst case is therefore around 1–2 minutes.

**Q1.3** If the `kubernetes` plugin cannot answer a reverse query (for example a PTR for an IP that is neither a Service nor a pod), it passes the query to the next plugin instead of returning NXDOMAIN. That plugin is `forward` in the default config, so reverse lookups of external IPs still work. For forward names under `cluster.local`, the plugin stays authoritative and answers NXDOMAIN itself.

**Q1.4** The file never appears in the container, because the volume projects only the `Corefile` key. A `file` directive pointing to it fails at load time. You would also need to edit the Deployment's volume `items` (or remove `items`), and a Deployment edit may be reverted by your installer or add-on manager on upgrade. That is one reason inline `hosts` entries or a separate authoritative server (Exercise 4) are usually preferable.
</details>

<details>
<summary>Exercise 2</summary>

**Q2.1** `nslookup` applies the `search` list from `/etc/resolv.conf`, so `kubernetes` becomes `kubernetes.default.svc.cluster.local`. `dig` does **not** use the search list unless you pass `+search`, so it sends the literal name `kubernetes.` and gets NXDOMAIN (empty `+short` output). This matters for debugging: `dig` shows what the server answers, while `nslookup` / `getent hosts` show what an application's resolver would do.

**Q2.2** `web` returns one virtual IP (the ClusterIP), and kube-proxy or the dataplane load-balances connections behind it. `web-headless` returns the **pod IPs** directly (one A record per ready endpoint). The client then picks one, so load balancing depends on the client's resolver and connection behavior. `loadbalance` in the Corefile shuffles the record order to spread that choice.

**Q2.3** SRV records are generated only for **named** ports: `_<port-name>._<protocol>.<svc>.<ns>.svc.cluster.local`. A ClusterIP Service gets one SRV record pointing at the Service name. A headless Service gets one per endpoint, pointing at per-pod hostnames. With an unnamed port there is no SRV record (NXDOMAIN), although A records still work.

**Q2.4** `pods insecure` inside the `kubernetes` block. It is "insecure" because CoreDNS synthesizes `a-b-c-d.<ns>.pod.cluster.local` for any IP without checking that such a pod exists in that namespace. It is kept for kube-dns backward compatibility. `pods verified` checks this against a pod watch (more memory), and `pods disabled` turns pod records off.
</details>

<details>
<summary>Exercise 3</summary>

**Q3.1** Four A queries (plus the same again for AAAA if the client asks). `example.com` has one dot, which is fewer than `ndots:5`, so the resolver tries each search suffix first (`default.svc.cluster.local`, `svc.cluster.local`, `cluster.local`). Each of those returns NXDOMAIN before the absolute name is tried. At scale, most CoreDNS load can be these negative lookups.

**Q3.2** Client side: use fully qualified names with a trailing dot (`example.com.`), or lower `ndots` through `dnsConfig` (Exercise 7). Server side: enable `autopath @kubernetes`, which requires `pods verified`. CoreDNS then follows the search path itself and returns the final answer in one round trip. Negative caching also reduces the cost. A NodeLocal DNSCache is another option: it cuts latency and conntrack pressure but not the number of queries.

**Q3.3** `log` writes one line per query to stdout. On a busy cluster that is a lot of CPU and log volume, and it can reveal which services each pod talks to. Use it while you diagnose, then remove it (or scope it, for example `log . { class denial error }`).

**Q3.4** Not necessarily. ConfigMap propagation plus the reload interval can take up to about two minutes (see Q1.2). Check the Corefile inside a pod before assuming a failure. A missing `Reloading complete` together with an error line means the new config was rejected (Exercise 8).
</details>

<details>
<summary>Exercise 4</summary>

**Q4.1** `forward` accepts IP addresses (optionally with a port or protocol prefix) or a resolv.conf-style file. It cannot resolve a name to find its own upstream, which would be circular anyway. Consequence: if someone deletes and recreates the `corp-dns` Service, its ClusterIP changes and the stub domain breaks silently. A Service with a pinned `spec.clusterIP`, or a stable external IP, avoids this.

**Q4.2** CoreDNS sends each query to the server block with the **most specific matching zone**. `corp.internal:53` catches `*.corp.internal`, and everything else goes to `.:53`. Inside a single block, a second `forward` for the same `.` zone would not route by domain. `forward` also supports `except`, but a separate server block is the idiomatic stub-domain pattern and is what the Kubernetes docs show. It also lets you give the zone its own `cache`, `log` and error handling.

**Q4.3** `db.corp.internal` has 2 dots, fewer than 5, so `db.corp.internal.default.svc.cluster.local.`, `...svc.cluster.local.` and `...cluster.local.` were tried first (all NXDOMAIN from `kubernetes`), then `db.corp.internal.`. To avoid that, use `db.corp.internal.` with a trailing dot, or lower `ndots` for that workload.

**Q4.4** CoreDNS makes a new recursive query from its own pod IP, so the upstream sees CoreDNS rather than the application pod. In a real network, the corporate DNS server's ACLs and firewalls must allow traffic from the **pod CIDR / CoreDNS pods**, or from node IPs if pod traffic is SNATed on egress. Per-client auditing on the corporate side is lost.

**Q4.5** CoreDNS would forward to itself. The `loop` plugin sends a random probe query at startup. If the probe comes back to the same instance, CoreDNS logs `Loop ... detected for zone "."` and exits, and the pods end up in CrashLoopBackOff. The same failure happens in real clusters when the node's `/etc/resolv.conf` points to a local stub (for example `127.0.0.53` from systemd-resolved). The fix there is to point the kubelet's `resolvConf` at the real upstream file (`/run/systemd/resolve/resolv.conf`).
</details>

<details>
<summary>Exercise 5</summary>

**Q5.1** Without `zones` arguments, `hosts` claims every zone of its server block, which is `.`, meaning all names. Without `fallthrough`, a name missing from its table gets a failure from `hosts` instead of being passed on to `kubernetes` and `forward`. Cluster DNS would effectively break for everything except the listed hosts. Keep `fallthrough`, or restrict `hosts` to specific zones.

**Q5.2** `hosts`. It builds PTR records for its entries automatically unless you set `no_reverse`. Plugin execution order is fixed at compile time (`plugin.cfg`), and `hosts` comes before `kubernetes`, so it answers first. Only when `hosts` falls through does `kubernetes` see the query.

**Q5.3** Use `hosts` for a handful of static records that you own, that rarely change, and for which no authoritative server exists (or you want to override one). Use a stub domain when another team or system is authoritative for a whole zone, records change independently of your cluster config, or you need proper SOA, NXDOMAIN and TTL semantics. Copying a zone into `hosts` goes stale.
</details>

<details>
<summary>Exercise 6</summary>

**Q6.1** Nothing changes. Directive order inside a server block does **not** determine execution order. CoreDNS runs plugins in the order compiled into the binary (`plugin.cfg`). There, `log` and `cache` come before `rewrite`, which comes before `hosts`, then `kubernetes`, and finally `forward`. So the rewritten name is what `kubernetes` sees. `cache` stores the response under the original question name, and `log` records the original name.

**Q6.2** The question section is restored to the original name, but the answer record's owner name would stay `postgres.data.svc.cluster.local.`. That no longer matches the question `postgres.corp.lab.`. `dig` still prints it, but stub resolvers such as glibc can discard answers whose owner name does not match, and the application gets "host not found". `answer name` rewrites the owner name back so the response is consistent.

**Q6.3** The regex is anchored with `\.corp\.lab\.$`, so it matches only names **ending** in `corp.lab.`. Search-expanded names end in `cluster.local.` and pass through to `kubernetes` untouched, getting normal NXDOMAIN until the absolute name is tried. An unanchored or looser regex could rewrite those intermediate names into something unexpected and return a wrong answer early in the search sequence.

**Q6.4** An `ExternalName` Service creates a **CNAME** in one namespace (`pg.app.svc.cluster.local` → target). It is declarative, namespaced, visible via `kubectl get svc`, and needs no cluster-admin access. But it only works for names under `cluster.local`, and it adds a CNAME hop that some TLS or HTTP clients handle poorly (the Host header and certificate name are the alias). `rewrite` works for arbitrary domains such as `corp.lab`, returns the A record directly, and applies cluster-wide. On the other hand, it lives in a central ConfigMap that needs cluster-admin, and a bad regex affects every pod.
</details>

<details>
<summary>Exercise 7</summary>

**Q7.1** `default.svc.cluster.local`, `svc.cluster.local` and `cluster.local` are added by the kubelet for `ClusterFirst` (from the pod's namespace and `clusterDomain`). Any node search domains are inherited from the node's resolv.conf. `corp.internal` is appended from `dnsConfig.searches`. `dnsConfig` entries are **merged** with what the policy generates, not substituted for it.

**Q7.2** `db` has 0 dots, fewer than 2, so the search list is walked. The three cluster suffixes return NXDOMAIN, then `db.corp.internal` goes to the stub domain from Exercise 4 and returns `10.10.0.50`. `example.com` has 1 dot, still fewer than 2, so it too walks the search list and generates about five A queries (the three cluster suffixes, `example.com.corp.internal`, then the absolute name). The saving shows on names with two or more dots: `www.example.com` or `db.corp.internal` are now tried as absolute names first, so a single query per record type succeeds. Under `ndots:5` they would have needed four.

**Q7.3** Names with 2 or more dots are tried as absolute names first. `web.default.svc` (2 dots) is first sent as `web.default.svc.`, which goes to the upstream and returns NXDOMAIN. Only then is the search list tried, so it works but slowly, and it leaks internal names upstream. The shorthand forms `service.namespace` (1 dot) still work. Lowering `ndots` is a per-workload trade-off.

**Q7.4** `Default` means "inherit the **node's** resolver configuration", not "the Kubernetes default". The pod cannot resolve any `*.svc.cluster.local` name. The actual default policy is `ClusterFirst`. For `hostNetwork: true` pods that still need cluster DNS, use `ClusterFirstWithHostNet`.

**Q7.5** `None` is justified when a workload must use a specific resolver: a dedicated DNS appliance, an isolated tenant resolver, or a test harness. You must then provide everything in `dnsConfig`: at least one `nameservers` IP (up to 3), plus `searches` and `options` as needed. The kubelet generates nothing for that pod.
</details>

<details>
<summary>Exercise 8</summary>

**Q8.1** The **previous** valid configuration. `reload` parses the new Corefile. If it fails to load, the running instance keeps serving the old one and logs the error. DNS appears healthy, which makes it easy to miss that the ConfigMap is broken.

**Q8.2** Any new CoreDNS process (a restarted pod, a rescheduled pod after a drain, a rollout) reads the broken Corefile at startup and fails to start, ending in CrashLoopBackOff. During a rolling restart, old pods are removed as new ones are created, so capacity drops and can reach zero. The result is a cluster-wide DNS outage that shows up hours after the edit that caused it.

**Q8.3** (1) Back up the Corefile before editing (as in Exercise 1) and keep the ConfigMap in version control or GitOps. (2) After every edit, confirm `Reloading complete` and the new `Running configuration SHA512` in **all** CoreDNS pods, and treat an error line as a failed change. (3) Validate changes first on a throwaway CoreDNS instance with the same image version, like the `corp-dns` Deployment in Exercise 4. Other useful safeguards: alert on `coredns_reload_failed_total` (from the `reload` plugin), and keep a PodDisruptionBudget and at least two replicas for CoreDNS.
</details>