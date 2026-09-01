# Cilium Architecture & Components — Guided Exercises

> **Exam context:** CCA Domain 2.1 — *Cilium Architecture & Components* (20% of the exam).
> **Format:** every block is a sequence of numbered steps you run against a real cluster, followed by checkpoint questions. Answers are collapsed at the bottom — resist opening them until you have written your own.
> **Version baseline:** Cilium **1.17.x** on Kubernetes **1.32**, kernel **≥ 6.6** (so the TCX attach mode is available). Where behaviour changed recently, the version is called out inline.
> **Outputs shown are representative.** Endpoint IDs, security identities, IPs and interface names will differ on your cluster — that is the point of several questions.

---

## Exercise 0 — Build the lab

You need a cluster where **you** own the datapath: no pre-installed CNI, and no `kube-proxy`, so that Cilium's own components are the only thing between a pod and the wire.

1. Write the kind topology to `cca-lab.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  disableDefaultCNI: true      # no kindnet — Cilium will be the only CNI
  kubeProxyMode: "none"        # no kube-proxy — Cilium will own service load balancing
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Create the cluster and confirm it is intentionally broken:

```bash
kind create cluster --config cca-lab.yaml
kubectl get nodes
kubectl -n kube-system get pods
```

```
NAME                        STATUS     ROLES           AGE   VERSION
cca-lab-control-plane       NotReady   control-plane   41s   v1.32.2
cca-lab-worker              NotReady   <none>          25s   v1.32.2
cca-lab-worker2             NotReady   <none>          25s   v1.32.2

NAME                       READY   STATUS    RESTARTS   AGE
coredns-668d6bf9bc-8f2qk   0/1     Pending   0          38s
coredns-668d6bf9bc-l7v9n   0/1     Pending   0          38s
etcd-cca-lab-...           1/1     Running   0          44s
```

3. Install Cilium with Helm. Note the two `k8sService*` values — they are not cosmetic:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system \
  --set k8sServiceHost=cca-lab-control-plane \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=true \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16} \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1
```

4. Watch it converge, then inventory what was installed:

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system get ds,deploy -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -o wide | grep -E 'cilium|hubble'
```

```
NAME                       DESIRED   CURRENT   READY   NODE SELECTOR   CONTAINERS      IMAGES
daemonset.apps/cilium          3         3       3     kubernetes.io/os=linux   cilium-agent   quay.io/cilium/cilium:v1.17.4
daemonset.apps/cilium-envoy    3         3       3     kubernetes.io/os=linux   cilium-envoy   quay.io/cilium/cilium-envoy:v1.32.6-...

NAME                                 READY   UP-TO-DATE   AVAILABLE
deployment.apps/cilium-operator          1/1           1           1
deployment.apps/hubble-relay            1/1           1           1
deployment.apps/hubble-ui               1/1           1           1
```

5. Install the `cilium` CLI (this is **cilium-cli**, a different binary from the one inside the pods) and get a cluster-wide verdict:

```bash
cilium status --wait
```

6. Create a shell alias you will use for the rest of this document:

```bash
export CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=cca-lab-worker -o name | head -1)
alias cdbg="kubectl -n kube-system exec -it $CILIUM_POD -c cilium-agent -- cilium-dbg"
cdbg version
```

### Checkpoint questions — Block 0

- **Q0.1** — With `kubeProxyMode: none`, there is no `kube-proxy` to program the `10.96.0.1:443` ClusterIP for the API server. Yet `cilium-agent` must reach the API server to boot. How does the chicken-and-egg break, and which two Helm values encode the answer?
- **Q0.2** — `kubectl get pods` shows *five* distinct Cilium workloads. Classify each one as **per-node** or **cluster-singleton**, and state the Kubernetes object kind that enforces that placement.
- **Q0.3** — CoreDNS was `Pending` before the install and `Running` after, but you never touched the CoreDNS Deployment. Which component made the difference, and through which kubelet interface?
- **Q0.4** — You ran `cilium status` (host) and `cilium-dbg version` (in-pod). Why do two CLIs exist, and what was the in-pod binary called before Cilium 1.16?

---

## Exercise 1 — Anatomy of `cilium-agent`

The agent is the only component that touches the datapath. Everything else feeds it or reads from it.

1. Read the full status report. Do not skim — every line is a subsystem:

```bash
cdbg status --verbose
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.32 (v1.32.2) [linux/amd64]
KubeProxyReplacement:    True   [eth0   172.18.0.3 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.17.4 (v1.17.4-a1b2c3d4)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 4/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.104 (health)
  10.244.1.148 (router)
  10.244.1.29  (default/nginx-6f8c...)
ClusterMesh:             0/0 clusters ready, 0 global-services
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Controller Status:       48/48 healthy
Proxy Status:            OK, ip 10.244.1.148, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 11.72
Encryption:              Disabled
Cluster health:          3/3 reachable   (2026-09-01T12:04:11Z)
Modules Health:          Stopped(0) Degraded(0) OK(52)
```

2. Dump the effective runtime configuration (this is what the agent actually resolved, not what Helm asked for):

```bash
cdbg config --all | head -40
kubectl -n kube-system get cm cilium-config -o yaml | head -60
```

3. Look at the agent's own control loops. Cilium models nearly every recurring job as a *controller* with a backoff:

```bash
cdbg status --all-controllers | head -30
```

```
Controller Status:   48/48 healthy
  Name                                   Last success   Last error   Count   Message
  bpf-map-sync-cilium_lxc                4s ago         never        0       no error
  cilium-health-ep                       48s ago        never        0       no error
  endpoint-2438-regeneration-recovery    never          never        0       no error
  ipcache-inject-labels                  1m2s ago       never        0       no error
  k8s-heartbeat                          9s ago         never        0       no error
  resolve-identity-2438                  1m5s ago       never        0       no error
  sync-lb-maps-with-k8s-services         2m1s ago       never        0       no error
  template-dir-watcher                   never          never        0       no error
```

4. Inspect the agent container's privileges and mounts — these explain *why* it can do what it does:

```bash
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | python3 -m json.tool
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' | tr ' ' '\n'
```

```
/host/proc/sys/net
/host/proc/sys/kernel
/sys/fs/bpf
/var/run/cilium
/host/etc/cni/net.d
/host/opt/cni/bin
/run/xtables.lock
/var/lib/cilium/tls/hubble
...
```

5. Find the init containers — the agent pod does real work before the agent starts:

```bash
kubectl -n kube-system get ds cilium -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}{"\n"}{end}'
```

```
config
mount-cgroup
apply-sysctl-overwrites
mount-bpf-fs
clean-cilium-state
install-cni-binaries
```

### Checkpoint questions — Block 1

- **Q1.1** — `Modules Health: OK(52)` and `Controller Status: 48/48 healthy` are two different health systems. What does each one cover, and which one would you look at first if pods on this node suddenly stopped getting new policy?
- **Q1.2** — `Proxy Status: ... Envoy: external`. What would this field say on a cluster installed with `envoy.enabled=false`, and what is the concrete operational consequence of the two modes differing?
- **Q1.3** — IPAM reports `10.244.1.148 (router)`. What interface holds that address, what is its role in the datapath, and why is it allocated out of the *pod* CIDR rather than the node CIDR?
- **Q1.4** — The `mount-bpf-fs` init container mounts a BPF filesystem at `/sys/fs/bpf` **in the host namespace**, not just the pod's. Why is a host-namespace mount mandatory for correct agent restarts?
- **Q1.5** — `clean-cilium-state` normally does nothing. Name the two Helm/env settings that arm it, and describe the blast radius of arming the destructive one on a production node.
- **Q1.6** — `Attach Mode: TCX` and `Device Mode: veth`. What does TCX replace, what kernel version introduced it, and what does Cilium fall back to on an older kernel?

---

## Exercise 2 — Endpoints: the unit Cilium actually manages

Kubernetes thinks in Pods. Cilium thinks in **endpoints**. The mapping is not one-to-one.

1. Deploy a workload spread across both workers:

```bash
kubectl create deployment nginx --image=nginx:1.27-alpine --replicas=4
kubectl create deployment client --image=nicolaka/netshoot --replicas=2 -- sleep infinity
kubectl rollout status deploy/nginx
kubectl get pods -o wide
```

2. List endpoints on one node:

```bash
cdbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                        IPv4           STATUS
           ENFORCEMENT        ENFORCEMENT
159        Disabled           Disabled          4          reserved:health                                    10.244.1.104   ready
912        Disabled           Disabled          1          k8s:node.kubernetes.io/exclude-from-external-lb
                                                           reserved:host                                                     ready
2438       Disabled           Disabled          14584      k8s:app=nginx
                                                           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
                                                           k8s:io.cilium.k8s.policy.cluster=default
                                                           k8s:io.cilium.k8s.policy.serviceaccount=default
                                                           k8s:io.kubernetes.pod.namespace=default          10.244.1.29    ready
3117       Disabled           Disabled          61203      k8s:app=client
                                                           ...                                              10.244.1.212   ready
