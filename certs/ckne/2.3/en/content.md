# Topic 2.3 — Customizing CoreDNS for Services

> **Exam weight:** 4.17% · **Certification:** CKNE (Certified Kubernetes Network Engineer)
> **Scope:** how Services are resolved in-cluster, how the CoreDNS configuration (the `Corefile`) is structured and executed, and how to change it safely in production: stub domains, upstream forwarding, rewrites, static records, caching, and query-volume tuning. Covers diagnosing DNS failures and the trade-offs between approaches.

---

## 1. Motivation: why the default is rarely enough in production

Every Pod with the default `dnsPolicy: ClusterFirst` sends its DNS queries to the cluster DNS Service (usually `kube-dns` in `kube-system`, backed by CoreDNS Pods). This one Deployment sits on the critical path of almost every connection in the cluster. When it breaks, the symptoms look like application failures: timeouts, `connection refused` to the wrong IP, intermittent 5-second latencies, `NXDOMAIN` for names that clearly exist.

The kubeadm default `Corefile` handles exactly two cases: names under `cluster.local`, and everything else sent to whatever the node's `/etc/resolv.conf` says. Real platforms need more:

| Production requirement | Why the default fails | CoreDNS mechanism |
|---|---|---|
| Resolve a corporate zone (`corp.example.com`) served by on-prem DNS | The node's resolver may not know the zone, or may be a public resolver | Stub domain: a separate server block with `forward` |
| Pin the upstream resolvers instead of inheriting them from the node | Node `resolv.conf` differs across node pools, cloud images and `systemd-resolved` setups | `forward . <ip> <ip>` |
| Keep a legacy hostname working after a migration into the cluster | Clients have `db.legacy.example.com` hard-coded | `rewrite` or `hosts` |
| Give a stable internal alias for a Service (`api.internal` → `api.prod.svc.cluster.local`) | Service DNS names include the namespace | `rewrite` with answer rewriting |
| Reduce query amplification from `ndots:5` | Every external lookup first tries up to 3–4 search-domain suffixes | `autopath`, Pod `dnsConfig`, `cache`, NodeLocal DNSCache |
| Stop wasted AAAA lookups in IPv4-only clusters | glibc queries A and AAAA in parallel, doubling upstream traffic | `template` |
| Survive upstream DNS outages | Once an entry expires, queries fail | `cache` with `serve_stale` |

The CKNE expects you to edit the CoreDNS configuration **without taking cluster DNS down**, and to prove the change works from inside a Pod.

---

## 2. Architecture: how a Service name becomes an IP

### 2.1 The resolution path

```
Pod (glibc/musl resolver)
  │  reads /etc/resolv.conf written by kubelet:
  │    nameserver 10.96.0.10
  │    search <ns>.svc.cluster.local svc.cluster.local cluster.local
  │    options ndots:5
  ▼
kube-dns Service ClusterIP (10.96.0.10:53 UDP/TCP)
  │  kube-proxy / eBPF dataplane DNAT → one CoreDNS Pod
  ▼
CoreDNS Pod
  │  plugin chain (fixed order, compiled in)
  │   ├─ cache            → hit? answer immediately
  │   ├─ rewrite          → change the question
  │   ├─ template / hosts → synthetic or static answers
  │   ├─ kubernetes       → watch-backed cache of Services/EndpointSlices
  │   └─ forward          → upstream resolvers (the node's resolv.conf, or explicit IPs)
  ▼
Answer
```

Key points:

- **The `kubernetes` plugin does not query the API server per request.** It keeps an informer (watch) cache of Services, EndpointSlices, Namespaces and, optionally, Pods. Answers come from memory. This is why a new Service resolves within milliseconds of being created, and why CoreDNS memory grows with cluster size.
- **Records produced for Services:**
  - ClusterIP Service: `A`/`AAAA` `<svc>.<ns>.svc.cluster.local` → ClusterIP.
  - Headless Service (`clusterIP: None`): `A`/`AAAA` → one record per ready endpoint, plus `<hostname>.<svc>.<ns>.svc.cluster.local` for Pods that set `hostname`/`subdomain` (StatefulSets).
  - `ExternalName` Service: `CNAME` → `spec.externalName`.
  - Named ports: `SRV` `_<port>._<proto>.<svc>.<ns>.svc.cluster.local`.
  - Reverse `PTR` in `in-addr.arpa` / `ip6.arpa`.

