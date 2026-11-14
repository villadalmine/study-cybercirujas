# Guided Exercises: AI Cluster Orchestration and Job Scheduling Essentials (NCA-AIIO 3.2)

These exercises are split into three tracks so that you can complete most of them without access to physical GPUs:

| Track | Requirements | Exercises |
|---|---|---|
| **A: Scheduling semantics** (required) | Linux/macOS workstation, Docker or Podman, `kind` ≥ 0.20, `kubectl` ≥ 1.27 | 1 to 5 |
| **B: Real GPU node** (optional) | A Kubernetes cluster with at least one NVIDIA GPU node and the NVIDIA GPU Operator installed (A100/H100 for the MIG step) | 6 |
| **C: HPC scheduler and policy reasoning** (paper or real Slurm) | Paper is enough. A Slurm cluster (for example, one provisioned by NVIDIA Base Command Manager) is a bonus | 7 and 8 |

Track A uses a documented Kubernetes technique: you advertise an **extended resource** called `nvidia.com/gpu` on the nodes by hand, so the scheduler treats them exactly as it would treat nodes running the NVIDIA device plugin. No container will actually touch a GPU, but every scheduling decision (filtering, `Insufficient nvidia.com/gpu`, preemption, quota admission) runs through the real `kube-scheduler` code path.

Official references used throughout:

- Kubernetes: Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
- Kubernetes: Advertise Extended Resources for a Node: https://kubernetes.io/docs/tasks/administer-cluster/extended-resource-node/
- Kubernetes: Pod Priority and Preemption: https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Kubernetes docs home: https://kubernetes.io/docs/home/
- Kueue: https://kueue.sigs.k8s.io/docs/
- NVIDIA GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/
- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- NVIDIA DCGM: https://developer.nvidia.com/dcgm
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- NVIDIA Run:ai and NIM GPU utilization: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- NVIDIA AI Infrastructure and Operations Fundamentals course: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- Slurm GRES scheduling: https://slurm.schedmd.com/gres.html

---

## Exercise 1: Build a lab cluster and advertise GPUs to the scheduler

**Goal:** understand that, to the Kubernetes scheduler, a GPU is nothing more than an integer counter called `nvidia.com/gpu` in `status.capacity` and `status.allocatable` of a Node. On a real cluster that counter is written by the **NVIDIA device plugin** (deployed by the GPU Operator) through the kubelet's Device Plugin gRPC API. Here you write it yourself.

1. Create a kind configuration with one control plane and two workers. Save it as `kind-gpu-lab.yaml`:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: gpu-lab
   nodes:
     - role: control-plane
     - role: worker
     - role: worker
   ```

2. Create the cluster and confirm the nodes:

   ```bash
   kind create cluster --config kind-gpu-lab.yaml
   kubectl get nodes
   ```

   Expected output (versions will differ):

   ```
   NAME                    STATUS   ROLES           AGE   VERSION
   gpu-lab-control-plane   Ready    control-plane   60s   v1.31.0
   gpu-lab-worker          Ready    <none>          40s   v1.31.0
   gpu-lab-worker2         Ready    <none>          40s   v1.31.0
   ```

3. Check that no node advertises GPUs yet:

   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
   ```

   ```
   NAME                    GPU
   gpu-lab-control-plane   <none>
   gpu-lab-worker          <none>
   gpu-lab-worker2         <none>
   ```

4. Advertise four "GPUs" on each worker. The Node `status` is a subresource, so you patch it with `--subresource=status`. In a JSON Patch path, `/` inside a key is escaped as `~1`, so `nvidia.com/gpu` becomes `nvidia.com~1gpu`:

   ```bash
   for n in gpu-lab-worker gpu-lab-worker2; do
     kubectl patch node "$n" --subresource=status --type=json -p '[
       {"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"4"},
       {"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"4"}
     ]'
   done
   ```

5. Simulate the labels that **GPU Feature Discovery (GFD)** adds on a real node, and the taint that many platform teams apply to keep non-GPU workloads off expensive nodes:

   ```bash
   kubectl label node gpu-lab-worker  nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3 nvidia.com/gpu.count=4
   kubectl label node gpu-lab-worker2 nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB nvidia.com/gpu.count=4
   kubectl taint node gpu-lab-worker  nvidia.com/gpu=present:NoSchedule
   kubectl taint node gpu-lab-worker2 nvidia.com/gpu=present:NoSchedule
   ```

