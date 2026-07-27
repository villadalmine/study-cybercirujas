# Guided Exercises: Troubleshoot Services and Networking (CKA 2.5)

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working Kubernetes cluster (kubeadm, kind, etc.) with at least two nodes and an active CNI plugin (Calico, Cilium, etc.).

---

## Exercise 1 — Service Without Endpoints (Selector Mismatch)

1. Deploy a test Deployment:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   kubectl label pods -l app=web tier=frontend --overwrite
   ```
2. Expose a Service specifying an intentionally mismatched selector:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 --name=web-svc \
     --overrides='{"spec":{"selector":{"tier":"backend"}}}'
   ```
3. Inspect Service state:
   ```bash
   kubectl get svc web-svc
   kubectl describe svc web-svc
   ```
4. Inspect associated Endpoints and EndpointSlices:
   ```bash
   kubectl get endpoints web-svc
   kubectl get endpointslices -l kubernetes.io/service-name=web-svc
   ```
5. Compare Service selector keys against active Pod labels:
   ```bash
   kubectl get pods --show-labels -l app=web
   kubectl get svc web-svc -o jsonpath='{.spec.selector}{"\n"}'
   ```
6. Patch Service selector to match active Pod labels:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'
   ```
7. Confirm Endpoints populate correctly:
   ```bash
   kubectl get endpoints web-svc
   ```

**Comprehension Questions**

- Which field in `kubectl describe svc` indicates missing backends before checking Endpoints objects?
- Why does a Service lacking Endpoints return no errors in `kubectl get svc`?
- What distinguishes `Endpoints` from `EndpointSlices` resources?

---

## Exercise 2 — Pod Healthy but Excluded from Endpoints (Readiness Probe Failure)

1. Patch Deployment adding a failing readiness probe:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/no-existe","port":80},"periodSeconds":5}}]}}}}'
   ```
2. Track Deployment rollout and inspect Pod status:
   ```bash
   kubectl rollout status deployment/web
   kubectl get pods -l app=web -o wide
   ```
3. Observe `READY` column status (`0/1`) and inspect Pod events:
   ```bash
   kubectl describe pod -l app=web | grep -A5 Events
   ```
4. Verify failing Pods are excluded from Endpoints:
   ```bash
   kubectl get endpoints web-svc
   ```
5. Fix readiness probe pointing to a valid endpoint:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/","port":80},"periodSeconds":5}}]}}}}'
   ```
6. Confirm recovery:
   ```bash
   kubectl rollout status deployment/web
   kubectl get endpoints web-svc
   ```

**Comprehension Questions**

- Why might a Pod reporting `Running` status fail to receive Service traffic?
- What functional distinction separates `livenessProbe` vs `readinessProbe` regarding Service traffic routing?
- Where are probe failure details recorded for inspection?

---

## Exercise 3 — kube-proxy Troubleshooting (iptables Mode)

1. Identify active proxy mode:
   ```bash
   kubectl -n kube-system get configmap kube-proxy -o yaml | grep mode
   ```
2. Confirm `kube-proxy` DaemonSet Pods run across all nodes:
   ```bash
   kubectl -n kube-system get ds kube-proxy -o wide
   kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
   ```
3. Inspect `kube-proxy` logs:
   ```bash
   kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=50
   ```
4. SSH into host node and inspect iptables rules generated for target Service ClusterIP:
   ```bash
   kubectl get svc web-svc -o jsonpath='{.spec.clusterIP}{"\n"}'
   sudo iptables -t nat -L KUBE-SERVICES -n | grep <CLUSTER-IP>
   ```
5. Force `kube-proxy` Pod restart on target node:
   ```bash
   kubectl -n kube-system delete pod <kube-proxy-pod-on-node>
   ```
6. Test end-to-end Service connectivity from a temporary client Pod:
   ```bash
   kubectl run tmp-curl --rm -it --image=busybox --restart=Never -- \
     wget -qO- http://web-svc.default.svc.cluster.local
   ```

**Comprehension Questions**

- Which iptables chain serves as the entry point for `kube-proxy` Service rules?
- Which tool replaces `iptables` inspection when `kube-proxy` operates in `ipvs` mode?
- Why might restarting `kube-proxy` temporarily fix rule desynchronization?

---

## Exercise 4 — DNS Resolution Failures (CoreDNS)

1. Confirm CoreDNS Pods and Services are active:
   ```bash
   kubectl -n kube-system get pods -l k8s-app=kube-dns
   kubectl -n kube-system get svc kube-dns
   ```
2. Launch a diagnostic Pod:
   ```bash
   kubectl run dnsutils --rm -it --image=registry.k8s.io/e2e-test-images/agnhost:2.39 \
     --restart=Never -- /bin/sh
   ```
3. Test DNS resolution targeting `web-svc`:
   ```bash
   nslookup web-svc.default.svc.cluster.local
   cat /etc/resolv.conf
   ```
4. If resolution fails, inspect CoreDNS logs:
   ```bash
   kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
   ```
5. Inspect `Corefile` syntax in `coredns` ConfigMap:
   ```bash
   kubectl -n kube-system get configmap coredns -o yaml
   ```
6. Restart CoreDNS Deployment to reload updated configurations:
   ```bash
   kubectl -n kube-system rollout restart deployment coredns
   ```

**Comprehension Questions**

- What is the standard internal FQDN format for cluster Services?
- Which `/etc/resolv.conf` parameters affect short vs FQDN name resolution behavior?
- What distinguishes Pod-level DNS failures from cluster-wide CoreDNS outages?

---

## Exercise 5 — NetworkPolicy Isolation

1. Create a namespace and test workloads:
   ```bash
   kubectl create namespace netpol-test
   kubectl -n netpol-test create deployment server --image=nginx
   kubectl -n netpol-test expose deployment server --port=80
   kubectl -n netpol-test run client --image=busybox --restart=Never -- sleep 3600
   ```
2. Confirm initial connectivity:
   ```bash
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```
3. Apply a default-deny ingress NetworkPolicy targeting `server`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: deny-all-ingress
     namespace: netpol-test
   spec:
     podSelector:
       matchLabels:
         app: server
     policyTypes:
       - Ingress
   ```
   ```bash
   kubectl apply -f deny-all-ingress.yaml
   ```
