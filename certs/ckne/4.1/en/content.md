# 4.1 Securing Traffic with Network Policies

> **Exam weight: 6.25%.** This domain tests whether you can reason exactly about how Kubernetes decides that a packet is allowed, write policies that are right the first time, and diagnose a policy that silently drops traffic. The API is small; the semantics are where people fail.

---

## 1. Motivation: the flat network is a production liability

The Kubernetes network model requires that **every Pod can reach every other Pod without NAT**, across nodes and namespaces. This makes service discovery and routing simple. It also means that, without policies, the cluster is a single flat trust zone:

- A compromised `frontend` Pod can open TCP connections to the `postgres` Pod in another namespace, to the kubelet API on every node (`:10250`), to the cloud metadata endpoint (`169.254.169.254`), and to any external host.
- Multi-tenancy by namespace separates names and RBAC. **It does not isolate the network.** A namespace does not act as a network boundary.
- Lateral movement is the main way a single-container breach becomes a cluster breach. Most real incidents follow the path "RCE in a web pod → scan the pod CIDR → find an unauthenticated internal service".

NetworkPolicy is the Kubernetes-native way to put **L3/L4 microsegmentation** on that flat network. It lets you state which Pods may talk to which, on which ports, in which direction. The CNI plugin then enforces it on every node.

Three architectural facts drive everything else in this topic:

1. **The API is defined by Kubernetes, but the CNI enforces it.** The API server accepts a `NetworkPolicy` object whether or not anything enforces it. With a CNI that does not implement policies (plain Flannel, for example), your policies are silent no-ops.
2. **The model is allow-list and additive.** No `deny` action exists. Policies can only add allowed flows to a Pod that is already isolated.
3. **Policies are namespaced and owned by app teams.** Cluster-wide guardrails that a namespace owner cannot override need a different API: `AdminNetworkPolicy`, or CNI-specific CRDs.

---

## 2. The isolation model: how a packet is judged

### 2.1 Default allow, then isolation per direction

Each Pod has two independent isolation states, one for **ingress** and one for **egress**:

| State | Condition | Effect |
|---|---|---|
| Non-isolated for ingress | No NetworkPolicy with `Ingress` in `policyTypes` selects the Pod | All inbound connections allowed |
| Isolated for ingress | At least one such policy selects the Pod | Only connections allowed by the **union** of all selecting ingress rules, plus traffic from the Pod's own node |
| Non-isolated for egress | No NetworkPolicy with `Egress` in `policyTypes` selects the Pod | All outbound connections allowed |
| Isolated for egress | At least one such policy selects the Pod | Only connections allowed by the **union** of all selecting egress rules |

Consequences you must internalize:

- **Selecting a Pod is what isolates it**, not writing a rule. A policy with `podSelector: {}` and no `ingress` rules isolates every Pod in the namespace and allows nothing. That is the "default deny" pattern.
- **Policies are additive (OR).** If policy A allows `frontend` and policy B allows `monitoring`, both are allowed. No policy can subtract what another one allows. Order does not matter, and no priorities exist.
- **Both ends must agree.** For a connection from Pod X to Pod Y, X's egress policy (if X is egress-isolated) *and* Y's ingress policy (if Y is ingress-isolated) must both allow it.
- **Policies are connection-oriented.** Reply packets of an allowed connection are allowed implicitly (conntrack). You never write a "return traffic" rule.
- **Traffic from the Pod's node is always allowed into the Pod.** This is why kubelet liveness/readiness probes keep working under a default-deny ingress policy.

### 2.2 How `policyTypes` is inferred

If you omit `policyTypes`, the API server defaults it:

- `Ingress` is always included.
- `Egress` is included only if the policy has an `egress` section.

This is a classic trap. A policy meant to be "egress default deny" that has no `egress:` key and no explicit `policyTypes: [Egress]` becomes an **ingress** default deny. Always set `policyTypes` explicitly.

---

## 3. Anatomy of a NetworkPolicy

A complete manifest that uses every field of the `networking.k8s.io/v1` API:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-full-anatomy
  namespace: shop