### 2.2 The Corefile model: server blocks and zones

A `Corefile` is a list of **server blocks**. Each block declares the zones and port it serves and lists plugins:

```
ZONE[:PORT] [ZONE[:PORT]...] {
    plugin [args] {
        plugin-options
    }
    ...
}
```

When a query arrives, CoreDNS picks the server block with the **most specific matching zone**. `corp.example.com:53` beats `.:53` for `db.corp.example.com`. That is how stub domains work.

### 2.3 The trap everyone falls into: plugin order is NOT Corefile order

Plugins run in the order fixed at compile time in `plugin.cfg`, **not** in the order you write them in the Corefile. Abridged execution order in upstream CoreDNS builds:

```
metadata → reload → ready → health → prometheus → errors → log → loadbalance
→ cache → rewrite → header → autopath → template → hosts → k8s_external
→ kubernetes → file → auto → etcd → loop → forward → ...
```

Consequences:

- Moving `cache` below `forward` in the file changes nothing. `cache` always wraps everything after it.
- `rewrite` always runs before `kubernetes`, so a rewritten name *can* be answered by the `kubernetes` plugin. This is what makes Service aliases possible.
- `hosts` and `template` run before `kubernetes`, so they can shadow cluster names. `fallthrough` controls whether an unmatched query continues down the chain.

### 2.4 How a change reaches the running process

```
kubectl edit cm coredns
   │
   ▼  kubelet syncs the ConfigMap volume (projected, NOT subPath)
/etc/coredns/Corefile inside the Pod   ← up to ~60–90 s: kubelet sync period + ConfigMap cache TTL
   │
   ▼  reload plugin checks the file's SHA512 (default every 30 s ± 15 s jitter)
graceful in-process reload
   │  if the new Corefile fails to parse → the OLD configuration keeps running, and an error is logged
   ▼
new configuration active
```

Without the `reload` plugin you need `kubectl -n kube-system rollout restart deployment coredns`. With it, **one to two minutes** is a normal propagation delay. Do not assume the edit is broken after 10 seconds.

---

## 3. Reference: the default kubeadm configuration

Every Corefile line below has a production meaning. Know them for the exam.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
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

| Plugin | Role | Production note |
|---|---|---|
| `errors` | Logs errors to stdout | Keep it. Add `log` only temporarily: it logs every query and is expensive at scale |
| `health { lameduck 5s }` | `:8080/health` liveness endpoint. Lameduck keeps answering for 5 s during shutdown | Prevents dropped queries during rolling updates |
| `ready` | `:8181/ready` readiness endpoint, OK once all plugins are ready (for example, the kubernetes informer has synced) | Stops traffic reaching a Pod before its Service cache is warm |
| `kubernetes` | Answers cluster zones | `pods insecure` answers `a-b-c-d.<ns>.pod.cluster.local` without checking that the Pod exists. `verified` checks, at the cost of watching all Pods (memory) |
| `fallthrough in-addr.arpa ip6.arpa` | Reverse lookups for non-cluster IPs continue to `forward` | Without it, a PTR for a node IP returns NXDOMAIN |
| `ttl 30` | TTL of Kubernetes answers (plugin default 5, max 3600) | Higher TTL means fewer queries but slower convergence after Service IP changes (rare: ClusterIPs are stable) |
| `prometheus :9153` | Metrics | Scrape it. See section 7 |
| `forward . /etc/resolv.conf` | Everything else goes to the upstream resolvers from the CoreDNS Pod's `resolv.conf` (inherited from the node, since CoreDNS runs with `dnsPolicy: Default`) | Source of the classic `systemd-resolved` loop |
| `cache 30` | Caches answers for up to 30 s | Caches both `kubernetes` and `forward` answers |
| `loop` | Detects forwarding loops at startup and **exits** if one is found | CrashLoopBackOff with `plugin/loop` means a real loop. Fix it, do not remove the plugin |
| `reload` | Hot-reloads the Corefile | See 2.4 |
| `loadbalance` | Shuffles the order of A/AAAA records | Rough client-side spreading for headless Services |

