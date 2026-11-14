# 3.2 — AI Cluster Orchestration and Job Scheduling Essentials

> **Exam weight: 5.5%.** NCA-AIIO tests whether you can explain *why* AI clusters need specialized orchestration and scheduling, and how the main layers fit together: workload managers (Slurm, Kubernetes), GPU enablement (NVIDIA GPU Operator, device plugin), GPU sharing (MIG, time-slicing, fractional GPUs), queueing and quota systems (Kueue, Volcano, NVIDIA Run:ai), and cluster management (NVIDIA Base Command Manager). This chapter goes deeper than the exam requires so that you understand the mechanics you will operate in production.

---

## 1. Motivation: the architectural problem

### 1.1 Why a generic scheduler is not enough

A traditional web-serving cluster schedules many small, stateless, interchangeable replicas. CPU and memory are fungible, a pod that starts 30 seconds late costs nothing, and a failed replica is replaced transparently.

An AI cluster breaks every one of those assumptions:

| Property | Web / microservices | AI training / inference |
|---|---|---|
| Unit of scarcity | CPU cores, RAM (cheap, divisible) | GPUs (expensive, coarse-grained, integer units) |
| Job shape | Many independent replicas | Tightly coupled groups (8 GPUs × N nodes) that must start together |
| Partial start | Useful (serve with 3 of 5 replicas) | Useless or harmful: 15 of 16 workers sit idle holding GPUs while waiting on NCCL rendezvous |
| Topology sensitivity | Low | High: NVLink/NVSwitch inside a node, InfiniBand/RoCE rail alignment across nodes |
| Duration | Long-running services | Hours to weeks (training) or bursty (notebooks, batch inference) |
| Failure impact | Replace one replica | One GPU Xid error can kill a 1,024-GPU job; checkpoint/restart required |
| Contention | Rare | Constant: demand always exceeds supply, so queueing, quota, priority and preemption are the core product |

The consequence: an AI cluster needs **three distinct capabilities** that a plain container orchestrator does not provide out of the box:

1. **Resource awareness** — the scheduler must know GPUs exist, what model they are, whether they are partitioned (MIG), and how they are interconnected.
2. **Batch semantics** — queueing, gang (all-or-nothing) scheduling, fair-share, quotas, priority, preemption, backfill.
3. **Utilization economics** — an H100 node idling at 10% utilization because a notebook holds all 8 GPUs is a direct financial loss. Sharing (MIG, time-slicing, fractional GPUs) and quota borrowing exist to fix this.

### 1.2 The layered stack

```
┌──────────────────────────────────────────────────────────────────┐
│  Users / MLOps: notebooks, training jobs, NIM inference services  │
├──────────────────────────────────────────────────────────────────┤
│  Policy & queueing: Slurm priority/fair-share | Kueue | Volcano   │
│                     | NVIDIA Run:ai (projects, quotas, fractions) │
├──────────────────────────────────────────────────────────────────┤
│  Orchestrator / workload manager: Slurm  |  Kubernetes            │
├──────────────────────────────────────────────────────────────────┤
│  GPU enablement: driver, container toolkit, device plugin / DRA,  │
│  GPU Feature Discovery, MIG manager, DCGM + DCGM Exporter         │
│  (packaged by the NVIDIA GPU Operator on Kubernetes)              │
├──────────────────────────────────────────────────────────────────┤
│  Cluster provisioning & lifecycle: NVIDIA Base Command Manager    │
│  (image management, node provisioning, monitoring, Slurm/K8s      │
│  deployment), BMC/Redfish for out-of-band management              │
├──────────────────────────────────────────────────────────────────┤
│  Hardware: DGX/HGX nodes, NVLink/NVSwitch, InfiniBand/Ethernet    │
└──────────────────────────────────────────────────────────────────┘
```

Keep this picture in mind: exam questions frequently ask *which layer* solves a given problem (e.g., "users monopolize GPUs" → quota/fair-share layer; "pods can't see GPUs" → GPU enablement layer; "reimage 64 nodes consistently" → BCM).

---

## 2. Workload managers: Slurm vs. Kubernetes

### 2.1 Slurm

Slurm (Simple Linux Utility for Resource Management) is the dominant HPC batch scheduler and remains the default on many DGX SuperPOD deployments. Its components:

| Component | Role |
|---|---|
| `slurmctld` | Central controller: holds the queue, makes scheduling decisions (runs on head node, optionally with a backup) |
| `slurmd` | Per-compute-node daemon: launches and monitors job steps |
| `slurmdbd` | Accounting database daemon (MySQL/MariaDB backend): job history, fair-share usage, associations |
| `slurmrestd` | REST API |
| GRES (Generic RESources) | Mechanism through which GPUs are declared and allocated (`--gres=gpu:8`, `--gpus-per-node=8`) |
| `select/cons_tres` | Selection plugin that allocates individual cores, memory and GPUs (trackable resources) |
| `priority/multifactor` | Priority plugin combining age, fair-share, job size, partition and QOS |
| Pyxis + Enroot | NVIDIA's SPANK plugin (Pyxis) and unprivileged container runtime (Enroot) that let `srun` run NGC containers |

Slurm's strengths for AI: native gang scheduling (a job's allocation is atomic), mature fair-share accounting, backfill scheduling, topology plugins (`topology/tree`, `topology/block`) and very low scheduling overhead for large tightly coupled jobs.

### 2.2 Kubernetes

Kubernetes was designed for services, and AI capabilities arrive through extensions:

