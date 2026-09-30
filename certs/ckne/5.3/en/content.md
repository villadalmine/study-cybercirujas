# 5.3 Auditing Traffic with Logs

> **Exam weight: 5%.** The CKNE curriculum pairs this domain with metrics (5.1) and troubleshooting (5.2). Metrics tell you *that* something is wrong: the drop rate went up, or p99 doubled. Logs tell you *which* packet, request or DNS query was involved, *who* sent it, *which rule* decided its fate, and *who changed that rule*. This topic covers building, filtering, shipping and querying those records.

---

## 1. Motivation: the production problem

A payment service starts returning intermittent `503`s at 02:14. Dashboards show a rise in `hubble_drop_total{reason="POLICY_DENIED"}` in namespace `payments`. On-call engineers usually get stuck at this point, because a metric **aggregates away the identity of the event**. To act, you need to answer five questions:

1. **Which flow?** Source pod, destination pod, port and protocol.
2. **Which verdict and why?** Forwarded, dropped by policy, dropped by an invalid conntrack state, or never answered.
3. **At which layer?** L3/L4 (CNI dataplane), L7 (proxy or Gateway), or name resolution (DNS never returned an IP).
4. **Who changed what, and when?** A `NetworkPolicy` applied at 02:13 by a CI service account.
5. **Can we prove it later?** Compliance regimes such as PCI-DSS 10.x, SOC 2 CC7 and ISO 27001 A.8.15 require durable, tamper-evident records of access to regulated segments.

No single component can answer all five. Kubernetes `NetworkPolicy` (`networking.k8s.io/v1`) has **no logging field at all**; the spec defines intent, not observability. Traffic auditing is therefore always assembled from several layers:

```
                  ┌───────────────────────────────────────────────┐
  control plane   │ kube-apiserver audit log                      │  WHO changed policy/routes
                  └───────────────────────────────────────────────┘
                  ┌───────────────────────────────────────────────┐
  L7 edge / mesh  │ Envoy / Gateway / Istio access logs           │  WHAT request, status, upstream
                  └───────────────────────────────────────────────┘
                  ┌───────────────────────────────────────────────┐
  L3/L4 dataplane │ Hubble flows / Antrea np.log / Calico Log     │  WHICH flow, verdict, rule
                  └───────────────────────────────────────────────┘
                  ┌───────────────────────────────────────────────┐
  name resolution │ CoreDNS `log` plugin                          │  DID it resolve, to what
                  └───────────────────────────────────────────────┘
                  ┌───────────────────────────────────────────────┐
  node kernel     │ conntrack events, iptables LOG, dmesg         │  last-resort ground truth
                  └───────────────────────────────────────────────┘
```

The architectural challenge is **volume versus fidelity**. A busy node can emit 5,000 flows per second. At about 400 bytes per JSON flow record:

```
5,000 flows/s × 400 B = 2 MB/s ≈ 172.8 GB/day per node
```

On a 50-node cluster that is roughly 8.6 TB/day before replication. Nobody keeps all of it. The engineering work is to decide **what to keep, at which layer, for how long, with which fields, and with which personal data removed**.

---

## 2. The layers compared

### 2.1 What each source can prove

| Source | Layer | Answers | Cannot answer | Default state |
|---|---|---|---|---|
| kube-apiserver audit | Control plane | Who created/patched/deleted a `NetworkPolicy`, `HTTPRoute` or `Service`, from which IP and user agent | Whether any packet was affected | **Off** (needs `--audit-policy-file`) |
| Cilium Hubble flows | L3/L4 (+L7 with a proxy) | 5-tuple, security identity, verdict, drop reason, policy match type, direction | Request bodies; L7 details without an L7 rule | Ring buffer in memory; export **off** |
| Antrea NetworkPolicy logging | L3/L4 | Rule name, action, `logLabel`, 5-tuple | Anything about unlogged rules | **Off** per rule |
| Calico `action: Log` (OSS, iptables) | L3/L4 | Packet headers via kernel log | Policy name (only a prefix) | Opt-in per rule |
| Calico flow logs (Goldmane/Whisker in OSS 3.30+, Enterprise) | L3/L4 | Aggregated flows plus the policies that matched | Per-packet granularity (aggregated) | Depends on version/edition |
| Envoy / Envoy Gateway access log | L7 | Method, authority, path, status, response flags, upstream host, duration, trace ID | Drops that happen before the proxy | EG: text to stdout by default |
| Istio Telemetry API | L7 (mesh) | Same as Envoy, per workload, plus mTLS peer identity | Non-mesh traffic | Depends on `meshConfig` |
| CoreDNS `log` | DNS | Client IP, qname, qtype, rcode, latency | What the client did next | **Off** in most distros |
| conntrack / iptables LOG | Kernel | Ground truth of NAT and state | Kubernetes identities | Ad hoc |

### 2.2 Delivery trade-offs

| Sink | Latency | Durability | Cost | Typical use |
|---|---|---|---|---|
| In-memory ring (`hubble observe`) | Real time | Lost on agent restart; ~4k–64k flows per node | Free | Live debugging, the exam |
| Local file + rotation (Hubble exporter, `np.log`) | Seconds | Survives restarts; bounded by rotation | Disk I/O on node | Source for a shipper |
| Container stdout | Seconds | Kubelet rotation (`containerLogMaxSize`) | Free until shipped | Proxies, CoreDNS |
| Shipper → Loki/Elasticsearch/OTLP | Seconds–minutes | Central, queryable, retained | Storage and ingest | Audit and compliance |
| Object storage (S3 + WORM) | Minutes | Immutable | Cheapest per GB | Long-term compliance retention |

### 2.3 Reduction strategies

| Technique | Where | Reduces | Risk |
|---|---|---|---|
| **Allow/deny filters** (log only `DROPPED`, `AUDIT`, `ERROR`) | Hubble exporter, Istio `filter.expression`, EG `matches` | 90–99% of volume | You lose the "allowed but suspicious" baseline |
| **Field masks** | Hubble `fieldMask` | 40–70% per record | Dropping a field you later need to correlate |
| **Aggregation** | Calico flow logs, Hubble metrics | Per-flow → per-interval | No individual-event evidence |
| **Sampling** | Proxy access logs | Proportional | Useless for "prove this one request" |
| **Redaction** | Hubble `redact`, Envoy format choice | Personal data | Under-redaction is a compliance incident |

