# Guided Exercises: Monitor cluster and application resource usage (CKA 2.3)

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

---

## Exercise 1 — Metrics Pipeline and `metrics-server`

1. Verify whether `metrics-server` is installed in the cluster:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```
2. If missing, deploy it using official manifests:
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```
3. If `metrics-server` pods run but `kubectl top` fails due to self-signed TLS certificates in lab environments, patch `--kubelet-insecure-tls`:
   ```bash
   kubectl logs -n kube-system deployment/metrics-server
   kubectl patch deployment metrics-server -n kube-system --type='json' \
     -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   ```
4. Confirm Metrics API availability as an `APIService`:
   ```bash
   kubectl get apiservices | grep metrics
   ```
5. Wait for Deployment availability and test querying metrics:
   ```bash
   kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
   kubectl top nodes
   ```

**Comprehension Questions**

- If `metrics-server` is not installed, which CKA exam utilities fail and why?
- Which node-level component acts as the raw data source for CPU/memory metrics aggregated by `metrics-server`?
- Does the Metrics API (`metrics.k8s.io`) store historical time-series data or only real-time snapshots?

---

## Exercise 2 — `kubectl top`: Nodes, Pods, and Containers

1. Display node resource utilization ordered by CPU consumption:
   ```bash
   kubectl top nodes --sort-by=cpu
   ```
2. Create a test namespace and deploy a workload with specified requests/limits:
   ```bash
   kubectl create namespace monitoring-demo
   kubectl run load-demo --image=nginx --namespace=monitoring-demo \
     --requests='cpu=50m,memory=64Mi' --limits='cpu=200m,memory=128Mi'
   ```
3. Display Pod resource utilization in the namespace, then break down per container:
   ```bash
   kubectl top pods -n monitoring-demo
   kubectl top pods -n monitoring-demo --containers
   ```
4. Display Pod utilization cluster-wide across all namespaces sorted by memory:
   ```bash
   kubectl top pods --all-namespaces --sort-by=memory
   ```

**Comprehension Questions**

- What distinction exists between `kubectl top pods` vs `kubectl top pods --containers` in multi-container Pods?
- Why do newly spawned Pods take several seconds to appear in `kubectl top` outputs?
- Does `kubectl top` output configured `requests`/`limits` declarations or only real-time measured usage?

---

## Exercise 3 — Capacity, Allocatable, and Node Resource Requests

1. Describe node resource capacities:
   ```bash
   kubectl describe node <node-name>
   ```
2. Inspect `Capacity`, `Allocatable`, and `Allocated resources` sections:
   ```bash
   kubectl describe node <node-name> | grep -A 5 "Capacity:"
   kubectl describe node <node-name> | grep -A 5 "Allocatable:"
   kubectl describe node <node-name> | grep -A 10 "Allocated resources"
   ```
3. Deploy a Pod requesting CPU exceeding available node capacity to trigger `Pending` status:
   ```bash
   kubectl run oversized --image=nginx -n monitoring-demo \
     --requests='cpu=100' --limits='cpu=100'
   kubectl get pod oversized -n monitoring-demo
   kubectl describe pod oversized -n monitoring-demo | grep -A 5 Events
   ```
4. Clean up test pod:
   ```bash
   kubectl delete pod oversized -n monitoring-demo
   ```

**Comprehension Questions**

- Why does `kube-scheduler` evaluate committed Pod `requests` instead of real-time usage (`kubectl top`) when assigning Pods to nodes?
- Which event reason and message appear in `kubectl describe pod` when Pods remain `Pending` due to CPU deficits?
- Why is `Allocatable` capacity smaller than total `Capacity` on nodes?

---

## Exercise 4 — Diagnosing `OOMKilled` via Metrics and Events

