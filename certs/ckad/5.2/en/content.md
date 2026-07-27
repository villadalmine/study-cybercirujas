# 5.2 Provide and troubleshoot access to applications via services

## Why Services Exist

Pods are ephemeral: when a Pod dies and is replaced (by a Deployment, ReplicaSet, etc.), it receives a new IP address. If other applications depended directly on individual Pod IPs, every restart would break connectivity. A **Service** resolves this issue by providing a stable endpoint (virtual IP + DNS name) that routes traffic to matching Pods backed by a label `selector`, regardless of Pod churn.

## How a Service Selects Pods

A Service uses `spec.selector` to match Pods by labels. The control plane automatically manages an `Endpoints` object (or `EndpointSlice` in modern clusters) containing `IP:port` pairs of matching Pods, filtering for Pods passing their **readiness probe**. A Pod in `Running` status but `NotReady` is excluded from Endpoints, even if its container process is active.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80          # Port exposed by Service
      targetPort: 8080  # Container listening port inside Pod
  type: ClusterIP
```

Three port fields frequently tested during the exam:

| Field | Location | Description |
|---|---|---|
| `port` | Service | Port where external/internal clients contact the Service |
| `targetPort` | Service → Pod | Port where the container listens inside the Pod |
| `nodePort` | Service (NodePort type) | Port exposed across all cluster Nodes (30000-32767) |

## Service Types

- **ClusterIP** (default): Internal virtual IP, accessible strictly within cluster network.
- **NodePort**: Extends ClusterIP by exposing a static port across all cluster Nodes (`<NodeIP>:<nodePort>`). Useful for simple external access or testing.
- **LoadBalancer**: Requests an external cloud provider load balancer (provisions NodePort + ClusterIP internally). Without a cloud provider, `EXTERNAL-IP` remains in `<pending>`.
- **ExternalName**: Has no selectors or Endpoints; maps Service to an external DNS CNAME record. References external resources outside cluster using a consistent internal DNS name.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-externo
spec:
  type: ExternalName
  externalName: db.company.com
```

### Headless Service

Setting `clusterIP: None` disables virtual IP allocation and kube-proxy load balancing. DNS queries for the Service return direct `A`/`AAAA` records targeting backing Pod IPs. Primarily used by StatefulSets for stable network identities per replica.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db-headless
spec:
  clusterIP: None
  selector:
    app: db
  ports:
    - port: 5432
```

## Imperative Service Creation

```bash
kubectl create deployment web --image=nginx --replicas=3

# Expose Deployment as ClusterIP
kubectl expose deployment web --port=80 --target-port=80 --name=web

# Expose as NodePort
kubectl expose deployment web --port=80 --target-port=80 --type=NodePort --name=web-np
```

```bash
kubectl get svc web
```
```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.45.201   <none>        80/TCP    5s
```

## Internal DNS Resolution

CoreDNS automatically registers every Service using this pattern:

```
<service-name>.<namespace>.svc.cluster.local
```

From Pods in the same namespace, `<service-name>` suffices (`web`); cross-namespace calls require `web.default.svc.cluster.local` (or `web.default`).

```bash
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web.default.svc.cluster.local
```
```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web.default.svc.cluster.local
Address:   10.96.45.201
```

## Session Affinity

By default, requests are load balanced round-robin across Pods. To pin client requests to the same Pod for a duration (useful for stateful sessions without external stores):

```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

## Troubleshooting Workflow

Follow an outside-in diagnostic path: Service → Endpoints → Pods → Container.

### 1. Service Has Missing/Empty Endpoints

Most common root cause for application unreachable errors: Service `selector` mismatch against actual Pod labels.

```bash
kubectl get endpoints web
```
```
NAME   ENDPOINTS   AGE
web    <none>      2m
```

```bash
kubectl describe svc web
```
```
Name:              web
Selector:          app=web
...
Endpoints:         <none>
```

```bash
kubectl get pods --show-labels
```
```
NAME              READY   STATUS    RESTARTS   AGE   LABELS
web-6b9f7c-abcde  1/1     Running   0          3m    app=frontend
```

Pod carries `app=frontend` while Service searches for `app=web`. Fix by aligning labels or selector:

```bash
kubectl label pod web-6b9f7c-abcde app=web --overwrite
```

### 2. Pod Matches Selector But Absent From Endpoints

Examine readiness probe status: failing readiness probes keep Pods out of Endpoints even if `STATUS` is `Running`.

```bash
kubectl get pods -o wide
```
```
NAME              READY   STATUS    RESTARTS   AGE
web-6b9f7c-abcde  0/1     Running   0          1m
```

`0/1` in `READY` column indicates container runs, but readiness checks fail.

```bash
kubectl describe pod web-6b9f7c-abcde
```
```
Warning  Unhealthy  10s  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
```

### 3. `targetPort` Mismatches Container Listening Port

Endpoints may exist but point to an unmonitored port.

```bash
kubectl exec -it web-6b9f7c-abcde -- ss -tlnp
```
```
State   Local Address:Port
LISTEN  0.0.0.0:8080
```

If Service specifies `targetPort: 80` while container listens on `8080`, update Service manifest `targetPort`.

### 4. Test Internal Connectivity Inside Cluster

```bash
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://web.default.svc.cluster.local
```

If this fails while direct `curl` to Pod IP succeeds, issue resides in Service layer (selector, ports, kube-proxy), not application layer.

```bash
kubectl get pods -o wide | grep web
# grab Pod IP and test directly
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- http://10.244.1.15:8080
```

### 5. `port-forward` for Problem Isolation

Bypass Service layer entirely to verify Pod responsiveness:

```bash
kubectl port-forward pod/web-6b9f7c-abcde 8080:8080
curl localhost:8080
```

If direct `port-forward` succeeds but Service fails, issue lies in Service/Endpoints layer.

### 6. NetworkPolicy Blocking Traffic

If Endpoints are populated, ports align, and direct `port-forward` succeeds, but cross-namespace Service access fails, check for restrictive `NetworkPolicy`:

```bash
kubectl get networkpolicy -A
```

### 7. `EXTERNAL-IP` Stuck in `<pending>` (LoadBalancer)

Expected behavior in local non-cloud clusters (kind, minikube without `minikube tunnel`, bare-metal without MetalLB). Not a manifest bug.

```bash
kubectl get svc web-lb
```
```
NAME     TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-lb   LoadBalancer   10.96.88.12    <pending>     80:31900/TCP   1m
```

Access remains available via auto-generated `nodePort` (`31900` in example above) using any Node IP.

## Rapid Exam Troubleshooting Checklist

1. `kubectl get svc <name>` — Verify existence, type, and port mappings.
2. `kubectl get endpoints <name>` — Verify non-empty `IP:port` entries exist.
3. If Endpoints missing → compare `kubectl describe svc` (Selector) vs `kubectl get pods --show-labels`.
4. If Endpoints present but connection fails → compare `targetPort` against actual listening container port (`kubectl exec ... ss -tlnp` or container inspect).
5. Inspect readiness probes (`READY` column, `kubectl describe pod`).
6. Spin temporary diagnostic Pod (`kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh`) using `wget`/`nslookup` to isolate DNS vs network vs app failures.

## References

- Service concepts: https://kubernetes.io/docs/concepts/services-networking/service/
- Connecting Applications with Services: https://kubernetes.io/docs/tutorials/services/connect-applications-service/
- DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
