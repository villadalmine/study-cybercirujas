# Guided Exercises — Domain 4.1: Observability with Cilium

> **Exam weight: 20%.** This is the second-heaviest domain in the CCA. Almost every question in it reduces to one of three skills: *reading a Hubble flow line correctly*, *choosing the right filter to isolate a problem*, and *knowing which layer of the stack (Hubble ⇄ agent ⇄ eBPF datapath) actually holds the answer you need.*
>
> Work through these in order. Each block is a set of numbered steps you execute, followed by comprehension checks. Do not read the answers until you have written yours down — the exam rewards recall of exact verdict/type semantics, and you only build that by predicting output before you see it.

---

## Lab prerequisites

| Requirement | Version used in this lab | Note |
|---|---|---|
| `kind` | ≥ 0.24 | any Kubernetes-in-Docker host works |
| `kubectl` | matching cluster minor | |
| `helm` | ≥ 3.13 | Cilium is installed via Helm here so every value is explicit |
| `cilium` CLI | ≥ 0.16 | [github.com/cilium/cilium-cli](https://github.com/cilium/cilium-cli) |
| `hubble` CLI | ≥ 1.16 | [github.com/cilium/hubble](https://github.com/cilium/hubble) |
| Cilium | 1.16.x | pin `CILIUM_VERSION` below; check the release you are studying against |

```bash
export CILIUM_VERSION=1.16.5
export KUBECONFIG=$HOME/.kube/cca-lab.config
```

Everything below runs on a laptop. No cloud account is required.

---

## Exercise 0 — Build an observable cluster from scratch

The point of this exercise is that **observability is an install-time decision**. Hubble is not a sidecar you bolt on; it is a consumer of an event ring buffer inside the Cilium agent, and if the agent was started without it, no history exists to recover.

### Steps

1. Write the kind configuration. Cilium replaces both the CNI and (here) kube-proxy, so both defaults must be disabled:

   ```yaml
   # kind-cca.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: cca-lab
   networking:
     disableDefaultCNI: true
     kubeProxyMode: none
     podSubnet: "10.244.0.0/16"
     serviceSubnet: "10.96.0.0/12"
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   ```

2. Create the cluster:

   ```bash
   kind create cluster --config kind-cca.yaml
   kubectl get nodes
   ```

   Expected — every node is `NotReady`, because there is no CNI yet:

   ```
   NAME                    STATUS     ROLES           AGE   VERSION
   cca-lab-control-plane   NotReady   control-plane   38s   v1.31.0
   cca-lab-worker          NotReady   <none>          25s   v1.31.0
   cca-lab-worker2         NotReady   <none>          25s   v1.31.0
   ```

3. Write an explicit Helm values file. Using a values file rather than a wall of `--set` flags avoids the comma-escaping trap in `labelsContext`, and it is what you would keep in Git in production:

   ```yaml
   # cilium-values.yaml
   kubeProxyReplacement: true
   k8sServiceHost: cca-lab-control-plane
   k8sServicePort: 6443

   # Agent + operator self-metrics (separate from Hubble's flow metrics)
   prometheus:
     enabled: true
     port: 9962
   operator:
     prometheus:
       enabled: true
       port: 9963

   hubble:
     enabled: true                # turns on the observer inside the agent
     eventBufferCapacity: 16383   # per-node ring buffer of flows (default 4095)
     relay:
       enabled: true              # cluster-wide aggregation
     ui:
       enabled: true              # service map
     metrics:
       enabled:
         - "dns:query;ignoreAAAA"
         - drop
         - tcp
         - flow
         - port-distribution
         - icmp
         - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
       enableOpenMetrics: true
       port: 9965
   ```

4. Install Cilium and wait for it:

   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm repo update
   helm install cilium cilium/cilium \
     --version "${CILIUM_VERSION}" \
     --namespace kube-system \
     --values cilium-values.yaml

   cilium status --wait
   ```

   Expected — note that `Hubble Relay` and `Hubble UI` are reported as *separate* deployments from the agent:

   ```
       /¯¯\
    /¯¯\__/¯¯\    Cilium:             OK
    \__/¯¯\__/    Operator:           OK
    /¯¯\__/¯¯\    Envoy DaemonSet:    OK
    \__/¯¯\__/    Hubble Relay:       OK
       \__/       ClusterMesh:        disabled

   DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
   Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1
   Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
   Containers:            cilium             Running: 3
                          hubble-relay       Running: 1
                          hubble-ui          Running: 1
   ```

5. Confirm the observer is actually enabled *inside the agent*, not just that a Deployment exists:

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A3 Hubble
   ```

   Expected:

   ```
   Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 42.17   Metrics: Ok
   ```

   > `cilium-dbg` is the in-agent debug CLI (renamed from `cilium` in 1.16; the old name may still exist as a deprecated alias). The `cilium` binary you run on your laptop is a *different program* — the cilium-cli, which talks to the Kubernetes API. Confusing the two is a classic exam trap.

6. Deploy the canonical demo workload:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/minikube/http-sw-app.yaml
   kubectl wait --for=condition=Ready pod --all --timeout=120s
   kubectl get pods --show-labels
   ```

   Expected:

   ```
   NAME                         READY   STATUS    LABELS
   deathstar-8555bf78d9-5x9lk   1/1     Running   class=deathstar,org=empire,...
   deathstar-8555bf78d9-p4tzq   1/1     Running   class=deathstar,org=empire,...
   tiefighter                   1/1     Running   class=tiefighter,org=empire
   xwing                        1/1     Running   class=xwing,org=alliance
   ```

7. Generate a request so there is something to observe:

   ```bash
   kubectl exec tiefighter -- \
     curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Expected: `Ship landed`

### Comprehension checks

- **Q0.1** — You inherit a cluster where an outage happened 20 minutes ago. `hubble.enabled` was `false` at the time; you enable it now and restart the agents. Can you retrieve the flows from the outage? Justify your answer in terms of where flow data lives.
- **Q0.2** — Why does `hubble-relay` being `Ready` tell you *nothing* about whether flows are being captured on a given node?
- **Q0.3** — `eventBufferCapacity` is set to `16383`. What is the unit, what is the scope (cluster, node, endpoint?), and what is the operational consequence of raising it?
- **Q0.4** — Name the four distinct Prometheus endpoints this install exposes and the default port of each. Which one is *not* enabled by anything in `cilium-values.yaml` above, and why does it exist anyway?

---

## Exercise 1 — The three layers of Hubble

Hubble is not one component. Understanding the split is worth exam points and is the difference between debugging a single node and debugging a cluster.

```
┌──────────────────────────── node ────────────────────────────┐
│  eBPF datapath  ──perf ring buffer──▶  cilium-agent          │
│                                        └─ Hubble observer    │
│                                           ├─ unix:///var/run/cilium/hubble.sock
│                                           └─ tcp :4244  ─────┼──▶ hubble-relay :4245 ──▶ hubble CLI / UI
└──────────────────────────────────────────────────────────────┘
```

### Steps

1. Talk to the **node-local** observer, from inside an agent pod:

   ```bash
   AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
     -o jsonpath='{.items[0].metadata.name}')
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     hubble observe --last 5
   ```

2. Now open a port-forward to **Relay** and talk to the cluster-wide view:

   ```bash
   cilium hubble port-forward &
   sleep 3
   hubble status
   ```

   Expected:

   ```
   Healthcheck (via localhost:4245): Ok
   Current/Max Flows: 49,149/49,149 (100.00%)
   Flows/s: 126.44
   Connected Nodes: 3/3
   ```

3. Prove the scope difference explicitly:

   ```bash
   hubble list nodes
   ```

   Expected:

   ```
   NAME                    STATUS      AGE   FLOWS/S   CURRENT/MAX-FLOWS
   cca-lab-control-plane   Connected   14m   38.21     16,383/16,383 (100.00%)
   cca-lab-worker          Connected   14m   44.09     16,383/16,383 (100.00%)
   cca-lab-worker2         Connected   14m   44.14     16,383/16,383 (100.00%)
   ```

4. Inspect how Relay reaches the agents — this is a mutual-TLS gRPC mesh by default in the Helm chart:

   ```bash
   kubectl -n kube-system get secret | grep hubble
   kubectl -n kube-system get svc hubble-peer hubble-relay
   ```

   Expected:

   ```
   hubble-ca-secret                 Opaque   2
   hubble-relay-client-certs        kubernetes.io/tls   3
   hubble-server-certs              kubernetes.io/tls   3

   NAME           TYPE        CLUSTER-IP     PORT(S)
   hubble-peer    ClusterIP   10.96.51.203   443/TCP
   hubble-relay   ClusterIP   10.96.140.11   80/TCP
   ```

5. Simulate a partial outage and watch the observability plane degrade honestly:

   ```bash
   kubectl -n kube-system delete pod -l k8s-app=cilium \
     --field-selector spec.nodeName=cca-lab-worker2
   hubble status
   ```

   Expected, briefly:

   ```
   Healthcheck (via localhost:4245): Ok
   Connected Nodes: 2/3
   Unavailable Nodes: 1
     - cca-lab-worker2: rpc error: code = Unavailable desc = connection error
   ```

### Comprehension checks

- **Q1.1** — Which port does the agent's Hubble server listen on, and which port does Relay serve to clients? Which of the two does `cilium hubble port-forward` forward?
- **Q1.2** — What is the `hubble-peer` Service for? Why is it a Service and not a hard-coded node list?
- **Q1.3** — In step 5, `hubble status` still reports `Ok` while one node is unreachable. Explain why that is the correct design and what it means for an alert you would write on this.
- **Q1.4** — You run `hubble observe` from inside an agent pod on `worker` and see nothing for a pod you know is running. Before suspecting a bug, what is the single most likely explanation?

---

## Exercise 2 — Anatomy of a flow line

Every Hubble answer on the exam depends on parsing this one line correctly.

### Steps

1. Generate steady traffic in one terminal:

   ```bash
   kubectl exec tiefighter -- sh -c \
     'while true; do curl -s -XPOST deathstar.default.svc.cluster.local/v1/request-landing >/dev/null; sleep 1; done' &
   ```

2. Observe it:

   ```bash
   hubble observe --namespace default --follow
   ```

   Expected (one request produces several flows — this is the key insight):

   ```
   Sep  1 14:02:11.284: default/tiefighter:45678 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) to-endpoint FORWARDED (UDP)
   Sep  1 14:02:11.301: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-overlay FORWARDED (TCP Flags: SYN)
   Sep  1 14:02:11.302: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: SYN)
   Sep  1 14:02:11.302: default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) -> default/tiefighter:45678 (ID:23459) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
   Sep  1 14:02:11.305: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
   Sep  1 14:02:11.311: default/tiefighter:45678 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
   ```

3. Decode the same flow as structured data — this is what you would ship to a SIEM:

   ```bash
   hubble observe --namespace default --last 1 --to-label class=deathstar -o json | jq '{
     time, verdict: .verdict, type: .Type,
     src: {ns: .source.namespace, pod: .source.pod_name, id: .source.identity, labels: .source.labels},
     dst: {ns: .destination.namespace, pod: .destination.pod_name, id: .destination.identity},
     l4: .l4, node: .node_name, event: .event_type
   }'
   ```

   Expected:

   ```json
   {
     "time": "2026-09-01T14:02:11.302Z",
     "verdict": "FORWARDED",
     "src": {
       "ns": "default", "pod": "tiefighter", "id": 23459,
       "labels": ["k8s:class=tiefighter", "k8s:io.kubernetes.pod.namespace=default", "k8s:org=empire"]
     },
     "dst": { "ns": "default", "pod": "deathstar-8555bf78d9-5x9lk", "id": 12551 },
     "l4": { "TCP": { "source_port": 45678, "destination_port": 80, "flags": { "SYN": true } } },
     "node_name": "cca-lab/cca-lab-worker",
     "event": { "type": 4, "sub_type": 0 }
   }
   ```

4. Look up what those numeric identities actually mean:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg identity list | head -20
   ```

   Expected:

   ```
   ID      LABELS
   1       reserved:host
   2       reserved:world
   3       reserved:unmanaged
   4       reserved:health
   5       reserved:init
   6       reserved:remote-node
   7       reserved:kube-apiserver
   8       reserved:ingress
   12551   k8s:class=deathstar
           k8s:io.cilium.k8s.policy.cluster=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
   23459   k8s:class=tiefighter
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
   ```

5. Note that the two `deathstar` replicas share **one** identity:

   ```bash
   hubble observe --last 200 --to-label class=deathstar -o json \
     | jq -r '"\(.destination.pod_name)\t\(.destination.identity)"' | sort -u
   ```

   Expected:

   ```
   deathstar-8555bf78d9-5x9lk	12551
   deathstar-8555bf78d9-p4tzq	12551
   ```

### Comprehension checks

- **Q2.1** — A single `curl` produced six flows. Explain what `to-overlay`, `to-endpoint` and `to-stack` mean and why one logical request can appear multiple times.
- **Q2.2** — Both `deathstar` pods report identity `12551`. What determines a security identity, and what is the direct consequence for policy scaling in a 5,000-pod cluster?
- **Q2.3** — Identity `2` is `reserved:world`. If you see `10.0.5.7 (ID:2) -> default/api:443`, what have you learned about the source, and what have you *not* learned?
- **Q2.4** — Which reserved identity would you filter on to find traffic to the Kubernetes API server, and why is having a dedicated identity for it useful in a policy audit?
- **Q2.5** — List the possible values of the `verdict` field. Which one means "policy denied *but* the packet was allowed through anyway", and when would you deliberately want that?

---

## Exercise 3 — Filtering like an SRE

Unfiltered `hubble observe` on a real cluster is a firehose. The exam expects fluency with the filter flags.

### Steps

1. Directional filters — note the difference between `--pod` and the directional variants:

   ```bash
   hubble observe --from-pod default/tiefighter --last 5
   hubble observe --to-pod   default/deathstar --last 5
   hubble observe --pod      default/tiefighter --last 5   # either direction
   ```

2. Label and identity filters — label filters survive pod restarts, IP filters do not:

   ```bash
   hubble observe --from-label org=empire --to-label class=deathstar --last 10
   hubble observe --identity 12551 --last 10
   ```

3. Protocol and port:

   ```bash
   hubble observe --protocol tcp --port 80 --last 10
   hubble observe --protocol dns --last 10
   ```

4. Verdict and event type — the two most useful filters during an incident:

   ```bash
   hubble observe --verdict DROPPED --last 20
   hubble observe --type drop --type policy-verdict --last 20
   ```

5. Time windows. `--since` accepts both durations and RFC3339 timestamps:

   ```bash
   hubble observe --since 5m --verdict DROPPED
   hubble observe --since 2026-09-01T14:00:00Z --until 2026-09-01T14:05:00Z --namespace default
   ```

6. Negation — find everything *except* the noisy known-good path:

   ```bash
   hubble observe --last 50 --not --to-namespace kube-system
   ```

7. Inspect the gRPC filter your flags actually compile into. This is the single best debugging tool when a filter "returns nothing":

   ```bash
   hubble observe --from-label org=empire --to-port 80 --verdict DROPPED --print-raw-filters
   ```

   Expected:

   ```yaml
   allowlist:
     - '{"source_label":["org=empire"],"destination_port":["80"],"verdict":["DROPPED"]}'
   ```

8. Build a triage one-liner you would actually keep:

   ```bash
   hubble observe --since 15m --verdict DROPPED -o json \
     | jq -r '[.source.namespace, .source.pod_name, .destination.namespace,
               .destination.pod_name, (.l4.TCP.destination_port // .l4.UDP.destination_port // "-"),
               .drop_reason_desc] | @tsv' \
     | sort | uniq -c | sort -rn | head
   ```

   Expected:

   ```
        41  default  xwing  default  deathstar-8555bf78d9-5x9lk  80  POLICY_DENIED
         3  default  xwing  kube-system  coredns-7db6d8ff4d-2q9wv  53  POLICY_DENIED
   ```

### Comprehension checks

- **Q3.1** — Within one `hubble observe` invocation, are multiple *different* flags (`--from-label` + `--to-port`) combined with AND or OR? What about repeating the *same* flag twice (`--type drop --type policy-verdict`)?
- **Q3.2** — Why should a runbook prefer `--from-label app=checkout` over `--from-ip 10.244.3.19`?
- **Q3.3** — `hubble observe --verdict DROPPED --since 1h` returns nothing on a cluster where you are certain packets were dropped 40 minutes ago. Give two independent explanations.
- **Q3.4** — What does `--print-raw-filters` output, and name a concrete bug it would catch that reading your own command line would not.

---

## Exercise 4 — Policy verdicts and drop forensics

This is the highest-yield exercise in the domain. "Why is this connection failing?" is the most common real question and the most common exam question.

### Steps

1. Apply an L3/L4 policy that allows only the Empire in:

   ```yaml
   # l4-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1
     namespace: default
   spec:
     description: "L4 policy to restrict deathstar access to empire ships only"
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f l4-policy.yaml
   ```

2. Confirm enforcement flipped on for the selected endpoints:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg endpoint list
   ```

   Expected — `Ingress` is now `Enabled` for deathstar only:

   ```
   ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS                    IPv4          STATUS
              ENFORCEMENT        ENFORCEMENT
   184        Enabled            Disabled          12551      k8s:class=deathstar       10.244.1.201  ready
                                                              k8s:org=empire
   1742       Disabled           Disabled          23459      k8s:class=tiefighter      10.244.1.87   ready
                                                              k8s:org=empire
   ```

3. Start a dedicated observer in a second terminal:

   ```bash
   hubble observe --follow --type policy-verdict --type drop --namespace default
   ```

4. Send an allowed request and a denied request:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed

   kubectl exec xwing -- curl -s --connect-timeout 5 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # (hangs, then: command terminated with exit code 28)
   ```

   Expected in the observer — note the **pair** of events for the deny:

   ```
   Sep  1 14:31:02.118: default/tiefighter:52984 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
   Sep  1 14:31:19.443: default/xwing:41010 (ID:24675) <> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
   Sep  1 14:31:19.443: default/xwing:41010 (ID:24675) <> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) Policy denied DROPPED (TCP Flags: SYN)
   ```

5. Read the drop reason as structured data:

   ```bash
   hubble observe --verdict DROPPED --last 1 -o json \
     | jq '{drop_reason: .drop_reason_desc, type: .event_type, dir: .traffic_direction, node: .node_name}'
   ```

   Expected:

   ```json
   {
     "drop_reason": "POLICY_DENIED",
     "type": { "type": 1, "sub_type": 133 },
     "dir": "INGRESS",
     "node": "cca-lab/cca-lab-worker"
   }
   ```

6. Now go one layer down and read the eBPF policy map for the enforcing endpoint. `184` is the deathstar endpoint ID from step 2:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   ```

   Expected — the `BYTES`/`PACKETS` columns are per-rule hit counters, which is observability the flow log cannot give you:

   ```
   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   BYTES   PACKETS   PREFIX
   Allow       0          reserved:unknown              80/TCP       NONE         0       0         16
   Allow       23459      k8s:class=tiefighter          80/TCP       NONE         4218    31        0
                          k8s:org=empire
   Allow       1          reserved:host                 ANY          NONE         610     9         0
   ```

7. Prove the counters move — the exam-relevant point is that a rule with `PACKETS 0` after weeks is a dead rule:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing >/dev/null
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg bpf policy get 184 | grep tiefighter -A0
   ```

8. Compare against the raw datapath event stream:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg monitor --type drop
   ```

   Then re-run the `xwing` curl. Expected:

   ```
   Listening for events on 8 CPUs with 64x4096 of shared memory
   Press Ctrl-C to quit
   xx drop (Policy denied) flow 0x9a3f21b8 to endpoint 184, ifindex 14, file bpf_lxc.c line 2091, , identity 24675->12551: 10.244.1.93:41014 -> 10.244.1.201:80 tcp SYN
   ```

9. Confirm the aggregate drop counter the agent exports:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg metrics list | grep drop_count
   ```

   Expected:

   ```
   cilium_drop_count_total   direction=INGRESS  reason=Policy denied   47.000000
   ```

### Comprehension checks

- **Q4.1** — Explain the difference between a `policy-verdict` event and a `drop` event. Why does one denied packet emit both, and when would you see a `policy-verdict` with no accompanying drop?
- **Q4.2** — What does `policy-verdict:L3-L4` mean versus `policy-verdict:none`? What are the other match-type values you might see?
- **Q4.3** — The `xwing` curl hung until timeout rather than getting `Connection refused`. What does that tell you about how Cilium enforces an L3/L4 deny, and how does it differ from an L7 deny?
- **Q4.4** — In step 2, `tiefighter`'s Ingress enforcement is `Disabled` while `deathstar`'s is `Enabled`. Explain the default-allow/default-deny model that produces this, and the operational risk it creates.
- **Q4.5** — You have a `CiliumNetworkPolicy` you believe is unused and want to delete it. Which command gives you evidence rather than a guess, and what exactly would you look at?
- **Q4.6** — When would you use `cilium-dbg monitor` instead of `hubble observe`? Name two capabilities `monitor` has that Hubble does not, and one major drawback.

---

## Exercise 5 — L7 visibility: HTTP

L3/L4 flows tell you *that* a connection happened. Answering "which endpoint returned 500?" requires the Envoy L7 proxy, and turning it on is a deliberate, costly choice.

### Steps

1. Confirm you currently have **no** HTTP visibility:

   ```bash
   hubble observe --protocol http --last 5
   # (no output)
   ```

2. Replace the L4 policy with an L7-aware one:

   ```yaml
   # l7-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1
     namespace: default
   spec:
     description: "L7 policy: empire ships may only request landing"
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
             rules:
               http:
                 - method: "POST"
                   path: "/v1/request-landing"
   ```

   ```bash
   kubectl apply -f l7-policy.yaml
   ```

3. Verify the redirect to the proxy appeared in the eBPF policy map — the `PROXY PORT` column is now non-zero:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   ```

   Expected:

   ```
   DIRECTION   IDENTITY   LABELS (source:key[=value])   PORT/PROTO   PROXY PORT   BYTES   PACKETS   PREFIX
   Allow       23459      k8s:class=tiefighter          80/TCP       17423        6104     44        0
                          k8s:org=empire
   ```

4. Exercise both the allowed and the forbidden API call:

   ```bash
   kubectl exec tiefighter -- curl -s -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed

   kubectl exec tiefighter -- curl -s -XPUT \
     deathstar.default.svc.cluster.local/v1/exhaust-port
   # Access denied
   ```

5. Observe the L7 flows:

   ```bash
   hubble observe --protocol http --last 10
   ```

   Expected:

   ```
   Sep  1 15:10:04.221: default/tiefighter:54012 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
   Sep  1 15:10:04.229: default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) -> default/tiefighter:54012 (ID:23459) http-response FORWARDED (HTTP/1.1 200 8ms (POST http://deathstar.default.svc.cluster.local/v1/request-landing))
   Sep  1 15:10:12.884: default/tiefighter:54020 (ID:23459) -> default/deathstar-8555bf78d9-5x9lk:80 (ID:12551) http-request DROPPED (HTTP/1.1 PUT http://deathstar.default.svc.cluster.local/v1/exhaust-port)
   ```

6. Filter on HTTP semantics — this is what you cannot do at L4:

   ```bash
   hubble observe --http-method PUT --last 10
   hubble observe --http-path /v1/exhaust-port --last 10
   hubble observe --http-status 200 --last 10
   ```

7. Extract latency, which only the `http-response` event carries:

   ```bash
   hubble observe --protocol http --last 100 -o json \
     | jq -r 'select(.l7.http.code != null)
              | [.l7.http.code, .l7.latency_ns, .l7.http.method, .l7.http.url] | @tsv'
   ```

   Expected:

   ```
   200	8214000	POST	http://deathstar.default.svc.cluster.local/v1/request-landing
   200	6109000	POST	http://deathstar.default.svc.cluster.local/v1/request-landing
   ```

8. Measure the cost. Compare the round-trip with and without the proxy in path:

   ```bash
   kubectl exec tiefighter -- sh -c \
     'for i in $(seq 1 20); do curl -s -o /dev/null -w "%{time_total}\n" \
       -XPOST deathstar.default.svc.cluster.local/v1/request-landing; done' \
     | awk '{s+=$1} END {print "mean:", s/NR, "s"}'
   ```

   Then `kubectl apply -f l4-policy.yaml` and repeat. The L7 path is measurably slower because every packet is now user-space-terminated by Envoy.

> **Production note on the visibility annotation.** Older material teaches `policy.cilium.io/proxy-visibility: "<Ingress/80/TCP/HTTP>"` (originally `io.cilium.proxy-visibility`) as a way to get L7 flows without writing an L7 policy. That annotation has been deprecated and removed in recent releases in favour of L7 policy rules. Check the upgrade guide for the exact version you run; the portable mechanism — and the one to give on the exam unless the question names the annotation — is an L7-aware `CiliumNetworkPolicy`.

### Comprehension checks

- **Q5.1** — What architectural change happens to the packet path when you add an `http:` rule, and how do you *prove* it happened from the CLI without sending traffic?
- **Q5.2** — The forbidden `PUT` produced `Access denied` immediately, whereas the L3/L4 deny in Exercise 4 hung until timeout. Explain the mechanical reason for the difference.
- **Q5.3** — An `http-request` flow with verdict `DROPPED` — did any packet get dropped by eBPF? What actually happened on the wire?
- **Q5.4** — Why does `latency_ns` appear only on `http-response` events and never on `http-request`?
- **Q5.5** — You want HTTP visibility for an audit but must not change the security posture of the namespace. Write the `rules.http` stanza that achieves this, and state the two costs you are accepting.

---

## Exercise 6 — L7 visibility: DNS and FQDN

DNS is where most "intermittent, unexplainable" incidents live, and Cilium's DNS proxy is the only component that sees the question and the answer together.

### Steps

1. Confirm you have no DNS visibility yet:

   ```bash
   hubble observe --protocol dns --last 5
   # (no output — DNS is just UDP/53 to the datapath)
   ```

2. Apply an egress policy that engages the DNS proxy and restricts destinations by FQDN:

   ```yaml
   # dns-egress-policy.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: tiefighter-egress
     namespace: default
   spec:
     description: "Observe all DNS, allow egress only to the empire CDN"
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       # 1. Allow DNS to kube-dns AND enable the L7 DNS proxy for every query
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
       # 2. Allow egress to a specific FQDN only
       - toFQDNs:
           - matchName: "www.cncf.io"
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
       # 3. Keep in-cluster access working
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f dns-egress-policy.yaml
   ```

3. Generate one allowed and one denied lookup:

   ```bash
   kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' https://www.cncf.io
   # 200
   kubectl exec tiefighter -- curl -s -o /dev/null --connect-timeout 5 https://www.example.com
   # (exit 28)
   ```

4. Observe DNS at L7:

   ```bash
   hubble observe --protocol dns --last 10
   ```

   Expected — the query and the resolved answer are both visible:

   ```
   Sep  1 15:44:03.881: default/tiefighter:40391 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) dns-request proxy FORWARDED (DNS Query www.cncf.io. A)
   Sep  1 15:44:03.904: kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) -> default/tiefighter:40391 (ID:23459) dns-response proxy FORWARDED (DNS Answer "104.22.7.82" TTL: 30 (Proxy www.cncf.io. A))
   Sep  1 15:44:11.220: default/tiefighter:33150 (ID:23459) -> kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) dns-request proxy FORWARDED (DNS Query www.example.com. A)
   Sep  1 15:44:11.245: kube-system/coredns-7db6d8ff4d-2q9wv:53 (ID:16558) -> default/tiefighter:33150 (ID:23459) dns-response proxy FORWARDED (DNS Answer "93.184.215.14" TTL: 30 (Proxy www.example.com. A))
   Sep  1 15:44:11.246: default/tiefighter:52288 (ID:23459) <> 93.184.215.14:443 (ID:16777217) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
   ```

5. Filter by resolved name — note this works even though the flow is to a bare IP:

   ```bash
   hubble observe --fqdn "www.cncf.io" --last 10
   hubble observe --to-fqdn "*.cncf.io" --last 10
   ```

6. Inspect the FQDN cache the proxy built, which is what the policy is actually enforced against:

   ```bash
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- \
     cilium-dbg fqdn cache list
   ```

   Expected:

   ```
   ENDPOINT   FQDN            TTL   EXPIRATION                     IPS
   1742       www.cncf.io.    30    2026-09-01T15:44:33.904Z       104.22.7.82,104.22.6.82
   1742       www.example.com. 30   2026-09-01T15:44:41.245Z       93.184.215.14
   ```

7. Find the top talkers by DNS name — a standard weekly hygiene query:

   ```bash
   hubble observe --protocol dns --since 10m -o json \
     | jq -r 'select(.l7.dns.qtypes != null) | .l7.dns.query' \
     | sort | uniq -c | sort -rn | head
   ```

### Comprehension checks

- **Q6.1** — Why did adding a `dns:` rule to an *egress* policy produce visibility, when adding no policy at all produced none? What component does the `dns:` rule instantiate?
- **Q6.2** — In step 4, `www.example.com` **resolved successfully** and was then denied at TCP SYN. Explain why the DNS answer was allowed through, and what that split means when you are debugging "DNS works but the app can't connect".
- **Q6.3** — Identity `16777217` appeared for the external IP. What class of identity is that, and how does it differ from `reserved:world` (ID 2)?
- **Q6.4** — `hubble observe --fqdn www.cncf.io` matched a flow whose destination field is an IP address. Where does that name→IP association come from, and what happens to the match after the TTL expires?
- **Q6.5** — A `toFQDNs` policy intermittently blocks a legitimate host. Give the two most likely DNS-related root causes and the command that distinguishes them.

---

## Exercise 7 — The service map (Hubble UI)

### Steps

1. Open the UI:

   ```bash
   cilium hubble ui
   # forwards hubble-ui:80 -> localhost:12000 and opens a browser
   ```

2. Select the `default` namespace. You should see nodes for `tiefighter`, `xwing`, `deathstar`, plus `kube-dns` and a `world` node, with directed edges annotated by port and verdict colour.

3. Generate a denial and watch the edge turn red:

   ```bash
   kubectl exec xwing -- curl -s --connect-timeout 3 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing || true
   ```

4. Click the red edge. The lower pane shows the flow table with the same fields as `hubble observe`; use the filter box with the same syntax (`org=empire`, `dns=www.cncf.io`).

5. Confirm what the UI is actually reading:

   ```bash
   kubectl -n kube-system get deploy hubble-ui -o jsonpath='{.spec.template.spec.containers[*].name}'
   ```

   Expected:

   ```
   frontend backend
   ```

   The `backend` container is a gRPC client of `hubble-relay`. The UI has no privileged access to the datapath.

### Comprehension checks

- **Q7.1** — Hubble UI shows a service map. Is that map built from the Kubernetes Service objects, from observed traffic, or from network policies? What does your answer imply about a service that receives no traffic?
- **Q7.2** — Your security team asks for a 30-day dependency diagram for an audit. Why is Hubble UI the wrong tool, and what would you build instead?
- **Q7.3** — Hubble UI is empty for a namespace where `hubble observe --namespace X` returns flows. Name two configuration causes.

---

## Exercise 8 — Metrics: from flows to time series

Flows are events; metrics are the aggregate you alert on. The trade-off you must be able to articulate is **cardinality**.

### Steps

1. Confirm the metrics endpoint exists and is separate from the agent's own metrics:

   ```bash
   kubectl -n kube-system get svc hubble-metrics -o yaml | grep -A5 annotations
   ```

   Expected:

   ```yaml
   annotations:
     prometheus.io/port: "9965"
     prometheus.io/scrape: "true"
   ```

2. Scrape it by hand:

   ```bash
   kubectl -n kube-system port-forward svc/hubble-metrics 9965:9965 &
   sleep 2
   curl -s localhost:9965/metrics | grep -E '^hubble_(drop|flows|http)' | head -20
   ```

   Expected:

   ```
   hubble_drop_total{destination="default/deathstar",protocol="TCP",reason="POLICY_DENIED",source="default/xwing"} 47
   hubble_flows_processed_total{destination="default/deathstar",protocol="TCP",subtype="to-endpoint",type="Trace",verdict="FORWARDED"} 8134
   hubble_http_requests_total{method="POST",protocol="HTTP/1.1",reporter="server",source_workload="tiefighter",destination_workload="deathstar",status="200"} 612
   hubble_http_request_duration_seconds_bucket{le="0.005",...} 388
   ```

3. Compare with the *agent's own* metrics, on a different port:

   ```bash
   kubectl -n kube-system port-forward ds/cilium 9962:9962 &
   sleep 2
   curl -s localhost:9962/metrics | grep -E '^cilium_(drop_count|policy|endpoint_state|bpf_map)' | head
   ```

   Expected:

   ```
   cilium_drop_count_total{direction="INGRESS",reason="Policy denied"} 47
   cilium_policy_endpoint_enforcement_status{enforcement="both"} 2
   cilium_endpoint_state{endpoint_state="ready"} 12
   cilium_bpf_map_pressure{map_name="cilium_policy_00184"} 0.0031
   ```

4. Deliberately blow up cardinality and observe the cost:

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --reuse-values \
     --set hubble.metrics.enabled="{drop,flow,httpV2:labelsContext=source_ip\,destination_ip\,source_pod\,destination_pod}"
   kubectl -n kube-system rollout status ds/cilium
   sleep 60
   curl -s localhost:9965/metrics | grep -c '^hubble_http_requests_total'
   ```

   Compare that series count with the `source_workload`-based configuration from Exercise 0. `source_ip` produces one series per ephemeral pod IP; `source_workload` produces one per Deployment.

5. Roll back to the sane configuration:

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --values cilium-values.yaml
   kubectl -n kube-system rollout status ds/cilium
   ```

6. Write an alert that is actually actionable:

   ```yaml
   # alert-rules.yaml
   groups:
     - name: cilium-observability
       rules:
         - alert: CiliumPolicyDropsSpiking
           expr: |
             sum by (source, destination) (
               rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
             ) > 1
           for: 10m
           labels:
             severity: warning
           annotations:
             summary: "Policy drops {{ $labels.source }} -> {{ $labels.destination }}"
             runbook: "hubble observe --verdict DROPPED --from-pod {{ $labels.source }} --last 100"

         - alert: CiliumHubbleBufferSaturated
           expr: |
             rate(hubble_lost_events_total[5m]) > 0
           for: 5m
           labels:
             severity: critical
           annotations:
             summary: "Hubble is dropping events on {{ $labels.instance }} — flow data is incomplete"
   ```

### Comprehension checks

- **Q8.1** — Give the default port for each of: cilium-agent metrics, cilium-operator metrics, Hubble metrics, cilium-envoy metrics.
- **Q8.2** — `hubble_drop_total` and `cilium_drop_count_total` both count drops. What is the difference in what they know, and which one survives Hubble being disabled?
- **Q8.3** — Explain concretely why `labelsContext=source_ip` is dangerous in a cluster with a HorizontalPodAutoscaler, and give the label you should use instead.
- **Q8.4** — What does `hubble_lost_events_total > 0` mean physically? Name two ways to fix it and the trade-off of each.
- **Q8.5** — `enableOpenMetrics: true` plus `exemplars=true` on `httpV2` buys you something specific. What, and what other system must exist for it to be useful?

---

## Exercise 9 — Flow export and retention

Hubble's in-memory ring buffer is a *debugging* store, not an audit store. Retention is a separate feature.

### Steps

1. Prove the buffer is finite and lossy:

   ```bash
   hubble observe --last 1 -o json | jq -r .time     # oldest retrievable is bounded
   hubble status                                     # Current/Max Flows: 49,149/49,149 (100.00%)
   ```

   At 100% the buffer is full and every new flow evicts an old one.

2. Enable static file export with an allowlist, so you keep the security-relevant subset rather than everything:

   ```yaml
   # append to cilium-values.yaml
   hubble:
     export:
       fileMaxSizeMb: 20
       fileMaxBackups: 5
       static:
         enabled: true
         filePath: /var/run/cilium/hubble/events.log
         fieldMask:
           - time
           - source
           - destination
           - verdict
           - drop_reason_desc
           - l4
           - l7
           - node_name
         allowList:
           - '{"verdict":["DROPPED","ERROR"]}'
           - '{"event_type":[{"type":129}]}'   # policy-verdict events
         denyList: []
   ```

   ```bash
   helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" \
     --namespace kube-system --values cilium-values.yaml
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Generate denials and read the exported file:

   ```bash
   for i in $(seq 1 5); do
     kubectl exec xwing -- curl -s --connect-timeout 2 \
       -XPOST deathstar.default.svc.cluster.local/v1/request-landing || true
   done

   kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
     tail -n 2 /var/run/cilium/hubble/events.log | jq -c '{
       t: .flow.time, v: .flow.verdict, r: .flow.drop_reason_desc,
       s: .flow.source.pod_name, d: .flow.destination.pod_name }'
   ```

   Expected:

   ```json
   {"t":"2026-09-01T16:22:08.441Z","v":"DROPPED","r":"POLICY_DENIED","s":"xwing","d":"deathstar-8555bf78d9-5x9lk"}
   {"t":"2026-09-01T16:22:10.518Z","v":"DROPPED","r":"POLICY_DENIED","s":"xwing","d":"deathstar-8555bf78d9-5x9lk"}
   ```

4. Confirm that a `FORWARDED` flow did **not** land in the file — the allowlist is doing its job:

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
     grep -c '"verdict":"FORWARDED"' /var/run/cilium/hubble/events.log || echo "0 — as designed"
   ```

