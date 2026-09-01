# 5.1 Securing Workloads with Cilium

> **Domain weight: 20%** — the single heaviest block of the CCA. Everything here assumes you already know that Cilium's datapath is eBPF at the tc/socket layer, and builds from there toward the question the exam and production both ask: *how do you express, enforce, verify and debug a security posture for workloads whose IP addresses are meaningless?*

---

## 1. The architectural problem: why IP-based security collapsed

### 1.1 The churn argument

A traditional firewall — iptables, a security group, a hardware ACL — is a function of the 5-tuple. Its atomic unit of identity is the IP address. That model rests on an assumption that held for thirty years and stopped holding around 2015: **an IP address is a stable, long-lived, meaningful name for a workload.**

In a Kubernetes cluster it is none of those things:

| Property | Bare-metal / VM era | Kubernetes |
|---|---|---|
| Address lifetime | months–years | seconds–hours (Pod IPs are recycled from the node CIDR on every reschedule) |
| Address↔workload binding | 1:1, administratively assigned | ephemeral, assigned by IPAM at admission |
| Rate of change | change-managed, ticketed | continuous (HPA, rolling updates, spot preemption, node drain) |
| Reuse | rare, deliberate | routine — a recycled IP may belong to a *different trust domain* seconds later |
| Cardinality | hundreds per segment | tens of thousands per cluster |

The killer is the fourth row. If your ACL says `10.244.3.17 may reach the payments database`, and the frontend pod holding `10.244.3.17` is evicted and the address is reassigned to a batch job in another namespace, your ACL is now **actively wrong** and no one gets an alert. This is not a theoretical race — on a cluster doing continuous delivery it happens many times per day.

The secondary problem is scale of state. A pure IP ruleset is O(sources × destinations × ports). In an iptables-based `kube-proxy` + `NetworkPolicy` implementation, every policy change triggers a rewrite of a rule chain that is walked linearly per packet. At a few thousand endpoints, `iptables-restore` runs take seconds, policy convergence latency becomes minutes, and the datapath cost of the linear walk shows up as p99 latency.

### 1.2 Cilium's answer: security identity

Cilium decouples *policy* from *addressing* entirely. Every endpoint (Pod, host, or external entity) is assigned a **security identity**: a small integer derived from the set of *security-relevant labels* on that endpoint.

```
labels {app=frontend, env=prod, ns=payments}  ──hash/allocate──▶  identity 12345
```

Two pods with identical security-relevant labels **share** one identity. That is the compression trick: a 500-replica Deployment is one identity, not 500 IPs. Policy is then expressed as `identity A → identity B on port/proto/L7-verb`, and the eBPF datapath answers each packet with a hash-map lookup keyed on `(remote identity, port, protocol, direction)` — an O(1) operation, independent of ruleset size.

Address resolution becomes a separate concern handled by the **ipcache**, a BPF map maintaining `IP → identity` for every address the node needs to reason about (local pods, remote pods learned via the kvstore/CRD watcher, node IPs, and CIDR-derived identities from policy). When a pod is rescheduled, the ipcache entry moves; the policy map does not change at all.

**Identity numbering (know this cold for the exam):**

| Range | Scope | Meaning |
|---|---|---|
| `0` | — | unknown / unspecified |
| `1`–`255` | reserved | fixed, well-known identities (below) |
| `256`–`65535` | cluster-wide | labels-derived identities, allocated via CRD (`CiliumIdentity`) or kvstore |
| `≥ 2^24` (`16777216`) | node-local | CIDR-derived identities, allocated by the local agent for `toCIDR`/FQDN rules; never leave the node |

Reserved identities you must be able to name:

| ID | Name | Matches |
|---|---|---|
| 1 | `reserved:host` | the local node itself (including host-network pods on that node) |
| 2 | `reserved:world` | any address outside the cluster |
| 3 | `reserved:unmanaged` | a pod Cilium does not manage |
| 4 | `reserved:health` | the per-node cilium-health endpoint |
| 5 | `reserved:init` | an endpoint whose labels are not yet resolved |
| 6 | `reserved:remote-node` | any *other* node in the cluster (or clustermesh) |
| 7 | `reserved:kube-apiserver` | endpoints backing the Kubernetes API server |
| 8 | `reserved:ingress` | the Cilium Ingress/Gateway API source endpoint |
| 9 / 10 | `reserved:world-ipv4` / `world-ipv6` | dual-stack split of `world` |

Under ClusterMesh, the cluster ID is packed into the upper bits of the numeric identity (`clusterID << 16 | localID` with the default `max-connected-clusters=255`), so identities remain globally unique across the mesh without coordination on every allocation.

### 1.3 Which labels count

Not every label contributes to identity. Cilium applies a **label filter** before allocation, and this is one of the highest-leverage operational knobs in the whole system.

Excluded by default (they are per-replica and would explode cardinality): `pod-template-hash`, `pod-template-generation`, `controller-revision-hash`, `statefulset.kubernetes.io/pod-name`, most `batch.kubernetes.io/*` labels, and all annotations.

Included by default: user labels (`k8s:app=…`), the namespace (`k8s:io.kubernetes.pod.namespace`), the service account (`k8s:io.cilium.k8s.policy.serviceaccount`), the cluster name (`k8s:io.cilium.k8s.policy.cluster`), and propagated namespace labels (`k8s:io.cilium.k8s.namespace.labels.*`).

> **Production failure mode.** Someone adds a label carrying a build SHA or a timestamp to a Deployment's pod template. Every rollout now allocates a *new* identity. The 65535 cluster-wide identity space fills, `CiliumIdentity` objects pile up faster than the operator's GC (default `identity-gc-interval` 15m, heartbeat timeout 30m), identity allocation starts failing, and new pods sit in `init` identity — which most policies do not match — so they are denied. Constrain the filter explicitly with `labels:` in Helm rather than trusting convention.

---

## 2. The enforcement pipeline, end to end

```
                     kube-apiserver
                           │  watch CNP/CCNP/KNP, Pods, Namespaces, Services
                           ▼
                  ┌──────────────────┐
                  │  cilium-agent    │
                  │  policy repo     │  ← rules, monotonically increasing revision
                  │  selector cache  │  ← selector → {identity,…}
                  │  identity alloc  │  ← CiliumIdentity CRD / kvstore
                  └────────┬─────────┘
                           │ regenerate endpoint (per-EP, incremental)
             ┌─────────────┼──────────────────────────┐
             ▼             ▼                          ▼
   cilium_policy_v2_<epid>   cilium_ipcache      cilium-envoy (L7 HTTP/Kafka)
   key: (identity, port,     key: IP/CIDR        cilium-agent DNS proxy (L7 DNS)
        proto, direction)    val: identity
   val: allow/deny, proxy
        port, auth type
             │
             ▼
   tc ingress/egress eBPF program on lxc<...> veth  ──▶  verdict
```