```

3. Drill into a single endpoint's full model:

```bash
cdbg endpoint get 2438 | python3 -m json.tool | head -60
cdbg endpoint log 2438
```

```
Timestamp                Code    Type      Message
2026-09-01T12:03:58Z     OK      Ready     Successfully regenerated endpoint program (Reason: updated security labels)
2026-09-01T12:03:58Z     OK      Waiting-to-regenerate  Triggering endpoint regeneration due to policy updates
2026-09-01T12:03:57Z     OK      Ready     Successfully regenerated endpoint program (Reason: Initial build)
2026-09-01T12:03:56Z     OK      Waiting-for-identity   Waiting for endpoint to obtain a security identity
```

4. Correlate the endpoint with its Kubernetes-visible mirror:

```bash
kubectl get ciliumendpoints.cilium.io -A -o wide
kubectl get ciliumendpoint -n default -o jsonpath='{.items[0].status.identity.id}{"\n"}'
```

5. Find the host side of the pod's veth pair and the BPF programs attached to it:

```bash
cdbg endpoint get 2438 -o jsonpath='{[0].status.networking.host-interface-name}'
# then, on the node (docker exec into the kind node):
docker exec -it cca-lab-worker bash -c 'ip -d link show type veth | grep -A2 lxc'
docker exec -it cca-lab-worker bpftool net show dev lxc1a2b3c4d5e6f
```

```
tc:
lxc1a2b3c4d5e6f(12) tcx/ingress cil_from_container prog_id 412
lxc1a2b3c4d5e6f(12) tcx/egress  cil_to_container   prog_id 418
```

6. Force a regeneration and watch the state machine move:

```bash
kubectl label pod -l app=nginx tier=frontend --overwrite
cdbg endpoint list | grep nginx -A1
cdbg endpoint log 2438 | head -5
```

### Checkpoint questions — Block 2

- **Q2.1** — Endpoint `912` has identity `1` and **no IPv4 address** in the listing, yet it is a fully managed endpoint. What is it, and what breaks if you write a policy that forgets it exists?
- **Q2.2** — Endpoint `159` carries `reserved:health` and a real pod IP, but `kubectl get pods -A` shows no such pod. Where does it come from and what is it used for?
- **Q2.3** — Two of the four nginx replicas landed on this node, but `cilium-dbg endpoint list` shows them sharing a single identity `14584`. Explain the relationship between *endpoint count* and *identity count*, and give the formula that determines when a new identity is minted.
- **Q2.4** — Compare `cilium-dbg endpoint list` (agent) with `kubectl get ciliumendpoints` (API server). Which is authoritative for the datapath, which is authoritative for cluster-wide observability, and what happens to each when the API server is unreachable for 10 minutes?
- **Q2.5** — In step 5, ingress on the **host side** of the veth is named `cil_from_container`. From whose perspective is "from container" written, and why does traffic *leaving the pod* hit a program attached to *ingress*?
- **Q2.6** — You added a label in step 6. Trace the causal chain from `kubectl label` to a new eBPF program byte-array being loaded. Name at least four intermediate stages.

---

## Exercise 3 — Identities, labels and the ipcache

This is the core abstraction of Cilium and a reliable source of exam questions.

1. List every identity the cluster knows:

```bash
cdbg identity list
```

```
ID       LABELS
1        reserved:host
2        reserved:world
3        reserved:unmanaged
4        reserved:health
5        reserved:init
6        reserved:remote-node
7        reserved:kube-apiserver
8        reserved:ingress
14584    k8s:app=nginx
         k8s:io.cilium.k8s.policy.cluster=default
         k8s:io.cilium.k8s.policy.serviceaccount=default
         k8s:io.kubernetes.pod.namespace=default
61203    k8s:app=client
         ...
```

2. See how identities are *stored* in this installation:

```bash
cdbg status | grep -i kvstore
kubectl get ciliumidentities.cilium.io
kubectl get ciliumidentity 14584 -o yaml | yq '.security-labels'
```

3. Read the ipcache — the map that answers "which identity owns this IP, and where does it live?":

```bash
cdbg bpf ipcache list | head -20
```

```
IP PREFIX/ADDRESS    IDENTITY
0.0.0.0/0            identity=2     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
10.244.0.0/24        identity=6     encryptkey=0 tunnelendpoint=172.18.0.2  flags=<none>
10.244.0.145/32      identity=14584 encryptkey=0 tunnelendpoint=172.18.0.4  flags=<none>
10.244.1.29/32       identity=14584 encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
10.244.1.104/32      identity=4     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.2/32        identity=7     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.3/32        identity=1     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.4/32        identity=6     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
```

4. Make Cilium mint a **local** identity by writing a CIDR-based policy:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-example-net
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: client
  egress:
    - toCIDR:
        - 93.184.216.0/24
EOF

cdbg identity list | tail -5
cdbg bpf ipcache list | grep 93.184
```

```
16777217   cidr:93.184.216.0/24
           reserved:world
```

5. Observe an identity being used in a live policy verdict:

```bash
cdbg monitor -t policy-verdict --related-to 3117
# in another terminal:
kubectl exec deploy/client -- curl -s -o /dev/null -w '%{http_code}\n' http://nginx
```

```
Policy verdict log: flow 0x8c1d2e3f local EP ID 3117, remote ID 14584, proto 6, egress, action allow, auth: disabled, match L3-Only, 10.244.1.212:54322 -> 10.244.1.29:80 tcp SYN
```

### Checkpoint questions — Block 3

- **Q3.1** — Identity `14584` was reported on *both* workers for pods with the same labels. Which component guarantees that agreement, and what would go wrong in a policy sense if two nodes independently chose different numbers for the same label set?
- **Q3.2** — Identity `16777217` sits far outside the `min 256, max 65535` global range reported by `cilium-dbg status`. What class of identity is it, why is it allocated from a different range, and is the *same* number guaranteed to mean the same thing on the other worker?
- **Q3.3** — The ipcache entry for `10.244.0.145/32` has `tunnelendpoint=172.18.0.4`, while `10.244.1.29/32` has `tunnelendpoint=0.0.0.0`. Explain both, and predict what the `tunnelendpoint` column looks like across the board if you reinstall with `routingMode=native`.
- **Q3.4** — `172.18.0.2/32` resolved to identity `7` (`reserved:kube-apiserver`) while the other node IPs resolved to `6` (`reserved:remote-node`). What produced that distinction, and why does it matter for writing a policy that allows pods to talk to the API server?
- **Q3.5** — Identity `2` (`reserved:world`) is bound to `0.0.0.0/0`. When Cilium also runs `reserved:world-ipv4` (9) and `reserved:world-ipv6` (10), what changed and why?
- **Q3.6** — A pod is deleted and its labels vanish. Which component removes the now-unreferenced `CiliumIdentity` object, on what trigger, and what is the failure symptom if that component is down for a week in a high-churn cluster?

---

## Exercise 4 — `cilium-operator`: the cluster-scoped half

The operator is easy to under-appreciate because nothing breaks the second it dies.

1. Read its arguments — they are a literal list of its responsibilities:

```bash
kubectl -n kube-system get deploy cilium-operator \
  -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n'
kubectl -n kube-system logs deploy/cilium-operator | head -40
```

```
level=info msg="Cilium Operator 1.17.4"
level=info msg="Leading the operator HA deployment" subsys=cilium-operator-generic
level=info msg="Starting apiserver on address :9234" subsys=cilium-operator-generic
level=info msg="Starting CNP derivative handler" subsys=cilium-operator-generic
level=info msg="Starting to synchronize CiliumNode custom resources" subsys=cilium-operator-generic
level=info msg="Starting CiliumEndpointSlice controller" subsys=cilium-operator-generic
level=info msg="Garbage collecting stale CiliumEndpoint custom resources" subsys=cilium-operator-generic
```

2. Inspect the resource the operator writes and every agent reads:

```bash
kubectl get ciliumnodes.cilium.io -o custom-columns=\
'NODE:.metadata.name,CIDR:.spec.ipam.podCIDRs,ROUTER:.spec.addresses[?(@.type=="CiliumInternalIP")].ip'
kubectl get ciliumnode cca-lab-worker -o yaml | yq '.spec.ipam' | head -20
```

```
NODE                    CIDR                ROUTER
cca-lab-control-plane   [10.244.0.0/24]     10.244.0.87
cca-lab-worker          [10.244.1.0/24]     10.244.1.148
cca-lab-worker2         [10.244.2.0/24]     10.244.2.63
```

3. Prove the failure domain. Scale the operator to zero and test three different operations:

```bash
kubectl -n kube-system scale deploy/cilium-operator --replicas=0

# (a) existing traffic
kubectl exec deploy/client -- curl -s -o /dev/null -w 'existing-traffic:%{http_code}\n' http://nginx

# (b) a new pod on an existing node
kubectl create deployment probe --image=nginx:1.27-alpine
kubectl rollout status deploy/probe --timeout=60s

# (c) identity churn
kubectl delete deploy probe
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
sleep 120
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
```

4. Restore it and watch the reconciliation:

```bash
kubectl -n kube-system scale deploy/cilium-operator --replicas=1
kubectl -n kube-system logs deploy/cilium-operator | grep -i 'garbage\|deleted'
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
```

5. Examine the alternative endpoint-scaling path:

```bash
kubectl get crd ciliumendpointslices.cilium.io
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-cilium-endpoint-slice}{"\n"}'
```

### Checkpoint questions — Block 4

- **Q4.1** — In step 3, which of (a), (b) and (c) actually degraded? Explain each result in terms of *who* performs the work.
- **Q4.2** — You add a brand-new node to the cluster while the operator is scaled to zero, in `ipam.mode=cluster-pool`. What is the precise symptom on that node, and which field stays empty?
- **Q4.3** — Now answer Q4.2 again for `ipam.mode=kubernetes`. Why does the answer change, and what is the trade-off between the two modes?
- **Q4.4** — The operator supports `operator.replicas=2` with leader election, while `cilium-agent` has no such concept. Justify both designs from first principles.
- **Q4.5** — In a 5,000-node cluster with 100,000 pods, what is the API-server load problem with one `CiliumEndpoint` per pod, and how does `CiliumEndpointSlice` change the arithmetic? Which component produces the slices?
- **Q4.6** — Name three operator jobs that only exist when a specific feature is enabled (i.e. they are absent in this minimal install).

---

## Exercise 5 — The CNI plugin and the pod-attach path

1. Find the plugin binary and the config, both placed on the host by the agent pod:

```bash
docker exec cca-lab-worker ls -l /opt/cni/bin/ /etc/cni/net.d/
docker exec cca-lab-worker cat /etc/cni/net.d/05-cilium.conflist
```

```json
{
  "cniVersion": "1.0.0",
  "name": "cilium",
  "plugins": [
    {
      "type": "cilium-cni",
      "enable-debug": false,
      "log-file": "/var/run/cilium/cilium-cni.log"
    }
  ]
}
```

2. Watch a pod attach end to end. Open the CNI log first, then create a pod:

```bash
# terminal 1
docker exec cca-lab-worker tail -f /var/run/cilium/cilium-cni.log
# terminal 2
kubectl run cnitest --image=nginx:1.27-alpine --overrides='{"spec":{"nodeName":"cca-lab-worker"}}'
```

```
level=info msg="Processing CNI ADD request" containerID=9f3c... eventUUID=...
level=info msg="Endpoint successfully created" endpointID=1204 containerID=9f3c...
```

3. Confirm the agent's local API socket is the transport:

```bash
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- ls -l /var/run/cilium/
```

```
srw-rw---- 1 root root  0 Sep  1 12:03 cilium.sock
srw-rw---- 1 root root  0 Sep  1 12:03 health.sock
srw-rw---- 1 root root  0 Sep  1 12:03 hubble.sock
drwxr-xr-x 3 root root 60 Sep  1 12:03 state
```

4. Now break it deliberately. Delete the agent on that node and try to create a pod:

```bash
kubectl -n kube-system delete pod $(basename $CILIUM_POD) --wait=false
kubectl -n kube-system patch ds cilium -p '{"spec":{"template":{"spec":{"nodeSelector":{"disabled":"true"}}}}}'
kubectl -n kube-system get pods -o wide | grep cilium

# existing pods:
kubectl exec deploy/client -- curl -s -o /dev/null -w 'existing:%{http_code}\n' http://nginx
# new pod on the agent-less node:
kubectl run orphan --image=nginx:1.27-alpine --overrides='{"spec":{"nodeName":"cca-lab-worker"}}'
kubectl describe pod orphan | tail -8
```