- **Device plugin API** (and, since v1.34, **Dynamic Resource Allocation (DRA)** as GA) to expose GPUs as schedulable resources.
- **NVIDIA GPU Operator** to automate the driver, toolkit, device plugin, MIG manager and monitoring stack.
- **Batch add-ons** — Kueue (job queueing and quota, a Kubernetes SIG project), Volcano (batch scheduler with gang scheduling), NVIDIA Run:ai (AI-workload scheduler and platform), and the KAI Scheduler (NVIDIA's open-source release of the Run:ai scheduler core).
- **Training operators / JobSet / LeaderWorkerSet** for multi-pod distributed jobs.

Its strengths: a unified platform for training *and* inference (KServe, NIM Operator), declarative GitOps, autoscaling, a rich ecosystem, and multi-tenancy primitives.

### 2.3 Trade-off table

| Dimension | Slurm | Kubernetes (+ GPU Operator + Kueue/Run:ai) |
|---|---|---|
| Primary workload | Batch training, HPC, MPI | Mixed: inference services, pipelines, notebooks, batch training |
| Gang scheduling | Native | Requires Kueue (`waitForPodsReady`, all-or-nothing admission), Volcano PodGroup, or Run:ai/KAI |
| Fair-share / accounting | Mature (`slurmdbd`, `sshare`, `sacct`) | Quota-based (ClusterQueue, Run:ai projects); historical fair-share is add-on dependent |
| Inference serving | Poor fit (no Service/Ingress/autoscaling model) | Native fit (Deployments, HPA, KServe, NIM) |
| Containers | Optional (Enroot/Pyxis, Apptainer) | Mandatory |
| Scheduling latency at scale | Very low for large jobs | Higher, per-pod; mitigated by batch schedulers |
| GPU sharing | MIG as GRES, MPS, sharding | MIG, time-slicing, MPS, Run:ai fractional GPUs, DRA |
| User interface | `sbatch`/`srun` scripts, SSH to login node | YAML/CLI/UI; GitOps |
| Operational skill set | HPC admins | Platform/SRE teams |
| Typical NVIDIA deployment | DGX SuperPOD with BCM-deployed Slurm | DGX/HGX clusters with BCM-deployed Kubernetes or managed K8s; Run:ai on top |

**Production pattern:** many organizations run both — Slurm for large pre-training runs and Kubernetes for inference, fine-tuning and interactive work — often provisioned and managed from the same NVIDIA Base Command Manager head node.

---

## 3. Core scheduling concepts (exam vocabulary)

| Concept | Definition | Why it matters for AI |
|---|---|---|
| **Queueing** | Jobs wait until resources and policy allow admission | Demand > supply is the normal state |
| **Gang scheduling** | All tasks of a job start together or none start | Prevents deadlock and idle partial allocations in distributed training |
| **Fair-share** | Priority adjusted by historical usage vs. allotted share | Prevents one team from dominating long-term |
| **Quota (guaranteed/nominal)** | Resources a team is entitled to | Predictability for each tenant |
| **Over-quota / borrowing** | Use idle capacity beyond quota | Keeps GPUs busy; borrowed resources are preemptible |
| **Priority & preemption** | Higher-priority work evicts lower-priority work | Production inference > research jobs; reclaim borrowed GPUs |
| **Backfill** | Run small jobs in gaps without delaying the top-priority reservation | Raises utilization while large jobs wait for full nodes |
| **Bin packing vs. spreading** | Consolidate onto few nodes vs. distribute | Packing keeps whole nodes free for 8-GPU jobs; spreading improves resilience for inference |
| **Topology-aware placement** | Place tasks according to NVLink/NVSwitch domains, PCIe/NUMA, network rails | All-reduce performance depends on it |
| **Checkpoint/restart** | Persist state so jobs survive preemption or failure | Mandatory when preemption or hardware failure is expected |

---

## 4. GPU enablement on Kubernetes: NVIDIA GPU Operator

### 4.1 What it deploys

The GPU Operator turns a node with an NVIDIA GPU into a schedulable GPU node, managing everything as containers reconciled from a `ClusterPolicy` custom resource:

| Component | Function |
|---|---|
| NVIDIA driver (containerized) | Kernel driver; can be skipped if pre-installed (`driver.enabled=false`), e.g., on DGX OS |
| NVIDIA Container Toolkit | Configures containerd/CRI-O so containers get GPU device nodes and libraries |
| Device plugin | Advertises `nvidia.com/gpu` (or MIG resources) to the kubelet |
| GPU Feature Discovery (GFD) | Labels nodes: `nvidia.com/gpu.product`, `nvidia.com/gpu.memory`, `nvidia.com/mig.capable`, etc. |
| Node Feature Discovery (NFD) | Detects PCI devices/kernel features; GFD depends on it |
| MIG Manager | Applies MIG geometry from the `nvidia.com/mig.config` node label |
| DCGM / DCGM Exporter | GPU telemetry exported as Prometheus metrics |
| Validator | Runs CUDA/driver validation workloads |

### 4.2 Installation

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories
$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --set driver.enabled=true \
    --set mig.strategy=mixed \
    --wait
NAME: gpu-operator
LAST DEPLOYED: Sat Nov 14 10:12:41 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Expected pods once reconciled:

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xq2c                                   1/1     Running     0          6m
gpu-operator-6d8f7c9b8d-lk2hv                                 1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5f8b9d7c6-xp4rn        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7c9d8b6f5-qm2zt    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-rk8w5              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-9pkfq                      1/1     Running     0          6m
nvidia-cuda-validator-hc5vt                                   0/1     Completed   0          5m
nvidia-dcgm-exporter-b4l7n                                    1/1     Running     0          6m
nvidia-device-plugin-daemonset-2wq8d                          1/1     Running     0          6m
nvidia-driver-daemonset-f7mxs                                 1/1     Running     0          7m
nvidia-mig-manager-zj6tc                                      1/1     Running     0          5m
nvidia-operator-validator-8sd9k                               1/1     Running     0          6m
```

Verify the node advertises GPUs:

```
$ kubectl get node dgx-h100-01 -o jsonpath='{.status.allocatable}' | jq .
{
  "cpu": "223",
  "ephemeral-storage": "1715037736447",
  "hugepages-1Gi": "0",
  "hugepages-2Mi": "0",
  "memory": "2112423960Ki",
  "nvidia.com/gpu": "8",
  "pods": "110"
}

$ kubectl get node dgx-h100-01 --show-labels | tr ',' '\n' | grep nvidia.com/gpu
nvidia.com/gpu.count=8
nvidia.com/gpu.family=hopper
nvidia.com/gpu.memory=81559
nvidia.com/gpu.present=true
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
```

### 4.3 Requesting a GPU

GPUs are **extended resources**: integer-only, cannot be overcommitted, and `limits` must be set (if `requests` is given it must equal `limits`).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: ml-research
spec:
  restartPolicy: OnFailure
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1
          cpu: "4"
          memory: 16Gi
        requests:
          nvidia.com/gpu: 1
          cpu: "4"
          memory: 16Gi
```

```
$ kubectl apply -f cuda-vectoradd.yaml
pod/cuda-vectoradd created
$ kubectl logs -n ml-research cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

### 4.4 Device plugin vs. Dynamic Resource Allocation (DRA)

| Aspect | Device plugin | DRA (GA in Kubernetes v1.34, `resource.k8s.io/v1`) |
|---|---|---|
| Request model | Integer count of a named resource | `ResourceClaim` referencing a `DeviceClass`, with CEL selectors on device attributes |
| Attribute selection | Indirect, via node labels | Direct (memory, architecture, MIG profile, interconnect) |
| Sharing between pods | Via time-slicing/MIG configured node-wide | A claim can be shared by multiple pods/containers |
| Reconfiguration | Node-level (relabel, restart plugin) | Per-claim, driver-dependent |
| NVIDIA implementation | `k8s-device-plugin` (in GPU Operator) | NVIDIA DRA driver for GPUs |
| Maturity in GPU fleets | Ubiquitous, default | Emerging; adopt where flexible GPU/ComputeDomain allocation is needed |

For the exam, know the device plugin model (`nvidia.com/gpu: N`) as the standard mechanism; know DRA as the newer, more expressive API.

---

## 5. GPU sharing: MIG, time-slicing, MPS, fractional GPUs

### 5.1 Comparison

| Technique | Isolation | Memory protection | Fault isolation | QoS | Granularity | Best for |
|---|---|---|---|---|---|---|
| **Whole GPU** | Full | Full | Full | Guaranteed | 1 GPU | Training, large-model inference |
| **MIG** (Ampere A100/A30, Hopper H100/H200, Blackwell) | Hardware: dedicated SMs, L2 slices, memory controllers | Yes | Yes (per instance) | Guaranteed per instance | Up to 7 instances per GPU | Multi-tenant inference, notebooks, CI, small fine-tunes |
| **Time-slicing** | None (temporal multiplexing via the CUDA scheduler) | No | No (one OOM/Xid can affect all) | None; context-switch overhead | Arbitrary replica count | Dev/test, light, bursty workloads, trusted tenants |
| **MPS** (Multi-Process Service) | Spatial sharing of SMs within one context | Limited (address space isolation on Volta+), no full fault isolation | Limited | Configurable thread percentage | Process-level | Many small cooperating inference processes |
| **Run:ai fractional GPU** | Software-enforced memory slice + time sharing | Memory limit enforced by Run:ai | No hardware fault isolation | Scheduler-managed | Fraction (e.g., 0.5) or GPU memory in GB | Notebooks, small inference with high consolidation |

MIG is the only option that gives **hardware-enforced** isolation of compute, cache and memory bandwidth — which is why it is the right answer whenever an exam scenario mentions multi-tenant QoS guarantees or isolation.

### 5.2 MIG profiles

Profiles are named `<compute slices>g.<memory>gb`:

| GPU | Profiles (max instances) |
|---|---|
| A100 40GB | `1g.5gb` (7), `2g.10gb` (3), `3g.20gb` (2), `4g.20gb` (1), `7g.40gb` (1) |
| A100 80GB | `1g.10gb` (7), `1g.20gb` (4), `2g.20gb` (3), `3g.40gb` (2), `4g.40gb` (1), `7g.80gb` (1) |
| H100 80GB | `1g.10gb` (7), `1g.20gb` (4), `2g.20gb` (3), `3g.40gb` (2), `4g.40gb` (1), `7g.80gb` (1) |

### 5.3 MIG strategies in the GPU Operator

- **`single`**: every GPU on a node uses the same profile; MIG devices are exposed as `nvidia.com/gpu` (with GFD labels describing the profile). Simple, transparent to workloads.
- **`mixed`**: different profiles may coexist; each is exposed as its own resource, e.g. `nvidia.com/mig-1g.10gb`, `nvidia.com/mig-3g.40gb`.

Apply a geometry by labeling the node; the MIG Manager drains GPU clients, reconfigures and reports state:

```
$ kubectl label node dgx-h100-02 nvidia.com/mig.config=all-1g.10gb --overwrite
node/dgx-h100-02 labeled

$ kubectl get node dgx-h100-02 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
pending
$ kubectl get node dgx-h100-02 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
success

$ kubectl get node dgx-h100-02 -o jsonpath='{.status.allocatable}' | jq 'with_entries(select(.key|startswith("nvidia.com")))'
{
  "nvidia.com/gpu": "0",
  "nvidia.com/mig-1g.10gb": "56"
}
```

On the node itself:

```
$ nvidia-smi -L
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-5a1c3e2f-8b7d-4c11-9e6a-1f2b3c4d5e6f)
  MIG 1g.10gb     Device  0: (UUID: MIG-0f3a9e21-7c44-5b1d-8a2e-6c7d8e9f0a1b)
  MIG 1g.10gb     Device  1: (UUID: MIG-1a2b3c4d-5e6f-5a7b-8c9d-0e1f2a3b4c5d)
  MIG 1g.10gb     Device  2: (UUID: MIG-2b3c4d5e-6f7a-5b8c-9d0e-1f2a3b4c5d6e)
  MIG 1g.10gb     Device  3: (UUID: MIG-3c4d5e6f-7a8b-5c9d-0e1f-2a3b4c5d6e7f)
  MIG 1g.10gb     Device  4: (UUID: MIG-4d5e6f7a-8b9c-5d0e-1f2a-3b4c5d6e7f8a)
  MIG 1g.10gb     Device  5: (UUID: MIG-5e6f7a8b-9c0d-5e1f-2a3b-4c5d6e7f8a9b)
  MIG 1g.10gb     Device  6: (UUID: MIG-6f7a8b9c-0d1e-5f2a-3b4c-5d6e7f8a9b0c)