**Rule of thumb:** keep **denials and errors at 100%**, keep **allowed L3/L4 flows only for regulated segments**, keep **L7 access logs at the edge at 100% with bodies never logged**, and keep **API audit for policy objects at `RequestResponse`**.

---

## 3. Control plane: who changed the policy?

Most network incidents begin with a change. The kube-apiserver audit log is the only authoritative record of who modified `NetworkPolicy`, CNI-specific policy CRDs, Gateway API routes and `Service` objects.

### 3.1 Audit policy focused on network objects

Rules are evaluated **in order; first match wins**. Specific rules therefore go first, and a catch-all goes last.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log Secret payloads, even if a later rule would match.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Full before/after for every mutation of network policy and routing.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: networking.k8s.io
        resources: ["networkpolicies", "ingresses"]
      - group: cilium.io
        resources: ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"]
      - group: crd.antrea.io
        resources: ["networkpolicies", "clusternetworkpolicies"]
      - group: projectcalico.org
        resources: ["networkpolicies", "globalnetworkpolicies"]
      - group: crd.projectcalico.org
        resources: ["networkpolicies", "globalnetworkpolicies"]
      - group: gateway.networking.k8s.io
        resources: ["gateways", "httproutes", "grpcroutes", "tlsroutes", "referencegrants"]
      - group: ""
        resources: ["services", "endpoints"]
      - group: discovery.k8s.io
        resources: ["endpointslices"]

  # Reads of policy objects: who looked, not what they saw.
  - level: Metadata
    verbs: ["get", "list", "watch"]
    resources:
      - group: networking.k8s.io
        resources: ["networkpolicies"]
      - group: cilium.io
        resources: ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"]

  # Drop the high-volume noise.
  - level: None
    users: ["system:kube-proxy"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]

  - level: None
```

> `endpointslices` mutations are made constantly by the EndpointSlice controller. In a large cluster, add `level: None` for `users: ["system:serviceaccount:kube-system:endpointslice-controller"]` **before** the `RequestResponse` rule, or that rule will dominate the log.

### 3.2 Wiring it into a kubeadm control plane

Excerpt of `/etc/kubernetes/manifests/kube-apiserver.yaml`. Only the relevant fields are shown; a static pod manifest must keep all its other existing flags.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.1
      command:
        - kube-apiserver
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-format=json
        - --audit-log-maxage=30
        - --audit-log-maxbackup=10
        - --audit-log-maxsize=200
      volumeMounts:
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
  volumes:
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
```

The most common failure here is a missing `volumeMounts`. The apiserver then cannot read the policy file, crash-loops, and `kubectl` stops answering. Check it from the node:

```
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED          STATE    NAME             ATTEMPT
3f1c9a0b2e7d1  a1b2c3d4e5f6   42 seconds ago   Running  kube-apiserver   0

$ sudo crictl logs 3f1c9a0b2e7d1 2>&1 | grep -i audit | head -3
I0930 02:10:11.204118  1 flags.go:64] FLAG: --audit-log-path="/var/log/kubernetes/audit/audit.log"
I0930 02:10:11.204130  1 flags.go:64] FLAG: --audit-policy-file="/etc/kubernetes/audit/policy.yaml"
```

### 3.3 Querying: who touched policy in `payments` in the last hour?

```
$ sudo jq -c 'select(.objectRef.resource=="networkpolicies"
                and .objectRef.namespace=="payments"
                and (.verb|test("create|update|patch|delete")))
              | {ts:.requestReceivedTimestamp, user:.user.username,
                 verb, name:.objectRef.name, code:.responseStatus.code,
                 src:.sourceIPs[0], ua:.userAgent}' \
    /var/log/kubernetes/audit/audit.log
{"ts":"2026-09-30T02:13:47.118223Z","user":"system:serviceaccount:ci:deployer","verb":"patch","name":"payments-ingress","code":200,"src":"10.0.4.17","ua":"argocd-application-controller/v3.1.5"}
```

With `RequestResponse`, `.requestObject` holds the patch body and `.responseObject` holds the resulting object. Diffing these shows exactly which `from` selector disappeared.

---

## 4. L3/L4 dataplane: Cilium Hubble

Hubble reads events that Cilium's eBPF programs already emit (trace, drop and policy-verdict notifications) from a per-node ring buffer. **Observation costs little because the dataplane produces these events anyway; export is what costs I/O.**

### 4.1 Anatomy of a flow

```
$ hubble observe --namespace payments --verdict DROPPED --last 3
Sep 30 02:14:03.512: payments/checkout-6c9f7d8b5-2xk4q:48212 (ID:31844) <> payments/ledger-7d9c4f6b8-q7m2n:8443 (ID:52011) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 02:14:03.512: payments/checkout-6c9f7d8b5-2xk4q:48212 (ID:31844) <> payments/ledger-7d9c4f6b8-q7m2n:8443 (ID:52011) Policy denied DROPPED (TCP Flags: SYN)
Sep 30 02:14:04.531: payments/checkout-6c9f7d8b5-2xk4q:48212 (ID:31844) <> payments/ledger-7d9c4f6b8-q7m2n:8443 (ID:52011) Policy denied DROPPED (TCP Flags: SYN)
```

How to read it:

| Token | Meaning |
|---|---|
| `(ID:31844)` | Cilium **security identity**, derived from the pod's labels. Policy is enforced on identities, not IPs. |
| `<>` | Direction unknown/ambiguous in this event; `->` means forward and `<-` means reply |
| `policy-verdict:none INGRESS DENIED` | Policy-verdict event: the ingress lookup at `ledger` found **no matching allow rule** |
| `Policy denied DROPPED` | Drop event with reason `POLICY_DENIED` (drop reason code 133) |
| `(TCP Flags: SYN)` | The connection never established; the retransmit at +1 s confirms client retry |