```
Warning  FailedCreatePodSandBox  8s  kubelet  Failed to create pod sandbox: plugin type="cilium-cni"
failed (add): unable to connect to Cilium daemon: failed to create cilium agent client after 30.000000
seconds timeout: Get "http://localhost/v1/config": dial unix /var/run/cilium/cilium.sock: connect:
no such file or directory
```

5. Restore:

```bash
kubectl -n kube-system patch ds cilium --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/disabled"}]'
kubectl -n kube-system rollout status ds/cilium
kubectl delete pod orphan cnitest --ignore-not-found
```

### Checkpoint questions — Block 5

- **Q5.1** — In step 4, existing pods kept serving traffic while new pods could not be created. Explain both halves in terms of where forwarding state lives versus where the control plane lives.
- **Q5.2** — `cilium-cni` is a short-lived process invoked by the container runtime, not a daemon. What are the two things it must do that require the agent, and why is *not* embedding that logic in the plugin the right design?
- **Q5.3** — The file is named `05-cilium.conflist`. What is the significance of the numeric prefix, and what is the failure mode if a second CNI leaves a `00-something.conflist` behind?
- **Q5.4** — Distinguish **CNI chaining** (`cni.chainingMode=aws-cni` / `generic-veth`) from the standalone mode you are running. What does `cilium-dbg status` show in each case, and which Cilium features are unavailable when chained?
- **Q5.5** — A node reboots. Between kernel boot and `cilium-agent` becoming ready, kubelet may try to start pods. Which two mechanisms prevent pods coming up with broken networking?

---

## Exercise 6 — The eBPF datapath: programs and maps

1. Enumerate the pinned maps. This is Cilium's entire forwarding state:

```bash
docker exec cca-lab-worker ls /sys/fs/bpf/tc/globals/
cdbg map list --verbose | head -40
```

```
Name                       Num entries   Num errors   Cache enabled
cilium_lxc                 4             0            true
cilium_ipcache_v2          21            0            true
cilium_policy_v2_02438     3             0            true
cilium_lb4_services_v2     14            0            true
cilium_lb4_backends_v3     9             0            true
cilium_lb4_reverse_nat     7             0            true
cilium_ct4_global          312           0            false
cilium_ct_any4_global      44            0            false
cilium_snat_v4_external    18            0            false
cilium_tunnel_map          2             0            true
cilium_metrics             6             0            false
cilium_node_map            3             0            true
cilium_runtime_config      1             0            false
```

2. Read three of them by hand:

```bash
cdbg bpf endpoint list      # cilium_lxc: local IP -> endpoint metadata
cdbg bpf tunnel list        # cilium_tunnel_map: remote pod CIDR -> node underlay IP
cdbg bpf ct list global | head -10
```

```
IP ADDRESS       LOCAL ENDPOINT INFO
10.244.1.29:0    id=2438  sec_id=14584  flags=0x0000 ifindex=12  mac=1A:2B:3C:4D:5E:6F  nodemac=AE:BF:C0:D1:E2:F3

TUNNEL           VALUE
10.244.0.0/24    172.18.0.2
10.244.2.0/24    172.18.0.4

TCP OUT 10.244.1.212:54322 -> 10.244.1.29:80 expires=17284 RxPackets=6 TxPackets=5 Flags=0x0013 ...
```

3. See the programs, not just the maps:

```bash
docker exec cca-lab-worker bpftool prog show | grep -c 'sched_cls\|cgroup'
docker exec cca-lab-worker bpftool net show | head -20
```

```
tc:
eth0(2)     tcx/ingress cil_from_netdev  prog_id 388
eth0(2)     tcx/egress  cil_to_netdev    prog_id 391
cilium_host(9)  tcx/ingress cil_to_host  prog_id 372
cilium_net(8)   tcx/ingress cil_from_host prog_id 366
cilium_vxlan(10) tcx/ingress cil_from_overlay prog_id 379
lxc1a2b3c4d5e6f(12) tcx/ingress cil_from_container prog_id 412

cgroup:
/run/cilium/cgroupv2  connect4  cil_sock4_connect  prog_id 340
/run/cilium/cgroupv2  sendmsg4  cil_sock4_sendmsg  prog_id 344
```

4. Map every interface you just saw:

```bash
docker exec cca-lab-worker ip -br addr show
docker exec cca-lab-worker ip route show
```

```
lo               UNKNOWN  127.0.0.1/8
eth0             UP       172.18.0.3/16
cilium_net@cilium_host  UP
cilium_host@cilium_net  UP  10.244.1.148/32
cilium_vxlan     UNKNOWN
lxc_health@if11  UP
lxc1a2b3c4d5e6f@if3  UP
```

5. Verify the persistence property that makes agent restarts non-disruptive:

```bash
docker exec cca-lab-worker stat -c '%i %n' /sys/fs/bpf/tc/globals/cilium_lxc
kubectl -n kube-system delete pod $(basename $CILIUM_POD)
sleep 5
# during the restart window, from another pod:
kubectl exec deploy/client -- curl -s -o /dev/null -w 'during-restart:%{http_code}\n' http://nginx
kubectl -n kube-system rollout status ds/cilium
docker exec cca-lab-worker stat -c '%i %n' /sys/fs/bpf/tc/globals/cilium_lxc
```

6. Look at what the agent kept on disk to make that possible:

```bash
docker exec cca-lab-worker ls /var/run/cilium/state/
docker exec cca-lab-worker ls /var/run/cilium/state/2438/
```

```
2438/  3117/  159/  912/  globals/  templates/
ep_config.h  lxc_config.h  bpf_lxc.o
```

### Checkpoint questions — Block 6

- **Q6.1** — `cilium_ct4_global` shows `Cache enabled: false` while `cilium_lxc` shows `true`. What does the agent's userspace cache do, and why is conntrack excluded?
- **Q6.2** — There are programs on `cilium_host`, `cilium_net`, `eth0`, `cilium_vxlan` and each `lxc*`. Trace a packet from `client` on worker to `nginx` on worker2, naming each program it traverses in order, and state where the VXLAN encapsulation happens.
- **Q6.3** — Two programs are attached to a **cgroup**, not to `tc`: `cil_sock4_connect` and `cil_sock4_sendmsg`. What feature are they implementing, what does it do to the packet path, and what is the observable side-effect inside the pod when you run `tcpdump`?
- **Q6.4** — In step 5 the inode of `cilium_lxc` was identical before and after the agent restart, and traffic never broke. Explain the mechanism precisely, and name the one configuration change that *would* have caused a datapath interruption on restart.
- **Q6.5** — `/var/run/cilium/state/2438/` contains `lxc_config.h` and a compiled `bpf_lxc.o`. What is Cilium doing at endpoint-regeneration time that these files are the artifacts of, and how does the `templates/` directory reduce that cost?
- **Q6.6** — `cilium_host` holds `10.244.1.148/32` — the router IP — and `cilium_net` holds nothing. Why is this a veth *pair* rather than a single dummy interface?

---

## Exercise 7 — kube-proxy replacement: services in BPF

1. Confirm what mode you are in and on which devices:

```bash
cdbg status --verbose | grep -A3 KubeProxyReplacement
docker exec cca-lab-worker iptables-save | grep -c KUBE-SVC || echo "0 kube-proxy chains"
```

2. Create a service and find it in the BPF LB maps:

```bash
kubectl expose deploy/nginx --port=80 --name=nginx
kubectl expose deploy/nginx --port=80 --name=nginx-np --type=NodePort
kubectl get svc

cdbg service list
cdbg bpf lb list
```

```
ID   Frontend             Service Type   Backend
1    10.96.0.1:443/TCP    ClusterIP      1 => 172.18.0.2:6443/TCP (active)
3    10.96.0.10:53/UDP    ClusterIP      1 => 10.244.0.87:53/UDP (active)
                                         2 => 10.244.2.19:53/UDP (active)
9    10.101.44.7:80/TCP   ClusterIP      1 => 10.244.1.29:80/TCP (active)
                                         2 => 10.244.2.55:80/TCP (active)
                                         ...
10   0.0.0.0:31654/TCP    NodePort       1 => 10.244.1.29:80/TCP (active)
                                         ...
11   172.18.0.3:31654/TCP NodePort       ...
```

3. Prove where the translation happens for a pod-originated connection:

```bash
kubectl exec -it deploy/client -- bash -c \
  'timeout 5 tcpdump -ni any -c 4 "tcp port 80" & sleep 1; curl -s -o /dev/null http://nginx; wait'
```

4. Compare with a connection that enters from outside the node:

```bash
NODE_IP=$(docker inspect cca-lab-worker -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
curl -s -o /dev/null -w '%{http_code}\n' http://$NODE_IP:31654
cdbg bpf lb list --revnat
cdbg bpf nat list | head -5
```

5. Look at the socket-level map and the maglev/affinity structures:

```bash
cdbg map get cilium_lb4_reverse_sk 2>/dev/null | head -5
cdbg bpf lb maglev list 2>/dev/null || echo "maglev not enabled (default: random)"
```

### Checkpoint questions — Block 7

- **Q7.1** — In step 3, `tcpdump` inside the client pod showed the destination as a **pod IP**, not the ClusterIP. Which eBPF program made that substitution, at which hook, and what is the performance consequence versus DNAT at `tc` level?
- **Q7.2** — A NodePort connection arriving on `eth0` cannot use the socket hook. Where is it translated instead, and which map provides the un-translation on the reply path?
- **Q7.3** — `cilium-dbg service list` and `cilium-dbg bpf lb list` present overlapping data. Which is the userspace view and which is the kernel view, and what does a discrepancy between them tell you?
- **Q7.4** — `kubeProxyReplacement=true` versus `false` with `nodePort.enabled=true`: describe what each does, and name one thing that only full replacement gives you.
- **Q7.5** — Explain why `k8sServiceHost`/`k8sServicePort` become **mandatory** in full replacement mode on a cluster with no kube-proxy, and what happens if you point them at a ClusterIP.
- **Q7.6** — Service backend selection defaults to `random`. Name the alternative, the map it populates, and the scenario in which the alternative is strictly better.

---

## Exercise 8 — Hubble: the observability plane

Hubble is not a separate agent. Understanding *where* it runs is the exam point.

1. Locate the Hubble server:

```bash
cdbg status | grep -i hubble
kubectl -n kube-system get ds cilium -o yaml | grep -A2 'name: hubble'
kubectl -n kube-system get svc hubble-peer hubble-relay
```

