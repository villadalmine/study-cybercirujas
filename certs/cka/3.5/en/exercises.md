# Guided Exercises — 3.5 Configure Pod admission and scheduling

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working cluster with `kubectl` configured.

```bash
kubectl create namespace admission-lab
```

---

## Exercise 1 — `LimitRange`: Container Resource Defaults and Maximum Limits

1. Create a `LimitRange` defining resource defaults and maximum limits per container:

```yaml
# limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: cpu-mem-limits
  namespace: admission-lab
spec:
  limits:
    - type: Container
      default:
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:
        cpu: "250m"
        memory: "128Mi"
      max:
        cpu: "1"
        memory: "512Mi"
```

2. Apply resource manifest:

```bash
kubectl apply -f limitrange.yaml
```

3. Launch a Pod without specifying container `resources`:

```bash
kubectl run sin-resources --image=nginx -n admission-lab
kubectl get pod sin-resources -n admission-lab -o jsonpath='{.spec.containers[0].resources}'
```

4. Attempt to create a Pod requesting CPU exceeding maximum limit bounds:

```bash
kubectl run excede-max --image=nginx -n admission-lab \
  --overrides='{"spec":{"containers":[{"name":"excede-max","image":"nginx","resources":{"requests":{"cpu":"2"}}}]}}'
```

### Questions

1. What separates `default` vs `defaultRequest` in a `LimitRange`?
2. Does the out-of-bounds Pod get persisted in `etcd` before failing scheduling, or is the API request rejected during admission?

---

## Exercise 2 — `ResourceQuota`: Namespace-Level Consumption Quotas

1. Manifest a `ResourceQuota` limiting total namespace resources and object counts:

```yaml
# quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: admission-lab
spec:
  hard:
    requests.cpu: "1"
    requests.memory: "512Mi"
    pods: "3"
```

2. Apply manifest:

```bash
kubectl apply -f quota.yaml
```

3. Inspect active quota usage:

```bash
kubectl describe resourcequota ns-quota -n admission-lab
```

4. Launch additional Pods exceeding `pods: "3"` caps:

```bash
kubectl run extra-1 --image=nginx -n admission-lab
kubectl run extra-2 --image=nginx -n admission-lab
kubectl run extra-3 --image=nginx -n admission-lab
```

### Questions

3. What occurs if launching Pods without explicit resources into namespaces configuring `requests.cpu` quotas without `LimitRange` defaults?
4. Why combine `LimitRange` and `ResourceQuota` in multi-tenant namespaces?

---

## Exercise 3 — `nodeSelector`

1. Label a cluster node:

```bash
kubectl get nodes
kubectl label node <node-name> disktype=ssd
```

2. Manifest a Pod targeting the custom node label:

```yaml
# pod-nodeselector.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-ssd
  namespace: admission-lab
spec:
  nodeSelector:
    disktype: ssd
  containers:
    - name: nginx
      image: nginx
```

3. Apply and verify node assignment:

```bash
kubectl apply -f pod-nodeselector.yaml
kubectl get pod pod-ssd -n admission-lab -o wide
```

### Questions

5. Which component evaluates `nodeSelector` rules: `kube-apiserver` admission controllers or `kube-scheduler`?

---

## Exercise 4 — Node Affinity (`required` vs `preferred`)

1. Label target node:

```bash
kubectl label node <node-name> env=prod
```

2. Manifest a Pod using `requiredDuringSchedulingIgnoredDuringExecution`:

```yaml
# pod-affinity-required.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-required
  namespace: admission-lab
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: env
                operator: In
                values: ["prod"]
  containers:
    - name: nginx
      image: nginx
```

3. Apply and confirm scheduling.
4. Manifest a Pod specifying `preferredDuringSchedulingIgnoredDuringExecution` targeting a non-existent label (`env=staging`):

```yaml
# pod-affinity-preferred.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-preferred
  namespace: admission-lab
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 50
          preference:
            matchExpressions:
              - key: env
                operator: In
                values: ["staging"]
  containers:
    - name: nginx
      image: nginx
```

```bash
kubectl apply -f pod-affinity-preferred.yaml
kubectl get pod pod-preferred -n admission-lab -o wide
```

### Questions

6. What occurs to Pods specifying unfulfilled `requiredDuringScheduling` rules?
7. What occurs to Pods specifying unfulfilled `preferredDuringScheduling` rules?
8. What does `IgnoredDuringExecution` specify in node affinity configurations?

---

## Exercise 5 — Taints and Tolerations

1. Apply a node taint:

```bash
kubectl taint nodes <node-name> dedicated=gpu:NoSchedule
```

2. Launch a Pod without matching tolerations:

```bash
kubectl run sin-toleration --image=nginx -n admission-lab
kubectl get pod sin-toleration -n admission-lab
```

3. Manifest a Pod declaring matching tolerations:

```yaml
# pod-toleration.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-con-toleration
  namespace: admission-lab
spec:
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "gpu"
      effect: "NoSchedule"
  containers:
    - name: nginx
      image: nginx
```

```bash
kubectl apply -f pod-toleration.yaml
kubectl get pod pod-con-toleration -n admission-lab -o wide
```

4. Remove node taint:

```bash
kubectl taint nodes <node-name> dedicated=gpu:NoSchedule-
```

### Questions

9. What distinguishes taint effects `NoSchedule`, `PreferNoSchedule`, and `NoExecute`?
10. Does configuring a Pod toleration force scheduling onto the tainted node, or merely permit it as a candidate?

---

## Exercise 6 — Pod Anti-Affinity

1. Manifest a Deployment configuring `podAntiAffinity`:

```yaml
# deploy-antiaffinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: admission-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values: ["web"]
              topologyKey: "kubernetes.io/hostname"
      containers:
        - name: nginx
          image: nginx
```

2. Apply and verify Pod node distribution:

```bash
kubectl apply -f deploy-antiaffinity.yaml
kubectl get pods -n admission-lab -l app=web -o wide
```

3. Scale replicas beyond available node counts:

```bash
kubectl scale deployment web -n admission-lab --replicas=5
kubectl get pods -n admission-lab -l app=web -o wide
```

### Questions

11. What role does `topologyKey` play in pod anti-affinity rules?

---

## Teardown

```bash
kubectl delete namespace admission-lab
```

---

<details>
<summary>View Answers</summary>

1. `defaultRequest` sets `resources.requests` when omitted; `default` sets `resources.limits` when omitted.
2. Rejected during admission validation before object creation in `etcd`.
3. Pod creation fails with errors requiring explicit resource request definitions.
4. `LimitRange` populates missing resource requests automatically, ensuring Pods pass `ResourceQuota` validation.
5. Evaluated by `kube-scheduler` during scheduling filter passes.
6. Pods remain in `Pending` status.
7. Schedulers assign Pods to alternative eligible nodes without penalty.
8. Label modifications post-scheduling do not evict running Pods.
9. `NoSchedule` blocks new Pods. `PreferNoSchedule` avoids node placement when possible. `NoExecute` evicts non-tolerating running Pods.
10. Tolerations permit node assignment; node affinity rules force node placement.
11. `topologyKey` defines topology domains (e.g. `kubernetes.io/hostname` per-node distribution).

</details>
