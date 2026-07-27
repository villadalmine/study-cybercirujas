# Guided Exercises — CKAD 5.2: Provide and troubleshoot access to applications via services

> Reference: [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf).

## Setup

Before starting, create a dedicated namespace to avoid interfering with other cluster resources.

1. Create working namespace:
   ```bash
   kubectl create namespace ckad-5-2
   kubectl config set-context --current --namespace=ckad-5-2
   ```
2. Verify context points to correct namespace:
   ```bash
   kubectl config view --minify | grep namespace
   ```

---

## Block 1 — Exposing a Deployment with a `ClusterIP` Service

1. Create a simple Deployment based on `nginx`:
   ```bash
   kubectl create deployment web --image=nginx:1.27 --replicas=3
   ```
2. Wait for Pods to reach `Running` state:
   ```bash
   kubectl get pods -l app=web -w
   ```
   (`Ctrl+C` when all 3 reach `1/1 Running`).
3. Expose Deployment with a `ClusterIP` Service (default type) on port 80:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 --name=web-svc
   ```
4. Inspect created Service:
   ```bash
   kubectl get svc web-svc -o wide
   ```
5. List associated **Endpoints** (Pod IP addresses load balanced by Service):
   ```bash
   kubectl get endpoints web-svc
   ```
6. Launch a temporary Pod in same namespace testing access via `ClusterIP` and Service name:
   ```bash
   kubectl run tmp-client --image=busybox:1.36 --rm -it --restart=Never -- \
     sh -c "wget -qO- http://web-svc && echo OK"
   ```

**Verification Questions**

- Which Service field determines target Pods receiving traffic, and which Pod field must match it?
- If `kubectl get endpoints web-svc` displays three IPs, how do those IPs relate to Pod IPs (`kubectl get pods -o wide`)?
- Why does `kubectl expose deployment` select Deployment labels automatically without manual specification?

---

## Block 2 — Troubleshooting: Service Lacking Endpoints Due to Selector Mismatch

Common failure scenario: Service exists with a ClusterIP but routes traffic to zero Pods.

1. Intentionally break Service selector by editing it:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web-wrong"}}}'
   ```
2. Confirm Service still exists with ClusterIP:
   ```bash
   kubectl get svc web-svc
   ```
3. Inspect Endpoints now:
   ```bash
   kubectl get endpoints web-svc
   ```
4. Use `describe` to view full diagnostics, including active selector:
   ```bash
   kubectl describe svc web-svc
   ```
5. Compare Service selector against actual Pod labels:
   ```bash
   kubectl get pods --show-labels
   ```
6. Fix selector to match Pod labels:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"selector":{"app":"web"}}}'
   kubectl get endpoints web-svc
   ```

**Verification Questions**

- What output does `kubectl get endpoints web-svc` display when selector matches zero Pods?
- Why does Service remain in active status (`kubectl get svc` displays normal `ClusterIP`) even with empty endpoints?
- With a `headless` Service (`clusterIP: None`), how would detecting this issue differ?

---

## Block 3 — Troubleshooting: `targetPort` Mismatching Container Port

1. Edit Service to point to a `targetPort` unmonitored by Nginx:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'
   ```
2. Confirm Endpoints still list Pod IPs (unlike Block 2):
   ```bash
   kubectl get endpoints web-svc
   ```
3. Attempt accessing Service from a temporary Pod:
   ```bash
   kubectl run tmp-client2 --image=busybox:1.36 --rm -it --restart=Never -- \
     wget -qO- --timeout=3 http://web-svc
   ```
4. Observe connection timeout and confirm container actual listening port:
   ```bash
   kubectl exec deploy/web -- ss -tlnp
   ```
