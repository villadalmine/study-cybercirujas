# Guided Exercises — 5.3 Auditing Traffic with Logs

**Exam weight:** 5% · **Estimated time:** 2.5–3 hours · **Level:** production / advanced

These exercises cover the four log layers you use to audit network traffic in Kubernetes. Each layer answers a different question, and none of them can answer the others' questions:

| Layer | Question it answers | Source used here |
|---|---|---|
| Kubernetes API audit log | *Who changed the network configuration, when, and with what content?* | `kube-apiserver` audit backend |
| L3/L4 flow logs | *Which packets were forwarded, dropped or audited, and by which policy?* | Cilium Hubble |
| L7 proxy access logs | *What happened to each HTTP request at the data-plane proxy?* | Envoy Gateway (Envoy access log), Hubble L7 |
| DNS query logs | *What did workloads try to resolve, and what answer did they get?* | CoreDNS `log` plugin |

The last exercise is an incident that you can only solve by correlating all four layers.

---

## Prerequisites

Install these tools on your workstation:

- `docker` (or `podman` with kind support)
- `kind` ≥ v0.24
- `kubectl` ≥ v1.30
- `helm` ≥ v3.14
- `cilium` CLI and `hubble` CLI (https://docs.cilium.io/en/stable/observability/hubble/setup/)
- `jq`

Work from an empty directory:

```bash
mkdir -p ~/ckne-5.3 && cd ~/ckne-5.3
```

---

## Exercise 0 — Build the lab cluster

The goal is a three-node kind cluster with API auditing enabled at bootstrap, no default CNI, and Cilium with Hubble installed on top.

### 0.1 Write the audit policy

The API server reads its audit policy **once, at startup**. It therefore has to exist on the control-plane node before the cluster is created.

```bash
cat > audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Drop high-volume, low-value noise first.
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/readyz*"
      - "/livez*"
      - "/version"

  # 2. Sensitive objects: record access (including reads) but never the payload.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # 3. Network configuration changes: record the full request and response bodies.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]
      - group: "cilium.io"
        resources: ["ciliumnetworkpolicies", "ciliumclusterwidenetworkpolicies"]
      - group: "gateway.networking.k8s.io"
        resources: ["gateways", "httproutes", "grpcroutes", "gatewayclasses"]
      - group: ""
        resources: ["services"]

  # 4. Reads of everything else are noise for a network audit.
  - level: None
    verbs: ["get", "list", "watch"]

  # 5. Catch-all: every other write, metadata only.
  - level: Metadata
EOF
```

**Questions 0.1**

- a) Audit policy rules are evaluated top-down and the **first match wins**. Suppose rule 4 (`None` for `get/list/watch`) were moved to the top of the list. What auditing capability would you lose, and why would that matter in a security review?
- b) Why is `secrets` logged at `Metadata` and not at `RequestResponse`?
- c) What does `omitStages: ["RequestReceived"]` remove, and why is that normally safe?

### 0.2 Create the cluster

```bash
cat > kind-ckne.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ckne
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/kube-apiserver-audit.log
            audit-log-maxsize: "100"
            audit-log-maxbackup: "3"
            audit-log-maxage: "7"
          extraVolumes:
            - name: audit-policies
              hostPath: /etc/kubernetes/policies
              mountPath: /etc/kubernetes/policies
              readOnly: true
              pathType: DirectoryOrCreate
            - name: audit-logs
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: ${PWD}/audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
  - role: worker
  - role: worker
EOF

kind create cluster --config kind-ckne.yaml
```

> **kubeadm v1beta4 note.** Starting with kubeadm config API `v1beta4`, `extraArgs` is a **list** of `name`/`value` pairs, not a map. If `kind create cluster` fails with a decode error on `extraArgs`, rewrite that section like this:
>
> ```yaml
> apiServer:
>   extraArgs:
>     - name: audit-policy-file
>       value: /etc/kubernetes/policies/audit-policy.yaml
>     - name: audit-log-path
>       value: /var/log/kubernetes/kube-apiserver-audit.log
> ```

Check the nodes:

```bash
kubectl get nodes
```

Expected output:

```
NAME                 STATUS     ROLES           AGE   VERSION
ckne-control-plane   NotReady   control-plane   60s   v1.3x.x
ckne-worker          NotReady   <none>          40s   v1.3x.x
ckne-worker2         NotReady   <none>          40s   v1.3x.x
```

Confirm that the API server is running with the audit flags:

```bash
docker exec ckne-control-plane grep audit /etc/kubernetes/manifests/kube-apiserver.yaml
docker exec ckne-control-plane ls -l /var/log/kubernetes/
```

### 0.3 Install Cilium and Hubble

```bash
cilium install            # pin with --version <x.y.z> for reproducibility
cilium status --wait
cilium hubble enable
cilium status --wait
```

In a separate terminal, which you leave running for the rest of the lab:

```bash
cilium hubble port-forward
```

Back in the main terminal:

```bash
hubble status
```

Expected output (the numbers will differ):

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,285/12,285 (100.00%)
Flows/s: 41.87
Connected Nodes: 3/3
```

### 0.4 Deploy the test workloads

```bash
kubectl create namespace audit-lab
kubectl -n audit-lab create deployment server --image=nginx:1.27 --replicas=2
kubectl -n audit-lab expose deployment server --port=80
kubectl -n audit-lab run client --image=nicolaka/netshoot --labels=app=client -- sleep infinity
kubectl -n audit-lab run intruder --image=nicolaka/netshoot --labels=app=intruder -- sleep infinity
kubectl -n audit-lab wait --for=condition=Ready pod --all --timeout=180s
kubectl -n audit-lab exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server
```

Expected output: `200`

**Questions 0.2–0.4**

- d) Why must the nodes be `NotReady` right after `kind create cluster` in this configuration?
- e) `hubble status` shows `Current/Max Flows: 12,285/12,285`. What does the "Max" value represent, and what does it imply about using `hubble observe` as an audit record?
- f) Why is the audit log directory mounted with `hostPath` instead of being written inside the container filesystem of the `kube-apiserver` static pod?

---

## Exercise 1 — Kubernetes API audit log: who changed the network?

### 1.1 Generate auditable events

```bash
cat > np-allow-client.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-server
  namespace: audit-lab
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 80
EOF

kubectl apply -f np-allow-client.yaml
kubectl -n audit-lab get networkpolicy allow-client-to-server -o yaml > /dev/null   # a read
kubectl -n audit-lab annotate networkpolicy allow-client-to-server owner=netops
kubectl -n audit-lab delete networkpolicy allow-client-to-server
```

### 1.2 Query the audit log

The audit log is JSON Lines: one event per line.

```bash
docker exec ckne-control-plane cat /var/log/kubernetes/kube-apiserver-audit.log \
  | jq -c 'select(.objectRef.resource=="networkpolicies")
           | {ts: .stageTimestamp, stage, level, verb,
              user: .user.username, ns: .objectRef.namespace,
              name: .objectRef.name, code: .responseStatus.code}'