Per packet, the datapath:

1. Resolves the **remote** identity: for ingress, from the ipcache (or from the tunnel header / IPsec SPI when the source is on another node); for egress, by ipcache lookup on the destination.
2. Looks up `cilium_policy_v2_<epid>` with the most specific key first — `(identity, port, proto)`, then `(identity, ANY)`, then `(ANY-identity/wildcard, port)`, then the L3-only wildcard.
3. Applies the verdict. If the matched entry carries a **proxy port**, the packet is tproxy-redirected to Envoy or the DNS proxy for L7 evaluation. If it carries an **auth type**, the flow is held until mutual authentication completes.
4. Emits a `policy-verdict` notification to the monitor ring buffer — which is what Hubble consumes.

Two consequences that matter operationally:

- **Policy is per-endpoint and per-direction.** There is no global chain. An endpoint's ingress can be enforced while its egress is unrestricted, and vice versa.
- **Regeneration is asynchronous.** `kubectl apply` returning success means the CRD was accepted, not that any datapath enforces it. Convergence is observable via the policy revision (§7.2).

---

## 3. Policy object models compared

Cilium accepts three policy CRDs plus upstream `NetworkPolicy`. Choosing correctly is an architecture decision, not a style preference.

| Capability | `networking.k8s.io/v1` NetworkPolicy | `CiliumNetworkPolicy` (CNP) | `CiliumClusterwideNetworkPolicy` (CCNP) |
|---|---|---|---|
| Scope | namespaced | namespaced | **cluster-wide, no namespace** |
| Select by pod labels | ✅ | ✅ | ✅ (must include ns label explicitly) |
| Select by namespace labels | ✅ `namespaceSelector` | ✅ via `k8s:io.cilium.k8s.namespace.labels.*` | ✅ |
| L3 CIDR | ✅ `ipBlock` (+`except`) | ✅ `toCIDR`, `toCIDRSet`, `CiliumCIDRGroup` | ✅ |
| L4 ports | ✅ (+`endPort` ranges) | ✅ (+`endPort`, + ICMP/ICMPv6 by type) | ✅ |
| L7 HTTP / Kafka | ❌ | ✅ | ✅ (not for host policies) |
| L7 DNS + FQDN egress | ❌ | ✅ `toFQDNs` | ✅ |
| Explicit **deny** rules | ❌ | ✅ `ingressDeny` / `egressDeny` | ✅ |
| Reserved entities (`world`, `host`, `remote-node`, `kube-apiserver`, `cluster`) | ❌ | ✅ | ✅ |
| Egress to a K8s Service by name | ❌ | ✅ `toServices` | ✅ |
| Node / host firewall | ❌ | ❌ | ✅ `nodeSelector` |
| Mutual authentication | ❌ | ✅ `authentication.mode` | ✅ |
| Cross-cluster (ClusterMesh) | ❌ | ✅ `io.cilium.k8s.policy.cluster` | ✅ |
| Opt out of default-deny | ❌ | ✅ `enableDefaultDeny` (1.16+) | ✅ |
| Portable to other CNIs | ✅ | ❌ | ❌ |

**Architectural guidance.** Use CCNP for *platform-owned invariants* that must not be deletable by a namespace tenant: block the cloud metadata endpoint, allow DNS, allow kube-apiserver, enforce the node firewall. Use CNP for *application-owned* rules, delegated to the team that owns the namespace via RBAC. Use upstream `NetworkPolicy` only where portability across CNIs is a hard requirement — and accept that you then get no L7, no FQDN, no deny, and no entities.

All four object kinds are evaluated together into one merged policy per endpoint. Mixing them is supported and common.

### 3.1 Precedence and merge semantics

There is **no rule ordering and no priority field.** The evaluation is set-algebraic:

1. All `ingressDeny`/`egressDeny` rules from all objects are unioned. **Deny always wins**, unconditionally, over every allow.
2. All allow rules are unioned. There is no "first match".
3. L7 rules only apply to traffic already permitted at L3/L4 by the same `toPorts` block. An L7 rule cannot open a port that L4 has not opened.
4. If *any* rule selects an endpoint for a direction, that endpoint becomes **default-deny for that direction** — unless `enableDefaultDeny` says otherwise.

Deny rules are **L3/L4 only**. You cannot write "deny `POST /admin`" — express it as an allowlist of the permitted L7 verbs instead.

---

## 4. Default-deny: the semantics that cause most outages

### 4.1 Cluster-level enforcement mode

`policyEnforcementMode` (agent flag `--enable-policy`) has three values:

| Mode | Behaviour | Use |
|---|---|---|
| `default` | An endpoint is unrestricted in a direction until at least one rule selects it in that direction; then that direction becomes default-deny. | Normal operation. |
| `always` | Every endpoint is default-deny in both directions from creation. | Regulated environments; requires complete policy coverage *before* workloads land, including for `kube-system`. |
| `never` | Policy is parsed and reported but never enforced. | Diagnosis only. Never in production. |

### 4.2 The trap

This is the single most common Cilium incident:

```yaml
# The engineer's intent: "let this pod resolve DNS."
# The actual effect: "this pod may ONLY do DNS. Everything else is now denied."
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: settlement
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

The moment this lands, `app=settlement` is selected for egress, therefore default-deny egress, therefore every non-DNS egress flow drops. The pod's readiness probe still passes (probes are ingress, from the host), so the deployment reports healthy while the workload is fully broken.

Cilium 1.16 introduced the surgical fix — a policy that *adds* allowances without flipping the direction into default-deny:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: platform-allow-dns
spec:
  description: >
    Additive DNS allowance for every managed endpoint. enableDefaultDeny is
    false so that merely selecting an endpoint does not isolate it; namespace
    owners remain responsible for their own default-deny posture.
  endpointSelector:
    matchExpressions:
      - key: io.kubernetes.pod.namespace
        operator: Exists
  enableDefaultDeny:
    ingress: false
    egress: false
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

Use `enableDefaultDeny: {ingress: false, egress: false}` for every *platform-supplied additive* rule. Use the default (true) only in the policy that deliberately establishes a workload's isolation boundary.

### 4.3 Audit mode — always run it before enforcing

Policy audit mode evaluates policy and logs the verdict it *would* have applied, while forwarding the traffic. It is the only safe way to introduce default-deny into a running system, and it is mandatory before enabling the host firewall.

Per endpoint:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config 2696 PolicyAuditMode=Enabled
Endpoint 2696 configuration updated successfully
```

