# Exercises: 4.3 — Understand requests, limits, quotas (CKAD v1.35)

> Prerequisite: An accessible Kubernetes cluster (`kind`, `minikube`, or similar) with configured `kubectl`, and `metrics-server` installed if using `kubectl top`.

## Exercise 1 — Working Namespace, Requests/Limits and QoS Class

1. Create a dedicated namespace for these exercises:
   ```bash
   kubectl create namespace res-quiz
   ```

2. Create a manifest `pod-guaranteed.yaml` with a Pod whose container defines **equal** `requests` and `limits` for `cpu` and `memory`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-guaranteed
     namespace: res-quiz
   spec:
     containers:
     - name: app
       image: nginx
       resources:
         requests:
           cpu: "200m"
           memory: "128Mi"
         limits:
           cpu: "200m"
           memory: "128Mi"
   ```
   Apply it:
   ```bash
   kubectl apply -f pod-guaranteed.yaml
   ```

3. Inspect assigned QoS class:
   ```bash
   kubectl get pod pod-guaranteed -n res-quiz -o jsonpath='{.status.qosClass}'
   ```

4. Create a second Pod, `pod-burstable.yaml`, with `requests` **lower** than `limits`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-burstable
     namespace: res-quiz
   spec:
     containers:
     - name: app
       image: nginx
       resources:
         requests:
           cpu: "100m"
           memory: "64Mi"
         limits:
           cpu: "300m"
           memory: "256Mi"
   ```
   Apply it and check its `qosClass` using the command from step 3.

5. Create a third Pod, `pod-besteffort.yaml`, **without** a `resources` block, and check its `qosClass`.

**Verification Questions:**
- What QoS class did each of the three Pods receive and why does that combination of `requests`/`limits` yield that class?
- If the node experiences `memory pressure` and kubelet must evict Pods, in what order would it evict these three Pods?

---

## Exercise 2 — Exceeding Memory Limit: OOMKilled

1. Create `pod-oom.yaml`, a Pod forcing memory usage beyond its `limit`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-oom
     namespace: res-quiz
   spec:
     containers:
     - name: stress
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
   ```
   Apply it:
   ```bash
   kubectl apply -f pod-oom.yaml
   ```

2. Wait a few seconds and describe the Pod:
   ```bash
   kubectl describe pod pod-oom -n res-quiz
   ```

3. Inspect `lastState.terminated.reason` container field:
   ```bash
   kubectl get pod pod-oom -n res-quiz -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
   ```

**Verification Questions:**
- Which `reason` appears in `lastState.terminated` and what `exit code` is associated with that condition?
- What is the difference in behavior between exceeding `memory` `limit` (step 1) vs exceeding `cpu` `limit`? Why does kubelet kill the container in one case but not the other?

---

## Exercise 3 — LimitRange: Default Values and Permitted Ranges

1. Create `limitrange.yaml` in namespace `res-quiz`:
   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: default-limits
     namespace: res-quiz
   spec:
     limits:
     - type: Container
       default:
         cpu: "250m"
         memory: "256Mi"
       defaultRequest:
         cpu: "100m"
         memory: "128Mi"
       min:
         cpu: "50m"
       max:
         cpu: "500m"
   ```
   Apply it:
   ```bash
   kubectl apply -f limitrange.yaml
   ```

2. Create a Pod **without** a `resources` block in the same namespace:
   ```bash
   kubectl run pod-no-resources --image=nginx -n res-quiz
   ```

3. Inspect assigned `requests`/`limits` on the container:
   ```bash
   kubectl get pod pod-no-resources -n res-quiz -o jsonpath='{.spec.containers[0].resources}'
   ```

4. Attempt creating a Pod requesting `cpu: "800m"` (exceeding defined `max`):
   ```bash
   kubectl run pod-exceeds-max --image=nginx -n res-quiz \
     --overrides='{"spec":{"containers":[{"name":"pod-exceeds-max","image":"nginx","resources":{"requests":{"cpu":"800m"},"limits":{"cpu":"800m"}}}]}}'
   ```

**Verification Questions:**
- Where did assigned `requests`/`limits` on step 2 Pod come from if omitted in original manifest?
- What error message returns in step 4, and which API object is responsible for rejecting creation?

---

## Exercise 4 — Namespace-Level ResourceQuota