spec:
  # WHICH Pods in THIS namespace the policy applies to (the "subject").
  # {} = every Pod in the namespace.
  podSelector:
    matchLabels:
      app: api
      tier: backend
  # WHICH directions this policy isolates. Always explicit.
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Rule 1: frontend Pods in the same namespace, on the named container port "http".
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: http
    # Rule 2: Prometheus from the monitoring namespace (AND semantics, one element).
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
  egress:
    # Rule A: PostgreSQL in the data namespace.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - postgres
                  - pgbouncer
      ports:
        - protocol: TCP
          port: 5432
    # Rule B: an external partner network, minus one blocked subnet, on a port range.
    - to:
        - ipBlock:
            cidr: 203.0.113.0/24
            except:
              - 203.0.113.128/25
      ports:
        - protocol: TCP
          port: 30000
          endPort: 30100
    # Rule C: cluster DNS (UDP and TCP, TCP is needed for truncated responses).
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

### 3.1 Field reference

| Field | Semantics | Production notes |
|---|---|---|
| `spec.podSelector` | Label selector over Pods **in the policy's namespace** | `{}` selects all Pods. A policy cannot select Pods in another namespace as its subject |
| `spec.policyTypes` | `Ingress`, `Egress`, or both | Defaulting rules in §2.2. Always set it explicitly |
| `ingress[].from[]` / `egress[].to[]` | List of peers, **OR** between elements | An empty or omitted `from`/`to` means "all peers" |
| `podSelector` (in a peer) | Pods in the **policy's** namespace, unless combined with `namespaceSelector` | |
| `namespaceSelector` | Namespaces selected by label; alone = all Pods in them | `{}` = all namespaces |
| `namespaceSelector` + `podSelector` in the **same element** | Pods matching the pod selector **inside** namespaces matching the namespace selector (AND) | The most error-prone construct, see §4 |
| `ipBlock.cidr` / `except` | CIDR peer, with carve-outs | Meant for cluster-external IPs. Behavior for Pod IPs is implementation-defined |
| `ports[].protocol` | `TCP` (default), `UDP`, `SCTP` | |
| `ports[].port` | Number or **named container port** | A named port resolves per Pod, so different Pods can map `http` to different numbers |
| `ports[].endPort` | Inclusive upper bound of a range | Requires a numeric `port`. GA since v1.25. A CNI that does not support it may ignore the range |
| Omitted `ports` | All ports and protocols | |

### 3.2 The `kubernetes.io/metadata.name` label

Since Kubernetes v1.22 (GA), the control plane sets the immutable label `kubernetes.io/metadata.name=<namespace-name>` on every namespace. Use it to select a namespace **by name**, instead of relying on custom labels that anyone with namespace `patch` rights could add to their own namespace to become "trusted".

```
$ kubectl get ns monitoring --show-labels
NAME         STATUS   AGE   LABELS
monitoring   Active   41d   kubernetes.io/metadata.name=monitoring
```

> **Security note:** a `namespaceSelector` such as `team: platform` is only as trustworthy as the RBAC that controls who can label namespaces. The `metadata.name` label cannot be forged, because it is reset to the real name.

---

## 4. Peer semantics: AND vs OR (the top exam trap)

The two policies below differ only in a YAML dash, and they mean very different things.

**AND: one peer element with two selectors.** "Pods labeled `app=prometheus` in the `monitoring` namespace":

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-and
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app: prometheus
```

**OR: two peer elements.** "Every Pod in the `monitoring` namespace, OR Pods labeled `app=prometheus` in the `shop` namespace":

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-or
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
        - podSelector:
            matchLabels:
              app: prometheus
```

`kubectl describe` shows the difference clearly. Use it as a sanity check on every policy you write in the exam:

```
$ kubectl -n shop describe networkpolicy allow-prometheus-and
Name:         allow-prometheus-and
Namespace:    shop
Created on:   2026-09-30 10:12:03 +0000 UTC
Labels:       <none>
Annotations:  <none>
Spec:
  PodSelector:     app=api
  Allowing ingress traffic:
    To Port: <any> (traffic allowed to all ports)
    From:
      NamespaceSelector: kubernetes.io/metadata.name=monitoring
      PodSelector: app=prometheus
  Not affecting egress traffic
  Policy Types: Ingress

$ kubectl -n shop describe networkpolicy allow-prometheus-or
...
  Allowing ingress traffic:
    To Port: <any> (traffic allowed to all ports)
    From:
      NamespaceSelector: kubernetes.io/metadata.name=monitoring
    ----------
    From:
      PodSelector: app=prometheus
...
```

The `----------` separator means OR. Similar pitfalls:

