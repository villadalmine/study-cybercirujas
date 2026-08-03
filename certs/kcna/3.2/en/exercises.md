# Guided Exercises: Scheduling (KCNA 3.2)

> Reference source: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

These exercises assume a local cluster with at least 2 worker nodes (for example `kind` with `kind create cluster --config` for multiple nodes, or `minikube start --nodes 3`). If your cluster has a single node, some commands will show different results than expected; this is indicated in each case.

---

## Exercise 1: See how the kube-scheduler assigns a Pod to a Node

The `kube-scheduler` is the control plane component that decides on which Node each Pod runs, based on resource requests, constraints, affinity and other factors.

1. List the available nodes and their roles:
   ```bash
   kubectl get nodes -o wide
   ```
2. Create a simple Pod without any scheduling restrictions:
   ```bash
   kubectl run nginx-demo --image=nginx --restart=Never
   ```
3. Check which Node it ended up running on:
   ```bash
   kubectl get pod nginx-demo -o wide
   ```
4. Inspect the Pod events to see the scheduler's decision:
   ```bash
   kubectl describe pod nginx-demo | grep -A5 Events
   ```

**Comprehension questions:**
1. Which control plane component appears as `Source` or `From` in the `Scheduled` type event?
2. If the cluster has a single Node, does it make sense to talk about the scheduler "decision"? Why does it still go through the scheduling process?

---

## Exercise 2: Restrict scheduling with `nodeSelector`

`nodeSelector` is the simplest mechanism to force a Pod to run only on Nodes with a specific label.

1. Label one of your Nodes (replace `<node-name>` with a real one from `kubectl get nodes`):
   ```bash
   kubectl label node <node-name> disk=ssd
   ```
2. Create a manifest `pod-nodeselector.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-ssd
   spec:
     nodeSelector:
       disk: ssd
     containers:
       - name: nginx
         image: nginx
   ```
3. Apply it and verify where it ran:
   ```bash
   kubectl apply -f pod-nodeselector.yaml
   kubectl get pod nginx-ssd -o wide
   ```
4. Now remove the label from the Node and create a second identical Pod (with a different `name`) to see what happens when no Node matches the selector:
   ```bash
   kubectl label node <node-name> disk-
   kubectl apply -f pod-nodeselector.yaml
   kubectl get pod nginx-ssd -o wide
   ```
   > Note: if you reuse the same `name`, you will have to delete the previous Pod first (`kubectl delete pod nginx-ssd`).

**Comprehension questions:**
1. What `status.phase` does a Pod show when its `nodeSelector` does not match any existing label in the cluster?
2. Is `nodeSelector` a "hard" (mandatory) or "soft" (preferred) restriction?

---

## Exercise 3: Node Affinity with more expressive rules

Node affinity extends `nodeSelector` with logical operators (`In`, `NotIn`, `Exists`, etc.) and the ability to express preferences instead of strict requirements.

1. Label a Node with one value among several possible:
   ```bash
   kubectl label node <node-name> zone=us-east-1a
   ```
2. Create `pod-affinity.yaml` using `requiredDuringSchedulingIgnoredDuringExecution`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-affinity
   spec:
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: zone
                   operator: In
                   values:
                     - us-east-1a
                     - us-east-1b
     containers:
       - name: nginx
         image: nginx
   ```
3. Apply it and confirm the assigned Node:
   ```bash
   kubectl apply -f pod-affinity.yaml
   kubectl get pod nginx-affinity -o wide
   ```
4. Change the section to `preferredDuringSchedulingIgnoredDuringExecution` with a `weight`, pointing to a label that no Node has, and apply again. Observe that the Pod still gets scheduled.

**Comprehension questions:**
1. What is the difference between `requiredDuringSchedulingIgnoredDuringExecution` and `preferredDuringSchedulingIgnoredDuringExecution`?
2. What does the `IgnoredDuringExecution` part of the name mean? What happens if the Node's label changes after the Pod is already running?

---

## Exercise 4: Taints and Tolerations

While affinity is defined on the Pod to "attract" it to certain Nodes, taints are defined on the Node to "repel" Pods, unless those Pods declare an explicit toleration.

1. Apply a taint to a Node:
   ```bash
   kubectl taint nodes <node-name> workload=batch:NoSchedule
   ```
2. Try to run a normal Pod (without toleration) and observe that the scheduler avoids that Node if others are available:
   ```bash
   kubectl run nginx-notaint --image=nginx --restart=Never
   kubectl get pod nginx-notaint -o wide
   ```
3. Create `pod-toleration.yaml` with a toleration that matches the taint:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-tolerado
   spec:
     tolerations:
       - key: "workload"
         operator: "Equal"
         value: "batch"
         effect: "NoSchedule"
     containers:
       - name: nginx
         image: nginx
   ```