---

## 4. Customization patterns (complete manifests)

> **Before any edit:** back up the current configuration. On the exam and in production alike, a broken Corefile is recovered by re-applying this file.
>
> ```
> $ kubectl -n kube-system get configmap coredns -o yaml > coredns-backup.yaml
> ```

### 4.1 Stub domain and explicit upstreams

Goals: send `corp.example.com` to the on-prem DNS servers `10.150.0.10` and `10.150.0.11`; send all other external names to fixed resolvers instead of the node's `resolv.conf`; keep private reverse lookups for the corporate range working.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
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
        forward . 1.1.1.1 8.8.8.8 {
           max_concurrent 1000
           policy sequential
           health_check 5s
        }
        cache 30
        loop
        reload
        loadbalance
    }
    corp.example.com:53 {
        errors
        cache 30
        forward . 10.150.0.10 10.150.0.11 {
           policy round_robin
        }
    }
    150.10.in-addr.arpa:53 {
        errors
        cache 30
        forward . 10.150.0.10 10.150.0.11
    }
```

Notes:

- The stub block has **no** `kubernetes` plugin, so names in that zone never touch the cluster cache.
- `policy sequential` always tries the first upstream first (predictable, good when the first is local). `round_robin` spreads load. `random` is the default.
- `health_check 5s` probes upstreams in the background, so a dead resolver is marked down before client queries time out.
- `150.10.in-addr.arpa` covers PTR lookups for `10.150.0.0/16`. The more specific zone wins over the `in-addr.arpa` zone owned by the `kubernetes` plugin in the `.:53` block.

### 4.2 Stable aliases for Services (`rewrite`)

Goals: make `api.internal` resolve to the `api` Service in `prod`, and map every `*.svc.corp.example.com` name onto the `default` namespace, with answers that clients accept.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        rewrite stop {
           name exact api.internal. api.prod.svc.cluster.local.
           answer name ^api\.prod\.svc\.cluster\.local\.$ api.internal.
        }
        rewrite stop {
           name regex (.*)\.svc\.corp\.example\.com\.$ {1}.default.svc.cluster.local.
           answer name (.*)\.default\.svc\.cluster\.local\.$ {1}.svc.corp.example.com.
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
        cache 30
        loop
        reload
        loadbalance
    }
```

Why the `answer name` line matters: `rewrite` changes the **question** before `kubernetes` sees it. Without an answer rewrite, the response contains a record for `api.prod.svc.cluster.local` while the client asked for `api.internal`. Strict stub resolvers (and `dig` in some modes) treat that as a mismatch and discard the answer. The answer rewrite restores the name the client asked for.

`stop` means: after this rule matches, do not evaluate later `rewrite` rules. `continue` would keep evaluating them.

**Alternative without CoreDNS changes:** an `ExternalName` Service in the client's namespace pointing to `api.prod.svc.cluster.local`. Trade-offs are in section 5.

### 4.3 Static records (`hosts`) from a dedicated ConfigMap

Keeping static entries in a separate ConfigMap means they can be edited without touching the Corefile. This requires mounting that ConfigMap into the CoreDNS Deployment.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom-hosts
  namespace: kube-system
data:
  customhosts: |
    10.150.20.5 db.legacy.example.com
    10.150.20.6 ldap.legacy.example.com
    fd00:150::20:5 db.legacy.example.com
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        hosts /etc/coredns/custom/customhosts legacy.example.com {
           reload 15s
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
        cache 30
        loop
        reload
        loadbalance
    }
```

Strategic-merge patch that adds the volume (mount at a **directory**, never with `subPath`, or updates never propagate):

```yaml
spec:
  template:
    spec:
      volumes:
        - name: custom-hosts
          configMap:
            name: coredns-custom-hosts
      containers:
        - name: coredns
          volumeMounts:
            - name: custom-hosts
              mountPath: /etc/coredns/custom
              readOnly: true