| YAML | Meaning |
|---|---|
| `ingress: []` or no `ingress` key, with `Ingress` in `policyTypes` | Deny all ingress |
| `ingress: [{}]` (one empty rule) | Allow all ingress |
| `from: []` or `from` omitted inside a rule | Any source (only `ports` restrict it) |
| `- podSelector: {}` | All Pods in the **policy's namespace** |
| `- namespaceSelector: {}` | All Pods in **all namespaces** (not external IPs) |
| `- namespaceSelector: {}` + `podSelector: {matchLabels: {app: x}}` in one element | Pods labeled `app=x` in any namespace |

---

## 5. A production baseline per namespace

Most platform teams ship a standard set of policies into every tenant namespace, usually through a namespace provisioning controller, Kyverno `generate` rules, or a GitOps template. The sequence below is the reference pattern.

### 5.1 Default deny in both directions

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: shop
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

When you apply this, **everything breaks, including DNS**. That is the intended starting point. The next policies add back only what is needed.

### 5.2 Allow DNS egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: shop
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
```

Check what DNS actually is in your cluster before relying on this:

- CoreDNS Pods usually keep the legacy label `k8s-app=kube-dns`. Verify with `kubectl -n kube-system get pods --show-labels`.
- If **NodeLocal DNSCache** is deployed, Pods query a link-local IP (commonly `169.254.20.10`) served by a hostNetwork DaemonSet. Pod selectors cannot match that. You need an `ipBlock` for the link-local address, and the node-local agent itself runs outside Pod policy.
- CoreDNS listens on container port `53` in most distributions. The rule matches the **Pod** port after the Service is translated (see §6.1), so a CoreDNS that listens on `1053` behind a Service port `53` needs port `1053` in the rule.

### 5.3 Allow traffic within the namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: shop
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

This is a pragmatic compromise, because the namespace becomes the trust boundary. Mature teams replace it with per-application policies (§5.6).

### 5.4 Allow the ingress controller to reach the web tier

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress-controller
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
```

If your Gateway or ingress controller runs with `hostNetwork: true`, its traffic comes from the **node IP**, not from a Pod. Pod selectors do not match it. Enforcement for hostNetwork sources is implementation-specific (§6.3).

### 5.5 Allow Prometheus scraping across namespaces

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: shop
spec:
  podSelector:
    matchLabels:
      metrics: enabled
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: metrics
```

The named port `metrics` resolves separately on each selected Pod, so one policy covers workloads that expose metrics on different numbers.

### 5.6 Per-application least privilege: a three-tier app

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-least-privilege
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: data
          podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
```

The database side must allow the connection too, because `data` has its own default deny:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-from-api
  namespace: data
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: shop
          podSelector:
            matchLabels:
              app: api
      ports:
        - protocol: TCP
          port: 5432
```

### 5.7 Egress to the Kubernetes API server

Operators, controllers and anything that uses a ServiceAccount token need to reach the API server. The `kubernetes` Service in `default` has a ClusterIP, but enforcement happens after DNAT (§6.1). You must allow the **real endpoints**:

```
$ kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes
NAME         ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
kubernetes   IPv4          6443    10.0.0.11,10.0.0.12,10.0.0.13      212d
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: shop
spec:
  podSelector:
    matchLabels:
      needs-apiserver: "true"
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.11/32
        - ipBlock:
            cidr: 10.0.0.12/32
        - ipBlock:
            cidr: 10.0.0.13/32
      ports:
        - protocol: TCP
          port: 6443
```

This is brittle, because control-plane IPs change during upgrades or when you move to a managed control plane. Cilium solves it with the `kube-apiserver` entity (`toEntities: [kube-apiserver]`). Managed clusters often put the API server behind a VIP that can also be the one seen after translation. Check with your CNI.

### 5.8 Egress to the internet while blocking internal ranges and cloud metadata

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internet-egress-only
  namespace: shop
spec:
  podSelector:
    matchLabels:
      egress: internet
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 443
```

Because policies are additive, this `except` only narrows **this rule**. If another policy selecting the same Pod allows `10.0.0.0/8`, that traffic is still allowed. For a real "no Pod may ever reach metadata" guarantee, you need a cluster-scoped deny (§7, §8).

---

## 6. Interaction with Services, NAT and nodes

This is where policies that look correct fail in production.

### 6.1 Policies see Pod IPs and Pod ports, not Services

kube-proxy (iptables/IPVS/nftables) or an eBPF replacement translates `ClusterIP:port` to `PodIP:targetPort` **before** the policy is evaluated at the destination, and in practice also for egress. Therefore:

- You cannot select a Service in a NetworkPolicy. You select the **Pods behind it**.
- `ports` must list the **`targetPort`** (container port), not the Service `port`. Service `80 → targetPort 8080` means the rule needs port `8080`.
- An `ipBlock` with a ClusterIP is not a reliable way to allow a Service.

### 6.2 SNAT at the edge breaks source-IP policies

| Traffic path | Source IP seen by the Pod | Can `ipBlock` match the real client? |
|---|---|---|
| `LoadBalancer` / `NodePort`, `externalTrafficPolicy: Cluster` | Node IP (SNAT) | **No** |
| `LoadBalancer` / `NodePort`, `externalTrafficPolicy: Local` | Real client IP | Yes, if the LB preserves it |
| L7 proxy (Ingress/Gateway) in front | Proxy Pod IP | No: match the proxy Pod, and filter clients at the proxy |
| Pod egress to the internet | Pod IP at the source node; node or NAT-GW IP outside | Policy is evaluated on the Pod IP, so it works |

The Kubernetes documentation says explicitly that whether `ipBlock` applies before or after NAT for ingress through load balancers is implementation-dependent. Test on your stack.

### 6.3 Nodes, hostNetwork and probes

- Traffic **from the Pod's own node** is always allowed into an ingress-isolated Pod. This is why kubelet probes work.
- Traffic from **other nodes**, and from `hostNetwork: true` Pods (which use the node IP), is not reliably matched by Pod selectors. Implementations differ. Cilium, for example, classifies it as the `host` / `remote-node` identities.
- **NetworkPolicy does not protect nodes.** It says nothing about traffic to the kubelet `:10250`, etcd or SSH. Use CNI host policies (Cilium `CiliumClusterwideNetworkPolicy` with `nodeSelector`, Calico `HostEndpoint`), or cloud security groups.

### 6.4 The Pod startup race

The Kubernetes docs warn that a policy may not be enforced yet when a Pod first starts, because the CNI programs rules asynchronously after the Pod gets its IP. Two consequences:

- A new Pod can briefly have **more** access than the policy allows (the ingress deny window). This matters for high-assurance setups. Some CNIs (Calico, Cilium) can be set to default-deny newly created endpoints until policy is computed.
- A new Pod can briefly have **less** access than the policy allows. An init container that runs `curl` to a dependency can fail on the first attempt. Make init logic retry.

---

## 7. Cluster-scoped guardrails: AdminNetworkPolicy and BaselineAdminNetworkPolicy

Namespaced NetworkPolicy cannot express "the security team denies X and no namespace owner may override it", because it has no deny and no priority. SIG Network's **Network Policy API** subproject defines cluster-scoped resources in the `policy.networking.k8s.io` API group:

| Resource | Scope | Actions | Evaluation order |
|---|---|---|---|
| `AdminNetworkPolicy` (ANP) | Cluster | `Allow`, `Deny`, `Pass` | **First**, by `priority` (lower number = higher precedence) |
| `NetworkPolicy` | Namespace | Implicit allow | Second, including anything passed down by an ANP `Pass` |
| `BaselineAdminNetworkPolicy` (BANP) | Cluster, singleton named `default` | `Allow`, `Deny` | **Last**: defaults that apply when nothing above decided |

- `Deny` in an ANP cannot be overridden by any NetworkPolicy.
- `Allow` in an ANP cannot be restricted by a NetworkPolicy.
- `Pass` skips the remaining ANPs and hands the decision to the namespace's NetworkPolicies, then the BANP.

These APIs are **alpha (`v1alpha1`)** and installed as CRDs. Implementations include OVN-Kubernetes, Antrea, Calico, and the reference `kube-network-policies` project. The API is still evolving: the subproject is consolidating ANP and BANP into a single tiered cluster policy resource in a newer API version. Check the project site for the version your CNI supports before you standardize on it.

### 7.1 ANP: block the metadata endpoint and pin DNS, cluster-wide

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: platform-guardrails
spec:
  priority: 10
  subject:
    namespaces: {}
  egress:
    - name: deny-cloud-metadata
      action: Deny
      to:
        - networks:
            - 169.254.169.254/32
    - name: allow-cluster-dns
      action: Allow
      to:
        - pods:
            namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: kube-system
            podSelector:
              matchLabels:
                k8s-app: kube-dns
      ports:
        - portNumber:
            protocol: UDP
            port: 53
        - portNumber:
            protocol: TCP
            port: 53
