# Securing Workloads with Cilium — Guided Exercises

**Certification:** Cilium Certified Associate (CCA) · **Domain 5.1** · **Exam weight: 20%**

> These exercises are written to be executed end to end on a disposable cluster. Every command is real, every manifest is complete and syntactically valid, and every expected output is representative of a Cilium 1.16/1.17 installation. Where output differs between versions, it is flagged inline.
>
> **Binary naming:** since Cilium v1.16 the in-agent debug binary is `cilium-dbg`. On v1.15 and earlier the identical commands are available as `cilium` inside the agent pod. The *host* CLI (`cilium status`, `cilium connectivity test`) is a different binary and keeps the name `cilium`.

---

## Exercise 0 — Lab environment and baseline

### Steps

1. Create a kind cluster without a CNI and without kube-proxy, so Cilium owns the entire datapath:

   ```bash
   cat <<'EOF' > kind-cca.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: cca
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   networking:
     disableDefaultCNI: true
     kubeProxyMode: none
     podSubnet: "10.244.0.0/16"
     serviceSubnet: "10.96.0.0/16"
   EOF

   kind create cluster --config kind-cca.yaml
   ```

2. Install Cilium with the feature set this domain requires. Note that Hubble, the L7 proxy and the FQDN proxy are what make policy *verifiable*, not just *declarable*:

   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm repo update

   helm install cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system \
     --set kubeProxyReplacement=true \
     --set k8sServiceHost=cca-control-plane \
     --set k8sServicePort=6443 \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true \
     --set hubble.metrics.enableOpenMetrics=true \
     --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,httpV2}" \
     --set l7Proxy=true \
     --set policyEnforcementMode=default
   ```

3. Wait for convergence and read the feature matrix:

   ```bash
   cilium status --wait
   ```

   Expected (abbreviated):

   ```
       /¯¯\
    /¯¯\__/¯¯\    Cilium:             OK
    \__/¯¯\__/    Operator:           OK
    /¯¯\__/¯¯\    Envoy DaemonSet:    OK
    \__/¯¯\__/    Hubble Relay:       OK
       \__/       ClusterMesh:        disabled

   DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
   Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
   Containers:            cilium             Running: 3
                          hubble-relay       Running: 1
   Cluster Pods:          6/6 managed by Cilium
   ```

4. Inspect the agent's own view of the enabled security features:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | \
     grep -A6 -E 'Policy|Proxy|Encryption'
   ```

   Expected (abbreviated):

   ```
   Encryption:              Disabled
   Policy enforcement:      default
   Proxy Status:            OK, ip 10.244.1.180, 0 redirects active on ports 10000-20000, Envoy: external
   ```

5. Deploy the canonical demo application (an HTTP API with three consumers):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/1.17.1/examples/minikube/http-sw-app.yaml
   kubectl get pods -L app.kubernetes.io/name,class,org
   ```

   Expected:

   ```
   NAME                         READY   STATUS    NAME         CLASS        ORG
   deathstar-8484d6f69c-7xk4t   1/1     Running   deathstar    deathstar    empire
   deathstar-8484d6f69c-p9dvn   1/1     Running   deathstar    deathstar    empire
   tiefighter                   1/1     Running   tiefighter   tiefighter   empire
   xwing                        1/1     Running   xwing        xwing        alliance
   ```

6. Prove the cluster is wide open before any policy exists:

   ```bash
   kubectl exec xwing      -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Expected — **both** succeed:

   ```
   Ship landed
   Ship landed
   ```

### Comprehension check — Block 0

* **Q0.1** — `policyEnforcementMode=default` was set explicitly. What are the three legal values, and what does each one do to an endpoint that is selected by *no* policy at all?
* **Q0.2** — The cluster was created with `kubeProxyMode: none`. Which Cilium security feature would silently degrade if kube-proxy *were* present and handling Service translation before Cilium sees the packet?
* **Q0.3** — `Proxy Status` reports `Envoy: external`. What is the difference between the embedded and the external (DaemonSet) Envoy, and why does the DaemonSet mode matter for the blast radius of an L7 policy?
* **Q0.4** — Why is `xwing` able to reach `deathstar` in step 6 even though the two pods carry completely different `org` labels?

---

## Exercise 1 — The identity model: labels, not IPs

This is the conceptual core of the domain. Cilium does not write per-IP firewall rules; it derives a **numeric security identity** from the pod's *security-relevant* labels and enforces policy between identities in eBPF maps.

### Steps

1. List the security identities Cilium has allocated:

   ```bash
   kubectl get ciliumidentities -o custom-columns=\
   'ID:.metadata.name,NS:.security-labels.k8s\:io\.kubernetes\.pod\.namespace,LABELS:.security-labels'
   ```

   Expected (abbreviated):

   ```
   ID      NS            LABELS
   4711    default       map[k8s:app.kubernetes.io/name:deathstar k8s:class:deathstar k8s:io.cilium.k8s.policy.cluster:default k8s:io.cilium.k8s.policy.serviceaccount:default k8s:io.kubernetes.pod.namespace:default k8s:org:empire]
   9034    default       map[... k8s:class:tiefighter ... k8s:org:empire]
   25871   default       map[... k8s:class:xwing ... k8s:org:alliance]
   ```

2. Map pods to identities through the `CiliumEndpoint` (CEP) object — one per pod:

   ```bash
   kubectl get cep -o wide
   ```

   Expected:

   ```
   NAME                         ENDPOINT ID   IDENTITY ID   INGRESS ENFORCEMENT   EGRESS ENFORCEMENT   IPV4          STATUS
   deathstar-8484d6f69c-7xk4t   1204          4711          false                 false                10.244.1.51   ready
   deathstar-8484d6f69c-p9dvn   3310          4711          false                 false                10.244.2.19   ready
   tiefighter                   776           9034          false                 false                10.244.1.94   ready
   xwing                        2295          25871         false                 false                10.244.2.77   ready
   ```

3. Confirm that **two replicas of the same Deployment share one identity** — this is why policy scales with the number of *label sets*, not the number of pods:

   ```bash
   kubectl get cep -l class=deathstar \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.identity.id}{"\n"}{end}'
   ```

   Expected:

   ```
   deathstar-8484d6f69c-7xk4t   4711
   deathstar-8484d6f69c-p9dvn   4711
   ```

4. Inspect the reserved identities, which represent traffic that has no pod behind it:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list | head -20
   ```

   Expected:

   ```
   ID     LABELS
   1      reserved:host
   2      reserved:world
   3      reserved:unmanaged
   4      reserved:health
   5      reserved:init
   6      reserved:remote-node
   7      reserved:kube-apiserver
   8      reserved:ingress
   4711   k8s:app.kubernetes.io/name=deathstar
          k8s:class=deathstar
          ...
   ```

5. Demonstrate that not every label is security-relevant. Add an annotation-like label and watch the identity **stay the same**, then add a label under a namespace that *is* relevant:

   ```bash
   # Default configuration ignores nothing by default, but pod-template-hash IS excluded.
   kubectl get cep deathstar-8484d6f69c-7xk4t -o jsonpath='{.status.identity.labels}' | tr ';' '\n'
   ```

   Expected — note the **absence** of `pod-template-hash`:

   ```
   k8s:app.kubernetes.io/name=deathstar
   k8s:class=deathstar
   k8s:io.cilium.k8s.policy.cluster=default
   k8s:io.cilium.k8s.policy.serviceaccount=default
   k8s:io.kubernetes.pod.namespace=default
   k8s:org=empire
   ```

6. Force an identity change by mutating a security-relevant label, and observe the churn:

   ```bash
   kubectl label pod xwing org=empire --overwrite
   sleep 3
   kubectl get cep xwing -o jsonpath='{.status.identity.id}{"\n"}'
   kubectl label pod xwing org=alliance --overwrite
   ```

   The identity ID changes (a new identity is allocated or an existing one is reused).

### Comprehension check — Block 1

* **Q1.1** — Two pods in *different namespaces* carry the identical set of application labels (`class=api, org=empire`). Do they share a security identity? Justify using the label list from step 5.
* **Q1.2** — A Deployment is scaled from 3 to 300 replicas. How many new `CiliumIdentity` objects are created, and what does that imply about the size of the eBPF policy map?
* **Q1.3** — Why is `pod-template-hash` deliberately excluded from identity computation? What would break during a rolling update if it were included?
* **Q1.4** — A policy allows `reserved:remote-node`. Name a concrete failure mode you would introduce by writing `reserved:host` instead in a multi-node cluster.
* **Q1.5** — Cilium allocates cluster-scoped identities from ID 256 upward, but CIDR-derived and FQDN-derived identities live in a *local* (node-scoped) range. Why can a CIDR identity not be cluster-scoped?

---

## Exercise 2 — L3/L4 policy and default-deny semantics

### Steps

1. Apply an ingress policy that admits only `org=empire` on TCP/80:

   ```yaml
   # 01-l3l4-ingress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l4
     namespace: default
   spec:
     description: "L3/L4: only empire ships may reach the deathstar HTTP port"
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
   kubectl apply -f 01-l3l4-ingress.yaml
   kubectl get cnp rule1-deathstar-l4
   ```

2. Re-test both consumers:

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec xwing      -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Expected:

   ```
   Ship landed
   command terminated with exit code 28      # xwing: curl timeout, the packet was dropped
   ```

3. Observe the enforcement flip on the endpoint:

   ```bash
   kubectl get cep -o wide
   ```

   Expected:

   ```
   NAME                         ENDPOINT ID   IDENTITY ID   INGRESS ENFORCEMENT   EGRESS ENFORCEMENT   IPV4
   deathstar-8484d6f69c-7xk4t   1204          4711          true                  false                10.244.1.51
   tiefighter                   776           9034          false                 false                10.244.1.94
   xwing                        2295          25871         false                 false                10.244.2.77
   ```

4. Read the compiled policy straight out of the eBPF map on the node where `deathstar` runs:

   ```bash
   POD=deathstar-8484d6f69c-7xk4t
   NODE=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}')
   AGENT=$(kubectl -n kube-system get pod -l k8s-app=cilium \
             --field-selector spec.nodeName="$NODE" -o jsonpath='{.items[0].metadata.name}')
   EPID=$(kubectl get cep "$POD" -o jsonpath='{.status.id}')

   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Expected:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                  PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS   PREFIX
   Allow    Ingress     4711       reserved:unknown                             ANY          NONE         disabled    0       0         0
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire          80/TCP       NONE         disabled    862     11        0
   Allow    Egress      0          reserved:unknown                             ANY          NONE         disabled    4210    36        0
   ```

5. Verify the drop with Hubble:

   ```bash
   cilium hubble port-forward &
   hubble observe --pod default/xwing --verdict DROPPED --last 5
   ```

   Expected:

   ```
   Sep  1 12:04:11.220: default/xwing:41022 (ID:25871) <> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) Policy denied DROPPED (TCP Flags: SYN)
   ```

6. Now add an **egress** rule for `tiefighter` and observe that adding *any* egress rule turns egress into default-deny for that endpoint — including DNS:

   ```yaml
   # 02-egress-trap.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule2-tiefighter-egress
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 02-egress-trap.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Expected — **it now fails**:

   ```
   curl: (6) Could not resolve host: deathstar.default.svc.cluster.local
   command terminated with exit code 6
   ```

