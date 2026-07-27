# Guided Exercises — 4.4 Define resource requirements

> **Prerequisites:** A practice cluster (minikube, kind, or similar) and `kubectl` configured. For Exercise 3, having `metrics-server` installed is recommended (on minikube: `minikube addons enable metrics-server`), though not strictly required.

---

## Exercise 1 — Basic Requests and Limits

A container can declare how many resources it **requests** (`requests`) and the **maximum** it can consume (`limits`). The scheduler uses `requests` to decide on which node to place the Pod; `limits` are enforced by kubelet at runtime.

1. Create a working namespace:

   ```bash
   kubectl create namespace recursos
   kubectl config set-context --current --namespace=recursos
   ```

2. Create file `pod-recursos.yaml` with a Pod declaring requests and limits:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-medida
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "250m"
           memory: "64Mi"
         limits:
           cpu: "500m"
           memory: "128Mi"
   ```

3. Apply it and verify it reaches `Running` state:

   ```bash
   kubectl apply -f pod-recursos.yaml
   kubectl get pod app-medida
   ```

4. Inspect how resources were registered:

   ```bash
   kubectl describe pod app-medida | grep -A 6 "Limits\|Requests"
   ```

5. Inspect on the node: look for **Allocated resources** section to see committed node capacity:

   ```bash
   kubectl describe node $(kubectl get pod app-medida -o jsonpath='{.spec.nodeName}') | grep -A 8 "Allocated resources"
   ```

**Questions**

1. What exactly does `cpu: "250m"` mean? And what is the difference between `64Mi` and `64M`?
2. If container `app-medida` attempts to use `600m` CPU continuously, what happens? What if it attempts to use `200Mi` memory?
3. Which of the two values (`requests` or `limits`) does the scheduler use to choose a node?

---

## Exercise 2 — The Three QoS Classes

Based on resource declarations, Kubernetes assigns a **QoS class** (`Guaranteed`, `Burstable`, or `BestEffort`) determining eviction order under node memory pressure.

1. Create a Pod **without any** resource declarations:

   ```bash
   kubectl run sin-recursos --image=nginx:1.27
   ```

2. Create file `pod-garantizado.yaml`, where `requests` and `limits` are **identical** for CPU and memory:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: garantizado
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "200m"
           memory: "100Mi"
         limits:
           cpu: "200m"
           memory: "100Mi"
   ```

   ```bash
   kubectl apply -f pod-garantizado.yaml
   ```

3. Inspect QoS classes for all three Pods created so far:

   ```bash
   kubectl get pods -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
   ```

4. Verify that a single field changes QoS class: imperatively add a request to `sin-recursos` (requires Pod recreation):

   ```bash
   kubectl delete pod sin-recursos
   kubectl run sin-recursos --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"sin-recursos","image":"nginx:1.27","resources":{"requests":{"memory":"32Mi"}}}]}}'
   kubectl get pod sin-recursos -o jsonpath='{.status.qosClass}{"\n"}'
   ```

**Questions**

4. Write the rule defining each of the three QoS classes.
5. If the node experiences memory pressure, in what order are Pods evicted according to QoS class?
6. A Pod declares equal `requests` and `limits` for memory, but only `requests` (no `limits`) for CPU. What QoS class does it receive?

---

## Exercise 3 — Exceeding Limits: OOMKilled vs Throttling

CPU and memory behave differently when exceeding limits: CPU is **compressible** (throttled) while memory is **incompressible** (process terminated).

1. Create file `pod-glotón.yaml` with a container attempting to allocate more memory than its limit:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: gloton
   spec:
     containers:
     - name: stress
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
   ```

2. Apply and observe status over one minute:

   ```bash
   kubectl apply -f pod-glotón.yaml
   kubectl get pod gloton --watch
   ```

   You will see Pod transition through `OOMKilled` and `CrashLoopBackOff` as kubelet restarts it.

3. Confirm exact termination cause:

   ```bash
   kubectl describe pod gloton | grep -A 3 "Last State"
   kubectl get pod gloton -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
   ```

4. If `metrics-server` is installed, check real-time consumption of healthy Pods:

   ```bash
   kubectl top pod
   ```

5. Clean up crashing Pod:

   ```bash
   kubectl delete pod gloton
   ```

**Questions**

7. What `reason` and `exit code` are reported for a container terminated due to memory exhaustion?
8. Why does the Pod enter `CrashLoopBackOff` instead of staying permanently dead on first crash?
9. If instead of memory the container exceeded its **CPU** limit, would kubelet terminate it? Justify.

---

## Exercise 4 — Impossible Requests: Pod Stuck Pending

If no single node has sufficient **unallocated requested capacity** for a Pod, the scheduler cannot place it, leaving the Pod in `Pending` state.

1. Create `pod-imposible.yaml` requesting impossible CPU capacity:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: imposible
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "64"
   ```

2. Apply and check status:

   ```bash
   kubectl apply -f pod-imposible.yaml
   kubectl get pod imposible
   ```

3. Troubleshoot cause using `describe` — examine **Events** section:

   ```bash
   kubectl describe pod imposible
   ```

   You should see `FailedScheduling` event with `Insufficient cpu`.

4. Fix Pod by reducing request to reasonable values. Replace Pod:

   ```bash
   kubectl get pod imposible -o yaml > imposible-fix.yaml
   # edit imposible-fix.yaml: change cpu: "64" to cpu: "100m"
   kubectl replace --force -f imposible-fix.yaml
   kubectl get pod imposible
   ```

