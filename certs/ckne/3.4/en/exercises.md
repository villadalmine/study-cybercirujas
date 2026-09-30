# Guided Exercises — Topic 3.4: Implementing Cross-Cluster Service Discovery and Load Balancing

> **Exam weight:** 5%
> **Goal:** Build two Kubernetes clusters, connect them with Cilium ClusterMesh, and publish a *global* Service that load-balances across both clusters. Then control how traffic is spread with affinity and sharing, test failover, restrict cross-cluster traffic with policy, and compare Cilium's annotation model with the Kubernetes Multi-Cluster Services (MCS) API (`ServiceExport` / `ServiceImport`, `clusterset.local`).

**Official references used throughout:**

- CKNE program page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cilium ClusterMesh setup: https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
- Cilium load-balancing and service discovery across clusters: https://docs.cilium.io/en/stable/network/clustermesh/services/
- Cilium ClusterMesh network policy: https://docs.cilium.io/en/stable/network/clustermesh/policy/
- Cilium MCS API support: https://docs.cilium.io/en/stable/network/clustermesh/mcsapi/
- MCS API (SIG-Multicluster): https://multicluster.sigs.k8s.io/concepts/multicluster-services-api/
- KEP-1645 Multi-Cluster Services API: https://github.com/kubernetes/enhancements/tree/master/keps/sig-multicluster/1645-multi-cluster-services-api
- MCS API CRDs: https://github.com/kubernetes-sigs/mcs-api

---

## Lab prerequisites

| Tool | Purpose |
|---|---|
| Docker or Podman | Runs the kind nodes |
| `kind` ≥ 0.20 | Creates the two clusters |
| `kubectl` | Works with both clusters through `--context` |
| `cilium` CLI (matching your Cilium minor version) | Installs Cilium and ClusterMesh |
| About 8 GB of free RAM | Two clusters with two nodes each |

Every command names its cluster explicitly with `--context kind-c1` or `--context kind-c2`. In multi-cluster work, a command that silently runs against the current context is the most common cause of confusing results. Get into the habit now.

---

## Exercise 1 — Two clusters with non-overlapping networks

### Steps

1. Create the kind configuration for cluster **c1**:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: c1
   networking:
     disableDefaultCNI: true
     podSubnet: "10.10.0.0/16"
     serviceSubnet: "10.110.0.0/16"
   nodes:
     - role: control-plane
     - role: worker
   ```

   Save it as `c1.yaml`.

2. Create `c2.yaml` with the same content, except for these fields:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: c2
   networking:
     disableDefaultCNI: true
     podSubnet: "10.20.0.0/16"
     serviceSubnet: "10.120.0.0/16"
   nodes:
     - role: control-plane
     - role: worker
   ```

3. Create both clusters:

   ```bash
   kind create cluster --config c1.yaml
   kind create cluster --config c2.yaml
   kubectl config get-contexts
   ```

   Expected output (abbreviated):

   ```
   CURRENT   NAME      CLUSTER   AUTHINFO   NAMESPACE
             kind-c1   kind-c1   kind-c1
   *         kind-c2   kind-c2   kind-c2
   ```

4. Check the nodes. They should be `NotReady`, because no CNI is installed yet:

   ```bash
   kubectl --context kind-c1 get nodes
   kubectl --context kind-c2 get nodes
   ```

   ```
   NAME               STATUS     ROLES           AGE   VERSION
   c1-control-plane   NotReady   control-plane   60s   v1.3x.x
   c1-worker          NotReady   <none>          40s   v1.3x.x
   ```

5. Confirm that the nodes of both clusters share one L3 network (the `kind` Docker network):

   ```bash
   docker network inspect kind -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
   ```

### Check your understanding

- **Q1.1** Why do the two clusters use *different* `podSubnet` values? What would break in ClusterMesh if both used `10.10.0.0/16`?
- **Q1.2** Step 5 checks node-to-node reachability. Which ClusterMesh components need that reachability, and on which kind of traffic?

---

## Exercise 2 — Install Cilium with a unique cluster identity and a shared CA

### Steps

1. Install Cilium on **c1** with a unique name and ID:

   ```bash
   cilium install --context kind-c1 \
     --set cluster.name=c1 \
     --set cluster.id=1 \
     --set ipam.mode=kubernetes
   cilium status --context kind-c1 --wait
   ```

2. Before you install anything on **c2**, copy c1's Cilium CA into c2. Remove the server-managed metadata so that `create` accepts the object:

   ```bash
   kubectl --context kind-c1 -n kube-system get secret cilium-ca -o yaml \
     | sed -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
     | kubectl --context kind-c2 create -f -
   ```

   Expected output:

   ```
   secret/cilium-ca created
   ```