Cluster-wide (Helm, for a staged rollout):

```yaml
policyAuditMode: true
```

Audited flows appear with an `AUDIT` verdict rather than `DROPPED`:

```console
$ hubble observe --verdict AUDIT --last 5
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:44120 (ID:34567) -> 34.117.59.81:443 (ID:16777231) policy-verdict:none EGRESS AUDIT (TCP Flags: SYN)
```

Harvest audit output for a full business cycle — including the weekly batch job and the backup window — before flipping to enforce. Anything that only runs monthly will not appear, and that is exactly what breaks at 03:00.

---

## 5. Writing policy, layer by layer

### 5.1 A complete, production-shaped three-tier policy set

The example below is a full, apply-ready set for a `payments` namespace with `frontend → api → db`, plus an external payment processor. Nothing is elided.

```yaml
---
# ─────────────────────────────────────────────────────────────────────────────
# 0. Namespace baseline: default-deny both directions, with the two allowances
#    every workload needs (DNS, and the kube-apiserver for pods that use the
#    downward/API access). Owned by the platform team.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: baseline-default-deny
  namespace: payments
spec:
  description: >
    Establishes default-deny for every endpoint in the payments namespace and
    grants the universal allowances. Application policies are additive on top.
  endpointSelector: {}          # empty selector == every endpoint in this namespace
  ingress:
    # Kubelet health/readiness probes originate from the node's host namespace.
    - fromEntities:
        - host
        - health
  egress:
    # DNS, via the L7 DNS proxy so that toFQDNs rules elsewhere can learn IPs.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    # The API server, addressed by entity rather than by IP: this survives
    # control-plane node replacement and HA VIP changes.
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "6443"
              protocol: TCP
---
# ─────────────────────────────────────────────────────────────────────────────
# 1. frontend: accepts north-south traffic from the Ingress, talks only to api.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: frontend
      tier: web
  ingress:
    - fromEntities:
        - ingress                    # the Cilium Ingress/Gateway API source identity
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app: prometheus
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/metrics$"
  egress:
    - toEndpoints:
        - matchLabels:
            app: api
            tier: backend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
# ─────────────────────────────────────────────────────────────────────────────
# 2. api: L7-constrained ingress, mutually authenticated egress to db,
#    FQDN-scoped egress to the external processor.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: api
      tier: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
            tier: web
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              # Read paths: anonymous GETs on the accounts collection.
              - method: "GET"
                path: "/v1/accounts/[0-9]+$"
              - method: "GET"
                path: "/v1/accounts/[0-9]+/transactions$"
              # Write path: POST only, and only with a JSON body and the
              # service's own tenant header present.
              - method: "POST"
                path: "/v1/payments$"
                headers:
                  - 'Content-Type: application/json'
                  - 'X-Tenant-Id: .*'
              - method: "GET"
                path: "/healthz$"
    # Deliberately NOT reachable from anywhere else, including other namespaces.
  egress:
    - toEndpoints:
        - matchLabels:
            app: postgres
            tier: data
      authentication:
        mode: "required"             # SPIFFE-based mutual authentication
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
    - toFQDNs:
        - matchName: "api.stripe.com"
        - matchPattern: "*.eu-west-1.amazonaws.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
  egressDeny:
    # Belt and braces: even if a future allow rule widens egress, the cloud
    # metadata service stays unreachable. Deny beats allow, always.
    - toCIDR:
        - 169.254.169.254/32
        - fd00:ec2::254/128
---
# ─────────────────────────────────────────────────────────────────────────────
# 3. db: ingress from api only, no egress except DNS (inherited from baseline).
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: postgres
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: postgres
      tier: data
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api
            tier: backend
      authentication:
        mode: "required"
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app: postgres-exporter
      toPorts:
        - ports:
            - port: "9187"
              protocol: TCP
```

### 5.2 Layer-by-layer notes

**L3 — selecting the peer.** Five mutually exclusive forms per rule element:

| Selector | Matches | Notes |
|---|---|---|
| `fromEndpoints` / `toEndpoints` | Cilium-managed endpoints by label | In a namespaced CNP, an empty `matchLabels` is implicitly scoped to that namespace. Add `io.kubernetes.pod.namespace` to cross namespaces. |
| `fromEntities` / `toEntities` | reserved identities | `cluster` = all managed endpoints + host + remote-node + init + health. `all` = everything including `world`. |
| `fromCIDR` / `toCIDR` | literal prefixes | Allocates a node-local CIDR identity per prefix. |
| `fromCIDRSet` / `toCIDRSet` | prefixes with `except`, or a `CiliumCIDRGroup` reference | Preferred for large or shared prefix lists. |
| `toFQDNs` | DNS names (egress only) | Requires a companion DNS L7 rule. See §6. |
| `toServices` | a Kubernetes Service by name/namespace | Resolved to backend identities; survives backend churn. |

> **CIDR vs node IPs — a real trap.** By default, a `toCIDR` rule that covers a cluster node's IP does **not** match traffic to that node: node IPs carry `remote-node` identity, and CIDR selectors do not match node identities unless you set `policyCIDRMatchMode: [nodes]` (agent flag `--policy-cidr-match-mode=nodes`). If your "allow the 10.0.0.0/8 corporate range" rule mysteriously fails for node addresses, this is why.

**L4 — ports.** `protocol` is `TCP`, `UDP`, `SCTP`, or `ANY`. Port ranges use `endPort`:

```yaml
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
```

Named ports are supported (`port: "http"`, resolved from the pod spec). ICMP is expressed by type:

```yaml
  ingress:
    - fromEntities: [cluster]
      icmps:
        - fields:
            - type: 8                 # echo-request
              family: IPv4
            - type: 128               # echo-request
              family: IPv6
```

**L7 — the semantics change.** When a `toPorts` block carries an L7 `rules:` stanza, matching traffic is redirected to a userspace proxy. This changes observable behaviour in ways you must communicate to application teams:

| Aspect | L3/L4 denial | L7 denial |
|---|---|---|
| Client observes | TCP SYN black-holed → connect timeout / RST | TCP connect **succeeds**, then `HTTP 403 Access denied` |
| Latency cost | ~0 (eBPF map lookup) | Envoy hop: typically +0.2–1 ms p50, more under load |
| Failure domain | datapath only | proxy process; run `cilium-envoy` as its own DaemonSet so agent restarts do not disrupt L7 flows |
| Hubble verdict | `DROPPED` on the flow | `DROPPED` on the `http-request` event, `FORWARDED` on the L4 flow |
| Source IP visibility | n/a | preserved (transparent proxying) |
| Protocol support | any | HTTP/1.1, HTTP/2, gRPC, Kafka, DNS |