1. Manifest a Pod configured to exceed specified memory limits:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: oom-demo
     namespace: monitoring-demo
   spec:
     containers:
     - name: hog
       image: polinux/stress
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
   ```
2. Apply manifest and observe execution states:
   ```bash
   kubectl apply -f oom-demo.yaml
   kubectl get pod oom-demo -n monitoring-demo -w
   ```
3. Following container restart, inspect previous container termination states:
   ```bash
   kubectl describe pod oom-demo -n monitoring-demo | grep -A 10 "Last State"
   ```
4. Review namespace events ordered by timestamp:
   ```bash
   kubectl get events -n monitoring-demo --sort-by='.lastTimestamp'
   ```
5. Retrieve container restart counts:
   ```bash
   kubectl get pod oom-demo -n monitoring-demo -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
   ```
6. Teardown test Pod:
   ```bash
   kubectl delete -f oom-demo.yaml
   ```

**Comprehension Questions**

- What exact `reason` appears in `Last State` when a container is terminated for exceeding memory limits?
- If a container exceeds CPU limits instead of memory limits, is the Pod terminated? Explain.
- Which `restartPolicy` causes Pod container restarts following `OOMKilled` terminations?

---

## Exercise 5 — Node Conditions and Resource Pressure

1. Inspect Node health `Conditions`:
   ```bash
   kubectl describe nodes | grep -A 15 "Conditions:"
   ```
2. Output Node pressure conditions in structured columns:
   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,MEMORY_PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,PID_PRESSURE:.status.conditions[?(@.type=="PIDPressure")].status'
   ```
3. Inspect Node `Taints` applied under resource pressure:
   ```bash
   kubectl describe nodes | grep -A 3 "Taints:"
   ```
4. Query cluster-wide eviction events:
   ```bash
   kubectl get events --all-namespaces --field-selector reason=Evicted
   ```

**Comprehension Questions**

- What taint is automatically applied to nodes entering `MemoryPressure` status, and how does it affect running vs new Pods?
- If `kubectl get nodes` displays `Ready` while `describe node` displays `MemoryPressure: True`, will the node accept new Pods lacking explicit tolerations?
- What distinguishes `OOMKilled` container terminations from node-level `Evicted` Pod terminations?

---

<details>
<summary>View Answers</summary>

**Exercise 1**
- `kubectl top nodes`, `kubectl top pods`, and metric-driven `HorizontalPodAutoscaler` controllers fail because `metrics.k8s.io` is served by `metrics-server`.
- `cAdvisor`, embedded inside node `kubelet` daemons, collects container cgroup stats.
- `metrics.k8s.io` holds only real-time in-memory snapshots without historical retention.

**Exercise 2**
- `kubectl top pods` aggregates total Pod consumption into a single number. `--containers` breaks down individual usage per container inside multi-container Pods.
- `metrics-server` polls kubelets periodically (~15s interval). New Pods require initial scrape cycles before metrics register.
- `kubectl top` outputs only measured real-time utilization.

**Exercise 3**
- Schedulers evaluate guaranteed `requests` contracts to prevent node over-subscription during peak workload spikes.
- `FailedScheduling` events displaying `0/N nodes are available: N Insufficient cpu`.
- `Allocatable` subtracts `system-reserved`, `kube-reserved`, and `eviction-hard` thresholds from physical hardware `Capacity`.

**Exercise 4**
- `OOMKilled` (Exit Code 137).
- No. CPU is a compressible resource: exceeding CPU limits triggers cgroup throttling rather than process termination.
- `restartPolicy: Always` (or `OnFailure`) triggers kubelet container restarts, increasing `restartCount`.

**Exercise 5**
- Taint `node.kubernetes.io/memory-pressure:NoSchedule`. Blocks new Pod scheduling while allowing active Pods to run until evicted.
- No. `NoSchedule` taints prevent new Pod placements lacking matching tolerations.
- `OOMKilled` is a kernel cgroup action terminating single containers exceeding memory limits. `Evicted` is a kubelet action evicting entire Pods when total node resources drop below eviction thresholds.

</details>