5. Capture a full support bundle, which is what you attach to an upstream issue:

   ```bash
   cilium sysdump --output-filename cca-lab-sysdump
   ```

   Expected (abridged):

   ```
   🔍 Collecting Kubernetes nodes, pods, services, network policies...
   🔍 Collecting Cilium bugtool output from all nodes...
   🔍 Collecting Hubble flows from all nodes...
   🗳 Compiling sysdump
   ✅ The sysdump has been saved to cca-lab-sysdump.zip
   ```

### Comprehension checks

- **Q9.1** — Where does the exported file physically live, and what is the single most important thing you must configure *outside* Cilium for this export to be worth anything?
- **Q9.2** — What is `fieldMask` for? Name the two distinct benefits.
- **Q9.3** — Your allowlist keeps only `DROPPED` and `ERROR`. An auditor asks "who talked to the payments service in July?". Can you answer? What would you have had to configure instead, and what is the cost?
- **Q9.4** — `cilium sysdump` collects Hubble flows. Given the ring buffer, what is the practical limit on how far back that snapshot reaches, and what does that imply about *when* you must run it during an incident?

---

## Exercise 10 — End-to-end incident drill

No hints. Use only observability tooling to diagnose, then fix.

### Steps

1. Reset and inject the fault:

   ```bash
   kubectl delete cnp --all
   kubectl apply -f - <<'EOF'
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: incident-10
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               org: empire
         toPorts:
           - ports:
               - port: "8080"
                 protocol: TCP
             rules:
               http:
                 - method: "GET"
                   path: "/v1/request-landing"
   EOF
   ```