...
```

A custom geometry (mixed profiles per GPU) is supplied to the MIG Manager as a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: custom-mig-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    mig-configs:
      all-disabled:
        - devices: all
          mig-enabled: false
      inference-mix:
        - devices: [0, 1, 2, 3]
          mig-enabled: true
          mig-devices:
            "1g.10gb": 7
        - devices: [4, 5]
          mig-enabled: true
          mig-devices:
            "3g.40gb": 2
        - devices: [6, 7]
          mig-enabled: false
```

```
$ kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
    -p '{"spec":{"migManager":{"config":{"name":"custom-mig-config"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched
$ kubectl label node dgx-h100-03 nvidia.com/mig.config=inference-mix --overwrite
node/dgx-h100-03 labeled
```

A pod consuming a MIG slice (mixed strategy):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: triton-small
  namespace: inference
spec:
  containers:
    - name: triton
      image: nvcr.io/nvidia/tritonserver:24.08-py3
      args:
        - tritonserver
        - --model-repository=/models
      resources:
        limits:
          nvidia.com/mig-1g.10gb: 1
          cpu: "4"
          memory: 24Gi
      volumeMounts:
        - name: models
          mountPath: /models
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: triton-models
```

### 5.4 Time-slicing configuration

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
        renameByDefault: false
        failRequestsGreaterThanOne: true
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

```
$ kubectl apply -f time-slicing-config.yaml
configmap/time-slicing-config created
$ kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl get node dgx-dev-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
32
$ kubectl get node dgx-dev-01 --show-labels | tr ',' '\n' | grep -E 'gpu.replicas|gpu.sharing'
nvidia.com/gpu.replicas=4
nvidia.com/gpu.sharing-strategy=time-slicing
```

`failRequestsGreaterThanOne: true` matters: with time-slicing, a request for `nvidia.com/gpu: 2` does **not** give two physical GPUs worth of compute — it could be two replicas of the same GPU. Failing such requests avoids that silent misallocation.

---

## 6. Batch scheduling on Kubernetes: Kueue, Volcano, Run:ai

### 6.1 Positioning

| Tool | Model | Gang scheduling | Quotas & borrowing | Fractional GPU | Notes |
|---|---|---|---|---|---|
| **Kueue** (Kubernetes SIG Scheduling) | Admission controller on top of the default kube-scheduler: suspends jobs until quota admits them | All-or-nothing admission plus `waitForPodsReady` | ClusterQueue nominal quota, cohorts, borrowing/lending limits, fair sharing | No | Integrates with Job, JobSet, Kubeflow training jobs, RayJob, plain Pods |
| **Volcano** (CNCF) | Replacement batch scheduler (`schedulerName: volcano`) | PodGroup `minMember` | Queues with weights/capability | No (vGPU via separate projects) | Strong in MPI/HPC-style jobs |
| **NVIDIA Run:ai** | AI-workload platform + scheduler; hierarchical departments/projects | Yes | Guaranteed quota, over-quota with fair-share, reclaim via preemption | Yes (fraction or memory-based), plus dynamic MIG | UI, CLI, API; workload types for training, inference, workspaces; integrates NIM |
| **KAI Scheduler** | Open-source scheduler derived from Run:ai's | Yes | Hierarchical queues, quotas | GPU sharing | Lightweight option without the full Run:ai platform |

### 6.2 Kueue: complete multi-team setup

Kueue's flow: a Job is created **suspended** → Kueue creates a `Workload` → the `ClusterQueue` checks quota/flavors → on admission Kueue injects node affinity for the chosen flavor and unsuspends the Job → the kube-scheduler places pods.

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: h100
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
  nodeTaints:
    - key: nvidia.com/gpu
      value: "present"
      effect: NoSchedule
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: a100
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-A100-SXM4-80GB
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: WorkloadPriorityClass
metadata:
  name: production
value: 10000
description: "Production training and evaluation"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: WorkloadPriorityClass
metadata:
  name: research
value: 1000
description: "Exploratory research, preemptible"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: team-nlp
spec:
  cohort: gpu-pool
  namespaceSelector:
    matchLabels:
      team: nlp
  queueingStrategy: BestEffortFIFO
  preemption:
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
      maxPriorityThreshold: 1000
    withinClusterQueue: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: h100
          resources:
            - name: cpu
              nominalQuota: 448
            - name: memory
              nominalQuota: 4000Gi
            - name: nvidia.com/gpu
              nominalQuota: 16
              borrowingLimit: 16
        - name: a100
          resources:
            - name: cpu
              nominalQuota: 256
            - name: memory
              nominalQuota: 2000Gi
            - name: nvidia.com/gpu
              nominalQuota: 8
              borrowingLimit: 8
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: team-vision
spec:
  cohort: gpu-pool
  namespaceSelector:
    matchLabels:
      team: vision
  queueingStrategy: BestEffortFIFO
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: h100
          resources:
            - name: cpu
              nominalQuota: 448
            - name: memory
              nominalQuota: 4000Gi
            - name: nvidia.com/gpu
              nominalQuota: 16
              lendingLimit: 8
        - name: a100
          resources:
            - name: cpu
              nominalQuota: 256
            - name: memory
              nominalQuota: 2000Gi
            - name: nvidia.com/gpu
              nominalQuota: 8
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: nlp-queue
  namespace: nlp
spec:
  clusterQueue: team-nlp
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: vision-queue
  namespace: vision
spec:
  clusterQueue: team-vision
```