6. Verify the result:

   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
   kubectl describe node gpu-lab-worker | sed -n '/Capacity:/,/System Info:/p'
   ```

   ```
   NAME                    GPU      PRODUCT
   gpu-lab-control-plane   <none>   <none>
   gpu-lab-worker          4        NVIDIA-H100-80GB-HBM3
   gpu-lab-worker2         4        NVIDIA-A100-SXM4-80GB
   ```

   ```
   Capacity:
     cpu:                8
     ...
     nvidia.com/gpu:     4
     pods:               110
   Allocatable:
     cpu:                8
     ...
     nvidia.com/gpu:     4
     pods:               110
   ```

**Check your understanding**

- **Q1.1** On a production cluster, which component writes `nvidia.com/gpu: 4` into the Node status, and through which kubelet interface?
- **Q1.2** What does the scheduler *not* know about these GPUs that a real AI scheduler often needs? Name at least two attributes.
- **Q1.3** Why does a platform team taint GPU nodes, and what must a GPU workload then carry to land on them?

---

## Exercise 2: GPU resource semantics in a Pod spec

**Goal:** learn the validation rules that make GPUs different from CPU and memory. GPUs are an **extended resource**: integer-only, not overcommittable, and requests must equal limits.

1. Create a namespace for the lab:

   ```bash
   kubectl create namespace ai-lab
   ```

2. Try a Pod that requests **half** a GPU. Save as `bad-fraction.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-fraction
     namespace: ai-lab
   spec:
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           limits:
             nvidia.com/gpu: 500m
   ```

   ```bash
   kubectl apply -f bad-fraction.yaml
   ```

   Expected (wording varies slightly by version):

   ```
   The Pod "bad-fraction" is invalid: spec.containers[0].resources.limits[nvidia.com/gpu]: Invalid value: "500m": must be an integer
   ```

3. Try a Pod with a **request but no limit**. Save as `bad-nolimit.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-nolimit
     namespace: ai-lab
   spec:
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           requests:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f bad-nolimit.yaml
   ```

   ```
   The Pod "bad-nolimit" is invalid: spec.containers[0].resources.limits: Required value: Limit must be set for non overcommitable resources
   ```

4. Try a Pod whose request and limit **differ**. Save as `bad-mismatch.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-mismatch
     namespace: ai-lab
   spec:
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           requests:
             nvidia.com/gpu: 1
           limits:
             nvidia.com/gpu: 2
   ```

   ```bash
   kubectl apply -f bad-mismatch.yaml
   ```

   ```
   The Pod "bad-mismatch" is invalid: spec.containers[0].resources.requests[nvidia.com/gpu]: Invalid value: "1": must be equal to nvidia.com/gpu limit ...
   ```

5. Now the correct form: only `limits`, which the API server copies into `requests`. Save as `good-gpu.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: good-gpu
     namespace: ai-lab
   spec:
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           limits:
             nvidia.com/gpu: 2
   ```

   ```bash
   kubectl apply -f good-gpu.yaml
   kubectl get pod good-gpu -n ai-lab -o jsonpath='{.spec.containers[0].resources}{"\n"}'
   kubectl get pod good-gpu -n ai-lab -o wide
   ```

   ```
   {"limits":{"nvidia.com/gpu":"2"},"requests":{"nvidia.com/gpu":"2"}}
   NAME       READY   STATUS    RESTARTS   AGE   IP           NODE             ...
   good-gpu   1/1     Running   0          5s    10.244.1.3   gpu-lab-worker   ...
   ```

6. Inspect what the node now reports as allocated:

   ```bash
   kubectl describe node "$(kubectl get pod good-gpu -n ai-lab -o jsonpath='{.spec.nodeName}')" | sed -n '/Allocated resources:/,/Events:/p'
   ```

   ```
   Allocated resources:
     Resource           Requests     Limits
     --------           --------     ------
     cpu                100m (1%)    0 (0%)
     ...
     nvidia.com/gpu     2            2
   ```

7. Ask for more GPUs than any single node has. Save as `too-big.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: too-big
     namespace: ai-lab
   spec:
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           limits:
             nvidia.com/gpu: 6
   ```

   ```bash
   kubectl apply -f too-big.yaml
   kubectl get pod too-big -n ai-lab
   kubectl describe pod too-big -n ai-lab | tail -n 5
   ```

   ```
   NAME      READY   STATUS    RESTARTS   AGE
   too-big   0/1     Pending   0          10s

   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  10s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient nvidia.com/gpu. preemption: 0/3 nodes are available: ...
   ```

8. Clean up:

   ```bash
   kubectl delete pod good-gpu too-big -n ai-lab
   ```

**Check your understanding**

- **Q2.1** The cluster has 8 GPUs in total and 8 free, yet `too-big` (6 GPUs) stays `Pending`. Explain why, and name two ways an AI team would actually run a job that needs 6 GPUs here.
- **Q2.2** Why does Kubernetes forbid `500m` of `nvidia.com/gpu`, while NVIDIA offers MIG, time-slicing and Run:ai fractional GPUs? How do those features fit inside this integer-only rule?
- **Q2.3** You see a Pod `Pending` with `Insufficient nvidia.com/gpu` but `kubectl describe node` shows `nvidia.com/gpu: 0` in Allocatable on a node that physically has 8 GPUs. Where do you look first?

---

## Exercise 3: Placement on heterogeneous GPU fleets

**Goal:** steer workloads to the right GPU model using node labels (as published by GFD) and node affinity, and see how taints protect GPU nodes.

1. Deploy a CPU-only Pod with no toleration and observe where it lands. Save as `cpu-only.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cpu-only
     namespace: ai-lab
   spec:
     containers:
       - name: web
         image: registry.k8s.io/pause:3.10
         resources:
           requests:
             cpu: 100m
             memory: 64Mi
   ```

   ```bash
   kubectl apply -f cpu-only.yaml
   kubectl get pod cpu-only -n ai-lab -o wide
   kubectl describe pod cpu-only -n ai-lab | tail -n 3
   ```

2. Deploy a training Pod that **must** run on H100 and **prefers** nodes with 4 or more GPUs. Save as `h100-train.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: h100-train
     namespace: ai-lab
   spec:
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: nvidia.com/gpu.product
                   operator: In
                   values:
                     - NVIDIA-H100-80GB-HBM3
         preferredDuringSchedulingIgnoredDuringExecution:
           - weight: 50
             preference:
               matchExpressions:
                 - key: nvidia.com/gpu.count
                   operator: Gt
                   values:
                     - "3"
     containers:
       - name: trainer
         image: registry.k8s.io/pause:3.10
         resources:
           limits:
             nvidia.com/gpu: 4
   ```

   ```bash
   kubectl apply -f h100-train.yaml
   kubectl get pod h100-train -n ai-lab -o wide
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE   IP           NODE             ...
   h100-train   1/1     Running   0          4s    10.244.1.4   gpu-lab-worker   ...
   ```

3. Submit a second H100 Pod requesting 1 GPU (copy the manifest, rename it to `h100-train-2`, set `nvidia.com/gpu: 1`):

   ```bash
   sed -e 's/name: h100-train$/name: h100-train-2/' -e 's/nvidia.com\/gpu: 4/nvidia.com\/gpu: 1/' h100-train.yaml | kubectl apply -f -
   kubectl describe pod h100-train-2 -n ai-lab | tail -n 3
   ```

   Expected message (abbreviated):

   ```
   Warning  FailedScheduling  ...  0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }. ...
   ```

4. Clean up:

   ```bash
   kubectl delete pod cpu-only h100-train h100-train-2 -n ai-lab
   ```

**Check your understanding**

- **Q3.1** Where did `cpu-only` land, and why could it not use the workers? Is that the desired behaviour for an AI cluster?
- **Q3.2** Read the `FailedScheduling` message from step 3 node by node. Which node failed which filter? Why does the A100 node, which has 4 free GPUs, not help?
- **Q3.3** A taint keeps *other* Pods off GPU nodes. What prevents a Pod that tolerates the taint but requests **zero** GPUs from landing on a GPU node and wasting it? Propose a mechanism.

---

## Exercise 4: Priority and preemption for mixed AI workloads

**Goal:** see how `PriorityClass` lets latency-sensitive inference or urgent jobs evict lower-priority batch work when GPUs are full.

1. Create two priority classes. Save as `priorities.yaml`:

   ```yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: batch-low
   value: 1000
   preemptionPolicy: PreemptLowerPriority
   globalDefault: false
   description: "Opportunistic training and experiments; may be preempted."
   ---
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: inference-high
   value: 100000
   preemptionPolicy: PreemptLowerPriority
   globalDefault: false
   description: "Production inference; may preempt batch-low."
   ```

   ```bash
   kubectl apply -f priorities.yaml
   kubectl get priorityclass
   ```

2. Fill all 8 GPUs with low-priority batch work: a Deployment of 8 replicas, 1 GPU each. Save as `batch-fill.yaml`:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: batch-fill
     namespace: ai-lab
   spec:
     replicas: 8
     selector:
       matchLabels:
         app: batch-fill
     template:
       metadata:
         labels:
           app: batch-fill
       spec:
         priorityClassName: batch-low
         tolerations:
           - key: nvidia.com/gpu
             operator: Exists
             effect: NoSchedule
         containers:
           - name: worker
             image: registry.k8s.io/pause:3.10
             resources:
               limits:
                 nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f batch-fill.yaml
   kubectl get pods -n ai-lab -l app=batch-fill -o wide
   ```

   Confirm 8 Pods are `Running`, 4 on each worker.