2. Observe the symptom:

   ```bash
   kubectl exec tiefighter -- curl -s --connect-timeout 5 -XPOST \
     deathstar.default.svc.cluster.local/v1/request-landing
   ```

3. Diagnose using only these, in order, writing down what each rules in or out:

   ```bash
   hubble observe --to-pod default/deathstar --last 20
   hubble observe --type policy-verdict --to-label class=deathstar --last 10
   hubble observe --verdict DROPPED --last 10 -o json | jq .drop_reason_desc
   kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg bpf policy get 184
   kubectl get cnp incident-10 -o jsonpath='{.status}' | jq
   ```

4. Fix the policy, then prove the fix with a flow — not with a `curl` exit code:

   ```bash
   hubble observe --protocol http --to-label class=deathstar --last 5
   ```

### Comprehension checks

- **Q10.1** — There are **two** independent faults in `incident-10`. Name both and state the exact flow evidence that identifies each.
- **Q10.2** — Which of the two faults is visible in `hubble observe --protocol http`, and which is invisible there? Why?
- **Q10.3** — Write the corrected `CiliumNetworkPolicy`.
- **Q10.4** — Write the single `hubble` command you would put in the runbook as the definitive "is it fixed?" check, and explain why an exit-code check from `curl` is insufficient.

---