Kafka, for completeness:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: kafka-producers
  namespace: streaming
spec:
  endpointSelector:
    matchLabels:
      app: kafka
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: settlement-producer
      toPorts:
        - ports:
            - port: "9092"
              protocol: TCP
          rules:
            kafka:
              - role: "produce"
                topic: "payments.events.v1"
              - apiKey: "apiversions"
              - apiKey: "metadata"
```

### 5.3 Reusable prefix lists with `CiliumCIDRGroup`

Duplicating a 40-prefix corporate range across twelve policies guarantees drift. Externalise it:

```yaml
---
apiVersion: cilium.io/v2alpha1        # promoted to cilium.io/v2 in newer releases
kind: CiliumCIDRGroup
metadata:
  name: corporate-datacentres
  labels:
    trust-zone: internal
spec:
  externalCIDRs:
    - 10.100.0.0/16
    - 10.101.0.0/16
    - 192.0.2.0/24
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-to-corporate
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: api
  egress:
    - toCIDRSet:
        # Reference a single group by name…
        - cidrGroupRef: corporate-datacentres
        # …or select any number of groups by label (1.16+):
        - cidrGroupSelector:
            matchLabels:
              trust-zone: internal
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

---

## 6. FQDN policy: the mechanics, and where it bites

`toFQDNs` is the feature teams ask for most and the one that generates the most incidents, because it is a *DNS-observation* mechanism, not a name-resolution mechanism.

**How it works.**
1. An egress DNS L7 rule redirects the pod's DNS queries to Cilium's DNS proxy.
2. The proxy forwards the query, inspects the **response**, and matches the answer's name against every `toFQDNs` selector in scope.
3. For matches, the returned A/AAAA addresses are inserted into the ipcache with a node-local CIDR identity, and the corresponding `/32` `/128` entries are programmed into the endpoint's policy map with the TTL from the DNS response (floored by `--tofqdns-min-ttl`, default 3600 s).

**Therefore:**

| Requirement | Consequence if violated |
|---|---|
| A DNS L7 rule (`rules: dns: matchPattern: "*"`) must exist for the same endpoint | The proxy never sees the query; no IPs are learned; the FQDN rule matches nothing and all traffic to that name is denied. |
| The application must actually resolve the name at connect time | Apps that resolve once at startup and cache the IP forever will break when the entry expires. Apps given a literal IP by config are never allowed. |
| The name must resolve to a bounded set of IPs | `--tofqdns-max-ips-per-hostname` (default 50) truncates; large CDN/anycast fleets churn IPs faster than TTLs, producing intermittent denials. |
| The connection must be initiated *after* the lookup | A long-lived connection surviving past TTL expiry is protected by `--tofqdns-idle-connection-grace-period`; beyond that it may be torn down. |

`matchName` is an exact match (case-insensitive, trailing dot optional). `matchPattern` supports `*` as a single- or multi-label wildcard — `*.example.com` matches `a.example.com` **and** `a.b.example.com`, which is broader than most engineers expect. Write the tightest pattern that works.

**Inspecting what the proxy has learned:**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg fqdn cache list --endpoint 2696
Endpoint   Source   FQDN                                  TTL     ExpirationTime               IPs
2696       lookup   api.stripe.com.                       3600    2026-09-01T13:07:44.000Z     54.187.174.169,54.187.205.235
2696       lookup   s3.eu-west-1.amazonaws.com.           3600    2026-09-01T13:09:02.000Z     52.218.100.42
2696       lookup   sqs.eu-west-1.amazonaws.com.          3600    2026-09-01T13:09:02.000Z     63.32.19.104,52.208.4.11
```

If the name you expect is absent, the DNS rule is missing or the application never queried. Confirm the second case directly:

```console
$ hubble observe --from-pod payments/api --protocol dns --last 10
Sep  1 12:09:02.118: payments/api-6b8d9c7f4-nx8vp:39220 (ID:23456) -> kube-system/coredns-668d6bf9bc-8zt4m:53 (ID:45678) dns-request proxy FORWARDED (DNS Query api.stripe.com. AAAA)
Sep  1 12:09:02.121: kube-system/coredns-668d6bf9bc-8zt4m:53 (ID:45678) -> payments/api-6b8d9c7f4-nx8vp:39220 (ID:23456) dns-response proxy FORWARDED (DNS Answer "54.187.174.169" TTL: 60 (Proxy api.stripe.com. A))
```

Note the `TTL: 60` in the answer versus the `3600` in the cache: `--tofqdns-min-ttl` deliberately holds entries longer than upstream advertises, trading freshness for stability. Lower it only if you must follow fast-moving DNS, and expect more denials at the boundary.

**Restart behaviour.** Enable transparent DNS proxy mode (`dnsProxy.enableTransparentMode: true`, the modern default) so that the proxy is not a NAT hop and source IPs survive. During a `cilium-agent` restart the DNS proxy is briefly unavailable; plan restarts, and prefer the standalone DNS proxy deployment where your version offers it.

---

## 7. Encryption and mutual authentication

Network policy answers *who may talk to whom*. It does not answer *is the wire confidential* or *is the peer who it claims to be at the cryptographic level*. Those are three separate controls and the exam expects you to keep them separate.

### 7.1 Transparent encryption: IPsec vs WireGuard

| Dimension | IPsec (ESP) | WireGuard |
|---|---|---|
| Helm | `encryption.type: ipsec` | `encryption.type: wireguard` |
| Granularity | per node-pair SA; pod-to-pod traffic encrypted | node-to-node tunnel (`cilium_wg0`); pod traffic rides inside |
| Key management | you supply and rotate `cilium-ipsec-keys` Secret; rotation is an operational procedure | keys generated per node automatically; public keys distributed via `CiliumNode` |
| Kernel requirement | XFRM stack (widely available) | kernel ≥ 5.6 or the `wireguard` module |
| Cipher | AES-GCM (128/256) via kernel crypto — can be a FIPS-validated module | ChaCha20-Poly1305 — **not** FIPS-validatable |
| MTU overhead | ~50–60 B, cipher-dependent | 60 B (IPv4) / 80 B (IPv6) |
| CPU cost | lower with AES-NI offload; can use NIC offload | slightly higher without AES-NI; very good with it |
| Node-to-node (host) traffic | supported | `encryption.nodeEncryption: true` |
| Operational complexity | high (SA state, key rotation windows, `ip xfrm` debugging) | low |
| Interaction with policy | none — identity is carried in the SPI/mark | none |

**Recommendation:** WireGuard unless a compliance regime demands a FIPS-validated cipher, in which case IPsec with AES-GCM. Do not enable both.

```yaml
# Helm values — encryption + node encryption
encryption:
  enabled: true
  type: wireguard
  nodeEncryption: true
  wireguard:
    persistentKeepalive: 0s