Mechanics to understand:

- **Flavors are tried in order**: `team-nlp` gets H100 if quota allows, otherwise falls back to A100.
- **Cohort `gpu-pool`**: unused nominal quota in one ClusterQueue can be borrowed by another, bounded by `borrowingLimit` (borrower side) and `lendingLimit` (lender side). `team-vision` lends at most 8 of its 16 H100s.
- **`reclaimWithinCohort: Any`**: when `team-vision` needs its quota back, Kueue preempts borrowing workloads in `team-nlp`.
- **`BestEffortFIFO`** lets smaller workloads that fit be admitted ahead of a blocked head-of-line workload (a form of backfill); `StrictFIFO` does not.

A distributed training Job (indexed, 2 pods × 8 GPUs) submitted to the queue:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: llama-ft
  namespace: nlp
spec:
  clusterIP: None
  selector:
    job-name: llama-ft
  ports:
    - name: rendezvous
      port: 29500
---
apiVersion: batch/v1
kind: Job
metadata:
  name: llama-ft
  namespace: nlp
  labels:
    kueue.x-k8s.io/queue-name: nlp-queue
    kueue.x-k8s.io/priority-class: production
spec:
  suspend: true
  completionMode: Indexed
  completions: 2
  parallelism: 2
  backoffLimit: 0
  template:
    spec:
      subdomain: llama-ft
      restartPolicy: Never
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: trainer
          image: nvcr.io/nvidia/pytorch:24.08-py3
          command:
            - bash
            - -c
            - >-
              torchrun
              --nnodes=2
              --nproc_per_node=8
              --node_rank=${JOB_COMPLETION_INDEX}
              --master_addr=llama-ft-0.llama-ft
              --master_port=29500
              /workspace/train.py --checkpoint-dir /checkpoints
          env:
            - name: NCCL_DEBUG
              value: WARN
          resources:
            limits:
              nvidia.com/gpu: 8
              cpu: "96"
              memory: 900Gi
            requests:
              nvidia.com/gpu: 8
              cpu: "96"
              memory: 900Gi
          volumeMounts:
            - name: dshm
              mountPath: /dev/shm
            - name: checkpoints
              mountPath: /checkpoints
      volumes:
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 64Gi
        - name: checkpoints
          persistentVolumeClaim:
            claimName: nlp-checkpoints