## Cleanup

```bash
kubectl delete cnp --all -n default
kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/HEAD/examples/minikube/http-sw-app.yaml
kind delete cluster --name cca-lab
```

---

## Sources

- CNCF CCA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- Cilium — Observability / Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium — Layer 7 protocol visibility — https://docs.cilium.io/en/stable/observability/visibility/
- Cilium — Monitoring & metrics — https://docs.cilium.io/en/stable/observability/metrics/
- Cilium — Hubble flow export — https://docs.cilium.io/en/stable/observability/hubble-exporter/
- Cilium — Network policy language (L7, `toFQDNs`) — https://docs.cilium.io/en/stable/security/policy/language/
- Cilium — Identity & security identities — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium — `cilium-dbg` command reference — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Cilium — Helm reference (`hubble.*` values) — https://docs.cilium.io/en/stable/helm-reference/
- Hubble CLI — https://github.com/cilium/hubble
- Cilium CLI (`cilium status`, `cilium sysdump`, `cilium hubble`) — https://github.com/cilium/cilium-cli

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 0

**A0.1 — No, the flows are permanently gone.** Hubble has no persistent backing store by default. The agent's eBPF datapath writes events to a perf ring buffer; the Hubble observer inside `cilium-agent` consumes them into an in-memory circular buffer sized by `hubble.eventBufferCapacity`. Both are process-memory structures on each node. If the observer was disabled, the events were never consumed; and restarting the agent discards whatever was buffered anyway. The only ways to have history are (a) flow export to a file shipped off-node, or (b) metrics, which retain aggregates but not individual flows. This is *the* argument for enabling Hubble before you need it.