```

Expected output (abridged):

```
{"ts":"2026-09-30T10:02:11.482913Z","stage":"ResponseComplete","level":"RequestResponse","verb":"create","user":"kubernetes-admin","ns":"audit-lab","name":"allow-client-to-server","code":201}
{"ts":"2026-09-30T10:02:14.107551Z","stage":"ResponseComplete","level":"RequestResponse","verb":"patch","user":"kubernetes-admin","ns":"audit-lab","name":"allow-client-to-server","code":200}
{"ts":"2026-09-30T10:02:16.920334Z","stage":"ResponseComplete","level":"RequestResponse","verb":"delete","user":"kubernetes-admin","ns":"audit-lab","name":"allow-client-to-server","code":200}
```

Inspect the full `create` event:

```bash
docker exec ckne-control-plane cat /var/log/kubernetes/kube-apiserver-audit.log \
  | jq 'select(.objectRef.resource=="networkpolicies" and .verb=="create")
        | {auditID, requestURI, sourceIPs, userAgent, annotations,
           requestObject: .requestObject.spec}'
```

Expected output (abridged):

```
{
  "auditID": "5b0f6f2e-8f4c-4d0b-9f55-0c1f0c7e2a11",
  "requestURI": "/apis/networking.k8s.io/v1/namespaces/audit-lab/networkpolicies?fieldManager=kubectl-client-side-apply&fieldValidation=Strict",
  "sourceIPs": ["172.18.0.1"],
  "userAgent": "kubectl/v1.3x.x (linux/amd64) kubernetes/xxxxxxx",
  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": ""
  },
  "requestObject": {
    "podSelector": { "matchLabels": { "app": "server" } },
    "ingress": [ ... ],
    "policyTypes": ["Ingress"]
  }
}
```

**Questions 1.2**

- a) The `get` from step 1.1 does not appear. Which rule in the policy suppressed it?
- b) The `annotate` command appears as verb `patch`, not `update`. What does `requestObject` contain for a `patch` event, and where do you look to see the **resulting** object?
- c) `sourceIPs` shows `172.18.0.1`, not your laptop's LAN IP. Why?
- d) In which field can you see that the request was authorized, and which authorizer made the decision?

### 1.3 Audit a denied request and an impersonated request

Create a user `alice` with the built-in `edit` role in `audit-lab`. Leave `bob` without permissions.

```bash
kubectl -n audit-lab create rolebinding alice-edit --clusterrole=edit --user=alice

kubectl --as=bob -n audit-lab get secrets
# Error from server (Forbidden): secrets is forbidden: User "bob" cannot list resource "secrets" ...

kubectl --as=alice -n audit-lab create configmap alice-was-here --from-literal=k=v
```

Query both events:

```bash
docker exec ckne-control-plane cat /var/log/kubernetes/kube-apiserver-audit.log \
  | jq -c 'select(.impersonatedUser.username=="bob" or .impersonatedUser.username=="alice")
           | {verb, res: .objectRef.resource, level,
              authn: .user.username, as: .impersonatedUser.username,
              code: .responseStatus.code,
              decision: .annotations["authorization.k8s.io/decision"],
              reason: .annotations["authorization.k8s.io/reason"]}'
```

Expected output:

```
{"verb":"list","res":"secrets","level":"Metadata","authn":"kubernetes-admin","as":"bob","code":403,"decision":"forbid","reason":""}
{"verb":"create","res":"configmaps","level":"Metadata","authn":"kubernetes-admin","as":"alice","code":201,"decision":"allow","reason":"RBAC: allowed by RoleBinding \"alice-edit/audit-lab\" of ClusterRole \"edit\" to User \"alice\""}
```

**Questions 1.3**

- e) Bob's `list secrets` was logged even though rule 4 says `None` for `list`. Why?
- f) In an investigation, which field identifies the **real** credential that sent the request, and which identifies the identity whose permissions were used?
- g) You edit `audit-policy.yaml` on the host to add a new rule. Is the change active? What must happen before it is?

---

## Exercise 2 — Hubble flow logs and policy audit mode (a safe rollout of default-deny)

Enforcing a default-deny policy blind is how outages happen. Cilium's **policy audit mode** evaluates policies and reports the verdict, but does not drop anything. You collect evidence first and enforce later.

### 2.1 Baseline flows

```bash
kubectl -n audit-lab exec client   -- curl -s -o /dev/null -w '%{http_code}\n' http://server
kubectl -n audit-lab exec intruder -- curl -s -o /dev/null -w '%{http_code}\n' http://server

hubble observe --namespace audit-lab --protocol tcp --to-port 80 --last 10
```

Expected output (abridged; arrow glyphs and spacing vary by Hubble CLI version):

```
Sep 30 10:10:04.512: audit-lab/client:48122 (ID:21871) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) to-endpoint FORWARDED (TCP Flags: SYN)
Sep 30 10:10:04.513: audit-lab/client:48122 (ID:21871) <- audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Sep 30 10:10:06.901: audit-lab/intruder:39310 (ID:30044) -> audit-lab/server-7b9c7d9d8f-hn4wz:80 (ID:4512) to-endpoint FORWARDED (TCP Flags: SYN)
```

The destination is a **pod**, not the Service `server`. Keep that in mind for question a.

### 2.2 Enable policy audit mode, then apply default-deny + allow

```bash
cilium config set policy-audit-mode true     # restarts the Cilium agents
cilium status --wait
```

```bash
cat > np-default-deny.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: audit-lab
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF

kubectl apply -f np-default-deny.yaml -f np-allow-client.yaml
```

Generate traffic from both pods:

```bash
for i in 1 2 3; do
  kubectl -n audit-lab exec client   -- curl -s -m 3 -o /dev/null -w 'client %{http_code}\n' http://server
  kubectl -n audit-lab exec intruder -- curl -s -m 3 -o /dev/null -w 'intruder %{http_code}\n' http://server