```
Hubble:   Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 11.72

NAME           TYPE        CLUSTER-IP       PORT(S)
hubble-peer    ClusterIP   10.96.201.14     443/TCP
hubble-relay   ClusterIP   10.99.7.60       80/TCP
```

2. Query flows from **one node only**, using the agent's local socket:

```bash
kubectl -n kube-system exec -it $CILIUM_POD -c cilium-agent -- \
  hubble observe --server unix:///var/run/cilium/hubble.sock --last 5
```

```
Sep  1 12:22:41.115: default/client-7f9d-abc:54322 (ID:61203) -> default/nginx-6f8c-xyz:80 (ID:14584) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:22:41.115: default/nginx-6f8c-xyz:80 (ID:14584) <- default/client-7f9d-abc:54322 (ID:61203) to-stack FORWARDED (TCP Flags: SYN, ACK)
```

3. Query flows from the **whole cluster** through Relay:

```bash
cilium hubble port-forward &
hubble status
hubble observe --namespace default --last 20
hubble observe --namespace default --type drop
```

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,285/12,285 (100.00%)
Flows/s: 34.19
Connected Nodes: 3/3
```

4. Make Relay's dependency explicit — cut one node's agent and re-check:

```bash
kubectl -n kube-system delete pod $(basename $CILIUM_POD)
hubble status
```

```
Connected Nodes: 2/3
Unavailable Nodes: 1
  cca-lab-worker: rpc error: code = Unavailable desc = connection error
```

5. Inspect how Relay discovers agents:

```bash
kubectl -n kube-system get svc hubble-peer -o yaml | yq '.spec'
kubectl -n kube-system logs deploy/hubble-relay | grep -i peer | head -5
```

6. Enable metrics and see who exposes them:

```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-metrics}{"\n"}'
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].ports}' \
  | python3 -m json.tool
```

### Checkpoint questions — Block 8

- **Q8.1** — `Current/Max Flows: 4095/4095 (100.00%)` looks like a saturation alarm. What is it actually reporting, and what is the data structure behind it?
- **Q8.2** — Draw the query path for `hubble observe --namespace default` run from your laptop. Name every process and port hop, and state which of them is stateless.
- **Q8.3** — In step 4, Relay reported `2/3` while the agent restarted, but the two surviving nodes kept answering. What is the availability model, and were the missing node's *historical* flows recoverable after it came back?
- **Q8.4** — `hubble-peer` is a Service with no Deployment behind it. What does it select, why is a dedicated Service needed at all, and what would break if you deleted it?
- **Q8.5** — Hubble flows are derived from a perf ring buffer written by the datapath. Name the map and explain the sampling/loss characteristic that makes Hubble unsuitable as a billing or audit-of-record source.
- **Q8.6** — Where do Hubble *metrics* come from — Relay or the agents — and what is the cardinality risk of enabling `hubble-metrics: "flow:sourceContext=pod;destinationContext=pod"` in a large cluster?

---

## Exercise 9 — The L7 proxy: `cilium-envoy`

1. Establish the deployment shape:

```bash
kubectl -n kube-system get ds cilium-envoy -o wide
kubectl -n kube-system get cm cilium-envoy-config -o yaml | head -30
cdbg status --verbose | grep -i 'proxy status'
```

2. Apply an L7 policy and watch a redirect appear:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-http
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: nginx
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
                path: "/$"
EOF

cdbg status | grep -i 'proxy status'
cdbg bpf proxy list
```

```
Proxy Status:   OK, ip 10.244.1.148, 1 redirects active on ports 10000-20000, Envoy: external
```

3. Generate an allowed and a denied request and read the L7 verdict:

```bash
kubectl exec deploy/client -- curl -s -o /dev/null -w 'GET /   -> %{http_code}\n' http://nginx/
kubectl exec deploy/client -- curl -s -o /dev/null -w 'POST /  -> %{http_code}\n' -X POST http://nginx/
hubble observe --namespace default --protocol http --last 5
```

```
Sep  1 12:31:02.771: default/client-...:41002 -> default/nginx-...:80 http-request FORWARDED (HTTP/1.1 GET http://nginx/)
Sep  1 12:31:03.118: default/client-...:41004 -> default/nginx-...:80 http-request DROPPED (HTTP/1.1 POST http://nginx/)
```

4. Inspect Envoy's own view:

```bash
cdbg envoy admin listeners 2>/dev/null | head -20 \
  || kubectl -n kube-system exec ds/cilium-envoy -- \
       curl -s --unix-socket /var/run/cilium/envoy/sockets/admin.sock http://admin/listeners | head -20
```

5. Look at the CRD that lets you drive Envoy directly:

```bash
kubectl get crd ciliumenvoyconfigs.cilium.io ciliumclusterwideenvoyconfigs.cilium.io
kubectl explain ciliumenvoyconfig.spec --recursive | head -20
```

### Checkpoint questions — Block 9

- **Q9.1** — Before the L7 policy, `Proxy Status` reported `0 redirects`. What exactly is a "redirect" here, which map holds it, and what does the datapath do differently for a packet matching one?
- **Q9.2** — The POST was `DROPPED` at `http-request`, not at `to-endpoint`. Which component made that decision, and at which point in the path relative to the eBPF policy map?
- **Q9.3** — Since Cilium 1.16 the default is a standalone `cilium-envoy` DaemonSet rather than Envoy embedded in the agent process. Give two concrete operational advantages, and one new failure mode this introduces.
- **Q9.4** — An L7 policy costs measurably more than an L3/L4 one. Explain the mechanical reason, and state what happens to *non-matching* traffic on the same endpoint.
- **Q9.5** — What is `CiliumEnvoyConfig` for, and name two built-in Cilium features that are implemented on top of it rather than by bespoke code.
- **Q9.6** — If `cilium-envoy` is unavailable on a node where an L7 policy is in force, what happens to the affected traffic — fail-open or fail-closed? Justify from the redirect mechanism.

---

## Exercise 10 — Cluster health, and a full diagnostic sweep

1. Read Cilium's own node-to-node health mesh:

```bash
cdbg status --all-health | head -30
```

```
Cluster health:                   3/3 reachable   (2026-09-01T12:35:00Z)
Name                              IP              Node        Endpoints
cca-lab/cca-lab-worker (localhost)
  Host connectivity to 172.18.0.3:
    ICMP to stack:   OK, RTT=241.9µs
    HTTP to agent:   OK, RTT=189.4µs
  Endpoint connectivity to 10.244.1.104:
    ICMP to stack:   OK, RTT=255.1µs
    HTTP to agent:   OK, RTT=203.7µs
cca-lab/cca-lab-worker2
  Host connectivity to 172.18.0.4:
    ICMP to stack:   OK, RTT=612.3µs
    HTTP to agent:   OK, RTT=744.0µs
  Endpoint connectivity to 10.244.2.63:
    ICMP to stack:   OK, RTT=655.8µs
    HTTP to agent:   OK, RTT=781.2µs
```

2. Run the packaged end-to-end suite:

```bash
cilium connectivity test --test-concurrency 2
```

3. Collect a support bundle and read its structure — this is what you attach to a bug report:

```bash
cilium sysdump --output-filename cca-sysdump
mkdir -p /tmp/sd && tar xzf cca-sysdump.zip -C /tmp/sd 2>/dev/null || unzip -q cca-sysdump.zip -d /tmp/sd
find /tmp/sd -maxdepth 2 -type d | head -20
```

4. Do a targeted drop investigation:

```bash
cdbg monitor -t drop --numeric &
kubectl exec deploy/client -- curl -s --max-time 3 -X POST http://nginx/ || true
cdbg metrics list | grep -i drop
```

```
xx drop (Policy denied) flow 0x0 to endpoint 2438, ID 61203->14584, identity 61203->14584: 10.244.1.212:41008 -> 10.244.1.29:80 tcp SYN
```

5. Clean up:

```bash
kubectl delete cnp l7-http allow-example-net --ignore-not-found
kubectl delete deploy nginx client --ignore-not-found
kubectl delete svc nginx nginx-np --ignore-not-found
kind delete cluster --name cca-lab
```

### Checkpoint questions — Block 10

- **Q10.1** — Health probes report both "Host connectivity" and "Endpoint connectivity" for every node. Why two? What does it mean if host is OK and endpoint is not?
- **Q10.2** — Which endpoint sources the "Endpoint connectivity" probes, and which reserved identity does it carry? What does that imply for a `default-deny` cluster-wide policy?
- **Q10.3** — `cilium sysdump` gathers data from every component. Name four artifact classes it collects that you could **not** reconstruct after the fact from a running cluster.
- **Q10.4** — You see `Policy denied` drops with `identity 61203->14584`. List, in order, the three commands you would run to turn those numbers into a root cause.
- **Q10.5** — Rank these five components by blast radius if a single instance fails: `cilium-agent`, `cilium-operator`, `cilium-envoy`, `hubble-relay`, `hubble-ui`. For each, state what stops working *immediately* versus *eventually*.

---

<details>
<summary><strong>Answers — expand only after attempting all blocks</strong></summary>

### Block 0

**A0.1** — Without kube-proxy nothing programs `10.96.0.1:443`, and Cilium is the thing that *would* program it — but it needs the API server first. The break is that `cilium-agent` is told the API server's **real address** directly, bypassing service resolution: `k8sServiceHost=cca-lab-control-plane` and `k8sServicePort=6443`. The agent connects to that endpoint, learns the cluster state, and only then installs the ClusterIP entry that everything else uses. Equivalently you can use `k8sServiceHost=auto` on newer releases, or a `KUBERNETES_SERVICE_HOST` env var. Pointing these at a ClusterIP is a boot deadlock.

**A0.2** —
| Workload | Placement | Object kind |
|---|---|---|
| `cilium` (agent) | per-node | DaemonSet |
| `cilium-envoy` | per-node | DaemonSet |
| `cilium-operator` | cluster-singleton (HA-capable, leader-elected) | Deployment |
| `hubble-relay` | cluster-singleton | Deployment |
| `hubble-ui` | cluster-singleton | Deployment |

The rule: anything that touches a node's kernel datapath must be a DaemonSet; anything that reconciles cluster-scoped state or aggregates is a Deployment.

**A0.3** — `cilium-agent` — specifically its `install-cni-binaries` init container plus the agent writing `/etc/cni/net.d/05-cilium.conflist`. kubelet's CRI implementation polls `/etc/cni/net.d`; a node with no valid CNI config reports `NetworkPluginNotReady` and stays `NotReady`, which is why CoreDNS was unschedulable. The interface is **CNI** (Container Network Interface), invoked by the container runtime, not by Cilium.