```

Verification:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A4 Encryption
Encryption:              Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: kQx9k2Fh1v0J5uWq3pR7cYt4mZbN8sLdA6eXfG1hIjk=, Port: 51871, Peers: 5)]

$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
        Public key: kQx9k2Fh1v0J5uWq3pR7cYt4mZbN8sLdA6eXfG1hIjk=
        Number of peers: 5
```

For a genuine end-to-end proof, capture on the physical NIC and confirm you cannot read payloads — `cilium connectivity test --test 'pod-to-pod-encryption'` does exactly this.

### 7.2 Mutual authentication (SPIFFE/SPIRE)

Cilium's mutual authentication binds a **cryptographic identity** (a SPIFFE SVID issued by SPIRE, keyed to the Cilium security identity) to the flow. The datapath holds the first packet of a new flow while the agents on both sides complete a mutual TLS handshake out of band; once the pair is authenticated, the result is cached and subsequent flows between those identities pass at line rate.

**The critical caveat, and a favourite exam distractor: mutual authentication does not encrypt your traffic.** It authenticates the peers. Confidentiality still requires WireGuard or IPsec. Enable both.

```yaml
# Helm values
authentication:
  mutual:
    spire:
      enabled: true
      install:
        enabled: true
        namespace: cilium-spire
        server:
          dataStorage:
            enabled: true
            size: 2Gi
            storageClass: fast-ssd
```

Then, per rule:

```yaml
  egress:
    - toEndpoints:
        - matchLabels:
            app: postgres
      authentication:
        mode: "required"        # "required" | "disabled"
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

The auth requirement is visible in the endpoint's policy map (`AUTH TYPE` column, §8.3) and failures surface as `AUTH_REQUIRED` drops in Hubble.

---

## 8. Beyond pod policy: host firewall and egress gateway

### 8.1 Host firewall

The node itself is an endpoint (`reserved:host`). Enabling the host firewall lets you replace per-node `iptables`/`nftables` management with the same identity-aware model — but it is also the fastest way to lock yourself out of a cluster.

```yaml
# Helm values
hostFirewall:
  enabled: true
devices: "eth+ ens+ bond+"      # MUST cover every NIC carrying node traffic
policyAuditMode: true           # start here. Always.
```

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: node-baseline
spec:
  description: >
    Host-level firewall for worker nodes. L3/L4 only — host policies do not
    support L7. Roll out with PolicyAuditMode enabled and only enforce after a
    full week of audit data shows no unexpected denials.
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Intra-cluster: other nodes, health checks, and all managed workloads.
    - fromEntities:
        - cluster
        - remote-node
        - health
    # Management plane: SSH and the node exporter, from the bastion range only.
    - fromCIDRSet:
        - cidr: 10.20.0.0/24
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP
            - port: "9100"
              protocol: TCP
    # Kubelet API, from the control plane only.
    - fromEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP
    # Load-balancer health probes into NodePort range.
    - fromCIDRSet:
        - cidr: 10.30.0.0/24
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
  egress:
    - toEntities:
        - all
```

Note the deliberately permissive host egress: constraining node egress is a separate, much riskier project (it breaks image pulls, NTP, cloud APIs and the container runtime), and should be done only after the ingress side is stable.

### 8.2 Egress gateway: a stable source IP for external policy

External systems — a partner bank, a legacy firewall, a database with an IP allowlist — cannot consume Kubernetes identity. They need a stable source address. `CiliumEgressGatewayPolicy` SNATs selected pod traffic through a designated node and IP.

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: settlement-to-partner-bank
spec:
  selectors:
    - podSelector:
        matchLabels:
          io.kubernetes.pod.namespace: payments
          app: settlement
  destinationCIDRs:
    - 203.0.113.0/24
  excludedCIDRs:
    - 203.0.113.10/32          # this host must be reached directly, not via the GW
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    interface: eth0
    # Alternatively pin the exact address:
    # egressIP: 198.51.100.42
```

Requirements and trade-offs:

- Needs `kubeProxyReplacement: true` and `bpf.masquerade: true`.
- The gateway node is a **bandwidth and failure bottleneck**; label at least two nodes and understand that failover breaks in-flight connections.
- Egress gateway is orthogonal to policy — you still need an egress `CiliumNetworkPolicy` permitting the destination. The gateway decides *what source IP*, the policy decides *whether at all*.
- SNAT collapses per-pod attribution at the destination; keep Hubble as the source of truth for who actually sent what.

---

## 9. Verification and failure diagnosis

### 9.1 The escalation ladder

Work down this list in order. Each rung is cheaper than the next and eliminates a whole class of cause.

**Rung 0 — is the platform healthy at all?**

```console
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 6, Ready: 6/6, Available: 6/6
DaemonSet              cilium-envoy             Desired: 6, Ready: 6/6, Available: 6/6
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 6
                       cilium-envoy             Running: 6
                       cilium-operator          Running: 2
                       hubble-relay             Running: 1
Cluster Pods:          142/142 managed by Cilium
Helm chart version:    1.17.4
```

`Cluster Pods: 142/142 managed by Cilium` matters: any pod *not* managed carries `reserved:unmanaged` and is invisible to identity-based policy.

**Rung 1 — was the policy accepted, and did it converge?**

```console
$ kubectl -n payments get cnp
NAME                    AGE   VALID
baseline-default-deny   3h    True
frontend                3h    True
api                     8m    True
postgres                3h    True

$ kubectl -n payments describe cnp api | tail -20
Status:
  Conditions:
    Last Transition Time:  2026-09-01T12:05:11Z
    Message:               Policy validation succeeded
    Status:                True
    Type:                  Valid
```

A CNP with `VALID: False` is *silently not enforced*. This is a mandatory check in any CI gate.

Then confirm the datapath caught up. Every agent tracks a monotonic policy revision:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get --all | tail -3
Revision: 4211

$ for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
    echo -n "$p  "; kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg policy get 2>/dev/null | tail -1
  done
pod/cilium-4gk9t  Revision: 4211
pod/cilium-8mzq2  Revision: 4211
pod/cilium-b7xrl  Revision: 4211
pod/cilium-jw5nd  Revision: 4209     ◀── lagging: investigate this agent
pod/cilium-p2vch  Revision: 4211
pod/cilium-t9hks  Revision: 4211
```

**Rung 2 — is the endpoint enforcing, and what identity does it have?**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                        IPv6   IPv4          STATUS
           ENFORCEMENT        ENFORCEMENT