```

### 7.2 ANP: isolate tenants, but let the monitoring namespace through

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: tenant-isolation
spec:
  priority: 20
  subject:
    namespaces:
      matchExpressions:
        - key: tenant
          operator: Exists
  ingress:
    - name: allow-monitoring
      action: Allow
      from:
        - namespaces:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
    - name: pass-same-tenant
      action: Pass
      from:
        - namespaces:
            sameLabels:
              - tenant
    - name: deny-other-tenants
      action: Deny
      from:
        - namespaces:
            matchExpressions:
              - key: tenant
                operator: Exists
```

> `sameLabels` was part of `v1alpha1` in early drafts and is being reworked, so support varies between implementations and releases. Check your CNI's conformance notes before you rely on it. The `Allow`/`Pass`/`Deny` structure is the concept to learn.

### 7.3 BANP: default deny as a cluster baseline

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: BaselineAdminNetworkPolicy
metadata:
  name: default
spec:
  subject:
    namespaces:
      matchExpressions:
        - key: tenant
          operator: Exists
  ingress:
    - name: default-deny-ingress
      action: Deny
      from:
        - namespaces: {}
```

Unlike a per-namespace `default-deny-all` NetworkPolicy, this baseline exists **even if the tenant forgets or deletes its own**. Tenants can still open specific flows with ordinary NetworkPolicies, because those are evaluated before the baseline.

---

## 8. Beyond the core API: CNI-specific policy engines

Standard NetworkPolicy is deliberately minimal. Production platforms usually add a CNI-specific policy layer.

### 8.1 Capability comparison

| Capability | K8s NetworkPolicy | AdminNetworkPolicy (alpha) | Cilium CNP / CCNP | Calico NP / GNP |
|---|---|---|---|---|
| Scope | Namespace | Cluster | Namespace / cluster | Namespace / cluster |
| Explicit deny | No | Yes | Yes (`ingressDeny`/`egressDeny`) | Yes (`action: Deny`) |
| Priority / ordering | No | `priority` | Deny wins over allow | `order` + tiers |
| L7 (HTTP method/path, gRPC, Kafka) | No | No | Yes (Envoy proxy) | Yes, with application-layer policy (Istio/Envoy integration) |
| FQDN egress (`api.stripe.com`) | No | Being designed (`domainNames`) | Yes (`toFQDNs`, DNS proxy) | Yes (`domains`, availability depends on edition/version) |
| Select by ServiceAccount | No | No | Yes (via labels/identity) | Yes (`serviceAccountSelector`) |
| Node/host protection | No | No | Yes (host policies) | Yes (`HostEndpoint`) |
| Policy logging | No | No | Hubble flow logs | `action: Log`, flow logs |
| Portability | Every enforcing CNI | Growing | Cilium only | Calico only |

### 8.2 Dataplane trade-offs

| Dataplane | Example CNIs | Policy mechanism | Trade-offs |
|---|---|---|---|
| iptables + ipset | Calico (iptables mode), kube-router, Weave (historic) | Per-Pod chains, ipsets for selectors | Mature, debuggable with `iptables-save`. Rule updates grow in cost as policy count and churn grow |
| nftables | Calico (nft mode), kube-network-policies | Sets and maps | Atomic updates, better scaling than iptables |
| eBPF | Cilium, Calico eBPF | Identity-based policy maps per endpoint | O(1) lookups, identity instead of IP, rich observability. Needs a recent kernel, and debugging needs CNI tooling |
| OVS / OpenFlow | Antrea, OVN-Kubernetes | Flow tables | Strong ANP support. Debugging uses OpenFlow tooling |

**Identity vs IP:** iptables-based implementations turn label selectors into sets of IPs, so every Pod churn event updates the sets on every node. Cilium gives each unique label set a numeric **security identity** and carries it with the packet (in the tunnel header, or resolved through an ipcache). Policy lookups then do not depend on the number of Pod IPs.

### 8.3 Cilium: L7 HTTP policy

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-readonly
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/v1/products.*"
              - method: GET
                path: "/healthz"
```

A request that does not match gets an HTTP **403 `Access denied`** from the Envoy proxy, not a TCP timeout. That is how you tell L7 denials from L3/L4 ones.

### 8.4 Cilium: FQDN-based egress

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-egress-fqdn
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: payments-api
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*.stripe.com"
    - toFQDNs:
        - matchName: api.stripe.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

