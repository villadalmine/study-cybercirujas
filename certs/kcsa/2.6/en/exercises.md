# KCSA Topic 2.6: KubeProxy & Cluster Networking Security Architecture

## Official References
* **CNCF KCSA Curriculum**: [KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Virtual IPs and Service Proxies**: [Kubernetes Service Proxies Documentation](https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies)
* **kube-proxy Component Reference**: [kube-proxy Reference Guide](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/)
* **Kubernetes Network Policies**: [Network Policies Concept](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## 1. Deep-Dive Architecture & Production Security Trade-offs

`kube-proxy` is a network proxy running on each node in a Kubernetes cluster. It maintains network rules on nodes that allow network communication to Pods from inside or outside of the cluster.

### 1.1 Operating Modes & Internal Mechanics

1. **iptables Mode**:
   * **Mechanism**: Uses Linux `iptables` rules generated sequentially via `iptables-restore`. `kube-proxy` watches the Kubernetes API server for changes to `Service` and `EndpointSlice` objects.
   * **Performance & Scale**: Rule evaluation is $O(N)$ sequential. Large clusters with tens of thousands of Services experience high CPU overhead on nodes during rule synchronization (`iptables-restore` locks the `xtables` lock).
   * **Security Overhead**: Does not perform packet inspection or identity verification. All traffic matching `ClusterIP` or `NodePort` destination patterns is NATed (`DNAT`/`SNAT`).

2. **IPVS Mode**:
   * **Mechanism**: Leverages Netfilter IP Virtual Server (IPVS) kernel module. Constructs IPVS virtual servers and real servers while utilizing `ipset` for high-performance set lookups.
   * **Performance & Scale**: $O(1)$ hashing lookup. Highly scalable for large clusters ($>2,000$ Services).
   * **Security Requirement**: Requires `strictARP: true` in `kube-proxy` config when using Layer 2 Load Balancers like MetalLB to prevent ARP response conflicts on the `kube-ipvs0` dummy interface.

3. **nftables Mode** (Kubernetes v1.31+ GA/Beta track):
   * **Mechanism**: Replaces legacy `iptables` with `nftables` syntax and kernel state management, reducing lock contention and optimizing rule tree structures.

4. **eBPF-based Alternatives** (e.g., Cilium eBPF host routing):
   * Bypasses Netfilter/iptables entirely by attaching eBPF programs directly to network device drivers (XDP/tc). Completely replaces or bypasses `kube-proxy`.

---

### 1.2 Security Perimeter & Common Attack Vectors

| Architectural Aspect | Security Concern | Remediation / Hardening Strategy |
| :--- | :--- | :--- |
| **Pod Privileges** | Runs on `hostNetwork: true` with `CAP_NET_ADMIN` and `CAP_NET_RAW` privileges to mutate host Netfilter kernel state. | Enforce tight Pod Security Standards (`Unrestricted` exception for system-critical CNI/proxy), restrict access to `kube-proxy` ServiceAccount token. |
| **Unauthenticated Metrics & Healthz** | Historically bound to `0.0.0.0:10249` (`/metrics`) and `0.0.0.0:10256` (`/healthz`). Exposes node/cluster internal metrics to unauthenticated network scanners. | Bind `metricsBindAddress` to `127.0.0.1:10249` or mandate authentication via RBAC/TLS proxies. |
| **Lack of Access Control** | `kube-proxy` **does NOT** enforce `NetworkPolicy` objects. It purely routes traffic. | Pair `kube-proxy` with a NetworkPolicy-compliant CNI (Calico, Cilium, Weave Net). |
| **Source IP Obfuscation (SNAT)** | Default `externalTrafficPolicy: Cluster` applies `SNAT` to incoming NodePort/LoadBalancer traffic, hiding client IP addresses from application logs and WAFs. | Set `externalTrafficPolicy: Local` to preserve client source IP (Note trade-off: risks uneven load balancing and zero-endpoint drops on nodes without pods). |

---

## 2. Hands-on Guided Exercises

### Exercise 1: Auditing and Hardening `kube-proxy` Exposure & Privileges

#### Scenario
You are auditing a production cluster to ensure `kube-proxy` complies with least-privilege security configurations and does not expose unauthenticated metrics endpoints on node public interfaces.

#### Steps

1. **Step 1**: Retrieve the current `kube-proxy` ConfigMap from the `kube-system` namespace and inspect its configuration structure.
```bash
kubectl get configmap kube-proxy -n kube-system -o yaml > kube-proxy-cm.yaml
cat kube-proxy-cm.yaml | grep -E "bindAddress|metricsBindAddress|mode|healthzBindAddress"
```
*Expected Output:*
```text
    bindAddress: 0.0.0.0
    healthzBindAddress: 0.0.0.0:10256
    metricsBindAddress: 0.0.0.0:10249
    mode: "iptables"
```

2. **Step 2**: Verify if the metrics endpoint is publicly reachable from within a cluster Pod across node interfaces.
```bash
kubectl run network-audit-pod --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl -s -I http://kube-proxy.kube-system.svc:10249/metrics | head -n 5
```
*Expected Output:*
```text
HTTP/1.1 200 OK
Content-Type: text/plain; version=0.0.4; charset=utf-8
Date: Fri, 07 Aug 2026 19:37:42 GMT
```

3. **Step 3**: Inspect the DaemonSet specification for `kube-proxy` to audit host network namespace sharing and security contexts.
```bash
kubectl get ds kube-proxy -n kube-system -o yaml | grep -A 12 "securityContext:"
```
*Expected Output:*
```yaml
      securityContext:
        capabilities:
          add:
          - NET_ADMIN
        privileged: true
```

4. **Step 4**: Apply a hardened ConfigMap patch that restricts `metricsBindAddress` to localhost (`127.0.0.1:10249`) and changes mode to `iptables` with strict masquerading rules.

Save the following manifest to `kube-proxy-hardened-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    app: kube-proxy
data:
  config.conf: |-
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    bindAddress: 0.0.0.0
    clientConnection:
      acceptContentTypes: ""
      burst: 10
      contentType: application/vnd.kubernetes.protobuf
      qps: 5
    clusterCIDR: 10.244.0.0/16
    healthzBindAddress: 127.0.0.1:10256
    metricsBindAddress: 127.0.0.1:10249
    mode: "iptables"
    iptables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 0s
      syncPeriod: 30s
    nftables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 0s
      syncPeriod: 30s
```

Apply the updated ConfigMap and trigger a rolling restart of the `kube-proxy` DaemonSet:
```bash
kubectl apply -f kube-proxy-hardened-cm.yaml
kubectl rollout restart daemonset/kube-proxy -n kube-system
kubectl rollout status daemonset/kube-proxy -n kube-system
```
*Expected Output:*
```text
configmap/kube-proxy configured
daemonset.apps/kube-proxy restarted
daemonset rolling update status master restart recorder: 1 of 1 updated instances are available...
```

5. **Step 5**: Verify that external pod access to `/metrics` is now blocked/refused.
```bash
kubectl run network-audit-pod-verify --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl --connect-timeout 3 http://10.96.0.1:10249/metrics
```
*Expected Output:*
```text
curl: (7) Failed to connect to 10.96.0.1 port 10249 after 3000 ms: Couldn't connect to server
pod "network-audit-pod-verify" deleted
```

---

#### Verification Questions - Exercise 1
1. **Q1.1**: Why does `kube-proxy` require the `CAP_NET_ADMIN` Linux capability when running inside a Pod?
2. **Q1.2**: What security risk is introduced when `metricsBindAddress` is set to `0.0.0.0:10249` without a network security group or firewall policy protecting the nodes?

---

### Exercise 2: Source IP Preservation & Netfilter Chain Inspection

#### Scenario
A security incident response team notes that web application access logs show all incoming external requests originating from internal cluster node IP addresses (e.g., `10.244.0.1` or node interface IP), masking true client source IPs. You must diagnose the `externalTrafficPolicy` behavior and inspect the corresponding `iptables` chains generated by `kube-proxy`.

#### Steps

1. **Step 1**: Create a test namespace and deploy a web application with a `NodePort` Service configured with the default `externalTrafficPolicy: Cluster`.

Save the manifest as `echoserver-cluster.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: net-security-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echoserver
  namespace: net-security-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echoserver
  template:
    metadata:
      labels:
        app: echoserver
    spec:
      containers:
      - name: echoserver
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        command: ["/agnhost", "netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: echoserver-nodeport
  namespace: net-security-test
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
  selector:
    app: echoserver
```

Apply the manifest:
```bash
kubectl apply -f echoserver-cluster.yaml
kubectl wait --for=condition=available deployment/echoserver -n net-security-test --timeout=60s
```

2. **Step 2**: Execute `iptables-save` inside a node or privileged debug container to inspect the `KUBE-NODEPORTS` and `KUBE-SERVICES` chains for port `30080`.
```bash
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') -it --image=alpine -- sh -c "apk add --no-舆 iptables >/dev/null 2>&1; iptables-save | grep 30080"
```
*Expected Output:*
```text
-A KUBE-NODEPORTS -p tcp -m comment --comment "net-security-test/echoserver-nodeport:" -m tcp --dport 30080 -j KUBE-SVC-WBX7M4O4KQKZ2V3X
-A KUBE-SVC-WBX7M4O4KQKZ2V3X -m comment --comment "net-security-test/echoserver-nodeport:" -j KUBE-MARK-MASQ
```
*(Notice the `KUBE-MARK-MASQ` rule: traffic coming in on NodePort gets marked for Source NAT (SNAT), rewriting the source IP to the node's IP address).*

3. **Step 3**: Patch the service to use `externalTrafficPolicy: Local`.

Save the following patch file as `patch-local.yaml`:
```yaml
spec:
  externalTrafficPolicy: Local
```

Apply the patch:
```bash
kubectl patch svc echoserver-nodeport -n net-security-test --patch-file patch-local.yaml
```
*Expected Output:*
```text
service/echoserver-nodeport patched
```

4. **Step 4**: Re-inspect the `iptables` rules generated by `kube-proxy` for `30080`.
```bash
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') -it --image=alpine -- sh -c "apk add --no-cache iptables >/dev/null 2>&1; iptables-save | grep 30080"
```
*Expected Output:*
```text
-A KUBE-NODEPORTS -p tcp -m comment --comment "net-security-test/echoserver-nodeport:" -m tcp --dport 30080 -j KUBE-XLB-WBX7M4O4KQKZ2V3X
-A KUBE-XLB-WBX7M4O4KQKZ2V3X -m comment --comment "net-security-test/echoserver-nodeport local retrieves" -m balancer --mode rc -j KUBE-SEP-EG6G4X3J77Y5L2RR
```
*(Notice the chain shifts from `KUBE-SVC-*` to `KUBE-XLB-*` (External Load Balancer/NodePort Local chain), bypassing `KUBE-MARK-MASQ` for local endpoints and retaining the true client IP).*

5. **Step 5**: Cleanup test resources.
```bash
kubectl delete ns net-security-test
```

---

#### Verification Questions - Exercise 2
1. **Q2.1**: What is the architectural trade-off when changing `externalTrafficPolicy` from `Cluster` to `Local`?
2. **Q2.2**: What happens to incoming NodePort traffic hitting a node that has **no** active Pod replicas for that Service when `externalTrafficPolicy: Local` is configured?

---

### Exercise 3: Validating Network Policy Boundaries & KubeProxy Isolation Limits

#### Scenario
A junior developer assumes that `kube-proxy` enforces `NetworkPolicy` objects and that configuring services automatically blocks unauthorized cross-namespace pod traffic. You must empirically demonstrate that `kube-proxy` does NOT enforce `NetworkPolicy` rules without a CNI provider plugin installed.

#### Steps

1. **Step 1**: Create two isolated namespaces (`secure-backend` and `untrusted-frontend`).
```bash
kubectl create namespace secure-backend
kubectl create namespace untrusted-frontend
```

2. **Step 2**: Deploy a target application in `secure-backend` and define a strict `NetworkPolicy` intended to deny all ingress traffic unless labeled `role: authorized`.

Save manifest as `backend-with-netpol.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api
  namespace: secure-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-api
  template:
    metadata:
      labels:
        app: secure-api
    spec:
      containers:
      - name: api
        image: registry.k8s.io/e2e-test-images/agnhost:2.43
        command: ["/agnhost", "netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: secure-api-svc
  namespace: secure-backend
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: secure-api
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ingress-by-default
  namespace: secure-backend
spec:
  podSelector:
    matchLabels:
      app: secure-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: authorized
```

Apply the manifest:
```bash
kubectl apply -f backend-with-netpol.yaml
kubectl wait --for=condition=available deployment/secure-api -n secure-backend --timeout=60s
```

3. **Step 3**: Launch an unauthorized client pod in `untrusted-frontend` and test connection to `secure-api-svc.secure-backend.svc.cluster.local`.
```bash
kubectl run attacker-pod -n untrusted-frontend --image=curlimages/curl:8.5.0 --rm -i --tty -- restart='Never' -- curl -i -s --connect-timeout 5 http://secure-api-svc.secure-backend.svc.cluster.local:8080/version
```

4. **Step 4**: Evaluate the result.
* **If CNI plugin with NetworkPolicy support (e.g., Calico, Cilium) IS installed**: Connection times out.
* **If CNI plugin does NOT support NetworkPolicy (e.g., Flannel default) and ONLY `kube-proxy` is running**: Connection succeeds (`HTTP/1.1 200 OK`).

*Output in non-enforcing environment:*
```text
HTTP/1.1 200 OK
Date: Fri, 07 Aug 2026 19:37:42 GMT
Content-Length: 12
Content-Type: text/plain; charset=utf-8

agnhost 2.43
pod "attacker-pod" deleted
```

5. **Step 5**: Cleanup resources.
```bash
kubectl delete ns secure-backend untrusted-frontend
```

---

#### Verification Questions - Exercise 3
1. **Q3.1**: Does `kube-proxy` create or manipulate kernel rules for `NetworkPolicy` objects? Which layer of the Kubernetes architecture is responsible for enforcing `NetworkPolicy`?
2. **Q3.2**: In an environment using Cilium in eBPF host-routing mode with `kubeProxyReplacement: true`, what happens to the standard `kube-proxy` DaemonSet?

---

## 3. Answers & Detailed Explanations

<details>
<summary>Click to expand Answers & Detailed Explanations</summary>

### Exercise 1 Answers

* **Q1.1 Answer**:
  `kube-proxy` needs to manipulate kernel-level network configuration objects on the host (such as modifying `iptables` tables/chains, updating `ipvs` virtual server tables, or configuring `ipset` set definitions). To do this from inside a container using the node's network namespace (`hostNetwork: true`), the container process must possess the `CAP_NET_ADMIN` Linux capability (or run as fully `privileged`).

* **Q1.2 Answer**:
  Binding `metricsBindAddress` to `0.0.0.0:10249` exposes the HTTP `/metrics` endpoint on all physical and virtual network interfaces of the node. If the node's management port is exposed to the internet or an untrusted VPC, unauthenticated external actors can scan port `10249` to scrape Prometheus metrics. This leaks sensitive operational telemetry, including service names, internal IP allocation patterns, packet count statistics, and cluster scale metrics.

---

### Exercise 2 Answers

* **Q2.1 Answer**:
  * **`externalTrafficPolicy: Cluster`**: Maximize availability and load distribution across all Pods in the cluster. If traffic arrives on Node A, but Node A has no local Pods for that Service, `kube-proxy` routes the packet across the overlay network to Node B (causing an extra network hop). To ensure Node B can return traffic back through Node A properly, `kube-proxy` performs Source Network Address Translation (SNAT), overwriting the original client IP with Node A's IP address.
  * **`externalTrafficPolicy: Local`**: Eliminates cross-node routing and SNAT, preserving the original client source IP address for ingress packets. However, it introduces two trade-offs:
    1. Potential uneven load balancing if Pod distribution across nodes is non-uniform.
    2. Drops packets hitting nodes that have zero local endpoints for that Service (unless coupled with an external load balancer using health checks on `healthCheckNodePort`).

* **Q2.2 Answer**:
  When `externalTrafficPolicy: Local` is active, `kube-proxy` creates `iptables`/`ipvs` rules that immediately drop packets or refuse connections arriving on a node's NodePort if no healthy local pod instances are running on that specific node. External Load Balancers (like AWS NLB or GCP ILB) rely on `healthCheckNodePort` (default port 30256 range) exposed by `kube-proxy` to dynamically exclude nodes without local endpoints from target groups.

---

### Exercise 3 Answers

* **Q3.1 Answer**:
  **No.** `kube-proxy` is strictly a Service proxy responsible for load-balancing traffic directed at `ClusterIP`, `NodePort`, and `ExternalName` IPs to `EndpointSlices`. It completely ignores `NetworkPolicy` resources. 
  The **CNI (Container Network Interface) plugin** (e.g., Calico, Cilium, Antrea, Weave Net) is exclusively responsible for interpreting `NetworkPolicy` objects and programming interface-level or eBPF/iptables packet filtering rules (e.g., via `tc`, `xt_physdev`, or eBPF map lookups) to block or allow pod-to-pod east-west traffic.

* **Q3.2 Answer**:
  When a CNI like Cilium operates with `kubeProxyReplacement: true`, Cilium's eBPF programs handle `ClusterIP`, `NodePort`, `LoadBalancer`, and `externalIPs` service routing directly in the socket layer (`BPF_PROG_TYPE_CGROUP_SOCK`) and network driver interfaces. In this architecture, the legacy `kube-proxy` DaemonSet is rendered redundant and can be completely removed from the cluster (`kubectl delete ds kube-proxy -n kube-system`), saving node memory and eliminating Netfilter/iptables lock contention entirely.

</details>