5. Fix `targetPort` matching actual listening port (80):
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"ports":[{"port":80,"targetPort":80}]}}'
   ```
6. Re-run `wget` from step 3 to confirm success.

**Verification Questions**

- Why do Endpoints list Pod IPs in this scenario unlike Block 2, despite access failing?
- What is the difference between `port`, `targetPort`, and `nodePort` in a Service spec?
- Which command inside container confirms actual process listening ports without relying on image documentation?

---

## Block 4 — External Access via `NodePort`

1. Change Service to `NodePort` type:
   ```bash
   kubectl patch svc web-svc -p '{"spec":{"type":"NodePort"}}'
   ```
2. Inspect auto-assigned NodePort within 30000-32767 range:
   ```bash
   kubectl get svc web-svc
   ```
3. Retrieve node IP address:
   ```bash
   kubectl get nodes -o wide
   ```
4. Test access combining node IP + NodePort (replace `<NODE_IP>` and `<NODE_PORT>`):
   ```bash
   curl http://<NODE_IP>:<NODE_PORT>
   ```
5. If `curl` fails while Service and Endpoints are healthy, inspect external firewalls/`NetworkPolicies` blocking NodePort ranges.

**Verification Questions**

- What advantage does `NodePort` provide over `ClusterIP` for external testing, and what limitation exists compared to `LoadBalancer`?
- A `NodePort` Service reserves the port across **all** cluster nodes. Why does this permit access via any node IP, even nodes hosting no Deployment Pods?

---

## Block 5 — Cross-Namespace DNS & Service Discovery

1. Create a second namespace and a client Pod inside it:
   ```bash
   kubectl create namespace ckad-5-2-other
   kubectl run tmp-client3 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     nslookup web-svc.ckad-5-2.svc.cluster.local
   ```
2. Attempt short name resolution (omitting namespace) from `ckad-5-2-other` namespace:
   ```bash
   kubectl run tmp-client4 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     nslookup web-svc
   ```
3. Confirm FQDN resolution works across any namespace:
   ```bash
   kubectl run tmp-client5 -n ckad-5-2-other --image=busybox:1.36 --rm -it --restart=Never -- \
     wget -qO- http://web-svc.ckad-5-2.svc.cluster.local
   ```
4. Inspect `kube-dns`/`coredns` Service verifying CoreDNS health:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   ```

**Verification Questions**

- What full FQDN structure does CoreDNS generate for a Service, and which components are fixed vs variable?
- Why does `nslookup web-svc` without namespace fail when queried from a different namespace?
- If a Pod fails resolving even `kubernetes.default.svc.cluster.local`, which cluster component is primary suspect?

---

## Block 6 — Readiness Probes Impact on Endpoints

1. Edit Deployment adding a `readinessProbe` pointing to non-existent path:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/no-existe","port":80},"periodSeconds":5}}]}}}}'
   ```
2. Wait for rollout status and observe `READY` column:
   ```bash
   kubectl rollout status deployment/web
   kubectl get pods -l app=web
   ```
3. Confirm Pods report `Running` but **not** `Ready` (e.g. `0/1`).
4. Inspect Service Endpoints while Pods remain unready:
   ```bash
   kubectl get endpoints web-svc
   ```
5. Fix probe pointing to valid path (`/`) and confirm Endpoints repopulate:
   ```bash
   kubectl patch deployment web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","readinessProbe":{"httpGet":{"path":"/","port":80},"periodSeconds":5}}]}}}}'
   kubectl rollout status deployment/web
   kubectl get endpoints web-svc
   ```

**Verification Questions**

- Why does a `Running` but unready Pod get excluded from Service Endpoints automatically?
- What practical diagnostic difference distinguishes selector mismatch (Block 2) vs failing readiness probes (Block 6)?

---

## Teardown

```bash
kubectl delete namespace ckad-5-2 ckad-5-2-other
kubectl config set-context --current --namespace=default
```

---

<details>
<summary>View Answers</summary>

**Block 1**
- Service `spec.selector` (key-value pairs) selects Pods matching `metadata.labels`.
- IPs in `endpoints` correspond to Pod IP addresses (`podIP`) of ready replicas matching selector.
- `kubectl expose` inherits selector from Deployment `spec.template.metadata.labels`.

**Block 2**
- Displays `<none>`, indicating no Pods match selector.
- Service objects exist independently of Endpoints; ClusterIP remains assigned.
- Headless Services omit ClusterIP; DNS queries return zero `A`/`AAAA` records when selector matches zero Pods.

**Block 3**
- Selector matches Pod labels (Endpoints controller tracks readiness and labels, not port responsiveness), but traffic forwards to wrong container port.
- `port`: Service exposure port; `targetPort`: container listening port; `nodePort`: external node port.
- Run `ss -tlnp` or `netstat -tlnp` inside container to inspect listening TCP ports.

**Block 4**
- `NodePort` provides external access without cloud provider load balancers.
- `kube-proxy` configures routing rules (iptables/IPVS) across all cluster nodes forwarding NodePort traffic to matching Pods anywhere in cluster.

**Block 5**
- `<service-name>.<namespace>.svc.cluster.local`.
- Unqualified names resolve strictly within Pod's local namespace via DNS search domains.
- CoreDNS (`kube-system` Pods with `k8s-app=kube-dns`).

**Block 6**
- Endpoint controller includes only Pods passing readiness checks (`Ready: true`).
- Selector mismatch shows `READY 1/1` Pods with empty endpoints; readiness failure shows `READY 0/1` Pods with empty endpoints.

</details>