```

```
$ kubectl -n kube-system patch deployment coredns --patch-file coredns-hosts-patch.yaml
deployment.apps/coredns patched
$ kubectl -n kube-system rollout status deployment coredns
Waiting for deployment "coredns" rollout to finish: 1 of 2 updated replicas are available...
deployment "coredns" successfully rolled out
```

Restricting `hosts` to the zone `legacy.example.com` keeps it out of the lookup path for every other name. `fallthrough` sends names in that zone that are not listed in the file on to `forward`.

The quick-and-dirty variant, entries inline in the Corefile:

```
hosts {
   10.150.20.5 db.legacy.example.com
   fallthrough
}
```

### 4.4 Blocking AAAA in an IPv4-only cluster (`template`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        template IN AAAA . {
           rcode NOERROR
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
        cache 30
        loop
        reload
        loadbalance
    }
```

`NOERROR` with an empty answer section (NODATA) tells the client "the name exists, it has no IPv6 address". The client still gets its A record. **Never** apply this in a dual-stack cluster: it hides every AAAA record, cluster ones included.

### 4.5 Cutting query amplification: `autopath`, cache tuning, `serve_stale`

With `ndots:5`, a lookup of `api.github.com` (2 dots < 5) from namespace `shop` tries, in order:

```
api.github.com.shop.svc.cluster.local   → NXDOMAIN
api.github.com.svc.cluster.local        → NXDOMAIN
api.github.com.cluster.local            → NXDOMAIN
api.github.com.<node search domain>     → NXDOMAIN (if the node has one)
api.github.com.                         → answer
```

Times two for A + AAAA, that is up to 10 queries for one name. Three tools reduce it:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods verified
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        autopath @kubernetes
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache {
           success 9984 300 5
           denial 9984 30 5
           prefetch 10 1m 10%
           serve_stale 1h immediate
        }
        loop
        reload
        loadbalance
    }
```

- `autopath @kubernetes` walks the search path **on the server side** on the first query and returns the final answer (as a CNAME chain), so the client stops after one round trip. It **requires `pods verified`**: CoreDNS has to map the source IP to a Pod to learn its namespace. That means watching every Pod in the cluster, which costs significant memory in large clusters. It also breaks if the source IP is not a Pod IP (for example, behind NodeLocal DNSCache, where the source is the node-local cache).
- `cache`: `success CAPACITY MAX_TTL MIN_TTL` and `denial ...` bound the TTLs. Caching NXDOMAIN (`denial`) is what absorbs the search-path misses. `prefetch 10 1m 10%` refreshes popular entries before they expire. `serve_stale 1h immediate` answers with expired data when the upstream is unreachable (resilience at the price of possibly stale answers).

Pod-side alternative that needs no CoreDNS change: lower `ndots` per workload.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: external-heavy-client
  namespace: shop
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    options:
      - name: ndots
        value: "2"
      - name: single-request-reopen
  containers:
    - name: app
      image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
      command:
        - sleep
        - infinity
```

With `ndots:2`, `api.github.com` is tried as an absolute name first. Short names like `orders` or `orders.shop` still go through the search path.

### 4.6 Exposing LoadBalancer Services under an external zone (`k8s_external`)

```
    k8s_external k8s.example.com {
       ttl 60
    }
```

Added to the `.:53` block, this makes `web.prod.k8s.example.com` resolve to the **external** IP (`status.loadBalancer.ingress`) of Service `web` in `prod`. It is useful when CoreDNS is also exposed as the authoritative server for that subdomain.

### 4.7 Managed and distribution-specific variants

Some platforms reconcile the `coredns` ConfigMap and overwrite your edits. They provide an extension point instead:

| Platform | Extension point | Behavior |
|---|---|---|
| kubeadm / vanilla | Edit `kube-system/coredns` directly | `kubeadm upgrade` may re-render it. Keep your version in Git |
| AKS | `kube-system/coredns-custom` ConfigMap | Keys ending in `.server` become new server blocks. Keys ending in `.override` are imported into the default block |
| k3s / RKE2 | `coredns-custom` ConfigMap (k3s), Helm chart values (RKE2) | The packaged Corefile uses `import` from a mounted directory |
| EKS | Managed add-on configuration (`corefile` value in the add-on schema) or self-managed | Direct edits to an add-on-managed ConfigMap can be reverted by `OVERWRITE` conflict resolution |
| GKE (kube-dns) | `kube-system/kube-dns` ConfigMap `stubDomains` / `upstreamNameservers` | Not CoreDNS. Cloud DNS mode is configured through the GKE API instead |

The general pattern behind these is the `import` plugin. A self-managed equivalent:

```
.:53 {
    import /etc/coredns/custom/*.override
    kubernetes cluster.local in-addr.arpa ip6.arpa
    forward . /etc/resolv.conf
}
import /etc/coredns/custom/*.server
```

---

## 5. Trade-off comparisons

### 5.1 Ways to give a workload an alternative name

| Mechanism | Scope | Needs CoreDNS change | Pros | Cons |
|---|---|---|---|---|
| `ExternalName` Service | One namespace (`<svc>.<ns>`) | No | Declarative, RBAC-scoped to the app team | Returns a CNAME: TLS SNI/Host header carries the alias. Cannot alias to an IP |
| `rewrite` in CoreDNS | Cluster-wide | Yes | Any name shape, regex, arbitrary zones | Cluster-wide blast radius. Needs answer rewriting. Platform-team owned |
| `hosts` plugin | Cluster-wide | Yes | Static IPs outside the cluster, file can be reloaded | Manual IP management, no health awareness |
| Pod `hostAliases` | One Pod (writes `/etc/hosts`) | No | Zero DNS involvement | Per-Pod, not visible to DNS tools, drifts |
| Stub domain `forward` | Cluster-wide per zone | Yes | Delegates to the authoritative source | Depends on network reachability to that DNS |

### 5.2 Scaling DNS query capacity

| Approach | Latency | Query volume at CoreDNS | Operational cost | Watch out for |
|---|---|---|---|---|
| More CoreDNS replicas (cluster-proportional-autoscaler) | Unchanged | Unchanged, spread over more Pods | Low | conntrack races on UDP (5 s timeouts) remain |
| NodeLocal DNSCache (DaemonSet on `169.254.20.10`) | Lower (node-local hits) | Much lower | Medium: extra DaemonSet, iptables/`NOTRACK` rules | In IPVS mode kubelet `clusterDNS` must point to the local IP. `autopath` stops working (source IP is the cache) |
| `autopath` | Lower for external names | Lower | Memory for `pods verified` | Large-cluster memory usage, incompatible with node-local caching |
| Lower `ndots` in Pod `dnsConfig` | Lower for external names | Lower | Per-workload | Short multi-dot names (`svc.ns`) still depend on search paths |
| Larger `cache` TTLs / `prefetch` | Lower | Lower | None | Staleness after upstream changes |

### 5.3 `pods insecure` vs `verified` vs `disabled`

| Mode | Pod A records `1-2-3-4.ns.pod.cluster.local` | Memory | Security |
|---|---|---|---|
| `disabled` | Not served | Lowest | — |
| `insecure` (kubeadm default) | Always answered, no existence check | Low | Anyone can mint a name that resolves to any IP. Harmless for most, bad for TLS-by-name assumptions |
| `verified` | Only if a Pod with that IP exists in that namespace | High (watches all Pods) | Correct. Required by `autopath` |

---

## 6. Hands-on: CLI workflow with expected output

### 6.1 Inspect the current state

```
$ kubectl -n kube-system get deploy,svc,cm -l k8s-app=kube-dns
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/coredns   2/2     2            2           41d

NAME               TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
service/kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   41d
```

The label selector does not return the `coredns` ConfigMap on kubeadm, because it has no labels. Fetch it by name:

```
$ kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
.:53 {
    errors
    health {
       lameduck 5s
    }
    ...
}
$ kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
registry.k8s.io/coredns/coredns:v1.11.3
```

### 6.2 Deploy a debug client