254        Disabled           Disabled          4          reserved:health                                           10.244.2.87   ready
1187       Enabled            Enabled           23456      k8s:app=api                                               10.244.2.31   ready
                                                           k8s:io.cilium.k8s.policy.cluster=prod-eu
                                                           k8s:io.cilium.k8s.policy.serviceaccount=api
                                                           k8s:io.kubernetes.pod.namespace=payments
                                                           k8s:tier=backend
2696       Enabled            Enabled           34567      k8s:app=settlement                                        10.244.2.44   ready
                                                           k8s:io.kubernetes.pod.namespace=payments
3312       Disabled           Disabled          16777220   reserved:host                                             10.0.1.12     ready
```

`POLICY ENFORCEMENT: Disabled` on a pod you believe is protected means **no rule selects it**. Ninety percent of the time this is a label typo or a namespace mismatch, not a Cilium bug.

**Rung 3 — what does the datapath actually believe?**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf policy get 1187
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                     PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES     PACKETS   PREFIX
Allow    Ingress     1          reserved:host                                   ANY          NONE         disabled    18244     212       0
Allow    Ingress     12345      k8s:app=frontend                                TCP/8080     16403        disabled    9812445   14022     0
                                k8s:io.kubernetes.pod.namespace=payments
                                k8s:tier=web
Allow    Egress      45678      k8s:io.kubernetes.pod.namespace=kube-system     ANY/53       16401        disabled    41220     388       0
                                k8s:k8s-app=kube-dns
Allow    Egress      56789      k8s:app=postgres                                TCP/5432     NONE         spire       2244109   6712      0
                                k8s:io.kubernetes.pod.namespace=payments
                                k8s:tier=data
Allow    Egress      16777231   cidr:54.187.174.169/32                          TCP/443      NONE         disabled    884210    1204      0
                                reserved:world
Deny     Egress      16777244   cidr:169.254.169.254/32                         ANY          NONE         disabled    0         0         0
```

Read this table carefully — it is the ground truth:
- The `PROXY PORT` non-zero on the frontend→api entry confirms L7 HTTP redirection is programmed.
- `AUTH TYPE: spire` on the postgres entry confirms mutual authentication is active for that pair.
- `IDENTITY 16777231` is a node-local CIDR identity minted by the FQDN rule — proof that `api.stripe.com` was resolved and programmed.
- `BYTES`/`PACKETS` per entry tell you which rules are *actually used*. Entries with zero counters after a week are candidates for removal, and a suspiciously busy `Deny` counter is an incident.