The DNS rule is **mandatory**. Cilium learns the IPs behind `api.stripe.com` by sending DNS responses through its DNS proxy. Without the `dns` rule, the FQDN rule never gets IPs and all traffic to it is dropped. It also does not see resolutions done through a different resolver, such as a hard-coded `8.8.8.8` or DNS-over-HTTPS.

### 8.5 Calico: a security tier with deny and log

```yaml
apiVersion: projectcalico.org/v3
kind: Tier
metadata:
  name: security
spec:
  order: 100
```

```yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: security.block-metadata
spec:
  tier: security
  order: 10
  selector: all()
  types:
    - Egress
  egress:
    - action: Log
      destination:
        nets:
          - 169.254.169.254/32
    - action: Deny
      destination:
        nets:
          - 169.254.169.254/32
    - action: Pass
```

Calico evaluates tiers in order. Kubernetes NetworkPolicies live in the `default` tier (order 1000 for the k8s-derived policies). The final `Pass` is essential: any endpoint selected by a policy in a tier that no rule matches **is denied at the end of that tier**. Without `Pass`, this guardrail would block all egress in the cluster. Tiers in Calico Open Source and the `<tier>.` name prefix requirement depend on the Calico version. Check the docs for yours.

---

## 9. Hands-on lab: build and verify default-deny segmentation

### 9.1 Confirm that your CNI enforces policy

```
$ kubectl get pods -n kube-system -o wide | grep -Ei 'cilium|calico|antrea|kindnet|flannel'
cilium-4xk9p                       1/1     Running   0     3d    172.18.0.3   worker1
cilium-operator-6c9d7b8f5-lq2vt    1/1     Running   0     3d    172.18.0.2   control-plane
```

Flannel alone does **not** enforce NetworkPolicy (Canal = Flannel + Calico policy does). Recent `kind` releases ship a kindnet with policy support. Older ones do not. Never assume: test with the deny check in §9.3.

### 9.2 Deploy a test topology

```
$ kubectl create namespace shop
namespace/shop created
$ kubectl create namespace data
namespace/data created

$ kubectl -n shop run frontend --image=nicolaka/netshoot --labels=app=frontend -- sleep infinity
pod/frontend created
$ kubectl -n shop run intruder --image=nicolaka/netshoot --labels=app=intruder -- sleep infinity
pod/intruder created
$ kubectl -n shop run api --image=registry.k8s.io/e2e-test-images/agnhost:2.47 --labels=app=api --port=8080 -- netexec --http-port=8080
pod/api created
$ kubectl -n shop expose pod api --port=80 --target-port=8080
service/api exposed

$ kubectl -n shop get pods -o wide
NAME       READY   STATUS    RESTARTS   AGE   IP            NODE
api        1/1     Running   0          22s   10.244.1.17   worker1
frontend   1/1     Running   0          31s   10.244.2.9    worker2
intruder   1/1     Running   0          27s   10.244.1.18   worker1
```

Baseline, before any policy (everything is reachable):

```
$ kubectl -n shop exec intruder -- curl -s -m 2 http://api/hostname
api
$ kubectl -n shop exec frontend -- curl -s -m 2 http://api/hostname
api
```

### 9.3 Apply default deny and watch it break

```
$ kubectl apply -f default-deny-all.yaml
networkpolicy.networking.k8s.io/default-deny-all created

$ kubectl -n shop exec frontend -- curl -s -m 2 http://api/hostname
curl: (28) Resolving timed out after 2000 milliseconds
command terminated with exit code 28
```

Note the error: **DNS resolution** fails first, because egress to CoreDNS is now denied. Add DNS back (§5.2):

```
$ kubectl apply -f allow-dns-egress.yaml
networkpolicy.networking.k8s.io/allow-dns-egress created

$ kubectl -n shop exec frontend -- curl -s -m 2 http://api/hostname
curl: (28) Connection timed out after 2001 milliseconds
command terminated with exit code 28
```

DNS works now. The TCP connection times out, because `frontend` egress and `api` ingress are both denied.

### 9.4 Open the flow, both sides

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-egress-to-api
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: api
      ports:
        - protocol: TCP
          port: 8080
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-ingress-from-frontend
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

```
$ kubectl apply -f frontend-egress-to-api.yaml -f api-ingress-from-frontend.yaml
networkpolicy.networking.k8s.io/frontend-egress-to-api created
networkpolicy.networking.k8s.io/api-ingress-from-frontend created

$ kubectl -n shop exec frontend -- curl -s -m 2 http://api/hostname
api
$ kubectl -n shop exec intruder -- curl -s -m 2 http://api/hostname
curl: (28) Connection timed out after 2002 milliseconds
command terminated with exit code 28
```