**A0.2 — Because `hubble-relay` is a pure aggregator with no datapath privileges.** It is a Deployment that opens gRPC connections to each agent's Hubble server on port 4244 (discovered via the `hubble-peer` Service) and multiplexes their streams. Relay can be perfectly healthy while a given agent has Hubble disabled, is crash-looping, or is unreachable. The per-node truth is `hubble list nodes` and `cilium-dbg status | grep Hubble` on that node.

**A0.3 — Unit: flow events. Scope: per node** (per cilium-agent process), not per cluster and not per endpoint. Raising it lengthens the time window you can look back over on a busy node, at the cost of agent RSS — roughly linear in the number of events, and each event is a non-trivial protobuf. On a node doing 5,000 flows/s, 16,383 events is about 3 seconds of history; this is why the buffer is a debugging aid, not a log. Raise it when you need to catch bursty, short-lived issues; do not raise it hoping for retention.

**A0.4 —**
- `cilium-agent`: **9962** — enabled by `prometheus.enabled: true`.
- `cilium-operator`: **9963** — enabled by `operator.prometheus.enabled: true`.
- Hubble flow metrics: **9965** — enabled by `hubble.metrics.enabled`.
- `cilium-envoy` (L7 proxy): **9964** — *not* enabled by anything in the values file above. It exists because the Envoy DaemonSet ships its own metrics endpoint for the L7 proxy; you enable it separately (`envoy.prometheus.enabled`). It matters only once you actually have L7 policies in play (Exercise 5).

### Exercise 1

**A1.1 —** The agent's Hubble gRPC server listens on **4244**. Relay serves clients on **4245**. `cilium hubble port-forward` forwards **4245** (Relay), which is why the resulting `hubble` CLI sees the whole cluster. Inside an agent pod, the `hubble` CLI defaults to the local Unix socket `/var/run/cilium/hubble.sock` and therefore sees only that node.

**A1.2 —** `hubble-peer` is a headless-style Service that Relay uses for **peer discovery**: it resolves to the set of Cilium agents currently running, so Relay learns about new nodes joining and drops nodes that leave without any restart or config change. A hard-coded list would break on every scale-up, node replacement, or spot-instance reclaim. It is a Service precisely because node membership is dynamic.