```

Note the `/dev/shm` memory volume: PyTorch DataLoader workers and NCCL use shared memory, and the container default (64 MiB) causes cryptic bus errors.

```
$ kubectl apply -f llama-ft.yaml
service/llama-ft created
job.batch/llama-ft created

$ kubectl get workloads -n nlp
NAME                 QUEUE       RESERVED IN   ADMITTED   FINISHED   AGE
job-llama-ft-8c2e1   nlp-queue   team-nlp      True                  12s

$ kubectl get clusterqueue
NAME          COHORT     PENDING WORKLOADS   ADMITTED WORKLOADS
team-nlp      gpu-pool   0                   1
team-vision   gpu-pool   0                   0

$ kubectl get pods -n nlp -o wide
NAME               READY   STATUS    RESTARTS   AGE   IP            NODE
llama-ft-0-x7k2p   1/1     Running   0          9s    10.244.3.17   dgx-h100-01
llama-ft-1-m4q9t   1/1     Running   0          9s    10.244.5.22   dgx-h100-04
```

### 6.3 Volcano: gang scheduling via PodGroup

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: resnet-dist
  namespace: vision
spec:
  schedulerName: volcano
  minAvailable: 4
  queue: vision
  plugins:
    svc: []
    env: []
  policies:
    - event: PodEvicted
      action: RestartJob
  tasks:
    - name: worker
      replicas: 4
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: worker
              image: nvcr.io/nvidia/pytorch:24.08-py3
              command: ["python", "/workspace/train_resnet.py"]
              resources:
                limits:
                  nvidia.com/gpu: 8
```

`minAvailable: 4` means Volcano binds no pod until all 4 workers can be placed — the classic gang guarantee that prevents two half-scheduled jobs deadlocking each other on a full cluster.

### 6.4 NVIDIA Run:ai

Run:ai adds an AI-specific control plane on Kubernetes:

- **Hierarchy**: Departments → Projects; each has a **guaranteed GPU quota**.
- **Over-quota**: projects may use idle GPUs beyond quota; over-quota workloads are **preemptible** and reclaimed when the owning project needs its guarantee back, with fair-share distribution of the surplus.
- **Workload types**: workspaces (interactive, typically non-preemptible within quota), training (preemptible), inference (with autoscaling and NIM integration).
- **Fractional GPUs**: request `0.5` of a GPU or a memory amount; the Run:ai scheduler packs multiple workloads on one GPU, enforcing the memory slice. **Dynamic MIG** creates MIG instances on demand.
- **Bin packing** by default for training to keep whole nodes free; topology-aware placement for distributed jobs.

The NVIDIA technical blog on Run:ai and NIM describes exactly this pattern: inference microservices (NIM) consume GPU fractions so that low-traffic models don't each pin a full GPU, raising cluster-wide utilization.

A pod scheduled by Run:ai with a half GPU:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: notebook-alice
  namespace: runai-nlp
  labels:
    runai/queue: nlp
  annotations:
    gpu-fraction: "0.5"
spec:
  schedulerName: runai-scheduler
  containers:
    - name: jupyter
      image: nvcr.io/nvidia/pytorch:24.08-py3
      command: ["jupyter", "lab", "--ip=0.0.0.0", "--no-browser", "--allow-root"]
      ports:
        - containerPort: 8888
      resources:
        limits:
          cpu: "8"
          memory: 64Gi
```

Note there is no `nvidia.com/gpu` limit: the fraction is expressed via annotation and enforced by Run:ai. In practice most users submit through the Run:ai CLI/UI, which generates the equivalent objects:

```
$ runai training submit llama-sweep -p nlp -i nvcr.io/nvidia/pytorch:24.08-py3 \
    -g 1 --command -- python /workspace/sweep.py
$ runai workspace submit notebook-alice -p nlp -i nvcr.io/nvidia/pytorch:24.08-py3 \
    --gpu-portion-request 0.5
$ runai training list -p nlp
```

(Flag names have changed across Run:ai CLI versions; check `runai <workload> submit --help` for your release.)

---

## 7. Slurm in practice

### 7.1 Configuration (BCM generates this on managed clusters)

`slurm.conf` excerpt:

```ini
ClusterName=superpod
SlurmctldHost=bcm-head01
SlurmctldHost=bcm-head02

GresTypes=gpu
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

PriorityType=priority/multifactor
PriorityDecayHalfLife=7-0
PriorityWeightFairshare=100000
PriorityWeightAge=1000
PriorityWeightJobSize=1000
PriorityWeightQOS=10000

