# CNCF KCSA Study Guide: Domain 2.6 – KubeProxy

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Kubernetes Cluster Component Security (Weight: 22%)  
**Subtopic:** 2.6 KubeProxy (Topic Weight: 2.0%)  

---

## 1. Production Architectural Motivation & Problem

### Architectural Role
`kube-proxy` is the network proxy daemon that runs on every node in a Kubernetes cluster. It reflects Kubernetes `Service` and `Endpoint` / `EndpointSlice` objects defined in the API server by manipulating host-level Linux kernel packet filtering and routing mechanisms (such as `iptables`, `IPVS`, or `nftables`). Its core function is to implement Virtual IP (VIP) networking and Layer 4 load balancing for cluster-internal (`ClusterIP`) and external (`NodePort`, `LoadBalancer`) traffic.

```
                   +-----------------------------------------------+
                   |                  Control Plane                |
                   |               kube-apiserver                  |
                   +-----------------------+-----------------------+
                                           | Watch (Services/EndpointSlices)
                                           v
+---------------------------------------------------------------------------------+
| Worker Node                                                                     |
|  +-------------------+        Modifies        +------------------------------+  |
|  |    kube-proxy     | ---------------------> | Host Linux Kernel Networking |  |
|  |   (DaemonSet)     |                        | (iptables / IPVS / nftables) |  |
|  +-------------------+                        +--------------+---------------+  |
|                                                              |                  |
|  Inbound Traffic ---> [ NodePort / ClusterIP ] --------------+                  |
|                                                              |                  |
|                                            +-----------------+-----------------+  |
|                                            | DNAT / Load Balancing             |  |
|                                            v                                   v  |
|                                    +---------------+                   +---------------+  |
|                                    | Pod A (Local) |                   | Pod B (Remote)|  |
|                                    +---------------+                   +---------------+  |
+---------------------------------------------------------------------------------+
```

### Production Security & Operational Problems

1. **Privileged Host Access & Expanded Attack Surface:**
   To mutate host kernel netfilter tables, IPVS sets, or raw sockets, `kube-proxy` typically requires elevated host privileges (`privileged: true` or Linux capabilities `CAP_NET_ADMIN` and `CAP_NET_RAW`) alongside access to the host network namespace (`hostNetwork: true`). If an attacker compromises a `kube-proxy` pod or exploits an unauthenticated metrics/health endpoint, they inherit low-level network manipulation rights on the host node, enabling traffic interception, ARP/IP spoofing, and man-in-the-middle (MitM) attacks.

2. **$O(N)$ Rule Scaling Complexity (iptables mode):**
   In `iptables` mode, every Service and Endpoint is evaluated sequentially. A cluster with 10,000 Services and 50,000 Endpoints creates hundreds of thousands of sequential iptables rules. Sequential rule evaluation incurs high CPU overhead per packet and induces kernel write locks (`iptables-restore` lock contention), resulting in packet processing latency spikes and prolonged synchronization delays during rapid scaling events.

3. **Source IP Obfuscation & Security Policy Evasion:**
   By default, `kube-proxy` performs Source Network Address Translation (SNAT) on inter-node Service traffic to ensure return packets traverse the originating node (handling asymmetric routing). This replaces the client’s real source IP with the node’s internal IP address. Security mechanisms such as NetworkPolicies, Web Application Firewalls (WAFs), Intrusion Detection Systems (IDS), and audit logging mechanisms lose visibility into true client identity, rendering IP-based access control lists (ACLs) ineffective unless `externalTrafficPolicy: Local` is explicitly enforced.

4. **Unrestricted Interface Binding (NodePort Risk):**
   By default, `kube-proxy` configures NodePort rules across all network interfaces on a node (`0.0.0.0`). In multi-homed nodes or environments where nodes possess both public (internet-facing) and private management network interfaces, internal Services of type `NodePort` are inadvertently exposed on public interfaces unless restricted via the `nodePortAddresses` configuration flag.