Other `policy-verdict` match types you will see: `L3-Only`, `L3-L4`, `L4-Only`, `all` (allow-all), and `none` (denied).

### 4.2 Accessing Hubble

```
$ cilium hubble enable --relay
$ cilium status --wait | grep -E 'Hubble|Relay'
Hubble Relay:       OK

$ cilium hubble port-forward &
[1] 48121
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 16,380/16,380 (100.00%)
Flows/s: 812.44
Connected Nodes: 3/3
```

`Current/Max Flows: 100%` means the ring buffer is full and wrapping. On a busy node, a flow from 90 seconds ago may already be gone. **The ring buffer is not an audit trail**, which is why export exists.

Without the CLI installed locally, use the Hubble binary inside the agent. This shows only that node's flows, without Relay:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    hubble observe --verdict DROPPED --last 5 -o compact
```

### 4.3 Filters that matter

```
# Everything denied TO a workload
$ hubble observe --to-pod payments/ledger-7d9c4f6b8-q7m2n --verdict DROPPED

# Only policy decisions (not trace events), both allowed and denied
$ hubble observe --namespace payments --type policy-verdict

# DNS traffic (requires a DNS-aware L7 rule; see 4.6)
$ hubble observe --namespace payments --protocol dns

# HTTP (requires an L7 HTTP rule)
$ hubble observe --namespace payments --protocol http --http-status 500+

# Traffic leaving the cluster
$ hubble observe --namespace payments --to-identity world

# Which node saw it
$ hubble observe --verdict DROPPED --print-node-name --last 10

# Machine-readable, for jq
$ hubble observe --verdict DROPPED --last 200 -o json \
  | jq -r '.flow | [.time, .source.namespace+"/"+.source.pod_name,
                     .destination.namespace+"/"+.destination.pod_name,
                     (.l4.TCP.destination_port // .l4.UDP.destination_port),
                     .drop_reason_desc] | @tsv' \
  | sort -k2,5 | uniq -c -f1 | sort -rn | head
     41 2026-09-30T02:14:03.512Z  payments/checkout-6c9f7d8b5-2xk4q  payments/ledger-7d9c4f6b8-q7m2n  8443  POLICY_DENIED
      3 2026-09-30T02:13:58.004Z  payments/checkout-6c9f7d8b5-2xk4q  kube-system/coredns-7db6d8ff4d-zz9lp  53    POLICY_DENIED
```

That second row is the classic trap: a default-deny egress policy that forgot DNS.

### 4.4 Persistent export (static exporter)

The Hubble exporter writes flows as JSON Lines to a file on the node, with rotation, filters and a field mask. A shipper (section 9) picks the file up from there.

Helm values for Cilium. Key names moved between minor versions, so confirm with `helm show values cilium/cilium --version <x>` before applying.

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: false
  redact:
    enabled: true
    http:
      urlQuery: true
      userInfo: true
      headers:
        deny:
          - authorization
          - cookie
          - set-cookie
          - x-api-key
  export:
    fileMaxSizeMb: 50
    fileMaxBackups: 5
    static:
      enabled: true
      filePath: /var/run/cilium/hubble/events.log
      allowList:
        - '{"verdict":["DROPPED","ERROR","AUDIT"]}'
        - '{"destination_label":["k8s:io.kubernetes.pod.namespace=payments"]}'
      denyList:
        - '{"source_pod":["kube-system/"]}'
        - '{"destination_pod":["kube-system/"],"destination_port":["53"],"verdict":["FORWARDED"]}'
      fieldMask:
        - time
        - node_name
        - verdict
        - drop_reason_desc
        - traffic_direction
        - is_reply
        - Type
        - source.namespace
        - source.pod_name
        - source.identity
        - source.labels
        - destination.namespace
        - destination.pod_name
        - destination.identity
        - destination.labels
        - IP
        - l4
        - l7
        - event_type
        - policy_match_type
```

Semantics you must know:

- Entries in `allowList` are **OR**ed. Fields *inside* one entry are **AND**ed. The config above keeps "anything dropped/errored/audited anywhere" **or** "anything to `payments`" (PCI scope, including allowed flows).
- `denyList` is applied after `allowList` and wins.
- An empty `fieldMask` exports the full flow. The mask above roughly halves record size.
- `/var/run/cilium` is a `hostPath` in the Cilium DaemonSet, so the file is reachable from the node and from any pod mounting that path.

Apply and verify:

```
$ helm upgrade cilium cilium/cilium -n kube-system --reuse-values -f hubble-export.yaml
$ kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out

$ cilium config view | grep hubble-export
hubble-export-allowlist                    {"verdict":["DROPPED","ERROR","AUDIT"]},{"destination_label":["k8s:io.kubernetes.pod.namespace=payments"]}
hubble-export-denylist                     {"source_pod":["kube-system/"]},{"destination_pod":["kube-system/"],"destination_port":["53"],"verdict":["FORWARDED"]}
hubble-export-fieldmask                    time node_name verdict drop_reason_desc traffic_direction is_reply Type source.namespace ...
hubble-export-file-max-backups             5
hubble-export-file-max-size-mb             50
hubble-export-file-path                    /var/run/cilium/hubble/events.log

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    sh -c 'tail -n 1 /var/run/cilium/hubble/events.log' | jq -c '.flow | {time,verdict,drop_reason_desc,src:.source.pod_name,dst:.destination.pod_name}'
{"time":"2026-09-30T02:14:03.512873411Z","verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","src":"checkout-6c9f7d8b5-2xk4q","dst":"ledger-7d9c4f6b8-q7m2n"}
```

For several independent streams, each with its own file, filter and mask, and reconfigurable without restarting the agent, Cilium also has a **dynamic exporter** (`hubble.export.dynamic.enabled` and `hubble.export.dynamic.config.content`). Use it to separate, for example, a "compliance" stream from a "security denials" stream with different retention.

### 4.5 Policy audit mode: log what *would* be denied

Rolling out default-deny in a brownfield cluster is the highest-risk network change you can make. Cilium's **policy audit mode** evaluates policy and emits verdicts, but **forwards** traffic that would have been dropped, with verdict `AUDIT`.

Cluster-wide (Helm):