done
```

Expected output: **every** request returns `200`, including the intruder's.

```bash
hubble observe --namespace audit-lab --type policy-verdict --last 20
```

Expected output (abridged):

```
Sep 30 10:14:22.004: audit-lab/client:50112 (ID:21871) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
Sep 30 10:14:23.217: audit-lab/intruder:40022 (ID:30044) -> audit-lab/server-7b9c7d9d8f-hn4wz:80 (ID:4512) policy-verdict:none INGRESS AUDITED (TCP Flags: SYN)
```

Extract a list of the connections that **would** be denied under enforcement:

```bash
hubble observe --namespace audit-lab --verdict AUDIT -o jsonpb --last 200 \
  | jq -r '.flow | [.source.namespace + "/" + (.source.labels | map(select(startswith("k8s:app="))) | first // "?"),
                    .destination.namespace + "/" + .destination.pod_name,
                    (.l4.TCP.destination_port // .l4.UDP.destination_port)] | @tsv' \
  | sort | uniq -c
```

Expected output:

```
      3 audit-lab/k8s:app=intruder	audit-lab/server-7b9c7d9d8f-hn4wz	80
      3 audit-lab/k8s:app=intruder	audit-lab/server-7b9c7d9d8f-k2x5q	80
```

(The counts depend on how kube-proxy spreads the connections across the two backends.)

**Questions 2.1–2.2**

- a) Hubble shows the destination as a pod, not as the `server` Service. At what point in the datapath was the Service ClusterIP translated, and what does that mean for "who talked to service X" queries?
- b) What is the difference between `policy-verdict:L3-L4 INGRESS ALLOWED` and `policy-verdict:none INGRESS AUDITED`?
- c) Why did you aggregate by the source **label** rather than the source pod name when building the "would be denied" list?
- d) Name one kind of flow that audit mode can show you before enforcement and that you would likely forget when writing the allow-list by hand. (Hint: think about what other namespaces send traffic to your pods.)

### 2.3 Switch to enforcement

```bash
cilium config set policy-audit-mode false
cilium status --wait

kubectl -n audit-lab exec client   -- curl -s -m 3 -o /dev/null -w 'client %{http_code}\n' http://server
kubectl -n audit-lab exec intruder -- curl -s -m 3 -o /dev/null -w 'intruder %{http_code}\n' http://server
```

Expected output:

```
client 200
intruder 000
command terminated with exit code 28
```

```bash
hubble observe --namespace audit-lab --verdict DROPPED --last 10
```

Expected output (abridged):

```
Sep 30 10:20:41.330: audit-lab/intruder:41876 (ID:30044) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 10:20:41.330: audit-lab/intruder:41876 (ID:30044) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) Policy denied DROPPED (TCP Flags: SYN)
Sep 30 10:20:42.345: audit-lab/intruder:41876 (ID:30044) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) Policy denied DROPPED (TCP Flags: SYN)
```

Look at the structured fields of one drop:

```bash
hubble observe --namespace audit-lab --verdict DROPPED -o jsonpb --last 1 \
  | jq '.flow | {verdict, drop_reason_desc, traffic_direction,
                 src: .source.pod_name, src_identity: .source.identity,
                 dst: .destination.pod_name, dst_identity: .destination.identity,
                 node_name, tcp_flags: .l4.TCP.flags}'
```

**Questions 2.3**

- e) The `curl` exit code is 28 (timeout), not "connection refused". What does that tell you about **how** Cilium denies the packet, and why does a client see a timeout instead of a RST?
- f) The same connection appears several times with the `SYN` flag a second or so apart. What are these?
- g) The flow shows `(ID:30044)`. What is that number, and why does Cilium enforce policy on it rather than on the pod IP?

---

## Exercise 3 — L7 flow logs with Hubble

L3/L4 flow logs cannot tell `GET /` from `POST /admin`. Cilium produces L7 flow records when traffic on a port is redirected to its Envoy proxy. One way to trigger that redirect is an L7 rule in a `CiliumNetworkPolicy`.

### 3.1 Replace the L4 allow with an L7 allow

Remove the L4 allow first. Allow rules are additive, so an L4 allow on the same port would allow every HTTP request.

```bash
kubectl -n audit-lab delete networkpolicy allow-client-to-server

cat > cnp-l7.yaml <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: server-l7
  namespace: audit-lab
spec:
  endpointSelector:
    matchLabels:
      app: server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/"
EOF