Note that the rules say port `8080` (the `targetPort`), while the client called Service port `80`. That confirms §6.1.

### 9.5 Verify the full policy set

```
$ kubectl -n shop get networkpolicy
NAME                        POD-SELECTOR   AGE
allow-dns-egress            <none>         4m
api-ingress-from-frontend   app=api        1m
default-deny-all            <none>         5m
frontend-egress-to-api      app=frontend   1m
```

`<none>` in `POD-SELECTOR` means `{}`: all Pods in the namespace.

A connectivity matrix is the best proof you can give. Script it:

```
$ for src in frontend intruder; do
    printf '%-10s -> api:8080  ' "$src"
    kubectl -n shop exec "$src" -- curl -s -o /dev/null -w '%{http_code}\n' -m 2 http://api/hostname \
      || echo "BLOCKED"
  done
frontend   -> api:8080  200
intruder   -> api:8080  000
BLOCKED
```

---

## 10. Troubleshooting guide

### 10.1 Symptom → cause table

| Symptom | Likely cause | Check |
|---|---|---|
| Policies have no effect at all | CNI does not enforce NetworkPolicy | §9.1. Apply a default deny and test |
| `Could not resolve host` / resolving timeout | Egress isolated without a DNS rule, or wrong DNS labels, or NodeLocal DNSCache | `kubectl -n kube-system get pods -l k8s-app=kube-dns`, `cat /etc/resolv.conf` in the Pod |
| Timeout (not refused) | Packet dropped by policy | Timeout = drop. `Connection refused` means the packet arrived and nothing listens |
| Works for Service port, fails after "fix" | Rule uses the Service `port` instead of `targetPort` | `kubectl get svc -o yaml`, compare `targetPort` |
| Cross-namespace access denied despite allow | `namespaceSelector` label missing on the namespace, or OR/AND confusion | `kubectl get ns --show-labels`, `kubectl describe netpol` |
| Allowed from everywhere unexpectedly | Separate peer elements (OR), or an empty `from` | `describe` shows `----------` separators |
| Egress deny policy only denies ingress | `policyTypes` omitted and no `egress` key | `kubectl get netpol -o yaml`: look at `policyTypes` |
| `ipBlock` for a client IP never matches | SNAT at the LB/NodePort | Set `externalTrafficPolicy: Local`, or filter at the proxy |
| Named port rule does not match | Container does not declare `ports[].name`, or the name differs | `kubectl get pod -o jsonpath='{.spec.containers[*].ports}'` |
| `endPort` range ignored | CNI does not implement `endPort` | CNI docs. Test the edges of the range |
| Operator cannot reach the API server | Egress deny without an allow for the post-DNAT API endpoints | §5.7 |
| Intermittent failures at Pod start | Policy programmed after the container started | Add retries to init containers. Check the CNI's endpoint readiness |
| L7 request gets `403 Access denied` | Cilium L7 rule does not match method/path | `hubble observe --type l7` |

### 10.2 Methodology

1. **Establish the facts.** Source Pod IP and labels, destination Pod IP, labels and **actual listening port**, and the namespace labels of both.

   ```
   $ kubectl -n shop get pod api -o wide --show-labels
   NAME   READY   STATUS    RESTARTS   AGE   IP            NODE      LABELS
   api    1/1     Running   0          9m    10.244.1.17   worker1   app=api
   ```

2. **List every policy that selects each end** (both directions). No built-in command does this. With `jq` you can approximate it for `matchLabels` selectors:

   ```
   $ kubectl -n shop get netpol -o json | jq -r '
       .items[] | select(
         (.spec.podSelector.matchLabels // {}) as $s
         | ($s | length == 0) or ($s | to_entries | all(.key == "app" and .value == "api"))
       ) | "\(.metadata.name)\t\(.spec.policyTypes | join(","))"'
   api-ingress-from-frontend	Ingress
   allow-dns-egress	Egress
   default-deny-all	Ingress,Egress
   ```

3. **Test from the source, bypassing DNS and the Service**, to isolate the layer:

   ```
   $ kubectl -n shop exec frontend -- nc -zv -w 2 10.244.1.17 8080
   Connection to 10.244.1.17 8080 port [tcp/http-alt] succeeded!
   ```