```yaml
policyAuditMode: true
```

Per endpoint, for a surgical rollout:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | grep ledger
1289   Enabled   Disabled   52011   k8s:app=ledger  ...  10.0.2.41   ready

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg endpoint config 1289 PolicyAuditMode=Enabled
Endpoint 1289 configuration updated successfully

$ hubble observe --namespace payments --verdict AUDIT --last 5
Sep 30 09:02:11.004: payments/reports-5b7f9c6d4-8tqzv:51544 (ID:40211) -> payments/ledger-7d9c4f6b8-q7m2n:8443 (ID:52011) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
```

Workflow: enable audit mode → apply the policy → collect `AUDIT` flows for a full business cycle (at least a week, so it includes batch jobs and month-end) → add the missing rules → re-check until no `AUDIT` flows remain → disable audit mode. The exporter's `allowList` above already captures `AUDIT`, so the evidence persists.

### 4.6 Turning on L7 visibility

By default Hubble sees L3/L4 only. L7 fields (`l7.http`, `l7.dns`) appear **only when traffic is redirected to Cilium's Envoy proxy by an L7 rule**. A permissive L7 rule gives visibility without changing enforcement semantics for the listed ports:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ledger-l7-visibility
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: ledger
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: checkout
        - matchLabels:
            app: reports
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

Caveats:

- A `CiliumNetworkPolicy` that selects an endpoint puts it into default-deny **for that direction**. This policy allows ingress only from `checkout` and `reports`, and egress only to DNS. That is intentional for `ledger`; it would be an outage if applied carelessly elsewhere.
- L7 redirection adds latency (typically sub-millisecond to low milliseconds) and proxy CPU. Enable it on the segments you must audit, not cluster-wide.
- The `dns` rule makes the agent's DNS proxy see every query. That enables `--protocol dns` in Hubble **and** is a prerequisite for `toFQDNs` policies.
- Port 8443 in the example above is TLS. Without TLS interception Cilium cannot parse HTTP inside it; the L7 rule is on the plaintext port 8080.

```
$ hubble observe --namespace payments --protocol http --last 3
Sep 30 09:15:40.221: payments/checkout-6c9f7d8b5-2xk4q:39120 (ID:31844) -> payments/ledger-7d9c4f6b8-q7m2n:8080 (ID:52011) http-request FORWARDED (HTTP/1.1 POST http://ledger:8080/v1/entries)
Sep 30 09:15:40.236: payments/checkout-6c9f7d8b5-2xk4q:39120 (ID:31844) <- payments/ledger-7d9c4f6b8-q7m2n:8080 (ID:52011) http-response FORWARDED (HTTP/1.1 201 15ms (POST http://ledger:8080/v1/entries))
```

---

## 5. L3/L4 dataplane: Antrea and Calico

Only one CNI is installed in a given cluster, but the CKNE covers the ecosystem, so you should recognise all of them.

### 5.1 Antrea: per-rule logging

Antrea writes NetworkPolicy logs on each node to `/var/log/antrea/networkpolicy/np.log` (the `antrea-agent` mounts `/var/log/antrea` from the host). Logging is opt-in **per rule** for Antrea-native policies:

```yaml
apiVersion: crd.antrea.io/v1beta1
kind: NetworkPolicy
metadata:
  name: ledger-ingress
  namespace: payments
spec:
  priority: 5
  tier: application
  appliedTo:
    - podSelector:
        matchLabels:
          app: ledger
  ingress:
    - name: allow-checkout
      action: Allow
      from:
        - podSelector:
            matchLabels:
              app: checkout
      ports:
        - protocol: TCP
          port: 8443
      enableLogging: true
      logLabel: pci-ledger-allow
    - name: drop-everything-else
      action: Drop
      from:
        - namespaceSelector: {}
        - ipBlock:
            cidr: 0.0.0.0/0
      enableLogging: true
      logLabel: pci-ledger-drop
```

For **standard** Kubernetes `NetworkPolicy` objects, Antrea enables logging per namespace through an annotation. The logs then cover the allow rules and the implicit isolation (default deny) that the K8s policies in that namespace create:

```
$ kubectl annotate namespace payments networkpolicy.antrea.io/enable-logging="true"
namespace/payments annotated
```

Reading the log. The exact column set varies slightly across Antrea versions:

```
$ kubectl -n kube-system exec ds/antrea-agent -c antrea-agent -- \
    tail -n 2 /var/log/antrea/networkpolicy/np.log
2026/09/30 02:14:03.512873 AntreaPolicyIngressRule AntreaNetworkPolicy:payments/ledger-ingress drop-everything-else Drop 44900 payments/ledger-7d9c4f6b8-q7m2n 10.0.1.23 48212 10.0.2.41 8443 TCP 60 pci-ledger-drop [1 packets in 0s]
2026/09/30 02:14:05.004211 AntreaPolicyIngressRule AntreaNetworkPolicy:payments/ledger-ingress allow-checkout Allow 44901 payments/ledger-7d9c4f6b8-q7m2n 10.0.1.19 51544 10.0.2.41 8443 TCP 60 pci-ledger-allow [1 packets in 0s]
```

Antrea deduplicates bursts (`[N packets in T]`) and rate-limits logging in the agent. **A log line is not one per packet.** Keep this in mind when counting events.

### 5.2 Calico OSS: the `Log` action

With the **iptables/nftables** dataplane, a rule with `action: Log` writes the packet to the kernel log and **continues evaluation**. Put it immediately before the `Deny` you want to observe:

```yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: pci-ledger-ingress
spec:
  order: 100
  selector: app == 'ledger'
  types:
    - Ingress
  ingress:
    - action: Allow
      protocol: TCP
      source:
        selector: app == 'checkout'
      destination:
        ports:
          - 8443
    - action: Log
      protocol: TCP
    - action: Deny
```

```
$ calicoctl apply -f pci-ledger-ingress.yaml
Successfully applied 1 'GlobalNetworkPolicy' resource(s)

# On the node that hosts the ledger pod
$ sudo journalctl -k --since "5 min ago" | grep calico-packet | tail -1
Sep 30 02:14:03 worker-2 kernel: calico-packet: IN=eth0 OUT=cali4f1a2b3c4d5 MAC=... SRC=10.0.1.23 DST=10.0.2.41 LEN=60 TOS=0x00 PREC=0x00 TTL=63 ID=51122 DF PROTO=TCP SPT=48212 DPT=8443 WINDOW=64240 RES=0x00 SYN URGP=0
```

Limitations to state clearly:

- The prefix (`calico-packet` by default, configurable in `FelixConfiguration.spec.logPrefix`) is the only link back to the policy. Use distinct prefixes if you need attribution.
- Kernel logging is expensive and unbounded. **Never put an unconditional `Log` in front of a high-traffic allow path.**
- The **eBPF dataplane does not implement `action: Log`**. There, use Calico's flow-log facilities: Goldmane/Whisker in Calico OSS 3.30+, or flow logs in Calico Enterprise/Cloud, which record the matched policies per flow.

---

## 6. L7: Gateway, Ingress and mesh access logs

Gateway API standardises routing but **not** logging. Access logging is always implementation-specific. Envoy-based implementations (Envoy Gateway, Istio, Contour, Cilium's own Envoy) share one format vocabulary, the Envoy command operators, which makes knowledge portable.

### 6.1 Envoy Gateway: structured JSON with trace correlation

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: access-logging
  namespace: envoy-gateway-system
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              authority: "%REQ(:AUTHORITY)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              protocol: "%PROTOCOL%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              response_code_details: "%RESPONSE_CODE_DETAILS%"
              upstream_transport_failure_reason: "%UPSTREAM_TRANSPORT_FAILURE_REASON%"
              bytes_received: "%BYTES_RECEIVED%"
              bytes_sent: "%BYTES_SENT%"
              duration_ms: "%DURATION%"
              upstream_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
              downstream_remote_address: "%DOWNSTREAM_REMOTE_ADDRESS%"
              x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              route_name: "%ROUTE_NAME%"
              request_id: "%REQ(X-REQUEST-ID)%"
              traceparent: "%REQ(TRACEPARENT)%"
              tls_version: "%DOWNSTREAM_TLS_VERSION%"
              sni: "%REQUESTED_SERVER_NAME%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: access-logging
    namespace: envoy-gateway-system
```

Things that are deliberately **not** logged: query strings (use `%REQ(:PATH)%` only if you have confirmed no tokens travel in URLs), `Authorization`, cookies, and bodies. Envoy Gateway can also send to an `OpenTelemetry` sink (OTLP) instead of, or in addition to, `File`, and supports per-setting `matches` (CEL expressions such as `response.code >= 400`) for filtering at the source.

```
$ kubectl -n envoy-gateway-system logs deploy/envoy-payments-gw-5f3c1a2b --tail=1 -c envoy | jq .
{
  "start_time": "2026-09-30T02:14:03.498Z",
  "method": "POST",
  "authority": "pay.example.com",
  "path": "/v1/checkout",
  "protocol": "HTTP/2",
  "response_code": 503,
  "response_flags": "UF",
  "response_code_details": "upstream_reset_before_response_started{connection_timeout}",
  "upstream_transport_failure_reason": null,
  "bytes_received": 412,
  "bytes_sent": 91,
  "duration_ms": 5002,
  "upstream_service_time": null,
  "downstream_remote_address": "203.0.113.54:61022",
  "x_forwarded_for": null,
  "upstream_host": "10.0.1.23:8080",
  "upstream_cluster": "httproute/payments/checkout/rule/0",
  "route_name": "httproute/payments/checkout/rule/0/match/0/pay_example_com",
  "request_id": "5c3b1f0e-2e0a-4c1a-9a7b-8f7f0f4c2d11",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "tls_version": "TLSv1.3",
  "sni": "pay.example.com"
}
```

### 6.2 `RESPONSE_FLAGS`: the L7-to-L4 bridge

This field tells you whether a `5xx` came from the application or from the network underneath it:

| Flag | Meaning | Next step |
|---|---|---|
| `UF` | Upstream connection failure | L3/L4: `hubble observe --to-ip <upstream_host> --verdict DROPPED` |
| `UH` | No healthy upstream | Endpoints empty or all unhealthy: `kubectl get endpointslices` |
| `NR` | No route configured | `HTTPRoute` not attached: check `status.parents[].conditions` |
| `URX` | Retry/connect limit exceeded | Upstream flapping, check pod restarts |
| `UT` | Upstream request timeout | App latency, or packets lost silently |
| `UC` | Upstream connection terminated | Upstream closed mid-request (OOM, idle timeout mismatch) |
| `DC` | Downstream connection terminated | Client gave up (its timeout is shorter than yours) |
| `RL` | Rate limited locally | Intended, check policy |
| `UAEX` | External authorization denied | Authz service decision |

In the record above, `UF` plus `connection_timeout` plus `upstream_host 10.0.1.23:8080` gives you a precise L4 question to ask Hubble. That is the core correlation move of this topic.

### 6.3 Istio: Telemetry API

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  accessLogging:
    - providers:
        - name: envoy
      filter:
        expression: "response.code >= 400 || connection.mtls == false"
---
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: payments-full
  namespace: payments
spec:
  accessLogging:
    - providers:
        - name: envoy
```

The root-namespace resource sets the mesh default (errors plus any plaintext connection, which is a useful audit signal in a STRICT-mTLS mesh). The namespace-scoped resource overrides it, so `payments` logs everything. The built-in `envoy` provider writes to the sidecar's (or ztunnel/waypoint's) stdout. For JSON, define an `envoyFileAccessLog` extension provider in `meshConfig` with `logFormat.labels`. In ambient mode, **ztunnel logs L4 connections** (with SPIFFE identities) and **waypoints log L7**. Know which component to query.

### 6.4 Source IP preservation: the silent log killer

An edge access log whose `downstream_remote_address` is always a node IP is useless as an audit record. Causes and fixes:

| Topology | What the Gateway sees | Fix |
|---|---|---|
| `Service type=LoadBalancer`, `externalTrafficPolicy: Cluster` | SNATed node IP | `externalTrafficPolicy: Local` (trade-off: uneven load, needs health-check node port) |
| Cloud L7 load balancer in front | LB's IP | Trust `X-Forwarded-For` with the correct number of trusted hops (EG `ClientTrafficPolicy.spec.clientIPDetection`) |
| L4 LB in front (NLB, MetalLB+HAProxy) | LB's IP | PROXY protocol on both ends (EG `ClientTrafficPolicy.spec.proxyProtocol`) |

---

## 7. DNS: the CoreDNS `log` plugin

Many "network" failures are resolution failures: `NXDOMAIN` from a typo in a Service name, `SERVFAIL` from an unreachable upstream, or timeouts because egress to kube-dns was denied. The `log` plugin records every query. In production, restrict it to `denial` (NXDOMAIN/NODATA) and `error` (SERVFAIL, REFUSED and similar) to keep volume sane.

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
        log . {
            class denial error
        }
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

```
$ kubectl apply -f coredns-cm.yaml
configmap/coredns configured

# The reload plugin picks the change up (checks every ~30s); no restart needed.
$ kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50 | grep -E 'reload|NXDOMAIN|SERVFAIL'
[INFO] Reloading
[INFO] plugin/reload: Running configuration SHA512 = 8c4f...e1
[INFO] Reloading complete
[INFO] 10.0.1.23:52311 - 40263 "A IN ledger.payment.svc.cluster.local. udp 61 false 512" NXDOMAIN qr,aa,rd 154 0.000151s
```

Field by field: client `10.0.1.23:52311`, query ID `40263`, type `A`, name `ledger.payment.svc.cluster.local.` (the namespace is `payments`, so this is a typo), transport `udp`, request size `61`, DO bit `false`, advertised buffer `512`, rcode `NXDOMAIN`, flags `qr,aa,rd`, response size `154`, and latency.

**What the absence of a log line means.** A client that times out on DNS while CoreDNS logs nothing (with `class all` temporarily enabled) means the query **never arrived**. That points to an egress policy drop, which Hubble or Antrea will show on port 53.

---

## 8. Node kernel: ground truth when everything else is ambiguous

Use these for ad hoc debugging only. They do not scale as an audit trail, but they cannot lie about NAT.

```
# Live connection events touching a ClusterIP (kube-proxy iptables/nftables mode)
$ sudo conntrack -E -d 10.96.142.7 -p tcp --dport 443
    [NEW] tcp      6 120 SYN_SENT src=10.0.1.23 dst=10.96.142.7 sport=48212 dport=443 [UNREPLIED] src=10.0.2.41 dst=10.0.1.23 sport=8443 dport=48212
 [UPDATE] tcp      6 60 SYN_RECV src=10.0.1.23 dst=10.96.142.7 sport=48212 dport=443 src=10.0.2.41 dst=10.0.1.23 sport=8443 dport=48212

# Insert-failure / drop counters per CPU
$ sudo conntrack -S | head -2
cpu=0   found=0 invalid=412 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=7
cpu=1   found=0 invalid=389 insert=0 insert_failed=0 drop=0 early_drop=0 error=0 search_restart=3
```

The reply tuple (`src=10.0.2.41 ... sport=8443`) proves which backend the ClusterIP was DNATed to. `[UNREPLIED]` that never becomes `ESTABLISHED` means the SYN reached the backend path but got no answer. With Cilium's kube-proxy replacement, use `cilium-dbg bpf ct list global` and `cilium-dbg bpf lb list` instead. The kernel's conntrack table is not used for service translation there.

---

## 9. Shipping: a Fluent Bit DaemonSet for flow and DNS logs

The pieces above write to node files (`events.log`, `np.log`) or container stdout. A node-level shipper centralises them. The complete manifest below tails the Hubble export and CoreDNS container logs and sends them to Loki with node labels.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: logging
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: logging
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.yaml: |
    service:
      flush: 2
      log_level: info
      http_server: on
      http_listen: 0.0.0.0
      http_port: 2020
      health_check: on
      storage.path: /var/fluent-bit/state/buffer
      storage.sync: normal
      storage.backlog.mem_limit: 16M
    parsers:
      - name: json_flow
        format: json
    pipeline:
      inputs:
        - name: tail
          tag: hubble.flows
          path: /var/run/cilium/hubble/events.log
          db: /var/fluent-bit/state/hubble.db
          parser: json_flow
          refresh_interval: 5
          rotate_wait: 10
          mem_buf_limit: 32M
          storage.type: filesystem
          skip_long_lines: on
        - name: tail
          tag: dns.coredns
          path: /var/log/containers/coredns-*_kube-system_coredns-*.log
          db: /var/fluent-bit/state/coredns.db
          multiline.parser: cri
          mem_buf_limit: 16M
          storage.type: filesystem
      filters:
        - name: record_modifier
          match: "*"
          record: cluster prod-eu-1
        - name: grep
          match: dns.coredns
          regex: log (NXDOMAIN|SERVFAIL|REFUSED)
      outputs:
        - name: loki
          match: hubble.flows
          host: loki-gateway.observability.svc
          port: 80
          labels: job=hubble-flows, node=${NODE_NAME}, cluster=prod-eu-1
          line_format: json
          retry_limit: false
        - name: loki
          match: dns.coredns
          host: loki-gateway.observability.svc
          port: 80
          labels: job=coredns, node=${NODE_NAME}, cluster=prod-eu-1
          line_format: key_value
          retry_limit: false
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: logging
  labels:
    app: fluent-bit
spec:
  selector:
    matchLabels:
      app: fluent-bit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.2.4
          args:
            - -c
            - /fluent-bit/etc/conf/fluent-bit.yaml
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          ports:
            - name: http
              containerPort: 2020
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            runAsUser: 0
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - DAC_READ_SEARCH
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/conf
              readOnly: true
            - name: hubble
              mountPath: /var/run/cilium/hubble
              readOnly: true
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: state
              mountPath: /var/fluent-bit/state
      volumes:
        - name: config
          configMap:
            name: fluent-bit-config
        - name: hubble
          hostPath:
            path: /var/run/cilium/hubble
            type: DirectoryOrCreate
        - name: varlog
          hostPath:
            path: /var/log
        - name: state
          hostPath:
            path: /var/fluent-bit/state
            type: DirectoryOrCreate
```

Design choices worth defending in a review:

- **`db:` offset databases on a hostPath.** A restarted shipper resumes where it stopped instead of re-sending or skipping. This is the idempotency property of the pipeline.
- **`storage.type: filesystem`** buffers to disk when Loki is unavailable, so a backend outage does not turn into audit gaps (up to the disk budget).
- **`rotate_wait`** keeps reading a rotated Hubble file for a short time, because the exporter rotates by size and you must not lose its tail.
- **The DNS `grep` filter** is defence in depth: even if someone switches CoreDNS to `class all`, only failures leave the node.
- **Low-cardinality Loki labels** (`job`, `node`, `cluster`). Never put pod names or IPs in labels; query them from the JSON body.

Verification:

```
$ kubectl -n logging rollout status ds/fluent-bit
daemon set "fluent-bit" successfully rolled out

$ kubectl -n logging port-forward ds/fluent-bit 2020:2020 &
$ curl -s localhost:2020/api/v1/metrics | jq '.input, .output | with_entries(.value |= {records, errors, retries})'
{
  "tail.0": { "records": 18422, "errors": null, "retries": null },
  "tail.1": { "records": 37, "errors": null, "retries": null }
}
{
  "loki.0": { "records": 18422, "errors": 0, "retries": 0 },
  "loki.1": { "records": 37, "errors": 0, "retries": 0 }
}
```

Query in Loki (LogQL). These are the top denied pairs in `payments` over 1 hour:

```
topk(10,
  sum by (src, dst, port) (
    count_over_time(
      {job="hubble-flows"} | json
        verdict="flow_verdict",
        src="flow_source_pod_name",
        dst="flow_destination_pod_name",
        ns="flow_destination_namespace",
        port="flow_l4_TCP_destination_port"
      | verdict="DROPPED" | ns="payments" [1h]
    )
  )
)
```

---

## 10. Correlating across layers: one incident, end to end

Here is the 02:14 incident walked through the layers:

```
1. Edge (Envoy Gateway)
   request_id=5c3b1f0e...  traceparent=00-4bf92f35...  503 UF connection_timeout
   upstream_host=10.0.1.23:8080 (checkout)

2. Checkout's own logs (grep trace ID 4bf92f35...)
   "calling ledger:8443 ... context deadline exceeded"

3. DNS (CoreDNS, denial/error)
   nothing for ledger.payments → name resolved fine (it's cached / correct)

4. L3/L4 (Hubble export)
   02:14:03.512 checkout(ID:31844) -> ledger(ID:52011):8443 policy-verdict:none INGRESS DENIED

5. Control plane (API audit)
   02:13:47 ci:deployer patch networkpolicies/payments-ingress via argocd
   requestObject removed podSelector app=checkout from spec.ingress[0].from
```

The join keys are:

| From → to | Key |
|---|---|
| Edge → app | `x-request-id`, W3C `traceparent` (propagated by the app) |
| Edge → flows | `upstream_host` IP:port plus a time window of ±2 s |
| Flow → workload | Pod name/namespace/identity (already resolved by Hubble; Antrea gives pod names too) |
| Flow → policy change | Destination namespace/policy name plus "last mutation before the first DROPPED" |

**Clock discipline is part of the design.** Correlation windows of a few seconds only work with NTP/chrony synchronised across nodes. Store everything in UTC with sub-second precision (Hubble uses RFC 3339 nanoseconds; configure Envoy's `%START_TIME%` likewise).

---

## 11. Verification and failure diagnosis

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| `hubble observe` hangs or returns `connection refused` | Relay not deployed, or port-forward died | `cilium status` shows `Hubble Relay: disabled`; `jobs` | `cilium hubble enable --relay`; re-run `cilium hubble port-forward` |
| `Connected Nodes: 2/3` | Agent on one node unhealthy or Hubble server TLS mismatch | `kubectl -n kube-system logs deploy/hubble-relay` shows peer errors | Restart that node's agent; check `hubble-relay-client-certs` |
| Flow you *know* happened is absent | Ring buffer wrapped | `hubble status` at 100% | Use the exporter; increase `hubble.eventBufferCapacity` (power of two minus one) |
| `events.log` does not exist | Export not enabled, or old key names for the chart version | `cilium config view \| grep hubble-export` is empty | Fix values against `helm show values`; roll the DaemonSet |
| `events.log` exists but has only a few lines | `allowList` too narrow (it's an OR of ANDs) | Run the same filter live: `hubble observe --verdict DROPPED` | Adjust the filter; remember that `denyList` wins |
| No `l7` fields in flows | No L7 rule on that port, or traffic is TLS | `hubble observe --protocol http` is empty; `cilium-dbg endpoint list` shows no L7 policy | Add an L7 visibility rule on a plaintext port |
| `AUDIT` verdicts never appear | Audit mode not enabled on that endpoint, or policy actually allows the traffic | `cilium-dbg endpoint get <id> -o jsonpath='{[0].spec.options}'` | Enable `PolicyAuditMode`; test with a known-denied flow |
| Antrea `np.log` empty | Rule lacks `enableLogging: true`, or namespace annotation missing for K8s NP | `kubectl get anp -n payments -o yaml \| grep enableLogging` | Add it; re-test |
| Calico `Log` rule produces nothing | eBPF dataplane, or rule order puts `Log` after the `Deny` | `kubectl get felixconfiguration default -o yaml \| grep bpfEnabled` | Use flow logs on eBPF; move `Log` before `Deny` |
| Kernel log flooded with `calico-packet` | Unconditional `Log` on a busy path | `journalctl -k \| grep -c calico-packet` | Scope the `Log` rule with protocol/selector; put it only before `Deny` |
| Gateway access log is plain text, not JSON | `EnvoyProxy` not attached | `kubectl get gatewayclass eg -o yaml` lacks `parametersRef`; `status.conditions` | Attach via GatewayClass or `Gateway.spec.infrastructure.parametersRef` |
| All client IPs are node IPs | `externalTrafficPolicy: Cluster` / no PROXY protocol | `kubectl get svc -n envoy-gateway-system -o yaml \| grep externalTrafficPolicy` | See 6.4 |
| CoreDNS change did nothing | `reload` plugin missing, or YAML indentation broke the Corefile | `kubectl -n kube-system logs -l k8s-app=kube-dns \| grep -i reload` | Restore `reload`; `kubectl -n kube-system rollout restart deploy/coredns` |
| Audit log missing after editing kube-apiserver | Missing hostPath mount → apiserver crash-loop | `crictl ps -a --name kube-apiserver` shows `Exited` | Add `volumeMounts`/`volumes` as in 3.2 |
| Shipper shows `retries` climbing | Backend unreachable, or a NetworkPolicy blocks the shipper's egress | `hubble observe --from-pod logging/fluent-bit-xxxxx --verdict DROPPED` | Allow egress from `logging` to the log backend (your audit pipeline is subject to policy too) |
| Log volume exploded after a change | Someone enabled `class all` / removed a filter | Loki ingestion rate per `job` | Restore filters; alert on ingestion rate per job |

### Quick self-check routine

```
# 1. Is flow observation healthy everywhere?
$ hubble status

# 2. Is persistence configured and writing?
$ cilium config view | grep hubble-export-file-path
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- ls -l /var/run/cilium/hubble/

# 3. Generate a known denial and follow it through every layer
$ kubectl -n payments run probe --rm -it --image=busybox:1.36 --restart=Never -- \
    wget -T 3 -qO- http://ledger:8080/healthz
wget: download timed out
$ hubble observe --from-pod payments/probe --verdict DROPPED --last 2
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    grep -c '"pod_name":"probe"' /var/run/cilium/hubble/events.log

# 4. Confirm the change trail exists
$ sudo tail -n 1 /var/log/kubernetes/audit/audit.log | jq '.auditID, .stage'
```

A synthetic, known-denied probe is the only way to **prove** that the pipeline would have captured the real incident. Without it, "0 denials logged" might mean nothing was denied, or it might mean the pipeline is broken.

---

## 12. Governance: retention, privacy, integrity

| Concern | Recommendation |
|---|---|
| **Retention** | Hot (queryable) 14–30 days for flows/access logs; cold/immutable 1 year or more for API audit and regulated-segment flows (PCI-DSS requires 12 months, 3 immediately available) |
| **Personal data** | IP addresses are personal data under GDPR. Document the lawful basis (security) and minimise with field masks; redact URL queries, userinfo and auth headers at the source (`hubble.redact`, Envoy format); never log bodies |
| **Integrity** | Ship off-node quickly (a compromised node can edit local files); use object-lock/WORM storage for the compliance tier; restrict who can delete log streams |
| **Access** | Flow logs reveal the whole service topology, which is valuable to attackers. Apply RBAC to Hubble Relay/UI and to the log backend |
| **Cost control** | Alert on ingestion rate per `job`; review filters when adding namespaces; prefer metrics for trends and logs for evidence |
| **Protect the auditors** | The logging namespace needs its own NetworkPolicy allowing egress to the backend. Monitor shipper `errors`/`retries` as a first-class SLO |

---

## 13. Exam-oriented summary

- Kubernetes `NetworkPolicy` has **no logging**. Auditing is always a CNI, proxy or DNS feature.
- `hubble observe` flags to know by heart: `--namespace`, `--from-pod`, `--to-pod`, `--verdict DROPPED|FORWARDED|AUDIT|ERROR`, `--type policy-verdict|drop|l7`, `--protocol dns|http`, `--port`, `--last`, `--follow`, `-o json`.
- A `policy-verdict:none ... DENIED` followed by `Policy denied DROPPED` means **no rule allows this flow**. SYN-only retransmits confirm the connection never established.
- L7 fields require an **L7 rule**. DNS visibility requires a `dns` rule.
- The Hubble ring buffer is not durable. **Export** is: `allowList`/`denyList` are JSON FlowFilters (OR of ANDs, deny wins) plus `fieldMask`.
- **Audit mode** (Cilium `AUDIT`, Antrea/Calico logging before a deny) is how you roll out default-deny safely.
- Envoy `RESPONSE_FLAGS` (`UF`, `UH`, `NR`, `UT`, `UC`, `DC`) link an L7 error to an L4 cause.
- Edge logs are only as good as **source-IP preservation**.
- Who changed a policy lives in the **kube-apiserver audit log** at `RequestResponse` level.

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes: Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes: Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes: Preserving the client source IP: https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip
- Cilium: Hubble observability: https://docs.cilium.io/en/stable/observability/hubble/
- Cilium: Hubble exporter configuration: https://docs.cilium.io/en/stable/observability/hubble/configuration/export/
- Cilium: Creating policies from verdicts (policy audit mode): https://docs.cilium.io/en/stable/security/policy-creation/
- Cilium: Layer 7 policy and visibility: https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- Antrea: Antrea-native NetworkPolicy (including logging): https://antrea.io/docs/main/docs/antrea-network-policy/
- Calico: GlobalNetworkPolicy resource (`Log` action): https://docs.tigera.io/calico/latest/reference/resources/globalnetworkpolicy
- Calico: Felix configuration (`logPrefix`): https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- Calico: Observability / flow logs: https://docs.tigera.io/calico/latest/observability/
- Envoy: Access log command operators and response flags: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- Envoy Gateway: Proxy access logs: https://gateway.envoyproxy.io/docs/tasks/observability/proxy-accesslog/
- Envoy Gateway: Client IP detection / ClientTrafficPolicy: https://gateway.envoyproxy.io/docs/tasks/traffic/client-traffic-policy/
- Gateway API: https://gateway-api.sigs.k8s.io/
- Istio: Configure access logging with the Telemetry API: https://istio.io/latest/docs/tasks/observability/logs/telemetry-api/
- CoreDNS: `log` plugin: https://coredns.io/plugins/log/
- Fluent Bit documentation: https://docs.fluentbit.io/manual/
- Grafana Loki: LogQL: https://grafana.com/docs/loki/latest/query/