**A0.4** — Two audiences:
- `cilium` (**cilium-cli**) runs on your workstation, speaks to the **Kubernetes API**, and does cluster-level operations: install, upgrade, `status`, `connectivity test`, `sysdump`, `hubble port-forward`.
- `cilium-dbg` runs **inside the agent pod**, speaks to the agent's local unix socket `/var/run/cilium/cilium.sock`, and inspects **one node's** datapath: endpoints, identities, BPF maps, monitor.

Before Cilium **1.16** the in-pod binary was also called `cilium`, which made every piece of documentation ambiguous. It was renamed to `cilium-dbg`; a deprecated `cilium` shim remains in the image for compatibility.

---

### Block 1

**A1.1** — They are different generations of the same idea.
- **Controllers** are the long-standing per-task retry loops (`resolve-identity-2438`, `sync-lb-maps-with-k8s-services`, `bpf-map-sync-*`). Each has a last-success timestamp, a last-error, and a consecutive-failure count.
- **Modules Health** is the newer Hive/cell dependency-injection framework's status tree, reporting each *module* as OK / Degraded / Stopped.

For "policy stopped updating on this node", go to **controllers first**: `cilium-dbg status --all-controllers` will show a specific loop with a rising `Count` and a `Last error`, which names the failing operation. Modules Health tells you a subsystem is unhappy; controllers tell you which job and why.

**A1.2** — With `envoy.enabled=false` it reads `Envoy: embedded`. Envoy then runs as a thread group *inside the `cilium-agent` process*.
Consequence: **restarting the agent restarts Envoy**, so every L7-proxied connection is torn down on any agent upgrade, config change or crash — and the agent's memory footprint includes Envoy's. With `Envoy: external`, the `cilium-envoy` DaemonSet has its own lifecycle: you can restart the agent without dropping L7 connections, and you can upgrade Envoy for a CVE without touching the datapath.

**A1.3** — It is on **`cilium_host`**, the host end of the `cilium_host`/`cilium_net` veth pair. It is the node's *cilium internal IP* / router IP: the next hop for traffic entering the Cilium datapath from the host stack, the source address used by the L7 proxy, and the address other nodes see as this node's in-cluster gateway.
It comes from the pod CIDR because it must be routable **inside** the pod network — it is a first-class participant in it, not a node-network address. It is registered on the `CiliumNode` object as `CiliumInternalIP` so remote agents can learn it.

**A1.4** — Because BPF maps and programs must **outlive the agent process**. Pinning in a bpffs that lives in the host mount namespace means the map file descriptors survive `cilium-agent` exiting; on restart the agent re-opens the pinned paths and reuses the existing maps instead of creating empty ones. If bpffs were mounted only in the pod's mount namespace, it would vanish when the pod is deleted, all maps would be recreated empty, and every agent restart would blackhole traffic until every endpoint regenerated.

**A1.5** — `cleanState` variants:
- `cilium.cleanState` / env `CLEAN_CILIUM_STATE=true` — the **destructive** one: unloads BPF programs, deletes pinned maps, removes the `cilium_host`/`cilium_net`/`cilium_vxlan` interfaces and wipes `/var/run/cilium/state`.
- `cilium.cleanBpfState` / `CLEAN_CILIUM_BPF_STATE=true` — narrower: BPF state only.

Arming the destructive one on a production node means **all existing pods on that node lose connectivity** the moment the init container runs, and stay down until the agent restores every endpoint from scratch. It is a recovery tool for corrupted state, not a routine setting.

**A1.6** — **TCX** (`tcx/ingress`, `tcx/egress`) is a BPF-link-based attach mechanism for the tc layer, added in **Linux 6.6**. It replaces the legacy `tc` clsact qdisc + `bpf` filter attachment (`tc filter add dev ... bpf da obj ...`). It gives: ordered multi-program attachment without stealing another agent's program, atomic replacement, and link-based ownership so a crashed loader's programs are reclaimed. On kernels < 6.6 Cilium falls back to `Attach Mode: Legacy TC`. `Device Mode: veth` refers to the pod interface type — the alternative is `netkit` (Linux 6.7+), which removes a further layer of overhead.

---

### Block 2

**A2.1** — It is the **host endpoint**: the node itself, identity `1` (`reserved:host`), representing all host-namespace processes (kubelet, sshd, the container runtime). It has no dedicated pod IP because it *is* the node's networking namespace — it owns the node IPs.
If you write a `default-deny` policy without accounting for it, and you enable the **host firewall** (`hostFirewall.enabled=true`), you can lock yourself out of the node: kubelet's health probes into pods, and SSH into the node, are traffic from `reserved:host`. Even without host firewall, forgetting `reserved:host` in an ingress rule breaks **kubelet liveness/readiness probes**, because they originate from the node, not from a pod.

**A2.2** — It is the **cilium-health endpoint** (`lxc_health` interface), created by the agent itself on every node. It is not a Kubernetes pod, so `kubectl get pods` cannot see it. It is one end of Cilium's built-in connectivity mesh: every agent probes every other node's health endpoint over ICMP and HTTP, through the real datapath (tunnel/encryption included), which is what populates `Cluster health: 3/3 reachable`. It measures pod-to-pod reachability rather than just node-to-node.

**A2.3** — Endpoints are **per-workload-instance**; identities are **per-unique-label-set**. Both nginx replicas have identical Cilium-relevant labels, so they share identity `14584` — 2 endpoints, 1 identity.
A new identity is minted when a new **security-relevant label set** appears. Which labels count is controlled by the label filter (`labels` / `--labels` option, default `k8s:!io.kubernetes.pod-template-hash` and friends): namespace, service account, cluster name and user labels are security-relevant; `pod-template-hash`, `controller-revision-hash` and annotations are excluded — otherwise every Deployment rollout would double the identity count. This is exactly why identity scales with *policy-relevant diversity*, not with pod count, and why a 100,000-pod cluster may have only a few thousand identities.

**A2.4** —
- `cilium-dbg endpoint list` is **authoritative for the datapath**. It reflects what is actually loaded in the kernel on this node.
- `CiliumEndpoint` CRDs are **authoritative for cluster-wide observability**: they let other nodes, Hubble and operators learn about endpoints they do not host.

If the API server is unreachable for 10 minutes: the local endpoint list keeps working and existing traffic keeps flowing (the datapath is already programmed), but the agent cannot create/update CRDs, cannot learn about *new* remote endpoints, and cannot resolve identities for newly-appearing labels. The `CiliumEndpoint` objects go stale; the operator's GC will later clean up any that were orphaned.

**A2.5** — From the **kernel's / host's** perspective on the `lxc*` interface. `lxc1a2b…` is the *host-side* leg of the veth pair; the *pod-side* leg is `eth0` inside the container. A packet the pod sends out of its `eth0` **arrives** at the host-side `lxc*` — that is an ingress event on that interface. Hence `cil_from_container` on `tcx/ingress` implements pod **egress** policy, and `cil_to_container` on `tcx/egress` implements pod **ingress** policy. Getting this inverted is the single most common misreading of `bpftool net show` output.

**A2.6** —
1. `kubectl label` mutates the Pod object; the API server emits a watch event.
2. The agent's Kubernetes watcher receives it and updates the endpoint's label set.
3. The endpoint enters `waiting-for-identity`; the identity allocator resolves the new label set — either finding an existing `CiliumIdentity` or creating a new one (CRD mode) / a new kvstore key.
4. The endpoint enters `waiting-to-regenerate`, then `regenerating`: the policy engine recomputes the allowed peer-identity set for this endpoint.
5. The agent writes `lxc_config.h`, compiles (or instantiates from `templates/`) `bpf_lxc.o`, and **atomically replaces** the attached program; the per-endpoint policy map `cilium_policy_v2_02438` is updated with the new key/value pairs.
6. Endpoint returns to `ready`; the `CiliumEndpoint` CRD is updated with the new identity.

Critically, existing connections are not dropped: the program swap is atomic and conntrack state persists in `cilium_ct4_global`.

---

### Block 3

**A3.1** — A **shared identity store**. In the default CRD mode, `CiliumIdentity` objects in the Kubernetes API server are the store: the first agent to see a label set creates the object with an allocated ID; every other agent looks it up and reuses it. In kvstore mode, an etcd cluster plays the same role.
If two nodes disagreed, policy would be silently wrong: node A would encode "allow identity 14584" into its endpoints' policy maps, while node B labels the same workload 14585. Traffic from B's nginx to A's protected endpoint would carry identity 14585 in the packet metadata, miss the policy map lookup, and be **dropped as Policy denied** — a non-deterministic, node-dependent failure. Global agreement on the number is the entire correctness premise of identity-based policy.

**A3.2** — It is a **local (node-scoped) identity**, allocated for a CIDR that appears only in policy, not attached to any workload. Cilium reserves everything at or above `1 << 24` = **16777216** for these; the flag bit distinguishes them from cluster-global identities.
They are allocated locally because CIDR identities are a *policy compilation detail*: nothing needs to send them across the wire as a packet-borne identity for remote lookup in the same way workload identities do, and forcing every CIDR in every policy through the cluster-wide allocator would be a needless scaling and coordination cost.
**No** — `16777217` on this node and `16777217` on worker2 are not guaranteed to mean the same CIDR. Never compare local identity numbers across nodes; always resolve them with `cilium-dbg identity get <id>` on the node that reported them.

**A3.3** —
- `tunnelendpoint=172.18.0.4` — that pod lives on a **remote** node, and to reach it this node must encapsulate the packet in VXLAN destined for the remote node's underlay IP `172.18.0.4`.
- `tunnelendpoint=0.0.0.0` — the destination is **local** (or reachable without encapsulation); deliver directly.

With `routingMode=native`, the tunnel column becomes `0.0.0.0` for essentially everything, because the underlay network is expected to route pod CIDRs natively (via BGP, cloud route tables, or a flat L2). `cilium_tunnel_map` would be empty, `cilium_vxlan` would not exist, and you would gain MTU and lose the requirement that the underlay know nothing about pod IPs — the classic tunnel-vs-native trade-off.

**A3.4** — The `kube-apiserver` identity is produced by the agent watching the `default/kubernetes` Endpoints/EndpointSlice and injecting the `reserved:kube-apiserver` label into the ipcache entries for those IPs. Here `172.18.0.2` is the control-plane node hosting the API server, so it gets identity `7` instead of the plain `6`.
It matters because it gives you a **stable, address-independent selector** for API server traffic:
```yaml
egress:
  - toEntities:
      - kube-apiserver
```
Without it you would have to hard-code control-plane IPs in a `toCIDR` — which breaks on every control-plane replacement, and in managed clusters where the API server endpoint is outside the cluster entirely (there, the same identity is attached to that external IP).