kubectl apply -f cnp-l7.yaml
```

### 3.2 Generate allowed and denied requests

```bash
kubectl -n audit-lab exec client -- curl -s -o /dev/null -w 'GET /      %{http_code}\n' http://server/
kubectl -n audit-lab exec client -- curl -s -o /dev/null -w 'GET /admin %{http_code}\n' http://server/admin
kubectl -n audit-lab exec client -- curl -s -o /dev/null -w 'POST /     %{http_code}\n' -X POST http://server/
```

Expected output:

```
GET /      200
GET /admin 403
POST /     403
```

```bash
hubble observe --namespace audit-lab --protocol http --last 10
```

Expected output (abridged):

```
Sep 30 10:31:02.114: audit-lab/client:56010 (ID:21871) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) http-request FORWARDED (HTTP/1.1 GET http://server/)
Sep 30 10:31:02.116: audit-lab/client:56010 (ID:21871) <- audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) http-response FORWARDED (HTTP/1.1 200 2ms (GET http://server/))
Sep 30 10:31:04.502: audit-lab/client:56020 (ID:21871) -> audit-lab/server-7b9c7d9d8f-hn4wz:80 (ID:4512) http-request DROPPED (HTTP/1.1 GET http://server/admin)
Sep 30 10:31:06.877: audit-lab/client:56030 (ID:21871) -> audit-lab/server-7b9c7d9d8f-hn4wz:80 (ID:4512) http-request DROPPED (HTTP/1.1 POST http://server/)
```

Structured view:

```bash
hubble observe --namespace audit-lab --protocol http -o jsonpb --last 10 \
  | jq -c '.flow | {verdict, type: .l7.type, method: .l7.http.method,
                    url: .l7.http.url, code: .l7.http.code, latency_ns: .l7.latency_ns}'
```

**Questions 3.2**

- a) The client received a `403`, yet the TCP handshake succeeded. Which component generated the `403`, and how is that different from the L4 drop in Exercise 2?
- b) The `path` field in a Cilium HTTP rule is a regular expression. Would `GET /index.html` be allowed by this policy? Why?
- c) L7 visibility has a cost. Name two operational costs of redirecting a port through the proxy.
- d) If the traffic on port 80 were TLS (HTTPS), what would Hubble be able to show at L7 without extra configuration?

---

## Exercise 4 — Persistent flow logs: the Hubble exporter

`hubble observe` reads a per-node **ring buffer**. Old flows are overwritten, so it is a live debugging tool and not an audit trail. The Hubble exporter writes selected flows to a file on each node, where a log shipper (Fluent Bit, Vector, Promtail/Alloy…) can collect them.

### 4.1 Configure a static exporter for security-relevant verdicts

```bash
cat > hubble-export-values.yaml <<'EOF'
hubble:
  export:
    fileMaxSizeMb: 10
    fileMaxBackups: 5
    static:
      enabled: true
      filePath: /var/run/cilium/hubble/events.log
      allowList:
        - '{"verdict":["DROPPED","ERROR","AUDIT"]}'
      fieldMask:
        - time
        - node_name
        - verdict
        - drop_reason_desc
        - traffic_direction
        - source.namespace
        - source.pod_name
        - source.identity
        - destination.namespace
        - destination.pod_name
        - destination.identity
        - l4
        - l7
EOF

cilium upgrade --reuse-values --values hubble-export-values.yaml
kubectl -n kube-system rollout status ds/cilium --timeout=300s
```

> The exporter options have changed between Cilium releases. If `cilium upgrade` rejects a key, check the "Configuring Hubble exporter" page for your installed version.

### 4.2 Produce drops and read the file on the right node

```bash
for i in 1 2 3; do
  kubectl -n audit-lab exec intruder -- curl -s -m 2 -o /dev/null http://server || true
done

# Which node(s) run the server pods?
kubectl -n audit-lab get pods -l app=server -o wide
```

Read the exporter file from the Cilium agent **on that node**:

```bash
NODE=ckne-worker   # replace with a node that runs a server pod
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=${NODE} -o jsonpath='{.items[0].metadata.name}')

kubectl -n kube-system exec ${CILIUM_POD} -c cilium-agent -- \
  tail -n 3 /var/run/cilium/hubble/events.log | jq -c '.flow | {time, verdict, drop_reason_desc, src: .source.pod_name, dst: .destination.pod_name}'
```

Expected output:

```
{"time":"2026-09-30T10:42:10.118Z","verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","src":"intruder","dst":"server-7b9c7d9d8f-k2x5q"}
{"time":"2026-09-30T10:42:11.130Z","verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","src":"intruder","dst":"server-7b9c7d9d8f-k2x5q"}
{"time":"2026-09-30T10:42:12.401Z","verdict":"DROPPED","drop_reason_desc":"POLICY_DENIED","src":"intruder","dst":"server-7b9c7d9d8f-hn4wz"}
```

**Questions 4.2**

- a) Why did you have to pick the Cilium agent on a **specific** node to find these drops? What does that imply for log collection in production?
- b) What do `allowList` and `fieldMask` each reduce, and why do both matter at scale?
- c) Ingress drops are recorded on the destination's node. On which node would you expect an **egress** policy drop to be recorded?
- d) Cilium also offers a *dynamic* exporter. What operational problem does it solve compared with the static one?

---

## Exercise 5 — Gateway access logs with Envoy Gateway

A Gateway API data plane is an L7 proxy. Its access log is the authoritative record of every north-south request: what came in, which route matched, which upstream was chosen, and **why** it failed.

### 5.1 Reset the namespace policies and install Envoy Gateway

```bash
kubectl -n audit-lab delete networkpolicy --all
kubectl -n audit-lab delete ciliumnetworkpolicy --all

EG_VERSION=v1.5.0     # use a current release: https://gateway.envoyproxy.io/news/releases/
helm install eg oci://docker.io/envoyproxy/gateway-helm --version ${EG_VERSION} \
  -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system wait --timeout=5m deployment/envoy-gateway --for=condition=Available
```

The chart also installs the Gateway API CRDs.

### 5.2 Define a structured access log and attach it to a GatewayClass

```bash
cat > eg-telemetry.yaml <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: audit-proxy
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
              upstream_failure: "%UPSTREAM_TRANSPORT_FAILURE_REASON%"
              duration_ms: "%DURATION%"
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              route_name: "%ROUTE_NAME%"
              downstream_remote: "%DOWNSTREAM_REMOTE_ADDRESS%"
              x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              request_id: "%REQ(X-REQUEST-ID)%"
              user_agent: "%REQ(USER-AGENT)%"
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
    name: audit-proxy
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: audit-lab
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: server
  namespace: audit-lab
spec:
  parentRefs:
    - name: eg
  hostnames:
    - "www.audit.lab"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: server
          port: 80
EOF

kubectl apply -f eg-telemetry.yaml
kubectl -n audit-lab wait gateway/eg --for=condition=Programmed --timeout=180s
```

Locate the generated Envoy Service and Deployment, then port-forward:

```bash
ENVOY_SVC=$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-namespace=audit-lab,gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')
ENVOY_DEPLOY=$(kubectl -n envoy-gateway-system get deploy \
  -l gateway.envoyproxy.io/owning-gateway-namespace=audit-lab,gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n envoy-gateway-system port-forward svc/${ENVOY_SVC} 8888:80 >/dev/null 2>&1 &
sleep 2
```

### 5.3 Generate three failure classes and read the log

```bash
# A: matched route, healthy backend
curl -s -o /dev/null -w 'A %{http_code}\n' -H 'Host: www.audit.lab' http://localhost:8888/

# B: unknown host, no route matches
curl -s -o /dev/null -w 'B %{http_code}\n' -H 'Host: nope.audit.lab' http://localhost:8888/

# C: route matches, backend has no endpoints
kubectl -n audit-lab scale deployment server --replicas=0
sleep 5
curl -s -o /dev/null -w 'C %{http_code}\n' -H 'Host: www.audit.lab' http://localhost:8888/
kubectl -n audit-lab scale deployment server --replicas=2
kubectl -n audit-lab rollout status deployment server
```

Expected output:

```
A 200
B 404
C 503
```

```bash
kubectl -n envoy-gateway-system logs deploy/${ENVOY_DEPLOY} -c envoy --tail=50 \
  | grep '^{' \
  | jq -c '{authority, path, response_code, response_flags, response_code_details, upstream_host, route_name, downstream_remote}'
```

Expected output (abridged):

```
{"authority":"www.audit.lab","path":"/","response_code":200,"response_flags":"-","response_code_details":"via_upstream","upstream_host":"10.244.1.23:80","route_name":"httproute/audit-lab/server/rule/0/match/0/www_audit_lab","downstream_remote":"127.0.0.1:49122"}
{"authority":"nope.audit.lab","path":"/","response_code":404,"response_flags":"NR","response_code_details":"route_not_found","upstream_host":null,"route_name":null,"downstream_remote":"127.0.0.1:49130"}
{"authority":"www.audit.lab","path":"/","response_code":503,"response_flags":"UH","response_code_details":"no_healthy_upstream","upstream_host":null,"route_name":"httproute/audit-lab/server/rule/0/match/0/www_audit_lab","downstream_remote":"127.0.0.1:49140"}
```

(The exact `route_name` string depends on the Envoy Gateway version.)

**Questions 5.3**

- a) Decode `NR` and `UH`. For each one, name the Kubernetes object you would inspect first.
- b) `upstream_host` shows a pod IP and port, not the `server` ClusterIP. How does Envoy Gateway obtain upstream addresses, and what does that imply for kube-proxy and for NetworkPolicy?
- c) `downstream_remote` is `127.0.0.1`. Why? In a real deployment behind a cloud load balancer, which setting or field would you use to recover the true client IP?
- d) Why is `%REQ(X-REQUEST-ID)%` the most valuable field when correlating the gateway log with application logs?
- e) Why is `"%START_TIME%"` quoted in the manifest? What would a YAML parser do with an unquoted value that starts with `%`?

---

## Exercise 6 — DNS query logs with CoreDNS

A surprising share of "network" incidents are DNS incidents. By default CoreDNS logs only errors. The `log` plugin records every query and its response code.

### 6.1 Enable query logging

Look at the current configuration first:

```bash
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

Apply the same Corefile with `log` added. The block below matches the kind/kubeadm default; if yours differs, add only the `log` line.

```bash
cat > coredns-cm.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        log
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
EOF

kubectl apply -f coredns-cm.yaml
```

The `reload` plugin detects the change within about 30–45 seconds. Wait for it:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns -f --tail=5 | grep -m1 -i reload
```

Expected output:

```
[INFO] Reloading
[INFO] plugin/reload: Running configuration SHA512 = 8a1c...
[INFO] Reloading complete
```

### 6.2 Observe search-path expansion

```bash
kubectl -n audit-lab exec client -- cat /etc/resolv.conf
kubectl -n audit-lab exec client -- nslookup kubernetes.io > /dev/null
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=40 --prefix=false | grep kubernetes.io
```

Expected output (abridged):

```
[INFO] 10.244.2.17:45012 - 33107 "A IN kubernetes.io.audit-lab.svc.cluster.local. udp 59 false 512" NXDOMAIN qr,aa,rd 152 0.000191s
[INFO] 10.244.2.17:45012 - 33108 "A IN kubernetes.io.svc.cluster.local. udp 49 false 512" NXDOMAIN qr,aa,rd 142 0.000102s
[INFO] 10.244.2.17:45012 - 33109 "A IN kubernetes.io.cluster.local. udp 45 false 512" NXDOMAIN qr,aa,rd 138 0.000097s
[INFO] 10.244.2.17:45012 - 33110 "A IN kubernetes.io. udp 31 false 512" NOERROR qr,rd,ra 60 0.012304s
```

The default log line format is:

```
{remote}:{port} - {>id} "{type} {class} {name} {proto} {size} {>do} {>bufsize}" {rcode} {>rflags} {rsize} {duration}
```

Now query the FQDN with a trailing dot:

```bash
kubectl -n audit-lab exec client -- nslookup kubernetes.io. > /dev/null
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=5 --prefix=false | grep kubernetes.io
```

**Questions 6.2**

- a) Why did one lookup of `kubernetes.io` produce three `NXDOMAIN` answers before the `NOERROR`? Which `resolv.conf` option drives this?
- b) What changed with the trailing dot, and why?
- c) The `rflags` show `aa` on the `NXDOMAIN` answers but not on the final answer. What does `aa` mean, and why does it differ?
- d) The CoreDNS log shows the **pod IP** of the client. With what other log source would you join it to get a pod name, and why is that join time-sensitive?

### 6.3 Reduce volume: log only denials and errors

Full query logging on a busy cluster produces a very large number of lines. Restrict it to the classes that matter for auditing:

```bash
sed -i 's/^        log$/        log . {\n            class denial error\n        }/' coredns-cm.yaml
grep -A3 'log \.' coredns-cm.yaml
kubectl apply -f coredns-cm.yaml
```

After the reload, run:

```bash
kubectl -n audit-lab exec client -- nslookup server.audit-lab.svc.cluster.local > /dev/null
kubectl -n audit-lab exec client -- nslookup does-not-exist.audit-lab.svc.cluster.local > /dev/null || true
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=10 --prefix=false | grep audit-lab
```

**Questions 6.3**

- e) Which of the two lookups appears, and why?
- f) What is the difference between the `denial` and `error` classes?

---

## Exercise 7 — Incident: correlate all four layers

**Scenario.** At an unknown time, somebody "hardened" `audit-lab`. Since then, `http://www.audit.lab` through the gateway returns errors after a long delay, while `client` → `server` still works. You must determine **what** broke, **where**, **who** did it, and **fix** it without undoing the hardening.

### 7.1 Inject the fault (in the scenario, this is someone else's action)

```bash
cat > np-lockdown.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: lockdown
  namespace: audit-lab
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 80
EOF

kubectl --as=alice apply -f np-lockdown.yaml
```

From here on, work as the investigator.

### 7.2 Symptom

```bash
time curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: www.audit.lab' http://localhost:8888/
kubectl -n audit-lab exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://server
```

Expected output:

```
503
real    0m10.0xxs
200
```

### 7.3 Layer 1 — Gateway access log

```bash
kubectl -n envoy-gateway-system logs deploy/${ENVOY_DEPLOY} -c envoy --tail=20 \
  | grep '^{' | jq -c 'select(.response_code==503)
      | {start_time, response_flags, response_code_details, upstream_failure, upstream_host, duration_ms, request_id}'
```

Expected output (abridged):

```
{"start_time":"2026-09-30T11:05:12.004Z","response_flags":"UF","response_code_details":"upstream_reset_before_response_started{connection_timeout}","upstream_failure":null,"upstream_host":"10.244.1.23:80","duration_ms":10001,"request_id":"3f0c1c8e-..."}
```

- **Question a:** What do `UF`, `connection_timeout` and `duration_ms ≈ 10000` together tell you, and how does that differ from the `UH` you saw in Exercise 5?

### 7.4 Layer 2 — Hubble

Take the `upstream_host` IP from the access log and search for drops to it:

```bash
UPSTREAM_IP=10.244.1.23      # from the access log
hubble observe --verdict DROPPED --to-ip ${UPSTREAM_IP} --last 20
hubble observe --from-namespace envoy-gateway-system --to-namespace audit-lab --verdict DROPPED -o jsonpb --last 5 \
  | jq -c '.flow | {time, src: .source.pod_name, src_labels: .source.labels, dst: .destination.pod_name, drop_reason_desc, traffic_direction}'
```

Expected output (abridged):

```
Sep 30 11:05:12.006: envoy-gateway-system/envoy-audit-lab-eg-xxxxxxxx-5d8c9b7f6-q7j2m:37214 (ID:18233) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep 30 11:05:12.006: envoy-gateway-system/envoy-audit-lab-eg-xxxxxxxx-5d8c9b7f6-q7j2m:37214 (ID:18233) -> audit-lab/server-7b9c7d9d8f-k2x5q:80 (ID:4512) Policy denied DROPPED (TCP Flags: SYN)
```

- **Question b:** Hubble proves *that* the packet was dropped by policy on ingress to `server`. Which **policy** caused it? Can you tell that from the flow alone? Which command lists the policies that select the server pods?

```bash
kubectl -n audit-lab get networkpolicy,ciliumnetworkpolicy
```

### 7.5 Layer 3 — API audit log: who, when, from where

```bash
docker exec ckne-control-plane cat /var/log/kubernetes/kube-apiserver-audit.log \
  | jq 'select(.objectRef.resource=="networkpolicies" and .objectRef.name=="lockdown")
        | {stageTimestamp, verb, authn: .user.username, as: .impersonatedUser.username,
           userAgent, sourceIPs, code: .responseStatus.code,
           reason: .annotations["authorization.k8s.io/reason"],
           ingress: .requestObject.spec.ingress}'
```

Expected output (abridged):

```
{
  "stageTimestamp": "2026-09-30T11:03:47.551230Z",
  "verb": "create",
  "authn": "kubernetes-admin",
  "as": "alice",
  "userAgent": "kubectl/v1.3x.x (linux/amd64) kubernetes/xxxxxxx",
  "sourceIPs": ["172.18.0.1"],
  "code": 201,
  "reason": "RBAC: allowed by RoleBinding \"alice-edit/audit-lab\" of ClusterRole \"edit\" to User \"alice\"",
  "ingress": [ { "from": [ { "podSelector": { "matchLabels": { "app": "client" } } } ], "ports": [ ... ] } ]
}
```

- **Question c:** Compare `stageTimestamp` with the first `UF` in the gateway log. Why does that comparison matter before you conclude causation?
- **Question d:** Should DNS (CoreDNS logs) be part of this investigation? Justify it using what you learned in Exercise 5 about how Envoy Gateway resolves upstreams.

### 7.6 Fix without undoing the hardening

Add an explicit, narrowly scoped allow for the gateway's data plane:

```bash
cat > np-allow-gateway.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-to-server
  namespace: audit-lab
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: envoy-gateway-system
          podSelector:
            matchLabels:
              gateway.envoyproxy.io/owning-gateway-name: eg
              gateway.envoyproxy.io/owning-gateway-namespace: audit-lab
      ports:
        - protocol: TCP
          port: 80
EOF

kubectl apply -f np-allow-gateway.yaml
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: www.audit.lab' http://localhost:8888/
kubectl -n audit-lab exec intruder -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://server || true
hubble observe --from-namespace envoy-gateway-system --to-namespace audit-lab --last 3
```

Expected output: `200` through the gateway, `000` (timeout) from the intruder, and `FORWARDED` flows from the Envoy pod.

- **Question e:** In `np-allow-gateway.yaml`, `namespaceSelector` and `podSelector` are in the **same** list item (no `-` before `podSelector`). What would change if you put a `-` before `podSelector`, and why would that be a security regression?
- **Question f:** Write the one-line incident summary you would put in the postmortem, citing one piece of evidence from each layer.

---

## Cleanup

```bash
kill %1 2>/dev/null || true         # the gateway port-forward
kind delete cluster --name ckne
```

---

## Answers

<details>
<summary>Exercise 0</summary>

**a)** Every `get`, `list` and `watch` would match that rule first and be dropped, including reads of `secrets` and `configmaps`. You would lose the record of who **read** credentials. Secret exfiltration through a read (`kubectl get secret -o yaml`) is one of the most important events in a security review, and it would leave no trace at all.

**b)** `RequestResponse` would copy the secret's data into the audit log. Secret values are only base64-encoded, not encrypted. The audit log would become a second, less protected secret store, usually shipped to a SIEM with broader access. `Metadata` records who, what, when and the result, without the payload.

**c)** It removes the event emitted as soon as the request is received, before authorization and before a response exists. Every request that completes also produces a `ResponseComplete` (or `Panic`) event with the same `auditID` and more information, so dropping `RequestReceived` roughly halves the volume. Long-running requests (`watch`, `exec`) also emit `ResponseStarted`, which is not omitted here.