**A1.3 —** Relay is designed to serve **partial results rather than fail closed**: a single unreachable node must not make the entire observability plane unusable during exactly the incident when you need it. The health of the aggregator and the completeness of the data are separate facts, so `Ok` refers only to the former. The operational consequence: **never alert on `hubble status` health alone.** Alert on `Connected Nodes < expected`, and treat "flows are missing" as a distinct failure mode from "Hubble is down". Silent partial data is more dangerous than a hard failure.

**A1.4 —** The pod is almost certainly **scheduled on a different node**. The node-local observer only sees traffic traversing that node's datapath. Switch to Relay (`cilium hubble port-forward` + `hubble observe`) or exec into the agent on the pod's node — `kubectl get pod <p> -o jsonpath='{.spec.nodeName}'`.

### Exercise 2

**A2.1 —** These are **datapath observation points**, each a different place the packet was seen:
- `to-overlay` — handed to the tunnel/overlay interface for transmission to another node.
- `to-endpoint` — delivered into the destination endpoint's veth (final ingress hop).
- `to-stack` — passed up to the host kernel networking stack.
- `to-proxy` — redirected to the Envoy or DNS proxy.
- `from-endpoint` / `from-network` / `from-host` — the corresponding source-side points.

One logical request appears many times because Hubble reports *packets at observation points*, not connections: the DNS lookup, the SYN on the source node, the SYN on the destination node, the SYN-ACK, the data segments, and the FIN each generate events. Reading a Hubble stream as "one line = one request" is the single most common beginner error.

**A2.2 —** A **security identity is derived from the set of security-relevant labels** on the endpoint (pod labels, minus those excluded by the identity-relevant-labels configuration, plus namespace and cluster). All pods sharing that label set share one numeric identity. Consequence: policy is enforced on **identity, not IP**, so the eBPF policy map for an endpoint has one entry per *identity* rather than per *peer pod*. A Deployment scaled from 3 to 3,000 replicas adds **zero** policy-map entries and triggers no policy recomputation on peers. This is the core reason Cilium's policy plane scales where iptables-per-IP approaches do not.

**A2.3 —** You have learned that **Cilium has no identity for that IP** — it is not a known cluster endpoint, not a node, not the kube-apiserver, and not covered by a `CiliumCIDRGroup`/`toCIDR` or `toFQDNs` rule that would have carved out a more specific identity. You have **not** learned that the traffic is from the public internet. `reserved:world` simply means "outside the cluster's known identity space"; it can include on-prem RFC1918 ranges, another VPC, or a node that Cilium does not manage. To learn more, define CIDR-based policy or FQDN rules, which cause Cilium to allocate more specific local identities (see A6.3).

**A2.4 —** `reserved:kube-apiserver`, identity **7** (`hubble observe --to-identity 7`). It is useful because the apiserver's address is frequently a VIP, a load balancer, or a host-network endpoint that would otherwise collapse into `reserved:world` or `reserved:host` — meaning a policy that allows apiserver access would have to allow a far broader identity. A dedicated identity lets you write and *audit* "who talks to the control plane" precisely.

**A2.5 —** `FORWARDED`, `DROPPED`, `ERROR`, `AUDIT`, `REDIRECTED`, `TRACED`, `TRANSLATED`. The one you want is **`AUDIT`**: emitted when the `CiliumNetworkPolicy` is in audit mode (`policy-audit-mode`), where a packet that *would* have been denied is logged as `AUDIT` and forwarded anyway. You use it deliberately when rolling out a new default-deny policy on a live service: you get the complete list of connections the policy would break, without an outage, and you promote to enforce once the `AUDIT` stream goes quiet.

### Exercise 3

**A3.1 —** Different flags are combined with **AND** (`--from-label org=empire --to-port 80` means *from empire* **and** *to port 80*). Repeating the same flag is combined with **OR** (`--type drop --type policy-verdict` means drop **or** policy-verdict). This asymmetry is exactly what `--print-raw-filters` makes visible: same-flag repeats become multiple values inside one filter field, while different flags become additional fields in the same allowlist entry — and fields within an entry are ANDed while separate allowlist entries are ORed.

**A3.2 —** Pod IPs are **ephemeral**: a restart, an eviction, or a rollout reassigns them, and the old IP may be recycled to an unrelated pod within seconds. A runbook keyed on an IP silently returns the wrong pod's traffic, or nothing. Labels are stable identity, they survive rescheduling, and they match the same abstraction the policy is written against — so the filter and the policy agree.

**A3.3 —** Two independent explanations:
1. **The buffer wrapped.** With a default `eventBufferCapacity` of 4095 on a busy node, 40 minutes of history does not exist; `--since 1h` cannot conjure evicted events. Confirm with `hubble status` showing `Current/Max Flows` at 100%.
2. **You are querying the wrong scope or the wrong node.** Either you are on a node-local socket and the drop happened on another node, or Relay lost the peer (`hubble list nodes` shows it unavailable), or the agent on that node restarted since — flushing its buffer.

   A third, subtler cause worth knowing: the drops were **L7 denies**, which appear as `http-request DROPPED` under `--type l7`; they are matched by `--verdict DROPPED`, but if the operator had instead filtered `--type drop` they would see nothing, because no eBPF drop event was generated.

**A3.4 —** It prints the **gRPC `FlowFilter` protobuf** that your flags compile into, as an allowlist/denylist of JSON objects — i.e. what Relay will actually evaluate. Concrete bug it catches: writing `--label org=empire` (matches source **or** destination) when you meant `--from-label`, or mixing `--not` and expecting it to negate only the last flag when it negates the whole filter into a denylist. The raw filter shows the true field names and grouping, so the AND/OR structure of A3.1 becomes literal rather than remembered.

### Exercise 4

**A4.1 —**
- A **`policy-verdict`** event is emitted by the policy engine at the point of decision, on the **first packet of a new connection**. It reports the direction (`INGRESS`/`EGRESS`), the decision (`ALLOWED`/`DENIED`) and the **match type** — which tier of the rule matched. It answers *"what did policy decide, and why?"*
- A **`drop`** event is emitted by the datapath when a packet is actually discarded, carrying a `drop_reason`. It answers *"what physically happened to the packet?"*

A denied packet emits both because they are two different subsystems reporting the same instant: the engine decided DENY, then the datapath dropped it. You see a `policy-verdict` with **no** drop whenever the verdict is `ALLOWED` (nothing was dropped), and you see a **drop with no policy-verdict** when the drop had a non-policy cause — `CT: Map insertion failed`, `Stale or unroutable IP`, `Invalid source ip`, `Unsupported L3 protocol`. That distinction is the fastest way to separate "someone's policy is wrong" from "the datapath or the network is broken", and it is a very common exam question.

**A4.2 —** The match type says which tier of the rule authorised the flow:
- `L3-L4` — matched both an identity selector and a port/protocol rule (the normal case for the policy in step 1).
- `L3-Only` — matched an identity selector with no port restriction (`toPorts` absent).
- `L4-Only` — matched a port/protocol rule that applies regardless of peer identity.
- `all` — matched an allow-all rule.
- `none` — **nothing matched**, so default-deny applied. This is always what you see on a DENIED verdict.

Reading `policy-verdict:none` as "no policy exists" is wrong — it means "policy is enforced here and no rule matched".

**A4.3 —** A `Connection refused` requires a TCP RST, which requires something to *respond*. Cilium's L3/L4 enforcement **silently discards the packet in eBPF** before it ever reaches the destination endpoint's stack — no RST, no ICMP unreachable, so the client retransmits the SYN until its own timeout expires. That is why the symptom of a missing network policy is a **hang**, not a refusal, and why "it times out" should immediately make you check policy.

An L7 deny is the opposite: the connection is *established* to the Envoy proxy (TCP succeeded), Envoy parses the request and returns an **application-layer error** — `403 Access denied` — immediately. Fast, explicit failure at L7; slow, silent failure at L3/L4. The failure *shape* tells you which layer denied you before you run a single command.

**A4.4 —** Cilium endpoints are **default-allow until they are selected by at least one policy in that direction**. `deathstar` is selected by `rule1`'s `endpointSelector`, so ingress flips to default-deny-with-exceptions for that endpoint. `tiefighter` is selected by nothing, so it stays wide open — including egress, which no rule in this exercise constrains.

The operational risk is that **coverage is invisible in the policy YAML**. Writing 40 excellent policies proves nothing about the pods none of them select; those remain fully permissive and no policy review will show it. The audit you actually need is `cilium-dbg endpoint list` (or `cilium_policy_endpoint_enforcement_status`) looking for `Disabled`, plus a namespace-wide default-deny baseline so that *forgetting* a policy fails closed rather than open.

**A4.5 —** `cilium-dbg bpf policy get <endpoint-id>` on every endpoint the policy selects, and read the **`BYTES` and `PACKETS`** columns for the entries that rule generates. These are eBPF map counters incremented on every match, so a rule showing `PACKETS 0` across all replicas for a period longer than your longest business cycle (batch jobs, monthly reports, DR failover) is genuinely unused. This is evidence; "no one remembers why it's there" is not. Caveat: counters reset when the endpoint is regenerated (pod restart, policy change, agent restart), so sample over time rather than reading once — and confirm across all endpoints selected, not just one.