**A3.5** — Originally `reserved:world` (2) covered *all* traffic outside the cluster, for both address families. In a dual-stack cluster that is too coarse: a rule intended to allow "all IPv4 internet" could not be expressed distinctly from IPv6. Cilium therefore added `reserved:world-ipv4` (**9**) and `reserved:world-ipv6` (**10**), used when IPv6 is enabled; identity `2` remains as the family-agnostic catch-all used in single-stack IPv4 deployments. Rules written against `toEntities: world` still match both.

**A3.6** — **`cilium-operator`**, via its identity garbage collector. It periodically scans `CiliumIdentity` objects and deletes those with no referencing `CiliumEndpoint` after a grace interval (`identity-gc-interval`, `identity-heartbeat-timeout`).
With the operator down for a week in a high-churn cluster: `CiliumIdentity` objects accumulate without bound. Symptoms escalate from etcd/API-server storage growth and slower agent startup (each agent lists all identities on boot), to **exhaustion of the 256–65535 global identity range** — after which new workloads cannot obtain an identity at all, endpoints stall in `waiting-for-identity`, and their pods never become ready.

---

### Block 4

**A4.1** —
- **(a) existing traffic — unaffected.** Forwarding is entirely in eBPF maps on each node; the operator is not on any packet path.
- **(b) new pod on an existing node — succeeded.** The node already had its PodCIDR from `CiliumNode.spec.ipam.podCIDRs`; the *agent* allocates individual IPs out of that range, and the *agent* creates the `CiliumIdentity` object. Neither needs the operator.
- **(c) identity churn — degraded silently.** The identity for the deleted `probe` Deployment was never garbage-collected; the count stayed flat over the two minutes instead of dropping. This is the only one that broke, and it broke invisibly.

The lesson: the operator's failure mode is **slow leakage, not immediate outage** — which is exactly why it is under-monitored.

**A4.2** — The new node's `CiliumNode` object is created (by the agent), but `spec.ipam.podCIDRs` stays **empty**, because in `cluster-pool` mode the operator is the allocator that carves per-node /24s out of `clusterPoolIPv4PodCIDRList`. The agent logs "waiting for IPAM pool" and never becomes ready; every pod scheduled to that node sits in `ContainerCreating` with a CNI ADD failure. Existing nodes are unaffected.

**A4.3** — In `ipam.mode=kubernetes` the PodCIDR comes from `node.Spec.PodCIDR`, written by the **kube-controller-manager**'s node IPAM controller — not by Cilium's operator. So the new node comes up fine with the operator down.
Trade-off: `kubernetes` mode inherits kube-controller-manager's fixed `--node-cidr-mask-size` and requires `--allocate-node-cidrs` to be enabled on the control plane, which you often do not control on managed clusters. `cluster-pool` gives Cilium full ownership: variable mask sizes, multiple pools, IPv6 alongside IPv4, and `CiliumPodIPPool` for multi-pool setups — at the cost of adding the operator to the node-bootstrap critical path.

**A4.4** — The operator performs **cluster-scoped, mutually-exclusive reconciliation**: allocating a PodCIDR to a node, or deciding an identity is unreferenced, must be done by exactly one actor or you get double-allocation and premature deletion. Leader election over N replicas gives fast failover without concurrency. It is off the data path, so an election gap costs nothing but latency in reconciliation.
The agent, conversely, performs **node-local, node-exclusive** work: there is exactly one kernel per node and exactly one correct owner of its BPF maps. Two agents on a node would fight over the same pinned maps and tc/tcx attachments. A DaemonSet already guarantees one-per-node, so leader election would be redundant machinery.

**A4.5** — Each `CiliumEndpoint` is an object the API server must store and watch. With 100,000 pods, **every one of the 5,000 agents** watches all 100,000 objects, and every pod churn event fans out 5,000 ways. That is O(nodes × endpoints) watch traffic and can saturate the API server and etcd before the workload does anything.
`CiliumEndpointSlice` batches many endpoints into one object (default grouping by namespace/identity), collapsing both object count and event count by roughly the batch factor — the same arithmetic that motivated Kubernetes' own `EndpointSlice`. The **`cilium-operator`** watches `CiliumEndpoint`s and produces the slices; agents then watch slices instead. Enabled with `enable-cilium-endpoint-slice: "true"`.

**A4.6** — Any three of:
- **Ingress / Gateway API**: translating `Ingress` and `Gateway`/`HTTPRoute` resources into `CiliumEnvoyConfig`, and syncing TLS Secrets into the Cilium namespace.
- **Cloud IPAM**: allocating ENIs/IPs in `eni` (AWS), `azure`, or `alibabacloud` mode — a substantial, cloud-API-calling subsystem.
- **kvstore mode**: heartbeat writes and identity management against etcd when `kvstore=etcd`.
- **`CiliumEndpointSlice`** production (as above).
- **`CiliumBGPClusterConfig` / LB-IPAM**: allocating IPs from `CiliumLoadBalancerIPPool` to `Service` type `LoadBalancer`.
- **CNP derivative handling**: expanding `toGroups` (e.g. AWS security group selectors) into concrete CIDRs.
- **Multi-pool IPAM** via `CiliumPodIPPool`.

---

### Block 5

**A5.1** — **Forwarding state is in the kernel; control-plane state is in the agent.** Existing pods keep working because their veth interfaces still exist, their tc/tcx programs are still attached, and their maps (`cilium_lxc`, `cilium_ipcache`, `cilium_policy_v2_*`, `cilium_ct4_global`) are still pinned under `/sys/fs/bpf`. None of that requires a running process.
New pods fail because pod attachment is a *control-plane* operation: `cilium-cni` must ask the agent to allocate an IP, create the veth pair, allocate/resolve an identity, build and attach the endpoint's BPF program, and write the map entries. With the socket gone, `cilium-cni` times out and CNI ADD fails, so kubelet cannot create the sandbox.

**A5.2** — It must (1) **allocate an IP** from the node's pool and (2) **create the endpoint**, which means resolving a security identity and compiling/attaching that endpoint's datapath program.
Embedding that in the plugin would be wrong because the plugin is a **short-lived process with no state**. IP allocation must be serialized against all other allocations on the node; identity resolution requires the watch-backed view of cluster state; endpoint programs must be tracked for later regeneration when labels or policies change. All of that requires a long-lived, stateful owner. The plugin is deliberately a thin RPC client over `/var/run/cilium/cilium.sock`.

**A5.3** — The container runtime reads `/etc/cni/net.d` in **lexicographic order and uses the first valid config file**. The `05-` prefix positions Cilium ahead of most defaults.
If a previous CNI left `00-something.conflist`, that file sorts first and wins: pods get IPs from the *other* plugin, Cilium never sees them, and they appear as `reserved:unmanaged` (identity 3) or not at all — while `cilium-dbg status` still looks perfectly healthy. This is why uninstalling a previous CNI means deleting its config from `/etc/cni/net.d` on every node, not just deleting its DaemonSet.

**A5.4** — In **standalone** mode Cilium is the only plugin: it owns IPAM, the veth, routing and policy end to end. `cilium-dbg status` shows `CNI Chaining: none`.
In **chaining** mode another plugin (AWS VPC CNI, Calico, `generic-veth`) creates the interface and assigns the IP, and Cilium is appended to the `plugins` array to attach its eBPF programs to the already-created interface. Status shows `CNI Chaining: aws-cni` (or `generic-veth`, `portmap`, …).
Chained mode gives you identity-based policy and Hubble, but **loses** the features that depend on owning the datapath end to end: notably `kubeProxyReplacement` (full), the socket-level LB, bandwidth manager, egress gateway, and generally anything requiring Cilium's own routing/masquerading. This is why the AWS VPC CNI chaining path is documented as feature-restricted.

**A5.5** —
1. **The CNI config file is written by the agent, late.** Until `cilium-agent` reaches a ready state and writes `05-cilium.conflist`, there is no valid CNI config, so the CRI reports the network plugin as not ready and the node is `NotReady` — kubelet will not start non-host-network pods. (Correspondingly, the agent *removes*/renames the config on shutdown in some configurations.)
2. **Endpoint restoration.** On start the agent reads `/var/run/cilium/state/` and re-establishes every previously-known endpoint before serving new CNI requests, so a pod that survived the reboot is not left half-configured.

Additionally, the agent's readiness probe (`cilium-health` / the agent's `/healthz`) gates the DaemonSet pod as Ready, which node-level tooling can key off.

---

### Block 6

**A6.1** — The agent keeps a **userspace mirror** of maps it owns and reconciles, so it can answer queries and detect drift without dumping the kernel map; the `bpf-map-sync-*` controllers periodically re-sync the cache against the kernel and repair discrepancies. That is appropriate for maps whose contents the *agent* authored: `cilium_lxc`, `cilium_ipcache`, the LB maps, policy maps.
Conntrack is excluded because it is authored by the **datapath**, not the agent: entries are created per-flow by eBPF programs in the fast path, at rates of hundreds of thousands per second, with kernel-side eviction. Caching that in userspace would be pure overhead and would be stale the instant it was written. Conntrack is instead managed by a periodic GC that walks the map directly.

**A6.2** — Client on worker → nginx on worker2, tunnel mode:
1. Pod's `eth0` → host-side `lxc*` **ingress** → **`cil_from_container`**. Here: conntrack, egress policy lookup against `cilium_policy_v2_<client-ep>`, destination lookup in `cilium_ipcache` → identity `14584`, `tunnelendpoint=172.18.0.4`.
2. Redirect to `cilium_vxlan` for **encapsulation**. The original packet is wrapped in VXLAN/UDP 8472 with the source security identity carried in the VNI/metadata so the far side can enforce ingress policy without re-deriving it.
3. Out through `eth0` **egress** → **`cil_to_netdev`** (masquerading decisions, host firewall egress).
4. On worker2: `eth0` **ingress** → **`cil_from_netdev`** recognises the VXLAN destination.
5. Decapsulation on `cilium_vxlan` **ingress** → **`cil_from_overlay`**. Identity extracted from the encapsulation.
6. Delivered to the target endpoint's `lxc*` **egress** → **`cil_to_container`**, which performs the **ingress** policy lookup against nginx's `cilium_policy_v2_02438` using the identity from step 5.

Encapsulation happens at step 2, decapsulation at step 5. Note the packet may never enter the host's IP stack at all — that is the point of `Host: BPF` routing.

**A6.3** — **Socket-level load balancing** (socket LB / "host-reachable services"), part of `kubeProxyReplacement`. `cil_sock4_connect` hooks the `connect(2)` of any process in the cgroup v2 hierarchy; if the destination is a known ClusterIP, it **rewrites the destination in the socket itself** to a chosen backend pod IP before a single packet is built. `cil_sock4_sendmsg` does the equivalent for connectionless UDP `sendmsg(2)` — which is what makes DNS to the CoreDNS ClusterIP work.
Effects: there is no per-packet DNAT and no reverse-NAT lookup on the return path for these connections — translation happens once, at socket setup, which is measurably cheaper than either iptables or per-packet BPF DNAT.
Observable side-effect: **`tcpdump` inside the pod never shows the ClusterIP.** By the time a packet exists, the destination is already the backend pod IP. Engineers regularly file bugs about this; it is correct behaviour.