**d)** `disableDefaultCNI: true` means no network plugin is installed. The kubelet reports `NetworkReady=false` until a CNI configuration exists, so the nodes stay `NotReady` (and CoreDNS stays `Pending`) until Cilium is installed.

**e)** It is the total ring-buffer capacity across the connected nodes (by default 4095 flows per node, here 3 × 4095). When the buffer is full, the oldest flows are overwritten. `hubble observe` therefore only sees a sliding window, which may be seconds long on a busy node. It is a debugging tool, not an audit record. Persistence requires the exporter (Exercise 4) or an external collector.

**f)** Static pod containers are recreated whenever the kubelet restarts them, and anything written inside the container filesystem is lost. A `hostPath` mount writes the log to the node itself, where it survives restarts and a node-level log shipper can collect it.

</details>

<details>
<summary>Exercise 1</summary>

**a)** Rule 4: `level: None` for `verbs: ["get", "list", "watch"]`. Rule 3 only matches write verbs, so the `get` on a NetworkPolicy fell through to rule 4.

**b)** For a `patch`, `requestObject` is the **patch body** (a strategic-merge or JSON-merge patch, here the annotation delta), not the full object. The resulting object is in `responseObject`, which is present because the level is `RequestResponse`. To reconstruct "before vs. after" you need the previous event's `responseObject` or the object's history in your change management.