3. Submit a high-priority inference Pod needing 2 GPUs. Save as `inference.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: llm-inference
     namespace: ai-lab
   spec:
     priorityClassName: inference-high
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: server
         image: registry.k8s.io/pause:3.10
         resources:
           limits:
             nvidia.com/gpu: 2
   ```

   ```bash
   kubectl apply -f inference.yaml
   kubectl get events -n ai-lab --sort-by=.lastTimestamp | grep -Ei 'preempt|schedul' | tail -n 8
   kubectl get pods -n ai-lab -o wide
   ```

   Expected (abbreviated):

   ```
   Normal   Preempted   pod/batch-fill-7d9c...-abcde   Preempted by pod 4f1c... on node gpu-lab-worker2
   Normal   Preempted   pod/batch-fill-7d9c...-fghij   Preempted by pod 4f1c... on node gpu-lab-worker2
   Normal   Scheduled   pod/llm-inference              Successfully assigned ai-lab/llm-inference to gpu-lab-worker2
   ```

   ```
   NAME                          READY   STATUS    ...   NODE
   batch-fill-7d9c...-xxxxx      0/1     Pending   ...   <none>
   batch-fill-7d9c...-yyyyy      0/1     Pending   ...   <none>
   batch-fill-7d9c...-...        1/1     Running   ...   gpu-lab-worker
   ...
   llm-inference                 1/1     Running   ...   gpu-lab-worker2
   ```

4. Look at the nominated node field, which the scheduler sets during preemption:

   ```bash
   kubectl get pod llm-inference -n ai-lab -o jsonpath='{.status.nominatedNodeName}{"\n"}{.spec.nodeName}{"\n"}'
   ```

5. Clean up:

   ```bash
   kubectl delete deployment batch-fill -n ai-lab
   kubectl delete pod llm-inference -n ai-lab
   ```

**Check your understanding**

- **Q4.1** Exactly how many batch Pods were evicted, and why did they all come from the same node?
- **Q4.2** Two batch Pods are now `Pending`. The Deployment controller recreated them. What happens to them when `llm-inference` is deleted?
- **Q4.3** Preemption of a single-GPU stateless Pod is cheap. Why is preempting one worker of a 64-GPU distributed training job much more expensive, and what must the training code do to make preemption tolerable?

---

## Exercise 5: The gang-scheduling problem and quota-based admission with Kueue

**Goal:** reproduce the partial-allocation deadlock that hits distributed training on a plain Kubernetes scheduler, then fix it with **Kueue**, a Kubernetes-native job queueing controller that admits a whole workload only when its full quota fits.

### Part A: reproduce the problem