**A6.4** — The map is **pinned** in bpffs at `/sys/fs/bpf/tc/globals/cilium_lxc`, in the host mount namespace. A pinned object's lifetime is owned by the filesystem, not by the process that created it. When `cilium-agent` exits, the kernel keeps the map (and the tc/tcx-attached programs that reference it), so packets continue to be classified, policed and forwarded with zero involvement from userspace. On restart the agent opens the same pinned paths, compares contents against desired state, and repairs deltas — hence the identical inode.
The change that **would** break it: setting `CLEAN_CILIUM_BPF_STATE=true` (or `cilium.cleanState`), which explicitly unpins and deletes the maps and unloads the programs before the agent starts. A major-version upgrade that changes a map's value struct also forces a map recreation for that specific map — which is why Cilium versions map names (`_v2`, `_v3`) and, for the disruptive cases, documents a migration.

**A6.5** — Cilium **compiles a per-endpoint eBPF program**. `lxc_config.h` / `ep_config.h` contain that endpoint's constants — its ID, MAC, IPs, security identity, policy-map file descriptor index, enabled features — and `bpf_lxc.o` is the object built with those constants baked in as compile-time values. Baking them in lets the verifier prune impossible branches and eliminates runtime map lookups for per-endpoint invariants, which is where much of Cilium's per-packet performance comes from.
The cost is a clang invocation per regeneration. `templates/` holds **pre-compiled templates keyed by the feature-flag combination**: endpoints that differ only in ID/MAC/IP reuse an existing template and have their constants patched in via ELF rewriting rather than recompiled. That is why the first endpoint on a node is slow and the hundredth is fast, and why a node with many *identical-configuration* endpoints regenerates far faster than one with many distinct feature sets.

**A6.6** — A veth pair is needed because Cilium requires a point where packets **cross between the host stack and the Cilium datapath** in a controllable, hookable way. `cilium_host` is the host-stack-facing end and carries the router IP; `cilium_net` is the datapath-facing peer. BPF programs attach on both (`cil_to_host` on `cilium_host`, `cil_from_host` on `cilium_net`), giving Cilium a hook on traffic in each direction between the two worlds — for host firewall enforcement, identity attribution of host traffic, and correct routing of proxy-originated traffic. A single dummy interface would have only one hook point and no way to represent direction across the boundary.

---

### Block 7

**A7.1** — **`cil_sock4_connect`**, attached to the **cgroup v2 `connect4` hook** (see A6.3). It rewrites the socket's destination address before the connection is established.
Performance: iptables-based kube-proxy does per-packet DNAT through a chain walk that is O(number of services) in the worst case, plus a conntrack entry and a reverse translation on every reply packet. Cilium's socket LB does **one translation per connection** at `connect()` time, with an O(1) hash lookup in `cilium_lb4_services_v2`, and no reverse-NAT work at all for the pod-local case. The gap widens linearly with service count, which is the headline argument for kube-proxy replacement in large clusters.

**A7.2** — At the **tc/tcx layer on the ingress device**: `cil_from_netdev` on `eth0` looks up the NodePort frontend `172.18.0.3:31654` (and the wildcard `0.0.0.0:31654`) in `cilium_lb4_services_v2`, selects a backend from `cilium_lb4_backends_v3`, and DNATs the packet. The external client did no `connect()` inside this node's cgroup hierarchy, so there was no socket to rewrite.
The reply path uses **`cilium_lb4_reverse_nat`** (keyed by the `REVNAT_ID` you saw in `cilium-dbg bpf lb list`) to restore the original NodePort frontend as the source address, so the client sees a reply from the address it dialled. When the selected backend is on a *different* node, `cilium_snat_v4_external` additionally holds the SNAT state that gets the reply routed back through the ingress node (unless `externalTrafficPolicy: Local` avoids the extra hop, or DSR is enabled).