PreemptType=preempt/qos
PreemptMode=REQUEUE

SchedulerType=sched/backfill
TopologyPlugin=topology/tree

AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageTRES=gres/gpu
JobAcctGatherType=jobacct_gather/cgroup
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity

NodeName=dgx[001-032] CPUs=224 Sockets=2 CoresPerSocket=56 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:h100:8 State=UNKNOWN
PartitionName=batch Nodes=dgx[001-032] Default=YES MaxTime=7-00:00:00 State=UP OverSubscribe=EXCLUSIVE
PartitionName=interactive Nodes=dgx[001-004] MaxTime=08:00:00 State=UP
```

`gres.conf`:

```ini
AutoDetect=nvml
```

`AutoDetect=nvml` makes `slurmd` discover GPUs, their types and NVLink/CPU affinity from the driver, so GPU-to-core binding is correct. `topology.conf` describes the InfiniBand switch tree so `topology/tree` can place a job under the fewest leaf switches.

### 7.2 Multi-node job with an NGC container (Pyxis/Enroot)

```bash
#!/bin/bash
#SBATCH --job-name=llama-pretrain
#SBATCH --partition=batch
#SBATCH --account=nlp
#SBATCH --qos=normal
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --exclusive
#SBATCH --time=48:00:00
#SBATCH --requeue
#SBATCH --signal=USR1@300
#SBATCH --output=%x-%j.out

export MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
export MASTER_PORT=29500
export NCCL_DEBUG=WARN

srun --container-image=nvcr.io#nvidia/pytorch:24.08-py3 \
     --container-mounts=/lustre/nlp:/data,/lustre/ckpt:/checkpoints \
     python /data/train.py --checkpoint-dir /checkpoints --resume
```

`--signal=USR1@300` sends SIGUSR1 five minutes before the time limit or preemption so the training loop can checkpoint; `--requeue` lets Slurm put the job back in the queue after preemption.

### 7.3 Operating it

```
$ sbatch pretrain.sbatch
Submitted batch job 481233

$ squeue -u alice
  JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
 481233     batch llama-pr    alice PD       0:00      4 (Resources)
 481190     batch eval-swe    alice  R    2:13:44      1 dgx017

$ sinfo -p batch
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
batch*       up 7-00:00:00      2  drain dgx[009,021]
batch*       up 7-00:00:00     28  alloc dgx[001-008,010-020,022-030]
batch*       up 7-00:00:00      2   idle dgx[031-032]

$ sinfo -R
REASON               USER      TIMESTAMP           NODELIST
GPU Xid 79           root      2026-11-14T03:12:08 dgx009
NHC: IB link down    root      2026-11-14T06:40:51 dgx021

$ sprio -j 481233
  JOBID PARTITION   PRIORITY       SITE        AGE  FAIRSHARE    JOBSIZE        QOS
 481233 batch          58421          0        120      52300        1001       5000

$ sshare -A nlp,vision
Account                    User  RawShares  NormShares    RawUsage  EffectvUsage  FairShare
-------------------- ---------- ---------- ----------- ----------- ------------- ----------
nlp                                     50    0.500000   912834112      0.712000   0.523000
vision                                  50    0.500000   368201555      0.288000   0.871000

$ sacct -j 481190 --format=JobID,JobName,Elapsed,State,AllocTRES%60
JobID           JobName    Elapsed      State AllocTRES
------------ ---------- ---------- ---------- ------------------------------------------------------------
481190       eval-sweep   02:13:44    RUNNING billing=224,cpu=224,gres/gpu=8,mem=1950G,node=1
```

Reading the output: job 481233 is pending with reason `Resources` (not `Priority`), because it needs 4 nodes and only 2 are idle (2 more are drained); `nlp` has consumed more than its share (EffectvUsage 0.712 vs NormShares 0.5), so its FairShare factor is lower than `vision`'s.

---

## 8. Cluster management: NVIDIA Base Command Manager

NVIDIA Base Command Manager (BCM) is the cluster management software used on DGX BasePOD/SuperPOD and broadly on HGX clusters. Its responsibilities sit *below* the scheduler:

- **Provisioning**: PXE-boots nodes from centrally managed software images; changes are made once in the image and synced to nodes, keeping the fleet consistent.
- **Workload manager deployment**: wizards to deploy and configure Slurm (generating `slurm.conf`/`gres.conf`) and Kubernetes (including the GPU Operator, and optionally Run:ai).
- **Monitoring & health**: metrics collection, health checks, integration with DCGM, automatic draining of unhealthy nodes.
- **Shell and UI**: `cmsh` CLI and Base View web UI.
- **Out-of-band**: integrates with BMCs (IPMI/Redfish) for power control, sensors and console — the same out-of-band management model described in NVIDIA's BMC documentation.

```
$ cmsh -c "device; list -t physicalnode"
Type             Hostname (key)   MAC                Category    Ip             Network        Status
---------------- ---------------- ------------------ ----------- -------------- -------------- --------
PhysicalNode     dgx001           A0:88:C2:1B:4E:10  dgx-h100    10.141.0.1     internalnet    [   UP   ]
PhysicalNode     dgx009           A0:88:C2:1B:4E:90  dgx-h100    10.141.0.9     internalnet    [  DOWN  ]
...

$ cmsh -c "device; use dgx009; power status"
ipmi0 .................... [   ON    ] dgx009
```

NVIDIA's Base Command portfolio also historically included **Base Command Platform**, a hosted job-submission and data-management service for DGX Cloud; know the distinction: *BCM manages the cluster infrastructure*, while schedulers and Run:ai manage *workloads on it*.

---

## 9. Observability for scheduling decisions: DCGM

Scheduling is only as good as the data behind it. NVIDIA Data Center GPU Manager (DCGM) provides health, diagnostics and telemetry; DCGM Exporter publishes it to Prometheus.

```
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-5a1c3e2f-8b7d-4c11-9e6a-1f2b3c4d5e6f                |
+--------+----------------------------------------------------------------------+
...

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 4.x                                            |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