3. Install Cilium on **c2**:

   ```bash
   cilium install --context kind-c2 \
     --set cluster.name=c2 \
     --set cluster.id=2 \
     --set ipam.mode=kubernetes
   cilium status --context kind-c2 --wait
   ```

4. Check the identity that each agent reports:

   ```bash
   kubectl --context kind-c1 -n kube-system get cm cilium-config -o jsonpath='{.data.cluster-name}{" "}{.data.cluster-id}{"\n"}'
   kubectl --context kind-c2 -n kube-system get cm cilium-config -o jsonpath='{.data.cluster-name}{" "}{.data.cluster-id}{"\n"}'
   ```

   ```
   c1 1
   c2 2
   ```

5. Check that both clusters trust the same CA by comparing the certificate fingerprints:

   ```bash
   for c in kind-c1 kind-c2; do
     kubectl --context $c -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}' \
       | base64 -d | openssl x509 -noout -fingerprint -sha256
   done
   ```

   Both lines must be identical.

### Check your understanding

- **Q2.1** What is `cluster.id` used for in the datapath, and what goes wrong if two meshed clusters share `cluster.id=1`?
- **Q2.2** Why must the CA be copied *before* installing Cilium on c2, and not afterwards?
- **Q2.3** What range of values is valid for `cluster.id` in a default ClusterMesh configuration, and what is the trade-off of raising the maximum number of clusters?

---

## Exercise 3 — Enable and connect ClusterMesh

### Steps

1. Enable the clustermesh control plane (`clustermesh-apiserver`) in both clusters. kind has no LoadBalancer implementation, so use `NodePort`:

   ```bash
   cilium clustermesh enable --context kind-c1 --service-type NodePort
   cilium clustermesh enable --context kind-c2 --service-type NodePort
   ```

   The CLI prints a warning that NodePort is not recommended for production. Note it; you will explain why in Q3.1.

2. Wait until both are ready:

   ```bash
   cilium clustermesh status --context kind-c1 --wait
   cilium clustermesh status --context kind-c2 --wait
   ```

3. Connect the clusters. One command sets up the relationship in both directions:

   ```bash
   cilium clustermesh connect --context kind-c1 --destination-context kind-c2
   ```

4. Check the mesh from both sides:

   ```bash
   cilium clustermesh status --context kind-c1 --wait
   ```

   Output similar to:

   ```
   ✅ Service "clustermesh-apiserver" of type "NodePort" found
   ✅ Cluster access information is available:
     - 172.18.0.3:32379
   ✅ Deployment clustermesh-apiserver is ready
   ✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
   🔌 Cluster Connections:
     - c2: 2/2 configured, 2/2 connected
   ```

5. Look at the mesh from inside an agent:

   ```bash
   kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A3 ClusterMesh
   kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg troubleshoot clustermesh
   ```

6. Optional, and slow (several minutes): run the multi-cluster connectivity suite:

   ```bash
   cilium connectivity test --context kind-c1 --multi-cluster kind-c2
   ```

### Check your understanding

- **Q3.1** Why is `NodePort` discouraged for the `clustermesh-apiserver` in production?
- **Q3.2** Which component in c1 connects to c2's `clustermesh-apiserver`: the operator, every agent, or the c1 `clustermesh-apiserver`? What does it read from there?
- **Q3.3** After the mesh is connected, does a pod in c1 reach a pod IP in c2 through the c2 control plane? Describe the actual data path.

---

## Exercise 4 — Deploy a global Service

### Steps