**A7.3** — `cilium-dbg service list` is the **agent's userspace service model**, built from watched Kubernetes `Service`/`EndpointSlice` objects. `cilium-dbg bpf lb list` dumps the **actual kernel maps** the datapath reads.
A discrepancy means the reconciliation between the two failed: the agent knows about a service but did not (or could not) program it. Check `cilium-dbg status --all-controllers` for `sync-lb-maps-with-k8s-services`, and check whether the LB maps are full (`cilium-dbg map list --verbose` — `Num errors` non-zero, or entries at the map's max size). Map exhaustion under `bpf-lb-map-max` is a real production failure and it presents exactly this way: services listed, traffic blackholed.

**A7.4** —
- `kubeProxyReplacement=false` **+ `nodePort.enabled=true`** (and friends like `socketLB.enabled`, `externalIPs.enabled`, `hostPort.enabled`): a **partial** replacement. Cilium handles the specifically enabled feature(s) and **kube-proxy still runs** and handles the rest, notably ClusterIP for host-namespace traffic depending on configuration.
- `kubeProxyReplacement=true`: **full** replacement. Cilium handles ClusterIP, NodePort, LoadBalancer, ExternalIPs, HostPort, session affinity and the socket LB. kube-proxy must not run.

Full replacement uniquely gives you the **cgroup socket LB** with no per-packet DNAT for in-cluster traffic, and enables DSR / Maglev / hybrid modes and the removal of the iptables service chains entirely. It also requires a sufficiently recent kernel and correct `k8sServiceHost`/`k8sServicePort`.

**A7.5** — In full replacement mode, **Cilium is the thing that programs ClusterIPs**. Before the agent has synced with the API server, `10.96.0.1:443` resolves to nothing. If the agent tried to reach the API server through that ClusterIP it would be asking for a service that only it can create — a hard boot deadlock, and after a full-cluster restart the entire cluster would be unrecoverable.
Pointing `k8sServiceHost` at a ClusterIP produces exactly that: agents log connection timeouts to the API server, never become ready, never write the CNI config, and every node goes `NotReady`. The value must be a **node IP, an external load balancer address, or a DNS name that resolves without in-cluster service resolution**.

**A7.6** — The alternative is **Maglev** (`loadBalancer.algorithm=maglev`), which populates **`cilium_lb4_maglev`** — a per-service consistent-hashing lookup table (size controlled by `maglev.tableSize`, a prime, default 16381).
It is strictly better when **backend selection must agree across nodes**: with DSR or `externalTrafficPolicy: Cluster`, a packet may arrive at any node, and with `random` each node would pick independently, breaking connections that get re-routed. Maglev's consistent hash makes every node choose the same backend for the same 5-tuple, and — its defining property — a backend removal only remaps that backend's share of flows rather than reshuffling everything. Cost: memory proportional to `tableSize × services`.

---

### Block 8

**A8.1** — It is a **ring buffer occupancy**, not an error. Each agent keeps the last N flows in memory (`hubble.eventBufferCapacity`, default 4095); once the cluster has been running for a few seconds the buffer is naturally full and stays at 100% forever, evicting the oldest flow for each new one. It reports "the buffer holds its maximum of recent flows", not "flows are being dropped due to overload".
The data structure is a fixed-size in-memory **circular buffer per agent**. The real capacity signal is `Flows/s` versus your retention need: at 4095 entries and 3,000 flows/s you retain roughly 1.4 seconds of history. If you need more, raise the buffer, or export to a persistent sink via Hubble metrics/exporter — do not treat the percentage as an alert.

**A8.2** —
1. `hubble` CLI on your laptop → **localhost:4245**, the local end of `cilium hubble port-forward` (a kubectl port-forward).
2. → Kubernetes API server → kubelet → the **`hubble-relay` pod, port 4245** (gRPC, mTLS optional).
3. Relay → for each peer, the **agent's Hubble server on port 4244**, discovered via the `hubble-peer` Service.
4. Each agent reads its **local in-memory ring buffer** and streams matching flows back.
5. Relay merges the N streams and returns one stream to the CLI.

**`hubble-relay` is the stateless one.** It stores no flows; it is purely a fan-out/fan-in gRPC proxy. That is why it can be restarted freely and why losing it costs you cluster-wide queries but no data.

**A8.3** — The model is **partial availability with per-node independence**. Relay queries every peer, returns whatever answers, and reports the failures explicitly rather than erroring the whole query. Losing one agent degrades coverage of that node only.
The historical flows were **not** recoverable. The ring buffer is in the agent process's memory; when the pod was deleted the buffer died with it. The node's flows resume from zero when the new agent starts. This is the single most important operational property of Hubble: **it is a live-tail and short-window debugging tool, not a store**. If you need durable history you must export it — `hubble-export` to a file, or Hubble metrics into Prometheus.

**A8.4** — It selects the **`cilium` agent pods themselves** (`k8s-app: cilium`), targeting port 4244. It is a *headless-style* Service used purely for **peer discovery**: Relay watches its EndpointSlice to learn the current set of agents and their addresses, and reacts to nodes joining and leaving without any static configuration or its own node watch.
Delete it and `hubble-relay` loses its peer list: `hubble status` reports 0 connected nodes and every cluster-wide query returns empty. Per-node queries via `cilium-dbg`/local socket keep working, and — importantly — **the datapath is entirely unaffected**, because Hubble is observability only.

**A8.5** — **`cilium_events`**, a `BPF_MAP_TYPE_PERF_EVENT_ARRAY` (per-CPU perf ring buffer) written by the datapath programs and read by the agent's NodeMonitor — that is what `Listening for events on 8 CPUs with 64x4096 of shared memory` in `cilium-dbg status` refers to.
Perf buffers are **lossy by design**: if the datapath produces events faster than userspace consumes them, the kernel drops them and increments a lost-event counter. Combined with the finite in-memory ring buffer downstream, this means Hubble gives you a statistically excellent but **not complete** view. For billing, compliance evidence or an audit-of-record you need a source with delivery guarantees; Hubble's guarantee is best-effort. (You can observe the losses — the monitor reports lost events, and the aggregation level `monitorAggregation` deliberately suppresses events to reduce pressure.)

**A8.6** — From the **agents**. Each `cilium-agent` computes Hubble metrics from its own flow stream and exposes them on its own Hubble metrics port (default **9965**); Prometheus scrapes the agents, not Relay. Relay is not in the metrics path at all.
The cardinality risk: `sourceContext=pod;destinationContext=pod` creates a time series per **(source pod, destination pod, verdict, protocol, …)** tuple. In a cluster with 10,000 pods in a mesh-ish communication pattern, that is potentially millions of series — it will destroy a Prometheus instance long before it tells you anything useful, and it also costs agent CPU and memory on every node. Use coarser contexts (`namespace`, `workload`, `identity`) and add pod-level granularity only for a narrow, temporary investigation.

---

### Block 9

**A9.1** — A **redirect** is an instruction in the datapath to divert matching traffic to the local L7 proxy instead of delivering it to the endpoint. It is stored in **`cilium_proxy4`** (dumped by `cilium-dbg bpf proxy list`), and the allocated proxy port comes from the 10000–20000 range reported in the status line.
For a matching packet, `cil_to_container` (ingress) does not deliver to the pod. It rewrites the destination to the local proxy port on `cilium_host`'s IP and hands the packet to the host stack, where Envoy accepts it, parses HTTP, applies the L7 rules, and — if allowed — opens/reuses a connection to the real backend. The original connection metadata is preserved so Envoy knows the true source identity and destination, and so the reply path is restored correctly.

**A9.2** — **`cilium-envoy`** made it, and it happened **after** the eBPF policy verdict, not instead of it. The L3/L4 lookup in `cilium_policy_v2_02438` matched — client→nginx on port 80 is allowed — but the matching entry is marked as *requiring proxy redirect* rather than *allow-and-deliver*. So the packet was accepted by eBPF, redirected to Envoy, and Envoy then evaluated the HTTP method and path and rejected the POST (returning `403` to the client, which is why you get a status code rather than a timeout).
This layering is why Hubble reports two distinct verdict types: `to-endpoint`/`policy-verdict` for the eBPF decision and `http-request` for the Envoy decision. An L7 rule can only ever *narrow* what an L4 rule already permitted.

**A9.3** — Advantages (any two):
- **Independent lifecycle**: restarting or upgrading `cilium-agent` no longer tears down every L7-proxied connection. Agent upgrades become far less disruptive on clusters using L7 policy, Ingress or Gateway API.
- **Independent CVE response**: Envoy has a high CVE rate; you can bump the `cilium-envoy` image without a datapath change.
- **Resource isolation**: Envoy's memory and CPU are accounted and limitable separately, so an Envoy leak cannot OOM the process that owns the eBPF datapath.
- Smaller agent image and process footprint on nodes that never use L7.

New failure mode: **a second thing can be independently unhealthy**. `cilium-agent` can be perfectly Ready on a node where `cilium-envoy` is CrashLooping or not yet scheduled, so L7-policied traffic breaks while every agent-level health signal is green. It also introduces a startup ordering concern and a new inter-process dependency over `/var/run/cilium/envoy/sockets/`.

**A9.4** — Mechanically, an L7 rule forces the packet **out of the eBPF fast path and into userspace**: redirect to the proxy, full TCP termination, HTTP parse, rule evaluation, then a *second* connection from Envoy to the backend. That is two TCP stacks, a userspace copy and protocol parsing per request, versus a single O(1) hash lookup for an L4 rule.
Non-matching traffic on the same endpoint is **not** affected: the redirect is installed per (endpoint, port, protocol, direction) in `cilium_proxy4`. Traffic to a different port on the same pod, or traffic from a peer identity not covered by the L7 rule, continues on the pure eBPF path at full speed. This is what makes selective L7 policy practical — you pay only where you asked for L7 semantics.

**A9.5** — `CiliumEnvoyConfig` (namespaced) and `CiliumClusterwideEnvoyConfig` (cluster-scoped) let you inject **raw Envoy xDS configuration** — listeners, clusters, routes, filter chains — into the Envoy instances Cilium manages, and bind them to Kubernetes Services. It is the escape hatch for capabilities Cilium's own policy CRDs do not model.
Built on top of it: **Cilium Ingress Controller** and **Cilium Gateway API** (the operator translates `Ingress`/`Gateway`+`HTTPRoute` into `CiliumEnvoyConfig`), and **L7-aware traffic management / L7 load balancing for Services** (e.g. gRPC-aware balancing via a service annotation). Cilium's Envoy-based **L7 network policy** enforcement uses the same infrastructure.

**A9.6** — **Fail-closed.** The redirect entry in `cilium_proxy4` is installed as part of the endpoint's policy program; the datapath's action for matching traffic is "send to proxy port", not "deliver to pod". If nothing is listening on that proxy port, the connection is refused or times out — the packet is never delivered to the application.
This is the correct security posture (an unavailable policy enforcer must not become an implicit allow), but it means `cilium-envoy` is a **hard dependency for availability** of any workload under L7 policy. Monitor the `cilium-envoy` DaemonSet with the same seriousness as the agent.

---

### Block 10

**A10.1** — They probe two different paths on purpose:
- **Host connectivity** targets the remote node's **node IP** — the underlay path, host stack to host stack.
- **Endpoint connectivity** targets the remote node's **health endpoint pod IP** — the full Cilium datapath: encapsulation (or native routing), identity handling, encryption if enabled, and delivery into a pod namespace.

Host OK + endpoint failing is a precise and very useful signal: **the underlay network is fine, the overlay is not.** Look at MTU (VXLAN adds 50 bytes; an underlay MTU that does not accommodate it silently drops large packets while ICMP-sized probes may pass), a firewall blocking UDP 8472/6081 or WireGuard 51871, a missing or stale `cilium_tunnel_map` entry, or an IPsec/WireGuard key mismatch.

**A10.2** — The **cilium-health endpoint** (`lxc_health`, seen as endpoint `159` in Block 2), carrying identity **`4` / `reserved:health`**.
Implication: under a cluster-wide default-deny policy, health probes are policy-subject traffic like anything else. Cilium special-cases `reserved:health` so the built-in mesh keeps working, but you must be aware of it when reasoning about "everything is denied" — and if you disable health checking (`healthChecking=false`) to silence noise, you lose the earliest and cheapest signal that your overlay has broken. Keep it, and alert on `Cluster health` degrading.

**A10.3** — Any four of:
- **Pod logs** for `cilium`, `cilium-operator`, `cilium-envoy`, `hubble-relay` — including `--previous` logs from **crashed containers**, which are gone once the container is garbage-collected.
- **Point-in-time BPF map dumps** (`cilium-dbg bpf * list`) and endpoint state — conntrack and LB tables change continuously; the state at failure time is unrecoverable minutes later.
- **A Hubble flow capture** from the in-memory ring buffer, which is overwritten within seconds at any real flow rate.
- **`cilium-dbg status --verbose`, controller status and per-endpoint logs** at the moment of the incident, including error counters that get reset by a restart.
- **Kubernetes events**, which expire (default 1 hour TTL).
- **`gops` stack/heap/goroutine dumps** from the agent process, gone with the process.

The general principle: run `cilium sysdump` **before** you restart anything. Restarting the agent to "fix" the problem destroys most of the evidence.

**A10.4** —
1. `cilium-dbg identity get 61203` and `cilium-dbg identity get 14584` — turn the numbers into label sets, so you know *which workloads*. (Run on the node that emitted the drop, in case either is a local identity.)
2. `cilium-dbg endpoint get <id-of-destination-endpoint>` — or `cilium-dbg policy get` — to see the realized policy for the destination and confirm whether the source identity is actually absent from the allowed set. `cilium-dbg bpf policy get <endpoint-id>` shows the kernel-side truth.
3. `hubble observe --from-identity 61203 --to-identity 14584 --verdict DROPPED -o json` (or `cilium-dbg monitor -t policy-verdict`) to get the full flow context — port, direction, and whether the drop is L3/L4 or an L7 `http-request` — and cross-check against the `CiliumNetworkPolicy` objects selecting the destination.

The frequent root causes this sequence surfaces: a `default-deny` was introduced without a matching allow; the policy selects on a label the pod does not actually carry (typo, or namespace label missing); the direction is wrong (an ingress rule written where egress was needed); or DNS-based policy is failing because the DNS proxy did not observe the lookup.

**A10.5** — Ranked by blast radius, worst first:

| Component | Immediately | Eventually |
|---|---|---|
| **`cilium-agent`** (one node) | No new pods on that node (CNI ADD fails); no policy, identity, service or ipcache updates on that node; local Hubble flows stop | Node's view of the cluster goes stale — new remote pods unreachable, revoked policy still enforced, conntrack GC stops. Existing traffic keeps flowing throughout. |
| **`cilium-envoy`** (one node) | All L7-policied, Ingress and Gateway API traffic on that node **fails closed** | Unchanged — it does not self-heal without the pod returning |
| **`cilium-operator`** (cluster) | Nothing user-visible | Identity and `CiliumEndpoint` garbage collection stops (leak → eventual identity-range exhaustion); new nodes get no PodCIDR in `cluster-pool` IPAM; Ingress/Gateway translation and LB-IPAM stop; cloud IPAM stops issuing IPs |
| **`hubble-relay`** (cluster) | Cluster-wide `hubble observe` and Hubble UI stop | Nothing else — per-node `cilium-dbg`/local-socket observability and all metrics still work; **no data-path impact** |
| **`hubble-ui`** (cluster) | The web UI is unavailable | Nothing — the `hubble` CLI is unaffected |

The shape to remember for the exam: **agent = node-local data plane + node-local control plane; operator = cluster-wide control plane with delayed symptoms; envoy = L7 data plane, fail-closed; Hubble = observability only, never data plane.**

</details>

---

## Sources

- Cilium — *Component Overview*: <https://docs.cilium.io/en/stable/overview/component-overview/>
- Cilium — *Introduction to Cilium & Hubble*: <https://docs.cilium.io/en/stable/overview/intro/>
- Cilium — *eBPF Datapath*: <https://docs.cilium.io/en/stable/network/ebpf/>
- Cilium — *Routing (Encapsulation / Native)*: <https://docs.cilium.io/en/stable/network/concepts/routing/>
- Cilium — *IP Address Management*: <https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Cilium — *Kubernetes Without kube-proxy*: <https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium — *Network Policy*: <https://docs.cilium.io/en/stable/security/policy/>
- Cilium — *Hubble Observability*: <https://docs.cilium.io/en/stable/observability/hubble/>
- Cilium — *Troubleshooting*: <https://docs.cilium.io/en/stable/operations/troubleshooting/>
- Cilium — *System Requirements* (kernel versions, required ports): <https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium — *Helm Reference*: <https://docs.cilium.io/en/stable/helm-reference/>
- Cilium — *`cilium-dbg` command reference*: <https://docs.cilium.io/en/stable/cmdref/cilium-dbg/>
- Cilium — *Cluster Mesh*: <https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/>
- Cilium source (reserved identity numbering, map definitions): <https://github.com/cilium/cilium>
- CNCF — *Cilium Certified Associate (CCA) curriculum*: <https://github.com/cncf/curriculum> · <https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md>