1. Each "distributed training job" below has 6 workers with 1 GPU each. A real all-reduce job (NCCL, PyTorch DDP) cannot make progress until **all** 6 workers are up. Save as `job-a.yaml`:

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: train-a
     namespace: ai-lab
   spec:
     parallelism: 6
     completions: 6
     backoffLimit: 0
     template:
       metadata:
         labels:
           job: train-a
       spec:
         restartPolicy: Never
         tolerations:
           - key: nvidia.com/gpu
             operator: Exists
             effect: NoSchedule
         containers:
           - name: worker
             image: busybox:1.36
             command: ["sh", "-c", "sleep 600"]
             resources:
               requests:
                 cpu: 100m
                 memory: 64Mi
               limits:
                 cpu: 100m
                 memory: 64Mi
                 nvidia.com/gpu: 1
   ```

2. Create a second job `train-b` from the same manifest and submit both together:

   ```bash
   sed 's/train-a/train-b/g' job-a.yaml > job-b.yaml
   kubectl apply -f job-a.yaml -f job-b.yaml
   sleep 10
   for j in train-a train-b; do
     echo "$j running: $(kubectl get pods -n ai-lab -l job=$j --field-selector=status.phase=Running --no-headers | wc -l)"
   done
   ```

   A possible output:

   ```
   train-a running: 4
   train-b running: 4
   ```

   Your split may differ (6/2, 5/3, 4/4). Note it down.

3. Clean up:

   ```bash
   kubectl delete job train-a train-b -n ai-lab
   ```

### Part B: fix it with Kueue

4. Install Kueue. Pick the latest release from https://github.com/kubernetes-sigs/kueue/releases and set it in the variable:

   ```bash
   KUEUE_VERSION=vX.Y.Z   # replace with the current release tag
   kubectl apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"
   kubectl -n kueue-system wait --for=condition=Available deployment/kueue-controller-manager --timeout=180s
   ```

5. Define the quota objects. A `ResourceFlavor` describes a kind of capacity (here, "any GPU node"), a `ClusterQueue` holds the quota, and a namespaced `LocalQueue` is what users submit to. Save as `kueue-setup.yaml`:

   ```yaml
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: ResourceFlavor
   metadata:
     name: gpu-node
   spec:
     nodeLabels:
       nvidia.com/gpu.count: "4"
   ---
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: ClusterQueue
   metadata:
     name: research-cq
   spec:
     namespaceSelector: {}
     queueingStrategy: BestEffortFIFO
     resourceGroups:
       - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
         flavors:
           - name: gpu-node
             resources:
               - name: cpu
                 nominalQuota: 4
               - name: memory
                 nominalQuota: 4Gi
               - name: nvidia.com/gpu
                 nominalQuota: 8
   ---
   apiVersion: kueue.x-k8s.io/v1beta1
   kind: LocalQueue
   metadata:
     name: research
     namespace: ai-lab
   spec:
     clusterQueue: research-cq
   ```

   ```bash
   kubectl apply -f kueue-setup.yaml
   kubectl get clusterqueue,localqueue -A
   ```

   > Check the Kueue docs for the API version shipped by your release; recent releases may serve a newer version alongside `v1beta1`.

6. Add the queue label to both jobs and submit again:

   ```bash
   for f in job-a.yaml job-b.yaml; do
     sed 's/^  namespace: ai-lab$/  namespace: ai-lab\n  labels:\n    kueue.x-k8s.io\/queue-name: research/' "$f" > "kueue-$f"
   done
   grep -A2 'namespace: ai-lab' kueue-job-a.yaml | head -n 3
   kubectl apply -f kueue-job-a.yaml -f kueue-job-b.yaml
   ```

   The `grep` should show the label under `metadata`:

   ```
     namespace: ai-lab
     labels:
       kueue.x-k8s.io/queue-name: research
   ```

7. Inspect admission:

   ```bash
   kubectl get workloads -n ai-lab
   kubectl get jobs -n ai-lab -o custom-columns='NAME:.metadata.name,SUSPENDED:.spec.suspend,ACTIVE:.status.active'
   kubectl describe clusterqueue research-cq | sed -n '/Flavors Usage:/,/Events:/p'
   ```

   Expected (names and wording abbreviated):

   ```
   NAME                QUEUE      RESERVED IN   ADMITTED   AGE
   job-train-a-1a2b3   research   research-cq   True       8s
   job-train-b-4c5d6   research                             8s

   NAME      SUSPENDED   ACTIVE
   train-a   false       6
   train-b   true        <none>
   ```

   ```bash
   kubectl describe workload -n ai-lab "$(kubectl get workloads -n ai-lab -o name | grep train-b)" | grep -A3 'Conditions:'
   ```

   You should see a `QuotaReserved=False` condition whose message mentions insufficient quota for `nvidia.com/gpu` in flavor `gpu-node`.

8. Delete `train-a` and watch `train-b` get admitted as a whole:

   ```bash
   kubectl delete job train-a -n ai-lab
   sleep 5
   kubectl get jobs -n ai-lab -o custom-columns='NAME:.metadata.name,SUSPENDED:.spec.suspend,ACTIVE:.status.active'
   ```

   ```
   NAME      SUSPENDED   ACTIVE
   train-b   false       6
   ```

9. Clean up:

   ```bash
   kubectl delete job train-b -n ai-lab
   ```

**Check your understanding**

- **Q5.1** In Part A, assume the split was 4/4. Describe what happens to a real distributed training job in that state, and why the default scheduler does not detect it.
- **Q5.2** Kueue never schedules a Pod onto a node itself. What is the mechanism by which it holds back `train-b`, and which component still places the Pods?
- **Q5.3** Kueue quota is *cluster-wide* accounting. Construct a scenario where Kueue admits a 6-GPU job, yet some of its Pods still stay `Pending`. What additional feature or scheduler addresses that?
- **Q5.4** Name two other gang-capable schedulers or platforms used for AI workloads on Kubernetes, and one HPC scheduler where gang allocation is the default behaviour.

---

## Exercise 6 (Track B): GPU Operator, sharing strategies and DCGM telemetry on a real node

**Goal:** connect the abstract `nvidia.com/gpu` counter to the components that produce it, and practise the two NVIDIA GPU-sharing mechanisms (time-slicing and MIG). Run on a cluster with the GPU Operator installed in namespace `gpu-operator`. **Do the MIG step only on a node you are allowed to reconfigure**: changing MIG geometry drains GPU workloads on that node.

1. List the operator-managed components:

   ```bash
   kubectl get pods -n gpu-operator -o wide
   ```

   Typical output (abbreviated):

   ```
   NAME                                              READY   STATUS      ...
   gpu-feature-discovery-xxxxx                       1/1     Running
   gpu-operator-xxxxxxxxxx-xxxxx                     1/1     Running
   nvidia-container-toolkit-daemonset-xxxxx          1/1     Running
   nvidia-cuda-validator-xxxxx                       0/1     Completed
   nvidia-dcgm-exporter-xxxxx                        1/1     Running
   nvidia-device-plugin-daemonset-xxxxx              1/1     Running
   nvidia-driver-daemonset-xxxxx                     1/1     Running
   nvidia-mig-manager-xxxxx                          1/1     Running
   nvidia-operator-validator-xxxxx                   1/1     Running
   node-feature-discovery-worker-xxxxx               1/1     Running
   ```

2. Inspect what GFD publishes on a GPU node:

   ```bash
   NODE=<your-gpu-node>
   kubectl get node "$NODE" -o json | jq -r '.metadata.labels | to_entries[] | select(.key|startswith("nvidia.com/")) | "\(.key)=\(.value)"'
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