1. Create the namespace and workload in **both** clusters. Each cluster answers with its own name. Save this as `echo-c1.yaml`:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: demo
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: echo
     namespace: demo
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: echo
     template:
       metadata:
         labels:
           app: echo
       spec:
         containers:
           - name: echo
             image: hashicorp/http-echo:1.0
             args:
               - "-text=served-by-c1"
               - "-listen=:5678"
             ports:
               - containerPort: 5678
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: echo
     namespace: demo
     annotations:
       service.cilium.io/global: "true"
   spec:
     selector:
       app: echo
     ports:
       - name: http
         port: 80
         targetPort: 5678
   ```

2. Copy it to `echo-c2.yaml` and change only the text to `-text=served-by-c2`. Apply each file to its own cluster:

   ```bash
   kubectl --context kind-c1 apply -f echo-c1.yaml
   kubectl --context kind-c2 apply -f echo-c2.yaml
   kubectl --context kind-c1 -n demo rollout status deploy/echo
   kubectl --context kind-c2 -n demo rollout status deploy/echo
   ```

3. Start a client pod in c1:

   ```bash
   kubectl --context kind-c1 -n demo run client --image=curlimages/curl:8.10.1 \
     --restart=Never --command -- sleep 3600
   kubectl --context kind-c1 -n demo wait --for=condition=Ready pod/client
   ```

4. Send 20 requests and count which cluster answered each one:

   ```bash
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s echo.demo.svc.cluster.local; done | sort | uniq -c'
   ```

   Output similar to (exact numbers vary):

   ```
        11 served-by-c1
         9 served-by-c2
   ```

5. Inspect the service table in the eBPF load balancer on a c1 node:

   ```bash
   SVC_IP=$(kubectl --context kind-c1 -n demo get svc echo -o jsonpath='{.spec.clusterIP}')
   kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- \
     cilium-dbg service list | grep -A4 "$SVC_IP"
   ```

   Output similar to:

   ```
   42   10.110.87.14:80/TCP    ClusterIP      1 => 10.10.1.23:5678/TCP (active)
                                              2 => 10.10.1.51:5678/TCP (active)
                                              3 => 10.20.1.88:5678/TCP (active)
                                              4 => 10.20.1.12:5678/TCP (active)
   ```

   The backends in `10.20.0.0/16` are c2 pods.

6. Compare the Kubernetes `EndpointSlice` objects with what the datapath uses:

   ```bash
   kubectl --context kind-c1 -n demo get endpointslices -l kubernetes.io/service-name=echo \
     -o custom-columns=NAME:.metadata.name,ADDRS:.endpoints[*].addresses[0]
   ```

### Check your understanding

- **Q4.1** The client resolved `echo.demo.svc.cluster.local`, a *local* DNS name. So how did it reach pods in c2? Which layer does the cross-cluster "discovery" actually happen in?
- **Q4.2** The `EndpointSlice` in step 6 lists only c1 pods, while `cilium-dbg service list` lists four backends. Why does this matter when you troubleshoot?
- **Q4.3** What two things must match in both clusters for Cilium to treat the Services as one global service?

---

## Exercise 5 — Controlling where the load goes: `shared` and `affinity`

### Steps

1. Give local backends priority in c1. Remote backends will be used only when no healthy local backend exists:

   ```bash
   kubectl --context kind-c1 -n demo annotate svc echo service.cilium.io/affinity=local --overwrite
   ```

2. Repeat the traffic test from c1:

   ```bash
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s echo.demo; done | sort | uniq -c'
   ```

   ```
        20 served-by-c1
   ```

3. Check the affinity markers in the datapath:

   ```bash
   kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- \
     cilium-dbg service list --clustermesh-affinity | grep -A4 "$SVC_IP"
   ```

   Local backends are marked `(preferred)`.

4. Now stop c2 from *sharing* its backends with the rest of the mesh:

   ```bash
   kubectl --context kind-c1 -n demo annotate svc echo service.cilium.io/affinity- 
   kubectl --context kind-c2 -n demo annotate svc echo service.cilium.io/shared="false" --overwrite
   ```

5. Test from c1 again, then from a client in c2:

   ```bash
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s echo.demo; done | sort | uniq -c'

   kubectl --context kind-c2 -n demo run client --image=curlimages/curl:8.10.1 \
     --restart=Never --command -- sleep 3600
   kubectl --context kind-c2 -n demo wait --for=condition=Ready pod/client
   kubectl --context kind-c2 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s echo.demo; done | sort | uniq -c'
   ```

   Record both results before you read the answers.

6. Remove the `shared` annotation to restore the default:

   ```bash
   kubectl --context kind-c2 -n demo annotate svc echo service.cilium.io/shared-
   ```

### Check your understanding

- **Q5.1** What do the three `affinity` values `local`, `remote` and `none` do?
- **Q5.2** In step 5, what did c1's client see, and what did c2's client see? Explain why they differ.
- **Q5.3** Name one production use case for `shared: "false"`, and one for `affinity: remote`.
- **Q5.4** Why is `affinity: local` usually the right default for chatty east-west services in a multi-region mesh?

---

## Exercise 6 — Cross-cluster failover

### Steps

1. Put `affinity: local` back on c1:

   ```bash
   kubectl --context kind-c1 -n demo annotate svc echo service.cilium.io/affinity=local --overwrite
   ```

2. In a second terminal, start a continuous request loop from c1:

   ```bash
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'while true; do curl -s -m 1 echo.demo || echo FAIL; sleep 0.5; done'
   ```

3. In the first terminal, simulate losing the local service:

   ```bash
   kubectl --context kind-c1 -n demo scale deploy/echo --replicas=0
   ```

   Watch the loop. The responses switch from `served-by-c1` to `served-by-c2`.

4. Restore it:

   ```bash
   kubectl --context kind-c1 -n demo scale deploy/echo --replicas=2
   ```

   Traffic moves back to `served-by-c1` once the pods are `Ready`.

5. Now simulate losing the *control plane* connection instead of the workload. Scale down c2's clustermesh-apiserver:

   ```bash
   kubectl --context kind-c2 -n kube-system scale deploy/clustermesh-apiserver --replicas=0
   cilium clustermesh status --context kind-c1
   ```

   Remove the affinity (`kubectl --context kind-c1 -n demo annotate svc echo service.cilium.io/affinity-`) and run the 20-request test again.

6. Restore it:

   ```bash
   kubectl --context kind-c2 -n kube-system scale deploy/clustermesh-apiserver --replicas=1
   cilium clustermesh status --context kind-c1 --wait
   ```

### Check your understanding

- **Q6.1** In step 3, did any `FAIL` lines appear? What decides how long failover takes?
- **Q6.2** In step 5, c1 lost its connection to c2's control plane. Did c1 immediately stop sending traffic to c2 backends? Why is that behaviour deliberate?
- **Q6.3** What is the risk of the behaviour in Q6.2 if c2's pods are rescheduled while the connection is down?

---

## Exercise 7 — Cross-cluster network policy

### Steps

1. Allow ingress to `echo` in c2 **only** from clients in cluster c1. Apply this to c2:

   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: echo-from-c1-only
     namespace: demo
   spec:
     endpointSelector:
       matchLabels:
         app: echo
     ingress:
       - fromEndpoints:
           - matchLabels:
               run: client
               io.cilium.k8s.policy.cluster: c1
         toPorts:
           - ports:
               - port: "5678"
                 protocol: TCP
   ```

   ```bash
   kubectl --context kind-c2 apply -f echo-from-c1-only.yaml
   ```