**c)** kind nodes run on a Docker bridge network. `kubectl` on the host reaches the API server through the published port, and the source address the API server sees is the bridge gateway (`172.18.0.1`). The same thing happens in production behind load balancers or NAT. `sourceIPs` also includes addresses from `X-Forwarded-For` when the proxies set it, but it is only as trustworthy as those proxies.

**d)** In the `annotations` map: `authorization.k8s.io/decision` (`allow` or `forbid`) and `authorization.k8s.io/reason`. For `kubernetes-admin` the reason is usually empty because the user is a member of a group bound to `cluster-admin`. For RBAC grants through a specific binding, the reason names the RoleBinding or ClusterRoleBinding and the role, as you see with Alice in 1.3.

**e)** Rule 2 (`Metadata` for `secrets` and `configmaps`, with no verb restriction) comes **before** rule 4, and the first match wins. The forbidden `list` is still recorded, with `code: 403` and `decision: forbid`. Failed access attempts to secrets are exactly what you want to keep.

**f)** `user.username` is the authenticated identity that presented the credential (`kubernetes-admin`). `impersonatedUser.username` is the identity the request acted as (`alice`), and authorization was evaluated against it. Both matter: `user` tells you whose credential to rotate, and `impersonatedUser` tells you which permissions were exercised. Impersonation itself requires the `impersonate` verb, which is an event worth auditing separately.