```
$ kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 --restart=Never -- sleep infinity
pod/dnsutils created
$ kubectl exec dnsutils -- cat /etc/resolv.conf
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

### 6.3 Baseline: resolve Services

```
$ kubectl exec dnsutils -- nslookup kubernetes.default
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	kubernetes.default.svc.cluster.local
Address: 10.96.0.1
```

SRV record for a named port (Service `web` in `prod`, port named `http`):

```
$ kubectl exec dnsutils -- dig +short SRV _http._tcp.web.prod.svc.cluster.local
0 100 80 web.prod.svc.cluster.local.
```

Headless Service, one A record per ready endpoint:

```
$ kubectl exec dnsutils -- dig +short db-headless.prod.svc.cluster.local
10.244.1.17
10.244.2.23
10.244.3.9
```

### 6.4 Apply a change and watch it reload

```
$ kubectl -n kube-system apply -f coredns-stubdomain.yaml
configmap/coredns configured
$ kubectl -n kube-system logs -l k8s-app=kube-dns -f --tail=5
[INFO] Reloading
[INFO] plugin/reload: Running configuration SHA512 = 8f2b3c...e41a
[INFO] Reloading complete
```

Test the stub domain and the rewrite (the `answer name` keeps the owner name as requested):

```
$ kubectl exec dnsutils -- dig +noall +answer db.corp.example.com
db.corp.example.com.	30	IN	A	10.150.3.21

$ kubectl exec dnsutils -- dig +noall +answer api.internal
api.internal.		30	IN	A	10.103.44.12
```

Test the static hosts entry:

```
$ kubectl exec dnsutils -- dig +short db.legacy.example.com
10.150.20.5
```

### 6.5 Validate the Corefile before it hits the cluster

A syntax error does not take DNS down, because the reload keeps the old configuration. But it silently leaves the new one unapplied, and a **restarted** Pod with a broken Corefile will crash. Validate locally with the same image:

```
$ kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > Corefile
$ podman run --rm -v "$PWD/Corefile:/Corefile:ro" registry.k8s.io/coredns/coredns:v1.11.3 -conf /Corefile -dns.port 1053
Error during parsing: Unknown directive 'forwad'
```

A valid file starts and prints `CoreDNS-1.11.3` along with the listener. Stop it with Ctrl-C. The `kubernetes` plugin fails outside a cluster (no service account), so for a pure syntax check, temporarily comment out that block or accept the connection error as proof that parsing succeeded.

### 6.6 Roll back

```
$ kubectl -n kube-system apply -f coredns-backup.yaml
configmap/coredns configured
$ kubectl -n kube-system rollout restart deployment coredns
deployment.apps/coredns restarted
```

---

## 7. Verification and failure diagnosis

### 7.1 Systematic ladder

Work from the client outward. Each rung isolates one layer.

| # | Check | Command | Healthy result |
|---|---|---|---|
| 1 | Pod resolver config | `kubectl exec dnsutils -- cat /etc/resolv.conf` | `nameserver` = kube-dns ClusterIP |
| 2 | CoreDNS Pods running and ready | `kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide` | `1/1 Running`, no restarts piling up |
| 3 | Service has endpoints | `kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns` | Pod IPs on ports 53 and 9153 |
| 4 | Query a CoreDNS Pod directly (bypasses Service dataplane) | `kubectl exec dnsutils -- dig @<coredns-pod-ip> kubernetes.default.svc.cluster.local` | Answer. If this works but step 5 fails: kube-proxy/CNI problem |
| 5 | Query through the Service | `kubectl exec dnsutils -- dig @10.96.0.10 kubernetes.default.svc.cluster.local` | Answer |
| 6 | External resolution | `kubectl exec dnsutils -- dig example.com` | Answer. If it fails while cluster names work: `forward`/upstream |
| 7 | Logs | `kubectl -n kube-system logs -l k8s-app=kube-dns` | No `[ERROR]` or `[FATAL]` |
| 8 | Loaded config | Look for the `Running configuration SHA512` log line after your edit | Present |

### 7.2 Typical failures

| Symptom | Log / evidence | Root cause | Fix |
|---|---|---|---|
| CoreDNS in `CrashLoopBackOff` right after install | `[FATAL] plugin/loop: Loop (127.0.0.1:44632 -> :53) detected for zone "."` | Node `resolv.conf` points to `127.0.0.53` (`systemd-resolved`). CoreDNS forwards to itself | Set kubelet `resolvConf: /run/systemd/resolve/resolv.conf`, or use explicit `forward . <upstream IPs>` |
| Edit has no effect | No `Reloading` line in logs | Missing `reload` plugin; ConfigMap mounted with `subPath`; not enough time has passed; parse error | Wait ~2 min, check logs for `plugin/reload: Corefile parse error`, or `rollout restart` |
| Rewrite resolves in CoreDNS logs but clients fail | Client error such as `;; Question section mismatch` or an empty answer | Question rewritten without `answer name` | Add the answer rewrite (4.2) |
| Stub domain returns `SERVFAIL` | `[ERROR] plugin/errors: 2 db.corp.example.com. A: read udp 10.244.1.5:53921->10.150.0.10:53: i/o timeout` | NetworkPolicy/firewall blocks egress from CoreDNS Pods to the corporate DNS | Allow UDP/TCP 53 egress from `kube-system` CoreDNS to those IPs |
| Intermittent 5 s delays | Pod-side latency, CoreDNS logs clean | conntrack race on parallel A/AAAA UDP queries sharing a socket | `single-request-reopen` in Pod `dnsConfig` (glibc), NodeLocal DNSCache, or TCP |
| `NXDOMAIN` for a Service that exists | `kubectl get svc` shows it | Wrong namespace in the name; a `hosts`/`template` block without `fallthrough` shadows the name | `dig` the FQDN; review blocks that run before `kubernetes` |
| Headless Service returns no records | EndpointSlice with no ready endpoints | Pods not Ready | Fix readiness, or `publishNotReadyAddresses: true` for peer discovery |
| High CoreDNS memory, OOMKilled | Container status `OOMKilled` | `pods verified` / `autopath` in a large cluster; huge caches | Raise limits, go back to `insecure`, drop `autopath`, cap `cache` capacity |
| `plugin/kubernetes` never ready | `[INFO] plugin/ready: Still waiting on: "kubernetes"` | Cannot reach the API server, or RBAC missing `list/watch` on `endpointslices` | Check the `system:coredns` ClusterRole and connectivity to `kubernetes.default` |

### 7.3 Temporary query logging

Turn it on, reproduce, turn it off. `log` at cluster scale floods stdout and costs CPU.

```
    log . {
       class denial error
    }