---

## 2. Technical Comparisons & Trade-off Tables

### Proxy Modes Architecture

*   **iptables Mode:** Relies on Linux `netfilter` hooks (`PREROUTING`, `POSTROUTING`, `KUBE-SERVICES`, `KUBE-NODEPORTS`). Rule updates use sequential `iptables-restore` calls. Packet selection uses `statistic` module random probability distribution ($1/N$).
*   **IPVS Mode:** Built on the Netfilter framework using IP Virtual Server (IPVS) hash tables ($O(1)$ complexity). Uses `ipset` data structures to store IP addresses and ports, reducing netfilter chain depth significantly.
*   **nftables Mode:** Replaces legacy `iptables` using modern kernel `nftables` bytecode. Offers better scaling than `iptables` while maintaining explicit state tables without legacy lock contention.
*   **eBPF (CNI-Integrated, e.g., Cilium):** Completely replaces `kube-proxy` by compiling C-like eBPF programs directly into socket layer and eXtensible Data Path (XDP) kernel hooks. Bypasses the netfilter stack entirely for $O(1)$ direct routing.

### Comprehensive Comparison Matrix

| Feature / Metric | `iptables` Mode | `IPVS` Mode | `nftables` Mode | `eBPF` (kube-proxy Replacement) |
| :--- | :--- | :--- | :--- | :--- |
| **Kernel Subsystem** | Netfilter (`iptables`) | IPVS & `ipset` | Netfilter (`nftables`) | eBPF (tc, socket ops, XDP) |
| **Algorithmic Complexity** | $O(N)$ (Sequential chain processing) | $O(1)$ (Hash table lookup) | $O(\log N)$ / $O(1)$ (Set lookups) | $O(1)$ (BFP map lookup) |
| **Rule Sync Performance** | Slow at scale ($>5k$ Services); atomic chain replace | Fast ($>100k$ Endpoints); dynamic update | Fast; atomic bytecode transaction | Near-instantaneous; lockless map updates |
| **Load Balancing Algorithms** | Random probability (`statistic` module) | Round-Robin, Least-Conn, Source/Dest Hash, Weighted | Weighted Random, Sets | Round-Robin, Maglev, Least-Conn, Random |
| **Host Privilege Requirement** | `CAP_NET_ADMIN`, `CAP_NET_RAW` | `CAP_NET_ADMIN`, `CAP_NET_RAW` + IPVS kernel modules | `CAP_NET_ADMIN` | `CAP_BPF`, `CAP_NET_ADMIN`, `CAP_SYS_ADMIN` |
| **Source IP Preservation** | Requires `externalTrafficPolicy: Local` | Requires `externalTrafficPolicy: Local` | Requires `externalTrafficPolicy: Local` | Native direct server return (DSR) support |
| **Conntrack Dependency** | High (Heavy dependency on `nf_conntrack`) | High (Uses `ip_vs` & `nf_conntrack`) | Moderate | Low / Optional (Bypasses `conntrack`) |

---

## 3. Production-Ready YAML & Infrastructure Manifests

### 3.1 Hardened `KubeProxyConfiguration` ConfigMap

This manifest enforces security hardening: explicitly binding metrics to localhost/internal IPs, restricting NodePort interfaces, configuring IPVS mode with strict ARP for CNI compatibility (e.g., MetalLB/Cilium), and tuning Linux `conntrack` limits to prevent Denial of Service (DoS) conditions.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy-production-config
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-proxy
    app.kubernetes.io/part-of: kube-system
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "ipvs"
    bindAddress: "0.0.0.0"
    healthzBindAddress: "127.0.0.1:10256"
    metricsBindAddress: "127.0.0.1:10249"
    enableProfiling: false
    showHiddenMetricsForVersion: ""
    clientConnection:
      acceptContentTypes: ""
      burst: 100
      contentType: "application/vnd.kubernetes.protobuf"
      qps: 50
    iptables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 2s
      syncPeriod: 30s
      localhostNodePorts: true
    ipvs:
      minSyncPeriod: 2s
      syncPeriod: 30s
      scheduler: "rr"
      strictARP: true
      tcpTimeout: 0s
      tcpFinTimeout: 0s
      udpTimeout: 0s
      excludeCIDRs: []
    nodePortAddresses:
      - "10.240.0.0/16"
    conntrack:
      maxPerCore: 32768
      min: 131072
      tcpEstablishedTimeout: 86400s
      tcpCloseWaitTimeout: 1h