**A4.6 —** Use `cilium-dbg monitor` when you need **below-Hubble detail on a single node**. Two things it gives you that Hubble does not:
1. **Datapath-internal debug events** — `--type debug`, `--type capture`, and trace events with the eBPF **source file and line number** (`file bpf_lxc.c line 2091`), which pinpoints *where in the datapath* a packet died.
2. **Raw, unaggregated packet-level output** including events Hubble filters or aggregates away, plus `--hex` for the actual bytes.

The drawback: it is **node-local and unaggregated** — no cluster-wide view, no Kubernetes pod/namespace enrichment beyond identities, no historical query (it is a live tail only), and on a busy node the volume is unusable without tight filters. Hubble is the tool 95% of the time; `monitor` is the escalation when Hubble says "dropped" and you need to know which line of C did it.

### Exercise 5

**A5.1 —** An `http:` rule causes Cilium to install a **proxy redirect** in the endpoint's eBPF policy map: matching traffic is no longer forwarded straight to the endpoint but redirected to the **Envoy L7 proxy**, which terminates the connection, parses HTTP, applies the rule, and re-originates to the backend. You prove it from the CLI with `cilium-dbg bpf policy get <endpoint-id>` and reading the **`PROXY PORT`** column: it is `NONE` for pure L3/L4 rules and a real port number (e.g. `17423`) once a redirect exists. Corroborate with `cilium-dbg proxy status` (lists the allocated proxy ports and redirects).

**A5.2 —** See A4.3. At L7 the TCP handshake **succeeds** — against Envoy, not against the backend — so the client has a live connection and Envoy can answer it with an explicit `403 Access denied` the instant it parses the disallowed method/path. At L3/L4 the SYN is discarded in eBPF with nothing to answer, so the client can only time out.

**A5.3 —** **No packet was dropped by eBPF.** `DROPPED` on an `http-request` event means *the L7 proxy refused the request*: the TCP connection was established, the request was parsed and rejected, and an HTTP 403 was returned. The verdict field is shared vocabulary across layers, so the same word describes two mechanically different events. You distinguish them by the **event type**: `--type drop` is a datapath drop with a `drop_reason`; `--type l7` with `DROPPED` is a proxy refusal with no `drop_reason`. Confusing the two sends you looking for a network fault that does not exist.

**A5.4 —** Because latency is only *knowable* once the response arrives. Envoy timestamps the request as it forwards it and computes the elapsed time when the matching response comes back; that duration can only be attached to the response event. A request event that never gets a matching response therefore has no latency at all — which is itself a useful signal: requests without responses are your timeouts and your backend hangs.

**A5.5 —** An allow-all L7 rule — it must be present to instantiate the proxy, but must not narrow anything:

```yaml
    rules:
      http:
        - {}
```

(equivalently a rule with no `method`/`path`/`headers` constraints, which matches every HTTP request). The two costs you accept:
1. **Latency and CPU** — every packet on that port now round-trips through a user-space Envoy proxy instead of staying in eBPF; you measured this in step 8. It also makes Envoy a new failure domain in the data path.
2. **Semantic change to the connection** — the client's TCP connection now terminates at the proxy. Anything depending on end-to-end TCP behaviour (source port visibility, some keepalive/timeout semantics, non-HTTP traffic accidentally on that port being rejected as malformed) can change. "Visibility-only" is never truly free.

### Exercise 6

**A6.1 —** The `dns:` rule under `toPorts` instantiates Cilium's **DNS proxy**. Without it, DNS is just UDP/53 to the datapath — Cilium sees a UDP packet to port 53 and nothing about its contents, so there is no `dns-request`/`dns-response` event to report. The `matchPattern: "*"` rule redirects DNS to the proxy, which parses the query and the answer, emits L7 DNS flows, and populates the FQDN cache that `toFQDNs` rules are enforced against. Note the coupling worth remembering: **`toFQDNs` does not work without a DNS rule** that routes the relevant lookups through the proxy — that omission is one of the most common `toFQDNs` bugs in the field.

**A6.2 —** The policy explicitly allows DNS to kube-dns for **all** patterns (`matchPattern: "*"`), so the lookup for `www.example.com` is permitted and answered normally. The *connection* to the resolved IP is a separate decision: no `toFQDNs` or `toCIDR` rule covers `www.example.com`, so default-deny applies at egress and the SYN is dropped with `policy-verdict:none EGRESS DENIED`.

The lesson for "DNS works but the app can't connect": **name resolution and reachability are enforced by two different rules**, and a successful `nslookup` from inside the pod proves nothing about connectivity. Debug the two independently — `hubble observe --protocol dns --from-pod X` for resolution, `hubble observe --type policy-verdict --from-pod X` for reachability.

**A6.3 —** `16777217` is in the **local (CIDR/FQDN-derived) identity range** — identities allocated node-locally by the agent when a policy needs a more specific identity than `reserved:world` for a particular CIDR or FQDN-resolved IP. Differences from `reserved:world` (ID 2):
- Scope: `reserved:world` is a fixed, cluster-wide reserved identity; local identities are **allocated per node** and are only meaningful on that node.
- Specificity: `reserved:world` means "any unknown external address"; a local identity means "this specific CIDR/FQDN that a policy referenced", allowing precise allow/deny and precise flow attribution.

Practically: the more `toCIDR`/`toFQDNs` rules you write, the more of your external traffic stops being an undifferentiated `world` blob in Hubble and becomes individually named.

**A6.4 —** From the **DNS proxy's FQDN cache** (`cilium-dbg fqdn cache list`), populated when the proxy observed the `dns-response`. Hubble enriches flows to that IP with the name that resolved to it, which is why `--fqdn` matches a flow whose destination field is a bare IP.

After the TTL expires, the cache entry is evicted (subject to `tofqdns-min-ttl` and the DNS-garbage-collection settings, which deliberately hold entries longer than a short upstream TTL to avoid tearing down live connections). Once evicted, subsequent flows to that IP lose the name association and appear as a plain IP with a `world` or local identity — and, importantly, the `toFQDNs` policy stops allowing them until the pod re-resolves. This is precisely the mechanism behind A6.5.

**A6.5 —** The two most likely causes:
1. **DNS bypassing the proxy** — the application caches DNS itself (JVM `networkaddress.cache.ttl=-1`, a sidecar resolver, a hard-coded `/etc/hosts` entry, or a connection pool holding an IP from before the policy existed). The proxy never sees a query, the FQDN cache entry expires, and the connection to the still-valid IP is denied.
2. **A short upstream TTL combined with a multi-IP / rotating-answer service** (CDNs, `www.cncf.io` behind Cloudflare). The pod resolves and gets IP set A; the cache holds A; a later connection uses an IP from set B obtained elsewhere, or the TTL expires between resolution and connection.

The command that distinguishes them: `hubble observe --protocol dns --from-pod default/tiefighter --since 10m`. If you see **no `dns-request` events** immediately before the denied SYN, it is cause 1 — the app is not asking, so the proxy cannot learn. If you see the query and the answer but the denied SYN is to an IP *not* in that answer (cross-check with `cilium-dbg fqdn cache list`), it is cause 2. Fixes differ completely: cause 1 needs an application/TTL change; cause 2 needs a raised `tofqdns-min-ttl`, a `matchPattern` covering the whole domain, or a CIDR fallback.

### Exercise 7

**A7.1 —** It is built from **observed traffic** — the map is a rendering of the Hubble flow stream, drawn from flows Relay currently holds. It is neither the Service catalogue nor the policy graph. The implication is important and frequently misunderstood: **a service that receives no traffic does not appear on the map, and neither does one whose traffic has aged out of the ring buffer.** Absence from the service map is not evidence that a dependency does not exist — only that no flow was observed in the retained window. Never use it to conclude "nothing talks to this, it's safe to delete".

**A7.2 —** Hubble UI is wrong because it renders only what is in the **in-memory ring buffer**, which on a real cluster is seconds-to-minutes of history — not 30 days. It also has no export, no query language, and no guarantee of completeness (see `hubble_lost_events_total`).

What to build instead: enable **Hubble flow export** (Exercise 9) with a field mask retaining source/destination workload identity and verdict, ship the files off-node with your log agent to a queryable store (Loki/Elasticsearch/S3+Athena/an OTel pipeline), and generate the dependency graph from that. Complement it with `hubble_flows_processed_total` in Prometheus for the aggregate view, which retains far longer than the buffer and is cheap. Audit questions need a durable store; Hubble is the live view on top of it.

**A7.3 —** Two configuration causes:
1. **The UI backend cannot reach Relay** — wrong `hubble.ui.backend` service address, a NetworkPolicy in `kube-system` blocking the UI backend's gRPC connection to `hubble-relay:80`, or TLS material mismatch after a certificate rotation. Check `kubectl -n kube-system logs deploy/hubble-ui -c backend`.
2. **RBAC / namespace scoping** — the UI backend's ServiceAccount lacks permission to list pods and services in that namespace, so it cannot enrich or render flows even though Relay is streaming them. The UI shows an empty map rather than an error.

   A third worth knowing: your `hubble observe` may be reading a *different* time window — the UI streams live, so a namespace whose traffic stopped minutes ago shows empty while `--last N` still returns buffered flows.