```

Only negative answers and errors are logged:

```
[INFO] 10.244.2.14:51832 - 21760 "A IN db.corp.example.com.default.svc.cluster.local. udp 63 false 512" NXDOMAIN qr,aa,rd 156 0.000151s
```

The line shows the client IP:port, query ID, type, the name *after* search-path expansion, response code and latency. That is exactly what you need to spot `ndots` amplification or a failed rewrite.

### 7.4 Metrics to watch (from `:9153`)

```
$ kubectl -n kube-system port-forward deploy/coredns 9153:9153 &
$ curl -s localhost:9153/metrics | grep -E '^coredns_(dns_requests_total|dns_responses_total|cache_hits_total)' | head
coredns_cache_hits_total{server="dns://:53",type="success",view="",zones="."} 48211
coredns_cache_hits_total{server="dns://:53",type="denial",view="",zones="."} 91732
coredns_dns_requests_total{family="1",proto="udp",server="dns://:53",type="A",view="",zones="."} 173412
coredns_dns_responses_total{plugin="kubernetes",rcode="NXDOMAIN",server="dns://:53",view="",zones="."} 102233
```

| Signal | Meaning |
|---|---|
| `NXDOMAIN` share of responses high, `denial` cache hits high | Search-path amplification: consider `ndots`, `autopath` or NodeLocal DNSCache |
| `coredns_dns_responses_total{rcode="SERVFAIL"}` rising | Upstream or stub-domain problems |
| `coredns_proxy_request_duration_seconds` (`proxy_name="forward"`) p99 rising | Slow upstreams. In older CoreDNS these were `coredns_forward_*` metrics |
| `coredns_forward_healthcheck_broken_total` > 0 | All upstreams failed health checks |
| `coredns_reload_failed_total` > 0 | A Corefile edit did not parse. The old configuration is still running |

Example alert rule (Prometheus Operator):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: coredns-alerts
  namespace: kube-system
spec:
  groups:
    - name: coredns
      rules:
        - alert: CoreDNSServfailRatioHigh
          expr: |
            sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]))
              /
            sum(rate(coredns_dns_responses_total[5m]))
              > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "More than 5% of CoreDNS responses are SERVFAIL"
        - alert: CoreDNSReloadFailed
          expr: |
            increase(coredns_reload_failed_total[15m]) > 0
          labels:
            severity: critical
          annotations:
            summary: "A CoreDNS Corefile change failed to load; the previous configuration is still active"
```