```

### 3.2 Secure `kube-proxy` DaemonSet Manifest

This manifest adopts security best practices: dropping unnecessary capabilities, running with a `readOnlyRootFilesystem`, enforcing a non-root environment where possible (with explicit required Linux network capabilities), setting security contexts, and assigning strict resource requests and limits.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    k8s-app: kube-proxy
    app.kubernetes.io/name: kube-proxy
    app.kubernetes.io/component: network
spec:
  selector:
    matchLabels:
      k8s-app: kube-proxy
  template:
    metadata:
      labels:
        k8s-app: kube-proxy
    spec:
      hostNetwork: true
      priorityClassName: system-node-critical
      serviceAccountName: kube-proxy
      terminationGracePeriodSeconds: 30
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
          effect: NoSchedule
        - operator: Exists
          effect: NoExecute
      securityContext:
        runAsNonRoot: false
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kube-proxy
          image: registry.k8s.io/kube-proxy:v1.30.2
          command:
            - /usr/local/bin/kube-proxy
            - --config=/var/lib/kube-proxy/config.conf
            - --v=2
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - NET_ADMIN
                - NET_RAW
                - SYS_MODULE
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: kube-proxy-config
              mountPath: /var/lib/kube-proxy
            - name: xtables-lock
              mountPath: /run/xtables.lock
              readOnly: false
            - name: sys-fs
              mountPath: /sys
              readOnly: true
            - name: modules
              mountPath: /lib/modules
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 10256
              host: 127.0.0.1
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 10256
              host: 127.0.0.1
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
      volumes:
        - name: kube-proxy-config
          configMap:
            name: kube-proxy-production-config
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
        - name: sys-fs
          hostPath:
            path: /sys
            type: Directory
        - name: modules
          hostPath:
            path: /lib/modules
            type: Directory
```

### 3.3 Zero-Trust Production Service Manifest with Source IP Preservation

This Service leverages `externalTrafficPolicy: Local` to preserve client source IPs for ingress auditing and uses `internalTrafficPolicy: Local` to keep intra-node traffic local, eliminating extra network hops.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-gateway-secure
  namespace: production
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/component: api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  internalTrafficPolicy: Local
  allocateLoadBalancerNodePorts: true
  selector:
    app.kubernetes.io/name: payment-gateway
  ports:
    - name: https
      port: 443
      targetPort: 8443
      nodePort: 32443
      protocol: TCP
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Verifying kube-proxy Deployment & Health Status

```bash
$ kubectl get daemonset kube-proxy -n kube-system -o wide
```
**Expected Output:**
```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE   CONTAINERS   IMAGES                                  SELECTOR
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   42d   kube-proxy   registry.k8s.io/kube-proxy:v1.30.2   k8s-app=kube-proxy
```

```bash
$ kubectl exec -n kube-system ds/kube-proxy -- curl -s http://127.0.0.1:10256/healthz
```
**Expected Output:**
```
{"lastUpdated": "2026-08-07 19:30:00.123456789 +0000 UTC m=+1234.567890123", "currentTime": "2026-08-07 19:30:05.123456789 +0000 UTC m=+1239.567890123"}
```

### 4.2 Inspecting `iptables` Mode Rules on a Cluster Node