### Exercise 8

**A8.1 —** cilium-agent **9962**, cilium-operator **9963**, cilium-envoy **9964**, Hubble **9965**. These are the chart defaults and are worth memorising — the exam does ask.

**A8.2 —**
- `hubble_drop_total` is computed by the **Hubble metrics handler from the flow stream**, so it carries rich Kubernetes context: source and destination workload/namespace/pod, protocol, and the drop reason. It answers *who* was dropped.
- `cilium_drop_count_total` is exported by the **agent from datapath counters**, with only `direction` and `reason` labels. It answers *how much and why*, with no idea who.

`cilium_drop_count_total` **survives Hubble being disabled** — it is an agent metric, independent of the observer. That makes it the right basis for a baseline "is anything being dropped at all" alert that keeps working even if the observability plane degrades, with `hubble_drop_total` as the enrichment layer for triage.

**A8.3 —** With an HPA, pods are created and destroyed continuously and each gets a **fresh, never-reused-soon IP**. `labelsContext=source_ip` therefore mints a **new time series for every pod that has ever existed**, and Prometheus never forgets a series within its retention — cardinality grows monotonically with the number of scaling events, not with the number of services. This is the classic path to an OOM-killed Prometheus. Worse, the series are useless: nobody queries by an IP that lived for four minutes.

Use **`source_workload`** (and `destination_workload`), which is stable per Deployment/StatefulSet — cardinality proportional to the number of workloads, which is what you actually reason about. `source_namespace`/`destination_namespace` are similarly safe. Reserve IP-level detail for the flow log, where per-event cost is bounded, rather than the metrics store, where per-series cost is forever.

**A8.4 —** It means the **Hubble observer could not keep up with the datapath**: events were produced into the perf ring buffer faster than the observer consumed them, and the kernel overwrote them. Physically, flow data has been irrecoverably lost — your observability has holes, silently, exactly when load is highest. Two fixes:
1. **Raise `hubble.eventBufferCapacity`** (and the underlying monitor buffer). Trade-off: more agent memory per node, linearly; it buys headroom for bursts but does not help sustained overload.
2. **Reduce the event volume** — enable monitor aggregation (`monitor-aggregation: medium|maximum`, which suppresses repeated trace events for established connections), or narrow what is captured. Trade-off: you lose per-packet granularity, so some short-lived or retransmission-level detail becomes invisible; `maximum` aggregation in particular makes flow counts unsuitable for precise packet accounting.

Either way, alert on this metric. An observability system that is silently lossy is worse than one that is honestly down.

**A8.5 —** `enableOpenMetrics: true` switches the exposition to the **OpenMetrics** format, which supports **exemplars** — a trace ID attached to an individual sample inside a histogram bucket. With `exemplars=true` on `httpV2`, a slow request in the p99 bucket of `hubble_http_request_duration_seconds` carries a pointer to the exact trace of that request.

For it to be useful you need a **distributed tracing backend** (Tempo, Jaeger, or any OTel-compatible store) *and* a Grafana (or equivalent) configured to link the metric datasource to it — plus the application must actually be propagating trace context. Without those, exemplars are inert extra bytes on every scrape. The payoff when present is large: it closes the gap from "p99 latency is bad" to "here is the specific request that was slow" in one click, without a log search.

### Exercise 9

**A9.1 —** The file lives **on each node's local filesystem**, inside the agent's mount at `/var/run/cilium/hubble/events.log` (a hostPath under `/var/run/cilium` on the node). The critical thing you must configure outside Cilium is a **log shipper that collects and forwards that file off the node** — Fluent Bit, Vector, Promtail, the cloud provider's node agent, whatever you already run. Cilium rotates the file (`fileMaxSizeMb`, `fileMaxBackups`) and will happily overwrite old data; and if the node dies, so does the file. Export without shipping is not retention, it is a slightly longer buffer.

**A9.2 —** `fieldMask` restricts which protobuf fields are written to the export. Two benefits:
1. **Volume and cost** — a full flow record is large; on a busy cluster the difference between full records and a ten-field mask is the difference between terabytes and gigabytes per day of ingest, which is real money in any log store.
2. **Data minimisation / privacy** — you can deliberately exclude fields that carry sensitive material (full HTTP URLs with query strings and tokens, headers, source IPs subject to data-protection rules) so they never leave the node. That is often a compliance requirement, not an optimisation.

**A9.3 —** **No, you cannot answer it.** The allowlist kept only `DROPPED` and `ERROR`; successful conversations with the payments service were `FORWARDED` and were never written. The buffer holding them wrapped within seconds in July.

To answer it you would have had to export `FORWARDED` flows too — realistically scoped, e.g. an allowlist entry restricted to the payments namespace, with a `fieldMask` limited to time/source/destination/verdict and monitor aggregation turned up so established connections do not emit per-packet records. The cost is **volume**: forwarded traffic outnumbers drops by orders of magnitude, so this multiplies ingest, storage and egress spend, and it puts more pressure on the observer (see `hubble_lost_events_total`). That is the trade-off to state explicitly to whoever is asking for the audit capability — retention of "everything" is a budget decision, not a config flag.

**A9.4 —** The Hubble flows in a sysdump come from the same **in-memory ring buffer**, so the snapshot reaches back only as far as that buffer holds — seconds to a few minutes on a busy node, bounded by `eventBufferCapacity` divided by the flow rate. The implication is operational and non-obvious: **run `cilium sysdump` as one of the first actions during an incident, not as part of the post-mortem.** By the time you have finished triaging, the flows that explain the incident have been evicted, and the sysdump you collect an hour later contains a perfect record of the recovery and nothing of the failure. (Everything *else* in a sysdump — policies, endpoint state, agent logs, bugtool output — ages far better; it is specifically the flows that are perishable.)

### Exercise 10

**A10.1 —** Two independent faults:

1. **Wrong port: the policy allows `8080`, the service and pod listen on `80`.** Evidence: `hubble observe --type policy-verdict --to-label class=deathstar` shows `policy-verdict:none INGRESS DENIED (TCP Flags: SYN)`, paired with a `Policy denied DROPPED` event whose `drop_reason_desc` is `POLICY_DENIED`. The denial is on the **SYN**, i.e. before any application data — which is the signature of an L3/L4 mismatch, not an L7 one. Confirming detail: `cilium-dbg bpf policy get 184` lists an allow entry for `8080/TCP` and nothing for `80/TCP`.

2. **Wrong HTTP method: the policy allows `GET /v1/request-landing`, the client sends `POST`.** This fault is *masked* by the first one — no connection ever reaches the proxy, so it produces no evidence at all until fault 1 is fixed. After correcting the port, the same `curl` yields `http-request DROPPED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)` and the client receives `Access denied`.

   The general lesson, and the reason the drill is ordered this way: **faults at lower layers hide faults at higher layers.** Fix and re-verify one layer at a time; a single "still broken" observation after one fix does not mean the fix was wrong.

**A10.2 —** Only **fault 2** is visible in `hubble observe --protocol http`. Fault 1 is invisible there because the SYN is dropped in eBPF before the connection is ever established, so it is never redirected to the Envoy proxy — and no proxy means no L7 event of any kind. Fault 1 lives exclusively in `--type policy-verdict` and `--type drop`. This is the practical statement of the layering: **an empty `--protocol http` output during an outage is itself a finding**, telling you the failure is below L7.

**A10.3 —**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: incident-10
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
```

Both corrections: `8080` → `80`, and `GET` → `POST`.

**A10.4 —**

```bash
hubble observe --protocol http --to-label class=deathstar \
  --http-path /v1/request-landing --last 20 -o json \
  | jq -r 'select(.verdict=="DROPPED") | "STILL BLOCKED: \(.l7.http.method) \(.l7.http.url)"'
```

— expected to print nothing, with the corresponding `hubble observe --protocol http --last 5` showing `http-request FORWARDED` and `http-response FORWARDED (HTTP/1.1 200 ...)`.

A `curl` exit code is insufficient for three reasons:
1. **An L7 deny returns `403 Access denied` in the response body with a successful HTTP transaction**, so plain `curl` exits **0** — the request was refused but the tool reports success. You would declare victory on a still-broken policy.
2. It conflates failure modes: exit 28 (timeout) could be the policy, a crashed backend, a full conntrack table, or DNS — the exit code cannot tell you which, while the flow's event type and verdict can.
3. It proves one packet from one client at one instant. The Hubble query proves what the **enforcement plane actually decided**, across every replica and every recent request, which is the thing you are trying to verify.

The general principle, and the one worth carrying into the exam: **verify network policy changes with the observability plane's verdict, not with the application's symptom.** The symptom is a lossy, ambiguous projection of the verdict.

</details>