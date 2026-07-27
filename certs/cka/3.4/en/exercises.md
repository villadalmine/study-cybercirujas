# Guided Exercises — 3.4 Self-healing primitives and robust deployments (CKA v1.35)

Prerequisites: A multi-node Kubernetes cluster (minikube `--nodes 2` or kind) with `kubectl` configured.

```bash
kubectl create namespace cka-3-4
kubectl config set-context --current --namespace=cka-3-4
```

---

## Exercise 1 — Deployments and ReplicaSets

1. Create a Deployment:

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
```

2. List resources created by the Deployment:

```bash
kubectl get deployment web
kubectl get replicaset -l app=web
kubectl get pods -l app=web -o wide
```

3. Inspect `ownerReferences` on a Pod:

```bash
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences}'
```

4. Inspect `ownerReferences` on the ReplicaSet:

```bash
RS=$(kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences}'
```

### Questions

1. Why do Deployments delegate Pod management to underlying ReplicaSets?
2. If a ReplicaSet is deleted via `kubectl delete rs <name>`, what happens?

---

## Exercise 2 — Self-Healing Control Loops

1. Save target Pod name:

```bash
kubectl get pods -l app=web
POD=$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
```

2. Manually delete Pod:

```bash
kubectl delete pod "$POD"
```

3. Observe replacement Pod creation:

```bash
kubectl get pods -l app=web -w
```

4. Scale deployment replicas to 0 and back to 3:

```bash
kubectl scale deployment web --replicas=0
kubectl get pods -l app=web
kubectl scale deployment web --replicas=3
```

### Questions

1. Which control plane component reconciles declared `replicas` against active Pod states?
2. Does the newly created replacement Pod inherit the original Pod's `metadata.name`?

---

## Exercise 3 — Rolling Updates and Rollbacks

1. Inspect default update strategy parameters:

```bash
kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
```

2. Trigger container image update and track rollout status:

```bash
kubectl set image deployment/web nginx=nginx:1.26
kubectl rollout status deployment/web
```

3. Inspect Pod container images during updates:

```bash
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image
```

4. Inspect rollout history and execute rollback:

```bash
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
```

### Questions

1. Which parameters control `maxSurge` vs `maxUnavailable` during rollouts?
2. Why does `kubectl rollout undo` scale historical ReplicaSets rather than deleting them?

---

## Exercise 4 — Liveness and Readiness Probes

1. Manifest a Pod with a failing liveness probe:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: probe-demo
  labels:
    app: probe-demo
spec:
  containers:
  - name: app
    image: busybox
    args:
    - /bin/sh
    - -c
    - "touch /tmp/healthy; sleep 30; rm -f /tmp/healthy; sleep 600"
    livenessProbe:
      exec:
        command: ["cat", "/tmp/healthy"]
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 1
EOF
```

2. Monitor Pod restart counts:

```bash
kubectl get pod probe-demo -w
```

3. Inspect probe failure events:

```bash
kubectl describe pod probe-demo | grep -A5 Events
```

4. Expose deployment web and trigger readiness failures:

```bash
kubectl expose deployment web --port=80 --name=web-svc
kubectl exec -it "$(kubectl get pods -l app=web -o jsonpath='{.items[0].metadata.name}')" -- \
  sh -c "mv /usr/share/nginx/html/index.html /usr/share/nginx/html/index.html.bak"
kubectl get endpoints web-svc
```

### Questions

1. How do liveness probe failure consequences differ from readiness probe failure consequences?
2. What purpose do startup probes serve compared to `initialDelaySeconds`?

---

## Exercise 5 — Jobs and `restartPolicy`

1. Manifest a failing Job:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: fail-job
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: fail
        image: busybox
        args: ["/bin/sh", "-c", "exit 1"]