4. **Ask the dataplane** what it decided.

   **Cilium / Hubble:**

   ```
   $ hubble observe --namespace shop --verdict DROPPED --last 5
   Sep 30 10:21:44.120: shop/intruder:38412 (ID:21453) <> shop/api:8080 (ID:40112) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
   Sep 30 10:21:44.120: shop/intruder:38412 (ID:21453) <> shop/api:8080 (ID:40112) Policy denied DROPPED (TCP Flags: SYN)
   ```

   ```
   $ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
   ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])      IPv4          STATUS
              ENFORCEMENT        ENFORCEMENT
   1287       Enabled            Enabled           40112      k8s:app=api                      10.244.1.17   ready
                                                              k8s:io.kubernetes.pod.namespace=shop
   ```

   `policy-verdict:none INGRESS DENIED` means no rule allowed it: a missing allow, not an explicit deny.

   **Calico (iptables mode):**

   ```
   $ calicoctl get networkpolicy -n shop -o wide
   NAMESPACE   NAME                             ORDER   SELECTOR
   shop        knp.default.default-deny-all     1000    projectcalico.org/orchestrator == 'k8s'
   ...
   $ sudo iptables-save -c | grep -E 'cali-(pi|po)-' | head
   ```

   The packet counters on the `cali-pi-*` (policy ingress) chains show which policy is being hit.

   **Antrea:** `antctl` inside the agent, `antctl get networkpolicy -S <pod> -n shop`. It lists the policies applied to a Pod, which answers step 2 directly.

5. **Change one thing and re-test.** Temporarily add a broad allow (`ingress: [{}]` on the destination). If it works then, the destination ingress was the problem. If not, look at the source egress.

---

## 11. Exam-oriented checklist

- Always write `policyTypes` explicitly.
- A default deny with egress **must** come with a DNS allow (UDP **and** TCP 53) toward the real DNS Pods.
- Select namespaces by name with `kubernetes.io/metadata.name`.
- One dash = AND. Two dashes = OR. Check with `kubectl describe networkpolicy`.
- Rules match the **Pod port** (`targetPort`), never the Service port.
- A timeout means dropped by policy. `Connection refused` means the packet arrived at a closed port.
- Both ends need an allow when both are isolated.
- NetworkPolicy has no deny, no priority, no L7, no FQDN, no node protection, no logging. Know which tool covers each (ANP/BANP, Cilium, Calico).
- Use `kubectl run` with a `netshoot`/`busybox` image and `curl -m 2` / `nc -zv -w 2` for fast tests. Always set a timeout so you do not wait for defaults.

---

## Referencias

- CNCF / Linux Foundation, Certified Kubernetes Network Engineer (CKNE): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes documentation, Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes documentation, Declare Network Policy (task): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Kubernetes API reference, NetworkPolicy v1: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Kubernetes documentation, Well-Known Labels (`kubernetes.io/metadata.name`): https://kubernetes.io/docs/reference/labels-annotations-taints/
- Kubernetes documentation, Service `externalTrafficPolicy` and source IP: https://kubernetes.io/docs/tutorials/services/source-ip/
- Kubernetes documentation, Using NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- SIG Network Policy API (AdminNetworkPolicy / BaselineAdminNetworkPolicy): https://network-policy-api.sigs.k8s.io/
- Network Policy API reference: https://network-policy-api.sigs.k8s.io/reference/spec/
- Cilium documentation, Network Policy: https://docs.cilium.io/en/stable/security/policy/
- Cilium documentation, Layer 7 policy examples: https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- Cilium documentation, DNS-based policies (`toFQDNs`): https://docs.cilium.io/en/stable/security/policy/language/#dns-based
- Cilium documentation, Hubble observability: https://docs.cilium.io/en/stable/observability/hubble/
- Calico documentation, Kubernetes network policy: https://docs.tigera.io/calico/latest/network-policy/get-started/kubernetes-policy/kubernetes-network-policy
- Calico documentation, Global network policy: https://docs.tigera.io/calico/latest/reference/resources/globalnetworkpolicy
- Calico documentation, Policy tiers: https://docs.tigera.io/calico/latest/network-policy/policy-tiers/tiered-policy
- Antrea documentation, Antrea Network Policy and AdminNetworkPolicy: https://antrea.io/docs/main/docs/antrea-network-policy/
- kube-network-policies (SIG Network reference implementation): https://github.com/kubernetes-sigs/kube-network-policies