```bash
$ sudo iptables -t nat -L KUBE-SERVICES -n -v | head -n 15
```
**Expected Output:**
```
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination         
    0     0 KUBE-SVC-NPXIX4V234123  tcp  --  *      *       0.0.0.0/0            10.96.0.10           /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
  142  8520 KUBE-SVC-T425234123412  tcp  --  *      *       0.0.0.0/0            10.96.14.22          /* production/payment-gateway-secure:https cluster IP */ tcp dpt:443
 1204 72240 KUBE-NODEPORTS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service nodeports; terminating search */ ADDRTYPE match dst-type LOCAL
```

```bash
$ sudo iptables -t nat -L KUBE-SVC-T425234123412 -n -v
```
**Expected Output:**
```
Chain KUBE-SVC-T425234123412 (1 references)
 pkts bytes target     prot opt in     out     source               destination         
   71  4260 KUBE-SEP-AAAA11112222  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */ statistic mode random probability 0.50000000000
   71  4260 KUBE-SEP-BBBB33334444  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */
```

### 4.3 Inspecting `IPVS` Virtual Server Tables and IP Sets

```bash
$ sudo ipvsadm -ln -t 10.96.14.22:443
```
**Expected Output:**
```
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.14.22:443 rr
  -> 10.244.1.45:8443             Masq    1      0          0         
  -> 10.244.2.89:8443             Masq    1      0          0         
```

```bash
$ sudo ipset list KUBE-CLUSTER-IP | head -n 12
```
**Expected Output:**
```
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 5
Header: family inet hashsize 1024 maxelem 65536 timeout 0 dynamic
Size in memory: 528 bytes
References: 2
Members:
10.96.0.1,tcp:443
10.96.0.10,udp:53
10.96.0.10,tcp:53
10.96.14.22,tcp:443
```

---

## 5. Verification & Troubleshooting Guide

### Diagnostic Decision Flowchart

```
                          [ Issue: Service Unreachable or High Latency ]
                                                |
                                                v
                                  [ Check kube-proxy Pod Logs ]
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
             (Kernel Netfilter Error)                               (API Error)
                      |                                                   |
                      v                                                   v
        [ Inspect conntrack & iptables ]                       [ Check RBAC & APIServer ]
                      |                                                   |
         +------------+------------+                             +--------+--------+
         |                         |                             |                 |
  (Table Full)             (Lock Contention)              (Token Expired)    (Watch Timeout)
         |                         |                             |                 |
         v                         v                             v                 v
[Increase sysctl      [Tune minSyncPeriod &        [Verify SA secret &    [Inspect APIServer
  conntrack_max]       switch mode to IPVS]         ClusterRoleBinding]    etcd health]
```

### Problem 1: Connection Tracking Table Exhaustion (`nf_conntrack: table full`)

*   **Symptom:** Intermittent connection timeouts, dropped TCP SYN packets, `dmesg` output shows `nf_conntrack: table full, dropping packet`.
*   **Root Cause:** Network traffic exceeds the allocated Linux kernel connection tracking limits defined by `net.netfilter.nf_conntrack_max`.

**Diagnostic Commands:**
```bash
$ sudo sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
```
*Output:*
```
net.netfilter.nf_conntrack_count = 262144
net.netfilter.nf_conntrack_max = 262144
```

**Resolution Strategy:**
Update the `conntrack` settings in the `KubeProxyConfiguration` ConfigMap (or directly via host `sysctl`):
```bash
$ sudo sysctl -w net.netfilter.nf_conntrack_max=524288
```

---

### Problem 2: Source IP Loss & Asymmetric Health Check Failures (`externalTrafficPolicy: Local`)

*   **Symptom:** Ingress LoadBalancer target groups report worker nodes as `Unhealthy`, or backend Pods receive traffic with node IPs instead of client IPs.
*   **Root Cause:** When `externalTrafficPolicy: Local` is configured, `kube-proxy` drops traffic routed to nodes that **do not run a local instance of the target Pod**. If the Cloud Load Balancer routes traffic to a node without local endpoint Pods, connection drops occur.