4. Apply it and verify that this one can land on the tainted Node:
   ```bash
   kubectl apply -f pod-toleration.yaml
   kubectl get pod nginx-tolerado -o wide
   ```
5. Clean up the taint when done:
   ```bash
   kubectl taint nodes <node-name> workload=batch:NoSchedule-
   ```

**Comprehension questions:**
1. With the correct toleration, is the Pod *forced* to run on the tainted Node?
2. What is the practical difference between the effects `NoSchedule`, `PreferNoSchedule` and `NoExecute`?

---

## Exercise 5: Resource requests and their impact on scheduling

The scheduler uses the CPU/memory `requests` declared in each container to decide if a Node has available capacity (it filters out Nodes that cannot satisfy the sum of requests).

1. Check the allocatable capacity of your Nodes:
   ```bash
   kubectl describe nodes | grep -A5 Allocatable
   ```
2. Create `pod-requests.yaml` requesting a deliberately huge memory request, greater than the capacity of any Node:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-oversized
   spec:
     containers:
       - name: nginx
         image: nginx
         resources:
           requests:
             memory: "500Gi"
             cpu: "1"
   ```
3. Apply it and observe the resulting state:
   ```bash
   kubectl apply -f pod-requests.yaml
   kubectl get pod nginx-oversized
   kubectl describe pod nginx-oversized | grep -A5 Events
   ```

**Comprehension questions:**
1. What event message explains why the Pod was not scheduled?
2. Are the container `limits` also considered in the Node filtering phase, or only the `requests`?

---

## Exercise 6: Manual scheduling with `nodeName`

It is possible to bypass the scheduler entirely by explicitly specifying the Node in the Pod spec.

1. Create `pod-nodename.yaml` (replace `<node-name>` with a real one):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-manual
   spec:
     nodeName: <node-name>
     containers:
       - name: nginx
         image: nginx
   ```
2. Apply it and confirm that it runs exactly where you specified:
   ```bash
   kubectl apply -f pod-nodename.yaml
   kubectl get pod nginx-manual -o wide
   ```
3. Review the Pod events:
   ```bash
   kubectl describe pod nginx-manual | grep -A5 Events
   ```

**Comprehension questions:**
1. Does a `Scheduled` type event appear for this Pod? Why?
2. What capacity or affinity checks are lost when using `nodeName` instead of letting the scheduler decide?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
1. `kube-scheduler` (or `default-scheduler`) appears as the source of the `Scheduled` event.
2. Yes: even with only one candidate Node, the Pod still goes through the filtering and scoring phases of the scheduler; there is simply only one possible outcome.

**Exercise 2**
1. The Pod remains in `Pending` state, because no Node satisfies the `nodeSelector`.
2. It is a "hard" restriction: if no Node has the exact label, the Pod will never be scheduled (there is no notion of preference in `nodeSelector`).

**Exercise 3**
1. `required...` is a mandatory condition: if no Node meets it, the Pod stays `Pending`. `preferred...` is a preference with a `weight` that influences scoring, but does not block scheduling if no Node meets it.
2. It means the affinity rule is only evaluated at the time the Pod is scheduled. If the Node's label changes afterwards, the already running Pod is not evicted or rescheduled.

**Exercise 4**
1. Not necessarily: the toleration only *allows* the Pod to be considered for that Node, but does not *force* it to run there. The scheduler may still choose another untainted Node.
2. `NoSchedule` prevents new Pods without toleration from being scheduled on the Node, but does not affect existing running Pods. `PreferNoSchedule` is a "soft" version (the scheduler tries to avoid it, but does not guarantee). `NoExecute` additionally evicts Pods that are already running and do not tolerate the taint.

**Exercise 5**
1. A `FailedScheduling` event with a message like "Insufficient memory" indicating that no Node has enough allocatable memory.
2. Only `requests` are used in the filtering phase (predicates) to decide if a Node has available capacity; `limits` are not a scheduling criterion, they are applied at runtime for resource contention (throttling/OOM).

**Exercise 6**
1. No `Scheduled` event appears, because the Pod never goes through the kube-scheduler process: the kubelet on the specified Node simply starts it directly.
2. All scheduler checks are lost: verification of available resources (requests vs allocatable), taints/tolerations, node affinity, and any other predicate or priority. If the Node lacks capacity or has an incompatible taint, the Pod may fail on the kubelet instead of cleanly staying `Pending`.

</details>