**g)** No. The API server parses the policy file only at startup. It must be restarted. For a static pod, the kubelet restarts it only when the manifest in `/etc/kubernetes/manifests/` changes, so you either touch or modify the manifest, or stop the container (for example with `crictl stop`) and let the kubelet recreate it. On HA control planes, repeat on each API server and keep the policies identical, or the audit coverage will depend on which replica served the request.

</details>

<details>
<summary>Exercise 2</summary>

**a)** With kube-proxy (iptables/IPVS) in the host network namespace, or with Cilium's socket-level load balancing, the ClusterIP is translated to a backend pod IP at the client node, before Hubble sees the packet on the destination endpoint. Flow logs therefore show pod-to-pod traffic. To answer "who talked to Service X", filter by the destination labels or pod names that back the service (`--to-label app=server`), or use Hubble's service fields when Cilium does the load balancing (`--to-service`). Filtering by the ClusterIP will find nothing.

**b)** `policy-verdict:L3-L4 INGRESS ALLOWED` means a rule matched at L3/L4 (identity + port) and the connection is allowed. `policy-verdict:none INGRESS AUDITED` means **no** rule matched, which under enforcement would be a denial. Because audit mode is on, the packet was forwarded and recorded with verdict `AUDIT`.

**c)** Pod names are ephemeral: a Deployment's pods change names on every rollout, and your allow-list must survive that. Policy is written against labels (which Cilium maps to identities), so the "would be denied" report must be aggregated at the same level of abstraction as the rules you are going to write.

**d)** Common examples are ingress-controller or gateway pods in another namespace, Prometheus scraping from `monitoring`, kubelet health probes from the node (the `host`/`remote-node` entities, depending on configuration), service-mesh or sidecar traffic, and backup or batch jobs. Exercise 7 is exactly this failure: the gateway namespace was forgotten.

**e)** Cilium silently drops the SYN. It does not send a RST or an ICMP unreachable. The client kernel retransmits the SYN until `curl`'s `-m 3` timeout fires (exit 28). A silent drop gives an attacker no information about whether the port exists, but it also turns misconfigurations into slow timeouts instead of fast failures, which lengthens incidents (see the 10-second delay in Exercise 7).

**f)** TCP SYN retransmissions from the client kernel, with exponential backoff (about 1 s, then 2 s, …). Each one is dropped and logged again. Several identical drops with the same source port are one connection attempt, not several attackers.

**g)** It is the Cilium **security identity**, a numeric ID derived from the pod's security-relevant labels (namespace + labels). All pods with the same labels share it. Enforcing on identity means that policy does not need to be recomputed each time a pod's IP changes, which is constant under churn. On the wire, the identity is conveyed through the IP-to-identity cache or tunnel metadata. It also explains the audit trail: a verdict references an identity, and you resolve it with `cilium identity get <id>` (inside the agent) to see which labels it represents.

</details>

<details>
<summary>Exercise 3</summary>

**a)** Cilium's node-local Envoy proxy generated it. Once port 80 on the server has an L7 rule, the connection is redirected to the proxy: the L4 handshake is allowed (the client identity is permitted at L3/L4), and the proxy parses each HTTP request and answers `403 Access denied` for requests that do not match. In Exercise 2, the packet was dropped in the eBPF datapath at L4, with no handshake and no response, so the client saw a timeout.

**b)** No. Cilium matches the `path` regular expression against the **whole** path (it behaves as if anchored), so `/` matches only `/`. To allow everything under the root you would write `path: "/.*"`. Mistakes like this are exactly what the L7 flow log (`http-request DROPPED ... /index.html`) exposes.

**c)** Any two of: added latency per request (a userspace proxy hop); CPU and memory in the Cilium Envoy proxy that scale with request rate; connections are terminated and re-originated, so the server sees a new TCP connection whose source port differs from the client's; protocol support is limited to what the proxy parses; and a much larger volume of flow records (one per request and per response, instead of per connection).

**d)** Only L3/L4 information, and the TLS SNI if you configure DNS/TLS-aware visibility. Method, path and status code are encrypted. L7 visibility into TLS requires terminating TLS (Cilium's TLS interception with a trusted CA, a service mesh with mTLS, or a gateway), each with its own trust and operational implications.

</details>

<details>
<summary>Exercise 4</summary>

**a)** Each Cilium agent observes and exports the flows for the endpoints **on its own node**, and an ingress drop is recorded where the destination pod lives. There is no central file. In production you run a node-level log shipper (DaemonSet) that tails `/var/run/cilium/hubble/*.log` on every node and sends it to central storage, with the node name kept as a field.

**b)** `allowList` (and `denyList`) reduces the **number of flows** written: only the flows that match the filters. `fieldMask` reduces the **size of each record** to the listed fields. At thousands of flows per second per node, both reduce disk I/O, shipper CPU, network egress and SIEM ingestion cost, which is often the dominant cost of flow logging.

**c)** On the **source** pod's node: egress policy is enforced when the packet leaves the source endpoint, before it ever reaches the network.

**d)** Static exporters are defined through the agent configuration, so changing their filters requires updating the configuration and usually restarting agents. The dynamic exporter reads a configuration file (typically mounted from a ConfigMap) that the agent watches. You can then add, change or remove several exporters, each with its own filters and output file, without restarting Cilium.

</details>

<details>
<summary>Exercise 5</summary>

**a)** `NR` = **No Route**: no route matched the request's host/path (`response_code_details: route_not_found`). Inspect the `HTTPRoute` first (`hostnames`, `matches`, `parentRefs`) and its `status.parents[].conditions` (`Accepted`, `ResolvedRefs`). `UH` = **No Healthy Upstream**: the route matched but the cluster had no healthy endpoints. Inspect the backend `Service` and its `EndpointSlices` (`kubectl get endpointslices -l kubernetes.io/service-name=server`), then the pods' readiness.

**b)** The Envoy Gateway controller watches `EndpointSlices` and programs the pod IPs directly into Envoy clusters (EDS). Envoy connects straight to pod IPs, so kube-proxy's ClusterIP translation is not involved in gateway-to-backend traffic. For NetworkPolicy, the traffic arrives at the backend pods from the **Envoy pods' identities** in `envoy-gateway-system`, so the backend's ingress policy must allow those pods. That is the cause of Exercise 7.

**c)** `kubectl port-forward` tunnels the connection through the API server and kubelet, and the kubelet connects to the pod from inside the pod's network namespace (localhost). In production, set `externalTrafficPolicy: Local` on the Envoy Service (to avoid SNAT by kube-proxy), and/or use PROXY protocol or `X-Forwarded-For` from the load balancer. In Envoy Gateway these are configured through `ClientTrafficPolicy` (for example `clientIPDetection` or PROXY protocol settings). Then log `%DOWNSTREAM_REMOTE_ADDRESS%` together with `%REQ(X-FORWARDED-FOR)%`.