---

## 8. Exam-style tasks to practice

1. Make `*.partner.example.net` resolve through `192.0.2.53` without changing any other resolution. Verify from a Pod. *(Stub server block, section 4.1.)*
2. Make `payments.internal` resolve to the `payments` Service in namespace `finance`, with the answer carrying the requested name. *(Section 4.2.)*
3. CoreDNS is in CrashLoopBackOff after a node OS upgrade. Find and fix the cause. *(`loop` plugin, section 7.2.)*
4. Add a static A record for `nas.lab.local` → `10.0.50.4` that survives CoreDNS restarts and does not affect other names. *(`hosts` with zone and `fallthrough`.)*
5. A team's Pod makes thousands of external lookups per second and CoreDNS CPU is high. Reduce the load without touching the Corefile. *(Pod `dnsConfig` with `ndots`.)*
6. After editing the ConfigMap, prove that the running CoreDNS picked up the new configuration. *(`Reloading` log line and SHA512, a behavioral `dig` test, `coredns_reload_failed_total`.)*

Time-saving habits for the exam:
- `kubectl -n kube-system edit cm coredns` is fastest. Keep the indentation of the `Corefile: |` block consistent.
- If you are unsure whether the reload happened, `kubectl -n kube-system rollout restart deploy coredns` removes the doubt and costs a few seconds.
- Always keep a `dnsutils` Pod running for the whole session.

---

## Referencias

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes — Customizing DNS Service: https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Kubernetes — Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Kubernetes — DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes — Using NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Kubernetes — Autoscale the DNS Service: https://kubernetes.io/docs/tasks/administer-cluster/dns-horizontal-autoscaling/
- Kubernetes DNS specification: https://github.com/kubernetes/dns/blob/master/docs/specification.md
- CoreDNS Manual: https://coredns.io/manual/toc/
- CoreDNS plugin execution order (`plugin.cfg`): https://github.com/coredns/coredns/blob/master/plugin.cfg
- CoreDNS plugin `kubernetes`: https://coredns.io/plugins/kubernetes/
- CoreDNS plugin `forward`: https://coredns.io/plugins/forward/
- CoreDNS plugin `rewrite`: https://coredns.io/plugins/rewrite/
- CoreDNS plugin `hosts`: https://coredns.io/plugins/hosts/
- CoreDNS plugin `template`: https://coredns.io/plugins/template/
- CoreDNS plugin `cache`: https://coredns.io/plugins/cache/
- CoreDNS plugin `autopath`: https://coredns.io/plugins/autopath/
- CoreDNS plugin `reload`: https://coredns.io/plugins/reload/
- CoreDNS plugin `loop` (troubleshooting loops): https://coredns.io/plugins/loop/
- CoreDNS plugin `k8s_external`: https://coredns.io/plugins/k8s_external/
- CoreDNS plugin `import`: https://coredns.io/plugins/import/
- CoreDNS plugin `prometheus` (metrics): https://coredns.io/plugins/metrics/
- Azure AKS — Customize CoreDNS: https://learn.microsoft.com/en-us/azure/aks/coredns-custom
- Amazon EKS — Manage CoreDNS: https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html