5. For Deployments, imperative updates trigger rolling updates:

   ```bash
   kubectl create deployment api --image=nginx:1.27 --replicas=2
   kubectl set resources deployment api --requests=cpu=100m,memory=64Mi --limits=cpu=250m,memory=128Mi
   kubectl get pods -l app=api -o custom-columns='NAME:.metadata.name,CPU-REQ:.spec.containers[0].resources.requests.cpu'
   ```

**Questions**

10. A Pod is `Pending` and `describe` shows `0/3 nodes are available: 3 Insufficient memory`. Name two valid resolution strategies.
11. Why can a Pod remain `Pending` due to requests even if **actual** node resource consumption is very low?
12. What does `kubectl set resources` on a Deployment do: edit existing Pods or create new Pods? Why?

---

## Exercise 5 — Namespace Defaults and Caps: LimitRange and ResourceQuota

1. Create `politicas.yaml` with both policy objects:

   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: defaults-container
     namespace: recursos
   spec:
     limits:
     - type: Container
       default:            # default limit
         cpu: "500m"
         memory: "256Mi"
       defaultRequest:     # default request
         cpu: "100m"
         memory: "64Mi"
       max:
         cpu: "1"
         memory: "512Mi"
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: presupuesto
     namespace: recursos
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: "1Gi"
       limits.cpu: "2"
       limits.memory: "2Gi"
       pods: "10"
   ```

   ```bash
   kubectl apply -f politicas.yaml
   ```

2. Create a Pod **without declaring resources** and view assigned LimitRange defaults:

   ```bash
   kubectl run heredero --image=nginx:1.27
   kubectl get pod heredero -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
   ```

3. Attempt violating LimitRange `max` and read error:

   ```bash
   kubectl run excesivo --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"excesivo","image":"nginx:1.27","resources":{"limits":{"memory":"1Gi"}}}]}}'
   ```

4. Check consumed quota budget:

   ```bash
   kubectl describe resourcequota presupuesto
   ```

5. Verify quota requirement behavior: with `ResourceQuota` tracking `requests.*`/`limits.*`, a Pod omitting resources is **rejected** unless a LimitRange fills defaults. Delete LimitRange to verify:

   ```bash
   kubectl delete limitrange defaults-container
   kubectl run huerfano --image=nginx:1.27
   ```

   Error message states quota requires every Pod to declare (or inherit) requests and limits.

6. Final cleanup:

   ```bash
   kubectl delete namespace recursos
   kubectl config set-context --current --namespace=default
   ```

**Questions**

13. What does each object govern: `LimitRange` vs `ResourceQuota`? Explain scope differences.
14. In step 2, what requests and limits did `heredero` Pod receive and where did they originate?
15. At what moment is a Pod violating quota rejected: `kubectl apply`, scheduling, or runtime?

---

## Answers

<details>
<summary>View Answers</summary>

1. `cpu: "250m"` represents 250 **millicores** (0.25 of 1 node vCPU). `64Mi` uses binary suffix **mebibyte** (64 × 1024² bytes ≈ 67.1 MB), while `64M` is decimal **megabyte** (64 × 1000² bytes). Binary suffixes (`Ki`, `Mi`, `Gi`) are standard in Kubernetes. `64m` for memory means 64 **milli-bytes**, a common exam error.

2. With continuous CPU above `500m` limit, container is **throttled** (slowed down), but process stays alive. With memory above `128Mi`, kernel terminates container with **OOM kill** (restarted by kubelet per `restartPolicy`).

3. Scheduler uses **only `requests`**. Compares Pod requests against node *allocatable* capacity minus existing Pod requests. `limits` are ignored during scheduling; enforced at runtime by kubelet.

4. - **Guaranteed**: all containers declare `requests` and `limits` for CPU **and** memory, with `requests == limits` per resource.
   - **Burstable**: does not qualify as Guaranteed, but at least one container declares some `request` or `limit`.
   - **BestEffort**: no containers declare requests or limits.

5. Under node memory pressure, kubelet evicts **BestEffort** first, then **Burstable** exceeding requests, leaving **Guaranteed** last.

6. **Burstable.** To be Guaranteed, requests == limits for CPU *and* memory across all containers is required; omitting CPU limit disqualifies Guaranteed while avoiding BestEffort.

7. `Reason: OOMKilled` with **exit code 137** (128 + 9, process received SIGKILL from kernel OOM killer).

8. Because default Pod `restartPolicy` is `Always`: kubelet restarts container whenever it dies, applying **exponential backoff** between repeated restarts — waiting state is `CrashLoopBackOff`.

9. No. CPU is **compressible**: exceeding limit triggers CPU throttling (running slower). Containers are never killed for CPU excess; only memory (**incompressible**) triggers OOM kill.

10. Either: (a) **lower Pod/Deployment `requests`**; (b) **free node capacity** by deleting or scaling down other Pods; (c) **add nodes** with higher capacity. Lowering `limits` does not help since scheduler ignores limits.

11. Because scheduling is based on **declared requests, not actual usage**. If existing Pods reserved (requested) most capacity, node appears full to scheduler even if actual process usage is low.

12. Creates **new Pods**. `kubectl set resources` updates Deployment Pod template (`spec.template.spec.containers[].resources`), triggering a **rolling update** replacing old Pods with updated ones.

13. `LimitRange` operates **per individual container/Pod** in namespace: sets default values and per-object limits (`max`, `min`). `ResourceQuota` operates on **aggregated namespace totals**: sum of requests/limits and object counts (Pods, Services).

14. Received `requests: cpu=100m, memory=64Mi` (`defaultRequest`) and `limits: cpu=500m, memory=256Mi` (`default`) from LimitRange. Injected by `LimitRanger` **admission controller** at Pod creation time.

15. At **admission** time (`kubectl apply`/`run`): API server rejects creation before Pod object is persisted or sent to scheduler/runtime.

</details>