Key metrics for scheduling/utilization SLOs:

| Metric | Meaning |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | Coarse "a kernel was running" percentage; overstates real usage |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | Fraction of time the graphics/compute engine was active (better) |
| `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | SM and Tensor Core activity: real efficiency |
| `DCGM_FI_DEV_FB_USED` | Framebuffer memory used |
| `DCGM_FI_DEV_XID_ERRORS` | Last Xid error code: hardware/driver faults |
| `DCGM_FI_PROF_NVLINK_TX_BYTES` / `RX_BYTES` | NVLink traffic: communication-bound jobs |

An alert that catches the most expensive scheduling anti-pattern — GPUs allocated to a pod but idle:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-scheduling-efficiency
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu-efficiency
      rules:
        - alert: AllocatedGPUIdle
          expr: |
            avg by (namespace, pod) (
              DCGM_FI_PROF_GR_ENGINE_ACTIVE{pod!=""}
            ) < 0.05
          for: 2h
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} holds GPUs below 5% engine activity for 2h"
            runbook: "Check for stuck rendezvous, idle notebooks, or data-loader starvation; consider fractional GPU or MIG"
        - alert: GPUXidErrorDetected
          expr: |
            DCGM_FI_DEV_XID_ERRORS > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Xid {{ $value }} on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
            runbook: "Cordon/drain the node, run dcgmi diag -r 3, consult the Xid catalog"
```

---

## 10. Verification and failure diagnosis

### 10.1 Kubernetes: pod stuck in `Pending`

```
$ kubectl describe pod llama-ft-1-m4q9t -n nlp | sed -n '/Events/,$p'
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  41s   default-scheduler  0/12 nodes are available: 4 Insufficient nvidia.com/gpu, 6 node(s) didn't match Pod's node affinity/selector, 2 node(s) had untolerated taint {nvidia.com/gpu: present}. preemption: 0/12 nodes are available: 4 No preemption victims found for incoming pod, 8 Preemption is not helpful for scheduling.
```

Decision tree:

| Symptom in events | Likely cause | Check / fix |
|---|---|---|
| `Insufficient nvidia.com/gpu` on all GPU nodes | Genuinely full, or GPUs not advertised | `kubectl describe node` → Allocatable vs Allocated; if allocatable is 0, device plugin problem |
| Allocatable `nvidia.com/gpu: 0` | Device plugin not running, driver failed, or MIG strategy exposes `mig-*` resources instead | `kubectl get pods -n gpu-operator`; `kubectl logs ds/nvidia-device-plugin-daemonset -n gpu-operator`; check `nvidia.com/mig.config.state` |
| `didn't match node affinity/selector` | Wrong `nvidia.com/gpu.product` value or Kueue flavor labels | `kubectl get nodes -L nvidia.com/gpu.product` |
| `untolerated taint` | GPU nodes tainted, pod lacks toleration | Add toleration (or let Kueue flavor inject it) |
| Requests `nvidia.com/gpu` but node only has `nvidia.com/mig-1g.10gb` | Mixed MIG strategy | Request the MIG resource name |
| Pod never created, Job `suspend: true` | Kueue has not admitted the Workload | See 10.2 |

GPU Operator driver failure check:

```
$ kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr --tail=5
Building kernel modules...
ERROR: Unable to load the kernel module 'nvidia.ko'.
...
Kernel headers for 6.8.0-49-generic not found
```

Typical fix: pre-install a matching driver (and set `driver.enabled=false`), use precompiled driver images, or ensure the kernel headers repository is reachable.

### 10.2 Kueue: workload not admitted

```
$ kubectl get workloads -n nlp
NAME                 QUEUE       RESERVED IN   ADMITTED   FINISHED   AGE
job-llama-ft-8c2e1   nlp-queue                                       6m

$ kubectl describe workload job-llama-ft-8c2e1 -n nlp | sed -n '/Conditions/,/Events/p'
  Conditions:
    Last Transition Time:  2026-11-14T10:41:07Z
    Message:               couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu in flavor h100, 16 more needed; insufficient quota for nvidia.com/gpu in flavor a100, request > maximum capacity (16 > 8)
    Reason:                Pending
    Status:                False
    Type:                  QuotaReserved
```

Interpretation: the job needs 16 GPUs as a gang; the H100 flavor is exhausted (including what can be borrowed from the cohort), and the A100 flavor's nominal + borrowing limit can never satisfy 16. Remedies: wait, raise quota, set priority so `reclaimWithinCohort` preempts borrowers, or reduce the job size. Also verify the LocalQueue exists and points to an existing ClusterQueue — a missing `LocalQueue` leaves the Job suspended with `Inadmissible`:

```
$ kubectl get localqueue -n nlp
NAME        CLUSTERQUEUE   PENDING WORKLOADS   ADMITTED WORKLOADS
nlp-queue   team-nlp       1                   0
```

### 10.3 Distributed job running but hung (partial gang)

Symptoms: some workers `Running`, others `Pending`; `DCGM_FI_PROF_GR_ENGINE_ACTIVE` ≈ 0 on running workers; logs stuck at rendezvous.

```
$ kubectl logs llama-ft-0-x7k2p -n nlp --tail=3
[I socket.cpp:480] [c10d] waiting for 1 more worker(s) to join rendezvous at llama-ft-0.llama-ft:29500
[I socket.cpp:480] [c10d] waiting for 1 more worker(s) to join rendezvous at llama-ft-0.llama-ft:29500
```