4. Re-test connectivity and observe timeout:
   ```bash
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```
5. Update policy permitting ingress strictly from Pods carrying label `role=client`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-client-ingress
     namespace: netpol-test
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
                 role: client
   ```
6. Label client Pod and confirm connectivity restores:
   ```bash
   kubectl -n netpol-test label pod client role=client
   kubectl -n netpol-test exec client -- wget -qO- --timeout=3 http://server
   ```

**Comprehension Questions**

- Why does specifying `Ingress` under `policyTypes` leave `Egress` traffic unconstrained?
- What happens when NetworkPolicies are applied on CNI plugins lacking policy enforcement support?
- What separates omitting NetworkPolicies vs applying default-deny selector policies?

---

## Exercise 6 — Ingress Routing Failures

1. Inspect Ingress controller status:
   ```bash
   kubectl -n ingress-nginx get pods
   kubectl -n ingress-nginx get svc
   ```
2. Deploy an Ingress manifest pointing to an incorrect Service port number (8080):
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
     namespace: default
   spec:
     ingressClassName: nginx
     rules:
       - host: web.example.local
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: web-svc
                   port:
                     number: 8080
   ```
   ```bash
   kubectl apply -f web-ingress.yaml
   ```
3. Inspect Ingress resource details and events:
   ```bash
   kubectl describe ingress web-ingress
   ```
4. Inspect Ingress controller logs:
   ```bash
   kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=50
   ```
5. Patch Ingress to reference correct Service port (80):
   ```bash
   kubectl patch ingress web-ingress --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'
   ```

**Comprehension Questions**

- What separates L4 Service routing from L7 Ingress routing during troubleshooting?
- What role does `ingressClassName` play when multiple ingress controllers exist?
- Why do controller logs provide more detail than `kubectl describe ingress` when 502/503 errors occur?

---

## Exercise 7 — Pod-to-Pod Cross-Node CNI Networking

1. Identify node placement for Pods:
   ```bash
   kubectl get pods -l app=web -o wide
   ```
2. Test direct Pod IP connectivity from a client Pod running on a separate node:
   ```bash
   kubectl run tmp-ping --rm -it --image=busybox --restart=Never --overrides='{"spec":{"nodeName":"<node-B>"}}' -- \
     wget -qO- --timeout=3 http://<POD-IP-on-node-A>
   ```
3. If cross-node connectivity fails, inspect CNI daemonset Pod status across nodes:
   ```bash
   kubectl -n kube-system get pods -o wide | grep -Ei 'calico|cilium|flannel'
   ```
4. Check CNI agent logs on failing nodes:
   ```bash
   kubectl -n kube-system logs <cni-pod-on-node> --tail=50
   ```
5. Verify node routing tables and CNI interface states:
   ```bash
   ip route show
   ip addr show
   ```

**Comprehension Questions**

- Why does testing direct Pod IPs isolate CNI network issues from `kube-proxy` Service rules?
- What does `NetworkUnavailable` status indicate on Node objects?
- How do single-node CNI agent failures differ from cluster-wide IP pool misconfigurations?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- `Endpoints: <none>` in `kubectl describe svc` immediately indicates missing backends.
- Service objects and ClusterIP addresses are registered in API servers independently of backend Pod availability.
- `EndpointSlice` splits endpoints into scalable subsets of up to 100 entries per slice.

**Exercise 2**
- `readinessProbe` failures exclude Pods from Service Endpoints even while running.
- `livenessProbe` triggers container restarts; `readinessProbe` temporarily removes Pods from Endpoints pools without restarting.
- Probe failure details appear under `Events` in `kubectl describe pod`.

**Exercise 3**
- `KUBE-SERVICES` chain in `nat` tables.
- `ipvsadm -Ln` lists virtual/real servers managed by IPVS.
- `kube-proxy` restarts force complete iptables/IPVS rule resynchronization against API server state.

**Exercise 4**
- `<svc>.<namespace>.svc.cluster.local`.
- `ndots:5` forces queries with fewer than 5 dots to append search domains first before querying absolute FQDNs.
- Pod-level DNS issues affect specific Pod configurations; cluster-wide CoreDNS outages affect all internal DNS resolution.

**Exercise 5**
- Specifying only `Ingress` leaves `Egress` traffic governed by default allow-all rules.
- Applying NetworkPolicies on CNI plugins lacking enforcement support leaves all traffic unconstrained.
- Omitting NetworkPolicies permits all traffic by default; empty selector policies enforce default-deny isolation.

**Exercise 6**
- L4 Services route IP/port traffic; L7 Ingress processes HTTP headers and paths.
- `ingressClassName` binds Ingress resources to specific installed ingress controller drivers.
- Controller logs record upstream proxy interactions and HTTP error codes returned by backends.

**Exercise 7**
- Direct Pod IP testing bypasses `kube-proxy` NAT rules, isolating CNI routing failures.
- `NetworkUnavailable` indicates CNI plugins have not finished node network setup.
- Single-node CNI agent failures affect local node Pods; cluster-wide IP pool conflicts corrupt routing across all nodes.

</details>