2. Test from both clients. Remove any affinity first, so that c2 backends are chosen:

   ```bash
   kubectl --context kind-c1 -n demo annotate svc echo service.cilium.io/affinity- 2>/dev/null
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s -m 1 echo.demo || echo TIMEOUT; done | sort | uniq -c'
   kubectl --context kind-c2 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s -m 1 echo.demo || echo TIMEOUT; done | sort | uniq -c'
   ```

3. Watch the drops with Hubble, if it is enabled (`cilium hubble enable --context kind-c2`):

   ```bash
   kubectl --context kind-c2 -n kube-system exec ds/cilium -c cilium-agent -- \
     hubble observe --namespace demo --verdict DROPPED --last 20
   ```

4. Delete the policy:

   ```bash
   kubectl --context kind-c2 -n demo delete cnp echo-from-c1-only
   ```

### Check your understanding

- **Q7.1** Predict c2's client result in step 2. Which replies does it get, and which requests time out?
- **Q7.2** How can c2 enforce a policy on a *source* label from c1, when the packet only carries IP addresses?
- **Q7.3** Why is the `io.cilium.k8s.policy.cluster` label important in a policy that uses only `app` labels, if the two clusters belong to different teams?

---

## Exercise 8 — The standard model: MCS API (`ServiceExport` / `ServiceImport`)

The Cilium annotation is implementation-specific. The **Multi-Cluster Services API** (KEP-1645) is the vendor-neutral Kubernetes model. Services are *exported* explicitly, *imported* by every cluster in the **ClusterSet**, and resolved under `clusterset.local`. Cilium implements it from 1.17 onwards. Check the exact Helm values for your version on https://docs.cilium.io/en/stable/network/clustermesh/mcsapi/.

### Steps

1. Install the MCS CRDs in **both** clusters. Use the file paths published in https://github.com/kubernetes-sigs/mcs-api for the release your Cilium version supports:

   ```bash
   MCS=https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/<release>/config/crd
   for c in kind-c1 kind-c2; do
     kubectl --context $c apply -f $MCS/multicluster.x-k8s.io_serviceexports.yaml
     kubectl --context $c apply -f $MCS/multicluster.x-k8s.io_serviceimports.yaml
   done
   kubectl --context kind-c1 api-resources --api-group=multicluster.x-k8s.io
   ```

   ```
   NAME             SHORTNAMES   APIVERSION                        NAMESPACED   KIND
   serviceexports   svcexport    multicluster.x-k8s.io/v1alpha1   true         ServiceExport
   serviceimports   svcim        multicluster.x-k8s.io/v1alpha1   true         ServiceImport
   ```