**Diagnostic Commands:**
```bash
$ kubectl get endpointslice -l kubernetes.io/service-name=payment-gateway-secure
```
*Output:*
```
NAME                           ADDRESSTYPE   PORTS   ENDPOINTS                  AGE
payment-gateway-secure-7x9zk   IPv4          8443    10.244.1.45,10.244.1.46   12m
```

```bash
$ kubectl get service payment-gateway-secure -n production -o jsonpath='{.spec.externalTrafficPolicy}'
```
*Output:*
```
Local
```

**Resolution Strategy:**
Ensure that external load balancers utilize the health check node port dynamically exposed by `kube-proxy` for Services with `externalTrafficPolicy: Local`.
```bash
$ kubectl get service payment-gateway-secure -n production -o jsonpath='{.spec.healthCheckNodePort}'
```
*Output:*
```
31892
```
Configure external load balancers to poll HTTP `GET /healthz` on port `31892` across all node IPs. Nodes returning `200 OK` possess local pod endpoints; nodes returning `503 Service Unavailable` have no local endpoints and will be removed from load balancer rotation.

---

### Problem 3: Unintended Exposure via NodePort `0.0.0.0` Binding

*   **Symptom:** Security scanners trigger alerts indicating internal cluster services are accessible via the node's public WAN interface over `NodePort`.
*   **Root Cause:** `kube-proxy` defaults to creating rules for all local host IP addresses.

**Diagnostic Commands:**
```bash
$ sudo iptables -t nat -L KUBE-NODEPORTS -n -v
```
*Output:*
```
Chain KUBE-NODEPORTS (1 references)
 pkts bytes target     prot opt in     out     source               destination         
   15   900 KUBE-SVC-T425234123412  tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            /* production/payment-gateway-secure:https */ tcp dpt:32443
```

**Resolution Strategy:**
Restrict `kube-proxy` to attach NodePorts strictly to the node's internal management network interface by modifying `nodePortAddresses` in `KubeProxyConfiguration`:
```yaml
nodePortAddresses:
  - "10.240.0.0/16"
```
Re-apply the ConfigMap and perform a rolling restart of the `kube-proxy` DaemonSet:
```bash
$ kubectl rollout restart daemonset/kube-proxy -n kube-system
```

---

### Problem 4: `iptables-restore` Lock Contention Under High Churn

*   **Symptom:** `kube-proxy` pod CPU utilization spikes to 100%, and logs display repeated `waiting for lock /run/xtables.lock` or sync timeout warnings.
*   **Root Cause:** Rapid pod creation/deletion events (e.g., autoscaling deployments) invoke concurrent `iptables` calls that contend for the system `xtables.lock`.

**Diagnostic Commands:**
```bash
$ kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=100 | grep -i "lock"
```
*Output:*
```
E0807 19:35:12.890123       1 server.go:842] "Error syncing iptables rules" err="exit status 4: Another app is currently holding the xtables lock; waiting (1s)..."
```

**Resolution Strategy:**
1. Increase `minSyncPeriod` in `KubeProxyConfiguration` from `0s` to `2s` to batch network rule updates.
2. Migrate from `iptables` mode to `IPVS` mode or eBPF-based CNI networking (such as Cilium).

---

## 6. References

*   **Kubernetes Official Documentation – Virtual IPs and Service Proxies:**  
    https://kubernetes.io/docs/concepts/services-networking/service/#virtual-ips-and-service-proxies
*   **Kubernetes Official Reference – KubeProxyConfiguration (v1alpha1):**  
    https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
*   **CNCF Official KCSA Curriculum Repository:**  
    https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
*   **Kubernetes Networking – Source IP Preservation:**  
    https://kubernetes.io/docs/tutorials/services/source-ip/
*   **Linux Kernel Netfilter & IPVS Documentation:**  
    https://www.kernel.org/doc/Documentation/networking/ipvs-sysctl.txt