EOF
```

2. Track Job retries:

```bash
kubectl get pods -l job-name=fail-job -w
kubectl get job fail-job
```

### Questions

1. Why do Jobs reject `restartPolicy: Always`?
2. How does `backoffLimit` exhaustion differ from Deployment `CrashLoopBackOff` behavior?

---

## Exercise 6 — CronJobs

1. Create a CronJob running every minute:

```bash
kubectl create cronjob hello --image=busybox --schedule="*/1 * * * *" -- /bin/sh -c "date; echo hello"
```

2. Inspect generated Job executions:

```bash
kubectl get jobs -l job-name --watch --timeout=180s
kubectl get cronjob hello
```

### Questions

1. What behavior does `concurrencyPolicy: Forbid` enforce when Job execution times exceed schedule intervals?

---

## Exercise 7 — DaemonSets

1. Manifest a DaemonSet:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  selector:
    matchLabels:
      app: node-agent
  template:
    metadata:
      labels:
        app: node-agent
    spec:
      containers:
      - name: agent
        image: busybox
        args: ["/bin/sh", "-c", "sleep 3600"]
EOF
```

2. Confirm one Pod runs per eligible host node:

```bash
kubectl get pods -l app=node-agent -o wide
kubectl get nodes
```

### Questions

1. Why do DaemonSet specs omit `replicas` fields?

---

## Exercise 8 — StatefulSet Identities

1. Manifest a headless Service and StatefulSet:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None
  selector:
    app: sts-demo
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sts-demo
spec:
  serviceName: web-headless
  replicas: 3
  selector:
    matchLabels:
      app: sts-demo
  template:
    metadata:
      labels:
        app: sts-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF
```

2. Inspect ordinal Pod names:

```bash
kubectl get pods -l app=sts-demo -w
```

3. Delete target Pod `sts-demo-1`:

```bash
kubectl delete pod sts-demo-1
kubectl get pods -l app=sts-demo
```

### Questions

1. Why does `sts-demo-1` preserve ordinal names and network identities upon re-creation?

---

## Exercise 9 — PodDisruptionBudgets

1. Manifest a PDB targeting deployment `web`:

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
EOF
```

2. Inspect PDB status:

```bash
kubectl get pdb web-pdb
```

### Questions

1. With `minAvailable: 2` and 3 active replicas, how many voluntary evictions are permitted simultaneously?
2. Does a PDB prevent involuntary node failures from terminating Pods?

---

## Teardown

```bash
kubectl delete namespace cka-3-4
```

---

<details>
<summary>View Answers</summary>

**Exercise 1**
1. Deployments manage update rollout strategies by versioning ReplicaSets. ReplicaSets handle pod replication.
2. The Deployment controller detects missing ReplicaSets and recreates them automatically.

**Exercise 2**
1. `kube-controller-manager` (ReplicaSet controller).
2. No. Deployment Pods receive new random hash suffixes.

**Exercise 3**
1. `maxUnavailable` limits down replicas during updates; `maxSurge` controls extra created Pods.
2. `kubectl rollout undo` scales existing historical ReplicaSets to avoid losing revision specs.

**Exercise 4**
1. Liveness failures trigger container restarts; readiness failures remove Pods from Service Endpoints.
2. Startup probes delay liveness/readiness evaluation until slow-starting applications boot completely.

**Exercise 5**
1. Jobs represent finite workloads (run-to-completion); `Always` enforces infinite container restarts.
2. `backoffLimit` transitions Jobs to `Failed` states; Deployments retry indefinitely.

**Exercise 6**
1. `concurrencyPolicy: Forbid` skips scheduled runs if previous Job executions remain active.

**Exercise 7**
1. Pod counts are determined dynamically by matching node topology counts.

**Exercise 8**
1. StatefulSets bind ordinal indices to Pod identities and persistent volume claims.

**Exercise 9**
1. Permits 1 simultaneous voluntary eviction.
2. No. PDBs apply exclusively to voluntary Eviction API operations (e.g. `kubectl drain`).

</details>