1. Create `resourcequota.yaml`:
   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: res-quiz-quota
     namespace: res-quiz
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: "1Gi"
       limits.cpu: "2"
       limits.memory: "2Gi"
       pods: "5"
   ```
   Apply it:
   ```bash
   kubectl apply -f resourcequota.yaml
   ```

2. Inspect current usage against quota:
   ```bash
   kubectl describe resourcequota res-quiz-quota -n res-quiz
   ```

3. Attempt creating a new Pod **without** explicit `resources` block (assuming `LimitRange` from exercise 3 was deleted, or keep it to observe interactions):
   ```bash
   kubectl run pod-no-quota --image=nginx -n res-quiz
   ```

4. Observe behavior if namespace contains a `ResourceQuota` but created Pod omits `requests`/`limits` and **no** `LimitRange` exists:
   ```bash
   kubectl delete limitrange default-limits -n res-quiz
   kubectl run pod-no-requests --image=nginx -n res-quiz
   ```

**Verification Questions:**
- Why does step 4 fail (or behave differently) when `ResourceQuota` tracks `requests.cpu`/`requests.memory` but no `LimitRange` provides default values?
- What is the difference between `ResourceQuota` and `LimitRange` regarding scope (entire namespace vs per-object)?

---

## Exercise 5 — Diagnostics via `kubectl top`

1. Install or verify `metrics-server` is running:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```

2. Query real-time resource consumption per Pod in namespace:
   ```bash
   kubectl top pods -n res-quiz
   ```

3. Query consumption per node:
   ```bash
   kubectl top nodes
   ```

4. Compare `cpu`/`memory` reported by `kubectl top` for `pod-guaranteed` against original manifest `request` (Exercise 1, step 2).

**Verification Questions:**
- Does `kubectl top` report real-time usage or configured `requests`/`limits` values? Which cluster component provides this data?
- If a Pod displays `cpu` usage well above its `request` but below its `limit`, is that problematic? What if it exceeds its `cpu` `limit`?

---

## Teardown

```bash
kubectl delete namespace res-quiz
```

---

**Reference:** CNCF, *CKAD Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf

<details>
<summary>View Answers</summary>

**Exercise 1:**
- `pod-guaranteed`: **Guaranteed** QoS, because `requests == limits` for **cpu and memory** on **all** Pod containers. `pod-burstable`: **Burstable** QoS, because `requests` and `limits` are defined but unequal (or one resource is omitted). `pod-besteffort`: **BestEffort** QoS, because no containers define `requests` or `limits`.
- Under memory pressure, kubelet evicts **BestEffort** Pods first, then **Burstable** Pods (prioritizing those exceeding `request` by highest margin), and finally **Guaranteed** Pods (evicted only if node itself faces system risk, as reserved capacity is assumed).

**Exercise 2:**
- `reason` is `OOMKilled`, with `exitCode: 137` (128 + SIGKILL/9 signal). Occurs because Linux kernel via cgroups terminates process when exceeding assigned memory `limit`.
- Memory is an **incompressible** resource: exceeding `limit` triggers kernel termination (OOMKilled). CPU is a **compressible** resource: exceeding CPU `limit` causes kernel throttling (reduced CPU time allocated via CFS quota) without terminating process.

**Exercise 3:**
- Applied from `LimitRange`: as Pod omitted `resources`, `LimitRanger` admission controller applied `defaultRequest` (`cpu: 100m`, `memory: 128Mi`) as `requests` and `default` (`cpu: 250m`, `memory: 256Mi`) as `limits`.
- API server rejects creation with error `is forbidden: maximum cpu usage per Container is 500m, but limit is 800m`, generated by `LimitRanger` admission controller validating against `max` in `LimitRange`.

**Exercise 4:**
- Fails because when a namespace has a `ResourceQuota` tracking `requests.cpu` or `requests.memory` (or `limits` equivalents), API server requires **every** created Pod to explicitly specify `requests`/`limits`. Without a `LimitRange` providing default values, Pod is rejected with error `must specify cpu, memory`.
- `ResourceQuota` caps **aggregated total** consumable resources (and object counts) across entire namespace; `LimitRange` operates **per individual object** (Pod or Container), defining minimums, maximums, and default values for each, regardless of overall namespace object totals.

**Exercise 5:**
- `kubectl top` reports **real-time instantaneous usage** of cpu/memory, obtained from metrics exposed by **metrics-server** (collected from node `cAdvisor`/kubelet). Does not reflect configured `requests`/`limits`, but actual current consumption.
- CPU usage above `request` but below `limit` is normal and expected (`request` guarantees capacity, not a ceiling); not an issue itself. Exceeding CPU `limit` does not kill container, but triggers *throttling*, which can degrade application performance.

</details>