**d)** Envoy generates (or propagates) a unique `x-request-id` and forwards it upstream. If the applications log it too, one ID joins the gateway record, the application log and traces, without relying on timestamps or IPs that are rewritten by NAT and proxies.

**e)** In YAML, `%` is an indicator character (it introduces directives such as `%YAML`) and cannot start a plain scalar. An unquoted `%START_TIME%` is a syntax error, so the manifest would be rejected before it reaches the API server.

</details>

<details>
<summary>Exercise 6</summary>

**a)** Pods get `options ndots:5` and a search list `audit-lab.svc.cluster.local svc.cluster.local cluster.local`. `kubernetes.io` has fewer than 5 dots, so the resolver tries each search suffix **first** and only then the name as given. Each failed suffix is one NXDOMAIN round trip, often doubled for `A` and `AAAA`. This is extra DNS load and latency for every external name.

**b)** A trailing dot marks the name as fully qualified: the resolver skips the search list and sends exactly one query, `kubernetes.io.`. The same effect can be obtained for a workload with `dnsConfig.options: [{name: ndots, value: "1"}]`, at the cost of breaking short in-cluster names like `server.audit-lab`.

**c)** `aa` = **Authoritative Answer**. CoreDNS is authoritative for `cluster.local` through the `kubernetes` plugin, so its NXDOMAINs for that zone are authoritative. `kubernetes.io.` was answered through `forward` by an upstream recursive resolver, so the answer is not authoritative (`ra` = recursion available is set instead).

**d)** Join it with a record of IP-to-pod ownership: Hubble flows (which carry both IP and pod name), CNI/IPAM data, or Kubernetes pod events/metadata shipped with timestamps. It is time-sensitive because pod IPs are reused: the same IP can belong to a different pod an hour later, so the join must use the ownership that was valid **at the query's timestamp**.

**e)** Only `does-not-exist...` appears. `class denial` logs NXDOMAIN and NODATA responses, and `class error` logs SERVFAIL, REFUSED and other error responses. A successful `NOERROR` answer with data (the `server` lookup) is in the `success` class, which is no longer logged.

**f)** `denial` covers **negative** answers: the name does not exist (NXDOMAIN) or exists without the requested type (NODATA). These often indicate misconfiguration, typos, or DGA-like or scanning behavior. `error` covers **failures to answer** (SERVFAIL, REFUSED, FORMERR, NOTIMP), which often indicate upstream resolver problems, loops or policy blocks.

</details>

<details>
<summary>Exercise 7</summary>

**a)** `UF` = upstream connection failure. `upstream_reset_before_response_started{connection_timeout}` together with about 10 s (the connect timeout) means Envoy **selected** a healthy endpoint (it has an `upstream_host`) but could not complete the TCP handshake. The endpoint exists, but packets to it vanish, which points to a silent drop in the network path (policy, firewall) rather than a dead app, which would usually produce a fast `connection refused` RST. `UH` in Exercise 5 was different: there were no endpoints at all, the failure was instant, and there was no `upstream_host`.

**b)** A standard Hubble drop record identifies the flow, direction and reason (`POLICY_DENIED`), but for a deny caused by *no rule matching* there is no single "denying policy": the drop occurs because the endpoint became isolated for ingress and none of the rules selecting it allows this peer. You identify the candidates by listing the policies that select the destination pods (`kubectl -n audit-lab get networkpolicy,ciliumnetworkpolicy`, then compare their `podSelector` with the pod labels), or by asking the agent which rules apply (`cilium-dbg policy get` / `cilium-dbg endpoint get <id>` in the Cilium pod on that node). Here, `lockdown` is the only policy selecting `app=server`.

**c)** Correlation is not causation. The change must **precede** the first failure (and failures should not exist before it). You should also check that nothing else changed in between: other audit events on Services, EndpointSlices, Gateways or CiliumNetworkPolicies, rollouts, and Cilium configuration changes. The audit log gives the exact timestamp of the change. Clock skew between the node and the proxy logs is usually negligible in-cluster, but it must be considered when joining with external systems.

**d)** No. Envoy Gateway receives the backend endpoints as IPs through EDS from `EndpointSlices`, so the gateway-to-backend hop performs no DNS lookup. The access log also shows an `upstream_host` IP, which proves that resolution was not the problem. CoreDNS logs would matter if the upstream were an FQDN-based backend (for example a `Backend` with an FQDN or an `ExternalName`-style upstream) or if the client-side failure happened before reaching the gateway.

**e)** With both selectors in the **same** peer entry, they are ANDed: pods with that label **in** `envoy-gateway-system`. With `-` before `podSelector`, there are two separate peers ORed together: *any pod* in `envoy-gateway-system`, **or** pods with those labels **in `audit-lab`** (a bare `podSelector` refers to the policy's own namespace). The first peer opens the backend to every workload in the gateway namespace, and the second matches nothing useful. It is a silent over-permission that still "fixes" the incident, which makes it easy to miss in review.

**f)** Example: "At 11:03:47Z, NetworkPolicy `audit-lab/lockdown` was created by `kubernetes-admin` impersonating `alice` (API audit, RBAC via RoleBinding `alice-edit`). It isolated `app=server` for ingress without allowing the Envoy Gateway data plane. From then on, Cilium dropped Envoy→server SYNs with `POLICY_DENIED` (Hubble), and the gateway returned 503 `UF`/`connection_timeout` after 10 s (Envoy access log). Fixed by `allow-gateway-to-server`, scoped to the gateway's pods by namespace AND pod labels."

</details>

---

## References

- Kubernetes — Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Kubernetes — Audit policy API (`audit.k8s.io/v1`): https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- Kubernetes — User impersonation: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Debugging DNS resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- kind — Auditing: https://kind.sigs.k8s.io/docs/user/auditing/
- Cilium — Hubble setup and CLI: https://docs.cilium.io/en/stable/observability/hubble/
- Cilium — Configuring the Hubble exporter: https://docs.cilium.io/en/stable/observability/hubble/configuration/export/
- Cilium — Policy audit mode / creating policies from verdicts: https://docs.cilium.io/en/stable/security/policy-creation/
- Cilium — Layer 7 policy examples: https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- Envoy Gateway — Proxy access logs: https://gateway.envoyproxy.io/docs/tasks/observability/proxy-accesslog/
- Envoy — Access log format and response flags: https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage
- CoreDNS — `log` plugin: https://coredns.io/plugins/log/
- Linux Foundation — CKNE certification: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/