3. Run a real CUDA smoke test. Save as `nvidia-smi.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nvidia-smi
     namespace: ai-lab
   spec:
     restartPolicy: Never
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: smi
         image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
         command: ["nvidia-smi", "-L"]
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f nvidia-smi.yaml
   kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/nvidia-smi -n ai-lab --timeout=120s
   kubectl logs nvidia-smi -n ai-lab
   ```

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c...)
   ```

4. **Time-slicing.** Create a device-plugin config that advertises each physical GPU as 4 schedulable replicas. Save as `time-slicing.yaml`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: time-slicing-config
     namespace: gpu-operator
   data:
     any: |-
       version: v1
       flags:
         migStrategy: none
       sharing:
         timeSlicing:
           resources:
             - name: nvidia.com/gpu
               replicas: 4
   ```

   ```bash
   kubectl apply -f time-slicing.yaml
   kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge \
     -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
   kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n gpu-operator
   kubectl get node "$NODE" -o json | jq '{gpu: .status.allocatable["nvidia.com/gpu"], replicas: .metadata.labels["nvidia.com/gpu.replicas"], product: .metadata.labels["nvidia.com/gpu.product"]}'
   ```

   On a node with 8 physical GPUs:

   ```
   {
     "gpu": "32",
     "replicas": "4",
     "product": "NVIDIA-H100-80GB-HBM3-SHARED"
   }
   ```

5. Revert time-slicing before the MIG step:

   ```bash
   kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type json \
     -p '[{"op":"remove","path":"/spec/devicePlugin/config"}]'
   ```