2. Enable MCS support in Cilium in both clusters, including the CoreDNS configuration for `clusterset.local` if your version provides it:

   ```bash
   for c in kind-c1 kind-c2; do
     cilium upgrade --context $c --reuse-values \
       --set clustermesh.mcsapi.enabled=true \
       --set clustermesh.mcsapi.corednsAutoConfigure.enabled=true
   done
   ```

3. Create a second, *non-annotated* service `web` in both clusters, reusing the echo pods:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: demo
   spec:
     selector:
       app: echo
     ports:
       - name: http
         port: 80
         targetPort: 5678
   ```

4. Export it from **both** clusters:

   ```yaml
   apiVersion: multicluster.x-k8s.io/v1alpha1
   kind: ServiceExport
   metadata:
     name: web
     namespace: demo
   ```

   ```bash
   for c in kind-c1 kind-c2; do
     kubectl --context $c apply -f web-svc.yaml -f web-export.yaml
   done
   kubectl --context kind-c1 -n demo get serviceexport web -o yaml | sed -n '/status:/,$p'
   ```

   Look for a `Valid` condition set to `True`, and no `Conflict` condition set to `True`.

5. Look at the `ServiceImport` that was created automatically:

   ```bash
   kubectl --context kind-c1 -n demo get serviceimport web -o wide
   kubectl --context kind-c1 -n demo get serviceimport web -o jsonpath='{.spec.type}{" "}{.spec.ips}{"\n"}'
   ```

6. Resolve and call the ClusterSet name:

   ```bash
   kubectl --context kind-c1 -n demo exec client -- nslookup web.demo.svc.clusterset.local
   kubectl --context kind-c1 -n demo exec client -- sh -c \
     'for i in $(seq 1 20); do curl -s web.demo.svc.clusterset.local; done | sort | uniq -c'
   ```

7. Cause a conflict on purpose: in c2 only, change the port of `web` to `8080` and re-apply. Then check the export status in both clusters again.

8. Unexport from c2 (`kubectl --context kind-c2 -n demo delete serviceexport web`) and repeat step 6.

### Check your understanding

- **Q8.1** Compare `web.demo.svc.cluster.local` and `web.demo.svc.clusterset.local` here. Which pods does each name reach, and why?
- **Q8.2** What is **namespace sameness**, and why does the MCS API rely on it?
- **Q8.3** Which `ServiceImport` type would you expect for a headless Service, and how does that change what DNS returns?
- **Q8.4** How does the MCS API resolve the port conflict in step 7? What does the operator see?
- **Q8.5** Give one reason to prefer the MCS API over the `service.cilium.io/global` annotation, and one reason the annotation is still common.

---

## Exercise 9 — Troubleshooting drill

Each scenario breaks one thing. Diagnose it with the commands you have used so far, **before** you read the answer.

| # | Break it | Symptom to explain |
|---|---|---|
| A | `kubectl --context kind-c2 -n demo delete svc echo` | From c1, only `served-by-c1` answers. The c2 pods are still running |
| B | In c1, remove the `service.cilium.io/global` annotation; keep it in c2 | From c1, only `served-by-c1`. From c2, both clusters answer |
| C | In a fresh lab, install c2 with `cluster.id=1` | Mesh status shows errors or intermittent connectivity |
| D | Rename the namespace in c2 to `demo2` | The service is no longer global |

Useful commands:

```bash
cilium clustermesh status --context kind-c1
kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg troubleshoot clustermesh
kubectl --context kind-c1 -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
kubectl --context kind-c1 -n kube-system logs deploy/clustermesh-apiserver -c apiserver --tail=50
```

Restore the lab after each scenario (re-apply `echo-c1.yaml` / `echo-c2.yaml`).

### Check your understanding

- **Q9.1** Explain symptoms A through D.
- **Q9.2** What is a sensible troubleshooting order for "cross-cluster service doesn't balance", from control plane to datapath?

---

## Cleanup

```bash
kind delete cluster --name c1
kind delete cluster --name c2
```

---

## Answers

<details>
<summary><strong>Exercise 1</strong></summary>

**Q1.1** ClusterMesh routes pod-to-pod traffic across clusters using pod IPs. Each agent learns which remote pod CIDRs, and which pod IPs, belong to which remote node. If both clusters used `10.10.0.0/16`, an address like `10.10.1.23` could belong to either cluster. Routing, the ipcache mapping from IP to identity, and policy enforcement would all be ambiguous. Cilium requires non-overlapping PodCIDRs across the mesh. Service CIDRs are not routed across clusters, because a ClusterIP is always translated locally. Distinct service CIDRs are still good hygiene, because they make packet captures unambiguous.

**Q1.2** Two kinds of traffic need it:
1. **Control plane:** the Cilium agents (and the operator) of each cluster connect to the other cluster's `clustermesh-apiserver` (its etcd, TCP 2379 behind the Service).
2. **Data plane:** pod-to-pod packets travel node to node. They use the encapsulation tunnel (VXLAN UDP 8472 or Geneve 6081) or native routing, so every node must reach every node of the other cluster.

</details>

<details>
<summary><strong>Exercise 2</strong></summary>

**Q2.1** The cluster ID is part of how Cilium makes **security identities** unique across the mesh. Identities allocated in each cluster are placed in a range derived from the cluster ID, so an identity number means the same thing everywhere. The ID also tags remote state (endpoints, services, nodes) with its origin cluster. With duplicate IDs, the identity ranges collide: a numeric identity from c2 can be read as a different c1 identity. The result is wrong policy decisions, backends attributed to the wrong cluster, and mesh connection errors. Cilium refuses or flags duplicate IDs among connected clusters.

**Q2.2** On first install, Cilium creates `cilium-ca` if it is absent. It then issues the clustermesh-apiserver server certificates, the remote-client certificates and the Hubble certificates from that CA. If c2 is installed first, it creates its *own* CA and signs everything with it. Replacing the secret later means you must regenerate and rotate every derived certificate. Seeding the CA before installation means both clusters sign from the same root from the start, and mutual TLS between agents and remote `clustermesh-apiserver` instances just works. (`cilium clustermesh connect` can also exchange CA bundles, but a shared CA is the simplest and the recommended setup.)

**Q2.3** By default, `cluster.id` is 1–255. ID 0 means "not part of a mesh", so 255 clusters are available. `clustermesh.maxConnectedClusters` can be raised to 511. That takes bits away from the per-cluster identity space, so each cluster can allocate fewer security identities. The setting must be decided at install time and be the same across the mesh.

</details>

<details>
<summary><strong>Exercise 3</strong></summary>

**Q3.1** A NodePort address is a specific node IP. If that node is drained, replaced or fails, remote clusters lose their control-plane endpoint until their configuration is updated. A LoadBalancer (or a stable internal LB/DNS name) gives a fixed, highly available address. NodePort also opens a high port on every node. It is fine for labs, and fragile in production.

**Q3.2** **Every cilium-agent** in c1 (and the operator, for some state) connects to c2's `clustermesh-apiserver` and watches its etcd with the remote-client certificate. It reads c2's nodes (so it can program routes and tunnels), identities, endpoints/ipcache entries (IP → identity), and the backends of global services. The `clustermesh-apiserver` in c1 serves c1's state to *other* clusters. It is not a proxy for c1's agents.

**Q3.3** No. The control plane only distributes *state*. The data path is direct and node to node: the source pod's eBPF program chooses a backend, the packet is encapsulated (or routed natively) from the c1 node to the c2 node that hosts the destination pod, and it is delivered there. The `clustermesh-apiserver` is never on the packet path. That is also why the data path survives a temporary control-plane outage (see Q6.2).

</details>

<details>
<summary><strong>Exercise 4</strong></summary>

**Q4.1** DNS resolved the name to c1's **local ClusterIP** as usual. The cross-cluster part happens in the **eBPF service load balancer**. The Cilium agent merged the local backends with the remote backends learned from c2's clustermesh-apiserver into the same service entry. When the client connects to the ClusterIP, socket-level or TC-level load balancing picks any of the four backends, including c2 pod IPs. So with the annotation model, discovery happens at the datapath layer, not in DNS.

**Q4.2** Kubernetes objects (`EndpointSlice`) show only local endpoints. Tools that trust them — `kubectl describe svc`, some service meshes, monitoring — do not know about remote backends. When you debug, check `cilium-dbg service list` (or `cilium-dbg bpf lb list`) on the *node where the client runs*. That is what the kernel actually uses. "The EndpointSlice looks fine" proves nothing about cross-cluster balancing.

**Q4.3** The Service must have the **same name in the same namespace** in each cluster, and carry `service.cilium.io/global: "true"` in each cluster that should take part. The ports should also match. A service in a cluster that has no local pods still needs the Service object, or clients there have no ClusterIP to connect to.

</details>

<details>
<summary><strong>Exercise 5</strong></summary>

**Q5.1**
- `local`: use local backends while any are healthy. Remote backends are used only as fallback.
- `remote`: prefer remote-cluster backends, and fall back to local ones.
- `none` (the default): no preference. Local and remote backends are balanced together.

**Q5.2** c1's client saw **only `served-by-c1`**. c2 no longer shares its backends, so c1's service entry holds only local backends. c2's client saw **both clusters**. `shared: "false"` controls whether *this* cluster's backends are *exported* to others. It does not stop c2 from *consuming* the backends c1 shares. In one sentence: `shared` controls what a cluster publishes, not what it uses.

**Q5.3**
- `shared: "false"`: a cluster that consumes a central service but must not receive other clusters' traffic. Examples: an edge or compliance-restricted cluster whose local instances should serve only local users, or a cluster being drained before maintenance (stop sharing, wait for connections to finish, then work on it).
- `affinity: remote`: move traffic *off* the local cluster while keeping the local deployment as a last resort. Examples: during a canary or maintenance in the local cluster, or when a dedicated remote cluster holds the "primary" copy of a service.

**Q5.4** Crossing regions adds latency (often tens of milliseconds per round trip) and costs money in cross-zone or cross-region egress. It also couples the local service's availability to the WAN link. `local` keeps the normal path inside the cluster and still gives automatic failover to remote backends when the local ones disappear. You get locality normally and cross-cluster resilience when you need it.

</details>

<details>
<summary><strong>Exercise 6</strong></summary>

**Q6.1** Usually a few `FAIL` lines at most, and often none. Scaling to zero sends SIGTERM to the pods. They leave the EndpointSlice (they are marked terminating, not ready), the local agent removes them from the service entry, and the `local` preference has no healthy local backend left, so remote backends are used. The failover time depends on how fast the endpoint update propagates: the kube-apiserver watch → Cilium agent → BPF map update. It also depends on in-flight connections to terminating pods and on the client's timeouts. A pod crash without graceful termination depends on readiness-probe failure detection (period × failureThreshold). That is usually the dominant term.

**Q6.2** No. Agents **keep the last known remote state** when the connection to a remote clustermesh-apiserver is lost, and traffic to c2 backends continues. Purging it would turn a *control-plane* hiccup (an apiserver restart, a flaky link to port 2379) into a *data-plane* outage for every cross-cluster flow. Pod-to-pod data paths don't depend on the control plane, so keeping stale state is the safer default.

**Q6.3** The state goes stale. If c2's pods are deleted or rescheduled to new IPs while the connection is down, c1 keeps sending some requests to IPs that no longer exist, or that were reused by other pods (which the identity-aware policy would drop). Clients see timeouts on a share of requests until the connection comes back and the state reconciles. That is why the clustermesh-apiserver should run with several replicas and be monitored (`cilium clustermesh status`, and the agents' remote-cluster health metrics).

</details>

<details>
<summary><strong>Exercise 7</strong></summary>

**Q7.1** c2's client gets **only `served-by-c1`** replies, plus **TIMEOUT** for the requests that were balanced to c2 backends. Its own cluster label is `c2`, so c2's policy drops those requests. Requests balanced to c1 backends pass, because c1 has no policy on `echo`. c1's client succeeds against both clusters.

**Q7.2** Through **identity**. Cilium assigns each pod a numeric security identity derived from its labels, and the cluster name is one of those labels (`io.cilium.k8s.policy.cluster`). Through ClusterMesh, c2's agents learn the ipcache mapping *c1 pod IP → c1 identity*. On ingress, the destination node maps the source IP (or the identity carried in the tunnel header) to the identity and evaluates the policy against its labels. No label travels in the packet itself, only the IP or the identity number.

**Q7.3** Without it, `matchLabels: {app: frontend}` matches pods with that label in **every** cluster of the mesh, because identities are global. A team that controls another cluster, or an attacker who can create pods there, can label a pod `app: frontend` and pass your policy. Adding the cluster label ties the rule to a trust domain. Cilium also offers `policy-default-local-cluster`: in recent versions, selectors without a cluster label match only the local cluster by default. Check which behaviour your version uses.

</details>

<details>
<summary><strong>Exercise 8</strong></summary>

**Q8.1** `web.demo.svc.cluster.local` resolves to the **local** Service's ClusterIP. `web` has no global annotation, so it reaches only local pods. `web.demo.svc.clusterset.local` resolves to the **ClusterSet IP** (the VIP of the `ServiceImport`). That VIP is backed by the endpoints of *every* cluster that exports `web`, so it reaches pods in both clusters. The MCS API makes the choice explicit in the name: a client asks for either local or ClusterSet scope.

**Q8.2** Namespace sameness means a namespace with a given name has the same meaning, and usually the same owner, in every cluster of the ClusterSet. `demo` in c1 and `demo` in c2 are "the same namespace". MCS relies on it to merge services: `web` exported from `demo` in any cluster contributes to one `ServiceImport` `demo/web`. Without sameness, two unrelated teams that both happen to own `demo/web` would be silently merged into one service. It is a governance requirement as much as a technical one.

**Q8.3** `type: Headless`. There is no ClusterSet VIP. DNS for `web.demo.svc.clusterset.local` returns the pod IPs of all exported endpoints directly. Per-pod names can be of the form `<hostname>.<clusterid>.<svc>.<ns>.svc.clusterset.local`, which lets StatefulSet members be addressed across clusters. A normal Service gives `type: ClusterSetIP` with one VIP.

**Q8.4** The KEP defines conflict resolution by **precedence: the oldest export wins**. The ServiceImport's properties (ports, type) come from the export with the oldest creation timestamp. The conflicting exports get a `Conflict` condition set to `True` in their `ServiceExport` status, with a reason and message that describe the mismatch. Implementations may still include the conflicting cluster's endpoints for the ports that match, or exclude them; check the implementation's docs. The operator sees the condition with `kubectl get serviceexport web -o yaml`. The failure is reported on the object, not silent.

**Q8.5**
- **For MCS:** it is a Kubernetes-standard, vendor-neutral API, implemented by several projects (Cilium, Submariner, GKE multi-cluster Services, and others). Export is an explicit, auditable object with status conditions. The local and ClusterSet scopes have separate DNS names, so clients choose deliberately.
- **For the annotation:** it works on long-established Cilium versions without extra CRDs or CoreDNS changes. Clients keep their existing `cluster.local` names without code changes. It also has datapath features such as `affinity` and `shared` that MCS does not express natively.

</details>

<details>
<summary><strong>Exercise 9</strong></summary>

**Q9.1**
- **A:** The Service in c2 is gone, so c2's agents no longer publish any global-service backends for `demo/echo`. The pods still exist, but nothing is advertised for the name. With the annotation model, the *Service object* in the exporting cluster is what makes pods shareable, not the pods themselves.
- **B:** In c1 the Service is no longer global, so c1's agents neither import remote backends nor share local ones. c1's clients see only c1. In c2 the Service is still global, and c2 still has the backends c1 advertised *before*. Depending on the version and timing, c1 either stops advertising them (and c2 ends up seeing only c2), or they remain as stale state until reconciliation. Both sides need the annotation for the service to be symmetric. Check `cilium-dbg service list` on each side.
- **C:** Duplicate cluster IDs make identities and origin tags collide. `cilium clustermesh status` and `cilium-dbg troubleshoot clustermesh` report errors, the agent logs complain about a duplicate cluster ID, and policy and service behaviour becomes inconsistent. The fix is to reinstall one cluster with a unique ID. The ID cannot be changed safely on a live cluster.
- **D:** Global services are matched by **namespace + name**. `demo2/echo` in c2 and `demo/echo` in c1 are different services. Namespace sameness applies to Cilium global services too, not only to the MCS API.

**Q9.2**
1. **Mesh health:** `cilium clustermesh status` on both sides. Are all nodes connected to all clusters?
2. **Agent view:** `cilium-dbg troubleshoot clustermesh` on the client's node. Does it have TLS, DNS or reachability errors to the remote clustermesh-apiserver?
3. **Service definition:** same namespace and name in each cluster, the `global` annotation on each, the `shared` and `affinity` values, matching ports. For MCS, the `ServiceExport` conditions (`Valid`, `Conflict`) and the existence of the `ServiceImport`.
4. **Datapath:** `cilium-dbg service list` (with `--clustermesh-affinity`) on the **client's node**. Are the remote backends present and active?
5. **Packet path:** `hubble observe` for drops (policy, a missing identity), then pod-to-pod connectivity across nodes (tunnel ports, MTU, native-routing routes).
6. **DNS**, for MCS only: does `*.svc.clusterset.local` resolve to the ServiceImport IP?

</details>