7. Confirm the cause and fix it:

   ```bash
   hubble observe --pod default/tiefighter --verdict DROPPED --last 5
   ```

   ```
   Sep  1 12:07:55.001: default/tiefighter:52310 (ID:9034) <> kube-system/coredns-xxxx:53 (ID:15410) Policy denied DROPPED (UDP)
   ```

   ```yaml
   # 02-egress-fixed.yaml — append this rule to spec.egress of rule2-tiefighter-egress
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule2-tiefighter-egress
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         class: tiefighter
     egress:
       - toEndpoints:
           - matchLabels:
               class: deathstar
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
       - toEndpoints:
           - matchLabels:
               io.kubernetes.pod.namespace: kube-system
               k8s-app: kube-dns
         toPorts:
           - ports:
               - port: "53"
                 protocol: ANY
   ```

   ```bash
   kubectl apply -f 02-egress-fixed.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   # Ship landed
   ```

### Comprehension check — Block 2

* **Q2.1** — In step 3, `xwing`'s `INGRESS ENFORCEMENT` is `false` even though its traffic is being dropped. Where is the drop actually happening, and why is that the correct answer for a distributed datapath?
* **Q2.2** — Restate the default-deny rule precisely. Complete the sentence: *"An endpoint enters default-deny for direction D as soon as ______."*
* **Q2.3** — In the `bpf policy get` output there is an `Allow Ingress` entry for identity `4711` (the endpoint's own identity) with `PORT/PROTO ANY`. What is that entry, and would removing it be safe?
* **Q2.4** — Step 6 is the single most common production outage caused by Cilium policy. State the failure in one sentence and name **two** distinct correct remedies (one policy-level, one cluster-level).
* **Q2.5** — The DNS allow rule uses `protocol: ANY` rather than `UDP`. Give a concrete scenario in which restricting it to UDP breaks name resolution.
* **Q2.6** — `rule1-deathstar-l4` selects `org: empire, class: deathstar`, and `rule2` selects `class: tiefighter`. If you delete `rule1`, does `tiefighter` still reach `deathstar`? Explain in terms of which endpoint each rule places into default-deny.

---

## Exercise 3 — Making policy debuggable: audit mode and Hubble

You will almost never write a correct policy on the first attempt against a real application. Audit mode is how you roll one out without an outage.

### Steps

1. Put the `deathstar` endpoint into **policy audit mode**:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint config "$EPID" PolicyAuditMode=Enabled
   ```

   Expected:

   ```
   Endpoint 1204 configuration updated successfully
   ```

2. Confirm the state:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint get "$EPID" \
     -o jsonpath='{[0].spec.options.PolicyAuditMode}{"\n"}'
   # Enabled
   ```

3. Retry the previously-denied request:

   ```bash
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   ```

   Expected — **the request now succeeds**:

   ```
   Ship landed
   ```

4. But the violation is still recorded:

   ```bash
   hubble observe --pod default/xwing --last 5
   ```

   Expected:

   ```
   Sep  1 12:15:02.771: default/xwing:44118 (ID:25871) -> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
   Sep  1 12:15:02.771: default/xwing:44118 (ID:25871) -> default/deathstar-8484d6f69c-7xk4t:80 (ID:4711) to-endpoint FORWARDED (TCP Flags: SYN)
   ```

5. Use Hubble as a policy *generator* — collect every flow the endpoint actually receives, so the resulting policy is derived from observed behaviour rather than guessed:

   ```bash
   hubble observe --to-pod default/deathstar-8484d6f69c-7xk4t --last 200 -o json |
     jq -r 'select(.flow.verdict=="AUDITED" or .flow.verdict=="FORWARDED")
            | [ (.flow.source.namespace + "/" + (.flow.source.labels | join(","))),
                (.flow.l4.TCP.destination_port // .flow.l4.UDP.destination_port | tostring) ]
            | @tsv' | sort -u
   ```

6. Turn audit mode **off** and re-verify the deny:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg endpoint config "$EPID" PolicyAuditMode=Disabled
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   # command terminated with exit code 28
   ```

7. Compare the three `policy-verdict` values you can encounter:

   ```bash
   hubble observe --to-pod default/deathstar-8484d6f69c-7xk4t --type policy-verdict --last 20
   ```

### Comprehension check — Block 3

* **Q3.1** — `PolicyAuditMode` was set per-endpoint via `cilium-dbg`. What is the scope and the lifetime of that setting, and what happens to it when the pod is rescheduled?
* **Q3.2** — Name the cluster-wide way to enable audit mode at install time, and explain why the per-endpoint route is the safer one for a running production cluster.
* **Q3.3** — In step 4, Hubble emits *two* lines for one packet: `AUDITED` then `FORWARDED`. Explain what each line represents in the datapath.
* **Q3.4** — Hubble reports `DROPPED` with reason `Policy denied`. List two *other* drop reasons Cilium can report that would be misread as a policy problem by an inexperienced operator.
* **Q3.5** — Why is `hubble observe` alone insufficient to prove that a policy is correct? What class of traffic will it never show you?

---

## Exercise 4 — L7 HTTP policy and the Envoy redirect

L3/L4 policy answers *who may talk to whom*. L7 policy answers *what they may say*.

### Steps

1. Replace the L4 policy with an L7 policy that permits only `POST /v1/request-landing`:

   ```yaml
   # 03-l7-http.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l7
     namespace: default
   spec:
     description: "L7: empire ships may request landing but not fire the superlaser"
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
                 - method: "GET"
                   path: "/v1/healthz"
   ```

   ```bash
   kubectl delete cnp rule1-deathstar-l4
   kubectl apply -f 03-l7-http.yaml
   ```

2. Test the allowed and the forbidden verb/path pair:

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   kubectl exec tiefighter -- curl -sS -m5 -XPUT  deathstar.default.svc.cluster.local/v1/exhaust-port
   ```

   Expected:

   ```
   Ship landed
   Access denied
   ```

3. Note the crucial difference from an L3/L4 drop — retrieve the HTTP status code:

   ```bash
   kubectl exec tiefighter -- curl -s -o /dev/null -w '%{http_code}\n' -m5 \
     -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
   ```

   Expected:

   ```
   403
   ```

4. Confirm the Envoy redirect now exists in the datapath:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Expected — note the non-zero **PROXY PORT**:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS                                PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire   80/TCP       15039        disabled    1204    16
   ```

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg status | grep Proxy
   # Proxy Status:  OK, ip 10.244.1.180, 1 redirects active on ports 10000-20000, Envoy: external
   ```

5. Read the L7 flow record — Hubble now carries HTTP semantics:

   ```bash
   hubble observe --pod default/tiefighter --protocol http --last 4
   ```

   Expected:

   ```
   Sep  1 12:22:40.104: default/tiefighter:33212 (ID:9034) -> default/deathstar:80 (ID:4711) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
   Sep  1 12:22:40.107: default/tiefighter:33212 (ID:9034) <- default/deathstar:80 (ID:4711) http-response FORWARDED (HTTP/1.1 200 2ms)
   Sep  1 12:23:01.550: default/tiefighter:33218 (ID:9034) -> default/deathstar:80 (ID:4711) http-request DROPPED (HTTP/1.1 PUT http://deathstar.default.svc.cluster.local/v1/exhaust-port)
   ```

6. Add a header-based constraint, which is the shape most real API-gateway-style policies take:

   ```yaml
   # 04-l7-headers.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: rule1-deathstar-l7-headers
     namespace: default
   spec:
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
                 - method: "PUT"
                   path: "/v1/exhaust-port"
                   headers:
                     - "X-Has-Superuser-Token: deathstar-command"
   ```

   ```bash
   kubectl apply -f 04-l7-headers.yaml
   kubectl exec tiefighter -- curl -sS -m5 -XPUT deathstar.default.svc.cluster.local/v1/exhaust-port
   # Access denied
   kubectl exec tiefighter -- curl -sS -m5 -XPUT \
     -H 'X-Has-Superuser-Token: deathstar-command' \
     deathstar.default.svc.cluster.local/v1/exhaust-port
   # Panic: deathstar exploded   (the request was allowed through)
   ```

### Comprehension check — Block 4

* **Q4.1** — An L3/L4 deny produces a TCP timeout; an L7 deny produces `403`. Explain the datapath reason for the difference, and state one security consequence of the L7 behaviour (what does the attacker learn?).
* **Q4.2** — A rule has `toPorts` on port 80 **with** an `http` block, and a second rule on port 80 **without** one. What is the resulting enforcement on port 80? (This is a classic exam trap.)
* **Q4.3** — Why does an L7 policy make the *ordering* of a rolling Cilium upgrade more delicate than an L3/L4 policy? Reference the `Envoy: external` line from Exercise 0.
* **Q4.4** — The service is reached as `deathstar.default.svc.cluster.local`, but the `http-request` flow shows the pod identity `4711` as destination. At what point relative to the Envoy redirect does Service→backend translation happen?
* **Q4.5** — Can you write an L7 HTTP policy for a workload that serves HTTPS on 443 with TLS terminated inside the pod? What are your options?

---

## Exercise 5 — DNS-aware egress (`toFQDNs`) and the DNS proxy

Egress to the internet cannot be expressed with CIDRs when the destination is a CDN-backed API. `toFQDNs` solves this, but only if the DNS proxy sees the lookup.

### Steps

1. Deploy a test client with real external connectivity:

   ```bash
   kubectl run mubuntu --image=nicolaka/netshoot --restart=Never -l app=mubuntu -- sleep infinity
   kubectl wait --for=condition=Ready pod/mubuntu --timeout=60s
   ```

2. Apply an FQDN egress policy. **The `dns` L7 rule is mandatory** — it is what installs the DNS proxy redirect that populates the FQDN cache:

   ```yaml
   # 05-fqdn-egress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: fqdn-allow-github-api
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       # 1. Allow DNS to CoreDNS AND intercept it with the DNS proxy.
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
       # 2. Allow egress only to names that resolved through the proxy.
       - toFQDNs:
           - matchName: "api.github.com"
           - matchPattern: "*.githubusercontent.com"
         toPorts:
           - ports:
               - port: "443"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 05-fqdn-egress.yaml
   ```

3. Test an allowed and a denied destination:

   ```bash
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w 'github:%{http_code}\n' https://api.github.com
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w 'cilium:%{http_code}\n' https://cilium.io
   ```

   Expected:

   ```
   github:200
   curl: (28) Connection timed out after 8001 milliseconds
   ```

4. Inspect the FQDN cache — this is the bridge between a name and the IPs the datapath will accept:

   ```bash
   AGENT2=$(kubectl -n kube-system get pod -l k8s-app=cilium \
     --field-selector spec.nodeName=$(kubectl get pod mubuntu -o jsonpath='{.spec.nodeName}') \
     -o jsonpath='{.items[0].metadata.name}')

   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg fqdn cache list
   ```

   Expected:

   ```
   Endpoint   Source   FQDN               TTL    ExpirationTime             IPs
   3891       lookup   api.github.com.    30     2026-09-01T12:31:04.000Z   140.82.121.6
   3891       lookup   raw.githubusercontent.com.   30   2026-09-01T12:31:09.000Z   185.199.108.133,185.199.109.133
   ```

5. Observe the L7 DNS flows:

   ```bash
   hubble observe --pod default/mubuntu --protocol dns --last 6
   ```

   Expected:

   ```
   Sep  1 12:30:34.001: default/mubuntu:41501 (ID:31122) -> kube-system/coredns-xxx:53 (ID:15410) dns-request proxy FORWARDED (DNS Query api.github.com. A)
   Sep  1 12:30:34.019: kube-system/coredns-xxx:53 (ID:15410) -> default/mubuntu:41501 (ID:31122) dns-response proxy FORWARDED (DNS Answer "140.82.121.6" TTL: 30 (Proxy api.github.com. A))
   Sep  1 12:30:41.700: default/mubuntu:52200 (ID:31122) <> 104.198.14.52:443 (ID:16777219) Policy denied DROPPED (TCP Flags: SYN)
   ```

6. Demonstrate the **bypass**, which is the single most important operational caveat of `toFQDNs`:

   ```bash
   # Resolve the IP out of band, then connect to it directly with SNI.
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w '%{http_code}\n' \
     --resolve api.github.com:443:1.1.1.1 https://api.github.com
   ```

   Expected — this fails, because `1.1.1.1` never went through the proxy:

   ```
   curl: (28) Connection timed out
   ```

   Now the opposite direction — a shared IP:

   ```bash
   kubectl exec mubuntu -- getent hosts raw.githubusercontent.com
   # 185.199.108.133  raw.githubusercontent.com
   kubectl exec mubuntu -- curl -sS -m8 -o /dev/null -w '%{http_code}\n' \
     -H 'Host: gist.githubusercontent.com' https://185.199.108.133
   ```

7. Check the identity allocated for the FQDN-derived CIDR:

   ```bash
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg identity list | grep -A2 'cidr:140.82'
   ```

   Expected:

   ```
   16777224   cidr:140.82.121.6/32
              reserved:world
   ```

### Comprehension check — Block 5

* **Q5.1** — Remove the `rules: dns:` block from the first egress rule but keep everything else. Predict exactly what happens to `curl https://api.github.com`, and explain why.
* **Q5.2** — Step 6 shows that `toFQDNs` binds a *name* to the *IPs the proxy observed*. State the security guarantee `toFQDNs` actually gives you, and the one it does **not** give you.
* **Q5.3** — The identity in step 7 is `16777224`, far above the cluster identity range. What scope is that identity in, and what breaks if you assumed it were consistent across nodes?
* **Q5.4** — An external API returns a 30-second TTL but the application caches DNS in-process for 1 hour. Describe the outage this causes and name the Cilium setting that mitigates it.
* **Q5.5** — Why does `matchPattern: "*"` in the DNS rule not weaken the policy, given that step 3 still denies `cilium.io`?
* **Q5.6** — The DNS proxy is a userspace component in the `cilium-agent` process. What happens to in-flight DNS lookups when the agent restarts, and which Helm value hardens this?

---

## Exercise 6 — Entities, CIDR, and deny-rule precedence

### Steps

1. Express "may reach anything outside the cluster except the metadata service and RFC1918" using an allow plus an explicit deny:

   ```yaml
   # 06-world-egress-with-deny.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: egress-world-except-internal
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       - toEntities:
           - world
           - cluster
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
     egressDeny:
       - toCIDR:
           - 169.254.169.254/32          # cloud instance metadata
       - toCIDRSet:
           - cidr: 10.0.0.0/8
             except:
               - 10.244.0.0/16           # keep the pod CIDR reachable
           - cidr: 172.16.0.0/12
           - cidr: 192.168.0.0/16
   ```

   ```bash
   kubectl delete cnp fqdn-allow-github-api
   kubectl apply -f 06-world-egress-with-deny.yaml
   ```

2. Verify the deny wins over the broad allow:

   ```bash
   kubectl exec mubuntu -- curl -sS -m4 -o /dev/null -w 'meta:%{http_code}\n' http://169.254.169.254/
   kubectl exec mubuntu -- curl -sS -m6 -o /dev/null -w 'ext:%{http_code}\n'  https://cilium.io
   ```

   Expected:

   ```
   curl: (28) Connection timed out after 4001 milliseconds
   ext:200
   ```

3. Confirm the deny entry in the datapath:

   ```bash
   EP2=$(kubectl get cep mubuntu -o jsonpath='{.status.id}')
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg bpf policy get "$EP2" | grep -i deny
   ```

   Expected:

   ```
   Deny    Egress   16777231   cidr:169.254.169.254/32,reserved:world   ANY   NONE   disabled   0   0   0
   ```

4. Demonstrate the `world` vs `cluster` vs `all` distinction:

   ```bash
   kubectl -n kube-system exec "$AGENT2" -- cilium-dbg policy get | \
     jq -r '.[].egress[]?.toEntities[]?' 2>/dev/null | sort -u
   ```

5. Add an explicit `kube-apiserver` egress rule — required in any cluster where workloads talk to the API (operators, controllers, service meshes):

   ```yaml
   # 07-apiserver-egress.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: allow-apiserver
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         app: mubuntu
     egress:
       - toEntities:
           - kube-apiserver
         toPorts:
           - ports:
               - port: "6443"
                 protocol: TCP
   ```

   ```bash
   kubectl apply -f 07-apiserver-egress.yaml
   kubectl exec mubuntu -- curl -sSk -m5 -o /dev/null -w '%{http_code}\n' https://kubernetes.default.svc/healthz
   # 401     (reachable; 401 is the expected unauthenticated answer)
   ```

### Comprehension check — Block 6

* **Q6.1** — State the precedence rule between `egress` and `egressDeny` in one sentence. Is there any allow rule — L7 included — that can override a deny?
* **Q6.2** — In step 1, `toCIDRSet` with `except: 10.244.0.0/16` is used instead of listing many small CIDRs. Explain how this is compiled and why the `except` list matters for the LPM trie in eBPF.
* **Q6.3** — Distinguish `reserved:world`, `reserved:all`, `reserved:cluster` and `reserved:remote-node`. Which one silently includes the node's own host namespace?
* **Q6.4** — A `toCIDR: 0.0.0.0/0` rule and a `toEntities: [world]` rule look equivalent. Name one case where they behave differently.
* **Q6.5** — Before the `kube-apiserver` entity existed, operators wrote `toCIDR` with the API server's IP. Give two reasons the entity is strictly better in a managed cluster.
* **Q6.6** — Why is the metadata-service deny (`169.254.169.254`) considered a *baseline* control rather than an application-specific one? What attack does it block?

---

## Exercise 7 — Clusterwide policy and the host firewall

`CiliumClusterwideNetworkPolicy` (CCNP) is not namespaced and is the only object that can carry a `nodeSelector`, which is how you firewall the **node itself**.

### Steps

1. Establish a cluster-wide default-deny baseline that still permits DNS and health checks — the shape most platform teams ship:

   ```yaml
   # 08-ccnp-baseline.yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata:
     name: baseline-default-deny
   spec:
     description: "Cluster-wide default deny with DNS and health exceptions"
     endpointSelector:
       matchExpressions:
         - key: io.kubernetes.pod.namespace
           operator: NotIn
           values: ["kube-system"]
     ingress:
       - fromEntities:
           - host
           - remote-node
           - health
     egress:
       - toEntities:
           - host
           - remote-node
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

   > **Do not apply this to a production cluster without audit mode first.** Applying it here will break the demo app's ingress until you re-add the earlier policies.

   ```bash
   kubectl apply -f 08-ccnp-baseline.yaml
   kubectl get ccnp
   ```

2. Enable the host firewall and restart the agents:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set hostFirewall.enabled=true \
     --set devices='{eth0}'
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

3. Confirm the host endpoint now exists and is *not yet* enforcing:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list | grep -E 'ENDPOINT|reserved:host'
   ```

   Expected:

   ```
   ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS
                ENFORCEMENT        ENFORCEMENT
   1783       Disabled           Disabled          1          reserved:host
   ```

4. **Put the host endpoint into audit mode before writing a single host rule.** This is the step that prevents locking yourself out of every node simultaneously:

   ```bash
   HOSTEP=$(kubectl -n kube-system exec ds/cilium -- \
     cilium-dbg endpoint list -o jsonpath='{[?(@.status.identity.id==1)].id}')
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config "$HOSTEP" PolicyAuditMode=Enabled
   ```

5. Apply a host policy that permits SSH, the kubelet, and the control-plane ports:

   ```yaml
   # 09-host-firewall.yaml
   apiVersion: cilium.io/v2
   kind: CiliumClusterwideNetworkPolicy
   metadata:
     name: host-firewall-workers
   spec:
     description: "Node ingress: SSH, kubelet, VXLAN, health"
     nodeSelector:
       matchLabels:
         node-role.kubernetes.io/worker: ""
     ingress:
       - fromEntities:
           - remote-node
           - health
           - cluster
       - fromCIDR:
           - 10.0.0.0/8
         toPorts:
           - ports:
               - port: "22"
                 protocol: TCP
               - port: "10250"    # kubelet
                 protocol: TCP
               - port: "8472"     # VXLAN
                 protocol: UDP
               - port: "4240"     # cilium health
                 protocol: TCP
   ```

   ```bash
   kubectl label node cca-worker  node-role.kubernetes.io/worker=""
   kubectl label node cca-worker2 node-role.kubernetes.io/worker=""
   kubectl apply -f 09-host-firewall.yaml
   ```

6. Harvest what audit mode would have blocked, **before** enforcing:

   ```bash
   hubble observe --identity 1 --verdict AUDIT --last 100 -o json |
     jq -r '[.flow.IP.source, (.flow.l4.TCP.destination_port // .flow.l4.UDP.destination_port)] | @tsv' |
     sort | uniq -c | sort -rn
   ```

7. Only when that list is empty (or fully understood), disable audit mode:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config "$HOSTEP" PolicyAuditMode=Disabled
   ```

8. Clean up so later exercises are not affected:

   ```bash
   kubectl delete ccnp baseline-default-deny host-firewall-workers
   ```

### Comprehension check — Block 7

* **Q7.1** — What happens if you apply a CCNP with **both** `endpointSelector` and `nodeSelector` set? What does the API server / Cilium operator do?
* **Q7.2** — In step 1, `endpointSelector` uses `matchExpressions ... NotIn [kube-system]`. Why is an empty `endpointSelector: {}` in a CCNP dangerous?
* **Q7.3** — The host policy allows `fromEntities: [remote-node]`. What breaks first in a 3-node cluster if you omit it?
* **Q7.4** — Host-firewall ingress is enforced, but egress from the host endpoint is a separate concern. Which system component's traffic originates from `reserved:host` and would be affected by a host *egress* policy?
* **Q7.5** — You applied a host policy and lost SSH to every worker at once. Describe the recovery procedure that does not require console access.
* **Q7.6** — Why does `hostFirewall.enabled=true` require `devices` to be specified in some environments, and what is the consequence of getting the device list wrong?

---

## Exercise 8 — Transparent encryption and mutual authentication

Policy answers *who may connect*. Encryption answers *who can read it on the wire*. Mutual authentication answers *is the peer really who its labels claim*.

### Steps

1. Enable WireGuard transparent encryption:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set encryption.enabled=true \
     --set encryption.type=wireguard
   kubectl -n kube-system rollout restart ds/cilium
   kubectl -n kube-system rollout status ds/cilium
   ```

2. Verify from the agent's own status:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
   ```

   Expected:

   ```
   Encryption: Wireguard
   Interface: cilium_wg0
     Public key: pM3W9v0Yc3l9Zk2Bp1qX4d7hR8s+Tn5Qw0Lm6Vg2Xk4=
     Number of peers: 2
   ```

3. Confirm each node published a public key:

   ```bash
   kubectl get ciliumnodes -o custom-columns=\
   'NODE:.metadata.name,WG_PUBKEY:.metadata.annotations.network\.cilium\.io/wg-pub-key'
   ```

4. Prove the traffic is actually encrypted on the wire — capture on the node's physical interface while generating pod-to-pod traffic across nodes:

   ```bash
   # Terminal A: capture on a worker
   docker exec cca-worker timeout 20 tcpdump -ni eth0 'udp port 51871' -c 5
   # Terminal B: cross-node traffic
   kubectl exec xwing -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing || true
   ```

   Expected in terminal A — only opaque UDP, no readable HTTP:

   ```
   12:51:03.114 IP 172.18.0.3.51871 > 172.18.0.4.51871: UDP, length 176
   12:51:03.115 IP 172.18.0.4.51871 > 172.18.0.3.51871: UDP, length 176
   ```

5. Now enable SPIRE-backed **mutual authentication**:

   ```bash
   helm upgrade cilium cilium/cilium --version 1.17.1 \
     --namespace kube-system --reuse-values \
     --set authentication.mutual.spire.enabled=true \
     --set authentication.mutual.spire.install.enabled=true
   kubectl -n cilium-spire rollout status statefulset/spire-server
   kubectl -n kube-system rollout restart ds/cilium
   ```

6. Require mutual authentication on a specific rule:

   ```yaml
   # 10-mutual-auth.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: deathstar-mutual-auth
     namespace: default
   spec:
     endpointSelector:
       matchLabels:
         org: empire
         class: deathstar
     ingress:
       - fromEndpoints:
           - matchLabels:
               class: tiefighter
         authentication:
           mode: "required"
         toPorts:
           - ports:
               - port: "80"
                 protocol: TCP
   ```

   ```bash
   kubectl delete cnp rule1-deathstar-l7 rule1-deathstar-l7-headers --ignore-not-found
   kubectl apply -f 10-mutual-auth.yaml
   ```

7. Observe the auth handshake in the policy map and in Hubble:

   ```bash
   kubectl -n kube-system exec "$AGENT" -- cilium-dbg bpf policy get "$EPID"
   ```

   Expected — note **AUTH TYPE**:

   ```
   POLICY   DIRECTION   IDENTITY   LABELS                                PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS
   Allow    Ingress     9034       k8s:class=tiefighter,k8s:org=empire   80/TCP       NONE         spire       0       0
   ```

   ```bash
   kubectl exec tiefighter -- curl -sS -m5 -XPOST deathstar.default.svc.cluster.local/v1/request-landing
   hubble observe --pod default/tiefighter --last 6
   ```

   Expected — the **first** packet is dropped while the handshake completes, then traffic flows:

   ```
   Sep  1 12:58:10.001: default/tiefighter (ID:9034) <> default/deathstar (ID:4711) Authentication required DROPPED (TCP Flags: SYN)
   Sep  1 12:58:10.412: default/tiefighter (ID:9034) -> default/deathstar (ID:4711) to-endpoint FORWARDED (TCP Flags: SYN)
   ```

8. Inspect the auth cache and the registered SPIFFE identities:

   ```bash
   kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf auth list
   kubectl -n cilium-spire exec -c spire-server spire-server-0 -- \
     /opt/spire/bin/spire-server entry show -socketPath /run/spire/sockets/server.sock | head -20
   ```

   Expected (abbreviated):

   ```
   Entry ID     : 8f0c...
   SPIFFE ID    : spiffe://spiffe.cilium/identity/4711
   Parent ID    : spiffe://spiffe.cilium/cilium-agent
   Selector     : cilium:mutual-auth
   ```

### Comprehension check — Block 8

* **Q8.1** — WireGuard is enabled but pod-to-pod traffic *within a single node* is not encrypted. Is that a bug? Explain the threat model.
* **Q8.2** — Compare WireGuard and IPsec in Cilium along three axes: key rotation, kernel requirements, and FIPS/compliance posture.
* **Q8.3** — In step 7 the very first SYN is dropped with `Authentication required`. Explain why this is *by design* and what the application must tolerate.
* **Q8.4** — The SPIFFE ID is `spiffe://spiffe.cilium/identity/4711` — it encodes the numeric **security identity**, not the pod or ServiceAccount. What does mutual authentication therefore prove, and what does it *not* prove?
* **Q8.5** — Does `authentication.mode: required` encrypt the payload? If not, what does it add on top of WireGuard, and what is the correct mental model of the two features together?
* **Q8.6** — `encryption.nodeEncryption=true` is a separate flag. What additional traffic does it cover, and why is it off by default?

---

## Exercise 9 — Full verification and teardown

### Steps

1. Run the official end-to-end suite, which exercises L3/L4, L7, DNS, and encryption paths:

   ```bash
   cilium connectivity test --test-namespace cilium-test
   ```

   Expected tail:

   ```
   ✅ All 58 tests (312 actions) successful, 12 tests skipped, 0 scenarios skipped.
   ```

2. Run the encryption-aware subset:

   ```bash
   cilium connectivity test --include-unsafe-tests --test 'pod-to-pod-encryption'
   ```

3. Produce a policy inventory for review — everything enforced, in one place:

   ```bash
   kubectl get cnp,ccnp -A -o custom-columns=\
   'KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.endpointSelector.matchLabels'
   ```

4. Cross-check that Kubernetes-native `NetworkPolicy` objects are also being enforced by Cilium (they are, unless `enableK8sNetworkPolicy=false`):

   ```bash
   kubectl get netpol -A
   kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get | jq -r '.[].labels[]?' | sort -u | head
   ```

5. Collect a support bundle before changing anything — this is what you attach to an incident ticket:

   ```bash
   cilium sysdump --output-filename cca-51-sysdump
   ```

6. Tear down:

   ```bash
   kubectl delete cnp --all -n default
   kubectl delete ccnp --all
   kubectl delete -f https://raw.githubusercontent.com/cilium/cilium/1.17.1/examples/minikube/http-sw-app.yaml
   kubectl delete pod mubuntu --ignore-not-found
   kind delete cluster --name cca
   ```

### Comprehension check — Block 9

* **Q9.1** — `cilium connectivity test` reports 12 tests **skipped**. Name two feature flags whose absence causes tests to be skipped rather than failed, and explain why "all tests passed" is a weaker claim than it sounds.
* **Q9.2** — A Kubernetes `NetworkPolicy` and a `CiliumNetworkPolicy` both select the same pod. Which wins? Under what circumstance does the answer change?
* **Q9.3** — Name two things a `CiliumNetworkPolicy` can express that a Kubernetes `NetworkPolicy` cannot, and one thing you lose by choosing the CRD.
* **Q9.4** — `cilium sysdump` is run *before* remediation. What policy-specific artefacts does it capture that `kubectl get cnp` would miss?

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 0

**A0.1** — The three values are `default`, `always`, `never`.
* `default` — an endpoint selected by **no** policy in a given direction is **allow-all** in that direction. Enforcement is turned on per-direction, per-endpoint, the moment at least one rule selects it.
* `always` — every endpoint is default-deny in both directions from the start, regardless of whether any policy selects it. Correct for a hardened cluster, but it will break the cluster the instant it is enabled unless every path is already covered (including `kube-system`).
* `never` — policy is never enforced. Rules are still computed and Hubble still emits `policy-verdict` events, which makes it a dry-run mode for the whole cluster.

**A0.2** — L7 policy, and any policy whose source is a *pod identity* behind a Service. With kube-proxy doing DNAT in netfilter before the Cilium BPF program runs, the original destination has already been rewritten, and Cilium loses the ability to attach the socket-level redirect cleanly. In practice `kubeProxyReplacement=true` also enables the socket-LB, which is what allows the L7 proxy redirect and correct source-identity preservation. Running both is supported but is a common source of subtle policy misses.

**A0.3** — Embedded Envoy runs inside the `cilium-agent` process; external Envoy runs as its own DaemonSet (`cilium-envoy`). With embedded Envoy, an agent restart tears down every L7 redirect on that node — every proxied connection drops during an upgrade. With the DaemonSet, agent and proxy lifecycles are decoupled, so an agent restart or a Cilium upgrade does not sever L7-proxied connections. This is why external Envoy is the default from 1.16 onward and why it matters for the blast radius of L7 policy.

**A0.4** — `policyEnforcementMode=default` plus zero policies selecting `deathstar`: the endpoint is in allow-all for both directions. Cilium does not implicitly deny anything until a rule selects the endpoint.

---

### Block 1

**A1.1** — **No.** `k8s:io.kubernetes.pod.namespace` is part of the security-relevant label set (visible in step 5), so the namespace is baked into the identity. Two pods with identical app labels in different namespaces get two distinct identities. This is also why a `fromEndpoints: {matchLabels: {app: foo}}` rule in a CNP is implicitly scoped to the policy's own namespace unless you add `io.kubernetes.pod.namespace` explicitly.

**A1.2** — **Zero.** All 300 replicas share the same label set (minus `pod-template-hash`, which is excluded) and therefore the same identity. The eBPF policy map is keyed on `(direction, identity, port, protocol)`, so its size is O(number of distinct identity/port pairs allowed), not O(number of pods). This is the whole point of identity-based security and the reason Cilium policy scales where iptables-per-IP does not.

**A1.3** — Every rolling update generates a new `pod-template-hash`, so every rollout would allocate a brand-new identity for the same logical workload. Consequences: identity churn on every deploy, a policy-map regeneration storm across all nodes that reference it, and — worst — a window during which the new pods' identity is unknown to peers' policy maps, causing transient drops for a workload whose labels and policy did not change.

**A1.4** — `reserved:host` is the **local** node's host namespace only; `reserved:remote-node` covers the *other* nodes in the cluster. Allowing only `reserved:host` means health checks, kubelet probes and any node-sourced traffic from a **different** node are dropped. The classic symptom: liveness probes pass for pods on the same node as the kubelet issuing them and fail for everything else, or Cilium health checks report the node as unreachable in one direction. (In older releases `reserved:host` included remote nodes; the split was made deliberately so that a compromised node cannot impersonate the local host identity.)

**A1.5** — Because CIDR and FQDN identities are derived from data that is not globally consistent. An FQDN resolves to different IPs on different nodes at different times (CDNs, geo-DNS, TTL skew), and each node's DNS proxy observes its own answer set. Allocating those identities cluster-wide through the kvstore/CRD backend would require distributed consensus on every DNS response — prohibitively expensive and racy. So they are allocated in a node-local numeric range (`16777216`+), meaning **the same numeric ID can mean different CIDRs on different nodes**. Never correlate a local-scope identity number across nodes.

---

### Block 2

**A2.1** — The drop happens at the **destination** endpoint (`deathstar`), in that endpoint's ingress BPF program. `xwing` has no policy selecting it, so its egress is unenforced and its `EGRESS ENFORCEMENT` is correctly `false`. This is right for a distributed datapath: ingress policy is enforced where the receiving endpoint's policy map lives, so a compromised sender cannot skip its own enforcement. It also explains the Hubble output — the flow is reported with the destination endpoint as the reporting node.

**A2.2** — *"An endpoint enters default-deny for direction D as soon as at least one policy rule selects that endpoint via `endpointSelector` (or `nodeSelector` for host policies) **and** that rule contains a section for direction D."* Note the two independent conditions: a policy with only an `ingress:` section does **not** put egress into default-deny, and an empty `ingress: []` list *does* select the direction and denies everything in it — that is the idiomatic way to write default-deny for one direction.

**A2.3** — It is the automatically-installed **same-identity allow** (and the `reserved:unknown`/wildcard rows that back the allow-all entries). Cilium always permits traffic between endpoints sharing an identity — replicas of the same Deployment talking to each other, sidecars, etc. It is not removable through policy; if you need to prevent same-identity communication you must split the workload into distinct label sets (distinct identities) first. Do not read those rows as a hole in your policy.

**A2.4** — **The failure:** adding any `egress` rule flips the endpoint to egress default-deny, which silently kills DNS to CoreDNS, so the application fails at name resolution rather than at connection — producing a misleading `Could not resolve host` instead of a policy timeout.
**Remedy 1 (policy-level):** explicitly allow egress on port 53 to the `kube-dns` endpoints in every policy that adds an egress section — ideally by shipping a `CiliumClusterwideNetworkPolicy` that grants DNS egress to all namespaces, so individual app policies never have to remember.
**Remedy 2 (cluster-level):** enable audit mode on the endpoint (or `policyEnforcementMode=never`) before rollout, harvest the actual flows from Hubble, and only then enforce — the same procedure as Exercise 3.

**A2.5** — DNS falls back to **TCP/53** whenever a response exceeds the UDP payload limit — large answer sets, DNSSEC records, or any response with the truncated (TC) bit set. It is also used by resolvers configured with `use-vc`. Restricting to UDP produces an intermittent, size-dependent resolution failure that is extremely hard to diagnose: small names resolve, large ones do not.

**A2.6** — **No, `tiefighter` no longer reaches `deathstar`... and then it does.** Careful: deleting `rule1` removes the only policy selecting `deathstar`, so `deathstar`'s ingress returns to unenforced (allow-all). `rule2` selects `tiefighter` and enforces its *egress*, which still permits port 80 to `class: deathstar`. So the answer is **yes, it still works** — but for a different reason than before: previously it was allowed by `deathstar`'s ingress rule and `tiefighter`'s egress rule; now only the egress rule is doing any work. The lesson is that ingress and egress enforcement are independent per-endpoint states, and removing a policy can widen access for *other* peers (e.g. `xwing` can now reach `deathstar` again).

---

### Block 3

**A3.1** — The scope is a **single endpoint on a single node**, and the lifetime is the endpoint's. It is stored in the agent's endpoint state, not in a Kubernetes object. When the pod is deleted, rescheduled, or the node's agent loses its endpoint state, the setting is gone and enforcement returns to normal. It is deliberately ephemeral: audit mode is a debugging state, not a configuration you can accidentally leave in Git.

**A3.2** — Cluster-wide: `--set policyAuditMode=true` at install/upgrade time (Helm), which puts **every** endpoint into audit mode. That is precisely why the per-endpoint route is safer in production — the Helm flag requires an agent restart, applies to all workloads including ones whose policy is already correct and already protecting them, and creates a window in which the entire cluster is effectively unenforced. The per-endpoint command is instantaneous, scoped to the one workload you are onboarding, requires no restart, and self-heals if forgotten.

**A3.3** — The `policy-verdict ... AUDITED` line is emitted by the **policy engine**: it records the verdict the policy *would* have produced (deny), tagged as audited rather than enforced. The `to-endpoint ... FORWARDED` line is emitted by the **datapath** at the point of delivery: the packet was actually passed to the endpoint. Two subsystems, two events, one packet. In enforcing mode you would see a single `Policy denied DROPPED` and no `to-endpoint` line at all.

**A3.4** — Common ones misread as policy problems:
* `Stale or unroutable IP` / `Unsupported L3 protocol` — the destination identity or route is not yet known to this node, typically during pod startup or identity propagation. Looks like a policy deny but is a race, and resolves on retry.
* `Authentication required` — the mutual-auth handshake has not completed yet (Exercise 8). The policy *allows* the flow; only the auth state is missing.
* `Service backend not found` / `No mapping for NAT masquerade` — a load-balancing or connectivity failure, not policy.
* `CT: Map insertion failed` — conntrack table exhaustion. This one is capacity, not security, and the fix is `bpf-ct-global-tcp-max`.

**A3.5** — Hubble shows traffic that was **attempted**. It cannot show you a permission your policy grants but that nobody has exercised yet — the over-permissive rule that only becomes an incident when an attacker uses it. Concretely: a policy allowing egress to `0.0.0.0/0` looks identical in Hubble to one allowing egress to a single API, as long as the application only ever talks to that API. Proving a policy is *tight* requires reading the policy (`cilium-dbg bpf policy get`, `cilium-dbg policy get`) and, ideally, an adversarial test — not observing production flows.

---

### Block 4

**A4.1** — **Reason:** an L3/L4 deny drops the packet in eBPF before any connection exists, so the client sees nothing and times out on SYN retransmission. An L7 deny requires the TCP handshake to *complete* — the connection is redirected to Envoy, Envoy parses the HTTP request, and only then applies the rule; a rejection at that point can only be expressed in-protocol, as `403 Access denied`.
**Security consequence:** the L7 behaviour is an information disclosure. The attacker learns the destination exists, is listening, speaks HTTP, and that their L3/L4 access is permitted — they now have a working oracle to enumerate which paths and methods are allowed by probing for `403` versus `200`/`404`. L3/L4 denial leaks nothing. This is a real trade-off, not a defect: you accept it in exchange for method/path granularity.

**A4.2** — **Port 80 becomes fully open at L4 — the L7 rule is effectively neutralised.** Cilium takes the union of allow rules, and a rule that permits port 80 with no L7 constraint is strictly broader than one that permits port 80 with an HTTP constraint. The result is that any HTTP method and path is allowed from any source the L4 rule matches. This is the trap: adding a "temporary" L4 rule for debugging silently disables the L7 policy you thought was protecting the endpoint. Verify with `cilium-dbg bpf policy get` — if `PROXY PORT` is `NONE` for a row you expected to be proxied, an L4-wide rule has shadowed it.

**A4.3** — With embedded Envoy (agent-internal), the L7 proxy dies and restarts with the agent, so every connection currently traversing the proxy is severed on each agent restart during a rolling upgrade — for L7-policed workloads that is a visible outage per node. `Envoy: external` (the `cilium-envoy` DaemonSet, default since 1.16) decouples them, so agent restarts leave the proxy and its established connections intact. If you are on embedded Envoy, schedule L7-policed workload upgrades accordingly, or migrate to the external proxy before rolling out L7 policy broadly.

**A4.4** — Service→backend translation happens **first**, in the socket-level load balancer (`kubeProxyReplacement`), at `connect()` time in the client pod — before the packet is ever built, and therefore before the Envoy redirect. By the time the flow reaches the destination node's ingress program and gets redirected to Envoy, the destination is already the concrete backend pod IP and its identity (`4711`). This is also why `toServices` in an egress policy resolves to backend endpoint identities rather than the ClusterIP.

**A4.5** — Not directly: Cilium's L7 policy engine needs to see cleartext HTTP, and it does not terminate TLS for you by default. Your options, in order of preference:
1. **Terminate TLS at the ingress/mesh boundary** and apply the L7 policy on the cleartext hop inside the cluster — the normal design.
2. Use **Cilium's TLS interception** for egress (`terminatingTLS` / `originatingTLS` in the `toPorts` block with a CA secret Cilium controls). This is a real MITM and requires distributing the CA to workloads; supported, but a significant operational commitment.
3. Fall back to **SNI-based control** (`serverNames` in the TLS rule) — you get destination-hostname granularity without decryption, but no method/path granularity.
4. Enforce at L3/L4 only, and push the authorization decision into the application.

---

### Block 5

**A5.1** — `curl https://api.github.com` **fails with a timeout on connect** (DNS itself still works). Without `rules: dns:`, no DNS proxy redirect is installed, so the agent never observes the answer for `api.github.com`, the FQDN cache stays empty, and no CIDR identity is ever allocated for `140.82.121.6`. The `toFQDNs` rule then matches nothing and the connection is denied as `reserved:world`. This is *the* most common `toFQDNs` mistake: the DNS L7 rule is not an optimisation, it is the mechanism.

**A5.2** — **What it guarantees:** the workload may only send packets to IP addresses that *this node's DNS proxy observed being returned* for a name matching your pattern, within the TTL. It ties egress to an actual, policy-visible DNS resolution.
**What it does not guarantee:** that the destination *is* that host. It is IP-based enforcement under the hood. Any other service sharing that IP is reachable (step 6's shared-IP case: `185.199.108.133` serves many `*.github.io` and `*.githubusercontent.com` sites, so allowing one allows all of them). Conversely, a workload using a hardcoded IP or its own resolver bypasses the mechanism — which is why `toFQDNs` must be paired with an `egressDeny`/absent-allow for direct-IP egress and a policy that forces DNS through the cluster resolver. `toFQDNs` is a *usability* control over CIDR egress, not a cryptographic identity check. For that, see mutual authentication.

**A5.3** — It is in the **local (node-scoped) identity range**. The ID is meaningful only on the node that allocated it. If you build tooling that joins Hubble flows or `bpf policy get` output across nodes by numeric identity, local-scope identities will produce nonsense — the same number maps to different CIDRs on different nodes. Always resolve local-scope identities via `cilium-dbg identity list` **on the node that reported the flow**.

**A5.4** — **The outage:** the app resolves once, caches the IP for an hour, and keeps using it. Cilium expires the FQDN cache entry after the 30s TTL (plus grace), removes the CIDR identity, and starts dropping the app's traffic to an IP it is still happily using. The symptom is "it worked for the first minute after deploy and then stopped", with no config change.
**The mitigation:** `--tofqdns-min-ttl` (Helm: `dnsPolicy`/`toFQDNs` tuning, agent flag `--tofqdns-min-ttl`, default 3600s in recent releases) raises the floor on how long an entry is retained regardless of the upstream TTL, and `--tofqdns-idle-connection-grace-period` keeps identities alive while connections are still using them. Raising the minimum TTL is the standard fix; the cost is a wider window in which a re-pointed DNS record is still permitted.

**A5.5** — Because the two rules do different jobs. `matchPattern: "*"` in the **`dns`** rule governs *which DNS queries the proxy will forward and observe* — it says "let this pod look up anything, and watch every answer". It grants no data-plane egress at all. The **`toFQDNs`** rule is what grants egress, and it is restricted to `api.github.com` and `*.githubusercontent.com`. So `cilium.io` resolves successfully (the proxy allows and observes the lookup) but the subsequent TCP connection to its IP is denied. If you *do* want to restrict which names may even be resolved — a useful DNS-exfiltration control — narrow the `matchPattern` in the `dns` rule, and expect to see `dns-request DROPPED` in Hubble for anything else.

**A5.6** — In-flight lookups fail during the restart window, and — worse — newly-resolved names are not observed, so new connections to FQDN-allowed destinations are denied until the proxy is back and the app re-resolves. The hardening is `dnsProxy.enableTransparentMode=true` (transparent DNS proxy mode, default in recent versions), which keeps the redirect rules in the datapath across agent restarts, plus `bpf.preallocateMaps`/`enableRuntimeDeviceDetection` for general restart resilience. The FQDN cache is also persisted to disk and restored on agent start, which bounds the damage.

---

### Block 6

**A6.1** — **Deny rules always win.** For any given flow, if a `ingressDeny`/`egressDeny` rule matches, the flow is dropped, unconditionally and irrespective of how specific or how numerous the matching allow rules are — including L7 allow rules. There is **no** allow rule that can override a deny. This is intentional: it makes deny rules a safe primitive for platform-level guardrails that application teams cannot accidentally punch through with their own CNPs. The corollary is that a badly-scoped deny rule is an outage with no application-side workaround.

**A6.2** — `toCIDRSet` with `except` is compiled into a **longest-prefix-match (LPM) trie** in the eBPF CIDR map. The `10.0.0.0/8` prefix is inserted as a deny entry and `10.244.0.0/16` is inserted as a more-specific entry that does *not* carry the deny. Because lookup is longest-prefix, a packet to `10.244.1.51` matches the /16 and is not denied, while `10.1.2.3` falls through to the /8 and is. Writing this as an explicit list of non-overlapping CIDRs would require dozens of entries, each consuming a map slot and each needing recalculation when the pod CIDR changes. The `except` form keeps the map small and the intent readable — and it is the only correct way to carve a hole in a supernet, because you cannot express "deny X but not Y" with two independent rules given that deny wins.

**A6.3** —
* `reserved:world` — everything **outside** the cluster: all IPs not known to Cilium as a pod, node, or cluster entity.
* `reserved:all` — literally everything, in-cluster and out. Equivalent to no L3 restriction.
* `reserved:cluster` — everything **inside** the cluster: all pods in all namespaces, plus `host`, `remote-node`, `health` and `init`. **This is the one that silently includes the node's own host namespace** (and every other node's) — so `toEntities: [cluster]` is much broader than "all pods" and grants reachability to node-level services.
* `reserved:remote-node` — the host namespaces of *other* nodes only, not the local one.

**A6.4** — They differ on **in-cluster destinations**. `toCIDR: 0.0.0.0/0` matches by IP prefix and therefore also matches pod IPs, node IPs and ClusterIPs that fall inside it — it is effectively allow-all. `toEntities: [world]` matches by *identity* and deliberately excludes anything Cilium knows to be in-cluster, so pods and nodes are **not** covered. Using `0.0.0.0/0` when you meant "the internet" is a real over-grant. (Related subtlety: `toCIDR` on an in-cluster IP creates a CIDR identity that can shadow the pod identity in policy evaluation — another reason to prefer entities and endpoint selectors for in-cluster destinations.)

**A6.5** — (1) **The API server IP is not stable** in a managed cluster — it may be a load balancer with a rotating address set, multiple control-plane IPs, or a private-endpoint IP that changes on upgrade. A hardcoded `toCIDR` breaks silently at the worst moment. (2) **The entity is maintained by Cilium**, which learns the API server's addresses from the `kubernetes` Service endpoints and keeps identity `7` accurate as they change, including across control-plane replacements. Bonus reason: on many managed platforms the API server IP falls inside a range you would otherwise want to deny (RFC1918, or the same LB range as other services), so a CIDR rule forces you to punch a hole that is wider than the API server alone.

**A6.6** — Because it is not about any one application's requirements — no legitimate workload in the cluster needs the node's cloud instance-metadata endpoint, and every workload is equally capable of abusing it. It blocks the **cloud credential theft / SSRF-to-IMDS** attack: a compromised or SSRF-vulnerable pod requests `http://169.254.169.254/latest/meta-data/iam/security-credentials/` (AWS) or the equivalent GCP/Azure path, and receives the *node's* IAM role credentials — instantly escalating from one pod to whatever the node instance profile can do, cluster-wide and often account-wide. It belongs in a `CiliumClusterwideNetworkPolicy` applied to every namespace by default, as a `egressDeny` so no application policy can re-enable it. (IMDSv2 raises the bar but does not close it; the network control is the durable fix.)

---

### Block 7

**A7.1** — Setting both is **invalid and rejected**. `nodeSelector` and `endpointSelector` are mutually exclusive in a CCNP: a policy either targets pod endpoints or targets node (host) endpoints, never both. The CRD's validation schema rejects the object, and the Cilium operator will report the policy as invalid — it is not silently half-applied. Write two separate CCNPs.

**A7.2** — An empty `endpointSelector: {}` in a **CCNP** selects **every endpoint in the cluster, in every namespace, including `kube-system`**. Combined with a default-deny shape (an `ingress:`/`egress:` section that does not cover the control plane's own traffic), it takes down CoreDNS, the Cilium operator, the metrics stack, and any CNI-adjacent component simultaneously — and because CoreDNS is down, most recovery tooling that resolves names also stops working. In a namespaced CNP an empty selector is merely "all pods in this namespace" and is a normal idiom; in a CCNP it is a cluster-wide blast radius. Always exclude `kube-system` (and your own platform namespaces) with `matchExpressions ... NotIn`, and always roll it out under audit mode first.

**A7.3** — **Cilium health checks and inter-node control traffic**, immediately — followed by kubelet-to-pod probes for pods on other nodes, VXLAN/Geneve encapsulated traffic if you are in tunnel mode, and node-to-node WireGuard/IPsec if encryption is on. The first visible symptom is usually `cilium status` reporting node-to-node health failures and liveness probes failing for pods not co-located with the probing kubelet. Because the host firewall applies on every selected node at once, this is a cluster-wide event, not a single-node one.

**A7.4** — Anything originating from the node's host network namespace carries `reserved:host`: **the kubelet** (API server calls, image pulls, probe traffic), `kube-proxy` if present, the container runtime pulling images from a registry, node-level agents (log shippers, monitoring, CSI drivers) running with `hostNetwork: true`, systemd services like `chronyd`/NTP and the DNS resolver, and the `cilium-agent` itself talking to the API server. A host **egress** policy that omits any of these breaks the node's ability to function as a Kubernetes node — most dramatically by cutting the kubelet off from the API server, after which the node goes `NotReady` and the control plane starts evicting its pods. Host egress policy is substantially more dangerous than host ingress policy, which is why Cilium requires it to be opted into explicitly and why almost all production host policies are ingress-only.

**A7.5** — Recovery without console access, in order:
1. The `cilium-agent` pods are on the cluster network and reachable via the API server, which is unaffected if you only firewalled workers. **Delete the offending CCNP through `kubectl`**: `kubectl delete ccnp host-firewall-workers`. The agents recompute the host endpoint's policy within seconds and enforcement drops back to allow-all (assuming `policyEnforcementMode=default` and no other host policy).
2. If `kubectl` still works but you want to keep the policy while you debug, re-enable audit mode on the host endpoint on every node: `kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config <host-ep-id> PolicyAuditMode=Enabled` — note `exec ds/cilium` hits only one pod, so loop over the pods.
3. If the API server itself is now unreachable because you firewalled the control plane too, you are down to node console / cloud-provider serial access, or the cloud provider's own security-group path. **This is why you label and roll out to a single canary node first, and why `nodeSelector` should match one node before it matches all of them.**

The generalisable lesson: a host policy is the one Cilium object that can remove your own remediation path. Always gate it behind audit mode and a canary selector.

**A7.6** — `devices` tells Cilium which **physical/native network interfaces** to attach the host-firewall BPF programs to. Cilium auto-detects devices (and `enableRuntimeDeviceDetection` keeps that current), but auto-detection can pick the wrong set in environments with multiple NICs, bonds, VLAN sub-interfaces, or unconventional naming — so it is often pinned explicitly for determinism.
**Consequence of getting it wrong:** if a device carrying node traffic is *omitted*, the host firewall simply does not see that traffic — the policy appears to be applied, `cilium-dbg endpoint list` shows enforcement enabled, and yet traffic arriving on the unlisted NIC is completely unfiltered. That is a **silent security hole**, the worst failure mode of the two. Conversely, listing a device that carries traffic you did not intend to filter produces unexpected drops. Verify with `cilium-dbg status --verbose | grep -A5 Devices` and confirm every NIC that can receive node traffic is listed.

---

### Block 8

**A8.1** — **Not a bug — it is the documented threat model.** Cilium's transparent encryption protects traffic **on the wire between nodes**. Intra-node pod-to-pod traffic never leaves the kernel: it is forwarded between veth pairs by eBPF without touching a physical interface, so there is no wire on which to eavesdrop. An attacker who can read that traffic already has kernel-level access on the node, at which point encryption between two processes on that same node protects nothing — they can read the plaintext at either endpoint. If your threat model *does* include a compromised node reading its co-tenants' traffic, network encryption is the wrong tool; you need node isolation (dedicated node pools, taints) or application-level TLS.

**A8.2** —
| Axis | WireGuard | IPsec |
|---|---|---|
| **Key rotation** | Automatic. Each node generates a keypair at agent start and publishes the public key on its `CiliumNode` object; peers pick it up. Rotation happens implicitly on agent restart, with no operator action and no shared secret to manage. | Manual. A pre-shared key lives in the `cilium-ipsec-keys` Secret with an explicit key ID; rotation is an operator procedure — bump the key ID, update the Secret, and let the agents converge through a window where both keys are accepted. Getting it wrong drops traffic. |
| **Kernel requirements** | Needs WireGuard support — in-tree from Linux 5.6, or the `wireguard` module. Cilium falls back to a userspace implementation only in limited cases; in practice you want ≥5.6. | Uses the kernel XFRM stack, present in essentially every kernel, but with more historical quirks (MTU handling, XFRM state explosion, interactions with certain NIC offloads). Broader kernel compatibility, more edge cases. |
| **FIPS / compliance** | ChaCha20-Poly1305 and Curve25519 — **not FIPS 140-2/3 approved**. If your auditor requires FIPS-validated cryptography, WireGuard is disqualified regardless of its technical merits. | AES-GCM via the kernel crypto API, which can be run in FIPS mode on a FIPS-validated kernel. **This is the reason IPsec still exists in Cilium** despite WireGuard being simpler to operate. |

Practical guidance: choose WireGuard unless a compliance requirement forces IPsec. The operational cost of manual key rotation is the dominant real-world difference.

**A8.3** — By design, because the authentication handshake is **out-of-band and asynchronous relative to the data path**. When the first packet of a flow hits the policy map and finds `AUTH TYPE: spire` with no valid entry in the auth cache, the datapath cannot block waiting for a mutual-TLS handshake — eBPF programs cannot sleep, and holding the packet would require unbounded state. So it drops the packet, emits `Authentication required`, and signals the agent to perform the handshake. Once the agents on both ends complete it (typically tens to low hundreds of milliseconds) the result is written to the auth cache (`cilium-dbg bpf auth list`) and subsequent packets are forwarded.
**What the application must tolerate:** the first connection attempt to a newly-authenticated peer fails at the TCP layer and must be retried. TCP's own SYN retransmission usually absorbs this transparently (the retry lands after the handshake completes), but an application with an aggressive connect timeout, or a health check with no retry, will observe a failure on the first attempt after any auth-cache expiry. Set connect retries accordingly, and be aware that the auth cache has a TTL — this is not strictly a once-per-pod-lifetime cost.

**A8.4** — The SPIFFE ID encodes the **Cilium security identity number**, so mutual authentication proves: *the peer is an endpoint that the Cilium control plane assigned this identity to, and it holds an X.509-SVID issued by the cluster's SPIRE server attesting that.* In other words, it cryptographically binds the label-derived identity that policy is written against to a certificate the peer must present — closing the gap where an attacker who can spoof an IP, or occupy a recycled pod IP, could otherwise be treated as the trusted identity.
**What it does not prove:** anything about the specific *pod*, *ServiceAccount*, or *process*. All replicas of a Deployment share identity `4711` and therefore share one SVID — mutual auth cannot distinguish replica A from replica B, and cannot tell you *which* process inside the pod opened the connection. It also does not authenticate the *user* or request on whose behalf the call is made; that remains an application-layer concern. And it is not end-to-end: the SVIDs are terminated by the Cilium agents, not by the workloads, so the guarantee is agent-to-agent about endpoint identity, not process-to-process.

**A8.5** — **No, `authentication.mode: required` does not encrypt anything.** The mutual-auth handshake establishes identity; the resulting flag in the policy map gates forwarding. The payload's confidentiality comes entirely from the separate transparent-encryption feature (WireGuard/IPsec).
**The correct mental model:** they are orthogonal halves of what a service mesh's mTLS gives you, and Cilium deliberately separates them because they are enforced in different places at different costs.
* *Encryption (WireGuard/IPsec)* answers **"can anyone on the wire read this?"** — node-to-node confidentiality and integrity.
* *Mutual authentication (SPIRE)* answers **"is the peer really the identity my policy names?"** — cryptographic identity verification, per policy rule.

You want both for a zero-trust posture: encryption without authentication protects the wire but still trusts identity assertions derived from labels and IPs; authentication without encryption verifies the peer but sends the payload in the clear. Enable WireGuard cluster-wide as a baseline, and add `authentication: required` selectively to the rules protecting your highest-value services, since it carries a per-flow handshake cost.

**A8.6** — `encryption.nodeEncryption=true` extends encryption to traffic originating from or destined to the **node's host network namespace** — i.e. `reserved:host` traffic: `hostNetwork: true` pods, kubelet traffic, node-level agents, and health checks between nodes. Without it, only pod-to-pod (endpoint-to-endpoint) traffic is encrypted, and host-sourced traffic crosses the wire in the clear.
**Why it is off by default:** it is substantially easier to break. Host traffic includes the paths the cluster depends on to recover from a misconfiguration — kubelet-to-API-server, the Cilium agents' own control connections, SSH, and node health checks. If encryption is misconfigured or a node's key is stale, enabling node encryption can partition the node from the control plane in a way that is not recoverable through `kubectl`. It also interacts badly with some cloud load balancers and with any middlebox that expects to see the node's traffic. It is a deliberate opt-in with a "verify on a canary node first" posture, the same as the host firewall.

---

### Block 9

**A9.1** — Tests are skipped when the feature they exercise is not enabled, rather than failed, so that the suite is usable on any configuration. Two examples: **`hostFirewall.enabled`** (the host-policy tests are skipped when it is off) and **`encryption.enabled`** (the pod-to-pod-encryption tests are skipped without it). Others include ClusterMesh tests without a mesh, egress-gateway tests without `egressGateway.enabled`, and the `--include-unsafe-tests` set which is skipped by default because those tests disrupt cluster traffic.
**Why "all tests passed" is weaker than it sounds:** the suite validates the features you turned *on*. A cluster with encryption disabled reports a clean run while transmitting every packet in cleartext. Always read the skip count and the skip reasons — a rising number of skips after a Helm upgrade is a strong signal that a flag was dropped from your values file. `cilium connectivity test` is a regression test for the datapath, not an audit of your security posture.

**A9.2** — **The `CiliumNetworkPolicy` and the `NetworkPolicy` are combined, not ranked — Cilium takes the union of all allow rules from both.** There is no "winner": Cilium translates Kubernetes `NetworkPolicy` objects into its own internal rule representation and evaluates them alongside CNPs. A flow is allowed if *any* rule from *either* source allows it. Both equally trigger default-deny on the directions they select.
**When the answer changes:** (1) if `enableK8sNetworkPolicy=false`, Kubernetes `NetworkPolicy` objects are ignored entirely and only CNPs/CCNPs are enforced — a dangerous configuration if application teams are still writing `NetworkPolicy`, because their objects apply cleanly to the API server and do nothing. (2) **Deny rules break the union**: a CNP with `ingressDeny`/`egressDeny` overrides every allow from both sources, since deny has absolute precedence and Kubernetes `NetworkPolicy` has no deny concept to compete with it.

**A9.3** — **Two things only the CRD can express** (there are many; the strongest are):
* **L7 rules** — HTTP method/path/header, DNS `matchPattern`, and Kafka. Kubernetes `NetworkPolicy` stops at L4.
* **`toFQDNs`** — egress by DNS name. Also uniquely CRD-only: `egressDeny`/`ingressDeny` (deny semantics), `toEntities` (`world`, `host`, `remote-node`, `kube-apiserver`, …), cluster-wide scope with `CiliumClusterwideNetworkPolicy`, `nodeSelector` for the host firewall, and `authentication: mode: required`.

**What you lose:** **portability**. A `NetworkPolicy` is a core Kubernetes API that every conformant CNI enforces; a `CiliumNetworkPolicy` binds the workload's security posture to Cilium. Migrating CNIs, running a multi-CNI estate, or handing a Helm chart to a customer whose cluster runs Calico all become harder. The secondary loss is **tooling and audit surface**: policy linters, admission controllers, CI checks and compliance scanners overwhelmingly understand `NetworkPolicy` and may not parse the CRD. The pragmatic pattern is to express as much as possible in portable `NetworkPolicy` and reach for the CRD only where you genuinely need L7, FQDN, deny, or host scope.

**A9.4** — `kubectl get cnp` returns only the **desired** state — the objects you wrote. `cilium sysdump` captures the **realised** state, per node, which is where policy bugs actually live:
* `cilium-dbg policy get` output per agent — the fully-resolved rule set after selector expansion and merging of CNP + CCNP + Kubernetes `NetworkPolicy`, including rules from namespaces you did not think were involved.
* `cilium-dbg bpf policy get` per endpoint — the **compiled eBPF policy map**, with per-rule byte and packet counters. A rule with zero packets after hours of traffic is either dead or shadowed.
* `cilium-dbg endpoint list` / `endpoint get` — per-endpoint enforcement state, `PolicyAuditMode`, and the endpoint's realised identity and labels (which may differ from the pod spec if labels changed).
* `cilium-dbg identity list` and the CIDR/FQDN caches — the local-scope identity mappings needed to interpret any flow record, which cannot be reconstructed after the fact.
* Agent logs containing **policy regeneration errors** — a CNP that the API server accepted but the agent failed to translate or install is only visible here; the CRD's status may not reflect it.
* Hubble flow buffers, and `cilium status --verbose` per node.

The reason to collect it *before* remediation is that all of the above is ephemeral in-memory agent state. Deleting the offending policy to restore service destroys the evidence — the counters reset, the identities are released, and the regeneration errors scroll out of the log. Sysdump first, then fix.

</details>

---

## Sources

* Cilium Network Policy reference — <https://docs.cilium.io/en/stable/security/policy/>
* Identity-based security and the label model — <https://docs.cilium.io/en/stable/overview/component-overview/> and <https://docs.cilium.io/en/stable/internals/security-identities/>
* Layer 7 (HTTP/DNS/Kafka) policy — <https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples>
* DNS-based egress (`toFQDNs`) — <https://docs.cilium.io/en/stable/security/policy/language/#dns-based>
* Deny policies and precedence — <https://docs.cilium.io/en/stable/security/policy/language/#deny-policies>
* Host firewall — <https://docs.cilium.io/en/stable/security/host-firewall/>
* Transparent encryption (WireGuard / IPsec) — <https://docs.cilium.io/en/stable/security/network/encryption/>
* Mutual authentication — <https://docs.cilium.io/en/stable/security/network/encryption-wireguard/> and <https://docs.cilium.io/en/stable/security/network/mutual-authentication/>
* Policy troubleshooting and audit mode — <https://docs.cilium.io/en/stable/security/policy-creation/> and <https://docs.cilium.io/en/stable/operations/troubleshooting/>
* Hubble observability — <https://docs.cilium.io/en/stable/observability/hubble/>
* CCA curriculum — <https://github.com/cncf/curriculum/blob/master/cca/README.md>