Root cause: no gang scheduling. Fix: submit through Kueue (all-or-nothing admission, and enable `waitForPodsReady` in the Kueue configuration so admitted workloads that can't get all pods running within a timeout are evicted and requeued), Volcano (`minAvailable`), or Run:ai.

### 10.4 Slurm diagnostics

| Symptom | Command | Meaning / action |
|---|---|---|
| Job pending | `squeue -j <id> -o "%.10i %.9P %.8T %.30R"` | `Resources` = not enough free nodes; `Priority` = others ahead; `QOSMaxGRESPerUser` = per-user limit; `AssocGrpGRES` = account GPU cap reached |
| Node drained | `sinfo -R`, `scontrol show node dgx009` | Reason set by admin or health check (NHC/DCGM); fix, then `scontrol update nodename=dgx009 state=resume` |
| GPUs not visible in job | `srun --gpus=1 nvidia-smi -L`; check `gres.conf`, cgroup `ConstrainDevices=yes` | Mismatch between `slurm.conf` Gres and detected devices makes node go `INVAL`/drain |
| Poor multi-node performance | `scontrol show job <id>` (node list), `topology.conf` | Nodes spread across leaf switches; enable topology plugin / `--switches=1@01:00:00` |
| Job killed at preemption without checkpoint | `sacct -j <id> --format=JobID,State,ExitCode` shows `PREEMPTED` | Add `--signal`, `--requeue`, checkpoint handler |

```
$ scontrol show node dgx009 | grep -E 'State|Gres|Reason'
   Gres=gpu:h100:8
   State=IDLE+DRAIN ThreadsPerCore=2 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A
   Reason=GPU Xid 79 [root@2026-11-14T03:12:08]

$ ssh dgx009 "dmesg -T | grep -i xid | tail -1"
[Sat Nov 14 03:12:05 2026] NVRM: Xid (PCI:0000:9a:00): 79, pid=0, GPU has fallen off the bus.
```

Xid 79 ("GPU has fallen off the bus") is a hardware/PCIe-level fault: keep the node drained, run DCGM diagnostics after reset, and engage hardware support if it recurs. Xid 48 (double-bit ECC), 63/64 (row remapping events) and 94/95 (contained/uncontained ECC errors) are other important ones to recognize.

### 10.5 MIG reconfiguration stuck

```
$ kubectl get node dgx-h100-03 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
failed
$ kubectl logs -n gpu-operator ds/nvidia-mig-manager --tail=4
Applying the selected MIG config to the node
Error: unable to set MIG mode: In use by another client
...
```

Cause: GPU clients (a pod, DCGM, or a host process) still hold the GPU. Drain GPU workloads from the node (`kubectl drain dgx-h100-03 --ignore-daemonsets --delete-emptydir-data`), ensure the MIG Manager is allowed to stop operator components, then relabel. On some GPUs/platforms enabling MIG mode requires a GPU reset.

### 10.6 Production checklist

1. `kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/mig.config.state` — every GPU node labeled and in `success`.
2. `kubectl get pods -n gpu-operator` — all `Running`/`Completed`; validators completed.
3. Allocatable GPU resources match physical inventory × sharing factor.
4. Queue objects consistent: every team namespace has a LocalQueue → ClusterQueue → flavors that match real node labels.
5. Gang semantics in place for every multi-pod training workload.
6. Preemptible workloads checkpoint (signal handling verified).
7. DCGM Exporter scraped; idle-allocated and Xid alerts firing to on-call.
8. Slurm: `sinfo -R` empty or every drain reason ticketed; `sshare` reflects intended shares.

---

## 11. Exam-oriented summary

- **Slurm** = HPC batch scheduler; native gang scheduling, fair-share, backfill; GPUs via GRES; containers via Pyxis/Enroot. Best for large training runs.
- **Kubernetes** = container orchestrator; GPUs via the device plugin (`nvidia.com/gpu`) or DRA; needs add-ons for batch semantics. Best for mixed and inference workloads.
- **GPU Operator** automates driver, container toolkit, device plugin, GFD, MIG Manager, DCGM Exporter.
- **MIG** = hardware partitioning with isolation (up to 7 instances); **time-slicing** = oversubscription without isolation; **Run:ai fractions** = software-enforced sharing with scheduler awareness.
- **Kueue** = quota/queueing and all-or-nothing admission on top of kube-scheduler; **Volcano** = gang-scheduling batch scheduler; **Run:ai** = AI-workload platform with projects, guaranteed quota, over-quota and fractional GPUs.
- **Base Command Manager** = provisioning and lifecycle management of the cluster, deploys Slurm/Kubernetes.
- **DCGM** = GPU health, diagnostics and telemetry feeding scheduling and utilization decisions.

---

## Referencias

- NVIDIA NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA Base Command: https://www.nvidia.com/en-us/data-center/base-command/
- NVIDIA Base Command Manager documentation: https://docs.nvidia.com/base-command-manager/
- NVIDIA IGX Orin BMC introduction: https://docs.nvidia.com/igx-orin/bmc/latest/introduction.html
- NVIDIA Data Center GPU Manager (DCGM): https://developer.nvidia.com/dcgm
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NVIDIA Multi-Instance GPU: https://www.nvidia.com/en-us/technologies/multi-instance-gpu/
- NVIDIA MIG User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- GPU Operator — Time-slicing GPUs in Kubernetes: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- GPU Operator — MIG support: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html
- NVIDIA k8s-device-plugin: https://github.com/NVIDIA/k8s-device-plugin
- NVIDIA DRA driver for GPUs: https://github.com/NVIDIA/k8s-dra-driver-gpu
- Maximizing GPU Utilization with NVIDIA Run:ai and NVIDIA NIM: https://developer.nvidia.com/blog/maximizing-gpu-utilization-with-nvidia-runai-and-nvidia-nim/
- NVIDIA Run:ai documentation: https://run-ai-docs.nvidia.com/
- KAI Scheduler: https://github.com/NVIDIA/KAI-Scheduler
- NVIDIA Pyxis: https://github.com/NVIDIA/pyxis
- NVIDIA Enroot: https://github.com/NVIDIA/enroot
- NVIDIA GPU Xid errors catalog: https://docs.nvidia.com/deploy/xid-errors/
- Kubernetes documentation: https://kubernetes.io/docs/home/
- Kubernetes — Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
- Kubernetes — Dynamic Resource Allocation: https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/
- Kueue documentation: https://kueue.sigs.k8s.io/docs/
- Volcano documentation: https://volcano.sh/en/docs/
- Slurm documentation: https://slurm.schedmd.com/documentation.html
- Slurm GRES scheduling: https://slurm.schedmd.com/gres.html
- Slurm multifactor priority: https://slurm.schedmd.com/priority_multifactor.html