6. **MIG** (A100/H100 only, MIG strategy `mixed` in the ClusterPolicy). Ask the MIG Manager to partition every GPU on the node into seven 1g.10gb instances:

   ```bash
   kubectl label node "$NODE" nvidia.com/mig.config=all-1g.10gb --overwrite
   kubectl get node "$NODE" -L nvidia.com/mig.config.state -w
   ```

   Wait until the state is `success`, then:

   ```bash
   kubectl get node "$NODE" -o json | jq '.status.allocatable | with_entries(select(.key|startswith("nvidia.com/")))'
   ```

   On an 8× H100 80GB node:

   ```
   {
     "nvidia.com/gpu": "0",
     "nvidia.com/mig-1g.10gb": "56"
   }
   ```

   A workload now asks for a slice explicitly:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: mig-infer
     namespace: ai-lab
   spec:
     restartPolicy: Never
     tolerations:
       - key: nvidia.com/gpu
         operator: Exists
         effect: NoSchedule
     containers:
       - name: smi
         image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
         command: ["nvidia-smi", "-L"]
         resources:
           limits:
             nvidia.com/mig-1g.10gb: 1
   ```

   Revert when done: `kubectl label node "$NODE" nvidia.com/mig.config=all-disabled --overwrite`.

7. **DCGM telemetry.** Scrape the DCGM exporter directly:

   ```bash
   kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep -E '^DCGM_FI_(DEV_GPU_UTIL|DEV_FB_USED|DEV_GPU_TEMP|PROF_GR_ENGINE_ACTIVE)' | head
   kill %1
   ```

   Example lines:

   ```
   DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3f1c...",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-1",container="trainer",namespace="ai-lab",pod="train-a-0"} 97
   DCGM_FI_DEV_FB_USED{gpu="0",...} 61234
   ```

   If Prometheus scrapes the exporter, this query shows GPUs that are allocated to a Pod but idle, the main target of utilization programmes:

   ```yaml
   groups:
     - name: gpu-efficiency
       rules:
         - alert: GPUAllocatedButIdle
           expr: |
             avg_over_time(DCGM_FI_DEV_GPU_UTIL{pod!=""}[30m])
               < 10
           for: 30m
           labels:
             severity: warning
           annotations:
             summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} allocated to {{ $labels.namespace }}/{{ $labels.pod }} is under 10% utilized"
   ```

**Check your understanding**

- **Q6.1** Map each component from step 1 to its role: which one installs the driver, which makes containers see GPUs, which advertises the resource, which labels nodes, which exports metrics, which reconfigures MIG?
- **Q6.2** After enabling time-slicing with `replicas: 4`, a Pod asks for `nvidia.com/gpu: 1`. What fraction of GPU memory and compute isolation does it get? Contrast with a `mig-1g.10gb` slice.
- **Q6.3** Why does `nvidia.com/gpu` drop to `0` once all GPUs are in MIG mode with the `mixed` strategy? What would the resource name be with the `single` strategy?
- **Q6.4** `DCGM_FI_DEV_GPU_UTIL` reads 100% while the training job is slow. Why is `DCGM_FI_PROF_GR_ENGINE_ACTIVE` (or the SM activity/occupancy profiling fields) a better signal of real work?

---

## Exercise 7 (Track C): Slurm for multi-node GPU training

**Goal:** read and write Slurm batch scripts for GPU jobs and reason about how Slurm allocates, queues and backfills. NVIDIA DGX SuperPOD and clusters built with **NVIDIA Base Command Manager** commonly run Slurm for training, Kubernetes for serving, or both side by side. If you have a Slurm cluster, run the commands; otherwise, predict the outputs.

1. Survey the cluster:

   ```bash
   sinfo -o "%P %a %D %t %G"
   squeue -o "%.8i %.10P %.12j %.8u %.2t %.10M %.5D %R"
   ```

   Example:

   ```
   PARTITION AVAIL NODES STATE GRES
   dgx* up 2 mix gpu:h100:8
   dgx* up 2 idle gpu:h100:8

      JOBID  PARTITION         NAME     USER ST       TIME NODES NODELIST(REASON)
       1201        dgx     llm-pt-a    alice  R      45:10     2 dgx[01-02]
   ```

2. Write a two-node, 16-GPU training script. Save as `train.sbatch`:

   ```bash
   #!/bin/bash
   #SBATCH --job-name=llm-ft
   #SBATCH --partition=dgx
   #SBATCH --nodes=2
   #SBATCH --ntasks-per-node=8
   #SBATCH --gpus-per-node=8
   #SBATCH --cpus-per-task=12
   #SBATCH --mem=0
   #SBATCH --exclusive
   #SBATCH --time=04:00:00
   #SBATCH --output=%x-%j.out

   export MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)
   export MASTER_PORT=29500

   srun --container-image=nvcr.io/nvidia/pytorch:24.05-py3 \
        python train.py --world-size "$SLURM_NTASKS"
   ```

   > `--container-image` requires the Pyxis/Enroot plugin, which NVIDIA uses on DGX-class Slurm clusters. Without it, drop the flag and use a module-loaded environment.

3. Submit and inspect:

   ```bash
   sbatch train.sbatch
   squeue -u "$USER"
   scontrol show job <JOBID> | grep -E 'JobState|Reason|NumNodes|TRES|StartTime'
   ```

   Possible output while waiting:

   ```
   Submitted batch job 1202
      JOBID PARTITION   NAME   USER ST  TIME NODES NODELIST(REASON)
       1202       dgx llm-ft    bob PD  0:00     2 (Resources)
   JobState=PENDING Reason=Resources ...
   NumNodes=2-2 ... TRES=cpu=192,node=2,billing=192,gres/gpu=16
   StartTime=2026-11-14T15:20:00
   ```

4. After completion, check accounting:

   ```bash
   sacct -j <JOBID> --format=JobID,JobName,State,Elapsed,AllocTRES%40,ExitCode
   ```

5. **Backfill scenario (paper).** The cluster has 4 nodes × 8 H100. Current state at 12:00:

   | Job | Nodes | Time limit | State |
   |---|---|---|---|
   | J1 | 2 | ends at 14:00 | Running |
   | J2 | 4 | 6 h | Pending, highest priority |
   | J3 | 1 | 1 h 30 min | Pending, low priority |
   | J4 | 2 | 3 h | Pending, low priority |

**Check your understanding**

- **Q7.1** Does `train.sbatch` start running on one node while waiting for the second? Compare with Exercise 5 Part A.
- **Q7.2** What do `--gpus-per-node=8` and the older `--gres=gpu:8` have in common, and what does `--exclusive` add?
- **Q7.3** In the backfill scenario, which pending jobs can start at 12:00 without delaying J2, and why? What would happen if J3's user had requested `--time=03:00:00` instead?
- **Q7.4** Why do users have an incentive to set accurate `--time` limits on a backfill-scheduled cluster?

---

## Exercise 8 (Track C): Fair-share GPU platforms and choosing an orchestrator

**Goal:** reason about Run:ai-style GPU scheduling (projects, quotas, over-quota, fractions) and choose the right orchestration layer for a given workload mix.

1. A cluster runs NVIDIA Run:ai on top of Kubernetes with 32 GPUs. Three projects are configured:

   | Project | Guaranteed quota | Over-quota allowed | Current demand |
   |---|---|---|---|
   | nlp | 16 | yes | 24 GPUs of training |
   | vision | 8 | yes | 2 GPUs |
   | serving | 8 | no | 6 GPUs of NIM inference, each 0.5 GPU fractions → 12 pods |

   Write down how many GPUs each project is actually using once the scheduler reaches steady state.

2. Ten minutes later the `vision` team submits 8 more GPUs of training (total demand now 10).

3. Classify these workloads to an orchestration approach (Slurm, Kubernetes + default scheduler, Kubernetes + Kueue or Run:ai):

   - (a) A 256-GPU pretraining run, MPI/NCCL, 3 weeks, owned by a research team used to HPC.
   - (b) An autoscaled NIM inference service with an SLO of p95 < 300 ms.
   - (c) 40 data scientists running Jupyter notebooks that are idle most of the day.
   - (d) Nightly fine-tuning pipelines of 8 GPUs each, submitted by CI.

**Check your understanding**

- **Q8.1** Give the steady-state allocation from step 1 and justify the number for `nlp`.
- **Q8.2** What happens after step 2, and which workloads are affected?
- **Q8.3** Twelve pods of 0.5 GPU fit on 6 physical GPUs. What isolation does a Run:ai fraction give compared to MIG, and why did the NVIDIA blog on Run:ai and NIM highlight fractions for inference specifically?
- **Q8.4** Give your classification for (a) to (d) with a one-line reason each.
- **Q8.5** Where does NVIDIA Base Command Manager fit relative to Slurm, Kubernetes and Run:ai?

---

## Answers

<details>
<summary>Exercise 1</summary>

- **Q1.1** The **NVIDIA device plugin** DaemonSet (deployed and managed by the GPU Operator). It registers with the kubelet through the **Device Plugin API** (gRPC over a Unix socket in `/var/lib/kubelet/device-plugins/`) and reports the list of healthy device IDs via `ListAndWatch`. The kubelet then publishes the count in `status.capacity`/`status.allocatable`, and on container start calls `Allocate` so the plugin can tell the runtime which device to inject.
- **Q1.2** The default scheduler only sees a count. It does not know the GPU model or memory size (unless exposed as labels by GFD), NVLink/NVSwitch topology between GPUs, PCIe/NUMA affinity to NICs and CPUs, the InfiniBand rail or rack placement, current utilization or health beyond "healthy/unhealthy". Topology-aware and gang-aware schedulers add these.
- **Q1.3** GPU nodes are scarce and expensive; without a taint, ordinary Pods (web apps, sidecars, CI runners) fill their CPU and memory and can block GPU jobs that also need CPU/RAM. GPU workloads must carry a **toleration** for the taint (`nvidia.com/gpu` with `operator: Exists`, effect `NoSchedule`). Note: some clusters use the `ExtendedResourceToleration` admission plugin, which adds the toleration automatically to Pods that request `nvidia.com/gpu`.

</details>

<details>
<summary>Exercise 2</summary>

- **Q2.1** A single Pod cannot span nodes; every container's resources must fit on one node, and each node only has 4 GPUs. Options: (1) split the job into multiple Pods (for example 6 × 1 GPU or 2 × 3 GPU workers) with a distributed framework (PyTorch DDP via a `PyTorchJob`, MPI Operator, JobSet), ideally with gang admission; (2) run it on nodes with 8 GPUs (DGX/HGX class), which is the common production layout.
- **Q2.2** The scheduler and the device plugin API account for whole devices. NVIDIA's sharing features work by changing **what a "device" is**: MIG presents each GPU instance as its own device (`nvidia.com/mig-1g.10gb: 1`); time-slicing advertises each physical GPU as N replica devices (`nvidia.com/gpu: 1` = one replica); Run:ai fractions are handled by the Run:ai scheduler and its own GPU-sharing mechanism rather than by a fractional quantity in the Pod spec. The Pod still requests an integer of some resource.
- **Q2.3** The node-side GPU stack: is the device plugin Pod running and healthy on that node (`kubectl get pods -n gpu-operator -o wide`, its logs)? Then the driver DaemonSet / validator status, `nvidia-smi` on the host, and whether GPUs were marked unhealthy (XID errors in `dmesg`, DCGM health). Also check whether MIG mode is enabled with the `mixed` strategy, where GPUs appear as `nvidia.com/mig-*` and `nvidia.com/gpu` is legitimately 0.

</details>

<details>
<summary>Exercise 3</summary>

- **Q3.1** `cpu-only` stays `Pending` (or, if your control plane is untainted in some setups, lands there): both workers carry the `nvidia.com/gpu=present:NoSchedule` taint and the control-plane node carries its own taint. In a real AI cluster you would have CPU worker nodes for such Pods. Keeping non-GPU Pods off GPU nodes is desired.
- **Q3.2** Control plane: untolerated control-plane taint. `gpu-lab-worker2` (A100): fails **node affinity**, since the Pod requires `NVIDIA-H100-80GB-HBM3`. `gpu-lab-worker` (H100): passes affinity but fails **NodeResourcesFit**, since `h100-train` already holds all 4 GPUs. The A100's free GPUs are irrelevant because the hard requirement excludes that node; the `preferred` rule only scores nodes that already passed filtering.
- **Q3.3** Nothing in the scheduler by default. Options: an admission policy (ValidatingAdmissionPolicy, Kyverno or OPA Gatekeeper) that rejects Pods tolerating `nvidia.com/gpu` unless they request a GPU resource; using the `ExtendedResourceToleration` admission plugin so users never write the toleration by hand (it is added only to Pods that request the resource); or quotas per namespace.

</details>

<details>
<summary>Exercise 4</summary>

- **Q4.1** Two. The scheduler looks for a single node where evicting the **minimum** set of lower-priority victims makes the preemptor fit. 2 GPUs are needed and every victim holds 1 GPU, so exactly 2 victims on one node suffice; evicting Pods on different nodes would not create 2 free GPUs on the same node.
- **Q4.2** They remain `Pending` while all GPUs are busy. When `llm-inference` is deleted, its 2 GPUs are freed and the scheduler places the 2 pending batch Pods there (they are retried on cluster events such as Pod deletion).
- **Q4.3** Synchronous data-parallel training stalls as soon as one rank disappears; NCCL collectives hang or fail, and the whole job typically restarts. Without checkpoints, all progress since the last restart is lost across all 64 GPUs. Training code must **checkpoint regularly** and support **resume** (and ideally elastic world size, such as `torchrun` elastic). Platforms also use gang-aware preemption (evict whole jobs, not single workers) and grace periods (`terminationGracePeriodSeconds`) to allow a final checkpoint.

</details>

<details>
<summary>Exercise 5</summary>

- **Q5.1** Each job has 4 running workers that block on rendezvous/all-reduce waiting for the 2 missing ranks, and 2 Pending Pods that can never schedule because the other job holds the remaining GPUs. Both jobs hold 8 GPUs doing nothing: a **resource deadlock**. The default scheduler schedules Pods one at a time and has no concept of "this Pod is useless unless its 5 siblings also run".
- **Q5.2** Kueue keeps the Job **suspended** (`spec.suspend: true`) via its webhook and controller; a suspended Job creates no Pods. When the Workload's full resource request fits in the ClusterQueue's quota, Kueue reserves quota, flips `suspend` to `false`, and injects node affinity for the chosen flavor. The Job controller then creates the Pods and **kube-scheduler** binds them to nodes.
- **Q5.3** Quota is a sum, not a placement. Example: quota of 8 GPUs, 6 free, but fragmented as 3 free on each node, and the job asks for 2 Pods of 3 GPUs each, which fits; but if the job asked for one Pod of 6 GPUs it would be admitted and still be unschedulable. Or a non-Kueue Pod occupies GPUs that the quota thinks are free. Addressed by Kueue's **Topology Aware Scheduling** / provisioning admission checks, and by gang schedulers that check actual placement (Volcano, the Kubernetes scheduler-plugins **coscheduling** PodGroup, NVIDIA Run:ai / KAI Scheduler).
- **Q5.4** Kubernetes: **Volcano**, **NVIDIA Run:ai** (and its open-sourced **KAI Scheduler**), scheduler-plugins **coscheduling**, YuniKorn. HPC: **Slurm**, which allocates all requested nodes before the job starts.

</details>

<details>
<summary>Exercise 6</summary>

- **Q6.1** `nvidia-driver-daemonset`: compiles/loads the NVIDIA kernel driver. `nvidia-container-toolkit-daemonset`: configures containerd/CRI-O so containers get GPU device nodes and libraries. `nvidia-device-plugin-daemonset`: advertises `nvidia.com/gpu` (or MIG resources) to the kubelet. `node-feature-discovery` + `gpu-feature-discovery`: label nodes with hardware and GPU attributes (`nvidia.com/gpu.product`, `.memory`, `.count`, MIG capability). `nvidia-dcgm-exporter`: exposes DCGM metrics for Prometheus. `nvidia-mig-manager`: applies the MIG geometry requested by the `nvidia.com/mig.config` label. Validators: verify the stack (CUDA workload test) before the node is marked ready for GPU Pods.
- **Q6.2** Time-slicing gives **no memory or fault isolation**: all replicas share the full GPU memory, a process can consume all of it and cause OOM for others, and compute is shared by context switching, not partitioned. The `replicas` value is a scheduling promise only. A MIG `1g.10gb` slice has dedicated, hardware-isolated memory (10 GB), its own SM slice, cache and memory bandwidth path, and fault isolation, so a noisy neighbour cannot affect its QoS.
- **Q6.3** With `mixed`, each MIG profile is exposed under its own resource name (`nvidia.com/mig-<profile>`), and GPUs with MIG enabled are no longer advertised as whole `nvidia.com/gpu`. With `single`, all GPUs on the node must use the same profile, and the slices are advertised as `nvidia.com/gpu` (each unit is one MIG instance), with GFD labels describing the profile.
- **Q6.4** `GPU_UTIL` measures the fraction of time **at least one kernel** was executing, a coarse duty-cycle. A tiny kernel occupying a few SMs counts as 100%. Profiling fields such as `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_SM_OCCUPANCY` and tensor-pipe activity show how much of the chip is actually busy, revealing input-pipeline stalls, small batches or communication-bound phases.

</details>

<details>
<summary>Exercise 7</summary>

- **Q7.1** No. Slurm grants the **entire allocation** (2 nodes, 16 GPUs) atomically; the job stays `PD` with `Reason=Resources` until both nodes are free, then all tasks launch together. This is gang allocation by default, which avoids the deadlock seen with independently scheduled Pods in Exercise 5 Part A.
- **Q7.2** Both request generic resources (GRES) of type `gpu` per node, which Slurm binds to specific devices and exposes through `CUDA_VISIBLE_DEVICES`/cgroups; `--gpus-per-node` is the newer, GPU-specific option family (`--gpus`, `--gpus-per-task`), while `--gres=gpu[:type]:N` is the generic form. `--exclusive` prevents other jobs from sharing the nodes (CPU cores, memory, NICs), which matters for multi-node training that uses all GPUs and InfiniBand rails.
- **Q7.3** J2 needs all 4 nodes and can start at 14:00 when J1 ends, so 2 nodes are idle from 12:00 to 14:00. **J3** (1 node, 1 h 30 min, finishes 13:30) can backfill. **J4** (2 nodes, 3 h, finishes 15:00) cannot, since it would push J2's start back. With `--time=03:00:00`, J3 would end at 15:00, after J2's reserved start, so it would not backfill and would wait until J2 finishes.
- **Q7.4** Backfill decisions use the **time limit**, not the actual runtime. Short, accurate limits let a job fit in gaps ahead of large reservations; overestimates make jobs look "too long" for the gap, so they wait. Accurate limits also improve overall cluster utilization.

</details>

<details>
<summary>Exercise 8</summary>

- **Q8.1** `serving`: 6 physical GPUs (12 × 0.5), cannot exceed its quota of 8 anyway. `vision`: 2 (its demand). `nlp`: its 16 guaranteed + over-quota from the idle capacity. Idle = 32 − 6 − 2 − 16 = 8, so `nlp` uses 24 (its full demand). Over-quota borrows unused quota from other projects instead of leaving GPUs idle.
- **Q8.2** `vision` is now below its guaranteed quota of 8 (demand 10). The scheduler **reclaims** capacity from the project running over quota: `nlp`'s over-quota workloads (preemptible) are preempted until `vision` gets its 8 guaranteed GPUs. Steady state: `vision` 8 (2 remaining demand could only use idle capacity, and there is none), `nlp` 18 (16 guaranteed + 2 still borrowed from `serving`'s unused 2), `serving` 6. Non-preemptible, in-quota workloads are not touched.
- **Q8.3** A Run:ai fraction shares one GPU between Pods by limiting the GPU **memory** each Pod can allocate and time-sharing compute; it is software-enforced, flexible in size (any fraction, set per workload, no node reconfiguration) but without MIG's hardware isolation of SMs, cache and memory bandwidth. Inference services, including small or mid-size NIM microservices, often use only part of a large GPU and have spiky load, so packing several on one GPU multiplies density and utilization, which is the blog's point; MIG is preferred when strict QoS isolation is required.
- **Q8.4** (a) **Slurm** (or Kubernetes with a gang scheduler): native gang allocation, topology-aware placement, MPI/Pyxis tooling familiar to HPC teams. (b) **Kubernetes default scheduler** with HPA/KServe-style autoscaling and high priority; long-running services, not batch. (c) **Run:ai** (or Kubernetes with fractions/time-slicing/MIG): fractional GPUs and idle-reclaim policies stop idle notebooks from pinning whole GPUs. (d) **Kubernetes + Kueue or Run:ai**: queued batch jobs with quotas, all-or-nothing admission and fair sharing.
- **Q8.5** **Base Command Manager** is the **cluster management** layer: bare-metal provisioning of nodes and images, driver/firmware/software stacks, monitoring and health, and deployment of the workload managers themselves. It can stand up and manage **Slurm** and/or **Kubernetes** clusters on the same infrastructure; Run:ai then runs on top of Kubernetes as the AI-aware scheduler and GPU-sharing layer. So: BCM manages the cluster, Slurm/Kubernetes orchestrate workloads, Run:ai/Kueue add AI-specific queueing, quota and fractional GPU policy.

</details>