**Rung 4 — watch the verdict live.**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor -t policy-verdict --related-to 1187
Listening for events on 6 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
Policy verdict log: flow 0x3f9a21b4 local EP ID 1187, remote ID 12345, proto 6, ingress, action allow, match L3-L4, 10.244.1.57:41022 -> 10.244.2.31:8080 tcp SYN
Policy verdict log: flow 0x7c14e88d local EP ID 1187, remote ID 34567, proto 6, ingress, action deny, match none, 10.244.2.44:52344 -> 10.244.2.31:8080 tcp SYN
Policy verdict log: flow 0x9b02fa31 local EP ID 1187, remote ID 56789, proto 6, egress, action allow, match L3-L4, 10.244.2.31:38812 -> 10.244.3.19:5432 tcp SYN
```

The `match` field is the diagnosis:

| `match` value | Meaning |
|---|---|
| `none` | No rule matched → default-deny fired. Your selector is wrong or absent. |
| `L3-Only` | Matched on identity alone (rule had no `toPorts`). |
| `L3-L4` | Matched identity + port/protocol. |
| `L4-Only` | Matched a port rule with a wildcard identity. |
| `all` | Matched an allow-all wildcard — usually a sign of an overly broad rule. |

Cluster-wide, the same thing through Hubble:

```console
$ hubble observe --verdict DROPPED --namespace payments --last 20
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:52344 (ID:34567) -> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:52344 (ID:34567) <> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:07.114: payments/api-6b8d9c7f4-nx8vp:41560 (ID:23456) -> 169.254.169.254:80 (ID:16777244) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:19.443: payments/frontend-7c9f4d5b6-4kq2z:41022 (ID:12345) -> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) http-request DROPPED (HTTP/1.1 DELETE http://api.payments.svc.cluster.local:8080/v1/accounts/42)
```

The last line is the L7 case: the L4 flow was forwarded, the HTTP request was denied, and the client received a 403. Note also the pairing on the first two lines — Hubble emits both the policy-verdict event and the drop event for the same packet.

Targeted queries you will use constantly:

```console
# Everything between two workloads, both directions, following new flows
$ hubble observe --from-pod payments/frontend --to-pod payments/api -f

# Only what a given identity is being denied
$ hubble observe --identity 34567 --verdict DROPPED

# Only drops attributable to policy, cluster-wide
$ hubble observe --verdict DROPPED --type drop --last 200 -o json \
    | jq -r 'select(.drop_reason_desc=="POLICY_DENIED")
             | [.source.namespace+"/"+.source.pod_name,
                .destination.namespace+"/"+.destination.pod_name,
                (.l4.TCP.destination_port // .l4.UDP.destination_port | tostring)]
             | @tsv' | sort | uniq -c | sort -rn
     47  payments/settlement-5f7b9c8d4-2xqmr   payments/api-6b8d9c7f4-nx8vp   8080
     12  observability/loki-0                  payments/api-6b8d9c7f4-nx8vp   3100
```

That last pipeline is the workhorse for a "what will break if I enforce this" review — run it against audit-mode data and you get a ranked worklist.

**Rung 5 — selector introspection, when labels are the suspect.**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg policy selectors
SELECTOR                                                                                        LABELS                        USERS   IDENTITIES
&LabelSelector{MatchLabels:{any.app: frontend,any.tier: web,k8s.io.kubernetes.pod.namespace: payments,},}   payments/api        1       12345
&LabelSelector{MatchLabels:{any.app: postgres,any.tier: data,k8s.io.kubernetes.pod.namespace: payments,},}  payments/api        1       56789
&LabelSelector{MatchLabels:{any.app: settlement,k8s.io.kubernetes.pod.namespace: payments,},}               payments/legacy     1
MatchName: api.stripe.com, MatchPattern:                                                        payments/api                  1       16777231
```

An `IDENTITIES` column that is **empty** is the smoking gun: the selector matches nothing. Compare against the real labels:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list | head -20
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
12345      k8s:app=frontend
           k8s:io.cilium.k8s.policy.cluster=prod-eu
           k8s:io.cilium.k8s.policy.serviceaccount=frontend
           k8s:io.kubernetes.pod.namespace=payments
           k8s:tier=web
23456      k8s:app=api
           k8s:io.cilium.k8s.policy.cluster=prod-eu
           k8s:io.cilium.k8s.policy.serviceaccount=api
           k8s:io.kubernetes.pod.namespace=payments
           k8s:tier=backend
```

And, for a cross-node problem, verify the ipcache actually knows the remote address:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ipcache get 10.244.3.19
10.244.3.19 maps to identity identity=56789 encryptkey=0 tunnelendpoint=10.0.1.14 flags=<none>
```

A remote pod IP resolving to identity `2` (`world`) or `0` means the identity has not propagated — check the operator, the kvstore/CRD sync, and (in ClusterMesh) the remote cluster's connectivity.

### 9.2 Failure-mode catalogue

| Symptom | Root cause | Confirm with | Remedy |
|---|---|---|---|
| Everything breaks the moment a first policy lands | The rule selected the endpoint, flipping that direction to default-deny | `cilium-dbg endpoint list` shows `Enabled`; `hubble observe --verdict DROPPED` shows drops to kube-dns | Add DNS + kube-apiserver allowances, or set `enableDefaultDeny: {egress: false}` for additive policies |
| DNS works, everything else times out | Policy allows port 53 only | Hubble shows `EGRESS DENIED match none` on 443 | Add the intended egress rules |
| `toFQDNs` rule denies traffic | No companion DNS L7 rule, so the proxy never saw the response | `cilium-dbg fqdn cache list` is empty for that name | Add `rules: dns: - matchPattern: "*"` on the DNS egress rule |
| FQDN policy works then intermittently fails | App caches the IP past TTL, or the name returns >`max-ips-per-hostname` addresses | `cilium-dbg fqdn cache list` shows churn; drops to `world` | Raise `--tofqdns-min-ttl`, fix the app's resolver caching, or fall back to a CIDR/CIDRGroup |
| Client gets `403 Access denied` instead of a timeout | Working as designed: L7 denial is answered by Envoy | `hubble observe --protocol http` shows `http-request DROPPED` | Widen the L7 rule, or explain the semantics to the team |
| Policy applied but not enforced anywhere | `policyEnforcementMode: never`, or the CNP is `VALID: False` | `cilium-dbg status`; `kubectl get cnp -o wide` | Fix the mode; fix the schema error |
| Enforcement is inconsistent node to node | One agent lags in policy revision, or is restarting | the revision loop in §9.1 rung 1 | Inspect that agent's logs; check `cilium_policy_import_errors_total` |
| Cross-node traffic denied for pods that should be allowed | ipcache stale / identity not propagated | `cilium-dbg bpf ipcache get <ip>` returns `world` or `0` | Check operator, kvstore/CRD sync, ClusterMesh `cilium clustermesh status` |
| `toCIDR` covering node IPs does not match | Node IPs carry `remote-node` identity | `cilium-dbg bpf ipcache get <node-ip>` | Set `policyCIDRMatchMode: [nodes]` |
| Node unreachable after enabling host firewall | Host ingress default-deny; SSH/kubelet not allowed | Console access; `cilium-dbg endpoint list` for the `reserved:host` endpoint | Re-enable `policyAuditMode`, then write the allowances before enforcing |
| Sporadic denies at scale; some endpoints stop enforcing correctly | Per-endpoint policy map full (`bpf-policy-map-max`, default 16384) | `cilium_bpf_map_pressure{map_name=~"cilium_policy.*"}` approaching 1.0 | Reduce identity/CIDR cardinality; consolidate CIDRs into groups; raise the limit and restart |
| Identity count climbing without bound; new pods stuck in `init` | High-cardinality pod label feeding identity allocation | `cilium-dbg identity list \| wc -l`; `kubectl get ciliumid \| wc -l` | Constrain the Helm `labels:` filter; remove the offending label |
| Denied flow keeps working after you apply a deny policy | The flow is already established in conntrack | `cilium-dbg bpf ct list global \| grep <ip>` | Verify your version's behaviour, then force with `cilium-dbg bpf ct flush --endpoint <id>` and restart the client |
| L7 flows blip during a Cilium upgrade | Envoy running inside the agent pod | check whether the `cilium-envoy` DaemonSet exists | Set `envoy.enabled: true` so the proxy has an independent lifecycle |
| `authentication.mode: required` denies everything | SPIRE not installed, or SVIDs not issued | `kubectl -n cilium-spire get pods`; Hubble drop reason `AUTH_REQUIRED` | Install/repair SPIRE; verify agent↔server registration |

### 9.3 Automated verification

Cilium ships a full connectivity conformance suite. Run it after every install, upgrade or policy-model change — it creates its own namespace, exercises pod-to-pod, pod-to-service, pod-to-world, DNS, L7 and encryption paths, and cleans up.

```console
$ cilium connectivity test --test-namespace cilium-test --test-concurrency 4
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [prod-eu] Creating namespace cilium-test for connectivity check...
✨ [prod-eu] Deploying echo-same-node service...
✨ [prod-eu] Deploying DNS test server configmap...
⌛ [prod-eu] Waiting for deployments [client client2 echo-same-node] to become ready...
🏃 Running 78 tests ...
[=] Test [no-policies] .........................
[=] Test [allow-all-except-world] ..............
[=] Test [client-ingress] ......................
[=] Test [echo-ingress] ........................
[=] Test [client-egress-l7] ....................
[=] Test [to-fqdns] ............................
[=] Test [pod-to-pod-encryption] ...............
✅ All 78 tests (312 actions) successful, 6 tests skipped, 0 scenarios skipped.
```

Validate policy CRDs before they reach the cluster — this is also the upgrade preflight step:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg preflight validate-cnp
level=info msg="Setting up client to access Kubernetes API"
level=info msg="Validating CiliumNetworkPolicy 'payments/api'"
level=info msg="Validating CiliumNetworkPolicy 'payments/frontend'"
level=info msg="Validating CiliumClusterwideNetworkPolicy 'node-baseline'"
level=info msg="All CCNPs and CNPs valid!"
```

### 9.4 Alert on the things that fail silently

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-policy-health
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: cilium-policy
      rules:
        - alert: CiliumPolicyMapPressureHigh
          # A full per-endpoint policy map silently stops enforcing correctly.
          expr: max by (node, map_name) (cilium_bpf_map_pressure{map_name=~"cilium_policy.*"}) > 0.85
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Policy map pressure {{ $value | humanizePercentage }} on {{ $labels.node }}"
            runbook: "Reduce identity/CIDR cardinality or raise bpf-policy-map-max."

        - alert: CiliumPolicyImportErrors
          # A rejected policy is a policy that is not protecting anything.
          expr: increase(cilium_policy_import_errors_total[15m]) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cilium rejected {{ $value }} policy imports on {{ $labels.pod }}"

        - alert: CiliumIdentityCardinalityGrowth
          # Runaway identity allocation exhausts the 65535 cluster-local space.
          expr: predict_linear(cilium_identity[6h], 24 * 3600) > 55000
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Cluster-local identity space projected to exhaust within 24h"

        - alert: CiliumPolicyDropSpike
          # A step change in policy drops after a deploy is almost always a regression.
          expr: |
            sum by (namespace) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
            ) > 5
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $value | printf \"%.1f\" }} policy drops/s in namespace {{ $labels.namespace }}"

        - alert: CiliumAgentPolicyRevisionLag
          expr: |
            max(cilium_policy_max_revision) - min(cilium_policy_max_revision) > 2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cilium agents are not converged on the same policy revision"
```

Enable the Hubble metrics that feed these:

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  metrics:
    enableOpenMetrics: true
    enabled:
      - "dns:query;ignoreAAAA"
      - "drop:sourceContext=pod;destinationContext=pod"
      - "flow:sourceContext=pod;destinationContext=pod"
      - "tcp"
      - "httpV2:exemplars=true;labelsContext=source_namespace,destination_namespace"
    serviceMonitor:
      enabled: true
```

> **Cardinality warning.** `sourceContext=pod;destinationContext=pod` produces a time series per pod pair. On a large cluster this will overwhelm Prometheus. Use `sourceContext=namespace;destinationContext=namespace` as the default and enable pod-level context only for a targeted investigation.

---

## 10. Rollout method for an existing cluster

The order matters, and skipping steps is how clusters break:

1. **Observe first.** Deploy Hubble with no policy at all. Export two weeks of flows. This is your ground truth for what actually communicates — nobody's architecture diagram is accurate.
2. **Derive candidate policies** from observed flows, per namespace, starting with the least-connected workloads.
3. **Apply in audit mode.** `policyAuditMode: true` cluster-wide, or per endpoint. Nothing is dropped.
4. **Mine the audit stream** with the `jq` pipeline in §9.1 for a full business cycle, including monthly jobs. Every `AUDIT` verdict is either a missing rule or a genuine finding.
5. **Enforce namespace by namespace**, lowest-risk first, with a documented rollback (`kubectl delete cnp <name>` restores the previous posture within one policy revision).
6. **Add L7 selectively.** L7 is a proxy hop and a new failure domain — apply it where the security value is real (an API boundary, a Kafka topic), not everywhere.
7. **Enable encryption**, then **mutual authentication**, as separate changes with separate verification.
8. **Host firewall last**, in audit mode, on one node pool, with console access confirmed working before you enforce.

---

## 11. Key takeaways

- Policy targets **identity**, not IP. Identity is derived from a filtered label set; controlling that filter is a first-class operational responsibility.
- Selecting an endpoint in a direction makes it **default-deny in that direction**. `enableDefaultDeny: false` is the tool for additive platform policies.
- **Deny beats allow, always**, and deny is L3/L4 only.
- `toFQDNs` requires a companion **DNS L7 rule**; without it the FQDN selector matches nothing.
- L7 denial returns **HTTP 403**; L3/L4 denial **drops the packet**. Different symptoms, different debugging.
- Mutual authentication **authenticates**; WireGuard/IPsec **encrypt**. They are independent controls and you generally want both.
- `CCNP` for platform invariants and the host firewall; `CNP` for application rules; upstream `NetworkPolicy` only when portability is mandatory.
- The debugging path is fixed: `cilium status` → CNP `VALID` → policy revision convergence → `cilium-dbg endpoint list` → `cilium-dbg bpf policy get` → `hubble observe` / `cilium-dbg monitor -t policy-verdict`. The `match` field in a verdict tells you *why*.
- **Audit mode before enforcement. Always.** Especially for the host firewall.

---

## 12. References

**Cilium — official documentation**
- Network Policy overview and concepts — https://docs.cilium.io/en/stable/security/policy/
- Policy enforcement modes and default deny — https://docs.cilium.io/en/stable/security/policy/intro/
- Layer 3 policy (endpoints, entities, CIDR, services) — https://docs.cilium.io/en/stable/security/policy/language/#layer-3-examples
- Layer 4 policy — https://docs.cilium.io/en/stable/security/policy/language/#layer-4-examples
- Layer 7 policy (HTTP, Kafka, DNS) — https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- DNS-based (FQDN) policies — https://docs.cilium.io/en/stable/security/policy/language/#dns-based
- Locking down external access with DNS-based policies — https://docs.cilium.io/en/stable/security/dns/
- Deny policies — https://docs.cilium.io/en/stable/security/policy/language/#deny-policies
- CiliumNetworkPolicy API reference — https://docs.cilium.io/en/stable/network/kubernetes/policy/
- Kubernetes NetworkPolicy support and differences — https://docs.cilium.io/en/stable/security/policy/kubernetes/
- Identity and identity management — https://docs.cilium.io/en/stable/internals/security-identities/
- Host firewall — https://docs.cilium.io/en/stable/security/host-firewall/
- Transparent encryption (IPsec and WireGuard) — https://docs.cilium.io/en/stable/security/network/encryption/
- WireGuard transparent encryption — https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- IPsec transparent encryption — https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Mutual authentication with SPIFFE/SPIRE — https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
- Egress gateway — https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- Policy troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Monitoring and metrics reference — https://docs.cilium.io/en/stable/observability/metrics/
- Helm reference (`policyEnforcementMode`, `policyAuditMode`, `hostFirewall`, `encryption`, `authentication`) — https://docs.cilium.io/en/stable/helm-reference/
- Command reference for `cilium-dbg` — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- eBPF datapath internals — https://docs.cilium.io/en/stable/network/ebpf/

**Hubble**
- Hubble observability overview — https://docs.cilium.io/en/stable/observability/
- Hubble CLI reference — https://docs.cilium.io/en/stable/observability/hubble/
- Hubble metrics — https://docs.cilium.io/en/stable/observability/metrics/#hubble-exported-metrics

**Kubernetes upstream**
- Network Policies concept — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- NetworkPolicy API reference — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/

**CNCF / exam**
- Cilium Certified Associate (CCA) curriculum — https://github.com/cncf/curriculum/blob/master/cca/README.md
- Cilium Certified Associate programme page — https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Related specifications**
- SPIFFE specification (workload identity used by Cilium mutual authentication) — https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE.md
- WireGuard protocol — https://www.wireguard.com/protocol/
- RFC 4303, IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303